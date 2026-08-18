"""Draw `world/gen/layouts/hollowmere.json` as a plan view.

    python3 tools/mapgen/hollowmere_plan.py [out.svg]

Writes a self-contained SVG — the terrain, water and roads as an embedded PNG
raster, everything you navigate by as labelled vector on top of it.

It exists because the numeric checks can prove a map is *correct* and cannot show
anyone whether it is *good*. `tools/hollowmere_render_check.gd` takes the in-engine
screenshots, but it needs a framebuffer and `agent godot` is always headless, so
between "the validator passed" and "somebody opened the editor" there was nothing
at all. A plan is not a screenshot, but it is the view that answers the questions a
layout raises: is anything stranded, do the roads go where people go, is the far
side of the map worth walking to.

Pure stdlib, including the PNG encoder — this must never become a reason to
install anything.
"""

from __future__ import annotations

import base64
import json
import math
import struct
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LAYOUT = ROOT / "world" / "gen" / "layouts" / "hollowmere.json"

PIXELS_PER_METRE = 4
MARGIN = 24

#: Prop families, in the order they are tested. First match wins, so the specific
#: entries come before `boulder`/`rock` and the catch-all is last.
FAMILIES: list[tuple[str, tuple[int, int, int], float]] = [
    ("enemy_crawler_nest", (236, 64, 122), 3.4),
    ("harvest_tree", (255, 214, 64), 2.4),
    ("stone_node", (176, 190, 197), 2.4),
    ("iron_node", (255, 138, 101), 2.4),
    ("wellspring", (186, 104, 200), 2.6),
    ("ward_", (77, 208, 225), 2.2),
    ("loot_", (255, 241, 118), 2.2),
    ("station_", (255, 167, 38), 2.6),
    ("tree_willow", (102, 187, 106), 2.6),
    ("tree_snag", (141, 110, 99), 2.0),
    ("tree_bare", (161, 136, 127), 2.0),
    ("tree_", (56, 142, 60), 2.2),
    ("mire_", (156, 39, 176), 1.8),
    ("sapling", (129, 199, 132), 1.2),
    ("bush_", (85, 139, 47), 1.2),
    ("standing_stone", (120, 144, 156), 2.2),
    ("ruin_", (144, 130, 116), 1.8),
    ("boulder_", (120, 124, 130), 1.6),
    ("rock_cluster", (140, 144, 150), 1.2),
    ("stump_", (121, 85, 72), 1.2),
    ("fallen_log", (109, 76, 65), 1.4),
    ("reeds_", (124, 152, 112), 1.0),
    ("pickup_", (255, 255, 255), 1.0),
    ("", (96, 100, 96), 0.9),
]


def png(width: int, height: int, rgb: bytearray) -> bytes:
    """A minimal RGB PNG. `rgb` is width*height*3 bytes, top row first."""
    raw = bytearray()
    stride = width * 3
    for row in range(height):
        raw.append(0)
        raw.extend(rgb[row * stride:(row + 1) * stride])

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
            + chunk(b"IEND", b""))


