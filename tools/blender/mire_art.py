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
from typing import Callable, Sequence

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
    # Bogsilver, the tier-4 metal (D-200). It has to be told apart from `iron` at a
    # glance and across a clearing, and iron already owns cool mid-grey — so the
    # separation is HUE and CONTRAST, not lightness. Modelled on what actually
    # happens to silver in a bog: anoxic, sulphur-rich water tarnishes it, and real
    # tarnish runs pale straw -> brown -> blue-black rather than simply darker grey.
    # So the body carries a faint warm-green cast, the recesses go almost black, and
    # the ground edge is nearly white. That spread is the tell; a flat pale grey head
    # would read as "iron, lit slightly differently" in fog, which is the failure.
    # Deliberately NOT gold-warm: brass and gold own warm metal already.
    "bogsilver_dark": Swatch("#2F3742", 0.58, 0.68, note="bogsilver tarnish: eyes, sockets, crevices"),
    "bogsilver": Swatch("#C6C9B6", 0.34, 0.84, note="bogsilver tool bodies and fittings"),
    "bogsilver_light": Swatch("#F0F2E2", 0.16, 0.90, note="ground bogsilver cutting edges only"),
    "bogsilver_crust": Swatch("#6B7362", 0.88, 0.10, note="dull mineral crust on unworked bogsilver in rock"),
    # Wellglass, the tier-5 material (D-200). It comes out of a capped Wellspring, so
    # it belongs to the cleansed side of that language — but Ward teal is RESERVED and
    # means "you are safe here", and an axe must never make that promise. Wellglass is
    # therefore greener and much dimmer than `ward_crystal`/`clear_liquid`: emission
    # 0.7-1.3 against the Ward's 2.2-3.4, so a shard catches light without glowing at
    # you. Modelled on obsidian and on sea glass rather than on gemstone: real volcanic
    # glass breaks by CONCHOIDAL FRACTURE, shallow curved facets meeting at edges
    # thinner than steel can hold, which is both why the tools are built knapped rather
    # than forged and why "the edge does not dull" is a true sentence about it.
    "wellglass_dark": Swatch("#2C5A5C", 0.30, 0.00, note="wellglass body seen through thickness; shadowed facets"),
    # Emission stays LOW here — 0.30/0.90, not the Ward's 2.2-3.4. The first pass ran 0.7/1.3 and
    # the render came back near-white: at that strength the emission drowns the base colour and a
    # teal blade reads as a bulb. It has to catch light, not make it.
    "wellglass": Swatch("#5FA79B", 0.20, 0.00, "#6FC9B4", 0.30, note="wellglass blade faces"),
    "wellglass_light": Swatch("#C4EDDD", 0.12, 0.00, "#B6FFE6", 0.90, note="fresh conchoidal fracture and the edge itself"),
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
    # Flora family (A-000V). Added, never edited — existing tokens are untouched so
    # nothing downstream needed a rebuild. Authored as base colours in the same
    # brightness band as the foliage above, not eyeballed off a tone-mapped render.
    "leaf_pale": Swatch("#B7CE8E", 0.92, note="leaf undersides and new growth"),
    "leaf_dry": Swatch("#A88E52", 0.93, note="leaves partway to dead, still on the plant"),
    "leaf_litter": Swatch("#7C5A34", 0.95, note="fallen leaves on the ground"),
    "moss_dark": Swatch("#46753E", 0.96, note="shadowed moss, patch edges"),
    "moss_light": Swatch("#86B96A", 0.95, note="lit moss crowns"),
    "bracken": Swatch("#86A24E", 0.94, note="bracken and other yellow-green fronds"),
    "sedge": Swatch("#7E9A55", 0.94, note="sedge and marsh blades; darker and duller than reed"),
    # Blossom is the one bright thing on the ground, so it stays small in area and
    # cool-to-neutral: warm accents belong to fire and brass, purple to the Mire.
    "flower_white": Swatch("#E8E6D4", 0.90, note="small white blooms and bog cotton"),
    "flower_cream": Swatch("#EFD9A0", 0.90, note="cream umbels"),
    "flower_yellow": Swatch("#E0C24A", 0.90, note="yellow blooms; use in small heads only"),
    "flower_rust": Swatch("#C1663F", 0.91, note="rust seed spikes and burrs"),
    "flower_pink": Swatch("#D2879C", 0.90, note="dusty pink blooms; never saturated toward the Mire"),
    # Fungus is the one place a non-corruption pink/blue is allowed. Kept muted so
    # it never competes with the reserved Mire purple or Ward teal.
    "fungus_cap": Swatch("#A8437F", 0.88, note="pink toadstool cap"),
    "fungus_blue": Swatch("#4A79A8", 0.88, note="blue toadstool cap"),
    #: The EDIBLE fungus, and it has to be a different family of colour from the
    #: two above, not a different shade of them. `fungus_cap`'s pink and
    #: `fungus_blue`'s blue are mire-growth signal colours — they mean "this grew
    #: out of the corruption" — so a mushroom a player is meant to eat cannot
    #: borrow either. A field mushroom is buff-brown with a paler stem, which is
    #: both what the real thing looks like and the one fungus colour the swamp has
    #: not already spoken for.
    "fungus_edible": Swatch("#9C7B55", 0.90, note="buff-brown edible mushroom cap"),
    "fungus_gill": Swatch("#DCCDB4", 0.88, note="pale gills and stem of an edible mushroom"),
    # Gatherable plants and deposits (A-011). Added, never edited. Berry red is
    # deliberately a true red and not the Mire's purple — a berry a player has to
    # decide about must never read as corruption, which is the one hue that already
    # means "do not touch". `berry_bloom` is the pale waxy film on real berry skin,
    # and it is this family's whole poison tell: `ITEMS.md` says the poison berry
    # "looks almost identical", so the difference had to be something a player can
    # learn but not something they spot across a clearing.
    "berry": Swatch("#B32F35", 0.84, note="ripe edible berry; true red, never toward the Mire"),
    "berry_bloom": Swatch("#C9909A", 0.78, note="pale waxy bloom on berry skin; the poison tell"),
    #: Tree fruit, which is not a berry: an apple is bigger, lighter and never one
    #: flat colour. `apple` is the sunward blush and `apple_shade` the green-gold
    #: cheek that never saw the sun, and every apple gets both — a single-colour
    #: apple reads as a red ball, which is what a cherry looks like.
    "apple": Swatch("#C2402F", 0.82, note="sunward blush on ripe apple skin"),
    "apple_shade": Swatch("#C9B24C", 0.84, note="the green-gold cheek of the same apple"),
    "wax": Swatch("#D8AC5E", 0.88, note="honeycomb wax"),
    "honey": Swatch("#C67C24", 0.42, note="honey in the cell; the low roughness is the wetness"),
    "clay": Swatch("#A57E5B", 0.68, note="riverbank clay; less rough than dirt because it is damp"),
    "peat": Swatch("#4C3A2B", 0.94, note="cut wet peat; darker and browner than charred wood"),
    "resin": Swatch("#B0611A", 0.38, note="amber sap; deliberately deeper than wood_cut (#DDAA65), which it is always seen against — the first value was #CE8A33 and the sap read as more cut wood"),
    # Food and tonics (A-012). A tonic is read by the colour of what is in the
    # flask, so these four have to be separable at inventory-icon size, in fog,
    # and next to each other: warm red, cold pale, amber, and the one that is
    # obviously wrong. None of them may drift toward the reserved Mire purple or
    # Ward teal — a healing draught must never read as corruption.
    "tonic_red": Swatch("#C4384A", 0.30, note="healing draught; warmer and lighter than blood (#7A1E1E), which is a wound, not a cure"),
    "tonic_pale": Swatch("#BFD8D2", 0.26, note="Pale Draught, the Blight cleanse; desaturated toward white so it never reads as Ward teal"),
    "tonic_amber": Swatch("#D99B2E", 0.28, note="stamina tonic; distinct from honey (#C67C24) by being yellower, because both are seen in glass"),
    "sludge": Swatch("#6E7A3C", 0.52, note="Suspicious Sludge; the one food colour allowed to look wrong. Olive, not green — a green would read as healthy"),
    "broth": Swatch("#9A6432", 0.34, note="stew in a bowl; low roughness is the surface, and it sits between cooked meat and clay so a bowl reads as full"),
    "bread_crust": Swatch("#A76A34", 0.86, note="baked crust; browner than wood_cut so a loaf is never mistaken for a cut end"),
    "bread_crumb": Swatch("#E2C88F", 0.90, note="the open crumb of a torn loaf"),
    "fish_scale": Swatch("#7E93A0", 0.52, note="bog fish flank; a cold grey-blue that is the only cool NATURAL colour in the food kit"),
    "fish_belly": Swatch("#D9D3C0", 0.60, note="pale fish underside and the flesh a cooked fish shows"),
    # Roads (A-014). Standing water on a road is NOT `clear_liquid` (Ward teal) and
    # NOT `mire_liquid` (corruption purple) — both of those hues mean something in
    # this game, and a puddle that borrows either is telling the player a lie about
    # the road they are standing on. This is dirty water over dark ground.
    "water_still": Swatch("#3E3B31", 0.12, note="standing water in a rut. Browner than it looks right in isolation, because the first value (#41504B) read as Ward teal from above, which is exactly the association a puddle must not carry"),
    # Wetland gatherables II (A-043). Bioluminescence needs a hue that is not
    # already spoken for: purple is the Mire, teal is the Ward, ember/flame are
    # fire, `critical` is damage and `eye` is an enemy looking at you. A cold green
    # glow is the one bright thing left that means "this is safe and useful", which
    # is what a light-source ingredient should say from across a dark swamp.
    "glowcap": Swatch("#C3DE84", 0.62, 0.0, "#CBFF63", 2.4, note="bioluminescent mushroom cap"),
    "glowcap_gill": Swatch("#8FA85C", 0.70, note="shaded gills under a glowcap; unlit on purpose so the cap reads as the light"),
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
    "chitin_light": Swatch("#A290AD", 0.60, note="lit carapace plates"),
    "nest": Swatch("#7E6579", 0.88, note="crawler nest wall"),
    "nest_dark": Swatch("#5B4658", 0.90),
    "throat": Swatch("#3C2C42", 0.95, note="the dark inside a nest mouth"),
    "eye": Swatch("#FFCE69", 0.18, 0.0, "#FFC459", 4.2, note="crawler eye; the one warm emissive on an enemy"),
    "lichen": Swatch("#C8CE81", 0.94, note="yellow-green crust on old stone"),
    "chitin_dark": Swatch("#4D3E5B", 0.72, note="crawler shell shadow"),
    "chitin": Swatch("#735D81", 0.68, note="crawler shell"),
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
    # -- terrain: the authored maps' own ground planes ---------------------
    "terrain_ground": Swatch("#4D6F48", 0.98, note="map ground plane"),
    "terrain_path": Swatch("#79674D", 1.00, note="worn dirt route"),
    "terrain_mire": Swatch("#615B6F", 0.72, note="corrupted ground"),
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
    "pickup_apple": 0.17,           # two apples plus a twig, each 0.086 across
    "pickup_raw_meat": 0.30,        # a cut off the bone, not a whole carcass
    "pickup_stone": 0.18,
    "pickup_flint": 0.13,
    "pickup_coal": 0.16,            # small heap of lumps
    "pickup_iron_ore": 0.20,
    "pickup_iron_ingot": 0.26,
    # Tier 4/5 (D-200). Bogsilver ore is a shade larger than iron ore because it comes out of the
    # rock as one nodule rather than as a broken chunk; the ingot shares the iron mould exactly.
    "pickup_bogsilver_ore": 0.22,
    "pickup_bogsilver_ingot": 0.26,
    "pickup_wellglass_shard": 0.18,   # three pieces of one break, largest ~0.10
    "pickup_guardian_core": 0.20,     # two-handed, but it fits in a pack
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
    # extraction ship (A-009). The hull is the game's largest single object, so
    # these are the entries most worth enforcing: a landmark that is 20% wrong
    # reads as wrong from across the map, where a 20% wrong berry does not.
    # Several figures are a span rather than a height, because that is what the
    # longest axis honestly is — the standing mast measures 10.35 m across its
    # fore- and backstay, not 7.7 m up.
    "ship_hull_wrecked": 10.55,
    "ship_hull_repair_1": 10.55,
    "ship_hull_repair_2": 10.55,
    "ship_hull_repaired": 10.55,      # 10.4 m hull, 3.5 m to the stem head
    "ship_mast": 10.35,               # stay span; the spar itself is 7.7 m
    "ship_mast_broken": 5.30,         # stump plus the top length down on deck
    "ship_sail_furled": 4.75,         # along the boom
    "ship_sail_raised": 6.05,         # sheet on the deck up to the halyard
    "ship_rudder": 2.36,
    "ship_boarding_ramp": 3.00,       # athwartships run, ground to gangway
    "ship_cargo_hatch": 2.03,         # coaming plus the propped lid
    "ship_anchor": 1.70,
    "ship_donation_crate": 1.05,
    "ship_departure_bell": 2.02,
    "ship_debris_cluster": 2.60,
    # practical construction (A-010). These are the kit whose numbers all come
    # from one module contract — 2.00 m run, 3.00 m wall, 1.00 m deck — so most
    # of them are whole modules on purpose. A drift here is a drift in the
    # contract, which is why they are enforced rather than eyeballed.
    "door_wood_frame": 3.00,
    "door_wood_leaf": 2.11,
    "gate_double_frame": 4.00,
    "gate_double_leaf_left": 2.58,
    "gate_double_leaf_right": 2.58,
    "ladder": 3.00,                   # exactly a wall: it tops out level with one
    "ramp": 2.00,                     # one module of run for one deck of rise
    "floor_wood": 2.00,               # one deck module square, the surface a ramp arrives on
    "bridge_straight": 2.00,
    "bridge_broken": 2.00,
    "bridge_rope": 4.00,              # two modules, because a slung span needs the length
    "dock_straight": 2.00,
    "dock_corner": 2.00,
    "palisade_straight": 3.00,
    "palisade_corner": 3.14,          # the corner post stands a little proud
    "palisade_gate_frame": 3.00,
    "palisade_gate_leaf": 2.50,
    "barricade": 2.00,
    "barricade_spike": 2.00,
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
    if cached is not None:
        # Test the datablock itself, not the cache key. This line used to read
        # `key in bpy.data.materials`, and the key is a palette token while the
        # datablock is named "MIRE_WoodBark" — so the test was always False, the
        # cache never hit, and every call minted another material. It went unseen
        # because all four fully migrated generators happen to hoist their `mat()`
        # calls into a dict once per build; call it inside a loop, as any
        # generator naturally would, and a single asset exports twenty-two
        # near-identical materials. F-058.
        try:
            if bpy.data.materials.get(cached.name) is cached:
                return cached
        except ReferenceError:
            pass

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
    #
    # Measure vertices, not `obj.bound_box`. The bound box is axis-aligned in the
    # object's LOCAL space, so once an object is rotated — which is every single
    # cone `cylinder_between` and `tapered_between` produce — transforming its
    # eight corners gives a box strictly larger than the geometry inside it. The
    # error is invisible per-object and cumulative per-asset: it grounds the
    # conservative box on z=0 and leaves the real mesh hanging above it. Measured
    # on the flora kit, that was up to **76 mm of air** under every willow and
    # snag, and it would have shipped as "assets sit on the ground" because the
    # only check was made with the same wrong ruler.
    #
    # `bound_box` is also stale immediately after `bpy.ops.object.join()`, even
    # through a depsgraph update. Vertices are never stale.
    bpy.context.view_layer.update()
    lo = Vector((1e9, 1e9, 1e9))
    hi = Vector((-1e9, -1e9, -1e9))
    for obj in objects:
        if obj.type != "MESH":
            continue
        matrix = obj.matrix_world
        for vertex in obj.data.vertices:
            world = matrix @ vertex.co
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


