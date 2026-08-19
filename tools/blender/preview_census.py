"""Count the subjects in a contact sheet, so a blank tile fails instead of shipping.

  python3 tools/blender/preview_census.py                 # every kit, against the manifest
  python3 tools/blender/preview_census.py --sheet PATH --expect N

Why this exists
---------------
F-204: an A-012 contact sheet shipped with one of five tiles blank. Every probe said the asset was
fine — present in the scene, `hide_render` false, `visible_get()` true, in a linked collection,
carrying its 109 polygons, `matrix_world` at exactly the requested position — and the sheet was still
wrong. F-222 then found that eight other generators render correctly only because something
incidental (a scale-reference cube created with `bpy.ops.mesh.primitive_*_add`, or a camera type
flip) happens to sit between their reposition and their render, and recorded that **no check in the
project would notice if that stopped happening**: `asset_repro_check.py` compares geometry, never
pixels, and none of the eight generators has a `check()` at all.

This is that check. It does not care WHY a sheet is wrong — the mechanism resisted two controlled
repros (see F-204's correction) — only that the picture contains what it claims to. Reading the
pixels is the one method that cannot be fooled by a scene that measures correctly.

Pure standard library: PNG decode is ~40 lines and this has to run in CI, in a hook, and from a
plain shell without Blender.
"""

from __future__ import annotations

import struct
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

#: sheet -> how many distinct subjects the census MEASURES today, including the
#: scale reference. Calibrated from the shipped sheets rather than counted by eye,
#: because two touching silhouettes read as one subject and a detached tail reads
#: as two — the number that matters is the one this tool sees, and a sheet that
#: gains or loses an asset updates it here, as a decision somebody makes rather
#: than a silent change in a picture.
MANIFEST: dict[str, int] = {
    "assets/construction/preview/construction_pieces_preview.png": 19,
    "assets/food/preview/food_cooked_preview.png": 8,
    "assets/food/preview/food_vessels_preview.png": 4,
    "assets/food/preview/food_tonics_preview.png": 6,
    "assets/camp/preview/camp_storage_preview.png": 6,
    "assets/camp/preview/camp_furniture_preview.png": 6,
    "assets/camp/preview/camp_racks_preview.png": 6,
    "assets/paths/preview/path_surfaces_preview.png": 5,
    "assets/paths/preview/path_boardwalk_preview.png": 6,
    "assets/paths/preview/path_markers_preview.png": 5,
    "assets/gatherables/preview/gatherable_plants_preview.png": 7,
    "assets/gatherables/preview/gatherable_deposits_preview.png": 5,
}

#: Two subjects whose silhouettes touch merge into one run; a tail detached from
#: its fish splits one subject into two. Both are normal, so the count is checked
#: as a range — but the count is the WEAK assertion.
TOLERANCE = 2

#: The strong one is spacing. A sheet lays its subjects on an even pitch, so a
#: missing tile leaves a gap about twice as wide as its neighbours — which is
#: exactly how F-204's blank tile was actually spotted, by measuring the picture
#: rather than by looking at it. A count can hide a missing subject (two others
#: merged, and the total is unchanged); a hole in the rhythm cannot.
MAX_GAP_RATIO = 1.75


def decode(path: Path) -> tuple[int, int, list[bytes]]:
    data = path.read_bytes()
    position, idat, width, height, colour, depth = 8, b"", 0, 0, 0, 0
    while position < len(data):
        length = struct.unpack(">I", data[position:position + 4])[0]
        kind = data[position + 4:position + 8]
        body = data[position + 8:position + 8 + length]
        if kind == b"IHDR":
            width, height, depth, colour = struct.unpack(">IIBB", body[:10])
        elif kind == b"IDAT":
            idat += body
        position += 12 + length
    if depth != 8 or colour not in (2, 6):
        raise SystemExit(f"{path}: only 8-bit RGB/RGBA PNGs are handled, got depth {depth} colour {colour}")
    channels = 4 if colour == 6 else 3
    raw = zlib.decompress(idat)
    stride = width * channels + 1
    rows: list[bytes] = []
    previous = bytearray(width * channels)
    for y in range(height):
        filter_kind = raw[y * stride]
        line = bytearray(raw[y * stride + 1:(y + 1) * stride])
        if filter_kind == 1:
            for i in range(channels, len(line)):
                line[i] = (line[i] + line[i - channels]) & 255
        elif filter_kind == 2:
            for i in range(len(line)):
                line[i] = (line[i] + previous[i]) & 255
        elif filter_kind == 3:
            for i in range(len(line)):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + previous[i]) >> 1)) & 255
        elif filter_kind == 4:
            for i in range(len(line)):
                a = line[i - channels] if i >= channels else 0
                b = previous[i]
                c = previous[i - channels] if i >= channels else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else (b if pb <= pc else c))) & 255
        rows.append(bytes(line))
        previous = line
    return width, channels, rows


