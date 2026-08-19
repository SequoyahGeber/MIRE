# MIRE asset production tracker

This is the source of truth for MIRE's visual assets: what exists, what is being made, and what an
asset agent should make next. It is a production queue, not a promise that every listed asset ships.
The roadmap's **fun before content** rule still wins: later batches stay queued until the gameplay
they support has survived playtesting.

## The one command

Tell a fresh agent:

> **Start the next asset batch in `docs/ASSET_TRACKER.md`.**

Task 2.1d is a repeating production task. The agent reads this file, takes the first `NEXT` batch,
makes exactly that batch, verifies it, marks it `DONE`, promotes the first eligible `QUEUED` batch to
`NEXT`, and hands 2.1d back rather than closing it. This keeps the same short instruction useful for
the whole queue.

If 2.1d has not yet been registered, the first agent bootstraps it after checking that nobody holds
`docs/ROADMAP.md`: add the following row to M2, run `.agent/bin/agent sync`, and continue normally.

```text
| 2.1d | Produce the single `NEXT` batch in `docs/ASSET_TRACKER.md`; verify, advance the queue, hand off rather than close | T0 | 4 |
```

Once it is registered, **Start 2.1d** is the shorter equivalent command.

## Status rules

| Status | Meaning |
|---|---|
| `DONE` | Exported, catalogued, previewed, and passed the verification contract below |
| `NEXT` | The single batch the next asset agent must make |
| `IN PROGRESS` | Claimed by an agent; nobody else starts an asset batch |
| `QUEUED` | Ordered backlog; do not skip ahead without recording why |
| `BLOCKED` | A named dependency is missing |
| `CUT` | Deliberately removed from scope; retained here so it is not proposed repeatedly |

There must be exactly one `NEXT` row while unfinished work remains. Priority is top to bottom, first
by phase and then by batch number. A batch may be promoted only when its `After` dependency is done.

## Agent production contract

An agent starting 2.1d must:

1. Run `.agent/bin/agent start`. If 2.1d is absent, bootstrap it exactly as described above, but only
   when `docs/ROADMAP.md` is unclaimed. Then run `.agent/bin/agent brief 2.1d`.
2. Read this file, `docs/DESIGN.md` section 6, `docs/DECISIONS.md` D-004 through D-007, and the README
   for the asset family being extended. Do not survey unrelated code.
3. Confirm there is exactly one `NEXT` row. Change it to `IN PROGRESS` and record the batch ID with
   `agent note 2.1d`.
4. Claim `docs/ASSET_TRACKER.md`, `docs/ROADMAP.md` if this run bootstrapped 2.1d, and every source,
   generator, catalog, preview, and export path the batch will touch — plus, by exact path with the
   Godot editor closed, any `content/*.tres` the batch itself owns (D-031; the boundary A-021S ran
   under, see *Explicitly not asset-agent work* below). Scenes and resources belonging to other
   batches or tasks stay untouched.
5. Make only the named batch. Closely related state variants count as part of the same asset; unrelated
   bonus models do not.
6. Run the verification contract. Visually inspect every preview, not just file existence.
7. Update the row with the actual asset count, output location, verification result, and commit hash
   if known. Mark it `DONE`, promote the next eligible row to `NEXT`, then run
   `agent handoff 2.1d "..."` and `agent ship 2.1d "Art: <batch name>"`.
8. Use `agent done 2.1d` only when every non-cut batch in this document is complete or Sequoyah
   explicitly ends the production queue.

If a batch proves too large for one clean commit, split it into lettered children such as `A-014a`
and `A-014b` in this file before making anything. Never silently leave half a batch marked done.

## Art and export contract

- Flat-shaded, saturated low-poly art with strong silhouettes. The Mire uses desaturated
  purple-black materials and emissive accents.
- Metres, +Y up, ground-centred origins, applied transforms, descriptive `snake_case` names.
- Individual portable GLBs with embedded materials. Editable `.blend` sources stay below
  `assets/source/`, which is excluded from Godot import by `.gdignore`.
- Assets contain no gameplay authority. Placement, harvesting, damage, loot, Ward behavior, enemy
  state, and destruction remain host-authoritative systems.
- Static presentation meshes contain no authored Godot collision. When a task needs collision or
  scene wiring, the agent adds it under a D-031 exact claim and verifies headlessly (D-039) — hand
  it to Sequoyah only when it needs his eyes.
- Prefer a new small generator/source kit per coherent family over turning
  `build_mire_map_kit.py` into one enormous file.
- Suggested polygon targets, not quotas: foliage/ground cover 30–400; ordinary props 50–800; hero
  props 300–2,000; first-person weapons 500–2,500; enemies 1,000–4,000 before animation testing.
- State sets must retain a recognizably shared footprint so gameplay can swap intact, damaged,
  depleted, corrupted, and destroyed meshes without collision surprises. **Centre the states on the
  geometry they share, not on each state's own bounds** — A-005 hit this and the next state set will
  too. Normalizing each state independently moves the object whenever a state adds geometry the
  others lack (an opened lid, a debris skirt, a lean), so the mesh visibly jumps at the moment it is
  swapped and drifts away from collision authored against a sibling. `build_loot_set.py` takes an
  `anchor_parts` filter for this and verifies the result; A-005 measured 0.00 mm drift across three
  pairs. Record the drift figure in the batch row.
- A state that opens or breaks must actually reveal something. A container built as a solid block
  looks identical opened and closed apart from the lid, and any contents modelled inside it are
  sealed where nothing can see them — build the cavity, and fill it to near the rim, because
  anything sitting on the floor of a chest is hidden behind its front wall at standing eye height.
- Material variants are welcome when they communicate state. Recolouring one mesh does not count as
  several distinct assets in the tracker.

## Look at the back of the asset (task 2.1j)

Every batch above recorded a "two-preview visual inspection", and **both of those previews are one
camera angle**. Only A-004R and A-021S ever orbited an asset. So the back, the far side and the
underside of most of MIRE's 224 exports had never been looked at by anyone, and the art shows it.
Sequoyah's example: *"the log only having branches on the front pointing all in the same
direction"*. In `build_pickup_kit.py` that was literally three ridges at `y = -0.20` running the
same direction, and the same hand put the mushroom's three cap spots at y=-0.25/-0.31/-0.18 and the
salvage fragment's three glow nodes at y=-0.20.

**The instrument now exists. Use it before marking any batch `DONE`:**

```text
Blender --background --python tools/blender/audit_all_sides.py -- --only <substring>
```

It renders every matching GLB from eight azimuths plus top and bottom into one contact sheet under
`assets/audit/sheets/`, with the key light following the camera so no side is hidden by shadow, and
writes numeric checks to `assets/audit/geometry_report.json`. That output is **regenerable and not
committed** — it is 35 MB per full run. `tools/blender/detail_distribution.py`
ranks assets by how tightly their protruding detail clusters on one side.

Two things learned the hard way while building it, so nobody re-learns them:

- **`recalc_face_normals` cannot judge these meshes.** They are unwelded face soup, so every edge
  reads as non-manifold and the recalc reports nonsense — it claimed 46 of 128 faces inverted on a
  clean asset. Signed volume (divergence theorem) is the check that works, and by it **no shipped
  asset is inside out**.
- **`smooth_shaded_faces` measured on an imported GLB is not a defect.** glTF stores flat shading as
  split per-vertex normals, which Blender re-imports as smooth-with-custom-normals. The generators
  do force flat shading. Do not chase this number.
- **The one-sidedness metric is triage, not an oracle.** It correctly flagged `pickup_log` (R=0.86)
  but *missed* `fallen_log_a` (R=0.15), because a branch stub is itself a cylinder whose vertices
  spread across sectors and dilute the signal. It also over-flags intentional asymmetry — a roof
  slope, an open chest lid, an axe head. Rank with it; judge with the contact sheet.

### Scale was never checked against the player

A second failure with the same root cause: each asset was sized to fill its own preview frame.
Measured across the pickup kit — a coin **0.36 m** across, a berry **0.71 m**, a stone **1.08 m**, a
1.50 m log. Fourteen objects whose real sizes span roughly 50:1 all landed within 4:1 of each other.
The scale previews existed but were only used to confirm a reference was *present*, never to check
each object against it.

`mire_art.SCALE` now holds the real longest-axis dimension for anything a player can size against
their own 1.80 m body, and `mire_art.check_scale()` **fails the build** when an asset drifts more
than 12%. It caught five drifts on the first rebuild. Small items are made legible by *quantity*
rather than inflation: the coin pickup is a spill of five true-size 26 mm coins, the berry pickup a
handful of seven.

### Pick palette values from base colour, never from a render

