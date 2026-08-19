"""A-012 — food, tonics and the containers they come in.

  /Applications/Blender.app/Contents/MacOS/Blender --background --python tools/blender/build_food_set.py

Thirteen assets in `assets/food/`, built with Blender 5.2.0 LTS (D-038 pins the toolchain).

The container is the constant; the contents are the identity
------------------------------------------------------------
Nine of the thirteen come off three frames. Five tonics are ONE fired flask, two stews are ONE
turned bowl, and the raw and cooked fish are ONE fish. That is not a shortcut — it is what makes a
consumable kit readable. A player learns three silhouettes instead of thirteen, and then reads the
*colour* to know what a thing does: warm red heals, pale cleanses, amber is stamina, and the olive
one is a mistake. Learning "flask means drink" once pays off for every tonic this game ever adds.

It also makes the batch honest under measurement. Sharing a frame is a claim, so `check()` asserts
that the five flasks and the two stews measure **identically** — not similarly — and the fish pair
with them. A-011 paid for that rule twice over: its state pair drifted 27.6 mm because each state was
sized to its own bounds, and its "near-identical" poison bush came out 79 mm wider than the safe one
because a shared *recipe* is not a shared *frame*. Same numbers, or it is a different object.

Every difference between siblings therefore costs zero geometry. A tonic's colour is
`paint_faces()` on the flask's shoulder plus its wax collar; a cooked fish is the raw fish with char
painted on its upward faces; the healing stew is the hearty stew's bowl with a herbal sheen on the
broth. This is the technique A-011's poison bush established, applied to a whole family.

**Opaque clay, visible contents.** A fired flask cannot show what is inside it, so the tell is a
glazed shoulder and a wax collar in the tonic's own colour rather than a liquid nobody can see. It
reads at inventory-icon size, which is where most of these are actually identified.

Sizes are true: a loaf is 0.24 m, a flask 0.23 m, a fish 0.34 m. `READABILITY_FLOOR_M` is not in
play — food is hand-sized, not coin-sized — so nothing here is inflated to be seen.
"""

from __future__ import annotations

import json
import math
import random
import sys
from pathlib import Path
from typing import Callable

import bpy
from mathutils import Vector

sys.path.append(str(Path(__file__).resolve().parent))

from mire_art import (  # noqa: E402
    Batch, box, cone, cylinder_between, eevee_engine, ground_and_centre, hull, look_at,
    mat, paint_faces, radial, reset_materials, tapered_between, world_bounds,
)
from godot_import_lock import import_cache_guard  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
EXPORT_DIR = ROOT / "assets" / "food" / "exports"
PREVIEW_DIR = ROOT / "assets" / "food" / "preview"
CATALOG_PATH = ROOT / "assets" / "food" / "catalog.json"
SOURCE_DIR = ROOT / "assets" / "source"
SOURCE_PATH = SOURCE_DIR / "food_set.blend"

#: Target size in metres, the axis it governs, and a hard footprint ceiling.
#: Hand-sized, all of it: set against a 1.80 m player, a 0.23 m flask is a flask.
SIZE: dict[str, tuple[float, str, float]] = {
    "cooked_meat": (0.26, "spread", 0.30),
    "raw_fish": (0.34, "spread", 0.38),
    "cooked_fish": (0.34, "spread", 0.38),
    "bog_loaf": (0.24, "spread", 0.28),
    "hearty_stew": (0.21, "spread", 0.24),
    "healing_stew": (0.21, "spread", 0.24),
    "meat_skewer": (0.40, "spread", 0.44),
    "honey_jar": (0.19, "height", 0.17),
    "fired_flask": (0.23, "height", 0.17),
    "healing_draught": (0.23, "height", 0.17),
    "pale_draught": (0.23, "height", 0.17),
    "stamina_tonic": (0.23, "height", 0.17),
    "suspicious_sludge": (0.23, "height", 0.17),
}

SIZE_TOLERANCE = 0.02

