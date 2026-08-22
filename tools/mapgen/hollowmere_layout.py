"""Author `hollowmere` — MIRE's main map.

Run with plain python3 (no Blender, no Godot):

    python3 tools/mapgen/hollowmere_layout.py

It writes `world/gen/layouts/hollowmere.json` and validates the result. One consumer reads it:

    world/gen/authored_world.gd  -> terrain, water, props, colliders, lights, markers

## Size, and why it changed

The first cut of this map was 356 m across. That is a beautiful number on a contour plot and a bad
one to walk: the density that survived the placement rules worked out to one authored prop per
250 m², so between any two landmarks was two minutes of empty hillside. This cut is **192 m
across** — a quarter of the area — and carries roughly twice as many props, so the same walk is
thirty seconds of continuously interesting ground. Nothing else about the pipeline changed.

At this size a single baked mesh would still be the wrong shape for the renderer, so the map keeps
its **one consumer instead of two**: `authored_world.gd` builds the visuals *and* the collision from
this file at load, which means the two cannot drift apart even in principle. Props are instanced
through `MultiMeshInstance3D` grouped by chunk, so the renderer culls a hillside in one test.

## What it authors

A drowned valley. A river comes out of the northern rim, cuts a gorge, and feeds the mere in the
south-east. A granite plateau stands over the north-west with an escarpment you climb by two ramps;
a worked-out quarry is cut into its foot. The hold — the only defensible, built-up ground — sits
just west of centre with every crafting station in it. West is old forest and a ruined village;
south is fen and the Wellspring; east is moor, a watchtower and the extraction yard.

**North-east is the Blight**: ash ground, dead trees, mire crystal and tendril, a re-corrupting
wellspring, and the crawler nests. It is the one region of the map that is actively hostile, it is
visible from the hold's north road, and everything about it — ground material, flora palette, fog —
says so before a crawler does.

Coordinates are GODOT coordinates everywhere in this file and in the JSON: +X east, +Y up, +Z south.

## Rotation, because it was wrong for a whole map cut

`Basis(Vector3.UP, yaw)` maps a model's local +X to **(cos yaw, 0, -sin yaw)** — the Z term is
negated, because a right-handed rotation about +Y turns +X toward -Z. So the yaw that lays an asset
along a world direction `(dx, dz)` is `atan2(-dz, dx)`, not `atan2(dz, dx)`. The previous cut used
the latter everywhere, which mirrors every directional prop across the axis it was meant to follow:
the bridge railings ran diagonally across their own decks. `yaw_along` is now the only way this file
computes a yaw from a direction, so the mistake cannot be made one call site at a time.

## Placement rules the validator enforces, so nobody has to eyeball a render

  * **nothing floats** — every grounded prop sits at the LOWEST surface height under its own
    footprint, sampled through the same triangulation the runtime meshes, so a boulder on a slope
    beds into the hill instead of balancing on its uphill edge
  * nothing interpenetrates — solid props keep their measured footprints apart
  * stacked pieces use measured catalog heights, and a course is never placed over a missing one
  * roads stay walkable — no solid prop inside a road corridor
  * **every landmark is reachable on foot from spawn**, proved by a slope-limited flood fill over
    the terrain grid, not by looking at it
  * nothing is placed in water it would drown in, and nothing stands on a slope it would slide off
  * everything is inside the boundary ring
  * **every asset in every placeable kit appears somewhere**, or the run fails and names the ones
    that do not — a kit asset nobody placed is an asset nobody paid for
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
BOUND = 86.0
RING_OUTER = 96.0

# Terrain grid. 2 m cells over 192 m gives 97x97 samples and 18,432 triangles —
# one ordinary mesh, and fine enough that the water's edge follows the shore
# rather than staircasing along it.
CELL = 2.0
HALF_SPAN = RING_OUTER
NX = int(round(HALF_SPAN * 2.0 / CELL)) + 1
NZ = NX
ORIGIN = (-HALF_SPAN, -HALF_SPAN)

WATER_LAKE = -3.2
WATER_FEN = -1.2
CHUNK = 32.0

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
    "blight": {"color": [0.146, 0.104, 0.152, 1.0], "roughness": 0.92},
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


def yaw_along(dx: float, dz: float) -> float:
    """The yaw that lays an asset's local +X along the world direction (dx, dz).

    See the module docstring: `Basis(Vector3.UP, yaw)` sends +X to (cos, 0, -sin),
    so the Z term is negated. Every yaw derived from a direction goes through here.
    """
    return math.atan2(-dz, dx)


#: The river, out of the northern rim and down to the mere, as
#: (x, z, bed_height, surface_height).
RIVER = [
    (-30.0, -94.0, 12.5, 14.2),
    (-24.0, -70.0, 8.0, 9.4),
    (-16.0, -46.0, 3.6, 4.8),
    (-6.0, -24.0, 0.4, 1.5),
    (6.0, -2.0, -1.6, -0.6),
    (20.0, 18.0, -2.6, -1.8),
    (30.0, 36.0, -3.1, -2.6),
    (37.0, 46.0, -3.4, WATER_LAKE),
]
RIVER_HALF_WIDTH = 6.0
GORGE_Z = (-58.0, -28.0)

#: The mere itself. It sits clear of the fen so the two water surfaces never
#: stack — two transparent sheets 2 m apart over the same ground is the single
#: ugliest thing water can do, and the previous cut did it over the whole lake.
LAKE_CENTRE = (38.0, 46.0)
LAKE_RADIUS = 24.0

#: The fen, south-west of the mere and not touching it.
FEN_MIN = (-58.0, 40.0)
FEN_MAX = (12.0, 84.0)

#: The granite plateau over the north-west, and the two ramps that are the only
#: ways up it. A cliff with no way up is scenery; a cliff with one way up is a
#: choke point; two is a place.
PLATEAU_CENTRE = (-48.0, -42.0)
PLATEAU_RADIUS = 26.0
PLATEAU_HEIGHT = 12.0
#: A ramp is only a ramp if you can walk it. `smoothstep` along its length peaks
#: at 1.5x its average gradient in the middle, which turned a 26-degree mean into
#: a 39-degree wall halfway up and left the plateau unreachable — so the profile
#: is linear and the runs are long enough that the mean IS the gradient.
RAMPS = [
    ((-18.0, -14.0), (-42.0, -38.0), 8.0),
    ((-60.0, 2.0), (-52.0, -32.0), 7.5),
]

#: The Blight. Its own bowl in the north-east, dropped below the moor around it so
#: you look down into it from the road rather than wandering into it by accident.
BLIGHT_CENTRE = (38.0, -56.0)
BLIGHT_RADIUS = 22.0

#: Flat ground the layout depends on. Anything authored against level ground gets
#: its own pad, blended out so the mask never shows as a crease.
PADS = [
    ("SpawnHold", -6.0, 10.0, 21.0, 2.6, 1.0),
    ("RuinedVillage", -56.0, 20.0, 18.0, 1.8, 0.75),
    ("Quarry", -30.0, -24.0, 16.0, 3.2, 0.6),
    ("StoneCircle", 54.0, -32.0, 14.0, 6.2, 0.85),
    ("Watchtower", 69.0, -4.0, 12.0, 4.4, 0.8),
    ("LumberCamp", -48.0, 50.0, 13.0, 1.7, 0.75),
    ("HuntersCamp", -6.0, -54.0, 12.0, 5.8, 0.8),
    ("WellspringVale", 4.0, 64.0, 16.0, -0.3, 0.7),
    ("ExtractionYard", 62.0, 29.0, 14.0, 1.4, 0.8),
    ("Blight", 38.0, -56.0, 15.0, 4.2, 0.7),
]

#: Roads, as polylines with a half-width. They connect every landmark to the hold.
#: The shape is a wheel: five spokes out of the hold, and a rim road linking the
#: north and east ends so the far side of the map is a loop instead of a dead end.
ROADS = [
    ("Road_Village", [(-6.0, 10.0), (-30.0, 14.0), (-55.0, 19.0)], 3.4),
    ("Road_Lumber", [(-55.0, 19.0), (-53.0, 34.0), (-48.0, 49.0)], 2.8),
    ("Road_Quarry", [(-6.0, 10.0), (-17.0, -5.0), (-29.0, -23.0)], 3.2),
    ("Road_North", [(-29.0, -23.0), (-18.0, -41.0), (-6.0, -53.0)], 3.0),
    ("Road_Blight", [(-6.0, -53.0), (14.0, -57.0), (34.0, -54.0)], 2.8),
    ("Road_Moor", [(34.0, -54.0), (46.0, -43.0), (54.0, -32.0)], 2.8),
    ("Road_Ridge", [(54.0, -32.0), (64.0, -19.0), (69.0, -5.0)], 2.6),
    ("Road_East", [(-6.0, 10.0), (18.0, 6.0), (44.0, 1.0), (68.0, -4.0)], 3.6),
    ("Road_Yard", [(44.0, 1.0), (55.0, 15.0), (62.0, 28.0)], 3.0),
    ("Road_Vale", [(-6.0, 10.0), (0.0, 34.0), (4.0, 62.0)], 3.0),
    ("Road_Shore", [(4.0, 62.0), (22.0, 70.0), (38.0, 72.0)], 2.6),
]

#: Ground the scatter must leave open. A camp is a clearing — that is most of what
#: makes it read as a camp rather than as props in a wood — and the spawn search
#: needs somewhere inside the hold that no boulder got to first. Authored pieces
#: pass `force=True` and are unaffected; only the scatter is held back.
CLEARINGS = [
    (-6.0, 10.0, 15.0),    # the hold
    (-6.0, -54.0, 8.0),    # hunters camp
    (-48.0, 50.0, 9.0),    # lumber camp
    (62.0, 29.0, 9.5),     # extraction yard
    (4.0, 64.0, 10.0),     # the Wellspring
    (54.0, -32.0, 9.0),    # stone circle
    (69.0, -4.0, 8.5),     # watchtower
    (-30.0, -24.0, 5.0),   # quarry floor
    (-56.0, 20.0, 8.0),    # ruined village
    (38.0, -56.0, 6.0),    # the Blight's heart
]


def in_clearing(x: float, z: float) -> bool:
    return any(math.hypot(x - cx, z - cz) <= radius for cx, cz, radius in CLEARINGS)


#: Where the river must be bridged. **Computed, not hand-placed.** The first cut
#: of this file listed two crossings by eye and both of them missed the river —
#: the roads actually cross it 12 m and 22 m away from where the bridges stood, so
#: the map was two islands with a pair of decorative jetties on it. A bridge has to
#: come from the same data as the road and the river, or it is a guess that ages.
BRIDGE_HALF_WIDTH = 9.0
BRIDGE_HALF_DEPTH = 2.4
BRIDGE_APPROACH = 13.0


def find_crossings() -> list[tuple[str, tuple[float, float], tuple[float, float]]]:
    """Every point where a road centreline enters the river channel.

    Returns (name, centre, unit direction along the road) so the deck can be laid
    along the road rather than along an axis.
    """
    runs: list[tuple[str, list[tuple[float, float]]]] = []
    for road_name, points, _ in ROADS:
        inside: list[tuple[float, float]] = []
        for index in range(len(points) - 1):
            ax, az = points[index]
            bx, bz = points[index + 1]
            steps = max(2, int(math.hypot(bx - ax, bz - az) / 1.0))
            for step in range(steps + 1):
                t = step / steps
                x, z = ax + (bx - ax) * t, az + (bz - az) * t
                distance, _, _ = river_at(x, z)
                if distance <= RIVER_HALF_WIDTH + 3.0:
                    inside.append((x, z))
                elif inside:
                    runs.append((road_name, inside))
                    inside = []
        if inside:
            runs.append((road_name, inside))

    bridges = []
    for index, (road_name, run) in enumerate(runs):
        cx = sum(p[0] for p in run) / len(run)
        cz = sum(p[1] for p in run) / len(run)
        ax, az = run[0]
        bx, bz = run[-1]
        length = math.hypot(bx - ax, bz - az)
        direction = ((bx - ax) / length, (bz - az) / length) if length > 1e-6 else (1.0, 0.0)
        bridges.append((f"Bridge_{road_name.replace('Road_', '')}_{index + 1}", (cx, cz), direction))
    return bridges


#: Zones. `centre`/`radius` drive flora and fog; the flood fill proves each is
#: reachable. Weights are consumed by the prop scatter below. Every name here needs
#: a palette in `world/gen/undergrowth.gd`, or its ground grows nothing.
#: (name, centre, disc radius, pull). Zones tile the map: every point belongs to
#: the zone minimising `distance - pull`, and `pull` is what lets a forest own
#: forest-sized ground while a quarry owns a pocket. Plain nearest-centre made
#: zone area a function of how close the neighbouring centres happened to be, so
#: DeepForest — the biggest wood on the map — ended up with 600 m² and eight trees
#: in it. Positive pull reaches further, negative yields to its neighbours.
#: `world/gen/undergrowth.gd` reads the same three numbers out of the layout, so
#: the flora on a patch of ground always matches the props standing in it.
ZONES = [
    ("SpawnHold", (-6.0, 10.0), 26.0, -2.0),
    ("WestWood", (-48.0, 4.0), 40.0, 5.0),
    ("RuinedVillage", (-60.0, 26.0), 20.0, -3.0),
    ("DeepForest", (-32.0, -36.0), 38.0, 6.0),
    ("Plateau", (-52.0, -46.0), 34.0, 1.0),
    ("Quarry", (-30.0, -18.0), 16.0, 0.0),
    ("Gorge", (-8.0, -36.0), 22.0, 1.0),
    ("Blight", (39.0, -57.0), 28.0, 2.0),
    ("StoneMoor", (56.0, -28.0), 30.0, 1.0),
    ("EastReach", (66.0, 2.0), 30.0, -1.0),
    ("MereShore", (37.0, 45.0), 34.0, 4.0),
    ("SouthMarsh", (-16.0, 60.0), 32.0, 4.0),
    ("LumberEdge", (-50.0, 46.0), 22.0, -2.0),
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


def river_at(x: float, z: float) -> tuple[float, float, float]:
    """Nearest distance to the river channel, the bed height, and the water surface."""
    best_distance, best_bed, best_surface = 1e9, 0.0, 0.0
    for index in range(len(RIVER) - 1):
        ax, az, a_bed, a_top = RIVER[index]
        bx, bz, b_bed, b_top = RIVER[index + 1]
        distance, t = _segment_distance(x, z, ax, az, bx, bz)
        if distance < best_distance:
            best_distance = distance
            best_bed = a_bed + (b_bed - a_bed) * t
            best_surface = a_top + (b_top - a_top) * t
    return best_distance, best_bed, best_surface


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


def water_level_at(x: float, z: float) -> float | None:
    """The surface level of whatever body covers this point, or None.

    This is the SAME union-by-highest rule `authored_world.gd` draws with, so a
    prop can never be rejected for standing in water that is not there, or kept in
    water that is. The two used to disagree, and the disagreement is invisible
    until a boulder is standing in the mere.
    """
    level: float | None = None
    if math.hypot(x - LAKE_CENTRE[0], z - LAKE_CENTRE[1]) <= LAKE_RADIUS:
        level = WATER_LAKE
    if FEN_MIN[0] <= x <= FEN_MAX[0] and FEN_MIN[1] <= z <= FEN_MAX[1]:
        level = WATER_FEN if level is None else max(level, WATER_FEN)
    distance, _, surface = river_at(x, z)
    if distance <= RIVER_HALF_WIDTH + 1.5:
        level = surface if level is None else max(level, surface)
    return level


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
        rolling = self.shape.fbm(x / 62.0, z / 62.0, octaves=5) * 8.0
        texture = self.detail.fbm(x / 18.0, z / 18.0, octaves=3) * 1.6
        return rolling + texture

    def _plateau(self, x: float, z: float) -> float:
        distance = math.hypot(x - PLATEAU_CENTRE[0], z - PLATEAU_CENTRE[1])
        lift = 1.0 - smoothstep(PLATEAU_RADIUS - 12.0, PLATEAU_RADIUS + 4.0, distance)
        crest = self.rock.ridged(x / 34.0, z / 34.0, octaves=4) * 3.4
        return (PLATEAU_HEIGHT + crest) * lift

    def _ramps(self, x: float, z: float, height: float) -> float:
        """Cut two walkable ramps into the escarpment.

        Without them the plateau is decoration: `CharacterBody3D` cannot step up a
        cliff, and a place you can only look at is not a place.
        """
        for (ax, az), (bx, bz), half in RAMPS:
            distance, t = _segment_distance(x, z, ax, az, bx, bz)
            if distance > half + 6.0:
                continue
            low = self._base(ax, az) + self._plateau(ax, az) * 0.05
            high = PLATEAU_HEIGHT + self._base(bx, bz) * 0.3
            target = low + (high - low) * t
            blend = 1.0 - smoothstep(half, half + 6.0, distance)
            height = height + (target - height) * blend
        return height

    def _river(self, x: float, z: float, height: float) -> float:
        distance, bed, _ = river_at(x, z)
        if distance > 34.0:
            return height
        channel = 1.0 - smoothstep(RIVER_HALF_WIDTH, RIVER_HALF_WIDTH + 4.0, distance)
        valley = 1.0 - smoothstep(RIVER_HALF_WIDTH + 4.0, 32.0, distance)
        # The gorge: the same river, but the walls stand instead of sloping.
        gorge = smoothstep(GORGE_Z[0] - 10.0, GORGE_Z[0], z) * (1.0 - smoothstep(GORGE_Z[1], GORGE_Z[1] + 10.0, z))
        bank = bed + 5.5 + gorge * 7.0
        height = height + (bank - height) * valley * (0.55 + gorge * 0.35)
        return height + (bed - height) * channel

    def _lake(self, x: float, z: float, height: float) -> float:
        distance = math.hypot(x - LAKE_CENTRE[0], z - LAKE_CENTRE[1])
        if distance > LAKE_RADIUS + 22.0:
            return height
        wobble = self.detail.at(x / 24.0, z / 24.0) * 4.0
        edge = LAKE_RADIUS + wobble
        basin = 1.0 - smoothstep(edge - 18.0, edge + 5.0, distance)
        floor = WATER_LAKE - 3.6 + self.detail.fbm(x / 16.0, z / 16.0, octaves=2) * 1.2
        return height + (floor - height) * basin

    def _fen(self, x: float, z: float, height: float) -> float:
        """The southern fen: level, wet, and shallow enough to wade everywhere.

        Sunk far enough under its own water level that it reads as *one* wet place
        with islands in it. The first cut sat 0.28 m under the surface with 0.85 m
        of noise on top, so half of it came out above the water and the fen drew as
        a scatter of unrelated puddles — which is what a marsh looks like when the
        noise is bigger than the depth.
        """
        flat = smoothstep(32.0, 50.0, z) * (1.0 - smoothstep(38.0, 60.0, abs(x + 22.0)))
        target = WATER_FEN - 0.62 + self.detail.fbm(x / 15.0, z / 15.0, octaves=2) * 0.62
        return height + (target - height) * flat * 0.95

    def _blight(self, x: float, z: float, height: float) -> float:
        """A shallow bowl for the Blight, so it reads as somewhere you descend into."""
        distance = math.hypot(x - BLIGHT_CENTRE[0], z - BLIGHT_CENTRE[1])
        if distance > BLIGHT_RADIUS + 12.0:
            return height
        bowl = 1.0 - smoothstep(BLIGHT_RADIUS - 10.0, BLIGHT_RADIUS + 8.0, distance)
        rim = smoothstep(BLIGHT_RADIUS - 4.0, BLIGHT_RADIUS + 7.0, distance) * \
            (1.0 - smoothstep(BLIGHT_RADIUS + 7.0, BLIGHT_RADIUS + 15.0, distance))
        floor = 4.2 + self.detail.fbm(x / 15.0, z / 15.0, octaves=2) * 1.1
        height = height + (floor - height) * bowl * 0.9
        return height + rim * 2.6

    def _ring(self, x: float, z: float, height: float) -> float:
        """A rising boundary ridge, so the map closes instead of ending."""
        distance = math.hypot(x, z)
        rise = smoothstep(BOUND - 10.0, RING_OUTER, distance)
        crest = 20.0 + self.rock.ridged(x / 28.0, z / 28.0, octaves=3) * 9.0
        return height + crest * rise * rise

    def _pads_and_roads(self, x: float, z: float, height: float) -> float:
        for _, cx, cz, radius, level, strength in PADS:
            distance = math.hypot(x - cx, z - cz)
            blend = (1.0 - smoothstep(radius * 0.62, radius * 1.35, distance)) * strength
            height = height + (level - height) * blend
        distance, half = road_distance(x, z)
        if distance < half + 11.0:
            smoothed = self.shape.fbm(x / 110.0, z / 110.0, octaves=2) * 3.4
            near = 1.0 - smoothstep(half, half + 11.0, distance)
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
                height = self._fen(x, z, height)
                height = self._blight(x, z, height)
                height = self._pads_and_roads(x, z, height)
                height = self._ring(x, z, height)
                self.heights.append(round(height, 3))
        self._assign_materials()

    # -- reading ------------------------------------------------------------

    def height_at(self, x: float, z: float) -> float:
        """The height of the terrain SURFACE — the triangle, not a bilinear guess.

        `authored_world.gd` meshes each quad as (a,b,c) and (a,c,d) with a at the
        low corner and c at the high one, so the surface a player stands on is two
        flat triangles per cell. A bilinear sample of the same four corners differs
        from that surface by up to a quarter of the cell's height range — around
        0.5 m on the escarpment — and every one of those centimetres is a prop
        hovering or half-buried. Sampling the actual triangle is what makes
        "nothing floats" a property of the map rather than of the tolerance.
        """
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
        if tz <= tx:  # triangle (a, b, c) = (0,0), (1,0), (1,1)
            return h00 + (h10 - h00) * tx + (h11 - h10) * tz
        return h00 + (h11 - h01) * tx + (h01 - h00) * tz  # triangle (a, c, d)

    def ground_for(self, x: float, z: float, radius: float) -> float:
        """The height to place a prop of this radius at: the LOWEST surface under it.

        A prop is a rigid object sitting on ground that is not flat. Placing it at
        the height under its pivot leaves the downhill half of its base in the air,
        which is most of what "things are floating" turns out to mean once you stop
        looking at the obvious cases. Taking the minimum beds the uphill side into
        the slope instead, which nobody can see and nobody trips over.
        """
        lowest = self.height_at(x, z)
        if radius <= 0.05:
            return lowest
        for ring_scale in (0.62, 1.0):
            span = radius * ring_scale
            for index in range(8):
                angle = index * math.tau / 8.0
                lowest = min(lowest, self.height_at(x + math.cos(angle) * span,
                                                   z + math.sin(angle) * span))
        return lowest

    def slope_deg_at(self, x: float, z: float) -> float:
        step = CELL * 0.75
        dx = self.height_at(x + step, z) - self.height_at(x - step, z)
        dz = self.height_at(x, z + step) - self.height_at(x, z - step)
        return math.degrees(math.atan(math.hypot(dx, dz) / (2.0 * step)))

    def water_at(self, x: float, z: float) -> float | None:
        """Water surface level at a point, or None for dry land."""
        level = water_level_at(x, z)
        if level is None or self.height_at(x, z) >= level:
            return None
        return level

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
        blight = math.hypot(x - BLIGHT_CENTRE[0], z - BLIGHT_CENTRE[1])
        # The Blight before anything else: it is the one region whose ground is
        # supposed to announce itself from the ridge above it.
        if blight < BLIGHT_RADIUS * 0.55:
            return "blight"
        if blight < BLIGHT_RADIUS + 4.0 and slope < 30.0:
            return "ash"
        if math.hypot(x, z) > BOUND - 4.0:
            return "rock" if slope > 26.0 else "scree"
        if slope > 34.0:
            return "rock"
        if height > PLATEAU_HEIGHT * 0.62:
            return "scree" if slope > 22.0 else "ridge"
        if self.depth_at(x, z) > 0.05:
            return "mud"
        if height < WATER_LAKE + 1.4 and \
                math.hypot(x - LAKE_CENTRE[0], z - LAKE_CENTRE[1]) < LAKE_RADIUS + 12.0:
            return "sand"
        if z > 36.0 and height < WATER_FEN + 1.8:
            return "marsh"
        forest = self.shape.fbm(x / 48.0 + 11.0, z / 48.0 - 7.0, octaves=3)
        if forest > 0.06 and slope < 24.0:
            return "forest_floor"
        return "meadow" if forest < -0.14 else "grass"


# ---------------------------------------------------------------------------
# Asset catalogs — real measured footprints, so clearance is computed not guessed
# ---------------------------------------------------------------------------

#: Kits whose assets are held, worn, spawned or swapped by a system rather than
#: placed on the ground. Everything NOT covered here must appear in the map, and
#: `validate` fails the run naming whatever does not.
RUNTIME_ONLY_KITS = {"icons", "tools_weapons"}
RUNTIME_ONLY_ASSETS = {
    # EnemyWorld spawns crawlers; Enemy emits the fragments on death.
    "enemy_crawler", "enemy_crawler_fragment_leg", "enemy_crawler_fragment_shell",
    # Every chest's OPEN state belongs to `Chest._refresh_visual()`, which swaps it in the moment
    # the replicated `opened` flag flips. Scattering one as scenery puts a permanently-open,
    # permanently-empty container on the map — a chest that promises a roll it will never make, and
    # the exact read the tier ladder exists to keep honest. The closed meshes still place normally.
    "loot_chest_crate_open", "loot_chest_small_open", "loot_chest_reinforced_open",
    "loot_chest_warded_open", "loot_chest_gilded_open", "loot_chest_wellspring_open",
}
#: Placed by `world/gen/undergrowth.gd` at load, not by this file — one entry per
#: family named in its `ZONE_PALETTES`. There are tens of thousands of them and
#: they are scattered by raycast against the real collision, which is a better
#: answer for ground cover than anything a layout file can do.
#:
#: The division of labour is the point: **this file places what you navigate by**
#: — trees, rocks, logs, harvestables, ruins — and undergrowth fills between them.
#: Authoring grass here as well spent the scatter's whole budget on plants that
#: were about to be covered by 26,000 better ones, and crowded out the trees.
UNDERGROWTH_FAMILIES = {
    "grass_short", "grass_dry", "grass_tussock", "leaf_litter", "clover_patch",
    "flowers_creeping", "flowers_meadow", "flowers_bog", "flowers_tall",
    "moss_patch", "plant_creeper", "plant_broadleaf", "plant_dock", "nettle",
    "bracken", "sedge", "marsh_grass", "lily_pad",
}


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


def dimensions(kit: str, asset: str) -> tuple[float, float, float]:
    entry = CATALOGS.get(kit, {}).get(asset)
    if entry is None:
        raise KeyError(f"{kit}/{asset} is not in any catalog")
    return (float(entry.get("width_m", 1.0)), float(entry.get("depth_m", 1.0)),
            float(entry.get("height_m", 1.0)))


def asset_height(kit: str, asset: str) -> float:
    return dimensions(kit, asset)[2]


#: Assets whose collision must be a BOX, not the default cylinder.
#:
#: A cylinder is a fine stand-in for a tree or a boulder and a disaster for a wall.
#: A 4.2 m plank wall became a disc of radius 1.23 m: it does not cover the wall it
#: represents, it bulges two metres out of both faces, and around a cabin the four
#: discs meet in the middle and seal the building shut. That is what trapped the
#: player inside the hold's shack.
BOX_COLLIDERS = {
    "wood_foundation", "wood_floor", "stone_foundation", "stone_floor",
    "wood_wall_solid", "wood_wall_window", "stone_wall_solid", "stone_wall_window",
    "wood_half_wall", "stone_half_wall", "wood_beam", "wood_post", "wood_railing",
    "fence_straight", "fence_corner", "fence_post", "stone_pillar",
    "wood_stairs", "stone_stairs", "ruin_wall_a", "ruin_wall_b", "ruin_wall_c",
    "ruin_wall_d", "ruin_arch_a", "ruin_arch_b",
}
#: Walls with a doorway. A single box would brick up the opening the model has, so
#: these emit two jambs and leave the gap the art already drew.
DOOR_WALLS = {"wood_wall_door", "stone_wall_door"}
DOOR_WIDTH = 1.55
#: Things you are meant to walk through. The gate leaves are modelled swung open.
NO_COLLIDERS = {"fence_gate", "wood_roof_slope", "wood_roof_corner"}


def box_collision(kit: str, asset: str, scale: float) -> list[dict] | None:
    width, depth, height = (value * scale for value in dimensions(kit, asset))
    if asset in DOOR_WALLS:
        jamb = max(0.2, (width - DOOR_WIDTH) * 0.5)
        return [
            {"t": "box", "size": [round(jamb, 3), round(height, 3), round(depth, 3)],
             "off": [round(-(width - jamb) * 0.5, 3), round(height * 0.5, 3), 0.0]},
            {"t": "box", "size": [round(jamb, 3), round(height, 3), round(depth, 3)],
             "off": [round((width - jamb) * 0.5, 3), round(height * 0.5, 3), 0.0]},
        ]
    if asset in ("ruin_arch_a", "ruin_arch_b"):
        # Same reasoning as a door wall: the arch's opening is the point of it.
        jamb = 0.62
        return [
            {"t": "box", "size": [round(jamb, 3), round(height, 3), round(depth, 3)],
             "off": [round(-(width - jamb) * 0.5, 3), round(height * 0.5, 3), 0.0]},
            {"t": "box", "size": [round(jamb, 3), round(height, 3), round(depth, 3)],
             "off": [round((width - jamb) * 0.5, 3), round(height * 0.5, 3), 0.0]},
        ]
    return [{"t": "box", "size": [round(width, 3), round(height, 3), round(depth, 3)],
             "off": [0.0, round(height * 0.5, 3), 0.0]}]


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
        self._grid: dict[tuple[int, int], list[tuple[float, float, float, float]]] = {}
        self.rejects: dict[str, int] = {}
        self.used: set[str] = set()
        self._bags: dict[tuple[str, str], list[str]] = {}

    def _reject(self, reason: str) -> None:
        self.rejects[reason] = self.rejects.get(reason, 0) + 1

    def _cells(self, x: float, z: float, radius: float):
        step = 8.0
        x0, x1 = int((x - radius) // step), int((x + radius) // step)
        z0, z1 = int((z - radius) // step), int((z + radius) // step)
        for cx in range(x0, x1 + 1):
            for cz in range(z0, z1 + 1):
                yield (cx, cz)

    def clear(self, x: float, z: float, radius: float, *, small: bool = False) -> bool:
        """Is there room here? `small` asks against trunks rather than canopies.

        A pine's keep-out radius is its canopy, which is what another pine has to
        respect. A fern does not: grass growing at the foot of a tree is the
        correct picture, and testing it against the canopy sterilises 24 m² of
        forest floor per tree — which is why the wood used to have bare ground
        under every trunk and the scatter reported 15,000 crowding rejections.
        """
        for cell in self._cells(x, z, radius):
            for ox, oz, oradius, otrunk in self._grid.get(cell, ()):
                against = otrunk if small else oradius
                if math.hypot(x - ox, z - oz) < radius + against:
                    return False
        return True

    def _occupy(self, x: float, z: float, radius: float, trunk: float) -> None:
        for cell in self._cells(x, z, radius):
            self._grid.setdefault(cell, []).append((x, z, radius, trunk))

    def place(self, kit: str, asset: str, zone: str, x: float, z: float, *,
              solid: bool = True, road_ok: bool = False, spacing: float = 0.0,
              yaw: float | None = None, scale: float = 1.0, note: str = "",
              max_slope: float = MAX_PROP_SLOPE_DEG, max_depth: float = 0.0,
              y_offset: float = 0.0, force: bool = False, harvestable: bool = False,
              level: float | None = None, col: list[dict] | None = None) -> dict | None:
        """Place one prop. Returns the record, or None if the ground refused it.

        `y_offset` is measured from the ground the prop beds into, so a piece
        stacked on another piece asks for that piece's measured height rather than
        a number that looked right when the art was a different size. `level`
        overrides the ground entirely: a building is one rigid object, so every
        piece of it is placed against ONE base height rather than each bedding
        into its own patch of hillside — which is how a wall ends up half a metre
        below the floor it is holding up.
        """
        radius, height = footprint(kit, asset)
        radius *= scale
        height *= scale
        # `spacing` is the separation between two of these, so half of it is the
        # keep-out radius. Using the whole number doubles every gap in the table:
        # two trees asking for 6 m ended up 12 m apart, which is the difference
        # between a wood and an orchard, and is most of why the previous cut
        # rejected 5,190 candidates for crowding.
        keep_out = max(radius, spacing * 0.5)

        if math.hypot(x, z) > BOUND - 2.0:
            self._reject("outside the boundary ring")
            return None
        if not force:
            if in_clearing(x, z):
                self._reject("inside a clearing")
                return None
            if self.terrain.slope_deg_at(x, z) > max_slope:
                self._reject("ground too steep")
                return None
            if self.terrain.depth_at(x, z) > max_depth:
                self._reject("under water")
                return None
            if not self.clear(x, z, keep_out, small=not solid):
                self._reject("too close to another prop")
                return None
            if solid and not road_ok:
                distance, half = road_distance(x, z)
                if distance < half + radius:
                    self._reject("blocking a road")
                    return None

        y = (self.terrain.ground_for(x, z, radius) if level is None else level) + y_offset
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
        if harvestable:
            # AuthoredWorld gives these their own node instead of a MultiMesh slot,
            # because HarvestWorld has to hide one tree's visual when it is felled
            # and a MultiMesh instance is not a thing you can hide.
            record["harvestable"] = True
        if asset in NO_COLLIDERS:
            pass
        elif col is not None:
            record["cols"] = col
        elif asset in BOX_COLLIDERS or asset in DOOR_WALLS:
            record["cols"] = box_collision(kit, asset, scale)
        elif solid:
            record["cols"] = [{
                "t": "cyl",
                "r": round(max(0.24, radius * 0.62), 3),
                "h": round(max(0.5, height), 3),
                "y": round(max(0.5, height) * 0.5, 3),
            }]
        self.props.append(record)
        self.used.add(asset)
        # What a small plant has to clear: the trunk, not the crown.
        self._occupy(x, z, keep_out, min(keep_out, max(0.2, radius * 0.5)))
        return record

    def stack(self, kit: str, zone: str, x: float, z: float, courses: list[str], *,
              yaw: float = 0.0, note: str = "", solid_from: int = 0,
              level: float | None = None) -> int:
        """Place courses one on top of another using their MEASURED heights.

        Two rules, both learned from the previous cut's village: the offset for
        course N is the sum of the real heights below it — `ruin_column` alone
        varies from 2.74 m to 3.53 m, so a fixed 3.6 m step left gaps of up to
        0.86 m under every second drum — and if a course cannot be placed, the
        courses above it are abandoned rather than left hanging over the hole.
        """
        offset = 0.0
        placed = 0
        for index, asset in enumerate(courses):
            record = self.place(kit, asset, zone, x, z, yaw=yaw, y_offset=offset,
                                solid=index >= solid_from, note=note, force=True, level=level)
            if record is None:
                break
            offset += asset_height(kit, asset)
            placed += 1
        return placed

    def variant(self, kit: str, prefix: str) -> str:
        """One asset from a family, drawn from a shuffled bag rather than at random.

        Independent draws leave holes: with four variants and forty draws the
        chance some variant never comes up is small but not zero, and across
        eighty families it happens every run — the previous cut shipped with
        eleven assets nobody had ever seen in the game. A bag refilled and
        reshuffled when it empties keeps the sequence irregular and the coverage
        total.
        """
        key = (kit, prefix)
        bag = self._bags.get(key)
        if not bag:
            options = names(kit, prefix)
            if not options:
                return ""
            bag = list(options)
            self.rng.shuffle(bag)
            self._bags[key] = bag
        return bag.pop()

    def return_variant(self, kit: str, prefix: str, asset: str) -> None:
        """Put back a variant whose candidate the ground refused.

        Drawing from a bag only guarantees coverage if a draw means a placement.
        Rejections outnumber placements four to one here, so a variant spent on a
        candidate that landed in a lake is a variant that may never appear.
        """
        bag = self._bags.setdefault((kit, prefix), [])
        bag.insert(self.rng.randrange(len(bag) + 1), asset)

    def base_level(self, x: float, z: float, radius: float) -> float:
        """One ground height for a whole structure: the lowest under its footprint.

        A building placed piece-by-piece against the ground under each piece is not
        a building, it is a set of independent props that happen to be adjacent —
        on any slope its floor steps, its walls miss the floor, and its roof floats
        over the high corner. Everything in one structure shares this number.
        """
        return self.terrain.ground_for(x, z, radius)

    def scatter(self, zone: str, centre: tuple[float, float], radius: float,
                table: list[tuple], target: int, *, step: float = 1.8,
                retries: int = 2, max_slope: float = MAX_PROP_SLOPE_DEG,
                exclusive: bool = True) -> int:
        """Sow up to `target` props over the ground this zone owns.

        Stratified dart throwing: a lattice fine enough that no cell is bigger than
        the tightest spacing in the table, visited in random order, with a couple of
        jittered retries per cell, and stopped once `target` have landed.

        The lattice used to be sized as sqrt(target), which sounds reasonable and
        guarantees the opposite of what it promises: the step lands at roughly the
        spacing of the props being placed, so every prop blocks its own
        neighbourhood and the pass ends at a fraction of its target — DeepForest
        placed 48 of 543. Sizing the lattice by the SPACING and treating `target`
        as a stopping condition inverts that: the zone fills to the density asked
        for, and only stops early when the ground genuinely has no room left.

        Visiting in random order matters as much. In row-major order a pass that
        stops at its target has filled the north of the zone and left the south
        bare, and the seam is a straight line across the map.
        """
        weights = [entry[2] for entry in table]
        total = sum(weights)
        if total <= 0 or target <= 0:
            return 0
        side = max(2, int(math.ceil(radius * 2.0 / step)))
        cells = [(row, column) for row in range(side) for column in range(side)]
        self.rng.shuffle(cells)
        cell_span = (radius * 2.0) / side
        placed = 0
        for row, column in cells:
            if placed >= target:
                break
            for _attempt in range(retries + 1):
                x = centre[0] - radius + (column + self.rng.random()) * cell_span
                z = centre[1] - radius + (row + self.rng.random()) * cell_span
                if math.hypot(x - centre[0], z - centre[1]) > radius:
                    break
                if exclusive and _zone_at(x, z) != zone:
                    break
                roll = self.rng.uniform(0.0, total)
                chosen = table[-1]
                for entry in table:
                    roll -= entry[2]
                    if roll <= 0.0:
                        chosen = entry
                        break
                kit, prefix, _, spacing, solid = chosen[:5]
                asset = self.variant(kit, prefix)
                if not asset:
                    break
                extra = dict(chosen[5]) if len(chosen) > 5 else {}
                # Ground cover follows the ground; a boulder has to sit on it.
                extra.setdefault("max_slope", max_slope if solid else max(max_slope, 44.0))
                if self.place(kit, asset, zone, x, z, solid=solid, spacing=spacing,
                              scale=round(self.rng.uniform(0.88, 1.16), 3), **extra) is not None:
                    placed += 1
                    break
                self.return_variant(kit, prefix, asset)
        return placed



# ---------------------------------------------------------------------------
# What grows where
# ---------------------------------------------------------------------------
#
# (kit, name prefix, weight, spacing in metres, has collision[, extra kwargs])
#
# Trees and harvestables carry the weight they do because the previous cut put
# 1,415 props on 99,000 m² of playable ground — one per 70 m², of which four were
# harvestable — and the result was a valley you crossed without touching anything.
# `HARVEST` marks the three assets HarvestWorld turns into live Harvestable nodes;
# they are the reason to walk into a wood rather than around it.

HARVEST: dict = {"harvestable": True}

SCATTER: dict[str, list[tuple]] = {
    "SpawnHold": [
        ("environment", "tree_birch_", 16, 5.0, True),
        ("harvestables", "harvest_tree_intact", 20, 4.6, True, HARVEST),
        ("flora", "bush_round_", 16, 2.4, False),
        ("flora", "sapling_", 12, 2.2, False),
        ("environment", "boulder_", 10, 2.8, True),
        ("environment", "rock_cluster_", 10, 2.4, False),
        ("environment", "grass_meadow_", 12, 1.6, False),
        ("environment", "grass_tuft_", 10, 1.5, False),
        ("environment", "mushroom_cluster_", 6, 1.8, False),
    ],
    "WestWood": [
        ("environment", "tree_pine_", 34, 4.4, True),
        ("environment", "tree_crooked_", 16, 4.8, True),
        ("environment", "tree_birch_", 18, 4.4, True),
        ("harvestables", "harvest_tree_intact", 34, 4.2, True, HARVEST),
        ("harvestables", "harvest_tree_damaged_", 8, 5.0, True),
        ("flora", "bush_broadleaf_", 12, 2.6, False),
        ("environment", "fern_", 16, 1.6, False),
        ("environment", "fallen_log_", 8, 3.4, True),
        ("environment", "stump_", 8, 2.4, True),
        ("flora", "sapling_", 12, 2.2, False),
        ("environment", "mushroom_cluster_", 8, 1.8, False),
        ("environment", "root_cluster_", 8, 2.4, False),
    ],
    "RuinedVillage": [
        ("environment", "ruin_wall_", 10, 4.6, True),
        ("environment", "ruin_column_", 9, 3.4, True),
        ("environment", "tree_crooked_", 14, 5.0, True),
        ("environment", "grass_clump_", 18, 1.6, False),
        ("flora", "bush_thorn_", 12, 2.2, False),
        ("environment", "rock_cluster_", 12, 2.2, False),
        ("harvestables", "stone_node_intact", 14, 3.0, True, HARVEST),
        ("environment", "stump_", 7, 2.6, True),
        ("environment", "fern_", 10, 1.6, False),
    ],
    "DeepForest": [
        ("environment", "tree_pine_", 38, 4.2, True),
        ("environment", "tree_bare_", 12, 4.6, True),
        ("harvestables", "harvest_tree_intact", 40, 4.2, True, HARVEST),
        ("harvestables", "harvest_tree_damaged_", 9, 4.8, True),
        ("environment", "fern_", 18, 1.6, False),
        ("flora", "bush_round_", 12, 2.4, False),
        ("environment", "root_cluster_", 10, 2.4, False),
        ("environment", "fallen_log_", 9, 3.6, True),
        ("flora", "tree_snag_", 7, 5.0, True),
        ("environment", "boulder_", 8, 2.8, True),
        ("environment", "mushroom_cluster_", 10, 1.8, False),
        ("flora", "sapling_", 10, 2.2, False),
    ],
    "Plateau": [
        ("environment", "boulder_", 26, 3.2, True),
        ("environment", "rock_cluster_", 20, 2.4, False),
        ("environment", "standing_stone_", 8, 5.0, True),
        ("environment", "grass_seedhead_", 16, 1.6, False),
        ("flora", "bush_thorn_", 13, 2.2, False),
        ("environment", "tree_bare_", 10, 5.4, True),
        ("environment", "grass_tuft_", 12, 1.5, False),
        ("harvestables", "stone_node_intact", 17, 3.0, True, HARVEST),
        ("environment_additions", "mire_mossy_boulder", 7, 2.6, True),
    ],
    "Quarry": [
        ("environment", "rock_cluster_", 26, 2.0, False),
        ("environment", "boulder_", 20, 2.6, True),
        ("harvestables", "stone_node_intact", 30, 2.8, True, HARVEST),
        ("harvestables", "iron_node_intact", 22, 2.8, True, HARVEST),
        ("harvestables", "stone_node_depleted", 8, 2.8, True),
        ("harvestables", "iron_node_depleted", 7, 2.8, True),
        ("environment", "grass_clump_", 10, 1.6, False),
        ("pickups", "pickup_stone", 7, 1.2, False),
        ("pickups", "pickup_iron_ore", 5, 1.2, False),
    ],
    "Gorge": [
        ("environment", "boulder_", 26, 2.8, True),
        ("environment", "rock_cluster_", 22, 2.2, False),
        ("environment", "fern_", 14, 1.6, False),
        ("environment", "fallen_log_", 8, 3.6, True),
        ("flora", "bush_dead_", 10, 2.4, False),
        ("environment", "root_cluster_", 10, 2.2, False),
        ("environment_additions", "mire_mossy_boulder", 8, 2.6, True),
        ("environment", "reeds_", 10, 1.8, False, {"max_depth": 0.6}),
    ],
    "Blight": [
        ("environment", "tree_bare_", 24, 4.4, True),
        ("flora", "bush_dead_", 20, 2.2, False),
        ("flora", "tree_snag_", 16, 5.0, True),
        ("environment", "mire_tendril_", 18, 2.0, False),
        ("environment", "mire_crystal_", 15, 2.4, False),
        ("environment", "stump_", 11, 2.6, True),
        ("harvestables", "iron_node_intact", 13, 3.0, True, HARVEST),
        ("environment", "boulder_", 9, 2.8, True),
        ("environment_additions", "mire_broadleaf_tree", 8, 4.6, True),
    ],
    "StoneMoor": [
        ("environment", "standing_stone_", 12, 5.6, True),
        ("environment", "boulder_", 22, 3.0, True),
        ("environment", "grass_seedhead_", 18, 1.6, False),
        ("flora", "bush_thorn_", 13, 2.2, False),
        ("environment", "ruin_column_", 7, 4.0, True),
        ("environment", "rock_cluster_", 13, 2.4, False),
        ("harvestables", "stone_node_intact", 17, 3.0, True, HARVEST),
        ("environment", "tree_crooked_", 10, 5.0, True),
        ("environment", "grass_tuft_", 12, 1.5, False),
    ],
    "EastReach": [
        ("environment", "ruin_wall_", 10, 4.6, True),
        ("environment", "ruin_column_", 10, 3.6, True),
        ("environment", "tree_crooked_", 18, 5.2, True),
        ("harvestables", "harvest_tree_intact", 20, 4.4, True, HARVEST),
        ("flora", "bush_round_", 13, 2.4, False),
        ("environment", "grass_clump_", 15, 1.6, False),
        ("environment", "boulder_", 11, 2.8, True),
        ("environment", "stone_marker_", 4, 4.0, True),
        ("environment", "grass_meadow_", 12, 1.6, False),
    ],
    "MereShore": [
        ("environment", "reeds_", 22, 1.8, False, {"max_depth": 0.7}),
        ("flora", "tree_willow_", 16, 6.0, True),
        ("harvestables", "harvest_tree_intact", 16, 4.6, True, HARVEST),
        ("environment", "boulder_", 10, 3.0, True),
        ("flora", "bush_dead_", 9, 2.4, False),
        ("environment", "grass_meadow_", 14, 1.6, False),
        ("environment", "grass_tuft_", 12, 1.5, False),
        ("flora", "bush_round_", 9, 2.4, False),
        ("environment", "mire_tendril_", 7, 2.2, False),
    ],
    "SouthMarsh": [
        ("environment", "reeds_", 24, 1.8, False, {"max_depth": 0.8}),
        ("environment", "mire_crystal_", 9, 2.4, False),
        ("environment", "mire_tendril_", 12, 2.2, False),
        ("flora", "tree_willow_", 15, 6.4, True),
        ("environment_additions", "mire_broadleaf_tree", 10, 4.8, True),
        ("environment", "tree_bare_", 11, 5.4, True),
        ("harvestables", "harvest_tree_intact", 14, 4.8, True, HARVEST),
        ("environment", "grass_tuft_", 12, 1.5, False),
        ("flora", "bush_dead_", 8, 2.4, False),
    ],
    "LumberEdge": [
        ("environment", "stump_", 22, 2.4, True),
        ("environment", "fallen_log_", 16, 3.4, True),
        ("environment", "tree_pine_", 26, 4.2, True),
        ("harvestables", "harvest_tree_intact", 30, 4.2, True, HARVEST),
        ("harvestables", "harvest_tree_felled_trunk", 9, 4.2, True),
        ("harvestables", "harvest_tree_fresh_stump", 9, 2.6, True),
        ("harvestables", "harvest_tree_depleted_stump", 7, 2.4, True),
        ("flora", "sapling_", 15, 2.2, False),
        ("environment", "fern_", 12, 1.6, False),
        ("pickups", "pickup_log", 7, 1.8, False),
        ("pickups", "pickup_branch", 7, 1.4, False),
    ],
}

#: How steep a zone's ground may be before it refuses props. The default suits a
#: meadow; a quarry and a gorge are steep *by definition*, and rejecting their
#: props for it is how the previous cut placed three props in the Quarry and one
#: in the Gorge — the two zones whose whole character is broken ground.
ZONE_MAX_SLOPE = {"Quarry": 42.0, "Gorge": 44.0, "Plateau": 38.0, "Blight": 38.0}

#: Roughly one candidate lattice cell per this many square metres of zone. Forest
#: floors are the tightest because a wood you can see through is a park.
ZONE_DENSITY = {
    "SpawnHold": 9.0, "WestWood": 3.4, "RuinedVillage": 4.6, "DeepForest": 3.2,
    "Plateau": 5.0, "Quarry": 3.6, "Gorge": 4.4, "Blight": 4.0,
    "StoneMoor": 5.0, "EastReach": 4.6, "MereShore": 4.4, "SouthMarsh": 4.4,
    "LumberEdge": 3.6,
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
    """Points around a circle, with the angle at each. Tangent yaw is `tangent_yaw`."""
    for index in range(count):
        angle = phase + index * math.tau / count
        yield (centre[0] + math.cos(angle) * radius, centre[1] + math.sin(angle) * radius, angle)


def tangent_yaw(angle: float) -> float:
    """Yaw that lays an asset along the ring's tangent at `angle` — fences, walls."""
    return yaw_along(-math.sin(angle), math.cos(angle))


