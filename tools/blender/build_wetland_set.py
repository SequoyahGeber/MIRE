"""A-043 — wetland gatherables II: the mere's own harvest.

  /Applications/Blender.app/Contents/MacOS/Blender --background --python tools/blender/build_wetland_set.py

Built with Blender 5.2.0 LTS (D-038 pins the toolchain). Outputs to `assets/wetland/`.

A second kit rather than an extension of `assets/gatherables/` (A-011), because extending that one
means re-running its generator and re-exporting ten already-shipped, already-audited GLBs to add
files that share nothing with them but a theme. `environment` and `environment_additions` set the
same precedent.

**Scope.** `ITEMS.md` §4.1 and the tracker's A-043 row list seven, two of which already exist and
are deliberately not rebuilt here: `poison_berry_bush` shipped in A-011, and `raw_fish` shipped in
A-012 as half of that kit's one-fish frame. Making either again would be two objects for one item.

**What separates a node from scenery.** The flora kit already has `reeds_a`..`reeds_d` and
`moss_patch_a`..`moss_patch_d`, and they are scatter — you walk past them. These are the ones you
walk *to*. A gatherable has to out-read its decorative neighbour standing next to it, so each one
here carries something scenery never does: a bundle is tied, a bed is dense enough to be worth a
trip, a moss clump is domed and wet rather than flat, a shoal moves as one body.
"""

from __future__ import annotations

import json
import math
import random
import sys
from pathlib import Path
from typing import Callable

import bpy
from mathutils import Matrix, Vector

sys.path.append(str(Path(__file__).resolve().parent))

from mire_art import (  # noqa: E402
    Batch,
    cone,
    cylinder_between,
    eevee_engine,
    ground_and_centre,
    hull,
    look_at,
    mat,
    paint_faces,
    radial,
    reset_materials,
    tapered_between,
    world_bounds,
)

ROOT = Path(__file__).resolve().parents[2]
EXPORT_DIR = ROOT / "assets" / "wetland" / "exports"
PREVIEW_DIR = ROOT / "assets" / "wetland" / "preview"
CATALOG_PATH = ROOT / "assets" / "wetland" / "catalog.json"
SOURCE_DIR = ROOT / "assets" / "source"
SOURCE_PATH = SOURCE_DIR / "wetland_set.blend"

#: Target size in metres, the axis it governs, and a hard footprint ceiling.
#: Set against a 1.80 m player: shin 0.2, knee 0.5, waist 1.0, chest 1.4.
SIZE: dict[str, tuple[float, str, float]] = {
    "cattail_bundle": (0.80, "spread", 0.84),
    "reed_bed": (1.55, "height", 1.32),
    "sphagnum_moss": (0.62, "spread", 0.66),
    "fish_shoal": (0.98, "spread", 1.04),
    "glowcap_mushroom": (0.32, "height", 0.36),
}

#: Assets that are laid over before grounding, as radians about world Y.
#:
#: `cattail_bundle` is a PICKUP and `reed_bed` is the growing node it comes from,
#: and they are made of the same parts. Standing the bundle up gives the two of
#: them the same silhouette, and a player looking across a mere then cannot tell
#: the thing they can carry from the thing they have to harvest. Laying it down
#: separates them at any distance and costs nothing — it is also simply what a cut
#: sheaf does when you put it on the ground.
LIE_DOWN: dict[str, float] = {
    "cattail_bundle": math.radians(84.0),
}

SIZE_TOLERANCE = 0.02
TRIANGLE_BUDGET = 900
#: Per-asset exceptions, each with a reason. The budget is a pickup's budget; a
#: node a player walks INTO is a different object. `ASSET_TRACKER.md` allows
#: 50-800 for an ordinary prop and 300-2,000 for a hero one, and a 1.55 m reed bed
#: sits between the two — it is the largest thing in this kit and the only one
#: whose whole job is to look like *a lot* of something.
TRIANGLE_ALLOWANCE = {"reed_bed": 1500}
MAX_MATERIALS = 4
MATERIAL_ALLOWANCE: dict[str, int] = {}