#: Where each asset stands, once, forever: (x, row_y). Sheets are rows, and a
#: sheet is rendered by pointing the camera at a row and hiding the others.
#:
#: Assets are NOT repositioned per sheet. Moving them and re-rendering in one
#: background process does not work — the render kept drawing the layout as it
#: was when the scene was first evaluated, so a sheet came out framing empty
#: ground while every object involved probed as visible and correctly placed.
#: Camera moves and `hide_render` toggles do take effect; object transforms
#: assigned after the first render do not. Place once, then only ever hide and
#: aim. (F-094's lesson at the end of the pipe.)
LAYOUT: dict[str, tuple[float, float]] = {
    "cooked_meat": (-1.24, 0.0), "raw_fish": (-0.62, 0.0), "cooked_fish": (0.0, 0.0),
    "bog_loaf": (0.62, 0.0), "meat_skewer": (1.24, 0.0),
    "hearty_stew": (-0.42, 3.0), "healing_stew": (0.0, 3.0), "honey_jar": (0.42, 3.0),
    "fired_flask": (-0.62, 6.0), "healing_draught": (-0.31, 6.0), "pale_draught": (0.0, 6.0),
    "stamina_tonic": (0.31, 6.0), "suspicious_sludge": (0.62, 6.0),
}

#: filename -> (row_y, half_width, the assets on it). Ortho scale is authored
#: rather than derived, so a sheet frames what it says it frames.
SHEETS: list[tuple[str, float, float, tuple[str, ...]]] = [
    ("food_cooked_preview.png", 0.0, 1.90,
     ("cooked_meat", "raw_fish", "cooked_fish", "bog_loaf", "meat_skewer")),
    ("food_vessels_preview.png", 3.0, 0.80,
     ("hearty_stew", "healing_stew", "honey_jar")),
    ("food_tonics_preview.png", 6.0, 1.05,
     ("fired_flask", "healing_draught", "pale_draught", "stamina_tonic", "suspicious_sludge")),
]

#: Small objects seen close up and in quantity, and props still have no LOD (F-144).
TRIANGLE_BUDGET = 560
MAX_MATERIALS = 4
#: Per-asset exceptions, each buying something specific. The healing stew spends a
#: fifth material on the pale herbal sheen that is the ONLY thing separating it
#: from the hearty stew at a glance — the same trade A-011's poison bush made.
MATERIAL_ALLOWANCE = {"healing_stew": 5}

#: The three shared frames. `create_asset` centres and SCALES each sibling on the
#: geometry named here and nothing else, so a garnish cannot resize a bowl and a
#: wax collar cannot resize a flask.
FRAMES: dict[str, tuple[str, ...]] = {
    "fired_flask": ("flask_",), "healing_draught": ("flask_",), "pale_draught": ("flask_",),
    "stamina_tonic": ("flask_",), "suspicious_sludge": ("flask_",),
    "hearty_stew": ("bowl_",), "healing_stew": ("bowl_",),
    "raw_fish": ("fish_",), "cooked_fish": ("fish_",),
}

#: Sibling groups that must measure identically. This is the batch's whole claim.
SIBLINGS: dict[str, tuple[str, ...]] = {
    "flask": ("fired_flask", "healing_draught", "pale_draught", "stamina_tonic", "suspicious_sludge"),
    "bowl": ("hearty_stew", "healing_stew"),
    "fish": ("raw_fish", "cooked_fish"),
}

#: One seed per FRAME, not per asset. A-011's lesson in one line: siblings that
#: derive a seed from their own name are not siblings, they are cousins.
FRAME_SEED = {"flask": 4111, "bowl": 2207, "fish": 6803}


def seed_for(name: str) -> int:
    """Stable per asset. Not `hash()`, which is salted per process and would make
    every rebuild a different object."""
    return sum((index + 3) * ord(char) for index, char in enumerate(name))


# ---------------------------------------------------------------------------
# The three shared frames
# ---------------------------------------------------------------------------