def radial_yaw(angle: float) -> float:
    """Yaw that points an asset's +X outward from the ring's centre — markers, stones."""
    return yaw_along(math.cos(angle), math.sin(angle))


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


def _cabin(placer: Placer, zone: str, base: tuple[float, float], yaw_offset: float,
           note: str, roof: str = "wood_roof_slope") -> None:
    """One 4 m timber cabin: foundation, floor, four walls, roof, all one rigid piece.

    Course heights come from the catalog, and every piece is placed against the one
    base level, so the cabin cannot step apart on sloping ground.
    """
    kit = "environment"
    level = placer.base_level(base[0], base[1], 3.0)
    floor_top = asset_height(kit, "wood_foundation") + asset_height(kit, "wood_floor")
    wall_top = floor_top + asset_height(kit, "wood_wall_solid")
    placer.place(kit, "wood_foundation", zone, base[0], base[1], level=level,
                 yaw=yaw_offset, note=note, force=True)
    placer.place(kit, "wood_floor", zone, base[0], base[1], level=level,
                 y_offset=asset_height(kit, "wood_foundation"), yaw=yaw_offset,
                 note=note, force=True)
    # Walls: (offset along the cabin's own axes, direction the wall runs).
    sides = (
        ("wood_wall_door", (0.0, -2.0), (1.0, 0.0)),
        ("wood_wall_window", (0.0, 2.0), (1.0, 0.0)),
        ("wood_wall_solid", (-2.0, 0.0), (0.0, 1.0)),
        ("wood_wall_solid", (2.0, 0.0), (0.0, 1.0)),
    )
    for asset, (ox, oz), (dx, dz) in sides:
        cos_a, sin_a = math.cos(yaw_offset), math.sin(yaw_offset)
        wx = base[0] + ox * cos_a - oz * sin_a
        wz = base[1] + ox * sin_a + oz * cos_a
        rdx = dx * cos_a - dz * sin_a
        rdz = dx * sin_a + dz * cos_a
        placer.place(kit, asset, zone, wx, wz, level=level, y_offset=floor_top,
                     yaw=yaw_along(rdx, rdz), note=note, force=True)
    placer.place(kit, roof, zone, base[0], base[1], level=level, y_offset=wall_top,
                 yaw=yaw_offset, note=note, force=True)
    # A porch: the step you actually walk up, and the rail beside it.
    cos_a, sin_a = math.cos(yaw_offset), math.sin(yaw_offset)
    step_x = base[0] - (-3.4) * sin_a
    step_z = base[1] + (-3.4) * cos_a
    placer.place(kit, "wood_stairs", zone, step_x, step_z, level=level,
                 yaw=yaw_along(-sin_a, cos_a) + math.pi * 0.5, note=note, force=True)
    placer.place(kit, "wood_half_wall", zone,
                 base[0] + 2.4 * cos_a - (-3.2) * sin_a,
                 base[1] + 2.4 * sin_a + (-3.2) * cos_a,
                 level=level, yaw=yaw_along(cos_a, sin_a), note=note, force=True)


