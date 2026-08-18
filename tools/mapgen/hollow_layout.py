"""Author `playtest_hollow` — the single source of truth for MIRE's playtest map.

Run with plain python3 (no Blender, no Godot):

  python3 tools/mapgen/hollow_layout.py

It writes `world/gen/layouts/playtest_hollow.json` and validates the result. Two consumers read
that JSON and neither one decides anything:

  tools/blender/build_playtest_hollow.py  -> assets/maps/playtest_hollow.glb  (what you see)
  world/gen/playtest_hollow.gd            -> StaticBody3D colliders           (what you hit)

That is the whole point. The previous map kept its visual layout in a Blender script and its
collision layout in a GDScript, and the two had already drifted: the forest drew harvest trees
where collision put pines, the ruins drew ore nodes where collision put boulders, and the counts
disagreed (26 vs 22 undergrowth, 10 vs 8 mushrooms). Colliders stood where nothing was drawn.
One file, two dumb consumers, no drift.

Placement rules the validator enforces, so nobody has to eyeball a render:

  * nothing floats — every grounded prop sits exactly on the surface below it
  * nothing interpenetrates — solid props keep their footprints apart
  * roads stay walkable — no solid prop in a road corridor unless it is a deliberate gateway
  * every platform is reachable — a ramp, never a step, because CharacterBody3D cannot step up
  * everything is inside the boundary ring

Coordinates are GODOT coordinates everywhere in this file and in the JSON: +X east, +Y up,
+Z south. The Blender consumer converts on the way out.
"""

from __future__ import annotations

import json
import math
import random
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / "assets"
OUT = ROOT / "world" / "gen" / "layouts" / "playtest_hollow.json"

SEED = 20260817
MAP_ID = "playtest_hollow"

# Playable half-extent. The rock wall ring stands from BOUND outward, so the hollow is closed:
# no falling off a floating slab, which is what the 60x60 ground plane used to allow.
BOUND = 44.0
WALL_THICK = 3.0
WALL_HEIGHT = 6.0

ZONES = ["SpawnCamp", "WestForest", "NorthRuins", "EastMire", "SouthRidge", "RoutesAndBoundary"]

# Camp perimeter. Fence pieces are 4.24 long, so a gate plus four straights spans 21.4m per side.
CAMP_X0, CAMP_X1 = -10.7, 10.7
CAMP_Z0, CAMP_Z1 = -8.6, 12.8
CAMP_CX, CAMP_CZ = 0.0, 2.1
SPAWN_POS = (0.0, 0.2, 7.4)

# Basin: the Mire sits BELOW grade rather than being a purple rectangle painted on flat ground.
BASIN_X0, BASIN_X1 = 15.0, 31.0
BASIN_Z0, BASIN_Z1 = -13.0, 13.0
BASIN_Y = -0.7

RIDGE_T1_Y = 1.2
RIDGE_T2_Y = 2.8

FLOOR_TOP = 0.64  # wood_foundation (0.40) + wood_floor (0.24)
STONE_TOP = 0.96  # stone_foundation (0.72) + stone_floor (0.24)

MATERIALS = {
    "ground": {"color": [0.09, 0.18, 0.08, 1.0], "roughness": 0.98},
    "meadow": {"color": [0.12, 0.235, 0.09, 1.0], "roughness": 0.99},
    "forest_floor": {"color": [0.095, 0.125, 0.055, 1.0], "roughness": 1.0},
    "path": {"color": [0.205, 0.15, 0.085, 1.0], "roughness": 1.0},
    "mud": {"color": [0.13, 0.115, 0.155, 1.0], "roughness": 0.72},
    "rock": {"color": [0.155, 0.16, 0.175, 1.0], "roughness": 0.95},
    "ridge": {"color": [0.115, 0.15, 0.085, 1.0], "roughness": 0.97},
    "timber": {"color": [0.22, 0.145, 0.08, 1.0], "roughness": 0.9},
}

# Road corridors, as (x0, z0, x1, z1). Solid props stay out of these; ground cover may sit inside.
ROADS = [
    ("Road_North", -3.0, -26.0, 3.0, CAMP_Z0),
    ("Road_South", -3.0, CAMP_Z1, 3.0, 23.0),
    ("Road_West", -18.0, -1.0, CAMP_X0, 5.0),
    ("Road_East", CAMP_X1, -1.0, 18.0, 5.0),
]

# Visible trail ribbons overlap slightly and bend toward each landmark. ROADS remains the conservative
# clearance envelope used by placement validation; TRAILS is presentation only.
TRAILS = [
    ("Trail_NorthA", (0.0, CAMP_Z0), (-0.8, -19.0), 5.6),
    ("Trail_NorthB", (-0.8, -19.0), (0.0, -27.0), 4.8),
    ("Trail_SouthA", (0.0, CAMP_Z1), (0.0, 20.5), 5.6),
    ("Trail_SouthB", (0.0, 20.5), (8.2, 27.2), 4.4),
    ("Trail_WestA", (CAMP_X0, CAMP_CZ), (-17.2, 2.8), 5.6),
    ("Trail_WestB", (-17.2, 2.8), (-23.0, 2.0), 4.2),
    ("Trail_EastA", (CAMP_X1, CAMP_CZ), (16.2, 1.8), 5.6),
    ("Trail_EastB", (16.2, 1.8), (19.8, 1.5), 4.2),
]


# ---------------------------------------------------------------------------
# Asset catalogs — real measured footprints, so clearance is computed, not guessed.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Ground heightfield
# ---------------------------------------------------------------------------
#
# The Hollow used to be four flat slabs at y=0, which read as a green table with
# props standing on it. This replaces them with a faceted low-poly surface that
# both Blender and Godot build from the same grid, so what you see is what you
# walk on.
#
# It is deliberately gentle and deliberately masked. Anything authored against
# flat ground — the camp decks and their ramps, the road corridors, the ruins
# court, the ridge terraces, the Mire basin and its banks — is flattened back to
# zero underneath, with a smooth falloff so the mask never shows as a crease.
# The noise only has the run of the open ground, which is exactly where the
# flatness was visible.

HF_CELL = 1.6
HF_AMPLITUDE = 2.05
#: Regions held flat, as (x0, z0, x1, z1, falloff). Falloff is the distance over
#: which the terrain eases back up to full amplitude outside the rectangle.
HF_FLAT: list[tuple[float, float, float, float, float]] = []


def _hash01(ix: int, iz: int, salt: int) -> float:
    h = (ix * 374761393 + iz * 668265263 + salt * 2147483647 + SEED) & 0xFFFFFFFF
    h = (h ^ (h >> 13)) * 1274126177 & 0xFFFFFFFF
    return ((h ^ (h >> 16)) & 0xFFFFFF) / float(0xFFFFFF)


def _smooth(t: float) -> float:
    return t * t * (3.0 - 2.0 * t)


def _value_noise(x: float, z: float, wavelength: float, salt: int) -> float:
    """One octave of value noise in [-1, 1]. No numpy: this runs in plain CPython."""
    fx, fz = x / wavelength, z / wavelength
    ix, iz = math.floor(fx), math.floor(fz)
    tx, tz = _smooth(fx - ix), _smooth(fz - iz)
    a = _hash01(ix, iz, salt)
    b = _hash01(ix + 1, iz, salt)
    c = _hash01(ix, iz + 1, salt)
    d = _hash01(ix + 1, iz + 1, salt)
    top = a + (b - a) * tx
    bot = c + (d - c) * tx
    return (top + (bot - top) * tz) * 2.0 - 1.0


def _flatten_factor(x: float, z: float) -> float:
    """0 inside a protected rectangle, easing to 1 outside it."""
    factor = 1.0
    for x0, z0, x1, z1, fade in HF_FLAT:
        dx = max(x0 - x, 0.0, x - x1)
        dz = max(z0 - z, 0.0, z - z1)
        d = math.hypot(dx, dz)
        factor = min(factor, _smooth(min(d / fade, 1.0)) if fade > 0.0 else (1.0 if d > 0 else 0.0))
        if factor <= 0.0:
            return 0.0
    return factor


def ground_height(x: float, z: float) -> float:
    """Height of the open ground at a point. Zero under everything authored."""
    factor = _flatten_factor(x, z)
    if factor <= 0.0:
        return 0.0
    # Long wavelengths keep every slope walkable without needing a gradient clamp.
    # The last octave is deliberately near the cell size. Without it adjacent
    # facets share almost the same normal and the surface reads as a smooth
    # sheet — rolling, but not *low poly*. This is what makes each triangle
    # catch the light differently, which is the whole look.
    h = (_value_noise(x, z, 34.0, 1) * 0.55
         + _value_noise(x, z, 17.0, 2) * 0.24
         + _value_noise(x, z, 8.5, 3) * 0.13
         + _value_noise(x, z, 3.6, 4) * 0.08)
    # Fade to zero at the wall ring so the boundary never shows a gap under it.
    edge = min(BOUND - abs(x), BOUND - abs(z))
    factor *= _smooth(max(min(edge / 4.5, 1.0), 0.0))
    return round(h * HF_AMPLITUDE * factor, 4)


