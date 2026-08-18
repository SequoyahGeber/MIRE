"""Author `hollowmere` — MIRE's large map.

Run with plain python3 (no Blender, no Godot):

    python3 tools/mapgen/hollowmere_layout.py

It writes `world/gen/layouts/hollowmere.json` and validates the result. One consumer reads it:

    world/gen/authored_world.gd  -> terrain, water, props, colliders, lights, markers

## Why this map is built differently from Playtest Hollow

The Hollow is 88 m across, and its pipeline bakes every placed prop into a single
`assets/maps/playtest_hollow.glb` in Blender, with a separate GDScript rebuilding the collision
from the same JSON. That is a good design at that size and the wrong one here. Hollowmere is
**320 m across — thirteen times the area** — and baking it would produce one enormous mesh with no
culling granularity, so the GPU would draw the far side of the valley through a hill every frame.

So this map has **one consumer instead of two**. `authored_world.gd` builds the visuals *and* the
collision from this file at load, which means the two cannot drift apart even in principle — the
drift the Hollow's one-file-two-consumers rule exists to prevent is structurally impossible here
rather than merely validated against. Props are instanced through `MultiMeshInstance3D` grouped by
chunk, so the renderer culls a hillside in one test instead of five hundred.

## What it authors

A drowned valley. A river enters from the north, drops through a gorge, and feeds a lake — the mere
— in the south-east. A granite plateau stands over the north-west with an escarpment you can only
climb by two ramps. The east is marsh going to open water. A ruined village sits on the west bank,
a quarry is cut into the plateau's foot, and the Mire has taken the low ground around the lake.

Coordinates are GODOT coordinates everywhere in this file and in the JSON: +X east, +Y up, +Z south.

## Placement rules the validator enforces, so nobody has to eyeball a render

  * nothing floats — every grounded prop sits on the sampled surface below it
  * nothing interpenetrates — solid props keep their measured footprints apart
  * roads stay walkable — no solid prop inside a road corridor
  * **every landmark is reachable on foot from spawn**, proved by a slope-limited flood fill over
    the terrain grid, not by looking at it
  * nothing is placed in water it would drown in, and nothing stands on a slope it would slide off
  * everything is inside the boundary ring
"""

from __future__ import annotations

import json
import math
import random
from collections import deque
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / "assets"
OUT = ROOT / "world" / "gen" / "layouts" / "hollowmere.json"

SEED = 20260818
MAP_ID = "hollowmere"

# --- extent ----------------------------------------------------------------
# Playable half-extent. The boundary ridge stands from BOUND outward.
BOUND = 158.0
RING_OUTER = 178.0

# Terrain grid. 2.5 m cells over 360 m gives 145x145 samples: fine enough that a
# 4 m rock does not read as sitting on a facet, coarse enough that the whole
# terrain is 41,472 triangles, which is one ordinary mesh.
CELL = 2.5
HALF_SPAN = RING_OUTER
NX = int(round(HALF_SPAN * 2.0 / CELL)) + 1
NZ = NX
ORIGIN = (-HALF_SPAN, -HALF_SPAN)

WATER_LAKE = -3.4
WATER_MARSH = -1.6
CHUNK = 40.0

MAX_WALK_SLOPE_DEG = 38.0
MAX_PROP_SLOPE_DEG = 32.0

MATERIALS = {
    "grass": {"color": [0.105, 0.195, 0.088, 1.0], "roughness": 0.98},
    "meadow": {"color": [0.135, 0.245, 0.098, 1.0], "roughness": 0.99},
    "forest_floor": {"color": [0.082, 0.118, 0.052, 1.0], "roughness": 1.0},
    "path": {"color": [0.205, 0.152, 0.088, 1.0], "roughness": 1.0},
    "mud": {"color": [0.126, 0.108, 0.148, 1.0], "roughness": 0.74},
    "marsh": {"color": [0.112, 0.142, 0.108, 1.0], "roughness": 0.86},
    "rock": {"color": [0.152, 0.162, 0.178, 1.0], "roughness": 0.95},
    "scree": {"color": [0.196, 0.201, 0.208, 1.0], "roughness": 0.97},
    "ridge": {"color": [0.118, 0.152, 0.088, 1.0], "roughness": 0.97},
    "sand": {"color": [0.242, 0.216, 0.152, 1.0], "roughness": 0.98},
    "ash": {"color": [0.118, 0.108, 0.106, 1.0], "roughness": 0.99},
}

# Water needs some metal in it. With metallic at zero a surface this dark reads as
# grey card no matter what hue it is given, because almost nothing reflects off it
# and fog then washes out what little remains — which is exactly how the first
# render of the mere came out.
WATER_MATERIALS = {
    "lake": {"color": [0.10, 0.26, 0.30, 0.74], "roughness": 0.06, "metallic": 0.35},
    "marsh": {"color": [0.16, 0.11, 0.20, 0.70], "roughness": 0.14, "metallic": 0.22},
}


# ---------------------------------------------------------------------------
# Deterministic noise
# ---------------------------------------------------------------------------


def _fade(t: float) -> float:
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0)


def _lerp(t: float, a: float, b: float) -> float:
    return a + t * (b - a)


class Noise:
    """Classic gradient noise, written out rather than imported.

    `tools/mapgen` runs on plain python3 with no third-party packages, which is
    deliberate — the layout must be reproducible from a clean checkout without a
    Blender or a numpy in the way. A permutation table is twenty lines.
    """

    def __init__(self, seed: int) -> None:
        table = list(range(256))
        random.Random(seed).shuffle(table)
        self.p = table + table

    def _grad(self, h: int, x: float, z: float) -> float:
        h &= 7
        u = x if h < 4 else z
        v = z if h < 4 else x
        return (u if not h & 1 else -u) + (2.0 * v if not h & 2 else -2.0 * v)

    def at(self, x: float, z: float) -> float:
        xi, zi = math.floor(x), math.floor(z)
        xf, zf = x - xi, z - zi
        xi &= 255
        zi &= 255
        u, v = _fade(xf), _fade(zf)
        p = self.p
        a = p[xi] + zi
        b = p[xi + 1] + zi
        return _lerp(
            v,
            _lerp(u, self._grad(p[a], xf, zf), self._grad(p[b], xf - 1.0, zf)),
            _lerp(u, self._grad(p[a + 1], xf, zf - 1.0), self._grad(p[b + 1], xf - 1.0, zf - 1.0)),
        )

    def fbm(self, x: float, z: float, octaves: int = 5, gain: float = 0.5,
            lacunarity: float = 2.03) -> float:
        total, amplitude, frequency, norm = 0.0, 1.0, 1.0, 0.0
        for _ in range(octaves):
            total += self.at(x * frequency, z * frequency) * amplitude
            norm += amplitude
            amplitude *= gain
            frequency *= lacunarity
        return total / norm

    def ridged(self, x: float, z: float, octaves: int = 4) -> float:
        """1 - |noise|, which turns smooth hills into crested ridges."""
        total, amplitude, frequency, norm = 0.0, 1.0, 1.0, 0.0
        for _ in range(octaves):
            total += (1.0 - abs(self.at(x * frequency, z * frequency))) * amplitude
            norm += amplitude
            amplitude *= 0.52
            frequency *= 2.07
        return total / norm


def smoothstep(edge0: float, edge1: float, x: float) -> float:
    if edge0 == edge1:
        return 0.0 if x < edge0 else 1.0
    t = max(0.0, min(1.0, (x - edge0) / (edge1 - edge0)))
    return t * t * (3.0 - 2.0 * t)


def clamp(value: float, low: float, high: float) -> float:
    return low if value < low else (high if value > high else value)


# ---------------------------------------------------------------------------
# The valley's skeleton: everything else is laid out relative to these
# ---------------------------------------------------------------------------

#: The river, north to south-east, as a polyline of (x, z, bed_height).
RIVER = [
    (-14.0, -156.0, 16.0),
    (-10.0, -118.0, 11.5),
    (-18.0, -86.0, 7.0),
    (-12.0, -54.0, 2.4),
    (2.0, -26.0, -1.0),
    (16.0, -2.0, -2.6),
    (30.0, 26.0, -3.3),
    (44.0, 54.0, -3.6),
]
RIVER_HALF_WIDTH = 9.5
GORGE_Z = (-96.0, -48.0)

