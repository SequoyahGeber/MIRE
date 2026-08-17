# FINDINGS — problems noticed, not yet fixed

> **For the thing you spotted while working on something else.** You're deep in task 4.3 and you
> notice the inventory code double-counts stacks. Fixing it now blows your scope and your quota;
> saying nothing loses it forever. Write it here and move on.

This file is the gap between "I found a problem" and "there's a task for it." Nothing here is
scheduled. Nothing here blocks anyone. It exists so that a real observation survives the session that
produced it.

**This is not:**

- a bug tracker for the current task — fix those, or note them on the task with `agent note`
- a wishlist — features and design ideas go to `DESIGN.md` or the roadmap
- a decision log — settled calls with rationale go to `DECISIONS.md`
- a to-do list you're allowed to ignore forever — see *Triage* below

---

## How to file one

Append to the bottom of **Open**. Take the next `F-###`. Thirty seconds, not five minutes — if it
takes longer than that you're either fixing it or writing a spec, both of which belong elsewhere.

```markdown
### F-012 · Short statement of the problem

**Area:** netcode · **Severity:** medium · **Found:** 2026-08-20 by codex during 4.3

What's wrong, in a sentence or three. What goes wrong as a result — the concrete failure, not
"this is bad practice." Where it lives, as `path/to/file.gd:42`.

Optionally: what fixing it would take, if you already know.
```

**Severity** — what happens if this is never fixed:

| | Meaning |
|---|---|
| **high** | Ships broken, corrupts saves, desyncs players, or blocks a later milestone. Escalate to a roadmap task at the next triage. |
| **medium** | Real bug or real friction, survivable for now. The default. |
| **low** | Untidiness, a missing comment, a mild inefficiency. Fix it opportunistically when you're already in the file. |

**Be specific or don't file.** "The netcode feels fragile" is unactionable and will rot here forever.
"`net_transport.gd:88` retries forever with no backoff, so a dead host hangs the client on a black
screen" is a finding. If you can't name a file or a concrete failure, you have a hunch — sit on it
until it's a finding.

---

## Triage

**At the end of each milestone, the planner walks this file** and gives every open entry one of four
outcomes:

- **Promote** — becomes a numbered roadmap task, gets scheduled. Move to *Resolved*, noting the task id.
- **Fix now** — small enough to do inline during milestone cleanup.
- **Won't fix** — a deliberate call. Move to *Resolved* with the reason. This is a legitimate outcome;
  say why, so nobody refiles it.
- **Still open** — genuinely not worth acting on yet. Stays.

An entry that survives three triages without being promoted or fixed is probably a *won't fix* nobody
wants to say out loud. Say it.

Never delete an entry. Move it to *Resolved* with its outcome. The record of what we decided not to
do is worth as much as the record of what we did.

---

## Open

### F-004 · Interpolation is only planned for remote players, not enemies or props

**Area:** rendering · **Severity:** medium · **Found:** 2026-08-15 by claude during the §5a doc update

Task 1.6 covers remote-player interpolation. Nothing covers enemies (2.10, M5), physics props, or
harvestables — all of which move under host authority at replication intervals well below the render
rate, and will judder identically.

If F-003's engine-level `physics_interpolation` is enabled it may cover all of these at once, making
1.6's hand-rolled approach partly redundant. Worth resolving which mechanism owns this **before**
building 1.6, so we don't write and then delete a system.

**The mechanism question is answered, 2026-08-16 by ash during 1.6 — see D-026.** It does not cover
them: engine interpolation smooths the physics grid to the render rate, network interpolation absorbs
packet rate and jitter, and both are needed. Measured with `tools/interp_check.gd`, sampling the
control through `get_global_transform_interpolated()` so the engine's smoothing counts: engine-only
leaves 67% of frames motionless (CV 1.64), plus snapshot interpolation gives 1.5% (CV 0.21). They
also fight — an interpolated node needs `physics_interpolation_mode = OFF` or the engine adds a tick
of lag back on.

**The rest of this entry stands, and is now cheap to close.** `RemoteInterpolator` is entity-agnostic
and derives its delay from the observed arrival interval, so 15 Hz enemies and on-change props need
no new numbers and no second component — one `NetInterp.attach_to(body)` per class. Only players use
it today. **Stays open until enemies (2.10) and props actually attach it**; the work is one line each
plus whatever their spawn path is, not a system.

**2026-08-17, dusk3 — the enemy half is done; props are what is left.** Task 2.10's `Enemy` names its
code-built synchronizer `NetConfig.PLAYER_SYNC_NODE` and calls `NetInterp.attach_to(self)` on every
peer that is not simulating it, so a 15 Hz enemy is smoothed by the same entity-agnostic component
players use — no new numbers and no second implementation, exactly as this entry predicted.
`tools/enemy_net_check.gd` asserts it over real ENet (`the client's copy is smoothed by NetInterp`).
**Harvestables and physics props still do not attach one.** They replicate on-change and are mostly
still, so they judder only when they actually move — which today is a harvest state swap, not motion.
Closing this needs someone to decide whether on-change props are worth interpolating at all; that is
a smaller question than the one this entry opened with.

---

### F-005 · R2's chunk benchmark excludes GPU upload cost

**Area:** worldgen · **Severity:** medium · **Found:** 2026-08-15 by terrain during 0.7

Spike R2 came back green at 0.330 ms/chunk, but ran under the headless dummy renderer — no GPU upload,
no material, no collision shape, no LOD. Its own writeup flags this.

The risk is that the green result gets treated as "chunk streaming is solved" when the measurement
excludes a cost that could dominate. Mesh upload and collision-shape creation are both real
main-thread work in Godot.

0.8 (R3) covers collision/nav baking. **GPU upload remains unmeasured by any planned spike** — worth
re-running the bench with a real renderer before 4.3 commits to a streaming budget.

**Correction, 2026-08-15 by nav after 0.8 landed:** 0.8 did **not** cover collision baking. R3 spiked
*navigation* baking only — `world/chunk/nav_bake_probe.gd` feeds triangles straight to Recast via
`NavigationMeshSourceGeometryData3D.add_faces()` and never creates a `CollisionShape3D`. Physics shape
cooking (`ConcavePolygonShape3D` from a chunk mesh) is a different code path and is still unmeasured
by anything. So this entry now covers **two** unmeasured main-thread costs, not one, and neither is on
the roadmap. Recorded in `DECISIONS.md` D-015 as the standing caveat on the R2 green result.

**Now tracked, 2026-08-16 by claude/planner:** both costs are task **`4.0a`** (Spike R2b), a gate at
the top of M4 that must clear before 4.1 starts — `ROADMAP.md` M4, prompt in `DELEGATION.md`. The nav
correction above was right that neither was on the roadmap; that was the actual defect here, since a
finding with no task ID is a finding that gets rediscovered too late. This entry stays open until
4.0a reports numbers, and 4.0a is explicitly required to run windowed rather than headless — running
headless is the specific mistake that produced this finding.

---

### F-006 · Three roadmap tasks assume a Windows or Linux machine we don't have

**Area:** process · **Severity:** high · **Found:** 2026-08-15 by claude

Development happens exclusively on a 14-inch M5 Pro MacBook Pro, permanently — there is no second
machine and no plan to get one. Three tasks are written as though there is:

| Task | Assumes |
|---|---|
| **0.10** (M0) | Running `tools/check_determinism.gd` on Windows and Linux to fill in the `ARCHITECTURE.md` §6a baseline table |
| **1.12** (M1) | A Mac ↔ Windows ↔ Linux lobby over Steam |
| **7.12** (M7) | Testing each export on its real OS, plus Steam Deck |

**0.10 is the urgent one.** R6 asks whether seeded world gen diverges between macOS arm64 and Windows
x86_64. If it does, §4's "clients regenerate the world from a seed" design is invalid and the fallback
— host ships a compact heightmap — has to be adopted *before* M4 is built on the current assumption.
That question is unanswerable on this hardware, and it is a genuine architectural fork, not a
verification chore. The macOS column of the §6a table is filled in; the other two cannot be.

**Updated resolution path, 2026-08-16:** Linux stays on the Unraid x86_64 KVM guest. A friend's
physical Ryzen 5 5600 / RTX 3060 Windows 11 PC is now available, has Codex, and can clone the repo and
run repo-authored validation briefs. Prefer it to a Windows VM: it answers the architecture question
and supplies the real Windows GPU that Unraid passthrough could not safely provide.

The distinction that decides where these VMs live:

| Host | Guest arch | Answers R6? |
|---|---|---|
| MacBook (UTM) | **arm64** | **No** — holds the CPU architecture constant, so it tests OS divergence only. A green result here would be misleading. |
| Unraid (KVM) | **x86_64** | **Yes** — this is the macOS-arm64 vs Windows-x86_64 comparison R6 is actually asking about. |

Use Unraid for anything determinism- or architecture-sensitive. UTM on the MacBook is still useful for
quick "does it launch on Linux" checks where architecture is irrelevant.

What this does and doesn't close:

- **0.10 / 4.0b — complete across macOS, Linux, and Windows.** `check_determinism.gd` is headless and
  compute-only; no GPU, no display, no Steam. The Ubuntu guest ran it with no `sudo` and no extra
  packages — `wget` and `rsync` were already present, so the project went over by `rsync` from the Mac
  rather than `git clone`, sidestepping credentials on the guest entirely. Result in **D-017**: noise
  and PRNG are bit-identical, raw libm calls are not. On 2026-08-16 the physical Windows PC ran both
  probes twice on pinned Godot `4.7.1.stable.official.a13da4feb`; the three world-generation hashes
  and all four safe-operation hashes matched macOS exactly. See D-028 and `ARCHITECTURE.md` §6a.