def flask_frame() -> list:
    """A fired clay flask: belly, shoulder, neck, lip, cork, collar, cord.

    Every part is prefixed `flask_` and every number is a literal, so the five
    tonics are the same object five times rather than five runs of one recipe.
    The collar exists in all five — an empty flask wears a plain wax one — because
    a part that appears only on some siblings changes their bounds, and then the
    "they measure identically" claim is false by construction.
    """
    seed = FRAME_SEED["flask"]
    body = hull("flask_body", (0.0, 0.0, 0.082), (0.058, 0.058, 0.082), mat("clay"),
                seed=seed, lumps=5, lump=0.09, sharpness=3.4, taper=0.30, flat_base=0.30)
    made = [body]
    made.append(tapered_between("flask_neck", (0.0, 0.0, 0.146), (0.0, 0.0, 0.196),
                                0.026, 0.021, mat("clay"), 8))
    made.append(cone("flask_lip", 0.028, 0.026, 0.014, (0.0, 0.0, 0.201), mat("clay"), 8))
    made.append(cone("flask_cork", 0.019, 0.017, 0.030, (0.0, 0.0, 0.216), mat("wood_timber"), 7))
    # The collar sits INSIDE the lip's silhouette, so swapping its material can
    # never move a sibling's bounds by a single vertex.
    made.append(cone("flask_collar", 0.027, 0.024, 0.016, (0.0, 0.0, 0.196), mat("wax"), 8))
    for index, height in enumerate((0.126, 0.114)):
        made.append(cone(f"flask_cord_{index}", 0.047, 0.047, 0.004,
                         (0.0, 0.0, height), mat("rope"), 8))
    return made


def bowl_frame() -> list:
    """A turned wooden bowl on a small foot. Wide and shallow, because a deep bowl
    hides its own contents at every angle a player ever sees it from."""
    seed = FRAME_SEED["bowl"]
    made = [cone("bowl_foot", 0.046, 0.058, 0.020, (0.0, 0.0, 0.010), mat("wood_timber"), 10)]
    made.append(hull("bowl_body", (0.0, 0.0, 0.058), (0.092, 0.092, 0.040), mat("wood_timber"),
                     seed=seed, lumps=4, lump=0.05, sharpness=4.0, taper=-0.38, flat_base=0.30))
    made.append(cone("bowl_rim", 0.096, 0.090, 0.011, (0.0, 0.0, 0.094), mat("wood_timber"), 12))
    return made


def fish_frame() -> list:
    """A bog fish, built pale and darkened on top rather than the other way round.

    `paint_faces` selects faces ABOVE a normal threshold, so a dark back over a
    pale belly is one paint pass on a pale body — and a cooked fish is then the
    same body with char painted where the scales were (A-011's onion trick).
    """
    seed = FRAME_SEED["fish"]
    body = hull("fish_body", (0.0, 0.0, 0.042), (0.132, 0.042, 0.042), mat("fish_belly"),
                seed=seed, lumps=5, lump=0.10, sharpness=3.0, taper=0.24)
    made = [body]
    made.append(tapered_between("fish_peduncle", (-0.140, 0.0, 0.042), (-0.176, 0.0, 0.042),
                                0.017, 0.009, mat("fish_belly"), 6))
    batch = Batch()
    # A forked tail: two lobes off the peduncle with a notch between them. One
    # triangle is a paddle, and a paddle reads as a leaf.
    for lobe in (1, -1):
        batch.add("fish_belly",
                  [(-0.176, 0.0, 0.042), (-0.226, 0.0, 0.042 + lobe * 0.052),
                   (-0.198, 0.0, 0.042 + lobe * 0.012)],
                  [(0, 1, 2)])
    # Pectoral fins, small: a fin as wide as the fish is a wing. The first cut
    # spread them 0.156 m on a body 0.084 m thick and the asset read as a kite.
    for side in (-1, 1):
        batch.add("fish_belly",
                  [(0.012, side * 0.022, 0.032), (-0.034, side * 0.046, 0.020),
                   (-0.036, side * 0.020, 0.030)],
                  [(0, 1, 2)])
    # Dorsal, low and swept back.
    batch.add("fish_belly",
              [(0.022, 0.0, 0.072), (-0.030, 0.0, 0.098), (-0.056, 0.0, 0.066)],
              [(0, 1, 2)])
    batch.emit("fish_fin")
    for side in (-1, 1):
        index = 1 if side > 0 else 0
        made.append(cone(f"fish_eye_{index}", 0.010, 0.008, 0.006,
                         (0.104, side * 0.026, 0.054), mat("coal"), 6,
                         (0.0, math.pi * 0.5, 0.0)))
    return made