#: The mere itself.
LAKE_CENTRE = (52.0, 78.0)
LAKE_RADIUS = 54.0

#: The granite plateau over the north-west, and the two ramps that are the only
#: ways up it. A cliff with no way up is scenery; a cliff with one way up is a
#: choke point; two is a place.
PLATEAU_CENTRE = (-96.0, -84.0)
PLATEAU_RADIUS = 62.0
PLATEAU_HEIGHT = 21.0
RAMPS = [
    ((-52.0, -52.0), (-84.0, -76.0), 13.0),
    ((-118.0, -18.0), (-104.0, -50.0), 12.0),
]

#: Flat ground the layout depends on. Anything authored against level ground gets
#: its own pad, blended out so the mask never shows as a crease.
PADS = [
    ("SpawnHold", -34.0, 18.0, 30.0, 3.2, 1.0),
    ("RuinedVillage", -78.0, 46.0, 34.0, 1.4, 0.6),
    ("Quarry", -44.0, -66.0, 26.0, 4.6, 0.5),
    ("StoneCircle", 96.0, -74.0, 20.0, 9.5, 0.9),
    ("Watchtower", 116.0, 6.0, 15.0, 6.4, 0.8),
    ("LumberCamp", -122.0, 96.0, 20.0, 2.2, 0.7),
    ("HuntersCamp", 22.0, -112.0, 15.0, 8.2, 0.8),
    ("WellspringVale", -6.0, 118.0, 24.0, -0.6, 0.7),
    ("ExtractionYard", 108.0, 104.0, 22.0, 1.2, 0.8),
    ("Boneyard", 84.0, -128.0, 18.0, 12.5, 0.8),
]

#: Roads, as polylines with a half-width. They connect every landmark to the hold.
ROADS = [
    ("Road_Village", [(-34.0, 18.0), (-56.0, 30.0), (-78.0, 44.0)], 4.2),
    ("Road_Quarry", [(-34.0, 18.0), (-40.0, -16.0), (-44.0, -60.0)], 4.0),
    ("Road_North", [(-44.0, -60.0), (-24.0, -86.0), (18.0, -108.0)], 3.6),
    ("Road_Circle", [(18.0, -108.0), (58.0, -96.0), (92.0, -78.0)], 3.4),
    ("Road_Bone", [(58.0, -96.0), (76.0, -120.0)], 3.0),
    ("Road_East", [(-34.0, 18.0), (12.0, 10.0), (62.0, 8.0), (112.0, 6.0)], 4.2),
    ("Road_Mere", [(62.0, 8.0), (78.0, 44.0), (98.0, 84.0), (108.0, 102.0)], 3.8),
    ("Road_Vale", [(-34.0, 18.0), (-22.0, 62.0), (-8.0, 112.0)], 3.6),
    ("Road_Lumber", [(-78.0, 44.0), (-104.0, 70.0), (-120.0, 94.0)], 3.2),
]

#: Where the river must be bridged. **Computed, not hand-placed.** The first cut
#: of this file listed two crossings by eye and both of them missed the river —
#: the roads actually cross it 12 m and 22 m away from where the bridges stood, so
#: the map was two islands with a pair of decorative jetties on it. A bridge has to
#: come from the same data as the road and the river, or it is a guess that ages.
BRIDGE_HALF_WIDTH = 13.0
BRIDGE_HALF_DEPTH = 3.6
BRIDGE_APPROACH = 17.0


def find_crossings() -> list[tuple[str, tuple[float, float], tuple[float, float]]]:
    """Every point where a road centreline enters the river channel.

    Returns (name, centre, unit direction along the road) so the deck can be laid
    along the road rather than along an axis.
    """
    out: list[tuple[str, tuple[float, float], tuple[float, float]]] = []
    for road_name, points, _ in ROADS:
        inside: list[tuple[float, float]] = []
        for index in range(len(points) - 1):
            ax, az = points[index]
            bx, bz = points[index + 1]
            steps = max(2, int(math.hypot(bx - ax, bz - az) / 1.0))
            for step in range(steps + 1):
                t = step / steps
                x, z = ax + (bx - ax) * t, az + (bz - az) * t
                distance, _ = river_at(x, z)
                if distance <= RIVER_HALF_WIDTH + 3.0:
                    inside.append((x, z))
                elif inside:
                    out.append((road_name, inside, None))
                    inside = []
        if inside:
            out.append((road_name, inside, None))

    bridges = []
    for index, (road_name, run, _) in enumerate(out):
        cx = sum(p[0] for p in run) / len(run)
        cz = sum(p[1] for p in run) / len(run)
        ax, az = run[0]
        bx, bz = run[-1]
        length = math.hypot(bx - ax, bz - az)
        direction = ((bx - ax) / length, (bz - az) / length) if length > 1e-6 else (1.0, 0.0)
        bridges.append((f"Bridge_{road_name.replace('Road_', '')}_{index + 1}", (cx, cz), direction))
    return bridges

#: Zones. `centre`/`radius` drive flora and fog; the flood fill proves each is
#: reachable. Weights are consumed by the prop scatter below.
ZONES = [
    ("SpawnHold", (-34.0, 18.0), 40.0),
    ("WestWood", (-96.0, 24.0), 62.0),
    ("DeepForest", (-70.0, -20.0), 58.0),
    ("Plateau", (-96.0, -84.0), 66.0),
    ("Quarry", (-44.0, -66.0), 32.0),
    ("Gorge", (-14.0, -70.0), 34.0),
    ("BoneFields", (78.0, -118.0), 56.0),
    ("StoneMoor", (92.0, -60.0), 54.0),
    ("EastReach", (108.0, 10.0), 52.0),
    ("MereShore", (52.0, 78.0), 68.0),
    ("SouthMarsh", (-24.0, 118.0), 62.0),
    ("LumberEdge", (-118.0, 98.0), 44.0),
]


# ---------------------------------------------------------------------------
# Terrain
# ---------------------------------------------------------------------------


def _segment_distance(px: float, pz: float, ax: float, az: float,
                      bx: float, bz: float) -> tuple[float, float]:
    """Distance from a point to a segment, plus how far along the segment it fell."""
    dx, dz = bx - ax, bz - az
    length_sq = dx * dx + dz * dz
    if length_sq <= 1e-9:
        return math.hypot(px - ax, pz - az), 0.0
    t = clamp(((px - ax) * dx + (pz - az) * dz) / length_sq, 0.0, 1.0)
    cx, cz = ax + dx * t, az + dz * t
    return math.hypot(px - cx, pz - cz), t


def river_at(x: float, z: float) -> tuple[float, float]:
    """Nearest distance to the river channel, and the bed height there."""
    best_distance, best_bed = 1e9, 0.0
    for index in range(len(RIVER) - 1):
        ax, az, ay = RIVER[index]
        bx, bz, by = RIVER[index + 1]
        distance, t = _segment_distance(x, z, ax, az, bx, bz)
        if distance < best_distance:
            best_distance = distance
            best_bed = ay + (by - ay) * t
    return best_distance, best_bed


def road_distance(x: float, z: float) -> tuple[float, float]:
    """Nearest distance to any road centreline, and that road's half-width."""
    best_distance, best_half = 1e9, 0.0
    for _, points, half in ROADS:
        for index in range(len(points) - 1):
            ax, az = points[index]
            bx, bz = points[index + 1]
            distance, _ = _segment_distance(x, z, ax, az, bx, bz)
            if distance < best_distance:
                best_distance = distance
                best_half = half
    return best_distance, best_half