# ---------------------------------------------------------------------------
# Shape recipes
# ---------------------------------------------------------------------------


def blade(batch: Batch, token: str, origin: Vector, angle: float, height: float, width: float,
          lean: float, curve: float) -> None:
    """One upright strap leaf that bends over and tapers out.

    Wide and few beats thin and many: a thin blade stops resolving a few metres
    out and turns the plant into fuzz while costing exactly the same triangles.
    """
    spine = [
        Vector((
            origin.x + math.cos(angle) * lean * height * (t ** 1.7),
            origin.y + math.sin(angle) * lean * height * (t ** 1.7),
            origin.z + height * t - curve * height * (t ** 2.4),
        ))
        for t in (0.0, 0.34, 0.68, 1.0)
    ]
    batch.ribbon(token, spine, [width * 0.5, width * 0.44, width * 0.27, 0.004],
                 [width * 0.34, width * 0.28, width * 0.17, 0.002])


def cattail(made: list, index: int, base: Vector, angle: float, height: float,
            lean: float, seed: int) -> Vector:
    """One cattail: a bare stem with the brown sausage head that names the plant.

    The head is the entire identity of this asset. Everything else about a cattail
    — strap leaves, a green stem — is what the flora kit's reeds already look like,
    so a bundle whose heads do not read is a bundle of grass.
    """
    rng = random.Random(seed)
    top = Vector((
        base.x + math.cos(angle) * lean * height,
        base.y + math.sin(angle) * lean * height,
        base.z + height,
    ))
    stem_top = base + (top - base) * 0.74
    made.append(tapered_between(f"cattail_stem_{index}", base, stem_top, 0.010, 0.007,
                                mat("sedge"), vertices=5))
    # The head sits on the stem's line, not on the vertical, or a leaning cattail
    # ends up with its head floating beside the stalk.
    head_bottom = stem_top
    head_top = base + (top - base) * 1.0
    made.append(tapered_between(f"cattail_head_{index}", head_bottom, head_top, 0.026, 0.021,
                                mat("leather"), vertices=7))
    # The dry spike above the head — short, and the thing that stops a cattail
    # reading as a corn dog.
    spike = head_top + (head_top - head_bottom).normalized() * rng.uniform(0.05, 0.08)
    # Same material as the head it grows out of. A cattail's spike IS the top of
    # the flower spike, and a fifth material on a pickup this small is not worth
    # the draw cost of saying so.
    made.append(tapered_between(f"cattail_spike_{index}", head_top, spike, 0.008, 0.002,
                                mat("leather"), vertices=4))
    return head_top


# ---------------------------------------------------------------------------
# Builders
# ---------------------------------------------------------------------------


