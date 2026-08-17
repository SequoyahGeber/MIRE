"""MIRE's shared art library: one palette, one scale table, one set of primitives.

Import from a generator with::

    import sys, pathlib
    sys.path.append(str(pathlib.Path(__file__).resolve().parent))
    from mire_art import PALETTE, SCALE, mat, box, ico, cone, cylinder_between

Why this module exists
----------------------
Before it, every generator carried its own copy of ``material()``, ``box()``,
``ico()`` and ``cone()`` — five different signatures of the first and nine to
eleven copies of the rest — and every generator invented its own colours inline
as raw linear floats. The result, measured across ``build_*.py``: **233 material
definitions, 216 of them a distinct colour, and not one colour shared between
two families.** Wood was seven different browns depending on which file drew it,
iron four different greys, leather two. A tool's oak haft and a crafting
station's oak bench top had no reason to match, so they did not.

Three rules keep that from coming back:

1. **Colour is named, never numeric.** Generators ask for ``PALETTE["wood_bark"]``.
   A raw RGB tuple in a generator is a bug.
2. **Colour is authored in sRGB hex, stored in linear.** The old floats were
   linear, which is the right thing to hand Blender and the wrong thing to hand
   a human: nobody can look at ``(0.075, 0.025, 0.014)`` and see charred wood, so
   nobody noticed the drift. ``#2E1A10`` is legible, so it is checkable.
3. **Size is named too.** ``SCALE`` holds the real dimension of anything whose
   size a player can judge against their own body. Assets were previously sized
   to fill their own preview frame, which is why a coin ended up 0.36 m across
   and a berry 0.71 m, and why fourteen pickups that should span 50:1 in size
   spanned 4:1.

The palette is deliberately small. Flat-shaded low-poly reads by value contrast
and silhouette, not by hue variety; a wide palette makes a scene look noisy, not
rich.
"""

from __future__ import annotations

import math
import random
from typing import Sequence

import bpy
from mathutils import Vector


# ---------------------------------------------------------------------------
# Colour
# ---------------------------------------------------------------------------


def srgb_to_linear(c: float) -> float:
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def hex_rgba(value: str, alpha: float = 1.0) -> tuple[float, float, float, float]:
    """``"#2E1A10"`` -> linear RGBA, which is what Blender's shader sockets want."""
    value = value.lstrip("#")
    r, g, b = (int(value[i : i + 2], 16) / 255.0 for i in (0, 2, 4))
    return (srgb_to_linear(r), srgb_to_linear(g), srgb_to_linear(b), alpha)


class Swatch:
    """A named surface: colour plus how it behaves under light.

    Roughness and metallic travel with the colour because they are part of what
    makes a substance recognisable. Iron that is 0.9 rough reads as painted grey
    plastic no matter how correct its hue is, and that was happening — the old
    per-family ``material()`` copies disagreed about whether metallic was even a
    parameter, so four of eleven generators could not express metal at all.
    """

    __slots__ = ("hex", "roughness", "metallic", "emission_hex", "emission_strength", "note")

    def __init__(
        self,
        hex_value: str,
        roughness: float = 0.88,
        metallic: float = 0.0,
        emission_hex: str | None = None,
        emission_strength: float = 0.0,
        note: str = "",
    ) -> None:
        self.hex = hex_value
        self.roughness = roughness
        self.metallic = metallic
        self.emission_hex = emission_hex
        self.emission_strength = emission_strength
        self.note = note

    @property
    def rgba(self) -> tuple[float, float, float, float]:
        return hex_rgba(self.hex)

    @property
    def emission_rgba(self) -> tuple[float, float, float, float] | None:
        return hex_rgba(self.emission_hex) if self.emission_hex else None


