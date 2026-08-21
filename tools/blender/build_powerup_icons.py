"""Build and render MIRE's powerup, ability and attunement icons (A-050).

Run with:
  Blender --background --python tools/blender/build_powerup_icons.py [-- --only <substring>]

Why these are MODELLED and not drawn
------------------------------------
`render_item_icons.py` renders an icon from the GLB the item already has, so an
item icon can never drift from the thing it stands for. A powerup has no prop —
"Stubborn Heart" is not an object lying in the world — so there is nothing to
point a camera at, and 72 hand-drawn 2D sprites would be the one part of MIRE's
art not made the way the rest of it is made. They would read as a different game
the moment they sat next to an item icon in the same chest window.

So each one is a small low-relief EMBLEM in the same palette, the same flat
shading and the same faceted vocabulary as every other asset here, rendered
face-on. The style does the work of making seventy-two of them feel like one set.

How an emblem is put together
-----------------------------
Two layers, and the split is what makes them readable at 48 px in a grid:

* **A plaque** — the backing, whose SHAPE and COLOUR are the powerup's tag family
  (Blood, Fire, Cold, Fungal, Void, Kinetic, or none). At icon size the family is
  what a player sorts by first, and colour plus outline are the only two channels
  that survive at that resolution. Six families, six silhouettes.
* **A motif** — what THIS powerup does, in front of the plaque, in a contrasting
  tone. The motif is where the individual authoring is; there is a builder per
  powerup below and no two share one.

The relief is deliberately shallow (about 0.12 of the plaque's width). A deep
model turns into a lit blob at 48 px; a shallow one keeps its outline and lets
the facets carry the shading.
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
from mire_art import mat, radial, around, reset_materials, hull  # noqa: E402
from godot_import_lock import import_cache_guard  # noqa: E402


ROOT = Path(__file__).resolve().parents[2]
ICON_DIR = ROOT / "assets" / "icons"
EXPORT_DIR = ICON_DIR / "exports"
PREVIEW_DIR = ICON_DIR / "preview"
SOURCE_DIR = ROOT / "assets" / "source"

ICON_SIZE = 256
SHEET_COLUMNS = 9

#: The emblem is authored inside a unit square in X/Z and looked at down -Y.
#: Everything below is written in those units, so a motif reads the same at any
#: icon resolution and a builder never has to know the pixel size.
FACE = 1.0
RELIEF = 0.12
#: Motifs are authored at FINAL size — 1.0, i.e. no rescale. The first cut
#: authored small and blew the motif up to fill the plaque, and every builder
#: then had to be checked against a multiplier it could not see: the mushroom cap
#: and the key both spilled straight out of their frames. The plaque grew instead.
#: Everything a builder draws must stay inside PLAQUE_BODY.
MOTIF_SCALE = 1.0
PLAQUE_RIM = 0.56
PLAQUE_BODY = 0.475


def argv() -> list[str]:
    return sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []


def opt(name: str, default: str) -> str:
    a = argv()
    return a[a.index(name) + 1] if name in a else default


def flat(obj: bpy.types.Object, material: bpy.types.Material) -> bpy.types.Object:
    obj.data.materials.append(material)
    for polygon in obj.data.polygons:
        polygon.use_smooth = False
    return obj


def slab(name: str, centre: tuple[float, float], size: tuple[float, float],
         material: bpy.types.Material, depth: float = RELIEF * 0.55,
         y: float = 0.0, roll: float = 0.0) -> bpy.types.Object:
    """A flat rectangular tile standing in the icon plane. The workhorse: bars,
    blades, planks, limbs and frames are all this with a roll on them."""
    bpy.ops.mesh.primitive_cube_add(location=(centre[0], y, centre[1]),
                                    rotation=(0.0, roll, 0.0))
    obj = bpy.context.object
    obj.name = name
    obj.scale = (size[0] * 0.5, depth * 0.5, size[1] * 0.5)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    return flat(obj, material)


def wedge(name: str, centre: tuple[float, float], radius: float, sides: int,
          material: bpy.types.Material, depth: float = RELIEF * 0.6,
          y: float = 0.0, roll: float = 0.0, taper: float = 1.0) -> bpy.types.Object:
    """A regular n-gon prism lying in the icon plane — discs, hexes, triangles,
    diamonds and shield blanks all come out of this."""
    bpy.ops.mesh.primitive_cone_add(vertices=sides, radius1=radius, radius2=radius * taper,
                                    depth=depth, location=(centre[0], y, centre[1]),
                                    rotation=(math.pi * 0.5, 0.0, 0.0))
    obj = bpy.context.object
    obj.name = name
    obj.rotation_euler = (math.pi * 0.5, roll, 0.0)
    bpy.ops.object.transform_apply(rotation=True)
    return flat(obj, material)


def blob(name: str, centre: tuple[float, float], size: tuple[float, float],
         material: bpy.types.Material, seed: int, y: float = 0.0,
         depth: float = RELIEF * 0.7, lumps: int = 3, lump: float = 0.30) -> bpy.types.Object:
    """An irregular organic mass — flesh, moss, spore heads, ash, cloud."""
    return hull(name, (centre[0], y, centre[1]), (size[0], depth, size[1]),
                material, seed, subdivisions=0, lumps=lumps, lump=lump, sharpness=2.2)


def oval(name: str, centre: tuple[float, float], radius: float, sides: int,
         material: bpy.types.Material, squash: float = 0.60, depth: float = RELIEF * 0.6,
         y: float = 0.0, roll: float = 0.0) -> bpy.types.Object:
    """A flattened n-gon — lenses, eyes, gills, shields, loaves, pupils."""
    obj = wedge(name, centre, radius, sides, material, depth=depth, y=y, roll=roll)
    obj.scale = (1.0, 1.0, squash)
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.transform_apply(scale=True)
    obj.location = (centre[0], y, centre[1])
    return obj


def heart(name: str, centre: tuple[float, float], size: float,
          material: bpy.types.Material, y: float = 0.0) -> None:
    """Two lobes and a point. Built as overlapping solids rather than as two
    droplets — the first cut used droplets and read as a blobby letter M, because
    a heart's lobes have to MEET above the point, not sit beside each other."""
    for index, side in enumerate((-1.0, 1.0)):
        wedge(f"{name}_Lobe_{index + 1}", (centre[0] + side * size * 0.34, centre[1] + size * 0.30),
              size * 0.46, 9, material, y=y)
    wedge(f"{name}_Point", (centre[0], centre[1] - size * 0.10), size * 0.86, 3, material,
          y=y, roll=math.pi)


def eye(name: str, centre: tuple[float, float], size: float, lid: bpy.types.Material,
        white: bpy.types.Material, iris: bpy.types.Material, pupil: bpy.types.Material,
        y: float = 0.0) -> None:
    """A lens, not a circle. An eye drawn as concentric rings reads as a target —
    the pointed corners are the whole difference."""
    oval(f"{name}_Lid", centre, size, 9, lid, squash=0.52, y=y)
    oval(f"{name}_White", centre, size * 0.84, 9, white, squash=0.48, y=y - RELIEF * 0.35)
    wedge(f"{name}_Corner_L", (centre[0] - size * 0.94, centre[1]), size * 0.22, 3, lid,
          y=y, roll=math.pi * 0.5)
    wedge(f"{name}_Corner_R", (centre[0] + size * 0.94, centre[1]), size * 0.22, 3, lid,
          y=y, roll=-math.pi * 0.5)
    wedge(f"{name}_Iris", centre, size * 0.42, 9, iris, y=y - RELIEF * 0.7)
    wedge(f"{name}_Pupil", centre, size * 0.20, 7, pupil, y=y - RELIEF * 1.0)


def bar(name: str, start: tuple[float, float], end: tuple[float, float], width: float,
        material: bpy.types.Material, y: float = 0.0,
        depth: float = RELIEF * 0.5) -> bpy.types.Object:
    """A rectangular bar between two points in the icon plane. Strokes, hafts,
    chevron legs, cracks and stems."""
    first, second = Vector(start), Vector(end)
    middle = (first + second) * 0.5
    span = (second - first).length
    angle = -math.atan2(second.y - first.y, second.x - first.x)
    return slab(name, (middle.x, middle.y), (span, width), material, depth=depth, y=y, roll=angle)


def chevron(name: str, apex: tuple[float, float], span: float, drop: float, width: float,
            material: bpy.types.Material, y: float = 0.0) -> None:
    """The motion mark. Two bars meeting at a point — used by everything Kinetic,
    because a chevron is the one shape that reads as DIRECTION at icon size."""
    bar(f"{name}_L", (apex[0] - span, apex[1] - drop), apex, width, material, y=y)
    bar(f"{name}_R", (apex[0] + span, apex[1] - drop), apex, width, material, y=y)


def droplet(name: str, centre: tuple[float, float], size: float,
            material: bpy.types.Material, y: float = 0.0) -> None:
    """A teardrop: round below, pointed above. Blood, tonic, sap, spore-fall."""
    wedge(f"{name}_Bowl", (centre[0], centre[1] - size * 0.18), size * 0.62, 9, material, y=y)
    wedge(f"{name}_Tip", (centre[0], centre[1] + size * 0.52), size * 0.46, 3, material, y=y)


