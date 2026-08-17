"""Build MIRE's Wellspring set (asset batch A-008).

Run with:
  Blender --background --python tools/blender/build_wellspring_set.py

Outputs 12 individual metre-scale GLBs, an editable Blender source, a catalog,
and two previews. The four gameplay condition meshes use identical 4.6 m base
geometry and are centred from that shared anchor, preventing state-swap drift.
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
from mathutils import Vector


ROOT = Path(__file__).resolve().parents[2]
ASSET_DIR = ROOT / "assets" / "wellsprings"
SOURCE_DIR = ROOT / "assets" / "source"
EXPORT_DIR = ASSET_DIR / "exports"
PREVIEW_DIR = ASSET_DIR / "preview"

EXPECTED_NAMES = [
    "wellspring_distant_monolith",
    "wellspring_base",
    "wellspring_crystal",
    "wellspring_basin",
    "wellspring_roots",
    "wellspring_uncapped",
    "wellspring_capped",
    "wellspring_recorrupting",
    "wellspring_corrupted",
    "wellspring_ritual_pedestal",
    "wellspring_boundary_stones",
    "wellspring_guardian_platform",
]
STATE_NAMES = (
    "wellspring_uncapped",
    "wellspring_capped",
    "wellspring_recorrupting",
    "wellspring_corrupted",
)


def material(
    name: str,
    color: tuple[float, float, float, float],
    roughness: float = 0.9,
    metallic: float = 0.0,
    emission: tuple[float, float, float, float] | None = None,
    emission_strength: float = 0.0,
) -> bpy.types.Material:
    mat = bpy.data.materials.new(name)
    mat.diffuse_color = color
    mat.use_nodes = True
    shader = mat.node_tree.nodes.get("Principled BSDF")
    shader.inputs["Base Color"].default_value = color
    shader.inputs["Roughness"].default_value = roughness
    shader.inputs["Metallic"].default_value = metallic
    if emission is not None:
        shader.inputs["Emission Color"].default_value = emission
        shader.inputs["Emission Strength"].default_value = emission_strength
    return mat


def assign(obj: bpy.types.Object, mat: bpy.types.Material) -> bpy.types.Object:
    obj.data.materials.append(mat)
    for polygon in obj.data.polygons:
        polygon.use_smooth = False
    return obj


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


def cone(
    name: str,
    radius_bottom: float,
    radius_top: float,
    depth: float,
    location: tuple[float, float, float],
    mat: bpy.types.Material,
    vertices: int = 10,
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
    subdivisions: int = 1,
) -> bpy.types.Object:
    bpy.ops.mesh.primitive_ico_sphere_add(
        subdivisions=subdivisions,
        radius=1.0,
        location=location,
        rotation=rotation,
    )
    obj = bpy.context.object
    obj.name = name
    obj.scale = scale
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    return assign(obj, mat)


def beam_between(
    name: str,
    start: tuple[float, float, float],
    end: tuple[float, float, float],
    width: float,
    depth: float,
    mat: bpy.types.Material,
) -> bpy.types.Object:
    start_v = Vector(start)
    end_v = Vector(end)
    direction = end_v - start_v
    obj = box(name, tuple((start_v + end_v) * 0.5), (width, depth, direction.length), mat)
    obj.rotation_euler = direction.to_track_quat("Z", "Y").to_euler()
    return obj


def look_at(obj: bpy.types.Object, target: tuple[float, float, float]) -> None:
    obj.rotation_euler = (Vector(target) - obj.location).to_track_quat("-Z", "Y").to_euler()


def move_to_collection(objects: list[bpy.types.Object], collection: bpy.types.Collection) -> None:
    for obj in objects:
        for old_collection in list(obj.users_collection):
            old_collection.objects.unlink(obj)
        collection.objects.link(obj)


def world_bounds(objects: list[bpy.types.Object]) -> tuple[Vector, Vector]:
    bpy.context.view_layer.update()
    corners = [obj.matrix_world @ Vector(corner) for obj in objects if obj.type == "MESH" for corner in obj.bound_box]
    if not corners:
        raise RuntimeError("Cannot measure an asset with no mesh geometry")
    minimum = Vector((min(v.x for v in corners), min(v.y for v in corners), min(v.z for v in corners)))
    maximum = Vector((max(v.x for v in corners), max(v.y for v in corners), max(v.z for v in corners)))
    return minimum, maximum


# ── Shared modular pieces ────────────────────────────────────────────────────


def build_base(
    mats: dict[str, bpy.types.Material],
    prefix: str = "Wellspring_Base",
    rune_material: str = "ancient_glow",
    inlay_material: str = "bronze",
) -> None:
    cone(f"{prefix}_Lower", 2.30, 2.14, 0.24, (0.0, 0.0, 0.12), mats["stone_dark"], 12)
    cone(f"{prefix}_Middle", 2.12, 1.98, 0.18, (0.0, 0.0, 0.33), mats["stone"], 12)
    cone(f"{prefix}_Inlay", 1.82, 1.78, 0.055, (0.0, 0.0, 0.448), mats[inlay_material], 12)
    cone(f"{prefix}_Inner", 1.58, 1.55, 0.07, (0.0, 0.0, 0.51), mats["slate"], 12)
    for index in range(6):
        angle = index * math.pi / 3.0
        box(
            f"{prefix}_Buttress_{index + 1}",
            (math.cos(angle) * 2.06, math.sin(angle) * 2.06, 0.25),
            (0.65, 0.46, 0.34),
            mats["stone"],
            (0.0, 0.0, angle),
        )
    for index in range(12):
        angle = index * math.pi / 6.0
        box(
            f"{prefix}_Rune_{index + 1}",
            (math.cos(angle) * 1.70, math.sin(angle) * 1.70, 0.558),
            (0.27, 0.075, 0.025),
            mats[rune_material],
            (0.0, 0.0, angle),
        )


def build_basin(
    mats: dict[str, bpy.types.Material],
    prefix: str = "Wellspring_Basin",
    liquid: str = "mire_liquid",
) -> None:
    cone(f"{prefix}_Floor", 1.38, 1.34, 0.12, (0.0, 0.0, 0.60), mats["basin_dark"], 12)
    cone(f"{prefix}_Liquid", 1.25, 1.25, 0.035, (0.0, 0.0, 0.68), mats[liquid], 12)
    for index in range(12):
        angle = index * math.pi / 6.0
        radius = 1.58
        box(
            f"{prefix}_Rim_{index + 1}",
            (math.cos(angle) * radius, math.sin(angle) * radius, 0.72 + (index % 2) * 0.035),
            (0.70, 0.40, 0.36),
            mats["stone"] if index % 3 else mats["stone_light"],
            (0.0, 0.0, angle),
        )


def build_root_system(
    mats: dict[str, bpy.types.Material],
    prefix: str,
    count: int,
    material_name: str,
    climb: float = 0.8,
) -> None:
    for index in range(count):
        angle = index * math.tau / count + 0.17
        outer = Vector((math.cos(angle) * 2.45, math.sin(angle) * 2.45, 0.10))
        middle = Vector((math.cos(angle + 0.10) * 1.72, math.sin(angle + 0.10) * 1.72, 0.30))
        inner = Vector((math.cos(angle - 0.08) * 1.03, math.sin(angle - 0.08) * 1.03, climb))
        beam_between(f"{prefix}_Outer_{index + 1}", tuple(outer), tuple(middle), 0.24, 0.18, mats[material_name])
        beam_between(f"{prefix}_Inner_{index + 1}", tuple(middle), tuple(inner), 0.20, 0.15, mats[material_name])
        ico(f"{prefix}_Knot_{index + 1}", tuple(middle), (0.20, 0.17, 0.16), mats[material_name])


def build_crystal_cluster(
    mats: dict[str, bpy.types.Material],
    prefix: str,
    material_name: str,
    base_z: float = 0.68,
    height: float = 2.75,
    width: float = 0.52,
    lean: float = 0.0,
) -> None:
    body_height = height * 0.78
    body = cone(
        f"{prefix}_Body",
        width,
        width * 0.56,
        body_height,
        (lean * 0.35, 0.0, base_z + body_height * 0.5),
        mats[material_name],
        6,
        (0.0, lean, 0.0),
    )
    body.rotation_euler[1] = lean
    cone(
        f"{prefix}_Tip",
        width * 0.56,
        0.0,
        height - body_height,
        (lean * 0.75, 0.0, base_z + body_height + (height - body_height) * 0.5),
        mats[material_name],
        6,
        (0.0, lean, 0.0),
    )
    for index, (angle, scale, z_offset) in enumerate((
        (0.35, (0.24, 0.19, 0.68), 0.18),
        (2.25, (0.20, 0.17, 0.52), 0.10),
        (4.45, (0.18, 0.15, 0.44), 0.05),
    )):
        ico(
            f"{prefix}_Shard_{index + 1}",
            (math.cos(angle) * 0.63, math.sin(angle) * 0.63, base_z + scale[2] + z_offset),
            scale,
            mats[material_name],
            (0.12 * index, 0.28 * math.cos(angle), angle),
        )


def build_capping_crown(
    mats: dict[str, bpy.types.Material],
    prefix: str,
    intact_segments: set[int],
    height: float,
    glow_material: str,
    metal_material: str = "bronze",
) -> None:
    """Build the unmistakable ritual crown that visually means 'capped'."""
    radius = 0.76
    for index in sorted(intact_segments):
        angle_a = index * math.tau / 8.0 + math.pi * 0.125
        angle_b = (index + 1) * math.tau / 8.0 + math.pi * 0.125
        start = (math.cos(angle_a) * radius, math.sin(angle_a) * radius, height)
        end = (math.cos(angle_b) * radius, math.sin(angle_b) * radius, height)
        beam_between(f"{prefix}_Crown_Segment_{index + 1}", start, end, 0.105, 0.075, mats[metal_material])
        midpoint = (Vector(start) + Vector(end)) * 0.5
        ico(
            f"{prefix}_Crown_Glyph_{index + 1}",
            tuple(midpoint + Vector((0.0, 0.0, 0.09))),
            (0.085, 0.065, 0.13),
            mats[glow_material],
        )


# ── Twelve requested assets ──────────────────────────────────────────────────


def build_distant_monolith(mats: dict[str, bpy.types.Material]) -> None:
    cone("Distant_Monolith_Foot", 1.15, 0.94, 0.42, (0.0, 0.0, 0.21), mats["stone_dark"], 8)
    cone("Distant_Monolith_Shaft", 0.82, 0.48, 5.55, (0.0, 0.0, 3.12), mats["mire_stone"], 6, (0.03, -0.05, 0.0))
    cone("Distant_Monolith_Crown", 0.52, 0.0, 1.35, (0.0, 0.0, 6.57), mats["mire_crystal"], 6)
    for index, z in enumerate((1.45, 2.45, 3.45, 4.45)):
        box(f"Distant_Monolith_Slit_{index + 1}", (0.0, -0.755 + index * 0.035, z), (0.15, 0.045, 0.58), mats["mire_glow"], (0.0, 0.0, 0.08 * (index % 2)))
    for index, angle in enumerate((0.4, 2.5, 4.7)):
        ico(
            f"Distant_Monolith_Base_Shard_{index + 1}",
            (math.cos(angle) * 0.92, math.sin(angle) * 0.92, 0.52),
            (0.24, 0.19, 0.48),
            mats["mire_crystal_dim"],
            (0.2, 0.3, angle),
        )
    # Broken shoulder fins give the landmark a unique horizon silhouette from
    # every approach instead of reading as a generic obelisk in fog.
    for index, (angle, z, length) in enumerate(((0.3, 4.35, 0.92), (2.4, 5.05, 0.74), (4.55, 3.75, 0.82))):
        radial = Vector((math.cos(angle), math.sin(angle), 0.0))
        start = radial * 0.44 + Vector((0.0, 0.0, z))
        end = radial * length + Vector((0.0, 0.0, z + 0.32))
        beam_between(f"Distant_Monolith_Shoulder_{index + 1}", tuple(start), tuple(end), 0.28, 0.20, mats["mire_stone"])
        ico(
            f"Distant_Monolith_Shoulder_Crystal_{index + 1}",
            tuple(end + Vector((0.0, 0.0, 0.12))),
            (0.20, 0.15, 0.40),
            mats["mire_crystal_dim"],
            (0.2, 0.3, angle),
        )


def build_standalone_crystal(mats: dict[str, bpy.types.Material]) -> None:
    cone("Wellspring_Crystal_Socket", 0.78, 0.62, 0.34, (0.0, 0.0, 0.17), mats["bronze_dark"], 10)
    build_crystal_cluster(mats, "Wellspring_Crystal", "clear_crystal", 0.28, 2.20, 0.44)


def build_roots_asset(mats: dict[str, bpy.types.Material]) -> None:
    build_root_system(mats, "Wellspring_Roots", 7, "mire_root", 0.72)
    for index, angle in enumerate((0.9, 3.0, 5.2)):
        cone(
            f"Wellspring_Roots_Bud_{index + 1}",
            0.16,
            0.02,
            0.46,
            (math.cos(angle) * 1.18, math.sin(angle) * 1.18, 0.68),
            mats["mire_glow"],
            5,
            (0.24, -0.16, angle),
        )


def build_state(mats: dict[str, bpy.types.Material], condition: str) -> None:
    # Exact geometry and names across all four states. Only these parts define
    # horizontal normalization and the recommended static collision footprint.
    base_style = {
        "uncapped": ("mire_glow", "bronze_dark"),
        "capped": ("ancient_glow", "bronze"),
        "recorrupting": ("split_glow", "bronze_dark"),
        "corrupted": ("mire_glow", "mire_metal"),
    }[condition]
    build_base(mats, "Wellspring_State_Anchor", *base_style)
    if condition == "uncapped":
        build_basin(mats, "Uncapped_Basin", "mire_liquid")
        build_root_system(mats, "Uncapped_Root", 7, "mire_root", 1.10)
        build_crystal_cluster(mats, "Uncapped_Crystal", "mire_crystal", 0.62, 3.15, 0.56, -0.05)
        for index, z in enumerate((1.30, 2.10, 2.85)):
            box(f"Uncapped_Crack_{index + 1}", (0.0, -0.53, z), (0.10, 0.035, 0.46), mats["crack"], (0.15, 0.0, -0.20 + index * 0.16))
        for index, (angle, height) in enumerate(((1.1, 1.15), (3.45, 0.88))):
            cone(
                f"Uncapped_Satellite_Spire_{index + 1}",
                0.22,
                0.02,
                height,
                (math.cos(angle) * 0.72, math.sin(angle) * 0.72, 0.70 + height * 0.5),
                mats["mire_crystal_dim"],
                5,
                (0.18, -0.22, angle),
            )
    elif condition == "capped":
        build_basin(mats, "Capped_Basin", "clear_liquid")
        build_root_system(mats, "Capped_Retreated_Root", 4, "root_dormant", 0.70)
        build_crystal_cluster(mats, "Capped_Crystal", "clear_crystal", 0.62, 3.05, 0.50)
        for index in range(4):
            angle = index * math.pi * 0.5 + math.pi * 0.25
            start = (math.cos(angle) * 1.43, math.sin(angle) * 1.43, 0.72)
            end = (math.cos(angle) * 0.58, math.sin(angle) * 0.58, 2.35)
            beam_between(f"Capped_Brace_{index + 1}", start, end, 0.14, 0.10, mats["bronze"])
            ico(f"Capped_Brace_Gem_{index + 1}", end, (0.13, 0.11, 0.18), mats["ancient_glow"])
        cone("Capped_Collar_Lower", 0.66, 0.64, 0.13, (0.0, 0.0, 1.48), mats["bronze"], 10)
        cone("Capped_Collar_Upper", 0.56, 0.54, 0.12, (0.0, 0.0, 2.38), mats["bronze"], 10)
        build_capping_crown(mats, "Capped", set(range(8)), 3.02, "ancient_glow")
    elif condition == "recorrupting":
        build_basin(mats, "Recorrupting_Basin", "split_liquid")
        build_root_system(mats, "Recorrupting_Root", 6, "mire_root", 0.94)
        build_crystal_cluster(mats, "Recorrupting_Crystal", "clear_crystal_dim", 0.62, 2.82, 0.50, 0.10)
        # Purple growth visibly overtakes one side of the formerly clear core.
        ico("Recorrupting_Growth_Main", (-0.31, -0.22, 1.85), (0.28, 0.20, 0.92), mats["mire_crystal"], (0.12, -0.30, 0.25))
        ico("Recorrupting_Growth_Tip", (0.26, 0.10, 2.62), (0.17, 0.13, 0.55), mats["mire_glow"], (-0.2, 0.25, -0.3))
        for index in (0, 1):
            angle = index * math.pi + math.pi * 0.25
            beam_between(
                f"Recorrupting_Broken_Brace_{index + 1}",
                (math.cos(angle) * 1.43, math.sin(angle) * 1.43, 0.72),
                (math.cos(angle) * 0.82, math.sin(angle) * 0.82, 1.55),
                0.14,
                0.10,
                mats["bronze_dark"],
            )
        ico("Recorrupting_Fallen_Collar", (1.28, -0.42, 0.73), (0.42, 0.12, 0.11), mats["bronze"], (0.2, 0.5, -0.4))
        build_capping_crown(mats, "Recorrupting", {0, 1, 2, 5, 6}, 2.76, "split_glow", "bronze_dark")
        ico("Recorrupting_Fallen_Crown", (-1.05, -0.74, 0.78), (0.48, 0.12, 0.10), mats["bronze_dark"], (0.18, 0.42, 0.65))
    elif condition == "corrupted":
        build_basin(mats, "Corrupted_Basin", "mire_liquid")
        build_root_system(mats, "Corrupted_Root", 9, "mire_root", 1.34)
        build_crystal_cluster(mats, "Corrupted_Crystal", "mire_crystal", 0.62, 3.60, 0.64, -0.08)
        for index, angle in enumerate((0.2, 1.7, 3.2, 4.8)):
            cone(
                f"Corrupted_Spire_{index + 1}",
                0.22,
                0.02,
                0.86 + (index % 2) * 0.25,
                (math.cos(angle) * 1.02, math.sin(angle) * 1.02, 1.05),
                mats["mire_glow"],
                5,
                (0.28, -0.16, angle),
            )
        for index, z in enumerate((1.20, 2.05, 2.90)):
            box(f"Corrupted_Vein_{index + 1}", (0.03, -0.61, z), (0.15, 0.04, 0.62), mats["mire_glow"], (0.18, 0.0, 0.18 - index * 0.15))
        for index, (angle, height, width) in enumerate(((0.85, 1.65, 0.28), (3.75, 1.28, 0.24))):
            cone(
                f"Corrupted_Crown_Spire_{index + 1}",
                width,
                0.02,
                height,
                (math.cos(angle) * 0.78, math.sin(angle) * 0.78, 0.72 + height * 0.5),
                mats["mire_crystal_dim"],
                6,
                (0.22, -0.18, angle),
            )
    else:
        raise ValueError(f"Unknown Wellspring state: {condition}")


def build_ritual_pedestal(mats: dict[str, bpy.types.Material]) -> None:
    cone("Ritual_Pedestal_Foot", 0.78, 0.64, 0.26, (0.0, 0.0, 0.13), mats["stone_dark"], 10)
    cone("Ritual_Pedestal_Shaft", 0.48, 0.39, 0.96, (0.0, 0.0, 0.72), mats["stone"], 8)
    cone("Ritual_Pedestal_Collar", 0.58, 0.55, 0.13, (0.0, 0.0, 1.23), mats["bronze"], 10)
    cone("Ritual_Pedestal_Bowl", 0.52, 0.40, 0.24, (0.0, 0.0, 1.39), mats["basin_dark"], 10)
    cone("Ritual_Pedestal_Light", 0.33, 0.33, 0.035, (0.0, 0.0, 1.53), mats["ancient_glow"], 10)
    for index in range(4):
        angle = index * math.pi * 0.5
        box(
            f"Ritual_Pedestal_Rune_{index + 1}",
            (math.cos(angle) * 0.43, math.sin(angle) * 0.43, 0.73),
            (0.09, 0.035, 0.38),
            mats["ancient_glow"],
            (0.0, 0.0, angle),
        )


def build_boundary_stones(mats: dict[str, bpy.types.Material]) -> None:
    for index in range(8):
        angle = index * math.pi * 0.25
        radius = 3.15
        height = 1.08 + (index % 3) * 0.20
        cone(
            f"Boundary_Stone_{index + 1}",
            0.42,
            0.27,
            height,
            (math.cos(angle) * radius, math.sin(angle) * radius, height * 0.5),
            mats["stone"] if index % 2 else mats["stone_dark"],
            7,
            (0.08 * math.sin(angle), 0.10 * math.cos(angle), angle),
        )
        box(
            f"Boundary_Stone_Rune_{index + 1}",
            (math.cos(angle) * (radius + 0.29), math.sin(angle) * (radius + 0.29), height * 0.56),
            (0.11, 0.035, height * 0.42),
            mats["ancient_glow"],
            (0.0, 0.0, angle),
        )


def build_guardian_platform(mats: dict[str, bpy.types.Material]) -> None:
    cone("Guardian_Platform_Lower", 3.65, 3.48, 0.30, (0.0, 0.0, 0.15), mats["stone_dark"], 14)
    cone("Guardian_Platform_Upper", 3.38, 3.22, 0.22, (0.0, 0.0, 0.41), mats["stone"], 14)
    cone("Guardian_Platform_Arena", 2.95, 2.93, 0.08, (0.0, 0.0, 0.56), mats["slate"], 14)
    for index in range(14):
        angle = index * math.tau / 14.0
        box(
            f"Guardian_Platform_Rune_{index + 1}",
            (math.cos(angle) * 2.65, math.sin(angle) * 2.65, 0.615),
            (0.34, 0.09, 0.025),
            mats["ancient_glow"] if index % 2 else mats["mire_glow"],
            (0.0, 0.0, angle),
        )
    for index in range(4):
        angle = index * math.pi * 0.5 + math.pi * 0.25
        base = Vector((math.cos(angle) * 3.02, math.sin(angle) * 3.02, 0.61))
        cone(
            f"Guardian_Platform_Pylon_{index + 1}",
            0.34,
            0.22,
            1.18,
            tuple(base + Vector((0.0, 0.0, 0.59))),
            mats["stone_dark"],
            7,
            (0.04, -0.05, angle),
        )
        ico(
            f"Guardian_Platform_Gem_{index + 1}",
            tuple(base + Vector((0.0, 0.0, 1.28))),
            (0.18, 0.15, 0.27),
            mats["mire_crystal_dim"],
        )
    # One broken entry in the ring gives the platform a clear approach side.
    for index, x in enumerate((-0.72, -0.24, 0.24, 0.72)):
        box(f"Guardian_Platform_Step_{index + 1}", (x, -3.36 - index * 0.08, 0.18 + index * 0.08), (0.58, 0.72, 0.18), mats["stone"])


# ── Assembly, export, catalog and previews ───────────────────────────────────


def set_visible(record: dict, visible: bool) -> None:
    record["root"].hide_render = not visible
    for child in record["root"].children_recursive:
        child.hide_render = not visible


def create_asset(
    name: str,
    family: str,
    build_fn: Callable[[], None],
    display_location: tuple[float, float, float],
    anchor_parts: tuple[str, ...] = (),
) -> dict:
    collection = bpy.data.collections.new(name)
    bpy.context.scene.collection.children.link(collection)
    root = bpy.data.objects.new(name, None)
    root.empty_display_type = "PLAIN_AXES"
    collection.objects.link(root)
    before_names = {obj.name for obj in bpy.data.objects}
    build_fn()
    made = sorted((obj for obj in bpy.data.objects if obj.name not in before_names), key=lambda obj: obj.name)
    anchors = [obj for obj in made if any(part in obj.name for part in anchor_parts)] if anchor_parts else made
    if not anchors:
        raise RuntimeError(f"{name}: anchor_parts {anchor_parts} matched no geometry")
    anchor_min, anchor_max = world_bounds(anchors)
    minimum, _ = world_bounds(made)
    offset = Vector((
        -(anchor_min.x + anchor_max.x) * 0.5,
        -(anchor_min.y + anchor_max.y) * 0.5,
        -minimum.z,
    ))
    for obj in made:
        obj.location += offset
        if obj.type == "MESH":
            bpy.ops.object.select_all(action="DESELECT")
            obj.select_set(True)
            bpy.context.view_layer.objects.active = obj
            bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)
            obj.select_set(False)
    move_to_collection(made, collection)
    for obj in made:
        obj.parent = root
    minimum, maximum = world_bounds(made)
    anchor_min, anchor_max = world_bounds(anchors)
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
        "anchor_center": ((anchor_min + anchor_max) * 0.5).copy(),
        "anchor_size": (anchor_max - anchor_min).copy(),
    }


def setup_render(mats: dict[str, bpy.types.Material]) -> tuple[bpy.types.Scene, bpy.types.Object, bpy.types.Collection]:
    preview_collection = bpy.data.collections.new("PREVIEW_ONLY")
    bpy.context.scene.collection.children.link(preview_collection)
    bpy.ops.mesh.primitive_plane_add(size=60, location=(0.0, 0.0, -0.025))
    floor = bpy.context.object
    floor.name = "Preview_Ground"
    assign(floor, mats["ground"])
    move_to_collection([floor], preview_collection)
    bpy.ops.object.light_add(type="SUN", location=(0.0, 0.0, 18.0))
    sun = bpy.context.object
    sun.name = "Preview_Sun"
    sun.rotation_euler = (math.radians(33), math.radians(-24), math.radians(-31))
    sun.data.energy = 2.25
    sun.data.angle = math.radians(18)
    move_to_collection([sun], preview_collection)
    bpy.ops.object.light_add(type="AREA", location=(-10.0, -13.0, 11.0))
    fill = bpy.context.object
    fill.name = "Preview_Fill"
    fill.data.energy = 1700
    fill.data.color = (0.38, 0.22, 0.62)
    fill.data.shape = "DISK"
    fill.data.size = 10.0
    look_at(fill, (0.0, 0.0, 1.8))
    move_to_collection([fill], preview_collection)
    bpy.ops.object.camera_add(location=(14.0, -23.0, 13.0))
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
    scene.world.color = (0.010, 0.014, 0.024)
    scene.view_settings.look = "AgX - Medium High Contrast"
    return scene, camera, preview_collection


def add_scale_reference(mats: dict[str, bpy.types.Material], collection: bpy.types.Collection) -> None:
    parts = [box("Scale_Post", (-7.6, -0.8, 4.0), (0.12, 0.12, 8.0), mats["scale"])]
    for index in range(1, 17):
        z = index * 0.5
        length = 0.42 if index % 2 == 0 else 0.28
        parts.append(box(f"Scale_Tick_{index}", (-7.6 + length * 0.5, -0.8, z), (length, 0.10, 0.035), mats["scale"]))
    parts.append(box("Scale_Half_Metre_Cube", (-6.95, -0.92, 0.25), (0.5, 0.5, 0.5), mats["scale"]))
    move_to_collection(parts, collection)


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
        # Shared palette. Geometry helpers stay local: this kit's cone defaults
        # to 10 vertices where mire_art's uses 8, and its box is bevel-free for
        # the same Apple Silicon determinism reason as the Ward's.
        "stone": mat("stone"),
        "stone_light": mat("stone_light"),
        "stone_dark": mat("stone_dark"),
        "slate": mat("ward_slate"),
        "basin_dark": mat("mire_black"),
        "bronze": mat("brass"),
        "bronze_dark": mat("brass_dark"),
        "mire_metal": mat("mire_metal"),
        "ancient_glow": mat("ward_glow"),
        "split_glow": mat("split_glow"),
        "clear_crystal": mat("ward_crystal_light"),
        "clear_crystal_dim": mat("ward_crystal_dim"),
        "mire_stone": mat("mire"),
        "mire_root": mat("mire"),
        "root_dormant": mat("mire_dormant"),
        "mire_crystal": mat("crystal_tip"),
        "mire_crystal_dim": mat("crystal"),
        "mire_glow": mat("mire_glow"),
        "mire_liquid": mat("mire_liquid"),
        "clear_liquid": mat("clear_liquid"),
        "split_liquid": mat("split_liquid"),
        "crack": mat("coal"),
        "ground": mat("preview_ground"),
        "scale": mat("reference_blue"),
    }

    state_anchor = ("Wellspring_State_Anchor_",)
    builders: list[tuple[str, str, Callable[[], None], tuple[str, ...]]] = [
        ("wellspring_distant_monolith", "landmark", lambda: build_distant_monolith(mats), ()),
        ("wellspring_base", "modular", lambda: build_base(mats), ()),
        ("wellspring_crystal", "modular", lambda: build_standalone_crystal(mats), ()),
        ("wellspring_basin", "modular", lambda: build_basin(mats), ()),
        ("wellspring_roots", "modular", lambda: build_roots_asset(mats), ()),
        ("wellspring_uncapped", "state", lambda: build_state(mats, "uncapped"), state_anchor),
        ("wellspring_capped", "state", lambda: build_state(mats, "capped"), state_anchor),
        ("wellspring_recorrupting", "state", lambda: build_state(mats, "recorrupting"), state_anchor),
        ("wellspring_corrupted", "state", lambda: build_state(mats, "corrupted"), state_anchor),
        ("wellspring_ritual_pedestal", "ritual", lambda: build_ritual_pedestal(mats), ()),
        ("wellspring_boundary_stones", "boundary", lambda: build_boundary_stones(mats), ()),
        ("wellspring_guardian_platform", "arena", lambda: build_guardian_platform(mats), ()),
    ]
    if [name for name, _, _, _ in builders] != EXPECTED_NAMES:
        raise RuntimeError("A-008 specification and expected export list diverged")

    positions = [
        (-8.0, 3.0, 0.0), (-4.8, 3.0, 0.0), (-1.8, 3.0, 0.0), (1.0, 3.0, 0.0),
        (4.2, 3.0, 0.0), (7.6, 3.0, 0.0), (-8.0, -3.3, 0.0), (-4.3, -3.3, 0.0),
        (-0.4, -3.3, 0.0), (3.0, -3.3, 0.0), (6.1, -3.3, 0.0), (10.4, -3.3, 0.0),
    ]
    records: list[dict] = []
    for (name, family, builder, anchor), location in zip(builders, positions, strict=True):
        records.append(create_asset(name, family, builder, location, anchor))

    state_records = [record for record in records if record["name"] in STATE_NAMES]
    reference_center = state_records[0]["anchor_center"]
    reference_size = state_records[0]["anchor_size"]
    max_anchor_drift = max((record["anchor_center"] - reference_center).length for record in state_records)
    max_anchor_size_delta = max((record["anchor_size"] - reference_size).length for record in state_records)
    if max_anchor_drift > 0.000001 or max_anchor_size_delta > 0.000001:
        raise RuntimeError(
            f"Wellspring state anchors drift: center={max_anchor_drift:.9f}m size={max_anchor_size_delta:.9f}m"
        )

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
    camera.data.ortho_scale = 22.5
    camera.location = (18.0, -30.0, 17.0)
    look_at(camera, (1.0, -0.2, 2.0))
    scene.render.filepath = str(PREVIEW_DIR / "wellspring_preview.png")
    bpy.ops.render.render(write_still=True)

    original_locations = {record["name"]: record["root"].location.copy() for record in records}
    showcase_positions = {
        "wellspring_distant_monolith": (-5.4, 0.7, 0.0),
        "wellspring_capped": (-1.3, 0.3, 0.0),
        "wellspring_recorrupting": (3.2, 0.3, 0.0),
        "wellspring_ritual_pedestal": (6.2, -0.2, 0.0),
    }
    for record in records:
        set_visible(record, record["name"] in showcase_positions)
        if record["name"] in showcase_positions:
            record["root"].location = showcase_positions[record["name"]]
    add_scale_reference(mats, preview_collection)
    camera.data.ortho_scale = 17.5
    camera.location = (16.0, -25.0, 13.0)
    look_at(camera, (-0.2, 0.0, 2.7))
    scene.render.filepath = str(PREVIEW_DIR / "wellspring_scale_preview.png")
    bpy.ops.render.render(write_still=True)

    for record in records:
        record["root"].location = original_locations[record["name"]]
        set_visible(record, True)
    bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE_DIR / "wellspring_set.blend"))
    total_polygons = sum(record["polygons"] for record in records)
    print(
        f"Built {len(records)} A-008 Wellspring assets ({total_polygons} polygons total); "
        f"state anchor drift {max_anchor_drift * 1000.0:.2f} mm"
    )


if __name__ == "__main__":
    main()
