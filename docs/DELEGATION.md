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

## Ready now — M1

| # | Task | Agent name | Model | Effort | Why this model |
|---|---|---|---|---|---|
| 1.2 | NetTransport autoload | `net` | Opus 5 | xhigh | Everything in M1 sits on this |
| 2.2 | Content framework *(optional)* | `content` | Sonnet 5 | medium | Pure data defs, mechanical |

**1.2 is the only thing on the critical path right now.** It gates 1.3, 1.5, 1.6, 1.7, 1.8, 1.10 and
1.11 — seven of the twelve M1 tasks — so it is worth the premium spend and the xhigh effort. The
lifecycle requirements are where cheap models produce plausible code that only fails on a real
disconnect, and Godot's `MultiplayerAPI` shifted across 4.x, which is the same stale-training-data trap
task 0.8 had to guard against explicitly.

2.2 jumps into M2, but it shares no files with 1.2 and runs on Sonnet — so it's parallelism that costs
no premium quota. Skip it if you'd rather keep M1 clean.

**Yours, not delegable:** 1.1 (GodotSteam GDExtension + `project.godot`), then 1.4 needs it. 1.12 needs
both. `4.0b` (Windows determinism) is yours too, and is quota-free.

M0 is closed. The 0.7 and 0.8 spike prompts that used to live here shipped in `9a1bc19` / `9ebe47b` —
their results are D-015 and D-016 in `DECISIONS.md`. The unmeasured half of R2 is now task `4.0a`.

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

## Optional second chat — only if you want more parallelism

## Task 2.2 — Content resource framework

> **Model: Sonnet 5 · effort medium · `export MIRE_AGENT=content`**
> This is M2 work pulled forward. It's safe — pure data definitions, no network state,
> no shared files with 1.2 — but it does jump the milestone. Skip it if you'd rather
> keep M1 clean.

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

## Not yet — M4 gate, written down now while the context is fresh

## Task 4.0a — Spike R2b: chunk collision cooking + GPU upload

> **Model: Opus 5 · effort high · `export MIRE_AGENT=collide`**
> **Do not start this during M1.** It's parked here so the reasoning behind it doesn't have to be
> rebuilt from `FINDINGS.md` F-005 in three milestones' time. Run it immediately before task 4.1.

```
You're working on MIRE, a co-op survival game in Godot 4.7.1. Read AGENTS.md first —
it's the protocol every agent here follows. Then:

    export MIRE_AGENT=collide
    .agent/bin/agent start collide
    .agent/bin/agent claim 4.0a tools/bench_chunk_collide.gd

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
    .agent/bin/agent done 4.0a "<the numbers, and which of GREEN/AMBER/RED they support>"
    .agent/bin/agent ship 4.0a "M4: chunk collision + upload spike (R2b)"

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
`.agent/JOURNAL.md`. Then **you** commit — agents can't, since the work usually needs a scene or
autoload wired first.

```bash
.agent/bin/agent board          # see what landed
```

Bring the result back to the planning chat before building on it. For 1.2 specifically: sanity-check
the interface snippet it gives you *before* starting 1.3, because seven tasks get written against that
shape and a change after the fact is a refactor across the milestone.