def crescent(name: str, centre: tuple[float, float], radius: float, width: float,
             material: bpy.types.Material, arc: tuple[float, float] = (0.15, 0.85),
             y: float = 0.0, segments: int = 9) -> None:
    """An arc drawn as a fan of short bars — rings, horns, bows, swirls, hoops."""
    low, high = arc
    for index in range(segments):
        first = low + (high - low) * (index / segments)
        second = low + (high - low) * ((index + 1) / segments)
        bar(
            f"{name}_{index + 1}",
            (centre[0] + math.cos(first * math.tau) * radius,
             centre[1] + math.sin(first * math.tau) * radius),
            (centre[0] + math.cos(second * math.tau) * radius,
             centre[1] + math.sin(second * math.tau) * radius),
            width, material, y=y,
        )


# ---------------------------------------------------------------------------
# Tag families — the plaque
# ---------------------------------------------------------------------------
#
# Six families, six SILHOUETTES, six colours. Both channels carry the family on
# purpose: colour alone fails for a colour-blind player and in a dark UI, and
# outline alone fails at 32 px. Together either one is enough.
#
# The colours are not free choices — the palette already assigns meaning to most
# of MIRE's hues (see `mire_art.PALETTE`'s reserved-colour notes), so each family
# takes the token that already means that thing in the world: Fire is the fire
# the torches burn with, Void is the Mire's own purple, Fungal is the toadstool
# pink that already signals "growth" in the swamp.

#: `teeth` adds marks around the rim, which is the cheap way to give a family a
#: silhouette nobody can confuse without paying for a second shape. The first cut
#: gave Fire a TRIANGLE, which is the most distinctive outline available and also
#: the one with the least room inside it: a triangle's inscribed circle is half
#: its circumradius, so the flame came out a quarter the size of every other
#: motif. Roomy plaque, distinctive RIM.
FAMILIES: dict[str, dict] = {
    #                sides  turn      body            rim              motif           rim marks
    "Blood":  {"sides": 9,  "roll": 0.0,  "body": "blood",      "rim": "flesh_raw",   "ink": "bone",         "teeth": 0},
    # Fire and Cold keep DARK bodies with bright rims, and that is not a style
    # preference: a motif has to sit on its plaque, and `ember` and `ice` are two
    # of the lightest values in the palette. Drawn on them, every pale motif
    # vanished and every dark one read as a hole. The family colour survives fine
    # on the rim and the teeth, which are the distinctive part of both anyway.
    "Fire":   {"sides": 8,  "roll": 0.20, "body": "wood_charred", "rim": "ember",     "ink": "flame",        "teeth": 8, "tooth_sides": 3},
    "Cold":   {"sides": 6,  "roll": 0.26, "body": "iron_dark",    "rim": "ice",       "ink": "iron_light",   "teeth": 6, "tooth_sides": 4},
    "Fungal": {"sides": 7,  "roll": 0.0,  "body": "fungus_cap", "rim": "moss",        "ink": "bone",         "teeth": 0},
    "Void":   {"sides": 4,  "roll": 0.0,  "body": "mire",       "rim": "crystal_tip", "ink": "bone",         "teeth": 0},
    "Kinetic":{"sides": 5,  "roll": 0.0,  "body": "brass",      "rim": "gold",        "ink": "wood_charred", "teeth": 0},
    "":       {"sides": 12, "roll": 0.0,  "body": "iron",       "rim": "bone",        "ink": "stone_dark",   "teeth": 0},
}


def plaque(tags: list[str]) -> dict[str, bpy.types.Material]:
    """Backing for one emblem. Returns the ink and accent this family's motifs
    should be drawn in, so a builder never picks its own colours and the set stays
    coherent however many are added.

    A two-tag powerup gets the FIRST tag's shape and a wedge of the second tag's
    colour cut into the rim, which is how a hybrid reads as a hybrid rather than
    as a third family nobody recognises."""
    primary = tags[0] if tags else ""
    family = FAMILIES.get(primary, FAMILIES[""])
    body = mat(family["body"])
    rim = mat(family["rim"])
    for index in range(int(family.get("teeth", 0))):
        angle = (index / family["teeth"]) * math.tau + family["roll"]
        wedge(f"Plaque_Tooth_{index + 1}",
              (math.cos(angle) * PLAQUE_RIM * 1.02, math.sin(angle) * PLAQUE_RIM * 1.02),
              FACE * 0.115, int(family.get("tooth_sides", 3)), rim, depth=RELIEF * 0.45,
              y=RELIEF * 0.34,
              roll=angle + math.pi * 0.5)
    wedge("Plaque_Rim", (0.0, 0.0), PLAQUE_RIM, family["sides"], rim,
          depth=RELIEF * 0.5, y=RELIEF * 0.30, roll=family["roll"])
    wedge("Plaque_Body", (0.0, 0.0), PLAQUE_BODY, family["sides"], body,
          depth=RELIEF * 0.55, y=RELIEF * 0.10, roll=family["roll"])
    if len(tags) > 1:
        # A hybrid's second family is three studs SET INTO the rim ring. The first
        # cut put them outside the plaque, where they read as coloured debris that
        # had fallen off the icon rather than as part of it — visible on every
        # two-tag card in the contact sheet.
        second = FAMILIES.get(tags[1], FAMILIES[""])
        ring = (PLAQUE_RIM + PLAQUE_BODY) * 0.5
        for index, (angle, _radius) in enumerate(radial(3, 1.0, seed=7, jitter=0.0)):
            wedge(f"Plaque_Second_{index + 1}",
                  (math.cos(angle + 0.9) * ring, math.sin(angle + 0.9) * ring),
                  FACE * 0.062, 4, mat(second["rim"]), depth=RELIEF * 0.5, y=RELIEF * 0.24,
                  roll=angle)
    return {"ink": mat(family["ink"]), "body": body, "rim": rim}


# ---------------------------------------------------------------------------
# The emblems — one authored builder per powerup, no two alike
# ---------------------------------------------------------------------------
#
# Each takes the palette `plaque()` handed back and draws in front of it. The
# rule every one of these follows: **say the effect, not the flavour name.** An
# icon that illustrates the words "Stubborn Heart" is a picture of a heart, which
# tells a player nothing; an icon of a heart with an iron band clamped round it
# says "this one keeps you alive when you should have died", which is the thing
# they are choosing.

def em_adrenal_bloom(ink, body, rim) -> None:
    """Badly hurt, your legs stop asking permission — a heart throwing a chevron."""
    heart("Heart", (0.0, -0.09), 0.30, ink)
    chevron("Surge", (0.0, 0.38), 0.19, 0.15, 0.055, rim)


def em_stubborn_heart(ink, body, rim) -> None:
    """A heart with an iron band clamped round it: it does not get to stop.

    Deliberately NOT a picture of a heart. An icon that illustrates the card's
    NAME tells a player nothing they could not read; the band is the effect."""
    heart("Heart", (0.0, -0.02), 0.34, ink)
    slab("Band", (0.0, -0.02), (0.56, 0.085), mat("iron"), y=-RELIEF * 0.5)
    for index, x in enumerate((-0.20, 0.20)):
        wedge(f"Rivet_{index + 1}", (x, -0.02), 0.042, 6, mat("iron_light"), y=-RELIEF * 0.85)


def em_open_flame(ink, body, rim) -> None:
    """A torch that is simply lit — the plainest Fire card, so the plainest shape."""
    bar("Haft", (0.0, -0.40), (0.0, -0.04), 0.095, mat("wood_bark"))
    slab("Wrap", (0.0, -0.02), (0.19, 0.085), mat("iron_dark"), y=-RELIEF * 0.4)
    wedge("Flame_Outer", (0.0, 0.20), 0.26, 3, mat("ember"), y=-RELIEF * 0.4)
    wedge("Flame_Mid", (0.0, 0.16), 0.17, 3, mat("flame"), y=-RELIEF * 0.75)
    wedge("Flame_Core", (0.0, 0.12), 0.085, 3, mat("gold"), y=-RELIEF * 1.05)


def em_chill_edge(ink, body, rim) -> None:
    """Frost that lives on the cutting edge and nowhere else."""
    slab("Blade", (0.0, 0.13), (0.13, 0.52), ink)
    wedge("Tip", (0.0, 0.42), 0.09, 3, ink)
    slab("Guard", (0.0, -0.16), (0.40, 0.070), mat("brass_dark"), y=-RELIEF * 0.3)
    bar("Grip", (0.0, -0.19), (0.0, -0.40), 0.075, mat("wood_bark"))
    wedge("Pommel", (0.0, -0.43), 0.068, 6, mat("brass_dark"))
    for index, (x, z) in enumerate(((-0.11, 0.30), (0.10, 0.38), (-0.09, 0.12))):
        wedge(f"Rime_{index + 1}", (x, z), 0.070, 6, mat("ice"), y=-RELIEF * 0.95,
              roll=index * 0.4)


def em_wide_cap(ink, body, rim) -> None:
    """One cap, deliberately too broad — the width IS the card."""
    bar("Stem", (0.0, -0.38), (0.0, 0.02), 0.12, mat("bone"))
    oval("Cap", (0.0, 0.12), 0.43, 11, ink, squash=0.62)
    # The gill line, drawn WIDER than the cap and in front of it. A dome alone is
    # an ellipse; it is the hard horizontal underside that makes it a mushroom,
    # and putting it in front is what hides the bottom of the ellipse without
    # painting a rectangle of plaque colour over the plaque (which is what the
    # first attempt did, and it showed).
    slab("Gills", (0.0, -0.07), (0.92, 0.13), mat("bone"), y=-RELIEF * 0.45)
    for index, x in enumerate((-0.22, 0.02, 0.24)):
        wedge(f"Spot_{index + 1}", (x, 0.22 - abs(x) * 0.32), 0.055, 7, mat("bone"),
              y=-RELIEF * 0.95)