- **7.12 — partially, and the gap is now confirmed rather than hypothetical.** The server's GTX 1070
  is already passed through to Ollama and Plex, so it is not available to a VM without taking it from
  services in use. Guests will render in software. **Second obstacle, found 2026-08-15 while building
  the Ubuntu guest:** Unraid reports the 1070 as the host's *primary adapter* ("GPU is primary adapter,
  vbios may be required"), so passing it to a VM also needs a dumped and patched vBIOS and risks
  leaving the host without console output. GPU passthrough here is not a checkbox; treat software
  rendering in the guests as the plan, not the fallback.

  **Sequoyah's call, 2026-08-15:** container contention is *not* a real constraint — Plex does not
  meaningfully need the card and Ollama can be paused on demand. So the only genuine obstacle to GPU
  passthrough is the primary-adapter/vBIOS work above. Do not cite the containers as a blocker. VMs therefore answer "does the export launch and
  behave correctly on this OS" — most of the value — but frame rate and rendering artifacts need real
  hardware. Steam Deck remains a separate purchase decision.
- **1.12 — machines and accounts are now available.** The macOS host, Windows VM and Linux VM each
  run the pinned engine/GodotSteam build under distinct mutual-friend Steam accounts, and all three
  peers have joined one Steam lobby. The remaining gap is test evidence and reliability, not machine
  access: F-023 tracks the intermittent Windows first-join timeout, and the formal 60-second run is
  still pending. Windows software rendering is sufficient for this transport/replication gate.

The first physical-Windows run formally reported `FAIL` because each probe also emitted 306 unrelated
startup errors. This was a harness/bootstrap error, not a determinism failure: `addons/godotsteam/` is
intentionally gitignored by D-022, and a raw clone has no generated global class cache. A fresh local
clone reproduced all 306; one `--headless --editor --quit` scan removed 303, leaving exactly the three
missing-GodotSteam errors. Future clean-machine briefs must install the D-022-pinned addon first and
run that scan. The probe scripts use only engine built-ins, reached their output, exited 0, and were
bit-identical across both Windows runs, so their R6 evidence remains valid. This does **not** count as
a clean Windows game boot test.

Practical notes for whoever builds the guests: the host is a Ryzen 5 3600X with 32 GB, shared with the
Ollama and Plex containers — assume only part of that RAM is free, and don't run both guests plus a
loaded Ollama at once. Put the vdisks on the 2 TB NVMe, not the HDD array.

Worth noting for later: Zen 2 is also the Steam Deck's CPU architecture, so CPU-side determinism
results from this box are a closer proxy for the Deck than anything else available here.

Still worth a `DECISIONS.md` entry: "cross-platform verification happens on Unraid x86_64 VMs, with
these known gaps" is a standing decision that shapes M7 and M8, not just a finding.

---


### F-020 · Steam sessions cannot use NetSession's direct-address auto-rejoin loop

**Area:** netcode · **Severity:** medium · **Found:** 2026-08-16 by tine during 1.7

LOCAL and LAN clients can rejoin by repeating the last mode/address/port. A Steam client must first
re-enter its asynchronous lobby through `SteamLobby`; calling `NetTransport.join()` with the old ID
alone is not the same lifecycle. `NetSession` therefore reports a lost Steam session without automatic
rejoin instead of pretending the retry worked. Fix when Steam lobby reconnect UX is implemented by
routing the retry through `SteamLobby` and only handing the joined lobby back to `NetTransport`.

---

### F-023 · Windows Steam first join intermittently exceeds the hard 10-second connection timeout

**Area:** netcode/testing · **Severity:** high · **Found:** 2026-08-16 by hollow during 1.12

With all prerequisites valid on pinned Godot `4.7.1.stable.official.a13da4feb`, GodotSteam 4.21 and
App ID 480, the Windows client twice reported
`connect to steam:<lobby_id> timed out after 10.0s`; an immediate retry against the same live lobby
then connected and joined the macOS and Linux peers. One failed first attempt happened after Windows
Firewall was fully disabled, so a missing firewall rule cannot explain the whole failure. Linux
joined the same lobbies on its first attempt.

The current fixed 10 s deadline therefore turns a recoverable Steam handshake delay into a failed
cross-platform run. Investigate Steam connection-state callbacks and measure first-join latency on
Windows before choosing a longer deadline or bounded retry policy. Keep this separate from task
1.12's evidence run: retain each failed log, restore Windows Firewall with a narrow Godot program
rule, and do not count a successful retry as a clean PASS.

**2026-08-16, vane — mechanism fixed, measurement still owed. Deliberately still open.**

The diagnosis above was half the story. The deadline being shared with ENet was real, but the larger
fault was that **nothing retried a first join at all**: `dev_launch.gd` excluded STEAM from its retry
by hand, `NetSession` never listened to `connection_failed`, and `SteamLobby` does not either. Every
"immediate retry" in the report above was a human relaunching the game. What landed (D-029):

- `NetConfig.STEAM_CONNECT_TIMEOUT_SEC` — Steam's own budget, **provisionally 20 s**, separate from
  ENet's 10 s because a rendezvous is a different mechanism, not a slower socket.
- `NetTransport.EndKind.CONNECT_TIMEOUT`, split from `CONNECT_FAILED`, so a retry policy can repeat an
  attempt that got no verdict and never repeat a refusal.
- `NetSession` retries a timed-out first join — STEAM only, twice, at 0.5 s and 2.0 s — and hands the
  lobby back if it gives up. Visible as `connect_retry_attempted` / `connect_failed`.
- `NetTransport.last_connect_msec()`, and a `connected … in N.NNs` line on every successful join.
- Fixed in passing: `host()`/`join()` now clear `_last_end_kind` up front. A synchronous failure used
  to inherit the previous attempt's ending, which would have made the new retry guard fire for a call
  that never opened a socket.

Verified headlessly on macOS by `tools/connect_retry_check.gd` (PASS, 0 failures) plus the full netcode
regression set — lifecycle 8/8, handshake, interp, interest, synced group, debug panel all 0 failures.

**What keeps this open, and it is the original ask:** nobody has still ever measured a Windows Steam
first join. 20 s is an allowance, not a number from evidence, and the retry has never been exercised
against a real rendezvous. Task 1.12's next physical run closes both — every join now prints its own
duration, so collect the `connected … in N.NNs` line from all three platforms, set
`STEAM_CONNECT_TIMEOUT_SEC` from the observed tail, and only then move this to Resolved. If a Windows
first join times out and the automatic retry recovers it, that is the fix working — still not a clean
PASS for 1.12, whose criteria require no connection failure.

**2026-08-16, later — F-025 is now the leading suspect for the cause.** A live Mac ↔ Windows session
had the Windows client rendering at 2–3 FPS against the host's 113. Steam's callback pump runs once per
rendered frame, so that machine serviced the rendezvous roughly 40× slower than the host — which
explains a 10 s timeout followed by a working immediate retry far better than a slow Steam network
does. Read F-025 before setting the budget from any measurement: **a number taken on a software-
rendered machine is contaminated**, and the fix may belong in the pump rather than in the deadline.

---

### F-024 · A shipped LAN first join has no retry — only the debug launcher does

**Area:** netcode · **Severity:** medium · **Found:** 2026-08-16 by vane during F-023

F-023's retry is deliberately STEAM-only, because it rests on a Steam-specific invariant: a timed-out
attempt tears down without announcing, so lobby membership survives and the retry is a plain `join()`.
LOCAL and LAN first joins are retried too — but by `core/dev/dev_launch.gd`, which is the two-window
dev launcher and is debug-only. Nothing in a shipped build retries a LAN join that times out.

Today that costs nothing: LAN has no player-facing entry point yet, so the only way to reach it is
DevLaunch, which does retry. It becomes real the moment M6 builds a join screen — a player typing an
address at a host that is still coming up gets one attempt and a dead end, while the same failure over
Steam quietly recovers. Fix it with the join UI rather than now, and the shape is already there:
`NetSession._should_retry_connect()` needs its mode gate widened plus a decision about whether
DevLaunch then defers to it, since two retry loops would double every attempt.

---

### F-025 · Steam's callback pump runs once per rendered frame, so a slow frame rate slows the handshake

**Area:** netcode · **Severity:** high · **Found:** 2026-08-16 by vane, from Sequoyah's Mac ↔ Windows session

`SteamLobby._process()` calls `_steam.run_callbacks()` exactly once per frame, and its own comment says
it is "the one that makes every other Steam call arrive". Godot polls the MultiplayerAPI per frame too.
So every Steam callback — lobby entry, the P2P rendezvous, connection state — is serviced at whatever
rate the machine happens to be *rendering*.

Observed on a live Mac-hosted Steam session: the Windows client ran at **2–3 FPS (387 ms and 312 ms
frame times)** while the macOS host ran at **113 FPS (16.5 ms)** on an identical scene (nodes 2559 on
both, objects 6501 vs 6504). Windows physics was 0.25 ms, so simulation was never the constraint —
5457 draw calls at 387 ms is roughly 70 µs per call, which is software rasterization, almost certainly
a VM without GPU passthrough rather than the physical Ryzen/RTX box. The session still worked: two
peers, two players, both synced.

**This is the leading hypothesis for F-023.** A 10 s connect window gets ~1,130 callback pumps at
113 FPS and ~20 at 2 FPS. A multi-round-trip rendezvous serviced 40× slower is a far better explanation
of "Windows first join times out, immediate retry connects" than a slow Steam network — the retry lands
once the scene is warm. D-029's longer budget and automatic retry remain correct (a shipped player on a
weak GPU or a loading screen hits the same coupling) but they treat the symptom.