#: The MIRE palette. Ramps are three stops of one hue (dark / mid / light) so a
#: flat-shaded form reads as one substance catching light at three angles.
#:
#: Art direction, stated once so a generator never has to guess:
#:   * Naturals are warm and muted — the world is wet, overcast and rotting.
#:   * The Mire is desaturated purple-black, and it is the ONLY purple.
#:   * Wards answer the Mire in teal. Purple means corruption, teal means safety;
#:     those two hues are reserved and must not be spent on decoration.
#:   * Fire and brass are the only warm accents, so a lit camp reads instantly.
PALETTE: dict[str, Swatch] = {
    # -- wood ---------------------------------------------------------------
    "wood_bark_dark": Swatch("#4A2C1B", 0.94, note="shadowed bark, trunk undersides"),
    "wood_bark": Swatch("#76482C", 0.94, note="standing tree bark"),
    "wood_bark_light": Swatch("#A46C3F", 0.92, note="lit bark, root flares"),
    "wood_timber": Swatch("#9E693C", 0.86, note="worked/planed wood: benches, planks, hafts"),
    "wood_timber_light": Swatch("#C0894D", 0.84, note="lit plank faces, fresh boards"),
    "wood_cut": Swatch("#DDAA65", 0.80, note="fresh cut end-grain and axe scars"),
    "wood_charred": Swatch("#3A2A20", 0.96, note="burnt wood around fire"),
    "wood_dead": Swatch("#8E8076", 0.95, note="grey weathered deadwood bark"),
    "wood_dead_cut": Swatch("#C0B2A0", 0.92, note="dry punky interior of deadwood"),
    "wood_birch": Swatch("#DDDFD1", 0.90, note="birch bark; the one pale trunk"),
    "wood_birch_mark": Swatch("#616961", 0.92, note="birch lenticels and scars"),
    # -- stone --------------------------------------------------------------
    "stone_dark": Swatch("#59656C", 0.95, note="crevices, undersides"),
    "stone": Swatch("#818E93", 0.94, note="boulders, walls, node bodies"),
    "stone_light": Swatch("#ACB6B3", 0.92, note="lit faces, fresh fracture"),
    "stone_ruin": Swatch("#A2A499", 0.94, note="dressed/lichened ruin masonry"),
    # -- metal --------------------------------------------------------------
    "iron_dark": Swatch("#506169", 0.52, 0.62, note="wrought shadow, hammer faces"),
    "iron": Swatch("#95A6AC", 0.42, 0.72, note="tool heads, fittings"),
    "iron_light": Swatch("#D0DDDE", 0.26, 0.80, note="ground cutting edges only"),
    "brass": Swatch("#EAB342", 0.34, 0.62, note="caps, quillons, fittings"),
    "gold": Swatch("#FFD738", 0.30, 0.66, note="coins and treasure"),
    # -- foliage ------------------------------------------------------------
    "pine_dark": Swatch("#277C59", 0.94),
    "pine": Swatch("#30A273", 0.94),
    "pine_light": Swatch("#59C486", 0.92),
    "leaf_deep": Swatch("#3C7E59", 0.94),
    "leaf": Swatch("#59AF65", 0.93),
    "leaf_light": Swatch("#95CE73", 0.92),
    "leaf_gold": Swatch("#D4AF50", 0.92, note="autumn accent; use sparingly"),
    "grass_dark": Swatch("#4B935D", 0.95),
    "grass": Swatch("#6CB56F", 0.94),
    "grass_light": Swatch("#A4D676", 0.93),
    "grass_dry": Swatch("#B8AF6F", 0.94, note="reeds, thatch, straw, dry tufts"),
    "moss": Swatch("#61A055", 0.96),
    "reed": Swatch("#A6BF61", 0.94),
    "grass_seed": Swatch("#99864D", 0.94, note="seed heads and dry stalk tips"),
    # Fungus is the one place a non-corruption pink/blue is allowed. Kept muted so
    # it never competes with the reserved Mire purple or Ward teal.
    "fungus_cap": Swatch("#A8437F", 0.88, note="pink toadstool cap"),
    "fungus_blue": Swatch("#4A79A8", 0.88, note="blue toadstool cap"),
    # -- organic / creature -------------------------------------------------
    "flesh_raw": Swatch("#B85757", 0.82, note="raw meat; muted, never fire-engine red"),
    "flesh_fat": Swatch("#F9D1C4", 0.84),
    "bone": Swatch("#ECE6CE", 0.86),
    "flesh_cooked": Swatch("#A56540", 0.86, note="cooked meat; browner and darker than raw"),
    "flesh_charred": Swatch("#4E3628", 0.92, note="seared edges on cooked food"),
    "leather": Swatch("#B58655", 0.90, note="ONE leather: grips, pouches, hides, straps"),
    "leather_dark": Swatch("#86613C", 0.92, note="shadowed leather, straps and welts"),
    "cloth_dark": Swatch("#AD9E76", 0.95, note="sackcloth in shadow"),
    "canvas": Swatch("#86AA9E", 0.95, note="sage tarpaulin and pack canvas"),
    "canvas_dark": Swatch("#65867E", 0.96, note="canvas in shadow"),
    "cloth": Swatch("#C2AE8C", 0.95),
    "cloth_red": Swatch("#C1503F", 0.93, note="the only red textile"),
    "rope": Swatch("#DABD65", 0.95),
    "fibre": Swatch("#EADA7C", 0.95),
    "chitin_dark": Swatch("#3A3149", 0.72, note="crawler shell shadow"),
    "chitin": Swatch("#5D5073", 0.68, note="crawler shell"),
    # -- mire corruption (purple is reserved) -------------------------------
    "mire_black": Swatch("#2E123A", 0.92),
    "mire": Swatch("#5D2473", 0.90),
    "mire_light": Swatch("#973CAF", 0.88),
    "mire_flesh": Swatch("#A8569E", 0.84, note="wet corrupted tissue"),
    "mire_glow": Swatch("#3A1C4E", 0.60, 0.0, "#A03CE6", 2.0, note="emissive corruption veins"),
    "crystal": Swatch("#8E50BF", 0.34, 0.0, "#8A34E0", 1.8, note="mire crystal body"),
    "crystal_tip": Swatch("#C47CF1", 0.24, 0.0, "#B14EFF", 2.4, note="crystal highlights"),
    # -- ward: teal is the answer to the Mire's purple, and is reserved ---
    "ward_stone": Swatch("#A2AAA6", 0.94, 0.00),
    "ward_stone_dark": Swatch("#6C7979", 0.95, 0.00),
    "ward_slate": Swatch("#596C73", 0.90, 0.00),
    "ward_crystal": Swatch("#45CED6", 0.22, 0.05, "#3FDDE7", 2.2),
    "ward_crystal_light": Swatch("#90F6F1", 0.18, 0.02, "#76FFF3", 3.0),
    "ward_crystal_dim": Swatch("#6FADB1", 0.38, 0.00, "#50A6AD", 0.8),
    "ward_glow": Swatch("#7CEFE5", 0.20, 0.00, "#61FFEA", 3.4),
    "ward_glow_dim": Swatch("#59A6A2", 0.34, 0.00, "#459E97", 0.8),
    "ward_dead": Swatch("#4D5555", 0.72, 0.00),
    "critical": Swatch("#F17661", 0.30, 0.00, "#FF5030", 2.5),
    "critical_light": Swatch("#FFB850", 0.22, 0.00, "#FF8B30", 3.0),
    "brass_dark": Swatch("#957645", 0.48, 0.52),
    # -- wellspring corruption states: the objective's own language, read
    #    left to right as clear -> split -> corrupted --------------------
    "mire_metal": Swatch("#6F4D7C", 0.52, 0.34, note="corrupted metal fittings"),
    "mire_dormant": Swatch("#796F76", 0.92, 0.00, note="roots gone quiet; neither clear nor corrupt"),
    "mire_liquid": Swatch("#794297", 0.16, 0.00, "#AA45CE", 1.8, note="corrupted Wellspring water"),
    "clear_liquid": Swatch("#3FBCBA", 0.14, 0.00, "#45DDD4", 1.7, note="cleansed Wellspring water"),
    "split_glow": Swatch("#86AAB8", 0.26, 0.00, "#9E8BCB", 1.6, note="re-corrupting: teal losing to purple"),
    "split_liquid": Swatch("#867CAA", 0.18, 0.00, "#9981C4", 1.4, note="water mid-turn between the two"),
    # -- fire and accents ---------------------------------------------------
    "ember": Swatch("#E06A22", 0.60, 0.0, "#FF6A18", 1.7, note="outer flame / hot coals"),
    "flame": Swatch("#F2A03C", 0.50, 0.0, "#FFB03A", 2.5, note="flame core; brighter than ember, still coloured"),
    "coal": Swatch("#2C3138", 0.96),
    "blood": Swatch("#7A1E1E", 0.86),
    "ice": Swatch("#7FD6E6", 0.30, 0.0, "#A8E8F4", 0.8),
    # -- utility ------------------------------------------------------------
    "preview_ground": Swatch("#3D5242", 0.98, note="preview backdrop only, never shipped"),
    "reference_blue": Swatch("#2E7ACC", 0.90, note="scale-reference figure only"),
}