def build_cattail_bundle(seed: int) -> None:
    """Cut cattails gathered and tied — the pickup, not the plant.

    `ITEMS.md` §4.1 gives this one item two jobs, food and fibre, so it has to
    read as *harvested material* rather than as a growing plant: cut ends level at
    the bottom, heads fanned at the top, and a fibre tie around the waist. The tie
    is what does the work. Without it this is a clump of reeds standing in the
    ground, which the flora kit already ships four of.
    """
    rng = random.Random(seed)
    made = []
    batch = Batch()
    # Stems rise from a tight cut base and fan outward, the way a tied sheaf does.
    # A tied sheaf is TIGHT at its cut base and fans above the tie. The first cut
    # started the stems on a 0.055 m ring and leaned them outward from there, so by
    # the tie's height the bundle was already 0.115 m across and the tie — sized to
    # the base — sat inside it, rendering as two loose discs floating in the middle
    # of the stalks rather than as anything holding them together.
    for index, (angle, rad) in enumerate(radial(9, 0.014, seed=seed, jitter=0.5,
                                                radius_jitter=0.45)):
        base = Vector((math.cos(angle) * abs(rad), math.sin(angle) * abs(rad), 0.0))
        cattail(made, index, base, angle, rng.uniform(0.62, 0.76),
                rng.uniform(0.015, 0.065), seed + index * 13)
    # A few loose strap leaves tucked into the bundle, so it is not nine parallel sticks.
    for angle, rad in radial(5, 0.028, seed=seed + 5, jitter=0.8, radius_jitter=0.5):
        origin = Vector((math.cos(angle) * abs(rad), math.sin(angle) * abs(rad), 0.01))
        blade(batch, "reed" if rng.random() < 0.5 else "sedge", origin, angle,
              rng.uniform(0.34, 0.52), rng.uniform(0.026, 0.038),
              rng.uniform(0.04, 0.14), rng.uniform(0.10, 0.24))
    batch.emit("cattail_leaves")
    # The tie: two bands of fibre round the waist. Two, because one band reads as
    # a smudge and two reads as deliberate.
    # Radius follows the stems' own spread at that height (base ring + lean x
    # height), plus a little, so the band sits ON the bundle instead of in it.
    for index, height in enumerate((0.13, 0.20)):
        segments = 7
        for step in range(segments):
            a0 = math.tau * step / segments
            a1 = math.tau * (step + 1) / segments
            radius = 0.014 + 0.065 * height + 0.011
            made.append(cylinder_between(
                f"cattail_tie_{index}_{step}",
                (math.cos(a0) * radius, math.sin(a0) * radius, height),
                (math.cos(a1) * radius, math.sin(a1) * radius, height),
                0.011, mat("fibre"), vertices=4))


def build_reed_bed(seed: int) -> None:
    """A stand of cattails in the shallows — the node a bundle is cut from.

    The flora kit already ships `reeds_a`..`reeds_d`, and they are scatter you walk
    past. This has to out-read them while standing next to them, and the thing that
    does it is **density plus heads**: decorative reeds are a handful of blades with
    no flower, so a player scanning a shore is looking for the brown spikes. The bed
    is mostly leaf and only eight flowering stems, which is also how a real one
    looks — every stalk carrying a head reads as a planted crop, not a mere.

    It sits on its own patch of wet mud rather than on nothing, because a reed bed
    growing out of bare terrain reads as a bouquet someone dropped.
    """
    rng = random.Random(seed)
    made = []
    # Wet mud the bed grows out of. Wide and very flat — it is a footing, not a mound.
    mud = hull("reed_mud", (0.0, 0.0, 0.035), (0.38, 0.35, 0.055), mat("peat"), seed=seed,
               lumps=5, lump=0.26, sharpness=2.6, flat_base=0.0)
    paint_faces(mud, mat("sedge"), min_normal_z=0.55, min_height=0.5, coverage=0.35,
                seed=seed + 1)
    made.append(mud)

    # Flowering stems, spread right across the patch rather than ringed around its
    # edge — `radial`'s radius_jitter is what keeps some of them in the middle.
    for index, (angle, rad) in enumerate(radial(8, 0.24, seed=seed + 3, jitter=0.6,
                                                radius_jitter=0.62)):
        base = Vector((math.cos(angle) * abs(rad), math.sin(angle) * abs(rad), 0.045))
        cattail(made, index, base, angle + rng.uniform(-0.7, 0.7),
                rng.uniform(0.95, 1.30), rng.uniform(0.04, 0.12), seed + index * 29)

    # The leaf mass. This is most of what the asset IS, and it is cheap: a strap
    # leaf is a three-segment ribbon.
    batch = Batch()
    for index, (angle, rad) in enumerate(radial(26, 0.26, seed=seed + 7, jitter=0.75,
                                                radius_jitter=0.68)):
        origin = Vector((math.cos(angle) * abs(rad), math.sin(angle) * abs(rad), 0.04))
        blade(batch, ("sedge", "reed", "sedge")[index % 3], origin,
              angle + rng.uniform(-0.9, 0.9), rng.uniform(0.55, 1.05),
              rng.uniform(0.030, 0.052), rng.uniform(0.05, 0.18),
              rng.uniform(0.10, 0.28))
    batch.emit("reed_bed_leaves")


