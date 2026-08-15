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
| **R6** | **Seeded world gen diverges between macOS arm64 and Windows x86_64** — two players, same lobby, different islands | M0: run `tools/check_determinism.gd` on both, compare hashes | Host generates and ships a compact heightmap; clients stop regenerating (costs bandwidth on join) |

> **R3 is the one to worry about.** Enemy pathfinding on runtime-generated terrain is where Godot is
> weakest and where an unprepared project stalls hardest. Spike it in M0, not M5.

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
| **World-gen determinism (R6)** | Clients regenerate terrain from a seed (§4). `sin`/`cos`/`pow` are not guaranteed bit-identical across CPU architectures *or across C libraries* — Linux glibc and Windows MSVC can differ even on the same x86_64. Divergence means different islands. | Run `tools/check_determinism.gd` on all three and compare. **Do this before building on §4.** |
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

Recorded from `tools/check_determinism.gd`. **Run on Windows and Linux and fill in the blanks before
building anything on §4.**

| | macOS arm64 | Windows x86_64 | Linux x86_64 |
|---|---|---|---|
| `rng_sequence` | `0077d6b42cd6f78f` | — | — |
| `noise_simplex` | `181e558b7b4841cf` | — | — |
| `noise_perlin` | `6c7a944516e3e64f` | — | — |
| `float_math` | `063eec62c34fa4ee` | — | — |

Godot 4.7.1-stable in every case — a version difference invalidates the comparison.

If `rng_sequence` differs, nothing seeded can be trusted and the fallback is mandatory. If only
`noise_*` or `float_math` differ, the fallback applies to terrain only.

If `rng_sequence` differs, nothing seeded can be trusted and the fallback is mandatory. If only
`noise_*` or `float_math` differ, the fallback applies to terrain only.

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
