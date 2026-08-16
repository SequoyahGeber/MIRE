# Delegation — ready-to-paste task prompts

Copy a block below into a fresh chat. Each is self-contained: the agent never needs to explore, which
is the single most expensive thing an agent can do (`AI-WORKFLOW.md` §4).

**Give every parallel chat its own identity** — `.agent/session` holds one name, so without this they
overwrite each other and claims get misattributed:

```bash
export MIRE_AGENT=terrain    # or nav, net, content — one per chat
```

**Model + effort are set per chat, not in the prompt.** See the table in each task.

---

## Ready now — these three can run in parallel

No shared files, no dependencies between them.

| # | Task | Agent name | Model | Effort | Why this model |
|---|---|---|---|---|---|
| 0.7 | Terrain meshing spike | `terrain` | Opus 5 | high | Perf analysis + threading design |
| 0.8 | NavMesh bake spike | `nav` | Opus 5 | xhigh | **The riskiest unknown in the project** |
| 1.2 | NetTransport autoload | `net` | Opus 5 | xhigh | Everything in M1 sits on this |

Blocked until 1.2 lands: 1.3, 1.5, 1.6, 1.7, 1.8, 1.10, 1.11.
Blocked on you: 1.1 (install GodotSteam), 1.4 (needs 1.1), 0.5, 0.9, 0.10.

---

## Task 0.7 — Spike R2: chunked terrain meshing performance

> **Model: Opus 5 · effort high · `export MIRE_AGENT=terrain`**

```
You're working on MIRE, a co-op survival game in Godot 4.7.1. Read AGENTS.md first —
it's the protocol every agent here follows. Then:

    export MIRE_AGENT=terrain
    .agent/bin/agent start terrain
    .agent/bin/agent claim 0.7 world/chunk/chunk_mesher.gd tools/bench_chunks.gd

TASK: Spike R2. Answer one question with measurements, not opinion:
"Can Godot 4.7 generate chunked terrain meshes fast enough to stream an island at 60fps?"

This is a SPIKE — throwaway code that produces a number. Do not build the real
terrain system. Do not make it pretty. Measure, report, stop.

Write exactly two files:

1. world/chunk/chunk_mesher.gd — class_name ChunkMesher, extends RefCounted
   - static func build_mesh(chunk_x: int, chunk_z: int, seed: int) -> ArrayMesh
   - 32m x 32m chunk, 1m vertex spacing (33x33 verts), heights from FastNoiseLite
   - Use SurfaceTool or ArrayMesh directly, whichever you measure as faster
   - Must be deterministic: seeded RandomNumberGenerator / FastNoiseLite.seed only,
     never global randi(). Clients regenerate terrain from a shared seed
     (docs/ARCHITECTURE.md §4), so nondeterminism means players on different islands.

2. tools/bench_chunks.gd — extends SceneTree, runs headless
   Measure and print:
   - ms per chunk, single-threaded, averaged over 100 chunks
   - ms per chunk via WorkerThreadPool across available cores
   - peak memory delta for 100 chunks held in memory
   - total triangles per chunk
   Run it yourself with:
     /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/bench_chunks.gd

SUCCESS CRITERIA — state clearly which of these the measurements support:
   GREEN : <8ms/chunk single-threaded → stream on the main thread, no complexity needed
   AMBER : 8-25ms → needs WorkerThreadPool; confirm the threaded number makes it viable
   RED   : >25ms threaded → GDScript can't do this; escalate (GDExtension, or coarser chunks)

AUTHORITY: none — this is offline generation, no networking involved.

CONSTRAINTS:
- .gd files only. NEVER create or edit .tscn/.tres/project.godot — those are human-only
  (docs/DECISIONS.md D-007) and the pre-commit hook will block you.
- Typed GDScript everywhere.
- Don't explore the codebase. Everything you need is in this prompt. If something is
  genuinely ambiguous, ask rather than searching.

FINISH WITH:
    .agent/bin/agent done 0.7 "<the numbers, and which of GREEN/AMBER/RED they support>"
    .agent/bin/agent ship 0.7 "M0: chunk mesher spike (R2)"

`ship` commits only this task's files and pushes to origin. Never `git add -A` —
other agents are working in this same directory and you would commit their
half-written files.

THEN, as your final chat message, tell me:
  - what you verified and the actual numbers/command
  - EXACTLY what I must wire before this runs (autoloads, scene nodes). You
    can't touch .tscn/.tres, so if anything needs wiring, say plainly that the
    feature does NOT work yet
  - whether it is safe for me to start the next task
  - the text to paste into docs/DECISIONS.md as D-015
```

