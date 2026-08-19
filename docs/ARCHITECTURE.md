# MIRE — Technical Architecture

Godot 4.7 · Forward+ · Jolt Physics · GDScript · First-person · Host-authoritative co-op

> **Read this before writing any gameplay code.** Nearly every expensive mistake in a co-op game is an
> architecture mistake made in month 1 and discovered in month 8. Fixing netcode later costs 10× the
> quota of getting it right now — and quota is our scarcest resource (see `AI-WORKFLOW.md`).

---

## 1. The one rule

**Every system is written network-aware from the first line.**

Do not build a singleplayer prototype and "add multiplayer later." This is the #1 killer of co-op
hobby projects. Retrofitting multiplayer means rewriting every system that touches state, which is
most of them. We build the network spine in M1, before any gameplay content, and everything after
plugs into it.

---

## 2. Networking model

### 2.1 Topology: host-authoritative listen server

One player is the host. The host's process runs the authoritative simulation. Other players are
clients. There is no dedicated server (see `DESIGN.md` §7 cut list).

This is what Muck does, it's correct for 3–6 friends, and it's the cheapest thing that works.

```
        HOST (player 1)                      CLIENT (players 2..6)
   ┌────────────────────────┐           ┌────────────────────────┐
   │ Authoritative sim:     │  state →  │ Local prediction:      │
   │  · enemies + AI        │           │  · own movement only   │
   │  · world mutation      │           │                        │
   │  · Mire grid           │  ← input  │ Everything else:       │
   │  · loot / crafting     │           │  · replicated, trusted │
   │  · day/night, waves    │           │  · rendered w/ interp  │
   └────────────────────────┘           └────────────────────────┘
```

### 2.2 Authority table

Decide this once. Every new system must declare which row it's in.

