"""Makes a test clip for `eyes-cli video` and `eyes-cli watch` out of still photos.

    tools/.venv/bin/python tools/make_test_clip.py out.mp4 empty.jpg:120 seated.jpg:8 [--fps 10] [--seed 1] [--still]

Each still is held for its number of seconds, with the wobble of a phone held in the hand: the
view drifts by a percent or two, tilts by a fraction of a degree and breathes in and out, and the
exposure wanders. `--still` leaves the wobble out.

This is a stand-in for real recordings, good for two things: how often watch mode asks the model,
and wrongly alerts, when nothing happens; and that an alert follows a change. The change itself is
a cut from one photo to the next, which is nothing like someone walking in, so timings measured on
these clips are the best case. Needs ffmpeg.
"""
import math
import random
import subprocess
import sys

from PIL import Image

W, H = 720, 960


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    flags = sys.argv[1:]
    fps = int(flags[flags.index("--fps") + 1]) if "--fps" in flags else 10
    seed = int(flags[flags.index("--seed") + 1]) if "--seed" in flags else 1
    if "--fps" in flags: args.remove(str(fps))
    if "--seed" in flags: args.remove(str(seed))
    still = "--still" in flags
    out, segments = args[0], [(s.rsplit(":", 1)[0], float(s.rsplit(":", 1)[1])) for s in args[1:]]
    rng = random.Random(seed)
    ffmpeg = subprocess.Popen(
        ["ffmpeg", "-loglevel", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}", "-r", str(fps),
         "-i", "-", "-c:v", "libx264", "-crf", "20", "-pix_fmt", "yuv420p", out], stdin=subprocess.PIPE)
    # Each wanders around zero and is pulled back towards it, as a hand that is trying to hold still does.
    dx = dy = angle = zoom = gain = 0.0
    for path, seconds in segments:
        source = Image.open(path).convert("RGB").resize((W, H), Image.BICUBIC)
        for _ in range(round(seconds * fps)):
            if not still:
                dx = dx * 0.93 + rng.gauss(0, 0.004)       # fraction of the width: about 1% typical
                dy = dy * 0.93 + rng.gauss(0, 0.004)
                angle = angle * 0.93 + rng.gauss(0, 0.12)  # degrees: about 0.3 typical
                zoom = zoom * 0.93 + rng.gauss(0, 0.002)
                gain = gain * 0.95 + rng.gauss(0, 0.005)
            # Zoomed in a little, so the wobble never shows the edge of the photo.
            scale = 1 / (1.07 + zoom)
            c, s = math.cos(math.radians(angle)) * scale, math.sin(math.radians(angle)) * scale
            cx, cy = W / 2, H / 2
            ox, oy = cx + dx * W, cy + dy * H
            frame = source.transform((W, H), Image.AFFINE,
                                     (c, -s, ox - c * cx + s * cy, s, c, oy - s * cx - c * cy), Image.BICUBIC)
            if gain:
                frame = frame.point(lambda v: v * (1 + gain))
            ffmpeg.stdin.write(frame.tobytes())
    ffmpeg.stdin.close()
    sys.exit(ffmpeg.wait())


if __name__ == "__main__":
    main()