Two things to settle, and they are separable:

1. **Decouple the pump from rendering.** Steam's callbacks should be serviced on a fixed cadence that a
   frame-rate collapse cannot starve, and the connect watchdog in `NetTransport._process` inherits the
   same problem — at 2 FPS a 10 s deadline is only checked every ~390 ms.
2. **Do not measure F-023 on a software-rendered machine.** Any first-join latency taken there is
   contaminated by this. Record frame rate alongside the `connected … in N.NNs` line, and get the
   number from the physical Windows PC.

**2026-08-16, dusk3 — item 1 is fixed. Item 2 is the whole of what keeps this open.**

`SteamLobby.run_callbacks()` and `NetTransport`'s connect watchdog both moved from `_process` to
`_physics_process`. The physics tick is fixed at `physics/common/physics_ticks_per_second` and the
engine runs up to `max_physics_steps_per_frame` of them inside one rendered frame, so a frame-rate
collapse no longer starves Steam by the same factor it starves rendering. At a healthy frame rate
nothing changes — it is the same 60 Hz the render loop was giving. At the observed 2–3 FPS it is up
to 8× more pumps per frame, and the 10 s deadline is no longer only *checked* every ~390 ms.

This is a mitigation, not a decoupling to an independent clock: physics steps are still capped per
frame, so a truly pathological frame rate still dilates. A dedicated thread or a `Timer` on
`PROCESS_MODE_ALWAYS` would be the real fix, and neither is worth building before item 2 says whether
it is needed.

Verified by the netcode regression set on macOS — `connect_retry_check`, `session_lifecycle_check`,
`steam_lobby_check`, `handshake_check`, `interest_check`, `synced_group_check`, `net_debug_panel_check`
all 0 failures — plus the four two-process ENet checks. **None of that touches real Steam**: no macOS
check can, and the change is exactly in the path only a real rendezvous exercises. Item 2 stands
unchanged and now covers this fix too: measure on the physical Windows PC, record frame rate beside
the latency, and only then set `STEAM_CONNECT_TIMEOUT_SEC` from evidence.

---

---

### F-036 · Task 2.9's gate cannot be met in its roadmap position — the enemy it tunes against lands in 2.10

**Area:** roadmap · **Severity:** medium — it gates a "never cut" item · **Found:** 2026-08-16 by dusk3
during 2.8

`ROADMAP.md` orders 2.8 (melee combat) → **2.9 "tune combat feel until one enemy with one weapon
feels great; do not proceed otherwise"** → 2.10 (Enemy v1). 2.9 is one of the four things `ROADMAP.md`
§"Never cut" names, and `DESIGN.md` §6 states its rule of thumb in the same terms: *if hitting one
enemy with one weapon doesn't feel great, do not build the second weapon.*

But after 2.8 there is no enemy. The only things in the `&"damageable"` group are harvestables, and a
tree does not exercise what 2.9 is actually gating: an enemy's 0.4 s telegraph, backpedal pressure,
whether the hit reads as a *kill* rather than a resource tick, or death feedback. Tuning against a
tree and declaring the gate passed is the failure mode the gate exists to prevent — and it would be
easy to do accidentally, because the swing, hitstop, shake and impact sound all *work* against a
tree.

Two ways out, and this is Sequoyah's call because it changes roadmap order:

1. **Swap 2.9 and 2.10.** Build Enemy v1, then tune. This is what the gate's own wording assumes.
2. **Keep the order but split 2.9**: tune the weapon-side feel (swing weights, hitstop, shake, sound)
   against a tree now, and re-run the real gate immediately after 2.10 before anything else starts.

Not fixed here: 2.8 owns combat code, not the roadmap. Filed rather than silently tuning against a
tree, which would have looked like the gate passing.

**2026-08-17, dusk3 — resolved by taking option 1.** 2.10 shipped before 2.9, so the enemy the gate
is about now exists and 2.9 was tuned against a crawler rather than a tree. The ordering concern is
spent; what remains is that **2.9's gate is still open**, because passing it requires a human
playtest and `tools/combat_feel_check.gd` deliberately measures relationships rather than declaring
anything fun. This entry stays open only until Sequoyah plays it and says yes or no.

*Filed as F-033, then F-035, and finally renumbered to F-036 on 2026-08-16: both earlier numbers were taken by entries that landed
concurrently (a resolved F-033, and kiln9's F-034 and F-035). `NEXT.md` and the 2.8 journal note refer to it by the new number.*

---

### F-037 · `net_debug_panel_check` fakes its second peer in-process, so host and client share one tree

**Area:** tests/netcode · **Severity:** low · **Found:** 2026-08-16 by dusk3 while fixing F-021

F-021 is fixed and the uninitialized-root errors are gone, but the harness still emits two:

```
ERROR: Condition "parent->has_node(name)" is true. Returning: ERR_INVALID_DATA
```

Cause: the "client" is a second `MultiplayerAPI` in the *same process*, and F-021's fix correctly
points its `root_path` at `/root` so autoload-addressed RPCs resolve. But that is the host's tree too,
so when `PlayerNet` spawns a body for the fake peer, the `MultiplayerSpawner` also replicates it back
into the same container and the name is already taken.

Harmless — the panel numbers this harness checks (RTT, bandwidth, peer list) are all correct, and it
exits 0 with 0 assertion failures. Filed because it is the last thing standing between this harness
and a clean error-free run, and because "two expected errors" is exactly the kind of allowance that
later hides a third.

Fix: use a real second process, the way `session_lifecycle_check`, `inventory_net_check`,
`crafting_net_check` and `combat_net_check` all do. That pattern is well established here — driver
spawns `OS.create_process` with a `--` probe argument and they talk through a `user://` JSON file — so
this is a rewrite of one function, not new machinery.

---

### F-038 · `inventory_net_check` intermittently fails its grant wait under machine load

**Area:** tests/netcode · **Severity:** medium · **Found:** 2026-08-16 by dusk3 during the findings sweep

Running the four two-process ENet checks back to back, `inventory_net_check` failed 10 assertions with
the client reporting `"error": "grant timeout"` — it never saw the host's granted items inside the
15 s `TIMEOUT_SEC`. An immediate re-run passed with 0 failures, and `harvestable_net`, `crafting_net`
and `combat_net` all passed in the same sequence, including ones that grant inventory over the same
wire.

So this is a race in the harness, not in `InventoryService`. It matters because it makes the check set
non-deterministic: a red run that goes green on retry trains everyone to re-run rather than
investigate, which is how a real intermittent failure gets ignored.

Two candidates, both cheap to test: the driver may grant before the client has finished subscribing
(the same class of bug as `combat_net_check`'s host-player race, which was fixed by polling for the
precondition instead of asserting it once), or 15 s is simply not enough when several Godot processes
are competing for the machine. Prefer fixing the ordering over raising the timeout — a longer timeout
hides the race rather than removing it.

---

## Resolved

### F-032 · Auto-rejoin assigns a new peer id, so peer-keyed gameplay state cannot follow it — **fixed**

**Area:** multiplayer/gameplay state · **Severity:** high · **Found:** 2026-08-16 by nettle during 2.4

Task 1.7's live lifecycle check proves that a reconnecting ENet client gets a new id (for example,
peer `1037623507` rejoined as `361299977`). `PlayerNet` can respawn a body under the new id, but there
is no stable run-player identity to tell host-owned systems that the new peer is the old player.
`InventoryService` therefore releases the departed peer's inventory and correctly creates a fresh
one on rejoin; retaining or assigning an orphan to "the next joiner" would give the wrong inventory
when two players reconnect together. Before reconnect can preserve inventory, health, powerups or
Attunement, add a host-issued opaque run-player token to admission/rejoin and an explicit old-peer to
new-peer rebind event that gameplay systems can consume.

**Resolved:** 2026-08-17 by dusk3 · fixed

`core/net/run_identity.gd` is the host-side registry; `NetSession` mints a token on the client hello,
hands each client only its own, and emits the two signals gameplay systems consume:
`run_player_rebound(old_peer_id, new_peer_id)` and `run_player_expired(peer_id)`. D-035 records the
call and the consumer contract. Protocol version 5 → 6, because the hello gained an argument.

**The half that actually fixes the bug is a deletion.** `InventoryService._on_peer_left()` no longer
releases anything — between a drop and a rejoin the player is still a player, and `peer_left` cannot
tell a reconnect from a departure. It now waits to be told which happened.

The entry's two hazards are both covered by rules in the registry rather than by hope: a token whose
peer is still connected is never reassigned, so a live player's state cannot be claimed by someone
presenting their token; and identities park for 90 s — an order of magnitude past `NetSession`'s
0.5 + 1 + 2 + 4 s rejoin ladder — then expire, so state is not held forever for someone who left. The
entry's specific worry about "two players reconnecting together" is asserted directly: each returning
player rebinds to its own previous peer id, in either order.

Verified two ways. `tools/run_identity_check.gd` (37 passes, 0 failures) drives the registry rules
and the InventoryService handover offline. `tools/session_lifecycle_check.gd` proves it over real
multi-process ENet — the harness grants 7 logs, kicks the client, and asserts the reconnect:

```
ok    the rejoiner came back under a different peer id  — was 1545394978, now 175915464
ok    the inventory followed the player across the new peer id  — peer 175915464 holds 7 log(s)
ok    nothing was left behind under the old peer id
```

Health, powerups and Attunement do not exist yet; when they do, they inherit this seam by connecting
to the same two signals and by *not* cleaning up on `peer_left`.

