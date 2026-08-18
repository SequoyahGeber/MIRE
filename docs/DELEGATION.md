# Delegation — the state agents start from

**A written prompt is no longer required to start a task.** Say *"start 1.6"* to a fresh chat; the
agent runs `agent brief 1.6`, which prints the task, the open findings, what recent tasks left it and
who holds which files, and points it at this file's *Current state* section below. That section is the
contract: **whatever the next task builds on gets written there by the task that produced it.**

**So the important half of this file is *Current state*, not the prompts.** Keeping it accurate is
part of closing out a task (`AGENTS.md` step 3) — a stale one is exactly what forced hand-written
prompts in the first place, because the next agent could not trust anything here.

The prompt blocks that remain are kept as worked examples, and because a hand-written brief is still
worth writing for a task that is unusually easy to get wrong — a spike with a specific measurement
protocol, or a task where the failure mode is subtle. If you do write one, set the model and effort
named under its heading. Nothing here is for Sequoyah to run.

**Each parallel chat gets its own identity automatically, and you no longer supply it (F-007).** The
name is derived from the chat's own session id, which every command carries in its environment — git
included, so the pre-commit hook resolves the same agent your `agent` commands do. Stable for a whole
session, unique per chat, nothing to pass:

```bash
.agent/bin/agent claim 1.2 autoload/net_transport.gd
```

**The archived prompt blocks below still carry `MIRE_AGENT=<name>` prefixes.** They shipped under the
old scheme and are kept verbatim as worked examples. The prefix still works — it overrides everything —
but do not copy that pattern into a new prompt, and never reintroduce `export`: each shell call is a
fresh process, which is what made the old scheme fail silently.

**Prefer `agent ship` for commits**, and it is now safe to prefer: **F-014 is fixed** (`ce8128a`), so
`ship` commits by pathspec and can no longer be blocked by, or unstage, another agent's staged work,
and **F-010 is fixed** (`60e85cc`), so it carries `.uid` sidecars along with the scripts that own them
instead of leaving them untracked.

**Roles are not fixed (D-020).** Any agent can take any task; which one gets it depends on which plan
has quota. Nothing below is reserved for a particular chat.

**Standing trap — most of `.godot/` is gitignored, and real setup can hide in it.** One task still
depends on local editor state:

| Task | What lives in `.godot/` |
|---|---|
| 1.3 | Run-instance config (Debug → Customize Run Instances) — the two-window launch args |

F-009 is fixed: `.godot/extension_list.cfg` is the sole tracked exception and registers GodotSteam in
a fresh clone or headless VM. Any prompt whose work touches other editor state should still say so
explicitly and hand back either a click-path or a committed script.

---

### Task 1.11 — version handshake is wired through `NetSession`

`core/net/net_version.gd` remains the pure version source: `PROTOCOL_VERSION: int` and
`mismatch_reason(local_version, remote_version) -> String`. Task 1.7 integrated it at the lifecycle
policy layer instead of the transport mechanism. On connection, a client calls
`NetSession.net_client_hello(PROTOCOL_VERSION)` on the host. The host compares versions, sends the
same human-readable refusal used by capacity/policy admission, waits 0.25 s for the reliable notice
to flush, then kicks the peer.

Version is necessarily checked just after ENet admits the connection, so the mismatched peer may
briefly spawn before the refusal arrives; it is then despawned and leaves no player behind. D-027
records that tradeoff and what would justify moving to `SceneMultiplayer.auth_callback`. The real
multi-process lifecycle harness verifies the complete path. `tools/handshake_check.gd` remains the
smaller pure-mechanics probe.

F-016 still applies to `NetVersion`: headless `--script` entry points should preload
`res://core/net/net_version.gd` rather than relying on the gitignored global-class cache.

Bump `NetVersion.PROTOCOL_VERSION` in the same commit as any change that would desync two builds
silently — see the constant's own doc comment for the exact list (replicated property, RPC signature,
`SceneReplicationConfig`).

---

## Current state — check `.agent/BOARD.md` before pasting anything

### 2026-08-18 — 7.1/7.2 v1: game audio is synthesized from committed recipes — toolkit, 2 ambient loops, 19 SFX (tine18)

**`tools/audio/mire_audio.py` is the instrument rack** — additive pads, Karplus-Strong plucks, FM
bells/groans, filtered-noise beds, convolution reverb, circular loop rendering, all seeded and
bit-reproducible. `render_music.py`/`render_sfx.py` hold the scores and recipes (edit the data
tables, not the engine), `audio_check.py` is the objective gate (clipping/DC/RMS/loop seams),
`tools/audio_import_check.gd` proves in-engine loading. **Read `docs/AUDIO.md` before adding any
sound** — palette rules (rewards ring in D, no percussion in ambience, mono SFX) live there.

- Assets: `assets/audio/music/ambient_{day,night}.ogg` — 3:44 seamless loops; `loop=true` lives in
  the two **force-committed `.ogg.import` sidecars** (gitignore exception, `icon.svg.import`
  precedent). `assets/audio/sfx/*.wav` — 19 mono effects, peak-normalised with mixer headroom.
- **Wiring is NOT done.** Next: a client-local MusicDirector autoload crossfading on DayNight's
  `day_started`/`night_started` (names proven in `tools/day_night_check.gd`), and sound fields on
  `weapon_def.gd`/`harvestable_def.gd` — those files sit under F-113/F-114 claims, wire after they
  clear. Audio is client-local presentation; no audio RPCs, ever (ARCHITECTURE §2.2).
- Re-render deps: system python3 + numpy, `pip install --user soundfile` (brew ffmpeg lacks
  libvorbis; ffmpeg only makes the MP3 listening copies Sequoyah auditions in chat).

### 2026-08-18 — F-115: ground mist is a fog SHADER built from code, and the look is judged from rendered PNGs (vane19)

**`world/environment/ground_fog.gd` + `.gdshader`.** `PlaytestAtmosphere._resolve_ground_fog()`
creates one for any level with an `Atmosphere` node — same reasoning as the star field, and the same
bug it fixes: the controller used to drive three `FogVolume` siblings by name and the shipped map
had none of them. **Do not add a GroundFog to a level scene**; if one is authored as a child named
`GroundFog` it is reused, otherwise it is built.

- Density is a function of `WORLD_POSITION`, so the volume is only an evaluation window. It follows
  the camera **in XZ only** — following in Y makes a plateau as foggy as a valley.
- `base_height` is measured off the terrain AABB (group `authored_world_terrain`), a quarter of the
  way up, **on the first frame that group is non-empty** — not in `_ready()`, where `Atmosphere` runs
  before `World` and the group is still empty. `NAN` means "not measured yet", never "y = 0".
- `apply_look(scale, albedo, emission, emission_energy)` is the only thing the atmosphere calls.
  Colour is passed in rather than derived in the fog so the mist, the sky and the shafts cannot
  disagree about the hour.
- `Environment.volumetric_fog_density` is now 0.00006 and must stay near there: it exists only so a
  sunbeam has a medium to be visible in. Raising it back is how the flat haze returns.
- **Anything on the `low` graphics preset is free** — it disables volumetric fog on the Environment
  and every FogVolume goes inert.

**Judging a look change: `tools/atmosphere_look_shot.gd`, run `--windowed`.** It renders the shipped
map at eight times of day plus sunward and forest-interior framings to `user://atmosphere_look/*.png`.
Two traps it already paid for: **pose the clock through `DayNight`** (`time_of_day` in 0..1), because
DayNight re-applies the hour every physics tick and overwrites `Atmosphere.set_time_of_day()` before
the frame is drawn; and the sun's elevation is `sin((hour - 6) / 24 * TAU) * 90`, so **hour 18 is
exactly sunset and 18.6 is already full night** — golden hour is only ~1.2 game-hours wide. It
renders through its own `SubViewport` because `agent godot --windowed` forces a 64×64 window (F-077).

### 2026-08-18 — `agent godot` imports before every run, so a check can no longer read a stale build (F-093, lm)

**Nothing to build against — this is a behaviour change in the shared harness itself.** Every
`agent godot <...>` call (any args other than a bare `--import`) now runs a real
`--headless --import` pass first, inside the same lock, before the caller's own run. The two-step
manual dance the F-093 finding used to recommend (`agent godot --import`, then run the check) is no
longer necessary — one `agent godot --script tools/x_check.gd` is enough, and always sees the current
build. `docs/ASSET_TRACKER.md`'s old "re-run to confirm" advice is gone for the same reason; it never
actually worked (F-093 measured three identical stale reruns), the import pass is what fixes it.