def build_landmarks(placer: Placer, terrain: Terrain, markers: list[dict], lights: list[dict]) -> None:
    rng = placer.rng

    # -- the hold: the only built-up, defensible ground on the map -----------
    hold = (-6.0, 10.0)
    # Count comes from the circumference, not from a number that looked right. A
    # fence piece is 4.24 m long; sixteen of them around a 132 m ring leaves half
    # the perimeter open, which is what the first render showed.
    hold_radius = 18.0
    fence_count = int(round(math.tau * hold_radius / 4.24))
    for index, (x, z, angle) in enumerate(ring(hold, hold_radius, fence_count)):
        # Three gates, evenly spaced, each facing a road out of the hold.
        if index % (fence_count // 3) == 1:
            asset = "fence_gate"
        elif index % 5 == 0:
            asset = "fence_corner"
        else:
            asset = "fence_straight"
        placer.place("environment", asset, "SpawnHold", x, z, yaw=tangent_yaw(angle),
                     spacing=1.4, note="hold perimeter", force=True)
        if index % 4 == 0:
            placer.place("environment", "fence_post", "SpawnHold",
                         hold[0] + math.cos(angle) * (hold_radius + 1.1),
                         hold[1] + math.sin(angle) * (hold_radius + 1.1),
                         yaw=radial_yaw(angle), spacing=0.8,
                         note="hold perimeter", force=True)

    for offset_x, offset_z, facing in ((-8.0, -4.0, 0.0), (7.0, -5.5, 0.6), (-1.0, 8.5, math.pi)):
        _cabin(placer, "SpawnHold", (hold[0] + offset_x, hold[1] + offset_z), facing,
               "hold cabin", roof="wood_roof_corner" if offset_z > 0 else "wood_roof_slope")

    stations = [
        ("station_campfire", 0.0, 0.0), ("station_workbench_primitive", -3.6, 1.8),
        ("station_workbench_upgraded", -3.4, 4.0), ("station_anvil", 3.4, 1.9),
        ("station_cooking_spit", 1.4, -2.6), ("station_woodcutting_block", -4.4, -1.4),
        ("station_stone_furnace", 4.8, -1.2), ("station_repair_bench", -1.6, 3.8),
    ]
    for asset, offset_x, offset_z in stations:
        x, z = hold[0] + offset_x, hold[1] + offset_z
        placer.place("crafting_stations", asset, "SpawnHold", x, z, spacing=1.3,
                     yaw=yaw_along(hold[0] - x, hold[1] - z), note="hold camp", force=True)
        markers.append(_marker(f"Station_{asset}", "station", x, terrain.height_at(x, z), z, "SpawnHold"))
    lights.append(_light("Hold_Fire", hold[0], terrain.height_at(*hold) + 1.1, hold[1],
                         [1.0, 0.62, 0.28], 3.4, 13.0))

    # The hold's ward, and the spares that say a ward is a thing you maintain.
    placer.place("wards", "ward_healthy", "SpawnHold", hold[0] - 8.0, hold[1] + 2.2,
                 spacing=2.0, note="hold ward", force=True)
    placer.place("wards", "ward_activation_crystal", "SpawnHold", hold[0] - 8.0, hold[1] + 4.4,
                 spacing=1.0, note="hold ward", force=True)
    placer.place("wards", "ward_foundation", "SpawnHold", hold[0] - 10.6, hold[1] + 0.4,
                 spacing=1.8, note="hold ward", force=True)
    placer.place("wards", "ward_repair_scaffolding", "SpawnHold", hold[0] - 10.4, hold[1] + 3.6,
                 spacing=1.8, note="hold ward", force=True)
    lights.append(_light("Hold_Ward", hold[0] - 8.0, terrain.height_at(hold[0] - 8.0, hold[1] + 2.2) + 1.6,
                         hold[1] + 2.2, [0.36, 0.94, 0.88], 2.2, 11.0))
    placer.place("loot", "loot_chest_small_closed", "SpawnHold", hold[0] + 6.4, hold[1] + 4.2,
                 spacing=1.2, note="hold stores", force=True)
    placer.place("loot", "loot_item_bag", "SpawnHold", hold[0] + 5.4, hold[1] + 4.6,
                 spacing=0.6, solid=False, note="hold stores", force=True)
    for asset, ox, oz in (("pickup_flint", 2.2, -3.6), ("pickup_fibre_bundle", -5.4, -0.4),
                          ("pickup_coal", 5.6, -2.2), ("pickup_iron_ingot", 3.9, 2.6)):
        placer.place("pickups", asset, "SpawnHold", hold[0] + ox, hold[1] + oz,
                     spacing=0.5, solid=False, note="hold stores", force=True)
    markers.append(_marker("Hold", "landmark", hold[0], terrain.height_at(*hold), hold[1], "SpawnHold"))

    # -- ruined village ------------------------------------------------------
    village = (-56.0, 20.0)
    for index, (x, z, angle) in enumerate(ring(village, 13.0, 6, phase=0.4)):
        # A shell is a foundation and whatever is still standing on it. Courses go
        # through `stack`, so an upper course is never left hanging over a gap.
        courses = ["stone_foundation", "stone_wall_solid"]
        if index % 3 == 0:
            courses = ["stone_foundation", "stone_wall_door"]
        elif index % 3 == 1:
            courses = ["stone_foundation", "stone_wall_window", "stone_half_wall"]
        placer.stack("environment", "RuinedVillage", x, z, courses,
                     yaw=tangent_yaw(angle), note="village shell", solid_from=0)
        if index % 2 == 0:
            placer.place("environment", "ruin_wall_c", "RuinedVillage", x + 3.2, z + 2.4,
                         yaw=tangent_yaw(angle + 0.6), spacing=2.0, note="village shell", force=True)
        else:
            placer.place("environment", "ruin_wall_d", "RuinedVillage", x - 2.8, z + 2.8,
                         yaw=tangent_yaw(angle - 0.5), spacing=2.0, note="village shell", force=True)
    placer.place("environment", "stone_pillar", "RuinedVillage", village[0], village[1],
                 note="village well", force=True)
    placer.place("environment", "stone_stairs", "RuinedVillage", village[0] + 4.4, village[1] - 1.0,
                 yaw=yaw_along(-1.0, 0.0), spacing=1.6, note="village steps", force=True)
    for index, (x, z, angle) in enumerate(ring(village, 19.0, 2, phase=1.2)):
        placer.place("environment", f"ruin_arch_{'ab'[index]}", "RuinedVillage", x, z,
                     yaw=tangent_yaw(angle), spacing=2.2, note="village gate", force=True)
    placer.place("loot", "loot_chest_small_open", "RuinedVillage", village[0] - 3.6, village[1] + 3.2,
                 spacing=1.0, note="village looted", force=True)
    placer.place("loot", "loot_player_backpack", "RuinedVillage", village[0] - 4.4, village[1] + 2.4,
                 spacing=0.6, solid=False, note="village looted", force=True)
    placer.place("loot", "loot_coin_pouch", "RuinedVillage", village[0] - 3.0, village[1] + 4.0,
                 spacing=0.4, solid=False, note="village looted", force=True)
    placer.place("pickups", "pickup_coin", "RuinedVillage", village[0] - 2.4, village[1] + 3.4,
                 spacing=0.3, solid=False, note="village looted", force=True)
    placer.place("pickups", "pickup_salvage_fragment", "RuinedVillage", village[0] + 2.8, village[1] + 3.8,
                 spacing=0.3, solid=False, note="village looted", force=True)
    markers.append(_marker("Ruined_Village", "landmark", village[0],
                           terrain.height_at(*village), village[1], "RuinedVillage"))

    # -- the quarry, cut into the plateau's foot -----------------------------
    quarry = (-30.0, -24.0)
    for index, (x, z, angle) in enumerate(ring(quarry, 9.0, 5, phase=0.3)):
        asset = ("stone_node_intact", "stone_node_cracked", "iron_node_intact",
                 "stone_node_intact", "iron_node_cracked")[index]
        placer.place("harvestables", asset, "Quarry", x, z, yaw=radial_yaw(angle),
                     spacing=2.2, note="quarry face", force=True,
                     harvestable=asset.endswith("_intact"))
    # A timber gantry over the cut: two posts and a beam, which is the only place
    # `wood_beam` reads as a built thing rather than a plank someone dropped.
    gantry_level = placer.base_level(quarry[0], quarry[1] - 6.0, 4.0)
    for side in (-2.0, 2.0):
        placer.place("environment", "wood_post", "Quarry", quarry[0] + side, quarry[1] - 6.0,
                     level=gantry_level, spacing=0.8, note="quarry gantry", force=True)
    placer.place("environment", "wood_beam", "Quarry", quarry[0], quarry[1] - 6.0,
                 level=gantry_level, y_offset=asset_height("environment", "wood_post"),
                 yaw=yaw_along(1.0, 0.0), note="quarry gantry", force=True)
    placer.place("loot", "loot_chest_small_closed", "Quarry", quarry[0] + 4.0, quarry[1] + 5.0,
                 spacing=1.0, note="quarry cache", force=True)
    for asset, ox, oz in (("pickup_coal", -3.4, 4.4), ("pickup_flint", -2.6, 5.0),
                          ("pickup_iron_ore", 1.6, 6.2), ("pickup_stone", -1.2, 6.6)):
        placer.place("pickups", asset, "Quarry", quarry[0] + ox, quarry[1] + oz,
                     spacing=0.5, solid=False, note="quarry spoil", force=True)
    markers.append(_marker("Quarry", "landmark", quarry[0], terrain.height_at(*quarry), quarry[1], "Quarry"))

    # -- the cairn on the plateau -------------------------------------------
    cairn = (-48.0, -42.0)
    for index, (x, z, angle) in enumerate(ring(cairn, 6.0, 5)):
        placer.place("environment", f"standing_stone_{'abcd'[index % 4]}", "Plateau", x, z,
                     yaw=radial_yaw(angle), spacing=2.2, note="plateau cairn", force=True)
    placer.place("environment", "stone_marker_b", "Plateau", cairn[0], cairn[1],
                 note="plateau cairn", force=True)
    for x, z, angle in ring(cairn, 12.0, 4, phase=0.7):
        placer.place("wards", "ward_boundary_post", "Plateau", x, z, yaw=radial_yaw(angle),
                     spacing=1.2, note="plateau wardline", force=True)
    markers.append(_marker("Plateau_Cairn", "landmark", cairn[0], terrain.height_at(*cairn),
                           cairn[1], "Plateau"))

    # -- the stone circle ----------------------------------------------------
    circle = (54.0, -32.0)
    for index, (x, z, angle) in enumerate(ring(circle, 11.0, 9)):
        placer.place("environment", f"standing_stone_{'abcd'[index % 4]}", "StoneMoor",
                     x, z, yaw=tangent_yaw(angle), spacing=2.2, note="stone circle", force=True)
    placer.place("environment", "stone_marker_a", "StoneMoor", circle[0], circle[1],
                 note="stone circle", force=True)
    placer.place("loot", "loot_powerup_orb", "StoneMoor", circle[0] + 1.8, circle[1] + 1.2,
                 spacing=0.6, solid=False, note="stone circle", force=True)
    lights.append(_light("Circle_Glow", circle[0], terrain.height_at(*circle) + 1.4, circle[1],
                         [0.52, 0.72, 0.96], 1.6, 9.0))
    markers.append(_marker("Stone_Circle", "landmark", circle[0], terrain.height_at(*circle), circle[1],
                           "StoneMoor"))

    # -- watchtower ----------------------------------------------------------
    tower = (69.0, -4.0)
    tower_level = placer.base_level(tower[0], tower[1], 5.0)
    for x, z, angle in ring(tower, 3.2, 4, phase=0.6):
        # Measured heights, so the drums meet. `ruin_column` runs 2.74 m to 3.53 m
        # and the previous cut stepped it by a flat 3.6 m: every second drum floated.
        placer.stack("environment", "EastReach", x, z,
                     ["ruin_column_a", "ruin_column_c", "ruin_column_b", "ruin_column_d"],
                     yaw=radial_yaw(angle), note="watchtower", level=tower_level)
    for index, (x, z, angle) in enumerate(ring(tower, 8.0, 5)):
        placer.place("environment", f"ruin_wall_{'abcd'[index % 4]}", "EastReach", x, z,
                     yaw=tangent_yaw(angle), spacing=2.2, note="watchtower yard", force=True)
    placer.place("loot", "loot_chest_reinforced_closed", "EastReach", tower[0] + 1.6, tower[1] + 5.4,
                 spacing=1.0, note="watchtower cache", force=True)
    markers.append(_marker("Watchtower", "landmark", tower[0], terrain.height_at(*tower), tower[1],
                           "EastReach"))

    # -- lumber camp ---------------------------------------------------------
    camp = (-48.0, 50.0)
    for index, (x, z, angle) in enumerate(ring(camp, 7.0, 7)):
        asset = ("harvest_tree_felled_trunk", "harvest_tree_fresh_stump", "pickup_log",
                 "harvest_tree_depleted_stump", "pickup_branch", "harvest_tree_felled_trunk",
                 "harvest_tree_fresh_stump")[index]
        kit = "pickups" if asset.startswith("pickup") else "harvestables"
        placer.place(kit, asset, "LumberEdge", x, z, yaw=radial_yaw(angle), spacing=1.6,
                     solid=not asset.startswith("pickup"), note="lumber camp", force=True)
    placer.place("crafting_stations", "station_woodcutting_block", "LumberEdge", camp[0], camp[1],
                 yaw=yaw_along(0.0, 1.0), note="lumber camp", force=True)
    placer.place("environment", "wood_railing", "LumberEdge", camp[0] + 4.6, camp[1] - 4.6,
                 yaw=yaw_along(1.0, -0.6), note="lumber camp", force=True)
    placer.place("environment", "wood_stairs", "LumberEdge", camp[0] - 5.2, camp[1] - 3.4,
                 yaw=yaw_along(0.0, 1.0), spacing=1.4, note="lumber camp", force=True)
    markers.append(_marker("Lumber_Camp", "landmark", camp[0], terrain.height_at(*camp), camp[1],
                           "LumberEdge"))

    # -- hunters' camp -------------------------------------------------------
    hunt = (-6.0, -54.0)
    placer.place("crafting_stations", "station_campfire", "DeepForest", hunt[0], hunt[1],
                 note="hunters camp", force=True)
    placer.place("crafting_stations", "station_cooking_spit", "DeepForest", hunt[0] + 2.4, hunt[1] + 0.6,
                 yaw=yaw_along(-1.0, 0.0), spacing=1.2, note="hunters camp", force=True)
    lights.append(_light("Hunt_Fire", hunt[0], terrain.height_at(*hunt) + 1.0, hunt[1],
                         [1.0, 0.58, 0.24], 2.6, 10.0))
    # A drying rack: two posts and a beam across them, same trick as the gantry.
    rack_level = placer.base_level(hunt[0] - 4.4, hunt[1] + 3.2, 3.0)
    for side in (-1.8, 1.8):
        placer.place("environment", "wood_post", "DeepForest", hunt[0] - 4.4 + side, hunt[1] + 3.2,
                     level=rack_level, spacing=0.8, note="hunters camp", force=True)
    placer.place("environment", "wood_beam", "DeepForest", hunt[0] - 4.4, hunt[1] + 3.2,
                 level=rack_level, y_offset=asset_height("environment", "wood_post"),
                 yaw=yaw_along(1.0, 0.0), note="hunters camp", force=True)
    for x, z, angle in ring(hunt, 5.0, 4, phase=0.9):
        placer.place("environment", "wood_post", "DeepForest", x, z, yaw=radial_yaw(angle),
                     spacing=1.0, note="hunters camp", force=True)
    placer.place("loot", "loot_chest_small_closed", "DeepForest", hunt[0] + 2.2, hunt[1] + 2.6,
                 spacing=1.0, note="hunters camp", force=True)
    for asset, ox, oz in (("pickup_raw_meat", -1.6, -2.2), ("pickup_berry", -2.4, -1.4),
                          ("pickup_mushroom", -3.0, -2.0), ("pickup_coin_stack", 3.4, -1.8)):
        placer.place("pickups", asset, "DeepForest", hunt[0] + ox, hunt[1] + oz,
                     spacing=0.4, solid=False, note="hunters camp", force=True)
    markers.append(_marker("Hunters_Camp", "landmark", hunt[0], terrain.height_at(*hunt), hunt[1],
                           "DeepForest"))

    # -- the Wellspring: the map's objective, and the whole wellspring kit ----
    vale = (4.0, 64.0)
    vale_level = placer.base_level(vale[0], vale[1], 3.0)
    placer.place("wellsprings", "wellspring_base", "SouthMarsh", vale[0], vale[1],
                 level=vale_level, spacing=3.2, note="wellspring", force=True)
    placer.place("wellsprings", "wellspring_uncapped", "SouthMarsh", vale[0], vale[1],
                 level=vale_level, y_offset=asset_height("wellsprings", "wellspring_base"),
                 solid=False, note="wellspring", force=True)
    placer.place("wellsprings", "wellspring_basin", "SouthMarsh", vale[0] + 6.2, vale[1] - 1.4,
                 spacing=2.4, note="wellspring", force=True)
    placer.place("wellsprings", "wellspring_roots", "SouthMarsh", vale[0] - 6.4, vale[1] + 1.2,
                 spacing=2.6, solid=False, note="wellspring", force=True)
    placer.place("wellsprings", "wellspring_ritual_pedestal", "SouthMarsh", vale[0] + 5.4, vale[1] + 4.4,
                 spacing=1.4, note="wellspring", force=True)
    placer.place("wellsprings", "wellspring_crystal", "SouthMarsh", vale[0] - 5.0, vale[1] + 5.2,
                 spacing=1.2, note="wellspring", force=True)
    placer.place("wellsprings", "wellspring_guardian_platform", "SouthMarsh", vale[0] - 1.0, vale[1] + 10.0,
                 spacing=4.0, note="wellspring", force=True)
    placer.place("wellsprings", "wellspring_capped", "SouthMarsh", vale[0] + 13.0, vale[1] + 8.0,
                 spacing=3.0, note="wellspring outlier", force=True)
    placer.place("loot", "loot_chest_wellspring_closed", "SouthMarsh", vale[0] + 3.0, vale[1] - 4.4,
                 spacing=1.0, note="wellspring cache", force=True)
    for index, (x, z, angle) in enumerate(ring(vale, 12.0, 8)):
        placer.place("wellsprings", "wellspring_boundary_stones", "SouthMarsh", x, z,
                     yaw=radial_yaw(angle), spacing=3.4, note="wellspring ring", force=True)
    # Two monoliths on the skyline, one either side of the vale's approach.
    for x, z, angle in ring(vale, 22.0, 2, phase=math.pi * 0.5):
        placer.place("wellsprings", "wellspring_distant_monolith", "SouthMarsh", x, z,
                     yaw=radial_yaw(angle), spacing=2.4, note="wellspring monolith", force=True)
    lights.append(_light("Wellspring_Glow", vale[0], terrain.height_at(*vale) + 3.2, vale[1],
                         [0.72, 0.30, 0.94], 3.0, 20.0))
    markers.append(_marker("Wellspring", "objective", vale[0], terrain.height_at(*vale), vale[1],
                           "SouthMarsh"))

    # -- extraction yard -----------------------------------------------------
    yard = (62.0, 29.0)
    yard_level = placer.base_level(yard[0], yard[1], 6.0)
    for offset_x in (-1, 1):
        for offset_z in (-1, 1):
            placer.place("environment", "stone_floor", "MereShore", yard[0] + offset_x * 2.0,
                         yard[1] + offset_z * 2.0, level=yard_level, note="extraction pad", force=True)
    placer.place("loot", "loot_chest_reinforced_open", "MereShore", yard[0] + 3.2, yard[1] - 1.0,
                 level=yard_level, y_offset=asset_height("environment", "stone_floor"),
                 spacing=1.0, note="extraction cache", force=True)
    placer.place("wards", "ward_healthy", "MereShore", yard[0] - 4.4, yard[1] + 2.6,
                 spacing=1.8, note="extraction ward", force=True)
    placer.place("environment", "wood_railing", "MereShore", yard[0], yard[1] + 4.8,
                 yaw=yaw_along(1.0, 0.0), spacing=1.4, note="extraction rail", force=True)
    for index, (x, z, angle) in enumerate(ring(yard, 8.0, 4, phase=0.8)):
        placer.place("environment", f"stone_marker_{'ab'[index % 2]}", "MereShore", x, z,
                     yaw=radial_yaw(angle), spacing=1.8, note="extraction markers", force=True)
    lights.append(_light("Extraction_Lamp", yard[0], terrain.height_at(*yard) + 2.4, yard[1],
                         [0.86, 0.92, 0.68], 2.0, 12.0))
    markers.append(_marker("Extraction", "extraction", yard[0],
                           terrain.height_at(yard[0], yard[1]) + 0.24, yard[1], "MereShore"))
    # F-166 added this marker by hand-editing `world/gen/layouts/hollowmere.json`, because the
    # generator was under someone else's claim at the time. A hand edit to a GENERATED file survives
    # exactly until the next regeneration, and the next regeneration is what deleted it — the
    # authored map silently lost its only exit. Emitted here so it cannot happen again; the position
    # is the extraction yard's, same as the marker above, because they are the same ship.
    markers.append(_marker("Shipwreck", "shipwreck", yard[0],
                           terrain.height_at(yard[0], yard[1]) + 0.24, yard[1], "MereShore"))

    # -- the Blight, and where the Mire breeds -------------------------------
    #
    # This is the map's hostile region and its enemy source. The nests are inside
    # the bowl, spread far enough apart that clearing one is not clearing the
    # Blight; `EnemyWorld.ambient_spawn_points` reads the `enemy_nest` markers, so
    # the crawlers come from here and from nowhere else.
    blight = BLIGHT_CENTRE
    corrupted_level = placer.base_level(blight[0], blight[1], 3.0)
    placer.place("wellsprings", "wellspring_corrupted", "Blight", blight[0], blight[1],
                 level=corrupted_level, spacing=3.2, note="blight heart", force=True)
    placer.place("wellsprings", "wellspring_recorrupting", "Blight", blight[0] + 9.0, blight[1] + 5.0,
                 spacing=3.0, note="blight heart", force=True)
    lights.append(_light("Blight_Heart", blight[0], terrain.height_at(*blight) + 3.4, blight[1],
                         [0.76, 0.18, 0.62], 3.2, 22.0))
    nests = [
        ("Nest_Heart", blight[0] - 5.0, blight[1] - 4.0),
        ("Nest_West", blight[0] - 13.0, blight[1] + 6.0),
        ("Nest_East", blight[0] + 12.0, blight[1] - 7.0),
        ("Nest_South", blight[0] + 2.0, blight[1] + 12.0),
    ]
    for name, nest_x, nest_z in nests:
        placer.place("enemies", "enemy_crawler_nest", "Blight", nest_x, nest_z,
                     spacing=2.4, note="crawler nest", force=True)
        markers.append(_marker(name, "enemy_nest", nest_x,
                               terrain.height_at(nest_x, nest_z), nest_z, "Blight"))
        lights.append(_light("%s_Glow" % name, nest_x, terrain.height_at(nest_x, nest_z) + 0.9,
                             nest_z, [0.82, 0.24, 0.44], 1.1, 6.5))
    # A failed ward line on the Blight's rim: the reason it is still spreading.
    for index, (x, z, angle) in enumerate(ring(blight, 18.0, 6, phase=0.5)):
        asset = ("ward_destroyed", "ward_critical", "ward_damaged",
                 "ward_destroyed", "ward_critical", "ward_damaged")[index]
        placer.place("wards", asset, "Blight", x, z, yaw=radial_yaw(angle),
                     spacing=2.0, note="broken wardline", force=True)
    placer.place("loot", "loot_chest_wellspring_open", "Blight", blight[0] + 4.4, blight[1] - 6.0,
                 spacing=1.0, note="blight cache", force=True)
    markers.append(_marker("Blight", "landmark", blight[0], terrain.height_at(*blight),
                           blight[1], "Blight"))

    # -- bridges -------------------------------------------------------------
    # The river carves a channel five metres below its own banks, so without a deck
    # at BANK height the map is two islands. The first cut of this put the deck at
    # bed + 2.2 m — five metres below the ground either side, decorative and
    # useless — and the reachability fill is the only reason anyone found out.
    for name, (cx, cz), direction in find_crossings():
        deck = bridge_deck_height(terrain, (cx, cz), direction)
        yaw = yaw_along(direction[0], direction[1])
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
                "environment", "wood_floor", "Gorge", x, z, yaw=yaw, level=deck,
                note=name, force=True,
                col=[{"t": "box", "size": [4.4, 0.6, 4.4], "off": [0.0, -0.16, 0.0]}],
            )
            for side in (-BRIDGE_HALF_DEPTH, BRIDGE_HALF_DEPTH):
                rx, rz = x + normal[0] * side, z + normal[1] * side
                if terrain.height_at(rx, rz) > deck + 0.45:
                    continue
                # Railings run ALONG the deck. `yaw_along` is why they now do:
                # atan2(dz, dx) mirrored them across the road and they crossed it.
                placer.place("environment", "wood_railing", "Gorge", rx, rz,
                             yaw=yaw, level=deck,
                             y_offset=asset_height("environment", "wood_floor"),
                             note=name, force=True)
        # Piers were here and are gone on purpose. `wood_post` is a fixed 3.0 m,
        # and the gap between deck and riverbed varies from under a metre to well
        # over five, so a post either floats or buries itself. A pier that only
        # fits at one specific depth is not a pier, it is a coincidence — the
        # honest options are a stretchable pier asset or none, and none is free.
        markers.append(_marker(name, "bridge", cx, deck, cz, "Gorge"))

    # -- waymarks and loot worth walking to ----------------------------------
    for index, (x, z) in enumerate(((-24.0, 30.0), (30.0, -20.0), (-40.0, -8.0), (18.0, 40.0),
                                    (60.0, -50.0), (-20.0, -66.0), (52.0, 12.0), (-66.0, 40.0))):
        zone = _zone_at(x, z)
        placer.place("loot", "loot_chest_crate_closed", zone, x, z, spacing=1.6,
                     note="field cache (free basic crate)", force=True)
        markers.append(_marker(f"Cache_{index + 1}", "loot", x, terrain.height_at(x, z), z, zone))
    for index, (x, z) in enumerate(((-18.0, 2.0), (12.0, -30.0), (34.0, 8.0), (-2.0, 40.0),
                                    (46.0, -46.0), (-38.0, 26.0))):
        placer.place("wards", "ward_boundary_post", _zone_at(x, z), x, z,
                     yaw=yaw_along(x, z), spacing=1.0, note="waymark", force=True)