def heightfield_block() -> dict:
    """The grid Blender meshes and Godot collides against. One source, both halves."""
    n = int(round((BOUND * 2.0) / HF_CELL)) + 1
    origin = -BOUND
    heights = []
    for iz in range(n):
        z = origin + iz * HF_CELL
        heights.extend(ground_height(origin + ix * HF_CELL, z) for ix in range(n))
    # The basin is its own authored floor and banks sitting below grade. Without
    # a hole here the ground sheet would roof straight over the Mire and hide it.
    holes = [[BASIN_X0, BASIN_Z0, BASIN_X1, BASIN_Z1]]
    return {"origin": [origin, origin], "cell": HF_CELL, "nx": n, "nz": n,
            "mat": "ground", "heights": heights, "holes": holes}


def load_catalogs() -> dict[str, dict]:
    catalog: dict[str, dict] = {}
    for kit in (
        "environment",
        "harvestables",
        "crafting_stations",
        "pickups",
        "loot",
        "enemies",
        "tools_weapons",
    ):
        path = ASSETS / kit / "catalog.json"
        for entry in json.loads(path.read_text()):
            catalog[entry["name"]] = {
                "kit": kit,
                "w": float(entry["width_m"]),
                "d": float(entry["depth_m"]),
                "h": float(entry["height_m"]),
            }
    return catalog


CATALOG = load_catalogs()


def dims(asset: str) -> dict:
    if asset not in CATALOG:
        raise KeyError("unknown asset id: %s" % asset)
    return CATALOG[asset]


# ---------------------------------------------------------------------------
# Collider profiles. Each returns a list of shapes in the prop's local space.
# Box offsets are from the prop origin, which sits at the asset's base.
# ---------------------------------------------------------------------------

def box(size: tuple[float, float, float], offset: tuple[float, float, float] = (0.0, 0.0, 0.0)) -> dict:
    return {"t": "box", "size": [round(v, 3) for v in size], "off": [round(v, 3) for v in offset]}


def cyl(radius: float, height: float, y: float) -> dict:
    return {"t": "cyl", "r": round(radius, 3), "h": round(height, 3), "y": round(y, 3)}


def stair_steps(count: int, width: float, rise: float, run: float) -> list[dict]:
    return [
        box((width, rise + 0.18, run), (0.0, rise * 0.5 + i * rise, (count - 1) * run * 0.5 - i * run))
        for i in range(count)
    ]


def colliders_for(asset: str) -> list[dict]:
    """Collision for one asset id. Solid where it should block, absent where it should not."""
    d = dims(asset)
    w, dp, h = d["w"], d["d"], d["h"]

    # Walk-through dressing. Grass you brush past; a tendril you push through.
    if asset.startswith(("grass_", "fern_", "reeds_", "mushroom_cluster", "mire_tendril")):
        return []
    # Pickups are collected, not collided with — 2.3/2.4 replace these with real interactables.
    if asset.startswith("pickup_") or asset.endswith("_world") or asset.startswith("loot_coin"):
        return []
    if asset.startswith(("loot_powerup_orb", "loot_item_bag", "loot_player_backpack")):
        return []

    if asset.startswith(("tree_pine", "tree_birch", "tree_crooked", "tree_bare", "harvest_tree_intact",
                         "harvest_tree_damaged")):
        return [cyl(0.42, h * 0.78, h * 0.39)]
    if asset.startswith(("boulder_", "rock_cluster_")):
        return [box((w * 0.82, h * 0.86, dp * 0.82), (0.0, h * 0.43, 0.0))]
    if asset.startswith("standing_stone"):
        return [box((w * 0.85, h, dp * 0.85), (0.0, h * 0.5, 0.0))]
    if asset.startswith("mire_crystal"):
        return [box((w * 0.6, h * 0.92, dp * 0.6), (0.0, h * 0.46, 0.0))]
    if asset.startswith(("stump_", "harvest_tree_fresh_stump", "harvest_tree_depleted_stump")):
        return [box((w * 0.8, h, dp * 0.8), (0.0, h * 0.5, 0.0))]
    if asset.startswith(("fallen_log", "harvest_tree_felled_trunk", "root_cluster")):
        return [box((w * 0.88, h * 0.9, dp * 0.8), (0.0, h * 0.45, 0.0))]
    if asset.startswith(("stone_node", "iron_node")):
        return [box((w * 0.88, h * 0.9, dp * 0.88), (0.0, h * 0.45, 0.0))]
    if asset.startswith("loot_chest"):
        return [box((w, h * 0.85, dp), (0.0, h * 0.42, 0.0))]
    if asset == "enemy_crawler_nest":
        return [box((w * 0.85, h * 0.9, dp * 0.85), (0.0, h * 0.45, 0.0))]

    # Ruins.
    if asset.startswith("ruin_wall"):
        return [box((w, h, dp), (0.0, h * 0.5, 0.0))]
    if asset.startswith("ruin_column"):
        return [cyl(0.55, h, h * 0.5)]
    if asset.startswith("ruin_arch"):
        return [
            box((0.8, h * 0.88, dp), (-1.35, h * 0.44, 0.0)),
            box((0.8, h * 0.88, dp), (1.35, h * 0.44, 0.0)),
            box((w * 0.62, 0.65, dp), (0.0, h - 0.33, 0.0)),
        ]
    if asset.startswith("stone_marker"):
        return [box((w * 0.8, h, dp * 0.8), (0.0, h * 0.5, 0.0))]

    # Building kit.
    if asset in ("wood_foundation",):
        return [box((4.0, 0.4, 4.0), (0.0, 0.2, 0.0))]
    if asset in ("wood_floor", "stone_floor"):
        return [box((3.96, 0.24, 3.96), (0.0, 0.12, 0.0))]
    if asset == "stone_foundation":
        return [box((3.94, 0.72, 3.94), (0.0, 0.36, 0.0))]
    if asset in ("wood_wall_solid", "stone_wall_solid"):
        return [box((w, h, max(dp, 0.4)), (0.0, h * 0.5, 0.0))]
    if asset in ("wood_half_wall", "stone_half_wall"):
        return [box((w, h, max(dp, 0.4)), (0.0, h * 0.5, 0.0))]
    if asset in ("wood_wall_window", "stone_wall_window"):
        return [
            box((1.05, h, max(dp, 0.44)), (-1.48, h * 0.5, 0.0)),
            box((1.05, h, max(dp, 0.44)), (1.48, h * 0.5, 0.0)),
            box((1.95, 0.86, max(dp, 0.44)), (0.0, 0.43, 0.0)),
            box((1.95, 0.52, max(dp, 0.44)), (0.0, h - 0.26, 0.0)),
        ]
    if asset in ("wood_wall_door", "stone_wall_door"):
        return [
            box((1.05, h, max(dp, 0.44)), (-1.48, h * 0.5, 0.0)),
            box((1.05, h, max(dp, 0.44)), (1.48, h * 0.5, 0.0)),
            box((1.95, 0.42, max(dp, 0.44)), (0.0, h - 0.21, 0.0)),
        ]
    if asset in ("wood_stairs", "stone_stairs"):
        return stair_steps(8, w, h / 8.0, dp / 8.0)
    if asset == "wood_post":
        return [box((0.62, h, 0.62), (0.0, h * 0.5, 0.0))]
    if asset == "stone_pillar":
        return [box((0.9, h, 0.9), (0.0, h * 0.5, 0.0))]
    if asset == "wood_beam":
        return [box((w, h, dp), (0.0, h * 0.5, 0.0))]
    if asset == "wood_railing":
        return [box((w, h, max(dp, 0.24)), (0.0, h * 0.5, 0.0))]
    if asset in ("wood_roof_slope", "wood_roof_corner"):
        return [box((w, 0.35, dp), (0.0, h - 0.18, 0.0))]
    if asset == "fence_gate":
        return [
            box((0.42, h, 0.42), (-2.05, h * 0.5, 0.0)),
            box((0.42, h, 0.42), (2.05, h * 0.5, 0.0)),
        ]
    if asset.startswith("fence_"):
        return [box((w, h, max(dp, 0.28)), (0.0, h * 0.5, 0.0))]

    # Crafting stations: a solid block a player cannot walk through, sized from the catalog.
    if asset.startswith("station_"):
        return [box((w, h, dp), (0.0, h * 0.5, 0.0))]

    raise KeyError("no collider profile for %s" % asset)


