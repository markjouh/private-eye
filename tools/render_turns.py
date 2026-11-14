"""Draws each saved turn's detections, faces and belongings onto its frame and prints a summary,
including how long and how loud the recorded audio was.

Usage: tools/.venv/bin/python tools/render_turns.py <debug folder> [--last N]
Writes <debug folder>/annotated/<turn id>.jpg and prints one block per turn, oldest first.
"""
import json
import sys
from pathlib import Path

import subprocess
import tempfile
import wave

import numpy as np
from PIL import Image, ImageDraw


def audio_summary(path):
    """Length and loudness of a turn's recording, or None if it cannot be read."""
    with tempfile.NamedTemporaryFile(suffix=".wav") as tmp:
        done = subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(path), tmp.name], capture_output=True)
        if done.returncode != 0:
            return None
        with wave.open(tmp.name) as w:
            samples = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float64) / 32768
    if samples.size == 0:
        return "empty"
    db = lambda v: 20 * np.log10(max(v, 1e-6))
    return f"{samples.size / 16000:.1f} s, peak {db(np.abs(samples).max()):.0f} dB, average {db(np.sqrt((samples ** 2).mean())):.0f} dB"

root = Path(sys.argv[1])
last = int(sys.argv[sys.argv.index("--last") + 1]) if "--last" in sys.argv else None
out = root / "annotated"
out.mkdir(exist_ok=True)

LAYERS = [("detections", (60, 220, 90), 2), ("faces", (255, 255, 255), 4), ("belongings", (255, 214, 0), 4)]

records = sorted((root / "turns").glob("*.json"))
if last:
    records = records[-last:]
for path in records:
    turn = json.loads(path.read_text())
    frame = path.with_suffix(".jpg")
    if frame.exists() and not (out / frame.name).exists():
        image = Image.open(frame).convert("RGB")
        draw = ImageDraw.Draw(image)
        w, h = image.size
        for key, colour, width in LAYERS:
            for box in turn.get(key, []):
                if key == "detections" and (box.get("confidence") or 0) < 0.35:
                    continue
                x0, y0 = box["x"] * w, box["y"] * h
                x1, y1 = x0 + box["width"] * w, y0 + box["height"] * h
                draw.rectangle([x0, y0, x1, y1], outline=colour, width=width)
                label = box["label"]
                if box.get("confidence") is not None:
                    label += f" {box['confidence']:.2f}"
                if box.get("distance") is not None:
                    label += f" {box['distance']:.1f}m"
                if box.get("note"):
                    label += f" ({box['note']})"
                draw.rectangle([x0, max(y0 - 14, 0), x0 + 7 * len(label) + 6, max(y0 - 14, 0) + 14], fill=colour)
                draw.text((x0 + 3, max(y0 - 14, 0) + 1), label, fill=(0, 0, 0))
        image.save(out / frame.name, quality=85)
    print(f"\n{turn['id']}  [{turn['trigger']}, {turn['pressSeconds']:.2f}s, route {turn['route']}, thermal {turn['thermal']}]")
    print(f"  heard: {turn['heard']}")
    print(f"  reply: {turn['reply']}")
    recording = path.with_suffix(".m4a")
    if recording.exists():
        print(f"  audio: {audio_summary(recording) or 'unreadable'}  ({recording.name})")
    if turn.get("model"):
        print(f"  model: {turn['model']}")
    if turn.get("context"):   # turns recorded before the model stopped being given context
        print(f"  context: {turn['context']}")
    for key in ("faces", "belongings"):
        if turn.get(key):
            print(f"  {key}: " + ", ".join(f"{b['label']} {b.get('confidence') or 0:.2f}" + (f" ({b['note']})" if b.get('note') else "") for b in turn[key]))
    for note in turn.get("notes", []):
        if not note.startswith(("Q:", "A")):
            print(f"  · {note}")
print(f"\n{len(records)} turns; annotated frames in {out}")