class Terrain:
    """The heightfield, and everything that reads it.

    Built once and then treated as read-only. Props sample it rather than
    recomputing the shaping functions, so a prop can never sit at a height the
    ground does not actually have.
    """

    def __init__(self, seed: int) -> None:
        self.shape = Noise(seed)
        self.detail = Noise(seed + 977)
        self.rock = Noise(seed + 5501)
        self.heights: list[float] = []
        self.materials: list[str] = []
        self._build()

    # -- shaping ------------------------------------------------------------

    def _base(self, x: float, z: float) -> float:
        rolling = self.shape.fbm(x / 96.0, z / 96.0, octaves=5) * 11.5
        texture = self.detail.fbm(x / 26.0, z / 26.0, octaves=3) * 2.4
        return rolling + texture

    def _plateau(self, x: float, z: float) -> float:
        distance = math.hypot(x - PLATEAU_CENTRE[0], z - PLATEAU_CENTRE[1])
        lift = 1.0 - smoothstep(PLATEAU_RADIUS - 16.0, PLATEAU_RADIUS + 6.0, distance)
        crest = self.rock.ridged(x / 48.0, z / 48.0, octaves=4) * 5.0
        return (PLATEAU_HEIGHT + crest) * lift

    def _ramps(self, x: float, z: float, height: float) -> float:
        """Cut two walkable ramps into the escarpment.

        Without them the plateau is decoration: `CharacterBody3D` cannot step up a
        cliff, and a place you can only look at is not a place.
        """
        for (ax, az), (bx, bz), half in RAMPS:
            distance, t = _segment_distance(x, z, ax, az, bx, bz)
            if distance > half + 8.0:
                continue
            low = self._base(ax, az) + self._plateau(ax, az) * 0.05
            high = PLATEAU_HEIGHT + self._base(bx, bz) * 0.3
            target = low + (high - low) * smoothstep(0.0, 1.0, t)
            blend = 1.0 - smoothstep(half, half + 8.0, distance)
            height = height + (target - height) * blend
        return height

    def _river(self, x: float, z: float, height: float) -> float:
        distance, bed = river_at(x, z)
        if distance > 46.0:
            return height
        channel = 1.0 - smoothstep(RIVER_HALF_WIDTH, RIVER_HALF_WIDTH + 5.0, distance)
        valley = 1.0 - smoothstep(RIVER_HALF_WIDTH + 5.0, 44.0, distance)
        # The gorge: the same river, but the walls stand instead of sloping.
        gorge = smoothstep(GORGE_Z[0] - 12.0, GORGE_Z[0], z) * (1.0 - smoothstep(GORGE_Z[1], GORGE_Z[1] + 12.0, z))
        bank = bed + 7.5 + gorge * 9.0
        height = height + (bank - height) * valley * (0.55 + gorge * 0.35)
        return height + (bed - height) * channel

    def _lake(self, x: float, z: float, height: float) -> float:
        distance = math.hypot(x - LAKE_CENTRE[0], z - LAKE_CENTRE[1])
        if distance > LAKE_RADIUS + 30.0:
            return height
        wobble = self.detail.at(x / 34.0, z / 34.0) * 7.0
        edge = LAKE_RADIUS + wobble
        basin = 1.0 - smoothstep(edge - 26.0, edge + 8.0, distance)
        floor = WATER_LAKE - 4.6 + self.detail.fbm(x / 22.0, z / 22.0, octaves=2) * 1.6
        return height + (floor - height) * basin

    def _marsh(self, x: float, z: float, height: float) -> float:
        flat = smoothstep(58.0, 116.0, z) * (1.0 - smoothstep(64.0, 128.0, abs(x + 30.0)))
        target = WATER_MARSH - 0.35 + self.detail.fbm(x / 18.0, z / 18.0, octaves=2) * 1.15
        return height + (target - height) * flat * 0.92

    def _ring(self, x: float, z: float, height: float) -> float:
        """A rising boundary ridge, so the map closes instead of ending."""
        distance = math.hypot(x, z)
        rise = smoothstep(BOUND - 12.0, RING_OUTER, distance)
        crest = 26.0 + self.rock.ridged(x / 40.0, z / 40.0, octaves=3) * 12.0
        return height + crest * rise * rise

    def _pads_and_roads(self, x: float, z: float, height: float) -> float:
        for _, cx, cz, radius, level, strength in PADS:
            distance = math.hypot(x - cx, z - cz)
            blend = (1.0 - smoothstep(radius * 0.62, radius * 1.35, distance)) * strength
            height = height + (level - height) * blend
        distance, half = road_distance(x, z)
        if distance < half + 14.0:
            smoothed = self.shape.fbm(x / 150.0, z / 150.0, octaves=2) * 5.0
            near = 1.0 - smoothstep(half, half + 14.0, distance)
            height = height + (smoothed - height) * near * 0.30
        return height

    def _build(self) -> None:
        for iz in range(NZ):
            z = ORIGIN[1] + iz * CELL
            for ix in range(NX):
                x = ORIGIN[0] + ix * CELL
                height = self._base(x, z)
                height += self._plateau(x, z)
                height = self._ramps(x, z, height)
                height = self._river(x, z, height)
                height = self._lake(x, z, height)
                height = self._marsh(x, z, height)
                height = self._pads_and_roads(x, z, height)
                height = self._ring(x, z, height)
                self.heights.append(round(height, 3))
        self._assign_materials()

    # -- reading ------------------------------------------------------------

    def height_at(self, x: float, z: float) -> float:
        fx = (x - ORIGIN[0]) / CELL
        fz = (z - ORIGIN[1]) / CELL
        ix = int(clamp(math.floor(fx), 0, NX - 2))
        iz = int(clamp(math.floor(fz), 0, NZ - 2))
        tx, tz = clamp(fx - ix, 0.0, 1.0), clamp(fz - iz, 0.0, 1.0)
        h = self.heights
        h00 = h[iz * NX + ix]
        h10 = h[iz * NX + ix + 1]
        h01 = h[(iz + 1) * NX + ix]
        h11 = h[(iz + 1) * NX + ix + 1]
        return _lerp(tz, _lerp(tx, h00, h10), _lerp(tx, h01, h11))

    def slope_deg_at(self, x: float, z: float) -> float:
        step = CELL * 0.75
        dx = self.height_at(x + step, z) - self.height_at(x - step, z)
        dz = self.height_at(x, z + step) - self.height_at(x, z - step)
        return math.degrees(math.atan(math.hypot(dx, dz) / (2.0 * step)))

    def water_at(self, x: float, z: float) -> float | None:
        """Water surface level at a point, or None for dry land."""
        if math.hypot(x - LAKE_CENTRE[0], z - LAKE_CENTRE[1]) <= LAKE_RADIUS + 10.0:
            if self.height_at(x, z) < WATER_LAKE:
                return WATER_LAKE
        distance, bed = river_at(x, z)
        if distance <= RIVER_HALF_WIDTH + 1.5 and self.height_at(x, z) < bed + 1.2:
            return bed + 1.1
        if z > 56.0 and self.height_at(x, z) < WATER_MARSH:
            return WATER_MARSH
        return None

    def depth_at(self, x: float, z: float) -> float:
        surface = self.water_at(x, z)
        return 0.0 if surface is None else max(0.0, surface - self.height_at(x, z))

    # -- materials ----------------------------------------------------------

    def _assign_materials(self) -> None:
        for iz in range(NZ):
            z = ORIGIN[1] + iz * CELL
            for ix in range(NX):
                x = ORIGIN[0] + ix * CELL
                self.materials.append(self._material_for(x, z, self.heights[iz * NX + ix]))

    def _material_for(self, x: float, z: float, height: float) -> str:
        distance, half = road_distance(x, z)
        if distance < half:
            return "path"
        slope = self.slope_deg_at(x, z)
        if math.hypot(x, z) > BOUND - 4.0:
            return "rock" if slope > 26.0 else "scree"
        if slope > 34.0:
            return "rock"
        if height > PLATEAU_HEIGHT * 0.62:
            return "scree" if slope > 22.0 else "ridge"
        if self.depth_at(x, z) > 0.05:
            return "mud"
        surface = self.water_at(x, z)
        if surface is None and height < WATER_LAKE + 1.6 and \
                math.hypot(x - LAKE_CENTRE[0], z - LAKE_CENTRE[1]) < LAKE_RADIUS + 16.0:
            return "sand"
        if z > 54.0 and height < WATER_MARSH + 2.2:
            return "marsh"
        if 84.0 < x < 150.0 and -150.0 < z < -92.0:
            return "ash"
        forest = self.shape.fbm(x / 74.0 + 11.0, z / 74.0 - 7.0, octaves=3)
        if forest > 0.08 and slope < 24.0:
            return "forest_floor"
        return "meadow" if forest < -0.14 else "grass"