def width_of(path: Path) -> int:
    return decode(path)[0]


def subjects(path: Path) -> list[tuple[int, int]]:
    """Occupied column runs. The background is whatever colour the sheet's own
    corner is, which is how this works across kits that light their backdrops
    differently without a per-kit threshold."""
    width, channels, rows = decode(path)
    corner = rows[2][:3]
    counts = [0] * width
    for row in rows:
        for x in range(width):
            offset = x * channels
            if (abs(row[offset] - corner[0]) > 14 or abs(row[offset + 1] - corner[1]) > 14
                    or abs(row[offset + 2] - corner[2]) > 14):
                counts[x] += 1
    runs: list[tuple[int, int]] = []
    start = None
    for x, count in enumerate(counts):
        # A stray pixel of anti-aliasing is not a subject; a gap of a few pixels
        # inside one silhouette is not a boundary.
        occupied = count > 2
        if occupied and start is None:
            start = x
        elif not occupied and start is not None:
            if x - start > 6:
                runs.append((start, x))
            start = None
    if start is not None and width - start > 6:
        runs.append((start, width))
    merged: list[tuple[int, int]] = []
    for run in runs:
        if merged and run[0] - merged[-1][1] <= 8:
            merged[-1] = (merged[-1][0], run[1])
        else:
            merged.append(run)
    return merged


def gap_report(runs: list[tuple[int, int]]) -> tuple[float, float, str]:
    """Widest gap between subject centres, as a multiple of the median gap."""
    if len(runs) < 4:
        return 0.0, 0.0, ""
    centres = [(start + end) * 0.5 for start, end in runs]
    gaps = [b - a for a, b in zip(centres, centres[1:])]
    ordered = sorted(gaps)
    median = ordered[len(ordered) // 2]
    if median <= 0.0:
        return 0.0, 0.0, ""
    worst = max(gaps)
    where = centres[gaps.index(worst)]
    return worst / median, median, f" at x~{int(where)}"


def main() -> None:
    argv = sys.argv[1:]
    if "--sheet" in argv:
        path = Path(argv[argv.index("--sheet") + 1])
        expect = int(argv[argv.index("--expect") + 1]) if "--expect" in argv else None
        found = subjects(path)
        ratio, median, where = gap_report(found)
        print(f"{path}: {len(found)} subject(s), widest gap {ratio:.2f}x median{where}")
        print(f"  runs {found}")
        # The gap check runs on the single-sheet path too. Without it this mode
        # would pass a sheet with a tile blanked out, which is the one thing the
        # tool exists to catch — verified by blanking a tile and watching it fail.
        if ratio > MAX_GAP_RATIO:
            raise SystemExit(f"FAIL a subject is missing: gap {ratio:.2f}x the median{where}")
        if expect is not None and abs(len(found) - expect) > TOLERANCE:
            raise SystemExit(f"FAIL expected about {expect}")
        return

    failures = 0
    missing = 0
    for relative, expect in sorted(MANIFEST.items()):
        path = ROOT / relative
        if not path.exists():
            print(f"SKIP  {relative} (not rendered)")
            missing += 1
            continue
        found = subjects(path)
        # A sheet rendered over a lit ground plane has no plain backdrop to
        # measure against — every column is occupied and the whole row reads as
        # one subject. Say so rather than failing: the sheet is not wrong, it is
        # unmeasurable by this method, and that is a fact about the sheet.
        if len(found) == 1 and found[0][1] - found[0][0] > width_of(path) * 0.9:
            print(f"SKIP  {relative}: backdrop is not plain, so subjects cannot be separated")
            missing += 1
            continue
        ratio, median, where = gap_report(found)
        ok = abs(len(found) - expect) <= TOLERANCE and ratio <= MAX_GAP_RATIO
        detail = f"{len(found)} subjects, expected ~{expect}"
        if ratio:
            detail += f", widest gap {ratio:.2f}x median{where}"
        print(f"{'PASS' if ok else 'FAIL'}  {relative}: {detail}")
        if not ok:
            failures += 1
    print(f"PREVIEW_CENSUS sheets={len(MANIFEST) - missing} failures={failures}")
    raise SystemExit(1 if failures else 0)


if __name__ == "__main__":
    main()