- **Cost:** roughly one extra Godot boot per `agent godot` call. Cheap when nothing changed (Godot
  only reimports what's dirty); the point of the fix is that the cost is now unconditional so no
  agent has to remember when it's needed.
- **`--import` alone still works** as its own command and is not doubled — `cmd_godot` skips the
  pre-pass when the caller's own args already ask for one.
- Test double for this lives in `tools/harness_check.py` (`fake-godot`, argv-echo pattern) — two
  cases assert the double-invocation shape. Extend those, don't write a new test double, if this
  needs more coverage later.

### 2026-08-18 — the in-game Steam lobby menu exists (6.10's lobby-UI slice, pulled forward per D-030) (moss11)

**Press M in game → the multiplayer panel.** `ui/lobby/lobby_menu.gd`, autoload `LobbyMenu`
(CanvasLayer, layer 55). Host a friends-only Steam lobby, **COPY** the lobby ID to the clipboard,
paste a friend's ID and **JOIN**, open the Steam **invite overlay**, see the member list, leave.
This is what makes 1.12's evidence run cheap: the ID travels over any chat instead of between
terminals. Sequoyah asked for it now, explicitly ahead of its roadmap slot.

- **UI over live seams only** — every button is `SteamLobby.host_session()` / `join_by_id()` /
  `open_invite_overlay()` / `leave()`, plus `NetTransport.leave()` for a non-Steam session. Network
  authority: none (client-local, §2.2's last row). Member rows render `SteamLobby.members()` — lobby
  membership, never authoritative.
- **Toggle is the raw keycode `KEY_M`** (DebugConsole's backtick pattern), so the input action map
  was not touched; A/B/D/E/S/W, Space, Tab, Shift were taken. Esc closes it, consumed in `_input`
  before `player_controller.gd`'s `_unhandled_input` mouse-release toggle can see the press. Typing
  into a focused LineEdit never toggles it.
- **D-032 honoured:** joins `blocks_gameplay_input` while open, refuses to open while any other
  node holds that group, frees the cursor and restores capture state on close.
- **Status line carries every outcome verbatim** — `lobby_failed`, `NetSession.session_ended`
  detail, connect retries/rejoins, and a mapped "Steam is not available" for `ERR_UNAVAILABLE`.
  `invite_accepted` while already in a session opens the panel with the friend's lobby ID prefilled
  rather than yanking the player out (SteamLobby's own rule).
- **Check:** `agent godot --script tools/lobby_menu_check.gd` — 19 assertions, green at ship.
  Headless has no Steam client, so it proves the panel, the group interlock and every refusal path;
  the happy path is 1.12's live run. Driveable from a check via `set_open()`, `request_host()`,
  `request_join()`, `set_join_field_text()`, `status_text()`, `member_row_count()`.
- **Still open in 6.10:** main menu shell, settings, seed entry (feeds 4.6). The lobby slice is done.

### 2026-08-18 — F-113/F-114: harvesting is keyed to the ASSET, and health is authored in tool swings (vane19)

**`systems/harvesting/harvest_library.gd` is the new source of truth for "is this worth hitting".**
It is `AssetVfxLibrary`'s twin — asset id in, answer out, no reference to any scene, map or layout —
and both `world/gen/authored_world.gd` and `autoload/harvest_world.gd` read it, so the world builder
and the wirer can never disagree. **A generated world gets a choppable pine by stamping
`tree_pine_c` on the node it emits; that is the entire contract.** Three static calls:
`definition_path_for(asset)`, `is_harvestable(asset)`, `representation_for(asset)`.

- **`Represent.NODE` vs `Represent.BATCH`** is how density stays affordable. NODE props get their
  own holder and mesh (trees, ore, boulders — 387 on Hollowmere). BATCH props stay inside the
  chunk's `MultiMesh` and get a logic-only holder (794 bushes and saplings, zero extra draw calls);
  the builder records `batch_meshes` / `batch_index` / `batch_transforms` metas on that holder and
  `HarvestWorld` turns them into the hook that hides one instance by zeroing its transform.
  **Never read a placement back with `MultiMesh.get_instance_transform()`** — it is a
  RenderingServer round trip that answers identity under the dummy renderer every headless check
  runs on, which is why the builder records the transform instead.
- **`HarvestableDef.active_state_scenes` may be empty**, meaning "this asset is its own intact
  visual". `Harvestable` then shows/hides whatever already draws the prop through
  `set_visual_hook(Callable)` — one seam that covers both a `Node3D` and a MultiMesh slot. This is
  what lets one `wild_tree.tres` cover 62 species without a damage-state export each. A definition
  in this mode may also have **no collider**, and that is legal.
- **`CollisionBody` is still mandatory** for a definition that ships state scenes: the states swap
  under it and something has to own the shape.

**The tool axis is separate from combat damage, on purpose.** `WeaponDef.tool_class`
(`Any`/`Chop`/`Mine`, stored as the int from `HarvestLibrary.Tool` — never reorder it) and
`WeaponDef.harvest_power` (**wooden 1, stone 2, iron 3**). `HarvestableDef.required_tool` +
`wrong_tool_scale` (0.34, floored, so an under-powered wrong tool reaches exactly 0 and can never
chip a prop down). **Harvestable health is authored in tool power**, so `max_health = 6` reads
"three swings of a stone axe" and stays that sentence when enemy damage is retuned.

- `Harvestable.host_apply_tool_damage(tool_class, harvest_power, peer_id)` is the host seam combat
  now prefers, chosen by **feature test** so `&"damageable"` stays one contract and enemies are
  untouched. `harvest_damage_for()` previews the number for the broadcast.
- A wrong-tool connect returns **true with 0 damage**, not a miss.
- **`autoload/harvest_world.gd` no longer listens for `attack`.** Adding a second damage source on
  one click is how F-113 happened; `try_harvest_from_camera()` remains as an API only.

**New content:** `wild_tree`, `boulder`, `rock_cluster`, `fallen_log`, `stump`, `bush`, `sapling` in
`content/harvestables/`, plus `content/items/stick.tres`. **3.2 (ivy8) — read F-116 before authoring
`content/items/branch.tres`:** `stick` already ships the `pickup_branch` art and is what 794 bushes
yield, so the two ids must converge rather than both exist.

**New checks:** `tools/harvest_tool_ladder_check.gd` (17 weapon×harvestable swing counts against the
shipped `.tres`) and `tools/harvest_batch_check.gd` (**run `--windowed`** — MultiMesh readback needs
a real renderer, and `physics_interpolation` means a freshly written transform reads back part-way).

### 2026-08-18 — `docs/ITEMS.md` is the item/loot/chest catalog; 3.2, 3.5 and 3.8 author against it (ivy8)

The full item economy is planned: ~136 items across gathered raws, creature drops, refined
components, food, tonics, throwables, tools/weapons, keys and the **Gleam jackpot pool**, plus the
chest-tier table set (reed cache → bog chest → strongbox → wellspring → **gilded** → sunken → boss).
It is a menu in the POWERUPS.md sense — hand-authored `.tres` later, never bulk-generated (D-006).
What matters for the next tasks:

- **3.5 gained four named mechanics** (spec block updated): `LootEntry.kind ITEM|POWERUP`,
  `LootEntry.rarity` (the consumer `loot_luck` has been waiting for), chest `cost_coins` +
  `locked_by` key check, and a gilded-tier placement budget. **D-063**: jackpots are balanced by
  rarity only — never neutered.
- **Gleam powerups are stats-only with NO tags** — `PowerupDef`'s validator already allows exactly
  that, so the jackpot tier never grows `KNOWN_FAMILIES` or fakes a Resonance.
- The 2-step refinement cap, no-armor and no-durability calls are ITEMS.md §2 rules with
  reopen conditions in §10 — read before adding an item family.
- Asset queue grew A-043–A-047 (gatherables II, component pickups, creature drops, throwables +
  held lights, Gleam uniques + gilded/sunken chests), all gated; A-010 stays `NEXT`, A-011/A-012
  unchanged as the first content wave's art.

**Update, same day (`9caef22`):** the first authorable slice is SHIPPED at Sequoyah's direct
request (a recorded D-006 override — see the 3.2 journal note): items `branch` / `flint` / `coal` /
`fibre_bundle` / `berry` / `mushroom` / `raw_meat` (the last three CONSUMABLE with hunger values
3.8 will consume), plus 11 recipes — every existing tool/weapon is now craftable, charcoal (3 log →
2 coal) is the furnace's second timed recipe, and recipe costs are untuned guesses scaled off
stone_axe. Boot: **23 items, 13 recipes**. Iron gear sits at the `workbench` until an anvil
StationDef exists (one field per recipe to move). `tools/crafting_check.gd`'s exact-census asserts
became floor+membership+determinism, so authoring more recipes can't red it. F-116's convergence
holds: bushes/saplings yield `branch`. Next authorable wave needs A-011/A-012 art (icons are
mandatory on every ItemDef) or new `render_item_icons.py` SOURCES; Gleam powerups (ITEMS.md §4.9)
are art-free under 3.4 whenever Sequoyah green-lights authoring them.

### 2026-08-18 — F-105: `BuildGhost.update_aim()` takes an optional `delta`, and skips `evaluate()` on an unchanged aim

`systems/building/build_ghost.gd`'s `update_aim(from, direction, builder_position, delta: float =
0.0)` gained a 4th, optional parameter — anything already calling it with 3 args still compiles and
still works, it just doesn't get the timer's proactive re-check (see below). `PlacementValidator.
evaluate()` (5 raycasts + a shape cast) now only runs when the snapped placement or the builder
position actually changed since the last call, or `REEVALUATE_INTERVAL_S` (0.2s) has elapsed —
whichever a caller cares about should pass a real `delta` (`player_controller.gd`'s
`_tick_build_ghost()` does). **`set_piece()` invalidates the cache** — a same-spot swap to a
different piece must re-evaluate, since the def (size/mass/rules) is part of what `evaluate()`
answers, not just the transform. `evaluate_count()` is a new getter (backed by `_evaluate_count`)
that exists purely so a check can assert the skip is actually happening; not gameplay-facing.

`entities/player/player_controller.gd`'s `_apply_horizontal_movement()`, `_try_jump()` and
`_tick_build_ghost()` all gained parameters too — `_physics_process()` now resolves
`gameplay_input_allowed()`/`_is_downed()`/`_is_dead()` exactly once per tick and threads them through
as `(input_allowed: bool, downed: bool, dead: bool)`, in that order, rather than each function
re-deriving its own copy. **Any direct `.call()` into these from a check bypasses `_physics_process()`
and must now pass all three** — `tools/player_vitals_check.gd` is the existing example
(`player.call(&"_try_jump", true, false, false)` for a standing, alive, unblocked player).
`_health_node()` now caches the resolved `/root/PlayerHealth` node in a `_health` member var instead
of re-walking `/root` every call.

Full reasoning, the exact per-item fix, and everything verified: `docs/SPECS.md`'s F-105 block.

### 2026-08-18 — a map now gets a group-name-mismatch check for free (F-076/D-062): `tools/world_contract_check.gd`

Hollowmere shipped as the main scene while `EnemyWorld`/`HarvestWorld` still recognized only Playtest
Hollow's group names — zero enemies, 77 dead trees, and nothing errored, because a group matching no
node reads identically to a level that genuinely has none of that thing. `tools/hollowmere_check.gd`
caught it for that one map by hand; this is the version a THIRD map needs no new code to get.

**Run it with `agent godot --script tools/world_contract_check.gd`.** It reads `main_scene` from
`project.godot`, so — like `environment_vfx_hollowmere_check.gd` (F-097) — it always follows whatever
map is actually shipped rather than one hardcoded scene path.

**The API it's built on, for anything that needs the same "does the map actually have X" shape:**

- **`EnemyWorld.expected_nest_count(layout: Dictionary) -> int`** and
  **`HarvestWorld.expected_harvestable_count(layout: Dictionary) -> int`** are pure functions that
  read a map's raw layout JSON directly (`markers[].kind`, `props[].harvestable`) — **never** through
  a Godot group. That's what makes the comparison catch anything: the group-name blind spot that can
  break `ambient_spawn_points()`/`wired_harvestables()` cannot also hide the number they're being
  checked against, because that number never went through a group.
- **`EnemyWorld.CANONICAL_NEST_KIND = &"enemy_nest"`** (D-062) is the one marker `kind` a NEW map's
  generator should publish for its nests. `NEST_SOURCES` still separately recognizes Playtest
  Hollow's legacy `enemy_spawn` for the map that still exists, but `expected_nest_count()`
  deliberately measures against the canonical spelling only — a check reading through the same
  synonym list it's meant to audit proves nothing.
- **Where the layout comes from:** a scene's `World` node exporting `layout_path` — the same
  convention `Undergrowth` already reads generically (`docs/DELEGATION.md`'s Hollowmere section
  below). A map not built that way has nothing to compare against; the layout-shaped checks are
  skipped, not failed, so this never blocks a genuinely different kind of world generator.

**Not covered — filed as F-112:** `world/gen/undergrowth.gd`'s "don't grow on top of a prop" rule,
the third system the original F-076 named. It has no equivalent ground-truth field sitting in a
layout the way markers/`harvestable` props do — "which collider is solid" is a fact about which node
the generator tagged, not something the JSON states directly — so generalizing it needs `Undergrowth`
to expose something like `sample_ground_gaps()` first. `tools/hollowmere_check.gd`'s
`_check_undergrowth_stays_off_props` is still the only check for it, and it is Hollowmere-specific.

### 2026-08-18 — a named collision-layer convention exists now (F-075/D-061): layer 2 is terrain, and ONLY terrain

Ground and everything else used to share collision layer 1, which is why `PlacementValidator`'s
overlap query could not tell "the ground I'm resting on" from "an obstruction" and had to work around
it with a self-tuning clearance lift. That workaround is gone. The convention, and what it means for
the next system that touches colliders:

- **`PlacementValidator.TERRAIN_LAYER: int = 2`** (`systems/building/placement_validator.gd`) is the
  one source of truth — preload the file for the constant rather than hardcoding `2` anywhere.
  `project.godot`'s `[layer_names]` names both layers for the editor:
  `3d_physics/layer_1="solid"`, `3d_physics/layer_2="terrain"`.
- **Layer 1 (`solid`) is still the default for everything that is not ground** — props, harvestables,
  placed buildable pieces, players, enemies. Nothing about them changed; a `StaticBody3D`/
  `CharacterBody3D` you create today with no explicit `collision_layer` is still on layer 1, same as
  before this task.
- **Layer 2 (`terrain`) belongs to world generators, and only to the one `StaticBody3D` per map that
  carries the ground.** `world/gen/authored_world.gd`'s `TerrainCollision` body is the only thing on
  it today. A future world generator (4.x chunk streaming is the named pairing in the original
  finding) must do the same: `body.collision_layer = PlacementValidator.TERRAIN_LAYER` on its ground
  body, nothing else moved.
- **Anything that queries physics with a narrowed mask has to decide, explicitly, whether it wants
  terrain.** `PlacementValidator._probe_support()` ORs `TERRAIN_LAYER` into whatever mask the caller
  passes, so support/ground-finding works regardless of the caller's own mask; `_overlaps()`
  deliberately does not, so a piece resting on the ground never reads the ground as the obstruction.
  `build_ghost.gd`'s own aim ray needed the same OR by hand — it is a second, independent query
  outside `PlacementValidator`, finding *where* the player is pointing before `evaluate()` ever runs.
- **Anything that MOVES on terrain needs `TERRAIN_LAYER` in its `collision_mask`, or it falls through
  the ground the instant that ground leaves layer 1.** `CharacterBody3D`'s engine default
  (`collision_mask = 1`) is exactly wrong for this. Both existing movers were fixed:
  `entities/player/player.tscn`'s `Player` node and `systems/enemies/enemy.gd`'s `_build_body()`
  both now set `collision_mask = 3` (`1 | TERRAIN_LAYER`). **Any new `CharacterBody3D` or
  `RigidBody3D` that stands on the ground needs the same** — either `3`, or leave the mask at the
  engine's true default (all layers) and never narrow it to a bare `1`.
- **Not migrated, on purpose:** `world/gen/playtest_hollow.gd` (deprecated, superseded by Hollowmere)
  keeps its terrain on layer 1. Confirmed via grep to have no `PlacementValidator` caller anywhere,
  so nothing regresses; migrate it only if that map is ever un-deprecated rather than retired.
- **Nav baking is unaffected** — `EnemyWorld.bake_navigation()` never set
  `NavigationMesh.geometry_collision_mask`, whose engine default is all layers, so it already parsed
  terrain regardless of which layer it sat on. Same is true of `harvest_world.gd`'s and
  `undergrowth.gd`'s ray queries — neither sets an explicit `collision_mask`, so both already see
  every layer and needed no change.

Verify with `agent godot --script tools/build_check.gd` (the layer split lives in its own fixtures
now — read the file's header before adding a new one) and `tools/hollowmere_check.gd`.

### 2026-08-18 — the extraction ship exists (A-009), and it introduces the "ship frame" placement pattern

Fifteen exports in `assets/ships/exports/`, catalogued in `assets/ships/catalog.json`, built by
`tools/blender/build_extraction_ship_set.py`, verified by
`.agent/bin/agent godot --script tools/ship_check.gd` (green: 15 imported, 10,456 triangles,
state drift 0.0000 mm, assembly asserted). `assets/ships/README.md` is the full contract.

**The one thing to know before you place any of it.** Eleven of the fifteen are **not**
ground-centred. The mast, both sails, the rudder, the boarding ramp and the cargo hatch are authored
in the hull's own coordinate frame and exported with the hull's origin, so the whole ship assembles
with no offsets to discover:

```gdscript
for part in ["ship_hull_repaired", "ship_mast", "ship_sail_raised",
             "ship_rudder", "ship_boarding_ramp", "ship_cargo_hatch"]:
    add_child(load("res://assets/ships/exports/%s.glb" % part).instantiate())
```

Only `ship_anchor`, `ship_donation_crate`, `ship_departure_bell` and `ship_debris_cluster` use the
usual ground-centred origin and are placed independently. **A ship-framed export legitimately sits
above the ground plane** — the raised sail's lowest vertex is 1.8 m up, because that is where a sail
is — so do not "fix" it, and do not run a blanket ground-contact assertion over this family.
`ship_check.gd` already enforces the right rule per family.

Numbers a gameplay task will want, all in the ship frame (Godot axes): **+X is the bow**, z=0 is the
ground under the cradle, the **deck is at y = 1.78**, the bulwark rail tops out 0.85 m above it, the
mast steps at **x = +1.15**, and the **gangway and boarding ramp are on the +Z (port) side**, 1.73 m
wide between framed posts. The hull is 10.4 m long, 3.4 m in beam, 3.8 m to the stem head.

**Repair states.** `ship_hull_wrecked` → `ship_hull_repair_1` → `ship_hull_repair_2` →
`ship_hull_repaired` swap in place; drift is 0.0000 mm, so collision authored against one fits all
four. Pair `ship_mast_broken` with the first two, `ship_mast` + `ship_sail_furled` from the third,
`ship_sail_raised` when she is ready to leave.

**What is deliberately absent:** collision, interaction volumes, and any repair-progress authority.
The extraction system owns which state is shown and when. The donation crate, the departure bell and
the boarding ramp are the three that will want interaction volumes first.

**If you build another sheet-based family** (anything made of open surfaces rather than closed
solids), copy the generator's `WINDING_LOG` proof — the all-sides audit's inside-out metric cannot
judge open sheets (F-109) and will both false-positive and miss real inversions. And measure
vertices, never `Transform3D * AABB`, on the engine side (F-108).


### 2026-08-18 — environmental VFX is asset-bound now (F-097, D-060). This is the seam every world generator inherits

**The rule, from Sequoyah:** animation and VFX bind to the **asset**, never to a scene or a map,
because release worlds are procedurally generated. D-060 records it; F-097 is what it cost to learn.

**What was actually wrong.** `EnvironmentVfx` was never registered as an autoload — the script had
existed since 2.1g and nothing loaded it. On top of that it discovered work by walking for
`MeshInstance3D` nodes with "grass" in the name, while both generators emit `MultiMeshInstance3D`
batches: 1,740 of them holding 13,026 copies, none of them matched. Hollowmere had no wind and no
firelight at all, and its check was green because it booted the map 2.1k deprecated.

**The contract, in one paragraph.** A generator stamps `asset` meta (the bare export name —
`grass_tuft_a`, `station_campfire`) on every node it emits. For assets whose presentation is
per-copy it also stamps `placements`, a `PackedVector3Array` of where each copy stands in that
node's space. `EnvironmentVfx` reads those two metas and **nothing else about the scene**. Stamp
them and every effect below works on a generated world with no further wiring.

```gdscript
holder.set_meta(&"asset", asset)                       # always
if AssetVfx.emitter_for(asset) != AssetVfx.Emitter.NONE:
    holder.set_meta(&"placements", origins)            # only when presentation is per-copy
```

**Why `placements` and not the batch's own transforms:** MultiMesh instance transforms live in the
RenderingServer and are **write-only under `--headless`** — the buffer is empty and every read is
identity (F-103, guarded by `tools/multimesh_readback_check.gd`). Reading them back put all 269 of
Hollowmere's emitters on the world origin *and passed the check*.

**Files and what each owns:**

| File | Owns |
|---|---|
| `world/environment/asset_vfx_library.gd` | Asset id -> `Sway` + `Emitter` class, and the tuning numbers. Pure classification; knows nothing about scenes. Add an asset family by adding one prefix rule. |
| `autoload/environment_vfx.gd` | Discovery, material swapping, the pooled emitter budget. Registered autoload (27 now). |
| `world/environment/foliage_wind.gdshader` | The sway itself, driven entirely by uniforms from the library. |

**Two properties worth not breaking.** Sway materials are applied to the **mesh resource**, once per
asset — so wind on 13,026 instanced plants costs one material swap, not 13,026. Emitters are served
by a **fixed pool** ranked by camera distance every 0.25 s: Hollowmere's **269 emitter sites cost 23
effect nodes**, and a generated world with ten times as many crystals costs the same. Budgets live in
`EMITTER_PROFILES.max_live` / `shadow_live` and are scaled by the `GraphicsQuality` preset
(low 0.4 / medium 0.7 / high 1.0), read through `/root/GraphicsQuality` — that file is **not**
modified here, so F-098's work on it does not conflict.

**For F-098 specifically (static chunk batching):** merging instances into one static mesh destroys
per-instance `MODEL_MATRIX`, which is where sway phase comes from. The shader already has the escape
hatch — `vertex_phase = 1` takes phase from world-space vertex position instead, and every small
asset (grass, reeds, ferns, flowers) is already set that way, so batching them keeps a per-plant
ripple. Trees are `vertex_phase = 0` and **cannot** be batched without their crowns shearing; batch
them only if you bake a per-instance phase into a vertex attribute.

**Verify with:** `agent godot --script tools/environment_vfx_hollowmere_check.gd` (reads `main_scene`
from `project.godot`, so it follows the shipped map), plus `tools/environment_vfx_check.gd` for the
hand-authored fallback path and `tools/multimesh_readback_check.gd` for the F-103 assumption.

**Untuned on purpose:** headless cannot screenshot (F-077), so the numbers prove the effects reach
the geometry, not that they look right. Sway rates, light colours and budgets are all inspector-free
constants in `SWAY_PROFILES` / `EMITTER_PROFILES` for Sequoyah to judge.

---


### 2026-08-18 — cheap read seams from the F-099 optimization sweep

Three accessors exist so per-frame code stops copying whole structures; use them in anything that
polls:

- **`InventoryService.local_slot(index) -> Dictionary`** — one confirmed local slot, copied. And
  **`local_item_id(index) -> StringName`** — allocation-light; answers `&""` for an out-of-range,
  empty, **or exhausted** (amount ≤ 0) slot, which is the answer held-item/consumable logic wants.
  `local_slots()` still exists for callers that genuinely need the whole array — but the array
  carried by `local_inventory_changed` is now the service's own snapshot: **read-only, duplicate it
  if you keep it past the handler.**
- **`NetTransport.has_peer(peer_id) -> bool`** — membership without the whole-array copy
  `peer_ids()` makes. Every F-059 `_peer_connected` guard now calls this.
- **`PlayerHealth.host_health_changed`** now declares its 5th arg (`revision`) — it was emitted all
  along, so 4-arg subscribers would have errored; there were none in-repo.
- **Downed flags travel only on change** (`PlayerHealth._broadcast_downed_flag` dedups). Late
  joiners get a one-shot flag sync in `_on_peer_joined`; run-player expiry broadcasts the flag
  clear (the ghost-"TEAMMATE DOWN" analogue of F-089). If you add a flag-shaped broadcast, copy
  this shape.

### 2026-08-18 — pixel-exact PNG comparison, without the alpha_only trap (F-079)

**`tools/png_pixels_equal.py`** — `pixel_diff_bbox(path_a, path_b) -> (l, t, r, b) | None` and
`images_pixel_equal(path_a, path_b) -> bool`, plus a CLI (`python3 tools/png_pixels_equal.py a.png
b.png`). Any batch that reruns a Blender generator and has to decide "did the pixels actually
change" should call this rather than reaching for `ImageChops.difference(a, b).getbbox()` directly —
that one-liner silently reports every RGB-only change as identical on an opaque RGBA image (Pillow's
`Image.getbbox()` defaults `alpha_only=True`, and a same-opacity diff image's alpha channel is all
zero). `pixel_diff_bbox` diffs each `Image.split()` band separately instead, so there's no combined
alpha channel for the default to key off. Verified: `python3 tools/png_pixels_equal_check.py` (pure
Python, no Godot — full detail in `docs/FINDINGS.md` F-079 and `docs/SPECS.md` F-079).

### 2026-08-18 — the harness has a test suite now, and `.agent/bin/` ships under a claim (F-081)

`python3 tools/harness_check.py` is the first automated check of `.agent/bin/agent`. It builds a
throwaway git repo, copies a real `agent` into it and drives real `ship`/`check` runs, so it needs no
Godot and takes about a second. **Run it after any harness edit**, and add a case to it rather than
testing a staging rule by hand; `--rev <sha>` runs the same cases against a past revision, which is
how a harness regression gets bisected. The behaviour it locks in: `ship` no longer stages everything
under `.agent/` — it stages the allowlist `COORDINATION_PATHS` (`BOARD.md`, `JOURNAL.md`,
`state.json`) and treats `.agent/bin/` as ordinary source. **If your task edits the harness, claim
the file before `agent done`,** or ship leaves the edit in the working tree; it now names any harness
file it declined to carry, in the "left alone" block.

`agent baseline` (F-080) is the other half: it answers "did this already fail before my change?"
without `git stash`, which is repo-wide and takes every other lane's uncommitted files with it.
`agent baseline --script tools/foo_check.gd` runs that check at HEAD in a throwaway worktree —
`--rev` for another commit, a non-`-` first argument for any other command, `--keep` to leave the
checkout behind. It grafts in everything gitignored that a checkout cannot run without —
`addons/godotsteam`, the `.godot` caches, and all 547 `*.import` sidecars — so the round trip is
about six seconds with a real engine run inside it. **Never `git stash` in this repo.**

**Render checks work now: `agent godot --windowed --script tools/x_render_check.gd` (F-077).**
Headless has no framebuffer, so every check that saves a PNG could only ever print `capture
skipped`; `--windowed` drops the injected `--headless`, keeps the lock, and parks a 64x64 window
offscreen — a `SubViewport` still renders at its full size, so nothing about the capture changes.
`agent baseline` takes it too. If you are writing a check whose output is meant for eyes, this is
how it gets run, and `tools/viewmodel_check.gd` is the pattern to copy: detect
`DisplayServer.get_name() == "headless"` and skip loudly rather than reading a dead texture (F-046).

### 2026-08-18 — performance base (F-090): the probe, the presets, and the scatter pattern the generator must inherit

**`tools/perf_probe.gd`** is the instrument: `.agent/bin/agent godot --display-driver macos --script
tools/perf_probe.gd` runs the real level fullscreen for ~50 s and prints fps / median / p95 /
draws / prims per suspect toggle plus the `gfx` presets (the trailing `--display-driver` wins over
the wrapper's `--headless`; the lock still holds; Metal's GPU timer reads 0 in this build so judge
by frame deltas). Baseline history lives in F-090.

**`GraphicsQuality` autoload (D-055)** — `apply(Preset)` / console `gfx low|medium|high`; `high`
restores per-node captured authored values, so levels need no registration. It re-applies itself on
scene change while a non-default preset is active. `undergrowth_density_scale` is read by
`world/gen/undergrowth.gd` at scatter; `Undergrowth.rescatter()` rebuilds mid-level
(deterministic — lower budgets are a prefix of the same RNG sequence). Console also has `vsync
[on|off]` and `fps_cap [n]` (DevFrameCap). 7.5's settings menu should call
`GraphicsQuality.apply()` and grow UI from there.

**Dynamic resolution (F-098):** `GraphicsQuality.set_dynamic_scale(enabled, target_fps)` /
console `gfx auto [<fps>|off]` (0 = panel refresh). Steps the 3D scale between 0.59 and the
active preset's ceiling, 0.5 s cadence, down fast/up slow, fps-steered. Off by default. The
worst-computer safety net; 7.5's settings menu should expose it as one toggle. Static chunk
batching for authored props is designed and parked in **F-100** (blocked on F-097's claim) —
read it before touching authored-world draw counts.

**World-build time (F-095):** `AUTHORED_WORLD` prints `phase_ms=[...]` — keep it honest when
adding phases. The kit-asset merge is disk-cached at `user://mesh_cache/<kit>_<asset>_<mtime>.res`;
warm loads build the world in ~117 ms (was 9,145 ms). First-ever load still pays ~2.9 s — the
export-time bake is the art pipeline's seam. Repo-wide trap fixed twice there: `get_or_add`
evaluates its default argument eagerly, so never pass an expensive call into it. Two rejected
ideas are recorded in F-095 with numbers (flora part-merge, terrain occluder) — read it before
re-proposing either. The probe's last row measures night+wave; night is currently no dearer than
day.

**The scatter pattern (reference: `world/gen/undergrowth.gd`, for the world generator):** bucket
placements into `CELL_SIZE` (48 m) cells; one MultiMeshInstance3D per (asset, cell) **positioned at
the cell centre including mean ground height** — visibility ranges measure to the node origin, and
an origin at y=0 culls a plateau's plants standing next to the player; short assets (merged AABB
< 0.75 m) get `cast_shadow = OFF` and a 60 m range, tall ones keep shadows and reach 110 m; ranges
get `+CELL_SLACK` and an 8 m `FADE_SELF` margin. Map-wide MultiMeshes are the disease this cures:
one huge AABB defeats all culling and feeds every PSSM cascade (measured 4.1 ms of a 9.3 ms frame).

`StationDef` (`systems/crafting/station_def.gd`: `id`, `display_name`, `world_scene`, `tier`) joins
`RecipeDef` as a registered content family — `content/stations/*.tres`, loaded by
`Registry._load_stations()` into `stations: Dictionary[StringName, Resource]` (untyped, F-016 —
`STATION_DEF` is a brand-new class_name this task, same reasoning as `LOOT_TABLE_DEF`/`POWERUP_DEF`/
`BUILDABLE_DEF` above it). `RecipeDef.station` already existed (default `&"workbench"`) and now
resolves through `Registry.get_station()` instead of a bare string compare — this **is** the "station-
tier check" 3.1's spec asked for: a recipe whose station id doesn't resolve to a registered `StationDef`
is rejected before the range check ever runs. `StationDef.world_scene` is **not** a `PackedScene` —
every crafting station shipped so far is baked map art (`assets/crafting_stations/catalog.json`), not
an instantiated scene, so it's the identifier `CraftingService._station_in_range` matches against a
physical station instance's name (D-051).

**`CraftingService` now finds stations on Hollowmere, not just Playtest Hollow.** The old
`_station_in_range` only ever checked `playtest_hollow_asset`-group nodes — exactly the trap
`world/gen/authored_world.gd:508` already documents for `HarvestWorld` ("only ever looked for
`playtest_hollow_asset` holders that this map never built"). It now also checks
`authored_world_marker` nodes named `"Station_<world_scene>"` (`tools/mapgen/hollowmere_layout.py`'s
`_marker(f"Station_{asset}", "station", ...)` — Hollowmere's station props are baked into a
`MultiMeshInstance3D`, so the marker is the only per-instance position that map exposes). Both group
shapes are checked so every existing offline/net check (built against the legacy group) still passes
unmodified.

**Timed crafts (the furnace worked example, `iron_ore ×2 → iron_ingot`, 2s) needed a field neither
`RecipeDef`'s nor `StationDef`'s spec'd fields had — added `RecipeDef.craft_time_sec: float = 0.0`**
(0 = instant, every pre-3.1 recipe including stone_axe is unaffected). `CraftingService` keeps a
HOST-only `_host_pending_crafts: peer_id -> (request_id -> {data, remaining_sec})`, ticked in
`_process(delta)`; a timed request pre-checks ingredients with `InventoryService.host_can_remove` (so
an already-doomed request rejects immediately instead of occupying a timer slot) but does not remove
them until the timer elapses and `host_transaction` runs — a craft that outlives its own ingredients
(spent elsewhere mid-smelt) is rejected then, same as the instant path already was.

**`CraftingService.craft_progress(request_id) -> float`** (0..1, or -1.0 if not a pending timed craft
this peer itself requested) is a **client-side estimate only** — every peer already has the identical
`RecipeDef` from `Registry`, so `request_craft()` starts the requester's own countdown the moment it
sends the request rather than waiting on a round trip (D-052). This is why 3.1 needed **no new RPC and
no protocol bump**: the wire shape is exactly what 2.6 shipped — a request carries a recipe id and a
local request id, and `craft_confirmed(request_id, accepted, detail)` is still the only completion
signal, timed or not. Proven over real ENet (not just same-process) in
`tools/crafting_net_check.gd` — the host's `_process()` timer completing and RPC-confirming a
genuinely remote peer specifically was previously untested by anything.

**`CraftingUI` no longer hardcodes `&"workbench"`.** `CraftingService.nearby_station_id()` (nearest
registered station the local player is in range of, or `&""`) drives `current_station_id()`; rows
rebuild (`_rebuild_rows`) whenever that identity changes, and the panel title/interact prompt read the
station's `display_name`. `craft_progress()` >= 0 while a request is in flight replaces "Waiting for
the host…" with a live "Crafting… NN%" line.

Checks: `Godot --headless --path . --script tools/crafting_check.gd` (offline, station registration +
tier-rejection + full timed-craft lifecycle), `tools/crafting_ui_check.gd` (station-switch + progress
readout), `agent godot --script tools/crafting_net_check.gd` (real two-process proof, both the
original stone_axe flow and the new remote furnace one). `tools/setup_station_content.gd` is the
deterministic authoring script for the two `StationDef`s plus the `iron_ingot` item/recipe — same
re-run caveat as `setup_crafting_content.gd`: it overwrites those four files, so don't re-run once
their values are being tuned in the inspector. 3.2 authors the rest of the tree against this schema.

### 2026-08-17 — first-person grips, per-weapon attack arcs, and how to get a real in-game screenshot (F-073)

**`agent godot` CAN render. This is the important one, and it answers F-077.** `cmd_godot` builds
`[binary, "--headless", "--path", ROOT] + your_args`, so an appended flag overrides an injected one:

```bash
.agent/bin/agent godot --display-driver macos --resolution 64x64 --position 2400,1400 \
  --script tools/viewmodel_check.gd
```

That keeps the import-cache lock (F-044) and still produces real 1280×720 frames of the running game
— `tools/viewmodel_check.gd` writes `/tmp/mire_viewmodel_{idle,windup,commit,recovery}.png`.
`--resolution 64x64 --position 2400,1400` shrinks the OS window and parks it offscreen; a
`SubViewport` renders at its own size regardless. Two cautions: it opens a real window, so use it for
a deliberate render run and not for every check; and a script that errors inside `_initialize()`
before its `call_deferred` hangs with no main loop to quit it, so keep `--quit-after` or a kill guard.
Every `tools/*_render_check.gd` in the repo becomes usable this way without any change to `agent`.

**`ItemDef` gained `attack_style`** (`enum AttackStyle { NONE, CHOP, SMASH, SLASH, THRUST }`,
`systems/inventory/item_def.gd`). It is presentation only — reach, arc width and damage stay on
`WeaponDef`, which is what the host reads. It is on `ItemDef` and not `WeaponDef` because `short_bow`,
`arrow` and the code-built `unarmed` fallback have no `WeaponDef` to carry it (D-050). A new tool or
weapon **must set it**; unset means CHOP, which is right for an axe and wrong for a spear.

**`entities/player/viewmodel.gd` is now table-driven.** `STYLE_POSES` holds one entry per style —
`cock` / `hit` / `follow` / `arc` — and `_apply_pose` reads the cached `_attack_style`. Adding a style
is one array entry plus one enum value; changing how a family swings is four vectors. Three
invariants that are not obvious and cost real time to rediscover:

- **The hit resolves at the WIND_UP→COMMIT boundary** (`combat_service.gd:197`,
  `elapsed >= wind_up_seconds`), not inside COMMIT. An arc must reach its contact pose at the *end of
  the wind-up* or the visible strike lands a phase after the damage.
- **A positive X rotation RAISES the weapon.** The node sits above `SWING_PIVOT`. The file used to
  claim the opposite and the old constants were signed accordingly.
- **The swing turns about `SWING_PIVOT`, not this node's origin**, via `position = pivot − R·pivot`.
  Rotating about the node origin orbits the weapon around the camera, so 30° of pitch throws a tool
  off the screen.

`PlayerViewmodel.current_attack_style()`, `swing_pose(style, phase, progress)` and
`swing_transform(position, rotation_degrees)` are all public so a check can drive any style's whole
arc **without that weapon being in the hotbar**. That is not a nicety: the dev loadout grants six of
the eleven holdable items, so assertions written against "whatever is selected" never exercise SLASH
and silently pass with an empty failure list. Walk `Registry.items` instead.

**Two generators author `content/items/stone_axe.tres`** — `setup_tool_content.gd` (the solved grips)
and `setup_crafting_content.gd` (the recipe). The second now *reads* `GRIPS` from the first instead of
repeating the numbers. If you add a third writer of any item, do the same; a second copy of these
values is a revert with a delay on it.

**Grips are solved, not nudged.** All eleven are in `tools/setup_tool_content.gd`'s `GRIPS`, so
regenerating content reproduces them. Every A-004 head runs bit-to-poll along local **+X** with the
flat cheeks on local **±Z**, and the origin is at ground level with the grip some way up the haft —
those three facts are what the solve needs. If a design's mesh is rebuilt, re-solve; hand-editing one
number here is what D-050 exists to prevent.

**`tools/viewmodel_check.gd` now asserts orientation and dispatch**, 18 assertions, and all of them
hold under a plain `--headless` run. The load-bearing one is `|cheek · view| <= 0.80` per bladed item:
the grip it replaced measured 0.92 on all seven, the solved grips measure 0.45–0.67. Extend this
check rather than writing a new harness.

**`tools/blender/render_item_icons.py` gained `ROLL_OVERRIDE_DEG`** for icons whose measured framing
picks the wrong roll. A rebuild rewrites all 25 PNGs plus the catalog and the contact sheet, but only
the genuinely changed ones should be committed — compare **per channel**, because
`ImageChops.difference(a, b).getbbox()` on RGBA defaults to `alpha_only=True` and calls every
RGB-only change identical (F-079).

---


### Hollowmere is the map now (2026-08-17, re-authored 2026-08-18 by 2.1k)

`res://levels/hollowmere.tscn` is `project.godot`'s main scene. It is **192 m across against Playtest
Hollow's 88 m** — it was 356 m and that was too big (D-045) — and it is built differently on purpose.

| | Playtest Hollow | Hollowmere |
|---|---|---|
| Source of truth | `tools/mapgen/hollow_layout.py` → JSON | `tools/mapgen/hollowmere_layout.py` → JSON |
| Visuals | baked in Blender to `assets/maps/*.glb` | built at load by `world/gen/authored_world.gd` |
| Collision | `world/gen/playtest_hollow.gd`, a **second** consumer | the same script, same loop |
| Props | placed as scene nodes | `MultiMeshInstance3D` per (chunk, asset) |

The Hollow's two-consumers-one-file rule exists to stop visuals and collision drifting apart.
Hollowmere has **one** consumer, so they cannot drift even in principle. Baking was also simply the
wrong call at this size: one mesh 356 m across cannot be culled.

**The seams, for whatever builds on this next:**

- `AuthoredWorld.height_at(x, z) -> float` — the authored ground height anywhere, without a raycast.
  Use it for placement; use a ray when you need to know what is actually *on* the ground.
- Groups: `authored_world_prop` (a prop's `StaticBody3D`, carrying `asset`/`kit` metadata),
  `authored_world_marker`, `authored_world_terrain`.
- Markers carry `kind` metadata and the map ships: `spawn` ×1, `extraction` ×1, `objective` ×1
  (the Wellspring), `enemy_nest` ×4, `landmark` ×9, `station` ×8, `loot` ×8, `bridge` ×2.
  **`enemy_nest` is now consumed**: `EnemyWorld.ambient_spawn_points()` reads
  `authored_world_marker` / kind `enemy_nest` as well as the Hollow's group, so the four nests in the
  Blight are where every crawler on this map comes from. `extraction` and `objective` are still
  unconsumed and remain host-authoritative work for whoever wires them.
- **Harvestables are live, and they are individual nodes** (D-049). A layout prop carrying
  `"harvestable": true` is built as a holder in group `authored_world_harvestable` with `asset`/`kit`
  metadata, a `Visual` child and a `CollisionBody` child — the shape `HarvestWorld._wire_holder`
  needs. `HarvestWorld.HOLDER_GROUPS` now lists both maps' groups and finds the visual either by a
  `Visual` child (Hollowmere) or by the `AuthoredVisuals` index (the Hollow). 83 wired on this map.
- **`yaw_along(dx, dz) = atan2(-dz, dx)`** is the only way the generator turns a direction into a
  yaw, with `tangent_yaw`/`radial_yaw` on top for rings (D-046). Get this wrong and every directional
  prop mirrors; the symptom that finally exposed it was bridge railings crossing their own decks.
- **Water is one unioned surface per material**, highest level wins per grid vertex, clipped to the
  ground and emitted wherever *any* corner of a quad is submerged. Bodies may be `circle`, `rect` or
  `polyline` (the river is one polyline body, not one strip per segment). Overlapping bodies can no
  longer draw two stacked sheets, and the shoreline no longer staircases.
- **Zones tile the map** by `distance - pull` (D-048). The layout's `zones` array carries `pull`, and
  `undergrowth.gd` reads it, so flora and props on a patch of ground always come from the same zone.
- `Undergrowth` (`world/gen/undergrowth.gd`) is map-agnostic: point `layout_path` at any layout with
  `zones`, `props`, `roads`, `heightfield` and `bound`, set `prop_group`, and it scatters the flora
  kit by zone. It is client-local and deterministic from the layout seed, so peers agree without
  replication. It owns every family named in its `ZONE_PALETTES` and the layout owns everything else
  (D-047). Three of its rules were silently inert on this map until 2.1k: the prop test looked at the
  collider's parent instead of the collider (grass grew on top of trees and rocks), the road test read
  a schema this map does not write (bushes grew down the middle of every road), and the probe ray ran
  between fixed world heights of 24 m and −12 m, so nothing above 24 m grew anything at all.
- **Neither node has network authority and neither may gain any.** They are presentation. Anything
  that needs to change during a run — a broken bridge, a flooded zone — is host state.

Measured 2026-08-18 by `agent godot --script tools/hollowmere_check.gd`: terrain 18,432 triangles in
one mesh, **2,869 authored props** through 1,028 multimeshes, 501 colliders, 83 live harvestables,
**10,240 scattered plants** through 78 multimeshes, 2 water surfaces, 9,486 navmesh polygons. Ground
probes at 647 points found no holes and collision **0.000 m** from the authored height — the generator
and `AuthoredWorld.height_at` now sample the same two triangles per cell rather than a bilinear
approximation of them, which is what makes "nothing floats" hold to the centimetre. 672 sampled props
float 0.00 m; 3,441 sampled plants sit on props 0 times; water samples stacked 0 times.

**To look at the map without the editor:** `python3 tools/mapgen/hollowmere_plan.py [out.svg]` draws
the layout as a labelled plan view — terrain, water, roads, every prop coloured by family, landmarks
named — and writes an SVG and a PNG. Pure stdlib. `tools/hollowmere_render_check.gd` still takes the
in-engine screenshots and still cannot, because `agent godot` is always headless (F-077).

**Playtest Hollow is deprecated, not deleted.** Nine headless checks still boot it, it is what every
existing system was tuned against, and it loads in a second — which makes it the right fixture for a
test long after it is the wrong thing to ship. Do not build new content against it; do not delete it
until those checks have somewhere else to run. `world/gen/playtest_hollow.gd` says so at the top.

**Not yet recorded as a decision.** `docs/DECISIONS.md` had uncommitted edits from another session
while this landed, so the D-number for "large maps are built at runtime, small ones are baked" still
needs writing by whoever owns that file next.


> Execution specs for every remaining roadmap task live in **`docs/SPECS.md`** — this section holds
> the *shipped* seams those specs build on.

### 2026-08-18 — a source-text regression guard for two `tools/*_net_check.gd` authoring traps (F-060)

`agent godot --script tools/net_check_pattern_check.gd` now runs alongside every other check suite and
fails if a new (or copied-from-old) `tools/*_check.gd`/`tools/*_net_check.gd` reintroduces either shape
F-060 named: a client ready-gate built from `local_peer_id() > HOST_PEER_ID` with no `is_active()`
check nearby (can read true while the connection is still CONNECTING), or a strictly-typed `Dictionary`
property mutated straight off a `some_autoload.get("prop")` reflection read with no `.set()`-back
(silently does not reach the original). It is a source scan, not a runtime one, on purpose — same
reasoning as `tools/interp_coverage_check.gd` (D-043): both bugs manifest as code that silently does
nothing, so there is nothing at runtime for a check to catch it failing against. Nobody needs to run it
by hand when writing a new net check — it walks the whole `tools/` tree itself.

### 2026-08-18 — `_peer_connected(peer_id)` is now a two-file pattern, and there's a gap it exposed (F-059/F-074)

`autoload/inventory_service.gd` gained the same `_peer_connected(peer_id)` guard
`systems/health/player_health.gd` already had: `_transport().call("peer_ids").has(peer_id)`, checked
before every `rpc_id(peer_id, ...)` send to a specific peer. **Any new host-owned per-peer system with
its own `rpc_id` sends should copy this from either file rather than reinvent it** — it's the standard
answer to D-035's grace window (a departed peer's state survives `peer_left` on purpose, so a peer id
can sit in a host dictionary with no live connection behind it).

**The gap the fix exposed, closed as F-074:** `InventoryService._valid_host_peer(peer_id)` used to
require `peer_id` to be a *currently connected* peer, so `host_add`/`host_remove`/`host_move_stack`/
`host_transaction` all silently refused to mutate a parked (mid-grace-window) peer's store — a grant
that landed for someone between a drop and a reconnect was lost, not queued. Fixed to match
`player_health.gd`'s `host_apply_damage` shape: **a live `_host_stores` entry is now valid regardless
of current connectivity** — `_valid_host_peer` returns true immediately if `_host_stores.has(peer_id)`,
before it ever asks the transport. A peer with no store yet still needs a live transport connection
(or, offline, must be the host) before one is created for it, so an unseen/spoofed peer id is still
rejected. Publishes immediately rather than waiting for rebind — safe because `_publish_snapshot`'s
`rpc_id` send is already gated on `_peer_connected` (F-059), so a parked peer's snapshot just updates
its host-side store, never an RPC to a peer id the transport doesn't recognise. Any new host-owned
per-peer system with its own mutation gate should copy this shape too: check the state dict, not the
transport, and let `_peer_connected` guard only the outbound `rpc_id` send.

### 2026-08-18 — the building system is in (3.6). This is what 3.7 authors against

`BuildService` is autoload #25, HOST-authoritative (§2.2 world mutation). Protocol is **12**. Three
files: `systems/building/buildable_def.gd`, `placement_validator.gd`, `build_ghost.gd`.

**The load-bearing idea is one validator, two callers.** The ghost calls
`PlacementValidator.evaluate()` to colour itself green or red; the host calls the *same function*
against its own space state to accept or reject. Sharing the code is not sharing the authority — the
host re-snaps and re-evaluates and believes nothing from the wire but a piece id and a transform,
both re-checked. What sharing buys is that a green ghost and an accepted placement cannot drift
apart through two subtly different rule sets, which is the bug that makes a building system feel
broken rather than strict. **Do not write placement rules anywhere else.**

`snap_transform()` is pure — no world, no builder — so two players snap to the same world-space grid
and their walls line up. `evaluate()` returns a `Reason`, and `reason_text()` gives the words, so the
ghost and a host rejection say the same thing to the player.

**Authoring (task 3.7).** Copy `content/buildables/wall.tres` (a plain piece) or `ward_post.tres` (a
Ward — `ward_radius_m > 0`; the field ships now, **4.11** is the task that makes the Mire respect it).
Fields: `size` is the footprint box in metres with the origin at its FLOOR centre, `snap_step` and
`rotation_step_degrees` drive snapping, `requires_support` / `max_ground_slope_degrees` /
`max_build_range_m` are the placement rules, `cost` is spent through `host_transaction` and
`refund_fraction` comes back on destruction. `scene` may be left null: `BuildService` generates a
box collider and mesh from `size` so a piece without art is still a real, colliding, navmesh-affecting
object — art is 3.7's job, not a blocker for testing gameplay.

**Two orderings inside the system that must not be swapped.** Support/slope is evaluated *before*
overlap, because a piece on a slope steep enough to refuse is also geometrically buried in it, so
overlap-first reports every steep placement as "something is in the way" — true and useless. And cost
is charged *last*, after every geometric rule has passed, because it is the only check with a side
effect: rejecting after a successful `host_transaction` silently eats the materials. If the spawn
then fails, the cost is explicitly refunded.

Navigation is rebaked after any placement or destruction, **debounced to one per second** in
`_physics_process`, never inline — a player dragging out a ten-piece wall would otherwise trigger ten
full-level rebakes (21,364 polygons on Hollowmere). Per-chunk baking is 4.5's problem.

**Verify:** `agent godot --script tools/build_check.gd` (59 assertions offline, against a real physics
world rather than a mock) and `tools/build_net_check.gd` (13, two real ENet processes, including the
assertion that a client running the host's own placement path forges nothing).

**A trap for the next networked harness in this area:** do not hard-code a build spot. `PlayerNet`
fans peers out from the spawn point, so a fixed spot lands on somebody's body and the host correctly
refuses it as OVERLAPS — the cost path is never reached and you measure the wrong refusal.
`build_net_check` derives the spot from the client's actual body position; copy that.

### 2026-08-18 — destruction now actually mirrors placement (F-084)

`_process_destroy` (`autoload/build_service.gd`) checked only `_placed.has(piece_name)` — sequential
node names (`Piece1`, `Piece2`, ...) meant any peer could free and refund any structure from anywhere
by guessing them. It now calls the exact same `_builder_position(peer_id)` placement already trusts
nobody about, and refuses (`VALIDATOR.Reason.OUT_OF_RANGE`, "too far away") before any refund or
`queue_free()` if that body is farther than the piece def's own `max_build_range_m`. **Ownership is
still not checked, on purpose** — "refund goes to whoever tears it down, not to whoever built it" was
already 3.6's design, so any teammate clearing a misplaced piece must keep working; the fix adds only
the range gate 3.6's own "Destruction mirrors it" line always implied. Whoever wires the gameplay
caller (F-086) or gives buildables a real damage method (F-085) should assume destroy is range-gated
identically to placement — there is no separate "destroy range" field, it reads `max_build_range_m`.

**For the next `tools/*_net_check.gd` that needs a piece of world state far from its one real
client:** you don't need a second player body. `service.call(&"_spawn_piece", id, transform)` spawns
a real, replicated piece anywhere (it skips `_process_place`'s validation, which is the point — you
are placing world state to test against, not re-testing placement); giving it a destroy-able identity
means writing to `BuildService._placed` yourself, and F-060 applies: capture `service.get(&"_placed")`
to a `Dictionary` local, mutate that, then `service.set(&"_placed", ...)` it back explicitly, or the
regression guard (`tools/net_check_pattern_check.gd`) has nothing to say about it but the mutation may
not stick anyway. `tools/build_net_check.gd`'s new destroy-range assertions are the worked example.

### 2026-08-18 — support now means ALL five probes, worst slope wins (F-082)

`PlacementValidator._probe_support()` used to skip any of its five footprint probes that missed and
return the flattest hit among whatever survived — `evaluate()` treated that as fully supported, so a
wall balanced on a pillar under its centre, or hanging three-corners-off a cliff, read `Reason.OK`.
**Contract now:** `_probe_support` returns `{}` (the same sentinel `evaluate()` already reads via
`is_empty()`) the instant any one of the five probes misses, and otherwise returns
`{"slope_degrees": <worst of the five>}` — the steepest, not the flattest. No `BuildableDef` field
distinguishes "required" from "optional" probes, so all five are required; a piece meant to bridge a
gap keeps using `requires_support = false`, unchanged. **Whoever authors more buildable content
(3.7) or touches placement rules next should know:** a flat piece run *across* a steep slope's fall
line can no longer be supported at all — its corners are metres apart vertically, well outside any
probe's 0.6 m reach — only a piece run *along* the contour, or one small enough that its whole
footprint sits within reach, can pass `requires_support` on genuinely steep ground. That is a real
behavior change (correct per the finding), not a regression: `tools/build_check.gd`'s own slope test
needed the same reorientation and is the worked example if you need another one — see its comment
in `_build_world()` for the "thin the box or a probe starts inside the solid a few cm off the exact
tuned point" trap when hand-placing tilted test geometry.

### 2026-08-18 — buildable pieces can now actually be attacked (F-085)

Joining `&"damageable"` used to be the whole story for a placed piece; now it also gets a
`host_apply_damage(amount, instigator_peer_id) -> bool` that does something, which is what
`CombatService._best_target()` actually requires via `has_method()` before it will ever pick a node
as a target — before this, every buildable was silently unreachable.

**`systems/building/buildable_piece.gd`** (new, `extends Node3D`, no `class_name` — it is attached
dynamically) is the implementation. `BuildService._net_spawn_piece()` attaches it to a piece root
**only if that root doesn't already have `host_apply_damage`** — today that's every piece (task 3.7's
art carries no scripts yet), but an authored root that brings its own richer damage handling (staged
break states, say) is left untouched rather than overwritten. `hp` is host-only and **deliberately
unreplicated** — nothing shows chip damage yet, and a piece's existence already replicates through
`MultiplayerSpawner`'s despawn the instant the host `queue_free()`s it (D-023), which is the only
state a client needs today. The method mirrors `Harvestable`/`Enemy`'s shape exactly: it re-checks
host authority itself (`_owns_world_mutation()`, same three-line pattern) rather than trusting that
`CombatService` already gated it — "someone else already checked" is how a check quietly disappears
later.

**`BuildableDef` gained `max_hp: int = 25`** (new `@export_group("Combat")`, validated `> 0` like
every other numeric field) — the source `_net_spawn_piece()` reads into a fresh piece's `hp` at spawn.
Existing content (`wall.tres`, `ward_post.tres`) needed no edit; an unauthored export field just takes
the script default, so both worked examples are HP 25 until someone tunes them in the inspector.

**`BuildService.host_piece_destroyed_by_damage(piece_name, instigator_peer_id)`** is the new host-only
entry point `BuildablePiece` calls on lethal damage. It does the same teardown `_process_destroy` does
(erase from `_placed`, `queue_free()`, request a nav rebake, emit `piece_destroyed`) **minus the range
check** (the attacker already had to pass the weapon's own reach/arc test in `CombatService`) **and
minus the refund** (a piece fought and lost pays out nothing — same as `Harvestable`/`Enemy` on
death; only a deliberate `request_destroy` teardown refunds, per the existing 3.6 design that refund
goes to whoever tears a piece down).

Whoever wires 3.7's real art (F-086) should know: dropping a script onto the scene root via
`set_script()` only works because nothing under `content/buildables/*.tres` carries one yet. The first
authored root that wants its own `host_apply_damage` (multi-stage break visuals, say) just needs to
implement the method itself — `_net_spawn_piece()` already detects and defers to it.

Verify: `agent godot --script tools/build_check.gd` (`failures=0`) — new assertions call
`host_apply_damage` directly rather than trusting the `&"damageable"` tag, then a dedicated
`_check_damage_destroys_piece()` places a second piece, kills it with a lethal hit, and confirms
`BuildService` forgets it, the node frees, no refund lands, and a nav rebake queues.
`agent godot --script tools/combat_check.gd` (`failures=0`) confirms combat's own harvestable/enemy
scenarios are unaffected.

### 2026-08-18 — placement Y is no longer snapped to the grid, only X/Z (F-083)

`PlacementValidator.snap_transform()` used to round Y onto the same `snap_step` grid as X and Z. On
Hollowmere's non-integer terrain that either buried a piece in the ground or floated it above the
surface — see F-083 in `docs/FINDINGS.md` Resolved for the exact failure and D-056 for the call.
**Now: `snap_transform()` snaps X/Z only; `origin.y` passes through untouched.** This is a contract
change anything calling `snap_transform()` or reading a placed piece's Y should know:

- The Y a piece ends up at is whatever the caller's own aim ray hit — terrain, a slope, or another
  piece's real top surface. There is no `BuildableDef` field or separate function for "anchor to a
  grid Y"; if a future piece type needs to ignore uneven ground and sit at an exact authored height,
  that is new scope (D-056's "would change my mind" line), not something this fix already covers.
- Flush stacking (a piece placed directly on top of another) needs no special-casing: a raycast
  against an existing piece already reports that piece's exact top, so the new piece's floor lands
  there with zero gap, the same way it lands flush on terrain.
- `content/buildables/wall.tres`'s own doc comment ("Snaps to the metre grid so a run of them
  actually lines up") is still true for X/Z. It is not true for Y across uneven ground — a run of
  walls built along a slope will follow the slope, not share one Y, same as it would in reality.

Verify: `agent godot --script tools/build_check.gd` — `_check_ground_height_is_preserved()` is the
new function, built against two isolated flat pads at non-integer heights (top surfaces y=0.4 and
y=0.6, the review's own `GROUND_0_4`/`GROUND_0_6` probes); `_check_ghost()` gained an end-to-end
case aiming `BuildGhost` straight down at the y=0.4 pad to prove the whole `update_aim() ->
snap_transform()` chain the finding named, not just the pure function. `failures=0`.
`tools/build_net_check.gd` `failures=0`, unaffected.

### 2026-08-18 — the 3.4 design check is done: the schema holds, and docs/POWERUPS.md is now the authoring spec (reed16)

The question that had to be answered before 3.4 hand-authors 40–60 `.tres` files: can the whole
design space live in `tags` + `max_stacks` + `(stat → Vector2)`, or is a field missing that would
force re-authoring everything? **docs/POWERUPS.md is the answer: a 60-powerup sketch spanning all
six families and every archetype (always-on, conditional, on-event, proc, capability, tradeoff,
tag-only feeder) — zero need a new field.** Conditions, triggers and capabilities are stat-name
conventions consumed at the owning system, not schema; D-050 records why that beats fields, and §5
of the doc records what evidence would reopen the question.

**For 3.4:** author against POWERUPS.md §2 (the stat catalog — names, signs, consumers) and §4
(the sketch, as a menu not a shipping list). The vocabulary is now enforced (F-078):
`PowerupDef.KNOWN_STATS`/`KNOWN_FAMILIES` back `validation_errors()`, so a typo'd stat name, a
lowercase `&"fire"` tag, a `Vector2.ZERO` no-op, or a negative multiplier that inverts its stat at
`max_stacks` (D-044 linear stacking crosses zero at `mult·N ≤ −1`) is a named boot error, never
silently dead content. Inventing a stat the catalog lacks = one row in POWERUPS.md §2 + one line in
`KNOWN_STATS`, on purpose. `tools/powerup_check.gd` carries seven F-078 assertions (42 total, 0
failures, clean error-line bar).

**For every system task that wires a stat** (movement, health, combat, stamina, Mire...): the name
your system must route through `PowerupService.stat()` is already settled in POWERUPS.md §2 —
content authored before your task exists depends on you using exactly that name. Condition-suffixed
stats (`melee_damage_low_hp`) chain onto your unconditional pass per the worked snippet in §2.

### 2026-08-18 — the powerup framework is in (3.3). This is what 3.4 and every effect task build on

`PowerupService` is autoload #23, HOST-authoritative (§2.2 "active modifiers"). Protocol is **11**.

**The one seam. Systems ASK the service; it never reaches into systems.**

```gdscript
speed = PowerupService.stat(peer_id, &"move_speed", BASE_SPEED)   # or local_stat() for yourself
```

That direction is the entire point. A powerup that pushed values into `PlayerController` would make
every new powerup a code change in the system it touches — the opposite of §4.4's "mostly data, not
code". **No system needs editing to support a new stat powerup**; it needs editing once, to route its
base value through `stat()`, and then never again. Movement, damage and health are the obvious first
three and none of them are wired yet — that is deliberate, it is each system's own task and a
one-line change when it comes.

**Authoring (task 3.4).** `content/powerups/swift_stride.tres` is the worked example; copy it.
`id`, `display_name`, `icon`, `tags`, `max_stacks`, `modifiers`. `modifiers` maps a stat name to
`Vector2(additive, multiplicative)` **per stack** — `Vector2(0, 0.08)` is +8% per stack,
`Vector2(2, 0)` is +2 flat. D-044 fixes the maths and fixes that **tags ARE the Resonance families**;
there is no separate `resonance_family` field, so do not look for one. `validation_errors()` runs at
boot and a malformed .tres is a named error and a skip, never a crash downstream.

**Resonance is a flag, not an effect.** `resonance_active(peer, &"Fire")` and
`greater_resonance_active(...)` at §4.4's 3+ and 6+. This service does not know what Blood resonance
*means* — the task that ships "kills heal you" asks the flag and implements itself, and the
`resonance_changed(peer_id, family, tier)` signal fires on crossings in both directions so an effect
can switch off as well as on.

**The replication split, which is the part to not accidentally undo.** The owner gets its full
`id -> stacks` map by `rpc_id`; *everyone* gets per-peer per-family **counts** by broadcast. So a
teammate can see you are three-deep in Fire — §4.4 makes that a decision at every chest — and cannot
name one powerup you hold. `tools/powerup_net_check.gd` asserts exactly that over two real ENet
processes, including the negative half, because broadcasting the snapshot by mistake is a change no
offline check can catch.

**D-035 is honoured**: `peer_left` drops nothing, `run_player_rebound` moves the stacks, only
`run_player_expired` deletes them. Losing a run's powerups to a reconnect would be worse than the
inventory bug that motivated D-035, because unlike an inventory they cannot be re-gathered.

**Verify:** `agent godot --script tools/powerup_check.gd` (28 assertions, offline) and
`tools/powerup_net_check.gd` (13, two processes). Writing the second one is what surfaced a real
gap — a mid-run joiner learned nothing until somebody happened to open a chest, because publishing
on mutation is only correct if every peer was present for every mutation. `_on_peer_joined` now
sends the board.

### 2026-08-18 — an obsolete peer id's family counts now actually leave the board (F-089)

D-035's rebound/expiry lifecycle above was correct on the host but incomplete on the wire: neither
`_on_run_player_rebound` nor `_on_run_player_expired` ever told teammates that an old/expired peer id
was gone, so `_family_counts[old_id]` on every client was a ghost that outlived the id forever —
`net_powerup_counts` is a broadcast with no deletion path of its own.

**The fix, if your task touches either lifecycle hook again:** both now end by calling a shared
`_retire_broadcast(peer_id, before)` on the id that is going away, BEFORE that id's `_family_counts`
entry is erased from the host's own state. It emits the downward `resonance_changed(peer_id, family,
Resonance.NONE)` transition for every family `before` was resonant in, then (guarded by
`NetTransport.is_active`, same as `_publish()`) broadcasts `net_powerup_counts.rpc(peer_id, {})` so
every client's entry for that id reads empty. **Call it with the retiring id's OWN `before` snapshot,
not the rebind target's** — `_on_run_player_rebound` still copies `_family_counts[old]` onto
`new_peer_id` first and calls `_retire_broadcast(old_peer_id, ...)` after, so `_commit(new_peer_id)`'s
before/after diff is unchanged and does not re-fire `resonance_changed` for thresholds already crossed
under the old id.

**Verify:** `agent godot --script tools/powerup_review_check.gd` (6 assertions over two real ENet
processes, both lifecycle events, `POWERUP_REVIEW_CHECK failures=0`) plus a clean rerun of
`powerup_check.gd` and `powerup_net_check.gd` for no regression.

### 2026-08-18 — night waves actually run now, and the reason they did not is worth keeping

`WaveSpawner` is registered (autoload #22, after `DayNight`, which its `_ready()` depends on). Dusk
disables `EnemyWorld.ambient_enabled`, spawns `base_count + per_player * live_players` at ambient
spawn points, and dawn clears the field and restores the exact ambient setting found at dusk. All
host-only; `EnemyWorld`'s existing `MultiplayerSpawner` replicates the bodies, so 2.12 added no RPC
and the protocol version is untouched (still 7).

**It shipped correct and did not run for a day, and the harness said it was fine.** `wave_spawner_check`
built its own `WaveSpawner` and its own node named `DayNight`, so it proved the *script* worked and
could say nothing about whether the *project* loaded it — and once 2.11 registered the real DayNight
autoload, the fake was renamed out from under it and four assertions started reading a signal nobody
had subscribed to. The generalisable rule, for anyone writing the next harness:

> **If the system under test is an autoload, the check must resolve the autoload.** Constructing a
> private instance is only defensible when the check has to pass *before* registration — which is
> `tools/day_night_check.gd`'s documented case, and it says so in its header. Everywhere else, reach
> for `/root/<Name>` and let a missing autoload fail the check on line one.

`tools/wave_spawner_check.gd` now does exactly that, and crosses thresholds by advancing the real
clock (`DayNight.host_advance()`, with `set_physics_process(false)` so nothing crosses behind your
back) rather than by emitting the signal — the claim under test is that the host's own clock reaching
0.75 causes a wave, not that a signal has a subscriber.

### 2026-08-18 — the sky has a night half now (F-065), and these are its seams

`world/environment/playtest_atmosphere.gd` is still the one place time-of-day becomes pixels, and it
is still purely client-local. It now drives two things it did not before. **If you are writing 2.12's
night waves, or anything that wants to know how dark it is, read the clock (`DayNight.time_of_day`),
not these — they are presentation, and a client may legitimately render them differently.**

- **`CloudDeck.set_sky_light(daylight: float, golden: float)`** — the cloud deck is
  `SHADING_MODE_UNSHADED`, so *no light in the scene can affect it*. Anything that wants the clouds
  to change colour has to drive `albedo_color` explicitly; this is that seam. `daylight` is 0 at
  night and 1 with the sun up; `golden` peaks at 1 with the sun exactly on the horizon. Resolved by
  method, not node name, so a level can call its deck whatever it likes.
- **`Atmosphere/StarField`** (`world/environment/star_field.gd`) — built at runtime by Atmosphere's
  `_ready()`, so **no level scene needs editing to get a night sky**, and a level with an Atmosphere
  node already has one. `set_night_amount(0..1)` fades it, `set_sky_rotation(radians)` wheels it. It
  is `top_level` and copies the active camera's position every frame while visible, and hides itself
  and stops processing entirely at `night_amount <= 0.001`.

Three curves now come off sun elevation in `apply_atmosphere()`, and they are deliberately *not* the
same curve — this was the bug, not a refinement. `daylight` (−7°..12°) is the ground-lighting curve
and reaches ~0.3 while the sun is still exactly on the horizon; driving sky colour off it made sunset
grey. `sky_night` (−1°..−14°) turns the sky material to its night colours only once the sun is
actually down. `starlight` (−1°..−16°) brings the stars in. Elevation moves ~24° per game hour at the
horizon, so a narrow window reads as a switch rather than a fade — `atmosphere_night_check.gd`
asserts the fade holds intermediate values, and it caught exactly that on the first attempt.

**Day is provably untouched.** Every day-end sky value is read off the authored resource in `_ready()`
rather than written into the script, and the check asserts full daylight restores
`rayleigh_color`/`mie_color`/`ground_color` byte-for-byte. Re-tune the sky in the `.tscn` and the
script follows.

**Two harnesses:** `agent godot --script tools/atmosphere_night_check.gd` is the headless one (33
assertions, no framebuffer needed). `tools/hollowmere_night_render.gd` is the one that produces
pictures, and it must run **windowed** — its header carries the five-line snippet that takes the same
`godot` lock `agent godot` takes, which is how any future windowed check should be run (F-044).

### 2026-08-17, from Sequoyah's 2.9 playtest — three things 2.13 broke or left dark (F-062/063/064)

The gate could not be judged as shipped. What he actually reported — hp at zero, no death, slow
movement, "attacking the enemies doesn't seem to work anymore" — decomposed into three separate
defects, all fixed and all now covered headless.

- **F-062 · every swing hit the attacker.** `CombatService._best_target()` iterated `&"damageable"`
  without excluding the swinger. Task 2.13 had put the player body into that group so crawler hits
  could land, and that alone turned every axe swing into a self-hit: the attacker's own origin sits
  `EYE_HEIGHT_M` (1.5 m) below the eye at *zero horizontal offset*, which takes the "directly on the
  axis" early branch and **skips the arc test entirely**, then wins the nearest-target contest
  against anything past 1.5 m. Most of the axe's 2.6 m reach was unusable and every swing cost 3 hp.
  **The lesson worth keeping: putting an entity into `&"damageable"` is not a local change.** Any
  future task that adds a body to that group must ask what now targets it.
  `tools/combat_self_hit_check.gd` is the regression anchor, and it exists separately from
  `tools/combat_check.gd` because *that* check's attacker is a bare `Node3D` in `&"players"` only —
  structurally incapable of catching this. New combat checks use the real `player.tscn`.

- **F-063 · offline respawn teleported to world origin.** `_spawn_transforms` was only ever written
  from `PlayerNet.player_spawned`, which fires *inside a session only* — offline PlayerNet leaves the
  level's hand-placed Player alone. So solo play, the configuration 2.9 is played in, always fell
  through to `Vector3.ZERO`. `PlayerHealth._capture_local_spawn_transform()` now latches the local
  body's transform on the first physics tick it exists, and a missing entry warns and respawns in
  place rather than silently slamming to the origin.
  **The lesson: `tools/player_health_check.gd` called `_on_player_spawned` by hand.** A check that
  simulates a signal the shipped configuration never emits proves the handler, not the wiring — it
  hid this for a whole task. That check now also runs the flow with nothing faking the signal.

- **F-064 · downed/dead were invisible.** `ui/hud/vitals_hud.gd` discarded the `state` and
  `bleed_out_remaining` its own snapshot handler received. It now draws a centre banner: **DOWNED**
  with a live bleed-out countdown and the revive line, **YOU DIED** with the respawn countdown, and
  **TEAMMATE DOWN** (with the bound interact key) for a living player, off the broadcast
  `downed_flag_changed` flag. All client-local presentation — no wire change, protocol still 7. The
  countdown re-seeds from every host snapshot and ticks locally in between, because the snapshot is
  throttled to ~1 Hz and a countdown a player watches cannot move at 1 Hz.
  `tools/vitals_hud_check.gd` drives it through the real PlayerHealth host path, not by emitting the
  HUD's own signals.

**Work can now be dispatched to three paid accounts in parallel, and you may be one of them.** If you
are `lc1`, `lc2` or `lp`, you were started by `agent dispatch` and your whole spec is the work order
piped into you — no one is going to answer a question, so decide and keep going. `docs/ORCHESTRATION.md`
is the protocol; D-036 and D-037 are the calls behind it. The commands, for a director:

```bash
agent order <id> --lane LC2 --files a.gd b.gd   # self-contained order; refuses overlapping claim sets
agent dispatch LC2 [--dry-run]                  # runs it on that account, headless
agent report | agent collect | agent reap       # who's working / what came back / free dead claims
```

Two things changed for **everyone**, agent or human, whether or not you use the lanes:

- **Launch the engine with `agent godot --script tools/x_check.gd`, never bare `Godot --headless`.**
  All ~49 checks share one 42 MB import cache and concurrent runs race on it (F-044) — the most
  likely explanation for F-038. `agent godot` takes an exclusive lock; a bare invocation bypasses it.
- **`agent ship` now takes a git lock**, so concurrent ships no longer contend on one index. Nothing
  to remember — it is automatic.

A lane that dies on a quota wall releases its claims and files its own handoff, so a dead lane never
blocks a file. If a process vanished too suddenly for that, `agent reap` is the backstop. Quota
exhaustion is detected only from a *failed* run's error text, and the pattern deliberately ignores
this project's ordinary `rate_limit`/`429` vocabulary — `lane selftest` holds that line at 14 cases,
so run it if you touch the classifier.

**Task 3.8 ships hunger/stamina/food — extending `PlayerHealth` rather than a new service.**
Three authority rows in one file, each documented in its own section of `player_health.gd`'s class
doc: hp and hunger are HOST (hunger drains every host tick, empty hunger drains hp through
`DownedState.apply_damage()` — the exact path a melee hit uses, so starving can down a player like
anything else); stamina is CLIENT-LOCAL (§2.2 row 1, "own player movement") because it gates
sprint/jump/dodge and gating a client's own movement from the host would reintroduce input lag.

**Hunger**: `_hunger`/`_starvation_accum` are host-owned `Dictionary[int, float]`, ticked in
`_physics_process` alongside the existing downed-state loop. `_tick_hunger(peer_id, downed_state,
delta)` prorates against the PREVIOUS hunger value, not the whole delta — a tick spanning both
"still had hunger" and "ran out partway through" (an oversized single step, whether a real engine
hitch or a check fast-forwarding many seconds) must only charge starvation for the fraction actually
spent at zero, or a big-enough delta applies years of accumulated damage in one frame. Found by
`tools/player_vitals_check.gd`'s own fast-forwarding, not by inspection — worth remembering next
time a `_physics_process`-driven accumulator takes an unbounded delta.

Hunger piggybacks `net_health_snapshot` (now `revision, hp, hp_max, state, bleed_out_remaining,
hunger, hunger_max` — **protocol version 9**, was 8) rather than a second RPC channel: published
immediately on a discrete event (damage, revive, consume) and otherwise throttled to
`HUNGER_SNAPSHOT_INTERVAL_SEC` (1 Hz) so a continuous per-tick drain never turns into a 60 Hz reliable
RPC — the same reasoning `day_night.gd`'s `REPLICATE_INTERVAL_SEC` exists for. Read API:
`local_hunger()`/`local_max_hunger()` (owner-only, via `local_hunger_changed`), `host_hunger(peer_id)`.

**Stamina** lives entirely outside `_states`/`_hunger` — no host dictionary, no RPC gate. The owning
client calls `local_tick_stamina(delta, draining)` every physics tick (drains at
`stamina_drain_per_sec` while `draining`, else regenerates at `stamina_regen_per_sec`) and
`local_try_spend_stamina(amount)` for a discrete cost (jump today; 3.8b's dodge is the next caller).
**Hysteresis, not a bare `stamina > 0` gate**: `local_can_sprint()` also checks a `_sprint_locked_out`
flag that `local_tick_stamina()` sets the instant stamina hits exactly zero and only clears once
stamina regenerates back above `sprint_resume_fraction` (15% by default) of max. Without it, a player
sitting at the boundary while still holding sprint flickers on and off every single physics frame —
one frame of regen reads as "> 0" and re-enables sprint, which immediately drains it back to zero.
Found the same way as the hunger prorating bug: by writing `tools/player_vitals_check.gd`'s own
`_apply_horizontal_movement` integration test, which failed until this existed.

The host keeps a **best-effort, advisory-only** copy via `host_stamina(peer_id)`, refreshed by
`net_report_local_stamina` (`any_peer`, unreliable) every `stamina_reconcile_interval_sec` (2s
default) from `local_tick_stamina()` itself. The host never derives gating from this — it exists so
3.8b's server-validated dodge i-frames (or a future teammate HUD) have something recent to read.
Losing a report changes nothing; the next one supersedes it.

**Food**: `ItemDef` gained a `Consumable` export group — `hunger_restore: float` and `hp_restore:
int`, both zero by default (a food item that doesn't heal, or doesn't fill you up, is valid). No real
food `.tres` is authored here — that is task 3.2's job (hand-authored content), not this task's
framework. `request_consume_item(item_id)` mirrors `request_revive()`'s exact shape: a local request
id immediately, completion via `consume_confirmed(request_id, accepted, detail)`. The host validates
alive + registered + `category == CONSUMABLE`, removes exactly one via
`InventoryService.host_transaction()` (reusing the crafting seam, not reinventing it — a rejected
transaction pays out nothing), then applies `hp_restore`/`hunger_restore` directly.

**A latent class of bug, found and fixed while adding hunger's periodic publish, not introduced by
it**: every `rpc_id(peer_id, ...)` send in this file (`net_health_snapshot`, `net_force_respawn`,
`net_revive_confirmed`, `net_consume_confirmed`) now goes through a new `_peer_connected(peer_id)`
guard before sending. D-035 deliberately keeps a departed peer's state alive through NetSession's
grace window rather than releasing it on `peer_left`, which means a peer id can sit in
`_states`/`_hunger` with no live transport connection behind it at all. The pre-existing RPCs here
only fired on a discrete gameplay event, rare enough that this raced silently; hunger's own ambient
1 Hz publish fires for every tracked peer regardless of any gameplay event, so it hit the grace window
within seconds in `tools/player_vitals_net_check.gd`'s own run (`Attempt to call RPC with unknown peer
ID`). **`autoload/inventory_service.gd`'s `_publish_snapshot` has the identical unguarded
`net_inventory_snapshot.rpc_id(peer_id, ...)` call and is presumed to share the bug** — not fixed here
(out of this task's claim), see F-057.

Checks: `Godot --headless --path . --script tools/player_vitals_check.gd` (offline — stamina hysteresis
and jump/sprint gating proven against a real `player.tscn`, hunger drain and prorated starvation
proven by stepping `_physics_process` directly, consume proven end to end against a synthetic
CONSUMABLE `ItemDef` injected into `Registry.items`) and
`agent godot --script tools/player_vitals_net_check.gd` (two real ENet peers — hunger rides the real
wire alongside hp, a client eats over the real RPC and the host's own inventory/hp/hunger all move,
and the client's stamina reaches the host's advisory copy).

**What is left for the playtest**: `ui/hud/vitals_hud.gd` (new autoload, `VitalsHud`, registered
last) renders three bars bottom-left and an `[G] Eat <item>` hint when the selected hotbar slot holds
a consumable — built in code like `InventoryUI`/`CraftingUI`, no `.tscn`. Eating is bound to the raw
`KEY_G` rather than a new InputMap action, the same choice `InventoryUI` already made for hotbar
slots 1-8, because `project.godot` was held by another lane's task (2.1j) when this shipped. Whether
the numbers (20-minute hunger bar, 4s of sprint, a 15% resume threshold) feel right is 3.11's job, not
this one's.

**Task 2.11 ships the day/night cycle — HOST-authoritative time, replicated at 1 Hz, applied
client-local.** `DayNight` (`systems/environment/day_night.gd`) is an autoload registered last (after
`PlayerHealth`). §2.2's "day/night, wave director, Cycle state, active modifiers" row: HOST. The host
advances `time_of_day` (a **0..1 fraction of a day** — 0 midnight, 0.25 dawn, 0.5 noon, 0.75 dusk;
deliberately NOT the same scale as `playtest_atmosphere.gd`'s own 0..24 hour export) every physics
tick by `delta / day_length_seconds`, and pushes it to clients over an unreliable `@rpc("authority")`,
`net_push_time`, at ~1 Hz (`REPLICATE_INTERVAL_SEC`). **Clients never advance the clock themselves** —
`_advance_client()` only lerps between the last two host snapshots (shortest path across the 1.0->0.0
wrap, `_lerp_wrapped_unit()`, the fractional-day equivalent of `lerp_angle()`) and holds flat at the
last snapshot once `REPLICATE_INTERVAL_SEC` has passed with nothing new — proven by
`day_night_net_check.gd` pausing the HOST's own `set_physics_process` (not disconnecting: a dropped
peer correctly self-promotes to host-of-one via `_owns_mutation()`, which would make "does it free-run"
untestable that way). Offline (no session) is host-of-one through the same `_owns_mutation()` gate
every other autoload in this codebase uses.

**Every peer, host included, applies the value the same way:** `get_tree().current_scene` ->
`get_node_or_null(^"Atmosphere")` -> `call(&"set_time_of_day", time_of_day * 24.0)` — the `* 24.0` is
the one conversion point between DayNight's 0..1 and Atmosphere's 0..24h. No Atmosphere node (a
harness, a menu, a level without one) is a silent no-op, asserted directly in `day_night_check.gd`.
**`day_length_seconds` is read from the level's own `Atmosphere.day_length_seconds` export the moment
one is found** (`_resolve_day_length()`), overwriting DayNight's own matching default (900s) rather
than duplicating it as a second source of truth that could drift from the level's tuned value.

**THE TRAP THIS TASK EXISTS TO AVOID, and it is still avoided:** `playtest_atmosphere.gd`'s
`cycle_enabled` free-runs a local clock per peer from its own boot time with no error if left on. It
is untouched here and stays `false` — DayNight drives the sky by calling `set_time_of_day()` every
tick instead, which is the only path this task adds.

**Thresholds for 2.12 (already shipped and already wired against this exact contract):**
`night_started` at `night_started_at` (0.75) and `day_started` at `day_started_at` (0.25), both
exported/tunable, both **HOST-ONLY by construction** — they fire only from `_advance_host()`, which a
client never calls while connected, so "client never emits a threshold signal" is structural, not a
guard that could be forgotten. Crossing detection (`_crossed()`) is wrap-safe and half-open on the
entry side, so sitting exactly on a threshold across many ticks fires once, not every tick.
`systems/waves/wave_spawner.gd` already subscribes by path (`/root/DayNight`, night_started/
day_started, no args) exactly as built here — no change needed on that side.

**Test-only seam worth knowing about:** `host_advance(delta: float)` is the exact math of the host
branch of `_physics_process`, exposed as a public method so a harness can drive many in-game days in a
fraction of a real second. It is genuinely general-purpose (a future "skip to night" console command
could use it too), not test scaffolding bolted on.

**Protocol version is now 8** (was 7) — the new host->client push, `net_push_time`
(`@rpc("authority", "call_remote", "unreliable")`), needed the bump per the standing rule even though
this task's own `docs/SPECS.md` block didn't list `core/net/net_version.gd` /
`tools/handshake_check.gd` in its claim set (added to the claim directly — see F-056 below).
`tools/handshake_check.gd` asserts the literal value.

Checks: `agent godot --script tools/day_night_check.gd` (offline, manually instantiates the script the
same way `tools/wave_spawner_check.gd` proves `WaveSpawner` before either is an autoload — so this
passes BEFORE registration, matching the task's own required order — 9/9, 0 `ERROR:`) and
`agent godot --script tools/day_night_net_check.gd` (two real ENet processes, run AFTER
`agent autoload DayNight ...` since real replication needs the real autoload on both processes —
13/13, 0 `ERROR:`).

**Task 2.13 ships death & respawn, and crawlers are now lethal.** `PlayerHealth`
(`systems/health/player_health.gd`) is an autoload registered last, after `EnemyWorld` and
`DevLoadout`. Same shape as `InventoryService`: a host-keyed `Dictionary[peer_id, DownedState]`
(`systems/health/downed_state.gd`, a pure `ALIVE -> DOWNED -> DEAD -> ALIVE` state machine with no
node and no peer id, exactly the split `InventoryStore` has from `InventoryService`), an owner-only
reliable snapshot (hp/state/bleed-out), and a broadcast bool everyone receives — teammates have to
see who needs help, not just the downed player's own client. D-035 applies in full: state moves on
`NetSession.run_player_rebound(old, new)` and releases only on `run_player_expired(peer)`;
`_on_peer_left` is the same deliberate no-op `InventoryService` uses, comment included.

**Damage comes IN two ways, both host-only, both landing on `host_apply_damage(peer_id, amount,
instigator_peer_id) -> bool`:** `entities/player/player_controller.gd` now joins `&"damageable"`
(same seam `Harvestable` and `Enemy` already use) and forwards CombatService's call here keyed by
`get_multiplayer_authority()`; and `PlayerHealth` is the subscriber `EventBus.enemy_attack_landed`
was built for in 2.10 — `EventBus.enemy_attack_landed_subscriber_count()` is how the wiring proves
itself rather than being trusted. Returns false while downed or dead (no corpse-kicking in M2) or for
an unknown peer, so `CombatService` reads it as a miss, never a phantom hit.

**Downed presentation is client-local, read off two query methods:** `local_is_downed()` and
`local_is_dead()` gate `player_controller.gd`'s own input — crawl speed instead of walk/sprint, jump
and attack blocked outright while downed, ALL movement input blocked while dead (mid-respawn). A
teammate holds `interact` near a downed player; the hold itself is client-side prediction exactly
like D-034 splits combat's wind-up from its hit — `player_controller.gd` tracks the hold locally and
fires exactly one `PlayerHealth.request_revive(target_peer)` the instant its timer reaches
`PlayerHealth.revive_seconds`, and the HOST is what actually decides: `net_request_revive` re-checks
both peers' states and re-measures the distance itself, never trusting the client's hold duration or
a client-supplied position. A downed player respawns at the transform `PlayerNet.player_spawned`
handed `PlayerHealth` when they first joined (own player movement is CLIENT authority per §2.2, so
the host cannot just write another peer's position — `net_force_respawn` tells that peer's own client
to place itself, the same as it is the only thing ever allowed to move its own body).

**Protocol version is now 7** (was 6) — the hello gained no new argument this time, but three new
RPCs did: `net_request_revive`, `net_health_snapshot`, `net_downed_flag`, plus `net_force_respawn`.
`tools/handshake_check.gd` asserts the literal value now, on purpose, so the next wire-shape change
that forgets the bump fails loudly instead of quietly.

**F-043 decided: the iron sword stays OUT of `DevLoadout.loadout`** — see FINDINGS.md's Resolved
section for why (the hotbar is already full at 8/8, and its `WeaponDef` numbers are still 2.9's
unpassed placeholders). `give iron_sword` still reaches it.

Checks: `Godot --headless --path . --script tools/player_health_check.gd` (offline — a real
`player.tscn` instance proves the `&"damageable"` wiring end to end, then bare host-state peers drive
the downed/bleed-out/death/respawn state machine and every revive rejection rule) and
`agent godot --script tools/player_health_net_check.gd` (two real ENet peers — the host downs
*itself* so the interesting proof is a DIFFERENT peer learning about it over the broadcast; a
self-targeted revive is rejected; an out-of-range revive is rejected using the host's own copy of
both positions; a non-lethal hit survives a live disconnect+reconnect under a new peer id, proving
D-035's rebind rather than a reset).

**What is left for the playtest:** no HUD reads any of this yet — `local_health_changed` and
`downed_flag_changed` are ready for 6.x's HUD to consume, but today the only feedback a downed player
gets is the crawl and the blocked input. The revive hold has no progress indicator either. Both are
presentation gaps, not authority gaps — the host-side contract above does not change under them.

**Items now have icons, and `ItemDef.icon` is populated.** `assets/icons/exports/icon_<id>.png` holds
26 transparent 256×256 icons — every A-002 pickup, every A-004 tool/weapon, A-021S's iron sword, and
(F-061) the coin pouch backing `coins.tres` — where `<id>` matches `ItemDef.id`. **All 16 item `.tres`
files carry their icon**; a new item wires its icon by setting `icon` on its `.tres`. Icons are
renders of the shipped GLBs, not drawings (D-033), so a model
change is followed by re-running `tools/blender/render_item_icons.py`, never by editing a PNG. Adding
an icon for a new asset family means appending to `SOURCES` in that script, not starting a second
pipeline. `assets/icons/catalog.json` records each icon's source GLB and framing;
`tools/item_icons_check.gd` is the headless proof that they import and that every `ItemDef` carries
one.

**The A-004 tool and weapon exports were rebuilt (A-004R) and every mesh in them changed.** File names,
the ten design names, and the world/viewmodel pairing are unchanged, and dimensions moved by at most
about 6 cm, so anything referencing these GLBs keeps working — but a scene that was tuned against the
old silhouettes is worth re-checking. `tools/blender/build_tool_weapon_set.py` gained two reusable
builders worth knowing about before hand-modelling anything similar: `ground_profile()` (a silhouette
outline with per-point bevel *distances*, which is how a head gets a square poll and a ground edge)
and `swept_shaft()` (a tube along a polyline with a radius per point, which is how hafts get taper and
an oval section).

**You now start with gear, and the world has crawlers in it.** Both were missing when Sequoyah first
pressed Play, and both were wiring rather than logic — `EnemyWorld.host_spawn()` worked and nothing
called it; the nest marker existed and nothing read it.

`DevLoadout` (`core/dev/dev_loadout.gd`, autoload, registered last) grants a starting kit through
`InventoryService.host_add()` — a host seam with no client RPC, so a client cannot ask for one. It
hangs off `PlayerNet.player_spawned` (F-018) and, offline, off a `current_scene` gate. **That gate is
load-bearing: a `--script` harness is its own main loop and has no `current_scene`, and without it
every headless check in `tools/` boots with a full inventory** — four of them failed the moment this
autoload existed, correctly. Entries marked `hotbar: true` are moved onto the bar, because 2.4 fills
backpack slots first and a grant without that leaves you unable to swing without opening Tab.
`enabled = false` turns the whole thing off when task 3.x decides what a real run starts with.

`EnemyWorld` gained **ambient spawning** — `ambient_enabled`, `ambient_population` (4),
`ambient_respawn_seconds`, spawning at every level marker whose `kind` meta is `enemy_spawn`. **This
is not task 2.12**: no day/night gate, no Cycle scaling, no despawn at dawn. 2.12 is expected to set
`ambient_enabled = false` and drive `top_up_ambient()` / `host_despawn_all()` itself. It also
bootstraps offline: pressing Play opens no session, so nothing called `bake_navigation()` either —
now a short delay after boot bakes the level's navmesh (2,529 polygons in Playtest Hollow) and fills
the field.

Console commands — every mutating one host-only; `items` and `enemies` are read-only and answer on
any peer: `give <item_id> [count]`, `loadout`, `items`, `spawn [enemy_id]
[count]`, `killall`, `enemies`. Check: `tools/dev_loadout_check.gd`, which loads the **real main
scene** rather than a bare tree — a bare tree would have passed throughout both of these bugs.

**Content warning, in the AGENTS.md sense.** `tools/setup_tool_content.gd` bulk-generated nine
ItemDefs and seven WeaponDefs from `assets/tools_weapons/catalog.json`, which is the thing agents are
told not to do. It was done because Sequoyah asked for one of each tool and nine of the ten designs
had no ItemDef, so there was nothing to grant. **The weapon numbers are derived from one rule —
heavier swings slower, hits harder, reaches further — not tuned.** They exist so the ten weapons
differ in a way 2.9 can feel and argue with. Retune in the inspector; re-running that script
overwrites them.

**Task 2.9 is a gate, and only Sequoyah can pass it.** `ROADMAP.md` says *tune combat feel until one
enemy with one weapon feels great; do not proceed otherwise*, and no agent can judge that. What 2.9
shipped is everything that makes the judgement possible, plus the instrument to argue about numbers
instead of adjectives:

`Godot --headless --path . --script tools/combat_feel_check.gd` prints the whole picture and asserts
the *relationships* between authored values — never whether a value is fun. Current reading:

```
time-to-kill 4 swings, 2.72 s of swinging
reaction     0.28 s of the 0.40 s tell is thinking time; 0.50 m of retreat costs 0.12 s
worst case   standing at contact needs 0.50 s to clear 2.00 m — sprint or trade, do not walk
retreat      walking loses 0.40 m/s; sprinting gains 1.60 m/s
```

**The one tuning call that is a design decision, not a number: the crawler moves at 4.4 m/s, faster
than the 4.0 m/s walk and slower than the 6.0 m/s sprint.** At 2.10's original 3.4 a player could
walk backwards forever and never be caught — which is exactly the "backpedal spam" `DESIGN.md` §6
names as the thing to fix, and it makes the 0.4 s telegraph decorative. Now retreating costs 0.4 m/s
per second, sprinting still disengages, and standing your ground is sometimes correct.

2.9 also filled two feedback gaps 2.10 left. An enemy now **reacts** to being hit: a replicated
`hit_counter` (a counter, not a flag — a flag can go true and false between two snapshots and be
missed) drives A-006's `hit` clip plus a 0.12 s white overlay, so a connect is visible even when the
clip is masked by a committed attack. And a corpse **sinks and fades** over `corpse_seconds` instead
of blinking out, which is the "ragdoll or dissolve" 2.10's line asked for, done as geometry rather
than as a shader on an imported GLB.

**What is left for the playtest**, in the order it will matter: does the 0.4 s tell read at all in
first person; does the axe's 100° arc make hitting a moving crawler feel generous or sloppy; is
0.075 s of hitstop an impact or a hitch; and does 4 swings per crawler stay right when there are
three of them. **There is still no authored impact sound** — the thud is 2.8's code-built
placeholder, and it is the single biggest remaining gap in "loud, satisfying impact".

**Task 2.10 ships Enemy v1, and 2.12's wave spawner drives it through `EnemyWorld`.** `EnemyWorld`
is an autoload registered after `CombatService` (later autoloads have since followed it — the
[autoload] section of `project.godot` is the truth, not any "last" claim here). It loads `content/enemies/*.tres` into
`get_def(id)` / `has_def(id)`, owns the code-built `MultiplayerSpawner` (D-023), and exposes the
host-only seams task 2.12 needs: `host_spawn(def_id, position) -> Node3D`, `host_despawn_all()`,
`live_enemies()`, `live_count()`, and the signals `enemy_spawned(enemy)` and
`enemy_died(enemy_id, instigator_peer_id, position)`. **There is no client spawn RPC and there must
not be one.**

`Enemy` (`systems/enemies/enemy.gd`) is a `CharacterBody3D` whose every decision is the host's:
target choice, pathing, turning, when the swing lands, health and death. Its state machine is
`IDLE → CHASE → TELL → ATTACK → RECOVER`, plus `DEAD`, replicated as an int alongside position, yaw
and health. Three behaviours are deliberate and worth not "fixing":

- **The hit resolves at the END of the tell, against where the target is then.** That is what makes
  backing out of a telegraphed swing work, and it is the entire point of DESIGN.md §6's 0.4 s.
- **Damage does not interrupt a committed attack.** An enemy whose swing any chip of damage cancels
  cannot threaten a group.
- **Aggro has hysteresis** — `aggro_radius_m` to acquire, the wider `deaggro_radius_m` to drop —
  because one radius makes a target on the boundary flicker every tick.

Enemies join `&"damageable"` and implement `host_apply_damage()`, so **2.8's `CombatService` needed
no change to make them hittable**. Damage going the other way is `EventBus.emit_enemy_attack_landed(
enemy_id, peer_id, damage, world_position)` — player health does not exist yet, and **task 2.13 owns
what an enemy hit costs**; subscribe rather than adding a health field to the player.

Two things to know before building on it. **Navigation is baked once per session from the level's
static collision** by `EnemyWorld.bake_navigation()`, and `nav_polygon_count()` reports the result;
if it bakes zero polygons the enemy steers straight at its target instead of freezing, which is the
right failure but is *not* pathing — check that number before blaming the AI. And the enemy's
synchronizer is deliberately named `NetConfig.PLAYER_SYNC_NODE`, so **`NetInterp` smooths enemies
with no change (F-004)**.

Content is one authored `content/enemies/crawler.tres` over A-006's model. **Its `attack_tell_seconds`
and `attack_seconds` are both 0.4 because the authored clips are** — changing either without
re-authoring the clip desynchronises the telegraph from the hit. Checks:
`tools/enemy_check.gd` (44 assertions, steps the state machine directly rather than sleeping) and
`tools/enemy_net_check.gd` (two real ENet processes; its interesting assertions are the negative
ones — the client's copy runs no physics).

**Run-player identity is how host-owned state survives a reconnect (F-032, D-035).** An ENet client
that rejoins gets a **new peer id**, so a system that keys state by peer id sees one player leave and
a different one arrive. `NetSession` now mints an opaque token per run-player on the client hello,
hands each client only its own, and exposes two signals:

| Signal | Meaning |
|---|---|
| `run_player_rebound(old_peer_id, new_peer_id)` | Same player, new id. **Move** whatever you keyed under the old one; it is gone when this returns. |
| `run_player_expired(peer_id)` | Not coming back — its 90 s grace ran out. **Release** its state now. |

**The rule every host-owned system must follow: do NOT release peer-keyed state on `peer_left`.**
Between a drop and a rejoin the player is still a player, and `peer_left` cannot tell the two apart.
`InventoryService` is the worked example — its `_on_peer_left()` is deliberately a no-op with a
comment saying why. Health, powerups, Attunement and any peer-keyed enemy aggro inherit this by
connecting to the same two signals.

Also on `NetSession`: `run_token()` (this peer's own token, harnesses only) and
`orphaned_run_players()` (how many are parked). The registry itself is `core/net/run_identity.gd` —
pure data, no node, testable without a session. **Protocol version is now 6**: the hello gained an
argument. Checks: `tools/run_identity_check.gd` for the rules,
`tools/session_lifecycle_check.gd` for the real multi-process reconnect.

**Four standing rules, promoted out of `FINDINGS.md` so they are read before they are rediscovered.**
F-011, F-012, F-016 and F-021 were closed on 2026-08-16 not because the engine changed but because a
permanent rule does not belong on a board of unscheduled problems.

1. **A gameplay script that a harness can reach must never name an autoload as a bare identifier**
   (F-011). A `--script` main loop is compiled *before* autoloads are registered, and it compiles the
   scripts it depends on in the same pass — so the restriction reaches any script pulled in through a
   `class_name`. Use `get_node_or_null(^"/root/Thing")` and `call(&"method")`. This is not
   theoretical: 2.8 put `CombatService.request_attack()` in `player_controller.gd`, which
   `verify_setup.gd` reaches through `PlayerController`, and silently broke that harness *and*
   `interp_check.gd` — the latter reporting what looked like a netcode defect.
2. **A new `class_name` is not resolvable bare in a headless run either** (F-016) — the global class
   cache is only rebuilt by an editor scan. `const Thing = preload("res://path/thing.gd")` works
   before and after the cache catches up.
3. **Set `set_multiplayer_authority()` on a synchronizer BEFORE `add_child()`** (F-012, D-023).
   Setting it once the node is in the tree makes the replication interface reject the pending spawn on
   every client, and the symptom is error spam plus silently degraded state, not a clean failure.
4. **Grep every check run for engine errors** — `… 2>&1 | grep -c 'ERROR:'` — and treat any
   UNDECLARED error line as a failure (F-021). GDScript has no supported hook to fail a harness on
   engine-level `push_error`, so a green exit code alone is not evidence: `net_debug_panel_check`
   passed 19 assertions for weeks on top of a stream of `Multiplayer root was not initialized`.
   One refinement (F-052): a check that deliberately provokes error paths declares them by PATTERN
   in its verdict line — `EXPECTED_ERROR_PATTERNS="pat1|pat2"` — because provoked-error counts vary
   with timing (a slow run logs an extra rejoin timeout). Grade with
   `grep 'ERROR:' | grep -vE '<declared>' | wc -l` → 0. Today only `session_lifecycle_check` and
   `connect_retry_check` declare (the refusals and timeouts they exist to test, which production
   code correctly reports via `MireLog.error`).

**Task 2.8 ships melee combat v1 — and 2.9 tunes it in the inspector, not in code.** `CombatService`
is an autoload late in the load order. The split is D-034: the swing is client-predicted, the hit is host.
`request_attack()` starts the local wind-up on the press and returns a request id; the client sends
only its hotbar slot index, and the host reads its *own* `InventoryService.host_slots(peer_id)` for
that slot to decide the weapon, uses the yaw/pitch the player synchronizer already replicates for
aim, runs its own swing clock, and resolves the hitbox at the end of the wind-up.

Read/observe seams: `local_phase()` → `CombatService.Phase.{IDLE, WIND_UP, COMMIT, RECOVERY}`,
`local_swing_progress()`, `local_hitstop_remaining()`, `host_swing_active(peer_id)`,
`weapon_for_hotbar_index(i)`, and the signals `swing_started(weapon_id)`,
`swing_phase_changed(phase)`, `attack_landed(peer_id, position, damage, target_name)`,
`attack_missed(peer_id)`, `attack_rejected(request_id, detail)`. A swing cannot be cancelled or
recut: `request_attack()` returns -1 while one is running and the host separately rejects a second
request with *previous swing has not recovered*.

**The melee target seam is the group `&"damageable"` plus
`host_apply_damage(amount: int, instigator_peer_id: int) -> bool`.** Harvestable joins it and already
had that exact method; **task 2.10's enemies join the same group and `CombatService` needs no
change**. Returning false is a miss, not a phantom hit. Targeting is a horizontal arc
(`arc_degrees`) with a separate vertical band (`vertical_reach_m`) rather than a shapecast, so a prop
whose mesh origin sits on the ground is hit by a level swing.

Weapons are content: `WeaponDef` (`systems/combat/weapon_def.gd`) is a `.tres` in `content/weapons/`
**keyed by the `ItemDef.id` it belongs to**, loaded by `Registry` into `get_weapon(item_id)` /
`has_weapon(item_id)`. `content/weapons/stone_axe.tres` is the one authored weapon; an item with no
WeaponDef swings `CombatService.unarmed`, which is built in code so an empty hand is never an
authoring job. **Task 2.9 tunes `stone_axe.tres` and the `@export`s on `player_camera.gd` in the
inspector — do not re-run `tools/setup_combat_content.gd` after that, it overwrites the resource.**
Impact audio falls back to a code-built placeholder thud (seeded, deterministic) so 2.9 has something
audible before any audio asset exists; assigning `WeaponDef.impact_sound` replaces it with no code
change. **There is still no authored impact sound in the repo** — that is Sequoyah's, and it is the
one part of 2.8's "impact SFX" that is a placeholder rather than final.

Checks: `Godot --headless --path . --script tools/combat_check.gd` (offline, ~40 s — it waits out
real swing timings, so do not assume a 15 s timeout is enough) and
`tools/combat_net_check.gd` (two real ENet processes). Three traps they cost: a harness target must
`add_to_group(&"damageable")` or every swing correctly finds nothing; `node.get("method_name")`
returns **null** — `get()` resolves properties and signals, so an RPC driven from a harness needs
`Callable(node, "method").rpc_id(...)`; and these net harnesses spawn players into an empty root with
no floor, so the player falls continuously and a fixed-position target drifts out of reach between
swings.

**Task 2.7 ships the client-local crafting presentation.** `CraftingUI` is an autoload ordered
after `CraftingService`. It is opened by the `interact` action (E) and only while
`CraftingService.local_station_in_range(&"workbench")` is true; `interact` again, Escape, or walking
out of range closes it. An "E USE WORKBENCH" prompt sits above the hotbar whenever a workbench is in
range and no cursor UI is open. Rows are built once from `recipes_for_station(&"workbench")`, and each
renders `have/need` per ingredient straight off the authoritative snapshot — `2/2 Log · 3/3 Stone` —
plus READY / MISSING MATERIALS / OUT OF RANGE. The craft button is a hint, not a gate: pressing it
sends `request_craft()`, shows *Waiting for the host…*, and the panel then displays the host's
`craft_confirmed` detail verbatim. Nothing is predicted; requirement counts change only when the next
authoritative snapshot arrives.

The seams a later UI should reuse: `is_open()`, `set_open(open)`, `try_open_station()` (returns
whether it actually opened, so the caller knows if the input was consumed), `poll_station()`,
`is_station_in_range()`, `is_prompt_visible()`, `recipe_row_count()`, `displayed_recipe_id(i)`,
`is_recipe_craftable(i)`, `craft_button_disabled(i)`, `recipe_requirement_text(i)`,
`request_craft_at(i)`, and `status_text()`. `request_craft_at()` presses the real button, so a harness
exercises the shipped path. Two traps this cost: a **local** host answers *inside* `request_craft()`,
before the request id exists to compare against — hence the in-flight flag rather than an id check
(a naive id comparison silently overwrites the answer with "Waiting…"); and **GDScript lambdas capture
locals by value**, so an `_until()` poll must never assign to an outer variable it also wants to read.
The focused check is `Godot --headless --path . --script tools/crafting_ui_check.gd`; the rendered
proof at both widths is `Godot --path . --script tools/crafting_ui_render_check.gd`; the client-side
waiting/confirmed states are proven over real ENet by the extended `tools/crafting_net_check.gd`.

**Task 2.6 ships host-authoritative workbench crafting.** `CraftingService` is an autoload ordered
after `InventoryService` and exposes `recipes_for_station(station)`,
`local_recipe_status(recipe_id)`, `local_station_in_range(station)`, and
`request_craft(recipe_id)`. The first three are presentation helpers only. A request carries only a
recipe id and local request id; the host derives the sending peer, looks up that peer's authoritative
`PlayerNet` player, requires it within 3.25 m of the mapped `station_workbench_primitive`, revalidates
the registered `RecipeDef`, and commits through `InventoryService.host_transaction()`. The
`craft_confirmed(request_id, accepted, detail)` signal is the UI's accepted/rejected feedback seam;
clients do not predict inventory changes.

The one authored vertical-slice recipe is `stone_axe`: two `log` plus three `stone` produce one
non-stackable Stone Axe at `&"workbench"`. Bulk recipes remain task 3.2. The focused offline proof is
`Godot --headless --path . --script tools/crafting_check.gd`; the real two-process ownership/RPC proof
is `agent godot --script tools/crafting_net_check.gd`. The new RPCs made the protocol version 5 at
the time; later additions have moved it on — `core/net/net_version.gd` is the single source of
truth (6 as of F-032's hello argument).

**Task 2.5 ships the client-local inventory presentation.** `InventoryUI` is an autoload ordered after
`InventoryService`. The hotbar always renders its own stable slots 24–31; Tab opens the separate
24-slot field pack at slots 0–23, and Escape or Tab closes it. Drag/drop sends a full-stack
`request_move_stack()` and renders only the
next authoritative snapshot — there is no optimistic mutation. `operation_confirmed` supplies the
accepted/rejected status line. Number keys 1–8 and clicking a hotbar cell change the local highlight;
held-item behavior is deliberately not invented before its gameplay system exists. Item icons render
when an `ItemDef.icon` exists, with compact names as the current content fallback.

Opening the inventory makes the cursor visible and joins `&"blocks_gameplay_input"`; the local player
gates movement and jump while any UI owns that group. This does not pause the tree, so a network client
continues processing. Closing removes the blocker and restores prior mouse capture. The focused check
is `Godot --headless --path . --script tools/inventory_ui_check.gd`; the rendered desktop and narrow
proof is `Godot --path . --script tools/inventory_ui_render_check.gd`.

**Task 2.4 ships the host-owned inventory seam that 2.5 and 2.6 build against.** `InventoryService`
is an autoload after `Registry`, with one 32-slot `InventoryStore` per peer: backpack slots 0–23 and
separate hotbar slots 24–31. New grants use backpack empties before hotbar overflow, and removals use
backpack stacks before equipped hotbar stacks. Slots are stable dictionaries shaped as
`{"item_id": StringName, "amount": int}`; empty slots are `{}`. UI reads `local_slots()` and
`local_revision()`, listens to `local_inventory_changed(slots, revision)`, and sends drag/drop through
`request_move_stack(from_index, to_index, amount = 0)`. Destructive requests return a request id and
finish through `operation_confirmed(request_id, accepted, detail)`. Callers never mutate returned
snapshots.

Only trusted host systems can grant items: `host_add(peer_id, item_id, amount)` is all-or-nothing,
and no client add RPC exists. Harvest yields are already subscribed and grant the yielded item to the
validated instigator peer. Crafting should use
`host_transaction(peer_id, removals: Dictionary, additions: Dictionary)`, which rolls back the exact
slot layout unless every removal and addition fits. `host_count`, `host_can_add`, `host_can_remove`,
`host_remove`, and `host_slots` are host-only seams. Owner-only reliable snapshots carry full stable
slots plus a monotonic revision; a client request carries no peer id, so the host always derives the
inventory owner from `multiplayer.get_remote_sender_id()`. The 32-slot snapshot introduced protocol
version 4; later RPC additions moved it on — `core/net/net_version.gd` is the single source of
truth. Inventories are keyed by transport peer id but are **NOT released on `peer_left`** — F-032
is fixed (D-035): `_on_peer_left` is a deliberate no-op, state moves on
`NetSession.run_player_rebound(old, new)` and is released only on `run_player_expired(peer)`. Any
system that copies the old released-on-peer_left behaviour reintroduces the bug F-032 describes.

**Asset batches A-001 through A-008 plus A-004R, A-042a and A-021S are complete; A-009 is next.**
Harvest states live under `assets/harvestables/` (12 GLBs), basic pickups under `assets/pickups/`
(14 GLBs), the eight vertical-slice stations under `assets/crafting_stations/`, and eleven
tool/weapon designs under `assets/tools_weapons/` as 22 paired `*_world` and `*_viewmodel` exports.
Each family has its own
catalog, previews, editable source, and deterministic generator. Pickups, stations, and tools are
horizontally centred and ground-origin normalized. The paired tool exports deliberately share
geometry and materials so Godot scenes can tune world and first-person transforms without silhouette
drift. None contain collision or authority: harvest mutation, pickup grants, station placement/use,
crafting validation, fuel, repairs, attacks, hits, and inventory changes remain host-owned. Static
fire meshes are cosmetic placeholders for later client-local VFX. A-005 added ten loot meshes under
`assets/loot/`, A-006 the first rigged family under `assets/enemies/`, A-007 eight Ward condition and
support meshes under `assets/wards/`, and A-008 twelve Wellspring landmark, modular, condition,
ritual, boundary and arena meshes under `assets/wellsprings/`. The Ward condition meshes share the
exact same 2.48 m foundation bounds with 0.00 mm centre/size drift; author collision from
`ward_foundation.glb` and do not expand it around damaged debris. The four Wellspring condition
meshes likewise share the exact 4.6 m foundation with 0.00 mm centre/size drift; author collision
from `wellspring_base.glb`, not roots or state-specific crystals. The distant monolith is 7.245 m
tall. Wellspring meshes contain no objective, ritual, corruption, reward, guardian or network
authority; the host owns those states. Sequoyah's supplied tree and rock were adapted separately
under `assets/environment_additions/` rather than counted in A-007. The next asset run takes the
single `NEXT` row in `docs/ASSET_TRACKER.md` — currently A-009, the extraction ship set — and should
use a separate generator per family.

**A-021S added the iron sword, and the tool/weapon generator gained a primitive for it.**
`lofted(name, rings, mat, apex)` in `tools/blender/build_tool_weapon_set.py` builds a solid through
explicit cross-sections and optionally closes it on a point. Reach for it instead of
`ground_profile()` whenever a shape is much longer than it is wide: a ground profile insets its walls
toward the profile's *centroid*, so on a metre-long blade the pull near the point is almost entirely
downward and leaves a square wall where the edge should be. The sword is the set's only design that
spends real budget — 421 polygons / 1,000 triangles against 114–348 for the ten tools.

A-021S is also the first batch to author its own content resources under D-031:
`content/items/iron_sword.tres` and `content/weapons/iron_sword.tres`, written while a parallel
session held the other nine item `.tres` files. The boundary that made that safe was claiming the two
files by exact path, not by directory. The `WeaponDef` numbers (0.19 / 0.11 / 0.26 s, 2.9 m, 95°,
6 damage) are placeholders chosen to sit between the cleaver and the axe — **task 2.9 owns them** and
its gate is unpassed. `ItemDef.grip_scale` is 0.32 rather than the axes' 0.55 because the sword is
1.72 m tall and at 0.55 its blade leaves the top of the screen; per-item grip data exists for exactly
this. F-043 records that nothing puts the sword in a player's hand: it is not in
`core/dev/dev_loadout.gd`, so only `give iron_sword` reaches it.

**Environmental animation is automatic in `playtest_hollow`.** `world/gen/playtest_hollow.gd`
creates the client-local `EnvironmentVfx` controller. It discovers grass, fern, reed and sedge mesh
parts in the authored GLB and applies the shared height-masked wind shader; new placements inherit
motion without material wiring. It also replaces authored outer/furnace flame placeholders with
procedural flame, spark and smoke particles plus a flickering local light. None of this carries
gameplay state or network authority. Verify with
`Godot --headless --path . --script tools/environment_vfx_check.gd` and visually tune the constants
in `autoload/environment_vfx.gd` or `world/environment/foliage_wind.gdshader`.

**A-006 is the first rig, and combat code needs three facts from it.** `assets/enemies/exports/`
holds `enemy_crawler.glb` (skinned, 17 bones, 6 clips) plus static `enemy_crawler_nest`,
`enemy_crawler_fragment_shell` and `enemy_crawler_fragment_leg`.

1. **Ask the `AnimationPlayer` for `idle`, `locomotion`, `attack_tell`, `attack`, `hit`, `death`.**
   The GLB names the first two `idle-loop` and `locomotion-loop`; Godot 4 reads that suffix as
   "loop this clip" and then strips it. The exported name will not resolve at runtime.
2. **`attack_tell` (0.4 s) and `attack` (0.4 s) chain.** The attack's first frame is the tell's last,
   so they play back to back without a pop, and the tell can be held or cancelled on its own. The
   0.4 s tell is `docs/DESIGN.md` §6's readable-telegraph target, not an arbitrary length.
3. **`death` (1.0 s) ends settled and flat**, so a corpse mesh, ragdoll or fragment burst can take
   over from its final pose.

The crawler is 1.10 m long, 0.59 m tall, origin at the ground between its feet, facing -Z. It carries
no collision, health, AI, aggro, or authority; spawning, targeting, attack timing, hit registration
and death stay host-authoritative. Rebuild with Blender 5.2 via `tools/blender/build_enemy_crawler.py`;
verify with `Godot --headless --path . --script tools/enemy_crawler_check.gd`, which asserts the
skeleton, the skin, all six clip names and exactly which two loop.

**Blender generator naming trap:** never put raw float values in object or datablock names. Blender
5.2 treats the text after the last `.` as a numeric duplicate suffix; a coordinate such as
`.30600000000000005` aborts background Blender in libc++ with `stoi: out of range`. Use integer
indices in procedural names.

**The Hollow is the only map, as of 2.1j.** `playtest_map` was removed at Sequoyah's request —
generator, source, GLB, preview, scene, check, and the `TestMapProps` autoload that loaded it.
`levels/playtest_hollow.tscn` is `main_scene`. Its editable source is
`assets/source/playtest_hollow.blend`, exported as `assets/maps/playtest_hollow.glb`, and both it and
the Godot collision are generated from one frozen layout at
`world/gen/layouts/playtest_hollow.json`. The open ground is a heightfield in that layout:
`build_playtest_hollow.py` meshes it flat-shaded, `world/gen/playtest_hollow.gd` builds a collider
from the same triangles. Rebuild with Blender 5.2 via
`tools/blender/build_playtest_hollow.py`; verify with
`.agent/bin/agent godot --script tools/playtest_hollow_check.gd`.

**`playtest_hollow` is the playtest level, and it is now the project's main scene.** Its **88 × 88 m**
layout — **783 prop placements and 33 terrain records**, of which 20 collide — lives in the single
deterministic `world/gen/layouts/playtest_hollow.json`. Blender consumes that file to produce
`assets/source/playtest_hollow.blend`, the **6,256-mesh** `assets/maps/playtest_hollow.glb`, and its
preview; `world/gen/playtest_hollow.gd` consumes the same records to build **359 terrain and prop
collision shapes**. The scene has six zones, a camp with two swung-open gate leaves and four verified
1.8 m-clear egress routes, clear roads, a lowered Mire basin, two ridge terraces, five traversable
ramps, a closed boundary, loot/pickup/tool placements, and the crawler nest marker.

*(F-031: this paragraph described the superseded 2.1f layout — 463 props, 4,102 meshes, 68 × 68 m —
long after 2.1h replaced it, so tasks were planning against a map that no longer existed. The figures
above are `tools/playtest_hollow_check.gd`'s own output, re-run 2026-08-16:
`zones=6 props=783 terrain=20 colliders=359 visuals=6256 failures=0`. Re-read them from that check
rather than editing this paragraph by hand.)* Rebuild with `tools/mapgen/hollow_layout.py` then
`tools/blender/build_playtest_hollow.py`; verify with `tools/playtest_hollow_check.gd`. Static map
collision remains client-local; harvesting, inventory, loot, enemies, damage, and mutation remain
host-authoritative. `world/environment/playtest_atmosphere.gd` controls its physical sky, sun, and
localized volumetric light shafts; `world/environment/low_poly_clouds.gd` builds deterministic,
faceted mesh-cloud clusters that drift locally. Blanket fog is disabled; the only readable fog
volumes are Mire haze, forest-floor mist, and a thin ruins layer. The optional local clock
defaults off; task 2.11 must drive `set_time_of_day()` from replicated host time rather than letting
peers advance it independently.

**1.5, 1.9 and 1.10 shipped earlier** (`8d6ddab`, `ef1bc16`, `4f17bcd`), and 1.10 is now actually
*wired* (`9f56451`). **1.6, 1.7, 1.8 and 1.11 are now implemented and headlessly verified** — read
the table and the per-task sections below rather than assuming a clean slate. The only remaining M1
task is 1.12, whose three-machine Steam transport has now worked but whose formal evidence run is
still incomplete.

**Task 1.12 live state (2026-08-16):** all three `tools/steam_check.gd` preflights passed on stock
Godot `4.7.1.stable.official.a13da4feb`, GodotSteam 4.21 and App ID 480. The accounts are macOS
`TheQuoy`, Windows `quoygeber`, and Linux `sequoyahgeber`, and they are mutual friends. The Windows
current test checkout is `C:\MIRE-main` with Godot at `C:\Tools\Godot\Godot_v4.7.1-stable_win64.exe`;
the stale `C:\MIRE` copy still predates D-029 and must not be used. The Linux
checkout is `/home/ubuntu/mire-task-1.12` with Godot at `/home/ubuntu/.local/bin/godot-4.7.1`.
Windows Steam IPC is unavailable to an OpenSSH service session, so launch Steam checks and the game
in the signed-in interactive console session (an interactive scheduled task is suitable).

A Mac-hosted lobby reached three peers and displayed all three spawned players after
`player_controller.gd` gained code-built coloured remote debug capsules and `players` group
registration. Linux movement visibly replicated on the Mac host. Windows first join remains flaky:
it twice hit `connect to steam:<lobby_id> timed out after 10.0s`, then connected on an immediate
retry to the same lobby; one of those first-attempt failures occurred with Windows Firewall already
fully disabled, so F-023 tracks the brittle timeout independently of firewall configuration.
Windows Firewall was restored and verified enabled on all three profiles before a later two-platform
rerun. That rerun used a fresh `origin/main` archive at `C:\MIRE-main`: Windows peer `579922246`
joined a Mac-hosted lobby, showed `STEAM client`, peers `[1, 579922246]`, and two players in F3, and
the host despawned it on exit. The old checkout's 10-second timeout was retained as failure evidence;
the fresh checkout used D-029's 20-second budget. Remaining 1.12 work is a fresh run on
the shipped revision with the firewall enabled, 60 seconds of movement by every player, one F3
screenshot and complete log per platform, then clients exiting before the host.
The retained evidence logs are in `/Users/sequoyahgeber/Desktop/MIRETestLogs`; the final diagnostic
run ended host-first, so both client logs correctly record `CONNECTION_LOST` and are not pass evidence.

**F-023's mechanism is fixed as of 2026-08-16 (vane, D-029) — 1.12's rerun inherits new behaviour and
one job.** A Steam client no longer gets one 10 s attempt and a dead end:

| API | What it is |
|---|---|
| `NetConfig.STEAM_CONNECT_TIMEOUT_SEC` | Steam's own connect budget, **provisionally 20 s**, separate from ENet's `CONNECT_TIMEOUT_SEC` |
| `NetTransport.connect_timeout_sec(mode)` | static; the budget for a mode. Anything that waits on a connect must derive its own deadline from this, never hard-code one |
| `NetTransport.EndKind.CONNECT_TIMEOUT` | split from `CONNECT_FAILED`. A refusal is an answer; a timeout is the absence of one, and only the second is retried |
| `NetTransport.last_connect_msec()` | how long the last successful join took, or -1. Also logged as `connected … in N.NNs` |
| `NetSession.connect_retry_attempted(attempt, of)` | a first join is being retried. **Not** `rejoin_attempted` — nothing has been lost yet, so a UI must not say "Reconnecting…" |
| `NetSession.connect_failed(detail)` | the first join gave up. `session_ended` does not fire; there was never a session |
| `NetSession.is_connect_retrying()` / `auto_connect_retry` | state, and the off switch for probes |

Retries are **STEAM-only** and that is load-bearing: a timed-out attempt tears down without announcing,
so SteamLobby never leaves the lobby and the retry is a plain `join()`. That is why this is not F-020,
which is the rejoin-*after-drop* case where the lobby genuinely was left. LOCAL/LAN first joins are
still DevLaunch's — F-024 records the gap that leaves in a shipped LAN join.

**The one job 1.12's rerun inherits:** every join now prints its own duration, so the run produces the
first-join latency nobody has ever measured. Collect the `connected … in N.NNs` line from all three
platforms, then set `STEAM_CONNECT_TIMEOUT_SEC` from the observed tail — 20 s is an allowance, not
evidence. A Windows timeout that the automatic retry recovers is the fix working, and is still not a
clean PASS. Verify the mechanism first with
`Godot --headless --path . --script tools/connect_retry_check.gd` (PASS, 0 failures on macOS).

**Three open findings were closed this session, all of them process rather than game code:** F-013
(the `&"synced"` convention, D-024 — 1.8 inherits it), F-015 (an F-number is a task id, so a finding
is startable exactly like a roadmap task), and F-007 (agents name themselves from their chat; no
`MIRE_AGENT`, no prefix, commits included). Practical effect on starting work: *"start 1.6"* and
*"fix F-004"* are now the same shape of instruction, and neither needs a name attached.

**Reading the table.** *Agent name* `auto` means the chat names itself on `agent start` (F-007) —
the named ones are historical, hand-assigned under the old scheme. *Model* and *Effort* are the only
things left for you to set, because they are set in the client before the chat starts and no script
can choose them: **Opus 5 · high** for anything that reasons about replication or lifecycle,
**Sonnet 5 · medium** where the work is mechanical and well-specified. The rows below are ordered by
what to start next, not by task number.

| # | Task | Agent name | Model | Effort | Status |
|---|---|---|---|---|---|
| **1.8** | Interest management — visibility filters, per-class intervals | `birch` | Opus 5 | high | **done and verified over a real wire.** `NetInterest` is the seam every replicated entity goes through — see below |
| **1.6** | Remote-player interpolation | `ash` | Opus 5 | high | **done and verified.** F-004's question answered as D-026: engine `physics_interpolation` does *not* cover it. See below |
| **1.7** | Connection lifecycle — mid-session join, disconnect, host quit, timeout | `reed` | Opus 5 | high | **done and verified over real multi-process ENet.** `NetSession` owns host admission and client-local LOCAL/LAN rejoin — see below |
| **1.11** | Protocol/build version handshake | auto | Sonnet 5 | medium | **done and wired through `NetSession`.** A mismatched build gets a readable refusal and leaves no player behind |
| 1.5 | Networked player — spawner + synchronizer | `spawn` | Opus 5 | high | **done** — runs; prompt kept for reference |
| 1.9 | Spike R1 — replication load | `load` | Opus 5 | high | **done — AMBER.** Read the verdict below before writing 1.8 |
| 1.10 | Network debug panel | `netui` | Sonnet 5 | medium | **done, wired, and reading real numbers** — F-013 closed, entity count live |
| 1.1 · 1.2 · 1.3 · 1.4 | GodotSteam · NetTransport · LOCAL loop · Steam lobby | | | | done and verified |
| 2.2 | Content framework | `content` | Sonnet 5 | medium | done — prompt kept for reference |

**1.6 took `project.godot`** and registered `NetInterp` with it; it is free again once 1.6 ships. It is
still the one file only one task at a time may hold, so claim it by name and check `agent board`
first. **Keep `NetInterp` after `PlayerNet` in `[autoload]`** (not "last" — eight gameplay autoloads
legitimately follow it now) — it resolves `PlayerNet` at `_ready()`, and autoload
order is load order. Two things wiring one cost us
already (`9f56451`): **an autoload script may not carry a `class_name` equal to its own singleton
name** — Godot rejects it as hiding the singleton and the autoload never registers — and **autoload
order is load order**: a script whose `_ready()` resolves `DebugOverlay`/`NetTransport`/`PlayerNet` by
bare identifier must be registered *after* them.

### What 1.7 shipped — one lifecycle policy above every transport

**`NetSession` is registered** between `NetTransport` and `DevLaunch`. `NetTransport` remains the
pipe; `NetSession` owns host-authoritative admission, player-facing end reasons, clean host shutdown,
and client-local rejoin policy. Mid-session roster replay remains `MultiplayerSpawner`'s job.

```gdscript
NetSession.end_session()                         # awaitable clean close; tells clients first
NetSession.refuse_peer(peer_id, detail)          # host-only readable refusal
NetSession.free_slots() -> int                   # host-side capacity remaining
NetSession.is_rejoining() -> bool
NetSession.capacity · accepting_joins · auto_rejoin

session_opened(is_host)
connection_interrupted(detail)
rejoin_attempted(attempt, of) · rejoined()
session_ended(reason, detail)                    # LOCAL_LEAVE / HOST_CLOSED / CONNECTION_LOST / REFUSED
peer_refused(peer_id, detail)                    # host-side
```

`NetTransport` gained the mechanism needed underneath: `last_end_kind()`, `has_rejoin_target()`,
`rejoin_last_target()`, `set_admission_gate()`, and `kick_peer()`. ENet accepts two short-lived
connections beyond game capacity so the host can say *why* it refused them (D-027), and dead-peer
timeouts are capped at 8 s. The lifecycle harness measured a killed client being detected and
despawned in **2.6 s** on this machine.

`tools/session_lifecycle_check.gd` is the real-process regression command. Its eight sections cover
autoload registration, host capacity, ordinary admission, over-capacity refusal without a spawn,
late joining with the complete roster, version mismatch cleanup, automatic rejoin after an unclean
drop, dead-process timeout, and clean host close without a rejoin loop. It completed 8/8 with zero
failures. LOCAL and LAN can retry their retained direct address; Steam requires asynchronous lobby
re-entry and deliberately does not pretend otherwise (F-020).

### What 1.6 leaves you — the smoothing seam, and the rule about who may read it

**`NetInterp` is registered** (`autoload/net_interp.gd`, last in the `[autoload]` list because it
resolves `PlayerNet`). It watches PlayerNet's `Players` container and gives every player this peer
does **not** own a `RemoteInterpolator`. Nothing else has to do anything: spawn a body under that
container and it is smoothed, or is skipped because it is yours. Offline it does nothing.

```gdscript
NetInterp.attach_to(body) -> bool        # give it an interpolator; false if it owns it / has no NetSync
NetInterp.interpolator_for(body) -> RemoteInterpolator
NetInterp.is_watching() -> bool          # false means "wiring is broken", not "netcode is broken"
NetInterp.debug_snapshot() -> Array[Dictionary]   # {peer, lag_ms, buffered} — 1.10's panel can read this
```

**`RemoteInterpolator` (`core/net/remote_interp.gd`) is entity-agnostic on purpose** — it is the
whole of F-004's answer for enemies (2.10) and props too, and it needs no new numbers for them
because it derives its delay from the *observed* arrival interval rather than being told the class
rate. 30 Hz players settle at ~67 ms, 15 Hz enemies at ~133 ms, automatically.

```gdscript
configure(target: Node3D, pitch_target: Node3D = null, sync: MultiplayerSynchronizer = null)
push_snapshot(position: Vector3, yaw: float, pitch: float)   # for a source that is not a synchronizer
reset()                                                       # after a teleport/respawn/level swap
lag_seconds() · buffered() · debug_stats()
```

Three things it would be expensive to rediscover:

1. **Nothing gameplay-authoritative may read an interpolated transform.** The interpolator overwrites
   `position`/`rotation.y` every rendered frame with a value ~67 ms in the past. It is attached only
   on the *receiving* side, so `player_net.gd`'s host speed check is unaffected today — but a future
   host-side check that runs on a client's copy of another client would be reading fiction. Read the
   synchronizer's value, or read it on the peer that owns it.
2. **It hooks `MultiplayerSynchronizer.synchronized`** and samples the node right after the engine
   writes to it, which is why 1.6 needed *no* change to `player_controller.gd` and added **nothing to
   the wire** — velocity is still deliberately absent (1.5's call stands; interpolation did not need
   it, and extrapolation derives it from the last two snapshots).
3. **`physics_interpolation_mode` is forced OFF on the subtree it drives**, and restored in
   `_exit_tree()`. D-026 says why: leaving it on makes the engine resample our per-frame output onto
   the 60 Hz grid and adds a tick of lag. If 1.7 ever detaches an interpolator on an authority change,
   free the node — don't just stop it — or that restore never runs.

`RemoteInterpolator` is a new `class_name`, so **F-016 applies to it**: both call sites `preload()`
the script instead of naming the class bare, and anything run via `--script` must keep doing that
until Sequoyah has opened the editor once since this landed.

**`tools/interp_check.gd`** is the fourth headless harness (`Godot --headless --path .
--script tools/interp_check.gd`, exits non-zero on failure, currently green). It measures judder as
*% of frames where the node visibly stopped*, and its control stream is read through
`get_global_transform_interpolated()` so the engine's own smoothing is included rather than being
handicapped. Numbers on this machine: **engine interpolation alone 67% still frames / CV 1.64 → plus
snapshot interpolation 1.5% / CV 0.21**, at a cost of ~67-84 ms of drawn latency. Extend it rather
than writing a fifth: phase A drives the interpolator directly with jitter and 6% loss (loopback has
neither), phase B checks a 100 m teleport snaps instead of smearing, phase C is two real ENet peers
and a real `player.tscn`.

### What 1.9 measured — 1.8 is now mandatory, and this is the budget it has to hit

**AMBER.** 6 real ENet peers, 200 host-authoritative entities, 60Hz paced:

| Configuration | Host up |
|---|---|
| Unfiltered, 30Hz | **918 KB/s** — 7.3× the 125 KB/s ceiling |
| §2.5 interest management, 30Hz | 105 KB/s |
| §2.5 interest management, 15Hz | 57 KB/s |

CPU never exceeded 1.18 ms of a 16.67 ms frame on any peer, so replication is **bandwidth-bound, not
CPU-bound** — do not optimize 1.6/1.8 for CPU. Wire cost is 30.5 B per entity per update per client
to carry 16 B of real state, so §6 R1's hand-rolled-binary fallback could buy at most 1.9× where
filtering buys 8.8–16×: **the fallback is not needed, and 1.8 is what makes M1 fit.**

One unexplained result 1.8 must budget for: filtering was *cheaper* with players clustered (100 KB/s)
than spread (180 KB/s) at an identical 11.6% visible fraction, and the extra cost is reliable-channel
traffic (~2× host ACK volume). That points at visibility churn — an entity crossing the 120 m boundary
forces a despawn+respawn per peer. Not isolated. **1.8 should assume churn is real and consider
hysteresis** (leave-radius larger than enter-radius) so boundary-hugging entities don't flap.

**F-013 is closed, and 1.8 inherits its answer.** The convention is settled as **D-024**: the
`&"synced"` group holds *every `MultiplayerSynchronizer`, one member each* — it counts update streams,
because that is what maps to the bandwidth budget above. The name lives once as
`NetConfig.SYNCED_GROUP` and is joined at construction, next to the authority assignment; 1.8's
per-class synchronizers just do the same and the panel's count stays meaningful.

### What 1.8 shipped — every replicated entity from here on goes through one call

`core/net/net_interest.gd`, `class_name NetInterest`. **Not an autoload**, so it costs nobody a
`project.godot` claim, and the observer registry is `static` because the filter runs once per entity
per peer per physics tick — 1.9's shape is 1000 calls a tick, which must not resolve a singleton or
walk the tree to answer.

```gdscript
# In the entity's _ready(), where authority is set, BEFORE add_child() (F-012):
sync.set_multiplayer_authority(NetConfig.HOST_PEER_ID)
NetInterest.configure(sync, self, NetInterest.Class.ENEMY)   # returns the filter, or null
add_child(sync)
```

`configure()` is the only seam, and it does three things so a construction site cannot half-opt-in:
sets `replication_interval` and `delta_interval` from the class, joins `NetConfig.SYNCED_GROUP`
(D-024 — nothing else joins it any more, including `PlayerController`), and installs the distance
filter for the filtered classes. The numbers live in `NetConfig`, not in `NetInterest`.

| `NetInterest.Class` | interval | delta | filtered | for |
|---|---|---|---|---|
| `PLAYER` | 30 Hz | 30 Hz | **no** | six of them; a teammate vanishing at 121 m is a bug report |
| `ENEMY` | 15 Hz | 15 Hz | yes | host-simulated, many, 15 Hz + interpolation is indistinguishable |
| `PROP` | 1 s | 100 ms | yes | on-change only — the 1 s interval is a cheap ceiling on a mistake, not a rate |

Observers — where each peer looks from — are pushed by `autoload/player_net.gd:_publish_observers()`,
every physics tick, **host only**, because every filtered row of §2.2 is host-authoritative. If a
client ever owns something filtered, that is the line to move. `NetInterest.clear_observer(peer)` on
despawn and `clear_observers()` on disconnect are already wired.

**D-025 settles the two calls that look like tuning and aren't:** two radii instead of one (enter
120 m / leave 144 m, so a boundary-hugging entity does not pay a despawn+respawn per peer per tick —
this is the churn 1.9 could only infer from reliable-channel volume), and
`VISIBILITY_PROCESS_PHYSICS` instead of `IDLE`, because re-evaluation rate *is* bandwidth and §5a
forbids hanging that off the render frame. `RadiusFilter.transitions` counts churn if you want to
measure rather than infer it.

**Two API facts worth not rediscovering.** `MultiplayerSynchronizer` in 4.7.1 has **no**
`is_visible_to()`; `get_visibility_for()` reads back only the *manual* `set_visibility_for()`
override, never the filter's answer, and `update_visibility()` pushes straight into the replicator,
which needs a live session. So there is no offline way to ask the engine what a filter decided —
proving the engine calls your filter at all requires real peers. And `replication_interval = 0.0`
means *every frame*, not "never", which is why `PROP` is 1 s.

### Headless verification you inherit — extend these rather than writing a fourth harness

All three run without an editor, exit non-zero on failure, and are the pattern 1.6/1.7/1.8 should
copy. **Verify your own work with them; do not ask Sequoyah to press Play and report back.**

| Tool | What it proves | Command |
|---|---|---|
| `tools/synced_group_check.gd` | Every synchronizer construction site joins `&"synced"` — builds both for real and reads the live tree back | `Godot --headless --path . --script tools/synced_group_check.gd` |
| `tools/net_debug_panel_check.gd` | The panel's 19 checks, including a real ENet host+client session with genuine RTT and bandwidth | same form |
| `tools/bench_replication.gd` | 1.9's spike: 6 peers, 200 entities, interest management on and off | same form |
| `tools/interest_check.gd` | 1.8's 40 checks: per-class intervals, hysteresis in both directions, and a live 1-host/2-client ENet session where moving one observer makes the entity appear and disappear on that client only | same form |

Two process notes that cost time when they were learned: a `--script` main loop compiles before
autoloads register, so `load()` them at runtime rather than preloading at class scope (**F-011**); and
nodes added in `_initialize()` have not run `_ready()` yet, so anything a node builds for itself must
be checked on the next frame via `call_deferred`.

Three more, all paid for on 2026-08-16:

- **A new `class_name` resolves nowhere until you rebuild the class cache** (**F-016**, hit
  independently by 1.8 and 1.11). `.godot/global_script_class_cache.cfg` is gitignored and only the
  editor's project scan writes it, so a brand-new global class is "not declared in the current scope"
  in every headless run *and* in the game itself. Fix, once, no editor window:
  `Godot --headless --path . --import`. It also generates the new script's `.uid` (**F-017**).
- **Do not pace a two-process game run with `--fixed-fps`.** It pins the *delta*, not the wall clock,
  so 420 "seconds" of simulation elapse in a fraction of a real one and the ENet handshake never gets
  time to happen — the client just sits on "connecting" and quits. `--max-fps 60 --quit-after 900`
  paces against the real clock and connects reliably.
- **A script error inside an `await`ed harness coroutine kills only that coroutine.** The run
  continues and prints `PASS` over whatever checks happened to have already run. `interest_check.gd`
  guards against that with a section counter asserted at the end; copy it.

### What 1.5 established — write 1.6, 1.7 and 1.8 against this, not against a guess

Node layout, built in code by `autoload/player_net.gd` and identical on every peer. The names are
load-bearing: the high-level API matches nodes by path.

```
/root/PlayerNet
  ├── Players                 Node3D                 every networked player lives here
  │     ├── "1"               PlayerController       named for the peer id that OWNS it
  │     │     ├── CollisionShape3D
  │     │     ├── CameraPivot  ├── Camera3D
  │     │     └── NetSync      MultiplayerSynchronizer — authority = owning peer, 30Hz
  │     └── "1210651288"      PlayerController       (ENet ids are random, not 2/3/4)
  └── PlayerSpawner           MultiplayerSpawner, spawn_path → ../Players
```

Replicated today, and nothing else: `.:position`, `.:rotation:y` (body yaw),
`CameraPivot:rotation:x` (head pitch). **Velocity is deliberately absent** — if 1.6 needs it for
interpolation, 1.6 adds it and pays for it.

Read the tree through `PlayerNet`'s public API rather than by path, so the paths stay ours to change:
`player_for(peer_id) -> Node3D` · `spawned_peers() -> PackedInt32Array` ·
`debug_snapshot() -> Array[Dictionary]`. `PlayerController` exposes `net_sync` and `is_local_authority`.

**Authority is derived from the node's NAME, not replicated.** The spawn function names each player
for its peer and sets authority before `add_child()`; `PlayerController._ready()` re-derives the same
value from that name. Both sides therefore agree with nothing extra on the wire — and a player node
named anything non-numeric (the level's hand-placed `Player`, or anything offline) is left alone,
which is why "press Play and walk around" still works with no session.

Three traps 1.6/1.8 will hit, all of them already paid for once: **F-012** (a synchronizer's authority
must be set *before* `add_child()`, or every client logs "no network ID" and state degrades silently),
**F-011** (autoloads are not compile-time identifiers in a `--script` harness), and **F-013** (spawned
synchronizers are not yet in group `&"synced"`, so 1.10's entity count reads 0).

### 1.5–1.8 were unblocked by D-023

They sat here for three sessions as *"Scene work, which only Sequoyah can wire — a spec conversation,
not a prompt."* That was wrong, and the correction is **D-023**: `MultiplayerSpawner`,
`MultiplayerSynchronizer` and `SceneReplicationConfig` all have complete script APIs, so they get
**built in code**, never authored in a scene. Task 1.9's prompt had already been requiring exactly that
for months of calendar-free session time — a headless benchmark can't author scenes either — so the
technique was proven in this repo before it was ever written down as a rule.

Consequence for the prompts below: **1.5 needs no `.tscn` change at all.** Read D-023 before writing
any further replication prompt, and don't reintroduce "tell Sequoyah to add a synchronizer node".

### Blocked, and why — so nobody writes a prompt that gets rejected at commit

| # | Blocked on | Clears when |
|---|---|---|
| 1.6 · 1.7 · 1.8 · 1.11 | ~~1.5~~ **Nothing. All four are writable now** against the layout above | cleared by `8d6ddab` |
| 1.12 | ~~Windows guest~~ **Nothing technical.** The physical Windows PC passed the pinned determinism probes; the Linux KVM guest exists. | Run the simultaneous Steam session in `docs/STEAM_CROSS_PLATFORM_TEST.md` |
| 4.0b | ~~A Windows guest existing at all~~ **done** | closed by `aa2efb2` |

The foundation is settled: `NetTransport` (1.2), `DevLaunch` (1.3), `SteamLobby` (1.4) and GodotSteam
4.21 (1.1) are all registered, booting and verified, so every prompt here is written against a real API
rather than a proposed one.

**1.12 test driver:** `DevLaunch` accepts debug-only `--steam-host` and
`--steam-join=<lobby_id>` arguments. They call the normal asynchronous `SteamLobby` flow, not
`NetTransport` directly, so lobby membership and Steam P2P start in the only supported order. The
complete three-machine commands, fresh-clone addon/import prerequisite, observed-state checks, and
PASS/FAIL/BLOCKED criteria are in `docs/STEAM_CROSS_PLATFORM_TEST.md`.

M0 is closed. The 0.7 and 0.8 spike prompts that used to live here shipped in `9a1bc19` / `9ebe47b` —
their results are D-015 and D-016 in `DECISIONS.md`. The unmeasured half of R2 is now task `4.0a`.

### 2026-08-18 — F-058/F-059/F-060 renumbered to F-092/F-093/F-094 (F-087); the originals are unchanged

If you're reading an old note (or a commit message) that cites **F-059** or **F-060** for something
art-pipeline-shaped — `mire_art.mat()`'s cache, or a headless `--script` run not re-importing changed
assets, or `mire_art.world_bounds` — that finding is now **F-093** and **F-094** respectively
(`mire_art.mat()`'s cache is **F-092**, was F-058). Nothing about **the originals** changed: F-059 is
still `InventoryService._publish_snapshot`'s unguarded `rpc_id` (cited by `983da6c`), F-060 is still
the two-process net-check authoring traps (cited by `adfaa78`, `abcf9bd`) — every mention of F-059/
F-060 elsewhere in this file is about those and needed no edit.

Three lanes had each read `agent brief`'s "next number" before another had written, so those three
numbers each named two unrelated findings — one Resolved and cited by a shipped commit, one still
Open. `agent brief`/`claim` picked one arbitrarily and `agent start`/`board` reported the Open one as
already closed. Full writeup and verification: `docs/FINDINGS.md` F-087 (Resolved).

New standing check: `agent godot --script tools/findings_numbering_check.gd` source-scans
`docs/FINDINGS.md` and fails if any F-number heads two different `## Open` entries, or heads an
`## Open` entry and a different `## Resolved` entry — the two collision shapes this finding fixed.
It does not flag same-number entries that are both Resolved (no routing risk, left as historical
record on purpose per F-087/F-052).

### 2026-08-18 — `mire_art.mat()`'s cache guard has a regression check now (F-092)

New standing check: `/Applications/Blender.app/Contents/MacOS/Blender --background --python
tools/blender/mat_cache_check.py` — the first focused check for `tools/blender/mire_art.py`. It is a
Blender background script, not a Godot one; `mire_art` is never Godot-reachable, so `agent godot`
does not apply and there is no shared lock to take (Blender's own process is the whole run). Exercises
`mat(token)` called repeatedly from inside a loop rather than hoisted into a `mats = {...}` dict once
per build — the shape that hid F-092 in the four originally migrated kits and the shape any new
generator will naturally reach for — and asserts one material minted per token no matter how many
times it's asked for, a `suffix` variant is an independent cache entry, and a datablock removed out
from under `_MATERIAL_CACHE` (e.g. a scene wipe that didn't call `reset_materials()`) is rebuilt
rather than returned dangling or raised. Any new `build_*.py` generator that calls `mat()` inside a
loop can lean on this instead of writing its own cache-hit assertion. Full writeup and verification:
`docs/FINDINGS.md` F-092 (Resolved), `docs/SPECS.md` F-092.

---

> **Historical documents — every task prompt from here down.** They predate D-021 (agents register
> their own autoloads), D-031 (agents may edit Godot-authored files under exact claim), D-039 (do it
> yourself rather than handing it back) and the D-036 lane system. Where a prompt says
> `.tscn`/`.tres`/`project.godot` are human-only or hook-blocked — and several do, in those words —
> that was true when it ran and is **not policy now**. `AGENTS.md` Hard rules and `docs/SPECS.md`
> are current. The disclaimer used to sit further down, below three prompts that make exactly that
> stale claim (F-045/F-053).

## Task 1.5 — Networked player: spawner + synchronizer, client-auth movement ✅ **DONE**

> **Model: Opus 5 · effort high** · agent name `spawn`
> **Shipped 2026-08-16 in `8d6ddab`. Do not paste this.** It runs — `PlayerNet` registered
> itself, no scene work was needed, and D-023 held: every replication node is built in code.
> The layout it established, and the traps it paid for, are in *Current state* above; the
> prompt is kept as the worked example of a replication-shaped brief, since 1.6, 1.7 and 1.8
> are all the same shape.

```
You're working on MIRE, a co-op survival game in Godot 4.7.1. Read AGENTS.md first — it is
the protocol every agent here follows. Then read docs/DECISIONS.md D-023, which is the
decision this task exists under. Then:

    MIRE_AGENT=spawn .agent/bin/agent start spawn
    MIRE_AGENT=spawn .agent/bin/agent claim 1.5 autoload/player_net.gd entities/player/player_controller.gd core/net/net_config.gd project.godot

Keep the MIRE_AGENT=spawn prefix on EVERY .agent/bin/agent command AND on `git commit`. Do
not use `export` — each shell call is a fresh process, so the value is lost and your claims
get filed under the wrong agent with no error. `agent ship` handles this itself.

TASK: One player per peer, spawned by the host, moving under its owner's control, visible to
everyone else. Two windows, two players, each drives their own and sees the other move.

AUTHORITY (docs/ARCHITECTURE.md §2.2, rows 1 and 2):
  Own player movement      → CLIENT-authoritative. The owning peer simulates locally and
                             sends its transform. Responsiveness beats anti-cheat here; these
                             are friends.
  Other players' movement  → host relays, MultiplayerSynchronizer + interpolation. Remote
                             copies run NO input and NO physics — they are moved purely by
                             replication. (Interpolation itself is task 1.6, not yours.)
  Spawning                 → HOST. Only the host decides a player exists. Clients receive.

WHAT ALREADY EXISTS — use it, do not rebuild it:

  NetTransport, a registered verified autoload (task 1.2). Query it; never touch
  multiplayer.multiplayer_peer yourself:
    func is_host() -> bool              # NOT multiplayer.is_server() — read that method's note
    func local_peer_id() -> int         # 0 when offline
    func peer_ids() -> PackedInt32Array # everyone INCLUDING us, ascending, host first
    func is_active() -> bool
    signal peer_joined(peer_id: int) / peer_left(peer_id: int)
    signal server_started() / connected_to_host() / disconnected()
  Contract worth knowing: the local peer never produces peer_joined. You learn you are in a
  session from server_started (host) or connected_to_host (client), and peer_joined is remote
  peers only. disconnected fires exactly once when an established session ends, any reason.

  NetConfig — a class_name, NOT an autoload. NetConfig.MAX_PLAYERS = 6,
  NetConfig.HOST_PEER_ID = 1, NetConfig.LOG_CHANNEL = &"net".

  PlayerController (entities/player/player_controller.gd) — CharacterBody3D, first-person
  walk/sprint/jump, already written and tuned. It ALREADY has the authority seam you need:
    var is_local_authority: bool = true      # set from is_multiplayer_authority() in _ready()
    @onready var camera: PlayerCamera = $CameraPivot
  and _ready() already gates camera.set_active(), set_physics_process() and
  set_process_unhandled_input() on it. Do not restructure that. Body yaw is on the
  CharacterBody3D; only pitch is on CameraPivot (see player_camera.gd) — so a remote player
  facing the right way needs the body's rotation, and its head angle needs the pivot's.

  entities/player/player.tscn — root "Player" (CharacterBody3D) > CollisionShape3D,
  CameraPivot (Node3D) > Camera3D. That is the whole scene.

  DevLaunch (core/dev/dev_launch.gd, task 1.3) — `--host` / `--client` user args auto-host or
  auto-join a LOCAL session at startup, with a bounded retry. This is how you test. Read it;
  it is one of the two files worth opening.

  MireLog statics: MireLog.info/warn/error/debug(channel: StringName, message: String).

WRITE / EDIT EXACTLY THESE:

1. autoload/player_net.gd — NEW. The spawner. Register it in project.godot as PlayerNet
   (see AUTOLOAD below). It owns:
     - a MultiplayerSpawner built IN CODE, plus a container node, at fixed paths
       /root/PlayerNet/PlayerSpawner and /root/PlayerNet/Players. Fixed because the high-level
       API matches nodes by path across peers, and because M4 swaps levels underneath this.
     - spawn on session start: host spawns one player per peer in NetTransport.peer_ids(),
       then one more on each peer_joined; frees on peer_left; clears everything on
       disconnected. (Mid-session join edge cases, host-quit and timeouts are task 1.7 — do
       the obvious signal handling, don't build a lifecycle system.)
     - a public read API for 1.6/1.7/1.10 to use rather than reaching into the tree:
       something like player_for(peer_id: int) -> Node3D and spawned_peers() -> PackedInt32Array.
     - offline behaviour: does NOTHING. No session, no spawning. "Open the project and press
       Play and walk around" must still work exactly as it does today.

2. entities/player/player_controller.gd — EDIT. Build its MultiplayerSynchronizer and
   SceneReplicationConfig in code in _ready(), identically on every peer, so the paths match.
   Replicate the minimum that makes a remote player look right:
       position, body rotation (yaw), CameraPivot rotation (pitch)
   and NOTHING else. Per §2.5, players sync at 30Hz — set replication_interval accordingly,
   and put the number in NetConfig as a named constant rather than a literal. Do NOT replicate
   velocity "for 1.6" — if 1.6 needs it, 1.6 adds it and pays for it then.

3. core/net/net_config.gd — EDIT, constants only. The sync rate, and the spawn-node names if
   you want them named once. Nothing with logic; read that file's header.

4. project.godot — EDIT, to register PlayerNet. Append only.

THE FOUR THINGS THAT WILL BITE YOU — all four are the actual content of this task:

  a) AUTHORITY MUST BE SET BEFORE add_child(). PlayerController._ready() reads
     is_multiplayer_authority() and immediately decides whether to run physics, capture the
     mouse and activate the camera. Set the owning peer as authority on the instance BEFORE it
     enters the tree, or every client runs input on every player and captures the mouse for
     six of them. If a spawn path makes that impossible, make the controller re-evaluate on an
     authority-changed signal rather than papering over it.

  b) THE LEVEL HAS A PLAYER IN IT ALREADY. levels/greybox_test.tscn hard-instances one
     "Player" at the scene root. In a session that node is a SPAWN POINT, not a player: read
     its global transform, use it as the spawn origin, free it, then spawn per-peer. You may
     NOT edit that scene (D-007, hook-enforced) and you do not need to. Offline, leave it
     completely alone.

  c) BOTH PEERS MUST BUILD THE SAME TREE. A synchronizer created only on the authority, or
     named differently on the two sides, fails as "node not found" or as silence. Construction
     runs unconditionally in _ready(); only the CONFIGURATION (who has authority) differs.

  d) SIX MICE. Only the local player's camera is current and only the local player captures
     the mouse. The controller already gates this correctly — verify it still holds once nodes
     are spawned rather than placed, because that changes when _ready() sees authority.

HOST SPEED SANITY CHECK — in scope, deliberately small. §2.2 row 1 says the host
sanity-checks speed, and player_controller.gd's own header promises it lands in this task. On
the host only: watch each remote player's replicated position between samples, and if the
implied horizontal speed exceeds sprint_speed by a clear margin for several consecutive
samples, log a WARN naming the peer. Do NOT correct, rubber-band, kick or teleport — that is a
later decision and the wrong one to make silently now. A warning that fires on a real speed
hack and never fires during normal play is the entire deliverable here.

CONSTRAINTS:
- .gd and project.godot only. NEVER create or edit .tscn/.tres — human-only, hook-enforced.
- project.godot: check `pgrep -fl Godot` FIRST. If the editor is running it rewrites that file
  on save and silently discards your edit — stop and say so rather than racing it. Append
  only; never reorder, reformat, or hand-write a setting equal to the engine default (D-019).
- Typed GDScript throughout. Networked functions prefixed net_.
- Do not build interpolation (1.6), visibility filters or per-class intervals beyond players
  (1.8), reconnection handling (1.7), or a version handshake (1.11). Each is someone's task.
- Don't explore beyond core/dev/dev_launch.gd, entities/player/player_camera.gd and the files
  you claimed. Everything else you need is above.

VERIFY IT, DON'T ASSERT IT. Two real processes, headless, using DevLaunch:

    /Applications/Godot.app/Contents/MacOS/Godot --headless --path . -- host
    /Applications/Godot.app/Contents/MacOS/Godot --headless --path . -- client

Show that on BOTH processes there are two players under /root/PlayerNet/Players, that each
process has authority over exactly one of them, and that moving the local one changes the
remote copy's position on the other process. Print positions from both sides; a log line
saying "spawned" proves nothing. If you cannot drive input headlessly, move the authoritative
player from code and show the far side following.

FINISH WITH:
    MIRE_AGENT=spawn .agent/bin/agent done 1.5 "<what replicates, what you measured on both sides>"
    MIRE_AGENT=spawn .agent/bin/agent ship 1.5 "M1: networked player — spawner, synchronizer, client-auth movement"

`ship` commits only this task's files. Never `git add -A` — other agents work in this same
directory and you would commit their half-written files.

THEN, as your final chat message, tell me:
  - the exact commands you ran and what the two processes actually printed
  - whether it RUNS or only compiles — and say plainly if anything still needs wiring
  - the node layout you settled on, as a path tree, since 1.6/1.7/1.8 get written against it
  - what the speed check fires on, and what it does NOT do
  - whether it is safe for me to start the next task
```

---

## Task 1.9 — Spike R1: 6 peers, 200 synced entities

> **Model: Opus 5 · effort high** · agent name `load`
> `ARCHITECTURE.md` §6 R1. If this is red, the fallback is hand-rolled binary state packets
> over raw ENet — a rewrite of how every replicated system is written. Worth knowing before
> 1.5–1.8 build on the assumption it's fine.

```
You're working on MIRE, a co-op survival game in Godot 4.7.1. Read AGENTS.md first — it is
the protocol every agent here follows. Then:

    MIRE_AGENT=load .agent/bin/agent start load
    MIRE_AGENT=load .agent/bin/agent claim 1.9 core/net/dummy_replicant.gd tools/bench_replication.gd

Keep the MIRE_AGENT=load prefix on EVERY .agent/bin/agent command AND on `git commit`. Do
not use `export` — each shell call is a fresh process, so the value is lost and your claims
get filed under the wrong agent with no error. `agent ship` handles this itself.

TASK: Spike R1. Answer one question with measurements, not opinion:
"Can Godot's high-level multiplayer carry 6 peers and 200 synced entities?"

This is a SPIKE — throwaway code that produces a number. Do not build the real replication
layer. Do not make it pretty. Measure, report, stop.

WHAT ALREADY EXISTS — use it, do not rebuild it:

  NetTransport is a registered, verified autoload (task 1.2). Relevant API:
    func host(mode: NetConfig.Mode, port: int = -1) -> Error
    func join(mode: NetConfig.Mode, address: String, port: int = -1) -> Error
    func leave() -> void
    func peer_ids() -> PackedInt32Array
    func local_peer_id() -> int
    signal peer_joined(peer_id: int) / peer_left(peer_id: int)
    signal server_started() / connected_to_host() / connection_failed(reason: String)

  NetConfig is a class_name, NOT an autoload. NetConfig.MAX_PLAYERS = 6,
  NetConfig.DEFAULT_PORT = 27515, NetConfig.LOG_CHANNEL = &"net".
  join(Mode.LOCAL, "") resolves to loopback and the default port.

  DevLaunch (core/dev/dev_launch.gd, task 1.3) already does headless multi-instance
  host/join via `--host` / `--client` user args, with a bounded retry. Read it — it is the
  one file worth opening — and drive your peers the same way rather than inventing a second
  launch mechanism.

  MireLog statics: MireLog.info/warn/error/debug(channel: StringName, message: String).

WRITE EXACTLY TWO FILES:

1. core/net/dummy_replicant.gd — a minimal host-authoritative entity that moves and
   replicates. Position plus a couple of small fields, nothing else. Build its
   MultiplayerSynchronizer and SceneReplicationConfig IN CODE — you cannot create .tscn
   files, and this must run headless with no scene authoring.

2. tools/bench_replication.gd — extends SceneTree, headless. Spawns 1 host + 5 clients
   (six peers total, the real MAX_PLAYERS) and 200 dummy replicants under host authority.

MEASURE AND PRINT:
   - bytes/sec up and down at the host, and at one client
   - bytes/sec per entity, so the number scales to other entity counts
   - host CPU: ms/frame spent in replication
   - client CPU: same
   - how all of the above change at replication_interval 0 (every frame) vs 30Hz vs 15Hz
   - packet loss / delivery failures, if the peer reports any

  Run it yourself:
    /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/bench_replication.gd

SUCCESS CRITERIA — state clearly which the measurements support. The budget that matters is
a typical home upload, so treat ~1 Mbit/s (125 KB/s) at the host as the ceiling for 5
clients, and remember real gameplay adds far more than 200 dummies:
   GREEN : host up < 60 KB/s at 15-30Hz and CPU under ~2 ms/frame → §2.5 interest management
           is enough; 1.5-1.8 proceed as designed
   AMBER : fits only with aggressive intervals or culling → say exactly which knobs bought
           it, because 1.8 then has to ship them rather than treat them as optional
   RED   : cannot fit → the §6 R1 fallback (hand-rolled binary state packets over raw ENet)
           is on the table. Do not just report red: sketch what that costs us, since it
           changes how every replicated system in the project gets written.

IMPORTANT — measure interest management too. §2.5 says enemies/props replicate only within
~120m and replication_interval is set per class (players 30Hz, enemies 15Hz, props
on-change). Task 1.8 implements that. Your job is to produce the numbers that tell 1.8
whether visibility filtering is optional or mandatory, so measure with filters OFF and ON.

AUTHORITY: host-authoritative, per docs/ARCHITECTURE.md §2.2 — the host owns every dummy
and clients only receive. Do not give clients authority over anything here.

CONSTRAINTS:
- .gd only. NEVER create or edit .tscn/.tres/project.godot — another agent holds
  project.godot right now (task 1.5) and you would be blocked at commit. You need no
  autoload for this; if you conclude you do, STOP and ask rather than claiming that file.
- Typed GDScript throughout.
- Deterministic movement for the dummies: seeded RandomNumberGenerator only, never global
  randi(), so two runs are comparable.
- Don't explore beyond core/dev/dev_launch.gd. Everything else you need is above.

FINISH WITH:
    MIRE_AGENT=load .agent/bin/agent done 1.9 "<the numbers, and which of GREEN/AMBER/RED>"
    MIRE_AGENT=load .agent/bin/agent ship 1.9 "M1: replication load spike (R1)"

`ship` commits only this task's files. Never `git add -A` — other agents work in this same
directory and you would commit their half-written files.

THEN, as your final chat message, tell me:
  - the actual numbers and the exact command that produced them
  - which of GREEN/AMBER/RED they support, and if AMBER, exactly which knobs task 1.8 now
    has to ship as mandatory rather than optional
  - whether anything you measured was simulated rather than real (six peers on one machine
    over loopback is NOT a network — say plainly what that does and does not tell us)
  - the text to paste into docs/DECISIONS.md as the R1 verdict
```

---

## Task 1.10 — Network debug panel ✅ **DONE**

> **Model: Sonnet 5 · effort medium** · agent name `netui`
> **Shipped 2026-08-16 in `4f17bcd`. Do not paste this.** Live readout through
> `DebugOverlay.watch()` (F3, FULL mode): session line, per-peer RTT, host bandwidth, event
> log. RTT and bandwidth read `n/a` in STEAM mode, stated rather than invented. Its
> entity-count line reads 0 until **F-013** is closed.

```
You're working on MIRE, a co-op survival game in Godot 4.7.1. Read AGENTS.md first. Then:

    MIRE_AGENT=netui .agent/bin/agent start netui
    MIRE_AGENT=netui .agent/bin/agent claim 1.10 ui/debug/net_debug_panel.gd

Keep the MIRE_AGENT=netui prefix on EVERY .agent/bin/agent command AND on `git commit`.
Do not use `export` — each shell call is a fresh process, so the value is lost and your
claims get filed under the wrong agent silently. `agent ship` handles this itself.

TASK: A live network readout, so that when 1.5–1.8 misbehave you can see WHY instead of
guessing. Every later M1 task is easier to debug because this exists.

Show, updating a few times a second (NOT every frame):
  - current mode (OFFLINE / LOCAL / LAN / STEAM) and whether we are host or client
  - our own peer id, and the list of connected peer ids
  - ping/RTT per peer
  - bandwidth in and out, per second, human-readable (KB/s)
  - total synced node count
  - a short rolling log of the last few connection events (joined / left / failed)

WHAT ALREADY EXISTS — do not rebuild any of it:

  NetTransport, a registered working autoload. Query it, never touch
  multiplayer.multiplayer_peer directly:
    func is_host() -> bool
    func local_peer_id() -> int
    func peer_ids() -> PackedInt32Array
    func current_mode() -> NetConfig.Mode
    func is_active() -> bool
    func is_connecting() -> bool
    static func mode_name(mode: NetConfig.Mode) -> String
  Signals to subscribe to for the event log:
    peer_joined(peer_id: int), peer_left(peer_id: int),
    connection_failed(reason: String), connected_to_host(),
    server_started(), disconnected()

  NetConfig is a class_name, not an autoload. NetConfig.LOG_CHANNEL = &"net".

  MireLog statics: MireLog.info/warn/error/debug(channel: StringName, message: String).

  DebugOverlay is an existing registered autoload at autoload/debug_overlay.gd, with the
  F3 overlay. READ THAT FILE — it is the one file worth opening — and follow whatever
  pattern it already uses for registering a panel or a line of readout. Match it rather
  than inventing a second, parallel overlay system. If it has no extension point, say so
  and propose the smallest one rather than editing that file (you do not hold its claim).

REQUIREMENTS:
- Typed GDScript throughout.
- Poll on a timer, not in _process. This is a debug readout; costing frames to display
  performance data is self-defeating.
- Get RTT and bandwidth from the real Godot APIs. VERIFY WHAT 4.7.1 ACTUALLY EXPOSES
  before writing against it — ENetPacketPeer and the MultiplayerPeer statistics surface
  changed across 4.x and your training data may be stale. If a figure genuinely is not
  available, display "n/a" and say so in your writeup. Do NOT invent a plausible number:
  a debug panel that lies is worse than one that admits a gap.
- Degrade cleanly when offline. Not connected is the normal state, not an error.
- No allocations per update where you can avoid them.

AUTHORITY: none — display only. This panel must never mutate game state, and must never
be the only thing calling something (if it is the sole caller of an API, that API is
about to be dead code in a release build).

CONSTRAINTS:
- .gd only. Scene files (.tscn/.tres) are human-only (D-007, hook-enforced).
- You did NOT claim project.godot and this needs no autoload of its own — it is a panel
  owned by DebugOverlay. If you conclude it genuinely must be an autoload, stop and ask
  before claiming that file.
- Don't explore beyond autoload/debug_overlay.gd.

FINISH WITH:
    MIRE_AGENT=netui .agent/bin/agent done 1.10 "<what it shows, what is n/a and why>"
    MIRE_AGENT=netui .agent/bin/agent ship 1.10 "M1: network debug panel"

`ship` commits only this task's files. Never `git add -A`.

THEN, as your final chat message, tell me:
  - what you verified and how, including which figures are real and which are "n/a"
  - whether it RUNS or only compiles
  - exactly what I must wire in the editor, if anything
  - whether it is safe for me to start the next task
```

---

## Already shipped — kept for reference

## Task 1.3 — LOCAL mode: two windows, one keypress ✅ **DONE**

> **Model: Opus 5 · effort high** · agent name `local`
> **Completed 2026-08-16. Do not paste this.** Shipped `core/dev/dev_launch.gd`: `--host` /
> `--client` auto-host or auto-join a LOCAL session, no args does nothing, gated on
> `OS.is_debug_build()`, bounded retry (6 × 0.4s) for a client that starts before its host.

```
You're working on MIRE, a co-op survival game in Godot 4.7.1. Read AGENTS.md first — it
is the protocol every agent here follows. Then:

    MIRE_AGENT=local .agent/bin/agent start local
    MIRE_AGENT=local .agent/bin/agent claim 1.3 core/dev/dev_launch.gd project.godot

Keep the MIRE_AGENT=local prefix on EVERY .agent/bin/agent command AND on `git commit`.
Do not use `export` — each shell call is a fresh process, so an exported value is gone by
your next command and your claims get filed under the wrong agent with no error. `agent
ship` handles this itself.

TASK: Make "two windows, host and client, already connected" cost one keypress. Today
testing multiplayer means launching twice by hand and wiring a connection each time; this
task removes that and is the reason every later M1 task is cheap to verify.

WHAT ALREADY EXISTS — do not rebuild any of it:

  NetTransport is a registered, working autoload (task 1.2, verified booting). API:

    signal peer_joined(peer_id: int)
    signal peer_left(peer_id: int)
    signal connection_failed(reason: String)
    signal connected_to_host()
    signal server_started()
    signal disconnected()

    func host(mode: NetConfig.Mode, port: int = -1) -> Error
    func join(mode: NetConfig.Mode, address: String, port: int = -1) -> Error
    func leave() -> void
    func is_host() -> bool
    func local_peer_id() -> int
    func peer_ids() -> PackedInt32Array
    func current_mode() -> NetConfig.Mode
    func is_active() -> bool
    func is_connecting() -> bool

  NetConfig is a class_name (NOT an autoload — do not register it). Constants you need:
    NetConfig.Mode.{OFFLINE, LOCAL, LAN, STEAM}
    NetConfig.DEFAULT_PORT = 27515
    NetConfig.LOOPBACK_ADDRESS = "127.0.0.1"
    NetConfig.MAX_PLAYERS = 6
    NetConfig.LOG_CHANNEL = &"net"

  join(Mode.LOCAL, "") resolves the address to loopback and port -1 to DEFAULT_PORT, so
  the LOCAL call needs no literals at the call site.

  MireLog (core/util/mire_log.gd, class_name) has statics:
    MireLog.info(channel: StringName, message: String)
    MireLog.warn / .error / .debug, same shape.

WRITE ONE FILE: core/dev/dev_launch.gd — an autoload, and register it yourself.

Behaviour, driven by user command-line args (OS.get_cmdline_user_args(), the args after
a bare `--`):

    -- host      host a LOCAL session on startup
    -- client    join a LOCAL session on startup
    (no args)    DO NOTHING AT ALL

THE NO-ARGS CASE IS THE IMPORTANT ONE. This autoload ships in the retail build. If it
ever auto-hosts without being asked, every player who launches the game opens a socket
they did not ask for. Guard it: no args means return immediately from _ready(), touching
nothing. Also gate the whole thing on OS.is_debug_build() so it is inert in an export.

Beyond that:
- Log every transition through MireLog on NetConfig.LOG_CHANNEL, prefixed so the two
  windows are tellable apart at a glance (peer id, and host/client role).
- Connect to connection_failed and log the reason. A client that starts a half-second
  before the host WILL fail to connect; if that happens, retry a small number of times
  with a short delay before giving up, and say so in the log. Do not retry forever.
- Typed GDScript throughout.

VERIFY THE LAUNCH MECHANISM BEFORE YOU DESIGN AROUND IT. Godot 4.x has a built-in
"Run Multiple Instances" feature (Debug menu → Customize Run Instances) that launches N
instances with per-instance arguments. Check what actually exists in 4.7.1 and how args
are passed, rather than assuming — the feature moved and changed across 4.x releases.

IMPORTANT CONSTRAINT ON THAT: run-instance configuration lives under `.godot/`, which is
in .gitignore. So you CANNOT commit that config, and it is not reproducible for anyone
else from the repo. Therefore:
  - the .gd side is yours and must work from args alone
  - the editor-side setup is Sequoyah's, and you must write him the exact click-path
    (menu, field, and the literal arg strings to type into each instance slot)
  - if you find a way to make this work that does NOT depend on gitignored editor state,
    say so and explain the tradeoff — a committed tools/ launcher script that spawns two
    OS processes is a legitimate alternative. Recommend one, do not build both.

AUTHORITY: none of its own. It only calls NetTransport, which is infrastructure. The
session it opens is host-authoritative per docs/ARCHITECTURE.md §2.2.

CONSTRAINTS:
- Scene files (.tscn/.tres) stay human-only (D-007, hook-enforced).
- project.godot IS yours — your claim names it (D-021). Register the autoload yourself.
  Append one line to [autoload]; do not reorder or reformat the file, and never write a
  setting equal to the engine default (Godot prunes those on save — D-019).
- BEFORE editing project.godot, run `pgrep -fl -i godot`. If the editor is running, STOP
  and tell Sequoyah — the editor rewrites that file on save and will silently discard
  your change. Check immediately before the write, not at the start of your session.
- Don't explore the codebase. Everything you need is above.

FINISH WITH:
    MIRE_AGENT=local .agent/bin/agent done 1.3 "<what works, and how you verified it>"
    MIRE_AGENT=local .agent/bin/agent ship 1.3 "M1: LOCAL two-window dev loop"

`ship` commits only this task's files and pushes. Never `git add -A` — other agents work
in this same directory and you would commit their half-written files.

THEN, as your final chat message, tell me:
  - what you verified, with the actual command and its output. You cannot press F5 in the
    editor; if the only real test is a manual two-window run, say so plainly and give me
    the exact steps and the log lines I should expect to see in each window
  - whether the feature RUNS now or only compiles
  - the exact editor click-path and arg strings I must enter, if any
  - whether it is safe for me to start the next task
```

---

## Task 1.2 — NetTransport autoload ✅ **DONE**

> **Model: Opus 5 · effort xhigh** · agent name `net`
> **Completed 2026-08-16, registered and verified booting. Do not paste this.** Kept as the
> worked example of an interface-first prompt — 1.5–1.8 are all written against what it defined.

```
You're working on MIRE, a co-op survival game in Godot 4.7.1. Read AGENTS.md and
docs/ARCHITECTURE.md §2 (all of §2 — it defines the networking model) before writing
code. Then:

    MIRE_AGENT=net .agent/bin/agent start net
    MIRE_AGENT=net .agent/bin/agent claim 1.2 autoload/net_transport.gd core/net/net_config.gd project.godot

Keep the MIRE_AGENT=net prefix on EVERY .agent/bin/agent command you run, including
done and ship. Do not use `export` — each shell call is a fresh process, so an
exported value is gone by your next command and your claims get filed under the
wrong agent without any error.

TASK: Build the NetTransport autoload — one interface that swaps between transports so
no gameplay code ever knows which one is live. This is the foundation of milestone M1;
everything else in the milestone plugs into it.

Three modes (docs/ARCHITECTURE.md §2.3):
  LOCAL  — ENetMultiplayerPeer on 127.0.0.1. Daily development: two windows, one
           machine, no Steam client, ~3 second iteration loop.
  LAN    — ENetMultiplayerPeer on a real address.
  STEAM  — SteamMultiplayerPeer via GodotSteam.

SCOPE FOR THIS TASK: implement LOCAL and LAN fully. For STEAM, define the code path
and leave it behind a clean seam that returns a clear "not yet installed" error —
GodotSteam isn't installed yet (that's task 1.1, and it's mine to do). Task 1.4 fills
in the Steam implementation. Design the seam so 1.4 is a drop-in, not a refactor.

Write exactly two files:

1. core/net/net_config.gd — class_name NetConfig, extends RefCounted
   Mode enum, default port, max players (6), timeouts. No logic.

2. autoload/net_transport.gd — the autoload. Public API, exactly this shape so the
   rest of M1 can be written against it:

     signal peer_joined(peer_id: int)
     signal peer_left(peer_id: int)
     signal connection_failed(reason: String)
     signal connected_to_host()
     signal server_started()
     signal disconnected()

     func host(mode: NetConfig.Mode, port: int = -1) -> Error
     func join(mode: NetConfig.Mode, address: String, port: int = -1) -> Error
     func leave() -> void
     func is_host() -> bool
     func local_peer_id() -> int
     func peer_ids() -> PackedInt32Array
     func current_mode() -> NetConfig.Mode

REQUIREMENTS:
- Wrap Godot's MultiplayerAPI; do not make callers touch multiplayer.multiplayer_peer.
- Handle the full lifecycle: host quits, client times out, join fails, leave and rejoin
  in the same process without restarting. That last one matters — it's what makes the
  two-window loop fast.
- Emit signals rather than requiring polling.
- Log through the existing MireLog class (core/util/mire_log.gd, class_name MireLog).
  Read that file to match its API — it's the one file worth opening.
- Typed GDScript, all of it.

AUTHORITY: this is infrastructure, not simulated state. But read the authority table
in docs/ARCHITECTURE.md §2.2 and note in a file-header comment which rows this enables.

CONSTRAINTS:
- Scene files (.tscn/.tres) stay human-only (D-007, hook-enforced).
- project.godot IS yours here: your claim names it, which D-012/D-021 permit. Register
  the autoload yourself rather than handing me a checklist. Append one line to the
  [autoload] section; do not reformat or reorder the file, and do not add settings that
  equal the engine default — Godot's editor prunes those on its next save (D-019).
- BEFORE editing project.godot, confirm the Godot editor is not running (pgrep -fl Godot).
  If it is, STOP and tell me — the editor rewrites that file on save and will silently
  discard your change. This is the one condition that makes wiring not yours.
- Don't explore the codebase beyond mire_log.gd. Everything else you need is here.

DELIVERABLE: also give me a 5-line snippet showing how task 1.3 (the two-window LOCAL
launcher) will call this, so I can sanity-check the interface before we build on it.

FINISH WITH:
    MIRE_AGENT=net .agent/bin/agent done 1.2 "<what works, what's stubbed>"
  (or handoff, if something is genuinely unfinished)
    MIRE_AGENT=net .agent/bin/agent ship 1.2 "M1: NetTransport autoload"

`ship` commits only this task's files and pushes to origin. Never `git add -A` —
other agents are working in this same directory and you would commit their
half-written files.

THEN, as your final chat message, tell me:
  - what you verified, with the actual command you ran and its output. If you
    could not run it, say so — do not describe unrun code as working
  - whether the feature actually RUNS now, or only compiles. You registered the
    autoload yourself, so "shipped" and "working" should finally be the same
    thing; if they aren't, say which one this is
  - anything still needing a .tscn/.tres change, which is genuinely mine
  - whether it is safe for me to start the next task

```

---

## Task 2.2 — Content resource framework ✅ **DONE**

> **Model: Sonnet 5 · effort medium** · agent name `content`
> **Completed 2026-08-16. Do not paste this.** Kept only as a worked example of a
> framework-shaped prompt, since M2 has several more of them.

```
You're working on MIRE, a co-op survival game in Godot 4.7.1. Read AGENTS.md first.
Then:

    MIRE_AGENT=content .agent/bin/agent start content
    MIRE_AGENT=content .agent/bin/agent claim 2.2 core/content/item_def.gd core/content/recipe_def.gd autoload/registry.gd

Keep the MIRE_AGENT=content prefix on EVERY .agent/bin/agent command you run,
including done and ship. Do not use `export` — each shell call is a fresh process,
so an exported value is gone by your next command and your claims get filed under
the wrong agent without any error.

TASK: Build the content resource framework — the thing that makes adding the 60th
powerup cost the same as the 2nd (docs/DECISIONS.md D-006).

Three files:

1. core/content/item_def.gd — class_name ItemDef, extends Resource
   @export'd: id (StringName), display_name, description, icon (Texture2D),
   max_stack (int), tags (Array[StringName]), tier (int).
   All @export so items are authored in the Godot inspector, not in code.

2. core/content/recipe_def.gd — class_name RecipeDef, extends Resource
   @export'd: id, inputs (Dictionary of item id -> count), output item id,
   output count, required station (StringName), craft_time (float).

3. autoload/registry.gd — loads every .tres under content/ at boot into typed
   dictionaries keyed by id. Public API:
     func item(id: StringName) -> ItemDef
     func recipe(id: StringName) -> RecipeDef
     func recipes_for_station(station: StringName) -> Array[RecipeDef]
     func all_items() -> Array[ItemDef]
   Fail loudly at boot on a duplicate or missing id — a silent content bug found at
   runtime costs far more than a hard startup error.

REQUIREMENTS:
- Typed GDScript throughout, including typed Arrays and Dictionaries.
- Registry must be deterministic: iterate directory entries in SORTED order. Load
  order must not vary between machines (docs/ARCHITECTURE.md §4 — we ship on macOS,
  Windows and Linux and their filesystems enumerate differently).
- Do NOT author any actual item or recipe content. Framework only. I author content
  by hand in the inspector — that's free, and it's the whole point of this design.

AUTHORITY: none — this is static content loaded identically on every peer. Nothing
here is replicated; nothing here is mutable at runtime.

CONSTRAINTS:
- .gd files only. NEVER touch .tscn/.tres/project.godot (D-007, hook-enforced).
  You cannot register the autoload — tell me what to register.
- Don't explore. Everything you need is in this prompt.

FINISH WITH:
    MIRE_AGENT=content .agent/bin/agent done 2.2 "<what you built>"
    MIRE_AGENT=content .agent/bin/agent ship 2.2 "M2: content resource framework"

`ship` commits only this task's files and pushes to origin. Never `git add -A` —
other agents are working in this same directory and you would commit their
half-written files.

THEN, as your final chat message, tell me:
  - what you verified, with the actual command you ran and its output. If you
    could not run it, say so — do not describe unrun code as working
  - whether the feature actually RUNS now, or only compiles. You registered the
    autoload yourself, so "shipped" and "working" should finally be the same
    thing; if they aren't, say which one this is
  - anything still needing a .tscn/.tres change, which is genuinely mine
  - whether it is safe for me to start the next task

```

---

## Not yet — M4 gate, written down now while the context is fresh

## Task 4.0a — Spike R2b: chunk collision cooking + GPU upload

> **Model: Opus 5 · effort high** · agent name `collide`
> **Do not start this during M1.** It's parked here so the reasoning behind it doesn't have to be
> rebuilt from `FINDINGS.md` F-005 in three milestones' time. Run it immediately before task 4.1.

```
You're working on MIRE, a co-op survival game in Godot 4.7.1. Read AGENTS.md first —
it's the protocol every agent here follows. Then:

    MIRE_AGENT=collide .agent/bin/agent start collide
    MIRE_AGENT=collide .agent/bin/agent claim 4.0a tools/bench_chunk_collide.gd

Keep the MIRE_AGENT=collide prefix on EVERY .agent/bin/agent command you run,
including done and ship. Do not use `export` — each shell call is a fresh process,
so an exported value is gone by your next command and your claims get filed under
the wrong agent without any error.

TASK: Spike R2b. Close the half of spike R2 that was never measured.

BACKGROUND — read this carefully, it is the whole point of the task:
R2 (task 0.7) benchmarked chunk mesh generation at 0.330 ms/chunk and came back GREEN.
It ran HEADLESS against the dummy renderer, so it measured noise sampling and vertex
array construction and NOTHING ELSE — no GPU buffer upload, no material, no collision
shape. R3 (task 0.8) measured NAVIGATION baking, which people assume covers this. It
does not: physics collision cooking is a different code path from Recast navmesh
generation. So the chunk streaming budget for task 4.3 is currently derived from a
number that excludes two costs that could each dominate it.

This is recorded as FINDINGS.md F-005 and as the standing caveat on DECISIONS.md D-015.

Reuse world/chunk/chunk_mesher.gd — it exists and is the real mesher from R2. Do not
rewrite it.

Write one file: tools/bench_chunk_collide.gd — extends SceneTree.

Measure, per 32x32m chunk (33x33 verts), averaged over 100 chunks:
  - ms to cook a ConcavePolygonShape3D from the chunk mesh
  - ms to cook the same as a HeightMapShape3D instead — heightfield chunks may not
    need a trimesh at all, and if the heightfield is much cheaper that is the finding
  - whether cooking is threadable (does it block the main thread? try WorkerThreadPool)
  - memory per cooked shape

CRITICAL: this benchmark must NOT run headless with --headless / the dummy renderer.
That is exactly the mistake that made R2 incomplete. Run it windowed against the real
Forward+ renderer so GPU upload is actually exercised:
  /Applications/Godot.app/Contents/MacOS/Godot --path . --script tools/bench_chunk_collide.gd
Measure mesh upload separately from cooking — instance the ArrayMesh into the live scene
tree and time to first rendered frame, so upload cost lands somewhere real.
If you cannot separate upload from cook cleanly, say so and report the combined number
with that stated plainly. A number with an honest caveat is worth more than a clean
number that quietly measures the wrong thing — that is how we got here.

SUCCESS CRITERIA — state which the measurements support, and remember the budget is
shared with meshing (0.330 ms) and nav baking (0.034 ms main-thread block):
   GREEN : cook + upload < 4 ms/chunk, or cook is threadable → 4.3 streams as designed
   AMBER : 4-15 ms → 4.3 needs a chunk budget per frame; say how many chunks/frame fit
   RED   : >15 ms and not threadable → chunk size or collision strategy must change
           before 4.1 is written. Evaluate HeightMapShape3D-only as the fallback.

AUTHORITY: none — offline generation, no networking.

CONSTRAINTS:
- .gd files only. NEVER create or edit .tscn/.tres/project.godot (D-007, hook-enforced).
- Typed GDScript.
- Deterministic: seeded RandomNumberGenerator / FastNoiseLite.seed only, never global
  randi(). And per D-017 + ARCHITECTURE.md §7, no sin/cos/tan/exp/log/pow anywhere in
  seed-derived generation — those diverge ~1 ULP across platforms.
- Don't explore the codebase beyond chunk_mesher.gd. Ask if genuinely blocked.

FINISH WITH:
    MIRE_AGENT=collide .agent/bin/agent done 4.0a "<the numbers, and which of GREEN/AMBER/RED they support>"
    MIRE_AGENT=collide .agent/bin/agent ship 4.0a "M4: chunk collision + upload spike (R2b)"

`ship` commits only this task's files and pushes to origin. Never `git add -A` —
other agents are working in this same directory and you would commit their
half-written files.

THEN, as your final chat message, tell me:
  - what you verified and the actual numbers/command
  - whether it is safe for me to start 4.1
  - the text to amend onto DECISIONS.md D-015, since this either confirms or
    overturns its GREEN verdict
```

---

## When they finish

Each agent ends with `agent done` or `agent handoff`, which releases its claims and writes
`.agent/JOURNAL.md` itself. `ship` commits and pushes its own files. So there's usually nothing for you
to run — read `.agent/BOARD.md` to see what landed, or ask any chat to summarise it.

What *is* yours: the wiring. Agents can't touch `.tscn`/`.tres`/`project.godot` (D-007), so a shipped
script is often not a working feature until you register an autoload or add a node. Every prompt here
ends by demanding the agent state plainly whether the thing works yet — believe that section over the
word "done".

For 1.2 specifically: **sanity-check the interface snippet it gives you before starting 1.3.** Seven
tasks get written against that shape, so changing it afterwards isn't a fix, it's a refactor across the
milestone. Paste the snippet into a fresh chat and ask whether the API holds up, if you want a second
read on it.