def em_second_glance(ink, body, rim) -> None:
    """Void: an eye that opens on the second look."""
    eye("Eye", (0.0, 0.0), 0.40, rim, mat("mire_black"), mat("crystal"), ink)


def em_swift_stride(ink, body, rim) -> None:
    """Three chevrons: the most literal motion mark in the set, and the baseline
    every other Kinetic emblem is read against."""
    for index, z in enumerate((-0.26, 0.0, 0.26)):
        chevron(f"Mark_{index + 1}", (0.03, z + 0.10), 0.23, 0.19,
                0.062, ink if index == 1 else rim)


def em_the_landlord(ink, body, rim) -> None:
    """Untagged utility: a key. Whatever the Mire owes, it pays this one rent."""
    crescent("Bow", (0.0, 0.25), 0.15, 0.070, mat("gold"), arc=(0.0, 1.0), segments=9)
    bar("Shank", (0.0, 0.13), (0.0, -0.38), 0.078, mat("gold"))
    slab("Ward_A", (0.11, -0.19), (0.18, 0.068), mat("gold"), y=-RELIEF * 0.3)
    slab("Ward_B", (0.10, -0.33), (0.15, 0.068), mat("gold"), y=-RELIEF * 0.3)


# --- Blood -----------------------------------------------------------------

def em_cauter_seal(ink, body, rim) -> None:
    """A wound shut with a hot iron. The brand crosses the cut, not beside it."""
    bar("Cut", (-0.24, -0.22), (0.22, 0.26), 0.075, mat("blood"))
    bar("Brand", (-0.20, 0.24), (0.24, -0.20), 0.10, mat("iron_dark"))
    wedge("Heat", (0.24, -0.22), 0.11, 3, mat("ember"), y=-RELIEF * 0.8, roll=0.8)
    for index, t in enumerate((0.25, 0.5, 0.75)):
        wedge(f"Stitch_{index + 1}", (-0.24 + 0.46 * t, -0.22 + 0.48 * t), 0.055, 4, ink,
              y=-RELIEF * 0.9)


def em_iron_tongue(ink, body, rim) -> None:
    """You speak and the swamp listens — a bell with an iron clapper."""
    wedge("Bell", (0.0, 0.10), 0.32, 7, mat("iron"), taper=0.45, roll=math.pi)
    slab("Lip", (0.0, -0.14), (0.52, 0.075), mat("iron_light"), y=-RELIEF * 0.3)
    bar("Clapper", (0.0, -0.16), (0.0, -0.34), 0.055, ink, y=-RELIEF * 0.5)
    wedge("Bead", (0.0, -0.38), 0.085, 7, ink, y=-RELIEF * 0.5)
    bar("Crown", (0.0, 0.32), (0.0, 0.44), 0.06, mat("iron_light"))


def em_pact_cut(ink, body, rim) -> None:
    """An open palm with a diagonal cut and one bead. A bargain costs something."""
    slab("Palm", (0.0, -0.10), (0.36, 0.34), ink)
    for index, x in enumerate((-0.13, -0.03, 0.07, 0.16)):
        slab(f"Finger_{index + 1}", (x, 0.17), (0.075, 0.24), ink)
    slab("Thumb", (-0.22, 0.02), (0.075, 0.20), ink, roll=0.7)
    bar("Cut", (-0.16, -0.22), (0.16, 0.06), 0.055, mat("blood"), y=-RELIEF * 0.7)
    droplet("Bead", (0.19, -0.26), 0.11, mat("blood"), y=-RELIEF * 0.9)


def em_red_quench(ink, body, rim) -> None:
    """A blade quenched in blood, not water — the bowl and the steam say which."""
    slab("Blade", (0.0, 0.20), (0.12, 0.44), mat("iron_light"))
    slab("Guard", (0.0, -0.03), (0.30, 0.06), mat("iron_dark"), y=-RELIEF * 0.3)
    wedge("Bowl", (0.0, -0.28), 0.36, 9, mat("iron_dark"), taper=0.55, roll=math.pi)
    oval("Blood", (0.0, -0.16), 0.30, 9, mat("blood"), squash=0.28, y=-RELIEF * 0.5)
    for index, x in enumerate((-0.19, 0.19)):
        wedge(f"Steam_{index + 1}", (x, 0.02), 0.075, 3, ink, y=-RELIEF * 0.9, roll=index * 0.5)


def em_sealed_veins(ink, body, rim) -> None:
    """A vein tied off in a knot. You stop bleeding because something clamped."""
    crescent("Vein_Top", (0.0, 0.18), 0.20, 0.080, ink, arc=(0.10, 0.62))
    crescent("Vein_Low", (0.0, -0.18), 0.20, 0.080, ink, arc=(0.60, 1.12))
    slab("Knot", (0.0, 0.0), (0.24, 0.15), mat("iron"), y=-RELIEF * 0.5)
    for index, x in enumerate((-0.06, 0.06)):
        slab(f"Knot_Line_{index + 1}", (x, 0.0), (0.035, 0.17), mat("iron_dark"),
             y=-RELIEF * 0.85)


def em_thick_hide(ink, body, rim) -> None:
    """Overlapping scutes. Not armour — skin that stopped being polite."""
    for row, z in enumerate((0.24, 0.02, -0.20)):
        offset = 0.11 if row % 2 else 0.0
        for column, x in enumerate((-0.22, 0.0, 0.22)):
            oval(f"Scute_{row}_{column}", (x + offset - 0.055, z), 0.14, 7, ink,
                 squash=0.80, y=-RELIEF * 0.12 * row)


def em_whetted_thirst(ink, body, rim) -> None:
    """A fang on a whetstone: the edge gets keener the more it drinks."""
    slab("Stone", (0.0, -0.28), (0.52, 0.13), mat("stone"), roll=0.12)
    wedge("Fang", (0.0, 0.10), 0.19, 3, ink, taper=0.0)
    slab("Fang_Body", (0.0, 0.22), (0.19, 0.34), ink)
    droplet("Drop", (0.0, -0.10), 0.12, mat("blood"), y=-RELIEF * 0.8)


def em_steady_hands(ink, body, rim) -> None:
    """Blood and Cold: a hand that has stopped shaking because it stopped feeling."""
    slab("Palm", (0.0, -0.12), (0.34, 0.32), ink)
    for index, x in enumerate((-0.12, -0.02, 0.08, 0.17)):
        slab(f"Finger_{index + 1}", (x, 0.15), (0.070, 0.26), ink)
    for index, (x, z) in enumerate(((-0.20, 0.20), (0.21, 0.28), (0.0, 0.34))):
        wedge(f"Rime_{index + 1}", (x, z), 0.070, 4, rim, y=-RELIEF * 0.9, roll=index * 0.5)


def em_scab_feast(ink, body, rim) -> None:
    """Blood and Fungal: a crust that fruits. Healing, but not the nice kind."""
    oval("Crust", (0.0, -0.10), 0.36, 9, mat("blood"), squash=0.66)
    for index, (x, z, r) in enumerate(((-0.16, 0.10, 0.11), (0.06, 0.20, 0.13), (0.22, 0.02, 0.09))):
        bar(f"Stalk_{index + 1}", (x, z - r), (x, z), 0.040, mat("bone"))
        oval(f"Cap_{index + 1}", (x, z + r * 0.55), r, 7, ink, squash=0.62, y=-RELIEF * 0.5)


def em_rich_marrow(ink, body, rim) -> None:
    """Blood and Fungal: a split bone with something growing in the middle."""
    slab("Bone", (0.0, 0.0), (0.20, 0.62), mat("bone"), roll=0.22)
    for index, (x, z) in enumerate(((-0.14, 0.30), (0.10, 0.34), (-0.16, -0.30), (0.08, -0.34))):
        wedge(f"Knuckle_{index + 1}", (x, z), 0.12, 8, mat("bone"))
    oval("Marrow", (0.0, 0.0), 0.13, 9, mat("blood"), squash=1.6, y=-RELIEF * 0.6)
    for index, z in enumerate((-0.08, 0.10)):
        oval(f"Bloom_{index + 1}", (0.02 - index * 0.04, z), 0.085, 7, mat("fungus_cap"),
             squash=0.6, y=-RELIEF * 0.95)


def em_grave_due(ink, body, rim) -> None:
    """Void and Blood: a stone with a coin on it. Something is owed, and it is paid here."""
    slab("Stone", (0.0, -0.10), (0.40, 0.48), mat("stone_ruin"))
    crescent("Stone_Top", (0.0, 0.14), 0.20, 0.12, mat("stone_ruin"), arc=(0.0, 0.5))
    oval("Coin", (0.0, 0.06), 0.15, 9, mat("gold"), squash=0.95, y=-RELIEF * 0.7)
    for index, x in enumerate((-0.13, 0.13)):
        bar(f"Grass_{index + 1}", (x, -0.34), (x + (0.05 if index else -0.05), -0.20), 0.045,
            mat("moss"), y=-RELIEF * 0.4)


def em_pale_guard(ink, body, rim) -> None:
    """Cold: a shield gone white with frost. It does not warm up."""
    oval("Shield", (0.0, 0.08), 0.34, 6, ink, squash=1.05)
    wedge("Shield_Point", (0.0, -0.24), 0.34, 3, ink, roll=math.pi)
    for index, (x, z) in enumerate(((-0.12, 0.16), (0.13, 0.10), (0.0, -0.08))):
        wedge(f"Frost_{index + 1}", (x, z), 0.080, 4, rim, y=-RELIEF * 0.8, roll=index * 0.4)