def build_gilded_chests(placer: Placer, terrain: Terrain, markers: list[dict]) -> None:
    """The Gilded Chest's world placement — `docs/ITEMS.md` §5/§6.4's "≈1–2 per island" rarity
    budget (F-146: nothing in the game placed a chest at all, so this budget had no owner).

    Named markers only, `"Chest_gilded_<n>"` — `autoload/chest_placement_service.gd` is the runtime
    reader, and it tells a gilded chest from every other `kind == "loot"` marker by that prefix
    alone, the same way the waymark loop above tells a `Cache_<n>` free scatter cache from
    everything else. `validate()` re-derives the count from `markers` itself and fails the build if
    it ever drifts outside 1–2, so the budget cannot silently grow or disappear under a future edit.

    The gilded tier shares the legendary rung's own mesh, `loot_chest_gilded_closed` — both are
    "the chest you saved up for", one gated on coins and one on the Gilded Key, and giving them two
    different expensive-looking silhouettes would teach the player a distinction the loot behind
    them does not actually make.

    `force` stays False, unlike the waymark loop's — a rare chest earns its rarity by standing
    somewhere the ordinary slope/water/clearance/road rules actually allow, not by being forced
    through a wall. A candidate that fails those checks is skipped, not forced in, so the two
    zones below are picked with room to spare rather than tuned to a single pixel.
    """
    candidates = [
        ("SouthMarsh", -10.0, 72.0),
        ("StoneMoor", 65.0, -35.0),
        ("DeepForest", -40.0, -55.0),
    ]
    placed = 0
    for zone, x, z in candidates:
        if placed >= 2:
            break
        record = placer.place("loot", "loot_chest_gilded_closed", zone, x, z,
                               spacing=2.6, note="gilded chest (Gilded Key)")
        if record is None:
            continue
        placed += 1
        markers.append(_marker(f"Chest_gilded_{placed}", "loot", x, terrain.height_at(x, z), z, zone))


