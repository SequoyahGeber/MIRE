# MIRE wetland kit

Batch **A-043** — wetland gatherables II, the mere's own harvest. Runtime-ready GLBs are in
`exports/`; the editable Blender source is `../source/wetland_set.blend`, rebuilt by
`tools/blender/build_wetland_set.py`. `catalog.json` is the exact index.

## Scope

The A-043 row lists seven. Two already exist and are deliberately **not** rebuilt here:
`poison_berry_bush` shipped in A-011 and `raw_fish` shipped in A-012 as half of that kit's one-fish
frame. Making either again would be two objects competing to be one item.

## Contents — 5 GLBs, 4,092 triangles

| Asset | Size | Triangles | What it is |
|---|---|---:|---|
| `cattail_bundle` | 0.80 m | 736 | Cut cattails, tied — the pickup |
| `reed_bed` | 1.55 m | 1,016 | The stand it was cut from |
| `sphagnum_moss` | 0.62 m | 680 | Raised moss hummock |
| `fish_shoal` | 0.98 m | 836 | Fish holding in a shallow pool |
| `glowcap_mushroom` | 0.32 m | 824 | Bioluminescent cluster — the light-source ingredient |

## A node has to out-read the scenery standing next to it

`assets/flora` already ships `reeds_a`..`reeds_d` and `moss_patch_a`..`moss_patch_d`. Those are
scatter you walk past; these are the ones you walk *to*, and they have to be tellable apart while
sitting side by side. Each one carries something scenery never does:

- **The bundle is tied and lying down.** It is made of the same parts as `reed_bed`, so standing it
  upright gave the two of them the same silhouette and a player could not tell the thing they can
  carry from the thing they have to harvest. Laid over, they are opposites at any distance.
- **The bed is dense and flowering.** Decorative reeds are a handful of blades with no flower, so
  the brown spikes are what a player scans a shore for. Only eight of its stems carry a head —
  every stalk flowering reads as a planted crop rather than a mere.
- **The hummock stands up.** Sphagnum's honest difference from a moss mat is that it grows in a
  raised, spongy dome, and the rust blush on its crowns is real: living sphagnum runs green to deep
  red, and nothing else on MIRE's ground does that.
- **The shoal is coherent.** Seven fish pointing seven ways is litter on a pond; seven sharing one
  heading is a shoal, and that shape is recognised without being named.
- **The glowcap is the only emissive surface in the kit**, and only its caps. Lighting the gills
  too would turn each mushroom into a glowing blob and throw away the cap-over-stem outline — which
  is what has to say "mushroom" once a player has found it by its glow. `preview/glowcap_night_preview.png`
  is the sheet that actually tests this; a sunlit render cannot.

## Two palette rules this kit had to obey

**Reserved hues.** The shoal's pool is peat-stained brown, not `clear_liquid`. `clear_liquid`
renders teal, and teal is reserved for the Ward the way purple is reserved for the Mire —
`ASSET_TRACKER.md` says not to spend either on decoration, and a fish pond is decoration. It is also
just wrong: water in a peat wetland is brown, and blue water would read as somewhere else entirely.
Silver fish on dark water is the better contrast anyway. (A-014's agent reached the identical
conclusion for road puddles, independently, on the same day.)

**Bioluminescence needed a hue nobody had claimed.** Purple is the Mire, teal is the Ward,
`ember`/`flame` are fire, `critical` is damage and `eye` is an enemy looking at you. `glowcap` and
`glowcap_gill` are added append-only, in a cold green that means "safe and useful".

## Verification

Built with **Blender 5.2.0 LTS** (D-038).

- **Build-time contract** — `tools/blender/build_wetland_set.py` **fails** rather than warns on size
  against target, footprint ceiling, ground contact, floating geometry, triangle budget, material
  cap, missing GLB and missing catalog entry. 5/5 pass.
- **All-sides audit** — every asset from eight azimuths plus top and bottom, re-run against a clean
  `--outdir` (F-110): **0 numeric defects** across all 5.
- **Godot import** — `tools/wetland_check.gd`, **21 assertions, 0 failures**, measuring each
  imported GLB from its **vertices** rather than `Transform3D * AABB` (F-108/F-094).

The join step bakes rotation into the mesh so no static prop ships a node transform — A-011's resin
node sat 53 mm underground for anything that measured the GLB rather than its world matrix.

## Not recorded in the tracker yet

`docs/ASSET_TRACKER.md` was claimed by another session for the whole of this batch's life, so
A-043's row still says `QUEUED`. It needs marking `DONE` with the figures above, and the row should
note that two of its seven were already shipped elsewhere.

## Gameplay wiring is not here

These are presentation meshes. Harvesting, drops, respawn, placement and collision stay
host-authoritative systems (`ARCHITECTURE.md` §2.2), wired by whichever task needs them.