# ---------------------------------------------------------------------------
# Massing primitives
# ---------------------------------------------------------------------------
#
# Everything above builds an asset by *assembling* primitives: a crown is nine
# ellipsoids, a mossy boulder is a boulder plus a moss ellipsoid stuck to it.
# That is one way to make low-poly art and it is not the way a person does it.
#
# Studying a hand-authored low-poly nature pack (Quaternius, CC0) next to MIRE's
# own kit made the difference measurable rather than a matter of taste. Its bush
# is ONE mesh of 364 triangles carrying ONE material; the closest MIRE asset was
# three meshes, five materials and 641 triangles for a shape that reads as less.
# Its grass tuft is twelve wide blades, not thirty-six thin ones. Its mossy rock
# is the *same 36-face rock* with some faces assigned a second material — the
# moss costs zero geometry.
#
# None of that pack's geometry is used here and none of it was traced. What is
# taken is the method, expressed as three primitives a generator can call:
#
#   hull()         one displaced solid instead of a heap of ellipsoids
#   paint_faces()  a second material by face orientation, at no geometric cost
#   fork()         recursive branching, so a bare tree is structure not sticks
#   tube_mesh()    one continuous surface where a stack of frusta used to be
#   trunk_tube()   the tree trunk both kits build on it
#
# They are deliberately general. A hull is a boulder, a bush, a tree crown, a
# mushroom cap, a bread loaf or a cloud; paint_faces() is moss, snow, lichen,
# rust, scorching or blood; fork() is a dead tree, a root system, a crack or an
# antler; a tube_mesh is a trunk, a limb, a horn, a rope, a chimney or a mast.
# Vegetation is only the first caller.
#
# F-422 added the fourth, and its lesson generalises past trunks: **a part that
# is bolted onto a surface will eventually read as bolted on.** The kit hit that
# three separate times on one asset family — root cones on a flare, lenticel
# cylinders on a birch bole, moss lumps on bark — and every time the answer was
# to make the detail part of the surface rather than a thing standing on it.