# --- Fire ------------------------------------------------------------------

def em_ashen_temper(ink, body, rim) -> None:
    """A blade tempered in ash: grey steel over a grey heap, one ember left."""
    slab("Blade", (0.0, 0.18), (0.13, 0.46), mat("iron_light"), roll=0.22)
    blob("Ash", (0.0, -0.26), (0.36, 0.14), mat("stone_dark"), 11, y=-RELIEF * 0.3)
    for index, x in enumerate((-0.14, 0.16)):
        wedge(f"Ember_{index + 1}", (x, -0.24), 0.055, 6, mat("ember"), y=-RELIEF * 0.8)


def em_ember_knuckle(ink, body, rim) -> None:
    """A fist that arrives hot. Knuckles first, flame trailing."""
    oval("Fist", (0.0, -0.06), 0.30, 7, mat("flesh_raw"), squash=0.86)
    for index, x in enumerate((-0.18, -0.06, 0.06, 0.18)):
        wedge(f"Knuckle_{index + 1}", (x, 0.14), 0.075, 6, mat("flesh_fat"), y=-RELIEF * 0.5)
    for index, (x, z, r) in enumerate(((-0.26, 0.18, 0.11), (0.0, 0.32, 0.13), (0.27, 0.16, 0.10))):
        wedge(f"Flame_{index + 1}", (x, z), r, 3, ink, y=-RELIEF * 0.8)


def em_flashover(ink, body, rim) -> None:
    """Everything catches at once. A burst, drawn as spokes, not a flame."""
    for index, (angle, _radius) in enumerate(radial(8, 1.0, seed=3, jitter=0.0)):
        length = 0.40 if index % 2 == 0 else 0.28
        bar(f"Spoke_{index + 1}", (math.cos(angle) * 0.10, math.sin(angle) * 0.10),
            (math.cos(angle) * length, math.sin(angle) * length), 0.070, ink)
    wedge("Core", (0.0, 0.0), 0.13, 8, mat("gold"), y=-RELIEF * 0.7)


def em_forge_blood(ink, body, rim) -> None:
    """A crucible tipping. What comes out is metal and it is not cooling."""
    wedge("Crucible", (-0.10, 0.14), 0.28, 7, mat("iron_dark"), taper=0.55, roll=math.pi + 0.5)
    bar("Pour", (0.10, 0.10), (0.20, -0.30), 0.085, ink)
    oval("Pool", (0.22, -0.36), 0.20, 9, ink, squash=0.34, y=-RELIEF * 0.4)
    wedge("Pool_Hot", (0.22, -0.36), 0.10, 7, mat("gold"), y=-RELIEF * 0.8)


def em_night_pyre(ink, body, rim) -> None:
    """A pyre that burns after dark: the fire, and the moon it is answering."""
    for index, roll in enumerate((0.55, -0.55)):
        bar(f"Log_{index + 1}", (-0.24 + index * 0.48, -0.34), (0.0, -0.10), 0.085,
            mat("wood_charred"))
    wedge("Flame", (0.0, 0.06), 0.24, 3, ink, y=-RELIEF * 0.4)
    wedge("Flame_Core", (0.0, 0.02), 0.12, 3, mat("gold"), y=-RELIEF * 0.8)
    crescent("Moon", (0.24, 0.32), 0.15, 0.070, mat("bone"), arc=(0.62, 1.14))


def em_tinder_snap(ink, body, rim) -> None:
    """A twig broken over a spark. The break IS the ignition."""
    bar("Twig_L", (-0.38, -0.14), (-0.05, 0.02), 0.075, mat("wood_bark"))
    bar("Twig_R", (0.06, 0.06), (0.38, -0.10), 0.075, mat("wood_bark"))
    for index, (angle, _radius) in enumerate(radial(5, 1.0, seed=5, jitter=0.2)):
        bar(f"Spark_{index + 1}", (0.0, 0.06),
            (math.cos(angle) * 0.20, 0.06 + math.sin(angle) * 0.20), 0.045, ink,
            y=-RELIEF * 0.7)
    wedge("Spark_Core", (0.0, 0.06), 0.085, 6, mat("gold"), y=-RELIEF * 0.95)


def em_cinder_tithe(ink, body, rim) -> None:
    """Fire and Void: a coin burning. Something takes its cut in ash."""
    oval("Coin", (0.0, -0.06), 0.28, 9, mat("gold"), squash=0.98)
    wedge("Coin_Face", (0.0, -0.06), 0.16, 9, mat("brass_dark"), y=-RELIEF * 0.5)
    for index, (x, z, r) in enumerate(((-0.20, 0.20, 0.11), (0.02, 0.30, 0.14), (0.22, 0.18, 0.10))):
        wedge(f"Flame_{index + 1}", (x, z), r, 3, ink, y=-RELIEF * 0.7)
    for index, x in enumerate((-0.10, 0.12)):
        wedge(f"Ash_{index + 1}", (x, -0.36), 0.060, 4, mat("mire"), y=-RELIEF * 0.4)


def em_warm_marrow(ink, body, rim) -> None:
    """Fire and Cold: a bone with an ember in it. The chill stops at your skin."""
    slab("Bone", (0.0, 0.0), (0.22, 0.58), mat("bone"))
    for index, (x, z) in enumerate(((-0.15, 0.30), (0.13, 0.32), (-0.14, -0.30), (0.14, -0.32))):
        wedge(f"Knuckle_{index + 1}", (x, z), 0.115, 8, mat("bone"))
    oval("Core", (0.0, 0.0), 0.095, 8, mat("ember"), squash=2.0, y=-RELIEF * 0.6)
    oval("Core_Hot", (0.0, 0.0), 0.050, 6, mat("gold"), squash=2.2, y=-RELIEF * 0.95)


# --- Cold ------------------------------------------------------------------

def em_deep_frost(ink, body, rim) -> None:
    """Not a dusting — a mass of it. Three crystals, one already bigger than the card."""
    for index, (x, z, r, sides) in enumerate(
            ((-0.18, -0.10, 0.24, 6), (0.14, 0.06, 0.30, 6), (0.20, -0.24, 0.16, 4))):
        wedge(f"Crystal_{index + 1}", (x, z), r, sides, ink if index == 1 else rim,
              y=-RELIEF * 0.25 * index, roll=index * 0.5)
    for index, (x, z) in enumerate(((-0.02, 0.34), (0.34, 0.22))):
        wedge(f"Shard_{index + 1}", (x, z), 0.085, 4, rim, y=-RELIEF * 0.9, roll=index * 0.7)


def em_numb_skin(ink, body, rim) -> None:
    """You stop feeling it before you stop taking it. A rimed forearm."""
    slab("Arm", (0.0, -0.04), (0.30, 0.56), mat("flesh_raw"), roll=0.16)
    for index, (x, z) in enumerate(((-0.14, 0.20), (0.12, 0.06), (-0.10, -0.14), (0.14, -0.26))):
        wedge(f"Rime_{index + 1}", (x, z), 0.095, 4, ink, y=-RELIEF * 0.7, roll=index * 0.4)


def em_patient_draw(ink, body, rim) -> None:
    """A bow held at full draw and not loosed. Frost has time to form on it."""
    crescent("Limb", (0.10, 0.0), 0.34, 0.075, mat("wood_bark"), arc=(0.72, 1.28), segments=11)
    bar("String", (-0.09, 0.32), (-0.09, -0.32), 0.035, mat("bone"))
    bar("Shaft", (-0.09, 0.0), (0.34, 0.0), 0.050, ink)
    wedge("Head", (0.38, 0.0), 0.085, 3, ink, roll=-math.pi * 0.5)
    for index, z in enumerate((0.20, -0.22)):
        wedge(f"Rime_{index + 1}", (0.26, z), 0.070, 4, rim, y=-RELIEF * 0.8, roll=index * 0.6)


def em_rime_shell(ink, body, rim) -> None:
    """A dome of ice grown over you. Layered, because it builds up."""
    for index, (r, material) in enumerate(((0.40, rim), (0.30, ink), (0.19, rim))):
        oval(f"Shell_{index + 1}", (0.0, -0.06), r, 9, material, squash=0.80,
             y=-RELIEF * 0.35 * index)
    slab("Ground", (0.0, -0.34), (0.86, 0.085), mat("stone_dark"), y=-RELIEF * 1.2)


def em_sanctum_frost(ink, body, rim) -> None:
    """A ward stone iced over: the Ward's own teal, gone cold."""
    wedge("Stone", (0.0, -0.14), 0.30, 6, mat("stone_ruin"), taper=0.62, roll=math.pi)
    wedge("Crystal", (0.0, 0.20), 0.20, 6, mat("ward_crystal"), taper=0.0)
    for index, (x, z) in enumerate(((-0.22, 0.06), (0.23, 0.02))):
        wedge(f"Rime_{index + 1}", (x, z), 0.095, 4, ink, y=-RELIEF * 0.7, roll=index * 0.5)


def em_still_breath(ink, body, rim) -> None:
    """Breath you can see, held. A mask and one slow cloud."""
    oval("Mask", (0.0, 0.04), 0.30, 7, mat("bone"), squash=1.05)
    for index, x in enumerate((-0.12, 0.12)):
        oval(f"Eye_{index + 1}", (x, 0.12), 0.075, 6, ink, squash=0.62, y=-RELIEF * 0.5)
    blob("Breath", (0.0, -0.30), (0.30, 0.11), rim, 17, y=-RELIEF * 0.7, lumps=4, lump=0.38)


