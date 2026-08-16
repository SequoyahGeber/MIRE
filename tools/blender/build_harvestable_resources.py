"""Build MIRE's first harvestable resource state set (asset batch A-001).

Run with:
  Blender --background --python tools/blender/build_harvestable_resources.py

Outputs 12 individual metre-scale GLBs, an editable Blender source, a JSON
catalog, and two preview renders. Geometry and layout are deterministic.
"""

from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Callable

import bpy
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
    "harvest_tree_felled_trunk",
    "harvest_tree_fresh_stump",
    "harvest_tree_depleted_stump",
    "stone_node_intact",
    "stone_node_cracked",
    "stone_node_depleted",
    "iron_node_intact",
    "iron_node_cracked",
    "iron_node_depleted",
]


def material(
    name: str,
    color: tuple[float, float, float, float],
    roughness: float = 0.9,
    metallic: float = 0.0,
) -> bpy.types.Material:
    mat = bpy.data.materials.new(name)
    mat.diffuse_color = color
    mat.use_nodes = True
    shader = mat.node_tree.nodes.get("Principled BSDF")
    shader.inputs["Base Color"].default_value = color
    shader.inputs["Roughness"].default_value = roughness
    shader.inputs["Metallic"].default_value = metallic
    return mat


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
    before = set(bpy.data.objects)
    build_fn()
    made = [obj for obj in bpy.data.objects if obj not in before]
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
    cone("Trunk", 0.48, 0.23, 5.25, (0.0, 0.0, 2.625), mats["bark"], 9)
    for index, (z, radius, depth) in enumerate(
        ((2.65, 1.62, 1.50), (3.45, 1.42, 1.42), (4.18, 1.15, 1.32), (4.82, 0.82, 1.18))
    ):
        if damage >= 2 and index == 0:
            continue
        foliage = cone(
            f"Foliage_{index + 1}",
            radius,
            0.08,
            depth,
            (0.05 * (index % 2), 0.0, z),
            mats["pine_dark" if index < 2 else "pine_light"],
            9,
        )
        foliage.rotation_euler[2] = index * 0.31
    for index, angle in enumerate((0.15, 2.18, 4.24)):
        start = (math.cos(angle) * 0.16, math.sin(angle) * 0.16, 0.12)
        end = (math.cos(angle) * 1.00, math.sin(angle) * 1.00, 0.04)
        cylinder_between(f"Root_{index + 1}", start, end, 0.13, mats["bark_dark"], 7)

    if damage >= 1:
        # A bright exposed cut over a dark inset reads as an axe notch without
        # using a brittle boolean modifier in the portable source.
        box("Notch_Shadow", (0.0, -0.445, 1.12), (0.55, 0.08, 0.54), mats["notch"], (0.0, 0.0, math.radians(45)))
        box("Fresh_Cut", (0.0, -0.49, 1.12), (0.38, 0.055, 0.38), mats["cut"], (0.0, 0.0, math.radians(45)))
    if damage >= 2:
        box("Deep_Notch", (0.0, -0.51, 1.12), (0.58, 0.065, 0.58), mats["notch"], (0.0, 0.0, math.radians(45)))
        box("Deep_Cut_Core", (0.0, -0.55, 1.12), (0.37, 0.045, 0.37), mats["cut_dark"], (0.0, 0.0, math.radians(45)))
        box("Cut_Score_L", (-0.14, -0.577, 1.12), (0.035, 0.03, 0.39), mats["cut"], (0.0, 0.0, math.radians(-22)))
        box("Cut_Score_R", (0.14, -0.577, 1.12), (0.035, 0.03, 0.39), mats["cut"], (0.0, 0.0, math.radians(22)))
        for index, (x, y, z, rz) in enumerate(
            ((-0.48, -0.48, 0.18, -0.35), (0.42, -0.58, 0.12, 0.62), (0.68, -0.32, 0.08, -0.18))
        ):
            box(f"Wood_Chip_{index + 1}", (x, y, z), (0.30, 0.12, 0.12), mats["cut"], (0.0, rz, rz))


def build_felled_tree(mats: dict[str, bpy.types.Material]) -> None:
    cylinder_between("Felled_Trunk", (-2.45, 0.0, 0.46), (2.40, 0.12, 0.62), 0.43, mats["bark"], 9)
    cone("Fresh_Cut_End", 0.405, 0.405, 0.035, (-2.47, -0.001, 0.458), mats["cut"], 9, (0.0, math.radians(88), 0.0))
    for index, (x, side) in enumerate(((-1.25, -1), (-0.15, 1), (1.02, -1), (1.78, 1))):
        cylinder_between(
            f"Branch_Stub_{index + 1}",
            (x, 0.0, 0.55),
            (x + 0.15, side * 0.70, 0.30),
            0.115,
            mats["bark_dark"],
            7,
        )
    for index, x in enumerate((1.35, 2.00)):
        foliage = cone(
            f"Crown_Remnant_{index + 1}",
            0.78 - index * 0.12,
            0.06,
            0.95,
            (x, 0.15, 0.95),
            mats["pine_dark" if index == 0 else "pine_light"],
            8,
            (math.radians(90), 0.0, 0.12),
        )
        foliage.rotation_euler[2] = index * 0.4


