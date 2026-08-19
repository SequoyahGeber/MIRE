"""A-015 — wetland nature: the trees and water cover a mire actually grows.

  /Applications/Blender.app/Contents/MacOS/Blender --background --python tools/blender/build_wetland_nature.py

Built with Blender 5.2.0 LTS (D-038 pins the toolchain). Outputs to `assets/wetland_nature/`.

**Scope: six of the row's twelve.** `assets/flora` already ships `tree_willow_a`..`c`,
`lily_pad_a`..`c`, `marsh_grass_a`..`c`, `sedge_a`..`c` and `flowers_bog_a`..`c`, and
`assets/environment` ships `reeds_a`..`d`. Swamp willow, lily pads, marsh grass, sedge, bog flowers
and water reeds are therefore already in the game, and remaking them would put two objects in the
world competing to be the same plant. What is genuinely missing is **alder, hollow tree, uprooted
tree, mangrove-root tree, duckweed and hanging moss** — and those are missing for a reason: they are
the shapes that say *wetland* rather than *forest*, and every tree the game has so far is a
straight trunk with a canopy on top.

**What a tree in this kit has to earn.** `assets/environment` has pine, birch, bare and crooked, and
`assets/flora` has willow, snag and sapling. A seventh tree that is another trunk-with-canopy is
scenery nobody notices. Each of these four trees is built around one silhouette a forest tree cannot
make: alder forks into several trunks from the ground, the hollow tree has a void through it, the
uprooted tree is horizontal with a vertical disc of root plate, and the mangrove stands clear of the
ground on arching stilts.
"""


from __future__ import annotations

import json
import math
import random
import sys
from pathlib import Path
from typing import Callable

import bpy
from mathutils import Matrix, Vector

sys.path.append(str(Path(__file__).resolve().parent))

from mire_art import (  # noqa: E402
    Batch,
    cone,
    fork,
    cylinder_between,
    eevee_engine,
    ground_and_centre,
    hull,
    look_at,
    mat,
    paint_faces,
    radial,
    reset_materials,
    tapered_between,
    world_bounds,
)

ROOT = Path(__file__).resolve().parents[2]
EXPORT_DIR = ROOT / "assets" / "wetland_nature" / "exports"
PREVIEW_DIR = ROOT / "assets" / "wetland_nature" / "preview"
CATALOG_PATH = ROOT / "assets" / "wetland_nature" / "catalog.json"
SOURCE_DIR = ROOT / "assets" / "source"
SOURCE_PATH = SOURCE_DIR / "wetland_nature.blend"

#: Target size in metres, the axis it governs, and a hard footprint ceiling.
#: Set against a 1.80 m player: shin 0.2, knee 0.5, waist 1.0, chest 1.4.
SIZE: dict[str, tuple[float, str, float]] = {
    "alder": (5.60, "height", 4.20),
    "hollow_tree": (4.90, "height", 3.20),
    "uprooted_tree": (6.40, "spread", 6.60),
    "mangrove_tree": (4.60, "height", 3.60),
    "duckweed": (0.94, "spread", 1.00),
    "hanging_moss": (1.65, "height", 1.15),
}

#: Assets that are laid over before grounding, as radians about world Y.
#:
#: `cattail_bundle` is a PICKUP and `reed_bed` is the growing node it comes from,
#: and they are made of the same parts. Standing the bundle up gives the two of
#: them the same silhouette, and a player looking across a mere then cannot tell
#: the thing they can carry from the thing they have to harvest. Laying it down
#: separates them at any distance and costs nothing — it is also simply what a cut
#: sheaf does when you put it on the ground.
LIE_DOWN: dict[str, float] = {}

SIZE_TOLERANCE = 0.02
TRIANGLE_BUDGET = 1650
#: Per-asset exceptions, each with a reason. The budget is a pickup's budget; a
#: node a player walks INTO is a different object. `ASSET_TRACKER.md` allows
#: 50-800 for an ordinary prop and 300-2,000 for a hero one, and a 1.55 m reed bed
#: sits between the two — it is the largest thing in this kit and the only one
#: whose whole job is to look like *a lot* of something.
TRIANGLE_ALLOWANCE: dict[str, int] = {}
MAX_MATERIALS = 4
MATERIAL_ALLOWANCE: dict[str, int] = {}


