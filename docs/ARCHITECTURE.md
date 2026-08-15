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
| Inventory / crafting | **Host** | Client requests, host validates & confirms | Prevents item dupes on lag |
| Mire grid | **Host** | Tick delta broadcast (see §5) | — |
| Day/night, wave director, Cycle state, active modifiers | **Host** | Replicated properties | — |
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

> **R3 is the one to worry about.** Enemy pathfinding on runtime-generated terrain is where Godot is
> weakest and where an unprepared project stalls hardest. Spike it in M0, not M5.

---

## 7. Conventions

- **GDScript**, static typing everywhere (`var hp: int = 100`). Typed GDScript is meaningfully faster
  and catches errors at parse time — free correctness.
- Signals via `event_bus` for cross-system comms; direct refs only within a system.
- `snake_case` files/functions, `PascalCase` classes/nodes, `SCREAMING_CASE` constants.
- Every networked function is prefixed `net_` or annotated at the top of the file with its authority row (§2.2).
- **Pin the Godot version.** Record it in `DECISIONS.md`. Do not upgrade mid-milestone.
- No `randi()` in world generation — always a seeded `RandomNumberGenerator`.

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