# ---------------------------------------------------------------------------
# The thirteen
# ---------------------------------------------------------------------------


def tonic(seal_token: str, shoulder_token: str | None) -> None:
    """One filled flask. The frame is identical in all five; the tell is a wax
    collar in the tonic's colour and a glaze over the flask's shoulder, and
    neither costs a single triangle."""
    flask_frame()
    collar = bpy.data.objects["flask_collar"]
    collar.data.materials.clear()
    collar.data.materials.append(mat(seal_token))
    if shoulder_token is not None:
        body = bpy.data.objects["flask_body"]
        # min_normal_z below -1 takes every face, so the selection is purely by
        # height: a glazed shoulder rather than a lid.
        paint_faces(body, mat(shoulder_token), min_normal_z=-1.1, min_height=0.62,
                    coverage=1.0, seed=FRAME_SEED["flask"])


def build_fired_flask(_seed: int) -> None:
    """Empty, corked, plain wax. `ITEMS.md` §9 cut thirst, and said this asset
    becomes the Fired Flask that every tonic is made in — so it ships as the
    container, not as a water bottle."""
    tonic("wax", None)


def build_healing_draught(_seed: int) -> None:
    tonic("tonic_red", "tonic_red")


def build_pale_draught(_seed: int) -> None:
    tonic("tonic_pale", "tonic_pale")


def build_stamina_tonic(_seed: int) -> None:
    tonic("tonic_amber", "tonic_amber")


def build_suspicious_sludge(_seed: int) -> None:
    """The joke is the colour and the description, never a different flask — a
    player has to be able to mistake it for a real tonic at a glance, or it is
    not funny and it is not a risk (D7)."""
    tonic("sludge", "sludge")


def stew(garnish: str, sheen: str | None, seed: int) -> None:
    """A bowl of stew. The bowl is the frame; the broth surface sits at the rim
    and the garnish is what the player actually reads."""
    bowl_frame()
    rng = random.Random(seed)
    surface = hull("stew_broth", (0.0, 0.0, 0.080), (0.083, 0.083, 0.016), mat("broth"),
                   seed=seed, lumps=4, lump=0.06, sharpness=4.0, flat_base=0.60)
    if sheen is not None:
        paint_faces(surface, mat(sheen), min_normal_z=0.20, min_height=0.40,
                    coverage=0.62, seed=seed + 5)
    batch = Batch()
    for angle, radius in radial(5, 0.048, seed=seed + 11, jitter=0.6, radius_jitter=0.4):
        # Chunks stand proud of the lip. A stew whose contents sit below the rim
        # is a bowl of nothing from every angle except straight down.
        batch.blob(garnish,
                   (math.cos(angle) * abs(radius) * 0.82, math.sin(angle) * abs(radius) * 0.82,
                    0.098 + rng.uniform(-0.003, 0.012)),
                   (rng.uniform(0.017, 0.025), rng.uniform(0.016, 0.023),
                    rng.uniform(0.010, 0.016)), rng)
    batch.emit("stew_bit")


def build_hearty_stew(_seed: int) -> None:
    """Meat, onion, mushroom — the group-cook payoff. Chunks you can see."""
    stew("flesh_cooked", None, FRAME_SEED["bowl"])


def build_healing_stew(_seed: int) -> None:
    """The big heal-feed. Same bowl, same broth, herbs instead of chunks and a
    pale sheen on the surface — the fifth material this batch allows, spent on
    the only thing that tells the two stews apart in a hotbar."""
    stew("moss", "tonic_pale", FRAME_SEED["bowl"])


def build_raw_fish(_seed: int) -> None:
    """Pale body, dark back. The back is painted, so the cooked sibling is the
    same geometry with a different pass."""
    fish_frame()
    paint_faces(bpy.data.objects["fish_body"], mat("fish_scale"), min_normal_z=0.05,
                min_height=0.34, coverage=1.0, seed=FRAME_SEED["fish"])