# ---------------------------------------------------------------------------
# Shape recipes
# ---------------------------------------------------------------------------


def spread_pick(items: list, count: int) -> list:
    """Take ``count`` items spaced across ``items``, never the first ``count``.

    `fork()` returns its tips depth-first, so a prefix of that list is every tip
    of the FIRST branch and nothing from the others. Hanging canopy on `tips[:6]`
    therefore puts the whole crown on one side of the tree — the 2.1j one-sidedness
    defect, reintroduced by a slice that looks harmless.
    """
    if count >= len(items):
        return list(items)
    step = len(items) / count
    return [items[int(index * step)] for index in range(count)]


def canopy(made: list, prefix: str, tips: list, count: int, radius: float, token: str,
           highlight: str, seed: int, subdivisions: int = 0) -> None:
    """Foliage masses hung across a set of branch tips.

    A crown is the one place the "three masses, never eighteen" rule from A-000V
    does NOT apply. That rule is about a bush, which is one object a player stands
    next to; a tree crown is a canopy seen against sky from tens of metres, and
    three masses on a branching tree read as three parasols parked on sticks. What
    it needs is enough masses to MERGE, which is affordable only because they are
    base icosahedra: `subdivisions=0` is 20 faces against 80, so sixteen of these
    cost less than four of the subdivided kind. At this size the extra facets would
    not survive the distance anyway, and this game ships with no prop LOD (F-144),
    so the triangles saved here are saved everywhere the tree is placed.

    `paint_faces` lights the crowns — it selects faces ABOVE a normal threshold, so
    it can light a top but never shade an underside, and passing a negative
    threshold to mean "the bottom" just scatters the second material over the whole
    mass at random.
    """
    rng = random.Random(seed)
    for index, tip in enumerate(spread_pick(tips, count)):
        scale = radius * rng.uniform(0.78, 1.18)
        # Sat ON the tip, not floating above it, and rounder than it is flat. The
        # first cut lifted each mass 0.35 of its own radius clear of the branch and
        # squashed it to 0.66 — twelve of those read as parasols on sticks rather
        # than as one crown.
        mass = hull(f"{prefix}_leaf_{index}", (tip.x, tip.y, tip.z + scale * 0.10),
                    (scale, scale * 0.94, scale * 0.82), mat(token),
                    seed=seed + index * 41, subdivisions=subdivisions, lumps=8,
                    lump=0.34, sharpness=2.0)
        paint_faces(mass, mat(highlight), min_normal_z=0.36, min_height=0.52,
                    coverage=0.55, seed=seed + index)
        made.append(mass)


# ---------------------------------------------------------------------------
# Builders
# ---------------------------------------------------------------------------


def build_alder(seed: int) -> None:
    """A wetland alder: several trunks out of one stool, not one trunk.

    Every tree the game has is a single stem with a canopy on it. An alder is a
    coppice — it throws three or four trunks from the same base — and that is the
    whole reason to build it: from a distance the multi-stem fork is a different
    shape from anything in `assets/environment`, and it is the shape a waterlogged
    tree makes because the crown cannot get heavy without falling over.
    """
    rng = random.Random(seed)
    made = []
    # The stool the trunks rise from, so they do not appear to grow out of nothing.
    made.append(hull("alder_stool", (0.0, 0.0, 0.13), (0.36, 0.33, 0.16),
                     mat("wood_bark_dark"), seed=seed, lumps=6, lump=0.26,
                     sharpness=2.6, flat_base=0.0))
    all_tips: list = []
    for index, (angle, rad) in enumerate(radial(4, 0.115, seed=seed, jitter=0.45,
                                                radius_jitter=0.35)):
        base = (math.cos(angle) * abs(rad), math.sin(angle) * abs(rad), 0.10)
        # Leaning outward as they rise — the give-away of a multi-stem stool.
        lean = rng.uniform(0.06, 0.15)
        direction = (math.cos(angle) * lean, math.sin(angle) * lean, 1.0)
        before = {obj.name for obj in bpy.data.objects}
        tips = fork(f"alder_stem_{index}", base, direction, rng.uniform(2.5, 3.4),
                    rng.uniform(0.105, 0.135), mat("wood_bark_dark"),
                    seed=seed + index * 53, depth=3, splits=(2, 3), spread=0.32,
                    shrink=0.70, curve=0.18, vertices=4)
        made.extend(obj for obj in bpy.data.objects if obj.name not in before)
        all_tips.extend(tips)
    canopy(made, "alder", all_tips, 17, 0.47, "leaf_deep", "leaf", seed + 7)