# ---------------------------------------------------------------------------
# Asset catalogs — real measured footprints, so clearance is computed not guessed
# ---------------------------------------------------------------------------


def load_catalogs() -> dict[str, dict[str, dict]]:
    catalogs: dict[str, dict[str, dict]] = {}
    for directory in sorted(ASSETS.iterdir()):
        catalog = directory / "catalog.json"
        if not catalog.is_file():
            continue
        entries = json.loads(catalog.read_text())
        if not isinstance(entries, list):
            continue
        # `assets/icons` keys its catalog by `id` and has no geometry, so it is
        # not a placeable kit; skipping it here beats special-casing it later.
        catalogs[directory.name] = {
            entry["name"]: entry for entry in entries if isinstance(entry, dict) and "name" in entry
        }
    return catalogs


CATALOGS = load_catalogs()


def footprint(kit: str, asset: str) -> tuple[float, float]:
    """(radius, height) in metres, from the kit's own catalog."""
    entry = CATALOGS.get(kit, {}).get(asset)
    if entry is None:
        raise KeyError(f"{kit}/{asset} is not in any catalog")
    width = float(entry.get("width_m", 1.0))
    depth = float(entry.get("depth_m", 1.0))
    return max(width, depth) * 0.5, float(entry.get("height_m", 1.0))


def names(kit: str, prefix: str) -> list[str]:
    return sorted(n for n in CATALOGS.get(kit, {}) if n.startswith(prefix))


# ---------------------------------------------------------------------------
# Placement
# ---------------------------------------------------------------------------