def build_cooked_fish(_seed: int) -> None:
    """Off the fire: the scales are gone and the char is patchy, because a fish
    grilled to an even colour is a fish nobody cooked."""
    fish_frame()
    paint_faces(bpy.data.objects["fish_body"], mat("flesh_charred"), min_normal_z=0.05,
                min_height=0.30, coverage=0.55, seed=FRAME_SEED["fish"] + 3)


def build_cooked_meat(seed: int) -> None:
    """A cut on the bone, seared on top. The bone is what makes it read as meat
    rather than as a rock at three metres."""
    rng = random.Random(seed)
    cut = hull("meat_cut", (0.0, 0.0, 0.048), (0.092, 0.070, 0.048), mat("flesh_cooked"),
               seed=seed, lumps=6, lump=0.16, sharpness=2.6, flat_base=0.24)
    paint_faces(cut, mat("flesh_charred"), min_normal_z=0.28, min_height=0.52,
                coverage=0.70, seed=seed + 2)
    cylinder_between("meat_bone", (0.058, -0.012, 0.030), (0.132, -0.026, 0.052),
                     0.014, mat("bone"), 7, 0.90)
    cone("meat_bone_knuckle", 0.020, 0.016, 0.020, (0.136, -0.027, 0.054), mat("bone"), 7,
         (0.0, math.pi * 0.42, 0.0))
    batch = Batch()
    for angle, radius in radial(3, 0.052, seed=seed + 7, jitter=0.7, radius_jitter=0.3):
        batch.blob("flesh_charred",
                   (math.cos(angle) * abs(radius), math.sin(angle) * abs(radius),
                    0.086 + rng.uniform(-0.006, 0.006)),
                   (0.016, 0.013, 0.006), rng)
    batch.emit("meat_sear")


def build_bog_loaf(seed: int) -> None:
    """Cattail flour is real bread; the name is ours (D7). Torn at one end, so the
    crumb shows and the loaf is not a brown pebble."""
    rng = random.Random(seed)
    loaf = hull("loaf_body", (0.0, 0.0, 0.058), (0.108, 0.074, 0.058), mat("bread_crust"),
                seed=seed, lumps=5, lump=0.11, sharpness=3.0, taper=0.16, flat_base=0.30)
    made_crumb = hull("loaf_crumb", (-0.086, 0.0, 0.054), (0.030, 0.058, 0.048),
                      mat("bread_crumb"), seed=seed + 4, lumps=6, lump=0.22, sharpness=2.2)
    paint_faces(made_crumb, mat("bread_crust"), min_normal_z=0.30, min_height=0.72,
                coverage=0.55, seed=seed + 6)
    batch = Batch()
    # Slashes across the crown: three cuts a baker made, in the colour of what is
    # under the crust.
    for index in range(3):
        x = -0.030 + index * 0.038
        batch.add("bread_crumb",
                  [(x - 0.010, -0.030, 0.104), (x + 0.010, -0.028, 0.104),
                   (x + 0.014, 0.030, 0.100), (x - 0.006, 0.032, 0.100)],
                  [(0, 1, 2, 3)])
    batch.emit("loaf_slash")
    _ = rng


def build_meat_skewer(seed: int) -> None:
    """Three chunks on a stick. Id `meat_skewer`, never `skewer` — `ITEMS.md` §4.4
    flags the collision with the weapon by name so nobody ships a food you can
    stab with."""
    rng = random.Random(seed)
    tapered_between("skewer_stick", (-0.196, 0.0, 0.020), (0.196, 0.006, 0.024),
                    0.008, 0.004, mat("wood_timber"), 6)
    for index, x in enumerate((-0.086, 0.006, 0.098)):
        chunk = hull(f"skewer_chunk_{index}", (x, 0.002, 0.032), (0.042, 0.036, 0.032),
                     mat("flesh_cooked"), seed=seed + index * 13, lumps=5, lump=0.18,
                     sharpness=2.8, flat_base=0.20)
        paint_faces(chunk, mat("flesh_charred"), min_normal_z=0.20, min_height=0.55,
                    coverage=0.62, seed=seed + index)
    _ = rng