def build_hollow_tree(seed: int) -> None:
    """A standing trunk with a void through it — shelter, stash, and a landmark.

    The hollow is the asset. A-006 paid for the rule this is built on: *an opening
    has to survive being drawn from standing eye height, not merely exist*. Its
    nest was first a dome with a throat inside and read as a pile of rocks,
    because at a player's eye level the far wall is simply the near wall's
    backdrop. The rim has to be cut away on the side you approach from.

    So the trunk is not a cylinder with a hole cut in it — it is a **ring of
    staves** with three of them missing on one side and the rest cut down to
    knee height there. That gives a real void with a lit back wall behind it, for
    about the cost of the cylinder it replaces, and it reads from ground level
    because there is nothing left in front of the opening to read instead.
    """
    rng = random.Random(seed)
    made = []
    # Root swell, so the staves do not appear to be standing in a bucket.
    made.append(hull("hollow_root", (0.0, 0.0, 0.19), (0.78, 0.72, 0.24),
                     mat("wood_bark_dark"), seed=seed, lumps=7, lump=0.28,
                     sharpness=2.4, flat_base=0.0))

    staves = 11
    # The mouth faces -Y, which is the camera and, in game, whichever way the
    # placer turns it. Front staves are dropped entirely; their neighbours are cut
    # down so the rim falls away instead of ending in a wall.
    missing = {4, 5, 6, 7}
    shortened = {3: 0.44, 8: 0.40}
    for index in range(staves):
        angle = math.tau * index / staves - math.pi * 0.5
        if index in missing:
            continue
        height = 3.05 * shortened.get(index, 1.0) * rng.uniform(0.94, 1.06)
        radius = 0.47
        base = (math.cos(angle) * radius, math.sin(angle) * radius, 0.10)
        top = (math.cos(angle) * radius * 0.80, math.sin(angle) * radius * 0.80, height)
        # Fat enough to OVERLAP its neighbours. At 0.105 they stood clear of each
        # other and the trunk read as a bundle of poles with gaps all the way
        # round, which meant the three deliberately-missing ones said nothing —
        # a mouth is only a mouth if the rest of the wall is solid.
        made.append(tapered_between(f"hollow_stave_{index}", base, top, 0.175, 0.135,
                                    mat("wood_bark_dark"), vertices=5))

    # The lit back wall of the cavity. Without something behind the gap the hollow
    # is a hole through to the skybox, which reads as a modelling mistake.
    back = hull("hollow_back", (0.0, 0.26, 1.30), (0.38, 0.20, 1.20), mat("wood_dead"),
                seed=seed + 5, lumps=6, lump=0.20, sharpness=2.8)
    made.append(back)
    # Rotted floor inside the mouth — the bit a player actually sees first.
    made.append(hull("hollow_floor", (0.0, 0.16, 0.20), (0.34, 0.26, 0.10),
                     mat("wood_dead"), seed=seed + 9, lumps=5, lump=0.26,
                     sharpness=2.6, flat_base=0.0))

    # Above the hollow the trunk closes up again and carries a thin, half-dead crown.
    before = {obj.name for obj in bpy.data.objects}
    tips = fork("hollow_crown", (0.0, 0.0, 2.70), (0.05, 0.02, 1.0), 1.60, 0.285,
                mat("wood_bark_dark"), seed=seed + 21, depth=3, splits=(2, 3),
                spread=0.44, shrink=0.68, curve=0.24, vertices=4)
    made.extend(obj for obj in bpy.data.objects if obj.name not in before)
    canopy(made, "hollow", tips, 9, 0.42, "leaf_deep", "leaf", seed + 33)


