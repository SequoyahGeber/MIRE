"""Render MIRE's inventory icons from the shipped GLBs (A-042a).

Run with:
  Blender --background --python tools/blender/render_item_icons.py

Every icon is a transparent 256x256 orthographic render of an asset that already
exists in `assets/`, so an icon can never drift from the model it stands for: the
source of truth is the GLB, and this script is a camera, not a second art pass.

Framing is measured, not guessed. Each asset's vertices are projected into camera
space, the script tries the icon upright and rolled 45 degrees, keeps whichever
packs the silhouette into a smaller square, and then centres and scales the camera
on the projected bounds. That is what lets a 1.9 m skewer and a 12 cm coin both
fill their slot without per-item hand tuning.
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path

import bpy
from mathutils import Matrix, Vector

sys.path.append(str(Path(__file__).resolve().parent))
from godot_import_lock import import_cache_guard  # noqa: E402


ROOT = Path(__file__).resolve().parents[2]
ICON_DIR = ROOT / "assets" / "icons"
EXPORT_DIR = ICON_DIR / "exports"
PREVIEW_DIR = ICON_DIR / "preview"

ICON_SIZE = 256
SHEET_COLUMNS = 6
MARGIN = 1.18

#: (icon id, source GLB relative to assets/). Order drives the contact sheet.
SOURCES: list[tuple[str, str]] = [
    ("log", "pickups/exports/pickup_log.glb"),
    ("branch", "pickups/exports/pickup_branch.glb"),
    ("fibre_bundle", "pickups/exports/pickup_fibre_bundle.glb"),
    ("stone", "pickups/exports/pickup_stone.glb"),
    ("flint", "pickups/exports/pickup_flint.glb"),
    ("coal", "pickups/exports/pickup_coal.glb"),
    ("iron_ore", "pickups/exports/pickup_iron_ore.glb"),
    ("iron_ingot", "pickups/exports/pickup_iron_ingot.glb"),
    # Tier 4/5 materials (F-473). Their own kit, same camera.
    ("bogsilver_ore", "deep_materials/exports/pickup_bogsilver_ore.glb"),
    ("bogsilver_ingot", "deep_materials/exports/pickup_bogsilver_ingot.glb"),
    ("wellglass_shard", "deep_materials/exports/pickup_wellglass_shard.glb"),
    ("guardian_core", "deep_materials/exports/pickup_guardian_core.glb"),
    ("salvage_fragment", "pickups/exports/pickup_salvage_fragment.glb"),
    ("berry", "pickups/exports/pickup_berry.glb"),
    ("mushroom", "pickups/exports/pickup_mushroom.glb"),
    ("apple", "pickups/exports/pickup_apple.glb"),
    ("raw_meat", "pickups/exports/pickup_raw_meat.glb"),
    ("coin", "pickups/exports/pickup_coin.glb"),
    ("coin_stack", "pickups/exports/pickup_coin_stack.glb"),
    ("coins", "loot/exports/loot_coin_pouch.glb"),
    ("wooden_axe", "tools_weapons/exports/wooden_axe_world.glb"),
    ("stone_axe", "tools_weapons/exports/stone_axe_world.glb"),
    ("wooden_pickaxe", "tools_weapons/exports/wooden_pickaxe_world.glb"),
    ("stone_pickaxe", "tools_weapons/exports/stone_pickaxe_world.glb"),
    ("iron_axe", "tools_weapons/exports/iron_axe_world.glb"),
    ("iron_pickaxe", "tools_weapons/exports/iron_pickaxe_world.glb"),
    ("bogsilver_axe", "tools_weapons/exports/bogsilver_axe_world.glb"),
    ("bogsilver_pickaxe", "tools_weapons/exports/bogsilver_pickaxe_world.glb"),
    ("wellglass_axe", "tools_weapons/exports/wellglass_axe_world.glb"),
    ("wellglass_pickaxe", "tools_weapons/exports/wellglass_pickaxe_world.glb"),
    ("cleaver", "tools_weapons/exports/cleaver_world.glb"),
    ("skewer", "tools_weapons/exports/skewer_world.glb"),
    ("short_bow", "tools_weapons/exports/short_bow_world.glb"),
    ("sling", "tools_weapons/exports/sling_world.glb"),
    ("longbow", "tools_weapons/exports/longbow_world.glb"),
    ("crossbow", "tools_weapons/exports/crossbow_world.glb"),
    ("arrow", "tools_weapons/exports/arrow_world.glb"),
    ("bolt", "tools_weapons/exports/bolt_world.glb"),
    ("repair_hammer", "tools_weapons/exports/repair_hammer_world.glb"),
    ("iron_sword", "tools_weapons/exports/iron_sword_world.glb"),
    # --- buildables (F-427) ---------------------------------------------------
    #
    # The build menu had thirteen empty icon slots, and these are rendered from
    # the SAME GLB the piece places, for the same reason every other icon here
    # is: an icon drawn separately is an icon that can quietly stop matching what
    # the button builds. Where a piece is a frame plus swinging leaves — the
    # door, both gates — the icon takes the FRAME, because the opening is what
    # the player is choosing and a closed leaf is a wall.
    ("build_wall", "construction/exports/wall_wood.glb"),
    ("build_door", "construction/exports/door_wood_frame.glb"),
    ("build_gate", "construction/exports/gate_double_frame.glb"),
    ("build_ladder", "construction/exports/ladder.glb"),
    ("build_ramp", "construction/exports/ramp.glb"),
    ("build_bridge", "construction/exports/bridge_straight.glb"),
    ("build_dock", "construction/exports/dock_straight.glb"),
    ("build_floor", "construction/exports/floor_wood.glb"),
    ("build_palisade", "construction/exports/palisade_straight.glb"),
    ("build_palisade_gate", "construction/exports/palisade_gate_frame.glb"),
    ("build_barricade", "construction/exports/barricade.glb"),
    ("build_barricade_spike", "construction/exports/barricade_spike.glb"),
    ("build_ward", "wards/exports/ward_healthy.glb"),
    ("build_ward_post", "wards/exports/ward_boundary_post.glb"),
    # --- crafting stations (F-477) --------------------------------------------
    #
    # F-477 made all eight stations buildable, which put eight more empty slots in
    # the build menu — the same gap F-427 closed for the construction kit, and
    # closed the same way: rendered from the exact GLB the piece places.
    ("build_workbench", "crafting_stations/exports/station_workbench_primitive.glb"),
    ("build_workbench_upgraded", "crafting_stations/exports/station_workbench_upgraded.glb"),
    ("build_campfire", "crafting_stations/exports/station_campfire.glb"),
    ("build_cooking_spit", "crafting_stations/exports/station_cooking_spit.glb"),
    ("build_furnace", "crafting_stations/exports/station_stone_furnace.glb"),
    ("build_anvil", "crafting_stations/exports/station_anvil.glb"),
    ("build_repair_bench", "crafting_stations/exports/station_repair_bench.glb"),
    ("build_woodcutting_block", "crafting_stations/exports/station_woodcutting_block.glb"),
]

#: Yaw applied before framing, for assets whose default face is not their best one.
AZIMUTH: dict[str, float] = {
    "wooden_axe": 20.0,
    "stone_axe": 20.0,
    "wooden_pickaxe": 12.0,
    "stone_pickaxe": 12.0,
    "iron_pickaxe": 12.0,
    "cleaver": 18.0,
    "short_bow": 8.0,
    "skewer": 24.0,
    "arrow": 24.0,
    "repair_hammer": 18.0,
    # Enough to catch the crossguard's depth without turning the blade edge-on: a
    # sword yawed much further is a line with a hilt.
    "iron_sword": 22.0,
    "log": 55.0,
    "branch": 55.0,
}
DEFAULT_AZIMUTH = 35.0
ELEVATION = 21.0

#: Camera roll in degrees, authored for icons whose measured framing picks the wrong one (F-073).
#:
#: `frame_icon` normally tries upright and rolled-45 and keeps whichever packs the silhouette into
#: the smaller square. That is right for 23 of the 25 icons and wrong for the two axes, which win
#: upright by under 1.1% (wooden 1.3622 m vs 1.3738 m; stone 1.3762 vs 1.3914) and so are the only
#: tools rendered on the vertical. Measured over all eleven tool icons, the silhouette's principal
#: axis sits at 33-45 degrees for every other design and at 67-68 degrees for these two — which, at
#: hotbar size, is what Sequoyah read as the axe facing the other way from everything else.
#:
#: An override rather than a tuned tie-break, because iron_pickaxe prefers the roll by only 0.54%:
#: any threshold wide enough to catch the axes flips the pickaxe too. Forcing the roll costs the axes
#: about 1% of their framing (~2 px in a 256 px slot) and rotates the image only — camera roll cannot
#: change which side of the model is being viewed, so the bit's bright bevel is untouched.
#:
#: NOT a mirror. Rendering the axes from behind (azimuth 20 -> 200) puts the long axis back at ~67
#: degrees AND hides the cutting bevel, so the axe reads as a wooden mallet. The roll is the whole fix.
ROLL_OVERRIDE_DEG: dict[str, float] = {
    "wooden_axe": 45.0,
    "stone_axe": 45.0,
    # F-427: every buildable is forced UPRIGHT. The roll contest exists to pack an
    # arbitrary prop's silhouette into a square, and for a loose object that is
    # the right question — nobody has an opinion about which way a flint lies.
    # Architecture is different: a wall, a dock and a ramp all have a known
    # up, and a wall tipped 45 degrees to save 3% of a 256 px slot reads as a wall
    # that has fallen over. Packing loses to legibility here.
    "build_wall": 0.0,
    "build_door": 0.0,
    "build_gate": 0.0,
    "build_ladder": 0.0,
    "build_ramp": 0.0,
    "build_bridge": 0.0,
    "build_dock": 0.0,
    "build_floor": 0.0,
    "build_palisade": 0.0,
    "build_palisade_gate": 0.0,
    "build_barricade": 0.0,
    "build_barricade_spike": 0.0,
    "build_ward": 0.0,
    "build_ward_post": 0.0,
    # F-477: stations are furniture, and furniture has a known up for the same
    # reason architecture does — a forge lying on its side is not a forge.
    "build_workbench": 0.0,
    "build_workbench_upgraded": 0.0,
    "build_campfire": 0.0,
    "build_cooking_spit": 0.0,
    "build_furnace": 0.0,
    "build_anvil": 0.0,
    "build_repair_bench": 0.0,
    "build_woodcutting_block": 0.0,
}


def clear_scene() -> None:
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for datablocks in (bpy.data.meshes, bpy.data.materials, bpy.data.cameras, bpy.data.lights, bpy.data.images):
        for block in list(datablocks):
            if block.users == 0 or datablocks is not bpy.data.images:
                datablocks.remove(block, do_unlink=True)


def build_rig() -> tuple[bpy.types.Scene, bpy.types.Object]:
    scene = bpy.context.scene
    # Cycles, not EEVEE. EEVEE resolves anti-aliasing on thin silhouettes — a
    # cleaver edge, a pick tip — a few samples differently from run to run, so the
    # icons were not reproducible. Cycles with a pinned seed is, and 24 renders at
    # 256px cost seconds.
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.seed = 0
    scene.cycles.use_animated_seed = False
    scene.cycles.samples = 256
    scene.cycles.use_denoising = False
    scene.cycles.use_adaptive_sampling = False
    scene.render.resolution_x = ICON_SIZE
    scene.render.resolution_y = ICON_SIZE
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    scene.render.film_transparent = True
    scene.view_settings.look = "AgX - Punchy"

    bpy.ops.object.light_add(type="SUN", location=(0.0, 0.0, 6.0))
    key = bpy.context.object
    key.name = "Icon_Key"
    key.data.energy = 3.4
    key.data.angle = math.radians(12)
    key.rotation_euler = (math.radians(52), 0.0, math.radians(-38))

    bpy.ops.object.light_add(type="AREA", location=(-4.0, -3.2, 2.4))
    fill = bpy.context.object
    fill.name = "Icon_Fill"
    fill.data.energy = 260
    fill.data.color = (0.55, 0.45, 0.85)
    fill.data.shape = "DISK"
    fill.data.size = 5.0
    fill.rotation_euler = (math.radians(74), 0.0, math.radians(-52))

    bpy.ops.object.light_add(type="AREA", location=(3.4, 2.8, 2.0))
    rim = bpy.context.object
    rim.name = "Icon_Rim"
    rim.data.energy = 190
    rim.data.color = (0.75, 0.86, 1.0)
    rim.data.shape = "DISK"
    rim.data.size = 4.0
    rim.rotation_euler = (math.radians(102), 0.0, math.radians(128))

    bpy.ops.object.camera_add(location=(0.0, -6.0, 0.0))
    camera = bpy.context.object
    camera.name = "Icon_Camera"
    camera.data.type = "ORTHO"
    scene.camera = camera
    return scene, camera


def import_glb(path: Path) -> list[bpy.types.Object]:
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=str(path))
    return [obj for obj in bpy.data.objects if obj not in before]


def mesh_points(objects: list[bpy.types.Object]) -> list[Vector]:
    bpy.context.view_layer.update()
    points: list[Vector] = []
    for obj in objects:
        if obj.type != "MESH":
            continue
        matrix = obj.matrix_world
        points.extend(matrix @ vertex.co for vertex in obj.data.vertices)
    return points


def projected_bounds(points: list[Vector], basis: Matrix, roll: float) -> tuple[float, float, float, float]:
    right = basis.col[0].to_3d()
    up = basis.col[1].to_3d()
    cosine, sine = math.cos(roll), math.sin(roll)
    xs: list[float] = []
    ys: list[float] = []
    for point in points:
        local_x = point.dot(right)
        local_y = point.dot(up)
        xs.append(local_x * cosine + local_y * sine)
        ys.append(-local_x * sine + local_y * cosine)
    return min(xs), max(xs), min(ys), max(ys)


def frame_icon(
    camera: bpy.types.Object, points: list[Vector], forced_roll: float | None = None
) -> tuple[float, float]:
    """Point the camera at the asset and choose upright or rolled 45 degrees.

    `forced_roll` (radians) skips the contest and uses that roll, for the icons in
    ROLL_OVERRIDE_DEG whose measured winner is not the readable one."""
    direction = Vector(
        (
            0.0,
            -math.cos(math.radians(ELEVATION)),
            math.sin(math.radians(ELEVATION)),
        )
    )
    # Quaternion mode throughout: setting `rotation_euler` on a quaternion-mode
    # object is silently ignored, which would leave the basis below reading the
    # previous icon's orientation and mis-centre every icon after the first.
    camera.rotation_mode = "QUATERNION"
    camera.rotation_quaternion = (-direction).to_track_quat("-Z", "Y")
    bpy.context.view_layer.update()
    basis = camera.matrix_world.to_3x3()

    candidates = (forced_roll,) if forced_roll is not None else (0.0, math.radians(45.0))
    best: tuple[float, float, tuple[float, float, float, float]] | None = None
    for roll in candidates:
        minimum_x, maximum_x, minimum_y, maximum_y = projected_bounds(points, basis, roll)
        extent = max(maximum_x - minimum_x, maximum_y - minimum_y)
        if best is None or extent < best[1]:
            best = (roll, extent, (minimum_x, maximum_x, minimum_y, maximum_y))
    roll, extent, (minimum_x, maximum_x, minimum_y, maximum_y) = best

    center_x = (minimum_x + maximum_x) * 0.5
    center_y = (minimum_y + maximum_y) * 0.5
    cosine, sine = math.cos(-roll), math.sin(-roll)
    unrolled_x = center_x * cosine + center_y * sine
    unrolled_y = -center_x * sine + center_y * cosine

    right = basis.col[0].to_3d()
    up = basis.col[1].to_3d()
    # `direction` points from the subject out to the camera, so the camera sits at
    # +direction and looks back along -direction.
    camera.location = direction * 6.0 + right * unrolled_x + up * unrolled_y
    camera.rotation_quaternion = (
        (-direction).to_track_quat("-Z", "Y") @ Matrix.Rotation(roll, 4, "Z").to_quaternion()
    )
    camera.data.ortho_scale = extent * MARGIN
    return math.degrees(roll), extent * MARGIN


def render_icon(scene: bpy.types.Scene, camera: bpy.types.Object, icon_id: str, source: Path) -> dict:
    objects = import_glb(source)
    yaw = math.radians(AZIMUTH.get(icon_id, DEFAULT_AZIMUTH))
    for obj in objects:
        if obj.parent is None:
            obj.rotation_mode = "XYZ"
            obj.rotation_euler.rotate(Matrix.Rotation(yaw, 4, "Z").to_euler())
    points = mesh_points(objects)
    if not points:
        raise RuntimeError(f"{source} imported with no mesh geometry")
    override = ROLL_OVERRIDE_DEG.get(icon_id)
    roll, ortho_scale = frame_icon(
        camera, points, math.radians(override) if override is not None else None
    )
    scene.render.filepath = str(EXPORT_DIR / f"icon_{icon_id}.png")
    bpy.ops.render.render(write_still=True)
    polygons = sum(len(obj.data.polygons) for obj in objects if obj.type == "MESH")

    bpy.ops.object.select_all(action="DESELECT")
    for obj in objects:
        obj.select_set(True)
    bpy.ops.object.delete(use_global=False)
    return {
        "id": icon_id,
        "source": f"assets/{source.relative_to(ROOT / 'assets')}".replace("\\", "/"),
        "size_px": ICON_SIZE,
        "azimuth_deg": round(math.degrees(yaw), 1),
        "elevation_deg": ELEVATION,
        "roll_deg": round(roll, 1),
        "ortho_scale_m": round(ortho_scale, 4),
        "source_polygons": polygons,
    }


def write_contact_sheet(records: list[dict]) -> Path:
    """Blit the rendered icons into one sheet over the Mire's UI background."""
    columns = SHEET_COLUMNS
    rows = (len(records) + columns - 1) // columns
    width = columns * ICON_SIZE
    height = rows * ICON_SIZE
    sheet = bpy.data.images.new("icon_contact_sheet", width=width, height=height, alpha=True)
    background = (0.055, 0.062, 0.085, 1.0)
    buffer = list(background) * (width * height)

    for index, record in enumerate(records):
        image = bpy.data.images.load(str(EXPORT_DIR / f"icon_{record['id']}.png"))
        pixels = list(image.pixels)
        column = index % columns
        # Blender images are bottom-up; fill rows from the top of the sheet.
        row = rows - 1 - index // columns
        for y in range(ICON_SIZE):
            source_offset = y * ICON_SIZE * 4
            target_offset = ((row * ICON_SIZE + y) * width + column * ICON_SIZE) * 4
            for x in range(ICON_SIZE):
                source_index = source_offset + x * 4
                alpha = pixels[source_index + 3]
                target_index = target_offset + x * 4
                for channel in range(3):
                    buffer[target_index + channel] = (
                        pixels[source_index + channel] * alpha + background[channel] * (1.0 - alpha)
                    )
                buffer[target_index + 3] = 1.0
        bpy.data.images.remove(image)

    sheet.pixels = buffer
    path = PREVIEW_DIR / "item_icons_sheet.png"
    sheet.filepath_raw = str(path)
    sheet.file_format = "PNG"
    sheet.save()
    return path


def main() -> None:
    EXPORT_DIR.mkdir(parents=True, exist_ok=True)
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    for icon_id, _ in SOURCES:
        (EXPORT_DIR / f"icon_{icon_id}.png").unlink(missing_ok=True)

    clear_scene()
    scene, camera = build_rig()

    seen: set[str] = set()
    records: list[dict] = []
    for icon_id, relative in SOURCES:
        if icon_id in seen:
            raise RuntimeError(f"duplicate icon id {icon_id}")
        seen.add(icon_id)
        source = ROOT / "assets" / relative
        if not source.exists():
            raise RuntimeError(f"missing source asset {source}")
        records.append(render_icon(scene, camera, icon_id, source))

    with (ICON_DIR / "catalog.json").open("w", encoding="utf-8") as handle:
        json.dump(records, handle, indent=2)
        handle.write("\n")

    sheet = write_contact_sheet(records)
    print(f"Rendered {len(records)} inventory icons at {ICON_SIZE}px into {EXPORT_DIR}")
    print(f"Contact sheet: {sheet}")


if __name__ == "__main__":
    with import_cache_guard(Path(__file__).name):
        main()