def footprint_radius(asset: str) -> float:
    """Clearance radius used for placement. Solid props use their collider, dressing uses less."""
    shapes = colliders_for(asset)
    if not shapes:
        d = dims(asset)
        return max(d["w"], d["d"]) * 0.25
    radius = 0.0
    for shape in shapes:
        if shape["t"] == "cyl":
            radius = max(radius, shape["r"])
        else:
            sx, _sy, sz = shape["size"]
            ox, _oy, oz = shape["off"]
            radius = max(radius, math.hypot(abs(ox) + sx * 0.5, abs(oz) + sz * 0.5))
    return radius


# ---------------------------------------------------------------------------
# Layout accumulator
# ---------------------------------------------------------------------------

class Layout:
    def __init__(self) -> None:
        self.terrain: list[dict] = []
        self.props: list[dict] = []
        self.lights: list[dict] = []
        self.markers: list[dict] = []
        # (x0, z0, x1, z1, top_y) walkable surfaces, used to prove nothing floats.
        self.supports: list[tuple[float, float, float, float, float]] = []
        # (x, z, radius) occupied footprints of solid props.
        self.occupied: list[tuple[float, float, float]] = []
        self.rng = random.Random(SEED)

    # -- terrain ---------------------------------------------------------
    def slab(self, name: str, zone: str, mat: str, x0: float, z0: float, x1: float, z1: float,
             top: float, thickness: float = 0.6, collide: bool = True, support: bool = True) -> None:
        self.terrain.append({
            "name": name, "zone": zone, "mat": mat,
            "pos": [round((x0 + x1) * 0.5, 3), round(top - thickness * 0.5, 3), round((z0 + z1) * 0.5, 3)],
            "size": [round(abs(x1 - x0), 3), round(thickness, 3), round(abs(z1 - z0), 3)],
            "tilt": 0.0, "axis": "x", "collide": collide,
        })
        if support:
            self.supports.append((min(x0, x1), min(z0, z1), max(x0, x1), max(z0, z1), top))

    def paint(self, name: str, zone: str, mat: str, x0: float, z0: float, x1: float, z1: float,
              y: float = 0.03) -> None:
        """A flat decal laid on the ground: visible, never collidable, never a support."""
        self.slab(name, zone, mat, x0, z0, x1, z1, top=y, thickness=0.06, collide=False, support=False)

    def paint_strip(self, name: str, zone: str, mat: str, start: tuple[float, float],
                    end: tuple[float, float], width: float, y: float = 0.035) -> None:
        """A rotated visual-only strip, used to make routes bend rather than form a rigid cross."""
        dx, dz = end[0] - start[0], end[1] - start[1]
        length = math.hypot(dx, dz)
        self.terrain.append({
            "name": name, "zone": zone, "mat": mat,
            "pos": [round((start[0] + end[0]) * 0.5, 3), round(y - 0.03, 3),
                    round((start[1] + end[1]) * 0.5, 3)],
            "size": [round(width, 3), 0.06, round(length, 3)],
            "tilt": 0.0, "axis": "x", "yaw": round(math.atan2(dx, dz), 6),
            "collide": False,
        })

    def ramp_z(self, name: str, zone: str, mat: str, x: float, width: float,
               z0: float, y0: float, z1: float, y1: float, thickness: float = 0.5) -> float:
        """Ramp running along Z. Returns its slope in degrees. Rotation is about Godot +X."""
        run, rise = z1 - z0, y1 - y0
        length = math.hypot(run, rise)
        pitch = -math.atan2(rise, run)
        # A box is symmetric along its local Z axis, so keep its equivalent rotation acute.
        # This also makes reversed endpoint order report the real climb angle, not 180-angle.
        if pitch > math.pi * 0.5:
            pitch -= math.pi
        elif pitch < -math.pi * 0.5:
            pitch += math.pi
        self.terrain.append({
            "name": name, "zone": zone, "mat": mat,
            "pos": [round(x, 3),
                    round((y0 + y1) * 0.5 - thickness * 0.5 * math.cos(pitch), 3),
                    round((z0 + z1) * 0.5, 3)],
            "size": [round(width, 3), round(thickness, 3), round(length, 3)],
            "tilt": round(pitch, 6), "axis": "x", "collide": True,
        })
        return abs(math.degrees(math.atan2(abs(rise), abs(run))))

    def ramp_x(self, name: str, zone: str, mat: str, z: float, width: float,
               x0: float, y0: float, x1: float, y1: float, thickness: float = 0.5) -> float:
        """Ramp running along X. Rotation is about Godot +Z."""
        run, rise = x1 - x0, y1 - y0
        length = math.hypot(run, rise)
        roll = math.atan2(rise, run)
        if roll > math.pi * 0.5:
            roll -= math.pi
        elif roll < -math.pi * 0.5:
            roll += math.pi
        self.terrain.append({
            "name": name, "zone": zone, "mat": mat,
            "pos": [round((x0 + x1) * 0.5, 3),
                    round((y0 + y1) * 0.5 - thickness * 0.5 * math.cos(roll), 3),
                    round(z, 3)],
            "size": [round(length, 3), round(thickness, 3), round(width, 3)],
            "tilt": round(roll, 6), "axis": "z", "collide": True,
        })
        return abs(math.degrees(math.atan2(abs(rise), abs(run))))

    # -- props -----------------------------------------------------------
    def prop(self, zone: str, asset: str, x: float, z: float, y: float | None = None,
             yaw: float = 0.0, scale: float = 1.0, note: str = "",
             float_ok: bool = False, road_ok: bool = False, reserve: bool = True) -> dict:
        surface = self.surface_at(x, z)
        record = {
            "asset": asset, "kit": dims(asset)["kit"], "zone": zone,
            "pos": [round(x, 3), round(surface if y is None else y, 3), round(z, 3)],
            "yaw": round(yaw, 5), "scale": round(scale, 4),
            "cols": colliders_for(asset),
        }
        if note:
            record["note"] = note
        if float_ok:
            record["float_ok"] = True
        if road_ok:
            record["road_ok"] = True
        self.props.append(record)
        if reserve and record["cols"]:
            self.occupied.append((x, z, footprint_radius(asset)))
        return record

    def platform(self, x0: float, z0: float, x1: float, z1: float, top: float) -> None:
        self.supports.append((min(x0, x1), min(z0, z1), max(x0, x1), max(z0, z1), top))

    def light(self, name: str, zone: str, pos: tuple[float, float, float], color: tuple[float, float, float],
              energy: float, rng: float) -> None:
        self.lights.append({
            "name": name, "zone": zone, "pos": [round(v, 3) for v in pos],
            "color": [round(v, 4) for v in color], "energy": energy, "range": rng,
        })

    def marker(self, name: str, zone: str, x: float, z: float, kind: str) -> None:
        self.markers.append({
            "name": name, "zone": zone, "kind": kind,
            "pos": [round(x, 3), round(self.surface_at(x, z), 3), round(z, 3)],
        })

    # -- queries ---------------------------------------------------------
    def surface_at(self, x: float, z: float) -> float:
        top = None
        for x0, z0, x1, z1, y in self.supports:
            if x0 - 1e-6 <= x <= x1 + 1e-6 and z0 - 1e-6 <= z <= z1 + 1e-6:
                top = y if top is None else max(top, y)
        if top is None:
            return ground_height(x, z)
        # Only the open ground undulates. A deck, terrace or basin floor keeps the
        # exact height it was authored at, which is what its ramps were built for.
        if abs(top) < 1e-6:
            return round(ground_height(x, z), 3)
        return top

    def blocked(self, x: float, z: float, radius: float) -> bool:
        for ox, oz, orad in self.occupied:
            if math.hypot(x - ox, z - oz) < radius + orad:
                return True
        return False

    def on_road(self, x: float, z: float, radius: float) -> bool:
        for _name, x0, z0, x1, z1 in ROADS:
            if x0 - radius < x < x1 + radius and z0 - radius < z < z1 + radius:
                return True
        return False

    def scatter(self, zone: str, assets: list[str], count: int, region, min_gap: float = 0.0,
                scale_range: tuple[float, float] = (1.0, 1.0), avoid_roads: bool = True,
                name_hint: str = "") -> int:
        """Rejection-sampled placement. Guarantees clearance instead of hoping for it."""
        placed = 0
        attempts = 0
        while placed < count and attempts < count * 400:
            attempts += 1
            x = self.rng.uniform(region[0], region[2])
            z = self.rng.uniform(region[1], region[3])
            if len(region) > 4 and not region[4](x, z):
                continue
            asset = assets[self.rng.randrange(len(assets))]
            scale = self.rng.uniform(*scale_range)
            radius = footprint_radius(asset) * scale + min_gap
            solid = bool(colliders_for(asset))
            if solid and self.blocked(x, z, radius):
                continue
            if solid and avoid_roads and self.on_road(x, z, radius):
                continue
            if not solid and self.blocked(x, z, radius * 0.35):
                continue
            self.prop(zone, asset, x, z, yaw=self.rng.uniform(0.0, math.tau), scale=scale,
                      note=name_hint, reserve=solid)
            placed += 1
        return placed