def build_uprooted_tree(seed: int) -> None:
    """A tree gone over, with its root plate standing on end.

    `assets/environment` already has `fallen_log_a`..`d`, `stump_a`..`d` and
    `root_cluster_a`..`d`, and this must not be a fifth fallen log. The difference
    is the **root plate**: when a waterlogged tree goes over it does not snap, it
    tips, and it drags up a vertical disc of root and soil taller than a player.
    That disc against the sky is the whole silhouette, and nothing else in the
    game makes it — a fallen log is a horizontal line and a stump is a stub.

    It is also the one asset here a player can walk behind and under, so the plate
    is built with roots on BOTH faces; a disc that is only detailed on the side it
    was authored from is the 2.1j defect at landmark scale.
    """
    rng = random.Random(seed)
    made = []
    # The trunk, lying along +X with the butt end at the plate.
    trunk_start = Vector((-0.35, 0.0, 0.62))
    trunk_end = Vector((4.35, 0.16, 0.30))
    made.append(tapered_between("uproot_trunk", trunk_start, trunk_end, 0.44, 0.13,
                                mat("wood_bark_dark"), vertices=7))
    # Broken branches still on it, sampled across the tips so they are not all on
    # one flank (`fork` returns depth-first — a prefix is one branch's worth).
    before = {obj.name for obj in bpy.data.objects}
    tips = fork("uproot_branch", (2.35, 0.08, 0.40), (0.42, 0.12, 0.90), 1.55, 0.125,
                mat("wood_bark_dark"), seed=seed + 11, depth=3, splits=(2, 3), spread=0.66,
                shrink=0.66, curve=0.26, vertices=4)
    made.extend(obj for obj in bpy.data.objects if obj.name not in before)
    canopy(made, "uproot", tips, 9, 0.30, "leaf_dry", "leaf_dry", seed + 17)

    # The plate: a thick vertical disc of soil, roots bursting from both faces.
    plate = hull("uproot_plate", (-0.62, 0.0, 1.32), (0.46, 1.42, 1.34),
                 mat("terrain_path"), seed=seed + 3, lumps=11, lump=0.44, sharpness=1.6)
    paint_faces(plate, mat("wood_bark_dark"), min_normal_z=0.20, min_height=0.30,
                coverage=0.45, seed=seed + 4)
    made.append(plate)
    # Roots as BRANCHING structures, not spikes. The first cut fired eleven
    # straight tapered rods radially out of the disc and it rendered as a sea
    # urchin — roots fork, curve and thicken toward the trunk, and `fork` is the
    # primitive that already knows how to do that.
    for index in range(6):
        face = -1.0 if index % 2 == 0 else 1.0
        angle = math.tau * index / 6 + rng.uniform(-0.25, 0.25)
        anchor = (-0.62 + face * 0.20,
                  math.cos(angle) * rng.uniform(0.30, 0.80),
                  1.35 + math.sin(angle) * rng.uniform(0.30, 0.80))
        direction = (face * rng.uniform(0.7, 1.1),
                     math.cos(angle) * 0.55,
                     math.sin(angle) * 0.55)
        before_root = {obj.name for obj in bpy.data.objects}
        fork(f"uproot_root_{index}", anchor, direction, rng.uniform(0.55, 0.95),
             rng.uniform(0.065, 0.105), mat("wood_bark_dark"), seed=seed + 40 + index,
             depth=2, splits=(2, 2), spread=0.70, shrink=0.60, curve=0.42,
             vertices=4)
        made.extend(obj for obj in bpy.data.objects if obj.name not in before_root)
    # The crater it came out of.
    made.append(hull("uproot_crater", (0.15, 0.0, 0.05), (0.85, 0.90, 0.09),
                     mat("terrain_path"), seed=seed + 7, lumps=7, lump=0.28,
                     sharpness=2.4, flat_base=0.0))


def arch(made: list, name: str, top: Vector, foot: Vector, radius: float,
         material, bow: float, segments: int = 3) -> None:
    """One arching stilt root: bows OUT before it comes down.

    A straight strut from trunk to ground is scaffolding. The arc is the whole
    read, and it needs at least three segments — two makes a tent, and one is the
    strut you were trying not to build.
    """
    outward = Vector((foot.x - top.x, foot.y - top.y, 0.0))
    points = []
    for index in range(segments + 1):
        t = index / segments
        point = top.lerp(foot, t)
        points.append(point + outward * (math.sin(t * math.pi) * bow))
    for index in range(segments):
        made.append(tapered_between(
            f"{name}_{index}", points[index], points[index + 1],
            radius * (1.0 - 0.22 * index / segments),
            radius * (1.0 - 0.22 * (index + 1) / segments),
            material, vertices=4))