def build_honey_jar(seed: int) -> None:
    """A squat clay jar, waxed shut, with one drip down the side that nobody
    wiped off. The drip is the whole asset: without it this is a pot."""
    rng = random.Random(seed)
    # Narrower than the first cut, which measured 0.177 m across a 0.19 m height —
    # that is a pot. A jar is taller than it is wide, and the footprint cap caught
    # it rather than being raised to accommodate it.
    hull("jar_body", (0.0, 0.0, 0.066), (0.050, 0.050, 0.066), mat("clay"),
         seed=seed, lumps=5, lump=0.07, sharpness=3.6, taper=-0.10, flat_base=0.34)
    cone("jar_neck", 0.038, 0.042, 0.024, (0.0, 0.0, 0.140), mat("clay"), 10)
    cone("jar_seal", 0.044, 0.040, 0.014, (0.0, 0.0, 0.158), mat("wax"), 10)
    cone("jar_tie", 0.046, 0.046, 0.008, (0.0, 0.0, 0.140), mat("rope"), 10)
    batch = Batch()
    run = [Vector((0.038, 0.015, 0.150)), Vector((0.045, 0.017, 0.104)),
           Vector((0.043, 0.016, 0.062)), Vector((0.040, 0.014, 0.034))]
    batch.ribbon("honey", run, [0.010, 0.013, 0.011, 0.007], [0.004, 0.006, 0.005, 0.003])
    batch.blob("honey", (0.049, 0.017, 0.028), (0.013, 0.011, 0.009), rng)
    batch.emit("jar_drip")


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
    # Bake the rotation in. `join` hands the result whichever rotation the
    # alphabetically-first component carried, and the exporter then writes it as a
    # node transform on top of the geometry — which put A-011's resin node 53 mm
    # underground when measured from mesh data. A static prop ships no rotation.
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

    # Centre AND scale on the shared frame where there is one. Centring alone is
    # not enough: sizing each sibling to its own total bounds gives them different
    # scale factors, which silently rescales the frame they are supposed to have
    # in common — A-011 paid 27.6 mm to learn that.
    prefixes = FRAMES.get(name)
    anchor = [obj for obj in made if obj.name.startswith(prefixes)] if prefixes else None
    anchor = anchor or None
    ground_and_centre(made, anchor=anchor)

    target, axis, _cap = SIZE[name]
    measured_on = anchor or made
    low, high = world_bounds(measured_on)
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
    ground_and_centre(made, anchor=anchor)
    glow, ghigh = world_bounds(measured_on)
    governed = (ghigh.z - glow.z) if axis == "height" else max(ghigh.x - glow.x, ghigh.y - glow.y)

    frame_bounds = None
    if anchor:
        alow, ahigh = world_bounds(anchor)
        frame_bounds = tuple(round(value, 6) for value in (*alow, *ahigh))

    made = [join_into_one(name, made)]
    for obj in made:
        for old in list(obj.users_collection):
            old.objects.unlink(obj)
        collection.objects.link(obj)
        obj.parent = root
    bpy.context.view_layer.update()

    adrift = floating_islands(made)
    # Vertices, never `obj.bound_box`: the cached box is stale after a join.
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
    materials = sorted({m.name for obj in made if obj.type == "MESH"
                        for m in obj.data.materials if m})

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
        "frame_bounds": frame_bounds, "governed": governed,
        "parts": sum(1 for obj in made if obj.type == "MESH"),
        "polygons": polygons, "triangles": triangles, "materials": materials,
    }


