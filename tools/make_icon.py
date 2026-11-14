"""Draws the app icon: the three black dots of the blind-person armband on yellow, arranged like the
iPhone Pro's three cameras (two stacked on the left, one centred on the right).

Usage: tools/.venv/bin/python tools/make_icon.py
"""
from pathlib import Path

from PIL import Image, ImageDraw

SIZE = 1024
SCALE = 4  # draw large and downsample for smooth edges
YELLOW = (255, 214, 0)
BLACK = (0, 0, 0)
RADIUS = 150
DOTS = [(352, 330), (352, 694), (672, 512)]  # top-left, bottom-left, right-middle; centred as a group

image = Image.new("RGB", (SIZE * SCALE, SIZE * SCALE), YELLOW)
draw = ImageDraw.Draw(image)
for x, y in DOTS:
    draw.ellipse([(x - RADIUS) * SCALE, (y - RADIUS) * SCALE, (x + RADIUS) * SCALE, (y + RADIUS) * SCALE], fill=BLACK)
out = Path(__file__).resolve().parent.parent / "Eyes/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
image.resize((SIZE, SIZE), Image.LANCZOS).save(out)
print("wrote", out)
