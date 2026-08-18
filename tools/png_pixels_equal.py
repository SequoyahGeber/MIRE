#!/usr/bin/env python3
"""Pixel-exact PNG comparison for asset-pipeline rebuilds (F-079).

F-042 established the rule: a rebuild must be judged by decoded pixels, never by file bytes, because
Blender stamps wall-clock into every PNG's `tEXt` chunk (`RenderTime`, `Date`, Cycles' total_time).
Two renders with identical pixels are never byte-identical, so comparing files reports a false
regression on every rebuild.

The obvious way to compare decoded pixels in Python is
`ImageChops.difference(a, b).getbbox()` — and that is broken for RGBA input. Pillow >= 9.2 defaults
`Image.getbbox()` to `alpha_only=True`. A *difference* image's alpha channel is the pointwise
difference of the two inputs' alpha channels, which is zero everywhere both inputs are equally
opaque — true of most rendered sprite sheets. So the call returns `None`, "identical," for a change
that moved every RGB byte and touched alpha nowhere. Not hypothetical: it cost the icon-sheet rebuild
in F-073 twice — a visible re-render of both axe cells in `item_icons_sheet.png` (fully opaque) read
as byte-only churn and was reverted, the second time *after* a direct `.convert("RGB")` comparison of
the same two files had already printed a difference bbox of `(531, 530, 1005, 749)`.

The fix: diff each band on its own and union the boxes. `Image.split()` bands are single-channel `L`
images, so `ImageChops.difference(...).getbbox()` on one of them has no alpha to default to — the
alpha_only trap has nothing to key off. Never call `.getbbox()` on a *combined* multi-band difference
image in this codebase; go through `pixel_diff_bbox` below instead.
"""

from __future__ import annotations

from pathlib import Path
from typing import Union

from PIL import Image, ImageChops

PathLike = Union[str, Path]


def pixel_diff_bbox(path_a: PathLike, path_b: PathLike) -> tuple[int, int, int, int] | None:
    """Bounding box (left, top, right, bottom) of every pixel that differs on ANY channel between
    the two decoded images, or None if they are pixel-identical. Ignores PNG metadata entirely —
    only decoded pixels are compared, per F-042.

    Differing image sizes are reported as a full-canvas box rather than raising, since "the whole
    thing changed" is the correct verdict for a batch deciding what to keep.
    """
    a = Image.open(path_a)
    b = Image.open(path_b)

    if a.size != b.size:
        return (0, 0, max(a.size[0], b.size[0]), max(a.size[1], b.size[1]))

    if a.mode != b.mode:
        # Normalize to a common mode so band counts line up for split() below, instead of
        # letting a bare RGB-vs-RGBA rebuild (a real thing a renderer's output format can drift
        # on) raise instead of comparing.
        mode = "RGBA" if "A" in a.mode or "A" in b.mode else "RGB"
        a = a.convert(mode)
        b = b.convert(mode)

    boxes = []
    for channel_a, channel_b in zip(a.split(), b.split()):
        box = ImageChops.difference(channel_a, channel_b).getbbox()
        if box:
            boxes.append(box)

    if not boxes:
        return None

    lefts, tops, rights, bottoms = zip(*boxes)
    return (min(lefts), min(tops), max(rights), max(bottoms))


def images_pixel_equal(path_a: PathLike, path_b: PathLike) -> bool:
    """True if two PNGs decode to identical pixels. This is the check a rebuild script should run
    before deciding a file actually changed — see the module docstring for why the naive
    `ImageChops.difference(a, b).getbbox()` one-liner is wrong for this."""
    return pixel_diff_bbox(path_a, path_b) is None


def _main(argv: list[str]) -> int:
    if len(argv) != 3:
        print("usage: png_pixels_equal.py <a.png> <b.png>")
        return 2
    box = pixel_diff_bbox(argv[1], argv[2])
    if box is None:
        print("identical")
        return 0
    print(f"different: bbox={box}")
    return 1


if __name__ == "__main__":
    import sys

    raise SystemExit(_main(sys.argv))
