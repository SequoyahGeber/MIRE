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
  depleted, corrupted, and destroyed meshes without collision surprises.
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
  a rendered contact sheet of key poses. Godot scene hookup remains Sequoyah's work.

## Completed baseline

`A-000` is the original environment/map kit. Its exact per-file inventory and measurements live in
`assets/environment/catalog.json`.

| Batch | Status | Made | Count | Evidence |
|---|---|---|---:|---|
| A-000 | `DONE` | Pines, bare trees, birches, crooked trees; boulders, rock clusters, standing stones; stumps, fallen logs, roots; grass, ferns, reeds; mushrooms, Mire crystals, tendrils; ruined walls, columns, arches, markers; modular wood, stone, roof, stair, railing, fence, corner, and gate pieces | 116 | `assets/environment/README.md`; commit `04bdedc` includes the expanded kit and previews |

The baseline is presentation-ready but not editor-wired: it has no collision, harvest states, or
gameplay scenes. Do not count those missing behaviors as missing meshes unless a batch below names a
visual state for them.

## P0 — first complete playable loop

These assets support gathering, crafting, one satisfying fight, loot, a Ward, a Wellspring, and
extraction. Make these before broad biome decoration.

| Batch | Status | Asset set | Planned models | After |
|---|---|---|---:|---|
| A-001 | `DONE` | Harvestable tree states: intact pine, two damage stages, felled trunk, fresh stump, depleted stump; stone node states: intact, cracked, depleted; iron node states: intact, cracked, depleted. Made 12 in `assets/harvestables/`; deterministic rebuild, GLB/catalog validation, two-preview visual inspection, and fresh Godot import all passed | 12 | A-000 |
| A-002 | `DONE` | Basic world pickups: log, branch, stone, flint, iron ore, iron ingot, coal, fibre bundle, berry, mushroom, raw meat, coin, coin stack, salvage fragment. Made 14 in `assets/pickups/`; deterministic rebuild, GLB/catalog validation, two-preview visual inspection, and fresh Godot import all passed | 14 | A-001 |
| A-003 | `DONE` | First crafting stations: primitive workbench, upgraded workbench, campfire, cooking spit, stone furnace, anvil, repair bench, woodcutting block. Made 8 in `assets/crafting_stations/`; deterministic rebuild, GLB/catalog validation, two-preview visual inspection, and fresh Godot import all passed | 8 | A-002 |
| A-004 | `NEXT` | First tool/weapon set: wooden axe, stone axe, wooden pickaxe, stone pickaxe, iron pickaxe, cleaver, skewer, short bow, arrow, repair hammer; world pickup and first-person versions share one design | 20 exports | A-003 |
| A-005 | `QUEUED` | Loot set: small chest closed/open, Wellspring chest closed/open, reinforced chest closed/open, coin pouch, powerup orb, item pickup bag, dropped-player backpack | 10 | A-002 |
| A-006 | `QUEUED` | Prototype enemy set: Mire crawler mesh, simple rig, idle, locomotion, attack tell, attack, hit, and death animations; spawn nest and death fragments | 4 models + animations | Combat task 2.9 confirms feel target |
| A-007 | `QUEUED` | Basic Ward set: foundation, healthy Ward, damaged Ward, critical Ward, destroyed remains, repair scaffolding, boundary post, activation crystal | 8 | A-003 |
| A-008 | `QUEUED` | Wellspring set: distant monolith, base, crystal, basin, roots, uncapped state, capped state, re-corrupting state, corrupted state, ritual pedestal, boundary stones, guardian platform | 12 | A-007 |
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
| A-021 | `QUEUED` | Weapon forks I: iron axe, iron pickaxe, heavy cleaver, barbed skewer, spear, iron sword, longbow, crossbow, bolt, buckler | 10 world + 10 viewmodel | Combat gate |
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
| A-042 | `QUEUED` | UI render pass: standardized orthographic renders for resources, tools, weapons, consumables, powerups, Attunements, Wards, Wellsprings, chests, and build pieces | Existing models | UI visual language is final |

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
| A-000 | Awaiting gameplay-map review | Technically validated; check scale, collision choices, and density in the real map |
| A-001 | Awaiting gameplay-state review | Technically validated; check damage-state readability, collision choices, and swap timing in the harvesting prototype |
| A-002 | Awaiting pickup-flow review | Technically validated; check hover/spin presentation, pickup collision size, and readability in fog during the inventory prototype |
| A-003 | Awaiting station-flow review | Technically validated; check interaction reach, collision simplification, fire VFX replacement, and station spacing during crafting playtests |