# ---------------------------------------------------------------------------
# What the wider low-poly craft actually agrees on (2026-08-21)
# ---------------------------------------------------------------------------
#
# Sequoyah asked for a research pass on low-poly technique rather than more
# opinions. Read across Imphenzia's and Grant Abbitt's workflows, RetroStyle's
# and Saved Pixel's write-ups, the Blender manual on normals, and the CC0 packs
# (Quaternius, Kenney) the study assets under `assets/source/reference_imports/`
# came from. Almost nothing in it contradicts what this file already does; what
# follows is the part that is worth holding onto, and where MIRE sits on it.
#
# **1. Silhouette is the entire budget.** The agreed definition of optimisation
#    is "remove vertices and hidden geometry, simplify forms, but never damage
#    silhouette recognition". Detail that does not change the outline is the
#    first thing to cut. MIRE follows this — and F-422 is a case of the same rule
#    used the other way: the trunk's bark grain is not surface decoration, it is
#    flutes in the silhouette, which is why it survives at distance.
#
# **2. Colour carries what texture would.** The style's texturing answer is a
#    limited palette of flat colours, applied per face — vertex colours, or UV
#    islands parked on a tiny palette image. No surface detail, no albedo
#    variation, shading from lighting and silhouette alone. `PALETTE` is exactly
#    this and predates the research; `paint_faces()` is the same idea per face.
#
# **3. Flat shading is split normals, not a shading mode.** glTF stores flat
#    shading by splitting per-vertex normals, which is why every mesh here sets
#    `use_smooth = False` and why the audit tool's note about re-imported GLBs
#    reading as "smooth with custom normals" is not a defect. Nothing to change.
#
# **4. `Decimate` is not a low-poly button.** Its ratio operates on TRIANGLES, so
#    a quad-heavy mesh keeps more faces than the number implies unless Triangulate
#    runs first — and it wrecks silhouettes besides. MIRE has never used it and
#    should not start; every asset here is built at its final density.
#
# **5. Leaf cards with alpha are the standard canopy answer, and MIRE
#    deliberately declines it.** The common technique is bulbous masses of
#    alpha-cut leaf cards. That is a texture-fetch and overdraw cost per pixel on
#    exactly the machines MIRE targets (docs/ROADMAP's low-end goal), and it needs
#    a transparent material where this project has none. Solid faceted masses cost
#    triangles instead, which the target hardware has more of. Deliberate
#    divergence, recorded so it is not "fixed" later by someone who read the same
#    tutorials.
#
# **6. One material per scene is the draw-call ceiling, and MIRE cannot reach
#    it.** The palette-atlas workflow's real prize is that an entire scene shares
#    ONE material and therefore one draw call. MIRE cannot take it as-is:
#    `ResourceScatterField._is_foliage()` decides which surfaces a tree collides
#    on by MATERIAL NAME, so collapsing the palette to one material would collide
#    trees on their leaves. See the finding filed alongside this note — the fix is
#    real but it is a pipeline change, not an asset change (F-426: 369 surfaces
#    across the 128 kit assets; two atlas'd materials rather than one keeps the
#    foliage prefix match working and takes most of the win).
#
# **7. What the reference actually measures.** Sequoyah approved pulling the CC0
#    packs down, so seven of Kenney's Nature Kit models sit under
#    `assets/source/reference_imports/kenney_nature_kit/` (CC0, licence beside
#    them) and were run through `audit_all_sides.py` like any shipped asset:
#
#      tree_default        114 tris   2 materials
#      tree_blocks         132 tris   2 materials
#      tree_pineDefaultA   230 tris   2 materials
#      rock_largeA          80 tris   2 materials
#      stump_old           120 tris   1 material
#
#    MIRE's own kit trees are 636-1,036 triangles on 4-6 materials. The triangle
#    gap is mostly not a defect — those models are stylised miniatures 1.7 m tall
#    and MIRE's are 15-20 m trees a player walks up to and swings an axe at, and
#    the trunk detail F-422 added is the part that only exists close up. **The
#    MATERIAL gap is the real finding.** Two materials carries a whole tree
#    there; six carries one here, and every one of them is a separate surface, a
#    separate MultiMeshInstance3D and a separate draw call in every chunk the
#    asset appears in. That is F-426, and the reference is what makes it concrete
#    rather than a preference.
#
# The reference packs are studied for METHOD only and never traced or shipped,
# which is the standing rule for third-party art in this repo. Nothing under
# `reference_imports/` is referenced by a scene, a scatter table or a catalog —
# `.gdignore` keeps `assets/source/` out of Godot's importer entirely.


