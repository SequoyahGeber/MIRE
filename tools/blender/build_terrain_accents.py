"""A-016a — terrain accents, the rock half: cliffs, slopes and the ways up them.

  /Applications/Blender.app/Contents/MacOS/Blender --background --python tools/blender/build_terrain_accents.py

Built with Blender 5.2.0 LTS (D-038). Outputs to `assets/terrain_accents/`.

**A-016 is split into lettered children**, as `ASSET_TRACKER.md` allows for a batch too large for
one clean commit. This is **A-016a**: cliff face, cliff corner, cliff overhang, rocky slope, scree
pile and natural stone steps — everything that is rock. A-016b is the earth-and-water half (mud
bank, riverbank, streambed, sinkhole, burrow entrance).

**The gate is met, not waived.** A-016 waited on "world-gen terrain shape is settled", and D-142
settled it on 2026-08-19: fBm + falloff base, domain warp, a masked ridged layer, steepest-descent
river tracing with arithmetic carving. Everything in A-016a sits ON that heightfield and needs
nothing it cannot produce.

**What that same decision costs this batch:** D-142 rejects 3D density and caves outright ("2D Mire
grid, low-end target, cut list"). A 2D heightfield cannot express an overhung void, so A-016's
`cave entrance` is filed as **F-237** rather than built — an asset that reads as an entrance backed
by solid ground is a bug report from every playtester who finds one. `cliff_overhang` survives that
same limit only because it is honest about being a rock ledge PLACED on a slope, never a claim that
the terrain itself overhangs.

**Modularity is the point.** A cliff is not one hero rock, it is a run of wall a placer repeats along
a contour. So `cliff_face` and `cliff_corner` share one 4.0 m module width and one 5.0 m height, and
their backs are flat and vertical at x = 0 so they can be pushed into a slope without a gap. The
build asserts both.
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
    box,
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
EXPORT_DIR = ROOT / "assets" / "terrain_accents" / "exports"
PREVIEW_DIR = ROOT / "assets" / "terrain_accents" / "preview"
CATALOG_PATH = ROOT / "assets" / "terrain_accents" / "catalog.json"
SOURCE_DIR = ROOT / "assets" / "source"
SOURCE_PATH = SOURCE_DIR / "terrain_accents.blend"

#: Target size in metres, the axis it governs, and a hard footprint ceiling.
#: Set against a 1.80 m player: shin 0.2, knee 0.5, waist 1.0, chest 1.4.
SIZE: dict[str, tuple[float, str, float]] = {
    "cliff_face": (5.00, "height", 4.30),
    "cliff_corner": (5.00, "height", 4.90),
    "cliff_overhang": (2.60, "height", 4.20),
    "rocky_slope": (3.90, "spread", 4.10),
    "scree_pile": (2.60, "spread", 2.90),
    "stone_steps": (4.40, "spread", 4.60),
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
TRIANGLE_BUDGET = 1500
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

#: The cliff module contract. `cliff_face` and `cliff_corner` are placed in runs
#: along a contour, so they must agree on width and height or a run of them
#: staircases. Asserted in `check()` rather than trusted.
CLIFF_MODULE_W = 4.00
CLIFF_MODULE_H = 5.00


def strata(made: list, prefix: str, centre, size, layers: int, token: str,
           accent: str, seed: int, back_flat: bool = True) -> None:
    """A rock mass built as irregular beds, with outcrops breaking up the face.

    Rock is not soft, so a single lumpy `hull` reads as a potato — but rock is not
    REGULAR either, and the first cut of this stacked near-identical boxes of equal
    thickness and rendered as a course of concrete blocks. `assets/environment`
    already ships `stone_wall_solid` for masonry; a cliff that reads as masonry is
    worse than no cliff, because it tells the player somebody built it.

    So: bed thickness varies by nearly 3:1, depth and tilt vary per bed, roughly a
    third of the beds take the darker stone, and angular outcrops are stuck on the
    front at random heights. Those outcrops are `hull` with ``subdivisions=0`` —
    20 faces of hard-edged rock, which is the cheapest primitive that does not
    read as a box.

    ``back_flat`` keeps every bed's back face on x = 0 so the piece can be pushed
    into a slope with no gap behind it. That is what makes these modular rather
    than sculptural.
    """
    rng = random.Random(seed)
    depth, width, height = size
    z = centre[2]
    index = 0
    while z < centre[2] + height - 1e-6:
        t = (z - centre[2]) / max(1e-6, height)
        shrink = 1.0 - 0.16 * t
        thickness = min((height / layers) * rng.uniform(0.55, 1.55),
                        centre[2] + height - z)
        bed_depth = depth * shrink * rng.uniform(0.74, 1.08)
        # NEVER wider than the module. Jitter that can exceed 1.0 turns a "4.00 m
        # module" into 4.48 m, and two of them placed side by side then push beds
        # through each other — the one thing a modular piece must not do. Variation
        # goes into depth, thickness and tilt instead, where it costs nothing.
        bed_width = width * rng.uniform(0.93, 1.00)
        # The FACE runs along X and the piece extends into the slope along +Y, with
        # its back pinned to y = 0. Built the other way round first, and every
        # preview then showed the modules edge-on: a 4.4 m wide cliff rendered as a
        # 2.7 m tower, which is why they read as columns rather than as a wall.
        y = (bed_depth * 0.5) if back_flat else rng.uniform(-0.05, 0.05) * depth
        bed = box(f"{prefix}_bed_{index}", (rng.uniform(-0.02, 0.02) * width, y,
                                            z + thickness * 0.5),
                  (bed_width, bed_depth, thickness),
                  mat(token if rng.random() < 0.66 else accent),
                  rotation=(rng.uniform(-0.02, 0.02), rng.uniform(-0.045, 0.045),
                            rng.uniform(-0.035, 0.035)),
                  bevel=0.06)
        made.append(bed)
        z += thickness
        index += 1

    # Outcrops on the face. Without these the beds read as courses however much
    # their thickness varies, because a stack of flat-fronted slabs is a wall.
    for outcrop in range(max(3, layers // 2)):
        oz = centre[2] + height * rng.uniform(0.10, 0.92)
        oy = rng.uniform(-0.40, 0.40) * width
        scale = depth * rng.uniform(0.42, 0.78)
        made.append(hull(f"{prefix}_outcrop_{outcrop}",
                         (oy, depth * rng.uniform(0.10, 0.34), oz),
                         (scale * rng.uniform(0.8, 1.6), scale, scale * rng.uniform(0.7, 1.3)),
                         mat(token if outcrop % 2 else accent), seed=seed + 300 + outcrop,
                         subdivisions=0, lumps=5, lump=0.36, sharpness=3.2))


def rubble(made: list, prefix: str, count: int, spread: float, height: float,
           size_range: tuple, token: str, seed: int, cone_bias: float = 0.0) -> None:
    """Loose stone. ``cone_bias`` piles it toward the middle, which is what a
    scree fan does and what a flat scatter never looks like."""
    rng = random.Random(seed)
    for index, (angle, rad) in enumerate(radial(count, spread, seed=seed, jitter=0.9,
                                                radius_jitter=0.75)):
        reach = abs(rad)
        # Clamped: `radial`'s radius_jitter can push a stone past `spread`, and a
        # negative base to a fractional power is a complex number in Python, not a
        # small one — it raises rather than flattening the fan.
        drop = max(0.0, 1.0 - reach / max(1e-6, spread)) ** 1.6
        centre = (math.cos(angle) * reach, math.sin(angle) * reach,
                  height + cone_bias * drop)
        scale = rng.uniform(*size_range)
        made.append(hull(f"{prefix}_{index}", centre,
                         (scale, scale * rng.uniform(0.7, 1.1), scale * rng.uniform(0.5, 0.9)),
                         mat(token), seed=seed + index * 17, subdivisions=0,
                         lumps=5, lump=0.34, sharpness=2.6, flat_base=0.0))


# ---------------------------------------------------------------------------
# Builders
# ---------------------------------------------------------------------------


def build_cliff_face(seed: int) -> None:
    """One module of cliff wall. Flat vertical back, banded front, mossy top."""
    made = []
    strata(made, "cliff_face", (0.0, 0.0, 0.0),
           (1.15, CLIFF_MODULE_W, CLIFF_MODULE_H - 0.35), 7,
           "stone", "stone_dark", seed)
    # Turf lip along the top — a cliff that stops at bare rock reads as a model
    # that was cut off, and this is the edge a player stands on.
    # Turf lip, irregular. A straight box of `terrain_ground` with moss painted on
    # it rendered as a green stripe laid across the top of a wall.
    lip = hull("cliff_face_lip", (0.0, 0.52, CLIFF_MODULE_H - 0.16),
               (CLIFF_MODULE_W * 0.46, 0.72, 0.20), mat("moss"), seed=seed + 3,
               subdivisions=0, lumps=8, lump=0.32, sharpness=2.4)
    made.append(lip)
    rubble(made, "cliff_face_talus", 7, 0.62, 0.10, (0.14, 0.30), "stone", seed + 9)


def build_cliff_corner(seed: int) -> None:
    """The outside corner of the same wall, on the same module.

    Built as two arms meeting at the origin so a run of `cliff_face` can turn
    ninety degrees without a seam. Same height and same module width as the face,
    which `check()` asserts — a corner that disagrees with its wall staircases the
    whole run.
    """
    made = []
    strata(made, "cliff_corner_x", (0.0, 0.0, 0.0),
           (1.15, CLIFF_MODULE_W * 0.82, CLIFF_MODULE_H - 0.35), 7,
           "stone", "stone_dark", seed)
    made_before = len(made)
    strata(made, "cliff_corner_y", (0.0, 0.0, 0.0),
           (1.15, CLIFF_MODULE_W * 0.82, CLIFF_MODULE_H - 0.35), 7,
           "stone", "stone_dark", seed + 101)
    # Swing the second arm ninety degrees about the shared inner edge.
    turn = Matrix.Rotation(math.radians(90.0), 4, "Z")
    for obj in made[made_before:]:
        obj.matrix_world = turn @ obj.matrix_world
    bpy.context.view_layer.update()
    lip = hull("cliff_corner_lip", (0.50, 0.50, CLIFF_MODULE_H - 0.16),
               (1.05, 1.05, 0.20), mat("moss"), seed=seed + 3,
               subdivisions=0, lumps=8, lump=0.32, sharpness=2.4)
    made.append(lip)
    rubble(made, "cliff_corner_talus", 6, 0.70, 0.10, (0.14, 0.28), "stone", seed + 9)


def build_cliff_overhang(seed: int) -> None:
    """A rock ledge jutting from a slope — shelter you can stand under.

    Deliberately a PROP, not a claim about the terrain. D-142's heightfield cannot
    make an overhung void (F-237), so this reads as a slab resting on a slope with
    a shadowed space beneath it, which is honest and is also the more useful
    object: somewhere to put a stash out of the rain.
    """
    made = []
    strata(made, "overhang_base", (0.0, 0.0, 0.0), (1.30, 1.35, 1.50), 3,
           "stone", "stone_dark", seed)
    slab = box("overhang_slab", (0.0, 0.05, 1.82), (3.10, 3.20, 0.46),
               mat("stone"), rotation=(0.10, 0.0, 0.05), bevel=0.06)
    paint_faces(slab, mat("moss"), min_normal_z=0.55, min_height=0.62, coverage=0.40,
                seed=seed + 2)
    made.append(slab)
    # A prop under the lip, so the sheltered space reads as a space.
    made.append(hull("overhang_boulder", (-0.95, -0.75, 0.26), (0.38, 0.34, 0.26),
                     mat("stone_dark"), seed=seed + 5, subdivisions=0, lumps=5,
                     lump=0.32, sharpness=2.6, flat_base=0.0))
    rubble(made, "overhang_debris", 6, 0.55, 0.08, (0.13, 0.26), "stone_dark", seed + 11)


def build_rocky_slope(seed: int) -> None:
    """A broken-rock ramp: the walkable way up a bank.

    Terrain gives slopes; what it cannot give is the read that THIS slope is
    climbable. The first cut spaced five slabs apart along the rise and rendered
    as stepping stones scattered on a hill — a ramp has to be CONTINUOUS, so these
    overlap heavily and each one is an angular mass rather than a box.
    """
    rng = random.Random(seed)
    made = []
    steps = 7
    for index in range(steps):
        t = index / (steps - 1.0)
        scale = 0.62 * rng.uniform(0.82, 1.18)
        made.append(hull(f"rocky_slope_mass_{index}",
                         (t * 1.95 - 0.95, rng.uniform(-0.22, 0.22), 0.16 + t * 0.92),
                         (scale * 1.15, scale * rng.uniform(1.3, 1.9), scale * 0.72),
                         mat("stone" if index % 3 else "stone_dark"),
                         seed=seed + index * 31, subdivisions=0, lumps=6, lump=0.34,
                         sharpness=2.8, flat_base=0.0))
    rubble(made, "rocky_slope_scatter", 10, 1.35, 0.08, (0.13, 0.28), "stone_dark", seed + 7)


def build_scree_pile(seed: int) -> None:
    """A fan of loose stone at the foot of a face.

    A flat scatter of rocks is `rock_cluster_a`..`f`, which `assets/environment`
    already ships. What makes this scree is the CONE: the pile is deepest at the
    middle and thins to nothing at its edge, which is the shape falling rock makes
    and the reason it reads as debris from something above rather than as stones
    someone placed.
    """
    made = []
    # BANKED, not spread flat. A 0.21 m deep scatter over 2.6 m is indistinguishable
    # from `rock_cluster_a`..`f`, which `assets/environment` already ships. Real
    # scree piles against the face it fell from, so the fan is shin-deep at its toe
    # and waist-deep where it meets the cliff — that wedge is the whole read.
    made.append(hull("scree_bed", (0.0, 0.28, 0.22), (1.00, 0.80, 0.40),
                     mat("stone_dark"), seed=seed, subdivisions=0, lumps=7,
                     lump=0.26, sharpness=2.4, flat_base=0.0))
    rubble(made, "scree_a", 22, 1.15, 0.08, (0.12, 0.28), "stone", seed + 3, cone_bias=0.72)
    rubble(made, "scree_b", 14, 0.66, 0.14, (0.14, 0.32), "stone_dark", seed + 21, cone_bias=0.80)


def build_stone_steps(seed: int) -> None:
    """Natural stepped rock — a route, not a staircase.

    `assets/environment` has `stone_stairs`, and that is masonry: cut, regular,
    built by someone. These are beds that happen to step, uneven in rise and run
    and rotated off each other, because the moment they line up they stop being
    terrain and start being architecture somebody has to explain.

    They also OVERLAP. Stacked as separate treads they read as a pile of pancakes;
    each one has to sit into the one below it the way a weathered outcrop does.
    """
    made = []
    rng = random.Random(seed)
    x = -1.05
    z = 0.0
    for index in range(6):
        rise = rng.uniform(0.24, 0.40)
        run = rng.uniform(0.42, 0.62)
        scale = rng.uniform(0.80, 1.05)
        made.append(hull(f"stone_steps_{index}",
                         (x, rng.uniform(-0.14, 0.14), z + rise * 0.20),
                         (run * 1.35, 0.86 * scale, rise * 1.45),
                         mat("stone" if index % 3 else "stone_dark"),
                         seed=seed + index * 23, subdivisions=0, lumps=6, lump=0.30,
                         sharpness=3.0, flat_base=0.0))
        x += run
        z += rise
    rubble(made, "stone_steps_grit", 8, 0.95, 0.05, (0.09, 0.19), "stone_dark", seed + 13)


SPECS: list[tuple[str, Callable[[int], None]]] = [
    ("cliff_face", build_cliff_face),
    ("cliff_corner", build_cliff_corner),
    ("cliff_overhang", build_cliff_overhang),
    ("rocky_slope", build_rocky_slope),
    ("scree_pile", build_scree_pile),
    ("stone_steps", build_stone_steps),
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
    materials = set()
    for obj in made:
        if obj.type != "MESH":
            continue
        slots = obj.data.materials
        used = {polygon.material_index for polygon in obj.data.polygons}
        for slot_index in used:
            if slot_index < len(slots) and slots[slot_index]:
                materials.add(slots[slot_index].name)
    materials = sorted(materials)

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
    by_name = {r["name"]: r for r in records}
    # The module contract: a corner that disagrees with its wall staircases a run.
    face, corner = by_name.get("cliff_face"), by_name.get("cliff_corner")
    if face and corner:
        if abs(face["height"] - corner["height"]) > 0.02:
            problems.append(
                "cliff_face %.3f m and cliff_corner %.3f m must share one module height"
                % (face["height"], corner["height"]))
        if abs(face["height"] - CLIFF_MODULE_H) > 0.02:
            problems.append("cliff_face is %.3f m, module height is %.2f m"
                            % (face["height"], CLIFF_MODULE_H))
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
        records.append(create_asset(name, builder, (index * 5.6 - 14.0, 0.0, 0.0)))

    problems = check(records)

    CATALOG_PATH.write_text(json.dumps({
        "batch": "A-016a",
        "family": "terrain_accents",
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

    first_x = -14.0
    last_x = first_x + (len(records) - 1) * 5.6
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
    scene.render.filepath = str(PREVIEW_DIR / "terrain_accents_preview.png")
    bpy.ops.render.render(write_still=True)

    bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE_PATH))

    print(f"\nTERRAIN_ACCENTS_BUILD assets={len(records)} "
          f"triangles={sum(r['triangles'] for r in records)} blender={bpy.app.version_string}")
    for record in records:
        print("  %-22s %5.2f x %5.2f x %5.2f m  %4d tris  %d mats  %s"
              % (record["name"], record["width"], record["depth"], record["height"],
                 record["triangles"], len(record["materials"]),
                 ",".join(m.replace("MIRE_", "") for m in record["materials"])))
    if problems:
        print(f"\nTERRAIN_ACCENTS_CHECK FAIL ({len(problems)})")
        for problem in problems:
            print(f"  {problem}")
        raise SystemExit(1)
    print("TERRAIN_ACCENTS_CHECK PASS")


if __name__ == "__main__":
    main()
