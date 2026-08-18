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
| `build_crafting_stations.py` | palette | primitives local |
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

Godot caches glTF imports, and a check run immediately after a rebuild can report
the *previous* import. A hollow visual count that jumps with no change in GLB bytes
or per-asset part counts is that cache, not your geometry — re-run to confirm.

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
  set turns up "modified" in `git status` after a rebuild that changed nothing. Decompress the `IDAT`
  chunks and compare those. A-021S re-ran the icon pipeline unchanged and found 24/24 pixel-identical
  behind 24 dirty files; restore them rather than committing the churn. EEVEE additionally jitters
  anti-aliasing on thin diagonal silhouettes (A-042a moved the icons to Cycles for this): A-021S's
  viewmodel preview differed by 9 bytes in 4,992,780, max delta 3/255, which is the noise floor, not
  a broken rebuild.
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
| A-003 | `DONE` | First crafting stations: primitive workbench, upgraded workbench, campfire, cooking spit, stone furnace, anvil, repair bench, woodcutting block. Made 8 in `assets/crafting_stations/`; deterministic rebuild, GLB/catalog validation, two-preview visual inspection, and fresh Godot import all passed | 8 | A-002 |
| A-004 | `DONE` | First tool/weapon set: wooden axe, stone axe, wooden pickaxe, stone pickaxe, iron pickaxe, cleaver, skewer, short bow, arrow, repair hammer. Made 20 paired world/viewmodel exports in `assets/tools_weapons/`; deterministic rebuild, paired consistency, GLB/catalog validation, three-preview visual inspection, and fresh Godot import all passed. **Rebuilt by A-004R** — see the row below | 20 exports | A-003 |
| A-004R | `DONE` | Quality rebuild of all ten A-004 designs at Sequoyah's direct request, out of queue order (A-009 stays `NEXT`, unstarted). Flat extrusions replaced by ground profiles with per-point bevel distances, butted body/edge shapes, swept oval hafts, flared bits and short polls. Same ten names, same 20 exports, so nothing downstream is renamed. 114–348 polygons per design (12,608 triangles across all 20), every export within ~6 cm of its A-004 dimensions. Byte-identical GLBs and catalog across two Blender 5.2 rebuilds, GLB 2.0 validation 20/20 with catalog exact and no orphans, six-azimuth orbit inspection of every design, three-preview visual inspection, and a fresh Godot 4.7.1 import plus `tools/item_icons_check.gd` all passed | 20 exports | A-004 |
| A-005 | `DONE` | Loot set: small/Wellspring/reinforced chests in closed and open states, coin pouch, powerup orb, item pickup bag, dropped-player backpack. Made 10 in `assets/loot/`; 2,542 polygons. Byte-identical deterministic rebuild, GLB 2.0 validation (10/10, catalog exact, no orphans), closed/open base-footprint drift 0.00 mm on all three pairs, two-preview visual inspection, and fresh Godot 4.7.1 import with zero errors all passed | 10 | A-002 |
| A-006 | `DONE` | **Gate waived by Sequoyah on 2026-08-16, not missed.** A-005's agent had marked this `BLOCKED` on combat task 2.9, which is still not started; Sequoyah directed it built anyway, so the crawler's feel targets come from `docs/DESIGN.md` §6 rather than from playtest, and 2.9 should re-check them. Prototype enemy set: six-legged Mire crawler with a 17-bone rig and idle, locomotion, attack tell, attack, hit and death clips; spawn nest; shell and leg death fragments. Made 4 in `assets/enemies/`; 1,172 polygons, crawler 794. Byte-identical deterministic rebuild (GLBs + catalog; previews pixel-identical), GLB 2.0 validation (4/4, catalog exact, no orphans), deform check 16/16 deform bones own geometry, clip-name and duration check against the authored timing, three-preview visual inspection including a rendered pose contact sheet, and a fresh Godot 4.7.1 import plus `tools/enemy_crawler_check.gd` (skeleton, skin, six clips, loop modes) all passed | 4 models + 6 clips | Combat task 2.9 confirms feel target |
| A-007 | `DONE` | Basic Ward set: foundation, healthy Ward, damaged Ward, critical Ward, destroyed remains, repair scaffolding, boundary post, activation crystal. Task 2.1i added the pronged socket, state-aware inlays, satellite shards, and damaged crystal tip. Made 8 in `assets/wards/`; 2,460 polygons. Byte-identical GLBs/catalog across two Blender 5.2 rebuilds and shared-foundation drift 0.00 mm passed | 8 | A-003 |
| A-008 | `DONE` | Wellspring set: distant monolith, base, crystal, basin, roots, uncapped state, capped state, re-corrupting state, corrupted state, ritual pedestal, boundary stones, guardian platform. Task 2.1i added complete/broken ritual crowns, condition-aware inlays, satellite spires, and a stronger monolith silhouette. Made 12 in `assets/wellsprings/`; 4,097 polygons. Byte-identical GLBs/catalog across two Blender 5.2 rebuilds and shared 4.6 m foundation drift 0.00 mm passed | 12 | A-007 |
| A-021S | `DONE` | **Iron sword, at Sequoyah's direct request, out of queue order**, split out of A-021. Made 2 exports + 1 icon: `iron_sword_world.glb`, `iron_sword_viewmodel.glb` in `assets/tools_weapons/`, `assets/icons/exports/icon_iron_sword.png`, plus `content/items/iron_sword.tres` and `content/weapons/iron_sword.tres`. 421 polygons / 1,000 triangles, 0.510 × 0.114 × 1.724 m — the set's hero, against 114–348 polygons for A-004R's ten. Diamond-section blade with a fuller, bright ground edges butted onto the core, upswept crossguard with brass quillon caps, brass écusson, leather grip with cord risers, faceted wheel pommel. Needed a new primitive: `lofted()` builds a solid through explicit cross-sections, because `ground_profile()` insets toward the profile centroid and on a blade a metre long that pull is almost entirely *downward* near the point, leaving a square wall where the edge should be. Verified: two clean rebuilds gave byte-identical GLBs (22/22) and catalog; GLB 2.0 validation 22/22 with catalog exact, no orphans/duplicates, ground origin, horizontally centred, embedded materials, no skins/animation; six-azimuth orbit inspection plus a blade-section close-up; three-preview visual inspection; fresh Godot 4.7.1 import; `tools/item_icons_check.gd` PASS; and the sword granted, held and swung through all four phases in the **running game** at 1280×720 with zero failures | 2 exports + 1 icon | A-004 |
| A-000V | `DONE` | **Vegetation expansion, at Sequoyah's direct request and out of queue order** — A-009 stays `NEXT` and unstarted, the same precedent as A-004R and A-021S. The environment kit had exactly one shape of ground cover (bladed grass, four sizes) and nothing between ankle-height grass and a full-grown tree, so a map read as one repeated texture however many grass variants were scattered. Made 84 in a new `flora` kit (`assets/flora/`, `tools/blender/build_flora_set.py`): 13 shrubs, 10 small trees, 16 leafy plants, 13 flowers, 18 grasses, 14 ground cover; 30,984 triangles, 12–1,012 per asset, at most four materials each. Sizes are **guaranteed by construction** — each asset is scaled to a target drawn from its group's band, with a separate footprint cap because scaling a rosette to a height band inflates its reach (`bracken_c` was a correct 0.95 m tall and 4.34 m across). Verified: build-time contract (size band, footprint cap, colour cap, ground contact, no floating mesh islands) **fails** rather than warns and passes 84/84; all-sides audit of every asset from eight azimuths plus top and bottom with **0 numeric defects**; and `tools/flora_check.gd` cross-checks the **engine's** measurements against the catalog and instantiates the real level, where `world/gen/undergrowth.gd` places **2,932 plants through 78 MultiMeshInstance3D nodes**. Filed F-092, F-093, F-094 (renumbered 2026-08-18 from F-058/F-059/F-060, which collided with unrelated
findings — see F-087) — all three found by this batch and all three fixed. Partially anticipates A-011 and A-015; both keep their rows, since neither's gameplay-bearing assets (harvestable berry bushes, state sets) are made here | 84 | A-000 |
| A-009 | `NEXT` | Extraction ship set: wrecked hull, two repair stages, repaired hull, mast, broken mast, furled sail, raised sail, rudder, anchor, boarding ramp, cargo hatch, donation crate, departure bell, debris cluster | 15 | A-004 |
| A-010 | `QUEUED` | Missing practical construction: working wood door, double gate, ladder, ramp, bridge straight, bridge broken, rope bridge, dock straight, dock corner, palisade straight/corner/gate, barricade, spike barricade | 14 | A-000 |