def icosphere(subdivisions: int = 1) -> tuple[list[Vector], list[tuple[int, int, int]]]:
    """Unit icosphere as plain data: 80 faces at 1, 320 at 2.

    Written out rather than taken from ``bpy.ops`` so the vertex order is fixed
    by this function and not by an operator, which is what lets a hull built
    from it rebuild byte-identically (F-057).
    """
    ratio = (1.0 + 5.0 ** 0.5) / 2.0
    vertices = [
        Vector(v).normalized() for v in (
            (-1, ratio, 0), (1, ratio, 0), (-1, -ratio, 0), (1, -ratio, 0),
            (0, -1, ratio), (0, 1, ratio), (0, -1, -ratio), (0, 1, -ratio),
            (ratio, 0, -1), (ratio, 0, 1), (-ratio, 0, -1), (-ratio, 0, 1),
        )
    ]
    faces = [
        (0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11),
        (1, 5, 9), (5, 11, 4), (11, 10, 2), (10, 7, 6), (7, 1, 8),
        (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9),
        (4, 9, 5), (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1),
    ]
    for _ in range(subdivisions):
        midpoints: dict[tuple[int, int], int] = {}

        def midpoint(a: int, b: int) -> int:
            key = (min(a, b), max(a, b))
            if key not in midpoints:
                vertices.append(((vertices[a] + vertices[b]) * 0.5).normalized())
                midpoints[key] = len(vertices) - 1
            return midpoints[key]

        split: list[tuple[int, int, int]] = []
        for a, b, c in faces:
            ab, bc, ca = midpoint(a, b), midpoint(b, c), midpoint(c, a)
            split.extend([(a, ab, ca), (b, bc, ab), (c, ca, bc), (ab, bc, ca)])
        faces = split
    return vertices, faces