| Domain | Authority | Mechanism | Why |
|---|---|---|---|
| Own player movement | **Client** | Client sends transform; host sanity-checks speed | Feels responsive; cheating is irrelevant among friends |
| Other players' movement | Host relays | `MultiplayerSynchronizer` + interpolation | — |
| Enemies (spawn, AI, damage) | **Host** | `MultiplayerSpawner` + synchronizer | One brain, no desync |
| World mutation (chopped tree, mined ore) | **Host** | RPC request → host validates → replicated delta | Prevents duplicate harvests |
| Carryable objects (heavy hauling, task 3.10) | **Host** | RPC request → host validates carriers → host positions the object each tick from the carriers' own replicated transforms, bounded speed | Carriers' own movement stays client-authoritative (row 1); the OBJECT must never be able to teleport, so the host is the only one that ever writes its transform |
| Inventory / crafting | **Host** | Client requests, host validates & confirms | Prevents item dupes on lag |
| Mire grid | **Host** | Tick delta broadcast (see §5) | — |
| Day/night, wave director, Cycle state, active modifiers | **Host** | Replicated properties | — |
| Attunement selection (task 3.9) | **Host** | RPC request → host validates one-time lock → grants a PowerupService modifier → broadcast to all | A double-pick or a desynced roster is worse than a slow one; every peer needs to see every player's role to self-organize (DESIGN §4.5) |
| Command execution (task 3.13) | **Host** for mutating commands; client submits, host validates op status and executes; results return to the issuer. Parsing/UI/read-only commands are client-local. | New reliable `net_submit_command`/`net_command_result` pair; host re-parses the raw line from scratch, never the client's parse | One brain for every mutation, same as the systems the commands drive |
| Gamerules (task 3.14) | **Host**. `RuleService` holds every rule's live value; only the host sets one. Clients read a replicated copy and never write. | New reliable pair: `net_rule_snapshot` (host → one joining peer, the full id → value map) and `net_rule_changed` (host → everyone, one id) | A rule is a knob on the simulation, and the simulation has one brain. The snapshot exists because a mid-run joiner was never present for the changes already made, and a rule disagreement is the kind nobody notices until its consequence lands. Values are runtime-only — no persistence (D-010), so every peer boots on the same authored defaults |
| Entity addressing / selectors (task 3.15) | **Host-side registry, not replicated.** A selector resolves wherever the command executes: a HOST command against the host's complete directory, a LOCAL read against that machine's own replicated view | No RPC of its own. `EntityDirectory` discovers by node group (D-088); `tp` on a player reuses `PlayerHealth`'s existing `net_force_respawn` | Selectors address the simulation, and the host is the only peer that can see all of it. `tp` on a **player** never writes a transform — own movement is client-authoritative (row 1), so the host asks that peer's client to place itself; `kill` routes through each owner's existing damage seam. Commands wrap host seams, they never grow a second mutation path |
| Player display names (F-157) | **Host.** `NetTransport` holds the canonical peer id → display name map (`_display_names`); only the host applies a submitted name (sanitized) and decides what every peer reads. | New reliable `net_request_display_name` (client → host, one raw String), `net_display_name_changed` (host → every remote, one id + its sanitized name), `net_display_name_snapshot` (host → one newly admitted peer, the full map). No `PROTOCOL_VERSION` bump yet — `core/net/net_version.gd` was held by another lane's exact-file claim for this task's whole session, continuing F-161/F-165/F-169's gap (F-178). | A client-chosen name is untrusted input crossing the wire, the same stance every other write RPC in this project takes (D-078's neighbor) — the host is the only peer allowed to decide what lands in the map everyone else reads, so a future `op <name>`-style resolution can trust it. Two peers picking the same name is allowed, not deduped: `CommandService._parse_peer()` (F-157's own consumer) refuses an ambiguous name rather than guessing which peer it means, the same "never guess" stance `@r`'s random-pick is the deliberate exception to elsewhere in the selector grammar |
| POI placement (task 4.7) | **None — derived, not owned.** Every peer computes the identical site list from the shared world seed plus `content/poi/*.tres` | Never sent over the wire | Same reasoning as terrain (§4): a POI position is a pure function of `(world_seed, content)`, so replicating it would pay bandwidth for something both sides can already compute. `PoiMap` is static and node-free, mixes seeds with integer multiply/xor only, and sorts defs by `placement_priority` then `id` — never by directory-scan order — so two peers cannot disagree (D-095) |
| Navigation baking (task 4.5) | **Host only.** `NavBaker` keeps one navigation map in step with the host's LOD0 chunks; a client peer bakes nothing | No RPC — the map is derived from terrain, never sent | Pathfinding is host-authoritative (D-016) and enemies are host-owned bodies, so a client has nothing to path; baking on all six peers would pay the cost six times for one useful result. Regions attach and retire with the LOD0/collision ring (D-101) |
| Chunk streaming / terrain LOD (task 4.3) | **Client-local**, independently per peer | `ChunkStreamer` streams a ring of chunks around its own anchors; nothing about which chunks are resident is ever sent over the wire | Terrain is never replicated (§4) — every peer regenerates it from the shared seed, so a host and a client streaming different chunk sets around their own local players is correct, not a desync. Only the terrain *content* at a given point must agree cross-peer, and that is `IslandHeightmap`/`ChunkMesher`'s job (both pure and cross-platform-safe), not the streamer's |
| Wellspring ritual — capped state, channel progress, defense wave, re-corruption clock (tasks 4.8, 6.4) | **Host**. `Wellspring` holds `capped`/`channeling`/`progress_sec`/`duration_sec`/`required_players`/`recorruption_sec`/`has_recorrupted`; only the host advances or resolves them. | New reliable `net_request_toggle_channel` (client → host, start/cancel); a code-built `SceneReplicationConfig`, all ON_CHANGE, same shape as `Chest.opened` | A client-side ritual timer or presence count is exactly the "two clients disagree" case below — how many players are close enough, and whether the timer has actually elapsed, has to be one answer. The defense wave rides `EnemyWorld`'s existing `MultiplayerSpawner`, so this adds no spawn RPC of its own. Task 6.4's re-corruption clock is the same reasoning applied to decay: only the host ticks `recorruption_sec` (paused, not reset, while a placed Ward covers the Wellspring — `BuildService.ward_radii()`, `MireGrid`'s own provider seam), and only the host decides when it flips `capped` back to false and fires `EventBus.emit_wellspring_recorrupted()`, `MireGrid`'s seam to undo the spread-rate reduction the cap granted |
| Extraction — shipwreck repair stages, board/departure group-confirm hold (task 6.5) | **Host.** `ExtractionShip` holds `repair_stage`/`departure_channeling`/`departure_progress_sec`/`departure_required_players`/`departed`; only the host advances or resolves them. | New reliable `net_request_repair` and `net_request_toggle_departure` (client → host, both carry no data). Code-built `SceneReplicationConfig`, all ON_CHANGE, same shape as Wellspring's own. No `PROTOCOL_VERSION` bump yet — `core/net/net_version.gd` was held by another lane's claim for this task's whole session (F-165, same gap F-161 already recorded for task 5.3). | Same "harvest pattern" as Wellspring/Chest: a request carries no item counts or stage number, the host alone re-derives whether the requester is in range, holds a repair hammer, and can afford the current stage — a client-decided outcome here is exactly the "two clients disagree" case the rule of thumb below exists for. The departure hold reuses Wellspring's own presence-gated ritual FSM (D-105) rather than a per-peer ready-vote, with `departure_required_players` snapshotting the whole connected session rather than Wellspring's 1-2 — DESIGN.md §5.2's extraction is a decision the whole crew makes together, not one player acting alone |
| Ranged weapons — bow draw, arrow flight, hit resolution (task 5.3) | **Host.** `RangedCombatService` holds every in-flight shot per peer; only the host advances the draw clock, simulates the flight, consumes ammo, and decides a connect. | New reliable `net_request_shot` (client → host, hotbar slot only, no aim vector), `net_shot_fired` (host → everyone, cosmetic spawn: origin/direction/speed/gravity), `net_shot_resolved` (host → everyone, authoritative hit/miss). No `PROTOCOL_VERSION` bump yet — D-102/F-161, `core/net/net_version.gd` was held by another lane's claim for this task's whole session. | Same split as melee (2.8): the host derives aim from the shooter's own already-replicated transform (`systems/combat/aim_util.gd`, shared with melee) rather than trusting a client-sent vector, and is the only peer that decides a hit — the difference is a bow's flight is variable-length, so the host also owns the SIMULATION (one raycast per physics tick), not just the resolution instant. The flight visual costs one broadcast, not per-tick sync (§2.5) — every peer already has enough (origin/direction/speed/gravity) to extrapolate the identical path itself |
| Salvage — meta-progression currency, persisted across runs (task 6.6) | **None.** Per-player account state, not simulation state — no two peers ever compare balances. `SalvageService` (autoload) runs identically on every peer, banking only into that peer's own `user://salvage.json`. | No RPC. Reacts to `EventBus.run_extracted`/`run_wiped`/`wellspring_capped`, all process-local — `ExtractionShip.departed` and `Wellspring.capped` both fire their `EventBus` emit from the property's own setter (D-107's pattern, F-168 applied it to the latter), so the signal reaches every peer's own bus, not just the host's. `Wellspring._finish_recorruption()`'s `emit_wellspring_recorrupted` still has the old host-only shape (F-181) — no live undercount yet, since nothing subscribes to it. | The rule of thumb below only governs state two clients could disagree about; Salvage has no such state to disagree over, so it is the first §2.2 row with authority "None" that isn't a pure-derived value (POI placement) or a pure-cosmetic (VFX/audio/UI) — it is genuinely private per-account data, the same category a Steam achievement or a local settings file falls into |
| Lose condition — team wipe / island consumed (task 6.7) | **Host** decides; the verdict reaches every peer through a reliable broadcast RPC, not a `MultiplayerSynchronizer`. `DefeatService` holds `defeated`/`cause`; only the host polls `PlayerHealth.host_is_alive()` across every present peer and `MireGrid.consumed_fraction()`. | New reliable `net_run_defeated` (host → everyone). No `PROTOCOL_VERSION` bump yet — `core/net/net_version.gd` was held by another lane's claim for this task's whole session (F-169, same gap F-161/F-165 already recorded for tasks 5.3/6.5). | Whether the run has ended is exactly the "two clients disagree" case — one peer still playing while another already sees a defeat screen is not a difference of opinion this game can afford. Not a synchronizer (D-023's usual mechanism for host-authoritative entities): those exist to bring a LATE JOINER up to date, and a run that just ended has nothing left to join. `defeated`'s setter fires `EventBus.emit_run_wiped()` — reached identically whether this process decided the verdict itself (the host) or received it over the wire (`net_run_defeated`, a client) — the same fix D-107/D-108 required, which `Wellspring.capped`'s setter now also applies (F-168) |
| Unlocks — meta-progression tree, "variety never power" (task 6.9, DESIGN.md §4.6) | **None.** Same shape as Salvage's own row (task 6.6) — per-player account state, no two peers ever compare purchased sets. `UnlockService` (autoload) runs identically on every peer, spending only that peer's own Salvage (`SalvageService.spend_salvage()`) and persisting only into that peer's own `user://unlocks.json`. | No RPC. `purchase(unlock_id)` is a local call; `EventBus.emit_unlock_purchased()` is process-local, the same "future task's hook" role `salvage_banked` plays. `is_content_unlocked()` gates `LootTableDef.roll()`'s POWERUP entries (F-173/D-111): `Chest` only ever asks it from the HOST process's own instance (`roll()` runs solely inside `_accept_open_request()`, which only executes host-side), so the party's odds are the HOST's own unlock set, not the opening peer's — a caller that trusted a value carried in from another peer would break this. | An unlock is exactly as private as the Salvage that bought it — nothing about which rows a player has purchased is simulation state two peers could disagree over. D-111's other open half: POI placement and the enemy roster must be byte-identical across every peer, which a per-peer unlock set cannot satisfy through this same "ask the host" trick — that still needs either replicated purchases or a session-wide unlock tree before it can gate either one |
| VFX, audio, camera, UI | **Client-local** | Never networked | Never pay bandwidth for cosmetics |

> **The rule of thumb:** if two clients disagreeing about it would cause a bug, the host owns it.
> If disagreeing is harmless (a particle, a footstep sound), keep it local and free.

### 2.3 Transport abstraction — build this in M1, never touch it again

A single autoload `NetTransport` that can swap peer implementations:

| Mode | Peer | Used for |
|---|---|---|
| `LOCAL` | `ENetMultiplayerPeer` on 127.0.0.1 | **Daily development.** Two windows, one machine, no Steam client, instant restart. |
| `LAN` | `ENetMultiplayerPeer` | Testing on a second physical machine |
| `STEAM` | `SteamMultiplayerPeer` (GodotSteam) | Real play with friends, and shipping |

**Why this matters enormously for us:** iterating on Steam P2P requires the Steam client running and
is slow to restart. `LOCAL` mode lets you test multiplayer changes in ~3 seconds. Over the project
this saves hundreds of hours *and* a great deal of quota (fewer "why doesn't this work" debugging
sessions). This abstraction is maybe 150 lines and is the highest-ROI code in the project.

### 2.4 Steam integration

- **GodotSteam GDExtension (4.4+ branch)** — works with the *stock* Godot 4.7 editor and stock export
  templates. No custom engine build. Install via the Godot Asset Store.
- **`SteamMultiplayerPeer`** ships in the main GodotSteam branches and plugs into Godot's high-level
  multiplayer API, so the same RPC/synchronizer code works across all three transports.
- **Develop against App ID 480 (Spacewar)** — Valve's public test app. Anyone with a Steam account can
  use it for lobbies and P2P *without buying an App ID*. Do not spend $100 until M7.
  - Caveat: 480 is shared by every developer testing, so the public lobby list is full of junk.
    Always use friend-invite or direct-join by lobby ID, never a public lobby browser.
- Real App ID replaces 480 as a **one-line config change** if you route it through `NetTransport`.

### 2.5 Interest management

With 6 players on a large island, replicating everything to everyone is wasteful. Godot's
`MultiplayerSynchronizer` supports visibility filters — use them from the start:

- Enemies/props replicate only to peers within ~120m
- Set `replication_interval` per node class: players 30Hz, enemies 15Hz, props/containers on-change only

Doing this at M1 is nearly free. Doing it at M6 means auditing every entity in the game.

---

## 3. Project structure

Godot's `res://` layout. One system per folder, one responsibility per file. Small files are a
**quota optimization** — an agent that must read 2,000 lines to change one thing burns 10× the tokens
of one that reads 200.

```
res://
├── addons/                     # GodotSteam, editor plugins (gitignored where possible)
├── autoload/
│   ├── net_transport.gd        # §2.3 — transport swap, lobby create/join
│   ├── game_state.gd           # act, day, seed, run status (host-authoritative)
│   ├── event_bus.gd            # local signal hub, decouples systems
│   └── registry.gd             # loads all .tres content resources at boot
├── core/
│   ├── net/                    # rpc helpers, authority utils, interpolation
│   ├── save/                   # meta-progression persistence (Salvage/unlocks)
│   └── util/
├── world/
│   ├── gen/                    # island generation, biome placement, POI scatter
│   ├── chunk/                  # chunk streaming, mesh building, nav baking
│   └── mire/                   # the Mire grid sim + visualization
├── entities/
│   ├── player/                 # controller, camera, viewmodel, inventory
│   ├── enemies/                # base enemy, AI states, per-enemy scenes
│   ├── props/                  # harvestable nodes, containers
│   └── structures/             # buildables, Wards
├── systems/
│   ├── crafting/  inventory/  combat/  powerups/  waves/  daynight/
├── content/                    # ← DATA, not code. .tres resources.
│   ├── items/  powerups/  enemies/  recipes/  biomes/
├── ui/
│   ├── hud/  menus/  lobby/  inventory/
└── docs/                       # ← you are here
```

### 3.1 Content is data, not code

Items, powerups, recipes, enemy stats are **Godot `Resource` (.tres) files** defined by a small set of
custom `Resource` scripts, loaded at boot by `registry.gd`.

This is the most important structural decision after netcode, for three reasons:
1. **You can author content in the Godot inspector for free** — zero quota per item.
2. Adding the 40th powerup costs the same as the 2nd. No code change, no agent call.
3. Balance tuning is editing numbers in the editor, not editing code.

**Build the framework once with tokens. Author the content yourself by hand.** A 60-powerup game
should cost you roughly 60 powerups' worth of *typing*, and zero powerups' worth of *quota*.

---

## 4. World generation

**Seeded and reproducible.** The host picks a seed; the seed is replicated to clients.

**Terrain replication strategy — important:**
Clients **regenerate terrain locally from the seed**. We never send mesh or heightmap data over the
network. Only *mutable* state (which tree is chopped, which ore is mined, which container is opened)
is host-authoritative and replicated as small deltas.

This keeps join bandwidth near zero and is the standard approach. It requires generation to be
deterministic given a seed — use explicit `RandomNumberGenerator` instances seeded per-subsystem,
**never the global `randi()`**, which will desync.

**Measured and confirmed viable (D-017), with one constraint:** everything in the pipeline below must
stay inside the world-gen safe set in §7 — no `sin`/`cos`/`pow`/`exp`/`log`, because those are not
bit-identical across CPU architectures. `FastNoiseLite` itself is, which is why this design survives.
The island falloff is `1.0 - d * d * d`, never `1.0 - pow(d, 3.0)`.

**Pipeline:**
1. Heightmap from layered noise (`FastNoiseLite`) masked to an island falloff
2. Biome assignment from height + moisture noise
3. Chunked mesh generation (e.g. 32×32m chunks) with 2–3 LOD levels
4. POI placement (Wellsprings, shipwreck, camps) via seeded Poisson-disc — placed *before* resources
5. Resource scatter per biome via `MultiMeshInstance3D` (thousands of trees in a handful of draw calls)
6. Runtime nav baking per chunk (see §6 risk R3)

---

## 5. The Mire simulation

`world/mire/mire_grid.gd`, host-authoritative.

- 256×256 `PackedFloat32Array` over island bounds, one cell ≈ 4m
- Tick every 2s: for each corrupted cell, bleed corruption into neighbours at the current Cycle's rate
- Wellspring caps subtract corruption in a radius; Wards resist accumulation in a radius
- **Replication:** send only *changed* cells as `(index, value)` pairs since last tick, batched into a
  `PackedByteArray` RPC. A typical tick changes a few hundred cells — trivially small.
- **Visualization is entirely client-side:** the grid drives a texture uploaded to a shader that
  controls ground tint, fog density, and particle spawn. No extra bandwidth for the pretty part.

This system is deliberately chosen to be **high design value, low engineering risk** — a 2D scalar
grid is one of the easiest things to simulate, replicate, and debug.

The 2s tick is **accumulated wall-clock time, not a frame count** — see §5a.

---

## 5a. Time, tick rate, and frame rate

**The rule: nothing about how the game plays may depend on the monitor's refresh rate.** A player on a
60 Hz laptop and a player on a 240 Hz desktop, in the same lobby, must experience identical movement
speed, identical jump height, identical corruption spread, identical damage over time. Refresh rate
buys smoothness and nothing else. This is a correctness requirement, not a polish item — in a
host-authoritative co-op game, a system that ties simulation to frames is a desync, not just a
feel bug.

### The two clocks

Godot runs two independent loops, and the distinction is the whole of this section.

| | `_physics_process(delta)` | `_process(delta)` |
|---|---|---|
| Rate | **Fixed 60 Hz**, set by `physics/common/physics_ticks_per_second` | Variable — one call per rendered frame |
| `delta` | Always `1.0/60.0`. Constant. | Whatever the last frame took. Varies constantly. |
| Tied to monitor? | **No** | Yes |
| Use for | Movement, gravity, collision, combat, anything simulated or replicated | Rendering, camera smoothing, UI, VFX, audio triggers |

The engine accumulates elapsed real time and runs however many physics steps that time owes. On a
120 Hz display you get 120 render frames and still exactly 60 physics ticks per second. **The classic
"game runs at double speed on a 120 Hz monitor" bug comes from a fixed timestep with no accumulator,
where one simulation step is hard-wired to one rendered frame. Godot does not work that way, and we
must not reintroduce it.**

### Required project settings

| Setting | Value | Why |
|---|---|---|
| `physics/common/physics_ticks_per_second` | `60` | The simulation rate. Changing this changes game feel and invalidates every tuned constant — treat it as frozen after M0. |
| `physics/common/max_physics_steps_per_frame` | `8` | Catch-up cap. Below ~7.5 fps the game runs in slow motion instead of spiralling. Correct tradeoff; know it exists when profiling. |
| `physics/common/physics_interpolation` | `true` | Renders bodies smoothly *between* the 60 Hz ticks. Without it, high-refresh displays show judder on everything not directly player-controlled. Load-bearing — see *Variable refresh rate* below. |
| `physics/common/physics_jitter_fix` | `0` | Its correction assumes a **stable** refresh rate, which is false on VRR, and it duplicates what interpolation does properly. Off. |
| `display/window/vsync/vsync_mode` | `enabled` (default), player-overridable | Ships as the safe default; exposed in settings (7.5). |
| `application/run/max_fps` | `0` (uncapped), player-overridable | An fps cap must never change simulation behaviour. If it does, something violates this section. |

> **Four of these six equal the engine default, and that's fine — do not chase pinning them into
> `project.godot` by hand.** Godot writes only settings whose value differs from the default and
> prunes the rest on *every* save the editor performs, not only a Project Settings edit — any action
> that resaves the file (setting the main scene did it once) silently drops them again regardless of
> how they got there. Hand-editing the file is not a fix, it's F-003 again on a timer (see
> `FINDINGS.md`). The value is correct either way, because absence just means "use the default," which
> already **is** the target value. The actual protection against a future engine default changing this
> out from under us is the version pin below, not file text — an upgrade is already the moment to
> re-check this table. `tools/verify_setup.gd` asserts the *effective* runtime values via
> `ProjectSettings.get_setting()`, which is correct whether the value comes from the file or the
> engine default and isn't fooled by pruning either way.

### Rules for writing systems

1. **Simulation goes in `_physics_process`.** Movement, gravity, combat, health, hunger, stamina,
   enemy AI stepping, projectiles. If it affects game state or is replicated, it belongs here.
2. **Multiply every rate by `delta`.** A value expressed per-second times `delta` gives the amount for
   this step. `velocity.y -= gravity * delta`, never `velocity.y -= gravity`.
3. **Never count frames.** No `if frame_count % 30 == 0`. Accumulate time:
   ```gdscript
   _elapsed += delta
   while _elapsed >= TICK_INTERVAL:
       _elapsed -= TICK_INTERVAL
       _do_tick()
   ```
   The `while` (not `if`) matters — it stays correct across a hitch that spans several intervals.
   This is how the Mire's 2s tick (§5), wave spawning, and every other periodic system must work.
4. **Mouse input is the exception: do *not* multiply by `delta`.** Mouse motion events already
   accumulate the distance moved. Delta-scaling them makes sensitivity depend on framerate — the bug
   people introduce while trying to avoid the one this section is about. Read `relative` in
   `_input`/`_unhandled_input` and apply it directly.
5. **Gamepad look *is* delta-scaled** — a stick reports a rate, not a displacement. The two input
   paths are genuinely different; don't unify them.
6. **Exponential smoothing needs the framerate-correct form.** `lerp(a, b, speed * delta)` converges
   at different rates on different hardware. For anything gameplay-visible use
   `lerp(a, b, 1.0 - exp(-speed * delta))`. For pure cosmetics the naive form is tolerable — say so
   in a comment so the next reader knows it was a choice.
7. **Never use `Engine.get_frames_per_second()` or frame counts as a time source** in game logic.
   Debug overlay only.
8. **Timers:** `Timer` nodes and `await get_tree().create_timer()` run on wall-clock time and are fine
   for UI and one-shot effects. For anything host-authoritative or replicated, prefer an accumulator
   in `_physics_process` so the timing is tied to the same clock the simulation uses.

### Variable refresh rate (G-Sync, FreeSync, ProMotion)

VRR displays vary their refresh rate continuously — a ProMotion Mac drifts anywhere in 48–120 Hz
depending on what the compositor is doing. **This does not affect simulation speed**; the accumulator
above is indifferent to how long a frame took. It affects *smoothness*, and it is the most commonly
noticed way a fixed-timestep game feels broken on modern hardware.

The mechanism: a rendered frame usually lands *between* two 60 Hz ticks. Without interpolation the
renderer draws the last completed tick, so on any refresh rate that isn't a clean multiple of 60, some
frames advance two ticks and some advance one — objects move in uneven jumps. At a fixed 144 Hz this
is a repeating artifact the eye learns to ignore. Under VRR the refresh rate drifts, so the pattern
keeps reshuffling and never settles into something ignorable. **VRR feels worse than a plain
mismatched refresh rate for this reason**, and it's why some games are specifically annoying on VRR
panels while fine everywhere else.

What follows from that:

- **`physics_interpolation` is the fix, and it is not optional.** Everything else here is secondary.
- **`physics_jitter_fix` must be `0`.** It nudges the physics delta toward the display's refresh
  interval, which assumes that interval is stable. Under VRR it chases a moving target and adds the
  jitter it exists to remove. It also overlaps with interpolation, so running both invites the two
  corrections to fight. *(Confirm the current default and semantics against the Godot 4.7 docs when
  applying these settings — this is stated from the mechanism, not from a doc read.)*
- **Don't render past the panel's maximum.** Above it you drop out of the VRR window and fall back to
  ordinary vsync behaviour, reintroducing the tearing or latency VRR was there to avoid. The usual
  mitigation is capping a few fps below the panel maximum — a **settings-menu affordance (7.5), not a
  hardcoded number**, since it depends on the player's display.
- **Never derive gameplay timing from the frame rate.** Already rule 7, restated because VRR is where
  that mistake stops being theoretical: the frame rate is now a continuously moving number.

Testing this needs a real VRR panel — the failure is a smoothness artifact that no headless run and no
frame-time graph will surface. Add it to the 7.12 hardware pass, and check it on Steam Deck, whose
display is also variable-refresh.

### What this means for networking

Physics ticks are the shared heartbeat between host and clients. Because the rate is fixed and
identical on every machine regardless of hardware, tick counts are directly comparable across peers —
which is what makes host-authoritative validation and the determinism work in §6a meaningful. A
client rendering at 240 fps sends no more input than one at 60 fps, because input is sampled per
physics tick, not per frame. Replication intervals (§2.5) are expressed in seconds and converted
against the physics rate, never against frames.

### How to verify

Any system touching movement, timing, or simulation is not done until this is checked:

- Run the same action at capped 30 fps, uncapped, and with vsync forced at a different rate. Distance
  travelled, jump apex, and elapsed time to complete must match within float tolerance.
- Two instances in a `LOCAL` lobby (task 1.3) with different fps caps — one 30, one uncapped — must
  stay in agreement on position and world state.
- Watch for judder rather than speed differences on high-refresh displays; that's an interpolation
  problem, not a timestep problem, and has a different fix.

---

## 6. Technical risks — spike these before committing

A "spike" = a throwaway prototype that answers one question. Timebox each to 1–2 sessions. If a spike
fails, that's a *success* — you found it in week 3 instead of month 8.

| # | Risk | Spike | Fallback if it fails |
|---|---|---|---|
| **R1** | Godot high-level multiplayer can't handle 6 players + hundreds of entities | M1: 6 fake peers, 200 synced dummies, measure bandwidth/CPU | Hand-rolled binary state packets over raw ENet |
| **R2** | Chunked terrain streaming stutters (GDScript mesh gen is slow) | M0: generate 100 chunks, measure frame times | Move mesh gen to `WorkerThreadPool`; then to GDExtension/C# if truly needed |
| **R3** | **Runtime NavMesh baking on procedural chunks** — the known-hardest part of this project in Godot | M0/M4: bake nav on a generated chunk at runtime, measure hitch | Grid-based A* on the heightmap instead of NavMesh; or pre-bake at gen time and accept longer load |
| **R4** | Mire grid replication too chatty at scale | M4: worst-case tick, measure bytes | Lower tick rate; send run-length-encoded rows; region-of-interest only |
| **R5** | GodotSteam breaks on a Godot 4.7 point release | M1: verify, then **pin the Godot version** | Stay pinned; upgrade deliberately, never casually |
| **R6** ✅ | **Seeded world gen diverges between macOS arm64 and Windows x86_64** — two players, same lobby, different islands | M0: run `tools/check_determinism.gd` on both, compare hashes | Host generates and ships a compact heightmap; clients stop regenerating (costs bandwidth on join) |

> **R3 is the one to worry about.** Enemy pathfinding on runtime-generated terrain is where Godot is
> weakest and where an unprepared project stalls hardest. Spike it in M0, not M5.
>
> **Spiked in M0 (task 0.8) — GREEN.** See `DECISIONS.md` D-016. The fallback is dropped; we keep
> `NavigationServer3D`. Read §6b before writing any navigation code.

### 6b. Navigation API traps in Godot 4.7.1

Four behaviours found while spiking R3 that cost real time to diagnose. All four fail *silently* —
no error, no warning, just a wrong result — so nothing in the engine will tell you about them. Working
examples of all four are in `world/chunk/nav_bake_probe.gd` and `tools/bench_navbake.gd`.

**1. Triangle winding is inverted from the usual convention, and getting it wrong bakes nothing.**
Godot's Recast bridge treats a triangle as up-facing when `cross(v1-v0, v2-v0).y` is **negative**. Feed
it faces wound the conventional way and the bake returns *success* with **zero polygons** — no error,
no warning. This is the single most expensive trap here; it looks exactly like "navigation is broken."

**2. A navigation map is not queryable until the server syncs it on a physics frame,** and both
obvious readiness signals lie. `map_force_update()` does not force the sync, and
`map_get_iteration_id()` reaches `1` while the polygon graph is still empty. Querying early fails with
*"query failed because it was made before first map synchronization."* Poll an actual query — e.g.
`map_get_closest_point()` returning something other than `Vector3.ZERO` — not a readiness flag.

**3. `NavigationMesh.cell_size` must equal the map's cell size.** Mismatched, region edges rasterize
onto different grids and connections silently misbehave. Godot warns for this one, at least.

**4. `filter_baking_aabb` filters *source geometry*, not output polygons.** It is the obvious tool for
trimming a chunk bake back to its footprint and it does not do that — it removes input triangles
before the bake, so agent-radius erosion still eats the edge. `border_size` makes it worse: it shrinks
the result further (a 4 m border produced an 8 m hole). Neither is the seam fix. The seam fix is
`map_set_edge_connection_margin` > `2 × agent_radius`, per D-016.

---

## 6a. Cross-platform: macOS + Windows + Linux, playing together

**Requirement:** the game ships on macOS, Windows and Linux, and any mix of those players must be able
to play in the same lobby. This is a first-class constraint, not a port done later.

**Bonus:** a native Linux build makes **Steam Deck** support nearly free — SteamOS is Arch Linux, so the
Linux binary runs directly rather than through Proton. Aim for Deck *compatible* (see `STEAM.md` §6);
verification remains out of scope.

### What already handles it

- **Steam P2P is platform-agnostic.** One App ID, one lobby, any mix of platforms. Muck itself does
  exactly this. Choosing `SteamMultiplayerPeer` (§2.4) means cross-play costs no extra work.
- **Godot exports to both natively** from one project, from either OS.
- Godot's high-level multiplayer serialises its own types consistently across platforms.

### What does not, and needs deliberate work

| Concern | Why it bites | What to do |
|---|---|---|
| **World-gen determinism (R6)** — *macOS↔Linux measured, D-017* | Clients regenerate terrain from a seed (§4). `sin`/`cos`/`pow` are **confirmed** not bit-identical across CPU architectures; `FastNoiseLite`, `sqrt` and basic arithmetic **are**. Divergence means different islands. | Keep world gen inside the §7 safe set. Run `tools/check_determinism.gd` on Windows to close the last column. |
| **Build-version mismatch** | Steam updates clients at different times; a 1.2 host and a 1.1 client desync in confusing ways. | Protocol-version handshake on join; refuse mismatched builds with a clear message. Task 1.11. |
| **Path case sensitivity** | Linux filesystems are case-**sensitive**; macOS and Windows usually are not. A wrong-case `res://` path works on your Mac and breaks on Linux. | Always match case exactly. Useful side effect: **test on Linux and this class of bug surfaces immediately.** |
| **GodotSteam binaries** | The GDExtension ships per-platform libraries. A platform-specific download fails to load on the others. | Install the full release with all platform binaries; verify the `.gdextension` lists macOS, Windows and Linux. |
| **Steam redistributables** | `libsteam_api.dylib` (macOS), `steam_api64.dll` (Windows) and `libsteam_api.so` (Linux) must ship next to each export. | Part of the export preset checklist, task 7.11. |
| **Architecture slices** | Apple Silicon vs Intel; Linux x86_64 vs arm64. | macOS universal (arm64 + x86_64); Linux x86_64 only unless someone asks. |
| **macOS signing / notarisation** | Unsigned Mac builds hit Gatekeeper and look broken to your friends. | Sign and notarise. Task 8.10 — needs an Apple Developer account ($99/yr), so budget for it. |
| **Linux desktop variance** | Wayland vs X11, driver quality, glibc versions. Far more variable than the other two. | Godot 4.7 handles both session types. Test on one mainstream distro plus Steam Deck; don't chase the long tail. |
| **Modifier keys** | Cmd on macOS vs Ctrl elsewhere. | Bind by action, never hardcode a modifier. Already the convention. |
| **Line endings** | Godot text files across three OSes. | Handled — `.gitattributes` normalises to LF. |

### Determinism baseline

Recorded from `tools/check_determinism.gd`. **All three shipping desktop platforms are now measured;
task `4.0b` closed the Windows column on 2026-08-16.**

| | macOS arm64 | Linux x86_64 | Windows x86_64 |
|---|---|---|---|
| `rng_sequence` | `0077d6b42cd6f78f` | `0077d6b42cd6f78f` ✅ | `0077d6b42cd6f78f` ✅ |
| `noise_simplex` | `181e558b7b4841cf` | `181e558b7b4841cf` ✅ | `181e558b7b4841cf` ✅ |
| `noise_perlin` | `6c7a944516e3e64f` | `6c7a944516e3e64f` ✅ | `6c7a944516e3e64f` ✅ |
| `float_math` | `063eec62c34fa4ee` | `187304c753e6e1ce` ❌ | `9a92d5895a7daf08` ❌ |

Godot 4.7.1-stable build `a13da4feb` in every case — a version difference invalidates the comparison.
Linux measured 2026-08-15 on an Unraid KVM guest (Ryzen 5 3600X, Ubuntu, glibc). Windows measured
twice, identically, on 2026-08-16 on a physical Ryzen 5 5600 / Windows 11 25H2 machine. The four
safe-operation hashes also matched macOS arm64 exactly: `arith a26c08c6939c9c70`,
`sqrt 8df50e64f11d53c4`, `vec2_length baa1bfdb8ba31f7b`, and
`falloff_safe fd601eb57df68bf0`.

`float_math` bundles six operations, so a follow-up probe split them per-operation. The result (D-017)
is that the divergence falls exactly on the IEEE-754 line:

| Bit-identical across architectures | Diverges (1 ULP, compounding) |
|---|---|
| `+ − × ÷` — correctly rounded by IEEE-754 | `sin` `cos` `tan` |
| `sqrt` — also correctly rounded by IEEE-754 | `exp` `log` |
| `Vector2/3.length()` — built on `sqrt` | `pow`, at any exponent |
| `FastNoiseLite` — integer hash + polynomial, never calls libm | |
| Seeded `RandomNumberGenerator` — integer PRNG | |

**So §4 stands, conditional on the §7 world-gen safe-set rule.** The noise that actually builds the
island is bit-identical; only raw libm calls diverge, and world gen does not need them. If
`rng_sequence` or `noise_*` had differed, the §6 R6 fallback would have been mandatory instead.

Not yet covered: `TYPE_CELLULAR` and domain warp are separate code paths and were not tested. Re-run
the probe before world gen uses either.

---

## 7. Conventions

- **GDScript**, static typing everywhere (`var hp: int = 100`). Typed GDScript is meaningfully faster
  and catches errors at parse time — free correctness.
- Signals via `event_bus` for cross-system comms; direct refs only within a system.
- `snake_case` files/functions, `PascalCase` classes/nodes, `SCREAMING_CASE` constants.
- Every networked function is prefixed `net_` or annotated at the top of the file with its authority row (§2.2).
- **Simulation in `_physics_process`, rendering in `_process`; every rate multiplied by `delta`; never
  count frames** (§5a). Refresh rate must never change how the game plays.
- **Pin the Godot version.** Record it in `DECISIONS.md`. Do not upgrade mid-milestone.
- No `randi()` in world generation — always a seeded `RandomNumberGenerator`.
- **No transcendentals in world generation.** Anything a client regenerates from a seed (§4) may use
  only the safe set: `+ − × ÷`, `sqrt`, `Vector2/3.length()`, `FastNoiseLite`, and a seeded
  `RandomNumberGenerator`. **`sin` `cos` `tan` `exp` `log` `pow` are banned there** — they resolve to
  the platform's libm, which is not bit-identical across architectures, and one ULP of drift means two
  players stand on different islands (D-017). Write `pow(d, 3.0)` as `d * d * d`; it is exact, and
  faster. Outside world gen — rendering, UI, animation, anything not regenerated from a seed — they
  are fine.

---

## 8. Why Godot and not Unity

Muck was Unity. We're staying in Godot 4.7 anyway:

- You already know it — no engine-learning tax on top of the netcode-learning tax
- The project is already created here with Jolt and Forward+ configured
- Godot's high-level multiplayer API (`MultiplayerSpawner`/`MultiplayerSynchronizer`) is genuinely
  good for exactly this topology
- MIT licensed, no revenue share, no per-seat cost
- Small text-based project files work well with AI agents and git

The honest tradeoffs: fewer ready-made 3D tutorials for open-world streaming, weaker runtime nav
tooling (risk R3), and a smaller asset ecosystem. All manageable; none worth a rewrite.