def build_mangrove_tree(seed: int) -> None:
    """A tree standing clear of the ground on arching stilt roots.

    The only tree in the game whose trunk does not touch the earth. That gap under
    the crown is the silhouette — a player can see daylight and water beneath it,
    and nothing in `assets/environment` can do that. It is also functional
    scenery: a thing you can wade under.
    """
    rng = random.Random(seed)
    made = []
    lift = 1.30
    made.append(tapered_between("mangrove_trunk", Vector((0.0, 0.0, lift * 0.72)),
                                Vector((0.06, 0.02, 3.05)), 0.185, 0.115,
                                mat("wood_bark_dark"), vertices=6))
    for index, (angle, rad) in enumerate(radial(7, 1.15, seed=seed, jitter=0.35,
                                                radius_jitter=0.22)):
        reach = abs(rad)
        top = Vector((0.0, 0.0, lift * rng.uniform(0.80, 1.25)))
        foot = Vector((math.cos(angle) * reach, math.sin(angle) * reach, 0.0))
        arch(made, f"mangrove_stilt_{index}", top, foot,
             rng.uniform(0.055, 0.082), mat("wood_bark_dark"),
             rng.uniform(0.38, 0.58))
    before = {obj.name for obj in bpy.data.objects}
    tips = fork("mangrove_crown", (0.06, 0.02, 3.00), (0.04, 0.02, 1.0), 1.15, 0.11,
                mat("wood_bark_dark"), seed=seed + 13, depth=3, splits=(2, 3),
                spread=0.52, shrink=0.68, curve=0.22, vertices=4)
    made.extend(obj for obj in bpy.data.objects if obj.name not in before)
    canopy(made, "mangrove", tips, 14, 0.44, "leaf_deep", "leaf", seed + 29)


def build_duckweed(seed: int) -> None:
    """A mat of duckweed on still water — the flattest asset in the kit.

    It exists to break up open water, which currently reads as an empty plane.
    Nothing here is taller than a coin: the moment duckweed has height it stops
    being duckweed and starts being lily pads, which `assets/flora` already ships.
    """
    rng = random.Random(seed)
    made = []
    made.append(hull("duckweed_water", (0.0, 0.0, 0.010), (0.46, 0.40, 0.012),
                     mat("peat"), seed=seed, lumps=7, lump=0.22, sharpness=2.4,
                     flat_base=0.0))
    batch = Batch()
    for index, (angle, rad) in enumerate(radial(64, 0.42, seed=seed + 3, jitter=0.95,
                                                radius_jitter=0.85)):
        centre = Vector((math.cos(angle) * abs(rad), math.sin(angle) * abs(rad),
                         0.019 + rng.uniform(0.0, 0.004)))
        size = rng.uniform(0.016, 0.030)
        batch.blob("leaf_light" if index % 3 else "leaf", centre,
                   (size, size * rng.uniform(0.8, 1.1), size * 0.20), rng)
    batch.emit("duckweed_fronds")


def build_hanging_moss(seed: int) -> None:
    """Moss hanging off a branch — a curtain, and curtains have to be BUILT.

    A-000V paid for this one: *you cannot make a hanging curtain by drooping a
    sphere*. Pulling lobes out of a round canopy gives it notches and hanging round
    masses off the rim gives it ears. A curtain is tall, narrow strands, and it is
    made by building strands.

    It hangs from its own branch stub so it can be placed against any of this
    kit's trees without needing a socket authored into them — the assets are
    procedurally scattered, so nothing can rely on a hand-placed attachment point.
    """
    rng = random.Random(seed)
    made = []
    made.append(tapered_between("moss_branch", Vector((-0.30, 0.0, 1.60)),
                                Vector((0.32, 0.05, 1.51)), 0.055, 0.032,
                                mat("wood_bark_dark"), vertices=5))
    batch = Batch()
    for index in range(34):
        along = rng.uniform(-0.27, 0.29)
        base = Vector((along, 0.05 * (along + 0.30) / 0.62 + rng.uniform(-0.040, 0.040),
                       1.585 - 0.09 * (along + 0.30) / 0.62))
        drop = rng.uniform(0.30, 0.95)
        width = rng.uniform(0.020, 0.042)
        sway = rng.uniform(-0.07, 0.07)
        spine = [
            Vector((base.x + sway * t * t, base.y + sway * 0.4 * t * t, base.z - drop * t))
            for t in (0.0, 0.36, 0.72, 1.0)
        ]
        token = ("moss", "moss_light", "moss_dark")[index % 3]
        batch.ribbon(token, spine, [width * 0.5, width * 0.44, width * 0.30, 0.004],
                     [width * 0.28, width * 0.24, width * 0.15, 0.002])
    batch.emit("hanging_moss")