def build_stump(mats: dict[str, bpy.types.Material], depleted: bool) -> None:
    height = 0.54 if not depleted else 0.32
    radius = 0.50 if not depleted else 0.45
    cone("Stump", radius, radius * 0.88, height, (0.0, 0.0, height * 0.5), mats["bark" if not depleted else "dead_bark"], 9)
    cone("Cut_Surface", radius * 0.82, radius * 0.82, 0.035, (0.0, 0.0, height + 0.012), mats["cut" if not depleted else "dead_cut"], 9)
    for index, angle in enumerate((0.10, 2.18, 4.26)):
        start = (math.cos(angle) * 0.16, math.sin(angle) * 0.16, 0.12)
        end = (math.cos(angle) * 0.92, math.sin(angle) * 0.92, 0.035)
        cylinder_between(f"Root_{index + 1}", start, end, 0.13, mats["bark_dark" if not depleted else "dead_bark"], 7)
    if depleted:
        for index, angle in enumerate((0.6, 2.7, 4.7)):
            box(
                f"Split_{index + 1}",
                (math.cos(angle) * 0.22, math.sin(angle) * 0.22, height + 0.035),
                (0.035, 0.34, 0.025),
                mats["notch"],
                (0.0, 0.0, angle),
            )


ROCK_LAYOUT = (
    ((-0.36, 0.04, 0.48), (0.78, 0.66, 0.72), (0.10, 0.18, 0.03)),
    ((0.35, 0.10, 0.38), (0.62, 0.58, 0.58), (0.22, -0.12, 0.41)),
    ((0.03, -0.36, 0.29), (0.50, 0.48, 0.44), (-0.16, 0.24, -0.18)),
)


def add_cracks(mats: dict[str, bpy.types.Material], prefix: str) -> None:
    points = ((-0.26, -0.665, 0.73), (-0.08, -0.69, 0.53), (0.10, -0.68, 0.35), (0.28, -0.62, 0.18))
    for index in range(len(points) - 1):
        cylinder_between(f"{prefix}_Crack_{index + 1}", points[index], points[index + 1], 0.022, mats["crack"], 5)


def build_node(mats: dict[str, bpy.types.Material], family: str, state: str) -> None:
    stone_mat = mats["stone"] if family == "stone" else mats["iron_stone"]
    if state != "depleted":
        for index, (location, scale, rotation) in enumerate(ROCK_LAYOUT):
            ico(f"Rock_{index + 1}", location, scale, stone_mat, rotation)
        if family == "iron":
            for index, (location, scale, rotation) in enumerate(
                (
                    ((-0.45, -0.46, 0.57), (0.22, 0.13, 0.18), (0.2, 0.4, 0.1)),
                    ((0.18, -0.48, 0.47), (0.25, 0.14, 0.19), (-0.3, 0.1, 0.5)),
                    ((0.43, -0.25, 0.22), (0.18, 0.12, 0.14), (0.3, -0.4, 0.2)),
                    ((-0.05, 0.12, 0.82), (0.20, 0.15, 0.16), (-0.2, 0.3, -0.1)),
                )
            ):
                ico(f"Iron_Seam_{index + 1}", location, scale, mats["iron"], rotation)
        if state == "cracked":
            add_cracks(mats, family.title())
            for index, (x, y, size) in enumerate(((-0.72, -0.22, 0.22), (0.66, -0.28, 0.17))):
                ico(f"Loose_Fragment_{index + 1}", (x, y, size * 0.42), (size, size * 0.72, size * 0.42), stone_mat, (0.2, index * 0.7, 0.4))
    else:
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


def set_visible(record: dict, visible: bool) -> None:
    record["root"].hide_render = not visible
    for child in record["root"].children_recursive:
        child.hide_render = not visible