#: The priced chest ladder's per-island budget, in price order (D-215). Rarity is expressed as
#: SCARCITY as well as cost: a player walks past five crates before they see one legendary, so the
#: top rung is an event rather than a shop. Every count is asserted in `validate()` against the
#: markers actually emitted, the same way the gilded budget is — a candidate site that the ordinary
#: slope/water/clearance rules reject is skipped, so a silently-short ladder has to fail the build
#: rather than ship as "the seed was unlucky".
LADDER_CHESTS: tuple[tuple[str, str, int, tuple[tuple[str, float, float], ...]], ...] = (
    ("basic", "loot_chest_crate_closed", 5, (
        ("ReedFlats", -52.0, 14.0), ("SouthMarsh", 8.0, 58.0), ("DeepForest", -30.0, -38.0),
        ("StoneMoor", 44.0, -24.0), ("ReedFlats", 22.0, 26.0), ("SouthMarsh", -14.0, 50.0),
        ("DeepForest", -56.0, -22.0), ("StoneMoor", 58.0, -8.0),
    )),
    ("common", "loot_chest_small_closed", 4, (
        ("DeepForest", -44.0, -46.0), ("StoneMoor", 52.0, -38.0), ("SouthMarsh", 20.0, 66.0),
        ("ReedFlats", -62.0, 28.0), ("DeepForest", -24.0, -58.0), ("StoneMoor", 68.0, -22.0),
        ("SouthMarsh", -6.0, 62.0),
    )),
    ("rare", "loot_chest_reinforced_closed", 3, (
        ("StoneMoor", 60.0, -56.0), ("DeepForest", -60.0, -44.0), ("SouthMarsh", 34.0, 54.0),
        ("ReedFlats", -70.0, 10.0), ("StoneMoor", 74.0, -40.0), ("DeepForest", -46.0, -66.0),
    )),
    ("epic", "loot_chest_warded_closed", 2, (
        ("DeepForest", -68.0, -58.0), ("StoneMoor", 76.0, -60.0), ("SouthMarsh", 44.0, 70.0),
        ("ReedFlats", -78.0, 34.0),
    )),
    ("legendary", "loot_chest_gilded_closed", 1, (
        ("StoneMoor", 84.0, -50.0), ("DeepForest", -78.0, -48.0), ("SouthMarsh", 8.0, 84.0),
        ("ReedFlats", -84.0, 20.0), ("StoneMoor", 70.0, -70.0),
    )),
)