def check(records: list[dict]) -> list[str]:
    """Everything a machine can judge about this batch, judged — and failed on."""
    problems: list[str] = []
    by_name = {record["name"]: record for record in records}
    for record in records:
        name = record["name"]
        target, axis, cap = SIZE[name]
        if abs(record["governed"] - target) > SIZE_TOLERANCE:
            problems.append(f"{name}: {axis} {record['governed']:.3f} m vs target {target:.3f} m")
        spread = max(record["width"], record["depth"])
        if spread > cap:
            problems.append(f"{name}: {spread:.3f} m across, footprint cap is {cap} m")
        if abs(record["ground_offset"]) > 0.005:
            problems.append(f"{name}: sits {record['ground_offset'] * 1000:.1f} mm off the ground")
        if record["adrift"]:
            problems.append(f"{name}: floating geometry: {record['adrift'][:3]}")
        if record["parts"] == 0 or record["polygons"] == 0:
            problems.append(f"{name}: exported no geometry")
        if record["triangles"] > TRIANGLE_BUDGET:
            problems.append(f"{name}: {record['triangles']} triangles over the {TRIANGLE_BUDGET} budget")
        allowance = MATERIAL_ALLOWANCE.get(name, MAX_MATERIALS)
        if len(record["materials"]) > allowance:
            problems.append(f"{name}: {len(record['materials'])} materials, cap is {allowance}")
        if not record["materials"]:
            problems.append(f"{name}: no embedded materials")
        if not (EXPORT_DIR / f"{name}.glb").exists():
            problems.append(f"{name}: no GLB written")

    # The batch's whole claim: siblings are the SAME object, not similar ones.
    # Bounds AND triangle count, because a difference in either means the frame
    # was rebuilt rather than shared — and a shared frame is what lets gameplay
    # swap a raw fish for a cooked one without the mesh jumping.
    for family, names in SIBLINGS.items():
        present = [by_name[n] for n in names if n in by_name]
        if len(present) != len(names):
            problems.append(f"{family}: only {len(present)} of {len(names)} siblings built")
            continue
        reference = present[0]
        for record in present[1:]:
            drift = max(
                abs(record["width"] - reference["width"]),
                abs(record["depth"] - reference["depth"]),
                abs(record["height"] - reference["height"]),
            )
            if drift > 1e-5:
                problems.append(
                    f"{family}: {record['name']} drifts {drift * 1000:.3f} mm from {reference['name']}"
                )
            if record["frame_bounds"] != reference["frame_bounds"]:
                problems.append(
                    f"{family}: {record['name']}'s frame is not {reference['name']}'s frame"
                )
            if record["triangles"] != reference["triangles"]:
                problems.append(
                    f"{family}: {record['name']} has {record['triangles']} triangles, "
                    f"{reference['name']} has {reference['triangles']} — a sibling that costs "
                    f"more geometry is a different object"
                )
    return problems


def sibling_drift(records: list[dict]) -> float:
    by_name = {record["name"]: record for record in records}
    worst = 0.0
    for names in SIBLINGS.values():
        present = [by_name[n] for n in names if n in by_name]
        if len(present) < 2:
            continue
        reference = present[0]
        for record in present[1:]:
            worst = max(worst, abs(record["width"] - reference["width"]),
                        abs(record["depth"] - reference["depth"]),
                        abs(record["height"] - reference["height"]))
    return worst