SPECS: list[tuple[str, Callable[[int], None]]] = [
    ("alder", build_alder),
    ("hollow_tree", build_hollow_tree),
    ("uprooted_tree", build_uprooted_tree),
    ("mangrove_tree", build_mangrove_tree),
    ("duckweed", build_duckweed),
    ("hanging_moss", build_hanging_moss),
]


def seed_for(name: str) -> int:
    """A stable seed per asset name. Deliberately not `hash()`, which is salted
    per process in Python 3 and would make every rebuild a different asset."""
    return sum((index + 3) * ord(char) for index, char in enumerate(name))


# ---------------------------------------------------------------------------
# Assembly
# ---------------------------------------------------------------------------


def join_into_one(name: str, made: list) -> bpy.types.Object:
    meshes = [obj for obj in made if obj.type == "MESH"]
    if len(meshes) <= 1:
        if meshes:
            meshes[0].name = name
        return meshes[0] if meshes else made[0]
    bpy.ops.object.select_all(action="DESELECT")
    for obj in meshes:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = meshes[0]
    bpy.ops.object.join()
    joined = bpy.context.view_layer.objects.active
    joined.name = name
    # Bake the rotation into the mesh. `join` hands the result whichever rotation
    # the alphabetically-first component carried, and the exporter then writes it
    # out as a node transform on top of the geometry — which put A-011's resin node
    # 53 mm underground for anything measuring the GLB rather than its world matrix.
    # A static prop has no business shipping a rotation.
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=False)
    bpy.ops.object.select_all(action="DESELECT")
    return joined


def floating_islands(objects: list, tolerance: float = 0.02) -> list[str]:
    adrift = []
    for obj in objects:
        if obj.type != "MESH":
            continue
        lowest = min((obj.matrix_world @ v.co).z for v in obj.data.vertices)
        if lowest > tolerance:
            adrift.append(f"{obj.name} @ {lowest * 1000:.0f} mm")
    return adrift


def create_asset(name: str, build_fn: Callable[[int], None], display_location) -> dict:
    collection = bpy.data.collections.new(name)
    bpy.context.scene.collection.children.link(collection)
    root = bpy.data.objects.new(name, None)
    root.empty_display_type = "PLAIN_AXES"
    collection.objects.link(root)

    before = {obj.name for obj in bpy.data.objects}
    build_fn(seed_for(name))
    made = sorted((obj for obj in bpy.data.objects if obj.name not in before),
                  key=lambda obj: obj.name)

    if name in LIE_DOWN:
        # Rotate the world matrices directly rather than through `bpy.ops`, which
        # needs a pivot and a selection context that background mode makes fragile.
        # About Y, so the asset lies ACROSS the sheet rather than pointing at the
        # camera. Laying it about X first put it end-on and it rendered as a
        # starburst of head-ends with its whole length hidden behind them.
        rotation = Matrix.Rotation(LIE_DOWN[name], 4, "Y")
        for obj in made:
            obj.matrix_world = rotation @ obj.matrix_world
        bpy.context.view_layer.update()

    ground_and_centre(made)
    target, axis, _cap = SIZE[name]
    low, high = world_bounds(made)
    current = (high.z - low.z) if axis == "height" else max(high.x - low.x, high.y - low.y)
    if current > 1e-6:
        factor = target / current
        for obj in made:
            if obj.parent is None:
                obj.scale = obj.scale * factor
                obj.location = obj.location * factor
        bpy.context.view_layer.update()
        for obj in made:
            bpy.context.view_layer.objects.active = obj
            obj.select_set(True)
        bpy.ops.object.transform_apply(location=True, rotation=False, scale=True)
        bpy.ops.object.select_all(action="DESELECT")
    ground_and_centre(made)

    made = [join_into_one(name, made)]
    for obj in made:
        for old in list(obj.users_collection):
            old.objects.unlink(obj)
        collection.objects.link(obj)
        obj.parent = root
    bpy.context.view_layer.update()

    adrift = floating_islands(made)
    # Vertices, never `obj.bound_box`: Blender does not refresh the cached box
    # after a join, so a joined asset otherwise measures as its first component.
    corners = [obj.matrix_world @ vertex.co
               for obj in made if obj.type == "MESH" for vertex in obj.data.vertices]
    minimum = Vector((min(v.x for v in corners), min(v.y for v in corners),
                      min(v.z for v in corners)))
    maximum = Vector((max(v.x for v in corners), max(v.y for v in corners),
                      max(v.z for v in corners)))
    dimensions = maximum - minimum
    polygons = sum(len(obj.data.polygons) for obj in made if obj.type == "MESH")
    triangles = sum(sum(max(0, len(polygon.vertices) - 2) for polygon in obj.data.polygons)
                    for obj in made if obj.type == "MESH")
    materials = sorted({m.name for obj in made if obj.type == "MESH"
                        for m in obj.data.materials if m})

    bpy.ops.object.select_all(action="DESELECT")
    for obj in collection.objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = root
    bpy.ops.export_scene.gltf(filepath=str(EXPORT_DIR / f"{name}.glb"), export_format="GLB",
                              use_selection=True, export_apply=True, export_yup=True)
    root.location = display_location
    return {
        "name": name, "root": root,
        "width": dimensions.x, "depth": dimensions.y, "height": dimensions.z,
        "ground_offset": minimum.z, "target": target, "axis": axis, "adrift": adrift,
        "parts": sum(1 for obj in made if obj.type == "MESH"),
        "polygons": polygons, "triangles": triangles, "materials": materials,
    }