def hull(
    name: str,
    centre: tuple[float, float, float],
    radius: tuple[float, float, float] | float,
    material: bpy.types.Material,
    seed: int,
    subdivisions: int = 1,
    lumps: int = 6,
    lump: float = 0.30,
    sharpness: float = 2.4,
    taper: float = 0.0,
    taper_low: float = 0.0,
    droop: float = 0.0,
    droop_lobes: int = 0,
    droop_sharpness: float = 6.0,
    flat_base: float | None = None,
    jitter: float = 0.0,
) -> bpy.types.Object:
    """One irregular solid: the shape a person sculpts, not a pile of spheres.

    The lumps are a sum of smooth directional bumps rather than per-vertex noise.
    Per-vertex noise on a 42-vertex sphere gives a spiky golf ball, because every
    vertex moves independently; a handful of broad bumps moves whole regions
    together, which is what produces the big readable facets that make flat
    shading look intentional.

    ``taper`` narrows the TOP and only the top — a negative value flares it,
    which is what a cooking pot's rim and a mushroom cap already rely on, so the
    sign is not free to repurpose. ``taper_low`` is the missing other half: it
    narrows the BOTTOM, which is the direction anything hanging thins in. The
    willow's shoots are its first caller; a stalactite, an icicle, a teardrop, a
    hanging vine or a wasp nest want the same thing.

    ``droop`` pulls lobes down out of the lower half — the hanging tongues that
    give a broadleaf crown its silhouette instead of leaving it a green ball.
    ``taper`` narrows the top, ``flat_base`` clips the underside flat at that
    fraction of the radius so a bush sits on the ground rather than floating on
    its own curvature. Every random draw comes from ``seed``.
    """
    if isinstance(radius, (int, float)):
        radius = (float(radius), float(radius), float(radius))
    rng = random.Random(seed)
    directions, faces = icosphere(subdivisions)

    bumps = [
        (
            Vector((rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(-1, 1))).normalized(),
            rng.uniform(-lump * 0.45, lump),
        )
        for _ in range(lumps)
    ]
    lobes = [
        (Vector((math.cos(angle), math.sin(angle), 0.0)), rng.uniform(0.55, 1.0))
        for angle, _ in radial(droop_lobes, 1.0, seed=seed + 7, jitter=0.5)
    ] if droop_lobes > 0 else []

    points: list[tuple[float, float, float]] = []
    for direction in directions:
        scale = 1.0
        for axis, amplitude in bumps:
            dot = direction.dot(axis)
            if dot > 0.0:
                scale += amplitude * (dot ** sharpness)
        scale = max(0.25, scale + rng.uniform(-jitter, jitter))
        point = Vector((direction.x * radius[0], direction.y * radius[1], direction.z * radius[2])) * scale
        if taper:
            narrow = 1.0 - taper * (direction.z * 0.5 + 0.5)
            point.x *= narrow
            point.y *= narrow
        if taper_low:
            narrow = 1.0 - taper_low * (0.5 - direction.z * 0.5)
            point.x *= narrow
            point.y *= narrow
        dropped = 0.0
        if lobes and direction.z < 0.30:
            flat = Vector((direction.x, direction.y, 0.0))
            if flat.length > 1e-6:
                flat.normalize()
                depth = 0.0
                for axis, weight in lobes:
                    dot = flat.dot(axis)
                    if dot > 0.0:
                        depth = max(depth, weight * (dot ** droop_sharpness))
                dropped = droop * depth * min(1.0, (0.30 - direction.z) / 0.9)
                point.z -= dropped
        if flat_base is not None:
            # The floor has to yield to the lobes, or it erases them. Clipping
            # first made every drooping bush come out a smooth egg — the lobes
            # were built and then flattened straight back off in the same pass.
            point.z = max(point.z, -radius[2] * flat_base - dropped)
        points.append((centre[0] + point.x, centre[1] + point.y, centre[2] + point.z))
    return mesh_object(name, points, faces, material, recalculate=False)


def tube_mesh(
    name: str,
    rings: list[list[tuple[float, float, float]]],
    materials: list[bpy.types.Material],
    face_material: Callable[[int, int], int],
    cap_bottom: bool = True,
    cap_top: bool = True,
) -> bpy.types.Object:
    """One closed, flat-shaded tube through a stack of same-width vertex rings.

    Every trunk in this kit used to be a STACK of separate frusta, and that is
    what "the trunks look really bad" kept coming back to. Two defects follow
    from the stack itself and cannot be tuned out of it:

    * **A shoulder at every joint.** Consecutive frusta are separate cylinders
      whose facets do not line up, so the silhouette steps in and out at each
      segment boundary — a telescoping antenna, not a taper. `rolled_frustum`
      made this worse on purpose, rolling each segment to break up the shading.
    * **Nowhere to put a root flare except a separate cone.** Which is why the
      base was a fatter stub butted onto the column, with a hard tone break
      where the two met (worst on the birch: a pale trunk standing in a dark
      boot) and five loose cones radiating off it that read as a chicken foot.

    A tube has neither, because it has no joints. Radius, material and shape all
    vary per RING and per COLUMN, so the flare, the buttress lobes and the bark
    grain are the same surface as the trunk and merge into it by construction.
    `face_material(ring, column)` picks the slot for each quad.

    Rings run bottom to top and must all carry the same number of vertices.
    """
    if len({len(ring) for ring in rings}) != 1:
        raise RuntimeError(f"{name}: rings have differing vertex counts")
    columns = len(rings[0])
    vertices: list[tuple[float, float, float]] = [point for ring in rings for point in ring]
    faces: list[tuple[int, ...]] = []
    slots: list[int] = []
    for ring in range(len(rings) - 1):
        low = ring * columns
        high = low + columns
        for column in range(columns):
            nxt = (column + 1) % columns
            faces.append((low + column, low + nxt, high + nxt, high + column))
            slots.append(face_material(ring, column))
    if cap_bottom:
        faces.append(tuple(range(columns - 1, -1, -1)))
        slots.append(face_material(0, 0))
    if cap_top:
        top = (len(rings) - 1) * columns
        faces.append(tuple(range(top, top + columns)))
        slots.append(face_material(len(rings) - 2, 0))

    mesh = bpy.data.meshes.new(f"{name}_Mesh")
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    for material in materials:
        obj.data.materials.append(material)
    for polygon, slot in zip(obj.data.polygons, slots):
        polygon.material_index = slot
        polygon.use_smooth = False
    return obj