SPECS: list[tuple[str, Callable[[int], None]]] = [
    ("cooked_meat", build_cooked_meat),
    ("raw_fish", build_raw_fish),
    ("cooked_fish", build_cooked_fish),
    ("bog_loaf", build_bog_loaf),
    ("meat_skewer", build_meat_skewer),
    ("hearty_stew", build_hearty_stew),
    ("healing_stew", build_healing_stew),
    ("honey_jar", build_honey_jar),
    ("fired_flask", build_fired_flask),
    ("healing_draught", build_healing_draught),
    ("pale_draught", build_pale_draught),
    ("stamina_tonic", build_stamina_tonic),
    ("suspicious_sludge", build_suspicious_sludge),
]


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
        raise RuntimeError("food asset names must be unique")
    for name, _ in SPECS:
        if name not in SIZE:
            raise RuntimeError(f"{name} has no SIZE entry")

    records: list[dict] = []
    for name, builder in SPECS:
        x, row_y = LAYOUT[name]
        records.append(create_asset(name, builder, (x, row_y, 0.0)))

    problems = check(records)

    CATALOG_PATH.write_text(json.dumps({
        "batch": "A-012",
        "family": "food",
        "blender": bpy.app.version_string,
        "frames": {family: list(names) for family, names in SIBLINGS.items()},
        "assets": [
            {
                "name": r["name"], "file": f"exports/{r['name']}.glb",
                "width_m": round(r["width"], 4), "depth_m": round(r["depth"], 4),
                "height_m": round(r["height"], 4), "target_m": r["target"], "axis": r["axis"],
                "frame": next((f for f, n in SIBLINGS.items() if r["name"] in n), None),
                "parts": r["parts"], "polygons": r["polygons"], "triangles": r["triangles"],
                "materials": r["materials"],
            }
            for r in records
        ],
    }, indent=2) + "\n")

    # -- previews ----------------------------------------------------------
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
    for light in (key, fill):
        for old in list(light.users_collection):
            old.objects.unlink(light)
        preview_collection.objects.link(light)

    bpy.ops.object.camera_add()
    camera = bpy.context.object
    camera.name = "Preview_Camera"
    scene = bpy.context.scene
    scene.camera = camera
    scene.render.engine = eevee_engine()
    scene.render.resolution_x = 1800
    scene.render.image_settings.file_format = "PNG"
    scene.render.film_transparent = False
    scene.world.color = (0.016, 0.021, 0.028)
    scene.view_settings.look = "AgX - Medium High Contrast"
    for old in list(camera.users_collection):
        old.objects.unlink(camera)
    preview_collection.objects.link(camera)

    # A 0.90 m half-height reference block: food is hand-sized, so a full 1.80 m
    # figure beside a flask renders the flask as a speck. This is a forearm's
    # reach of a standing player — the distance these are actually judged at.
    bpy.ops.mesh.primitive_cube_add(location=(0, 0, 0.16))
    figure = bpy.context.object
    figure.name = "Scale_Reference"
    figure.scale = (0.045, 0.045, 0.16)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    figure.data.materials.append(mat("reference_blue"))
    for old in list(figure.users_collection):
        old.objects.unlink(figure)
    preview_collection.objects.link(figure)

    def set_visible(record: dict, visible: bool) -> None:
        record["root"].hide_render = not visible
        for child in record["root"].children_recursive:
            child.hide_render = not visible

    by_name = {record["name"]: record for record in records}
    camera.data.type = "ORTHO"
    scene.render.resolution_y = 620

    def sheet(filename: str, row_y: float, half_width: float, names: tuple[str, ...]) -> None:
        for record in records:
            set_visible(record, record["name"] in names)
        left = -half_width
        figure.location = (left + 0.16, row_y, 0.16)
        camera.data.type = "ORTHO"
        camera.data.ortho_scale = half_width * 2.0
        camera.location = (0.0, row_y - 6.0, 0.42)
        look_at(camera, (0.0, row_y, 0.14))
        scene.render.filepath = str(PREVIEW_DIR / filename)
        bpy.ops.render.render(write_still=True)

    for filename, row_y, half_width, names in SHEETS:
        sheet(filename, row_y, half_width, names)

    for record in records:
        set_visible(record, True)
    bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE_PATH))

    print(f"\nFOOD_BUILD assets={len(records)} "
          f"triangles={sum(r['triangles'] for r in records)} blender={bpy.app.version_string}")
    for record in records:
        print("  %-20s %5.3f x %5.3f x %5.3f m  %4d tris  %d mats  %s"
              % (record["name"], record["width"], record["depth"], record["height"],
                 record["triangles"], len(record["materials"]),
                 ",".join(m.replace("MIRE_", "") for m in record["materials"])))
    print("  worst sibling drift: %.4f mm" % (sibling_drift(records) * 1000.0))
    if problems:
        print(f"\nFOOD_CHECK FAIL ({len(problems)})")
        for problem in problems:
            print(f"  {problem}")
        raise SystemExit(1)
    print("FOOD_CHECK PASS")


if __name__ == "__main__":
    with import_cache_guard(Path(__file__).name):
        main()