def em_white_quiet(ink, body, rim) -> None:
    """The card that does the least on purpose: a flat white field, one horizon."""
    oval("Field", (0.0, -0.20), 0.44, 11, rim, squash=0.42)
    slab("Horizon", (0.0, 0.04), (0.72, 0.045), ink, y=-RELIEF * 0.5)
    for index, (x, z, r) in enumerate(((-0.20, 0.16, 0.055), (0.10, 0.24, 0.045), (0.26, 0.12, 0.038))):
        wedge(f"Fall_{index + 1}", (x, z), r, 4, rim, y=-RELIEF * 0.8)


def em_cellar_cache(ink, body, rim) -> None:
    """Cold and Fungal: a crock that keeps. Lid on, and something already growing."""
    wedge("Crock", (0.0, -0.14), 0.30, 8, ink, taper=0.78)
    slab("Lid", (0.0, 0.14), (0.60, 0.10), rim, y=-RELIEF * 0.35)
    bar("Knob", (0.0, 0.19), (0.0, 0.28), 0.075, rim)
    for index, x in enumerate((-0.16, 0.14)):
        oval(f"Bloom_{index + 1}", (x, -0.20), 0.080, 7, mat("fungus_cap"), squash=0.62,
             y=-RELIEF * 0.8)


def em_root_hold(ink, body, rim) -> None:
    """Fungal and Cold: roots frozen into the ground. You are not being moved."""
    bar("Trunk", (0.0, 0.38), (0.0, -0.06), 0.11, mat("wood_bark"))
    for index, (angle, _radius) in enumerate(radial(5, 1.0, seed=13, jitter=0.25)):
        end = (math.cos(angle) * 0.40, -0.12 + math.sin(angle) * 0.16)
        bar(f"Root_{index + 1}", (0.0, -0.08), end, 0.065, mat("wood_bark_dark"))
    for index, (x, z) in enumerate(((-0.26, -0.16), (0.24, -0.14), (0.0, -0.28))):
        wedge(f"Rime_{index + 1}", (x, z), 0.080, 4, rim, y=-RELIEF * 0.8, roll=index * 0.5)


# --- Fungal ----------------------------------------------------------------

def em_damp_stride(ink, body, rim) -> None:
    """Wet ground stops slowing you. A boot print filling with spores."""
    oval("Sole", (0.0, -0.08), 0.24, 9, ink, squash=1.5)
    oval("Heel", (0.0, -0.34), 0.16, 8, ink, squash=0.70)
    for index, x in enumerate((-0.14, -0.05, 0.05, 0.14)):
        wedge(f"Toe_{index + 1}", (x, 0.24), 0.060, 7, ink)
    for index, (x, z) in enumerate(((-0.28, 0.08), (0.28, -0.02), (0.24, 0.26))):
        oval(f"Spore_{index + 1}", (x, z), 0.055, 7, rim, squash=0.9, y=-RELIEF * 0.6)


def em_fruiting_call(ink, body, rim) -> None:
    """You call and the ground answers. A cluster, rising in a row."""
    for index, (x, z, r) in enumerate(((-0.26, -0.12, 0.15), (0.0, 0.06, 0.21), (0.26, -0.16, 0.13))):
        bar(f"Stem_{index + 1}", (x, z - r * 1.4), (x, z), 0.052, mat("bone"))
        oval(f"Cap_{index + 1}", (x, z + r * 0.30), r, 9, ink, squash=0.66, y=-RELIEF * 0.4)
    slab("Ground", (0.0, -0.36), (0.80, 0.075), mat("wood_bark_dark"), y=-RELIEF * 0.9)


def em_quiet_bloom(ink, body, rim) -> None:
    """One cap, still closed. Nothing has noticed it yet, which is the point."""
    bar("Stem", (0.0, -0.36), (0.0, 0.0), 0.095, mat("bone"))
    oval("Bud", (0.0, 0.14), 0.24, 9, ink, squash=1.25)
    wedge("Tip", (0.0, 0.40), 0.14, 3, ink)


def em_rot_chew(ink, body, rim) -> None:
    """Eat what should not be eaten. A cap with a bite out of it."""
    oval("Cap", (0.0, 0.06), 0.36, 11, ink, squash=0.86)
    oval("Bite", (0.28, 0.20), 0.16, 8, body, squash=0.9, y=RELIEF * 0.05)
    slab("Gills", (0.0, -0.16), (0.72, 0.11), mat("bone"), y=-RELIEF * 0.45)
    bar("Stem", (0.0, -0.40), (0.0, -0.14), 0.095, mat("bone"))


def em_slow_gut(ink, body, rim) -> None:
    """Food lasts because nothing is in a hurry. A coil, drawn as a spiral."""
    for index in range(22):
        t = index / 21.0
        angle = t * 2.4
        radius = 0.40 - t * 0.30
        nxt = (index + 1) / 21.0
        bar(f"Coil_{index + 1}",
            (math.cos(angle * math.tau) * radius, math.sin(angle * math.tau) * radius),
            (math.cos(nxt * 2.4 * math.tau) * (0.40 - nxt * 0.30),
             math.sin(nxt * 2.4 * math.tau) * (0.40 - nxt * 0.30)),
            0.075, ink if index % 4 < 2 else rim)


def em_spore_sole(ink, body, rim) -> None:
    """You leave a trail that keeps working after you have gone."""
    oval("Sole", (0.0, 0.12), 0.22, 9, ink, squash=1.45)
    oval("Heel", (0.0, -0.14), 0.15, 8, ink, squash=0.72)
    for index, (x, z, r) in enumerate(
            ((-0.30, -0.28, 0.075), (0.02, -0.38, 0.060), (0.30, -0.24, 0.050),
             (-0.32, 0.06, 0.045), (0.32, 0.10, 0.045))):
        oval(f"Puff_{index + 1}", (x, z), r, 7, rim, squash=0.85, y=-RELIEF * 0.6)


# --- Void ------------------------------------------------------------------

def em_deep_pocket(ink, body, rim) -> None:
    """A pouch whose mouth does not end where the pouch does."""
    wedge("Pouch", (0.0, -0.14), 0.32, 9, rim, taper=0.72)
    oval("Mouth", (0.0, 0.14), 0.30, 9, ink, squash=0.40)
    oval("Dark", (0.0, 0.13), 0.22, 9, mat("mire_black"), squash=0.34, y=-RELIEF * 0.5)
    slab("Cord", (0.0, 0.19), (0.66, 0.055), mat("wood_bark"), y=-RELIEF * 0.75)
    for index, (x, z) in enumerate(((-0.09, 0.02), (0.10, -0.06))):
        wedge(f"Spark_{index + 1}", (x, z), 0.055, 4, mat("crystal_tip"), y=-RELIEF * 0.9)


def em_empty_vessel(ink, body, rim) -> None:
    """An open jar with nothing in it, and the nothing is the useful part."""
    wedge("Jar", (0.0, -0.10), 0.28, 8, rim, taper=0.86)
    oval("Neck", (0.0, 0.22), 0.19, 8, rim, squash=0.44)
    oval("Void", (0.0, 0.21), 0.14, 8, mat("mire_black"), squash=0.40, y=-RELIEF * 0.5)
    for index, z in enumerate((0.02, -0.16)):
        oval(f"Ring_{index + 1}", (0.0, z), 0.28, 8, ink, squash=0.10, y=-RELIEF * 0.7)


def em_far_grasp(ink, body, rim) -> None:
    """Reach further than your arm. A hand coming through a ring."""
    crescent("Ring", (-0.08, 0.0), 0.30, 0.075, ink, arc=(0.0, 1.0), segments=12)
    slab("Palm", (0.18, -0.02), (0.26, 0.26), rim, y=-RELIEF * 0.5)
    for index, (x, z) in enumerate(((0.30, 0.14), (0.36, 0.02), (0.34, -0.12))):
        slab(f"Finger_{index + 1}", (x, z), (0.16, 0.062), rim, y=-RELIEF * 0.5, roll=index * 0.3)


def em_fletchers_debt(ink, body, rim) -> None:
    """An arrow you did not pay for yet. The fletching is coming apart into dark."""
    bar("Shaft", (-0.30, -0.24), (0.24, 0.22), 0.055, rim)
    wedge("Head", (0.32, 0.30), 0.11, 3, rim, roll=-math.pi * 0.25)
    for index, offset in enumerate((0.0, 0.09, 0.18)):
        bar(f"Fletch_{index + 1}", (-0.30 + offset, -0.24 + offset),
            (-0.40 + offset, -0.08 + offset), 0.070, ink, y=-RELIEF * 0.5)
    for index, (x, z) in enumerate(((-0.34, -0.34), (-0.16, -0.38))):
        wedge(f"Fray_{index + 1}", (x, z), 0.060, 4, mat("crystal_tip"), y=-RELIEF * 0.8)


def em_hollow_bargain(ink, body, rim) -> None:
    """Something for something. A ring split, with the halves not quite matching."""
    crescent("Half_L", (-0.06, 0.0), 0.30, 0.090, rim, arc=(0.28, 0.72), segments=9)
    crescent("Half_R", (0.06, 0.0), 0.30, 0.090, mat("crystal"), arc=(0.78, 1.22), segments=9)
    bar("Split", (0.0, 0.40), (0.0, -0.40), 0.045, ink, y=-RELIEF * 0.6)
    wedge("Toll", (0.0, 0.0), 0.10, 4, mat("crystal_tip"), y=-RELIEF * 0.9)


