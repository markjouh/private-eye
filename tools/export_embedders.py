"""Convert the two embedding models used for memory to Core ML.

  face:  ArcFace ResNet-50 (InsightFace buffalo_l, w600k_r50.onnx) -> Models/arcface_r50.mlpackage
         input: 112x112 aligned face, output: 512-d identity embedding
  thing: DINOv3 ViT-S/16 (timm)                                   -> Models/dinov3_s.mlpackage
         input: 224x224 object crop, output: 384-d CLS embedding

Usage:  tools/.venv/bin/python tools/export_embedders.py [face] [thing]   (run from tools/work)
Each conversion is checked against the source model on random input before it is saved.
"""
import shutil
import sys
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
MODELS = ROOT / "Models"


def to_coreml(module, size, scale, bias, out_name, dst):
    module.eval()
    example = torch.rand(1, 3, size, size)
    traced = torch.jit.trace(module, example, strict=False)
    ml = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=(1, 3, size, size), scale=scale, bias=bias,
                             color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name=out_name)],
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT16,
    )
    ml.save(str(dst))
    return ml


def cosine(a, b):
    a, b = np.asarray(a).ravel(), np.asarray(b).ravel()
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b)))


def export_face():
    import onnx
    import onnxruntime as ort
    from onnx2torch import convert

    src = Path("w600k_r50.onnx")
    net = convert(onnx.load(str(src)))
    ml = to_coreml(net, 112, 1 / 127.5, [-1.0, -1.0, -1.0], "embedding", MODELS / "arcface_r50.mlpackage")

    # Same pixels through ONNX Runtime and Core ML must give the same direction.
    sess = ort.InferenceSession(str(src), providers=["CPUExecutionProvider"])
    rng = np.random.default_rng(0)
    worst = 1.0
    for _ in range(5):
        img = rng.integers(0, 256, (112, 112, 3), dtype=np.uint8)
        x = ((img.astype(np.float32) - 127.5) / 127.5).transpose(2, 0, 1)[None]
        ref = sess.run(None, {sess.get_inputs()[0].name: x})[0]
        got = ml.predict({"image": Image.fromarray(img)})["embedding"]
        worst = min(worst, cosine(ref, got))
    print(f"face: Core ML vs ONNX cosine >= {worst:.5f}")
    assert worst > 0.995, "face conversion mismatch"


class HalfSafeAttention(torch.nn.Module):
    """timm's EvaAttention, computing the same attention weights without leaving float16 range.

    Block 0 of DINOv3 has queries and keys in the thousands, so its attention logits reach 10^6 while
    float16 ends at 65504: the CPU returns NaN and the Neural Engine clips them (cosine 0.995 against
    PyTorch). Here the q and k rows of the qkv weights are scaled down, the row maximum is subtracted
    (softmax ignores a per-row shift), what is left is clamped where exp() is zero anyway, and only then
    is the scale restored.
    """

    DOWN = 1 / 64

    def __init__(self, attn):
        super().__init__()
        assert attn.q_bias is None and attn.gate is None, "unexpected EvaAttention variant"
        self.heads, self.prefix, self.half = attn.num_heads, attn.num_prefix_tokens, attn.rotate_half
        self.up = attn.scale / self.DOWN**2
        self.qkv, self.proj = attn.qkv, attn.proj
        with torch.no_grad():
            self.qkv.weight[: 2 * self.qkv.in_features] *= self.DOWN

    def forward(self, x, rope=None, attn_mask=None, is_causal=False):
        from timm.layers import apply_rot_embed_cat

        B, N, C = x.shape
        q, k, v = (t.reshape(B, N, self.heads, -1).transpose(1, 2) for t in self.qkv(x).chunk(3, dim=-1))
        p = self.prefix
        q = torch.cat([q[:, :, :p], apply_rot_embed_cat(q[:, :, p:], rope, half=self.half)], dim=2)
        k = torch.cat([k[:, :, :p], apply_rot_embed_cat(k[:, :, p:], rope, half=self.half)], dim=2)
        logits = q @ k.transpose(-2, -1)
        logits = logits - logits.amax(dim=-1, keepdim=True)
        weights = (logits.clamp(min=-30000 / self.up) * self.up).softmax(dim=-1)
        return self.proj((weights @ v).transpose(1, 2).reshape(B, N, C))