# ---------------------------------------------------------------------------
# Scale
# ---------------------------------------------------------------------------

#: Player eye height. Every "does this read?" judgement is made from here.
EYE_HEIGHT_M = 1.65
PLAYER_HEIGHT_M = 1.80

#: A dropped item smaller than this is a pixel at gameplay distance. Rather than
#: inflating a single coin to the size of a dinner plate — which is what the old
#: art did, at 0.36 m — small items are authored true-size and made *legible by
#: quantity*: a dropped "coin" is a small spill of coins, a "berry" is a handful.
#: The object is honest next to a 1.8 m player and still visible on the ground.
READABILITY_FLOOR_M = 0.10

#: Real longest-axis dimension, in metres, for anything a player can size up
#: against themselves. Generators assert against this instead of eyeballing a
#: preview. Where a pickup is a cluster, the figure is the cluster's extent and
#: the per-unit size is in the comment.
SCALE: dict[str, float] = {
    # pickups — the family that drifted worst
    "pickup_coin": 0.10,            # spill of ~5 coins, each 0.026 across
    "pickup_coin_stack": 0.12,      # stacked column plus a few loose
    "pickup_berry": 0.09,           # handful of ~7 berries, each 0.019
    "pickup_mushroom": 0.16,        # pair of caps, larger 0.11 across
    "pickup_raw_meat": 0.30,        # a cut off the bone, not a whole carcass
    "pickup_stone": 0.18,
    "pickup_flint": 0.13,
    "pickup_coal": 0.16,            # small heap of lumps
    "pickup_iron_ore": 0.20,
    "pickup_iron_ingot": 0.26,
    "pickup_salvage_fragment": 0.19,
    "pickup_fibre_bundle": 0.32,
    "pickup_branch": 0.85,
    "pickup_log": 1.20,
    # tools and weapons — length along the haft
    "wooden_axe": 0.78,
    "stone_axe": 0.80,
    "wooden_pickaxe": 0.92,
    "stone_pickaxe": 0.95,
    "iron_pickaxe": 0.98,
    "cleaver": 0.42,
    "skewer": 1.05,
    "short_bow": 1.15,
    "arrow": 0.74,
    "repair_hammer": 0.55,
    "iron_sword": 1.02,
    # world fixtures
    "station_workbench": 1.30,
    "station_campfire": 1.10,
    "station_anvil": 0.95,
    "ward_healthy": 2.10,
    "wellspring_monolith": 7.25,
    "enemy_crawler": 1.10,
}


