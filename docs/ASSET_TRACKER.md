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
   generator, catalog, preview, and export path the batch will touch. Never edit `.tscn`, `.tres`,
   `.import`, or `export_presets.cfg`.
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
- Static presentation meshes contain no authored Godot collision. Sequoyah adds simple collision and
  scene wiring in the editor when needed.
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

## Verification contract

Every completed batch records evidence for all applicable checks:

- Generator syntax check and deterministic clean rebuild.
- GLB 2.0 validation: every expected export exists, has meshes, positive dimensions, applied scale,
  embedded materials, and a sane polygon count.
- Catalog matches the exports exactly: no missing, duplicate, or orphan records.
- Category preview plus a scale-reference preview rendered at a useful resolution.
- Visual inspection for silhouette, ground contact, clipping, accidental smooth shading, material
  consistency, and first-person readability where applicable.
- Fresh Godot 4.7.1 import with zero missing imported scenes and no Blender-path dependency.
- For rigs/animation batches: deform check, animation-name check, looping check where applicable, and
  a rendered contact sheet of key poses. Godot scene hookup remains Sequoyah's work. A-006 ran these
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

The compact playtest layout is now a separate authored asset rather than runtime scatter:
`assets/source/playtest_map.blend` exports `assets/maps/playtest_map.glb` and its preview. It directly
uses A-000 environment pieces, A-001 harvestables, and A-003 crafting stations across six named
zones. `tools/blender/build_playtest_map.py` is its deterministic rebuild path; gameplay collision
and authority remain outside the Blender source.

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
| A-021S | `NEXT` | **Iron sword, at Sequoyah's direct request, out of queue order** — split out of A-021 so one weapon lands now rather than behind nine others. One design: `iron_sword`, exported as `iron_sword_world.glb` + `iron_sword_viewmodel.glb`, plus `assets/icons/exports/icon_iron_sword.png`. Follow A-004's contract exactly: same generator (`tools/blender/build_tool_weapon_set.py`), both presentations rebuilt from one geometry function and embedded materials, horizontally centred, ground-level origin, no collision/sockets/animation/authority. **This is the hero weapon of the vertical slice — spend the polygon budget.** A-004R's rebuild is the quality bar: ground profiles with per-point bevels, butted body/edge shapes, a swept oval haft, a flared bit. 114–348 polygons per design there; a sword may exceed it if the silhouette earns it. Read `assets/tools_weapons/README.md` before starting, and A-004R's `DONE` row for what verification is expected. **The viewmodel export now has a consumer**: `ItemDef.view_model` and `entities/player/viewmodel.gd` render the held item in first person, so the viewmodel presentation is no longer decorative — check it in the running game, not only in the preview render. Finish by adding `content/items/iron_sword.tres` and `content/weapons/iron_sword.tres` (write those two files only — do NOT re-run `tools/setup_tool_content.gd`, another agent owns the existing nine) | 2 exports + 1 icon | A-004 |
| A-009 | `QUEUED` | Extraction ship set: wrecked hull, two repair stages, repaired hull, mast, broken mast, furled sail, raised sail, rudder, anchor, boarding ramp, cargo hatch, donation crate, departure bell, debris cluster | 15 | A-004 |
| A-010 | `QUEUED` | Missing practical construction: working wood door, double gate, ladder, ramp, bridge straight, bridge broken, rope bridge, dock straight, dock corner, palisade straight/corner/gate, barricade, spike barricade | 14 | A-000 |

## P1 — world identity and survival readability

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
| A-023 | `QUEUED` | Enemy roster I: sporeling, Mire hound, root walker, crystal crab; each with mesh, rig, required core animations, and death treatment | 4 characters | A-006 |
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

- `.tscn` and `.tres` creation or edits: Sequoyah does these in the Godot editor.
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
| A-042a | Awaiting UI review | Icons read clearly at 256px on the contact sheet, but they have not been seen at real slot size in the running inventory. Check legibility at ~64px, whether thin tools (arrow, skewer, bow) need an outline or a backing plate, and whether fit-to-frame is right or stacks should keep relative size cues. `stone`/`flint`/`coal` are distinguishable but similar — that is the source art, not the render |
| A-006 | Awaiting combat-feel review | Technically validated, but its gate was waived: the 0.4 s tell, the 0.3 s flinch and the walk speed come from `docs/DESIGN.md` §6, not from playtest. Check tell readability in fog and first-person, silhouette at aggro range, whether 1.10 m is the right size next to a player, collision choices, and where the fragments should spawn — then re-time the clips if 2.9 disagrees |
| A-007 | Awaiting Ward-flow review | Technically validated; check state readability in the live fog/lighting, foundation collision, repair-scaffold clearance, boundary-post spacing, and whether the 2.10 m healthy silhouette feels substantial without blocking first-person sightlines |
| A-008 | Awaiting Wellspring-flow review | Technically validated; check the 7.25 m monolith at real discovery distance, condition-state readability through localized fog, shared-base collision, cap/ritual interaction clearance, boundary-ring placement, and guardian-platform approach width before objective hookup |
| S-001 | Awaiting environment review | Supplied tree and boulder were adapted and technically validated; check their scale against existing forest pieces, collision simplification, foliage wind suitability, and placement density before adding them to authored maps |
| Authored playtest map | Awaiting layout review | Fixed Blender-authored layout is running in Godot; check route widths, zone density, sightlines, and whether the 60 m square is large enough for the first multiplayer loop |