The first cut of `mire_art.PALETTE` was authored by eyeballing hex values against
the existing preview renders. Every one of them came out 25-40% too dark, because
a preview has AgX tone mapping applied on top — matching the *rendered* look means
the base colour gets darkened twice, once by you and once by the renderer. `iron`
should be `#95A6AC`; it was set to `#4A555C`. The icon contact sheet is what
exposed it: the cleaver, skewer, iron pickaxe and iron sword all read as
near-black silhouettes on the dark hotbar.

All 53 tokens were re-anchored by converting the shipped art's own linear base
colours to sRGB, so the palette inherits brightness that was already tuned to read
in-game while still collapsing seven browns and four greys down to one each. If
you add a token, take its value from a base colour, and check it on the icon sheet
rather than in a lit preview.

### Migration status (2.1j)

**All ten art generators are on the shared palette.** No `build_*.py` defines a colour any more —
every one of the original 233 private material definitions is gone, and a raw RGB tuple in a
generator is now a bug rather than the norm.

| Generator | Migration | Notes |
|---|---|---|
| `build_pickup_kit.py` | **full** | palette + primitives + true scale + all-round detail |
| `build_tool_weapon_set.py` | **full** | 185 helper lines deleted, zero dimension change |
| `build_loot_set.py` | **full** | 116 helper lines deleted; chest state pairs still share anchors |
| `build_ward_set.py` | **full** | keeps a bevel-free `box()` override on purpose (F-057) |
| `build_crafting_stations.py` | palette | primitives local; keeps a bevel-free `box()` override on purpose (F-057) |
| `build_mire_map_kit.py` | palette | + fallen logs rebuilt all-round |
| `build_harvestable_resources.py` | palette | |
| `build_wellspring_set.py` | palette | its `cone` defaults to 10 vertices |
| `build_enemy_crawler.py` | palette | its `cone` defaults to 6; rigged, re-run the deform check |
| `build_adapted_nature_set.py` | palette | |
| `build_playtest_hollow.py` | n/a | imports shipped GLBs; rebuild it after any art change |

**Only swap the geometry primitives when the local ones match.** `mire_art`'s
`cylinder_between` uses 8 vertices and a 0.94 end taper. `build_mire_map_kit.py`
uses 7 and no taper; `build_harvestable_resources.py` tapers to 0.82. Swapping
those would reshape every asset in the kit, and the environment and harvestable
families are placed in both authored maps. Migrate the palette, leave the
primitives, and prove it with a catalog dimension diff — colour-only migrations
must show zero dimension changes.

**`world_bounds` must flush the depsgraph before measuring.** Assigning
`obj.location` does not refresh `matrix_world`, so measuring without
`bpy.context.view_layer.update()` reads the object where it was *before* the
builder moved it. This is silent: the asset still exports, just mis-measured and
mis-grounded. It cost the woodcutting block 0.31 m of height and only a catalog
diff noticed. `mire_art.world_bounds` now does it for every caller.

**`around()` defaults to `axis="z"`.** For anything whose long axis is X — a log,
a haft, a beam — pass `axis="x"` or the "radial" spread fans out horizontally and
the asset ends up just as flat as the one-sided version you were fixing. And bias
the spread off the underside: a branch aimed straight down jacks the whole asset
up onto it when `create_asset` grounds it.

### Rebuild order after touching the palette

`mire_art.PALETTE` is upstream of everything. After changing a token:

1. Rebuild every migrated generator.
2. `render_item_icons.py` — icons are rendered from the shipped GLBs and go stale.
3. `build_playtest_hollow.py` — it imports the shipped GLBs at build time, so the
   authored map keeps the old art until rebuilt.
4. `agent godot --script tools/item_icons_check.gd` and `playtest_hollow_check.gd`.

Godot caches glTF imports. `agent godot` now runs its own import pass before every check (F-093,
fixed) — re-running does *not* help on its own, that pass is what makes the check see the rebuild. A
hollow visual count that still looks wrong after that pass is your geometry, not the cache.

### Massing primitives, and how to use a reference pack (A-000V)

`mire_art` now carries three primitives that exist because MIRE's art was being *assembled* where a
person would have *sculpted*. A crown was nine ellipsoids; a mossy boulder was a boulder with a moss
ellipsoid stuck on one flank.

| Primitive | What it replaces | Also good for |
|---|---|---|
| `hull()` | a heap of ellipsoids standing in for one mass | boulders, bushes, crowns, mushroom caps, bread, clouds |
| `paint_faces()` | a separate blob stuck on to mean "mossy" | moss, snow, lichen, rust, scorching, pooled blood |
| `fork()` | "six branches, each with two twigs" | dead trees, roots, cracks, lightning, antlers |

`paint_faces()` is the one worth reaching for first: it assigns a second material to faces by
orientation and height, so the detail costs **zero geometry**. `build_mire_map_kit.py`'s
`build_boulder` should use it instead of `ico("Moss", ...)` — the current moss is both more triangles
and more obviously a sticker, and it only exists on the side its author was looking at.

Three traps, all paid for once already:

- **You cannot make a hanging curtain by drooping a sphere.** Pulling lobes out of a round canopy
  gives it notches; hanging round masses off the rim gives it ears. A curtain has to be *built* tall
  and narrow. `droop` is for softening the underside of a canopy that is already the right shape.
- **`fork()` returns its tips depth-first**, so `tips[:5]` is every tip of the first branch and
  nothing from the others — the 2.1j one-sidedness defect, reintroduced by a slice that looks
  harmless. Sample across the list.
- **A bush is three overlapping masses, not one and not eighteen.** One reads as an egg; eighteen
  reads as a bag of peas. Three gives the silhouette shoulders, and costs 240 triangles.

**Using a supplied reference pack.** Sequoyah's instruction, verbatim in intent: *use it for
inspiration, don't assume that is how everything has to be, and don't copy it — it's somebody else's
work, we want our own.* That holds **even when the licence permits copying**; the pack that prompted
these primitives is CC0 and the rule still applied. Measure how a reference is built — element counts,
materials per asset, where detail is spent — then write our own generator that uses the same *method*.
Never import, trace, retopologise or ship the reference geometry. Where its choices conflict with a
decision this project made on purpose, the project wins: that pack's palette is much darker and more
olive than ours, and ours was deliberately re-anchored bright after being authored too dark once
already. Record in the batch row which techniques were adopted, so provenance is never ambiguous.

### One palette, one set of primitives

`tools/blender/mire_art.py` is now the shared art library and generators must draw from it.
Before it: **233 material definitions across 11 generators, 216 of them a distinct colour, and not
one colour shared between two families** — wood was seven different browns, iron four greys,
leather two. `material()` existed in five different signatures and four generators could not express
metal at all because their copy had no `metallic` parameter; `box()`, `ico()` and `cone()` were
copy-pasted 9–11 times each. Colour is now authored in **sRGB hex** (a human can see that `#2E1A10`
is charred wood; nobody could see it in `(0.075, 0.025, 0.014)`), stored linear, and reached by
semantic token. A raw RGB tuple in a generator is a bug.

`mire_art.radial()` is the direct cure for one-sided detail: it hands out angles around an axis
instead of coordinates, so the even spread is the default and the one-sided cluster is the thing you
have to work at.

Reserved hues, so they keep meaning something: **purple is corruption, teal is the Ward.** Do not
spend either on decoration.

## Verification contract

Every completed batch records evidence for all applicable checks:

- **Record the exact Blender version the batch was built with** (D-038 — the toolchain is pinned the
  way the engine is; every deterministic-rebuild claim below depends on it). After any Blender
  upgrade, the first batch re-verifies a clean rebuild of an existing family before shipping
  anything new.
- Generator syntax check and deterministic clean rebuild.
- **Compare rendered PNGs by pixels, never by file hash.** Blender stamps its own render wall-clock
  and the current date into `tEXt` chunks — `RenderTime`/`Date` from EEVEE, `cycles.ViewLayer.total_time`
  from Cycles — so a preview or an icon can never be byte-identical across two runs, and the whole
  set turns up "modified" in `git status` after a rebuild that changed nothing. Use
  `tools/png_pixels_equal.py` (F-079) — `images_pixel_equal(a, b)` or the CLI
  (`python3 tools/png_pixels_equal.py a.png b.png`) — rather than decompressing `IDAT` by hand; it
  diffs decoded pixel bands directly and doesn't fall into `ImageChops.difference().getbbox()`'s
  `alpha_only` trap on opaque RGBA images (F-079). A-021S re-ran the icon pipeline unchanged and found
  24/24 pixel-identical behind 24 dirty files (reconfirmed 2026-08-18 against the current 26-icon set,
  F-042); restore the dirty files rather than committing the churn. EEVEE additionally jitters
  anti-aliasing on thin diagonal silhouettes (A-042a moved the icons to Cycles for this): A-021S's
  viewmodel preview differed by 9 bytes in 4,992,780, max delta 3/255, which is the noise floor, not
  a broken rebuild — `png_pixels_equal.py` does exact comparison with no tolerance, so a preview still
  rendered in EEVEE can report a real diff for this reason alone; treat a few-bytes/low-delta report
  on a near-diagonal silhouette as this known noise floor, not a regression.