#: Offsets tried around each authored candidate, nearest first, before that candidate is given up
#: on. A chest is not scenery — its position is a promise the budget in `validate()` has to keep —
#: but "this clearing, roughly" is the real authoring intent, and demanding one exact square metre
#: makes the ladder hostage to whatever tree the scatter dropped there first. Deterministic order,
#: so the same seed still produces the same map.
_CHEST_SEARCH: tuple[tuple[float, float], ...] = tuple(
    [(0.0, 0.0)]
    + [(round(radius * math.cos(math.tau * step / 8), 3), round(radius * math.sin(math.tau * step / 8), 3))
       for radius in (3.0, 6.0, 9.0, 13.0) for step in range(8)]
)


def build_ladder_chests(placer: Placer, terrain: Terrain, markers: list[dict]) -> None:
    """The five priced rungs of the chest ladder, as `"Chest_<tier>_<n>"` markers.

    `autoload/chest_placement_service.gd` reads the tier straight out of the marker name and looks
    its price, its lock and its silhouette up from that — so this function ships POSITIONS and
    nothing else. Adding a sixth rung is a marker name here plus a row in that service's economy
    table; it is deliberately not a scene edit, a prefab, or a per-instance property anywhere.

    Each tier walks its own candidate list until its budget is filled, `force=False` throughout:
    a chest that had to be forced through a slope check is standing somewhere the player cannot
    comfortably reach, and the whole point of a priced chest is that reaching it is the cost.
    Candidate lists are longer than the budgets they feed so an unlucky rejection has somewhere to
    go; `validate()` fails the build if any tier still comes up short.
    """
    for tier, asset, budget, candidates in LADDER_CHESTS:
        placed = 0
        for zone, x, z in candidates:
            if placed >= budget:
                break
            for ox, oz in _CHEST_SEARCH:
                record = placer.place("loot", asset, zone, x + ox, z + oz, spacing=2.4,
                                      note=f"{tier} chest")
                if record is None:
                    continue
                placed += 1
                px, _, pz = record["pos"]
                markers.append(_marker(f"Chest_{tier}_{placed}", "loot",
                                       px, terrain.height_at(px, pz), pz, zone))
                break


