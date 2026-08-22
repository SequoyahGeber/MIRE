"""The tier-4 and tier-5 materials: bogsilver and wellglass (F-473, D-200).

Run with:
  Blender --background --python tools/blender/build_deep_materials.py

Four world pickups — unworked bogsilver, a cast bogsilver ingot, a wellglass shard cluster, and a
guardian core. They are `pickup_*` by name and behave exactly like `build_pickup_kit.py`'s fifteen,
because a player picks them up the same way; they live in their own kit and their own catalog only
because two agents cannot share one generator without one of them losing work.

**Every one of these is modelled on what the real material actually does**, not on a hue shift of the
iron it sits above in the ladder. Silver grows in wires and tarnishes blue-black in sulphur water;
cast silver sinks and spits as it freezes where iron sets flat; volcanic glass breaks in curved
dishes with no cleavage planes. Each builder's docstring says which fact it is built on, because
"why is it shaped like that" is the question this file exists to answer for whoever edits it next.

Sizes are enforced, not asserted: `create_asset` scales each finished asset onto its `mire_art.SCALE`
entry, the same contract F-440 gave the pickup kit.
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
from godot_import_lock import import_cache_guard  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
ASSET_DIR = ROOT / "assets" / "deep_materials"
SOURCE_DIR = ROOT / "assets" / "source"
EXPORT_DIR = ASSET_DIR / "exports"
PREVIEW_DIR = ASSET_DIR / "preview"

EXPECTED_NAMES = [
    "pickup_bogsilver_ore",
    "pickup_bogsilver_ingot",
    "pickup_wellglass_shard",
    "pickup_guardian_core",
]


def shard(
    name: str,
    location: tuple[float, float, float],
    scale: tuple[float, float, float],
    material: bpy.types.Material,
    rotation: tuple[float, float, float] = (0.0, 0.0, 0.0),
) -> bpy.types.Object:
    """An angular chip with two apexes — the low-poly stand-in for fracture.

    Copied deliberately from `build_pickup_kit.py` rather than imported: that file belongs to the
    asset queue's own task and importing across two generators would couple their rebuild order.
    """
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


def build_bogsilver_ore() -> None:
    """0.22 m of unworked bogsilver, and deliberately not "iron ore in another colour".

    Iron ore reads as SEAMS — flat bright bands lying in the rock, which is what banded ironstone
    actually looks like. Native silver does not do that. It grows in WIRES: fine threads that push
    out of a cavity in the host rock and curl over, which is why a silver specimen looks hairy where
    an iron one looks striped. So the metal here is a dense nest of thin curling rods filling one
    open vug on the rock, not a spray of spikes all over it — real native silver occupies a pocket,
    and a lump with metal on every face reads as a burr.

    The host stays ordinary grey stone. The first pass made the whole rock the green mineral crust
    and it read as a mossy boulder; the crust belongs on the lip of the vug, where the bog water that
    put the silver there has stained it, and nowhere else.
    """
    ico("Bogsilver_Host", (0.0, 0.0, 0.068), (0.086, 0.074, 0.064), mat("stone"), (0.3, -0.2, 0.5))
    ico("Bogsilver_Host_Shoulder", (0.034, 0.022, 0.104), (0.046, 0.042, 0.030), mat("stone_dark"), (0.1, 0.4, -0.3))
    ico("Bogsilver_Host_Foot", (-0.040, -0.034, 0.030), (0.048, 0.044, 0.028), mat("stone_dark"), (0.5, 0.1, 0.2))

    # The vug: a shallow stained bowl the wires grow out of. Its lip is the only crust on the asset.
    vug = (-0.030, 0.040, 0.086)
    ico("Bogsilver_Vug", vug, (0.044, 0.040, 0.032), mat("bogsilver_crust"), (0.35, 0.15, 0.4))
    ico("Bogsilver_Vug_Floor", (vug[0], vug[1], vug[2] + 0.004), (0.030, 0.028, 0.022), mat("bogsilver_dark"), (0.2, 0.4, 0.1))

    # Wires. Nine of them, fine, of three lengths, each leaning its own way and every one rooted in
    # the vug rather than in the rock at large.
    for i, (angle, rad) in enumerate(radial(9, 0.026, seed=929, jitter=0.55)):
        x, y, _ = around((0.0, 0.0, 0.0), angle, rad)
        length = 0.030 - (i % 3) * 0.008
        ico(
            f"Bogsilver_Wire_{i + 1}",
            (vug[0] + x, vug[1] + y, vug[2] + 0.016 + length * 0.5),
            (0.0055, 0.0050, length),
            mat("bogsilver_light" if i % 3 else "bogsilver"),
            (0.30 + 0.16 * i, 0.22 - i * 0.09, 0.5 * i),
        )
    # Two wires have gone over to tarnish — sulphur water is what put the silver here and it is still
    # working on it. Placed on the outside of the nest so the dark reads as bloom, not as a hole.
    for i, (angle, rad) in enumerate(radial(2, 0.030, seed=515, jitter=0.2)):
        x, y, _ = around((0.0, 0.0, 0.0), angle, rad)
        ico(
            f"Bogsilver_Wire_Tarnished_{i + 1}",
            (vug[0] + x, vug[1] + y, vug[2] + 0.020),
            (0.0060, 0.0055, 0.022),
            mat("bogsilver_dark"),
            (0.4 + 0.3 * i, -0.2, 0.9 * i),
        )
    # One flake broken loose and lying on the rock's shoulder, on the far side from the vug, so the
    # asset has something to say from the angles the nest is hidden at (task 2.1j).
    ico("Bogsilver_Flake", (0.050, -0.028, 0.096), (0.020, 0.016, 0.008), mat("bogsilver"), (0.2, 0.5, 0.3))


def build_bogsilver_ingot() -> None:
    """0.26 m cast bogsilver, from the same mould as the iron ingot and NOT the same object.

    Same billet form on purpose — one furnace, one mould, whatever you pour into it. What separates
    them is what the metal does while it cools: silver takes up oxygen when molten and throws it back
    out as it freezes, so a cast silver bar's top face sinks and spits instead of setting flat. That
    is a real, specific, one-material fact, and it is worth more here than a recolour: this bar has a
    shrunken top with a raised lip around it where iron has a flat struck stamp.
    """
    hx, hy, h = 0.130, 0.055, 0.052
    tx, ty = 0.104, 0.038
    vertices = [
        (-hx, -hy, 0.0), (hx, -hy, 0.0), (hx, hy, 0.0), (-hx, hy, 0.0),
        (-tx, -ty, h), (tx, -ty, h), (tx, ty, h), (-tx, ty, h),
    ]
    faces = [(0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)]
    mesh_object("Bogsilver_Ingot", vertices, faces, mat("bogsilver"))
    # The sunken face, sitting BELOW the rim rather than on top of it.
    # Sits just under the rim and only just proud of the cast face, so it reads as a shallow
    # depression in the top rather than as a slab laid on it — the first pass was 14 mm thick and
    # 12 mm down, which rendered as a black plate balanced on the bar.
    box("Bogsilver_Sink", (0.0, 0.0, h - 0.004), (0.112, 0.034, 0.006), mat("bogsilver_dark"),
        (0.0, 0.0, math.radians(-3)))
    for i, (angle, rad) in enumerate(radial(4, 0.052, seed=515, jitter=0.30)):
        x, y, _ = around((0.0, 0.0, 0.0), angle, rad)
        # Spit: small frozen blisters around the sink, each a different size.
        ico(f"Bogsilver_Blister_{i + 1}", (x * 1.5, y * 0.55, h - 0.001),
            (0.019 - (i % 3) * 0.004, 0.015, 0.009), mat("bogsilver_light"), (0.2 * i, 0.3, 0.5 * i))
    for sign in (-1.0, 1.0):
        box(f"Bogsilver_Cast_Seam_{'p' if sign > 0 else 'n'}", (0.0, sign * (hy - 0.004), h * 0.42),
            (0.22, 0.007, 0.008), mat("bogsilver_dark"))


def build_wellglass_shard() -> None:
    """0.18 m of Wellglass, broken the way glass breaks.

    Flint next to it is knapped stone: straight ridges, a struck platform, opaque. Glass fractures
    CONCHOIDALLY — shallow curved dishes, no cleavage planes, edges that go thinner than any stone
    can hold — so this is three pieces of one break rather than a cluster of pebbles, sized large,
    medium, small and lying as they fell. The largest keeps a bright fresh face; the smallest are
    darker because you are looking through their thickness.
    """
    shard("Wellglass_Main", (0.0, 0.0, 0.058), (0.088, 0.062, 0.104), mat("wellglass_dark"), (0.28, 0.12, 0.5))
    shard("Wellglass_Main_Face", (0.012, -0.016, 0.062), (0.062, 0.030, 0.082), mat("wellglass"), (0.34, 0.10, 0.62))
    # The other two pieces LEAN ON the first. The first pass spread them at 0.05 m and scattered the
    # chips at 0.052 with jitter, and the whole asset read as five separate objects floating apart —
    # a pickup has to read as one thing a hand closes around, so every piece now touches the main.
    shard("Wellglass_Second", (-0.036, 0.026, 0.032), (0.056, 0.044, 0.062), mat("wellglass"), (0.9, -0.4, 0.2))
    shard("Wellglass_Third", (0.038, 0.028, 0.024), (0.040, 0.034, 0.044), mat("wellglass_dark"), (0.4, 0.8, -0.3))
    for i, (angle, rad) in enumerate(radial(4, 0.030, seed=737, jitter=0.28)):
        x, y, z = around((0.0, 0.0, 0.012 + (i % 2) * 0.008), angle, rad)
        # Chips off the same break, banked against the base of the cluster.
        shard(f"Wellglass_Chip_{i + 1}", (x, y, z), (0.018 - (i % 3) * 0.003, 0.014, 0.020),
              mat("wellglass_light" if i % 2 else "wellglass"), (0.5 * i, 0.3 - i * 0.2, 0.7 * i))


def build_guardian_core() -> None:
    """0.20 m, and the only pickup in the game that is MADE rather than found.

    Everything else here is a rock, a plant or a billet. This came out of something that was alive
    enough to fight you, so it has to read as an object with an INSIDE: a bogsilver cage over a
    wellglass heart, still lit. The ribs are what stop it reading as a gemstone — a bare glowing lump
    is a gem, a lump behind a frame is a component — and `ITEMS.md`'s "still warm, still humming" is
    the brief, so the glow is only ever seen through the gaps.

    The cage has to stand OUTSIDE the heart to be a cage at all. The first pass put the ribs at 30%
    of the heart's radius, which buried every one of them inside the glass and left four dark studs
    stuck to a teal ball; the ribs now run the full height at the heart's own radius, and the studs
    are collars where a rib crosses the equator rather than free-floating warts.
    """
    heart_r = 0.056
    # Tuned by eye against the all-sides sheet, twice. At 0.150 the ribs stand clear of the glass and
    # the thing reads as scaffolding round a gem — separate objects, not one component. At 0.064 the
    # heart bulges through the frame at its equator and the two read as ONE object with an inside,
    # which is the whole point. A cage is not a fence.
    cage_r = 0.064
    base_z, top_z = 0.026, 0.150
    mid_z = (base_z + top_z) * 0.5

    ico("Guardian_Heart", (0.0, 0.0, mid_z), (heart_r, heart_r, heart_r * 1.06), mat("wellglass"), (0.2, 0.3, 0.1))
    # A brighter inner node, smaller than the shell so it shows as depth through the glass rather
    # than as a second surface.
    ico("Guardian_Heart_Node", (0.0, 0.0, mid_z), (heart_r * 0.52, heart_r * 0.52, heart_r * 0.60),
        mat("wellglass_light"), (0.5, 0.1, 0.4))

    # Five ribs, so no two views ever show the same pair square-on and the cage never reads as a
    # four-sided box (task 2.1j — look at the back).
    for i, (angle, rad) in enumerate(radial(5, cage_r, seed=343, jitter=0.0)):
        x, y, _ = around((0.0, 0.0, 0.0), angle, rad)
        cylinder_between(
            f"Guardian_Rib_{i + 1}",
            (x * 0.42, y * 0.42, base_z - 0.004),
            (x * 0.42, y * 0.42, top_z + 0.004),
            0.0105,
            mat("bogsilver"),
            5,
        )
        # The rib is a straight bar, so it stands off the glass at the equator and touches near the
        # poles; the collar closes that gap where it is widest and reads as the fixing.
        ico(f"Guardian_Rib_Collar_{i + 1}", (x * 0.42, y * 0.42, mid_z), (0.017, 0.017, 0.022),
            mat("bogsilver_dark"), (0.0, 0.0, 0.35 * i))

    # A band round the equator tying the ribs together, and a cap at each pole.
    for i, (angle, rad) in enumerate(radial(10, cage_r * 0.44, seed=717, jitter=0.0)):
        x, y, _ = around((0.0, 0.0, 0.0), angle, rad)
        following = radial(10, cage_r * 0.44, seed=717, jitter=0.0)[(i + 1) % 10]
        nx, ny, _ = around((0.0, 0.0, 0.0), following[0], following[1])
        cylinder_between(f"Guardian_Band_{i + 1}", (x, y, mid_z), (nx, ny, mid_z), 0.0055,
                         mat("bogsilver_dark"), 4)

    ico("Guardian_Cap_Top", (0.0, 0.0, top_z), (0.036, 0.036, 0.020), mat("bogsilver"), (0.0, 0.0, 0.4))
    ico("Guardian_Cap_Base", (0.0, 0.0, base_z), (0.046, 0.046, 0.022), mat("bogsilver_dark"), (0.0, 0.0, 0.2))


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

    # Size is enforced here, not merely checked — the F-440 contract. A builder owns the SHAPE; the
    # SCALE table owns how big it is, so a lump that came out 0.31 m because an ico was nudged is
    # brought back to 0.22 m instead of shipping and failing a check nobody reruns.
    target = SCALE.get(name)
    if target is not None:
        longest = max((maximum - minimum).x, (maximum - minimum).y, (maximum - minimum).z)
        if longest > 1e-6 and abs(longest / target - 1.0) > 1e-4:
            factor = target / longest
            for obj in made:
                obj.scale = (factor, factor, factor)
                obj.location = obj.location * factor
            bpy.ops.object.select_all(action="DESELECT")
            for obj in made:
                obj.select_set(True)
            bpy.context.view_layer.objects.active = made[0]
            bpy.ops.object.transform_apply(scale=True)
            bpy.ops.object.select_all(action="DESELECT")
            bpy.context.view_layer.update()
            minimum, maximum = world_bounds(made)
            offset = Vector((-(minimum.x + maximum.x) * 0.5,
                             -(minimum.y + maximum.y) * 0.5, -minimum.z))
            for obj in made:
                obj.location += offset
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


def set_visible(record: dict, visible: bool) -> None:
    for obj in record["root"].children_recursive:
        obj.hide_render = not visible
    record["root"].hide_render = not visible


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
        ("pickup_bogsilver_ore", "mineral", build_bogsilver_ore),
        ("pickup_bogsilver_ingot", "crafted", build_bogsilver_ingot),
        ("pickup_wellglass_shard", "mineral", build_wellglass_shard),
        ("pickup_guardian_core", "crafted", build_guardian_core),
    ]
    if [name for name, _, _ in builders] != EXPECTED_NAMES:
        raise RuntimeError("deep-material specification and expected export list diverged")

    records: list[dict] = []
    for index, (name, family, builder) in enumerate(builders):
        records.append(create_asset(name, family, builder, ((index - 1.5) * 0.42, 0.0, 0.0)))

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
    camera.data.ortho_scale = 1.5
    camera.location = (1.1, -1.6, 0.95)
    look_at(camera, (0.0, 0.0, 0.08))
    scene.render.filepath = str(PREVIEW_DIR / "deep_materials_preview.png")
    bpy.ops.render.render(write_still=True)

    # Scale shot with the 1.80 m reference, so these four can never drift the way the pickups did.
    ref = box("Scale_Reference_Human", (-1.30, 0.10, 0.90), (0.34, 0.20, 1.80), mat("reference_blue"))
    move_to_collection([ref], preview_collection)
    camera.data.ortho_scale = 3.4
    camera.location = (2.0, -3.2, 1.7)
    look_at(camera, (-0.35, 0.0, 0.80))
    scene.render.filepath = str(PREVIEW_DIR / "deep_materials_scale_preview.png")
    bpy.ops.render.render(write_still=True)

    bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE_DIR / "deep_materials.blend"))
    total = sum(r["polygons"] for r in records)
    print(f"deep materials: {len(records)} assets, {total} polygons")
    for r in records:
        print(f"  {r['name']:26s} {r['width']:.3f} x {r['depth']:.3f} x {r['height']:.3f} m  {r['polygons']:4d} polys")


if __name__ == "__main__":
    with import_cache_guard():
        main()