def em_thin_step(ink, body, rim) -> None:
    """You were here and the ground barely agrees. A print fading out of itself."""
    for index, (z, r, material) in enumerate(((0.22, 0.19, rim), (-0.02, 0.15, mat("mire_light")),
                                              (-0.24, 0.11, ink))):
        oval(f"Print_{index + 1}", (index * 0.10 - 0.10, z), r, 9, material, squash=1.35,
             y=-RELIEF * 0.2 * index)


def em_unseen_seam(ink, body, rim) -> None:
    """A crack in the world with light behind it."""
    points = ((-0.06, 0.44), (0.06, 0.20), (-0.08, -0.02), (0.08, -0.24), (-0.04, -0.44))
    for index in range(len(points) - 1):
        bar(f"Seam_{index + 1}", points[index], points[index + 1], 0.10, mat("mire_black"))
        bar(f"Light_{index + 1}", points[index], points[index + 1], 0.045,
            mat("crystal_tip"), y=-RELIEF * 0.6)


def em_skip_step(ink, body, rim) -> None:
    """Kinetic and Void: a chevron with the middle missing. You were not there for it."""
    chevron("Mark_A", (0.0, 0.36), 0.24, 0.20, 0.065, rim)
    chevron("Mark_C", (0.0, -0.10), 0.24, 0.20, 0.065, rim)
    for index, side in enumerate((-1.0, 1.0)):
        wedge(f"Ghost_{index + 1}", (side * 0.18, 0.06), 0.070, 4, mat("crystal_tip"),
              y=-RELIEF * 0.7, roll=0.3)


def em_gaunt_frame(ink, body, rim) -> None:
    """Void and Kinetic: less of you to carry. A ribcage with the ribs thinned."""
    bar("Spine", (0.0, 0.40), (0.0, -0.34), 0.070, rim)
    for index, z in enumerate((0.28, 0.14, 0.0, -0.14)):
        width = 0.34 - index * 0.045
        crescent(f"Rib_L_{index + 1}", (0.0, z), width, 0.050, rim, arc=(0.28, 0.72), segments=6)
        crescent(f"Rib_R_{index + 1}", (0.0, z), width, 0.050, rim, arc=(0.78, 1.22), segments=6)
    wedge("Hollow", (0.0, 0.06), 0.10, 4, ink, y=-RELIEF * 0.8)


def em_moss_shroud(ink, body, rim) -> None:
    """Fungal and Void: you are under something and it is growing. A hooded shape."""
    wedge("Hood", (0.0, 0.14), 0.34, 7, mat("moss"), taper=0.30, roll=math.pi)
    slab("Body", (0.0, -0.24), (0.44, 0.34), mat("moss_dark"), y=RELIEF * 0.05)
    oval("Face", (0.0, 0.06), 0.17, 8, mat("mire_black"), squash=1.05, y=-RELIEF * 0.5)
    for index, (x, z) in enumerate(((-0.20, 0.28), (0.18, 0.26), (0.0, 0.36))):
        oval(f"Tuft_{index + 1}", (x, z), 0.065, 7, mat("moss_light"), squash=0.7,
             y=-RELIEF * 0.7)


# --- Kinetic ---------------------------------------------------------------

def em_air_writ(ink, body, rim) -> None:
    """Permission to be somewhere you are not. A feather over a sealed slip."""
    slab("Writ", (0.0, -0.06), (0.40, 0.46), mat("bone"), roll=0.10)
    for index, z in enumerate((0.06, -0.06, -0.18)):
        slab(f"Line_{index + 1}", (0.0, z), (0.26, 0.032), mat("stone_dark"), y=-RELIEF * 0.4)
    wedge("Seal", (0.14, -0.26), 0.085, 8, mat("blood"), y=-RELIEF * 0.6)
    bar("Quill", (-0.28, -0.20), (0.16, 0.36), 0.055, ink, y=-RELIEF * 0.8)
    for index, t in enumerate((0.45, 0.62, 0.78)):
        bar(f"Barb_{index + 1}", (-0.28 + 0.44 * t, -0.20 + 0.56 * t),
            (-0.40 + 0.44 * t, -0.10 + 0.56 * t), 0.045, rim, y=-RELIEF * 0.95)


def em_bellows_lung(ink, body, rim) -> None:
    """Air on demand. A bellows, mid-squeeze."""
    wedge("Body", (-0.06, 0.0), 0.32, 6, ink, taper=0.40, roll=-math.pi * 0.5)
    for index, z in enumerate((0.14, 0.0, -0.14)):
        slab(f"Pleat_{index + 1}", (-0.10, z), (0.34, 0.030), mat("wood_bark_dark"),
             y=-RELIEF * 0.5)
    bar("Nozzle", (0.20, 0.0), (0.40, 0.0), 0.070, mat("iron"))
    for index, (angle, _radius) in enumerate(radial(3, 1.0, seed=9, jitter=0.3)):
        bar(f"Puff_{index + 1}", (0.42, 0.0),
            (0.42 + math.cos(angle) * 0.10, math.sin(angle) * 0.16), 0.038, rim,
            y=-RELIEF * 0.8)


def em_cat_fall(ink, body, rim) -> None:
    """You land and keep going. A paw with an arc coming into it."""
    oval("Pad", (0.0, -0.16), 0.22, 9, ink, squash=0.80)
    for index, (x, z) in enumerate(((-0.20, 0.06), (-0.07, 0.14), (0.07, 0.14), (0.20, 0.06))):
        oval(f"Toe_{index + 1}", (x, z), 0.090, 8, ink, squash=0.90)
    crescent("Fall", (0.0, 0.30), 0.32, 0.060, rim, arc=(0.56, 0.94))


def em_long_bound(ink, body, rim) -> None:
    """One jump, further than it should be. A long flat arc with a mark at each end."""
    crescent("Arc", (0.0, -0.24), 0.44, 0.070, rim, arc=(0.06, 0.44), segments=13)
    for index, x in enumerate((-0.40, 0.40)):
        wedge(f"Foot_{index + 1}", (x, -0.24), 0.085, 4, ink, y=-RELIEF * 0.5)
    chevron("Tip", (0.30, 0.14), 0.14, 0.12, 0.055, ink)


def em_loping_gait(ink, body, rim) -> None:
    """Not fast — tireless. Two offset chevrons, one always trailing."""
    chevron("Lead", (-0.10, 0.30), 0.24, 0.26, 0.070, ink)
    chevron("Trail", (0.12, -0.06), 0.24, 0.26, 0.070, rim)
    slab("Ground", (0.0, -0.40), (0.76, 0.055), mat("wood_bark_dark"), y=-RELIEF * 0.5)


def em_second_wind(ink, body, rim) -> None:
    """Stamina you had already spent. A spiral coming back around."""
    for index in range(18):
        t = index / 17.0
        angle = 0.15 + t * 1.05
        radius = 0.16 + t * 0.26
        nxt = (index + 1) / 17.0
        bar(f"Swirl_{index + 1}",
            (math.cos(angle * math.tau) * radius, math.sin(angle * math.tau) * radius),
            (math.cos((0.15 + nxt * 1.05) * math.tau) * (0.16 + nxt * 0.26),
             math.sin((0.15 + nxt * 1.05) * math.tau) * (0.16 + nxt * 0.26)),
            0.075, ink if t < 0.5 else rim)
    wedge("Head", (0.42, 0.12), 0.10, 3, rim, roll=-0.5)


def em_spent_spring(ink, body, rim) -> None:
    """A coil already compressed: the power is stored, not spent yet."""
    for index, z in enumerate((0.30, 0.19, 0.08, -0.03, -0.14)):
        oval(f"Coil_{index + 1}", (0.0, z), 0.30 - index * 0.012, 9,
             ink if index % 2 == 0 else rim, squash=0.16, y=-RELIEF * 0.10 * index)
    slab("Plate", (0.0, -0.30), (0.70, 0.10), mat("iron"), y=-RELIEF * 0.2)
    slab("Cap", (0.0, 0.40), (0.56, 0.085), mat("iron"), y=-RELIEF * 0.2)


def em_pack_frame(ink, body, rim) -> None:
    """Kinetic and Fungal: a carrying frame, grown rather than built."""
    for index, x in enumerate((-0.18, 0.18)):
        bar(f"Rail_{index + 1}", (x, 0.40), (x, -0.36), 0.075, mat("wood_bark"))
    for index, z in enumerate((0.26, 0.04, -0.18)):
        slab(f"Rung_{index + 1}", (0.0, z), (0.44, 0.065), mat("wood_bark_dark"),
             y=-RELIEF * 0.35)
    for index, (x, z) in enumerate(((-0.30, 0.16), (0.30, -0.06), (0.28, 0.30))):
        oval(f"Growth_{index + 1}", (x, z), 0.075, 7, mat("fungus_cap"), squash=0.66,
             y=-RELIEF * 0.6)


# --- Untagged: utility, economy and the four attunement sigils ---------------

