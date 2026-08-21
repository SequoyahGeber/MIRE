"""Build MIRE's original low-poly environment and construction kit.

Run with:
  Blender --background --python tools/blender/build_mire_map_kit.py

Outputs 128 individual, metre-scale GLBs, an editable Blender source file,
a machine-readable catalog, and category preview renders. All variation is
seeded so repeated builds preserve geometry and naming.
"""

from __future__ import annotations

import json
import math
import sys
import random
from pathlib import Path
from typing import Callable

import bpy

sys.path.append(str(Path(__file__).resolve().parent))
from mire_art import mat, radial, around, reset_materials, hull, fork  # noqa: E402
from godot_import_lock import import_cache_guard  # noqa: E402
from mathutils import Quaternion, Vector


ROOT = Path(__file__).resolve().parents[2]
ASSET_DIR = ROOT / "assets" / "environment"
SOURCE_DIR = ROOT / "assets" / "source"
EXPORT_DIR = ASSET_DIR / "exports"
PREVIEW_DIR = ASSET_DIR / "preview"

CATEGORY_ORDER = ["trees", "rocks", "forest_debris", "ground_cover", "mire_growth", "ruins", "building_pieces"]
CATEGORY_PREVIEWS = {
    "trees": "trees_preview.png",
    "rocks": "rocks_preview.png",
    "forest_debris": "forest_debris_preview.png",
    "ground_cover": "ground_cover_preview.png",
    "mire_growth": "mire_growth_preview.png",
    "ruins": "ruins_preview.png",
    "building_pieces": "building_pieces_preview.png",
}
CATEGORY_TOTALS = {"trees": 18, "rocks": 18, "forest_debris": 12, "ground_cover": 28, "mire_growth": 16, "ruins": 12, "building_pieces": 24}


def assign(obj: bpy.types.Object, mat: bpy.types.Material) -> bpy.types.Object:
    obj.data.materials.append(mat)
    for polygon in obj.data.polygons:
        polygon.use_smooth = False
    return obj


def box(name: str, location: tuple[float, float, float], dimensions: tuple[float, float, float], mat: bpy.types.Material, rotation: tuple[float, float, float] = (0.0, 0.0, 0.0)) -> bpy.types.Object:
    bpy.ops.mesh.primitive_cube_add(location=location, rotation=rotation)
    obj = bpy.context.object
    obj.name = name
    obj.scale = (dimensions[0] * 0.5, dimensions[1] * 0.5, dimensions[2] * 0.5)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    return assign(obj, mat)


def cylinder(name: str, radius: float, depth: float, location: tuple[float, float, float], mat: bpy.types.Material, vertices: int = 8) -> bpy.types.Object:
    bpy.ops.mesh.primitive_cylinder_add(vertices=vertices, radius=radius, depth=depth, location=location)
    obj = bpy.context.object
    obj.name = name
    return assign(obj, mat)


def cone(name: str, radius_bottom: float, radius_top: float, depth: float, location: tuple[float, float, float], mat: bpy.types.Material, vertices: int = 8) -> bpy.types.Object:
    bpy.ops.mesh.primitive_cone_add(vertices=vertices, radius1=radius_bottom, radius2=radius_top, depth=depth, location=location)
    obj = bpy.context.object
    obj.name = name
    return assign(obj, mat)


def ico(name: str, location: tuple[float, float, float], scale: tuple[float, float, float], mat: bpy.types.Material, rotation: tuple[float, float, float] = (0.0, 0.0, 0.0)) -> bpy.types.Object:
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=1, radius=1.0, location=location, rotation=rotation)
    obj = bpy.context.object
    obj.name = name
    obj.scale = scale
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    return assign(obj, mat)


def cylinder_between(name: str, start: tuple[float, float, float], end: tuple[float, float, float], radius: float, mat: bpy.types.Material, vertices: int = 7) -> bpy.types.Object:
    a = Vector(start)
    b = Vector(end)
    direction = b - a
    obj = cylinder(name, radius, direction.length, tuple((a + b) * 0.5), mat, vertices)
    obj.rotation_mode = "QUATERNION"
    obj.rotation_quaternion = direction.to_track_quat("Z", "Y")
    return obj


def tapered_between(name: str, start: tuple[float, float, float], end: tuple[float, float, float], radius_start: float, radius_end: float, mat: bpy.types.Material, vertices: int = 7) -> bpy.types.Object:
    a = Vector(start)
    b = Vector(end)
    direction = b - a
    obj = cone(name, radius_start, radius_end, direction.length, tuple((a + b) * 0.5), mat, vertices)
    obj.rotation_mode = "QUATERNION"
    obj.rotation_quaternion = direction.to_track_quat("Z", "Y")
    return obj


def rolled_frustum(name: str, start: tuple[float, float, float], end: tuple[float, float, float], radius_start: float, radius_end: float, mat: bpy.types.Material, vertices: int = 7, roll: float = 0.0) -> bpy.types.Object:
    """`tapered_between` with control over the roll about the segment's own axis.

    F-396 ("the trunks look really bad"): a trunk built as a stack of frusta that
    all share the same roll is a smooth extruded polygon with a seam — every
    facet lines up with the one below it, so the whole column shades as one flat
    band and reads as a pipe. Rolling each segment by its own amount breaks the
    facets into plates that catch light separately, which is most of what makes a
    low-poly trunk read as bark at all. Costs nothing: same vertices, different
    rotation.
    """
    first, second = Vector(start), Vector(end)
    direction = second - first
    obj = cone(name, radius_start, radius_end, direction.length, tuple((first + second) * 0.5), mat, vertices)
    obj.rotation_mode = "QUATERNION"
    obj.rotation_quaternion = direction.to_track_quat("Z", "Y") @ Quaternion(Vector((0.0, 0.0, 1.0)), roll)
    return obj


def spine_point(points: list[Vector], fraction: float) -> Vector:
    """Point at `fraction` of the way up a trunk spine, interpolated between the
    two nearest control points. Branches want to leave the trunk WHERE THE TRUNK
    IS — anchoring them to the axis instead is why the old crooked tree had
    branches starting in mid-air on the lean side."""
    span = len(points) - 1
    position = max(0.0, min(1.0, fraction)) * span
    low = min(span - 1, int(position))
    return points[low].lerp(points[low + 1], position - low)


def join_by_material(name: str, made: list[bpy.types.Object]) -> list[bpy.types.Object]:
    """Collapse an asset to ONE mesh carrying one material slot per colour.

    F-396: `ResourceScatterField` builds one `MultiMeshInstance3D` per MESH PART
    (`_load_mesh_parts` -> the `slots` loop), so a pine that exports as 63 loose
    cones costs 63 nodes and 63 draw calls in every chunk it appears in — and
    F-395's scatter work is about to place all eighteen of these trees rather
    than the three willows the island had. Joining first takes that to one node
    per asset and as many draw calls as the tree has colours.

    Safe for the collider fit: `_collider_for`/`_cross_section_radius` walk mesh
    SURFACES and skip the foliage materials by name, so a joined tree still
    collides on its trunk only (F-390) — the surfaces are all still there, they
    just live on one mesh now.

    `build_flora_set.py` reached the same conclusion for the same reason
    (`_join_into_one`); this is the map kit's copy because the two kits
    deliberately do not share their geometry helpers (see `main`'s palette note).
    """
    meshes = [obj for obj in made if obj.type == "MESH"]
    if not meshes:
        raise RuntimeError(f"{name} produced no mesh objects")
    bpy.ops.object.select_all(action="DESELECT")
    for obj in meshes:
        obj.select_set(True)
    target = meshes[0]
    bpy.context.view_layer.objects.active = target
    if len(meshes) > 1:
        bpy.ops.object.join()
    # Bake the transform away. The join keeps whichever rotation the first
    # component happened to carry — every cone built by `tapered_between` has one
    # — and that rotation rides out on the glTF node, where Godot's local
    # `get_aabb()` then has to enclose a rotated box and answers too large. An
    # identity node transform removes the question, and makes the scatter's
    # per-instance maths trivial.
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    bpy.ops.object.select_all(action="DESELECT")
    target.name = name.title().replace("_", "")
    for polygon in target.data.polygons:
        polygon.use_smooth = False
    return [target]


def mesh_object(name: str, vertices: list[tuple[float, float, float]], faces: list[tuple[int, ...]], mat: bpy.types.Material) -> bpy.types.Object:
    mesh = bpy.data.meshes.new(f"{name}_Mesh")
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    return assign(obj, mat)


def roof_wedge(name: str, width: float, depth: float, rise: float, mat: bpy.types.Material) -> bpy.types.Object:
    vertices = [(-width / 2, -depth / 2, 0.0), (width / 2, -depth / 2, 0.0), (-width / 2, depth / 2, 0.0), (width / 2, depth / 2, 0.0), (-width / 2, depth / 2, rise), (width / 2, depth / 2, rise)]
    faces = [(0, 2, 3, 1), (2, 4, 5, 3), (0, 1, 5, 4), (0, 4, 2), (1, 3, 5)]
    return mesh_object(name, vertices, faces, mat)


def hip_roof(name: str, width: float, depth: float, rise: float, mat: bpy.types.Material) -> bpy.types.Object:
    vertices = [(-width / 2, -depth / 2, 0.0), (width / 2, -depth / 2, 0.0), (width / 2, depth / 2, 0.0), (-width / 2, depth / 2, 0.0), (0.0, 0.0, rise)]
    faces = [(0, 3, 2, 1), (0, 1, 4), (1, 2, 4), (2, 3, 4), (3, 0, 4)]
    return mesh_object(name, vertices, faces, mat)