---

## Task 0.8 — Spike R3: runtime NavMesh bake

> **Model: Opus 5 · effort xhigh · `export MIRE_AGENT=nav`**
> This is the highest-risk unknown in the project. Worth the effort setting.

```
You're working on MIRE, a co-op survival game in Godot 4.7.1. Read AGENTS.md first —
it's the protocol every agent here follows. Then:

    export MIRE_AGENT=nav
    .agent/bin/agent start nav
    .agent/bin/agent claim 0.8 world/chunk/nav_bake_probe.gd tools/bench_navbake.gd

TASK: Spike R3, the riskiest unknown in this project. Answer with measurements:
"Can we bake navigation on runtime-generated terrain chunks without visible hitching?"

Enemy pathfinding over procedurally generated terrain is where Godot is weakest. If
this is red, the whole enemy AI design changes — so we're finding out now, in week
one, rather than in month eight.

This is a SPIKE. Throwaway code, produces a number. Self-contained — generate your own
trivial heightmap mesh inside the probe; do NOT depend on world/chunk/chunk_mesher.gd
(another agent holds that file right now).

Write exactly two files:

1. world/chunk/nav_bake_probe.gd — generates a 32x32m heightmap mesh with some slopes,
   and bakes a NavigationMesh over it. Try BOTH:
   - Synchronous NavigationMeshGenerator / NavigationServer3D bake
   - Async bake (NavigationServer3D.bake_from_source_geometry_data_async or the 4.7
     equivalent — check what actually exists in 4.7.1 before assuming an API)

2. tools/bench_navbake.gd — extends SceneTree, headless. Measure:
   - ms to bake one chunk, sync
   - ms of MAIN THREAD BLOCKING during an async bake (this is the number that matters —
     a 200ms bake that doesn't block is fine; a 40ms bake that blocks every frame is not)
   - whether adjacent baked chunks actually connect (can an agent path across a seam?
     this is the classic failure and the reason chunked navmesh is hard)
   - how bake time scales with cell_size

   Run it yourself with:
     /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/bench_navbake.gd

SUCCESS CRITERIA:
   GREEN : async bake, <2ms main-thread block, chunks connect across seams
   AMBER : works but chunks don't connect, or hitches on bake → mitigations exist
           (bake a larger region less often, pre-bake at gen time, stitch manually)
   RED   : can't bake at runtime without visible hitching, or seams can't be joined

IF RED: don't stop there. Evaluate the fallback from docs/ARCHITECTURE.md §6 R3 —
grid-based A* directly on the heightmap, no NavigationServer at all. Sketch what that
costs us (no off-mesh links, no dynamic obstacle avoidance, hand-rolled steering) so we
can make an informed call.

AUTHORITY: none for the spike. For the record, enemy pathfinding will be
host-authoritative (docs/ARCHITECTURE.md §2.2).

CONSTRAINTS:
- .gd files only. NEVER touch .tscn/.tres/project.godot (D-007, hook-enforced).
- Typed GDScript.
- Verify the Godot 4.7 navigation API before writing against it — it changed across
  4.x releases and your training data may be stale. Read the actual class reference
  or test in a scratch script.
- Don't explore the codebase. Ask if genuinely blocked.

FINISH WITH:
    .agent/bin/agent done 0.8 "<numbers, GREEN/AMBER/RED, and the fallback if RED>"
    .agent/bin/agent ship 0.8 "M0: navmesh bake spike (R3)"

`ship` commits only this task's files and pushes to origin. Never `git add -A` —
other agents are working in this same directory and you would commit their
half-written files.

THEN, as your final chat message, tell me:
  - what you verified and the actual numbers/command
  - EXACTLY what I must wire before this runs (autoloads, scene nodes). You
    can't touch .tscn/.tres, so if anything needs wiring, say plainly that the
    feature does NOT work yet
  - whether it is safe for me to start the next task
  - the text to paste into docs/DECISIONS.md as D-016
```