def em_bottomless_quiver(ink, body, rim) -> None:
    """Arrows that do not run out. A quiver too full to close."""
    wedge("Quiver", (0.0, -0.16), 0.24, 8, mat("wood_bark"), taper=0.86)
    slab("Strap", (0.0, -0.10), (0.56, 0.075), mat("wood_bark_dark"), y=-RELIEF * 0.4)
    for index, (x, roll) in enumerate(((-0.13, 0.20), (0.0, 0.0), (0.13, -0.20))):
        bar(f"Shaft_{index + 1}", (x, 0.10), (x + roll * 0.6, 0.42), 0.045, ink)
        for feather in range(2):
            bar(f"Fletch_{index + 1}_{feather + 1}", (x + roll * 0.5, 0.32 + feather * 0.05),
                (x + roll * 0.5 + (0.07 if feather else -0.07), 0.40 + feather * 0.04),
                0.042, rim, y=-RELIEF * 0.5)


def em_coin_worm(ink, body, rim) -> None:
    """Money that finds you. A worm of coins coming out of the ground."""
    for index, (x, z, r) in enumerate(
            ((-0.30, -0.28, 0.11), (-0.13, -0.10, 0.13), (0.06, 0.08, 0.15), (0.24, 0.26, 0.16))):
        oval(f"Coin_{index + 1}", (x, z), r, 9, mat("gold"), squash=0.94,
             y=-RELIEF * 0.18 * index)
        wedge(f"Face_{index + 1}", (x, z), r * 0.52, 8, mat("brass_dark"),
              y=-RELIEF * (0.18 * index + 0.5))
    slab("Soil", (0.0, -0.40), (0.82, 0.10), mat("wood_bark_dark"), y=-RELIEF * 0.2)


def em_eggshell_warlord(ink, body, rim) -> None:
    """Enormous damage, and one hit kills you. A crown on a cracked shell."""
    oval("Shell", (0.0, -0.10), 0.30, 9, mat("bone"), squash=1.15)
    for index, points in enumerate((((-0.14, 0.06), (-0.04, -0.10), (-0.16, -0.24)),
                                    ((0.10, 0.10), (0.18, -0.06), (0.08, -0.22)))):
        for step in range(len(points) - 1):
            bar(f"Crack_{index}_{step}", points[step], points[step + 1], 0.040,
                mat("stone_dark"), y=-RELIEF * 0.5)
    slab("Band", (0.0, 0.26), (0.44, 0.065), mat("gold"), y=-RELIEF * 0.6)
    for index, x in enumerate((-0.16, 0.0, 0.16)):
        wedge(f"Point_{index + 1}", (x, 0.38), 0.085, 3, mat("gold"), y=-RELIEF * 0.6)


def em_foremans_whistle(ink, body, rim) -> None:
    """Everyone works faster. A whistle, and the note leaving it."""
    wedge("Body", (-0.10, -0.06), 0.24, 6, mat("brass"), taper=0.70, roll=-math.pi * 0.5)
    bar("Mouth", (-0.34, -0.06), (-0.16, -0.06), 0.11, mat("brass_dark"))
    wedge("Ring", (-0.10, 0.20), 0.075, 8, mat("brass_dark"))
    for index, (r, material) in enumerate(((0.20, mat("bone")), (0.30, mat("stone_dark")))):
        crescent(f"Note_{index + 1}", (0.14, 0.0), r, 0.055, material, arc=(0.86, 1.14),
                 segments=7)


def em_second_sunrise(ink, body, rim) -> None:
    """The day gets a second go. A sun clearing a horizon, with rays."""
    for index, (angle, _radius) in enumerate(radial(7, 1.0, seed=21, jitter=0.0)):
        if math.sin(angle) < -0.1:
            continue
        bar(f"Ray_{index + 1}", (math.cos(angle) * 0.26, 0.02 + math.sin(angle) * 0.26),
            (math.cos(angle) * 0.44, 0.02 + math.sin(angle) * 0.44), 0.060, mat("gold"))
    oval("Sun", (0.0, 0.02), 0.22, 11, mat("flame"))
    slab("Horizon", (0.0, -0.12), (0.86, 0.075), mat("stone_dark"), y=-RELIEF * 0.6)
    slab("Land", (0.0, -0.32), (0.86, 0.28), mat("wood_bark_dark"), y=-RELIEF * 0.4)


def em_seven_league_waders(ink, body, rim) -> None:
    """Water stops mattering. One very tall boot, and the line it walks past."""
    slab("Leg", (-0.04, 0.10), (0.26, 0.56), mat("wood_bark"))
    slab("Foot", (0.08, -0.26), (0.46, 0.20), mat("wood_bark"))
    slab("Sole", (0.08, -0.38), (0.50, 0.075), mat("wood_bark_dark"), y=-RELIEF * 0.2)
    slab("Cuff", (-0.04, 0.36), (0.32, 0.085), mat("bone"), y=-RELIEF * 0.4)
    for index, z in enumerate((-0.06, -0.16)):
        slab(f"Water_{index + 1}", (0.0, z), (0.84, 0.040), mat("ward_crystal"),
             y=-RELIEF * 0.8)


def em_wellspring_heart(ink, body, rim) -> None:
    """The Wellspring keeps a piece of you. A basin with a rising column."""
    wedge("Basin", (0.0, -0.26), 0.34, 8, mat("stone_ruin"), taper=0.62, roll=math.pi)
    oval("Water", (0.0, -0.14), 0.30, 9, mat("ward_crystal"), squash=0.26, y=-RELIEF * 0.4)
    bar("Column", (0.0, -0.12), (0.0, 0.26), 0.13, mat("ward_crystal_light"), y=-RELIEF * 0.5)
    heart("Core", (0.0, 0.24), 0.24, mat("ward_crystal"), y=-RELIEF * 0.8)


def em_attunement_forager(ink, body, rim) -> None:
    """Forager: a hand-shaped sigil round a seed. Gathering, not taking."""
    crescent("Cup_L", (0.0, -0.04), 0.32, 0.085, mat("moss"), arc=(0.52, 0.98), segments=11)
    oval("Seed", (0.0, 0.04), 0.16, 8, mat("leaf_light"), squash=1.25, y=-RELIEF * 0.5)
    bar("Sprout", (0.0, 0.14), (0.0, 0.34), 0.045, mat("moss_light"), y=-RELIEF * 0.7)
    for index, side in enumerate((-1.0, 1.0)):
        oval(f"Leaf_{index + 1}", (side * 0.11, 0.32), 0.10, 7, mat("leaf"), squash=0.50,
             y=-RELIEF * 0.7, roll=side * 0.4)


def em_attunement_reaver(ink, body, rim) -> None:
    """Reaver: two crossed blades over a notched ring. Take it by force."""
    crescent("Ring", (0.0, 0.0), 0.34, 0.060, mat("iron_dark"), arc=(0.0, 1.0), segments=12)
    for index, roll in enumerate((0.72, -0.72)):
        slab(f"Blade_{index + 1}", (0.0, 0.02), (0.10, 0.62), mat("iron_light"), roll=roll,
             y=-RELIEF * 0.4)
    wedge("Boss", (0.0, 0.0), 0.11, 8, mat("blood"), y=-RELIEF * 0.9)


def em_attunement_tinker(ink, body, rim) -> None:
    """Tinker: a cog with one tooth replaced by something improvised."""
    for index, (angle, _radius) in enumerate(radial(8, 1.0, seed=31, jitter=0.0)):
        material = mat("brass") if index else mat("wood_bark")
        slab(f"Tooth_{index + 1}", (math.cos(angle) * 0.33, math.sin(angle) * 0.33),
             (0.15, 0.15), material, roll=angle)
    oval("Cog", (0.0, 0.0), 0.28, 11, mat("brass_dark"))
    oval("Bore", (0.0, 0.0), 0.11, 8, mat("stone_dark"), y=-RELIEF * 0.6)


def em_attunement_warden(ink, body, rim) -> None:
    """Warden: the Ward's own crystal inside a closed shield."""
    oval("Shield", (0.0, 0.10), 0.32, 6, mat("iron"), squash=1.05)
    wedge("Shield_Point", (0.0, -0.22), 0.32, 3, mat("iron"), roll=math.pi)
    wedge("Crystal", (0.0, 0.08), 0.16, 6, mat("ward_crystal"), y=-RELIEF * 0.5)
    wedge("Crystal_Core", (0.0, 0.08), 0.075, 6, mat("ward_crystal_light"), y=-RELIEF * 0.9)


# ---------------------------------------------------------------------------
# Registry, render, sheet
# ---------------------------------------------------------------------------
#
# `EMBLEMS` maps a powerup id to (tags, builder). The tags are repeated here
# rather than read out of the `.tres` on purpose: this script runs inside Blender
# with no Godot available, and a tag list that silently disagreed with the
# definition would give a card the wrong family colour with nothing to catch it.
# `tools/powerup_icon_check.gd` compares the two from the Godot side instead.