def build_sphagnum_moss(seed: int) -> None:
    """A sphagnum hummock — the moss you can actually take.

    `assets/flora` already ships `moss_patch_a`..`moss_patch_d` and they are flat
    mats pressed to the ground. This has to be distinguishable from one lying next
    to it, and the honest difference is the one sphagnum really has: it grows in a
    raised, spongy **hummock**, domed and lumpy, not a mat. Silhouette does the
    work — a player scanning wet ground is looking for something that stands up.

    The rust is the second tell and it is real: living sphagnum runs from green
    through deep red, and no other ground cover in the game does that. It is
    painted onto the crowns rather than modelled, so it costs nothing.
    """
    rng = random.Random(seed)
    made = []
    # Three overlapping cushions, uneven. One dome reads as a stone; a dozen reads
    # as gravel; three gives the hummock shoulders — the same count A-000V settled
    # on for a bush, for the same reason.
    # Taller than wide-and-flat. The first cut domed only 0.20 m over a 0.62 m
    # spread and read as a green stone with orange spots on it; sphagnum's whole
    # silhouette argument against the flora kit's flat mats is that it STANDS UP.
    cushions = [
        ((0.00, 0.01, 0.150), (0.205, 0.185, 0.150)),
        ((-0.150, -0.070, 0.105), (0.140, 0.130, 0.106)),
        ((0.140, -0.085, 0.092), (0.125, 0.120, 0.094)),
    ]
    for index, (centre, radius) in enumerate(cushions):
        cushion = hull(f"sphagnum_cushion_{index}", centre, radius, mat("moss"),
                       seed=seed + index * 37, lumps=12, lump=0.24, sharpness=1.7,
                       flat_base=0.0)
        # Sun-caught crown. `paint_faces` selects faces ABOVE a normal threshold,
        # so it lights a crown; it cannot shade an underside, and passing a negative
        # threshold to mean "the bottom" just scatters the material over the whole
        # object at random (A-011 shipped a bush that looked diseased that way).
        paint_faces(cushion, mat("moss_light"), min_normal_z=0.42, min_height=0.55,
                    coverage=0.55, seed=seed + index)
        # A blush on the very crowns, not a spotted pattern. Sphagnum reddens where
        # the light hits it hardest, and at 0.40 coverage over a low threshold this
        # read as orange stickers on a rock.
        paint_faces(cushion, mat("flower_rust"), min_normal_z=0.68, min_height=0.80,
                    coverage=0.30, seed=seed + 90 + index)
        made.append(cushion)

    # Fine strands standing off the crowns, so the hummock has a soft edge against
    # the ground instead of reading as a painted rock.
    batch = Batch()
    for index, (angle, rad) in enumerate(radial(22, 0.235, seed=seed + 5, jitter=0.85,
                                                radius_jitter=0.55)):
        origin = Vector((math.cos(angle) * abs(rad), math.sin(angle) * abs(rad),
                         rng.uniform(0.04, 0.16)))
        blade(batch, "moss_light" if index % 3 else "moss", origin,
              angle + rng.uniform(-1.0, 1.0), rng.uniform(0.07, 0.15),
              rng.uniform(0.014, 0.024), rng.uniform(0.35, 0.80),
              rng.uniform(0.30, 0.60))
    batch.emit("sphagnum_strands")