def ensure_coverage(placer: Placer, terrain: Terrain, markers: list[dict]) -> int:
    """Place one of every kit asset the scatter happened not to reach.

    The scatter draws variants from a shuffled bag, so coverage is even — but a
    family that only comes up four times across the run still cannot show all six
    of its variants, and which four is a property of the seed. Rather than tune
    weights until the dice cooperate, this walks whatever is left and finds each
    one a home in a zone that already asks for its family, so "we shipped every
    asset we made" is a guarantee instead of a run-to-run coincidence.
    """
    wanted = sorted(placeable_assets() - {(kit, asset) for kit, asset in
                                          ((p["kit"], p["asset"]) for p in placer.props)})
    if not wanted:
        return 0
    homes: dict[tuple[str, str], list[tuple[str, tuple[float, float], float]]] = {}
    for name, centre, radius, _pull in ZONES:
        for entry in SCATTER.get(name, []):
            homes.setdefault((entry[0], entry[1]), []).append((name, centre, radius))
    placed = 0
    for kit, asset in wanted:
        family = asset.rsplit("_", 1)[0] + "_"
        candidates = homes.get((kit, family)) or homes.get((kit, asset)) or [
            (name, centre, radius) for name, centre, radius, _ in ZONES
        ]
        done = False
        # Three passes, each giving up one constraint the one before it kept: the
        # zone it belongs in, then the whole map, then the placement rules. The
        # last one always succeeds, and if it is ever reached the run says so.
        attempts: list[tuple[list, int, dict]] = [
            (candidates, 400, {"spacing": 2.2, "max_slope": 40.0, "max_depth": 0.3}),
            ([(name, centre, radius) for name, centre, radius, _ in ZONES], 400,
             {"spacing": 1.4, "max_slope": 44.0, "max_depth": 0.5}),
        ]
        for where, samples, rules in attempts:
            for zone_name, centre, radius in where:
                for step in range(samples):
                    angle = step * 2.39996
                    distance = radius * math.sqrt((step + 0.5) / samples)
                    x = centre[0] + math.cos(angle) * distance
                    z = centre[1] + math.sin(angle) * distance
                    if placer.place(kit, asset, zone_name, x, z, **rules) is not None:
                        placed += 1
                        done = True
                        break
                if done:
                    break
            if done:
                break
        if not done:
            zone_name, centre, _radius = candidates[0]
            record = placer.place(kit, asset, zone_name, centre[0], centre[1],
                                  spacing=1.0, force=True, note="coverage")
            placed += 1 if record is not None else 0
            print(f"    forced {kit}/{asset} into {zone_name} — nowhere legal was free")
    return placed


def _zone_at(x: float, z: float) -> str:
    """Which zone owns this point — the same rule `undergrowth.gd` uses."""
    return min(ZONES, key=lambda e: math.hypot(x - e[1][0], z - e[1][1]) - e[3])[0]