EMBLEMS: dict[str, tuple[list[str], Callable]] = {
    "adrenal_bloom": (["Blood", "Kinetic"], em_adrenal_bloom),
    "air_writ": (["Kinetic"], em_air_writ),
    "ashen_temper": (["Fire"], em_ashen_temper),
    "attunement_forager": ([], em_attunement_forager),
    "attunement_reaver": ([], em_attunement_reaver),
    "attunement_tinker": ([], em_attunement_tinker),
    "attunement_warden": ([], em_attunement_warden),
    "bellows_lung": (["Kinetic"], em_bellows_lung),
    "bottomless_quiver": ([], em_bottomless_quiver),
    "cat_fall": (["Kinetic"], em_cat_fall),
    "cauter_seal": (["Fire", "Blood"], em_cauter_seal),
    "cellar_cache": (["Cold", "Fungal"], em_cellar_cache),
    "chill_edge": (["Cold"], em_chill_edge),
    "cinder_tithe": (["Fire", "Void"], em_cinder_tithe),
    "coin_worm": ([], em_coin_worm),
    "damp_stride": (["Fungal"], em_damp_stride),
    "deep_frost": (["Cold"], em_deep_frost),
    "deep_pocket": (["Void"], em_deep_pocket),
    "eggshell_warlord": ([], em_eggshell_warlord),
    "ember_knuckle": (["Fire"], em_ember_knuckle),
    "empty_vessel": (["Void"], em_empty_vessel),
    "far_grasp": (["Void"], em_far_grasp),
    "flashover": (["Fire"], em_flashover),
    "fletchers_debt": (["Void"], em_fletchers_debt),
    "foremans_whistle": ([], em_foremans_whistle),
    "forge_blood": (["Fire"], em_forge_blood),
    "fruiting_call": (["Fungal"], em_fruiting_call),
    "gaunt_frame": (["Void", "Kinetic"], em_gaunt_frame),
    "grave_due": (["Void", "Blood"], em_grave_due),
    "hollow_bargain": (["Void"], em_hollow_bargain),
    "iron_tongue": (["Blood"], em_iron_tongue),
    "long_bound": (["Kinetic"], em_long_bound),
    "loping_gait": (["Kinetic"], em_loping_gait),
    "moss_shroud": (["Fungal", "Void"], em_moss_shroud),
    "night_pyre": (["Fire"], em_night_pyre),
    "numb_skin": (["Cold"], em_numb_skin),
    "open_flame": (["Fire"], em_open_flame),
    "pack_frame": (["Kinetic", "Fungal"], em_pack_frame),
    "pact_cut": (["Blood"], em_pact_cut),
    "pale_guard": (["Cold"], em_pale_guard),
    "patient_draw": (["Cold"], em_patient_draw),
    "quiet_bloom": (["Fungal"], em_quiet_bloom),
    "red_quench": (["Blood"], em_red_quench),
    "rich_marrow": (["Fungal", "Blood"], em_rich_marrow),
    "rime_shell": (["Cold"], em_rime_shell),
    "root_hold": (["Fungal", "Cold"], em_root_hold),
    "rot_chew": (["Fungal"], em_rot_chew),
    "sanctum_frost": (["Cold"], em_sanctum_frost),
    "scab_feast": (["Blood", "Fungal"], em_scab_feast),
    "sealed_veins": (["Blood"], em_sealed_veins),
    "second_glance": (["Void"], em_second_glance),
    "second_sunrise": ([], em_second_sunrise),
    "second_wind": (["Kinetic"], em_second_wind),
    "seven_league_waders": ([], em_seven_league_waders),
    "skip_step": (["Kinetic", "Void"], em_skip_step),
    "slow_gut": (["Fungal"], em_slow_gut),
    "spent_spring": (["Kinetic"], em_spent_spring),
    "spore_sole": (["Fungal"], em_spore_sole),
    "steady_hands": (["Blood", "Cold"], em_steady_hands),
    "still_breath": (["Cold"], em_still_breath),
    "stubborn_heart": (["Blood"], em_stubborn_heart),
    "swift_stride": (["Kinetic"], em_swift_stride),
    "the_landlord": ([], em_the_landlord),
    "thick_hide": (["Blood"], em_thick_hide),
    "thin_step": (["Void"], em_thin_step),
    "tinder_snap": (["Fire"], em_tinder_snap),
    "unseen_seam": (["Void"], em_unseen_seam),
    "warm_marrow": (["Fire", "Cold"], em_warm_marrow),
    "wellspring_heart": ([], em_wellspring_heart),
    "whetted_thirst": (["Blood"], em_whetted_thirst),
    "white_quiet": (["Cold"], em_white_quiet),
    "wide_cap": (["Fungal"], em_wide_cap),
}


def fit_to_plaque(motif: list[bpy.types.Object]) -> float:
    """Shrink a motif until it is inside its own plaque, and report the factor.

    Seventy-two builders authored by hand against a coordinate budget is
    seventy-two chances to be a few hundredths over, and the first full contact
    sheet showed it: a dozen cards had a cap, a boot or a coin hanging past the
    frame. Rather than hand-trimming each one — which only holds until the next
    edit — the extent is MEASURED here and scaled to fit. A builder that is
    already inside is untouched, so this costs nothing when it is not needed.

    Deliberately uniform and about the origin: squashing to fit would silently
    distort shapes that were authored round, and re-centring would slide
    deliberately off-centre compositions back to the middle."""
    if not motif:
        return 1.0
    reach = 0.0
    for obj in motif:
        for corner in obj.bound_box:
            point = obj.matrix_world @ Vector(corner)
            reach = max(reach, math.hypot(point.x, point.z))
    limit = PLAQUE_BODY * 0.94
    factor = min(1.0, limit / reach) if reach > 1e-6 else 1.0
    bpy.ops.object.select_all(action="DESELECT")
    for obj in motif:
        obj.select_set(True)
        obj.scale = (factor, 1.0, factor)
        obj.location = (obj.location.x * factor, obj.location.y, obj.location.z * factor)
    bpy.context.view_layer.objects.active = motif[0]
    bpy.ops.object.transform_apply(scale=True)
    bpy.ops.object.select_all(action="DESELECT")
    return factor


def clear() -> None:
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for blocks in (bpy.data.meshes, bpy.data.objects):
        for block in list(blocks):
            try:
                blocks.remove(block, do_unlink=True)
            except (RuntimeError, ReferenceError):
                pass


def eevee_name() -> str:
    items = bpy.types.RenderSettings.bl_rna.properties["engine"].enum_items.keys()
    for candidate in ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE"):
        if candidate in items:
            return candidate
    return items[0]


def build_rig() -> None:
    """Face-on orthographic, transparent film, and a key from the upper left.

    Deliberately NOT `render_item_icons.py`'s rig. That one hunts for the roll
    and elevation that pack an arbitrary prop's silhouette best, which is right
    for a 3D object of unknown shape and wrong here: an emblem is a low relief
    AUTHORED to be seen square-on, and letting a heuristic tilt it would throw
    away the alignment every one of these is built around."""
    scene = bpy.context.scene
    scene.render.engine = eevee_name()
    scene.render.resolution_x = ICON_SIZE
    scene.render.resolution_y = ICON_SIZE
    scene.render.resolution_percentage = 100
    scene.render.film_transparent = True
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    scene.view_settings.look = "AgX - Punchy"

    world = bpy.data.worlds.new("IconWorld")
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs[0].default_value = (0.20, 0.21, 0.24, 1.0)
    world.node_tree.nodes["Background"].inputs[1].default_value = 0.9
    scene.world = world

    camera_data = bpy.data.cameras.new("IconCam")
    camera_data.type = "ORTHO"
    camera_data.ortho_scale = FACE * 1.26
    camera = bpy.data.objects.new("IconCam", camera_data)
    camera.location = (0.0, -6.0, 0.0)
    camera.rotation_euler = (math.pi * 0.5, 0.0, 0.0)
    scene.collection.objects.link(camera)
    scene.camera = camera

    key = bpy.data.objects.new("IconKey", bpy.data.lights.new("IconKey", type="SUN"))
    key.data.energy = 3.6
    key.rotation_euler = (math.radians(62.0), math.radians(-26.0), math.radians(-34.0))
    scene.collection.objects.link(key)

    fill = bpy.data.objects.new("IconFill", bpy.data.lights.new("IconFill", type="SUN"))
    fill.data.energy = 1.5
    fill.rotation_euler = (math.radians(108.0), 0.0, math.radians(150.0))
    scene.collection.objects.link(fill)


def main() -> None:
    EXPORT_DIR.mkdir(parents=True, exist_ok=True)
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    only = opt("--only", "")
    reset_materials()
    clear()
    for blocks in (bpy.data.materials, bpy.data.cameras, bpy.data.lights, bpy.data.worlds):
        for block in list(blocks):
            try:
                blocks.remove(block, do_unlink=True)
            except (RuntimeError, ReferenceError):
                pass
    build_rig()

    rendered: list[str] = []
    catalog: list[dict] = []
    for identifier, (tags, builder) in EMBLEMS.items():
        if only and only not in identifier:
            continue
        for obj in [o for o in bpy.context.scene.objects if o.type == "MESH"]:
            bpy.data.objects.remove(obj, do_unlink=True)
        palette = plaque(list(tags))
        before = {o.name for o in bpy.context.scene.objects}
        builder(palette["ink"], palette["body"], palette["rim"])
        # The motif is authored inside a comfortable half-unit and then blown up
        # to fill the plaque. Authoring at final size instead meant every builder
        # carried the same constant in every coordinate, and the first eight came
        # out small and timid inside their own frames.
        motif = [o for o in bpy.context.scene.objects if o.name not in before and o.type == "MESH"]
        fit_to_plaque(motif)
        polygons = sum(len(o.data.polygons) for o in bpy.context.scene.objects if o.type == "MESH")
        target = EXPORT_DIR / f"icon_powerup_{identifier}.png"
        bpy.context.scene.render.filepath = str(target)
        bpy.ops.render.render(write_still=True)
        rendered.append(identifier)
        catalog.append({"id": identifier, "tags": list(tags), "polygons": polygons,
                        "icon": f"icon_powerup_{identifier}.png"})
        print(f"  icon {identifier} ({polygons} polygons)", flush=True)

    (ICON_DIR / "powerup_catalog.json").write_text(
        json.dumps(catalog, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"\nPOWERUP_ICONS built={len(rendered)}")


with import_cache_guard():
    main()