def trunk_tube(
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
    flare: float = 1.9,
    flare_top: float = 0.44,
    toe: float = 0.85,
    toe_top: float = 0.16,
    taper_power: float = 1.35,
    flare_power: float = 1.7,
    grain: float = 0.075,
    flute: float = 0.62,
    shade_columns: int = 1,
    lit_columns: int = 1,
    marks: int = 0,
    mark_band: float = 0.11,
    moss: int = 0,
    moss_band: float = 0.26,
    moss_material: bpy.types.Material | None = None,
) -> tuple[list[Vector], list[float]]:
    """A standing tree trunk: ONE tube mesh, from the soil to the tip.

    `tone` is (shadow, bark, lit) — three tones from the same wood, because
    one flat colour is what made the first trunks read as plastic pipe.

    Returns the spine points and the radius at each, so a caller can hang
    limbs on the trunk WHERE THE TRUNK IS rather than on the vertical axis.

    F-422 rebuilt this from a stack of rolled frusta plus bolt-on parts into a
    single `tube_mesh`, and moved it here because BOTH kits had grown their own
    copy of the stack and therefore both had all four of its defects. Every one
    was visible from two metres away:

    * **A stepped silhouette.** Separate frusta with independent rolls do not
      line up, so the outline shouldered in and out at every joint. The tube
      has no joints; the taper is one continuous surface.
    * **A chicken foot.** The root flare was a separate fat cone butted onto
      the column, with five thin cones arching off it to the ground. Now the
      flare is the tube's own bottom rings, swelling by `flare` over the
      first `flare_top` metres, and the buttresses are `flute`-deep LOBES in
      those rings — the same surface as the trunk, so there is nothing to
      detach. Only `roots` short, thick, half-buried toes leave it, and they
      leave it from the lobe crests where a real root would.
    * **A dip line.** The flare cone carried its own material, so a pale
      birch stood in a dark boot. Material is now per-face on one mesh and
      keyed to the lobe depth, so it varies VERTICALLY — which is the one
      direction bark actually varies. Two earlier passes varied tone per
      segment, i.e. horizontally, and both read as painted rings.
    * **A black stick beside the trunk.** The bark ridges were separate cones
      anchored at a fixed fraction of the BASE radius, so on a tapering trunk
      they finished outside the wood, in shadow tone, reading as a pole. The
      grain is now `grain`-deep flutes in the tube itself: free, always on the
      surface, and it is what makes the facets catch light separately.

    Two things here stay load-bearing:

    * **The taper is a curve, not a line.** `taper_power` > 1 sheds radius
      fast at the base and slowly near the top, which is the profile a trunk
      actually has; a linear taper is a traffic cone and looks like one.
    * **The flare stops at `flare_top` on purpose.**
      `ResourceScatterField.COLLIDER_TRUNK_BAND_MIN_M` is 0.5 m — F-390
      lifted the collider's measuring band off the floor precisely because
      the flare, not the trunk, was setting the radius and holding the player
      a metre off the bark they were walking at. Keeping the flare under that
      line means a wide, well-planted base costs nothing in collision.
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

    # One number per column, held constant all the way up, and it drives
    # THREE things at once: how far that column bulges (grain), how far it
    # swells into a buttress down at the flare, and which of the three tones
    # its faces take. Driving them from the same value is what makes the
    # flutes at the base read as the same wood as the ridges up the trunk,
    # instead of as two unrelated decorations — and holding it constant per
    # column is what makes the variation run vertically.
    column_rng = random.Random(seed + 733)
    depth = [column_rng.uniform(-1.0, 1.0) for _ in range(vertices)]
    # Guarantee at least one crest and one deep flute however the seed falls;
    # an all-shallow column set is a smooth pipe again.
    depth[column_rng.randrange(vertices)] = column_rng.uniform(0.55, 1.0)
    depth[column_rng.randrange(vertices)] = column_rng.uniform(-1.0, -0.50)
    # Break the regular polygon too. A perfect heptagon in cross-section is
    # readable as a machined part however good the profile is.
    skew = [column_rng.uniform(-0.13, 0.13) for _ in range(vertices)]

    def spine_at(z: float) -> tuple[Vector, float]:
        """Position and radius of the spine at absolute height `z`."""
        for index in range(len(points) - 1):
            low, high = points[index], points[index + 1]
            if z <= high.z or index == len(points) - 2:
                span = high.z - low.z
                fraction = 0.0 if span <= 0.0 else (z - low.z) / span
                return (low.lerp(high, fraction),
                        radii[index] + (radii[index + 1] - radii[index]) * fraction)
        return points[-1], radii[-1]

    # Ring heights: four extra rings inside the flare, because the flare is
    # under half a metre tall and the trunk's own segments are metres apart —
    # sampled only at the spine points, a root flare has nowhere to happen.
    # The first ring is BELOW the soil line, which is what lets the root toes
    # dive rather than stop dead on the ground plane.
    sink = base_radius * 0.30
    ring_heights = [-sink, 0.0, toe_top * 0.55, flare_top * 0.30, flare_top * 0.62, flare_top]
    ring_heights += [point.z for point in points if point.z > flare_top * 1.35]
    if ring_heights[-1] < points[-1].z - 1e-6:
        ring_heights.append(points[-1].z)

    # A scar needs its OWN pair of rings, `mark_band` apart. The trunk's
    # rings are metres apart above the flare, so painting a face between two
    # of them paints a two-metre black rectangle — which is exactly what the
    # first cut of `marks` produced on the birch. Inserting the band first
    # and recording which ring index it starts at is what keeps a lenticel
    # the size of a lenticel.
    band_rng = random.Random(seed + 811)
    scars: list[tuple[float, int, int]] = []
    for _ in range(marks):
        z = round(band_rng.uniform(flare_top * 1.4, max(flare_top * 1.9, points[-1].z * 0.55)), 5)
        ring_heights += [z, z + mark_band * band_rng.uniform(0.7, 1.4)]
        scars.append((z, band_rng.randrange(vertices), band_rng.randint(2, 3)))

    # Moss runs UP a trunk, on the side that stays damp — it does not belt it.
    # The first cut reused the scar machinery, which paints a run of faces on
    # ONE ring band, and two of those on a bole is unmistakably a strip of
    # green tape wrapped round the tree. So a moss patch gets three closely
    # spaced rings of its own and takes a staggered L out of them: tall, one
    # or two columns wide, and not a rectangle.
    patches: list[tuple[float, float, int]] = []
    for _ in range(moss):
        z = round(band_rng.uniform(flare_top * 0.5, max(flare_top, points[-1].z * 0.22)), 5)
        step = moss_band * band_rng.uniform(0.8, 1.25)
        ring_heights += [z, round(z + step, 5), round(z + step * 2.0, 5)]
        patches.append((z, step, band_rng.randrange(vertices)))
    ring_heights = sorted(set(round(z, 5) for z in ring_heights))

    rings: list[list[tuple[float, float, float]]] = []
    for z in ring_heights:
        centre, radius = spine_at(max(0.0, z))
        surface = max(0.0, z)
        # Flare: a swell that dies out by `flare_top`, sharpened so the
        # widening happens down at the soil rather than halfway up a bole.
        swell = 0.0
        if surface < flare_top:
            swell = (flare - 1.0) * ((1.0 - surface / flare_top) ** flare_power)
        # Toes: the same idea taken one step further, over the first
        # `toe_top` metres only and raised to a high power on the lobe, so it
        # reaches on the two or three sharpest buttress crests and nowhere
        # else. This is what replaced the separate root cones. Cones could
        # never be made to work: a cone butted onto the flare either leaves a
        # hairline gap and reads as a fin lying on the floor, or is pushed in
        # far enough to hide the gap and then shows its end cap through the
        # bark as a dark pentagon. Both were visible on the shipped pine. A
        # toe that is the trunk's own surface has no seam to show.
        spread = 0.0
        if surface < toe_top and toe > 0.0:
            spread = toe * ((1.0 - surface / toe_top) ** 1.55)
        # Below the soil line everything draws in, so the base dives into the
        # ground instead of ending on it.
        dive = 1.0 if z >= 0.0 else 0.72
        wobble = 1.0 + rng.uniform(-0.018, 0.018)
        ring: list[tuple[float, float, float]] = []
        for column in range(vertices):
            angle = (column / vertices) * math.tau + skew[column]
            lobe = 0.5 * (depth[column] + 1.0)
            reach = radius * (1.0 + depth[column] * grain) * wobble
            reach *= 1.0 + swell * (1.0 - flute + flute * lobe) + spread * (lobe ** 3.0)
            reach *= dive
            ring.append((centre.x + math.cos(angle) * reach,
                         centre.y + math.sin(angle) * reach,
                         z))
        rings.append(ring)

    # slot 0 -> the shadow tone (birch lenticels), slot 1 -> `moss_material`.
    band_faces: dict[tuple[int, int], int] = {}
    for z, start, run in scars:
        ring = ring_heights.index(z)
        for step in range(run):
            band_faces[(ring, (start + step) % vertices)] = 0
    for z, step, column in patches:
        low = ring_heights.index(z)
        mid = ring_heights.index(round(z + step, 5))
        # A diagonal creep up and around the bole. Painting the same column
        # on both rings gives a rectangle, and a rectangle of one flat green
        # on brown is a sticker whatever colour it is.
        for row, offset in ((low, 0), (mid, 0), (mid, 1)):
            band_faces[(row, (column + offset) % vertices)] = 1

    # Which columns take the shadow and lit tones, by COUNT rather than by a
    # threshold on `depth`. A threshold is a lottery on the seed: the first
    # cut put a third of the trunk in `wood_bark_dark` and a quarter in the
    # saturated `wood_bark_light`, and eight-column trunks came out striped
    # like a barber's pole. One deep flute in shadow and one crest catching
    # light is bark; four of each is paint.
    order = sorted(range(vertices), key=lambda column: depth[column])
    shaded = set(order[:max(0, shade_columns)])
    lit_set = set(order[len(order) - max(0, lit_columns):]) if lit_columns > 0 else set()

    def face_material(ring: int, column: int) -> int:
        slot = band_faces.get((ring, column))
        if slot == 0:
            return 0
        if slot == 1:
            return 3
        # The buried ring goes to shadow whatever its column, so the toes
        # darken as they enter the soil rather than ending in a lit facet
        # against the ground — the cheapest contact shadow there is, and the
        # one place a horizontal tone break is the correct answer.
        if ring == 0:
            return 0
        if column in shaded:
            return 0
        if column in lit_set:
            return 2
        return 1

    # Only declare the fourth slot when something uses it: an unused slot is
    # an extra glTF primitive, an extra Godot surface and an extra draw call
    # on every instance of the asset.
    palette = [shadow, bark, lit] + ([moss_material] if moss and moss_material else [])
    tube_mesh("Trunk", rings, palette, face_material)

    return points, radii


def paint_faces(
    obj: bpy.types.Object,
    material: bpy.types.Material,
    min_normal_z: float = 0.30,
    min_height: float = 0.42,
    coverage: float = 1.0,
    seed: int = 0,
) -> int:
    """Give some of ``obj``'s faces a second material. Costs no geometry at all.

    This is how a mossy boulder should be made: the same rock, with its upward
    faces above the waterline assigned moss. MIRE currently sticks a separate
    flattened ellipsoid on one flank instead, which is both more triangles and
    more obviously fake — it reads as a sticker, and it only exists on the side
    the author was looking at.

    Also: snow on a roof, lichen on a ruin, scorch on the up-faces of a burnt
    beam, rust in the crevices (invert ``min_normal_z``), blood pooling on flat
    surfaces. ``coverage`` below 1.0 drops faces at random for a patchy edge, so
    the boundary is not a clean contour line.
    """
    index = len(obj.data.materials)
    obj.data.materials.append(material)
    zs = [vertex.co.z for vertex in obj.data.vertices]
    low, high = min(zs), max(zs)
    span = max(1e-6, high - low)
    rng = random.Random(seed)
    painted = 0
    for polygon in obj.data.polygons:
        if polygon.normal.z < min_normal_z:
            continue
        if (polygon.center.z - low) / span < min_height:
            continue
        if coverage < 1.0 and rng.random() > coverage:
            continue
        polygon.material_index = index
        painted += 1
    return painted


def fork(
    prefix: str,
    start: tuple[float, float, float],
    direction: tuple[float, float, float],
    length: float,
    radius: float,
    material: bpy.types.Material,
    seed: int,
    depth: int = 3,
    splits: tuple[int, int] = (2, 3),
    spread: float = 0.55,
    shrink: float = 0.70,
    curve: float = 0.22,
    vertices: int = 5,
    tip_material: bpy.types.Material | None = None,
) -> list[Vector]:
    """Recursive branching. Returns the tip points so the caller can hang things.

    A bare tree drawn as "six branches off a trunk, each with two twigs" is a
    fixed two-level shape and looks like one. Real branch structure is the same
    rule applied at every scale, and it is three lines of recursion — the reason
    hand-authored dead trees read so much better than MIRE's is structure, not
    triangle count. Also serves root systems, cracks, lightning and antlers.
    """
    rng = random.Random(seed)
    tips: list[Vector] = []
    origin = Vector(start)
    heading = Vector(direction).normalized()

    def basis(vector: Vector) -> tuple[Vector, Vector]:
        reference = Vector((0.0, 0.0, 1.0))
        if abs(vector.dot(reference)) > 0.94:
            reference = Vector((1.0, 0.0, 0.0))
        side = vector.cross(reference).normalized()
        return side, vector.cross(side).normalized()

    def grow(point: Vector, heading: Vector, length: float, radius: float, level: int, tag: str) -> None:
        side, other = basis(heading)
        bend = (side * rng.uniform(-curve, curve) + other * rng.uniform(-curve, curve))
        end = point + (heading + bend).normalized() * length
        tapered_between(
            f"{prefix}_{tag}", tuple(point), tuple(end), radius, radius * shrink,
            tip_material if (tip_material is not None and level <= 1) else material, vertices,
        )
        if level <= 1 or radius * shrink < 0.006:
            tips.append(end)
            return
        heading = (end - point).normalized()
        count = rng.randint(*splits)
        for index in range(count):
            roll = index * math.tau / count + rng.uniform(-0.5, 0.5)
            tilt = spread * rng.uniform(0.6, 1.35)
            side, other = basis(heading)
            child = (heading + (side * math.cos(roll) + other * math.sin(roll)) * math.tan(tilt)).normalized()
            grow(end, child, length * rng.uniform(0.58, 0.80), radius * shrink, level - 1, f"{tag}{index + 1}")

    grow(origin, heading, length, radius, depth, "0")
    return tips


# ---------------------------------------------------------------------------
# Batched geometry
# ---------------------------------------------------------------------------


class Batch:
    """Accumulate many small shapes and emit one mesh per material.

    A fibre plant is thirty blades. Thirty Blender objects export as thirty glTF
    nodes with thirty primitives, which costs far more at runtime than the
    triangles do — and props have no cross-asset batching yet (F-144), so the
    node count is the cost. Everything repetitive goes through here instead.

    Lifted into the shared library by A-011. `build_flora_set.py` still carries a
    private copy of this class, `ribbon` and `blob` included; migrating it is a
    behaviour-neutral change but it would rebuild all 84 flora assets, so it is
    filed rather than done here. Do not make a third copy.
    """

    def __init__(self) -> None:
        self._groups: dict[str, tuple[list, list]] = {}

    def add(self, token: str, vertices: list, faces: list) -> None:
        vert_list, face_list = self._groups.setdefault(token, ([], []))
        offset = len(vert_list)
        vert_list.extend(tuple(float(c) for c in v) for v in vertices)
        face_list.extend(tuple(index + offset for index in face) for face in faces)

    def blob(self, token: str, centre, radius, rng) -> None:
        """An 8-triangle irregular octahedron — the cheapest thing that still
        reads as a mass. For anything bigger than a berry or a flower head, use
        `hull`."""
        cx, cy, cz = centre
        rx, ry, rz = (radius, radius, radius) if isinstance(radius, (int, float)) else radius

        def wobble(value: float) -> float:
            return value * rng.uniform(0.74, 1.26)

        vertices = [
            (cx + wobble(rx), cy, cz), (cx - wobble(rx), cy, cz),
            (cx, cy + wobble(ry), cz), (cx, cy - wobble(ry), cz),
            (cx, cy, cz + wobble(rz)), (cx, cy, cz - wobble(rz)),
        ]
        self.add(token, vertices, [
            (0, 2, 4), (2, 1, 4), (1, 3, 4), (3, 0, 4),
            (2, 0, 5), (1, 2, 5), (3, 1, 5), (0, 3, 5),
        ])

    def ribbon(self, token: str, spine: list, half_widths: list[float], fold: list[float]) -> None:
        """A solid, folded strip along ``spine``: one leaf, one blade, one frond.

        Cross-section is a triangle — left edge, right edge, raised centre — so
        the strip has a top crease and a flat underside and is visible from every
        direction. A one-sided leaf card is an invisible leaf, because Godot
        imports glTF with back-face culling on; the crease is also what catches
        light differently along its length, which is most of why a flat-shaded
        leaf reads as a leaf.
        """
        if len(spine) < 2:
            return
        vertices: list[tuple[float, float, float]] = []
        faces: list[tuple[int, ...]] = []
        for index, point in enumerate(spine):
            nxt = spine[min(index + 1, len(spine) - 1)]
            prv = spine[max(index - 1, 0)]
            tangent = Vector((nxt.x - prv.x, nxt.y - prv.y, 0.0))
            if tangent.length < 1e-6:
                tangent = Vector((1.0, 0.0, 0.0))
            tangent.normalize()
            side = Vector((-tangent.y, tangent.x, 0.0)) * half_widths[index]
            vertices.extend([
                (point.x - side.x, point.y - side.y, point.z),
                (point.x + side.x, point.y + side.y, point.z),
                (point.x, point.y, point.z + fold[index]),
            ])
        for index in range(len(spine) - 1):
            a, b = index * 3, (index + 1) * 3
            faces.extend([
                (a + 0, b + 0, b + 2, a + 2),
                (a + 2, b + 2, b + 1, a + 1),
                (a + 1, b + 1, b + 0, a + 0),
            ])
        last = (len(spine) - 1) * 3
        faces.extend([(0, 2, 1), (last + 1, last + 2, last + 0)])
        self.add(token, vertices, faces)

    def emit(self, prefix: str) -> None:
        for token, (vertices, faces) in sorted(self._groups.items()):
            if vertices:
                mesh_object(f"{prefix}_{token}", vertices, faces, mat(token), recalculate=False)
