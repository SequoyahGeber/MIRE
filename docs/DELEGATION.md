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
Prefer `agent ship`, which gets this right on its own — and it is now safe to prefer: **F-014 is
fixed** (`ce8128a`), so `ship` commits by pathspec and can no longer be blocked by, or unstage,
another agent's staged work, and **F-010 is fixed** (`60e85cc`), so it carries `.uid` sidecars along
with the scripts that own them instead of leaving them untracked.

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

**Nothing is in flight — clean slate, 20/108 tasks done.** 1.5, 1.9 and 1.10 all shipped
(`8d6ddab`, `ef1bc16`, `4f17bcd`), and 1.10 is now actually *wired* (`9f56451`). No file is claimed;
`1.6`, `1.7`, `1.8`, `1.11` are ready to pick up and `agent brief <id>` will print each one.

| # | Task | Agent name | Model | Effort | Status |
|---|---|---|---|---|---|
| 1.5 | Networked player — spawner + synchronizer | `spawn` | Opus 5 | high | **done** — runs; prompt kept for reference |
| 1.9 | Spike R1 — replication load | `load` | Opus 5 | high | **done — AMBER.** Read the verdict below before writing 1.8 |
| 1.10 | Network debug panel | `netui` | Sonnet 5 | medium | **done and wired** — entity count still reads 0 until F-013 is closed |
| 1.6 · 1.7 · 1.8 | Interpolation · lifecycle · interest management | | | | **ready, no prompt written yet** — 1.8 is now mandatory, not optional |
| 1.11 | Protocol/build version handshake | | | | **ready, no prompt written yet** |
| 1.1 · 1.2 · 1.3 · 1.4 | GodotSteam · NetTransport · LOCAL loop · Steam lobby | | | | done and verified |
| 2.2 | Content framework | `content` | Sonnet 5 | medium | done — prompt kept for reference |

`project.godot` is free again. It is still the one file only one task at a time may hold, so whichever
of 1.6–1.8 needs an autoload claims it by name and the others do not. Two things wiring one cost us
already (`9f56451`): **an autoload script may not carry a `class_name` equal to its own singleton
name** — Godot rejects it as hiding the singleton and the autoload never registers — and **autoload
order is load order**: a script whose `_ready()` resolves `DebugOverlay`/`NetTransport`/`PlayerNet` by
bare identifier must be registered *after* them.

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

**F-013 is still open** and is now the cheapest task on the board: nothing calls
`add_to_group(&"synced")`, so the wired panel's entity line reads 0 while players visibly replicate.
Whoever touches it decides the convention *once* — every synchronizer, or every replicated entity
root — because 1.8 and 1.9's dummy replicants both need to be counted the same way.

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
| 1.12 | Two VMs, plus F-009 (`.godot/extension_list.cfg` is gitignored, so GodotSteam won't load from a fresh clone) | F-009 gets a real fix |
| 4.0b | A Windows guest existing at all | You provision it |

The foundation is settled: `NetTransport` (1.2), `DevLaunch` (1.3), `SteamLobby` (1.4) and GodotSteam
4.21 (1.1) are all registered, booting and verified, so every prompt here is written against a real API
rather than a proposed one.

**Yours, not delegable:** 1.1 (GodotSteam GDExtension + `project.godot`), which 1.4 then needs, and
1.12 needs both. `4.0b` (Windows determinism) is yours only to the extent of provisioning the VM.

M0 is closed. The 0.7 and 0.8 spike prompts that used to live here shipped in `9a1bc19` / `9ebe47b` —
their results are D-015 and D-016 in `DECISIONS.md`. The unmeasured half of R2 is now task `4.0a`.

---

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