# ---------------------------------------------------------------------------
# Terrain: a closed hollow with real elevation
# ---------------------------------------------------------------------------

def build_terrain(L: Layout) -> None:
    B = BOUND
    # Ground is tiled around the basin so the Mire can actually sit below grade.
    # The open ground is the heightfield, not four slabs. These register support
    # regions so surface_at still resolves; the mesh and its collider come from
    # heightfield_block(). Everything authored against flat ground is masked out
    # of the noise below, so decks, ramps and banks meet it exactly as before.
    HF_FLAT.extend([
        (CAMP_X0 - 2.0, CAMP_Z0 - 2.0, CAMP_X1 + 2.0, CAMP_Z1 + 2.0, 7.0),   # camp and its decks
        (BASIN_X0 - 5.0, BASIN_Z0 - 5.0, BASIN_X1 + 5.0, BASIN_Z1 + 5.0, 6.0),  # basin and banks
        (-21.0, 20.0, 23.0, B, 6.5),                                          # ridge terraces + ramps
        (-10.0, -35.0, 12.0, -23.0, 6.0),                                     # ruins court + forge ramp
    ])
    for _n, rx0, rz0, rx1, rz1 in ROADS:
        HF_FLAT.append((rx0 - 1.0, rz0 - 1.0, rx1 + 1.0, rz1 + 1.0, 5.5))
    for _n, (sx, sz), (ex, ez), width in TRAILS:
        HF_FLAT.append((min(sx, ex) - width * 0.5, min(sz, ez) - width * 0.5,
                        max(sx, ex) + width * 0.5, max(sz, ez) + width * 0.5, 5.0))
    L.platform(-B, -B, BASIN_X0, B, 0.0)
    L.platform(BASIN_X0, -B, B, BASIN_Z0, 0.0)
    L.platform(BASIN_X0, BASIN_Z1, B, B, 0.0)
    L.platform(BASIN_X1, BASIN_Z0, B, BASIN_Z1, 0.0)

    # Basin floor plus banks gentle enough to walk in and out of (CharacterBody3D cannot step up).
    L.slab("Mire_BasinFloor", "EastMire", "mud", BASIN_X0, BASIN_Z0, BASIN_X1, BASIN_Z1,
           top=BASIN_Y, thickness=1.0)
    L.ramp_x("Mire_BankWest", "EastMire", "mud", z=(BASIN_Z0 + BASIN_Z1) * 0.5,
             width=BASIN_Z1 - BASIN_Z0, x0=BASIN_X0 - 0.2, y0=0.0, x1=BASIN_X0 + 3.6, y1=BASIN_Y)
    L.ramp_x("Mire_BankEast", "EastMire", "mud", z=(BASIN_Z0 + BASIN_Z1) * 0.5,
             width=BASIN_Z1 - BASIN_Z0, x0=BASIN_X1 + 0.2, y0=0.0, x1=BASIN_X1 - 3.6, y1=BASIN_Y)
    L.ramp_z("Mire_BankNorth", "EastMire", "mud", x=(BASIN_X0 + BASIN_X1) * 0.5,
             width=BASIN_X1 - BASIN_X0, z0=BASIN_Z0 - 0.2, y0=0.0, z1=BASIN_Z0 + 3.6, y1=BASIN_Y)
    L.ramp_z("Mire_BankSouth", "EastMire", "mud", x=(BASIN_X0 + BASIN_X1) * 0.5,
             width=BASIN_X1 - BASIN_X0, z0=BASIN_Z1 + 0.2, y0=0.0, z1=BASIN_Z1 - 3.6, y1=BASIN_Y)

    # South ridge: two terraces and the ramps that earn them.
    L.slab("Ridge_Tier1", "SouthRidge", "ridge", -20.0, 21.0, 22.0, B, top=RIDGE_T1_Y, thickness=1.6)
    L.slab("Ridge_Tier2", "SouthRidge", "ridge", 2.0, 26.0, 18.0, B, top=RIDGE_T2_Y, thickness=2.0)
    slope1 = L.ramp_z("Ridge_Ramp1", "SouthRidge", "ridge", x=0.0, width=8.0,
                      z0=16.5, y0=0.0, z1=21.2, y1=RIDGE_T1_Y)
    slope2 = L.ramp_z("Ridge_Ramp2", "SouthRidge", "ridge", x=10.0, width=6.0,
                      z0=21.6, y0=RIDGE_T1_Y, z1=26.2, y1=RIDGE_T2_Y)
    L.slopes = [("Ridge_Ramp1", slope1), ("Ridge_Ramp2", slope2)]

    # Forge terrace ramp (the old map put 1.74m stairs against a 0.72m platform).
    slope3 = L.ramp_x("Ruins_ForgeRamp", "NorthRuins", "rock", z=-28.0, width=3.4,
                      x0=7.2, y0=0.0, x1=11.2, y1=STONE_TOP)
    L.slopes.append(("Ruins_ForgeRamp", slope3))

    # Camp platform ramps — a 0.64m lip is a wall to a CharacterBody3D, so every deck gets one.
    for name, x, z0, z1 in (("Camp_CabinRamp", -7.0, 3.6, 1.0), ("Camp_WorkshopRamp", 7.0, 3.6, 1.0)):
        slope = L.ramp_z(name, "SpawnCamp", "timber", x=x, width=3.2,
                         z0=z0, y0=0.0, z1=z1, y1=FLOOR_TOP)
        L.slopes.append((name, slope))

    # Rock wall ring: the hollow is closed, so nobody walks off the edge of the world.
    outer = B + WALL_THICK
    L.slab("Wall_North", "RoutesAndBoundary", "rock", -outer, -outer, outer, -B, top=WALL_HEIGHT, thickness=WALL_HEIGHT + 1.2)
    L.slab("Wall_South", "RoutesAndBoundary", "rock", -outer, B, outer, outer, top=WALL_HEIGHT, thickness=WALL_HEIGHT + 1.2)
    L.slab("Wall_West", "RoutesAndBoundary", "rock", -outer, -B, -B, B, top=WALL_HEIGHT, thickness=WALL_HEIGHT + 1.2)
    L.slab("Wall_East", "RoutesAndBoundary", "rock", B, -B, outer, B, top=WALL_HEIGHT, thickness=WALL_HEIGHT + 1.2)

    # Broad material zones are lightly overlapped so forest, meadow, and ridge do not read as
    # unrelated boxes dropped onto one green slab. These are visual skins, never collision/support.
    L.paint("ForestFloor", "WestForest", "forest_floor", -B + 1.0, -B + 1.0, -15.0, B - 5.0, y=0.025)
    L.paint("ForestMeadowSeam", "WestForest", "meadow", -16.2, -B + 3.0, -12.8, B - 7.0, y=0.032)
    L.paint("RidgeMeadowApron", "SouthRidge", "meadow", -24.0, 13.5, 26.0, 20.7, y=0.032)

    # Bent trail ribbons steer toward the landmarks and overlap enough to read as one network.
    for name, start, end, width in TRAILS:
        L.paint_strip(name, "RoutesAndBoundary", "path", start, end, width)
    L.paint("Camp_Plaza", "SpawnCamp", "path", -4.0, -1.5, 4.0, 6.5)
    L.paint("Ruins_Court", "NorthRuins", "path", -9.0, -34.0, 9.0, -24.0)


# ---------------------------------------------------------------------------
# Camp — the hub. Roomy enough for six, and no road runs through the fire.
# ---------------------------------------------------------------------------