def check(records: list[dict]) -> list[str]:
    """Everything a machine can judge about this batch, judged — and failed on."""
    problems: list[str] = []
    for record in records:
        name = record["name"]
        target, axis, cap = SIZE[name]
        measured = record["height"] if axis == "height" else max(record["width"], record["depth"])
        if abs(measured - target) > SIZE_TOLERANCE:
            problems.append(f"{name}: {axis} {measured:.3f} m vs target {target:.3f} m")
        spread = max(record["width"], record["depth"])
        if spread > cap:
            problems.append(f"{name}: {spread:.2f} m across, footprint cap is {cap} m")
        if abs(record["ground_offset"]) > 0.005:
            problems.append(f"{name}: sits {record['ground_offset'] * 1000:.1f} mm off the ground")
        if record["adrift"]:
            problems.append(f"{name}: floating geometry: {record['adrift'][:3]}")
        if record["parts"] == 0 or record["polygons"] == 0:
            problems.append(f"{name}: exported no geometry")
        cap_triangles = TRIANGLE_ALLOWANCE.get(name, TRIANGLE_BUDGET)
        if record["triangles"] > cap_triangles:
            problems.append(f"{name}: {record['triangles']} triangles over {cap_triangles}")
        cap_materials = MATERIAL_ALLOWANCE.get(name, MAX_MATERIALS)
        if len(record["materials"]) > cap_materials:
            problems.append(f"{name}: {len(record['materials'])} materials, cap is {cap_materials}")
        if not record["materials"]:
            problems.append(f"{name}: no embedded materials")
        if not (EXPORT_DIR / f"{name}.glb").exists():
            problems.append(f"{name}: no GLB written")
    return problems