- GLB 2.0 validation: every expected export exists, has meshes, positive dimensions, applied scale,
  embedded materials, and a sane polygon count.
- Catalog matches the exports exactly: no missing, duplicate, or orphan records.
- Category preview plus a scale-reference preview rendered at a useful resolution.
- Visual inspection for silhouette, ground contact, clipping, accidental smooth shading, material
  consistency, and first-person readability where applicable.
- Fresh Godot 4.7.1 import with zero missing imported scenes and no Blender-path dependency.
- For rigs/animation batches: deform check, animation-name check, looping check where applicable, and
  a rendered contact sheet of key poses. Godot scene hookup is done by whichever task needs it,
  under D-031 claims (D-039) — visual tuning stays Sequoyah's. A-006 ran these
  first and the specifics are worth reusing:
  - **Deform check across every primitive.** The exporter splits a multi-material mesh into one
    primitive per material, so reading `meshes[0].primitives[0]` samples a fraction of the model and
    reports most bones as owning no geometry. Union `JOINTS_0`/`WEIGHTS_0` over all primitives, then
    assert that every deform bone appears. A bone with no vertices is a limb that will not move.
  - **Check clip duration in seconds, not frames.** glTF stores animation time in seconds, so the
    exporter divides frame numbers by whatever `scene.render.fps` holds — Blender's default is 24.
    Set the frame rate before the first export, and compare each exported clip's `max - min` sample
    time against its authored length. A-006 shipped every clip 25% slow until this check caught it,
    and nothing in the .blend looked wrong, because the frame numbers were correct.
  - **Check the animation names Godot ends up with, not the ones exported.** Godot 4 reads a `-loop`
    name suffix as an instruction to loop the clip and then removes it, so `idle-loop` imports as
    `idle`. Verify names and loop modes on the imported scene, in Godot, and record the engine-side
    names for gameplay — this is what `tools/enemy_crawler_check.gd` is for.
- **An opening has to survive being drawn from standing eye height, not just exist.** A-005's rule
  that a state which opens must reveal something has a sibling: a cavity is only visible along a
  sightline. A-006's nest was first built as a dome with a throat inside it, then as a ring of lobes
  of even height, and both read as a pile of rocks in the preview, because at a player's eye level
  the far wall is simply the near wall's backdrop. It needed the rim dropped away on the viewing side
  before the mouth was legible. Judge these on a preview shot from roughly player height, never from
  above.

### Sheet-built assets need their own winding proof (A-009)

A-009 is the first batch whose assets are mostly **open surfaces** — a planked hull, a sail, a cap
rail — rather than closed solids, and two of the standing instruments do not transfer:

- **The audit's inside-out test cannot judge an open sheet** (F-109, **fixed**). Its divergence-theorem
  sum is dominated by where the sheet sits relative to the world origin, not by which way it faces, so
  it false-positived on every correct back/rim/underside face and would have missed a real inversion on
  the far side of the origin — it reported 96 "inside out" objects on the fully verified repaired hull
  alone. `audit_all_sides.py` now recognizes which objects it can actually judge: `is_closed_shell()`
  welds vertices by position and only trusts the volume-sign test when every welded edge borders
  exactly two faces, filing anything else under a new `open_surface_objects` key instead of
  `inside_out_objects`. That number is now 0 across the shipped A-009 batch. It still cannot tell you
  whether an open sheet's winding is *correct* — only the generator that authored the sheet knows the
  intended outward direction, which is what the next bullet is for.
- **The generator is the only place that knows the intended outward direction**, so that is where the
  check belongs. `build_extraction_ship_set.py` logs every sheet it emits with the outward vector it
  was asked for and the area-weighted normal it produced, and fails the build when they disagree.
  Copy that. It caught two inverted ramp edges outright, and before it an inverted transom on all
  four hull states — which under Godot's back-face culling is a hole in the stern, not a shading nit.
- **Never decide a sheet's winding from its first quad.** On the transom and the stem the first quad
  is degenerate — both sides meet on the centreline at the keel — so its cross product is the zero
  vector and the sign test reads noise. Decide from the largest-area quad, and emit a two-coincident-
  corner quad as the triangle it actually is.

**A lid's rotation sign is apparently a per-batch tax.** A-005 recorded the trap on its chest lids;
A-009 hit it again on the cargo hatch, where the inverted sign left the lid hanging in mid-air beside
its hinge. If a part pivots, render it and look — the arithmetic looks right either way.

**And measure vertices on the engine side too** (F-108). `Transform3D * AABB` inflates through
rotation exactly the way Blender's `bound_box` does (F-094), and every `cone`/`tapered_between`
primitive is a rotated object, so a check built that way reported seven of these fifteen exports
oversized when nothing was wrong with them. `tools/flora_check.gd` still has this construction.

**Re-run the audit against a clean `--outdir`** after any rebuild (F-110). Its resume ledger keys on
the asset name, not the GLB's contents, so a second run happily re-reports defects you have already
fixed.

## Completed baseline

`A-000` is the original environment/map kit. Its exact per-file inventory and measurements live in
`assets/environment/catalog.json`.

| Batch | Status | Made | Count | Evidence |
|---|---|---|---:|---|
| A-000 | `DONE` | Pines, bare trees, birches, crooked trees; boulders, rock clusters, standing stones; stumps, fallen logs, roots; grass, ferns, reeds; mushrooms, Mire crystals, tendrils; ruined walls, columns, arches, markers; modular wood, stone, roof, stair, railing, fence, corner, and gate pieces. Task 2.1i rebuilt all 18 trees with tapered trunks, roots, branches/forks, and attached faceted crowns | 128 | `assets/environment/README.md`; 23,489 polygons after the 2.1i audit; exact 128-file catalog and two clean GLB/catalog rebuilds matched |

### Supplemental adapted imports

User-supplied models are tracked separately so they do not inflate or reorder the production queue.

| Set | Status | Made | Count | Evidence |
|---|---|---|---:|---|
| S-001 | `DONE` | Adapted supplied mossy boulder and broadleaf tree: removed render/diorama geometry, normalized scale/origin/transforms/names, remapped to MIRE's saturated palette, grounded the boulder with faceted footing stones, and varied the canopy. Runtime outputs live in `assets/environment_additions/` | 2 | 1,780 polygons; byte-identical GLBs/catalog across two Blender 5.2 rebuilds and two-preview visual inspection passed |

The baseline is presentation-ready but not editor-wired: it has no collision, harvest states, or
gameplay scenes. Do not count those missing behaviors as missing meshes unless a batch below names a
visual state for them.

The Hollow is the only map. `playtest_map` was removed in 2.1j at Sequoyah's request, along with its
generator, source, GLB, scene, check and the `TestMapProps` autoload that loaded it. The Hollow's
open ground is a heightfield rather than flat slabs: `tools/mapgen/hollow_layout.py` emits the grid,
`build_playtest_hollow.py` meshes it flat-shaded, and `world/gen/playtest_hollow.gd` builds a
collider from the same triangles, so the visual and the collision cannot drift apart.

## P0 — first complete playable loop

These assets support gathering, crafting, one satisfying fight, loot, a Ward, a Wellspring, and
extraction. Make these before broad biome decoration.