def zone_area(name: str, centre: tuple[float, float], radius: float) -> float:
    """How much ground this zone actually owns, in square metres.

    Zone discs overlap, and `_zone_at` gives every point to exactly one of them, so
    a disc's area is not a zone's area. Scattering by disc area meant the zone that
    ran first filled the shared ground and the one that ran second found it full:
    DeepForest's disc covers almost all of the Quarry's, and the Quarry ended up
    placing zero standing props into a hole it could not see.
    """
    inside = 0
    total = 0
    step = 2.0
    z = centre[1] - radius
    while z <= centre[1] + radius:
        x = centre[0] - radius
        while x <= centre[0] + radius:
            if math.hypot(x - centre[0], z - centre[1]) <= radius:
                total += 1
                if _zone_at(x, z) == name and math.hypot(x, z) <= BOUND:
                    inside += 1
            x += step
        z += step
    return inside * step * step


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
    """Water bodies, as shapes the runtime unions into ONE clipped surface.

    Three rules, each of which the previous cut broke and each of which is visible
    from the shore:

    * **They do not stack.** The mere and the fen used to overlap over the whole
      lake at levels 1.8 m apart, so the lake was drawn twice — a second
      transparent sheet hanging in the air above the first. The fen now stops
      short of the mere, and `authored_world.gd` takes the single highest level
      per cell in any case, so an overlap can never produce two surfaces again.
    * **The river is one body, not eight.** It used to be emitted as one strip per
      polyline segment, and consecutive strips overlap at every bend — two quads
      at slightly different interpolated heights, z-fighting the whole way down
      the valley. One polyline body has one level function and no seams.
    * **The river meets the mere at the mere's level.** The last river point's
      surface IS `WATER_LAKE`, so there is no 1 m step where they join.
    """
    return [
        {
            "name": "The_Mere", "kind": "circle", "material": "lake",
            "centre": [LAKE_CENTRE[0], LAKE_CENTRE[1]], "radius": LAKE_RADIUS,
            "level": WATER_LAKE,
        },
        {
            "name": "South_Fen", "kind": "rect", "material": "marsh",
            "min": [FEN_MIN[0], FEN_MIN[1]], "max": [FEN_MAX[0], FEN_MAX[1]],
            "level": WATER_FEN,
        },
        {
            "name": "Hollow_River", "kind": "polyline", "material": "lake",
            "points": [[round(x, 3), round(z, 3), round(top, 3)] for x, z, _, top in RIVER],
            "half_width": RIVER_HALF_WIDTH + 1.5,
        },
    ]


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
    # cost an afternoon. On a 2 m grid a *continuous* 38-degree hillside changes
    # height by 1.56 m from cell to cell; a flat 0.55 m cap therefore rejected
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


SPAWN_CLEARANCE = 2.4


def find_spawn(placer: Placer, terrain: Terrain, hold: tuple[float, float]) -> tuple[float, float, float]:
    """Search outward from the hold for open, level, dry ground.

    The spawn used to be a coordinate typed next to the hold's centre, and one of
    the three cabins later landed a metre away from it — so the player spawned
    inside a shack, under a floor that had no collision, and could not get out.
    A hand-written spawn is a bug waiting for the next prop to move, so this asks
    the same spatial index everything else was placed through.
    """
    for step in range(4, 44):
        radius = step * 0.6
        count = max(10, int(radius * 2.5))
        for index in range(count):
            angle = index * math.tau / count + step * 0.31
            x = hold[0] + math.cos(angle) * radius
            z = hold[1] + math.sin(angle) * radius
            if not placer.clear(x, z, SPAWN_CLEARANCE):
                continue
            if terrain.slope_deg_at(x, z) > 12.0 or terrain.depth_at(x, z) > 0.0:
                continue
            distance, half = road_distance(x, z)
            if distance < half:
                continue
            return (round(x, 3), round(terrain.height_at(x, z) + 0.4, 3), round(z, 3))
    raise RuntimeError("no clear spawn anywhere near the hold")


def placeable_assets() -> set[tuple[str, str]]:
    """Every (kit, asset) this file is expected to put on the map.

    "Use everything we made" is a rule the map can enforce rather than a thing
    somebody notices in a render six weeks later, so it does — see `validate`.
    """
    out: set[tuple[str, str]] = set()
    for kit, entries in CATALOGS.items():
        if kit in RUNTIME_ONLY_KITS:
            continue
        for asset in entries:
            if asset in RUNTIME_ONLY_ASSETS:
                continue
            family = asset.rsplit("_", 1)[0]
            if kit == "flora" and family in UNDERGROWTH_FAMILIES:
                continue
            out.add((kit, asset))
    return out


def validate(terrain: Terrain, placer: Placer, markers: list[dict],
             spawn: tuple[float, float, float]) -> list[str]:
    problems: list[str] = []

    # -- nothing floats, nothing is buried ----------------------------------
    #
    # Both directions matter and the tolerances are not symmetric. A prop ABOVE
    # its ground is a visible gap under it at any distance; a prop below its
    # ground is only wrong once it swallows the thing, and every prop on a slope
    # is slightly below by construction because `ground_for` beds it in.
    floating = 0
    worst_float = 0.0
    worst_name = ""
    for prop in placer.props:
        x, y, z = prop["pos"]
        if math.hypot(x, z) > RING_OUTER:
            problems.append(f"{prop['asset']} at ({x:.1f}, {z:.1f}) is outside the map")
        if prop.get("note"):
            continue  # authored structures carry deliberate offsets; checked below
        radius = footprint(prop["kit"], prop["asset"])[0] * float(prop.get("scale", 1.0))
        ground = terrain.ground_for(x, z, radius)
        gap = y - ground
        if gap > 0.06:
            floating += 1
            if gap > worst_float:
                worst_float, worst_name = gap, f"{prop['asset']} at ({x:.1f}, {z:.1f})"
        if y < ground - 1.2:
            problems.append(f"{prop['asset']} at ({x:.1f}, {z:.1f}) is buried {ground - y:.2f} m")
    if floating:
        problems.append(
            f"{floating} scattered props float above their own ground "
            f"(worst {worst_float:.2f} m, {worst_name})"
        )

    # Authored structures may sit above the terrain — a bridge deck must — but
    # only where something is holding them up. A piece with nothing under it and
    # no deck under it is the village wall that hung 3.7 m over a missing course.
    supported: dict[tuple[int, int], float] = {}
    for prop in placer.props:
        if not prop.get("note"):
            continue
        x, y, z = prop["pos"]
        key = (int(round(x / 2.0)), int(round(z / 2.0)))
        top = y + asset_height(prop["kit"], prop["asset"]) * float(prop.get("scale", 1.0))
        supported[key] = max(supported.get(key, -1e9), top)
    for prop in placer.props:
        note = prop.get("note", "")
        if not note or note.startswith("Bridge_"):
            continue
        x, y, z = prop["pos"]
        radius = footprint(prop["kit"], prop["asset"])[0] * float(prop.get("scale", 1.0))
        gap = y - terrain.ground_for(x, z, radius)
        if gap <= 0.35:
            continue
        key = (int(round(x / 2.0)), int(round(z / 2.0)))
        if supported.get(key, -1e9) < y - 0.35:
            problems.append(
                f"{prop['asset']} ({note}) at ({x:.1f}, {z:.1f}) hangs {gap:.2f} m "
                "with nothing under it"
            )

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

    # -- every asset we made is on the map ----------------------------------
    missing = sorted(f"{kit}/{asset}" for kit, asset in placeable_assets()
                     if asset not in placer.used)
    if missing:
        problems.append(f"{len(missing)} kit assets are placed nowhere: " + ", ".join(missing[:12]))

    # The spawn is the one point on the map a player is guaranteed to occupy, so
    # it gets its own check rather than relying on the general placement rules.
    nearest = 1e9
    nearest_asset = ""
    for prop in placer.props:
        if not prop.get("cols"):
            continue
        distance = math.hypot(prop["pos"][0] - spawn[0], prop["pos"][2] - spawn[2])
        if distance < nearest:
            nearest, nearest_asset = distance, prop["asset"]
    if nearest < SPAWN_CLEARANCE * 0.8:
        problems.append(
            f"spawn is {nearest:.2f} m from {nearest_asset} — the player starts inside it"
        )
    ground = terrain.height_at(spawn[0], spawn[2])
    if abs(spawn[1] - ground - 0.4) > 0.05:
        problems.append(f"spawn is {spawn[1] - ground:.2f} m off the ground")

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
            if marker["kind"] not in ("landmark", "objective", "extraction", "station", "enemy_nest"):
                continue
            mx, _, mz = marker["pos"]
            ix = int(round((mx - ORIGIN[0]) / CELL))
            iz = int(round((mz - ORIGIN[1]) / CELL))
            near = any(
                0 <= ix + dx < NX and 0 <= iz + dz < NZ and seen[(iz + dz) * NX + ix + dx]
                for dx in range(-3, 4) for dz in range(-3, 4)
            )
            if not near:
                problems.append(f"{marker['name']} cannot be walked to from spawn")

        # F-146: the Gilded Chest's placement budget (`docs/ITEMS.md` §6.4, "≈1-2 per island") is
        # a COUNT, not a spacing rule — build_gilded_chests() can silently place fewer than
        # intended (every candidate site rejected) or a future edit could add too many, and either
        # is wrong in a way none of the spacing/reachability checks above would ever catch. Checked
        # here, not as its own top-level pass, because reachability needs the same `seen` flood
        # fill this branch already paid for.
        gilded_chests = [m for m in markers if m["kind"] == "loot" and m["name"].startswith("Chest_gilded_")]
        if not 1 <= len(gilded_chests) <= 2:
            problems.append(
                f"gilded chest budget is {len(gilded_chests)}, must be 1-2 per island (ITEMS.md §6.4)"
            )
        # D-215: the same argument, once per priced rung. A tier that placed zero chests is not a
        # quieter map, it is a price ladder with a missing rung — and since each rung's odds are
        # what the rung above it is measured against, the ladder only means anything whole.
        for tier, _asset, budget, _candidates in LADDER_CHESTS:
            prefix = f"Chest_{tier}_"
            rung = [m for m in markers if m["kind"] == "loot" and m["name"].startswith(prefix)]
            if len(rung) != budget:
                problems.append(
                    f"{tier} chest budget is {len(rung)}, must be exactly {budget} per island"
                )
            gilded_chests.extend(rung)

        for marker in gilded_chests:
            mx, _, mz = marker["pos"]
            ix = int(round((mx - ORIGIN[0]) / CELL))
            iz = int(round((mz - ORIGIN[1]) / CELL))
            near = any(
                0 <= ix + dx < NX and 0 <= iz + dz < NZ and seen[(iz + dz) * NX + ix + dx]
                for dx in range(-3, 4) for dz in range(-3, 4)
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

    build_gilded_chests(placer, terrain, markers)
    build_ladder_chests(placer, terrain, markers)

    # Two passes per zone, and the order is the whole reason a wood looks like a
    # wood. One pass draws from the full table by weight, and ground cover — which
    # is most of the weight and needs the least room — takes the lattice first and
    # leaves no 4 m gap for a pine. So structure goes down first against an empty
    # zone, and the second pass fills between the trunks with whatever still fits.
    for name, centre, radius, _pull in ZONES:
        table = SCATTER.get(name)
        if not table:
            continue
        area = zone_area(name, centre, radius)
        slope = ZONE_MAX_SLOPE.get(name, MAX_PROP_SLOPE_DEG)
        structure = [entry for entry in table if entry[4] or entry[3] >= 2.2]
        standing = 0
        if structure:
            standing = placer.scatter(name, centre, radius, structure,
                                      int(area / (ZONE_DENSITY[name] * 3.2)),
                                      step=2.8, max_slope=slope)
        target = int(area / ZONE_DENSITY[name])
        placed = placer.scatter(name, centre, radius, table, target,
                                step=1.7, max_slope=slope)
        print(f"  {name:14s} {standing + placed:5d} placed ({standing:4d} standing) "
              f"of {target:5d} lattice cells")

    topped_up = ensure_coverage(placer, terrain, markers)
    if topped_up:
        print(f"  coverage top-up: {topped_up} asset(s) the scatter never reached")

    spawn = find_spawn(placer, terrain, (-6.0, 10.0))
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
        "zones": [{"name": n, "centre": [c[0], c[1]], "radius": r, "pull": p}
                  for n, c, r, p in ZONES],
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
    harvestables = sum(1 for prop in placer.props if prop.get("harvestable"))
    trees = sum(1 for prop in placer.props
                if "tree" in prop["asset"] or prop["asset"].startswith("sapling"))
    print(f"\n  props {len(placer.props)} across {len(kits)} kits: "
          + ", ".join(f"{k} {v}" for k, v in sorted(kits.items())))
    print(f"  {trees} trees, {harvestables} live harvestable nodes, "
          f"{len(placer.used)}/{len(placeable_assets())} kit assets used")
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
