# Delegation — ready-to-paste task prompts

**How to use this file:** find the task, select from its `## Task N.N` heading down to the end of its
fenced block, paste that into a fresh chat, and set the model and effort named just under the heading.
Nothing here is for you to run — every command lives inside the prompt and the agent executes it.

Each block is self-contained on purpose: the agent never needs to explore, which is the single most
expensive thing an agent can do (`AI-WORKFLOW.md` §4).

**Each parallel chat needs its own identity.** `.agent/session` holds exactly one name, so two chats
started without this overwrite each other and claims get misattributed to the wrong agent — which
defeats the entire point of claiming. The name is passed per command:

```bash
MIRE_AGENT=net .agent/bin/agent claim 1.2 autoload/net_transport.gd
```

**Per command, not `export`.** Agent tools run each shell call in a fresh process, so a bare
`export MIRE_AGENT=net` on its own line is gone by the next command and the agent silently falls back
to whatever `.agent/session` happens to hold. It fails quietly and produces exactly the misattributed
claim the identity is there to prevent. Every prompt below carries the prefix on each command.

**Including `git commit`.** The pre-commit hook re-runs `agent check` under git's environment, so an
unprefixed commit is checked against the wrong identity and can be blocked despite valid claims.
Prefer `agent ship`, which gets this right on its own.

**Roles are not fixed (D-020).** Any agent can take any task; which one gets it depends on which plan
has quota. Nothing below is reserved for a particular chat.

**Standing trap — `.godot/` is gitignored, and real setup keeps hiding in it.** Twice now a task has
finished with its working state in a directory that cannot be committed:

| Task | What lives in `.godot/` |
|---|---|
| 1.3 | Run-instance config (Debug → Customize Run Instances) — the two-window launch args |
| 1.1 | `extension_list.cfg`, without which GodotSteam does not load at all (F-009) |

Neither is reproducible from a fresh clone, which makes **1.12 (Mac ↔ Windows ↔ Linux)** the task
where this bill comes due — the Linux VM will clone the repo and GodotSteam simply won't load. Any
prompt whose work touches editor state should say so explicitly and hand back either a click-path or
a committed script. Assume `.godot/` does not exist on anyone else's machine, because effectively it
doesn't.

---

## Current state — check `.agent/BOARD.md` before pasting anything

| # | Task | Agent name | Model | Effort | Status |
|---|---|---|---|---|---|
| 1.4 | Steam lobby | `lobby` | — | — | **IN FLIGHT** — do not start a second one |
| 1.10 | Network debug panel | `netui` | Sonnet 5 | medium | **ready to paste** — safe alongside 1.4 |
| 1.1 · 1.2 · 1.3 | GodotSteam · NetTransport · LOCAL loop | | | | done and verified |
| 2.2 | Content framework | `content` | Sonnet 5 | medium | done — prompt kept for reference |

**`lobby` currently holds four files**, and a claim collision is the one failure this system exists to
prevent — check `.agent/BOARD.md` before pasting anything:

```
autoload/steam_lobby.gd · autoload/net_transport.gd · project.godot · tools/steam_api_probe.gd
```

**That includes `project.godot`.** Any task that would register an autoload must wait for 1.4 to
close, or it will be blocked at commit. 1.10 needs no autoload, which is why it's still safe.

**1.10 is the only thing to start right now.** It shares no files with 1.4, runs on cheap quota, and
it's what makes 1.5–1.8 debuggable — so it earns its slot before the tasks that need it, not after.

**1.5 and 1.6 are genuinely unblocked** now that 1.3 gives you two windows, but both need scene work
(`MultiplayerSpawner`, `MultiplayerSynchronizer` on the player) that only you can do. They need a
spec conversation before they need a prompt — ask for one when 1.4 lands.

The foundation is settled: `NetTransport` (1.2), `DevLaunch` (1.3) and GodotSteam 4.21 (1.1) are all
registered, booting and verified, so every prompt here is written against a real API rather than a
proposed one.

**Yours, not delegable:** 1.1 (GodotSteam GDExtension + `project.godot`), which 1.4 then needs, and
1.12 needs both. `4.0b` (Windows determinism) is yours only to the extent of provisioning the VM.

M0 is closed. The 0.7 and 0.8 spike prompts that used to live here shipped in `9a1bc19` / `9ebe47b` —
their results are D-015 and D-016 in `DECISIONS.md`. The unmeasured half of R2 is now task `4.0a`.

---

## Task 1.10 — Network debug panel

> **Model: Sonnet 5 · effort medium** · agent name `netui`
> Optional parallel chat. Shares no files with 1.3 and runs on cheap quota. It is also
> the thing that makes 1.5–1.8 debuggable, so it earns its slot early rather than late.

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