def build_fish_shoal(seed: int) -> None:
    """Fish holding in the shallows — the node you fish, not a dropped fish.

    The read is **coherence**. Seven fish pointing seven ways is litter on a pond;
    seven fish pointing the same way with one or two off-heading is a shoal, and a
    player recognises that shape without being told what it is. So every fish here
    shares one heading with only a few degrees of scatter, and they are spaced
    along that heading rather than around a ring.

    It carries its own patch of water. Terrain is procedural (there is no authored
    pond to sit this in), and a shoal rendered as fish lying on mud reads as a
    catch someone left out — the water is what makes them *alive and gettable*.
    They break the surface at the back, because a fish fully under an opaque disc
    is a fish nobody can see.
    """
    rng = random.Random(seed)
    made = []
    # The pool. Very flat and slightly irregular — a puddle, not a dinner plate.
    #
    # Peat-stained brown, not `clear_liquid`. Two reasons and either is sufficient:
    # `clear_liquid` renders teal, and teal is reserved for the Ward the way purple
    # is reserved for the Mire — `ASSET_TRACKER.md` says not to spend either on
    # decoration, and a fish pond is decoration. It is also just wrong for the
    # setting: water in a peat wetland is brown, and blue water in MIRE would read
    # as somewhere else entirely. Silver fish on dark water is the better contrast.
    water = hull("shoal_water", (0.0, 0.0, 0.022), (0.44, 0.36, 0.026),
                 mat("peat"), seed=seed, lumps=7, lump=0.20, sharpness=2.4,
                 flat_base=0.0)
    made.append(water)

    heading = rng.uniform(0.0, math.tau)
    batch = Batch()
    for index in range(7):
        # Spaced ALONG the heading with a small lateral offset, which is how a
        # shoal actually occupies water — a ring of fish reads as a decoration.
        # An oval cluster, not a queue. Spacing them along the heading alone put
        # all seven on one line, and from the side perpendicular to it they stacked
        # up behind each other and rendered as two grey lumps.
        along = (index - 3) * 0.068 + rng.uniform(-0.020, 0.020)
        across = rng.uniform(-0.155, 0.155)
        centre = Vector((
            math.cos(heading) * along - math.sin(heading) * across,
            math.sin(heading) * along + math.cos(heading) * across,
            0.048 + rng.uniform(-0.005, 0.007),
        ))
        angle = heading + rng.uniform(-0.22, 0.22)
        length = rng.uniform(0.092, 0.128)
        body = hull(f"shoal_fish_{index}", centre, (length, length * 0.34, length * 0.44),
                    mat("fish_scale"), seed=seed + index * 23, lumps=4, lump=0.16,
                    sharpness=3.4, taper=0.30)
        body.rotation_euler = (0.0, 0.0, angle)
        # Pale belly under the waterline, dark back above it — countershading, and
        # the reason a fish reads as a fish rather than as a pebble.
        paint_faces(body, mat("fish_belly"), min_normal_z=0.30, min_height=0.0,
                    coverage=0.30, seed=seed + index)
        made.append(body)
        # Tail, as a folded ribbon so it is visible from both sides.
        tail_root = centre - Vector((math.cos(angle), math.sin(angle), 0.0)) * length * 0.92
        tail_tip = tail_root - Vector((math.cos(angle), math.sin(angle), 0.0)) * length * 0.52
        batch.ribbon("fish_scale",
                     [tail_root, (tail_root + tail_tip) * 0.5, tail_tip],
                     [length * 0.06, length * 0.13, length * 0.30],
                     [length * 0.05, length * 0.09, length * 0.16])
        # A dorsal ridge standing clear of the water. This asset is mostly seen
        # from a standing player looking DOWN at it, and the back-and-fin outline
        # is what separates a fish from a stone at that angle.
        fin_front = centre + Vector((math.cos(angle), math.sin(angle), 0.0)) * length * 0.22
        fin_back = centre - Vector((math.cos(angle), math.sin(angle), 0.0)) * length * 0.36
        lift = Vector((0.0, 0.0, length * 0.34))
        batch.ribbon("fish_scale",
                     [fin_front, (fin_front + fin_back) * 0.5 + lift * 0.55, fin_back],
                     [length * 0.030, length * 0.028, length * 0.020],
                     [length * 0.10, length * 0.26, length * 0.08])
    batch.emit("shoal_tails")