def setup_render(mats: dict[str, bpy.types.Material]) -> tuple[bpy.types.Scene, bpy.types.Object]:
    preview_collection = bpy.data.collections.new("PREVIEW_ONLY")
    bpy.context.scene.collection.children.link(preview_collection)
    bpy.ops.mesh.primitive_plane_add(size=70, location=(0.0, 0.0, -0.045))
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

    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for datablocks in (bpy.data.materials, bpy.data.curves, bpy.data.cameras, bpy.data.lights):
        for block in list(datablocks):
            datablocks.remove(block)

    mats = {
        "bark": material("MIRE_Harvest_Bark", (0.23, 0.075, 0.025, 1.0)),
        "bark_dark": material("MIRE_Harvest_Bark_Dark", (0.10, 0.025, 0.012, 1.0)),
        "dead_bark": material("MIRE_Harvest_Dead_Bark", (0.16, 0.12, 0.10, 1.0)),
        "cut": material("MIRE_Harvest_Fresh_Wood", (0.95, 0.54, 0.16, 1.0)),
        "cut_dark": material("MIRE_Harvest_Deep_Cut", (0.48, 0.19, 0.055, 1.0)),
        "dead_cut": material("MIRE_Harvest_Dead_Wood", (0.38, 0.30, 0.21, 1.0)),
        "notch": material("MIRE_Harvest_Notch", (0.055, 0.012, 0.008, 1.0)),
        "pine_dark": material("MIRE_Harvest_Pine_Dark", (0.018, 0.22, 0.095, 1.0)),
        "pine_light": material("MIRE_Harvest_Pine_Light", (0.08, 0.48, 0.19, 1.0)),
        "stone": material("MIRE_Harvest_Stone", (0.31, 0.36, 0.38, 1.0)),
        "stone_dark": material("MIRE_Harvest_Stone_Depleted", (0.12, 0.14, 0.15, 1.0)),
        "iron_stone": material("MIRE_Harvest_Iron_Stone", (0.24, 0.25, 0.25, 1.0)),
        "iron": material("MIRE_Harvest_Iron_Ore", (0.72, 0.22, 0.055, 1.0), 0.55, 0.42),
        "iron_dull": material("MIRE_Harvest_Spent_Iron", (0.31, 0.14, 0.08, 1.0), 0.85, 0.12),
        "crack": material("MIRE_Harvest_Crack", (0.045, 0.018, 0.014, 1.0)),
        "ground": material("MIRE_Harvest_Preview_Ground", (0.048, 0.085, 0.056, 1.0)),
        "scale": material("MIRE_Harvest_Scale_Reference", (0.15, 0.53, 0.78, 1.0)),
    }

    specs: list[tuple[str, str, str, Callable[[], None], tuple[float, float, float]]] = [
        ("harvest_tree_intact", "tree", "intact", lambda: build_tree_base(mats, 0), (-9.0, 3.1, 0.0)),
        ("harvest_tree_damaged_a", "tree", "damaged_a", lambda: build_tree_base(mats, 1), (-5.4, 3.1, 0.0)),
        ("harvest_tree_damaged_b", "tree", "damaged_b", lambda: build_tree_base(mats, 2), (-1.8, 3.1, 0.0)),
        ("harvest_tree_felled_trunk", "tree", "felled", lambda: build_felled_tree(mats), (2.6, 3.1, 0.0)),
        ("harvest_tree_fresh_stump", "tree", "fresh_stump", lambda: build_stump(mats, False), (7.0, 3.1, 0.0)),
        ("harvest_tree_depleted_stump", "tree", "depleted_stump", lambda: build_stump(mats, True), (9.0, 3.1, 0.0)),
        ("stone_node_intact", "stone", "intact", lambda: build_node(mats, "stone", "intact"), (-7.0, -3.0, 0.0)),
        ("stone_node_cracked", "stone", "cracked", lambda: build_node(mats, "stone", "cracked"), (-3.5, -3.0, 0.0)),
        ("stone_node_depleted", "stone", "depleted", lambda: build_node(mats, "stone", "depleted"), (0.0, -3.0, 0.0)),
        ("iron_node_intact", "iron", "intact", lambda: build_node(mats, "iron", "intact"), (3.5, -3.0, 0.0)),
        ("iron_node_cracked", "iron", "cracked", lambda: build_node(mats, "iron", "cracked"), (7.0, -3.0, 0.0)),
        ("iron_node_depleted", "iron", "depleted", lambda: build_node(mats, "iron", "depleted"), (9.6, -3.0, 0.0)),
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
    camera.data.ortho_scale = 25.0
    camera.location = (15.0, -24.0, 12.0)
    look_at(camera, (0.0, 0.0, 1.8))
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
    camera.data.ortho_scale = 15.0
    camera.location = (12.0, -18.0, 8.5)
    look_at(camera, (0.0, 0.0, 2.1))
    scene.render.filepath = str(PREVIEW_DIR / "harvestables_scale_preview.png")
    bpy.ops.render.render(write_still=True)

    for record in records:
        record["root"].location = original_locations[record["name"]]
        set_visible(record, True)
    bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE_DIR / "harvestable_resources.blend"))
    total_polygons = sum(record["polygons"] for record in records)
    print(f"Built {len(records)} A-001 assets ({total_polygons} polygons total)")


if __name__ == "__main__":
    main()