### F-017 · A brand-new script still ships without its `.uid`, because the sidecar does not exist yet — **fixed**

**Area:** build/tooling · **Severity:** low · **Filed:** 2026-08-16 by birch during 1.8

F-010's durable half — `cmd_ship` stages `<file>.uid` whenever it stages `<file>.gd` — closes the case
where the sidecar exists and nobody claimed it. It cannot close this one: **Godot writes the `.uid`
at import time, and a task that never runs an import ships before the file exists.** `ship` stages
what is on disk, and there is nothing there to stage.

Seen live: `0a267f5` shipped `world/gen/test_map_props.gd` with no sidecar. It appeared in this
working directory ten minutes later, untracked, the moment 1.8 ran `Godot --headless --path . --import`
to rebuild the global class cache (**F-016** — three tasks hit that one on the same day). Nothing was
wrong with how 0.11 shipped: the file genuinely did not exist yet.

So this recurs for **every new script from every task that has no reason to import**, and the two
halves of F-010 between them still leave the repo one sidecar short each time. The consequence is
F-010's, unchanged: harmless while our `.tscn` files reference scripts by `path=`, and not harmless
the first time Sequoyah saves a scene and Godot rewrites those as `uid://`.

**Likely fix, not attempted here** (it is `.agent/bin/agent`, which 1.8 does not hold): have `ship`
run `Godot --headless --path . --import` before it stages, when the staged set contains a `.gd` with
no sidecar. That is a few seconds, it is the same command that fixes the class-cache problem, and it
makes both failures impossible rather than periodically swept. The alternative — a per-milestone
sweep — is explicitly the thing F-010 called "a fix with a timer".

---

**Resolved:** 2026-08-16 by dusk3 · fixed

`ship` now runs `Godot --headless --path . --import` when its staged set contains a `.gd` with no
sidecar, then re-reads `git status` and stages whatever appeared. This is the entry's own suggested
fix, and it was the right one: it is the same command that rebuilds the global class cache (F-016), so
one call closes both failures instead of leaving a per-milestone sweep — "a fix with a timer" — to
catch them.

Three guards, because `ship` must never become a command that can fail for environmental reasons:

- **Godot running → skip with a warning.** Importing under a live editor is the D-031 hazard; the
  sidecars ship late rather than risking the editor's own write.
- **Godot not found → skip with a warning**, naming `GODOT=/path/to/Godot`. Codex on another machine
  must still be able to ship.
- **Import fails → skip with a warning.** A non-zero import never blocks the commit.

Verified end-to-end: created `tools/_f017_probe.gd` with no sidecar, called `_generate_missing_uids()`
against a real `git status`, and confirmed `tools/_f017_probe.gd.uid` was created and appeared in the
refreshed change list. Probe removed afterwards.

### F-034 · `agent ship` silently drops directory claims and appends stray argv to the commit message — **fixed**

**Area:** agent tooling · **Severity:** medium · **Found:** 2026-08-16 by kiln9 during 2.1d

`agent ship <id> ["message"]` takes a message only, and commits the task's *claimed* files. Two things
follow that cost a commit to notice:

1. **A claim on a directory is not expanded at ship time.** 2.1d was claimed with
   `assets/tools_weapons` and `assets/icons`. `agent check` accepted those claims and the pre-commit
   hook was happy, but `ship` committed only the individually-named files — the generators, the docs,
   the four `.tres`. Every rebuilt GLB, every preview, and the entire new `assets/icons/` tree stayed
   uncommitted, and `ship` still printed `✓ pushed to origin/main` and the sign-off. Nothing in the
   output distinguishes "shipped everything" from "shipped a third of it".
2. **Extra arguments become part of the commit subject.** Passing a file list after the message (a
   reasonable guess, since `claim` takes files) produced the subject
   `Art: rebuild the tool set and add inventory icons tools/blender/build_tool_weapon_set.py …
   docs/DELEGATION.md` — the whole pathspec glued on. `340d9a3` is stuck with it: it was pushed, and
   another agent committed on top before it could be amended.

`ship` also committed `docs/DECISIONS.md` including another agent's uncommitted D-031/D-032, because
the file was claimed by this task for one added decision. Content was preserved, but it is attributed
to the wrong commit.

Until this is fixed: **claim files individually, never directories**, and check `git status` after
every `ship` rather than trusting its sign-off. The fix is to expand directory claims to their files
at ship time, reject unexpected positional arguments instead of concatenating them, and print the
committed file count.

**Resolved:** 2026-08-16 by dusk3 · fixed, all three parts

1. **Directory claims expand at ship time.** `ship` matched claimed paths against `git status`
   output, which lists *files*, so a claim on `assets/tools_weapons` matched nothing while
   `agent check` and the pre-commit hook both accepted it. It now collects every changed file under
   each claimed directory. Verified against 2.1d's exact shape: claims
   `["assets/tools_weapons", "docs/DELEGATION.md"]` over changed files including
   `assets/tools_weapons/exports/a.glb` now expand to both nested files and leave `autoload/x.gd`
   alone.

2. **Path-shaped arguments are rejected, not concatenated.** Validation runs before any state is
   loaded, so the mistake is caught whatever the task's status:

   ```
   ✗ ship takes a task id and a MESSAGE, not a file list — it commits what the task claimed.
     Looks like a path: docs/FINDINGS.md
     Did you mean:  agent ship F-017 "your message here"
   ```

   The test is "does this argument exist on disk, or contain a `/`" rather than an argument count,
   so an unquoted prose message still works — that usage was never the bug.

3. **The sign-off distinguishes a full ship from a partial one.** "Left alone" now prints its total
   and says how many it truncated, instead of showing at most eight paths with no count.

The entry's fourth observation — that `ship` committed another agent's uncommitted `D-031`/`D-032`
because the file was claimed for one added decision — is **not** fixed and is not a bug in `ship`:
committing a claimed file means committing its current contents. The working practice that avoids it
is to keep shared documents out of a claim when another agent is mid-edit in them, which is what the
2.8 sweep did by hand.

### F-002 · Sprint-FOV lerp uses the framerate-dependent smoothing form — **fixed**

**Area:** gameplay feel · **Severity:** low · **Found:** 2026-08-15 by claude during the §5a doc update

`entities/player/player_camera.gd:66` uses `lerpf(camera.fov, target_fov, minf(fov_lerp_speed * delta,
1.0))`. This converges at slightly different rates at 60 vs 240 fps, so the sprint FOV punch feels
marginally snappier on faster hardware.

Purely cosmetic, and `ARCHITECTURE.md` §5a rule 6 explicitly permits the naive form for cosmetics —
but it wants a comment marking the choice as deliberate, which isn't there. Either add the comment or
switch to `1.0 - exp(-speed * delta)`.

Flagged mainly because this is the pattern most likely to get copy-pasted into something that *does*
affect gameplay.

---

**Resolved:** 2026-08-16 by dusk3 · fixed

`entities/player/player_camera.gd` now uses `lerpf(camera.fov, target_fov, 1.0 - exp(-fov_lerp_speed * delta))`,
with a comment naming this finding and §5a rule 6. Switched rather than documented as a deliberate
exception, precisely for the reason the entry gives: it is the shape most likely to be copy-pasted
into something that does affect gameplay, and there is now no framerate-dependent copy left to
inherit. The same file's new impact shake (2.8) integrates elapsed time instead of lerping, so it
never had the problem.

Verified by `tools/verify_setup.gd` (0 failures) — no behavioural check exists for FOV feel, and
2.9 owns tuning the constant.

### F-011 · Autoloads are not compile-time identifiers in a `--script` main loop — **fixed**

**Area:** tooling/netcode · **Severity:** medium — costs a run, not a day · **Filed:** 2026-08-16 by
spawn during 1.5

A script run as the main loop (`Godot --headless --path . --script tools/foo.gd`, `extends SceneTree`)
is **compiled before the autoloads are registered**, so naming one fails at compile time, not at run
time:

```
SCRIPT ERROR: Compile Error: Identifier not found: NetTransport
ERROR: Failed to load script "res://tools/foo.gd" with error "Compilation failed".
```

The autoloads themselves are fine — they exist and have run `_ready()` by the time `_initialize()` is
called. Only the *identifier* is unavailable. Look them up by path instead, into an untyped `Node`:

```gdscript
var _net: Node = root.get_node(^"NetTransport")
```

**Who this hits:** every headless harness in `tools/`. Task **1.9**'s `bench_replication.gd` is
specified as `extends SceneTree` and drives `NetTransport` directly, so it hits this on its first run.
So does anything 4.0a writes later.

**Not worth "fixing".** It is how GDScript resolves autoload names, not a defect of ours. It is filed
so the next person loses a compile cycle instead of an hour.

---

**Resolved:** 2026-08-16 by dusk3 · fixed, and it caught a live regression

The entry said "not worth fixing" because it describes how GDScript resolves autoload names. That was
right about the mechanism and wrong about the blast radius: **a `--script` main loop compiles the
scripts it *depends on* in the same pass**, so the restriction reaches any script pulled in through a
`class_name` reference — not just the harness itself.

Found the hard way. Task 2.8 added a bare `CombatService.request_attack()` to
`entities/player/player_controller.gd`. `tools/verify_setup.gd` references `PlayerController`, so the
controller compiled in the harness's own pass, before autoloads existed:

```
SCRIPT ERROR: Compile Error: Identifier not found: CombatService
SCRIPT ERROR: Compile Error: Failed to compile depended scripts.
```