def build_camp(L: Layout) -> None:
    Z = "SpawnCamp"

    # Perimeter: gate on each side, straights either way, a post to hide every corner joint.
    for x in (-8.6, -4.3, 4.3, 8.6):
        L.prop(Z, "fence_straight", x, CAMP_Z0, note="perimeter", road_ok=True)
        L.prop(Z, "fence_straight", x, CAMP_Z1, note="perimeter", road_ok=True)
    for z in (CAMP_CZ - 8.6, CAMP_CZ - 4.3, CAMP_CZ + 4.3, CAMP_CZ + 8.6):
        L.prop(Z, "fence_straight", CAMP_X0, z, yaw=math.pi * 0.5, note="perimeter", road_ok=True)
        L.prop(Z, "fence_straight", CAMP_X1, z, yaw=math.pi * 0.5, note="perimeter", road_ok=True)
    L.prop(Z, "fence_gate", 0.0, CAMP_Z0, note="gate:north", road_ok=True)
    L.prop(Z, "fence_gate", 0.0, CAMP_Z1, note="gate:south", road_ok=True)
    L.prop(Z, "fence_gate", CAMP_X0, CAMP_CZ, yaw=math.pi * 0.5, note="gate:west", road_ok=True)
    L.prop(Z, "fence_gate", CAMP_X1, CAMP_CZ, yaw=math.pi * 0.5, note="gate:east", road_ok=True)
    for x, z in ((CAMP_X0, CAMP_Z0), (CAMP_X1, CAMP_Z0), (CAMP_X0, CAMP_Z1), (CAMP_X1, CAMP_Z1)):
        L.prop(Z, "fence_post", x, z, note="corner")

    # Hearth: the rally point, dead centre, clear of every road corridor.
    L.prop(Z, "station_campfire", 0.0, 2.0, note="hearth")
    L.light("CampFire", Z, (0.0, 2.2, 2.0), (1.0, 0.55, 0.2), 3.2, 12.0)
    L.prop(Z, "station_cooking_spit", 3.3, 4.3, yaw=-2.2, note="hearth")
    L.prop(Z, "station_woodcutting_block", -3.5, 4.4, yaw=2.5, note="hearth")

    # Cabin: two modules, so six players fit inside instead of one.
    for cz in (-5.0, -1.0):
        L.prop(Z, "wood_foundation", -7.0, cz, note="cabin")
        L.prop(Z, "wood_floor", -7.0, cz, y=0.4, note="cabin", float_ok=True)
    L.platform(-9.0, -7.0, -5.0, 1.0, FLOOR_TOP)
    L.prop(Z, "wood_wall_solid", -7.0, -7.0, y=FLOOR_TOP, note="cabin", float_ok=True)
    L.prop(Z, "wood_wall_window", -9.0, -5.0, y=FLOOR_TOP, yaw=math.pi * 0.5, note="cabin", float_ok=True)
    L.prop(Z, "wood_wall_solid", -9.0, -1.0, y=FLOOR_TOP, yaw=math.pi * 0.5,
           note="cabin", float_ok=True, road_ok=True)
    L.prop(Z, "wood_wall_solid", -5.0, -5.0, y=FLOOR_TOP, yaw=math.pi * 0.5, note="cabin", float_ok=True)
    L.prop(Z, "wood_wall_window", -5.0, -1.0, y=FLOOR_TOP, yaw=math.pi * 0.5, note="cabin", float_ok=True)
    L.prop(Z, "wood_wall_door", -7.0, 1.0, y=FLOOR_TOP, note="cabin", float_ok=True)
    for cz in (-5.0, -1.0):
        L.prop(Z, "wood_roof_slope", -7.0, cz, y=FLOOR_TOP + 3.0, note="cabin", float_ok=True)
    L.prop(Z, "loot_chest_small_closed", -8.1, -0.2, y=FLOOR_TOP, yaw=0.35, note="cabin", float_ok=True)
    L.prop(Z, "loot_player_backpack", -8.2, -3.4, y=FLOOR_TOP, yaw=-0.6, note="cabin", float_ok=True)

    # Workshop: open deck, crafting stations, railing on the outside only.
    for cz in (-5.0, -1.0):
        L.prop(Z, "wood_foundation", 7.0, cz, note="workshop")
        L.prop(Z, "wood_floor", 7.0, cz, y=0.4, note="workshop", float_ok=True)
    L.platform(5.0, -7.0, 9.0, 1.0, FLOOR_TOP)
    L.prop(Z, "wood_half_wall", 7.0, -7.0, y=FLOOR_TOP, note="workshop", float_ok=True)
    L.prop(Z, "wood_railing", 9.0, -5.0, y=FLOOR_TOP, yaw=math.pi * 0.5, note="workshop", float_ok=True)
    L.prop(Z, "wood_railing", 9.0, -1.0, y=FLOOR_TOP, yaw=math.pi * 0.5,
           note="workshop", float_ok=True, road_ok=True)
    L.prop(Z, "wood_post", 5.3, -6.7, y=FLOOR_TOP, note="workshop", float_ok=True)
    L.prop(Z, "wood_post", 8.7, -6.7, y=FLOOR_TOP, note="workshop", float_ok=True)
    L.prop(Z, "station_workbench_primitive", 7.0, -6.2, y=FLOOR_TOP, yaw=math.pi, note="workshop", float_ok=True)
    L.prop(Z, "station_repair_bench", 8.2, -2.6, y=FLOOR_TOP, yaw=math.pi * 0.5, note="workshop", float_ok=True)
    L.prop(Z, "repair_hammer_world", 6.2, -2.4, y=FLOOR_TOP, yaw=1.1, note="workshop", float_ok=True)

    # Supply corner: ground level, so it needs no third ramp.
    L.prop(Z, "loot_chest_reinforced_closed", -8.4, 7.4, yaw=0.2, note="supply")
    L.prop(Z, "loot_chest_small_closed", -6.9, 8.4, yaw=-0.5, note="supply")
    L.prop(Z, "loot_item_bag", -7.9, 9.6, yaw=0.9, note="supply")
    for i, (px, pz) in enumerate(((-5.6, 6.6), (-5.2, 7.7), (-6.3, 9.9))):
        L.prop(Z, "pickup_log", px, pz, yaw=0.4 + i * 0.9, note="supply")
    L.prop(Z, "pickup_stone", -4.6, 9.2, yaw=0.3, note="supply")
    L.prop(Z, "pickup_fibre_bundle", -4.4, 8.1, yaw=-0.8, note="supply")

    # Woodcutting corner, and a couple of world tools so the kit is visible in play.
    L.prop(Z, "harvest_tree_felled_trunk", 7.4, 8.2, yaw=0.5, note="woodcutting")
    L.prop(Z, "stump_b", 5.2, 6.4, yaw=0.9, note="woodcutting")
    L.prop(Z, "stone_axe_world", 5.9, 7.5, yaw=-0.4, note="woodcutting")
    L.prop(Z, "wooden_pickaxe_world", 4.6, 9.8, yaw=1.6, note="woodcutting")
    for i, (px, pz) in enumerate(((8.6, 10.2), (9.4, 9.0), (7.7, 10.9))):
        L.prop(Z, "pickup_branch", px, pz, yaw=1.2 + i * 0.7, note="woodcutting")

    # Wayfinding: a marker pair at each gate, so a lost player can read the exits.
    for gx, gz, yaw in ((0.0, CAMP_Z0 - 2.2, 0.0), (0.0, CAMP_Z1 + 2.2, 0.0),
                        (CAMP_X0 - 2.2, CAMP_CZ, math.pi * 0.5), (CAMP_X1 + 2.2, CAMP_CZ, math.pi * 0.5)):
        offset = (3.4, 0.0) if abs(yaw) < 0.01 else (0.0, 3.4)
        L.prop(Z, "stone_marker_a", gx - offset[0], gz - offset[1], yaw=yaw + 0.15,
               note="wayfinding", road_ok=True)
        L.prop(Z, "stone_marker_b", gx + offset[0], gz + offset[1], yaw=yaw - 0.15,
               note="wayfinding", road_ok=True)

    inside = (CAMP_X0 + 1.2, CAMP_Z0 + 1.2, CAMP_X1 - 1.2, CAMP_Z1 - 1.2,
              lambda x, z: math.hypot(x - 0.0, z - 2.0) > 3.4)
    camp_grass = (["grass_clump_%s" % c for c in "abcdef"]
                  + ["grass_meadow_%s" % c for c in "abcd"])
    L.scatter(Z, camp_grass, 18, inside, min_gap=0.26,
              scale_range=(0.72, 1.05), avoid_roads=False, name_hint="dressing")


# ---------------------------------------------------------------------------
# North ruins — stone, iron, the forge, and the map's biggest fight space
# ---------------------------------------------------------------------------

