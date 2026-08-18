#!/usr/bin/env python3
"""Focused check for tools/png_pixels_equal.py (F-079).

Pure-Python tool bug, not a runtime one — no Godot involved, so this runs as a plain script rather
than through `agent godot`:

    python3 tools/png_pixels_equal_check.py

Prints PNG_PIXELS_EQUAL_CHECK ok / FAIL and exits 0/1.
"""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path

from PIL import Image, PngImagePlugin

sys.path.insert(0, str(Path(__file__).resolve().parent))
from png_pixels_equal import images_pixel_equal, pixel_diff_bbox  # noqa: E402

failures = 0


def check(cond: bool, msg: str) -> None:
    global failures
    if not cond:
        failures += 1
        print(f"FAIL: {msg}")


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp_str:
        tmp = Path(tmp_str)

        # The exact F-079 regression: a fully-opaque RGBA image (item_icons_sheet.png's shape),
        # changed in RGB only. ImageChops.difference(a, b).getbbox()'s alpha_only default reads
        # this as identical; pixel_diff_bbox must not.
        opaque_a = Image.new("RGBA", (16, 16), (10, 20, 30, 255))
        opaque_b = opaque_a.copy()
        opaque_b.putpixel((4, 4), (200, 20, 30, 255))  # alpha unchanged, red channel moved
        opaque_a.save(tmp / "opaque_a.png")
        opaque_b.save(tmp / "opaque_b.png")

        check(
            not images_pixel_equal(tmp / "opaque_a.png", tmp / "opaque_b.png"),
            "an RGB-only change on a fully-opaque RGBA image must be detected (this is the F-079 "
            "regression itself: alpha_only=True reads it as identical)",
        )
        box = pixel_diff_bbox(tmp / "opaque_a.png", tmp / "opaque_b.png")
        check(box == (4, 4, 5, 5), f"bbox should isolate the single changed pixel, got {box}")

        # An alpha-only change must still be caught (this path never relied on the broken default).
        alpha_a = Image.new("RGBA", (8, 8), (0, 0, 0, 255))
        alpha_b = alpha_a.copy()
        alpha_b.putpixel((2, 2), (0, 0, 0, 128))
        alpha_a.save(tmp / "alpha_a.png")
        alpha_b.save(tmp / "alpha_b.png")
        check(
            not images_pixel_equal(tmp / "alpha_a.png", tmp / "alpha_b.png"),
            "an alpha-only change must still be detected",
        )

        # Identical pixels, different tEXt metadata — the F-042 case. Must read as identical.
        meta_a = PngImagePlugin.PngInfo()
        meta_a.add_text("RenderTime", "12.3")
        meta_b = PngImagePlugin.PngInfo()
        meta_b.add_text("RenderTime", "99.9")
        same_pixels = Image.new("RGBA", (8, 8), (5, 5, 5, 255))
        same_pixels.save(tmp / "meta_a.png", pnginfo=meta_a)
        same_pixels.save(tmp / "meta_b.png", pnginfo=meta_b)
        check(
            images_pixel_equal(tmp / "meta_a.png", tmp / "meta_b.png"),
            "identical pixels with different tEXt metadata must read as identical (F-042)",
        )

        # Byte-identical files (the trivial case) must compare equal.
        check(
            images_pixel_equal(tmp / "opaque_a.png", tmp / "opaque_a.png"),
            "a file compared with itself must be identical",
        )

        # Different canvas size is reported, not raised.
        wide = Image.new("RGBA", (20, 16), (10, 20, 30, 255))
        wide.save(tmp / "wide.png")
        check(
            not images_pixel_equal(tmp / "opaque_a.png", tmp / "wide.png"),
            "a size mismatch must not be reported as identical",
        )

        # RGB vs RGBA of the same visible pixels must not raise and must compare equal.
        rgb_only = Image.new("RGB", (8, 8), (7, 8, 9))
        rgba_same = Image.new("RGBA", (8, 8), (7, 8, 9, 255))
        rgb_only.save(tmp / "rgb.png")
        rgba_same.save(tmp / "rgba.png")
        check(
            images_pixel_equal(tmp / "rgb.png", tmp / "rgba.png"),
            "RGB vs fully-opaque RGBA of the same colour must compare equal, not raise",
        )

    if failures:
        print(f"PNG_PIXELS_EQUAL_CHECK FAIL ({failures})")
        return 1
    print("PNG_PIXELS_EQUAL_CHECK ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