That silently broke **two** harnesses. `verify_setup.gd` went from 0 to 4 failures and
`tools/interp_check.gd` to 3 — the interp failures looked like a netcode defect ("NetInterp refused to
attach an interpolator", 100% still frames) but were just bodies whose script never compiled, so they
had no synchronizer to smooth.

Fixed by resolving the autoload by path, the pattern `systems/harvesting/harvestable.gd` already used:

```gdscript
var combat: Node = get_node_or_null(^"/root/CombatService")
if combat != null:
	combat.call(&"request_attack")
```

**The rule, now in `DELEGATION.md`: a gameplay script that a harness can reach must never name an
autoload as a bare identifier.** Verified: `verify_setup.gd` 0 failures (was 4), `interp_check.gd`
0 failures (was 3).

### F-012 · A `MultiplayerSynchronizer`'s authority must be set BEFORE `add_child()` — **fixed**

**Area:** netcode · **Severity:** medium · **Filed:** 2026-08-16 by spawn during 1.5

Building a synchronizer in code (D-023) and then setting its authority once it is already in the tree
— even in the same `_ready()` — makes the replication interface reject the pending spawn, on every
client, for every spawned instance:

```
ERROR: The MultiplayerSynchronizer at path ".../NetSync" is unable to process the pending spawn
since it has no network ID. This might happen when changing the multiplayer authority during the
"_ready" callback.
```

Replication appeared to work anyway in the 1.5 two-process test, which is the dangerous part: the
symptom is error spam plus an unknown amount of silently degraded state, not a clean failure.

Fixed in `player_controller.gd` by setting `set_multiplayer_authority()` on the synchronizer before
`add_child()`, and noted in a comment there. **Filed because 1.6 and 1.8 both add or reconfigure
synchronizers**, and the engine's own advice ("only change authority during `_enter_tree` of their
spawner") points somewhere that does not exist in our layout — the synchronizers are built by the
player, not by the spawner.

---

**Resolved:** 2026-08-16 by dusk3 · promoted out of findings, not un-fixed

The defect itself was fixed in `player_controller.gd` during 1.5. This entry stayed open to warn 1.6
and 1.8, and both have since shipped having honoured it. What is left is not a finding — it is a
permanent rule about building replication nodes in code (D-023), and it belongs where someone writing
one will read it rather than on a findings board they may not open.

Recorded in `DELEGATION.md` alongside the D-023 guidance: **set `set_multiplayer_authority()` on a
synchronizer before `add_child()`, never after.** Task 2.10's enemies are the next code to need it.
Closing rather than leaving it to survive a third triage as a warning nobody can action.

### F-016 · A brand-new `class_name` is not resolvable by bare identifier in a `--script` main loop — **fixed**

**Area:** tooling · **Severity:** low — costs a run, not a day · **Filed:** 2026-08-16 by bram during
1.11

Distinct from F-011 (autoloads): this is about *new* `class_name` scripts. `.godot/global_script_class_cache.cfg`
is only regenerated by the editor scanning the project, so a `class_name` a headless `--script` run has
never seen through an editor session fails the same way an autoload does:

```
SCRIPT ERROR: Parse Error: Identifier "NetVersion" not declared in the current scope.
```

`--headless --path . --quit-after N` (the normal boot path, not `--script`) does **not** trigger the
rescan either — confirmed by running it after adding `core/net/net_version.gd` and grepping the cache
file afterward; the class was still absent. Existing classes like `NetConfig` already work bare because
their cache entry predates this session, not because the mechanism is different.

Fix: `preload()` it instead of naming it bare, same as `tools/bench_replication.gd` already does for
`Dummy` — `const NetVersion = preload("res://core/net/net_version.gd")`. Cheap and it keeps working
after the cache does eventually pick the class up, so there's no reason to revert it once Sequoyah opens
the editor.

**Who this hits:** any `tools/*_check.gd` or spike script that introduces a *new* `class_name` in the
same session it's first exercised headless — which is most of them, since a check script and the class
it verifies usually land together.

---

**Resolved:** 2026-08-16 by dusk3 · promoted out of findings

Same disposition as F-011 and for the same reason: this describes how the global class cache works,
not a defect of ours, and it has an established workaround already used across `tools/` —
`const Thing = preload("res://path/to/thing.gd")` instead of naming a fresh `class_name` bare.

The convention is now in `DELEGATION.md` with F-011's, so a harness author meets both rules in the
same paragraph. Nothing about the engine behaviour changed; only where it is written down.

### F-018 · `PlayerNet` has no way to be told when a player spawns, so observers reach into its children — **fixed**

**Area:** netcode · **Severity:** low · **Found:** 2026-08-16 by ash during 1.6

`autoload/player_net.gd` exposes `player_for()`, `spawned_peers()` and `debug_snapshot()` — all
*pull*. Nothing pushes. A system that has to act the moment a player appears or disappears has no
signal to connect to, so 1.6's `NetInterp` does the next-best thing: it resolves PlayerNet's
container by child name (`NetConfig.PLAYER_CONTAINER_NODE`) and connects to that node's
`child_entered_tree`. That works and is scoped correctly, but it depends on the container being a
directly-named child, which the file's own header says is PlayerNet's business and nobody else's:

> Never reach into the tree by path from outside this file; the paths are ours to change.

`autoload/net_interp.gd:50` is the reach. Two more callers are coming — 1.7 wants despawn/reconnect
edges and 2.10's enemies will want the same shape — and each one that copies this pattern makes the
container path harder to change later.

Fix, cheap and obvious: `signal player_spawned(peer_id: int, body: Node3D)` and
`signal player_despawned(peer_id: int)` on `PlayerNet`, emitted from `_spawn_for()`/`_despawn()`,
plus a `players_root() -> Node` for anyone who genuinely wants the container. Then `NetInterp._bind()`
loses its child lookup. **1.7 is the natural owner** — it holds the lifecycle and is already in that
file; this is a few lines on top of what it is doing anyway, not a task.

---

**Resolved:** 2026-08-16 by dusk3 · fixed

`PlayerNet` now pushes instead of only being pulled from:

```gdscript
signal player_spawned(peer_id: int, body: Node3D)
signal player_despawned(peer_id: int, body: Node3D)
func players_root() -> Node
```

Both are emitted from PlayerNet's *own* subscription to its container's `child_entered_tree` /
`child_exiting_tree`, not from `_spawn_for()`. That detail is load-bearing: `_spawn_for()` runs on the
host only, while on a client the `MultiplayerSpawner` puts the body into the container directly — a
signal emitted from the spawn call would never fire for the peers that need it most.

`autoload/net_interp.gd` no longer resolves `NetConfig.PLAYER_CONTAINER_NODE` by name; it connects to
`player_spawned` and uses `players_root()` only for its catch-up sweep. The reach the entry named
(`net_interp.gd:50`) is gone, and the two callers it predicted — 1.7's despawn edges and 2.10's
enemies — now have a signal to use instead of a copy of the pattern.

Verified by `tools/interp_check.gd` (0 failures) and the four two-process ENet checks
(`harvestable_net`, `inventory_net`, `crafting_net`, `combat_net`), which exercise real spawns over a
real wire.

### F-021 · The net debug panel harness passes while Godot reports an uninitialized multiplayer root — **fixed**

**Area:** tests/netcode · **Severity:** medium · **Found:** 2026-08-16 by reed during 1.7

`tools/net_debug_panel_check.gd` exits 0 with all 19 assertions passing, but its real-ENet section
repeatedly emits `Multiplayer root was not initialized` from `SceneMultiplayer._process_packet()` at
line 111. The custom client `SceneMultiplayer` is assigned an ENet peer without a root path. Give it
a stable root path before polling, then make engine errors fail the harness so a green exit cannot
hide them. This is independent of 1.7: `tools/session_lifecycle_check.gd` uses full Godot processes
with initialized roots and completes cleanly.

---

**Resolved:** 2026-08-16 by dusk3 · fixed

`tools/net_debug_panel_check.gd` gives its second in-process peer a `root_path` before the peer is
attached, so no packet is ever processed without one. `Multiplayer root was not initialized` is gone —
0 occurrences, from a stream of them.

One correction to the entry's suggested fix: the root must be `/root`, not a private node. Rooting the
fake peer at its own node silences that error and immediately produces a different one, because the
host addresses RPCs at autoload paths like `/root/InventoryService` — the same hidden-error problem
wearing a new message. The harness went 11 engine errors → 2 with `/root`.

**The residual 2 are a different problem and are filed as F-037**, not swept in here: they come from
faking a second peer inside one process, where host and client share a tree and the spawner tries to
add the same player name twice.

On the entry's second ask — "make engine errors fail the harness" — GDScript has no supported hook to
intercept engine-level `push_error`. The durable guard is to run checks as
`… 2>&1 | grep -c 'ERROR:'` and treat a non-zero count as a failure; that is now recorded in
`DELEGATION.md` as how to run the check set.

### F-028 · `verify_setup.gd` hard-codes the superseded greybox main scene — **fixed**

**Area:** tooling · **Severity:** low · **Found:** 2026-08-16 by nettle during 2.3

`tools/verify_setup.gd` fails only its “main_scene points at the level” assertion after the current
human-owned `project.godot` change selected `levels/playtest_hollow.tscn`; it still compares against
`greybox_test.tscn`. The new default scene itself boots headlessly and reports 463 props, 20 terrain
bodies, 274 shapes, and one marker. Update the assertion to accept the current playable level or
validate the configured main scene structurally instead of pinning the old path.

**Resolved:** 2026-08-16 by dusk3 · fixed

`tools/verify_setup.gd` no longer pins a path. It keeps `greybox_test.tscn` as an explicitly named
physics fixture (`PHYSICS_FIXTURE_SCENE` — small, has a Player and a Ground, cheap to instantiate) and
validates whatever `application/run/main_scene` actually points at, structurally: the setting is
non-empty, the resource exists, it loads as a `PackedScene`, its root is a `Node3D`, and it contains a
`WorldEnvironment`, a `DirectionalLight3D` and a `CharacterBody3D` player body.

Chosen over "accept the current playable level" because pinning is what produced this finding; the new
form survives the next level change without an edit. Verified against the current main scene
(`levels/playtest_hollow.tscn`): 0 failures.

### F-031 · `DELEGATION.md` still describes the pre-polish Playtest Hollow layout — **fixed**

**Area:** documentation · **Severity:** low · **Found:** 2026-08-16 by nettle during 2.4

The bounded `DELEGATION.md` *Current state* read still says Playtest Hollow has 463 props, 254 prop
collision shapes and 4,102 visual meshes from task 2.1f. Task 2.1h shipped an 88×88 m replacement
with 783 props, 339 prop shapes, 359 total colliders and 6,256 meshes. Update that inherited-state
paragraph from task 2.1h's journal evidence so future tasks do not plan against the smaller map.

**Resolved:** 2026-08-16 by dusk3 · fixed

`DELEGATION.md`'s *Current state* paragraph now carries 2.1h's numbers — 88 × 88 m, 783 props,
33 terrain records (20 colliding), 6,256 meshes, 359 collision shapes — replacing 2.1f's 463 props /
4,102 meshes / 68 × 68 m. The figures are `tools/playtest_hollow_check.gd`'s own output rather than a
hand copy from a journal entry, re-run to confirm:

```
PLAYTEST_HOLLOW_CHECK zones=6 props=783 terrain=20 colliders=359 visuals=6256 failures=0
```

The paragraph now says to re-read them from that check rather than editing them by hand, which is how
they went stale in the first place. Also corrected there: it claimed the project still booted the old
greybox level, which stopped being true when `main_scene` became `playtest_hollow.tscn`.

### F-035 · Inventory icons are capped at 26 px because a `CenterContainer` sizes children to their minimum — **fixed**

**Area:** inventory/UI · **Severity:** medium · **Found:** 2026-08-16 by Sequoyah after A-042a ·
**Resolved:** 2026-08-16 by kiln9

`InventorySlot._build_contents()` put the icon `TextureRect` inside a `CenterContainer` with
`custom_minimum_size = Vector2(26, 26)`. A `CenterContainer` centres each child **at its minimum
size** and never expands it, so the icon stayed 26 px regardless of `set_slot_size()` — about a third
of a 72 px backpack slot. The cap was invisible while slots showed text, and only became wrong when
A-042a gave items real icons.

`STRETCH_KEEP_ASPECT_CENTERED` was already set, which is why this reads as "the icons are small"
rather than as a broken layout: the texture was scaled correctly, into a box that was too small.

Fix: the icon is now its own full-slot layer. `InventorySlot` is a `PanelContainer`, which lays every
child out across its content rect, so adding the icon as the *first* child makes it fill the slot and
draw behind the key and amount labels, with padding from a dedicated `MarginContainer` that scales
with slot size. Anything else laid out this way should be checked for the same mistake — a fixed
`custom_minimum_size` inside a `CenterContainer` is a cap, not a hint.

Verified with `inventory_ui_check.gd` (3 confirmations, 0 failures) and Forward+ renders at 1280×720
and 374×666: icons now fill their slot at both sizes instead of sitting at a third of it, and the
amount and key labels still read over them.

### F-033 · Inventory hotbar aliases eight backpack slots instead of adding eight separate slots — **fixed**

**Area:** inventory/UI · **Severity:** high · **Found:** 2026-08-17 by Sequoyah after task 2.5 ·
**Resolved:** 2026-08-17 by dusk3

Expanded the authoritative snapshot from 24 to 32 stable slots. Backpack slots are 0–23 and separate
hotbar slots are 24–31; grants fill backpack empties before hotbar overflow, and ingredient removal
uses backpack stacks before equipped hotbar stacks. `InventoryUI` maps its two regions to those
distinct ranges and drag/drop moves between them through the unchanged host-validated request seam.
The wire contract is protocol v4.

Verified with `inventory_check.gd` (51 passes, 0 failures), `inventory_ui_check.gd` (32 passes,
0 failures), and the two-process `inventory_net_check.gd` (0 failures, including a client move from
backpack slot 0 to hotbar slot 24). Forward+ renders at 1280×720 and 374×666 show independent contents
in both regions with all eight hotbar cells visible.

### F-030 · Replicated harvest state could briefly create a doomed VFX target — **fixed**

**Area:** gameplay/presentation · **Severity:** low · **Found/fixed:** 2026-08-16 by nettle during F-029

The first real-map ENet run logged eight deferred-call errors from `environment_vfx.gd::_apply_mesh`.
Replication assigned `visual_state` and `active` back-to-back, and both setters rebuilt the harvest
visual immediately; the environment controller had correctly deferred work for the first visual,
but Harvestable freed it in the same frame. `Harvestable` now coalesces replicated presentation
setters into one deferred rebuild while host methods explicitly flush once to preserve immediate
local feedback. The 39-assertion component check still passes, and the real-map two-process run now
passes depletion/respawn with no VFX or deferred-call errors.

### F-029 · Task 2.3's harvest lifecycle was not wired into the playable map — **fixed**

**Area:** gameplay · **Severity:** high · **Found/fixed:** 2026-08-16 by nettle after 2.3

Added serialized log, stone and iron-ore item definitions plus tree, stone-node and iron-node
harvestable definitions. The `HarvestWorld` autoload discovers the deterministic A-001 runtime
holders without editing the live map generator, moves each holder's collision under a
host-authoritative `Harvestable`, hides only the matching intact authored duplicate, and provides a
4 m first-person attack ray. Damaged/depleted props already placed as scenery remain decorative.

`harvest_world_check.gd` loaded the actual `playtest_hollow.tscn`, found the expected 5 trees, 4 stone
nodes and 2 iron nodes, and passed depletion, a single three-log yield, collision disable, explicit
respawn and collider-to-component targeting with zero failures. `harvest_world_net_check.gd` then
loaded that same map in two ENet processes: host depletion and respawn of layout prop 240 replicated
to the client, the host yielded exactly once, and the client yielded zero times. The original
39-assertion component check and its parameterless client-request ENet check also still pass.

### F-027 · `NetInterest.configure()` did not keep its returned filter alive — **fixed**

**Area:** netcode · **Severity:** high · **Found/fixed:** 2026-08-16 by nettle during 2.3

Godot 4.7.1 releases a `RefCounted` callable target when the caller discards the returned
`RadiusFilter`, causing repeated visibility call errors. `NetInterest.configure()` now stores the
filter as synchronizer metadata, which gives it exactly the synchronizer's lifetime; the interest
harness asserts that ownership and its full live-wire visibility run passes.

### F-026 · A deferred task pins the board's active milestone forever, hiding all remaining work — **fixed**

**Area:** tooling · **Found and fixed:** 2026-08-16 by vane while applying D-030

`_print_ready` in `.agent/bin/agent` picked the active milestone as the lowest one holding any task
whose status was not `done`, then listed only that milestone's `todo` tasks. `blocked` is not `done`,
so a single deferred task kept its milestone active permanently while contributing nothing pickable.

Marking 1.12 `blocked` under D-030 reproduced it exactly: M1 stayed active on the strength of that one
task, M1 had no `todo` left, and the board's *Ready to pick up* section vanished entirely — so
`agent start`, the one command every session begins with, would have told every future agent there was
no work at all, with M2 sitting untouched at 5/18.

**Fixed** by excluding `blocked` alongside `done` from that scan: a milestone whose only remaining work
is deferred is finished for the one question the scan answers, which is "what should I start now". The
status was never wrong — it already rendered as 🚧 — the milestone scan was.

Verified with `agent board`: *Ready to pick up* now heads M2 with `2.3`, the milestone table still
reports M1 honestly at **13/14**, and 1.12 still shows 🚧 `blocked` with its do-not-start title. The
progress counts are untouched, because they only ever counted `done`.

### F-009 · A GDExtension only loads if gitignored `.godot/extension_list.cfg` lists it — **fixed**

**Area:** build/tooling · **Filed:** 2026-08-16 by steam during 1.1

Godot loads GDExtensions from `.godot/extension_list.cfg`, but the whole `.godot/` directory was
ignored. A fresh clone or headless VM could therefore have the pinned GodotSteam addon on disk while
never registering its classes. The deterministic one-line registry is now the sole tracked exception
inside `.godot/`; all generated import and editor state remains ignored. D-022's reinstall recipe now
states that the committed registry is required beside the ignored addon binaries.

Verified by confirming `.godot/extension_list.cfg` is tracked, running `tools/steam_check.gd` against
the live Steam client (all checks passed on App ID 480), and running a normal headless project boot.

### F-019 · Generated asset import sidecars flood every clean-tree audit — **fixed**

**Area:** repository hygiene · **Severity:** low · **Found:** 2026-08-16 by reed during repository audit

Opening the project after adding the asset kits created 166 untracked `*.import` sidecars. Agents are
forbidden from editing or shipping these editor-owned files, but `.gitignore` did not exclude them,
so `agent start` reported roughly 180 uncommitted files and hid real work in noise.

Fixed by ignoring `*.import` globally. Committed source GLBs remain authoritative and Godot
regenerates local import state. Verified after a fresh `git fetch`: all 166 sidecars disappeared from
`git status`, leaving only the active 1.7 work, six delayed script UIDs, and the human-authored map
scene visible for separate handling.

### F-007 · Forgetting `MIRE_AGENT` made you silently impersonate another agent — **fixed**

**Area:** tooling · **Severity:** medium · **Found:** 2026-08-15 by nav during 0.8/0.9

`whoami()` in `.agent/bin/agent:81` resolves identity as `MIRE_AGENT` → the shared `.agent/session`
file → die. The session file holds exactly one name, so whoever ran `agent start` most recently owns
it. With two agents live, the one that forgets the export silently acts as the other:

```
$ export MIRE_AGENT=nav && .agent/bin/agent check    ->  session: nav
$ env -u MIRE_AGENT   .agent/bin/agent check         ->  session: claude   # the other agent's start
```

The consequences are quiet and compounding. Claim checks are evaluated against the wrong agent, so a
real collision can pass. The `in_grace()` window at `:394` is keyed to `r["agent"] == me`, so a
mislabelled session also loses the 6-hour grace on its own just-released claims and gets warned about
files it legitimately owns — which is what produced the spurious warning on `bdf8587`.

This is a known trade-off, not an oversight: the comment at `:82` explains that `MIRE_AGENT` exists
precisely so parallel agents don't clobber the shared session file. The gap is that forgetting it
fails *silently* rather than loudly.

Fix, if we want one: warn when the resolved identity comes from the session file while claims exist
under a different agent — the one case where the fallback is probably wrong. Cheaper alternative: just
make "always export `MIRE_AGENT`" load-bearing in `AGENTS.md` rather than a parenthetical.

**Filed wrong twice, corrected here.** v1 blamed the hook for not inheriting the environment — false,
it inherits normally. v2 claimed a hardcoded fallback to `claude` — also false, there is no such
constant. Both were guesses made without reading `.agent/bin/agent`. Reading it took two minutes and
would have got this right the first time.

**Mitigated, 2026-08-16 by claude — and the proposed fix above was itself wrong.** This entry's
cheap option was "make *always export* `MIRE_AGENT` load-bearing in `AGENTS.md`." Exporting does not
actually work: most agent tools run each shell call in a **separate process**, so `export MIRE_AGENT=net`
on its own line is gone by the next command and identity falls back to `.agent/session` anyway. Every
prompt in `DELEGATION.md` used exactly that pattern, so the mitigation this file recommended would
have left the bug fully intact while reading as fixed.

What landed instead: `MIRE_AGENT=<name>` is now a **per-command prefix** on every `agent` invocation
in `AGENTS.md`, `NEXT.md` and all three `DELEGATION.md` prompt blocks, with the reason stated inline
so nobody "simplifies" it back to an `export`. That survives regardless of shell lifetime.

**Still open**, and the reason this stays unresolved: the mitigation is documentation, so it holds
only as long as every agent follows it. The real fix is the loud-failure one this entry already
proposes — warn when identity resolves from the session file while claims exist under a different
name. Worth doing the first time two chats actually run in parallel.

Note for anyone re-reading the v1 correction: the hook inherits the environment fine. It is not the
problem, and it has now been blamed three times.

**Third failure mode, hit live 2026-08-16 while writing the mitigation above.** Per-command prefixing
fixes `agent` calls but NOT commits. `git commit` invokes the pre-commit hook, the hook re-runs
`agent check`, and it resolves identity from git's environment — which has no prefix on it. A commit
whose claims were entirely valid (`project.godot` claimed by `claude` under D-012) was blocked because
the hook resolved the committer as `net` from the session file. `MIRE_AGENT=claude git commit` went
through and printed the expected D-012 warning instead.

So the rule is `MIRE_AGENT=` on every `agent` command **and** on `git commit`, or just use
`agent ship`, which sets it correctly itself. This is the third distinct way this one shared-state
design has produced a wrong identity, which is the argument for the loud-failure fix rather than
another round of documentation.


**Fixed 2026-08-16 by larch — the loud-failure fix this entry kept proposing was the wrong target.**
Warning on a suspicious identity would have made the fourth failure mode legible instead of removing
it. The cause was never that agents forget the prefix; it was that identity was **shared mutable
state** (`.agent/session`, one name for the whole repo) which every parallel chat raced on.

Identity is now **derived, not declared**. `whoami()` resolves a per-chat session token out of the
environment — `CLAUDE_CODE_SESSION_ID`, Codex's equivalents, `TERM_SESSION_ID` for a human's terminal
— and maps it to a name in `.agent/sessions.json` (gitignored, machine-local). The name is assigned on
first use from a short word list, `crc32`-keyed off the token so the same chat resolves to the same
name in every process, and chosen to avoid names already held by other live sessions.

That kills all four failure modes at once, including the two documentation could never reach:

- **Two chats cannot collide.** Different tokens, different names, nothing shared to overwrite.
- **`git commit` is fixed too** — the hook is a child process, so it inherits the same session id and
  resolves the same agent. This was the third failure mode, and it needed no prefix at all.
- **Nothing to forget**, so nothing to fail silently. `agent start` takes no argument now.
- **Nobody has to invent names.** That chore was the actual cost to Sequoyah, and it is gone.

`MIRE_AGENT` still overrides everything, and an explicit `agent start <name>` still works — a human
who wants to be `sequoyah` on the board, or a script. Neither is needed.

Verified: the same chat resolves `larch` on repeated calls; two fabricated session tokens resolve
`coil` and `quill` with no overwrite; a claim, a `done` and a `git commit` all ran with no prefix and
the hook reported `session: larch` — the identity that held the claims. Docs updated in step: the
per-command-prefix rule is gone from `AGENTS.md`, `CLAUDE.md`, `NEXT.md` and `DELEGATION.md`'s rules
block. The archived prompt blocks in `DELEGATION.md` keep their prefixes, labelled as historical.

---

### F-015 · A finding could not be claimed, so fixing one always edited unclaimed files — **fixed**

**Area:** agent tooling · **Severity:** low · **Filed:** 2026-08-16 by claude, while fixing F-013 ·
**Fixed:** 2026-08-16 by claude

`agent claim` resolves ids against `docs/ROADMAP.md`, so `agent claim F-013 <files>` fails with
"unknown task F-013". Findings are exactly the work most likely to run *between* roadmap tasks, and
the only way to do one is to edit without a claim — which the pre-commit hook then warns about, one
line per file. Two costs, and the second is the real one: a warning that fires during correct work
teaches agents to ignore the warning that fires during incorrect work.

`ce8128a`'s commit was warned at for the same reason.

**Fixed in `.agent/bin/agent`: an F-number is a task id everywhere a task id is accepted.** Open
findings sync out of this file's `## Open` section into state the same way `agent sync` reads the
roadmap — adding and refreshing titles, never touching status — so `claim`, `brief`, `note`, `done`,
`handoff`, `drop` and `ship` all take `F-013` (case-insensitively, and syncing on demand so a
just-filed finding is claimable without `agent sync` first).

Three details that were not obvious, and are the reason this wasn't a one-line change:

- **Findings live in their own `Findings` milestone, excluded from the milestone plan.** `"Findings"`
  sorts before `"M0"`, so folding them into the existing scan would have made the current milestone
  the findings list forever — on the terminal board and in `BOARD.md` both.
- **They are excluded from the progress count** (`20/108` is roadmap work). Filing a finding must not
  move the milestone number; otherwise the number punishes the filing.
- **They sort after every roadmap task, in filed order** — `task_sort_key` gives them `(1000, n)`
  rather than the `(999, 999)` catch-all, which would have collapsed them into one indistinguishable
  bucket in every sorted view.

`agent brief F-013` prints the finding's full prose as its spec, so a finding is as self-briefing as
a roadmap task, plus the close-out contract that a fix is not done until the section moves here.
`agent done` re-reads this file and warns if the section is still under `## Open`.

Verified end-to-end on F-015 itself: claimed by F-number, noted via a lowercase `f-015`, briefed,
closed out and shipped through the hook — the commit that fixes this finding is the test that it
works. Error paths checked too: a resolved finding is refused with a reason, and an unknown task id
now points at the F-number form.

### F-013 · Spawned replication nodes were not in group `&"synced"` — **fixed**

**Area:** netcode/debug · **Severity:** low · **Filed:** 2026-08-16 by spawn, after 1.5 and 1.10
shipped within a minute of each other · **Fixed:** 2026-08-16 by claude

`net_debug_panel.gd` (1.10) counts synced entities via `DebugOverlay.track_group(&"synced")`, and its
header asks whoever spawns `MultiplayerSynchronizer` nodes to add them to that group. 1.5 shipped
without doing so — the two tasks ran in parallel and neither prompt mentioned the other — so the
panel's entity line read 0 in a real session while two players were visibly replicating.

**Fixed by settling the convention rather than by adding the line** (D-024): the group is *every
`MultiplayerSynchronizer`, one member each*, named once as `NetConfig.SYNCED_GROUP` and joined at
construction next to the authority assignment — so the two sites that build one today
(`PlayerController._build_synchronizer()`, `DummyReplicant._build_synchronizer()`) both do it, and
1.8's per-class synchronizers inherit the answer instead of re-deciding it.

Verified headless by `tools/synced_group_check.gd`: both sites are built for real, and the group is
read back off the live tree — a synchronizer added to a group after it enters the tree, or built on a
node nothing adds, would pass a grep and fail this. `tools/net_debug_panel_check.gd` still passes
19/19, including its real ENet host+client session.

### F-003 · §5a project settings not applied — **fixed**

**Area:** rendering · **Filed:** 2026-08-15 by claude · **Fixed:** 2026-08-15 by sequoyah (`ba5945f`)

All six §5a settings are now explicitly written in `project.godot`, so the contract is visible in the
file rather than inherited. `physics_interpolation=true` with `physics_jitter_fix=0.0` closes the
high-refresh judder risk that motivated this entry — load-bearing on the ProMotion MacBook, which
would have shown it before any other hardware.

**The gotcha, kept because it is not obvious and cost time:** Godot's editor writes only settings whose
value differs from the engine default and prunes the rest on save. `physics_ticks_per_second=60`,
`max_physics_steps_per_frame=8`, `vsync_mode=enabled` and `max_fps=0` all *are* the defaults, so
setting them in Project Settings did nothing to the file and they silently disappeared. They had to be
written into `project.godot` by hand. Now folded into `ARCHITECTURE.md` §5a as a note under the
settings table, so the next person reads it before spending the ten minutes.

**Reopened and closed differently, 2026-08-15, same day:** the prune is not a one-time editor quirk —
it fires on *any* editor save, not just a Project Settings edit. Setting the main scene during task 0.5
resaved `project.godot` and silently dropped all four lines again, proving the original fix (hand-write
the lines) doesn't hold: the next resave strips them regardless of how they got there. Chasing file
presence for a value that equals the engine default is unwinnable, so this stopped being the goal.
`tools/verify_setup.gd` now checks the *effective* runtime value via `ProjectSettings.get_setting()`
instead of raw file text — correct either way the value is sourced, and it can only fail on the thing
that actually matters: someone changing a value away from the target. Genuinely closed this time
because it no longer depends on the file staying in a state Godot won't hold.

### F-001 · Pre-commit hook scans the working tree instead of the staged set — **fixed**

**Area:** tooling · **Filed:** 2026-08-15 by claude during the §5a doc update · **Fixed:** 2026-08-15 by nav

The claim check blocked a commit when *any* file in the working tree was claimed by another agent,
even when that file wasn't staged — so two agents working at once blocked each other regardless of
overlap, and it trained everyone toward `--no-verify`.

Fixed in `cmd_check`: when `GIT_INDEX_FILE` is set, git is running us as a hook, so we judge
`git diff --cached --name-only` — what is actually being committed. Run by hand, `agent check` still
scans the working tree, which is the useful scope there. Falls back to the working tree if the diff
fails (e.g. a repo with no HEAD yet) rather than failing open.

Detecting the hook via `GIT_INDEX_FILE` rather than adding a `--staged` flag was deliberate: the
installed hook in `.git/hooks/` is not version-controlled, so a flag would have needed every clone to
re-run `install-hooks` before the fix took effect.

Verified: with `codex` holding a dirty unstaged `world/chunk/chunk_mesher.gd`, committing an unrelated
staged file now passes; staging `chunk_mesher.gd` itself still blocks.

Noted while testing: `FREE_PREFIXES` (`:32`) exempts `docs/`, `.agent/`, `CLAUDE.md`, `AGENTS.md`,
`README.md` and `.gitignore` from claim checking entirely. Claiming a docs file is therefore
ceremony — harmless, and still useful as a signal to other agents, but it is not enforced.

### F-008 · CLAUDE.md's close-out order makes the hook warn on your own files — **won't fix, not a defect**

**Area:** process · **Filed:** 2026-08-15 by nav during 0.8 · **Resolved:** 2026-08-15 by nav, same day

Filed on the belief that `CLAUDE.md`'s "`agent done`, then commit" ordering causes
`⚠ <file> — edited without a claim`, because `done` releases claims before the commit runs.

**It doesn't.** `.agent/bin/agent` already handles this: `cmd_done` records released files under
`st["recent"]` (`:287`) and `in_grace()` (`:394`) suppresses the warning for `RECENT_GRACE_HOURS = 6`.
The documented order is fine and needs no change.

The warning on `bdf8587` had a different cause. `in_grace()` matches on `r["agent"] == me`, and that
commit resolved `me` to `claude` rather than `nav`, so the grace record didn't match — a symptom of
**F-007**, not of the ordering. Fixing this here would have treated the symptom and left the cause.

Kept as a record so nobody refiles it. Anyone who sees this warning after a correct close-out should
check their `MIRE_AGENT`, not the docs.

---

### F-014 · Parallel agents share one git index, so `agent ship` can be blocked by — and then unstage — another agent's staged work — **fixed**

**Area:** process · **Severity:** medium · **Found:** 2026-08-16 by load during 1.9

`agent ship 1.9` was blocked by the pre-commit hook naming `project.godot` (spawn's, task 1.5) and
`ui/debug/net_debug_panel.gd` (netui's, task 1.10) — two files 1.9 never touched.

**The hook was right, and this is not F-001 regressing.** Verified: with only 1.9's files staged and
`GIT_INDEX_FILE` set, `.git/hooks/pre-commit` passes, *while those same two files are dirty in the
working tree* — so the staged-set scope is working as F-001 intended. Plain `git commit` does export
`GIT_INDEX_FILE` (checked against git 2.54.0); that is not the problem either.

The problem is one level up: **several agents share one working directory and therefore one git
index.** If agent A has run `git add` and not yet committed, agent B's `ship` stages its own files on
top of A's, and the hook correctly refuses a commit that would have swept A's files in. The claim
system prevents two agents editing one file; it does nothing about two agents staging into one index.

Two consequences, the second worse than the first:

1. A blocked `ship` looks like a tooling bug — the message names files you have never touched, which
   is exactly the shape that teaches people to reach for `--no-verify`. `cmd_ship` (`:424`) prints the
   hook output raw with no hint that the extra files may be another agent's staging.
2. **`cmd_ship`'s failure path runs `_git("reset")` (`:423`), which unstages *everything*, including
   the other agent's work.** B's failed commit silently discards A's staging. Nothing is lost from the
   working tree, but A's next `ship` restages from its own claim list and recovers — so this is
   survivable, not silent corruption. It is still B reaching into A's state.

Fixing it: `cmd_ship` should compare the pre-existing staged set against `to_stage` before committing,
say plainly "N staged file(s) belong to another agent — wait for them or ask", and on failure reset
only the paths it added (`git reset -- <paths>`) rather than the whole index.

**Correction to the commit record:** `ef1bc16`'s message asserts the hook "fell back to scanning the
whole working tree." That was my hypothesis at the time and it is **wrong** — the evidence above
disproves it. The commit's staged set was verified to be 1.9's files only before it went in, so the
commit itself is clean; only its explanation is. Not amended because `main` is shared with two live
agents and a force-push is worse than a wrong sentence. This entry is the correction.

**Fixed 2026-08-16 by claude, in `4d2d64a`** — at the root rather than at the message. `cmd_ship` now
commits **by pathspec** (`git commit -m ... -- <this task's files>`) instead of committing the whole
index, and its failure path resets only the paths it added. Git builds a temporary index from HEAD
plus the named paths for a partial commit, so another agent's staged work is neither committed nor
disturbed, and the pre-commit hook sees only this task's files.

That makes the blocked-`ship` case impossible rather than merely legible, so the suggested "N staged
file(s) belong to another agent" warning was not added — there is nothing left to warn about.

Verified: with a foreign file staged, a pathspec commit of five unrelated files passed the hook
(`check passed (5 changed file(s))`), committed exactly those five, and left the foreign file staged
and uncommitted.

The correction to `ef1bc16`'s commit message stands as written above — the record of a wrong
hypothesis, tested and disproved by the agent that made it, is worth keeping.

---

### F-010 · Two `.uid` files were left untracked when 1.4 shipped — **fixed**

**Area:** build/tooling · **Filed:** 2026-08-16 by claude while picking the next task

`autoload/net_transport.gd.uid` and `core/net/net_config.gd.uid` are untracked. Seventeen other `.uid`
files in the repo are committed, so this is an omission, not a policy — `agent ship` stages the files
a task claimed, and a `.uid` Godot regenerates alongside an edited script isn't one of them.

**Low severity today, and worth saying why rather than just "should commit it".** Godot 4.4+ writes a
`.uid` per script and resolves `uid://` references through it. Our scene files reference scripts by
`path=`, not `uid=` — checked in `player.tscn` and `greybox_test.tscn` — so a peer with a
freshly-generated UID currently breaks nothing. That stops being true the first time Sequoyah saves a
scene in the editor and Godot rewrites those references as `uid://`, which it does on its own.

The failure mode is the same shape as **F-009**: state that only exists on one machine, discovered on
the Linux VM at 1.12. Cheapest fix is to commit both files. The durable fix is `agent ship` staging
`<file>.uid` whenever it stages `<file>.gd`.

**Fixed 2026-08-16 by claude, both halves.** The sweep: nine orphaned sidecars committed in `9cdfe7f`
— the two named above plus seven more that accumulated as 1.3, 1.4, 1.5, 1.9 and 1.10 shipped, and
that a Godot editor session had just regenerated.

The durable half, which is the point: `cmd_ship` now stages `<file>.uid` whenever it stages
`<file>.gd`. The root cause was structural — a sidecar is authored by nobody and claimed by nobody, so
it could never appear in a task's file list, and `ship` stages exactly that list. Every task was
therefore guaranteed to leak one, and a per-milestone sweep would have been a fix with a timer.

---

### F-022 · Project metadata retained the superseded "Muck but better" name — **fixed**

**Area:** project metadata · **Found:** 2026-08-16 during project rename · **Resolved:** 2026-08-16 by kiln

Renamed the local workspace and GitHub repository to `MIRE`, updated `project.godot` so Godot displays
`MIRE`, and removed the remaining working-title wording from the design document. A repository scan
found no remaining "muck but better" references, and `tools/verify_setup.gd` passed headlessly on
Godot 4.7.1.
