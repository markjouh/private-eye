"""Export YOLOE-26m (open-vocabulary) to Core ML with a fixed everyday-object vocabulary.

Usage:  tools/.venv/bin/python tools/export_yoloe.py
Output: Models/yoloe26m.mlpackage + Eyes/Resources/yoloe_labels.json

The text prompts are baked into the detection head at export time, so changing
VOCAB means re-running this script. Input is portrait 640x480 (HxW) to match the
iPhone's 4:3 camera frames without letterboxing.
"""
import json
import shutil
from pathlib import Path

from ultralytics import YOLOE

ROOT = Path(__file__).resolve().parent.parent
WEIGHTS = "yoloe-26m-seg.pt"
IMGSZ = (640, 480)  # (height, width)

VOCAB = [
    # people
    "person", "face", "hand",
    # furniture / indoor structure
    "chair", "couch", "bed", "table", "desk", "bench", "stool", "shelf", "cabinet", "drawer",
    "door", "door handle", "window", "stairs", "elevator", "escalator", "railing",
    "light switch", "power outlet", "lamp", "mirror", "curtain", "rug", "trash can",
    "sink", "faucet", "toilet", "bathtub", "shower", "towel",
    # kitchen
    "refrigerator", "oven", "stove", "microwave", "toaster", "kettle", "coffee maker", "dishwasher",
    "cup", "mug", "glass", "bottle", "bowl", "plate", "fork", "knife", "spoon", "pan", "pot",
    # food
    "apple", "banana", "orange", "sandwich", "pizza", "bread", "can", "food package", "box",
    # personal items
    "phone", "laptop", "keyboard", "computer mouse", "monitor", "television", "remote control",
    "headphones", "charger", "cable", "book", "notebook", "pen", "paper", "wallet", "keys",
    "glasses", "sunglasses", "watch", "backpack", "handbag", "suitcase", "umbrella", "hat",
    "shoe", "jacket", "pill bottle", "medicine box", "toothbrush", "scissors", "white cane",
    "clock", "vase", "potted plant", "pillow", "blanket", "fan", "washing machine",
    # outdoors / navigation
    "car", "bus", "truck", "bicycle", "motorcycle", "scooter", "train", "traffic light",
    "stop sign", "street sign", "sign", "crosswalk", "curb", "pole", "fire hydrant",
    "parking meter", "mailbox", "tree", "fence", "wet floor sign", "traffic cone",
    "wheelchair", "stroller", "shopping cart", "atm", "vending machine", "screen",
    # animals
    "dog", "cat", "bird",
]


def main() -> None:
    assert len(VOCAB) == len(set(VOCAB)), "duplicate vocab entries"
    model = YOLOE(WEIGHTS)
    model.set_classes(VOCAB, model.get_text_pe(VOCAB))
    out = model.export(format="coreml", imgsz=IMGSZ, half=True, nms=False)
    dst = ROOT / "Models" / "yoloe26m.mlpackage"
    if dst.exists():
        shutil.rmtree(dst)
    shutil.move(out, dst)
    labels = ROOT / "Eyes" / "Resources" / "yoloe_labels.json"
    labels.parent.mkdir(parents=True, exist_ok=True)
    labels.write_text(json.dumps(VOCAB, indent=0))
    print("wrote", dst, "and", labels, f"({len(VOCAB)} classes)")


if __name__ == "__main__":
    main()
