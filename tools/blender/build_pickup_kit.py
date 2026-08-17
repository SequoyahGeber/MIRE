"""Build MIRE's world-pickup kit (asset batch A-002, overhauled by task 2.1j).

Run with:
  Blender --background --python tools/blender/build_pickup_kit.py

Outputs 14 individual GLBs, an editable Blender source, a JSON catalog, and two
preview renders. Geometry and layout are deterministic.

What task 2.1j changed
----------------------
**Scale.** The kit was authored so each pickup filled its own preview frame, and
nothing was ever checked against the 1.80 m player. A coin came out 0.36 m across
— a dinner plate — a berry 0.71 m, a stone 1.08 m. Fourteen objects whose real
sizes span roughly 50:1 all landed within 4:1 of each other. Every asset now
builds to its ``mire_art.SCALE`` entry and ``main()`` fails the build if one
drifts more than 12% off.

**All-sided detail.** Decoration was placed by writing coordinates by hand, which
put it wherever the preview camera was looking: the log's three bark ridges all
sat at y=-0.20 running the same direction, the mushroom's three cap spots at
y=-0.25/-0.31/-0.18, the salvage fragment's three glow nodes at y=-0.20. Every
one of those is now placed with ``mire_art.radial()``, so detail wraps the form
and the asset reads from any angle. Verify with::

    Blender --background --python tools/blender/audit_all_sides.py -- --only pickup_

**Palette.** Thirty-seven private ``MIRE_Pickup_*`` colours are gone; the kit
draws from ``mire_art.PALETTE``, so its wood matches the forest's wood and its
iron matches a tool's iron. Iron ore's seams were bright orange (0.74, 0.23,
0.05) and read as copper; they are iron and brass now.

**Legibility by quantity, not inflation.** A true-size coin is 26 mm and would be
a pixel on the ground, which is presumably why it was inflated. Instead the coin
pickup is a small spill of five coins and the berry pickup a handful of seven —
honest next to a player, and still visible.
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path
from typing import Callable

sys.path.append(str(Path(__file__).resolve().parent))

import bpy
from mathutils import Vector

from mire_art import (
    SCALE,
    around,
    assign,
    box,
    check_scale,
    cone,
    cylinder_between,
    eevee_engine,
    ico,
    look_at,
    mat,
    mesh_object,
    move_to_collection,
    radial,
    reset_materials,
    world_bounds,
)

ROOT = Path(__file__).resolve().parents[2]
ASSET_DIR = ROOT / "assets" / "pickups"
SOURCE_DIR = ROOT / "assets" / "source"
EXPORT_DIR = ASSET_DIR / "exports"
PREVIEW_DIR = ASSET_DIR / "preview"

EXPECTED_NAMES = [
    "pickup_log",
    "pickup_branch",
    "pickup_stone",
    "pickup_flint",
    "pickup_iron_ore",
    "pickup_iron_ingot",
    "pickup_coal",
    "pickup_fibre_bundle",
    "pickup_berry",
    "pickup_mushroom",
    "pickup_raw_meat",
    "pickup_coin",
    "pickup_coin_stack",
    "pickup_salvage_fragment",
]


def shard(
    name: str,
    location: tuple[float, float, float],
    scale: tuple[float, float, float],
    material: bpy.types.Material,
    rotation: tuple[float, float, float] = (0.0, 0.0, 0.0),
) -> bpy.types.Object:
    """An angular chip with two apexes — the low-poly stand-in for fracture."""
    vertices = [
        (0.0, 0.0, 0.55),
        (-0.50, -0.30, 0.0),
        (0.42, -0.36, 0.0),
        (0.50, 0.28, 0.0),
        (-0.38, 0.38, 0.0),
        (0.0, 0.0, -0.45),
    ]
    faces = [(0, 1, 2), (0, 2, 3), (0, 3, 4), (0, 4, 1), (5, 2, 1), (5, 3, 2), (5, 4, 3), (5, 1, 4)]
    obj = mesh_object(name, vertices, faces, material)
    obj.location = location
    obj.scale = scale
    obj.rotation_euler = rotation
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    obj.select_set(False)
    return obj


# ---------------------------------------------------------------------------
# Builders — all dimensions in real metres against a 1.80 m player
# ---------------------------------------------------------------------------


def build_log() -> None:
    """A 1.20 m bucked log: tapered, knotted, bark texture right around it."""
    half, r0, r1 = 0.60, 0.115, 0.098
    # Two segments with a slight kink, so the silhouette is not a perfect tube.
    cylinder_between("Log_A", (-half, 0.0, r0), (0.02, 0.012, r0 * 0.99), r0, mat("wood_bark"), 10, 0.97)
    cylinder_between("Log_B", (0.02, 0.012, r0 * 0.99), (half, -0.008, r1 * 1.02), r1, mat("wood_bark"), 10, 0.97)
    # End grain, slightly proud of the bark so the ring reads as a cut face.
    cone("Cut_L", r0 * 0.97, r0 * 0.90, 0.020, (-half - 0.008, 0.0, r0), mat("wood_cut"), 10, (0.0, math.radians(90), 0.0))
    cone("Cut_R", r1 * 0.97, r1 * 0.90, 0.020, (half + 0.008, -0.008, r1 * 1.02), mat("wood_cut"), 10, (0.0, math.radians(90), 0.0))
    # Bark plates: long ridges running WITH the grain, spaced right around the
    # trunk. Short nubs read as dirt at gameplay distance; a plate that runs a
    # third of the length catches the light and says "bark" from any azimuth.
    for i, (angle, rad) in enumerate(radial(6, r0 * 0.90, seed=201, jitter=0.38)):
        x0 = -0.46 + (i * 0.19) % 0.88
        length = 0.26 + (i % 3) * 0.09
        drift = 0.055 * (1 if i % 2 else -1)
        a0, a1 = angle, angle + drift
        p0 = around((x0, 0.0, r0), a0, rad)
        p1 = around((min(x0 + length, half - 0.03), 0.0, r0 * 0.99), a1, rad * 0.97)
        cylinder_between(f"Bark_Plate_{i + 1}", p0, p1, 0.019,
                         mat("wood_bark_light" if i % 2 else "wood_bark_dark"), 5, 0.88)
    # Branch stubs on opposite flanks, big enough to break the silhouette.
    for i, (angle, rad) in enumerate(radial(3, r0, seed=77, jitter=0.22, phase=0.9)):
        cx = -0.26 + i * 0.30
        base = around((cx, 0.0, r0), angle, rad * 0.80)
        tip = around((cx + (0.06 if i % 2 else -0.05), 0.0, r0 + 0.012), angle, rad + 0.075 + (i % 2) * 0.022)
        cylinder_between(f"Branch_Stub_{i + 1}", base, tip, 0.030 - (i % 2) * 0.006, mat("wood_bark"), 7, 0.72)
        cone(f"Stub_Cut_{i + 1}", 0.023 - (i % 2) * 0.005, 0.019, 0.009, tip, mat("wood_cut"), 7,
             (0.0, math.radians(90), angle))
    # Knots on two different faces, not one decal on the front.
    for i, (angle, rad) in enumerate(radial(2, r1 * 0.86, seed=88, jitter=0.0, phase=2.4)):
        ico(f"Knot_{i + 1}", around((0.18 + i * 0.26, 0.0, r1), angle, rad),
            (0.034, 0.030, 0.024), mat("wood_bark_dark"), (0.2, 0.4 * i, 0.0))


def build_branch() -> None:
    """0.85 m forked branch; twigs leave at three different angles."""
    cylinder_between("Branch_Main", (-0.40, 0.0, 0.055), (0.40, 0.02, 0.075), 0.030, mat("wood_bark_light"), 8, 0.82)
    for i, (angle, rad) in enumerate(radial(3, 0.030, seed=311, jitter=0.30)):
        x = -0.20 + i * 0.26
        base = around((x, 0.0, 0.065), angle, rad * 0.8)
        tip = around((x + 0.13 - i * 0.05, 0.0, 0.065 + 0.05 + i * 0.02), angle, rad + 0.075 + i * 0.012)
        cylinder_between(f"Twig_{i + 1}", base, tip, 0.013 - i * 0.002, mat("wood_bark"), 6, 0.7)
    cone("Broken_End", 0.028, 0.010, 0.030, (-0.415, 0.0, 0.054), mat("wood_cut"), 8, (0.0, math.radians(-92), 0.0))


def build_stone() -> None:
    """0.18 m rock: three overlapping masses, no single flat face."""
    ico("Stone_Core", (0.0, 0.0, 0.062), (0.082, 0.070, 0.058), mat("stone"), (0.18, -0.12, 0.34))
    for i, (angle, rad) in enumerate(radial(3, 0.052, seed=404, jitter=0.40)):
        p = around((0.0, 0.0, 0.050 + i * 0.012), angle, rad)
        ico(f"Stone_Lobe_{i + 1}", p, (0.040 - i * 0.006, 0.036, 0.030),
            mat("stone_light" if i == 0 else "stone_dark" if i == 2 else "stone"),
            (0.3 * i, 0.2 - i * 0.3, 0.4 * i))


def build_flint() -> None:
    """0.13 m flint nodule with fracture flakes on several faces."""
    shard("Flint_Core", (0.0, 0.0, 0.044), (0.100, 0.074, 0.092), mat("stone_dark"), (0.12, -0.28, 0.18))
    for i, (angle, rad) in enumerate(radial(4, 0.038, seed=515, jitter=0.38)):
        p = around((0.0, 0.0, 0.033 + (i % 2) * 0.019), angle, rad)
        shard(f"Flint_Flake_{i + 1}", p, (0.029, 0.022, 0.021),
              mat("stone_light" if i % 2 else "stone"), (0.3 - i * 0.2, 0.4, 0.5 * i))


def build_iron_ore() -> None:
    """0.20 m ore chunk. Seams are iron and brass, never the old orange."""
    ico("Ore_Rock", (0.0, 0.0, 0.064), (0.079, 0.069, 0.061), mat("stone_dark"), (0.2, -0.3, 0.4))
    for i, (angle, rad) in enumerate(radial(6, 0.059, seed=626, jitter=0.36)):
        p = around((0.0, 0.0, 0.051 + (i % 3) * 0.017), angle, rad)
        ico(f"Ore_Seam_{i + 1}", p, (0.024 - (i % 3) * 0.004, 0.017, 0.015),
            mat("iron" if i % 3 else "brass"), (0.2 * i, 0.4 - i * 0.2, 0.1 * i))


def build_ingot() -> None:
    """0.26 m cast ingot with draft angle and a struck mark."""
    hx, hy, h = 0.130, 0.055, 0.052
    tx, ty = 0.104, 0.038
    vertices = [
        (-hx, -hy, 0.0), (hx, -hy, 0.0), (hx, hy, 0.0), (-hx, hy, 0.0),
        (-tx, -ty, h), (tx, -ty, h), (tx, ty, h), (-tx, ty, h),
    ]
    faces = [(0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)]
    mesh_object("Iron_Ingot", vertices, faces, mat("iron"))
    box("Ingot_Stamp", (0.0, 0.0, h - 0.004), (0.068, 0.030, 0.010), mat("iron_dark"),
        (0.0, 0.0, math.radians(-8)), 0.004)
    # Casting seam down both long flanks, not one.
    for sign in (-1.0, 1.0):
        box(f"Cast_Seam_{'p' if sign > 0 else 'n'}", (0.0, sign * (hy - 0.004), h * 0.42),
            (0.22, 0.007, 0.008), mat("iron_dark"))


def build_coal() -> None:
    """0.16 m heap of six lumps at genuinely different orientations."""
    ico("Coal_Base", (0.0, 0.0, 0.030), (0.062, 0.055, 0.030), mat("coal"), (0.1, 0.2, 0.3))
    for i, (angle, rad) in enumerate(radial(5, 0.048, seed=737, jitter=0.42)):
        p = around((0.0, 0.0, 0.038 + (i % 3) * 0.016), angle, rad)
        ico(f"Coal_{i + 1}", p, (0.034 - (i % 3) * 0.006, 0.029, 0.026),
            mat("coal" if i % 4 else "stone_dark"), (0.4 * i, 0.3 - i * 0.2, 0.5 * i))


def build_fibre() -> None:
    """0.32 m bundle; stalks splay around the binding instead of lying flat."""
    for i, (angle, rad) in enumerate(radial(9, 0.032, seed=848, jitter=0.44)):
        y0, z0 = around((0.0, 0.0, 0.038), angle, rad)[1:]
        spread = 1.55
        cylinder_between(
            f"Fibre_{i + 1}",
            (-0.150, y0 * spread, max(z0 * spread, 0.008)),
            (0.150, y0 * spread * 0.82 + 0.006, max(z0 * spread * 0.9, 0.008)),
            0.0085, mat("fibre" if i % 3 else "grass_dry"), 5,
        )
    for x in (-0.055, 0.055):
        cone(f"Binding_{'a' if x < 0 else 'b'}", 0.040, 0.040, 0.014, (x, 0.0, 0.038),
             mat("rope"), 8, (0.0, math.radians(90), 0.0))


def build_berry() -> None:
    """0.12 m handful of seven berries, each a true ~18 mm."""
    r = 0.0095
    ico("Berry_Base_A", (-0.017, 0.006, r), (r, r, r * 0.92), mat("blood"), subdivisions=1)
    ico("Berry_Base_B", (0.019, -0.008, r), (r, r, r * 0.92), mat("blood"), subdivisions=1)
    for i, (angle, rad) in enumerate(radial(5, 0.024, seed=959, jitter=0.40)):
        p = around((0.0, 0.0, r + 0.008 + (i % 2) * 0.007), angle, rad)
        ico(f"Berry_{i + 1}", p, (r, r, r * 0.94), mat("blood" if i % 2 else "cloth_red"), subdivisions=1)
    cylinder_between("Sprig", (0.004, 0.0, 0.030), (0.016, 0.010, 0.048), 0.0035, mat("grass_dark"), 5)
    for i, (angle, rad) in enumerate(radial(2, 0.020, seed=96, jitter=0.0, phase=0.6)):
        leaf = ico(f"Leaf_{i + 1}", around((0.012, 0.006, 0.044), angle, rad), (0.020, 0.009, 0.004),
                   mat("leaf" if i else "leaf_light"), (0.1, 0.25, 0.0))
        leaf.rotation_euler[2] = angle


def build_mushroom() -> None:
    """0.16 m pair of caps. Gills are modelled, so the bottom view reads."""
    for i, (cap_r, cap_h, stem_h, offset) in enumerate(
        ((0.055, 0.026, 0.052, (-0.026, 0.008)), (0.036, 0.018, 0.034, (0.038, -0.012)))
    ):
        ox, oy = offset
        cone(f"Stem_{i + 1}", 0.013, 0.010, stem_h, (ox, oy, stem_h * 0.5), mat("flesh_fat"), 9)
        ico(f"Cap_{i + 1}", (ox, oy, stem_h + cap_h * 0.42), (cap_r, cap_r * 0.94, cap_h),
            mat("mire_flesh" if i == 0 else "mire_light"), (0.0, 0.0, 0.18 * (i + 1)), 2)
        # Radial gills under the cap — the underside was a blank dome before.
        for j, (angle, rad) in enumerate(radial(7, cap_r * 0.62, seed=1070 + i * 7, jitter=0.12)):
            g = around((ox, oy, stem_h + cap_h * 0.06), angle, rad)
            blade = box(f"Gill_{i + 1}_{j + 1}", g, (cap_r * 0.60, 0.0035, cap_h * 0.30), mat("flesh_fat"))
            blade.rotation_euler[2] = angle
        # Spots wrapped round the cap rather than pasted on the front.
        for j, (angle, rad) in enumerate(radial(4, cap_r * 0.58, seed=1180 + i * 11, jitter=0.40)):
            s = around((ox, oy, stem_h + cap_h * 0.80), angle, rad)
            ico(f"Spot_{i + 1}_{j + 1}", s, (0.008, 0.008, 0.004), mat("flesh_fat"), subdivisions=1)


def build_meat() -> None:
    """0.30 m cut of meat: the bone passes through it, marbling wraps it."""
    top, mid = 0.072, 0.030
    vertices = [
        (-0.150, -0.062, 0.0), (0.108, -0.078, 0.0), (0.150, 0.010, 0.0), (0.066, 0.082, 0.0), (-0.098, 0.070, 0.0),
        (-0.138, -0.052, top), (0.096, -0.066, top), (0.134, 0.008, top), (0.058, 0.070, top), (-0.088, 0.058, top),
    ]
    faces = [(0, 4, 3, 2, 1), (5, 6, 7, 8, 9), (0, 1, 6, 5), (1, 2, 7, 6), (2, 3, 8, 7), (3, 4, 9, 8), (4, 0, 5, 9)]
    mesh_object("Raw_Meat", vertices, faces, mat("flesh_raw"))
    # The bone runs THROUGH the cut and shows a sawn face at each end, instead of
    # lying on the surface like a garnish.
    cylinder_between("Bone", (-0.128, 0.004, mid), (0.126, 0.008, mid + 0.006), 0.021, mat("bone"), 8, 0.96)
    for sign, x in ((-1.0, -0.132), (1.0, 0.130)):
        cone(f"Bone_Face_{'l' if sign < 0 else 'r'}", 0.021, 0.019, 0.006, (x, 0.006, mid + (0.003 if sign > 0 else 0.0)),
             mat("flesh_fat"), 8, (0.0, math.radians(90), 0.0))
    # Marbling on several faces, wrapped, not a single front stripe.
    for i, (angle, rad) in enumerate(radial(4, 0.088, seed=1212, jitter=0.36)):
        p = around((0.0, 0.0, 0.018 + (i % 2) * 0.030), angle, rad)
        strip = box(f"Fat_{i + 1}", p, (0.058, 0.010, 0.011), mat("flesh_fat"))
        strip.rotation_euler[2] = angle + 1.57


def add_coin(name: str, location: tuple[float, float, float], upright: bool, spin: float = 0.0) -> None:
    rotation = (math.radians(90), 0.0, spin) if upright else (0.0, 0.0, spin)
    cone(name, 0.0132, 0.0132, 0.0026, location, mat("gold"), 12, rotation)
    cone(f"{name}_Face", 0.0082, 0.0082, 0.0011, location, mat("brass"), 12, rotation)


def build_coin() -> None:
    """0.11 m spill of five coins — a true 26 mm coin, made visible by number."""
    add_coin("Coin_Flat_A", (0.0, 0.0, 0.0014), False, 0.0)
    for i, (angle, rad) in enumerate(radial(3, 0.036, seed=1313, jitter=0.34)):
        p = around((0.0, 0.0, 0.0014 + (i % 2) * 0.0026), angle, rad)
        add_coin(f"Coin_Flat_{i + 1}", p, False, angle)
    lean = around((0.0, 0.0, 0.0132), 2.1, 0.036)
    add_coin("Coin_Leaning", lean, True, 2.1)


def build_coin_stack() -> None:
    """0.14 m stack plus loose coins fallen around its base."""
    for i in range(7):
        add_coin(f"Coin_Stacked_{i + 1}", (0.0, 0.0, 0.0014 + i * 0.0027), False, i * 0.22)
    for i, (angle, rad) in enumerate(radial(3, 0.050, seed=1414, jitter=0.38)):
        add_coin(f"Coin_Loose_{i + 1}", around((0.0, 0.0, 0.0014), angle, rad), False, angle)


def build_salvage() -> None:
    """0.19 m torn plate; the emissive nodes sit on more than one face."""
    plate = box("Salvage_Plate", (0.0, 0.0, 0.048), (0.155, 0.098, 0.028), mat("iron"), (0.05, -0.15, 0.28), 0.016)
    plate.rotation_euler[2] += 0.12
    box("Salvage_Brace", (-0.042, -0.046, 0.052), (0.028, 0.112, 0.024), mat("iron_dark"), (0.2, -0.1, -0.38), 0.006)
    for i, (angle, rad) in enumerate(radial(3, 0.056, seed=1515, jitter=0.42)):
        p = around((0.0, 0.0, 0.052 + (i % 2) * 0.014), angle, rad)
        ico(f"Salvage_Node_{i + 1}", p, (0.013, 0.008, 0.013), mat("mire_glow"), subdivisions=1)
    cylinder_between("Loose_Wire", (0.052, 0.026, 0.056), (0.094, 0.052, 0.020), 0.0045, mat("brass"), 6)


# ---------------------------------------------------------------------------
# Assembly
# ---------------------------------------------------------------------------


def create_asset(name: str, family: str, build_fn: Callable[[], None],
                 display_location: tuple[float, float, float]) -> dict:
    collection = bpy.data.collections.new(name)
    bpy.context.scene.collection.children.link(collection)
    root = bpy.data.objects.new(name, None)
    root.empty_display_type = "PLAIN_AXES"
    collection.objects.link(root)
    before = set(bpy.data.objects)
    build_fn()
    made = [obj for obj in bpy.data.objects if obj not in before]

    bpy.context.view_layer.update()
    minimum, maximum = world_bounds(made)
    offset = Vector((-(minimum.x + maximum.x) * 0.5, -(minimum.y + maximum.y) * 0.5, -minimum.z))
    for obj in made:
        obj.location += offset
    move_to_collection(made, collection)
    for obj in made:
        obj.parent = root
    bpy.context.view_layer.update()
    minimum, maximum = world_bounds(made)
    dimensions = maximum - minimum
    polygons = sum(len(obj.data.polygons) for obj in made if obj.type == "MESH")
    materials = sorted({m.name for obj in made if obj.type == "MESH" for m in obj.data.materials if m})

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
        "name": name, "family": family, "root": root,
        "width": dimensions.x, "depth": dimensions.y, "height": dimensions.z,
        "parts": sum(1 for obj in made if obj.type == "MESH"),
        "polygons": polygons, "materials": materials,
    }


def set_visible(record: dict, visible: bool) -> None:
    record["root"].hide_render = not visible
    for child in record["root"].children_recursive:
        child.hide_render = not visible


def setup_render() -> tuple[bpy.types.Scene, bpy.types.Object, bpy.types.Collection]:
    preview_collection = bpy.data.collections.new("PREVIEW_ONLY")
    bpy.context.scene.collection.children.link(preview_collection)
    bpy.ops.mesh.primitive_plane_add(size=40, location=(0.0, 0.0, -0.004))
    floor = bpy.context.object
    floor.name = "Preview_Ground"
    assign(floor, mat("preview_ground"))
    move_to_collection([floor], preview_collection)
    bpy.ops.object.light_add(type="SUN", location=(0.0, 0.0, 15.0))
    sun = bpy.context.object
    sun.name = "Preview_Sun"
    sun.rotation_euler = (math.radians(34), math.radians(-22), math.radians(-28))
    sun.data.energy = 2.35
    sun.data.angle = math.radians(20)
    move_to_collection([sun], preview_collection)
    bpy.ops.object.light_add(type="AREA", location=(-6.0, -8.0, 8.0))
    fill = bpy.context.object
    fill.name = "Preview_Fill"
    fill.data.energy = 1000
    fill.data.color = (0.43, 0.28, 0.68)
    fill.data.shape = "DISK"
    fill.data.size = 7.0
    look_at(fill, (0.0, 0.0, 0.3))
    move_to_collection([fill], preview_collection)
    bpy.ops.object.camera_add(location=(10.5, -15.0, 8.5))
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

    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for datablocks in (bpy.data.materials, bpy.data.curves, bpy.data.cameras, bpy.data.lights):
        for block in list(datablocks):
            datablocks.remove(block)
    reset_materials()

    builders: list[tuple[str, str, Callable[[], None]]] = [
        ("pickup_log", "wood", build_log),
        ("pickup_branch", "wood", build_branch),
        ("pickup_stone", "mineral", build_stone),
        ("pickup_flint", "mineral", build_flint),
        ("pickup_iron_ore", "mineral", build_iron_ore),
        ("pickup_iron_ingot", "crafted", build_ingot),
        ("pickup_coal", "mineral", build_coal),
        ("pickup_fibre_bundle", "organic", build_fibre),
        ("pickup_berry", "food", build_berry),
        ("pickup_mushroom", "food", build_mushroom),
        ("pickup_raw_meat", "food", build_meat),
        ("pickup_coin", "currency", build_coin),
        ("pickup_coin_stack", "currency", build_coin_stack),
        ("pickup_salvage_fragment", "salvage", build_salvage),
    ]
    if [name for name, _, _ in builders] != EXPECTED_NAMES:
        raise RuntimeError("A-002 specification and expected export list diverged")

    records: list[dict] = []
    for index, (name, family, builder) in enumerate(builders):
        column = index % 7
        row = index // 7
        location = ((column - 3) * 0.42, (0.30 - row * 0.52), 0.0)
        records.append(create_asset(name, family, builder, location))

    # Scale is a build-time contract now, not something a preview might reveal.
    complaints = [c for c in (check_scale(r["name"], (r["width"], r["depth"], r["height"])) for r in records) if c]
    if complaints:
        raise SystemExit("scale contract failed:\n  " + "\n  ".join(complaints))

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
    (ASSET_DIR / "catalog.json").write_text(json.dumps(catalog, indent=2) + "\n")

    scene, camera, preview_collection = setup_render()

    for record in records:
        set_visible(record, True)
    camera.data.ortho_scale = 3.2
    camera.location = (2.2, -3.1, 1.9)
    look_at(camera, (0.0, -0.1, 0.06))
    scene.render.filepath = str(PREVIEW_DIR / "pickups_preview.png")
    bpy.ops.render.render(write_still=True)

    # Scale preview: a 1.80 m human bar so nothing can quietly drift again.
    for record in records:
        set_visible(record, record["name"] in {"pickup_log", "pickup_iron_ingot", "pickup_stone",
                                               "pickup_mushroom", "pickup_berry", "pickup_coin"})
    # The reference stands clear of the row rather than on top of it, and the
    # frame holds all 1.80 m of it — a scale shot that crops the yardstick is
    # how the old kit passed inspection at ten times life size.
    ref = box("Scale_Reference_Human", (-1.95, 0.10, 0.90), (0.34, 0.20, 1.80), mat("reference_blue"))
    move_to_collection([ref], preview_collection)
    # Vertical extent of an ortho frame is ortho_scale * (res_y / res_x) =
    # 4.6 * 1000/1600 = 2.88 m; centred at z=0.95 that spans -0.49..2.39, so all
    # 1.80 m of the reference is inside the frame with headroom.
    camera.data.ortho_scale = 4.6
    camera.location = (2.4, -4.2, 2.1)
    look_at(camera, (-0.35, 0.0, 0.95))
    scene.render.filepath = str(PREVIEW_DIR / "pickups_scale_preview.png")
    bpy.ops.render.render(write_still=True)

    bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE_DIR / "pickup_kit.blend"))
    total = sum(r["polygons"] for r in records)
    print(f"pickup kit: {len(records)} assets, {total} polygons")
    for r in records:
        print(f"  {r['name']:26s} {r['width']:.3f} x {r['depth']:.3f} x {r['height']:.3f} m  {r['polygons']:4d} polys")


if __name__ == "__main__":
    main()