class Dino(torch.nn.Module):
    """DINOv3 ViT-S/16 laid out for Core ML: pixels in 0..1 in, L2-normalised CLS token out.

    The forward pass is spelled out instead of calling timm's. Traced through timm's `_pos_embed` (which
    expands the CLS and register tokens to the batch size before joining them to the patches), the graph
    makes Core ML hand block 0 back and forth between the Neural Engine and the CPU, and that model returns
    wrong embeddings on the Neural Engine (cosine 0.4-0.7 against PyTorch; fine on CPU and GPU). With the
    prefix tokens and the RoPE table as constants it stays on the Neural Engine from the first convolution
    to the output.
    """

    def __init__(self, net, size):
        super().__init__()
        grid = size // net.patch_embed.patch_size[0]
        self.net = net
        self.register_buffer("mean", torch.tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1))
        self.register_buffer("prefix", torch.cat([net.cls_token, net.reg_token], dim=1).detach())
        self.register_buffer("rope", net.rope.get_embed(shape=(grid, grid)).detach())
        net.blocks[0].attn = HalfSafeAttention(net.blocks[0].attn)

    def forward(self, x):
        x = self.net.patch_embed.proj((x - self.mean) / self.std).flatten(2).transpose(1, 2)
        x = torch.cat([self.prefix, x], dim=1)
        for block in self.net.blocks:
            x = block(x, rope=self.rope)
        return torch.nn.functional.normalize(self.net.norm(x)[:, 0], dim=-1)


def selfcheck_image(size):
    """A fixed test picture that ThingEmbedder.swift can draw too: two gradients and a checkerboard."""
    y, x = np.mgrid[0:size, 0:size]
    return np.stack([x * 255 // (size - 1), y * 255 // (size - 1), (x // 16 + y // 16) % 2 * 255], axis=-1).astype(np.uint8)


def export_thing():
    import json

    import timm

    size = 224
    # timm averages the patch tokens by default. DINOv3 itself uses the CLS token, and it tells objects apart
    # far better: 93% top-1 against 85% on the Objectron crops (eyes-cli things).
    net = timm.create_model("vit_small_patch16_dinov3.lvd1689m", pretrained=True, num_classes=0, global_pool="token").eval()

    rng = np.random.default_rng(0)
    images = [selfcheck_image(size)] + [rng.integers(0, 256, (size, size, 3), dtype=np.uint8) for _ in range(3)]
    images += [np.asarray(Image.open(f).convert("RGB").resize((size, size))) for f in sorted(Path("objectron").glob("*.jpg"))[::8]]

    # References come from timm's untouched forward pass, before Dino rewires the network.
    mean, std = torch.tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1), torch.tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1)
    with torch.no_grad():
        refs = [torch.nn.functional.normalize(
            net((torch.from_numpy(img.astype(np.float32) / 255).permute(2, 0, 1)[None] - mean) / std), dim=-1).numpy()
            for img in images]

    unverified = Path("dinov3_s.unverified.mlpackage")
    ml = to_coreml(Dino(net, size), size, 1 / 255.0, [0.0, 0.0, 0.0], "embedding", unverified)

    # Each backend has its own arithmetic, and the failures this guards against were specific to one of them.
    for units in (ct.ComputeUnit.CPU_ONLY, ct.ComputeUnit.CPU_AND_GPU, ct.ComputeUnit.CPU_AND_NE):
        model = ct.models.MLModel(str(unverified), compute_units=units)
        scores = [cosine(ref, model.predict({"image": Image.fromarray(img)})["embedding"]) for ref, img in zip(refs, images)]
        print(f"thing: Core ML ({units.name}) vs PyTorch cosine >= {min(scores):.5f} over {len(images)} images")
        assert min(scores) > 0.999, f"thing conversion mismatch on {units.name}"

    # ThingEmbedder repeats this comparison on the phone when it loads the model.
    ml.user_defined_metadata["selfcheck_embedding"] = json.dumps([round(float(v), 6) for v in refs[0].ravel()])
    ml.save(str(MODELS / "dinov3_s.mlpackage"))
    shutil.rmtree(unverified)


if __name__ == "__main__":
    which = sys.argv[1:] or ["face", "thing"]
    if "face" in which:
        export_face()
    if "thing" in which:
        export_thing()
