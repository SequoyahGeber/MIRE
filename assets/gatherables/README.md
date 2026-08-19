# MIRE gatherables kit

Batch **A-011** — the plants and deposits a player walks up to and takes. Runtime-ready GLBs are in
`exports/`; the editable Blender source is `../source/gatherable_plants.blend`, rebuilt by
`tools/blender/build_gatherable_plants.py`. `catalog.json` is the exact index — every filename,
dimension, mesh part, polygon and triangle count, and embedded material.

## Why it exists

`ITEMS.md` §4.1 lists the T0 gathers the first ten minutes of a run are made of — berry, poison
berry, fibre, marshwort, wild onion, honeycomb, clay, peat, resin — and none of them had a source
object. The flora kit (A-000V) fills the world with plants you walk past; this kit is the plants you
walk *to*.

That difference sets a higher bar than decoration has to clear. A gatherable must be recognisable as
its own item across a clearing, and two of them must be tellable apart on sight, or the gathering
loop becomes "walk up to every green thing and press E".

## Contents — 10 GLBs, 5,472 triangles

| Asset | Size | Triangles | What it is |
|---|---|---:|---|
| `berry_bush_full` | 0.78 m | 768 | Fruiting berry bush |
| `berry_bush_harvested` | 0.78 m | 488 | The same bush, picked — bare stalks left behind |
| `poison_berry_bush` | 0.78 m | 768 | Deliberately almost the safe bush (see below) |
| `fibre_plant` | 0.88 m | 380 | Standing fan of strappy blades; rope and cloth come from here |
| `medicinal_herb` | 0.34 m | 450 | Marshwort — low rosette under small white heads |
| `wild_onion` | 0.46 m | 530 | Tubular clump over pale bulbs that show above the soil |
| `honeycomb` | 0.38 m | 400 | Comb in a bee hollow, cells facing the player |
| `clay_deposit` | 0.92 m | 844 | Riverbank bank with a dug floor and prised-out lumps |
| `peat_deposit` | 1.06 m | 316 | Cut peat bricks stacked to dry on a fen bank |
| `resin_node` | 0.74 m | 528 | Tapped pine with sap running from the wound |

Sheets are in `preview/`, each with a 1.80 m reference figure standing in frame.

## Silhouette carries the identity

A bush, a fan, a rosette, a tubular clump, a hanging comb, a bank, a stack of bricks, a tapped
trunk. No two read the same at ten metres, which matters because MIRE is usually viewed through fog
and because colour is the first thing distance takes away.

The two deposits are the case this was hardest on. Clay and peat are both brown things on the
ground, so they are built as opposites on purpose: clay is a damp *bank* someone has prised lumps
out of, peat is *stacked bricks* somebody cut. Peat is the one gatherable that is obviously worked,
and that reads instantly.

## The poison berry bush is a deliberate near-copy

`ITEMS.md` §4.1 asks for a poison berry that "looks *almost* identical" to the safe one — the D7
tone rule, where the joke is that you have to actually learn it. So the poison bush is built from
the same seed, the same frame, the same foliage colours and the same berry geometry in the same
places. `catalog.json` records both at 0.910 × 0.727 × 0.780 m and 768 triangles, and the build
fails if their silhouettes ever diverge by more than 50 mm on any axis.

The single tell is a pale `berry_bloom` film on the fruit's upward faces. One tell, not three, and
it is on the berries rather than the leaves — the berry is what a player already leans in to look at
before eating, so the difference is where they will actually be looking. It costs no geometry at
all: it is `paint_faces` on the berry mesh, not a second berry.

An earlier cut also darkened the foliage. The two bushes were then trivially separable from across a
clearing, which throws away the entire point of the item existing.

## The state pair shares a frame, and shares a scale

`berry_bush_full` and `berry_bush_harvested` are one bush with and without fruit. A-005's rule is
that state sets centre on the geometry they **share**, not on each state's own bounds — but that
rule is not sufficient on its own, and this batch found the missing half:

**Scaling has to be driven by the shared geometry too.** Sizing each state to its own total bounds
gives them different scale factors, because a fruiting bush is fractionally taller than a picked
one, and that silently rescales the frame they are supposed to have in common. Centring a rescaled
frame just centres the wrong size. Both states now take their scale factor from the shared frame.
Measured drift between the two: **0.000 mm**.

Both states also derive from one shared seed rather than one per asset name. Seeding per name is
what the first build did, and it produced three different plants wearing the same labels — the pair
27.6 mm apart and the "near-identical" poison bush 79 mm wider than the safe one, with a different
number of berries on it.

## Verification

Built with **Blender 5.2.0 LTS** (D-038).

- **Build-time contract** — `tools/blender/build_gatherable_plants.py` **fails** rather than warns
  on size against target, footprint ceiling, ground contact, floating geometry, triangle budget,
  material cap, missing GLB, the state pair's shared-frame agreement, and the poison bush's
  silhouette match. 10/10 pass.
- **All-sides audit** — every asset from eight azimuths plus top and bottom,
  `tools/blender/audit_all_sides.py`, re-run against a clean `--outdir` (F-110): **0 numeric
  defects** across all 10. No inside-out objects, no open surfaces, no ngons, no loose vertices, no
  unapplied transforms.
- **Godot import** — `tools/gatherables_check.gd`, 41 assertions, 0 failures. It measures each
  imported GLB from its **vertices**, never `Transform3D * AABB` (F-108/F-094), and cross-checks
  dimensions, ground contact, triangle count and material count against `catalog.json`, plus orphan
  GLBs.

The Godot check is not a formality. Blender reported `resin_node` perfectly grounded while the
shipped GLB sat **53 mm underground and 93 mm too tall**, because the measurement went through the
object's world matrix and the exporter wrote its rotation out as a node transform instead. The join
step now bakes rotation into the mesh so a static prop ships no rotation at all.

## Gameplay wiring is not here

These are presentation meshes. Harvesting, drops, respawn, placement and collision stay
host-authoritative systems (`ARCHITECTURE.md` §2.2), wired by whichever task needs them.