---

## Task 1.2 — NetTransport autoload

> **Model: Opus 5 · effort xhigh · `export MIRE_AGENT=net`**
> Every other M1 task sits on this interface. Getting it right is worth the spend.

```
You're working on MIRE, a co-op survival game in Godot 4.7.1. Read AGENTS.md and
docs/ARCHITECTURE.md §2 (all of §2 — it defines the networking model) before writing
code. Then:

    export MIRE_AGENT=net
    .agent/bin/agent start net
    .agent/bin/agent claim 1.2 autoload/net_transport.gd core/net/net_config.gd

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
- .gd files only. NEVER touch .tscn/.tres/project.godot (D-007, hook-enforced).
  You cannot register the autoload yourself — tell me what to register and I'll do it.
- Don't explore the codebase beyond mire_log.gd. Everything else you need is here.

DELIVERABLE: also give me a 5-line snippet showing how task 1.3 (the two-window LOCAL
launcher) will call this, so I can sanity-check the interface before we build on it.

FINISH WITH:
    .agent/bin/agent done 1.2 "<what works, what's stubbed>"
  (or handoff, if something is genuinely unfinished)
    .agent/bin/agent ship 1.2 "M1: NetTransport autoload"

`ship` commits only this task's files and pushes to origin. Never `git add -A` —
other agents are working in this same directory and you would commit their
half-written files.

THEN, as your final chat message, tell me:
  - what you verified and the actual numbers/command
  - EXACTLY what I must wire before this runs (autoloads, scene nodes). You
    can't touch .tscn/.tres, so if anything needs wiring, say plainly that the
    feature does NOT work yet
  - whether it is safe for me to start the next task

```

---

## Optional fourth chat — only if you want more parallelism

## Task 2.2 — Content resource framework

> **Model: Sonnet 5 · effort medium · `export MIRE_AGENT=content`**
> This is M2 work pulled forward. It's safe — pure data definitions, no network state,
> no shared files with the three above — but it does jump the milestone. Skip it if
> you'd rather keep M1 clean.

```
You're working on MIRE, a co-op survival game in Godot 4.7.1. Read AGENTS.md first.
Then:

    export MIRE_AGENT=content
    .agent/bin/agent start content
    .agent/bin/agent claim 2.2 core/content/item_def.gd core/content/recipe_def.gd autoload/registry.gd

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
    .agent/bin/agent done 2.2 "<what you built>"
    .agent/bin/agent ship 2.2 "M2: content resource framework"

`ship` commits only this task's files and pushes to origin. Never `git add -A` —
other agents are working in this same directory and you would commit their
half-written files.

THEN, as your final chat message, tell me:
  - what you verified and the actual numbers/command
  - EXACTLY what I must wire before this runs (autoloads, scene nodes). You
    can't touch .tscn/.tres, so if anything needs wiring, say plainly that the
    feature does NOT work yet
  - whether it is safe for me to start the next task

```

---

## When they finish

Each agent ends with `agent done` or `agent handoff`, which releases its claims and writes
`.agent/JOURNAL.md`. Then **you** commit — agents can't, since the work usually needs a scene or
autoload wired first.

```bash
.agent/bin/agent board          # see what landed
git add -A && git commit -m "M0: terrain and navmesh spikes"
```

Bring the spike results back to the planning chat before starting M1 proper. If R3 came back RED,
the enemy AI design changes and the roadmap needs revising before anyone writes more code.