def check_scale(name: str, dimensions: Sequence[float], tolerance: float = 0.12) -> str | None:
    """Return a complaint if a built asset misses its ``SCALE`` entry."""
    target = SCALE.get(name)
    if target is None:
        return None
    longest = max(dimensions)
    if target <= 0:
        return None
    ratio = longest / target
    if abs(ratio - 1.0) > tolerance:
        return f"{name}: longest axis {longest:.3f} m vs target {target:.3f} m ({ratio:.2f}x)"
    return None


# ---------------------------------------------------------------------------
# Materials
# ---------------------------------------------------------------------------

_MATERIAL_CACHE: dict[str, bpy.types.Material] = {}


def mat(token: str, suffix: str = "") -> bpy.types.Material:
    """Fetch (or build once) the shared material for a palette token.

    Materials are cached per token so a scene with forty objects sharing
    ``wood_timber`` exports one material, not forty near-identical ones.
    """
    if token not in PALETTE:
        raise KeyError(f"unknown palette token {token!r}; add it to mire_art.PALETTE rather than inlining a colour")
    key = f"{token}{suffix}"
    cached = _MATERIAL_CACHE.get(key)
    if cached is not None and key in bpy.data.materials:
        return cached

    sw = PALETTE[token]
    name = "MIRE_" + "".join(part.capitalize() for part in key.split("_"))
    material = bpy.data.materials.new(name)
    material.diffuse_color = sw.rgba
    material.use_nodes = True
    shader = material.node_tree.nodes.get("Principled BSDF")
    shader.inputs["Base Color"].default_value = sw.rgba
    shader.inputs["Roughness"].default_value = sw.roughness
    shader.inputs["Metallic"].default_value = sw.metallic
    emission = sw.emission_rgba
    if emission is not None:
        shader.inputs["Emission Color"].default_value = emission
        shader.inputs["Emission Strength"].default_value = sw.emission_strength
    _MATERIAL_CACHE[key] = material
    return material


def reset_materials() -> None:
    """Drop the cache. Call after clearing the scene between builds."""
    _MATERIAL_CACHE.clear()