def main() -> None:
    EXPORT_DIR.mkdir(parents=True, exist_ok=True)
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    SOURCE_DIR.mkdir(parents=True, exist_ok=True)
    reset_materials()
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for datablocks in (bpy.data.materials, bpy.data.curves, bpy.data.cameras, bpy.data.lights):
        for block in list(datablocks):
            datablocks.remove(block)

    if len({name for name, _ in SPECS}) != len(SPECS):
        raise RuntimeError("wetland asset names must be unique")
    for name, _ in SPECS:
        if name not in SIZE:
            raise RuntimeError(f"{name} has no SIZE entry")

    records: list[dict] = []
    for index, (name, builder) in enumerate(SPECS):
        records.append(create_asset(name, builder, (index * 4.6 - 9.2, 0.0, 0.0)))

    problems = check(records)

    CATALOG_PATH.write_text(json.dumps({
        "batch": "A-015",
        "family": "wetland_nature",
        "blender": bpy.app.version_string,
        "assets": [
            {
                "name": r["name"], "file": f"exports/{r['name']}.glb",
                "width_m": round(r["width"], 4), "depth_m": round(r["depth"], 4),
                "height_m": round(r["height"], 4), "target_m": r["target"], "axis": r["axis"],
                "parts": r["parts"], "polygons": r["polygons"], "triangles": r["triangles"],
                "materials": r["materials"],
            }
            for r in records
        ],
    }, indent=2) + "\n")

    preview_collection = bpy.data.collections.new("Preview")
    bpy.context.scene.collection.children.link(preview_collection)
    bpy.ops.object.light_add(type="SUN", location=(4.0, -6.0, 8.0))
    key = bpy.context.object
    key.data.energy = 4.0
    look_at(key, (0.0, 0.0, 0.0))
    bpy.ops.object.light_add(type="SUN", location=(-6.0, 4.0, 5.0))
    fill = bpy.context.object
    fill.data.energy = 1.4
    look_at(fill, (0.0, 0.0, 0.0))
    bpy.ops.object.camera_add()
    camera = bpy.context.object
    camera.name = "Preview_Camera"
    scene = bpy.context.scene
    scene.camera = camera
    scene.render.engine = eevee_engine()
    scene.render.resolution_x = 1500
    scene.render.image_settings.file_format = "PNG"
    scene.render.film_transparent = False
    scene.world.color = (0.016, 0.021, 0.028)
    scene.view_settings.look = "AgX - Medium High Contrast"
    for obj in (key, fill, camera):
        for old in list(obj.users_collection):
            old.objects.unlink(obj)
        preview_collection.objects.link(obj)

    bpy.ops.mesh.primitive_cube_add(location=(0, 0, 0.9))
    figure = bpy.context.object
    figure.name = "Scale_Reference"
    figure.scale = (0.20, 0.13, 0.90)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    figure.data.materials.append(mat("reference_blue"))
    for old in list(figure.users_collection):
        old.objects.unlink(figure)
    preview_collection.objects.link(figure)

    def set_visible(record: dict, visible: bool) -> None:
        record["root"].hide_render = not visible
        for child in record["root"].children_recursive:
            child.hide_render = not visible

    first_x = -9.2
    last_x = first_x + (len(records) - 1) * 4.6
    widest = max(max(r["width"], r["depth"]) for r in records)
    figure_x = first_x - widest * 0.5 - 1.1
    left = figure_x - 0.9
    right = last_x + widest * 0.5 + 0.9
    span = right - left
    centre_x = (left + right) * 0.5
    # Vertical extent is driven by the 1.80 m reference standing in the sheet, not
    # by a fixed aspect: at one asset the span is narrow, and a fixed 0.52 ratio
    # framed 1.17 m of world and cut the bundle off at the ankles.
    view_height = max(2.35, max(r["height"] for r in records) * 1.16)
    camera.data.type = "ORTHO"
    camera.data.ortho_scale = span
    scene.render.resolution_y = int(1500 * view_height / span)
    figure.location = (figure_x, 0.0, 0.9)
    camera.location = (centre_x, -12.0, view_height * 0.5 - 0.14)
    look_at(camera, (centre_x, 0.0, view_height * 0.5 - 0.14))
    scene.render.filepath = str(PREVIEW_DIR / "wetland_nature_preview.png")
    bpy.ops.render.render(write_still=True)

    bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE_PATH))

    print(f"\nWETLAND_NATURE_BUILD assets={len(records)} "
          f"triangles={sum(r['triangles'] for r in records)} blender={bpy.app.version_string}")
    for record in records:
        print("  %-22s %5.2f x %5.2f x %5.2f m  %4d tris  %d mats  %s"
              % (record["name"], record["width"], record["depth"], record["height"],
                 record["triangles"], len(record["materials"]),
                 ",".join(m.replace("MIRE_", "") for m in record["materials"])))
    if problems:
        print(f"\nWETLAND_NATURE_CHECK FAIL ({len(problems)})")
        for problem in problems:
            print(f"  {problem}")
        raise SystemExit(1)
    print("WETLAND_NATURE_CHECK PASS")


if __name__ == "__main__":
    main()