## P1 — world identity and survival readability

Do not start this phase until the M2 playtest (task 2.14) has produced its first feedback — "fun
before content" is the rule this queue runs under, and P1 is where a top-to-bottom reader would
otherwise sail past it (the audit found no gate here at all). Sequoyah can waive a specific batch
by saying so in its row, the way A-006 records its waiver.

| Batch | Status | Asset set | Planned models | After |
|---|---|---|---:|---|
| A-011 | `QUEUED` | Gatherable plants: berry bush full/harvested, poison berry bush, fibre plant, medicinal herb, wild onion, honeycomb, clay deposit, peat deposit, resin node | 10 | A-002 |
| A-012 | `QUEUED` | Food and consumables: cooked meat, fish, cooked fish, bread, soup, healing stew, skewer, honey jar, water flask, healing potion, Blight cleanse, stamina tonic, suspicious sludge drink | 13 | A-011 |
| A-013 | `QUEUED` | Camp storage and furniture: small/large barrel, crate intact/broken, sack, bucket, bedroll, stool, bench, table, shelf, storage rack, weapon rack, tool rack, drying rack, lantern | 16 | A-003 |
| A-014 | `QUEUED` | Roads and navigation: dirt path, muddy path, cobble path, corrupted path, boardwalk straight/corner/stairs/broken, stepping stones, trail marker, rune marker, warning sign, signpost | 13 | A-010 |
| A-015 | `QUEUED` | Wetland nature: swamp willow, alder, hollow tree, uprooted tree, mangrove-root tree, lily pads, duckweed, marsh grass, sedge, bog flowers, hanging moss, water reeds | 12 | A-000 |
| A-016 | `QUEUED` | Terrain accents: cliff face, cliff corner, cliff overhang, rocky slope, mud bank, riverbank, streambed, sinkhole, cave entrance, burrow entrance, scree pile, natural stone steps | 12 | World-gen terrain shape is settled |
| A-017 | `QUEUED` | Expanded Mire growth: ground vein, pulsing root, corruption bulb, spore pod, Blight flower, cyst, fungal tower, spore chimney, crystal spike, hanging sac, dead-resource husk, enemy nest | 12 | A-008 |
| A-018 | `QUEUED` | Small settlement shell: cottage frame/roof/chimney, shed, storehouse, market stall, awning, shutters, wooden door, hanging-sign bracket, firewood stack, lumber stack, hay bale, water trough | 14 | A-010 |
| A-019 | `QUEUED` | Landmark kit I: abandoned lumber camp, quarry, hunter camp, fisher camp, ruined cottage, ruined watchtower, stone circle, grave cluster; built from reusable sub-pieces rather than monolithic dioramas | 8 assemblies | A-013, A-018 |
| A-020 | `QUEUED` | Landmark kit II: giant hollow tree, crystal grove centerpiece, mushroom grove centerpiece, corrupted crater, Mire nest, flooded cellar entrance, broken dam, hilltop beacon | 8 assemblies | A-015, A-017 |

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
| A-004R | Awaiting art review | Rebuilt geometry, unchanged names and near-unchanged dimensions, so existing scenes should still frame correctly — but confirm that, and check the new silhouettes at first-person distance and in fog. Polygon counts (114–348) sit below this file's 500–2,500 suggestion for first-person weapons; that is deliberate for the flat-shaded style, and the arrow (114) and cleaver (174) are the two most worth a second look if you want more chamfer |
| A-021S | Awaiting combat-feel and loadout review | Technically validated and checked in the running game: it renders in hand, swings through all four phases, and its icon reads at real hotbar size. Three things need your eyes, not another check. (1) **It is not in the starting loadout** — `core/dev/dev_loadout.gd` belongs to another task, so nobody will hold the hero weapon until a line is added there. (2) **`WeaponDef` numbers are placeholders I picked, not tuned** — 0.19/0.11/0.26 s, 2.9 m reach, 95°, 6 damage, sitting between the cleaver and the axe. Task 2.9 owns them and its gate is still unpassed. (3) `grip_scale` 0.32 with offset (0.27, −0.30, −0.48) was tuned by eye at 1280×720; check it at your aspect ratio, and watch the blade at the commit — the swing drives it down past the camera and stills cannot show whether it clips the near plane. Also worth a look: the icon framer fits to a bounding square, so a long thin sword renders smaller in its slot than a compact tool does |
| A-042a | Awaiting UI review | Icons read clearly at 256px on the contact sheet; A-021S has now seen the tool/weapon ones at real hotbar size in the running game and they read. Check legibility at ~64px, whether thin tools (arrow, skewer, bow) need an outline or a backing plate, and whether fit-to-frame is right or stacks should keep relative size cues. `stone`/`flint`/`coal` are distinguishable but similar — that is the source art, not the render |
| A-006 | Awaiting combat-feel review | Technically validated, but its gate was waived: the 0.4 s tell, the 0.3 s flinch and the walk speed come from `docs/DESIGN.md` §6, not from playtest. Check tell readability in fog and first-person, silhouette at aggro range, whether 1.10 m is the right size next to a player, collision choices, and where the fragments should spawn — then re-time the clips if 2.9 disagrees |
| A-007 | Awaiting Ward-flow review | Technically validated; check state readability in the live fog/lighting, foundation collision, repair-scaffold clearance, boundary-post spacing, and whether the 2.10 m healthy silhouette feels substantial without blocking first-person sightlines |
| A-008 | Awaiting Wellspring-flow review | Technically validated; check the 7.25 m monolith at real discovery distance, condition-state readability through localized fog, shared-base collision, cap/ritual interaction clearance, boundary-ring placement, and guardian-platform approach width before objective hookup |
| S-001 | Awaiting environment review | Supplied tree and boulder were adapted and technically validated; check their scale against existing forest pieces, collision simplification, foliage wind suitability, and placement density before adding them to authored maps |
| Authored playtest map | Awaiting layout review | Fixed Blender-authored layout is running in Godot; check route widths, zone density, sightlines, and whether the 60 m square is large enough for the first multiplayer loop |
