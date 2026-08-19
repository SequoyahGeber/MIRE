"""Build MIRE's first crafting-station kit (asset batch A-003).

Run with:
  Blender --background --python tools/blender/build_crafting_stations.py

Outputs eight individual metre-scale GLBs, an editable Blender source, a JSON
catalog, and two preview renders. Geometry and layout are deterministic.
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path
from typing import Callable

import bpy
from mathutils import Vector

sys.path.append(str(Path(__file__).resolve().parent))
from mire_art import (  # noqa: E402
    SCALE, assign, check_scale, cone, cylinder_between, eevee_engine, ico,
    look_at, mat, mesh_object, move_to_collection, radial, reset_materials, world_bounds,
)


def box(
    name: str,
    location: tuple[float, float, float],
    dimensions: tuple[float, float, float],
    material: bpy.types.Material,
    rotation: tuple[float, float, float] = (0.0, 0.0, 0.0),
    bevel: float = 0.0,
) -> bpy.types.Object:
    """Bevel-free box, overriding ``mire_art.box`` on purpose (F-057).

    This kit's contract includes a byte-identical rebuild, and `build_ward_set.py`
    found Blender's bevel modifier changing float bytes between otherwise
    identical background exports on Apple Silicon. `build_flora_set.py`,
    `build_construction_set.py` and `build_extraction_ship_set.py` all made the
    same call for the same reason; this kit is the one family that shipped
    without it. The ``bevel`` argument is accepted and ignored so the 23 call
    sites below read the same as everywhere else in this file.
    """
    bpy.ops.mesh.primitive_cube_add(location=location, rotation=rotation)
    obj = bpy.context.object
    obj.name = name
    obj.scale = (dimensions[0] * 0.5, dimensions[1] * 0.5, dimensions[2] * 0.5)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    return assign(obj, material)


ROOT = Path(__file__).resolve().parents[2]
ASSET_DIR = ROOT / "assets" / "crafting_stations"
SOURCE_DIR = ROOT / "assets" / "source"
EXPORT_DIR = ASSET_DIR / "exports"
PREVIEW_DIR = ASSET_DIR / "preview"

EXPECTED_NAMES = [
    "station_workbench_primitive",
    "station_workbench_upgraded",
    "station_campfire",
    "station_cooking_spit",
    "station_stone_furnace",
    "station_anvil",
    "station_repair_bench",
    "station_woodcutting_block",
]


def flame(
    name: str,
    location: tuple[float, float, float],
    scale: tuple[float, float, float],
    mat: bpy.types.Material,
    rotation_z: float,
) -> bpy.types.Object:
    vertices = [
        (0.0, 0.0, 0.65),
        (-0.42, -0.22, -0.35),
        (0.34, -0.30, -0.35),
        (0.44, 0.20, -0.35),
        (-0.30, 0.32, -0.35),
        (0.0, 0.0, -0.48),
    ]
    faces = [(0, 1, 2), (0, 2, 3), (0, 3, 4), (0, 4, 1), (5, 2, 1), (5, 3, 2), (5, 4, 3), (5, 1, 4)]
    obj = mesh_object(name, vertices, faces, mat)
    obj.location = location
    obj.scale = scale
    obj.rotation_euler[2] = rotation_z
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    obj.select_set(False)
    return obj


def create_asset(
    name: str,
    family: str,
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
    minimum, maximum = world_bounds(made)
    offset = Vector((-(minimum.x + maximum.x) * 0.5, -(minimum.y + maximum.y) * 0.5, -minimum.z))
    for obj in made:
        obj.location += offset
    move_to_collection(made, collection)
    for obj in made:
        obj.parent = root
    minimum, maximum = world_bounds(made)
    dimensions = maximum - minimum
    polygons = sum(len(obj.data.polygons) for obj in made if obj.type == "MESH")
    materials = sorted({mat.name for obj in made if obj.type == "MESH" for mat in obj.data.materials if mat})
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
        "root": root,
        "width": dimensions.x,
        "depth": dimensions.y,
        "height": dimensions.z,
        "parts": sum(1 for obj in made if obj.type == "MESH"),
        "polygons": polygons,
        "materials": materials,
    }


def add_table_frame(mats: dict[str, bpy.types.Material], width: float, depth: float, height: float, upgraded: bool) -> None:
    leg_mat = mats["wood_dark"] if not upgraded else mats["wood"]
    top_mat = mats["wood"] if not upgraded else mats["wood_light"]
    for x_index, x in enumerate((-width * 0.42, width * 0.42)):
        for y_index, y in enumerate((-depth * 0.34, depth * 0.34)):
            box(f"Leg_{x_index + 1}_{y_index + 1}", (x, y, height * 0.43), (0.18, 0.18, height * 0.86), leg_mat, (0.02 * y, 0.03 * x, 0.0), 0.025)
    box("Worktop", (0.0, 0.0, height), (width, depth, 0.18), top_mat, bevel=0.035)
    box("Front_Brace", (0.0, -depth * 0.34, height * 0.60), (width * 0.80, 0.13, 0.16), leg_mat)
    box("Back_Brace", (0.0, depth * 0.34, height * 0.60), (width * 0.80, 0.13, 0.16), leg_mat)
    box("Lower_Shelf", (0.0, 0.0, height * 0.34), (width * 0.78, depth * 0.62, 0.10), mats["wood_dark"])


def add_hammer(name: str, location: tuple[float, float, float], mats: dict[str, bpy.types.Material], rotation_z: float) -> None:
    handle_start = (location[0] - 0.22 * math.cos(rotation_z), location[1] - 0.22 * math.sin(rotation_z), location[2])
    handle_end = (location[0] + 0.22 * math.cos(rotation_z), location[1] + 0.22 * math.sin(rotation_z), location[2])
    cylinder_between(f"{name}_Handle", handle_start, handle_end, 0.025, mats["wood_light"], 7)
    box(f"{name}_Head", handle_end, (0.22, 0.08, 0.09), mats["iron"], (0.0, 0.0, rotation_z + math.pi * 0.5), 0.02)


def build_workbench_primitive(mats: dict[str, bpy.types.Material]) -> None:
    add_table_frame(mats, 2.05, 0.82, 0.91, False)
    for index, x in enumerate((-0.62, 0.0, 0.62)):
        box(f"Top_Plank_{index + 1}", (x, -0.01, 1.015), (0.58, 0.86, 0.055), mats["wood_light" if index == 1 else "wood"], (0.0, 0.0, 0.015 * (index - 1)))
    add_hammer("Bench_Hammer", (-0.40, -0.12, 1.07), mats, 0.12)
    cylinder_between("Twine_Coil_A", (0.48, -0.18, 1.07), (0.68, -0.12, 1.07), 0.045, mats["rope"], 8)
    box("Wood_Stop", (0.78, 0.20, 1.14), (0.14, 0.38, 0.20), mats["wood_dark"], bevel=0.025)


def build_workbench_upgraded(mats: dict[str, bpy.types.Material]) -> None:
    add_table_frame(mats, 2.25, 0.95, 0.94, True)
    box("Backboard", (0.0, 0.39, 1.55), (2.05, 0.13, 1.10), mats["wood_dark"], bevel=0.025)
    for index, x in enumerate((-0.72, -0.24, 0.24, 0.72)):
        box(f"Backboard_Slat_{index + 1}", (x, 0.305, 1.55), (0.055, 0.025, 0.90), mats["wood_light"])
    box("Drawer_Left", (-0.55, -0.30, 0.72), (0.62, 0.42, 0.32), mats["iron_dark"], bevel=0.035)
    box("Drawer_Right", (0.18, -0.30, 0.72), (0.62, 0.42, 0.32), mats["iron_dark"], bevel=0.035)
    for x in (-0.55, 0.18):
        box(f"Drawer_Handle_{x}", (x, -0.525, 0.72), (0.23, 0.04, 0.045), mats["iron"], bevel=0.012)
    # A chunky red vise distinguishes the upgrade from the primitive bench at distance.
    box("Vise_Base", (0.78, -0.10, 1.10), (0.42, 0.34, 0.17), mats["red_metal"], bevel=0.045)
    box("Vise_Jaw_Back", (0.78, 0.04, 1.25), (0.44, 0.13, 0.30), mats["red_metal"], bevel=0.035)
    box("Vise_Jaw_Front", (0.78, -0.28, 1.25), (0.44, 0.13, 0.30), mats["red_metal"], bevel=0.035)
    cylinder_between("Vise_Screw", (0.78, -0.46, 1.20), (0.78, -0.18, 1.20), 0.035, mats["iron"], 8)
    cylinder_between("Vise_Handle", (0.58, -0.49, 1.20), (0.98, -0.49, 1.20), 0.025, mats["iron_light"], 8)
    add_hammer("Hanging_Hammer", (-0.55, 0.24, 1.56), mats, math.pi * 0.5)
    box("Hanging_Square", (0.12, 0.22, 1.55), (0.34, 0.045, 0.34), mats["iron_light"], (0.0, 0.0, math.radians(45)), 0.02)


def add_fire_ring(mats: dict[str, bpy.types.Material], with_flame: bool = True) -> None:
    for index in range(10):
        angle = index / 10.0 * math.tau
        ico(
            f"Ring_Stone_{index + 1}",
            (math.cos(angle) * 0.54, math.sin(angle) * 0.54, 0.15),
            (0.25, 0.18, 0.17),
            mats["stone" if index % 2 == 0 else "stone_light"],
            (index * 0.17, index * 0.23, angle),
        )
    for index, angle in enumerate((math.radians(45), math.radians(-45), math.radians(90))):
        cylinder_between(
            f"Fire_Log_{index + 1}",
            (-0.43 * math.cos(angle), -0.43 * math.sin(angle), 0.30 + index * 0.035),
            (0.43 * math.cos(angle), 0.43 * math.sin(angle), 0.30 + index * 0.035),
            0.105,
            mats["charred"],
            8,
        )
    if with_flame:
        flame("Flame_Outer", (0.0, 0.0, 0.66), (0.48, 0.42, 0.72), mats["fire_orange"], 0.16)
        flame("Flame_Inner", (0.05, -0.05, 0.58), (0.28, 0.25, 0.48), mats["fire_yellow"], -0.28)


def build_campfire(mats: dict[str, bpy.types.Material]) -> None:
    add_fire_ring(mats, True)
    for index, angle in enumerate((0.2, 2.25, 4.35)):
        ico(
            f"Coal_{index + 1}",
            (math.cos(angle) * 0.22, math.sin(angle) * 0.22, 0.23),
            (0.13, 0.11, 0.09),
            mats["ember"],
            (0.2 * index, 0.3, angle),
        )


def build_cooking_spit(mats: dict[str, bpy.types.Material]) -> None:
    add_fire_ring(mats, True)
    for side in (-1, 1):
        x = side * 0.88
        cylinder_between(f"Tripod_Leg_Front_{side}", (x, -0.38, 0.0), (x, 0.0, 1.58), 0.055, mats["iron_dark"], 8)
        cylinder_between(f"Tripod_Leg_Back_{side}", (x, 0.38, 0.0), (x, 0.0, 1.58), 0.055, mats["iron_dark"], 8)
    cylinder_between("Spit_Rod", (-1.02, 0.0, 1.20), (1.02, 0.0, 1.20), 0.045, mats["iron"], 8)
    cylinder_between("Spit_Handle", (1.02, 0.0, 1.20), (1.25, -0.18, 1.20), 0.035, mats["iron"], 8)
    # A stylized roast shape keeps the station legible without creating a separate pickup asset.
    ico("Roast", (0.0, 0.0, 1.20), (0.42, 0.24, 0.28), mats["cooked_meat"], (0.0, 0.0, 0.2))
    for x in (-0.30, 0.30):
        cone(f"Roast_End_{x}", 0.20, 0.13, 0.20, (x, 0.0, 1.20), mats["cooked_meat_dark"], 8, (0.0, math.radians(90), 0.0))


def build_stone_furnace(mats: dict[str, bpy.types.Material]) -> None:
    # Offset stone courses leave a deep arched fire mouth without fragile booleans.
    course_specs = (
        (-0.72, -0.47, 0.28), (-0.24, -0.47, 0.28), (0.24, -0.47, 0.28), (0.72, -0.47, 0.28),
        (-0.72, -0.47, 0.72), (0.72, -0.47, 0.72),
        (-0.66, -0.47, 1.12), (-0.22, -0.47, 1.18), (0.22, -0.47, 1.18), (0.66, -0.47, 1.12),
    )
    for index, (x, y, z) in enumerate(course_specs):
        ico(
            f"Front_Stone_{index + 1}",
            (x, y, z),
            (0.34, 0.28, 0.25),
            mats["stone" if index % 2 == 0 else "stone_light"],
            (index * 0.11, index * 0.07, index * 0.13),
        )
    for index, (x, y, z) in enumerate(((-0.68, 0.0, 0.35), (0.68, 0.0, 0.35), (-0.62, 0.25, 0.78), (0.62, 0.25, 0.78), (0.0, 0.30, 0.35), (0.0, 0.30, 0.88))):
        ico(f"Body_Stone_{index + 1}", (x, y, z), (0.42, 0.40, 0.34), mats["stone_dark" if index % 3 == 0 else "stone"], (index * 0.18, 0.2, index * 0.25))
    box("Fire_Mouth", (0.0, -0.67, 0.54), (0.72, 0.14, 0.70), mats["soot"], bevel=0.12)
    flame("Furnace_Fire", (0.0, -0.76, 0.43), (0.31, 0.18, 0.42), mats["fire_orange"], 0.0)
    box("Furnace_Lintel", (0.0, -0.53, 0.96), (0.88, 0.34, 0.22), mats["stone_light"], bevel=0.06)
    box("Chimney_Base", (0.0, 0.05, 1.42), (0.80, 0.72, 0.48), mats["stone_dark"], bevel=0.08)
    box("Chimney_Top", (0.0, 0.05, 1.82), (0.58, 0.54, 0.40), mats["stone"], bevel=0.06)
    box("Chimney_Lip", (0.0, 0.05, 2.05), (0.72, 0.66, 0.12), mats["stone_light"], bevel=0.035)


def build_anvil(mats: dict[str, bpy.types.Material]) -> None:
    cone("Stump_Base", 0.46, 0.40, 0.66, (0.0, 0.0, 0.33), mats["wood_dark"], 9)
    cone("Stump_Cut", 0.36, 0.36, 0.035, (0.0, 0.0, 0.675), mats["wood_cut"], 9)
    box("Anvil_Foot", (0.0, 0.0, 0.76), (0.54, 0.40, 0.18), mats["iron_dark"], bevel=0.05)
    box("Anvil_Waist", (-0.04, 0.0, 0.95), (0.40, 0.34, 0.28), mats["iron"], bevel=0.07)
    box("Anvil_Face", (-0.06, 0.0, 1.16), (0.90, 0.42, 0.20), mats["iron_light"], bevel=0.045)
    # Tapered horn assembled as low-poly cones, reading clearly from the side.
    cone("Anvil_Horn", 0.22, 0.035, 0.66, (0.54, 0.0, 1.14), mats["iron"], 8, (0.0, math.radians(90), 0.0))
    box("Hardy_Hole", (-0.28, -0.18, 1.275), (0.10, 0.10, 0.025), mats["soot"], bevel=0.015)


def build_repair_bench(mats: dict[str, bpy.types.Material]) -> None:
    add_table_frame(mats, 2.15, 0.90, 0.90, True)
    box("Metal_Worktop", (0.0, 0.0, 1.04), (2.08, 0.84, 0.12), mats["iron_dark"], bevel=0.035)
    box("Tool_Rail", (0.0, 0.36, 1.52), (1.88, 0.10, 0.16), mats["red_metal"], bevel=0.03)
    for index, x in enumerate((-0.68, -0.22, 0.24, 0.68)):
        cylinder_between(f"Hook_{index + 1}", (x, 0.28, 1.48), (x, 0.17, 1.31), 0.025, mats["iron_light"], 6)
    add_hammer("Repair_Hammer", (-0.55, -0.08, 1.15), mats, 0.18)
    # A gear and clamp create a mechanical silhouette separate from both workbenches.
    # The gear uses export-safe primitives; Blender 5.2's background torus operator
    # can abort in libc++ before Python receives an exception.
    cone("Repair_Gear_Hub", 0.22, 0.22, 0.10, (0.15, -0.03, 1.18), mats["iron_light"], 10, (math.radians(90), 0.0, 0.0))
    for index in range(8):
        angle = index / 8.0 * math.tau
        box(
            f"Repair_Gear_Tooth_{index + 1}",
            (0.15 + math.cos(angle) * 0.25, -0.03, 1.18 + math.sin(angle) * 0.25),
            (0.13, 0.11, 0.09),
            mats["iron_light"],
            (0.0, angle, 0.0),
            0.015,
        )
    box("Clamp_Base", (0.68, -0.10, 1.18), (0.42, 0.32, 0.18), mats["red_metal"], bevel=0.035)
    box("Clamp_Jaw", (0.68, -0.25, 1.33), (0.40, 0.12, 0.28), mats["red_metal"], bevel=0.025)
    cylinder_between("Clamp_Screw", (0.68, -0.42, 1.28), (0.68, -0.18, 1.28), 0.03, mats["iron"], 8)
    box("Parts_Tray", (0.38, 0.18, 1.16), (0.45, 0.30, 0.08), mats["iron"], bevel=0.04)
    for index, x in enumerate((0.26, 0.40, 0.53)):
        ico(f"Spare_Part_{index + 1}", (x, 0.14, 1.24), (0.05, 0.05, 0.04), mats["brass"], (index * 0.3, 0.2, index * 0.4))


def build_woodcutting_block(mats: dict[str, bpy.types.Material]) -> None:
    cone("Chopping_Block", 0.62, 0.54, 0.76, (0.0, 0.0, 0.38), mats["wood_dark"], 10)
    cone("Block_Cut", 0.50, 0.50, 0.035, (0.0, 0.0, 0.775), mats["wood_cut"], 10)
    for index, angle in enumerate((0.3, 2.25, 4.18)):
        box(
            f"Cut_Crack_{index + 1}",
            (math.cos(angle) * 0.20, math.sin(angle) * 0.20, 0.800),
            (0.035, 0.34, 0.025),
            mats["soot"],
            (0.0, 0.0, angle),
        )
    # Two split billets and a metal wedge communicate function without duplicating A-004's axe.
    for index, (x, y, rz) in enumerate(((-0.72, -0.20, -0.28), (0.68, 0.15, 0.34))):
        box(f"Split_Wood_{index + 1}", (x, y, 0.17), (0.58, 0.22, 0.24), mats["wood"], (0.04, rz, rz), 0.025)
        box(f"Split_Face_{index + 1}", (x - 0.24 if x < 0 else x + 0.24, y, 0.17), (0.06, 0.19, 0.20), mats["wood_cut"], (0.04, rz, rz), 0.015)
    wedge_vertices = [(-0.12, -0.05, 0.0), (0.12, -0.05, 0.0), (0.12, 0.05, 0.0), (-0.12, 0.05, 0.0), (-0.04, -0.05, 0.34), (0.04, -0.05, 0.34), (0.04, 0.05, 0.34), (-0.04, 0.05, 0.34)]
    wedge_faces = [(0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)]
    wedge = mesh_object("Splitting_Wedge", wedge_vertices, wedge_faces, mats["iron"])
    wedge.location = (0.10, 0.0, 0.78)
    wedge.rotation_euler[2] = 0.22


def set_visible(record: dict, visible: bool) -> None:
    record["root"].hide_render = not visible
    for child in record["root"].children_recursive:
        child.hide_render = not visible


def setup_render(mats: dict[str, bpy.types.Material]) -> tuple[bpy.types.Scene, bpy.types.Object, bpy.types.Collection]:
    preview_collection = bpy.data.collections.new("PREVIEW_ONLY")
    bpy.context.scene.collection.children.link(preview_collection)
    bpy.ops.mesh.primitive_plane_add(size=55, location=(0.0, 0.0, -0.035))
    floor = bpy.context.object
    floor.name = "Preview_Ground"
    assign(floor, mats["ground"])
    move_to_collection([floor], preview_collection)
    bpy.ops.object.light_add(type="SUN", location=(0.0, 0.0, 18.0))
    sun = bpy.context.object
    sun.name = "Preview_Sun"
    sun.rotation_euler = (math.radians(34), math.radians(-22), math.radians(-28))
    sun.data.energy = 2.35
    sun.data.angle = math.radians(18)
    move_to_collection([sun], preview_collection)
    bpy.ops.object.light_add(type="AREA", location=(-9.0, -11.0, 12.0))
    fill = bpy.context.object
    fill.name = "Preview_Fill"
    fill.data.energy = 1350
    fill.data.color = (0.43, 0.28, 0.68)
    fill.data.shape = "DISK"
    fill.data.size = 10.0
    look_at(fill, (0.0, 0.0, 0.8))
    move_to_collection([fill], preview_collection)
    bpy.ops.object.camera_add(location=(0.0, -18.0, 11.0))
    camera = bpy.context.object
    camera.name = "Preview_Camera"
    camera.data.type = "ORTHO"
    bpy.context.scene.camera = camera
    move_to_collection([camera], preview_collection)
    scene = bpy.context.scene
    scene.render.engine = eevee_engine()
    scene.render.resolution_x = 1600
    scene.render.resolution_y = 1000
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.film_transparent = False
    scene.world.color = (0.012, 0.016, 0.026)
    scene.view_settings.look = "AgX - Medium High Contrast"
    return scene, camera, preview_collection


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

    # Every colour now comes from the shared palette, so a bench top and a
    # tool haft are the same oak and the furnace is the same stone as a boulder.
    mats = {
        "wood": mat("wood_timber"),
        "wood_light": mat("wood_timber_light"),
        "wood_dark": mat("wood_bark_dark"),
        "wood_cut": mat("wood_cut"),
        "rope": mat("rope"),
        "stone": mat("stone"),
        "stone_light": mat("stone_light"),
        "stone_dark": mat("stone_dark"),
        "soot": mat("coal"),
        "charred": mat("wood_charred"),
        "iron": mat("iron"),
        "iron_light": mat("iron_light"),
        "iron_dark": mat("iron_dark"),
        "brass": mat("brass"),
        "red_metal": mat("cloth_red"),
        "fire_orange": mat("ember"),
        "fire_yellow": mat("flame"),
        "ember": mat("ember"),
        "cooked_meat": mat("flesh_cooked"),
        "cooked_meat_dark": mat("flesh_charred"),
        "ground": mat("preview_ground"),
        "scale": mat("reference_blue"),
    }

    builders: list[tuple[str, str, Callable[[], None]]] = [
        ("station_workbench_primitive", "workbench", lambda: build_workbench_primitive(mats)),
        ("station_workbench_upgraded", "workbench", lambda: build_workbench_upgraded(mats)),
        ("station_campfire", "fire", lambda: build_campfire(mats)),
        ("station_cooking_spit", "fire", lambda: build_cooking_spit(mats)),
        ("station_stone_furnace", "forge", lambda: build_stone_furnace(mats)),
        ("station_anvil", "forge", lambda: build_anvil(mats)),
        ("station_repair_bench", "repair", lambda: build_repair_bench(mats)),
        ("station_woodcutting_block", "woodworking", lambda: build_woodcutting_block(mats)),
    ]
    if [name for name, _, _ in builders] != EXPECTED_NAMES:
        raise RuntimeError("A-003 specification and expected export list diverged")

    positions = ((-5.25, 2.4, 0.0), (-1.75, 2.4, 0.0), (1.75, 2.4, 0.0), (5.25, 2.4, 0.0), (-5.25, -2.3, 0.0), (-1.75, -2.3, 0.0), (1.75, -2.3, 0.0), (5.25, -2.3, 0.0))
    records: list[dict] = []
    for (name, family, builder), location in zip(builders, positions):
        records.append(create_asset(name, family, builder, location))

    catalog = [
        {
            "name": record["name"],
            "family": record["family"],
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

    scene, camera, preview_collection = setup_render(mats)
    camera.data.ortho_scale = 17.8
    camera.location = (0.0, -19.0, 11.5)
    look_at(camera, (0.0, 0.0, 0.75))
    scene.render.filepath = str(PREVIEW_DIR / "crafting_stations_preview.png")
    bpy.ops.render.render(write_still=True)

    original_locations = {record["name"]: record["root"].location.copy() for record in records}
    showcase = {
        "station_workbench_upgraded": (-3.3, 0.5, 0.0),
        "station_cooking_spit": (0.0, 0.4, 0.0),
        "station_stone_furnace": (3.2, 0.5, 0.0),
        "station_anvil": (5.4, 0.4, 0.0),
    }
    for record in records:
        set_visible(record, record["name"] in showcase)
        if record["name"] in showcase:
            record["root"].location = showcase[record["name"]]
    scale_parts = [
        ico("Scale_Head", (-5.4, -0.7, 1.63), (0.16, 0.16, 0.18), mats["scale"]),
        cone("Scale_Body", 0.24, 0.17, 0.92, (-5.4, -0.7, 1.02), mats["scale"], 8),
        cylinder_between("Scale_Leg_L", (-5.50, -0.7, 0.60), (-5.52, -0.7, 0.02), 0.075, mats["scale"], 7),
        cylinder_between("Scale_Leg_R", (-5.30, -0.7, 0.60), (-5.28, -0.7, 0.02), 0.075, mats["scale"], 7),
        box("Scale_Metre", (-4.85, -0.7, 0.50), (0.10, 0.10, 1.0), mats["scale"]),
    ]
    move_to_collection(scale_parts, preview_collection)
    camera.data.ortho_scale = 14.5
    camera.location = (7.5, -16.0, 8.5)
    look_at(camera, (0.0, 0.0, 0.9))
    scene.render.filepath = str(PREVIEW_DIR / "crafting_stations_scale_preview.png")
    bpy.ops.render.render(write_still=True)

    for record in records:
        record["root"].location = original_locations[record["name"]]
        set_visible(record, True)
    bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE_DIR / "crafting_stations.blend"))
    total_polygons = sum(record["polygons"] for record in records)
    print(f"Built {len(records)} A-003 station assets ({total_polygons} polygons total)")


if __name__ == "__main__":
    main()