def palette_report() -> list[str]:
    """Human-checkable dump, used by the palette contact sheet."""
    return [f"{k:18s} {v.hex}  rough={v.roughness:.2f} metal={v.metallic:.2f}  {v.note}" for k, v in PALETTE.items()]


# ---------------------------------------------------------------------------
# Primitives
# ---------------------------------------------------------------------------


def assign(obj: bpy.types.Object, material: bpy.types.Material) -> bpy.types.Object:
    obj.data.materials.append(material)
    for polygon in obj.data.polygons:
        polygon.use_smooth = False
    return obj


def make_consistent(obj: bpy.types.Object) -> None:
    """Recalculate outward normals.

    Hand-authored face loops are not reliably wound the same way, and Godot
    imports glTF with back-face culling on, so an inverted face is an invisible
    face rather than a shading nit.
    """
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.mesh.normals_make_consistent(inside=False)
    bpy.ops.object.mode_set(mode="OBJECT")


def mesh_object(
    name: str,
    vertices: list[tuple[float, float, float]],
    faces: list[tuple[int, ...]],
    material: bpy.types.Material,
    recalculate: bool = True,
) -> bpy.types.Object:
    mesh = bpy.data.meshes.new(f"{name}_Mesh")
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    assign(obj, material)
    if recalculate:
        make_consistent(obj)
        for polygon in obj.data.polygons:
            polygon.use_smooth = False
    return obj


def box(
    name: str,
    location: tuple[float, float, float],
    dimensions: tuple[float, float, float],
    material: bpy.types.Material,
    rotation: tuple[float, float, float] = (0.0, 0.0, 0.0),
    bevel: float = 0.0,
) -> bpy.types.Object:
    """A cube. ``bevel`` > 0 applies a one-segment bevel modifier.

    Beware the bevel on families that must rebuild byte-identically:
    ``build_ward_set.py`` found Blender's bevel modifier changing four float
    bytes between otherwise identical background exports on Apple Silicon, so it
    overrides this function with a bevel-free version. If a family's contract
    includes a deterministic rebuild, check that before turning bevels on.
    """
    bpy.ops.mesh.primitive_cube_add(location=location, rotation=rotation)
    obj = bpy.context.object
    obj.name = name
    obj.scale = (dimensions[0] * 0.5, dimensions[1] * 0.5, dimensions[2] * 0.5)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    if bevel > 0.0:
        modifier = obj.modifiers.new("Low_Poly_Bevel", "BEVEL")
        modifier.width = bevel
        modifier.segments = 1
        bpy.context.view_layer.objects.active = obj
        bpy.ops.object.modifier_apply(modifier=modifier.name)
    return assign(obj, material)