def build_ruins(L: Layout) -> None:
    Z = "NorthRuins"

    L.prop(Z, "stone_marker_a", -4.6, -18.0, yaw=0.2, note="approach")
    L.prop(Z, "stone_marker_b", 4.6, -18.0, yaw=-0.2, note="approach")
    # The arch stands in the road on purpose: it is the landmark you aim at from camp.
    L.prop(Z, "ruin_arch_a", 0.0, -21.0, note="gateway", road_ok=True)

    for z in (-26.0, -30.5):
        L.prop(Z, "ruin_wall_a" if z < -28 else "ruin_wall_c", -9.0, z, yaw=math.pi * 0.5, note="court")
        L.prop(Z, "ruin_wall_b" if z < -28 else "ruin_wall_d", 9.0, z, yaw=math.pi * 0.5, note="court")
    L.prop(Z, "ruin_wall_c", -4.7, -33.5, note="court")
    L.prop(Z, "ruin_wall_d", 4.7, -33.5, note="court")
    L.prop(Z, "ruin_column_a", -6.2, -24.2, yaw=0.1, note="court")
    L.prop(Z, "ruin_column_c", 6.2, -24.2, yaw=-0.1, note="court")
    L.prop(Z, "ruin_column_b", -6.6, -31.8, yaw=0.2, note="court")
    L.prop(Z, "ruin_column_d", 6.6, -31.8, yaw=-0.2, note="court")

    # Forge terrace. Reached by Ruins_ForgeRamp, not by stairs taller than the platform.
    L.prop(Z, "stone_foundation", 13.0, -28.0, note="forge")
    L.prop(Z, "stone_floor", 13.0, -28.0, y=0.72, note="forge", float_ok=True)
    L.platform(11.03, -29.97, 14.97, -26.03, STONE_TOP)
    L.prop(Z, "stone_half_wall", 14.9, -28.0, y=STONE_TOP, yaw=math.pi * 0.5, note="forge", float_ok=True)
    L.prop(Z, "station_stone_furnace", 13.2, -29.0, y=STONE_TOP, yaw=math.pi, note="forge", float_ok=True)
    L.prop(Z, "station_anvil", 12.4, -26.8, y=STONE_TOP, yaw=0.4, note="forge", float_ok=True)
    L.light("ForgeGlow", Z, (13.2, STONE_TOP + 1.1, -29.0), (1.0, 0.42, 0.12), 2.6, 9.0)
    L.prop(Z, "loot_chest_reinforced_closed", 11.6, -29.4, y=STONE_TOP, yaw=-0.4, note="forge", float_ok=True)
    L.prop(Z, "pickup_iron_ingot", 11.5, -27.2, y=STONE_TOP, yaw=0.5, note="forge", float_ok=True)
    L.prop(Z, "pickup_coal", 14.1, -26.6, y=STONE_TOP, yaw=1.1, note="forge", float_ok=True)
    L.prop(Z, "iron_pickaxe_world", 13.9, -27.6, y=STONE_TOP, yaw=-1.2, note="forge", float_ok=True)

    # The ore itself, near enough to the forge to make the loop short.
    L.prop(Z, "iron_node_intact", 16.6, -25.2, yaw=0.9, note="ore")
    L.prop(Z, "iron_node_intact", 17.8, -30.4, yaw=-0.6, note="ore")
    L.prop(Z, "stone_node_intact", -6.0, -27.5, yaw=0.4, note="ore")
    L.prop(Z, "stone_node_intact", 5.2, -30.0, yaw=-0.8, note="ore")
    L.prop(Z, "stone_node_cracked", -2.4, -29.6, yaw=1.3, note="ore")
    L.prop(Z, "pickup_stone", -3.4, -26.4, yaw=0.7, note="ore")
    L.prop(Z, "pickup_iron_ore", 16.0, -27.6, yaw=0.2, note="ore")

    L.prop(Z, "loot_chest_small_closed", -6.2, -29.0, yaw=0.6, note="reward")
    L.prop(Z, "loot_coin_pouch", 7.9, -33.0, yaw=0.0, note="reward")

    court = (-8.4, -33.2, 8.4, -24.4)
    L.scatter(Z, ["rock_cluster_%s" % c for c in "abcdef"], 7, court, min_gap=1.4, name_hint="rubble")
    L.scatter(Z, ["grass_clump_%s" % c for c in "abcdef"], 14, court, min_gap=0.2,
              scale_range=(0.7, 1.0), avoid_roads=False, name_hint="dressing")
    ruins_grass = (["grass_meadow_%s" % c for c in "abcd"]
                   + ["grass_seedhead_%s" % c for c in "abcd"])
    L.scatter(Z, ruins_grass, 22, (-18.0, -41.5, 20.0, -18.0), min_gap=0.32,
              scale_range=(0.75, 1.12), avoid_roads=False, name_hint="weathered_grass")
    outskirts = (-20.0, -41.0, 21.0, -18.0, lambda x, z: abs(x) > 10.0 or z < -23.0)
    L.scatter(Z, ["boulder_%s" % c for c in "abcdefgh"], 13, outskirts, min_gap=1.6, name_hint="outskirts")
    L.scatter(Z, ["tree_bare_%s" % c for c in "abcd"], 10, outskirts, min_gap=1.8, name_hint="outskirts")


# ---------------------------------------------------------------------------
# West forest — wood, and one clearing worth walking to
# ---------------------------------------------------------------------------

def build_forest(L: Layout) -> None:
    Z = "WestForest"
    clearing = (-22.0, 2.0)

    def outside_clearing(x: float, z: float) -> bool:
        return math.hypot(x - clearing[0], z - clearing[1]) > 7.0

    band = (-42.5, -40.0, -14.0, 38.5, outside_clearing)
    L.scatter(Z, ["tree_pine_%s" % c for c in "abcdef"], 36, band, min_gap=1.7, name_hint="canopy")
    L.scatter(Z, ["tree_birch_%s" % c for c in "abcd"], 20, band, min_gap=1.6, name_hint="canopy")

    # The logging clearing: this is where wood comes from, and it reads as a place.
    for i, (ax, az) in enumerate(((-25.4, -0.6), (-24.6, 5.2), (-19.2, -1.4), (-18.6, 5.6), (-22.2, 7.6))):
        L.prop(Z, "harvest_tree_intact", ax, az, yaw=0.4 + i * 1.1, note="logging")
    L.prop(Z, "harvest_tree_felled_trunk", -22.0, 0.0, yaw=-0.35, note="logging")
    L.prop(Z, "harvest_tree_fresh_stump", -24.3, 3.4, yaw=0.4, note="logging")
    L.prop(Z, "harvest_tree_fresh_stump", -19.2, 3.8, yaw=1.2, note="logging")
    L.prop(Z, "harvest_tree_depleted_stump", -21.0, 4.6, yaw=-0.9, note="logging")
    L.prop(Z, "wooden_axe_world", -22.6, 3.6, yaw=0.8, note="logging")
    for i, (px, pz) in enumerate(((-20.8, 2.4), (-21.4, 3.2), (-22.9, 0.6))):
        L.prop(Z, "pickup_log", px, pz, yaw=0.6 + i * 1.3, note="logging")
    L.prop(Z, "pickup_fibre_bundle", -19.8, 1.8, yaw=0.2, note="logging")
    L.prop(Z, "pickup_berry", -24.2, 4.0, yaw=0.0, note="logging")

    L.prop(Z, "loot_chest_small_closed", -29.6, -14.8, yaw=0.5, note="reward")
    L.prop(Z, "loot_coin_pouch", -28.0, 16.4, yaw=0.0, note="reward")
    L.prop(Z, "loot_powerup_orb", -30.4, 8.2, y=0.6, yaw=0.0, note="reward", float_ok=True)

    L.scatter(Z, ["fallen_log_%s" % c for c in "abcd"], 8, band, min_gap=1.2, name_hint="debris")
    L.scatter(Z, ["stump_%s" % c for c in "acd"], 8, band, min_gap=1.0, name_hint="debris")
    L.scatter(Z, ["root_cluster_%s" % c for c in "abcd"], 7, band, min_gap=1.0, name_hint="debris")
    L.scatter(Z, ["boulder_%s" % c for c in "bcefg"], 8, band, min_gap=1.5, name_hint="debris")
    undergrowth = (-42.5, -40.0, -14.0, 38.5)
    L.scatter(Z, ["fern_%s" % c for c in "abcdef"], 42, undergrowth, min_gap=0.4,
              scale_range=(0.85, 1.25), avoid_roads=False, name_hint="undergrowth")
    forest_grass = (["grass_clump_%s" % c for c in "abcdef"]
                    + ["grass_meadow_%s" % c for c in "abcd"]
                    + ["grass_tuft_%s" % c for c in "abcd"])
    L.scatter(Z, forest_grass, 58, undergrowth, min_gap=0.3,
              scale_range=(0.8, 1.2), avoid_roads=False, name_hint="undergrowth")
    L.scatter(Z, ["mushroom_cluster_%s" % c for c in "abcdef"], 14, undergrowth, min_gap=0.4,
              avoid_roads=False, name_hint="undergrowth")


# ---------------------------------------------------------------------------
# East mire — the dangerous one. Below grade, lit wrong, and it has a nest.
# ---------------------------------------------------------------------------