| Batch | Status | Asset set | Planned models | After |
|---|---|---|---:|---|
| A-001 | `DONE` | Harvestable tree states: intact pine, two damage stages, felled trunk, fresh stump, depleted stump; stone node states: intact, cracked, depleted; iron node states: intact, cracked, depleted. Task 2.1i replaced stacked-cone crowns and decal damage with branch-supported foliage, concave axe cuts, broken limbs/chips, and coherent felled/stump silhouettes. Made 12 in `assets/harvestables/`; 3,792 polygons | 12 | A-000 |
| A-002 | `DONE` | Basic world pickups: log, branch, stone, flint, iron ore, iron ingot, coal, fibre bundle, berry, mushroom, raw meat, coin, coin stack, salvage fragment. Made 14 in `assets/pickups/`; deterministic rebuild, GLB/catalog validation, two-preview visual inspection, and fresh Godot import all passed | 14 | A-001 |
| A-003 | `DONE` | First crafting stations: primitive workbench, upgraded workbench, campfire, cooking spit, stone furnace, anvil, repair bench, woodcutting block. Made 8 in `assets/crafting_stations/`; 1,651 polygons. **F-057 found the original "deterministic rebuild passed" claim false** (bevel modifier drift, same mechanism `build_ward_set.py` first found) and, separately, that the checked-in GLBs didn't match a clean rebuild at all, having been swept into an unrelated commit (F-197). Re-fixed with the same bevel-free `box()` override every other byte-identical-rebuild family already carries (D-124); rebuilt clean and re-verified: `tools/blender/crafting_stations_repro_check.py` gives byte-identical GLBs and catalog across two real separate-process rebuilds (six total rebuilds, all pairwise identical), reproduced the pre-fix drift directly before re-fixing, and a fresh Godot import (`agent godot --quit-after 30`) now loads all 8 with zero errors | 8 | A-002 |
| A-004 | `DONE` | First tool/weapon set: wooden axe, stone axe, wooden pickaxe, stone pickaxe, iron pickaxe, cleaver, skewer, short bow, arrow, repair hammer. Made 20 paired world/viewmodel exports in `assets/tools_weapons/`; deterministic rebuild, paired consistency, GLB/catalog validation, three-preview visual inspection, and fresh Godot import all passed. **Rebuilt by A-004R** — see the row below | 20 exports | A-003 |
| A-004R | `DONE` | Quality rebuild of all ten A-004 designs at Sequoyah's direct request, out of queue order (A-009 stays `NEXT`, unstarted). Flat extrusions replaced by ground profiles with per-point bevel distances, butted body/edge shapes, swept oval hafts, flared bits and short polls. Same ten names, same 20 exports, so nothing downstream is renamed. 114–348 polygons per design (12,608 triangles across all 20), every export within ~6 cm of its A-004 dimensions. Byte-identical GLBs and catalog across two Blender 5.2 rebuilds, GLB 2.0 validation 20/20 with catalog exact and no orphans, six-azimuth orbit inspection of every design, three-preview visual inspection, and a fresh Godot 4.7.1 import plus `tools/item_icons_check.gd` all passed. **F-198/D-124, 2026-08-19**: `build_tool_weapon_set.py` still called `mire_art.box()`'s bevel-capable version at one site (`Cleaver_Bolster`, `bevel=0.022`) despite this row's byte-identical claim; added the family's own bevel-free `box()` override (same shape as `build_ward_set.py`), rebuilt, and reverified. Cleaver drops from 174 to 154 polygons per export (both world and viewmodel), the only geometry change. `stone_axe` and `arrow` — neither calls `box(bevel=...)` — shift 4–6 mm in `depth_m` and lose a spurious `.001`/`.002` material-name suffix each: all eleven designs build in one Blender session, and removing `Cleaver_Bolster`'s old `modifier_apply` call (which reassigns `view_layer.objects.active`) removed a perturbation it was leaving for whatever design built after it. Confirmed stable rather than new nondeterminism by the byte-identical two-rebuild proof below, and well inside the "~6 cm of A-004" tolerance already documented above. `tools/blender/asset_repro_check.py --script tools/blender/build_tool_weapon_set.py --export-dir assets/tools_weapons/exports --catalog assets/tools_weapons/catalog.json --label A-004` proves byte-identical GLBs and catalog across two clean separate-process rebuilds (22/22), and `agent godot --script tools/item_icons_check.gd` still passes clean | 20 exports | A-004 |
| A-005 | `DONE` | Loot set: small/Wellspring/reinforced chests in closed and open states, coin pouch, powerup orb, item pickup bag, dropped-player backpack. Made 10 in `assets/loot/`; 2,542 polygons. Byte-identical deterministic rebuild, GLB 2.0 validation (10/10, catalog exact, no orphans), closed/open base-footprint drift 0.00 mm on all three pairs, two-preview visual inspection, and fresh Godot 4.7.1 import with zero errors all passed. **F-198/D-124, 2026-08-19**: `build_loot_set.py` still called `mire_art.box()`'s bevel-capable version at thirteen sites (chest bodies, locks, cloth, bag parts) despite this row's byte-identical claim; added the family's own bevel-free `box()` override (same shape as `build_ward_set.py`), rebuilt, and reverified. Polygon total drops from 2,542 to 1,542 (chamfers square off per D-124's accepted tradeoff); footprint (`width_m`/`depth_m`) is unchanged on every export, so the closed/open drift-0.00mm claim still holds structurally — same shared body function, same anchor, only the modifier removed. `tools/blender/asset_repro_check.py --script tools/blender/build_loot_set.py --export-dir assets/loot/exports --catalog assets/loot/catalog.json --label A-005` proves byte-identical GLBs and catalog across two clean separate-process rebuilds (10/10), and `agent godot --script tools/loot_content_check.gd` plus a fresh Godot import still pass clean | 10 | A-002 |
| A-006 | `DONE` | **Gate waived by Sequoyah on 2026-08-16, not missed.** A-005's agent had marked this `BLOCKED` on combat task 2.9, which is still not started; Sequoyah directed it built anyway, so the crawler's feel targets come from `docs/DESIGN.md` §6 rather than from playtest, and 2.9 should re-check them. Prototype enemy set: six-legged Mire crawler with a 17-bone rig and idle, locomotion, attack tell, attack, hit and death clips; spawn nest; shell and leg death fragments. Made 4 in `assets/enemies/`; 1,172 polygons, crawler 794. Byte-identical deterministic rebuild (GLBs + catalog; previews pixel-identical), GLB 2.0 validation (4/4, catalog exact, no orphans), deform check 16/16 deform bones own geometry, clip-name and duration check against the authored timing, three-preview visual inspection including a rendered pose contact sheet, and a fresh Godot 4.7.1 import plus `tools/enemy_crawler_check.gd` (skeleton, skin, six clips, loop modes) all passed. **F-198/D-124, 2026-08-19**: `build_enemy_crawler.py` has always defined its own local `box()` override, but it copied `mire_art.box()`'s bevel-applying body verbatim rather than stripping it — an override that looked like the ward-set pattern at a glance without ever changing behavior, so this batch was exposed at five sites (thorax, collar, waist, head, jaw plate) despite this row's byte-identical claim. Fixed the override to actually drop the modifier, rebuilt, and reverified. Polygon total drops from 1,172 to 972 (crawler 794→634, shell fragment 59→19; nest and leg fragment are unaffected — no `bevel=` sites of their own — and stay at 283 and 36); rig (17 bones, 6 clips) and skin weights are untouched by a box-only change. `tools/blender/asset_repro_check.py --script tools/blender/build_enemy_crawler.py --export-dir assets/enemies/exports --catalog assets/enemies/catalog.json --label A-006` proves byte-identical GLBs and catalog across two clean separate-process rebuilds (4/4), and `agent godot --script tools/enemy_crawler_check.gd` still passes clean (17 bones, 6 clips, all loop modes correct) | 4 models + 6 clips | Combat task 2.9 confirms feel target |
| A-007 | `DONE` | Basic Ward set: foundation, healthy Ward, damaged Ward, critical Ward, destroyed remains, repair scaffolding, boundary post, activation crystal. Task 2.1i added the pronged socket, state-aware inlays, satellite shards, and damaged crystal tip. Made 8 in `assets/wards/`; 2,460 polygons. Byte-identical GLBs/catalog across two Blender 5.2 rebuilds and shared-foundation drift 0.00 mm passed | 8 | A-003 |
| A-008 | `DONE` | Wellspring set: distant monolith, base, crystal, basin, roots, uncapped state, capped state, re-corrupting state, corrupted state, ritual pedestal, boundary stones, guardian platform. Task 2.1i added complete/broken ritual crowns, condition-aware inlays, satellite spires, and a stronger monolith silhouette. Made 12 in `assets/wellsprings/`; 4,097 polygons. Byte-identical GLBs/catalog across two Blender 5.2 rebuilds and shared 4.6 m foundation drift 0.00 mm passed | 12 | A-007 |
| A-021S | `DONE` | **Iron sword, at Sequoyah's direct request, out of queue order**, split out of A-021. Made 2 exports + 1 icon: `iron_sword_world.glb`, `iron_sword_viewmodel.glb` in `assets/tools_weapons/`, `assets/icons/exports/icon_iron_sword.png`, plus `content/items/iron_sword.tres` and `content/weapons/iron_sword.tres`. 421 polygons / 1,000 triangles, 0.510 × 0.114 × 1.724 m — the set's hero, against 114–348 polygons for A-004R's ten. Diamond-section blade with a fuller, bright ground edges butted onto the core, upswept crossguard with brass quillon caps, brass écusson, leather grip with cord risers, faceted wheel pommel. Needed a new primitive: `lofted()` builds a solid through explicit cross-sections, because `ground_profile()` insets toward the profile centroid and on a blade a metre long that pull is almost entirely *downward* near the point, leaving a square wall where the edge should be. Verified: two clean rebuilds gave byte-identical GLBs (22/22) and catalog; GLB 2.0 validation 22/22 with catalog exact, no orphans/duplicates, ground origin, horizontally centred, embedded materials, no skins/animation; six-azimuth orbit inspection plus a blade-section close-up; three-preview visual inspection; fresh Godot 4.7.1 import; `tools/item_icons_check.gd` PASS; and the sword granted, held and swung through all four phases in the **running game** at 1280×720 with zero failures | 2 exports + 1 icon | A-004 |
| A-000V | `DONE` | **Vegetation expansion, at Sequoyah's direct request and out of queue order** — A-009 stays `NEXT` and unstarted, the same precedent as A-004R and A-021S. The environment kit had exactly one shape of ground cover (bladed grass, four sizes) and nothing between ankle-height grass and a full-grown tree, so a map read as one repeated texture however many grass variants were scattered. Made 84 in a new `flora` kit (`assets/flora/`, `tools/blender/build_flora_set.py`): 13 shrubs, 10 small trees, 16 leafy plants, 13 flowers, 18 grasses, 14 ground cover; 30,984 triangles, 12–1,012 per asset, at most four materials each. Sizes are **guaranteed by construction** — each asset is scaled to a target drawn from its group's band, with a separate footprint cap because scaling a rosette to a height band inflates its reach (`bracken_c` was a correct 0.95 m tall and 4.34 m across). Verified: build-time contract (size band, footprint cap, colour cap, ground contact, no floating mesh islands) **fails** rather than warns and passes 84/84; all-sides audit of every asset from eight azimuths plus top and bottom with **0 numeric defects**; and `tools/flora_check.gd` cross-checks the **engine's** measurements against the catalog and instantiates the real level, where `world/gen/undergrowth.gd` places **2,932 plants through 78 MultiMeshInstance3D nodes**. Filed F-092, F-093, F-094 (renumbered 2026-08-18 from F-058/F-059/F-060, which collided with unrelated
findings — see F-087) — all three found by this batch and all three fixed. Partially anticipates A-011 and A-015; both keep their rows, since neither's gameplay-bearing assets (harvestable berry bushes, state sets) are made here | 84 | A-000 |
| A-009 | `DONE` | Extraction ship set — the object `DESIGN.md` §5.2's cash-out decision is made in front of, so built as one hero landmark: a 10.4 m hull, 3.8 m to the stem head, on a timber repair cradle. Made 15 in `assets/ships/` (`tools/blender/build_extraction_ship_set.py`, Blender **5.2.0 LTS**, unchanged since A-000V so no re-verification was owed under D-038); **10,456 triangles**, 116–1,750 per asset, at most 8 materials each. **The hull is a swept surface, not an assembly**: a thirteen-station table of half-beam/keel/sheer, meshed as quad strakes — a boat built from boxes reads as boxes from every angle its author was not looking at, and a swept surface has no favoured side. **Eleven of the fifteen share the hull's coordinate frame instead of being individually ground-centred**, so a scene assembles the whole ship by adding every part at `Transform3D.IDENTITY` and nothing is left for a human to position by eye (D-039); the four standalone props normalize the usual way. `assets/ships/README.md` is the placement contract. The four hull states are one builder with a different hole set, strake palette and deck coverage, so **state drift is 0.0000 mm measured in the engine** — because nothing is re-centred, not because the re-centring agrees. Verified: build contract (scale table, triangle and material budgets, per-family origin rule, and a **winding proof** — every emitted sheet's area-weighted normal checked against the outward direction it was asked for) **fails** rather than warns, and passes 15/15; two clean rebuilds gave **byte-identical GLBs 15/15 and byte-identical catalog**, with all four previews **pixel-identical** behind differing file bytes (F-042); all-sides audit of every asset from eight azimuths plus top and bottom at **0 degenerate faces, 0 loose vertices, 0 unapplied transforms**; four preview renders; and `tools/ship_check.gd` cross-checks the **engine's own vertex measurements** against the catalog, proves the 0.0000 mm state drift, and asserts the assembly — mast stepped inside the hull, rudder hung aft of the transom, ramp reaching both ground and deck and leaving the hull's footprint, hatch on the deck, both sails meeting the mast above deck level. Six defects were found and fixed by the instruments rather than by luck: an inverted transom on all four states (the winding was decided from a degenerate quad), two inverted ramp edges, ribs standing proud of the planking, a hatch lid floating beside its hinge, a boom set below the bulwark, and moss that painted nothing. Filed F-108, F-109, F-110 | 15 | A-004 |
| A-010 | `DONE` | Practical construction kit — the pieces a player walks through, climbs, crosses or hides behind. Made 14 assets as **18 exports** in `assets/construction/` (`tools/blender/build_construction_set.py`, Blender **5.2.0 LTS**, unchanged since A-000V so no re-verification was owed under D-038); **7,568 triangles**, 160–1,356 per export, at most 6 materials each. **The pieces are only correct in relation to each other**, so the contract is a module rather than a shape: `MODULE` 2.00 m (matching `content/buildables/wall.tres` `size.x` and its 1 m snap grid), `WALL_H` 3.00 m (that wall's height — palisade, both gate frames, the door frame and the ladder all reach exactly it), `DECK_Z` 1.00 m (every bridge and dock walking surface) and a ramp rising exactly one deck over one module, **26.57°**, checked against the player's own `floor_max_angle` of 46° because `entities/player/player_controller.gd` implements no step-up at all — a vertical lip is a wall however low it is. Three origin rules, each because the usual one would hand a human an offset to find by eye (D-039): fourteen exports are ground-centred, `palisade_corner` is centred on **its corner post** so both arms end on the cell edges a straight section butts to, and the four leaves are centred on **their hinge axis** — the leaf's outer back corner — so a scene hangs one with `position = hinge_offset_m` and swings it with `rotate_y()` and nothing else. `assets/construction/README.md` is the placement contract; the catalog carries `run_span_m`, `mates_m`, `deck_z_m`, `opening_m`, `slope_deg` and per-leaf `hinge_offset_m`/`opens_toward`/`swing_deg`. Verified: the build contract (module span, deck plane, ramp slope, doorway clearance, hinge axis, per-family origin, triangle and material budgets) **fails** rather than warns and passes 18/18; two clean rebuilds gave **byte-identical GLBs 18/18 and byte-identical catalog**, with three of four previews pixel-identical and the fourth differing by one quantization step on **1 of 8,294,400 channel samples** (F-042 again, measured rather than assumed); all-sides audit of every export from eight azimuths plus top and bottom at **0 degenerate faces, 0 loose vertices, 0 inside-out objects, 0 unapplied transforms**; four preview renders including a door swung through 0/35/70/90°; and `tools/construction_check.gd` **assembles the kit in the engine** — a five-module walkway with a ramp onto it, a boardwalk corner, a fence corner and all four leaves swung through their documented arc against their own frame's triangles — at **worst joint 0.0000 mm**, deck 1.000 m, and **0.0000 mm** bridge state drift. Four defects were found by the instruments rather than by luck, and two of them only the engine could see: **every deck field was inset half a plank gap at both ends, so a run of modules showed a 12 mm stripe of daylight at every joint** while each piece still measured exactly 2.000 m wide; the door leaf's bottom 40 mm was buried in a 60 mm threshold that the player could not have stepped over anyway; the double gate's knee braces stood in the gateway at head height; and the swing test itself was condemning four innocent leaves by measuring rotated parts with the box around the rotated box (F-094 on the engine side). Filed F-129, F-130, F-131 | 14 assets / 18 exports | A-000 |

## P1 — world identity and survival readability

Do not start this phase until the M2 playtest (task 2.14) has produced its first feedback — "fun
before content" is the rule this queue runs under, and P1 is where a top-to-bottom reader would
otherwise sail past it (the audit found no gate here at all). Sequoyah can waive a specific batch
by saying so in its row, the way A-006 records its waiver.

> **2026-08-18 — P0 is complete. The P1 gate was waived by Sequoyah on 2026-08-18**
> ("keep making game assets"), which is the unblock the note below describes; A-011 shipped under
> it and A-012 is `NEXT`. The gate itself has not been *met* — 2.14's playtest has still not run —
> so P2 and P3 remain shut, and an agent reaching the end of P1 should stop and say so rather than
> promote across a phase boundary on the strength of this waiver. The original note follows.
>
> **P0 is complete, and there was deliberately no `NEXT` row.** A-010 closed the last P0
> batch, and every remaining batch in this file sits behind a gate a human clears, not an agent: P1
> waits on 2.14's playtest feedback, P2 on the one-enemy/one-weapon combat gate in `docs/ROADMAP.md`,
> and P3's batches each name a dependency that is still open. An asset agent picking up 2.1d should
> **say so and stop** rather than promoting a gated batch — that is what "fun before content" costs
> when the fun has not been measured yet. Sequoyah unblocks it either by running the playtest or by
> waiving one batch in its row (A-006 is the worked example). A-011 is marked `BLOCKED` for that
> reason and is otherwise ready: its dependency, A-000, is done.

| Batch | Status | Asset set | Planned models | After |
|---|---|---|---:|---|
| A-011 | `DONE` | **Gate waived by Sequoyah on 2026-08-18** — "keep making game assets", the same unblock A-006's row records and the same out-of-queue precedent as A-004R/A-021S/A-000V. Gatherable plants and deposits: berry bush full/harvested, poison berry bush, fibre plant, medicinal herb, wild onion, honeycomb, clay deposit, peat deposit, resin node. Made 10 in a new `gatherables` kit (`assets/gatherables/`, `tools/blender/build_gatherable_plants.py`); **5,184 triangles, 188–812 per asset**, at most 4 materials each (`poison_berry_bush` has a recorded allowance of 5 — the fifth is the bloom that is the whole asset). Blender 5.2.0 LTS. **The poison bush is a deliberate near-copy** per `ITEMS.md` §4.1/D7: same seed, same frame, same foliage colours, same berry geometry in the same places — both exports measure 0.910 × 0.727 × 0.780 m at 768 triangles — with one tell, a pale `berry_bloom` film on the fruit's upward faces, costing zero geometry (`paint_faces`). **The state pair drifts 0.000 mm**, and getting there extended A-005's rule: centring on shared geometry is not enough, the SCALE has to come from the shared geometry too, or each state sizes to its own bounds and silently rescales the frame they have in common. Seven palette tokens added (`berry`, `berry_bloom`, `wax`, `honey`, `clay`, `peat`, `resin`) and `Batch` lifted into `mire_art` — append-only, nothing downstream rebuilt. Verified: build-time contract **fails** rather than warns on 9 conditions and passes 10/10; all-sides audit of every asset from eight azimuths plus top and bottom against a clean `--outdir` (F-110) with **0 numeric defects**; and `tools/gatherables_check.gd`, **41 assertions, 0 failures**, measuring each imported GLB from its vertices rather than `Transform3D * AABB` (F-108). That last check earned its place immediately: Blender called `resin_node` grounded while the shipped GLB sat 53 mm underground and 93 mm too tall, because the exporter wrote the join's inherited rotation out as a node transform. **F-206/D-124, 2026-08-19**: `build_gatherable_plants.py` still called `mire_art.box()`'s bevel-capable version at six sites (terrain path, peat bank, and four plant/deposit details) despite carrying no byte-identical claim of its own — the exposure F-198 left latent rather than live. Added the family's own bevel-free `box()` override (same shape as `build_ward_set.py`), rebuilt, and reverified; triangle total drops from 5,472 to 5,184 (chamfers square off per D-124's accepted tradeoff), every catalog dimension unchanged at 3-decimal precision. This row now also carries the byte-identical claim A-012's already has: `tools/blender/asset_repro_check.py --script tools/blender/build_gatherable_plants.py --export-dir assets/gatherables/exports --catalog assets/gatherables/catalog.json --label A-011` proves byte-identical GLBs and catalog across two clean separate-process rebuilds (10/10), and `agent godot --script tools/gatherables_check.gd` still passes clean (41 assertions, 0 failures) | 10 exports | A-002 |
| A-012 | `DONE` | **Gate waived by Sequoyah on 2026-08-19** — "keep making assets", the same unblock A-011's row records. Food, tonics and the containers they come in. Made 13 in a new `food` kit (`assets/food/`, `tools/blender/build_food_set.py`); **2,864 triangles, 144–280 per asset**, at most 4 materials each (`healing_stew` has a recorded allowance of 5 — the fifth is the pale sheen that is the only thing separating it from the hearty stew at a glance). Blender 5.2.0 LTS. **Nine of the thirteen come off three shared frames**: five tonics are ONE fired flask, two stews are ONE turned bowl, and the raw and cooked fish are ONE fish. That is what makes a consumable kit readable — a player learns three silhouettes instead of thirteen and then reads the *colour* — and every difference between siblings costs **zero geometry**: a tonic is a glazed shoulder plus a wax collar (`paint_faces`), a cooked fish is the raw fish with char painted where the scales were, the healing stew is the hearty stew's bowl with a herbal sheen. A fired clay flask cannot show what is inside it, so the tell is deliberately on the outside; it reads at inventory-icon size, which is where a tonic is actually identified. Nine palette tokens added (`tonic_red`, `tonic_pale`, `tonic_amber`, `sludge`, `broth`, `bread_crust`, `bread_crumb`, `fish_scale`, `fish_belly`) — append-only, nothing downstream rebuilt. Names follow `ITEMS.md`: the food skewer is `meat_skewer`, never the weapon `skewer` (§4.4 flags the collision by name), and the "water flask" slot ships as `fired_flask` because §9 cut thirst and made that asset the tonic container. Verified: the build contract **fails** rather than warns on 9 conditions including sibling identity — siblings must match in bounds AND triangle count — and passes 13/13 at **0.0000 mm drift** across all three families; two clean rebuilds gave **byte-identical GLBs 13/13 and byte-identical catalog**; all-sides audit against a clean `--outdir` (F-110) with **0 numeric defects**; three contact sheets inspected; and `tools/food_check.gd` re-measures every import from its vertices, re-asserts the 0.0000 mm frame drift in the engine, and refuses a node transform on a static prop (A-011's 53 mm lesson). Filed F-204, which cost this batch an hour: a Blender preview that MOVES assets between renders draws the layout it had at the first render, so a sheet came out with a tile blank while the asset probed as present, visible and correctly placed | 13 exports | A-011 |
| A-013 | `DONE` | **Gate waived by Sequoyah on 2026-08-19** — "keep making assets", the third time that unblock has been recorded (A-011, A-012). Camp storage and furniture. Made 16 in a new `camp` kit (`assets/camp/`, `tools/blender/build_camp_set.py`); **5,470 triangles, 172–628 per asset**, at most 4 materials (the four racks and the lantern carry a recorded allowance of 5 — for the racks it is what hangs on them, which is the only difference between four deliberately identical frames; for the lantern it is glass, flame, iron, timber and rope, which is what a lantern is). Blender 5.2.0 LTS. **Everything structural comes off a stock list** — one plank thickness (32 mm), one plank width, one post, one rail, one iron band, one stave — and `plank()`/`post()`/`rail()`/`band()`/`lashing()` are the only ways to make it. Each logs what it emits and the contract **fails** if an asset produced a structural mesh that did not come through them, so a dimension nobody chose cannot enter the kit; parts that are honestly not timber (a sack, a bedroll, a lantern's flame) are declared per asset in `FREEFORM`. That is what makes a stool, a bench, a table and four racks read as one camp rather than eight purchases — and it caught its own author twice, on a bedroll built with a raw cylinder and on a shelf brace. **The four racks are one rack** (storage, weapon, tool, drying: same uprights, rails and lashings, differing only in their load) and **the crate is a state pair**, both centred and scaled on the geometry they share — **0.0000 mm frame drift**, and the engine re-asserts the consequence a player can see, that four racks stand the same height and width however differently they are loaded. Verified: build contract **fails** rather than warns on 10 conditions and passes 16/16 with 207 stock parts logged; two clean rebuilds gave **byte-identical GLBs 16/16 and byte-identical catalog**; all-sides audit against a clean `--outdir` (F-110) with **0 numeric defects**; three contact sheets inspected; and `tools/camp_check.gd` re-measures every import from its vertices at 0 failures. Four defects the contract caught: the footprint cap was being applied to the axis the size target already governs, so a 1.72 m table failed for being 1.72 m across; the smashed crate's boards were tilted 77° and the piece sat **170 mm into the floor**; the crate pair's anchor included the walls a smashed crate loses, so the state pair drifted by definition; and the crates were three widely-spaced boards, which reads as a cage | 16 exports | A-003 |
| A-014 | `DONE` | **Gate waived by Sequoyah on 2026-08-19** — "keep making assets", and then "keep going one by one until I stop you". Roads and navigation. Made 13 in a new `paths` kit (`assets/paths/`, `tools/blender/build_path_set.py`); **3,608 triangles, 108–632 per asset**, at most 4 materials (allowances of 5 recorded for `path_corrupted`, `warning_sign` and `signpost`). Blender 5.2.0 LTS. **This is the first batch governed by two earlier kits at once.** Every tiling piece is exactly A-010's 2.00 m module, measured on the walking SURFACE rather than the bounding box (F-135's lesson, inherited); and the boardwalk takes A-010's 55 mm plank rather than A-013's 32 mm board, on the rule *camp furniture is board stock, anything structural or walked on is plank stock*. **`boardwalk_stairs` is the join between the two kits**: it climbs from this kit's 0.22 m boardwalk deck to A-010's 1.00 m dock deck over one module — 21.3°, inside the player's 46° floor limit (F-136) — so a low walkway over mud and a raised dock over water are one continuous route. **Four surfaces, one slab**: dirt, mud, cobble and corruption share the tile geometry (0.0000 mm frame drift) and differ in what sits on it, so a mixed run tiles. Each carries a verge — the ring of quads traffic never reaches — assigned by POSITION during slab construction rather than by `paint_faces`, because a path's height range is 28 mm and height-based selection painted blocky patches of grass down the middle of the road. One palette token added (`water_still`), and its first value was wrong in a way worth recording: a puddle at #41504B read as Ward teal from above, which is the one association a road must not carry. Verified: build contract **fails** rather than warns on 9 conditions and passes 13/13; two clean rebuilds gave **byte-identical GLBs 13/13 and byte-identical catalog**; all-sides audit against a clean `--outdir` with **0 numeric defects**; three contact sheets inspected, each shot at the angle its assets are actually judged from (ground from above, boardwalk from a walker's height, markers from standing); and `tools/path_check.gd` re-measures every import, confirms the 2 m module across all 8 tiling pieces and asserts the stairs top out on A-010's deck. Two defects the contract caught: it was demanding boardwalks tile sideways as well as along their run, which would make a walkway a road; and the mud's churn wandered 80 mm past the tile so a placed run overlapped its neighbours | 13 exports | A-010 |
| A-015 | `NEXT` | Wetland nature: swamp willow, alder, hollow tree, uprooted tree, mangrove-root tree, lily pads, duckweed, marsh grass, sedge, bog flowers, hanging moss, water reeds | 12 | A-000 |
| A-016 | `QUEUED` | Terrain accents: cliff face, cliff corner, cliff overhang, rocky slope, mud bank, riverbank, streambed, sinkhole, cave entrance, burrow entrance, scree pile, natural stone steps | 12 | World-gen terrain shape is settled |
| A-017 | `QUEUED` | Expanded Mire growth: ground vein, pulsing root, corruption bulb, spore pod, Blight flower, cyst, fungal tower, spore chimney, crystal spike, hanging sac, dead-resource husk, enemy nest | 12 | A-008 |
| A-018 | `QUEUED` | Small settlement shell: cottage frame/roof/chimney, shed, storehouse, market stall, awning, shutters, wooden door, hanging-sign bracket, firewood stack, lumber stack, hay bale, water trough | 14 | A-010 |
| A-019 | `QUEUED` | Landmark kit I: abandoned lumber camp, quarry, hunter camp, fisher camp, ruined cottage, ruined watchtower, stone circle, grave cluster; built from reusable sub-pieces rather than monolithic dioramas | 8 assemblies | A-013, A-018 |
| A-020 | `QUEUED` | Landmark kit II: giant hollow tree, crystal grove centerpiece, mushroom grove centerpiece, corrupted crater, Mire nest, flooded cellar entrance, broken dam, hilltop beacon | 8 assemblies | A-015, A-017 |
| A-043 | `QUEUED` | Wetland gatherables II (`ITEMS.md` §4.1): cattail bundle pickup + reed-bed node, sphagnum moss clump, glowcap mushroom, poison berry bush, fish-shoal shallow-water node, raw fish pickup | 7 | A-011 |
| A-044 | `QUEUED` | Refined material & component pickups (`ITEMS.md` §4.3, §4.8): tar, rope, cloth, cured leather, fired flask, mechanism, mithril ore, mithril ingot, wellglass shard, heavy mithril chunk (3.10's two-player haul object — size it to read as *heavy*) | 10 | A-002 |

## P2 — combat breadth and run variety

Do not start this phase until the one-enemy/one-weapon combat gate in `docs/ROADMAP.md` has passed.

| Batch | Status | Asset set | Planned models | After |
|---|---|---|---:|---|
| A-021 | `QUEUED` | Weapon forks I: iron axe, iron pickaxe, heavy cleaver, barbed skewer, spear, longbow, crossbow, bolt, buckler. **Iron sword removed — split out as A-021S and delivered early**, so this batch is nine designs | 9 world + 9 viewmodel | Combat gate |
| A-022 | `QUEUED` | Weapon forks II: mithril axe, mithril pickaxe, throwing axe, throwing knife, sling, wooden shield, Ward shield, Tinker hammer | 8 world + 8 viewmodel | A-021 |
| A-023 | `QUEUED` | Enemy roster I: sporeling, Mire hound, root walker, crystal crab; each with mesh, rig, required core animations, and death treatment | 4 characters | A-006 **and the 2.9 combat gate** (the phase rule above, put in the row so a row-reader cannot miss it) |
| A-024 | `QUEUED` | Enemy roster II: bog skeleton, corrupted scarecrow, spore thrower, mud elemental; each with mesh, rig, required core animations, and death treatment | 4 characters | A-023 |
| A-025 | `QUEUED` | Enemy roster III: thorn beast, floating Mire eye, shielded husk, burrower; each with mesh, rig, required core animations, and death treatment | 4 characters | A-024 and only if playtests justify 12 enemies |
| A-026 | `QUEUED` | Elites: armoured root brute, crystal-backed charger, fungal broodmother, Void stalker, Ward breaker, Hunt beast | 6 characters | Enemy framework and Cycle modifiers exist |
| A-027 | `QUEUED` | Wellspring guardian boss: dormant statue, awakened body, damaged-phase parts, exposed core, arena pylons, summoned growth, trophy, death remains | 8 | Boss framework exists |
| A-028 | `QUEUED` | Deep-Cycle boss: Mire titan, weak-point crystals, phase-growth set, eruption rocks, trophy, death remains | 6 | A-027 and Cycle 7 reached in playtest |
| A-029 | `QUEUED` | Physical powerups — Blood and Fungal: heart, fang, chalice, cap, spore sac, mycelium knot | 6 | Powerup framework exists |
| A-030 | `QUEUED` | Physical powerups — Kinetic and Fire: boot, spring, weight, coal, crown, fire bottle | 6 | A-029 |
| A-031 | `QUEUED` | Physical powerups — Cold and Void: ice shard, frozen eye, ice bell, Void eye, Void cube, Void compass | 6 | A-030 |
| A-032 | `QUEUED` | Ward variants: crystal, fungal, fire, cold, blood, kinetic, Void, cleansing brazier, Tinker bolt turret, Tinker stone thrower | 10 | Ward gameplay proves variants useful |
| A-045 | `QUEUED` | Creature-drop pickups (`ITEMS.md` §4.2): feather, small pelt, sinew, bone, frog legs, chitin plate, spore sac, fang, heartwood, crystal shard, burlap scrap, mud core, thorn quill, eye jelly, husk plate, digger claw, blight residue, corrupted heart. Each drop ships **no earlier than its creature** — split the batch by roster wave if A-023/A-024 land far apart | 18 | A-023 |
| A-046 | `QUEUED` | Throwables & held lights (`ITEMS.md` §4.6–4.7): tar bomb, spore bomb, fire flask, frost flask, bee jar, smoke pot, glow flare, decoy duck, the brick, held torch + storm lantern (both with viewmodel pairs — they live in the hand) | 11 | The 5.3 throw verb ships |
| A-047 | `QUEUED` | Gleam uniques & jackpot containers (`ITEMS.md` §4.9/§5, D-063): Gutterking, The Longest Skewer, Thumper, Widow's Whisper, The Bog Unit — world+viewmodel pairs, hero-prop polygon budgets like A-021S; gilded chest closed/open + sunken cache closed/open (A-005 anchor rules apply); rusted key, gilded key; World's Okayest Axe (stone axe geometry, gold material — a recolour that IS the joke, so it counts as an asset this once) | 10 designs / 16 exports | 3.5 ships chests |

## P3 — atmosphere, polish, and personality

| Batch | Status | Asset set | Planned models | After |
|---|---|---|---:|---|
| A-033 | `QUEUED` | Ambient wildlife: frog, crow, owl, bat, rabbit, rat, fish, firefly, dragonfly, beetle, snail, crab | 12 | Biomes are final |
| A-034 | `QUEUED` | Corrupted wildlife variants: giant frog, Mire crow, Blight boar, Mire leech, infected deer, insect swarm | 6 | A-033 |
| A-035 | `QUEUED` | Combat/VFX geometry: wood chips, stone fragments, ore sparks, blood splash, Mire splash, mud splash, spore projectile, crystal projectile, Mire glob, root eruption, Void portal, frozen shell | 12 | Relevant combat effects exist |
| A-036 | `QUEUED` | World-state VFX geometry: Ward ring, Ward impact ripple, Wellspring pulse, chest burst, powerup burst, Resonance burst, extraction wake, resource respawn growth, placement-valid and placement-invalid markers | 10 | Relevant systems exist |
| A-037 | `QUEUED` | First-person arm set: neutral arms/gloves plus empty, two-handed tool, bow, shield, eating, healing, reviving, building, heavy-carry, pointing, thumbs-up poses/animations | 1 rig + animation set | Final viewmodel proportions are settled |
| A-038 | `QUEUED` | Attunement visual accents for Warden, Forager, Tinker, and Reaver arms; lightweight colour/prop variations, not four separate character pipelines | 4 variants | A-037 |
| A-039 | `QUEUED` | Comedy props I: “Definitely Safe” sign, “Not Mire” barrel, tiny chair, huge spoon, bad outhouse, mug skeleton, barrel skeleton, wrong-way skeleton | 8 | Core loop content complete |
| A-040 | `QUEUED` | Comedy props II: suspicious mushroom, fish-mounted Ward, cooking-pot helmet, bent ceremonial sword, ground boot, “skill issue” grave, crowned dummy, emergency banana case | 8 | A-039 |
| A-041 | `QUEUED` | Hats: cooking pot, mushroom cap, bucket, tiny crown, fish, Mire crystal, pointy wizard hat, ship captain hat | 8 | Cosmetic system exists |
| A-042a | `DONE` | Inventory icons for every A-002 pickup and every A-004 tool/weapon, at Sequoyah's direct request and ahead of the `UI visual language is final` gate on A-042. 24 transparent 256×256 PNGs in `assets/icons/`, rendered from the shipped GLBs rather than drawn, with measured framing (upright vs 45° roll chosen per asset). Cycles with a pinned seed, because EEVEE would not reproduce anti-aliasing on thin silhouettes; two rebuilds pixel-identical on every channel. `iron_ore`, `log`, `stone`, and `stone_axe` wired to their icons in `content/items/`. Contact-sheet inspection and `tools/item_icons_check.gd` (24/24 import as 256×256, sources exist, every ItemDef carries an icon, A-004 exports still instantiate) passed | 24 | A-002, A-004 |
| A-042 | `QUEUED` | UI render pass, remainder: consumables, powerups, Attunements, Wards, Wellsprings, chests, and build pieces. Resources, tools, and weapons are done in A-042a; extend `tools/blender/render_item_icons.py` rather than starting a second icon pipeline | Existing models | UI visual language is final |

## Explicitly not asset-agent work

- `.tscn` and `.tres` creation or edits **used to be Sequoyah's alone; D-031 lifted that**. An asset
  agent may write the `content/items/*.tres` and `content/weapons/*.tres` its own batch needs, under
  a claim naming each exact file, with the Godot editor closed. It still does not touch scenes or
  resources belonging to other batches — A-021S wrote its two files while another session held the
  other nine, and the boundary was the exact paths.
- Collision, navigation obstacles, sockets, gameplay scripts, RPCs, damage, drops, harvesting, crafting,
  or placement authority.
- Balance stats, recipes, enemy stats, powerup definitions, or bulk-generated content resources.
- Full player bodies, third-person locomotion, facial animation, lore objects, cutscene props, or
  persistent-base cosmetics. These conflict with the current design decisions.

## Sequoyah review column

An agent may verify technical and visual basics, but Sequoyah is the final art integrator. Record
editor/playtest feedback here so it survives between agent sessions.

| Batch | Review state | Notes |
|---|---|---|
| A-000 | Awaiting gameplay-map review | Tree models were rebuilt in 2.1i without changing map/layout files; check their new scale, collision choices, foliage density, and fog-range silhouettes in the real Hollow scene |
| A-001 | Awaiting gameplay-state review | Tree states were rebuilt in 2.1i; check concave notch readability from the normal chop angle, collision choices, felled orientation, and swap timing in the harvesting prototype |
| A-002 | Awaiting pickup-flow review | Technically validated; check hover/spin presentation, pickup collision size, and readability in fog during the inventory prototype |
| A-003 | Awaiting station-flow review | Technically validated; check interaction reach, collision simplification, fire VFX replacement, and station spacing during crafting playtests |
| A-004 | Awaiting combat/viewmodel review | Technically validated; check grip transforms, first-person framing, hit reach, sockets, and collision during harvesting/combat prototypes |
| A-004R | Awaiting art review | Rebuilt geometry, unchanged names and near-unchanged dimensions, so existing scenes should still frame correctly — but confirm that, and check the new silhouettes at first-person distance and in fog. Polygon counts (114–348) sit below this file's 500–2,500 suggestion for first-person weapons; that is deliberate for the flat-shaded style, and the arrow (114) and cleaver (now 154, was 174 before F-198's bevel-free fix) are the two most worth a second look if you want more chamfer |
| A-021S | Awaiting combat-feel and loadout review | Technically validated and checked in the running game: it renders in hand, swings through all four phases, and its icon reads at real hotbar size. Three things need your eyes, not another check. (1) **It is not in the starting loadout** — `core/dev/dev_loadout.gd` belongs to another task, so nobody will hold the hero weapon until a line is added there. (2) **`WeaponDef` numbers are placeholders I picked, not tuned** — 0.19/0.11/0.26 s, 2.9 m reach, 95°, 6 damage, sitting between the cleaver and the axe. Task 2.9 owns them and its gate is still unpassed. (3) `grip_scale` 0.32 with offset (0.27, −0.30, −0.48) was tuned by eye at 1280×720; check it at your aspect ratio, and watch the blade at the commit — the swing drives it down past the camera and stills cannot show whether it clips the near plane. Also worth a look: the icon framer fits to a bounding square, so a long thin sword renders smaller in its slot than a compact tool does |
| A-042a | Awaiting UI review | Icons read clearly at 256px on the contact sheet; A-021S has now seen the tool/weapon ones at real hotbar size in the running game and they read. Check legibility at ~64px, whether thin tools (arrow, skewer, bow) need an outline or a backing plate, and whether fit-to-frame is right or stacks should keep relative size cues. `stone`/`flint`/`coal` are distinguishable but similar — that is the source art, not the render |
| A-009 | Awaiting landmark and extraction-flow review | Technically validated and checked in the engine, but four things want your eyes. (1) **The sail is `canvas` (#86AA9E), a desaturated sage** — the largest single-colour surface in the game. I judged it not a reserved-hue violation, because the Ward's identity is emissive bright cyan and this is matte sailcloth, and it separates cleanly from the salmon hull. If you disagree it is a one-token change to `cloth`. (2) **The repaired hull still carries sixteen fresh-timber patch boards.** That is deliberate — a repaired wreck is not a new boat — but it reads as a checkerboard at some angles; say if you want them toned to `wood_timber_light`. (3) **The cradle is permanent in all four states**, including the repaired one, because a round-bottomed hull cannot stand on a beach without it. If extraction is meant to show her afloat, the repaired state needs a cradle-free variant. (4) Deck at 1.78 m, bulwark 0.85 m above it, gangway 1.73 m wide — check those against first-person sightlines and against 3–6 players standing on the deck at once. Collision, interaction volumes and repair-progress authority are all still unbuilt; the donation crate, departure bell and boarding ramp are the three that will want them first |
| A-006 | Awaiting combat-feel review | Technically validated, but its gate was waived: the 0.4 s tell, the 0.3 s flinch and the walk speed come from `docs/DESIGN.md` §6, not from playtest. Check tell readability in fog and first-person, silhouette at aggro range, whether 1.10 m is the right size next to a player, collision choices, and where the fragments should spawn — then re-time the clips if 2.9 disagrees |
| A-007 | Awaiting Ward-flow review | Technically validated; check state readability in the live fog/lighting, foundation collision, repair-scaffold clearance, boundary-post spacing, and whether the 2.10 m healthy silhouette feels substantial without blocking first-person sightlines |
| A-008 | Awaiting Wellspring-flow review | Technically validated; check the 7.25 m monolith at real discovery distance, condition-state readability through localized fog, shared-base collision, cap/ritual interaction clearance, boundary-ring placement, and guardian-platform approach width before objective hookup |
| S-001 | Awaiting environment review | Supplied tree and boulder were adapted and technically validated; check their scale against existing forest pieces, collision simplification, foliage wind suitability, and placement density before adding them to authored maps |
| Authored playtest map | Awaiting layout review | Fixed Blender-authored layout is running in Godot; check route widths, zone density, sightlines, and whether the 60 m square is large enough for the first multiplayer loop |