def build_glowcap_mushroom(seed: int) -> None:
    """The mushroom that makes light — `ITEMS.md` §4.5/§4.6's Glow Tonic and Glow Flare.

    This is the only asset in MIRE so far whose entire job is to be *seen in the
    dark*, so the cap is the one emissive surface and everything else is
    deliberately unlit: pale stems, shaded gills, a dull moss footing. Lighting the
    gills too would turn each mushroom into a glowing blob and throw away the
    silhouette, and it is the silhouette — cap over stem — that says "mushroom"
    when a player finds one by its glow and then has to recognise what it is.

    A cluster rather than a single mushroom, and of uneven heights, because one
    stalk reads as a nail and a matched set reads as a fairy ring. Real fungus
    fruits in uneven clumps off one mycelium.
    """
    rng = random.Random(seed)
    made = []
    # Damp footing. Fungus grows out of something; a mushroom standing on bare
    # terrain reads as a prop dropped on the floor.
    base = hull("glowcap_base", (0.0, 0.0, 0.022), (0.135, 0.120, 0.026), mat("moss"),
                seed=seed, lumps=7, lump=0.26, sharpness=2.4, flat_base=0.0)
    made.append(base)

    # Uneven on purpose: two tall, two middling, two small.
    heights = [0.290, 0.235, 0.170, 0.145, 0.100, 0.082]
    for index, (angle, rad) in enumerate(radial(len(heights), 0.075, seed=seed + 3,
                                                jitter=0.6, radius_jitter=0.55)):
        height = heights[index]
        foot = Vector((math.cos(angle) * abs(rad), math.sin(angle) * abs(rad), 0.020))
        lean = rng.uniform(0.04, 0.13)
        top = foot + Vector((math.cos(angle) * lean * height,
                             math.sin(angle) * lean * height, height))
        stem_radius = 0.010 + height * 0.035
        made.append(tapered_between(f"glowcap_stem_{index}", foot, top,
                                    stem_radius, stem_radius * 0.86,
                                    mat("flower_cream"), vertices=6))
        cap_radius = 0.026 + height * 0.135
        # Gills as their own thin disc under the cap. `paint_faces` selects faces
        # ABOVE a normal threshold, so it can never reach an underside — the gills
        # have to be geometry or they do not exist.
        made.append(cone(f"glowcap_gill_{index}", cap_radius * 0.92, cap_radius * 0.55,
                         0.014, (top.x, top.y, top.z + 0.004), mat("glowcap_gill"),
                         vertices=7))
        cap = hull(f"glowcap_cap_{index}", (top.x, top.y, top.z + 0.016),
                   (cap_radius, cap_radius, cap_radius * 0.62), mat("glowcap"),
                   seed=seed + index * 19, lumps=5, lump=0.14, sharpness=3.0,
                   flat_base=0.0)
        made.append(cap)


SPECS: list[tuple[str, Callable[[int], None]]] = [
    ("cattail_bundle", build_cattail_bundle),
    ("reed_bed", build_reed_bed),
    ("sphagnum_moss", build_sphagnum_moss),
    ("fish_shoal", build_fish_shoal),
    ("glowcap_mushroom", build_glowcap_mushroom),
]