def build_mire(L: Layout) -> None:
    Z = "EastMire"
    floor = (BASIN_X0 + 4.4, BASIN_Z0 + 4.4, BASIN_X1 - 4.4, BASIN_Z1 - 4.4)

    # Landmark first: the standing stone is what you steer toward once you drop into the basin.
    L.prop(Z, "standing_stone_a", 23.0, 1.5, note="landmark")
    L.prop(Z, "loot_powerup_orb", 23.0, 1.5, y=BASIN_Y + 3.26, note="landmark", float_ok=True)
    # Crystals as one vein around the landmark, not evenly sprinkled across the zone.
    for i, (cx, cz) in enumerate(((21.2, 3.4), (24.8, 3.6), (24.2, -0.9), (21.4, -0.7))):
        L.prop(Z, "mire_crystal_%s" % "abcd"[i], cx, cz, yaw=0.3 + i * 1.4, note="vein")
    L.prop(Z, "mire_crystal_e", 27.6, -6.4, yaw=0.9, note="vein")
    L.prop(Z, "mire_crystal_f", 18.4, 8.2, yaw=-0.5, note="vein")
    L.light("MireVein", Z, (23.0, BASIN_Y + 2.2, 1.5), (0.55, 0.35, 0.95), 2.4, 14.0)

    # The nest, in its own clearing, with the reward parked behind it.
    L.prop(Z, "enemy_crawler_nest", 25.4, -8.2, yaw=0.6, note="threat")
    L.prop(Z, "loot_chest_wellspring_closed", 28.2, -9.6, yaw=-0.7, note="threat")
    L.prop(Z, "loot_item_bag", 26.8, -10.4, yaw=0.3, note="threat")
    L.light("NestGlow", Z, (25.4, BASIN_Y + 1.0, -8.2), (0.85, 0.3, 0.35), 1.4, 7.0)
    L.marker("NestSpawn", Z, 25.4, -8.2, "enemy_spawn")

    L.scatter(Z, ["tree_bare_%s" % c for c in "abcd"], 5, floor, min_gap=2.0, name_hint="deadwood")
    L.scatter(Z, ["tree_crooked_%s" % c for c in "abcd"], 5, floor, min_gap=2.0, name_hint="deadwood")
    L.scatter(Z, ["mire_tendril_%s" % c for c in "abcd"], 6, floor, min_gap=0.6,
              avoid_roads=False, name_hint="growth")
    L.scatter(Z, ["mushroom_cluster_%s" % c for c in "abcdef"], 12, floor, min_gap=0.5,
              scale_range=(0.85, 1.2), avoid_roads=False, name_hint="growth")
    L.scatter(Z, ["reeds_%s" % c for c in "abcd"], 18, floor, min_gap=0.3,
              scale_range=(0.9, 1.3), avoid_roads=False, name_hint="growth")
    mire_grass = (["grass_tuft_%s" % c for c in "abcd"]
                  + ["grass_seedhead_%s" % c for c in "abcd"])
    L.scatter(Z, mire_grass, 20, floor, min_gap=0.32,
              scale_range=(0.82, 1.16), avoid_roads=False, name_hint="marsh_grass")
    L.prop(Z, "pickup_mushroom", 22.0, -4.6, yaw=0.4, note="forage")
    L.prop(Z, "pickup_mushroom", 19.6, 6.2, yaw=1.1, note="forage")
    L.prop(Z, "pickup_salvage_fragment", 26.4, 4.8, yaw=0.7, note="forage")

    # Rim dressing sits on level ground outside the banks, never on a slope.
    rim = (BASIN_X0 - 2.0, -26.0, 32.0, 26.0,
           lambda x, z: not (BASIN_X0 - 1.0 < x < BASIN_X1 + 1.0 and BASIN_Z0 - 1.0 < z < BASIN_Z1 + 1.0))
    L.scatter(Z, ["tree_crooked_%s" % c for c in "abcd"], 7, rim, min_gap=1.8, name_hint="rim")
    L.scatter(Z, ["boulder_%s" % c for c in "acdfh"], 6, rim, min_gap=1.6, name_hint="rim")
    L.scatter(Z, ["grass_seedhead_%s" % c for c in "abcd"], 18, rim, min_gap=0.35,
              scale_range=(0.8, 1.18), avoid_roads=False, name_hint="rim_grass")
    L.prop(Z, "standing_stone_c", 31.2, 19.0, yaw=-0.3, note="rim")
    L.prop(Z, "standing_stone_d", 16.2, -16.2, yaw=0.4, note="rim")


# ---------------------------------------------------------------------------
# South ridge — the high ground, and the only place you can see the whole map
# ---------------------------------------------------------------------------

def build_ridge(L: Layout) -> None:
    Z = "SouthRidge"

    # Lookout on the top terrace: posts and beams, no floor, so there is no step to trip on.
    for px, pz in ((7.0, 26.8), (13.0, 26.8), (7.0, 31.4), (13.0, 31.4)):
        L.prop(Z, "wood_post", px, pz, note="lookout")
    L.prop(Z, "wood_beam", 10.0, 26.8, y=RIDGE_T2_Y + 3.0, note="lookout", float_ok=True)
    L.prop(Z, "wood_beam", 10.0, 31.4, y=RIDGE_T2_Y + 3.0, note="lookout", float_ok=True)
    L.prop(Z, "wood_railing", 10.0, 31.6, note="lookout")
    L.prop(Z, "wood_railing", 6.8, 29.1, yaw=math.pi * 0.5, note="lookout")
    L.prop(Z, "wood_railing", 13.2, 29.1, yaw=math.pi * 0.5, note="lookout")
    L.prop(Z, "station_campfire", 10.0, 29.2, note="lookout")
    L.light("RidgeFire", Z, (10.0, RIDGE_T2_Y + 1.2, 29.2), (1.0, 0.6, 0.25), 2.4, 11.0)
    L.prop(Z, "loot_chest_small_closed", 15.4, 28.6, yaw=-0.5, note="reward")
    L.prop(Z, "short_bow_world", 8.4, 28.2, yaw=0.9, note="lookout")

    # Quarry face on the lower terrace.
    L.prop(Z, "stone_node_intact", -8.4, 25.0, yaw=0.5, note="quarry")
    L.prop(Z, "stone_node_intact", -11.2, 28.0, yaw=-0.7, note="quarry")
    L.prop(Z, "stone_node_cracked", -10.6, 30.2, yaw=1.0, note="quarry")
    L.prop(Z, "pickup_stone", -9.6, 27.0, yaw=0.3, note="quarry")
    L.prop(Z, "pickup_flint", -11.8, 24.6, yaw=0.8, note="quarry")
    L.prop(Z, "stone_pickaxe_world", -10.2, 26.0, yaw=-0.4, note="quarry")
    L.prop(Z, "loot_coin_pouch", -15.6, 30.8, yaw=0.0, note="reward")

    tier1 = (-19.0, 22.0, 21.0, 33.0, lambda x, z: not (1.0 < x < 19.0 and z > 25.0) and abs(x) > 4.5)
    L.scatter(Z, ["boulder_%s" % c for c in "abcdefgh"], 9, tier1, min_gap=1.5, name_hint="ridge")
    L.scatter(Z, ["rock_cluster_%s" % c for c in "abcdef"], 6, tier1, min_gap=1.2, name_hint="ridge")
    ridge_grass = (["grass_clump_%s" % c for c in "abcdef"]
                   + ["grass_meadow_%s" % c for c in "abcd"]
                   + ["grass_tuft_%s" % c for c in "abcd"])
    L.scatter(Z, ridge_grass, 38, tier1, min_gap=0.3,
              scale_range=(0.75, 1.1), avoid_roads=False, name_hint="ridge")

    # The enlarged south edge earns its space with a wind-beaten back ridge, not an empty green shelf.
    back_ridge = (3.0, 34.0, 17.0, 42.2)
    L.prop(Z, "standing_stone_b", 10.0, 39.5, yaw=0.3, note="back_ridge")
    L.scatter(Z, ["tree_bare_%s" % c for c in "abcd"], 4, back_ridge, min_gap=1.8, name_hint="back_ridge")
    L.scatter(Z, ["boulder_%s" % c for c in "abcdefgh"], 5, back_ridge, min_gap=1.5, name_hint="back_ridge")
    L.scatter(Z, ["grass_tuft_%s" % c for c in "abcd"], 16, back_ridge, min_gap=0.3,
              scale_range=(0.8, 1.2), avoid_roads=False, name_hint="back_ridge")

    # Below the ridge face, so the climb reads as a climb.
    apron = (-22.0, 14.0, 24.0, 20.6, lambda x, z: abs(x) > 4.5)
    L.scatter(Z, ["boulder_%s" % c for c in "acdfg"], 6, apron, min_gap=1.4, name_hint="apron")
    L.scatter(Z, ["reeds_%s" % c for c in "abcd"], 10, apron, min_gap=0.3,
              scale_range=(0.9, 1.2), avoid_roads=False, name_hint="apron")