class Placer:
    """Places props and refuses to place bad ones.

    Every rejection is counted and reported. A scatter that silently drops half
    its candidates looks identical to one that placed them, and the difference is
    the whole map — so the run prints why it said no.
    """

    def __init__(self, terrain: Terrain, seed: int) -> None:
        self.terrain = terrain
        self.rng = random.Random(seed)
        self.props: list[dict] = []
        self._grid: dict[tuple[int, int], list[tuple[float, float, float]]] = {}
        self.rejects: dict[str, int] = {}

    def _reject(self, reason: str) -> None:
        self.rejects[reason] = self.rejects.get(reason, 0) + 1

    def _cells(self, x: float, z: float, radius: float):
        step = 8.0
        x0, x1 = int((x - radius) // step), int((x + radius) // step)
        z0, z1 = int((z - radius) // step), int((z + radius) // step)
        for cx in range(x0, x1 + 1):
            for cz in range(z0, z1 + 1):
                yield (cx, cz)

    def clear(self, x: float, z: float, radius: float) -> bool:
        for cell in self._cells(x, z, radius):
            for ox, oz, oradius in self._grid.get(cell, ()):
                if math.hypot(x - ox, z - oz) < radius + oradius:
                    return False
        return True

    def _occupy(self, x: float, z: float, radius: float) -> None:
        for cell in self._cells(x, z, radius):
            self._grid.setdefault(cell, []).append((x, z, radius))

    def place(self, kit: str, asset: str, zone: str, x: float, z: float, *,
              solid: bool = True, road_ok: bool = False, spacing: float = 0.0,
              yaw: float | None = None, scale: float = 1.0, note: str = "",
              max_slope: float = MAX_PROP_SLOPE_DEG, max_depth: float = 0.0,
              y_offset: float = 0.0, force: bool = False,
              col: list[dict] | None = None) -> bool:
        radius, height = footprint(kit, asset)
        radius *= scale
        height *= scale
        keep_out = max(radius, spacing)

        if math.hypot(x, z) > BOUND - 2.0:
            self._reject("outside the boundary ring")
            return False
        if not force:
            if self.terrain.slope_deg_at(x, z) > max_slope:
                self._reject("ground too steep")
                return False
            if self.terrain.depth_at(x, z) > max_depth:
                self._reject("under water")
                return False
            if not self.clear(x, z, keep_out):
                self._reject("too close to another prop")
                return False
            if solid and not road_ok:
                distance, half = road_distance(x, z)
                if distance < half + radius:
                    self._reject("blocking a road")
                    return False

        y = self.terrain.height_at(x, z) + y_offset
        record = {
            "asset": asset,
            "kit": kit,
            "zone": zone,
            "pos": [round(x, 3), round(y, 3), round(z, 3)],
            "yaw": round(self.rng.uniform(0.0, math.tau) if yaw is None else yaw, 4),
            "scale": round(scale, 3),
            "road_ok": road_ok,
        }
        if note:
            record["note"] = note
        if col is not None:
            record["cols"] = col
        elif solid:
            record["cols"] = [{
                "t": "cyl",
                "r": round(max(0.24, radius * 0.62), 3),
                "h": round(max(0.5, height), 3),
                "y": round(max(0.5, height) * 0.5, 3),
            }]
        self.props.append(record)
        self._occupy(x, z, keep_out)
        return True

    def scatter(self, zone: str, centre: tuple[float, float], radius: float,
                table: list[tuple], target: int, *, jitter: float = 1.0) -> int:
        """Sow `target` candidates over a disc and keep whatever survives.

        Candidates come from a jittered lattice rather than uniform random draws:
        pure random clumps, and clumping is indistinguishable from "the scatter is
        broken" once half the clump is rejected for overlapping the other half.
        """
        weights = [entry[2] for entry in table]
        total = sum(weights)
        if total <= 0:
            return 0
        placed = 0
        side = max(2, int(math.sqrt(target)))
        step = (radius * 2.0) / side
        for row in range(side):
            for column in range(side):
                x = centre[0] - radius + (column + 0.5) * step + self.rng.uniform(-step, step) * jitter * 0.5
                z = centre[1] - radius + (row + 0.5) * step + self.rng.uniform(-step, step) * jitter * 0.5
                if math.hypot(x - centre[0], z - centre[1]) > radius:
                    continue
                roll = self.rng.uniform(0.0, total)
                chosen = table[-1]
                for entry in table:
                    roll -= entry[2]
                    if roll <= 0.0:
                        chosen = entry
                        break
                kit, prefix, _, spacing, solid = chosen[:5]
                options = names(kit, prefix)
                if not options:
                    continue
                asset = options[self.rng.randrange(len(options))]
                extra = chosen[5] if len(chosen) > 5 else {}
                if self.place(kit, asset, zone, x, z, solid=solid, spacing=spacing,
                              scale=round(self.rng.uniform(0.88, 1.16), 3), **extra):
                    placed += 1
        return placed


# ---------------------------------------------------------------------------
# What grows where
# ---------------------------------------------------------------------------

# (kit, name prefix, weight, spacing in metres, has collision[, extra kwargs])
SCATTER: dict[str, list[tuple]] = {
    "SpawnHold": [
        ("environment", "tree_birch_", 6, 6.0, True),
        ("flora", "bush_round_", 14, 2.6, False),
        ("flora", "sapling_", 10, 2.4, False),
        ("environment", "boulder_", 8, 3.0, True),
        ("environment", "rock_cluster_", 8, 2.6, False),
        ("flora", "grass_tussock_", 18, 1.6, False),
        ("flora", "flowers_meadow_", 16, 1.5, False),
        ("harvestables", "harvest_tree_intact", 6, 6.0, True),
    ],
    "WestWood": [
        ("environment", "tree_pine_", 30, 5.0, True),
        ("environment", "tree_crooked_", 10, 5.4, True),
        ("environment", "tree_birch_", 8, 5.0, True),
        ("flora", "bush_broadleaf_", 10, 3.0, False),
        ("flora", "bracken_", 14, 2.0, False),
        ("environment", "fallen_log_", 6, 4.0, True),
        ("environment", "stump_", 6, 3.0, True),
        ("flora", "sapling_", 12, 2.6, False),
        ("environment", "mushroom_cluster_", 6, 2.0, False),
    ],
    "DeepForest": [
        ("environment", "tree_pine_", 34, 4.8, True),
        ("environment", "tree_bare_", 10, 5.2, True),
        ("flora", "bracken_", 16, 1.9, False),
        ("flora", "bush_round_", 10, 2.8, False),
        ("environment", "root_cluster_", 8, 3.0, False),
        ("environment", "fallen_log_", 7, 4.2, True),
        ("flora", "tree_snag_", 5, 6.0, True),
        ("harvestables", "harvest_tree_intact", 8, 6.4, True),
        ("environment", "boulder_", 6, 3.4, True),
    ],
    "Plateau": [
        ("environment", "boulder_", 24, 4.0, True),
        ("environment", "rock_cluster_", 20, 3.0, False),
        ("environment", "standing_stone_", 6, 6.0, True),
        ("flora", "grass_dry_", 18, 1.8, False),
        ("flora", "bush_thorn_", 12, 2.6, False),
        ("environment", "tree_bare_", 6, 7.0, True),
        ("flora", "grass_tussock_", 14, 1.8, False),
    ],
    "Quarry": [
        ("environment", "rock_cluster_", 30, 2.4, False),
        ("environment", "boulder_", 22, 3.2, True),
        ("harvestables", "stone_node_intact", 14, 4.0, True),
        ("harvestables", "iron_node_intact", 8, 4.2, True),
        ("flora", "grass_dry_", 12, 1.8, False),
        ("environment", "wood_beam", 4, 3.0, True),
    ],
    "Gorge": [
        ("environment", "boulder_", 26, 3.4, True),
        ("environment", "rock_cluster_", 22, 2.6, False),
        ("flora", "moss_patch_", 16, 1.6, False),
        ("flora", "sedge_", 14, 1.6, False, {"max_depth": 0.35}),
        ("environment", "fallen_log_", 6, 4.4, True),
        ("flora", "bush_dead_", 8, 2.8, False),
    ],
    "BoneFields": [
        ("environment", "tree_bare_", 20, 5.4, True),
        ("flora", "bush_dead_", 22, 2.6, False),
        ("flora", "tree_snag_", 12, 6.2, True),
        ("environment", "stump_", 12, 3.2, True),
        ("flora", "grass_dry_", 18, 1.8, False),
        ("environment", "mire_tendril_", 8, 2.6, False),
        ("environment", "boulder_", 8, 3.4, True),
    ],
    "StoneMoor": [
        ("environment", "standing_stone_", 10, 7.0, True),
        ("environment", "boulder_", 20, 3.6, True),
        ("flora", "grass_tussock_", 22, 1.7, False),
        ("flora", "grass_dry_", 18, 1.7, False),
        ("flora", "bush_thorn_", 12, 2.6, False),
        ("environment", "ruin_column_", 5, 5.0, True),
        ("environment", "rock_cluster_", 12, 2.8, False),
    ],
    "EastReach": [
        ("environment", "ruin_wall_", 8, 5.4, True),
        ("environment", "ruin_column_", 8, 4.6, True),
        ("environment", "tree_crooked_", 10, 6.8, True),
        ("flora", "bush_round_", 14, 2.8, False),
        ("flora", "nettle_", 14, 1.7, False),
        ("flora", "flowers_tall_", 12, 1.6, False),
        ("environment", "boulder_", 10, 3.4, True),
        ("environment", "stone_marker_", 4, 5.0, True),
    ],
    "MereShore": [
        ("flora", "marsh_grass_", 24, 1.7, False, {"max_depth": 0.55}),
        ("flora", "sedge_", 20, 1.6, False, {"max_depth": 0.5}),
        ("environment", "reeds_", 18, 2.0, False, {"max_depth": 0.7}),
        ("flora", "lily_pad_", 14, 2.2, False, {"max_depth": 1.6, "max_slope": 60.0}),
        ("flora", "tree_willow_", 10, 8.0, True),
        ("flora", "flowers_bog_", 14, 1.6, False, {"max_depth": 0.3}),
        ("environment", "boulder_", 8, 3.6, True),
        ("flora", "bush_dead_", 8, 2.8, False),
    ],
    "SouthMarsh": [
        ("environment", "reeds_", 22, 1.9, False, {"max_depth": 0.8}),
        ("flora", "marsh_grass_", 22, 1.7, False, {"max_depth": 0.6}),
        ("environment", "mire_crystal_", 8, 3.0, False),
        ("environment", "mire_tendril_", 10, 2.6, False),
        ("flora", "tree_willow_", 8, 8.4, True),
        ("flora", "moss_patch_", 16, 1.6, False),
        ("environment", "tree_bare_", 8, 7.0, True),
        ("flora", "flowers_bog_", 12, 1.6, False, {"max_depth": 0.35}),
    ],
    "LumberEdge": [
        ("environment", "stump_", 24, 3.0, True),
        ("environment", "fallen_log_", 16, 4.2, True),
        ("environment", "tree_pine_", 18, 5.0, True),
        ("flora", "sapling_", 16, 2.4, False),
        ("flora", "bracken_", 14, 1.9, False),
        ("harvestables", "harvest_tree_felled", 8, 5.0, True),
        ("pickups", "pickup_log", 6, 2.2, False),
    ],
}

#: Roughly one prop per this many square metres of zone, before rejections.
ZONE_DENSITY = {
    "SpawnHold": 22.0, "WestWood": 7.0, "DeepForest": 6.5, "Plateau": 10.0,
    "Quarry": 6.0, "Gorge": 9.0, "BoneFields": 9.0, "StoneMoor": 10.0,
    "EastReach": 10.0, "MereShore": 8.0, "SouthMarsh": 8.0, "LumberEdge": 6.0,
}


# ---------------------------------------------------------------------------
# Landmarks
# ---------------------------------------------------------------------------
#
# Everything above is rules. This is authorship: the places a player navigates by
# and remembers, each built from the shared kits rather than as a bespoke model,
# which is `docs/ASSET_TRACKER.md`'s A-019 rule ("built from reusable sub-pieces
# rather than monolithic dioramas") applied a batch early.


def ring(centre: tuple[float, float], radius: float, count: int, phase: float = 0.0):
    for index in range(count):
        angle = phase + index * math.tau / count
        yield (centre[0] + math.cos(angle) * radius, centre[1] + math.sin(angle) * radius, angle)


def bridge_deck_height(terrain: Terrain, centre: tuple[float, float],
                       direction: tuple[float, float]) -> float:
    """Deck height: the mean of the two approach heights on the road itself.

    Sampling a ring around the crossing is the obvious thing and the wrong one —
    half the ring is still in the channel and drags the median down into the water.
    The deck has to meet the road where the road actually arrives, or the player
    walks up to a bridge and finds a step they cannot climb.
    """
    ax = centre[0] - direction[0] * BRIDGE_APPROACH
    az = centre[1] - direction[1] * BRIDGE_APPROACH
    bx = centre[0] + direction[0] * BRIDGE_APPROACH
    bz = centre[1] + direction[1] * BRIDGE_APPROACH
    return (terrain.height_at(ax, az) + terrain.height_at(bx, bz)) * 0.5 + 0.25


def build_landmarks(placer: Placer, terrain: Terrain, markers: list[dict], lights: list[dict]) -> None:
    rng = placer.rng

    # -- the hold: the only built-up, defensible ground on the map -----------
    hold = (-34.0, 18.0)
    # Count comes from the circumference, not from a number that looked right. A
    # fence piece is 4.24 m long; sixteen of them around a 132 m ring leaves half
    # the perimeter open, which is what the first render showed.
    hold_radius = 21.0
    fence_count = int(round(math.tau * hold_radius / 4.24))
    for x, z, angle in ring(hold, hold_radius, fence_count):
        asset = "fence_gate" if int((angle / math.tau) * fence_count) % 8 == 3 else "fence_straight"
        placer.place("environment", asset, "SpawnHold", x, z, yaw=angle + math.pi * 0.5,
                     spacing=1.6, note="hold perimeter", force=True)
    for offset_x, offset_z in ((-7.0, -5.0), (5.5, -6.5), (0.0, 7.0)):
        base = (hold[0] + offset_x, hold[1] + offset_z)
        placer.place("environment", "wood_foundation", "SpawnHold", base[0], base[1],
                     solid=False, note="hold cabin", force=True)
        placer.place("environment", "wood_floor", "SpawnHold", base[0], base[1],
                     solid=False, y_offset=0.40, note="hold cabin", force=True)
        for side, (wall_x, wall_z, yaw) in enumerate((
            (0.0, -2.0, 0.0), (0.0, 2.0, math.pi), (-2.0, 0.0, math.pi * 0.5), (2.0, 0.0, -math.pi * 0.5)
        )):
            wall = "wood_wall_door" if side == 0 else ("wood_wall_window" if side == 1 else "wood_wall_solid")
            placer.place("environment", wall, "SpawnHold", base[0] + wall_x, base[1] + wall_z,
                         yaw=yaw, y_offset=0.64, note="hold cabin", force=True)
        placer.place("environment", "wood_roof_slope", "SpawnHold", base[0], base[1],
                     y_offset=3.64, solid=False, note="hold cabin", force=True)
    stations = [
        ("station_campfire", 0.0, 0.0), ("station_workbench_primitive", -3.4, 1.6),
        ("station_anvil", 3.2, 1.8), ("station_cooking_spit", 1.2, -2.6),
        ("station_woodcutting_block", -4.2, -2.2), ("station_stone_furnace", 4.6, -1.4),
        ("station_repair_bench", -1.8, 3.6),
    ]
    for asset, offset_x, offset_z in stations:
        x, z = hold[0] + offset_x, hold[1] + offset_z
        placer.place("crafting_stations", asset, "SpawnHold", x, z, spacing=1.4,
                     yaw=rng.uniform(0.0, math.tau), note="hold camp", force=True)
        markers.append(_marker(f"Station_{asset}", "station", x, terrain.height_at(x, z), z, "SpawnHold"))
    lights.append(_light("Hold_Fire", hold[0], terrain.height_at(*hold) + 1.1, hold[1],
                         [1.0, 0.62, 0.28], 3.4, 13.0))
    placer.place("wards", "ward_healthy", "SpawnHold", hold[0] - 9.0, hold[1] + 2.0,
                 spacing=2.4, note="hold ward", force=True)
    lights.append(_light("Hold_Ward", hold[0] - 9.0, terrain.height_at(hold[0] - 9.0, hold[1] + 2.0) + 1.6,
                         hold[1] + 2.0, [0.36, 0.94, 0.88], 2.2, 11.0))

    # -- ruined village ------------------------------------------------------
    village = (-78.0, 46.0)
    for index, (x, z, angle) in enumerate(ring(village, 15.0, 6, phase=0.4)):
        for row, piece in enumerate(("stone_foundation", "stone_wall_solid", "stone_wall_window")):
            if row and rng.random() < 0.35:
                continue
            placer.place("environment", piece, "RuinedVillage", x, z, yaw=angle,
                         y_offset=0.0 if row == 0 else 0.72 + (row - 1) * 3.0,
                         solid=row == 0, spacing=2.0, note="village shell", force=True)
        if index % 2 == 0:
            placer.place("environment", "ruin_wall_a", "RuinedVillage", x + 3.4, z + 2.6,
                         yaw=angle + 0.6, spacing=2.2, note="village shell", force=True)
    placer.place("environment", "stone_pillar", "RuinedVillage", village[0], village[1],
                 note="village well", force=True)
    markers.append(_marker("Village_Centre", "landmark", village[0],
                           terrain.height_at(*village), village[1], "RuinedVillage"))

    # -- the stone circle ----------------------------------------------------
    circle = (96.0, -74.0)
    for x, z, angle in ring(circle, 13.0, 9):
        placer.place("environment", f"standing_stone_{'abcd'[int(abs(x + z)) % 4]}", "StoneMoor",
                     x, z, yaw=angle + math.pi * 0.5, spacing=2.4, note="stone circle", force=True)
    placer.place("environment", "stone_marker_a", "StoneMoor", circle[0], circle[1],
                 note="stone circle", force=True)
    markers.append(_marker("Stone_Circle", "landmark", circle[0], terrain.height_at(*circle), circle[1],
                           "StoneMoor"))

    # -- watchtower ----------------------------------------------------------
    tower = (116.0, 6.0)
    for level in range(4):
        for x, z, angle in ring(tower, 3.4, 4, phase=0.6):
            placer.place("environment", "ruin_column_a" if level % 2 == 0 else "ruin_column_b",
                         "EastReach", x, z, yaw=angle, y_offset=level * 3.6, spacing=1.4,
                         note="watchtower", force=True)
    for x, z, angle in ring(tower, 9.0, 5):
        placer.place("environment", "ruin_wall_b", "EastReach", x, z, yaw=angle + math.pi * 0.5,
                     spacing=2.4, note="watchtower yard", force=True)
    markers.append(_marker("Watchtower", "landmark", tower[0], terrain.height_at(*tower), tower[1],
                           "EastReach"))

    # -- lumber camp ---------------------------------------------------------
    camp = (-122.0, 96.0)
    for index, (x, z, angle) in enumerate(ring(camp, 8.0, 7)):
        asset = ("harvest_tree_felled_trunk", "harvest_tree_fresh_stump", "pickup_log")[index % 3]
        kit = "pickups" if asset.startswith("pickup") else "harvestables"
        placer.place(kit, asset, "LumberEdge", x, z, yaw=angle, spacing=1.8,
                     solid=not asset.startswith("pickup"), note="lumber camp", force=True)
    placer.place("crafting_stations", "station_woodcutting_block", "LumberEdge", camp[0], camp[1],
                 note="lumber camp", force=True)
    placer.place("environment", "wood_railing", "LumberEdge", camp[0] + 5.0, camp[1] - 5.0,
                 yaw=0.6, note="lumber camp", force=True)
    markers.append(_marker("Lumber_Camp", "landmark", camp[0], terrain.height_at(*camp), camp[1],
                           "LumberEdge"))

    # -- hunters' camp -------------------------------------------------------
    hunt = (22.0, -112.0)
    placer.place("crafting_stations", "station_campfire", "BoneFields", hunt[0], hunt[1],
                 note="hunters camp", force=True)
    lights.append(_light("Hunt_Fire", hunt[0], terrain.height_at(*hunt) + 1.0, hunt[1],
                         [1.0, 0.58, 0.24], 2.6, 10.0))
    for x, z, angle in ring(hunt, 5.5, 4, phase=0.9):
        placer.place("environment", "wood_post", "BoneFields", x, z, yaw=angle, spacing=1.2,
                     note="hunters camp", force=True)
    placer.place("loot", "loot_chest_small_closed", "BoneFields", hunt[0] + 2.4, hunt[1] + 2.2,
                 note="hunters camp", force=True)
    markers.append(_marker("Hunters_Camp", "landmark", hunt[0], terrain.height_at(*hunt), hunt[1],
                           "BoneFields"))

    # -- the Wellspring ------------------------------------------------------
    vale = (-6.0, 118.0)
    placer.place("wellsprings", "wellspring_base", "SouthMarsh", vale[0], vale[1],
                 spacing=4.0, note="wellspring", force=True)
    placer.place("wellsprings", "wellspring_corrupted", "SouthMarsh", vale[0], vale[1],
                 solid=False, y_offset=1.2, note="wellspring", force=True)
    placer.place("wellsprings", "wellspring_ritual_pedestal", "SouthMarsh", vale[0] + 6.5, vale[1] + 3.0,
                 spacing=2.0, note="wellspring", force=True)
    for x, z, angle in ring(vale, 14.0, 8):
        placer.place("wellsprings", "wellspring_boundary_stones", "SouthMarsh", x, z, yaw=angle,
                     spacing=2.6, note="wellspring ring", force=True)
    lights.append(_light("Wellspring_Glow", vale[0], terrain.height_at(*vale) + 3.2, vale[1],
                         [0.72, 0.30, 0.94], 3.0, 20.0))
    markers.append(_marker("Wellspring", "objective", vale[0], terrain.height_at(*vale), vale[1],
                           "SouthMarsh"))

    # -- extraction yard -----------------------------------------------------
    yard = (108.0, 104.0)
    for offset_x in (-2.0, 2.0):
        for offset_z in (-2.0, 2.0):
            placer.place("environment", "stone_floor", "MereShore", yard[0] + offset_x * 2.0,
                         yard[1] + offset_z * 2.0, solid=False, note="extraction pad", force=True)
    placer.place("loot", "loot_chest_reinforced_closed", "MereShore", yard[0] + 3.0, yard[1] - 1.0,
                 y_offset=0.24, note="extraction cache", force=True)
    for x, z, angle in ring(yard, 9.0, 4, phase=0.8):
        placer.place("environment", "stone_marker_b", "MereShore", x, z, yaw=angle, spacing=2.0,
                     note="extraction markers", force=True)
    markers.append(_marker("Extraction", "extraction", yard[0], terrain.height_at(*yard) + 0.24,
                           yard[1], "MereShore"))

    # -- the boneyard, and where the Mire breeds -----------------------------
    bone = (84.0, -128.0)
    placer.place("enemies", "enemy_crawler_nest", "BoneFields", bone[0], bone[1],
                 spacing=3.0, note="crawler nest", force=True)
    markers.append(_marker("Nest_Boneyard", "enemy_nest", bone[0], terrain.height_at(*bone), bone[1],
                           "BoneFields"))
    for index, (nest_x, nest_z) in enumerate(((58.0, 92.0), (-56.0, 104.0), (18.0, -62.0))):
        placer.place("enemies", "enemy_crawler_nest", "MereShore", nest_x, nest_z,
                     spacing=3.0, note="crawler nest", force=True)
        markers.append(_marker(f"Nest_{index + 1}", "enemy_nest", nest_x,
                               terrain.height_at(nest_x, nest_z), nest_z, "MereShore"))

    # -- bridges -------------------------------------------------------------
    # The river carves a channel seven metres below its own banks, so without a
    # deck at BANK height the map is two islands. The first cut of this put the
    # deck at bed + 2.2 m — five metres below the ground either side, decorative
    # and useless — and the reachability fill is the only reason anyone found out.
    for name, (cx, cz), direction in find_crossings():
        deck = bridge_deck_height(terrain, (cx, cz), direction)
        yaw = math.atan2(direction[1], direction[0])
        normal = (-direction[1], direction[0])
        span = BRIDGE_HALF_WIDTH + BRIDGE_APPROACH * 0.35
        steps = int(span * 2.0 / 4.0) + 1
        for step in range(steps):
            t = -span + step * (span * 2.0 / max(1, steps - 1))
            x, z = cx + direction[0] * t, cz + direction[1] * t
            # Past the bank the ground has already risen to meet the deck, so a
            # plank here would be buried in the hillside carrying nobody.
            if terrain.height_at(x, z) > deck + 0.45:
                continue
            placer.place(
                "environment", "wood_floor", "Gorge", x, z, yaw=yaw,
                y_offset=deck - terrain.height_at(x, z),
                note=name, force=True,
                col=[{"t": "box", "size": [4.4, 0.6, 4.4], "off": [0.0, -0.16, 0.0]}],
            )
            if step % 2 == 0:
                for side in (-BRIDGE_HALF_DEPTH, BRIDGE_HALF_DEPTH):
                    rx, rz = x + normal[0] * side, z + normal[1] * side
                    placer.place("environment", "wood_railing", "Gorge", rx, rz,
                                 yaw=yaw, solid=False,
                                 y_offset=deck - terrain.height_at(rx, rz) + 0.24,
                                 note=name, force=True)
        for side in (-1.0, 1.0):
            px = cx + direction[0] * BRIDGE_HALF_WIDTH * side
            pz = cz + direction[1] * BRIDGE_HALF_WIDTH * side
            placer.place("environment", "wood_post", "Gorge", px, pz, yaw=yaw, solid=False,
                         y_offset=deck - terrain.height_at(px, pz) - 2.6, note=name, force=True)
        markers.append(_marker(name, "bridge", cx, deck, cz, "Gorge"))

    # -- loot worth walking to ----------------------------------------------
    for index, (x, z) in enumerate(((-104.0, -30.0), (68.0, -40.0), (-16.0, 76.0), (132.0, 60.0),
                                    (-140.0, 20.0), (40.0, -140.0))):
        placer.place("loot", "loot_chest_small_closed", "EastReach", x, z, spacing=2.0,
                     note="field cache", force=True)
        markers.append(_marker(f"Cache_{index + 1}", "loot", x, terrain.height_at(x, z), z, "EastReach"))


def _marker(name: str, kind: str, x: float, y: float, z: float, zone: str) -> dict:
    return {"name": name, "kind": kind, "zone": zone,
            "pos": [round(x, 3), round(y, 3), round(z, 3)]}


def _light(name: str, x: float, y: float, z: float, color: list[float],
           energy: float, radius: float) -> dict:
    return {"name": name, "pos": [round(x, 3), round(y, 3), round(z, 3)],
            "color": color, "energy": energy, "range": radius}


# ---------------------------------------------------------------------------
# Water
# ---------------------------------------------------------------------------


def build_water() -> list[dict]:
    """Water surfaces, as shapes the runtime tessellates against the terrain.

    Each carries its own level; the runtime clips it to wherever the ground is
    actually below that level, so a lake fills its basin instead of being a disc
    floating over a hillside.
    """
    bodies = [{
        "name": "The_Mere", "kind": "circle", "material": "lake",
        "centre": [LAKE_CENTRE[0], LAKE_CENTRE[1]], "radius": LAKE_RADIUS + 14.0,
        "level": WATER_LAKE,
    }, {
        "name": "South_Marsh", "kind": "rect", "material": "marsh",
        "min": [-118.0, 54.0], "max": [76.0, 152.0], "level": WATER_MARSH,
    }]
    for index in range(len(RIVER) - 1):
        ax, az, ay = RIVER[index]
        bx, bz, by = RIVER[index + 1]
        bodies.append({
            "name": f"River_{index + 1}", "kind": "strip", "material": "lake",
            "a": [ax, az], "b": [bx, bz],
            "half_width": RIVER_HALF_WIDTH + 2.0,
            "level_a": round(ay + 1.1, 3), "level_b": round(by + 1.1, 3),
        })
    return bodies


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------


def bridge_cells(terrain: Terrain) -> dict[int, float]:
    """Grid cells a bridge deck covers, and the height it puts them at."""
    cells: dict[int, float] = {}
    for _, (bx, bz), direction in find_crossings():
        deck = bridge_deck_height(terrain, (bx, bz), direction)
        reach = BRIDGE_HALF_WIDTH + BRIDGE_APPROACH * 0.35
        for iz in range(NZ):
            z = ORIGIN[1] + iz * CELL
            if abs(z - bz) > reach + 4.0:
                continue
            for ix in range(NX):
                x = ORIGIN[0] + ix * CELL
                along = (x - bx) * direction[0] + (z - bz) * direction[1]
                across = abs((x - bx) * -direction[1] + (z - bz) * direction[0])
                if abs(along) <= reach and across <= BRIDGE_HALF_DEPTH:
                    cells[iz * NX + ix] = deck
    return cells


def walkable_mask(terrain: Terrain) -> list[bool]:
    """Which grid cells a player could stand on.

    Slope from the terrain itself, and water deeper than a wade counts as a wall.
    """
    mask: list[bool] = []
    for iz in range(NZ):
        z = ORIGIN[1] + iz * CELL
        for ix in range(NX):
            x = ORIGIN[0] + ix * CELL
            inside = math.hypot(x, z) <= BOUND
            shallow = terrain.depth_at(x, z) <= 1.3
            gentle = terrain.slope_deg_at(x, z) <= MAX_WALK_SLOPE_DEG
            mask.append(inside and shallow and gentle)
    for index, _ in bridge_cells(terrain).items():
        mask[index] = True
    return mask


def reachable_from(terrain: Terrain, mask: list[bool], start: tuple[float, float]) -> list[bool]:
    """Flood fill over walkable cells, refusing steps a CharacterBody3D cannot take.

    This is the check that stops a landmark being scenery. `docs/DECISIONS.md`
    already records that CharacterBody3D cannot step up — so a 0.6 m lip is a wall,
    and a plateau whose ramps got shaped away by a later edit would be unreachable
    with nothing on screen to say so.
    """
    # A step limit and a slope limit are not the same rule, and conflating them
    # cost an afternoon. On a 2.5 m grid a *continuous* 38-degree hillside changes
    # height by 1.95 m from cell to cell; a flat 0.55 m cap therefore rejected
    # every ordinary slope on the map as if it were a ledge, and reported the
    # valley as unreachable when a player could simply have walked up it.
    #
    # Terrain-to-terrain is governed by slope, which `walkable_mask` already
    # checked. The 0.55 m ledge rule belongs only where there IS a discontinuity:
    # stepping on or off a bridge deck, which is exactly where CharacterBody3D's
    # inability to step up actually bites.
    max_slope_step = CELL * math.tan(math.radians(MAX_WALK_SLOPE_DEG))
    max_ledge_step = 0.55
    decks = bridge_cells(terrain)
    heights = list(terrain.heights)
    for index, deck in decks.items():
        heights[index] = deck
    sx = int(round((start[0] - ORIGIN[0]) / CELL))
    sz = int(round((start[1] - ORIGIN[1]) / CELL))
    seen = [False] * (NX * NZ)
    if not mask[sz * NX + sx]:
        return seen
    queue = deque([(sx, sz)])
    seen[sz * NX + sx] = True
    while queue:
        cx, cz = queue.popleft()
        here = heights[cz * NX + cx]
        for dx, dz in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nx, nz = cx + dx, cz + dz
            if not (0 <= nx < NX and 0 <= nz < NZ):
                continue
            index = nz * NX + nx
            if seen[index] or not mask[index]:
                continue
            on_deck = (index in decks) != (cz * NX + cx in decks)
            limit = max_ledge_step if on_deck else max_slope_step
            if abs(heights[index] - here) > limit:
                continue
            seen[index] = True
            queue.append((nx, nz))
    return seen


def validate(terrain: Terrain, placer: Placer, markers: list[dict],
             spawn: tuple[float, float, float]) -> list[str]:
    problems: list[str] = []

    for prop in placer.props:
        x, y, z = prop["pos"]
        if math.hypot(x, z) > RING_OUTER:
            problems.append(f"{prop['asset']} at ({x:.1f}, {z:.1f}) is outside the map")
        ground = terrain.height_at(x, z)
        if prop.get("cols") and y < ground - 0.75:
            problems.append(f"{prop['asset']} at ({x:.1f}, {z:.1f}) is buried {ground - y:.2f} m")

    solids = [(p["pos"][0], p["pos"][2], p["cols"][0].get("r", 1.0), p["asset"])
              for p in placer.props if p.get("cols") and not p.get("note")]
    grid: dict[tuple[int, int], list[int]] = {}
    for index, (x, z, radius, _) in enumerate(solids):
        grid.setdefault((int(x // 8), int(z // 8)), []).append(index)
    overlaps = 0
    for index, (x, z, radius, name) in enumerate(solids):
        for cx in range(int(x // 8) - 1, int(x // 8) + 2):
            for cz in range(int(z // 8) - 1, int(z // 8) + 2):
                for other in grid.get((cx, cz), ()):
                    if other <= index:
                        continue
                    ox, oz, oradius, oname = solids[other]
                    if math.hypot(x - ox, z - oz) < (radius + oradius) * 0.82:
                        overlaps += 1
    if overlaps:
        problems.append(f"{overlaps} pairs of solid props interpenetrate")

    for prop in placer.props:
        if not prop.get("cols") or prop.get("road_ok") or prop.get("note"):
            continue
        x, _, z = prop["pos"]
        distance, half = road_distance(x, z)
        if distance < half:
            problems.append(f"{prop['asset']} stands in a road corridor at ({x:.1f}, {z:.1f})")

    mask = walkable_mask(terrain)
    if not mask[int(round((spawn[2] - ORIGIN[1]) / CELL)) * NX
                + int(round((spawn[0] - ORIGIN[0]) / CELL))]:
        problems.append("spawn point is not on walkable ground")
    else:
        seen = reachable_from(terrain, mask, (spawn[0], spawn[2]))
        walkable_total = sum(1 for value in mask if value)
        reached = sum(1 for value in seen if value)
        if walkable_total and reached / walkable_total < 0.45:
            problems.append(
                f"only {reached}/{walkable_total} walkable cells reachable from spawn "
                "— the map is cut in half"
            )
        for marker in markers:
            if marker["kind"] not in ("landmark", "objective", "extraction", "station"):
                continue
            mx, _, mz = marker["pos"]
            ix = int(round((mx - ORIGIN[0]) / CELL))
            iz = int(round((mz - ORIGIN[1]) / CELL))
            near = any(
                0 <= ix + dx < NX and 0 <= iz + dz < NZ and seen[(iz + dz) * NX + ix + dx]
                for dx in range(-2, 3) for dz in range(-2, 3)
            )
            if not near:
                problems.append(f"{marker['name']} cannot be walked to from spawn")
    return problems


# ---------------------------------------------------------------------------
# Assembly
# ---------------------------------------------------------------------------


def main() -> None:
    print(f"hollowmere: {NX}x{NZ} grid at {CELL} m ({HALF_SPAN * 2:.0f} m across)")
    terrain = Terrain(SEED)
    lo = min(terrain.heights)
    hi = max(terrain.heights)
    print(f"  terrain {lo:.1f} m to {hi:.1f} m")

    placer = Placer(terrain, SEED + 31)
    markers: list[dict] = []
    lights: list[dict] = []
    build_landmarks(placer, terrain, markers, lights)
    landmark_props = len(placer.props)
    print(f"  landmarks: {landmark_props} props")

    for name, centre, radius in ZONES:
        table = SCATTER.get(name)
        if not table:
            continue
        area = math.pi * radius * radius
        target = int(area / ZONE_DENSITY[name])
        placed = placer.scatter(name, centre, radius, table, target)
        print(f"  {name:12s} {placed:5d} placed of {target:5d} attempted")

    spawn = (-34.0, terrain.height_at(-34.0, 24.0) + 0.4, 24.0)
    markers.insert(0, _marker("PlayerSpawn", "spawn", spawn[0], spawn[1], spawn[2], "SpawnHold"))

    for prop in placer.props:
        x, _, z = prop["pos"]
        prop["chunk"] = [int(math.floor(x / CHUNK)), int(math.floor(z / CHUNK))]

    problems = validate(terrain, placer, markers, spawn)

    material_names = list(MATERIALS)
    layout = {
        "id": MAP_ID,
        "seed": SEED,
        "bound": BOUND,
        "ring_outer": RING_OUTER,
        "chunk": CHUNK,
        "spawn": [round(v, 3) for v in spawn],
        "materials": MATERIALS,
        "water_materials": WATER_MATERIALS,
        "heightfield": {
            "origin": [ORIGIN[0], ORIGIN[1]],
            "cell": CELL,
            "nx": NX,
            "nz": NZ,
            "heights": terrain.heights,
            "material_names": material_names,
            # One index per grid vertex; the runtime takes each quad's material
            # from its lower-left corner, which is what makes the ground read as
            # faceted patches of mud, moss and scree rather than one flat green.
            "material_index": [material_names.index(name) for name in terrain.materials],
        },
        "water": build_water(),
        "zones": [{"name": n, "centre": [c[0], c[1]], "radius": r} for n, c, r in ZONES],
        "roads": [{"name": n, "points": [[p[0], p[1]] for p in pts], "half": h} for n, pts, h in ROADS],
        "props": placer.props,
        "markers": markers,
        "lights": lights,
    }

    OUT.parent.mkdir(parents=True, exist_ok=True)
    with OUT.open("w", encoding="utf-8") as handle:
        json.dump(layout, handle, separators=(",", ":"))
        handle.write("\n")

    kits: dict[str, int] = {}
    for prop in placer.props:
        kits[prop["kit"]] = kits.get(prop["kit"], 0) + 1
    print(f"\n  props {len(placer.props)} across {len(kits)} kits: "
          + ", ".join(f"{k} {v}" for k, v in sorted(kits.items())))
    print(f"  markers {len(markers)}, lights {len(lights)}, water bodies {len(layout['water'])}")
    print("  rejections: " + ", ".join(f"{k} {v}" for k, v in sorted(placer.rejects.items())))
    print(f"  wrote {OUT.relative_to(ROOT)} ({OUT.stat().st_size / 1024:.0f} KB)")

    if problems:
        print(f"\nHOLLOWMERE_VALIDATE FAIL ({len(problems)})")
        for problem in problems[:30]:
            print(f"  {problem}")
        raise SystemExit(1)
    print("HOLLOWMERE_VALIDATE PASS")


if __name__ == "__main__":
    main()