def cone(
    name: str,
    radius_bottom: float,
    radius_top: float,
    depth: float,
    location: tuple[float, float, float],
    material: bpy.types.Material,
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
    return assign(obj, material)


def ico(
    name: str,
    location: tuple[float, float, float],
    scale: tuple[float, float, float],
    material: bpy.types.Material,
    rotation: tuple[float, float, float] = (0.0, 0.0, 0.0),
    subdivisions: int = 1,
) -> bpy.types.Object:
    bpy.ops.mesh.primitive_ico_sphere_add(
        subdivisions=subdivisions, radius=1.0, location=location, rotation=rotation
    )
    obj = bpy.context.object
    obj.name = name
    obj.scale = scale
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    return assign(obj, material)


def cylinder_between(
    name: str,
    start: tuple[float, float, float],
    end: tuple[float, float, float],
    radius: float,
    material: bpy.types.Material,
    vertices: int = 8,
    end_radius_ratio: float = 0.94,
) -> bpy.types.Object:
    first, second = Vector(start), Vector(end)
    direction = second - first
    obj = cone(
        name, radius, radius * end_radius_ratio, direction.length,
        tuple((first + second) * 0.5), material, vertices,
    )
    obj.rotation_mode = "QUATERNION"
    obj.rotation_quaternion = direction.to_track_quat("Z", "Y")
    return obj


def tapered_between(
    name: str,
    start: tuple[float, float, float],
    end: tuple[float, float, float],
    start_radius: float,
    end_radius: float,
    material: bpy.types.Material,
    vertices: int = 8,
) -> bpy.types.Object:
    first, second = Vector(start), Vector(end)
    direction = second - first
    obj = cone(name, start_radius, end_radius, direction.length, tuple((first + second) * 0.5), material, vertices)
    obj.rotation_mode = "QUATERNION"
    obj.rotation_quaternion = direction.to_track_quat("Z", "Y")
    return obj


# ---------------------------------------------------------------------------
# Scene and bounds helpers
# ---------------------------------------------------------------------------


def radial(
    count: int,
    radius: float,
    seed: int = 0,
    jitter: float = 0.34,
    radius_jitter: float = 0.12,
    phase: float = 0.0,
) -> list[tuple[float, float]]:
    """``count`` (angle, radius) pairs spread right around an axis.

    This is the cure for the defect that prompted the overhaul. The old code
    placed decoration by writing coordinates by hand, and a hand that is looking
    at one preview writes them all on the side it can see::

        for x in (-0.38, 0.18, 0.48):
            cylinder_between(f"Bark_Ridge", (x, -0.20, 0.19), (x + 0.12, -0.19, 0.39), ...)

    Three ridges, all at y = -0.20, all running the same direction: a log with a
    front and a bare back. Asking for angles instead of coordinates makes the
    even spread the default and the one-sided cluster the thing you have to work
    at. Jitter is deterministic, seeded per asset, so rebuilds stay identical.
    """
    rng = random.Random(seed)
    step = math.tau / max(count, 1)
    out: list[tuple[float, float]] = []
    for i in range(count):
        angle = phase + i * step + rng.uniform(-jitter, jitter) * step
        out.append((angle, radius * (1.0 + rng.uniform(-radius_jitter, radius_jitter))))
    return out


def around(
    axis_point: tuple[float, float, float],
    angle: float,
    radius: float,
    axis: str = "z",
) -> tuple[float, float, float]:
    """Point at ``angle``/``radius`` around an axis through ``axis_point``."""
    x, y, z = axis_point
    c, s = math.cos(angle) * radius, math.sin(angle) * radius
    if axis == "z":
        return (x + c, y + s, z)
    if axis == "x":
        return (x, y + c, z + s)
    return (x + c, y, z + s)


def look_at(obj: bpy.types.Object, target: tuple[float, float, float]) -> None:
    direction = obj.location - Vector(target)
    obj.rotation_euler = direction.to_track_quat("Z", "Y").to_euler()


def descendants(obj: bpy.types.Object) -> list[bpy.types.Object]:
    out = [obj]
    for child in obj.children:
        out.extend(descendants(child))
    return out


def move_to_collection(objects: list[bpy.types.Object], collection: bpy.types.Collection) -> None:
    for obj in objects:
        for existing in list(obj.users_collection):
            existing.objects.unlink(obj)
        collection.objects.link(obj)


def world_bounds(objects: list[bpy.types.Object]) -> tuple[Vector, Vector]:
    # Flush pending transforms first. `obj.location = ...` does not refresh
    # `matrix_world` on its own, so measuring without this reads the object at
    # wherever it was BEFORE the builder moved it. That is not a visible error —
    # the asset still exports, just mis-measured and mis-grounded. It cost the
    # woodcutting block 0.31 m of height (its splitting wedge was measured at
    # the origin) and the catalog diff was the only thing that noticed.
    bpy.context.view_layer.update()
    lo = Vector((1e9, 1e9, 1e9))
    hi = Vector((-1e9, -1e9, -1e9))
    for obj in objects:
        if obj.type != "MESH":
            continue
        for corner in obj.bound_box:
            world = obj.matrix_world @ Vector(corner)
            lo = Vector((min(lo[i], world[i]) for i in range(3)))
            hi = Vector((max(hi[i], world[i]) for i in range(3)))
    return lo, hi


def ground_and_centre(objects: list[bpy.types.Object], anchor: list[bpy.types.Object] | None = None) -> None:
    """Sit the asset on z=0 and centre it in x/y.

    ``anchor`` restricts the centring to the geometry a state set shares, which
    is what keeps an opened lid or a debris skirt from shifting the whole object
    sideways the moment gameplay swaps the mesh (the A-005 rule).
    """
    lo, hi = world_bounds(anchor or objects)
    offset = Vector(((lo.x + hi.x) * 0.5, (lo.y + hi.y) * 0.5, lo.z))
    for obj in objects:
        if obj.parent is None:
            obj.location -= offset


def eevee_engine() -> str:
    items = bpy.types.RenderSettings.bl_rna.properties["engine"].enum_items.keys()
    for candidate in ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE"):
        if candidate in items:
            return candidate
    return items[0]