def look_at(obj: bpy.types.Object, target: tuple[float, float, float]) -> None:
    obj.rotation_euler = (Vector(target) - obj.location).to_track_quat("-Z", "Y").to_euler()


def seed_for(name: str) -> int:
    return sum((index + 1) * ord(char) for index, char in enumerate(name))


def create_asset(name: str, category: str, build_fn: Callable[[], None], display_location: tuple[float, float, float], join: bool = False) -> dict:
    collection = bpy.data.collections.new(name)
    bpy.context.scene.collection.children.link(collection)
    root = bpy.data.objects.new(name, None)
    root.empty_display_type = "PLAIN_AXES"
    collection.objects.link(root)
    before_names = {obj.name for obj in bpy.data.objects}
    build_fn()
    made = sorted((obj for obj in bpy.data.objects if obj.name not in before_names), key=lambda obj: obj.name)
    if join:
        made = join_by_material(name, made)
    for obj in made:
        for old_collection in list(obj.users_collection):
            old_collection.objects.unlink(obj)
        collection.objects.link(obj)
        obj.parent = root
    bpy.context.view_layer.update()
    corners: list[Vector] = []
    for obj in made:
        if obj.type != "MESH":
            continue
        if join:
            # F-094: `obj.bound_box` is not refreshed after `bpy.ops.object.join()`
            # even through a depsgraph update, so a joined asset would measure as
            # whatever its first component happened to be — that is the bug that
            # put a willow in the catalog at 6.97 m. Vertices are never stale, and
            # after the join's `transform_apply` they are already world-space.
            corners.extend(obj.matrix_world @ vertex.co for vertex in obj.data.vertices)
        else:
            corners.extend(obj.matrix_world @ Vector(corner) for corner in obj.bound_box)
    minimum = Vector((min(v.x for v in corners), min(v.y for v in corners), min(v.z for v in corners)))
    maximum = Vector((max(v.x for v in corners), max(v.y for v in corners), max(v.z for v in corners)))
    dimensions = maximum - minimum
    polygon_count = sum(len(obj.data.polygons) for obj in made if obj.type == "MESH")
    materials = sorted({mat.name for obj in made if obj.type == "MESH" for mat in obj.data.materials if mat})
    bpy.ops.object.select_all(action="DESELECT")
    for obj in collection.objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = root
    bpy.ops.export_scene.gltf(filepath=str(EXPORT_DIR / f"{name}.glb"), export_format="GLB", use_selection=True, export_apply=True, export_yup=True)
    root.location = display_location
    return {"name": name, "category": category, "root": root, "width": dimensions.x, "depth": dimensions.y, "height": dimensions.z, "parts": sum(1 for obj in made if obj.type == "MESH"), "polygons": polygon_count, "materials": materials}


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

    # Shared palette. Geometry helpers stay local in this kit: its
    # cylinder_between defaults to 7 vertices and no end taper where
    # mire_art's uses 8 and 0.94, and swapping them would reshape all 128
    # assets — which are placed in both authored maps.
    mats = {
        "bark": mat("wood_bark"),
        "bark_light": mat("wood_bark_light"),
        # F-396: the trunks were one flat colour top to bottom, which is the other
        # half of why they read as pipes. `wood_bark_dark` was already in the
        # palette ("shadowed bark, trunk undersides") and used only by roofs.
        "bark_dark": mat("wood_bark_dark"),
        "cut": mat("wood_cut"),
        "birch": mat("wood_birch"),
        "birch_dark": mat("wood_birch_mark"),
        "pine_dark": mat("pine_dark"),
        "pine_mid": mat("pine"),
        "pine_tip": mat("pine_light"),
        "leaf": mat("leaf"),
        "leaf_light": mat("leaf_light"),
        "leaf_gold": mat("leaf_gold"),
        "stone": mat("stone"),
        "stone_light": mat("stone_light"),
        "stone_dark": mat("stone_dark"),
        "moss": mat("moss"),
        "grass": mat("grass"),
        "grass_light": mat("grass_light"),
        "grass_dark": mat("grass_dark"),
        "grass_dry": mat("grass_dry"),
        "seed_head": mat("grass_seed"),
        "reed": mat("reed"),
        "cattail": mat("wood_bark"),
        "mushroom": mat("fungus_cap"),
        "mushroom_blue": mat("fungus_blue"),
        "mushroom_spot": mat("flesh_fat"),
        "mire": mat("mire"),
        "mire_mid": mat("mire_light"),
        "crystal": mat("crystal"),
        "crystal_tip": mat("crystal_tip"),
        "ruin": mat("stone_ruin"),
        "rune": mat("mire_glow"),
        "wood_build": mat("wood_timber"),
        "wood_build_light": mat("wood_timber_light"),
        "roof": mat("wood_bark_dark"),
        "stone_build": mat("stone"),
        "ground": mat("preview_ground"),
    }

    # ── trees ─────────────────────────────────────────────────────────────────
    #
    # F-396. Every tree in the repo used to top out between 4.5 m and 7.4 m
    # against a 1.7 m player eye — 3.3x eye height at the median, where a real
    # forest tree reads at 6-15x — so the island looked like scrub and the canopy
    # never once broke the horizon. Reported from play twice ("tree assets should
    # be significantly taller", then "we didn't do anything about the trees being
    # way too short still") before the finding measured it.
    #
    # **Why the fix is here and not on a scatter def.** `ScatterEntry.min_scale`/
    # `max_scale` multiply the whole prop, so a 1.6x tree gets a 1.6x-thick trunk
    # and reads as the same tree seen from closer — bigger, not taller. Height has
    # to be built in, where the trunk radius is a separate number that grows far
    # slower than the height does (a 17 m pine here carries a ~0.5 m base radius
    # against the ~0.45 m the old 5.8 m one had). That ratio IS the read.
    #
    # **The trunks themselves** were called out separately — "the trunks look
    # really bad": two untapered cylinders in one flat colour, ending dead flat at
    # z=0, with branches that never joined anything. All four species now share
    # `tree_trunk()`, which gives them a continuous taper over 6-8 rolled
    # segments, a root flare with buttress roots running out of it, bark ridges,
    # and two bark tones so the facets catch light the way the canopy already did.
    #
    # **And the silhouettes stop being the same tree in three colours** ("some
    # diversity going, some variety"):
    #
    #   pine     tallest and narrowest — a spire of tiered skirts, no live branch
    #            below head height, crown width about a third of its height
    #   birch    slim pale trunk carried high and clean, small high crown, the
    #            most trunk visible of any of them
    #   bare     dead: the recursive branching IS the silhouette, wide and open,
    #            nothing to hide structure behind
    #   crooked  shortest, heaviest, leaning hard, one broad lopsided low crown
    #
    # Everything below is joined to a single mesh on export (`join_by_material`) —
    # see that function for the node-count reason.

    def tree_trunk(
        height: float,
        base_radius: float,
        tip_radius: float,
        lean: Vector,
        sway: float,
        segments: int,
        tone: tuple[bpy.types.Material, bpy.types.Material, bpy.types.Material],
        rng: random.Random,
        seed: int,
        vertices: int = 7,
        ridges: int = 3,
        flare: float = 1.9,
        flare_top: float = 0.44,
        roots: int = 5,
        root_reach: tuple[float, float] = (1.0, 1.7),
        taper_power: float = 1.35,
        roll_spread: float = math.pi,
    ) -> tuple[list[Vector], list[float]]:
        """The shared standing trunk of this kit's four trees (F-396).

        `tone` is (shadow, bark, lit) — three tones from the same wood, because
        one flat colour is what made the old trunks read as plastic pipe.

        Returns the spine points and the radius at each, so a caller can hang
        limbs on the trunk WHERE THE TRUNK IS rather than on the vertical axis.

        Three things here are load-bearing and easy to undo by accident:

        * **The taper is a curve, not a line.** `taper_power` > 1 sheds radius
          fast at the base and slowly near the top, which is the profile a trunk
          actually has; a linear taper is a traffic cone and looks like one.
        * **The flare stops at 0.44 m on purpose.** `ResourceScatterField.
          COLLIDER_TRUNK_BAND_MIN_M` is 0.5 m — F-390 lifted the collider's
          measuring band off the floor precisely because the flare, not the
          trunk, was setting the radius and holding the player a metre off the
          bark they were walking at. Keeping the flare under that line means a
          wide, well-planted base costs nothing in collision.
        * **The lean accumulates as t².** A trunk that leans linearly is a
          leaning pole — the base has to stay planted and the crown carry the
          offset, or the tree looks knocked over rather than grown crooked.
        """
        shadow, bark, lit = tone

        points = [Vector((0.0, 0.0, 0.0))]
        drift = Vector((0.0, 0.0, 0.0))
        for index in range(1, segments + 1):
            t = index / segments
            drift = drift + Vector((rng.uniform(-sway, sway), rng.uniform(-sway, sway), 0.0))
            points.append(lean * (t * t) + drift + Vector((0.0, 0.0, height * t)))
        radii = [
            tip_radius + (base_radius - tip_radius) * ((1.0 - index / segments) ** taper_power)
            for index in range(segments + 1)
        ]

        # Root flare, and the buttresses that ARCH out of it. A cylinder that stops
        # dead at z=0 is the single clearest tell that a tree was generated — but
        # the first pass over-corrected into the opposite tell: long thin roots
        # running straight from the flare to the ground read as a spider standing
        # on the tree. A real buttress is SHORT, THICK and mostly buried, so these
        # go up over a knee at flare height and dive back down inside about half a
        # metre past the flare.
        tapered_between("Flare", (0.0, 0.0, 0.0), (0.0, 0.0, flare_top),
                        base_radius * flare, base_radius * 1.06, shadow, 8)
        for index, (angle, rad) in enumerate(radial(roots, base_radius * 1.05, seed=seed + 311,
                                                    jitter=0.34, radius_jitter=0.20)):
            toe = rad + rng.uniform(*root_reach)
            knee = around((0.0, 0.0, flare_top * 0.62), angle, (rad + toe) * 0.48)
            tapered_between(
                f"Root_{index + 1}_A",
                around((0.0, 0.0, flare_top * 0.95), angle, rad * 0.45), knee,
                base_radius * 0.54, base_radius * 0.36, bark if index % 2 else lit, 5,
            )
            tapered_between(
                f"Root_{index + 1}_B", knee, around((0.0, 0.0, 0.02), angle, toe),
                base_radius * 0.36, base_radius * 0.11, bark if index % 2 else lit, 5,
            )

        # The column. Each segment rolls by its own amount (see `rolled_frustum`),
        # `roll_spread` controlling how much — full freedom on rough bark, nearly
        # none on a smooth pale birch, where visible facet twist at every joint
        # turns the trunk into a bamboo pole.
        #
        # ONE tone for the whole column, and the foot in shadow. Two earlier
        # passes varied the tone per segment — first seeded, then by height — and
        # both read as painted rings, because a trunk's segment boundaries are
        # horizontal, so anything that varies per segment varies horizontally,
        # which is the one direction bark never does. The second tone earns its
        # keep on the RIDGES below and on the flare, where it runs vertically or
        # sits where a shadow genuinely would.
        for index in range(segments):
            material = shadow if index == 0 else bark
            rolled_frustum(f"Trunk_{index + 1}", tuple(points[index]), tuple(points[index + 1]),
                           radii[index], radii[index + 1], material, vertices,
                           roll=rng.uniform(-roll_spread, roll_spread))

        # Bark ridges: slivers of the shadow tone laid up the trunk. Thirty
        # triangles, and the difference between a cone and something with grain.
        for index, (angle, _rad) in enumerate(radial(ridges, 1.0, seed=seed + 313, jitter=0.55)):
            stop = max(2, min(segments, int(segments * rng.uniform(0.40, 0.80))))
            tapered_between(
                f"Bark_Ridge_{index + 1}",
                around(tuple(points[0] + Vector((0.0, 0.0, flare_top * 0.45))), angle, radii[0] * 0.86),
                around(tuple(points[stop]), angle, radii[stop] * 0.78),
                base_radius * 0.26, base_radius * 0.07, shadow, 4,
            )
        return points, radii

    def tree_limb(name: str, start: Vector, heading: Vector, length: float, radius: float,
                  material: bpy.types.Material, rng: random.Random, segments: int = 3,
                  rise: float = 0.55, shrink: float = 0.62, vertices: int = 5) -> Vector:
        """One limb, in a few tapering segments that bend as they go; returns the
        tip so the caller can hang a crown mass on it.

        A limb built as one straight cone is a stick, and a crown hung off sticks
        is what made the old birch read as lollipops on wires. Three segments with
        accumulated curve costs 14 more triangles and reads as wood."""
        point = Vector(start)
        direction = Vector(heading).normalized()
        current = radius
        for index in range(segments):
            direction = (direction + Vector((rng.uniform(-0.24, 0.24), rng.uniform(-0.24, 0.24),
                                             rise / segments))).normalized()
            nxt = point + direction * (length / segments)
            tapered_between(f"{name}_{index + 1}", tuple(point), tuple(nxt),
                            current, current * shrink, material, vertices)
            current *= shrink
            point = nxt
        return point

    def build_pine(seed: int) -> None:
        """The tall one: 15-20 m, and deliberately the narrowest thing in the kit.

        Conifer mass is stacked skirts rather than an ellipsoid per branch. Eight
        cones read as a conifer from sixty metres where twenty-four ellipsoids
        read as a green cloud, and they cost a quarter of the triangles — which
        matters now that F-395's scatter work places all eighteen of these instead
        of three willows, out to F-369's 160 m visual band.
        """
        rng = random.Random(seed)
        height = rng.uniform(15.0, 20.5)
        base_radius = 0.30 + height * 0.0110
        lean = Vector((rng.uniform(-0.60, 0.60), rng.uniform(-0.50, 0.50), 0.0))
        points, _radii = tree_trunk(
            height * 0.97, base_radius, 0.075, lean, height * 0.011, 7,
            (mats["bark_dark"], mats["bark"], mats["bark_light"]), rng, seed,
            vertices=7, ridges=3, flare=1.95, roots=5, root_reach=(0.75, 1.30),
        )

        needles = (mats["pine_dark"], mats["pine_mid"], mats["pine_tip"])
        # Lowest live branch well above head height: a conifer whose skirts start
        # at your knees is a bush, and it is also what hid the trunk entirely.
        crown_start = 0.32 + rng.uniform(-0.03, 0.07)
        tiers = 8 + (seed % 3)
        widest = height * 0.150
        for tier in range(tiers):
            t = tier / (tiers - 1)
            centre = spine_point(points, crown_start + (0.94 - crown_start) * t)
            spread = (1.0 - t) ** 0.80
            radius = widest * (0.22 + 0.78 * spread) * rng.uniform(0.90, 1.10)
            depth = height * 0.075 * (0.55 + 0.70 * spread)
            skirt = cone(f"Skirt_{tier + 1}", radius, radius * 0.17, depth,
                         tuple(centre + Vector((0.0, 0.0, depth * 0.20))),
                         needles[min(2, (tier * 3) // tiers)], 8)
            skirt.rotation_euler = (rng.uniform(-0.08, 0.08), rng.uniform(-0.08, 0.08),
                                    tier * 0.79 + rng.uniform(-0.22, 0.22))
            # Every other tier grows a real branch past the skirt edge with a
            # needle SPRAY on the end, so the silhouette is ragged rather than a
            # stack of clean circles.
            #
            # The spray has to be flat and it has to overlap the skirt: the first
            # pass hung a near-spherical tuft at the branch tip and it read as a
            # green boulder orbiting the tree, because a mass that touches nothing
            # is a separate object however close it sits. Wide, thin, and anchored
            # back at 0.72 of the branch fixes both.
            if tier % 2 == 0 and t < 0.86:
                for index, (angle, rad) in enumerate(radial(3, radius * 0.45, seed=seed + tier * 29,
                                                            jitter=0.4, radius_jitter=0.2)):
                    tip = tree_limb(
                        f"Branch_{tier + 1}_{index + 1}", centre,
                        Vector((math.cos(angle), math.sin(angle), -0.16)),
                        radius * rng.uniform(0.95, 1.20), base_radius * 0.22,
                        mats["bark_dark"], rng, segments=2, rise=-0.10, shrink=0.55, vertices=4,
                    )
                    spray = hull(f"Needle_Spray_{tier + 1}_{index + 1}",
                                 tuple(centre.lerp(tip, 0.72)),
                                 (radius * 0.52, radius * 0.30, depth * 0.20),
                                 needles[min(2, (tier * 3) // tiers)], seed + tier * 13 + index,
                                 subdivisions=0, lumps=3, lump=0.44, sharpness=2.0)
                    spray.rotation_euler = (0.0, rng.uniform(-0.18, 0.05), angle)
        cone("Leader", widest * 0.30, 0.02, height * 0.13,
             tuple(spine_point(points, 0.955) + Vector((0.0, 0.0, height * 0.055))),
             mats["pine_tip"], 7)

    def build_bare(seed: int) -> None:
        """Dead, 12-17 m, and the one tree with nowhere to hide: with no leaves,
        the branch structure IS the silhouette.

        So it is the one that gets real recursion (`mire_art.fork`) instead of
        "six branches, each with two twigs" — a fixed two-level shape that looks
        like a fixed two-level shape from any distance. Two or three leaders come
        out of the crotch and each one branches three levels down."""
        rng = random.Random(seed)
        height = rng.uniform(12.0, 17.0)
        base_radius = 0.30 + height * 0.0145
        lean = Vector((rng.uniform(-0.85, 0.85), rng.uniform(-0.70, 0.70), 0.0))
        crotch_fraction = rng.uniform(0.40, 0.52)
        points, radii = tree_trunk(
            height * crotch_fraction, base_radius, base_radius * 0.52, lean * crotch_fraction,
            height * 0.014, 5, (mats["bark_dark"], mats["bark"], mats["bark_light"]), rng, seed,
            vertices=7, ridges=4, flare=2.05, roots=6, root_reach=(0.85, 1.45), taper_power=1.15,
        )

        crotch = points[-1]
        leaders = 2 + (seed % 2)
        remaining = height * (1.0 - crotch_fraction)
        for index, (angle, _rad) in enumerate(radial(leaders, 1.0, seed=seed + 401, jitter=0.42)):
            tilt = rng.uniform(0.28, 0.52)
            fork(
                f"Limb_{index + 1}", tuple(crotch),
                (math.cos(angle) * math.sin(tilt), math.sin(angle) * math.sin(tilt), math.cos(tilt)),
                remaining * rng.uniform(0.42, 0.56), radii[-1] * rng.uniform(0.72, 0.94),
                mats["bark"], seed + index * 97, depth=3, splits=(2, 2), spread=0.52,
                shrink=0.64, curve=0.20, vertices=5, tip_material=mats["bark_light"],
            )
        # A dead tree is a fungus habitat, and it is the cheapest way to say the
        # trunk has been standing dead for years rather than being an unfinished
        # asset. Two shelves, one flat mass each.
        #
        # `wood_cut` and not `fungus_cap`: the palette's toadstool pink is a
        # deliberate mire-growth signal colour, and on a trunk at 40 m it reads as
        # two magenta pixels stuck to the bark — it looked like a rendering bug in
        # the first kit render. A bracket fungus is pale dead wood, which is what
        # `wood_cut` already is.
        for index, (angle, rad) in enumerate(radial(2, base_radius * 0.95, seed=seed + 409, jitter=0.6)):
            shelf_z = height * rng.uniform(0.14, 0.34)
            hull(f"Bracket_{index + 1}",
                 around(tuple(spine_point(points, shelf_z / (height * crotch_fraction))), angle, rad),
                 (base_radius * 0.70, base_radius * 0.62, base_radius * 0.16),
                 mats["cut"], seed + 411 + index, subdivisions=0, lumps=3, lump=0.40,
                 flat_base=0.5)

    def build_birch(seed: int) -> None:
        """13-18 m of slim pale trunk with the crown held high and clean.

        The birch is the kit's contrast tree: it is the only pale trunk, so it is
        the one asset where showing MORE trunk is the point. Nothing branches
        below 58% of its height, and its crown is deliberately the smallest
        relative to its height of the four."""
        rng = random.Random(seed)
        height = rng.uniform(12.5, 16.5)
        base_radius = 0.20 + height * 0.0088
        lean = Vector((rng.uniform(-0.70, 0.70), rng.uniform(-0.40, 0.40), 0.0))
        points, radii = tree_trunk(
            height, base_radius, 0.055, lean, height * 0.010, 8,
            # Birch inverts the usual tone order: the trunk is the pale one and
            # `wood_birch_mark` is the scar. Which makes the bark ridges the
            # lenticel bands, at no extra cost — the right answer for this species
            # happens to be the same geometry as everyone else's.
            (mats["birch_dark"], mats["birch"], mats["birch"]), rng, seed,
            vertices=7, ridges=4, flare=1.75, roots=5, root_reach=(0.55, 0.95), taper_power=1.55,
            # Birch bark is smooth. A big per-segment roll on a slim pale trunk
            # makes every joint a visible twist and the tree reads as bamboo.
            roll_spread=0.18,
        )
        # Three scars, not six. Six evenly spaced discs down a pale trunk read as
        # a measuring stick — the regularity is the tell, and birch lenticels are
        # not regular. Wide gaps, mixed sizes.
        for index, fraction in enumerate((0.13, 0.29, 0.47)):
            centre = spine_point(points, fraction + rng.uniform(-0.03, 0.03))
            band = cylinder(f"Bark_Mark_{index + 1}",
                            base_radius * rng.uniform(0.94, 1.12) * (1.0 - fraction * 0.5),
                            0.045 + rng.uniform(0.0, 0.055),
                            tuple(centre), mats["birch_dark"], 7)
            band.rotation_euler = (rng.uniform(-0.05, 0.05), rng.uniform(-0.05, 0.05), rng.random())

        # Crown: one dense mass in the top third, not a ladder of blobs up the
        # whole trunk. A birch's read is a long clean bole and then all the leaves
        # at once; the first pass spread five small masses from 58% upward and got
        # lollipops on wires instead.
        # The standing world baseline is summer-green. Seasonal gold belongs in an explicit
        # biome/season variant; isolated orange crown facets read as missing materials in play.
        leaf_palette = (mats["leaf"], mats["leaf_light"], mats["leaf"], mats["leaf_light"])
        crown_radius = height * 0.175
        for index, (angle, rad) in enumerate(radial(7, crown_radius * 0.50, seed=seed + 503,
                                                    jitter=0.34, radius_jitter=0.30)):
            fraction = 0.66 + (index % 4) * 0.075
            anchor = spine_point(points, fraction)
            tip = tree_limb(
                f"Branch_{index + 1}", anchor,
                Vector((math.cos(angle), math.sin(angle), 0.85)),
                crown_radius * rng.uniform(0.42, 0.68),
                radii[min(len(radii) - 1, int(fraction * 8))] * 0.62,
                mats["birch"], rng, segments=2, rise=0.95, shrink=0.62, vertices=4,
            )
            hull(f"Crown_{index + 1}", tuple(tip),
                 (crown_radius * rng.uniform(0.50, 0.70), crown_radius * rng.uniform(0.46, 0.64),
                  crown_radius * rng.uniform(0.38, 0.54)),
                 leaf_palette[(seed + index) % 4], seed + index * 37,
                 subdivisions=0, lumps=4, lump=0.38, sharpness=2.2, droop=0.26, droop_lobes=2)
        hull("Crown_Top", tuple(points[-1] + Vector((0.0, 0.0, crown_radius * 0.18))),
             (crown_radius * 0.78, crown_radius * 0.72, crown_radius * 0.62),
             mats["leaf_light"], seed + 521, subdivisions=0, lumps=4, lump=0.34, taper=0.28,
             droop=0.30, droop_lobes=3)

    def build_crooked(seed: int) -> None:
        """The short heavy one: 9.5-13.5 m, leaning hard, with one broad lopsided
        crown sitting low.

        Deliberately the opposite end of the range from the pine — this is the
        tree that reads as an obstacle and a landmark rather than as canopy, and
        it is the only one whose crown is wider than it is tall."""
        rng = random.Random(seed)
        height = rng.uniform(9.5, 13.5)
        base_radius = 0.32 + height * 0.0180
        # A big deliberate lean plus heavy sway: this is the one tree allowed to
        # look like it grew around something.
        lean = Vector((rng.uniform(-1.7, 1.7), rng.uniform(-1.4, 1.4), 0.0))
        points, radii = tree_trunk(
            height * 0.80, base_radius, base_radius * 0.34, lean, height * 0.028, 6,
            (mats["bark_dark"], mats["bark"], mats["bark_light"]), rng, seed,
            vertices=6, ridges=4, flare=2.15, flare_top=0.48, roots=6, root_reach=(0.95, 1.65),
            taper_power=1.05,
        )

        # Keep crown variation within the standing summer-green palette. Seasonal gold can return
        # through an explicit variant where a whole tree/biome supports the read.
        leaf_palette = (mats["leaf"], mats["leaf_light"], mats["leaf"], mats["leaf_light"],
                        mats["leaf"])
        crown_radius = height * 0.26
        # One lopsided crown, offset toward the lean, built from four overlapping
        # masses rather than one ball — the offset is what makes it read as a tree
        # that has been reaching for light for a century.
        bias = Vector((lean.x, lean.y, 0.0)) * 0.55
        for index, (angle, rad) in enumerate(radial(4, crown_radius * 0.62, seed=seed + 601,
                                                    jitter=0.4, radius_jitter=0.28)):
            anchor = spine_point(points, 0.62 + 0.11 * (index % 3))
            tip = tree_limb(
                f"Branch_{index + 1}", anchor,
                Vector((math.cos(angle), math.sin(angle), 0.45)),
                crown_radius * rng.uniform(0.55, 0.85),
                radii[min(len(radii) - 1, 3 + index % 2)] * 0.62,
                mats["bark_light"], rng, segments=3, rise=0.60, shrink=0.66, vertices=5,
            )
            hull(f"Crown_{index + 1}", tuple(tip + bias * 0.35),
                 (crown_radius * rng.uniform(0.58, 0.80), crown_radius * rng.uniform(0.52, 0.74),
                  crown_radius * rng.uniform(0.36, 0.52)),
                 leaf_palette[(seed + index) % 5], seed + index * 43,
                 subdivisions=0, lumps=4, lump=0.40, sharpness=2.0, droop=0.42, droop_lobes=3)
        hull("Crown_Core", tuple(points[-1] + bias + Vector((0.0, 0.0, crown_radius * 0.30))),
             (crown_radius * 0.86, crown_radius * 0.78, crown_radius * 0.50),
             mats["leaf"], seed + 617, subdivisions=1, lumps=5, lump=0.34, taper=0.22,
             droop=0.50, droop_lobes=4)
        for index, (angle, rad) in enumerate(radial(2, base_radius * 1.05, seed=seed + 619, jitter=0.7)):
            hull(f"Moss_{index + 1}",
                 around(tuple(spine_point(points, rng.uniform(0.10, 0.30))), angle, rad * 0.92),
                 (base_radius * 0.62, base_radius * 0.30, base_radius * 0.58),
                 mats["moss"], seed + 623 + index, subdivisions=0, lumps=3, lump=0.44)

    def build_boulder(seed: int) -> None:
        rng = random.Random(seed); sx, sy, sz = rng.uniform(0.9, 1.8), rng.uniform(0.75, 1.5), rng.uniform(0.65, 1.4)
        ico("Boulder", (0, 0, sz * 0.72), (sx, sy, sz), mats["stone"], (rng.uniform(-0.4, 0.4), rng.uniform(-0.4, 0.4), rng.uniform(0, math.tau)))
        if seed % 2 == 0: ico("Face", (-sx * 0.25, -sy * 0.55, sz * 0.85), (sx * 0.35, sy * 0.16, sz * 0.24), mats["stone_light"], (rng.random(), rng.random(), rng.random()))
        if seed % 3 == 0: ico("Moss", (sx * 0.12, -sy * 0.42, sz * 1.36), (sx * 0.48, sy * 0.16, 0.09), mats["moss"])

    def build_rock_cluster(seed: int) -> None:
        rng = random.Random(seed)
        for index in range(rng.randint(3, 6)):
            size = rng.uniform(0.32, 0.82); angle = rng.uniform(0, math.tau); distance = rng.uniform(0.05, 0.85)
            ico(f"Rock_{index + 1}", (math.cos(angle) * distance, math.sin(angle) * distance, size * 0.65), (size * rng.uniform(0.8, 1.25), size * rng.uniform(0.7, 1.1), size), mats["stone_light"] if index % 3 == 1 else mats["stone"], (rng.random(), rng.random(), rng.random()))

    def build_standing_stone(seed: int) -> None:
        rng = random.Random(seed); height = rng.uniform(2.1, 3.8)
        cone("Monolith", rng.uniform(0.62, 0.95), rng.uniform(0.28, 0.50), height, (0, 0, height * 0.5), mats["stone_dark"], rng.randint(5, 7))
        box("Rune", (0, -0.64, height * 0.57), (0.12, 0.035, height * 0.35), mats["rune"], (0, 0, rng.uniform(-0.35, 0.35)))
        for index in range(rng.randint(2, 4)):
            size = rng.uniform(0.20, 0.38); ico(f"Foot_Rock_{index + 1}", (rng.uniform(-0.75, 0.75), rng.uniform(-0.55, 0.55), size * 0.5), (size, size * 0.8, size * 0.65), mats["stone"])

    def build_stump(seed: int) -> None:
        rng = random.Random(seed); height = rng.uniform(0.65, 1.35); radius = rng.uniform(0.38, 0.67)
        cone("Stump", radius, radius * rng.uniform(0.72, 0.88), height, (0, 0, height * 0.5), mats["bark"], rng.randint(7, 10)); cylinder("Cut", radius * 0.78, 0.035, (0, 0, height + 0.015), mats["cut"], 9)
        for index in range(rng.randint(3, 5)):
            angle = index / 4 * math.tau + rng.uniform(-0.4, 0.4); cylinder_between(f"Root_{index + 1}", (math.cos(angle) * radius * 0.2, math.sin(angle) * radius * 0.2, 0.20), (math.cos(angle) * rng.uniform(0.7, 1.2), math.sin(angle) * rng.uniform(0.7, 1.2), 0.05), rng.uniform(0.09, 0.16), mats["bark"], 7)

    def build_fallen_log(seed: int) -> None:
        """A log that reads from any angle.

        The old one put every branch at y=0 on the TOP of the trunk with its tip
        at +x/+z, so all of them left the same face pointing the same way, and
        the moss was a single flattened ellipsoid stuck on one flank. From the
        far side it was a bare tube. Branches now leave at angles spread around
        the trunk axis and point outward along their own radial direction; moss
        sits in several patches at different angles; both ends are cut.
        """
        rng = random.Random(seed)
        length = rng.uniform(2.6, 4.5)
        radius = rng.uniform(0.28, 0.48)
        tip_radius = radius * rng.uniform(0.78, 0.90)
        half = length * 0.5
        sag = rng.uniform(-0.22, 0.22)
        tapered_between("Log", (-half, 0.0, radius), (half, sag, tip_radius * 1.02),
                        radius, tip_radius, mats["bark"], rng.randint(7, 10))
        cylinder_between("Cut_A", (-half - 0.012, 0.0, radius), (-half, 0.0, radius),
                         radius * 0.88, mats["cut"], 9)
        cylinder_between("Cut_B", (half, sag, tip_radius * 1.02), (half + 0.012, sag, tip_radius * 1.02),
                         tip_radius * 0.88, mats["cut"], 9)

        count = rng.randint(3, 5)
        for index, (angle, rad) in enumerate(radial(count, radius, seed=seed + 601, jitter=0.34, phase=0.45)):
            angle = angle * 0.72 + 0.30  # bias off the underside; a downward branch lifts the log
            x = rng.uniform(-length * 0.34, length * 0.36)
            reach = rng.uniform(0.34, 0.78)
            base = around((x, 0.0, radius), angle, rad * 0.82, axis="x")
            tip = around((x + rng.uniform(-0.22, 0.30), 0.0, radius), angle, rad + reach, axis="x")
            tapered_between(f"Branch_{index + 1}", base, tip, 0.085, 0.035, mats["bark"], 6)
            if rng.random() < 0.55:
                stub = around((x + rng.uniform(-0.10, 0.10), 0.0, radius), angle + rng.uniform(-0.5, 0.5),
                              rad + rng.uniform(0.10, 0.22), axis="x")
                tapered_between(f"Twig_{index + 1}", base, stub, 0.05, 0.022, mats["bark_light"], 5)

        for index, (angle, rad) in enumerate(radial(rng.randint(2, 4), radius * 0.96,
                                                    seed=seed + 977, jitter=0.46)):
            centre = around((rng.uniform(-half * 0.7, half * 0.7), 0.0, radius), angle, rad, axis="x")
            patch = ico(f"Moss_{index + 1}", centre,
                        (rng.uniform(0.22, 0.46), rng.uniform(0.16, 0.30), 0.055),
                        mats["moss"])
            patch.rotation_euler = (angle, 0.0, rng.uniform(-0.4, 0.4))

    def build_root_cluster(seed: int) -> None:
        rng = random.Random(seed); ico("Root_Knot", (0, 0, 0.28), (0.52, 0.44, 0.38), mats["bark"], (rng.random(), rng.random(), rng.random())); count = rng.randint(5, 8)
        for index in range(count):
            angle = index / count * math.tau + rng.uniform(-0.2, 0.2); length = rng.uniform(0.8, 1.65); start = (math.cos(angle) * 0.18, math.sin(angle) * 0.18, 0.24); middle = (math.cos(angle) * length * 0.55, math.sin(angle) * length * 0.55, rng.uniform(0.10, 0.26)); end = (math.cos(angle) * length, math.sin(angle) * length, 0.035)
            cylinder_between(f"Root_{index + 1}_A", start, middle, rng.uniform(0.09, 0.16), mats["bark"], 6); cylinder_between(f"Root_{index + 1}_B", middle, end, rng.uniform(0.045, 0.09), mats["bark"], 6)

    def grass_cluster(name: str, rng: random.Random, count: int, radius: float,
                      height_range: tuple[float, float], width_range: tuple[float, float],
                      palette: list[bpy.types.Material], lean_range: tuple[float, float]) -> None:
        """Build full, bent grass from a few combined meshes instead of sparse cone spikes."""
        vertices_by_material: list[list[tuple[float, float, float]]] = [[] for _ in palette]
        faces_by_material: list[list[tuple[int, ...]]] = [[] for _ in palette]
        for index in range(count):
            material_index = index % len(palette)
            vertices = vertices_by_material[material_index]
            faces = faces_by_material[material_index]
            distance = radius * (rng.random() ** 0.62)
            position_angle = rng.uniform(0.0, math.tau)
            cx = math.cos(position_angle) * distance
            cy = math.sin(position_angle) * distance
            blade_angle = position_angle + rng.uniform(-1.15, 1.15)
            width = rng.uniform(*width_range)
            height = rng.uniform(*height_range)
            thickness = max(0.012, width * 0.18)
            lean_angle = blade_angle + rng.uniform(-0.7, 0.7)
            lean = height * rng.uniform(*lean_range)
            lean_x = math.cos(lean_angle) * lean
            lean_y = math.sin(lean_angle) * lean
            ux, uy = math.cos(blade_angle) * width * 0.5, math.sin(blade_angle) * width * 0.5
            vx, vy = -math.sin(blade_angle) * thickness * 0.5, math.cos(blade_angle) * thickness * 0.5
            middle = (cx + lean_x * 0.42, cy + lean_y * 0.42, height * 0.58)
            tip = (cx + lean_x, cy + lean_y, height)
            base = len(vertices)
            vertices.extend([
                (cx - ux - vx, cy - uy - vy, 0.015),
                (cx + ux - vx, cy + uy - vy, 0.015),
                (cx - ux + vx, cy - uy + vy, 0.015),
                (cx + ux + vx, cy + uy + vy, 0.015),
                (middle[0] - ux * 0.72 - vx, middle[1] - uy * 0.72 - vy, middle[2]),
                (middle[0] + ux * 0.72 - vx, middle[1] + uy * 0.72 - vy, middle[2]),
                (middle[0] - ux * 0.72 + vx, middle[1] - uy * 0.72 + vy, middle[2]),
                (middle[0] + ux * 0.72 + vx, middle[1] + uy * 0.72 + vy, middle[2]),
                tip,
            ])
            faces.extend([
                (base, base + 1, base + 3, base + 2),
                (base, base + 4, base + 5, base + 1),
                (base + 2, base + 3, base + 7, base + 6),
                (base, base + 2, base + 6, base + 4),
                (base + 1, base + 5, base + 7, base + 3),
                (base + 4, base + 6, base + 8),
                (base + 6, base + 7, base + 8),
                (base + 7, base + 5, base + 8),
                (base + 5, base + 4, base + 8),
            ])
        for material_index, grass_material in enumerate(palette):
            if vertices_by_material[material_index]:
                mesh_object(
                    f"{name}_{material_index + 1}",
                    vertices_by_material[material_index],
                    faces_by_material[material_index],
                    grass_material,
                )

    def build_grass(seed: int) -> None:
        rng = random.Random(seed)
        grass_cluster(
            "Grass", rng, rng.randint(24, 32), 0.78, (0.34, 0.72), (0.05, 0.105),
            [mats["grass_dark"], mats["grass"], mats["grass"], mats["grass_light"]], (0.06, 0.22),
        )

    def build_grass_meadow(seed: int) -> None:
        rng = random.Random(seed)
        grass_cluster(
            "Meadow", rng, rng.randint(42, 56), 1.22, (0.22, 0.54), (0.04, 0.09),
            [mats["grass_dark"], mats["grass"], mats["grass_light"]], (0.04, 0.16),
        )

    def build_grass_tuft(seed: int) -> None:
        rng = random.Random(seed)
        grass_cluster(
            "Tuft", rng, rng.randint(22, 30), 0.34, (0.62, 1.14), (0.045, 0.085),
            [mats["grass_dark"], mats["grass"], mats["grass_light"]], (0.14, 0.36),
        )

    def build_grass_seedhead(seed: int) -> None:
        rng = random.Random(seed)
        grass_cluster(
            "SeedGrass", rng, rng.randint(24, 34), 0.74, (0.36, 0.76), (0.04, 0.08),
            [mats["grass"], mats["grass_dry"], mats["grass_light"]], (0.06, 0.22),
        )
        for index in range(rng.randint(5, 8)):
            angle = rng.uniform(0.0, math.tau)
            distance = rng.uniform(0.12, 0.68)
            height = rng.uniform(0.78, 1.16)
            x, y = math.cos(angle) * distance, math.sin(angle) * distance
            lean = rng.uniform(0.04, 0.16)
            end = (x + math.cos(angle) * lean, y + math.sin(angle) * lean, height)
            cylinder_between(f"Seed_Stem_{index + 1}", (x, y, 0.02), end, 0.014, mats["grass_dry"], 5)
            cone(f"Seed_Head_{index + 1}", 0.055, 0.025, rng.uniform(0.16, 0.25),
                 (end[0], end[1], end[2] + 0.08), mats["seed_head"], 6)

    def build_fern(seed: int) -> None:
        rng = random.Random(seed); fronds = rng.randint(5, 8)
        for index in range(fronds):
            angle = index / fronds * math.tau + rng.uniform(-0.2, 0.2); length = rng.uniform(0.75, 1.35); end = (math.cos(angle) * length, math.sin(angle) * length, rng.uniform(0.25, 0.55)); cylinder_between(f"Stem_{index + 1}", (0, 0, 0.12), end, 0.025, mats["grass"], 5)
            for leaf_index in range(3):
                t = 0.35 + leaf_index * 0.22; pos = (end[0] * t, end[1] * t, 0.12 + (end[2] - 0.12) * t); leaf = ico(f"Leaf_{index + 1}_{leaf_index + 1}", pos, (0.22, 0.055, 0.055), mats["leaf_light"] if leaf_index == 2 else mats["leaf"]); leaf.rotation_euler[2] = angle

    def build_reeds(seed: int) -> None:
        rng = random.Random(seed)
        for index in range(rng.randint(5, 9)):
            angle = rng.uniform(0, math.tau); distance = rng.uniform(0, 0.55); height = rng.uniform(1, 2); x, y = math.cos(angle) * distance, math.sin(angle) * distance; cylinder(f"Reed_{index + 1}", 0.025, height, (x, y, height * 0.5), mats["reed"], 6)
            if index % 2 == 0: cylinder(f"Cattail_{index + 1}", 0.075, 0.32, (x, y, height - 0.18), mats["cattail"], 7)

    def build_mushrooms(seed: int) -> None:
        rng = random.Random(seed); count = rng.randint(3, 8)
        for index in range(count):
            angle = rng.uniform(0, math.tau); distance = rng.uniform(0, 0.72); height = rng.uniform(0.28, 0.95); cap_radius = rng.uniform(0.14, 0.36); x, y = math.cos(angle) * distance, math.sin(angle) * distance
            cylinder(f"Stem_{index + 1}", 0.045 + cap_radius * 0.10, height, (x, y, height * 0.5), mats["cut"], 7); ico(f"Cap_{index + 1}", (x, y, height), (cap_radius, cap_radius, cap_radius * rng.uniform(0.35, 0.58)), mats["mushroom_blue"] if seed % 3 == 0 else mats["mushroom"], (rng.random(), rng.random(), rng.random()))
            if index == 0: ico("Cap_Spot", (x - cap_radius * 0.3, y - cap_radius * 0.2, height + cap_radius * 0.35), (0.045, 0.045, 0.02), mats["mushroom_spot"])
        ico("Mire_Growth", (0, 0, 0.055), (0.95, 0.70, 0.08), mats["mire"])

    def build_crystals(seed: int) -> None:
        rng = random.Random(seed); count = rng.randint(4, 8)
        for index in range(count):
            angle = index / count * math.tau + rng.uniform(-0.35, 0.35); distance = rng.uniform(0.05, 0.55); height = rng.uniform(0.55, 2); crystal = cone(f"Crystal_{index + 1}", rng.uniform(0.12, 0.28), rng.uniform(0.015, 0.055), height, (math.cos(angle) * distance, math.sin(angle) * distance, height * 0.5), mats["crystal_tip"] if index == 0 else mats["crystal"], rng.randint(5, 7)); crystal.rotation_euler[1] = rng.uniform(-0.22, 0.22)
        ico("Mire_Base", (0, 0, 0.07), (0.92, 0.72, 0.10), mats["mire_mid"])

    def build_tendrils(seed: int) -> None:
        rng = random.Random(seed); count = rng.randint(3, 6)
        for index in range(count):
            height = rng.uniform(0.9, 2.2); radius = rng.uniform(0.25, 0.55); phase = index / count * math.tau; points = [(math.cos(phase + step / 4 * 1.4) * radius * (1 - step / 4 * 0.45), math.sin(phase + step / 4 * 1.4) * radius * (1 - step / 4 * 0.45), step / 4 * height) for step in range(5)]
            for step in range(4): cylinder_between(f"Tendril_{index + 1}_{step + 1}", points[step], points[step + 1], 0.07 - step * 0.011, mats["mire_mid"], 6)
            ico(f"Bud_{index + 1}", points[-1], (0.13, 0.13, 0.18), mats["crystal_tip"])
        ico("Mire_Base", (0, 0, 0.055), (0.84, 0.68, 0.08), mats["mire"])

    def build_ruin_wall(seed: int) -> None:
        rng = random.Random(seed)
        for row in range(4):
            for column in range(6):
                if row >= 2 and rng.random() < 0.24 + row * 0.08: continue
                x = (column - 2.5) * 0.72 + (row % 2) * 0.18; z = 0.32 + row * 0.61; box(f"Block_{row}_{column}", (x, rng.uniform(-0.05, 0.05), z), (0.68, 0.58, 0.56), mats["ruin"] if (row + column) % 3 else mats["stone_light"], (rng.uniform(-0.03, 0.03), rng.uniform(-0.03, 0.03), rng.uniform(-0.04, 0.04)))
        ico("Moss", (rng.uniform(-1, 1), -0.34, rng.uniform(0.35, 1.4)), (0.65, 0.12, 0.22), mats["moss"])

    def build_ruin_column(seed: int) -> None:
        rng = random.Random(seed); height = rng.uniform(2.3, 4); box("Base", (0, 0, 0.18), (1.10, 1.10, 0.36), mats["ruin"]); segments = rng.randint(3, 5); segment_h = (height - 0.5) / segments
        for index in range(segments): box(f"Shaft_{index + 1}", (rng.uniform(-0.04, 0.04), rng.uniform(-0.04, 0.04), 0.36 + segment_h * (index + 0.5)), (0.72, 0.72, segment_h * 0.92), mats["ruin"] if index % 2 == 0 else mats["stone_light"], (rng.uniform(-0.025, 0.025), rng.uniform(-0.025, 0.025), rng.uniform(-0.04, 0.04)))
        if seed % 2 == 0: box("Capital", (0, 0, height), (1, 1, 0.28), mats["ruin"])

    def build_ruin_arch(seed: int) -> None:
        rng = random.Random(seed)
        for side in (-1, 1):
            for row in range(5): box(f"Pillar_{side}_{row}", (side * 1.35, 0, 0.30 + row * 0.58), (0.72, 0.72, 0.54), mats["ruin"] if row % 2 else mats["stone_light"], (0, rng.uniform(-0.03, 0.03), rng.uniform(-0.04, 0.04)))
        for index, angle in enumerate((-0.48, -0.16, 0.16, 0.48)): box(f"Arch_{index + 1}", ((index - 1.5) * 0.66, 0, 3.05 - abs(index - 1.5) * 0.12), (0.72, 0.75, 0.58), mats["ruin"], (0, angle * 0.18, angle))

    def build_marker(seed: int) -> None:
        rng = random.Random(seed); box("Base", (0, 0, 0.16), (1.35, 0.85, 0.32), mats["ruin"]); box("Marker", (0, 0, 1.45), (0.78, 0.42, 2.65), mats["stone_dark"], (0, rng.uniform(-0.08, 0.08), rng.uniform(-0.09, 0.09))); box("Rune_V", (0, -0.225, 1.45), (0.11, 0.035, 1.10), mats["rune"], (0, 0, rng.uniform(-0.3, 0.3))); box("Rune_H", (0, -0.225, 1.45), (0.70, 0.035, 0.10), mats["rune"], (0, 0, rng.uniform(-0.18, 0.18)))

    def wood_planks(prefix: str, z: float, height: float, skip: set[int] | None = None) -> None:
        for index in range(8):
            if index in (skip or set()): continue
            box(f"{prefix}_{index + 1}", (-1.75 + index * 0.5, 0, z), (0.46, 0.24, height), mats["wood_build_light"] if index % 3 == 0 else mats["wood_build"], (0, 0, (index % 2 - 0.5) * 0.012))

    def build_wood_foundation() -> None:
        for axis in (-1.75, -0.58, 0.58, 1.75): box(f"Beam_X_{axis}", (0, axis, 0.20), (4, 0.28, 0.40), mats["wood_build"]); box(f"Beam_Y_{axis}", (axis, 0, 0.20), (0.28, 4, 0.40), mats["wood_build_light"])
    def build_wood_floor() -> None:
        for index in range(8): box(f"Floor_{index + 1}", (-1.75 + index * 0.5, 0, 0.12), (0.46, 4, 0.24), mats["wood_build_light"] if index % 3 == 0 else mats["wood_build"])
    def build_wood_wall_solid() -> None: wood_planks("Wall", 1.5, 3); box("Top_Beam", (0, -0.04, 2.87), (4.2, 0.32, 0.26), mats["wood_build"]); box("Bottom_Beam", (0, -0.04, 0.13), (4.2, 0.32, 0.26), mats["wood_build"])
    def build_wood_wall_window() -> None: wood_planks("Wall", 1.5, 3, {3, 4}); box("Window_Sill", (0, -0.02, 0.88), (1.15, 0.34, 0.22), mats["wood_build_light"]); box("Window_Header", (0, -0.02, 2.20), (1.15, 0.34, 0.22), mats["wood_build_light"]); box("Window_Left", (-0.58, -0.02, 1.54), (0.20, 0.34, 1.52), mats["wood_build"]); box("Window_Right", (0.58, -0.02, 1.54), (0.20, 0.34, 1.52), mats["wood_build"])
    def build_wood_wall_door() -> None: wood_planks("Wall", 1.5, 3, {3, 4}); box("Door_Header", (0, -0.02, 2.72), (1.30, 0.36, 0.28), mats["wood_build_light"]); box("Door_Left", (-0.67, -0.02, 1.35), (0.22, 0.36, 2.70), mats["wood_build"]); box("Door_Right", (0.67, -0.02, 1.35), (0.22, 0.36, 2.70), mats["wood_build"])
    def build_wood_half_wall() -> None: wood_planks("Half_Wall", 0.75, 1.5); box("Cap", (0, -0.03, 1.52), (4.2, 0.34, 0.22), mats["wood_build_light"])
    def build_wood_roof_slope() -> None: roof_wedge("Roof", 4.2, 4.2, 2, mats["roof"])
    def build_wood_roof_corner() -> None: hip_roof("Hip_Roof", 4.2, 4.2, 2, mats["roof"])
    def build_wood_stairs() -> None:
        for index in range(8): box(f"Step_{index + 1}", (0, -1.75 + index * 0.5, 0.19 + index * 0.19), (2, 0.52, 0.38), mats["wood_build_light"] if index % 2 else mats["wood_build"])
        for side in (-0.9, 0.9): cylinder_between(f"Stringer_{side}", (side, -2, 0.15), (side, 2, 1.65), 0.10, mats["wood_build"], 6)
    def build_wood_beam() -> None: box("Beam", (0, 0, 0.18), (4, 0.36, 0.36), mats["wood_build"])
    def build_wood_post() -> None: box("Post", (0, 0, 1.5), (0.38, 0.38, 3), mats["wood_build"]); box("Foot", (0, 0, 0.12), (0.62, 0.62, 0.24), mats["wood_build_light"])
    def build_wood_railing() -> None:
        for x in (-1.9, -0.95, 0, 0.95, 1.9): box(f"Post_{x}", (x, 0, 0.62), (0.16, 0.18, 1.24), mats["wood_build"])
        box("Rail_Top", (0, 0, 1.18), (4.1, 0.22, 0.18), mats["wood_build_light"]); box("Rail_Mid", (0, 0, 0.52), (4.1, 0.18, 0.15), mats["wood_build"])

    def stone_block_wall(mode: str) -> None:
        for row in range(5):
            for column in range(8):
                if mode == "window" and 2 <= column <= 5 and 1 <= row <= 3: continue
                if mode == "door" and 2 <= column <= 5 and row <= 3: continue
                box(f"Stone_{row}_{column}", (-1.75 + column * 0.50 + (row % 2) * 0.12, 0, 0.30 + row * 0.60), (0.47, 0.46, 0.55), mats["stone_build"] if (row + column) % 3 else mats["stone_light"])
    def build_stone_foundation() -> None:
        for row in range(2):
            for x in range(4):
                for y in range(4): box(f"Block_{row}_{x}_{y}", (-1.5 + x, -1.5 + y, 0.22 + row * 0.38), (0.94, 0.94, 0.34), mats["stone_build"] if (x + y + row) % 3 else mats["stone_light"])
    def build_stone_floor() -> None:
        for x in range(4):
            for y in range(4): box(f"Tile_{x}_{y}", (-1.5 + x, -1.5 + y, 0.12), (0.94, 0.94, 0.24), mats["stone_build"] if (x + y) % 3 else mats["stone_light"])
    def build_stone_solid() -> None: stone_block_wall("solid")
    def build_stone_window() -> None: stone_block_wall("window"); box("Sill", (0.12, -0.02, 0.88), (2, 0.58, 0.24), mats["stone_light"]); box("Lintel", (0.12, -0.02, 2.48), (2, 0.58, 0.28), mats["stone_light"])
    def build_stone_door() -> None: stone_block_wall("door"); box("Lintel", (0.12, -0.02, 2.72), (2.1, 0.62, 0.30), mats["stone_light"])
    def build_stone_half() -> None:
        for row in range(3):
            for column in range(8): box(f"Stone_{row}_{column}", (-1.75 + column * 0.50 + (row % 2) * 0.12, 0, 0.28 + row * 0.55), (0.47, 0.46, 0.50), mats["stone_build"] if (row + column) % 3 else mats["stone_light"])
    def build_stone_stairs() -> None:
        for index in range(8): box(f"Step_{index + 1}", (0, -1.75 + index * 0.5, 0.18 + index * 0.20), (2.2, 0.54, 0.36), mats["stone_build"] if index % 3 else mats["stone_light"])
    def build_stone_pillar() -> None:
        box("Base", (0, 0, 0.18), (0.90, 0.90, 0.36), mats["stone_light"])
        for index in range(5): box(f"Pillar_{index + 1}", (0, 0, 0.55 + index * 0.54), (0.62, 0.62, 0.50), mats["stone_build"] if index % 2 else mats["stone_light"])
        box("Cap", (0, 0, 3), (0.90, 0.90, 0.30), mats["stone_light"])
    def build_fence_straight() -> None:
        for x in (-2, 0, 2): box(f"Post_{x}", (x, 0, 0.78), (0.24, 0.24, 1.56), mats["wood_build"])
        box("Rail_Low", (0, 0, 0.48), (4.2, 0.18, 0.18), mats["wood_build_light"]); box("Rail_High", (0, 0, 1.08), (4.2, 0.18, 0.18), mats["wood_build_light"])
    def build_fence_corner() -> None:
        build_fence_straight()
        for y in (1, 2): box(f"Corner_Post_{y}", (2, y, 0.78), (0.24, 0.24, 1.56), mats["wood_build"])
        for z in (0.48, 1.08): box(f"Corner_Rail_{z}", (2, 1, z), (0.18, 2.1, 0.18), mats["wood_build_light"])
    def build_fence_gate() -> None:
        # Two short leaves are modelled swung open, so the map's four exits read as exits.
        for post_index, x in enumerate((-2.05, 2.05), start=1):
            box(f"Post_{post_index}", (x, 0, 0.92), (0.32, 0.32, 1.84), mats["wood_build"])
        leaf_length = 1.58
        for side, pivot_x, angle in (("Left", -2.05, math.radians(72.0)),
                                     ("Right", 2.05, math.radians(108.0))):
            cx = pivot_x + math.cos(angle) * leaf_length * 0.5
            cy = math.sin(angle) * leaf_length * 0.5
            for rail_index, height in enumerate((0.48, 1.10), start=1):
                box(f"Gate_{side}_Rail_{rail_index}", (cx, cy, height),
                    (leaf_length, 0.18, 0.18), mats["wood_build_light"], (0, 0, angle))
            end_x = pivot_x + math.cos(angle) * leaf_length
            end_y = math.sin(angle) * leaf_length
            box(f"Gate_{side}_Stile", (end_x, end_y, 0.80), (0.18, 0.18, 1.28), mats["wood_build"])
    def build_fence_post() -> None: box("Post", (0, 0, 0.90), (0.34, 0.34, 1.80), mats["wood_build"]); cone("Post_Cap", 0.28, 0.02, 0.38, (0, 0, 1.99), mats["wood_build_light"], 4)

    specs: list[tuple[str, str, Callable[[], None]]] = []
    def add_seeded(names: list[str], category: str, builder: Callable[[int], None]) -> None:
        for asset_name in names: specs.append((asset_name, category, lambda name=asset_name, fn=builder: fn(seed_for(name))))
    add_seeded([f"tree_pine_{x}" for x in "abcdef"], "trees", build_pine); add_seeded([f"tree_bare_{x}" for x in "abcd"], "trees", build_bare); add_seeded([f"tree_birch_{x}" for x in "abcd"], "trees", build_birch); add_seeded([f"tree_crooked_{x}" for x in "abcd"], "trees", build_crooked)
    add_seeded([f"boulder_{x}" for x in "abcdefgh"], "rocks", build_boulder); add_seeded([f"rock_cluster_{x}" for x in "abcdef"], "rocks", build_rock_cluster); add_seeded([f"standing_stone_{x}" for x in "abcd"], "rocks", build_standing_stone)
    add_seeded([f"stump_{x}" for x in "abcd"], "forest_debris", build_stump); add_seeded([f"fallen_log_{x}" for x in "abcd"], "forest_debris", build_fallen_log); add_seeded([f"root_cluster_{x}" for x in "abcd"], "forest_debris", build_root_cluster)
    add_seeded([f"grass_clump_{x}" for x in "abcdef"], "ground_cover", build_grass)
    add_seeded([f"grass_meadow_{x}" for x in "abcd"], "ground_cover", build_grass_meadow)
    add_seeded([f"grass_tuft_{x}" for x in "abcd"], "ground_cover", build_grass_tuft)
    add_seeded([f"grass_seedhead_{x}" for x in "abcd"], "ground_cover", build_grass_seedhead)
    add_seeded([f"fern_{x}" for x in "abcdef"], "ground_cover", build_fern); add_seeded([f"reeds_{x}" for x in "abcd"], "ground_cover", build_reeds)
    add_seeded([f"mushroom_cluster_{x}" for x in "abcdef"], "mire_growth", build_mushrooms); add_seeded([f"mire_crystal_{x}" for x in "abcdef"], "mire_growth", build_crystals); add_seeded([f"mire_tendril_{x}" for x in "abcd"], "mire_growth", build_tendrils)
    add_seeded([f"ruin_wall_{x}" for x in "abcd"], "ruins", build_ruin_wall); add_seeded([f"ruin_column_{x}" for x in "abcd"], "ruins", build_ruin_column); add_seeded([f"ruin_arch_{x}" for x in "ab"], "ruins", build_ruin_arch); add_seeded([f"stone_marker_{x}" for x in "ab"], "ruins", build_marker)
    building_specs = [("wood_foundation", build_wood_foundation), ("wood_floor", build_wood_floor), ("wood_wall_solid", build_wood_wall_solid), ("wood_wall_window", build_wood_wall_window), ("wood_wall_door", build_wood_wall_door), ("wood_half_wall", build_wood_half_wall), ("wood_roof_slope", build_wood_roof_slope), ("wood_roof_corner", build_wood_roof_corner), ("wood_stairs", build_wood_stairs), ("wood_beam", build_wood_beam), ("wood_post", build_wood_post), ("wood_railing", build_wood_railing), ("stone_foundation", build_stone_foundation), ("stone_floor", build_stone_floor), ("stone_wall_solid", build_stone_solid), ("stone_wall_window", build_stone_window), ("stone_wall_door", build_stone_door), ("stone_half_wall", build_stone_half), ("stone_stairs", build_stone_stairs), ("stone_pillar", build_stone_pillar), ("fence_straight", build_fence_straight), ("fence_corner", build_fence_corner), ("fence_gate", build_fence_gate), ("fence_post", build_fence_post)]
    specs.extend((name, "building_pieces", builder) for name, builder in building_specs)
    if len(specs) != 128: raise RuntimeError(f"Catalog must contain 128 assets, found {len(specs)}")
    if len({name for name, _, _ in specs}) != len(specs): raise RuntimeError("Asset names must be unique")

    counters = {category: 0 for category in CATEGORY_ORDER}; records: list[dict] = []
    for name, category, builder in specs:
        index = counters[category]; counters[category] += 1; columns = 6; rows = math.ceil(CATEGORY_TOTALS[category] / columns); column = index % columns; row = index // columns; category_y = CATEGORY_ORDER.index(category) * 38.0
        # F-396: the trees are now 12-20 m with crowns 5-7 m across, so the flat
        # 5.5 m grid the preview used to lay them out on packed them into one
        # continuous hedge. Spacing is per category now; every other row is
        # unchanged. This only moves `display_location`, which is applied AFTER
        # export — no GLB is affected by it.
        spacing_x, spacing_y = (11.0, 12.0) if category == "trees" else (5.5, 6.0)
        location = ((column - 2.5) * spacing_x, category_y + (row - (rows - 1) * 0.5) * spacing_y, 0.0)
        records.append(create_asset(name, category, builder, location, join=(category == "trees")))
    catalog = [{"name": r["name"], "category": r["category"], "width_m": round(r["width"], 3), "depth_m": round(r["depth"], 3), "height_m": round(r["height"], 3), "mesh_parts": r["parts"], "polygons": r["polygons"], "materials": r["materials"]} for r in records]
    with (ASSET_DIR / "catalog.json").open("w", encoding="utf-8") as handle:
        json.dump(catalog, handle, indent=2)
        handle.write("\n")

    preview_collection = bpy.data.collections.new("PREVIEW_ONLY"); bpy.context.scene.collection.children.link(preview_collection); bpy.ops.mesh.primitive_plane_add(size=320, location=(0, 114, -0.04)); plane = bpy.context.object; plane.name = "Preview_Ground"; assign(plane, mats["ground"])
    for old in list(plane.users_collection): old.objects.unlink(plane)
    preview_collection.objects.link(plane)
    bpy.ops.object.light_add(type="SUN", location=(0, 0, 80)); sun = bpy.context.object; sun.name = "Preview_Sun"; sun.rotation_euler = (math.radians(34), math.radians(-22), math.radians(-28)); sun.data.energy = 2.4; sun.data.angle = math.radians(18)
    bpy.ops.object.light_add(type="AREA", location=(-22, 110, 34)); fill = bpy.context.object; fill.name = "Preview_Fill"; fill.data.energy = 1800; fill.data.color = (0.43, 0.28, 0.68); fill.data.shape = "DISK"; fill.data.size = 24; look_at(fill, (0, 110, 1.5))
    bpy.ops.object.camera_add(location=(23, -28, 22)); camera = bpy.context.object; camera.name = "Preview_Camera"; camera.data.type = "ORTHO"; camera.data.ortho_scale = 36; bpy.context.scene.camera = camera
    scene = bpy.context.scene; scene.render.engine = "BLENDER_EEVEE"; scene.render.resolution_x = 1600; scene.render.resolution_y = 900; scene.render.resolution_percentage = 100; scene.render.image_settings.file_format = "PNG"; scene.render.film_transparent = False; scene.world.color = (0.014, 0.019, 0.026); scene.view_settings.look = "AgX - Medium High Contrast"
    def set_visible(record: dict, visible: bool) -> None:
        record["root"].hide_render = not visible
        for child in record["root"].children_recursive:
            child.hide_render = not visible

    # F-396: the trees grew 3x, so their frame has to. Everything else is untouched.
    preview_scales = {"trees": 86.0, "rocks": 36.0, "forest_debris": 34.0, "ground_cover": 42.0, "mire_growth": 34.0, "ruins": 34.0, "building_pieces": 40.0}
    preview_heights = {"trees": 8.5, "rocks": 1.2, "forest_debris": 0.8, "ground_cover": 0.5, "mire_growth": 0.9, "ruins": 1.6, "building_pieces": 1.5}
    for category in CATEGORY_ORDER:
        category_y = CATEGORY_ORDER.index(category) * 38.0
        for r in records: set_visible(r, r["category"] == category)
        target_height = preview_heights[category]
        camera.location = (22, category_y - 29, 22 + target_height); camera.data.ortho_scale = preview_scales[category]; look_at(camera, (0, category_y, target_height)); scene.render.filepath = str(PREVIEW_DIR / CATEGORY_PREVIEWS[category]); bpy.ops.render.render(write_still=True)

    # F-396: re-laid out for trees that are now 12-20 m rather than 5-7 m. The
    # trees move to the back and spread out; the ground-scale props stay forward
    # where they are still legible against them. The point of this frame is
    # precisely the comparison the finding is about, so it has to hold both.
    hero_positions = {
        "tree_pine_c": (-15.0, 12.0, 0.0), "tree_birch_b": (-6.5, 14.0, 0.0),
        "tree_crooked_b": (2.0, 11.0, 0.0), "tree_bare_b": (11.0, 14.5, 0.0),
        "boulder_d": (7.0, 2.0, 0.0), "standing_stone_b": (11.5, 2.5, 0.0),
        "fallen_log_c": (-9.0, -1.0, 0.0), "fern_c": (-4.5, -2.0, 0.0), "mire_crystal_c": (-0.5, -2.0, 0.0),
        "ruin_arch_a": (3.5, -1.5, 0.0), "wood_wall_window": (-14.0, 1.0, 0.0),
    }
    original_locations: dict[str, Vector] = {}
    for r in records:
        set_visible(r, r["name"] in hero_positions)
        if r["name"] in hero_positions:
            original_locations[r["name"]] = r["root"].location.copy()
            r["root"].location = hero_positions[r["name"]]
    camera.data.type = "PERSP"; camera.data.lens = 48.0; camera.location = (24.0, -46.0, 11.0); look_at(camera, (-1.0, 4.0, 7.5))
    scene.render.resolution_x = 1600; scene.render.resolution_y = 900; scene.render.filepath = str(PREVIEW_DIR / "mire_map_kit_preview.png"); bpy.ops.render.render(write_still=True)
    for r in records:
        if r["name"] in original_locations: r["root"].location = original_locations[r["name"]]
        set_visible(r, True)
    bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE_DIR / "mire_map_kit.blend")); print(f"Built {len(records)} MIRE assets across {len(CATEGORY_ORDER)} categories")


if __name__ == "__main__":
    with import_cache_guard(Path(__file__).name):
        main()