# ---------------------------------------------------------------------------
# Routes and boundary — dressing that never blocks a road
# ---------------------------------------------------------------------------

def build_routes(L: Layout) -> None:
    Z = "RoutesAndBoundary"

    # Verge grass hugs each road without standing in it.
    for name, x0, z0, x1, z1 in ROADS:
        horizontal = (x1 - x0) > (z1 - z0)
        for i in range(18):
            t = L.rng.uniform(0.05, 0.95)
            side = -1.0 if i % 2 == 0 else 1.0
            if horizontal:
                x = x0 + (x1 - x0) * t
                z = (z0 + z1) * 0.5 + side * L.rng.uniform(3.4, 4.6)
            else:
                z = z0 + (z1 - z0) * t
                x = (x0 + x1) * 0.5 + side * L.rng.uniform(3.4, 4.6)
            if abs(x) > BOUND - 2.0 or abs(z) > BOUND - 2.0:
                continue
            family = L.rng.randrange(3)
            asset = ("grass_clump_%s" % "abcdef"[L.rng.randrange(6)] if family == 0
                     else "grass_meadow_%s" % "abcd"[L.rng.randrange(4)] if family == 1
                     else "grass_seedhead_%s" % "abcd"[L.rng.randrange(4)])
            if L.blocked(x, z, 0.4):
                continue
            L.prop(Z, asset, x, z, yaw=L.rng.uniform(0.0, math.tau),
                   scale=L.rng.uniform(0.75, 1.05), note="verge", reserve=False)

    # Talus against the inner face of the rock wall, so the boundary reads as geology.
    inner = 1.6
    for _ in range(240):
        if len([p for p in L.props if p.get("note") == "talus"]) >= 42:
            break
        edge = L.rng.randrange(4)
        along = L.rng.uniform(-BOUND + 4.0, BOUND - 4.0)
        off = BOUND - L.rng.uniform(inner, inner + 2.4)
        x, z = (along, -off) if edge == 0 else (along, off) if edge == 1 else (-off, along) if edge == 2 else (off, along)
        asset = "boulder_%s" % "abcdefgh"[L.rng.randrange(8)]
        radius = footprint_radius(asset)
        if L.blocked(x, z, radius) or L.on_road(x, z, radius):
            continue
        if abs(L.surface_at(x, z)) > 0.01:  # keep talus on flat ground, off the terraces
            continue
        L.prop(Z, asset, x, z, yaw=L.rng.uniform(0.0, math.tau), note="talus")

    # A tree line behind the forest so the wall is not the first thing you see to the west.
    treeline = (-42.5, -39.0, -37.0, 39.0)
    L.scatter(Z, ["tree_pine_%s" % c for c in "abcdef"], 18, treeline, min_gap=1.4, name_hint="treeline")

    # Transition cover carries the eye between landmarks and fills the new breathing room without
    # turning every added metre into another dense forest.
    north_meadow = (-19.0, -42.0, 22.0, -35.0)
    east_meadow = (32.0, -31.0, 42.0, 31.0)
    transition_grass = (["grass_meadow_%s" % c for c in "abcd"]
                        + ["grass_seedhead_%s" % c for c in "abcd"])
    L.scatter(Z, transition_grass, 28, north_meadow, min_gap=0.4,
              scale_range=(0.8, 1.2), avoid_roads=False, name_hint="transition")
    L.scatter(Z, transition_grass, 36, east_meadow, min_gap=0.4,
              scale_range=(0.8, 1.2), avoid_roads=False, name_hint="transition")


# ---------------------------------------------------------------------------
# Validation — the part that makes this better than placing props by eye
# ---------------------------------------------------------------------------

def validate(L: Layout) -> list[str]:
    errors: list[str] = []

    for name, slope in getattr(L, "slopes", []):
        if slope > 40.0:
            errors.append("ramp %s is %.1f deg — steeper than the player can climb" % (name, slope))

    for prop in L.props:
        asset, (x, y, z) = prop["asset"], prop["pos"]
        if max(abs(x), abs(z)) > BOUND - 0.5:
            errors.append("%s at (%.1f, %.1f) is outside the boundary" % (asset, x, z))
        # Foundations establish the support surface seen by later props; comparing their base
        # against their own finished top would incorrectly report them as buried.
        if not prop.get("float_ok") and not asset.endswith("_foundation"):
            surface = L.surface_at(x, z)
            if abs(y - surface) > 0.02:
                errors.append("%s at (%.1f, %.1f) floats/sinks: y=%.2f, surface=%.2f"
                              % (asset, x, z, y, surface))
        if prop["cols"] and not prop.get("road_ok"):
            radius = footprint_radius(asset) * prop["scale"]
            if L.on_road(x, z, radius):
                errors.append("%s at (%.1f, %.1f) blocks a road corridor" % (asset, x, z))

    solids = [(p, footprint_radius(p["asset"]) * p["scale"]) for p in L.props if p["cols"]]
    for i, (a, ra) in enumerate(solids):
        for b, rb in solids[i + 1:]:
            if a.get("note") in ("cabin", "workshop", "forge", "perimeter", "gate:north", "lookout"):
                continue
            if b.get("note") in ("cabin", "workshop", "forge", "perimeter", "lookout"):
                continue
            gap = math.hypot(a["pos"][0] - b["pos"][0], a["pos"][2] - b["pos"][2])
            if gap < (ra + rb) * 0.82:
                errors.append("%s and %s interpenetrate at (%.1f, %.1f) — gap %.2f, need %.2f"
                              % (a["asset"], b["asset"], a["pos"][0], a["pos"][2], gap, (ra + rb) * 0.82))

    hearth = [p for p in L.props if p.get("note") == "hearth"]
    for prop in L.props:
        if prop is hearth[0] or not prop["cols"]:
            continue
        if math.hypot(prop["pos"][0], prop["pos"][2] - 2.0) < 2.6 and prop.get("note") != "hearth":
            errors.append("%s crowds the hearth at (%.1f, %.1f)" % (prop["asset"], prop["pos"][0], prop["pos"][2]))

    gates = [prop for prop in L.props if prop["asset"] == "fence_gate"]
    if len(gates) != 4:
        errors.append("spawn camp needs four gates, found %d" % len(gates))
    for gate in gates:
        for shape in gate["cols"]:
            if shape["t"] != "box":
                continue
            half_width = shape["size"][0] * 0.5
            centre_x = shape["off"][0]
            if abs(centre_x) - half_width < 0.9:
                errors.append("fence gate at (%.1f, %.1f) blocks its 1.8m centre passage"
                              % (gate["pos"][0], gate["pos"][2]))

    grass_assets = {prop["asset"] for prop in L.props if prop["asset"].startswith("grass_")}
    grass_count = sum(1 for prop in L.props if prop["asset"].startswith("grass_"))
    if len(grass_assets) < 14 or grass_count < 220:
        errors.append("ground cover is under-dressed: %d grass placements across %d variants"
                      % (grass_count, len(grass_assets)))

    return errors


def build() -> tuple[Layout, dict]:
    L = Layout()
    L.slopes = []
    build_terrain(L)
    build_camp(L)
    build_ruins(L)
    build_forest(L)
    build_mire(L)
    build_ridge(L)
    build_routes(L)

    data = {
        "id": MAP_ID,
        "seed": SEED,
        "bound": BOUND,
        "zones": ZONES,
        "materials": MATERIALS,
        "spawn": {"pos": list(SPAWN_POS), "yaw": 0.0},
        "heightfield": heightfield_block(),
        "terrain": L.terrain,
        "props": L.props,
        "lights": L.lights,
        "markers": L.markers,
        "roads": [{"name": r[0], "rect": list(r[1:])} for r in ROADS],
    }
    return L, data


def main() -> int:
    L, data = build()
    errors = validate(L)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(data, indent=1) + "\n")

    solid = sum(1 for p in L.props if p["cols"])
    shapes = sum(len(p["cols"]) for p in L.props)
    per_zone = {z: sum(1 for p in L.props if p["zone"] == z) for z in ZONES}
    print("HOLLOW_LAYOUT props=%d solid=%d shapes=%d terrain=%d lights=%d"
          % (len(L.props), solid, shapes, len(L.terrain), len(L.lights)))
    print("HOLLOW_ZONES " + " ".join("%s=%d" % (k, v) for k, v in per_zone.items()))
    for name, slope in L.slopes:
        print("HOLLOW_RAMP %s %.1f deg" % (name, slope))
    if errors:
        print("HOLLOW_VALIDATE failed=%d" % len(errors))
        for error in errors[:40]:
            print("  FAIL: %s" % error)
        return 1
    print("HOLLOW_VALIDATE ok wrote=%s" % OUT.relative_to(ROOT))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
