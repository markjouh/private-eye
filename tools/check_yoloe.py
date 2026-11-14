"""Sanity-check the exported Core ML detector on a few images (prints top detections)."""
import json, sys, time
from pathlib import Path
import numpy as np
import coremltools as ct
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
m = ct.models.MLModel(str(ROOT / "Models" / "yoloe26m.mlpackage"))
spec = m.get_spec()
print("inputs:", [(i.name, i.type.WhichOneof("Type")) for i in spec.description.input])
for i in spec.description.input:
    if i.type.WhichOneof("Type") == "imageType":
        print("  image", i.type.imageType.width, "x", i.type.imageType.height, i.type.imageType.colorSpace)
print("outputs:", [(o.name, list(o.type.multiArrayType.shape)) for o in spec.description.output])
labels = json.loads((ROOT / "Eyes/Resources/yoloe_labels.json").read_text())
inp = spec.description.input[0]
W, H = inp.type.imageType.width, inp.type.imageType.height
for p in sys.argv[1:]:
    im = Image.open(p).convert("RGB").resize((W, H))
    t = time.time(); out = m.predict({inp.name: im}); dt = time.time() - t
    for k, v in out.items():
        v = np.asarray(v)
        if v.ndim == 3 and v.shape[1] <= 400:
            det = v[0]
            keep = det[det[:, 4] > 0.25]
            print(Path(p).name, f"{dt*1000:.0f} ms", k, v.shape, "->",
                  [(labels[int(d[5])], round(float(d[4]), 2), [int(x) for x in d[:4]]) for d in keep[:12]])
        else:
            print("  other output", k, v.shape)
