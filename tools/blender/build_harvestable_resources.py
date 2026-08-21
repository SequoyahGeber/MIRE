"""Build MIRE's first harvestable resource state set (asset batch A-001).

Run with:
  Blender --background --python tools/blender/build_harvestable_resources.py

Outputs 17 individual metre-scale GLBs, an editable Blender source, a JSON
catalog, and two preview renders. Geometry and layout are deterministic.

Every harvestable runs a **five-state chain**: intact, three progressively worse
damaged states, and depleted (F-425). `HarvestableDef.active_state_scenes`
divides the prop's health evenly across whatever it is given, so the count is an
art decision — and two damaged states across six or nine swings meant most hits
landed with nothing changing on screen. Each stage below is modelled on what the
real job actually does to the material, not on "the same mesh, smaller".
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path
from typing import Callable

import bpy

sys.path.append(str(Path(__file__).resolve().parent))
from mire_art import mat, radial, around, reset_materials  # noqa: E402
from godot_import_lock import import_cache_guard  # noqa: E402
from mathutils import Vector


ROOT = Path(__file__).resolve().parents[2]
ASSET_DIR = ROOT / "assets" / "harvestables"
SOURCE_DIR = ROOT / "assets" / "source"
EXPORT_DIR = ASSET_DIR / "exports"
PREVIEW_DIR = ASSET_DIR / "preview"

EXPECTED_NAMES = [
    "harvest_tree_intact",
    "harvest_tree_damaged_a",
    "harvest_tree_damaged_b",
    "harvest_tree_damaged_c",
    "harvest_tree_felled_trunk",
    "harvest_tree_fresh_stump",
    "harvest_tree_depleted_stump",
    "stone_node_intact",
    "stone_node_chipped",
    "stone_node_cracked",
    "stone_node_shattered",
    "stone_node_depleted",
    "iron_node_intact",
    "iron_node_chipped",
    "iron_node_cracked",
    "iron_node_shattered",
    "iron_node_depleted",
]


def assign(obj: bpy.types.Object, mat: bpy.types.Material) -> bpy.types.Object:
    obj.data.materials.append(mat)
    for polygon in obj.data.polygons:
        polygon.use_smooth = False
    return obj


def cone(
    name: str,
    radius_bottom: float,
    radius_top: float,
    depth: float,
    location: tuple[float, float, float],
    mat: bpy.types.Material,
    vertices: int = 8,
    rotation: tuple[float, float, float] = (0.0, 0.0, 0.0),
) -> bpy.types.Object:
    bpy.ops.mesh.primitive_cone_add(
        vertices=vertices,
        radius1=radius_bottom,
        radius2=radius_top,
        depth=depth,
        location=location,
        rotation=rotation,
    )
    obj = bpy.context.object
    obj.name = name
    return assign(obj, mat)


def ico(
    name: str,
    location: tuple[float, float, float],
    scale: tuple[float, float, float],
    mat: bpy.types.Material,
    rotation: tuple[float, float, float] = (0.0, 0.0, 0.0),
) -> bpy.types.Object:
    bpy.ops.mesh.primitive_ico_sphere_add(
        subdivisions=1,
        radius=1.0,
        location=location,
        rotation=rotation,
    )
    obj = bpy.context.object
    obj.name = name
    obj.scale = scale
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    return assign(obj, mat)


def box(
    name: str,
    location: tuple[float, float, float],
    dimensions: tuple[float, float, float],
    mat: bpy.types.Material,
    rotation: tuple[float, float, float] = (0.0, 0.0, 0.0),
) -> bpy.types.Object:
    bpy.ops.mesh.primitive_cube_add(location=location, rotation=rotation)
    obj = bpy.context.object
    obj.name = name
    obj.scale = (dimensions[0] * 0.5, dimensions[1] * 0.5, dimensions[2] * 0.5)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    return assign(obj, mat)


def cylinder_between(
    name: str,
    start: tuple[float, float, float],
    end: tuple[float, float, float],
    radius: float,
    mat: bpy.types.Material,
    vertices: int = 8,
) -> bpy.types.Object:
    first = Vector(start)
    second = Vector(end)
    direction = second - first
    obj = cone(
        name,
        radius,
        radius * 0.82,
        direction.length,
        tuple((first + second) * 0.5),
        mat,
        vertices,
    )
    obj.rotation_mode = "QUATERNION"
    obj.rotation_quaternion = direction.to_track_quat("Z", "Y")
    return obj


def tapered_between(
    name: str,
    start: tuple[float, float, float],
    end: tuple[float, float, float],
    radius_start: float,
    radius_end: float,
    mat: bpy.types.Material,
    vertices: int = 8,
) -> bpy.types.Object:
    first = Vector(start)
    second = Vector(end)
    direction = second - first
    obj = cone(
        name,
        radius_start,
        radius_end,
        direction.length,
        tuple((first + second) * 0.5),
        mat,
        vertices,
    )
    obj.rotation_mode = "QUATERNION"
    obj.rotation_quaternion = direction.to_track_quat("Z", "Y")
    return obj


def notched_trunk_band(
    name: str,
    z_bottom: float,
    z_top: float,
    radius_bottom: float,
    radius_top: float,
    depth: float,
    bark_mat: bpy.types.Material,
    cut_mat: bpy.types.Material,
    core_mat: bpy.types.Material,
) -> bpy.types.Object:
    """Build a concave axe notch into the trunk rather than pasting one on."""
    segments = 12
    rings = (z_bottom, (z_bottom + z_top) * 0.5, z_top)
    vertices: list[tuple[float, float, float]] = []
    for ring_index, z in enumerate(rings):
        blend = ring_index / 2.0
        outer_radius = radius_bottom + (radius_top - radius_bottom) * blend
        for segment in range(segments):
            angle = segment * math.tau / segments
            front_delta = abs(math.atan2(math.sin(angle + math.pi * 0.5), math.cos(angle + math.pi * 0.5)))
            radius = outer_radius
            if ring_index == 1 and front_delta < math.radians(18):
                radius *= depth
            elif ring_index == 1 and front_delta < math.radians(48):
                radius *= min(0.88, depth + 0.32)
            vertices.append((math.cos(angle) * radius, math.sin(angle) * radius, z))

    faces: list[tuple[int, int, int, int]] = []
    material_indices: list[int] = []
    for ring_index in range(2):
        for segment in range(segments):
            following = (segment + 1) % segments
            faces.append(
                (
                    ring_index * segments + segment,
                    ring_index * segments + following,
                    (ring_index + 1) * segments + following,
                    (ring_index + 1) * segments + segment,
                )
            )
            angle = (segment + 0.5) * math.tau / segments
            front_delta = abs(math.atan2(math.sin(angle + math.pi * 0.5), math.cos(angle + math.pi * 0.5)))
            material_indices.append(2 if front_delta < math.radians(17) else 1 if front_delta < math.radians(50) else 0)

    mesh = bpy.data.meshes.new(f"{name}_Mesh")
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    obj.data.materials.append(bark_mat)
    obj.data.materials.append(cut_mat)
    obj.data.materials.append(core_mat)
    for polygon, material_index in zip(obj.data.polygons, material_indices):
        polygon.material_index = material_index
        polygon.use_smooth = False
    return obj


def look_at(obj: bpy.types.Object, target: tuple[float, float, float]) -> None:
    obj.rotation_euler = (Vector(target) - obj.location).to_track_quat("-Z", "Y").to_euler()


def move_to_collection(objects: list[bpy.types.Object], collection: bpy.types.Collection) -> None:
    for obj in objects:
        for old_collection in list(obj.users_collection):
            old_collection.objects.unlink(obj)
        collection.objects.link(obj)


def create_asset(
    name: str,
    family: str,
    state: str,
    build_fn: Callable[[], None],
    display_location: tuple[float, float, float],
) -> dict:
    collection = bpy.data.collections.new(name)
    bpy.context.scene.collection.children.link(collection)
    root = bpy.data.objects.new(name, None)
    root.empty_display_type = "PLAIN_AXES"
    collection.objects.link(root)
    before_names = {obj.name for obj in bpy.data.objects}
    build_fn()
    made = sorted((obj for obj in bpy.data.objects if obj.name not in before_names), key=lambda obj: obj.name)
    move_to_collection(made, collection)
    for obj in made:
        obj.parent = root
    bpy.context.view_layer.update()

    corners: list[Vector] = []
    for obj in made:
        if obj.type == "MESH":
            corners.extend(obj.matrix_world @ Vector(corner) for corner in obj.bound_box)
    minimum = Vector((min(v.x for v in corners), min(v.y for v in corners), min(v.z for v in corners)))
    maximum = Vector((max(v.x for v in corners), max(v.y for v in corners), max(v.z for v in corners)))
    dimensions = maximum - minimum
    polygons = sum(len(obj.data.polygons) for obj in made if obj.type == "MESH")
    materials = sorted(
        {mat.name for obj in made if obj.type == "MESH" for mat in obj.data.materials if mat}
    )

    bpy.ops.object.select_all(action="DESELECT")
    for obj in collection.objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = root
    bpy.ops.export_scene.gltf(
        filepath=str(EXPORT_DIR / f"{name}.glb"),
        export_format="GLB",
        use_selection=True,
        export_apply=True,
        export_yup=True,
    )
    root.location = display_location
    return {
        "name": name,
        "family": family,
        "state": state,
        "root": root,
        "width": dimensions.x,
        "depth": dimensions.y,
        "height": dimensions.z,
        "parts": sum(1 for obj in made if obj.type == "MESH"),
        "polygons": polygons,
        "materials": materials,
    }


def build_tree_base(mats: dict[str, bpy.types.Material], damage: int) -> None:
    """The standing harvest tree at damage 0-3 — one tree being felled, in stages.

    F-425. The stages are what an axe actually does to a standing conifer, in
    order, because "the same tree with a smaller notch" is not a stage and does
    not read as progress from six metres away:

      0  untouched
      1  the face cut is opened — a shallow wedge on one side, bright sapwood
         showing, the first chips on the ground
      2  the notch is most of the way in, dead lower branches have been knocked
         off by the work, and there is a real chip pile
      3  the hinge is nearly cut through, so **the tree is visibly leaning into
         its own notch** and shedding: half the branches gone, the crown thinned,
         the notch a dark cavity. This is the state that has to say "one more
         swing", and lean is what says it — a leaning tree is unmistakable at a
         distance where a notch is four pixels wide.

    The base of the trunk never moves, at any stage. The prop's collider and its
    harvest proxy are authored against the shared footprint (ASSET_TRACKER.md's
    state-set rule), so the lean has to come out of the trunk BENDING above the
    notch, not out of tilting the whole asset.
    """
    # F-425. **15.4 m, not 5.35.** F-396 raised every tree in the environment and
    # flora kits and this one was missed, because it lives in the harvestable kit
    # and nobody auditing "the trees" looked here — so the one tree the player
    # walks right up to and swings an axe at was the shortest in the game, at
    # 3.1x a 1.7 m eye where a real conifer reads at 6-15x. Sequoyah has now
    # raised tree height four separate times; "keep those trees tall, trees ain't
    # short" is the standing rule, and it means every asset that is a tree.
    #
    # The height is built in rather than fixed by a scale factor, for F-396's
    # reason: scaling uniformly gives a proportionally fatter trunk and reads as
    # the same tree seen from closer. The base radius goes 0.48 -> 0.62 while the
    # height goes 5.35 -> 15.4, i.e. the trunk gets 1.3x thicker for a tree 2.9x
    # taller. That ratio IS the read.
    #
    # The axe notch stays at 0.80-1.48 m. It is cut where a person can swing,
    # which does not change with the size of the tree.
    height = 15.4
    # Everything above the notch swings toward the face cut as the hinge thins.
    # A real tree does this because the wood left holding it is no longer enough
    # to keep it upright, so the movement starts AT the notch and grows with
    # height — which is why it is applied as an offset scaled by z, not a tilt.
    lean = (0.0, 0.0, -0.10, -0.46)[min(3, damage)]

    def swing(point: Vector) -> Vector:
        if lean == 0.0:
            return point
        above = max(0.0, point.z - 1.48) / (height - 1.48)
        return point + Vector((0.0, lean * above * above, -0.06 * above * above))

    lower_top = swing(Vector((0.11, -0.06, 7.40)))
    upper_top = swing(Vector((0.44, 0.09, height)))
    if damage == 0:
        tapered_between("Trunk_Lower", (0.0, 0.0, 0.0), tuple(lower_top), 0.62, 0.34, mats["bark"], 9)
    else:
        tapered_between("Trunk_Base", (0.0, 0.0, 0.0), (0.01, -0.005, 0.80), 0.62, 0.57, mats["bark"], 9)
        # Notch depth as a fraction of the trunk radius: shallow, deep, nearly
        # through. At 0.16 the far wall of the cut is all that is left holding it.
        notch_depth = (0.54, 0.30, 0.16)[damage - 1]
        notch = notched_trunk_band(
            "Axe_Notch",
            0.80,
            1.48,
            0.57,
            0.53,
            notch_depth,
            mats["bark"],
            mats["cut"],
            mats["cut_dark"] if damage == 1 else mats["notch"],
        )
        notch.location = (0.01, -0.005, 0.0)
        tapered_between("Trunk_Above_Notch", (0.01, -0.005, 1.48), tuple(lower_top), 0.53, 0.34, mats["bark"], 9)
    tapered_between("Trunk_Upper", tuple(lower_top), tuple(upper_top), 0.34, 0.085, mats["bark_dark"], 8)

    # Dark at the bottom of the crown, lit at the top — six tiers now, so the
    # ramp is indexed by height fraction rather than by a four-entry tuple that
    # silently ran off its end when the tier count changed.
    foliage_mats = (mats["pine_dark"], mats["pine_dark"], mats["pine_dark"],
                    mats["pine_light"], mats["pine_light"], mats["pine_light"])
    # Which branches are gone, cumulatively. Damage 2 loses the three that the
    # work would knock off; damage 3 loses those plus five more, and the ones
    # that survive keep smaller needle masses — a tree this far into being felled
    # has been shaken hard several times.
    broken_at_2 = {(0, 1), (1, 3), (2, 0), (4, 2)}
    broken_at_3 = broken_at_2 | {(0, 3), (1, 0), (2, 2), (3, 1), (3, 4), (4, 0), (5, 3)}
    broken_set = broken_at_3 if damage >= 3 else broken_at_2 if damage == 2 else set()
    needle_scale = 0.82 if damage >= 3 else 1.0
    # Six tiers over 15 m instead of four over 5 m, and the lowest is at 6.6 m —
    # a conifer whose live branches start at your knees is a bush, and the bare
    # bole under the crown is most of what makes a tall tree read as tall.
    tiers = (6.60, 8.20, 9.75, 11.25, 12.65, 13.90)
    for tier, z in enumerate(tiers):
        t = tier / float(len(tiers) - 1)
        center = lower_top.lerp(upper_top, max(0.0, (z - lower_top.z) / (upper_top.z - lower_top.z)))
        branch_count = 5
        branch_length = 2.25 - t * 0.95
        for branch in range(branch_count):
            angle = branch * math.tau / branch_count + tier * 0.57
            radial = Vector((math.cos(angle), math.sin(angle), 0.0))
            end = center + radial * branch_length + Vector((0.0, 0.0, -0.30 + (branch % 2) * 0.16))
            broken = (tier, branch) in broken_set
            if broken:
                end = center.lerp(end, 0.42 if damage == 2 else 0.30)
            tapered_between(
                f"Branch_{tier + 1}_{branch + 1}",
                tuple(center),
                tuple(end),
                0.135 - t * 0.040,
                0.030,
                mats["bark_dark"],
                7,
            )
            if broken:
                cone(f"Broken_Branch_Cut_{tier + 1}_{branch + 1}", 0.037, 0.037, 0.025, tuple(end), mats["cut"], 7)
                continue
            scale = (0.86 - t * 0.24) * needle_scale
            ico(
                f"Needles_{tier + 1}_{branch + 1}",
                tuple(center.lerp(end, 0.80)),
                (scale * 1.18, scale * 0.68, scale * 0.60),
                foliage_mats[tier],
                (0.08 * (branch % 2), -0.06 * (tier % 2), angle),
            )
            if branch % 2 == tier % 2 and damage < 3:
                ico(
                    f"Needle_Tip_{tier + 1}_{branch + 1}",
                    tuple(end),
                    (scale * 0.72, scale * 0.48, scale * 0.48),
                    mats["pine_light"],
                    (-0.10, 0.07, angle + 0.30),
                )
    leader = swing(Vector((0.40, 0.08, 14.35)))
    cone("Leader_Needles", 0.82 * needle_scale, 0.045, 2.30, tuple(leader), mats["pine_light"], 8)

    for index, angle in enumerate((0.15, 2.18, 4.24)):
        start = (math.cos(angle) * 0.20, math.sin(angle) * 0.20, 0.15)
        end = (math.cos(angle) * 1.24, math.sin(angle) * 1.24, 0.04)
        tapered_between(f"Root_{index + 1}", start, end, 0.19, 0.042, mats["bark_dark"], 7)

    # The chip pile grows with the cut, and it grows on the NOTCH side (-Y),
    # because that is where the axe throws them. Three chips at damage 2, eight
    # at damage 3 — a pile is a better read at distance than a deeper notch is.
    if damage >= 2:
        chips = (
            ((-0.44, -0.52, 0.10), (0.18, 0.08, 0.055), (0.1, -0.4, 0.2)),
            ((0.36, -0.66, 0.075), (0.14, 0.07, 0.045), (-0.2, 0.5, -0.1)),
            ((0.64, -0.34, 0.06), (0.11, 0.06, 0.04), (0.3, 0.2, 0.6)),
            ((-0.18, -0.86, 0.055), (0.16, 0.08, 0.045), (0.2, 0.3, -0.5)),
            ((0.14, -0.95, 0.05), (0.13, 0.07, 0.04), (-0.1, -0.3, 0.9)),
            ((-0.70, -0.70, 0.05), (0.12, 0.07, 0.04), (0.4, 0.1, 1.3)),
            ((0.52, -0.80, 0.045), (0.10, 0.06, 0.035), (-0.3, 0.4, 0.3)),
            ((-0.02, -0.60, 0.13), (0.15, 0.09, 0.055), (0.1, 0.2, -0.8)),
        )
        for index, (location, scale, rotation) in enumerate(chips[: 3 if damage == 2 else 8]):
            ico(f"Wood_Chip_{index + 1}", location, scale, mats["cut"], rotation)


def build_felled_tree(mats: dict[str, bpy.types.Material]) -> None:
    tapered_between("Felled_Trunk", (-3.90, 0.0, 0.60), (3.85, 0.18, 0.78), 0.57, 0.20, mats["bark"], 9)
    cone("Fresh_Cut_End", 0.405, 0.405, 0.035, (-2.47, -0.001, 0.458), mats["cut"], 9, (0.0, math.radians(88), 0.0))
    for tier, x in enumerate((0.45, 1.20, 1.86)):
        length = 1.02 - tier * 0.15
        for branch, side in enumerate((-1, 1)):
            start = (x, 0.04, 0.56 + tier * 0.025)
            end = (x + 0.08, side * length, 0.86 + branch * 0.18)
            tapered_between(f"Felled_Branch_{tier + 1}_{branch + 1}", start, end, 0.10, 0.025, mats["bark_dark"], 7)
            scale = 0.47 - tier * 0.05
            ico(
                f"Felled_Needles_{tier + 1}_{branch + 1}",
                tuple(Vector(start).lerp(Vector(end), 0.82)),
                (scale * 0.72, scale * 1.22, scale * 0.58),
                mats["pine_dark" if tier == 0 else "pine_light"],
                (side * 0.10, 0.08, side * 0.20),
            )
    ico("Felled_Crown", (2.30, 0.12, 0.85), (0.72, 0.58, 0.72), mats["pine_light"], (0.1, -0.2, 0.3))


def build_stump(mats: dict[str, bpy.types.Material], depleted: bool) -> None:
    # F-425: the stump's radius is the TRUNK's radius, because that is what it is
    # the bottom of. When the harvest tree went from 5.35 m to 15.4 m its base
    # went 0.48 -> 0.62, and a 0.52 stump left behind read as a different, thinner
    # tree having been cut — the state set's shared-footprint rule, broken by
    # forgetting that a stump is part of the set.
    height = 0.74 if not depleted else 0.56
    radius = 0.63 if not depleted else 0.58
    cone("Stump", radius, radius * 0.88, height, (0.0, 0.0, height * 0.5), mats["bark" if not depleted else "dead_bark"], 9)
    cone("Cut_Surface", radius * 0.82, radius * 0.82, 0.035, (0.0, 0.0, height + 0.012), mats["cut" if not depleted else "dead_cut"], 9)
    for index, angle in enumerate((0.10, 1.67, 3.24, 4.81)):
        start = (math.cos(angle) * 0.20, math.sin(angle) * 0.20, 0.14)
        end = (math.cos(angle) * 1.22, math.sin(angle) * 1.22, 0.035)
        tapered_between(f"Root_{index + 1}", start, end, 0.18, 0.042, mats["bark_dark" if not depleted else "dead_bark"], 7)
    if depleted:
        cone("Hollow_Core", 0.25, 0.23, 0.055, (0.0, 0.0, height + 0.035), mats["notch"], 9)
        for index, angle in enumerate((0.35, 1.78, 3.12, 4.58, 5.62)):
            base = (math.cos(angle) * 0.32, math.sin(angle) * 0.32, height)
            tip = (math.cos(angle) * 0.35, math.sin(angle) * 0.35, height + 0.18 + 0.06 * (index % 2))
            tapered_between(f"Weathered_Splinter_{index + 1}", base, tip, 0.075, 0.018, mats["dead_bark"], 6)
    else:
        for index, ring_radius in enumerate((0.18, 0.32)):
            bpy.ops.mesh.primitive_torus_add(
                major_segments=9,
                minor_segments=4,
                location=(0.0, 0.0, height + 0.035),
                major_radius=ring_radius,
                minor_radius=0.014,
            )
            ring = bpy.context.object
            ring.name = f"Growth_Ring_{index + 1}"
            assign(ring, mats["cut_dark"])
        for index, angle in enumerate((0.52, 2.65, 4.78)):
            base = (math.cos(angle) * 0.39, math.sin(angle) * 0.39, height - 0.02)
            tip = (math.cos(angle) * 0.42, math.sin(angle) * 0.42, height + 0.16 + 0.05 * index)
            tapered_between(f"Fresh_Splinter_{index + 1}", base, tip, 0.065, 0.014, mats["cut"], 6)


ROCK_LAYOUT = (
    ((-0.36, 0.04, 0.48), (0.78, 0.66, 0.72), (0.10, 0.18, 0.03)),
    ((0.35, 0.10, 0.38), (0.62, 0.58, 0.58), (0.22, -0.12, 0.41)),
    ((0.03, -0.36, 0.29), (0.50, 0.48, 0.44), (-0.16, 0.24, -0.18)),
)


def add_cracks(mats: dict[str, bpy.types.Material], prefix: str, face: int = 0) -> None:
    """One crack running down a face. `face` rotates it round the node so a later
    stage can add a second one somewhere else rather than thickening the first."""
    points = ((-0.26, -0.665, 0.73), (-0.08, -0.69, 0.53), (0.10, -0.68, 0.35), (0.28, -0.62, 0.18))
    turn = face * 2.28
    spun = [
        (x * math.cos(turn) - y * math.sin(turn), x * math.sin(turn) + y * math.cos(turn), z)
        for x, y, z in points
    ]
    for index in range(len(spun) - 1):
        cylinder_between(f"{prefix}_Crack_{face + 1}_{index + 1}", spun[index], spun[index + 1],
                         0.022, mats["crack"], 5)


#: Where the pick has been landing, and how big a bite it took, per damage stage.
#: A struck rock face does not shrink — it loses flakes, leaving pale angular
#: scars where the fresh stone shows through the weathered outside. Scars are
#: cheap (one ico each), they read at any distance because they are a VALUE
#: change rather than a silhouette change, and they are what makes the first
#: damaged stage legible at all: at stage 1 nothing has broken off yet.
CHIP_SCARS = (
    ((-0.52, -0.44, 0.66), (0.20, 0.14, 0.15), (0.3, 0.5, 0.1)),
    ((0.30, -0.44, 0.52), (0.17, 0.12, 0.13), (-0.2, 0.3, 0.7)),
    ((-0.10, -0.20, 0.92), (0.19, 0.15, 0.12), (0.1, -0.4, 0.4)),
    ((0.55, -0.10, 0.38), (0.15, 0.11, 0.11), (0.4, 0.2, -0.3)),
    ((-0.60, 0.18, 0.50), (0.16, 0.13, 0.12), (-0.3, 0.1, 0.9)),
    ((0.12, 0.34, 0.60), (0.18, 0.12, 0.13), (0.2, 0.4, 0.2)),
)

#: Debris on the ground, added to as the node comes apart. The first two are
#: flakes a pick knocks off; the rest are the collapse at stage 3.
NODE_DEBRIS = (
    ((-0.72, -0.22, 0.09), (0.22, 0.16, 0.10)),
    ((0.66, -0.28, 0.07), (0.17, 0.12, 0.08)),
    ((-0.30, -0.72, 0.08), (0.20, 0.15, 0.09)),
    ((0.44, -0.62, 0.06), (0.15, 0.12, 0.07)),
    ((0.78, 0.16, 0.07), (0.18, 0.14, 0.08)),
    ((-0.66, 0.44, 0.06), (0.16, 0.12, 0.07)),
    ((0.10, 0.70, 0.05), (0.14, 0.11, 0.06)),
)


def build_node(mats: dict[str, bpy.types.Material], family: str, damage: int) -> None:
    """A stone or iron node at damage 0-3, or depleted at 4 (F-425).

    Modelled on what a pick actually does to an outcrop, in order:

      0  weathered rock, whole
      1  **chipped** — worked but not yet broken: pale angular scars where flakes
         have come off, and two of those flakes on the ground. Nothing has
         changed shape, which is correct; the first thirty seconds of breaking a
         rock changes its colour, not its outline
      2  **cracked** — the fractures have joined up. One crack line down a face,
         the crown of the node knocked down, more scars, four pieces at the base
      3  **shattered** — the top mass is gone and what is left is a jagged stub
         in a skirt of its own rubble. Cracks on two faces. On iron, the seams
         that were buried are now the widest thing on it, which is the reward
         read: the closer this is to spent, the more ore is showing
      4  depleted — rubble only

    Iron and stone share every number here on purpose. They are the same rock
    doing the same job; what separates them is the ore, and the ore is what the
    damage progressively exposes.
    """
    stone_mat = mats["stone"] if family == "stone" else mats["iron_stone"]
    if damage >= 4:
        rubble = (
            ((-0.52, 0.04, 0.16), (0.34, 0.28, 0.19)),
            ((0.42, 0.12, 0.13), (0.29, 0.25, 0.16)),
            ((0.02, -0.42, 0.10), (0.25, 0.21, 0.13)),
            ((-0.05, 0.38, 0.08), (0.21, 0.19, 0.11)),
            ((0.64, -0.31, 0.07), (0.17, 0.15, 0.10)),
        )
        for index, (location, scale) in enumerate(rubble):
            ico(f"Rubble_{index + 1}", location, scale, mats["stone_dark"], (index * 0.21, index * 0.37, index * 0.18))
        if family == "iron":
            ico("Spent_Iron_Fleck", (-0.24, -0.29, 0.09), (0.13, 0.08, 0.05), mats["iron_dull"], (0.2, 0.4, 0.1))
        return

    # The rocks themselves. Only stage 3 takes material off the SILHOUETTE, and
    # it takes it off the top — a worked face collapses downward, and a node that
    # shrank evenly would just read as the same node further away.
    crown = (1.0, 1.0, 0.86, 0.42)[damage]
    for index, (location, scale, rotation) in enumerate(ROCK_LAYOUT):
        loss = crown if index == 0 else (1.0 if damage < 3 else 0.74)
        ico(
            f"Rock_{index + 1}",
            (location[0], location[1], location[2] * (1.0 if index else loss)),
            (scale[0] * (1.0 if index else 1.0), scale[1], scale[2] * loss),
            stone_mat,
            rotation,
        )
    if family == "iron":
        # Four seams, and the last two are only reachable once the rock over them
        # is gone. `spread` widens what is left as the node comes apart.
        spread = (1.0, 1.06, 1.18, 1.42)[damage]
        seams = (
            ((-0.45, -0.46, 0.57), (0.22, 0.13, 0.18), (0.2, 0.4, 0.1)),
            ((0.18, -0.48, 0.47), (0.25, 0.14, 0.19), (-0.3, 0.1, 0.5)),
            ((0.43, -0.25, 0.22), (0.18, 0.12, 0.14), (0.3, -0.4, 0.2)),
            ((-0.05, 0.12, 0.82), (0.20, 0.15, 0.16), (-0.2, 0.3, -0.1)),
        )
        for index, (location, scale, rotation) in enumerate(seams):
            height = location[2] * (crown if index == 3 else 1.0)
            ico(
                f"Iron_Seam_{index + 1}",
                (location[0], location[1], height),
                (scale[0] * spread, scale[1] * spread, scale[2] * spread),
                mats["iron"],
                rotation,
            )

    # A fresh break is PALER than the weathered outside — that value step is the
    # whole read, and it is why the scars use `stone_light` on a `stone` node and
    # `stone` on the darker iron host rock. Painted in the node's own body colour
    # they are invisible, which is what the first cut of this did.
    scar_mat = mats["stone_light"] if family == "stone" else mats["stone"]
    for index, (location, scale, rotation) in enumerate(CHIP_SCARS[: (0, 3, 5, 6)[damage]]):
        ico(f"Chip_Scar_{index + 1}", location, scale, scar_mat, rotation)
    for face in range((0, 0, 1, 2)[damage]):
        add_cracks(mats, family.title(), face)
    for index, (location, scale) in enumerate(NODE_DEBRIS[: (0, 2, 4, 7)[damage]]):
        ico(f"Loose_Fragment_{index + 1}", location, scale, stone_mat, (0.2, index * 0.7, 0.4))


def set_visible(record: dict, visible: bool) -> None:
    record["root"].hide_render = not visible
    for child in record["root"].children_recursive:
        child.hide_render = not visible


def setup_render(mats: dict[str, bpy.types.Material]) -> tuple[bpy.types.Scene, bpy.types.Object]:
    preview_collection = bpy.data.collections.new("PREVIEW_ONLY")
    bpy.context.scene.collection.children.link(preview_collection)
    bpy.ops.mesh.primitive_plane_add(size=160, location=(0.0, 0.0, -0.045))
    floor = bpy.context.object
    floor.name = "Preview_Ground"
    assign(floor, mats["ground"])
    move_to_collection([floor], preview_collection)

    bpy.ops.object.light_add(type="SUN", location=(0.0, 0.0, 18.0))
    sun = bpy.context.object
    sun.name = "Preview_Sun"
    sun.rotation_euler = (math.radians(32), math.radians(-25), math.radians(-28))
    sun.data.energy = 2.2
    sun.data.angle = math.radians(20)
    move_to_collection([sun], preview_collection)

    bpy.ops.object.light_add(type="AREA", location=(-7.0, -9.0, 10.0))
    fill = bpy.context.object
    fill.name = "Preview_Fill"
    fill.data.energy = 1200
    fill.data.color = (0.46, 0.30, 0.68)
    fill.data.shape = "DISK"
    fill.data.size = 8.0
    look_at(fill, (0.0, 0.0, 1.4))
    move_to_collection([fill], preview_collection)

    bpy.ops.object.camera_add(location=(15.0, -22.0, 12.0))
    camera = bpy.context.object
    camera.name = "Preview_Camera"
    camera.data.type = "ORTHO"
    bpy.context.scene.camera = camera
    move_to_collection([camera], preview_collection)

    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = 1600
    scene.render.resolution_y = 1000
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.film_transparent = False
    scene.world.color = (0.012, 0.016, 0.026)
    scene.view_settings.look = "AgX - Medium High Contrast"
    return scene, camera


def main() -> None:
    EXPORT_DIR.mkdir(parents=True, exist_ok=True)
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    SOURCE_DIR.mkdir(parents=True, exist_ok=True)
    for expected in EXPECTED_NAMES:
        (EXPORT_DIR / f"{expected}.glb").unlink(missing_ok=True)

    reset_materials()
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for datablocks in (bpy.data.materials, bpy.data.curves, bpy.data.cameras, bpy.data.lights):
        for block in list(datablocks):
            datablocks.remove(block)

    mats = {
        # Shared palette: a harvestable tree stands next to an environment
        # tree, so their bark has to be the same bark. Geometry helpers stay
        # local — this kit's cylinder_between tapers to 0.82, mire_art's to 0.94.
        "bark": mat("wood_bark"),
        "bark_dark": mat("wood_bark_dark"),
        "dead_bark": mat("wood_dead"),
        "cut": mat("wood_cut"),
        "cut_dark": mat("wood_timber"),
        "dead_cut": mat("wood_dead_cut"),
        "notch": mat("wood_bark_dark"),
        "pine_dark": mat("pine_dark"),
        "pine_light": mat("pine_light"),
        "stone": mat("stone"),
        "stone_dark": mat("stone_dark"),
        "stone_light": mat("stone_light"),
        "iron_stone": mat("stone_dark"),
        "iron": mat("iron"),
        "iron_dull": mat("iron_dark"),
        "crack": mat("coal"),
        "ground": mat("preview_ground"),
        "scale": mat("reference_blue"),
    }

    specs: list[tuple[str, str, str, Callable[[], None], tuple[float, float, float]]] = [
        ("harvest_tree_intact", "tree", "intact", lambda: build_tree_base(mats, 0), (-11.0, 3.1, 0.0)),
        ("harvest_tree_damaged_a", "tree", "damaged_a", lambda: build_tree_base(mats, 1), (-7.6, 3.1, 0.0)),
        ("harvest_tree_damaged_b", "tree", "damaged_b", lambda: build_tree_base(mats, 2), (-4.2, 3.1, 0.0)),
        ("harvest_tree_damaged_c", "tree", "damaged_c", lambda: build_tree_base(mats, 3), (-0.8, 3.1, 0.0)),
        ("harvest_tree_felled_trunk", "tree", "felled", lambda: build_felled_tree(mats), (3.0, 3.1, 0.0)),
        ("harvest_tree_fresh_stump", "tree", "fresh_stump", lambda: build_stump(mats, False), (7.2, 3.1, 0.0)),
        ("harvest_tree_depleted_stump", "tree", "depleted_stump", lambda: build_stump(mats, True), (9.2, 3.1, 0.0)),
        ("stone_node_intact", "stone", "intact", lambda: build_node(mats, "stone", 0), (-11.0, -3.0, 0.0)),
        ("stone_node_chipped", "stone", "chipped", lambda: build_node(mats, "stone", 1), (-8.6, -3.0, 0.0)),
        ("stone_node_cracked", "stone", "cracked", lambda: build_node(mats, "stone", 2), (-6.2, -3.0, 0.0)),
        ("stone_node_shattered", "stone", "shattered", lambda: build_node(mats, "stone", 3), (-3.8, -3.0, 0.0)),
        ("stone_node_depleted", "stone", "depleted", lambda: build_node(mats, "stone", 4), (-1.4, -3.0, 0.0)),
        ("iron_node_intact", "iron", "intact", lambda: build_node(mats, "iron", 0), (1.4, -3.0, 0.0)),
        ("iron_node_chipped", "iron", "chipped", lambda: build_node(mats, "iron", 1), (3.8, -3.0, 0.0)),
        ("iron_node_cracked", "iron", "cracked", lambda: build_node(mats, "iron", 2), (6.2, -3.0, 0.0)),
        ("iron_node_shattered", "iron", "shattered", lambda: build_node(mats, "iron", 3), (8.6, -3.0, 0.0)),
        ("iron_node_depleted", "iron", "depleted", lambda: build_node(mats, "iron", 4), (11.0, -3.0, 0.0)),
    ]
    if [spec[0] for spec in specs] != EXPECTED_NAMES:
        raise RuntimeError("A-001 specification and expected export list diverged")

    records: list[dict] = []
    for name, family, state, builder, location in specs:
        records.append(create_asset(name, family, state, builder, location))

    catalog = [
        {
            "name": record["name"],
            "family": record["family"],
            "state": record["state"],
            "width_m": round(record["width"], 3),
            "depth_m": round(record["depth"], 3),
            "height_m": round(record["height"], 3),
            "mesh_parts": record["parts"],
            "polygons": record["polygons"],
            "materials": record["materials"],
        }
        for record in records
    ]
    with (ASSET_DIR / "catalog.json").open("w", encoding="utf-8") as handle:
        json.dump(catalog, handle, indent=2)
        handle.write("\n")

    scene, camera = setup_render(mats)
    # Framed off the tallest asset instead of a hand-tuned constant. The old 25.0
    # was set when the harvest tree was 5.35 m, and it silently cropped the crown
    # off every tree the moment F-425 made them tall.
    tallest = max(record["height"] for record in records)
    camera.data.ortho_scale = 30.0
    camera.location = (15.0, -24.0, tallest * 0.85)
    look_at(camera, (0.0, 0.0, tallest * 0.42))
    scene.render.filepath = str(PREVIEW_DIR / "harvestables_preview.png")
    bpy.ops.render.render(write_still=True)

    original_locations = {record["name"]: record["root"].location.copy() for record in records}
    showcase = {
        "harvest_tree_intact": (-4.8, 1.0, 0.0),
        "harvest_tree_damaged_b": (-1.4, 1.0, 0.0),
        "stone_node_intact": (2.1, 0.5, 0.0),
        "iron_node_intact": (4.9, 0.5, 0.0),
    }
    for record in records:
        set_visible(record, record["name"] in showcase)
        if record["name"] in showcase:
            record["root"].location = showcase[record["name"]]
    # A simple 1.8 m figure and one-metre blocks make asset scale obvious.
    scale_parts = [
        ico("Scale_Head", (0.0, -2.0, 1.63), (0.16, 0.16, 0.18), mats["scale"]),
        cone("Scale_Body", 0.24, 0.17, 0.92, (0.0, -2.0, 1.02), mats["scale"], 8),
        cylinder_between("Scale_Leg_L", (-0.10, -2.0, 0.60), (-0.12, -2.0, 0.02), 0.075, mats["scale"], 7),
        cylinder_between("Scale_Leg_R", (0.10, -2.0, 0.60), (0.12, -2.0, 0.02), 0.075, mats["scale"], 7),
        box("Scale_Metre_One", (1.0, -2.0, 0.5), (0.18, 0.18, 1.0), mats["scale"]),
        box("Scale_Metre_Two", (1.0, -2.0, 1.55), (0.24, 0.24, 0.08), mats["scale"]),
    ]
    preview_collection = bpy.data.collections.get("PREVIEW_ONLY")
    move_to_collection(scale_parts, preview_collection)
    camera.data.ortho_scale = 21.0
    camera.location = (12.0, -18.0, tallest * 0.70)
    look_at(camera, (0.0, 0.0, tallest * 0.40))
    scene.render.filepath = str(PREVIEW_DIR / "harvestables_scale_preview.png")
    bpy.ops.render.render(write_still=True)

    for record in records:
        record["root"].location = original_locations[record["name"]]
        set_visible(record, True)
    bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE_DIR / "harvestable_resources.blend"))
    total_polygons = sum(record["polygons"] for record in records)
    print(f"Built {len(records)} A-001 assets ({total_polygons} polygons total)")


if __name__ == "__main__":
    with import_cache_guard(Path(__file__).name):
        main()