def main() -> None:
    layout = json.loads(LAYOUT.read_text())
    field = layout["heightfield"]
    origin_x, origin_z = field["origin"]
    cell = float(field["cell"])
    nx, nz = int(field["nx"]), int(field["nz"])
    heights = field["heights"]
    material_names = field["material_names"]
    material_index = field["material_index"]
    palette = layout["materials"]

    bound = float(layout["bound"])
    span = bound * 2.0
    size = int(span * PIXELS_PER_METRE)

    def to_pixel(x: float, z: float) -> tuple[float, float]:
        return ((x + bound) * PIXELS_PER_METRE, (z + bound) * PIXELS_PER_METRE)

    def height_at(x: float, z: float) -> float:
        fx = min(max((x - origin_x) / cell, 0.0), nx - 1.001)
        fz = min(max((z - origin_z) / cell, 0.0), nz - 1.001)
        ix, iz = int(fx), int(fz)
        tx, tz = fx - ix, fz - iz
        h00 = heights[iz * nx + ix]
        h10 = heights[iz * nx + ix + 1]
        h01 = heights[(iz + 1) * nx + ix]
        h11 = heights[(iz + 1) * nx + ix + 1]
        if tz <= tx:
            return h00 + (h10 - h00) * tx + (h11 - h10) * tz
        return h00 + (h11 - h01) * tx + (h01 - h00) * tz

    def material_at(x: float, z: float) -> str:
        ix = min(max(int(round((x - origin_x) / cell)), 0), nx - 1)
        iz = min(max(int(round((z - origin_z) / cell)), 0), nz - 1)
        return material_names[material_index[iz * nx + ix]]

    def water_at(x: float, z: float) -> tuple[float, str] | None:
        best: tuple[float, str] | None = None
        for body in layout["water"]:
            level = body_level(body, x, z)
            if level is None:
                continue
            if best is None or level > best[0]:
                best = (level, str(body.get("material", "lake")))
        return best

    def body_level(body: dict, x: float, z: float) -> float | None:
        kind = body.get("kind")
        if kind == "circle":
            cx, cz = body["centre"]
            return body["level"] if math.hypot(x - cx, z - cz) <= body["radius"] else None
        if kind == "rect":
            lo, hi = body["min"], body["max"]
            return body["level"] if lo[0] <= x <= hi[0] and lo[1] <= z <= hi[1] else None
        if kind == "polyline":
            points = body["points"]
            half = float(body["half_width"])
            best_distance, best_level = 1e9, 0.0
            for index in range(len(points) - 1):
                ax, az, a_level = points[index]
                bx, bz, b_level = points[index + 1]
                dx, dz = bx - ax, bz - az
                length_sq = dx * dx + dz * dz
                t = 0.0 if length_sq < 1e-9 else min(
                    max(((x - ax) * dx + (z - az) * dz) / length_sq, 0.0), 1.0)
                distance = math.hypot(x - (ax + dx * t), z - (az + dz * t))
                if distance < best_distance:
                    best_distance = distance
                    best_level = a_level + (b_level - a_level) * t
            return best_level if best_distance <= half else None
        return None

    # -- raster: ground colour, hillshaded, with water over it ---------------
    pixels = bytearray(size * size * 3)
    for py in range(size):
        z = -bound + (py + 0.5) / PIXELS_PER_METRE
        for px in range(size):
            x = -bound + (px + 0.5) / PIXELS_PER_METRE
            spec = palette.get(material_at(x, z), {"color": [0.3, 0.3, 0.3, 1.0]})
            red, green, blue = (min(1.0, c * 1.9) for c in spec["color"][:3])

            # Hillshade from the same surface the engine meshes, so the plan reads
            # as terrain rather than as a flat map of colours.
            here = height_at(x, z)
            slope_x = height_at(x + 1.4, z) - here
            slope_z = height_at(x, z + 1.4) - here
            shade = min(1.55, max(0.42, 1.0 + (slope_x * 0.30 - slope_z * 0.30)))
            red, green, blue = red * shade, green * shade, blue * shade

            water = water_at(x, z)
            if water is not None and here < water[0]:
                depth = min(1.0, (water[0] - here) / 3.0)
                tint = layout["water_materials"][water[1]]["color"]
                mix = 0.42 + 0.5 * depth
                red = red * (1.0 - mix) + tint[0] * 2.2 * mix
                green = green * (1.0 - mix) + tint[1] * 2.2 * mix
                blue = blue * (1.0 - mix) + tint[2] * 2.4 * mix

            if math.hypot(x, z) > bound:
                red, green, blue = red * 0.34, green * 0.34, blue * 0.36

            slot = (py * size + px) * 3
            pixels[slot] = int(min(255, max(0, red * 255)))
            pixels[slot + 1] = int(min(255, max(0, green * 255)))
            pixels[slot + 2] = int(min(255, max(0, blue * 255)))

    # -- the same plan drawn straight into the raster ------------------------
    #
    # A PNG as well as the SVG, because an SVG needs something that can render one
    # and the whole point of this tool is that nothing has to be installed or
    # opened. Both are drawn from the same arrays, so they cannot disagree.
    def dot(x: float, z: float, colour: tuple[int, int, int], radius: float) -> None:
        cx, cy = to_pixel(x, z)
        span = int(math.ceil(radius))
        for oy in range(-span, span + 1):
            for ox in range(-span, span + 1):
                if ox * ox + oy * oy > radius * radius:
                    continue
                px, py = int(cx) + ox, int(cy) + oy
                if not (0 <= px < size and 0 <= py < size):
                    continue
                slot = (py * size + px) * 3
                pixels[slot], pixels[slot + 1], pixels[slot + 2] = colour

    def line(a: tuple[float, float], b: tuple[float, float],
             colour: tuple[int, int, int], half: float) -> None:
        ax, ay = to_pixel(*a)
        bx, by = to_pixel(*b)
        steps = max(2, int(math.hypot(bx - ax, by - ay)))
        for step in range(steps + 1):
            t = step / steps
            for oy in range(-int(half), int(half) + 1):
                for ox in range(-int(half), int(half) + 1):
                    px = int(ax + (bx - ax) * t) + ox
                    py = int(ay + (by - ay) * t) + oy
                    if not (0 <= px < size and 0 <= py < size):
                        continue
                    slot = (py * size + px) * 3
                    for channel in range(3):
                        pixels[slot + channel] = (pixels[slot + channel] + colour[channel]) // 2

    for road in layout["roads"]:
        points = road["points"]
        for index in range(len(points) - 1):
            line(tuple(points[index]), tuple(points[index + 1]), (235, 214, 170),
                 max(1.0, road["half"] * PIXELS_PER_METRE * 0.5))
    for prop in layout["props"]:
        for prefix, colour, radius in FAMILIES:
            if prop["asset"].startswith(prefix):
                dot(prop["pos"][0], prop["pos"][2], colour, radius)
                break
    for marker in layout["markers"]:
        fill = {"spawn": (255, 255, 255), "objective": (206, 147, 216),
                "extraction": (128, 203, 196), "enemy_nest": (255, 92, 138),
                "bridge": (215, 204, 200), "landmark": (255, 224, 130)}.get(marker["kind"])
        if fill is None:
            continue
        dot(marker["pos"][0], marker["pos"][2], (18, 21, 26), 6.0)
        dot(marker["pos"][0], marker["pos"][2], fill, 4.0)

    encoded = base64.b64encode(png(size, size, pixels)).decode("ascii")

    # -- vector: roads, props, landmarks -------------------------------------
    width = size + MARGIN * 2
    height = size + MARGIN * 2 + 92
    out: list[str] = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 {width} {height}" font-family="system-ui,sans-serif">',
        f'<rect width="{width}" height="{height}" fill="#12151a"/>',
        f'<g transform="translate({MARGIN},{MARGIN})">',
        f'<image x="0" y="0" width="{size}" height="{size}" '
        f'href="data:image/png;base64,{encoded}"/>',
    ]

    for road in layout["roads"]:
        points = " ".join(f"{to_pixel(x, z)[0]:.1f},{to_pixel(x, z)[1]:.1f}"
                          for x, z in road["points"])
        out.append(f'<polyline points="{points}" fill="none" stroke="#e8d3a8" '
                   f'stroke-opacity="0.5" stroke-width="{road["half"] * PIXELS_PER_METRE:.1f}" '
                   'stroke-linecap="round" stroke-linejoin="round"/>')

    by_family: dict[tuple[int, int, int], list[str]] = {}
    radii: dict[tuple[int, int, int], float] = {}
    for prop in layout["props"]:
        asset = prop["asset"]
        for prefix, colour, radius in FAMILIES:
            if asset.startswith(prefix):
                px, py = to_pixel(prop["pos"][0], prop["pos"][2])
                by_family.setdefault(colour, []).append(f"M{px:.1f} {py:.1f}h.01")
                radii[colour] = radius
                break
    for colour, path in by_family.items():
        out.append('<path d="%s" stroke="rgb(%d,%d,%d)" stroke-width="%.1f" '
                   'stroke-linecap="round" fill="none" stroke-opacity="0.95"/>'
                   % ("".join(path), colour[0], colour[1], colour[2], radii[colour] * 2.0))

    for marker in layout["markers"]:
        kind = marker["kind"]
        if kind not in ("landmark", "objective", "extraction", "spawn", "enemy_nest", "bridge"):
            continue
        px, py = to_pixel(marker["pos"][0], marker["pos"][2])
        fill = {"spawn": "#ffffff", "objective": "#ce93d8", "extraction": "#80cbc4",
                "enemy_nest": "#ff5c8a", "bridge": "#d7ccc8"}.get(kind, "#ffe082")
        out.append(f'<circle cx="{px:.1f}" cy="{py:.1f}" r="4" fill="{fill}" '
                   'stroke="#12151a" stroke-width="1.6"/>')
        if kind in ("landmark", "objective", "extraction", "spawn"):
            label = marker["name"].replace("_", " ")
            out.append(f'<text x="{px + 7:.1f}" y="{py + 4:.1f}" font-size="12" '
                       f'fill="#12151a" stroke="#12151a" stroke-width="3.4" '
                       f'stroke-linejoin="round">{label}</text>'
                       f'<text x="{px + 7:.1f}" y="{py + 4:.1f}" font-size="12" '
                       f'fill="#f4efe6">{label}</text>')

    out.append(f'<circle cx="{size / 2}" cy="{size / 2}" r="{bound * PIXELS_PER_METRE}" '
               'fill="none" stroke="#f4efe6" stroke-opacity="0.28" stroke-dasharray="6 6"/>')
    out.append("</g>")

    kits: dict[str, int] = {}
    for prop in layout["props"]:
        kits[prop["kit"]] = kits.get(prop["kit"], 0) + 1
    harvestable = sum(1 for prop in layout["props"] if prop.get("harvestable"))
    caption = (f'{layout["id"]} — {span:.0f} m across · {len(layout["props"])} authored props · '
               f'{harvestable} harvestable nodes · {len(layout["markers"])} markers')
    out.append(f'<text x="{MARGIN}" y="{size + MARGIN + 28}" font-size="15" fill="#f4efe6">'
               f'{caption}</text>')

    legend = [("spawn", "#ffffff"), ("landmark", "#ffe082"), ("Wellspring", "#ce93d8"),
              ("extraction", "#80cbc4"), ("crawler nest", "#ff5c8a"),
              ("harvestable", "#ffd640"), ("tree", "#388e3c"), ("rock", "#787c82"),
              ("blight growth", "#9c27b0")]
    x = MARGIN
    for label, colour in legend:
        out.append(f'<circle cx="{x + 5}" cy="{size + MARGIN + 54}" r="4.5" fill="{colour}"/>')
        out.append(f'<text x="{x + 14}" y="{size + MARGIN + 58}" font-size="12" '
                   f'fill="#b9b3a8">{label}</text>')
        x += 24 + len(label) * 7
    out.append("</svg>")

    destination = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "hollowmere_plan.svg"
    destination.write_text("\n".join(out), encoding="utf-8")
    raster = destination.with_suffix(".png")
    raster.write_bytes(png(size, size, pixels))
    print(f"wrote {destination} ({destination.stat().st_size / 1024:.0f} KB) and "
          f"{raster.name} ({raster.stat().st_size / 1024:.0f} KB), "
          f"{size}x{size} px at {PIXELS_PER_METRE} px/m")


if __name__ == "__main__":
    main()