def seed_for(name: str) -> int:
    """A stable seed per asset name. Deliberately not `hash()`, which is salted
    per process in Python 3 and would make every rebuild a different asset."""
    return sum((index + 3) * ord(char) for index, char in enumerate(name))


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
    # Bake the rotation into the mesh. `join` hands the result whichever rotation
    # the alphabetically-first component carried, and the exporter then writes it
    # out as a node transform on top of the geometry — which put A-011's resin node
    # 53 mm underground for anything measuring the GLB rather than its world matrix.
    # A static prop has no business shipping a rotation.
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

    if name in LIE_DOWN:
        # Rotate the world matrices directly rather than through `bpy.ops`, which
        # needs a pivot and a selection context that background mode makes fragile.
        # About Y, so the asset lies ACROSS the sheet rather than pointing at the
        # camera. Laying it about X first put it end-on and it rendered as a
        # starburst of head-ends with its whole length hidden behind them.
        rotation = Matrix.Rotation(LIE_DOWN[name], 4, "Y")
        for obj in made:
            obj.matrix_world = rotation @ obj.matrix_world
        bpy.context.view_layer.update()

    ground_and_centre(made)
    target, axis, _cap = SIZE[name]
    low, high = world_bounds(made)
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
    ground_and_centre(made)

    made = [join_into_one(name, made)]
    for obj in made:
        for old in list(obj.users_collection):
            old.objects.unlink(obj)
        collection.objects.link(obj)
        obj.parent = root
    bpy.context.view_layer.update()

    adrift = floating_islands(made)
    # Vertices, never `obj.bound_box`: Blender does not refresh the cached box
    # after a join, so a joined asset otherwise measures as its first component.
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
        "parts": sum(1 for obj in made if obj.type == "MESH"),
        "polygons": polygons, "triangles": triangles, "materials": materials,
    }


def check(records: list[dict]) -> list[str]:
    """Everything a machine can judge about this batch, judged — and failed on."""
    problems: list[str] = []
    for record in records:
        name = record["name"]
        target, axis, cap = SIZE[name]
        measured = record["height"] if axis == "height" else max(record["width"], record["depth"])
        if abs(measured - target) > SIZE_TOLERANCE:
            problems.append(f"{name}: {axis} {measured:.3f} m vs target {target:.3f} m")
        spread = max(record["width"], record["depth"])
        if spread > cap:
            problems.append(f"{name}: {spread:.2f} m across, footprint cap is {cap} m")
        if abs(record["ground_offset"]) > 0.005:
            problems.append(f"{name}: sits {record['ground_offset'] * 1000:.1f} mm off the ground")
        if record["adrift"]:
            problems.append(f"{name}: floating geometry: {record['adrift'][:3]}")
        if record["parts"] == 0 or record["polygons"] == 0:
            problems.append(f"{name}: exported no geometry")
        cap_triangles = TRIANGLE_ALLOWANCE.get(name, TRIANGLE_BUDGET)
        if record["triangles"] > cap_triangles:
            problems.append(f"{name}: {record['triangles']} triangles over {cap_triangles}")
        cap_materials = MATERIAL_ALLOWANCE.get(name, MAX_MATERIALS)
        if len(record["materials"]) > cap_materials:
            problems.append(f"{name}: {len(record['materials'])} materials, cap is {cap_materials}")
        if not record["materials"]:
            problems.append(f"{name}: no embedded materials")
        if not (EXPORT_DIR / f"{name}.glb").exists():
            problems.append(f"{name}: no GLB written")
    return problems


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
        raise RuntimeError("wetland asset names must be unique")
    for name, _ in SPECS:
        if name not in SIZE:
            raise RuntimeError(f"{name} has no SIZE entry")

    records: list[dict] = []
    for index, (name, builder) in enumerate(SPECS):
        records.append(create_asset(name, builder, (index * 1.15 - 2.3, 0.0, 0.0)))

    problems = check(records)

    CATALOG_PATH.write_text(json.dumps({
        "batch": "A-043",
        "family": "wetland",
        "blender": bpy.app.version_string,
        "assets": [
            {
                "name": r["name"], "file": f"exports/{r['name']}.glb",
                "width_m": round(r["width"], 4), "depth_m": round(r["depth"], 4),
                "height_m": round(r["height"], 4), "target_m": r["target"], "axis": r["axis"],
                "parts": r["parts"], "polygons": r["polygons"], "triangles": r["triangles"],
                "materials": r["materials"],
            }
            for r in records
        ],
    }, indent=2) + "\n")

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
    bpy.ops.object.camera_add()
    camera = bpy.context.object
    camera.name = "Preview_Camera"
    scene = bpy.context.scene
    scene.camera = camera
    scene.render.engine = eevee_engine()
    scene.render.resolution_x = 1500
    scene.render.image_settings.file_format = "PNG"
    scene.render.film_transparent = False
    scene.world.color = (0.016, 0.021, 0.028)
    scene.view_settings.look = "AgX - Medium High Contrast"
    for obj in (key, fill, camera):
        for old in list(obj.users_collection):
            old.objects.unlink(obj)
        preview_collection.objects.link(obj)

    bpy.ops.mesh.primitive_cube_add(location=(0, 0, 0.9))
    figure = bpy.context.object
    figure.name = "Scale_Reference"
    figure.scale = (0.20, 0.13, 0.90)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    figure.data.materials.append(mat("reference_blue"))
    for old in list(figure.users_collection):
        old.objects.unlink(figure)
    preview_collection.objects.link(figure)

    def set_visible(record: dict, visible: bool) -> None:
        record["root"].hide_render = not visible
        for child in record["root"].children_recursive:
            child.hide_render = not visible

    first_x = -2.3
    last_x = first_x + (len(records) - 1) * 1.15
    figure_x = first_x - 1.05
    span = (last_x + 0.75) - (figure_x - 0.45)
    centre_x = ((figure_x - 0.45) + (last_x + 0.75)) * 0.5
    # Vertical extent is driven by the 1.80 m reference standing in the sheet, not
    # by a fixed aspect: at one asset the span is narrow, and a fixed 0.52 ratio
    # framed 1.17 m of world and cut the bundle off at the ankles.
    view_height = 2.15
    camera.data.type = "ORTHO"
    camera.data.ortho_scale = span
    scene.render.resolution_y = int(1500 * view_height / span)
    figure.location = (figure_x, 0.0, 0.9)
    camera.location = (centre_x, -12.0, view_height * 0.5 - 0.14)
    look_at(camera, (centre_x, 0.0, view_height * 0.5 - 0.14))
    scene.render.filepath = str(PREVIEW_DIR / "wetland_preview.png")
    bpy.ops.render.render(write_still=True)

    # Night sheet. `glowcap_mushroom` exists to be found in the dark, and a sunlit
    # contact sheet cannot show whether its emission actually survives the export —
    # under a key light at 4.0 the cap is just a pale mushroom. This is the only
    # honest test of the one thing the asset is for.
    #
    # The CAMERA moves to the asset; the asset does not move to the camera. F-204:
    # a preview that relocates objects between renders draws the layout it had at
    # the first render, and the tile comes out blank while the asset probes as
    # present, visible and correctly placed.
    glow = next(r for r in records if r["name"] == "glowcap_mushroom")
    for record in records:
        set_visible(record, record["name"] == "glowcap_mushroom")
    key.data.energy = 0.05
    fill.data.energy = 0.02
    scene.world.color = (0.004, 0.006, 0.010)
    figure.hide_render = True
    glow_x = glow["root"].location.x
    camera.data.type = "PERSP"
    camera.data.lens = 62.0
    scene.render.resolution_y = 900
    camera.location = (glow_x + 0.03, -1.30, 0.26)
    look_at(camera, (glow_x, 0.0, 0.15))
    scene.render.filepath = str(PREVIEW_DIR / "glowcap_night_preview.png")
    bpy.ops.render.render(write_still=True)
    figure.hide_render = False
    for record in records:
        set_visible(record, True)

    bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE_PATH))

    print(f"\nWETLAND_BUILD assets={len(records)} "
          f"triangles={sum(r['triangles'] for r in records)} blender={bpy.app.version_string}")
    for record in records:
        print("  %-22s %5.2f x %5.2f x %5.2f m  %4d tris  %d mats  %s"
              % (record["name"], record["width"], record["depth"], record["height"],
                 record["triangles"], len(record["materials"]),
                 ",".join(m.replace("MIRE_", "") for m in record["materials"])))
    if problems:
        print(f"\nWETLAND_CHECK FAIL ({len(problems)})")
        for problem in problems:
            print(f"  {problem}")
        raise SystemExit(1)
    print("WETLAND_CHECK PASS")


if __name__ == "__main__":
    main()
