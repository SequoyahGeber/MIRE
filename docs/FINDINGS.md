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

### F-161 · Task 5.3's three new ranged-combat RPCs shipped with no `PROTOCOL_VERSION` bump — `net_version.gd` was held all session by another lane's claim

**Area:** netcode · **Severity:** medium · **Found:** 2026-08-18 by lp during 5.3

`autoload/ranged_combat_service.gd` added `net_request_shot`, `net_shot_fired` and `net_shot_resolved`
— a real new wire shape, same class of change `core/net/net_version.gd`'s own header says must bump
`PROTOCOL_VERSION` ("an RPC's name, argument order, or @rpc config... changed"). `core/net/net_version.gd`
and `tools/handshake_check.gd` were both held by lane slate17's 3.7 claim for this task's entire
session, so neither could be edited under AGENTS.md's claim rule. D-102 records the call (ship
un-versioned rather than stall the task) and why it's an acceptable transient risk given this project
ships from one evolving source tree, not staggered binaries.

**What closes this:** whoever next holds `core/net/net_version.gd`:
1. Bump `const PROTOCOL_VERSION: int = 19` to `20`.
2. Add a `## 20 (task 5.3)` comment naming the three RPCs, matching every entry above it.
3. Raise `tools/handshake_check.gd`'s `_check("PROTOCOL_VERSION reflects task 4.8's Wellspring channel RPC", NetVersion.PROTOCOL_VERSION == 19, ...)` assertion to `== 20` (and its label, since it will no longer be about 4.8).
4. `agent godot --script tools/handshake_check.gd` green is the actual closing proof — not just the absence of a WARN line.

No code change to `ranged_combat_service.gd` itself is needed; the RPCs are already correct and
covered by `tools/ranged_combat_check.gd`/`tools/ranged_combat_net_check.gd`, both `failures=0`. This
is purely the bookkeeping bump D-100 already hit once for task 6.1 (that task avoided it by reusing
`WorldDeltaLog` instead — not an option here, see D-102).

### F-158 · `bog_crawler` (task 4.11's corrupted spawn-table variant) is visually identical to a normal crawler

**Area:** content/vfx · **Severity:** low · **Found:** 2026-08-19 by lm during 4.11

Task 4.11 wired `systems/waves/wave_spawner.gd` to substitute `content/enemies/bog_crawler.tres`
for the default `crawler` slot with a probability that scales with `MireGrid` corruption at the
spawn point — the "corrupted spawn tables" SPECS.md 4.11 asks for. `bog_crawler` reuses
`enemy_crawler.glb` as-is (tankier/slower/harder-hitting stats only; no new art was authored — 4.11
is mechanics, not asset authoring, and content is hand-authored one asset at a time per D-073). The
result is mechanically real but **invisible to a player**: a bog_crawler and a crawler currently
render, animate and sound completely identically, so nothing on screen tells a player the Mire has
made this fight harder until it already has.

Task 4.10 (Mire visuals — shader tint, fog, particles) is the natural owner of a fix: even a simple
material tint or a corruption-VFX attachment on `bog_crawler`'s instance would close this. Filing
rather than fixing here because 4.10 hasn't shipped yet and this task's own scope was the mechanic,
not the skin.

### F-151 · `ui/loot/chest_ui.gd` was never registered, so no chest in the game could be opened — **fixed**

**Area:** ui · **Severity:** high · **Found:** 2026-08-18 by slate17 during 3.7

Task 3.5 shipped `ui/loot/chest_ui.gd` — the client-local panel that finds the nearest chest, turns
[E] into exactly one `request_open()`, and renders the result. Every other UI system in the project
is an autoload (`InventoryUI`, `CraftingUI`, `AttunementUI`, `VitalsHud`, `LobbyMenu`). This one was
not, and nothing else loaded it: no `[autoload]` line, no `.tscn` instancing it, no `preload` from
any script. **There was no way to open a chest in the running game at all** — the whole loot path
existed and was unreachable, which is precisely what CLAUDE.md means by "a script nothing loads
isn't shipped" (F-051).

It went unnoticed because every chest check drives `Chest` directly: `chest_check.gd` calls
`request_open()` on a node it built itself, and `chest_net_check.gd` does the same across two
processes. Both are correct tests of the authority path and neither can see that nothing in the game
ever calls it.

**Fixed here** with `agent autoload ChestUI ui/loot/chest_ui.gd`, verified by a clean boot and
`tools/verify_setup.gd` (all checks passed). Worth a general habit: a UI script with no autoload
line and no scene reference is dead code until proven otherwise, and `verify_setup`'s autoload
assertion is the place a future orphan would be caught cheaply.

### F-139 · `ChunkStreamer`/`ResourceScatterField` still have no real caller — the live game still ships the authored Hollowmere map, not the procedural pipeline

**Area:** worldgen / netcode · **Severity:** low · **Found:** 2026-08-18 by lm during 4.6

Tasks 4.3 and 4.4 both shipped pure, tested, unreachable systems and said so explicitly in their own
`DELEGATION.md` entries: "nothing in the shipped game instantiates a `ChunkStreamer` yet... waiting
on 4.6." Task 4.6 shipped the piece those notes were waiting on — seed replication
(`core/game_state.gd`) and the chunk-keyed mutation log (`autoload/world_delta_log.gd`) — and proved
both mechanisms work with a real two-process ENet check (`tools/seed_sync_check.gd`). **It did NOT
put a `ChunkStreamer`/`ResourceScatterField` pair into the actual playable level.** The shipped game
still boots into the hand-authored Hollowmere map (`world/gen/authored_world.gd`); the procedural
pipeline remains exactly as reachable as it was after 4.4 — by a check script that builds its own
throwaway scene, not by anything a player's session ever runs.

**Why not closed here:** swapping Hollowmere for procedural generation is not a mechanism task, it is
a full map cutover — every system F-076 generalized against Hollowmere's launch (`EnemyWorld`,
`HarvestWorld`, and F-112's still-open `Undergrowth` gap), every POI/nest marker, and 4.7's
POI-placement task (not yet built) would all need to agree on the new map before a player could
stand on it safely. Guessing at that scope inside a T2 "seed replication + delta sync" task would
have been exactly the kind of scope creep `AGENTS.md` warns against.

**What to do about it:** whichever task actually intends the island to be procedural (most likely
after 4.7 POI placement, possibly not until M4's playtest gate in 4.12) is where a real level scene
gets a `ChunkStreamer` + `ResourceScatterField` pair wired against `GameState.run_seed`, following
the exact API both `DELEGATION.md` entries already document. Until then, Hollowmere is the map, and
that is a decision this finding is recording, not a bug anyone introduced.

### F-112 · `world/gen/undergrowth.gd`'s prop-avoidance still has no map-agnostic check — F-076's third system, not lifted

**Area:** worldgen · **Severity:** medium · **Found:** 2026-08-18 by lp during F-076

F-076 generalized two of the three systems Hollowmere's launch exposed (`EnemyWorld`, `HarvestWorld`)
into `tools/world_contract_check.gd`, which runs against whatever map is `project.godot`'s main scene
with no per-map code. The third — `Undergrowth`'s "don't grow on top of a prop" rule
(`world/gen/undergrowth.gd:_is_prop`) — was not: it wasn't in this task's claim
(`autoload/enemy_world.gd`, `autoload/harvest_world.gd` only), and unlike the other two it has no
clean ground-truth field to read straight from a layout — "which props are solid" isn't in the JSON,
only in which collider the generator happens to tag with `prop_group`. The only check for it today is
still `tools/hollowmere_check.gd::_check_undergrowth_stays_off_props`, which is Hollowmere-specific
(reads `world.height_at()` and hardcodes the "Undergrowth"/"World" node names of that one scene).

**What to do about it:** the shape that generalized the other two should transfer — sample a handful
of each MultiMesh's instance transforms, ray down onto the SAME collider the placer used, and assert
the landing collider is never in `prop_group` — but doing that without a specific map's coordinates
needs `Undergrowth` itself to expose something like `sample_ground_gaps() -> Array[float]` the way
`EnemyWorld`/`HarvestWorld` now expose `expected_*_count()`, so a generic tool can ask the system
rather than reimplementing its raycast. Needs a claim on `world/gen/undergrowth.gd` and
`tools/world_contract_check.gd`.

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

### F-044 · Concurrent headless Godot runs share one import cache, which is the likely cause of F-038

**Area:** tooling · **Severity:** medium · **Found:** 2026-08-17 by yarrow21 during 0.12

Every check in `tools/` runs `Godot --headless --path .`, and every one of them reads and writes the
same 42 MB `.godot/` import cache. Nothing serialises them. With one agent that was fine; with three
lanes dispatched at once (D-036) it is a race, and it costs a whole dispatch when it fires.

This is almost certainly what **F-038** is describing — `inventory_net_check` "intermittently fails
its grant wait under machine load." Machine load is the symptom; a second engine rewriting the
import cache mid-run is a better explanation than slowness, because a slow machine should make the
wait *longer*, not make the grant never arrive.

Observed while building 0.12: an audit session was running ten checks in a bare `for` loop
(`Godot --headless --path . --script tools/$s.gd`) at the same time as this task's own verification.

**Mitigated, not fixed:** `agent godot --script tools/x_check.gd` now takes an exclusive lock
(`.agent/locks/godot.lock`) and every work order tells lanes to launch the engine that way. The
mitigation only binds callers who use it — a bare `Godot --headless` still bypasses it. Fixing it
properly means either making the checks tolerate a shared cache or giving each lane its own
`.godot/`, which costs a full reimport per lane. Re-test F-038 under the lock before doing either.

**2026-08-18, lp — the F-038 hypothesis here was wrong; this finding's general claim stands on its
own.** F-038 is fixed (see Resolved) and its actual cause was a pure ordering race inside the two
checks (grant sent before the host's own `InventoryService` had created the peer's store) —
reproduced and fixed entirely under the `agent godot` lock, with no import-cache contention involved
and no other lane running at the same time. So the import-cache race this finding describes is real
and still open for whatever *does* trigger it, but it was never F-038's cause; the two just happened
to share a "grant timeout under load" symptom. Retitling would break the F-number-in-title convention
other entries link against, so left as-is with this correction instead.

---

**2026-08-18, bram1 (director) — instrumented, still not decided.** The choice this finding names —
make the checks tolerate a shared cache, or give each lane its own `.godot/` at the price of a full
reimport each — is deliberately still open, because it should be made on measurements rather than on
a guess. What shipped instead is everything needed to take that measurement, after the lock was
observed serialising four concurrent runs and killing one lane outright:

- `file_lock` names its holder, heartbeats every 30 s with elapsed time, and reports how long a
  caller waited. A multi-minute wait is normal with six agents; before this it was one dim line and
  then silence, which is what F-086 misread as a hang before it stopped mid-task.
- A holder record whose pid is gone now reports itself stale rather than claiming a free lock is held.
- `agent godot` kills the F-104 silent hang at 45 s instead of letting it hold the lock for eight
  minutes (see F-104, Resolved).

So the contention is now visible and bounded. **Decide the cache question against real hold times,
not against this paragraph.**

### F-057 · A-003's deterministic-rebuild claim is false: two crafting-station GLBs differ byte-wise across identical rebuilds

**Area:** art pipeline · **Severity:** low · **Found:** 2026-08-17 by tine18 during the 2.1j palette migration

`assets/crafting_stations/exports/station_stone_furnace.glb` and `station_workbench_upgraded.glb`
change content — same byte length, different bytes — when `tools/blender/build_crafting_stations.py`
runs twice with no source change. Both were already dirty in `git status` at the start of the 2.1j
session, so this predates that task; the migration only surfaced it, because diffing catalogs across
rebuilds became routine.

The cause is almost certainly the bevel modifier. `build_ward_set.py` overrides `box()` with a
bevel-free version and says why: Blender's bevel modifier changed four float bytes between otherwise
identical background exports on Apple Silicon. The station kit has 23 `bevel=` call sites, does not
override `box()`, and the two affected stations are the bevel-heavy ones — worktops, drawers, handles.

This matters because the verification contract requires a deterministic clean rebuild and A-003 is
recorded as having passed it. Either that check never compared two rebuilds of this family, or it
compared sizes rather than bytes.

Left open deliberately: both fixes are art-owner calls. Drop bevels from the station kit as the Ward
set did (byte-stable, but squares off deliberate chamfers and changes polygon counts), or accept the
drift and weaken the contract for this one family. `mire_art.box()` now carries the warning in its
docstring so the next family chooses deliberately instead of inheriting it.

---

### F-130 · Three console commands never migrated to CommandService — they register via console.call("register", ...), which 3.13's sweep could not see

**Area:** tooling · **Severity:** low · **Found:** 2026-08-18 by yarrow21

`f9cb6f7` ("CommandService front door: ... **migrate every console command**") left three behind, and
every headless run since prints their deprecation warnings:

```
[WARN] dev: DebugConsole.register('fps_cap') uses the deprecated shim — migrate to
       CommandService.register_spec() (docs/COMMANDS.md §2.1)
[WARN] dev: DebugConsole.register('vsync')  ... same
[WARN] dev: DebugConsole.register('gfx')    ... same
```

- `core/dev/dev_frame_cap.gd:61,63` — `fps_cap`, `vsync`
- `autoload/graphics_quality.gd:181` — `gfx`

**Why the sweep missed them, which is the part worth keeping.** Every migrated caller referenced the
autoload directly, so `grep -rn 'DebugConsole.register('` found it. These three do not: they resolve
the node at runtime and invoke it by name —

```gdscript
var console: Node = get_node_or_null(^"/root/DebugConsole")
if console == null or not console.has_method("register"):
    return
console.call("register", &"gfx", _cmd_gfx, "gfx [low|medium|high] | ...")
```

so the command name never appears next to the method name in the source text and no grep for the
call site can match. The same shape will hide the next migration too. A source-text regression guard
in the style of the one F-060 already established for `tools/*_net_check.gd` would catch it: assert
that no `.gd` outside `autoload/debug_console.gd` contains `call("register"` / `call(&"register"`.

**Cost today:** three WARN lines on every single headless check run — against a repo whose audit
standard is 0 error lines and whose checks are read by eye. It is noise that trains agents to skim
warnings. The commands themselves work; the shim still forwards them (`command_service.gd:210`
handles bare-String returns from old handlers).

**Fix:** port the three to `CommandService.register_spec()` with typed specs and a declared scope
(`gfx`, `fps_cap` and `vsync` are all LOCAL — they change this peer's rendering, nothing else's),
then delete the shim path if nothing else uses it. Needs a claim on `core/dev/dev_frame_cap.gd`,
`autoload/graphics_quality.gd`, and whatever guard file the regression check lands in.

**Partial fix 2026-08-18 by lp (task 3.16).** `fps_cap` and `vsync` are migrated —
`core/dev/dev_frame_cap.gd` now registers both through `register_spec()`, and neither warns on a
headless run anymore. `gfx` is still on the shim: `autoload/graphics_quality.gd` was held under
another task's claim (F-144) for this task's entire run, so the one remaining line is a one-`register_spec`-call
fix for whoever next holds that file — same shape as `fps_cap` above it. Still **Open** for that
reason; not moving to Resolved on two thirds of a fix. The source-text regression guard this finding
proposed was not built — `tools/command_catalog_check.gd` (3.16) catches the same class of leftover
differently, by refusing to count a shim-registered verb as coverage, but that only fires for names
§7 already lists, so a *new* verb someone forgets to migrate would still slip past silently as F-130
originally warned.

**Second session 2026-08-18 (lp) — still blocked on the same file, guard built this time.**
`agent claim F-130 autoload/graphics_quality.gd` still fails — held by `nettle12` for F-144,
unchanged from the last session (confirmed via `agent brief F-130`'s "held by someone else" list).
Per protocol did not force or work around it: `gfx` is untouched. Instead built the regression guard
this finding proposed in its "why the sweep missed them" section — `tools/command_shim_check.gd`,
a source-text check in the style of `tools/net_check_pattern_check.gd` (F-060), asserting no `.gd`
outside `autoload/debug_console.gd` contains the reflection shape `.call("register", ` /
`.call(&"register", `. Verified it actually catches the shape it's meant to: `agent godot --script
tools/command_shim_check.gd` → `COMMAND_SHIM_CHECK scripts=228 hits=1 failures=2`, the one hit being
`autoload/graphics_quality.gd:197` (`gfx`) — exactly the remaining case, and exactly what a check
that fails until the fix lands is supposed to report. Re-ran the other three to confirm nothing
regressed: `command_catalog_check` `failures=0`, `command_check` `failures=0`, `command_net_check`
`failures=0`. `docs/SPECS.md` gained the `## F-130` block that was missing (§0 of this task's own
work order) — see it for the exact remaining fix shape and the done-means checklist, including
`tools/command_shim_check.gd failures=0` as the new closing condition. Still **Open**: the fix is
now fully specified and has a check that will announce the moment it lands, but `gfx` itself still
needs `autoload/graphics_quality.gd` free to claim.

---

### F-144 · Props have no LOD and no cross-asset batching: every one of ~2,900 renders at full detail, in every shadow cascade, at every distance

**Area:** perf · **Severity:** high · **Found:** 2026-08-18 by nettle12

Two levers that the frame-budget work (F-090/F-098) named but never pulled, found while looking for
what is left after dynamic resolution shipped.

1. NO MESH LOD ANYWHERE. `visibility_range_begin/end` and `lod_bias` appear nowhere in the
   codebase. The terrain has a real LOD ladder (ChunkMesher LOD0/1/2), but every prop, every
   flora MultiMesh and every harvestable renders its full triangle count at any distance, and
   again in each of the four shadow cascades. On a weak GPU this is the dominant cost.

   The merged prop meshes make it worse than the default: `AuthoredWorld._mesh_parts` builds an
   ArrayMesh at runtime with `add_surface_from_arrays`, and a runtime ArrayMesh carries no LOD
   levels at all — so even the automatic LOD Godot generates for imported meshes is discarded by
   the very merge that made the map shippable.

2. F-100's per-chunk cross-asset batching never landed. state.json marks F-100 done; the
   finding text still says BLOCKED on F-097, and F-097 resolved on 2026-08-18. `_build_props`
   still groups by `(chunk, kit, asset)`, one MultiMesh per group.

Measure before and after with tools/render_census.gd (added by this finding) and
tools/perf_probe.gd.

---

### F-146 · Nothing in the game places a chest, so the gilded tier's 1-2/island budget has no owner

**Area:** world-gen · **Severity:** medium · **Found:** 2026-08-18 by reed16

`docs/ITEMS.md` §6 assigned four small things to task 3.5. Three of them — `LootEntry.kind`/`rarity`,
`LootTableDef.roll`'s powerups bucket, and `Chest.cost_coins`/`locked_by` — were caught by F-140 and
fixed inside 3.2. **The fourth was not**, and F-140 said so explicitly while resolving the rest:
"a placement budget for `gilded` is still open and belongs to whatever places chests in the world."

The reason it could not be fixed there is still true: **nothing places chests in the world at all.**
`grep -rn chest --include='*.gd' world/` returns zero hits. `systems/loot/chest.gd` is a complete,
net-authoritative, headlessly-proven chest that no world-generation code ever instantiates. All
seven tiers are authored (`content/loot/{small,bog,strongbox,wellspring,gilded,sunken,boss}.tres`)
and reachable through `Registry.get_loot_table`, so the content exists and the consumer does not.

What the spec actually asks for, so it is not re-derived from scratch:

- `ITEMS.md` §5 line 314 — **Gilded Chest** (`gilded`) is a "rare spawn (≈1–2/island) **or** a Gilded
  Key", and is "unmistakable at distance". The count is a per-island budget, not a per-chunk
  probability: a Poisson-disc or weighted-scatter pass that happens to average 1.5 per island is not
  the same guarantee, and the "unmistakable at distance" clause means placement has to survive
  whatever LOD/culling policy F-144 lands on.
- `ITEMS.md` §6 item 4 — "A placement budget for `gilded` (≈1–2 per island) wherever chest placement
  lands."
- §5 also gives every other tier a spawn rule, so gilded is the *tightest* constraint but not the
  only one this owner inherits.

**Why this is not simply "part of 4.7".** Task 4.7 (POI placement: seeded Poisson-disc, Wellsprings +
landmarks) is the obvious home, and probably is the home — but two things make it worth its own
finding rather than a line inside that task. First, a per-island *count* budget is a different
algorithm from Poisson-disc *spacing*, and 4.7's spec names spacing only. Second, F-139 records that
`ChunkStreamer`/`ResourceScatterField` still have no real caller and the live game ships the authored
Hollowmere map — so "per island" has no runtime meaning yet, and whoever takes this has to decide
whether gilded chests are placed by the procedural pipeline (correct, but unreachable today) or hand-
placed in the authored map as an interim (reachable, but throws the budget away at the D-092 switch).

That decision is the finding. Filed rather than folded into F-140's resolution so it is not lost when
F-140 moves to '## Resolved'.

---

### F-149 · F-141's docs edits got committed under F-144's message — a concurrent agent's plain 'git commit' absorbs another lane's staged-but-uncommitted files

**Area:** coordination · **Severity:** low · **Found:** 2026-08-18 by lm

This session (lm, F-141) staged exactly three named files — `git add docs/FINDINGS.md docs/SPECS.md
docs/DELEGATION.md` — after `agent ship F-141` left them for hand-commit (docs/ is exempt from
claims, F-006). The first `git commit` attempt was correctly BLOCKED by the pre-commit hook because
other files were already sitting staged in the shared index — `autoload/graphics_quality.gd`,
`core/render/mesh_merge.gd`, `systems/harvesting/harvestable.gd`, etc. — all claimed by a different
concurrent lane (nettle12, F-144), not this session's. Those got unstaged with `git reset --
<paths>` (non-destructive, working tree untouched) and the commit was retried with only the three
named docs files staged.

Before that retry ran, nettle12's own `agent ship`/`git commit` (their commit e5f96b1, "F-144: merge
kit geometry everywhere it is stamped, and bound how far props draw") landed first — and its diff
shows all three of F-141's staged docs edits inside it: the F-141 FINDINGS.md `**fixed**` +
`## Resolved` move, the new F-141 SPECS.md block, and the F-141 DELEGATION.md `Current state` entry
all appear in `e5f96b1`, none in a commit of this session's own.

**Root cause:** `git commit` with no pathspec commits the WHOLE index, not just what the committing
agent itself staged. AGENTS.md already documents the sibling hazard — a committing agent's OWN
`git add docs/` (blanket) sweeping someone else's untracked docs edits into their commit — and its
fix (name files exactly) is what this session followed. But naming files on `git add` only protects
the ADDER's own blanket-add risk; it does nothing about a DIFFERENT concurrent agent's plain `git
commit` scooping up files the first agent staged-but-not-yet-committed, because the git index itself
has no per-agent partition and no lock of its own — only claimed *files* are protected (F-006 exempts
docs/ from claims entirely), and the index is repo-wide shared state between every lane working in
this one checkout.

**Consequence here:** cosmetic only. The content is correct, complete, and already pushed to origin —
verified by re-reading `e5f96b1`'s diff for all three files, which matches exactly what this session
staged. Only the commit's authorship/message is wrong (credited to F-144's commit instead of a
dedicated F-141 docs commit). Nothing was lost, corrupted, or silently dropped.

**What would close this:** a narrow window exists between "docs files staged" and "docs files
committed" during which any other lane's commit can absorb them. Options for whoever picks this up:
(a) `agent ship`/a new `agent commit-docs <id> <files>` helper that commits immediately after
staging, shrinking the window to effectively zero; (b) accept the risk as low-severity and cosmetic
(current state) since content is never lost, only re-attributed, and file it under "known, harmless"
in AGENTS.md's git-hazards section next to the blanket-add note it already carries. This finding
exists so the next agent who sees a docs commit under a stranger's message understands why, instead
of assuming their own `agent ship`/hand-commit silently failed.

---

### F-154 · Two events in COMMANDS.md §5.2's own illustrative hook vocabulary — `run_started`,
`player_downed` — have no shipped signal to bind to

**Area:** commands · **Severity:** low · **Found:** 2026-08-18 by lp during 3.17

COMMANDS.md §5.2 names the starting event vocabulary as "`run_started`, `night_started`,
`day_started`, `player_downed`, `enemy_died`". Three of those are real, existing signals
(`DayNight.night_started`/`day_started`, `EnemyWorld.enemy_died`) and `CommandService._HOOK_EVENTS`
(task 3.17) binds all three. The other two do not exist anywhere in the codebase today: nothing emits
a `run_started` signal (there is no run-lifecycle system yet), and `PlayerHealth` has
`downed_flag_changed(peer_id, downed)` — fired on both down AND revive — but no one-shot
"just went down" signal a hook could bind to without also firing on every revive.

Neither `player_health.gd` nor a run-lifecycle owner was in 3.17's claim, so no new signal was added
to reach the illustrative list — that would have meant editing files outside this task's claim set to
manufacture a signal for a mechanism that ships disabled by default anyway (D-094). Naming either
event in a HookDef today is not silent, though: `CommandService.wire_hook()` logs a MireLog error at
boot ("unknown event '...' has no signal binding") instead of quietly never firing, so authoring one
by mistake is loud, not a mystery.

**What would close this:** whichever task adds a real run-lifecycle owner (a "run started" moment
beyond just "the level loaded") or a player-health "downed" edge signal (not the existing level-
triggered `downed_flag_changed`) should add one row each to `CommandService._HOOK_EVENTS` — the table
`wire_hook()` already reads is the whole cost of a new event once the real signal exists.

### F-165 · Task 6.5's two new extraction RPCs shipped with no `PROTOCOL_VERSION` bump — `net_version.gd` was held all session by another lane's claim

**Area:** netcode · **Severity:** medium · **Found:** 2026-08-19 by lm during 6.5

`systems/extraction/extraction_ship.gd` added `net_request_repair` and `net_request_toggle_departure`
— two real new wire shapes, plus its own `SceneReplicationConfig`
(`repair_stage`/`departure_channeling`/`departure_progress_sec`/`departure_required_players`/
`departed`). `core/net/net_version.gd` and `tools/handshake_check.gd` were both held by lane
slate17's 3.7 claim for this task's entire session, the identical situation F-161 already recorded
for task 5.3's ranged-combat RPCs — D-102 covers why shipping un-versioned is an acceptable transient
risk here.

**What closes this — same list as F-161, do both in one pass:**
1. Bump `const PROTOCOL_VERSION: int = 19` to `20`, or `21` if F-161 lands first.
2. Add a `## N (task 6.5)` comment naming `net_request_repair`, `net_request_toggle_departure`, and
   the ExtractionShip synchronizer's five properties, matching every entry above it.
3. Raise `tools/handshake_check.gd`'s version-number assertion to match, and its label.

### F-166 · `world/gen/authored_world.gd` has no `shipwreck` marker kind, so task 6.5's ExtractionShip is built but never reachable in the live Hollowmere map — same shape as F-146's chest gap

**Area:** world-gen · **Severity:** medium · **Found:** 2026-08-19 by lm during 6.5

`autoload/extraction_service.gd` follows `wellspring_service.gd`'s exact bridge pattern: it watches
`&"authored_world_marker"` for a child whose `kind` meta is `"shipwreck"` and builds a live
`ExtractionShip` there. `grep -n 'shipwreck' world/gen/authored_world.gd` returns zero hits — the
Hollowmere layout has no such marker, unlike the Wellspring's `"objective"` marker, which some
earlier task (4.8) already added. `content/poi/shipwreck.tres` authors the procedural placement
(task 4.7's PoiMap, target 3/island), but F-139 already recorded that the live game still ships the
authored Hollowmere map, not the procedural pipeline — so neither path currently puts a shipwreck a
player can ever see.

`world/gen/authored_world.gd` was held all session by lane nettle12's F-144 claim, so this task could
not add the marker itself; `tools/extraction_check.gd` proves the whole repair/board/departure state
machine against a synthetic marker instead (the same "unreachable but correct" shape F-139 describes
for tasks 4.3/4.4).

**What closes this:** whoever next holds `world/gen/authored_world.gd`, drop one `Marker3D` in the
Hollowmere layout with `meta("kind") == "shipwreck"`, in a shore-adjacent spot — same recipe
`wellspring_service.gd`'s own "objective" marker already proves works. No gameplay-side change is
needed; `ExtractionService` picks it up automatically the next time the scene builds.

### F-169 · Task 6.7's new `net_run_defeated` RPC shipped with no `PROTOCOL_VERSION` bump — `net_version.gd` was held all session by another lane's claim

**Area:** netcode · **Severity:** low · **Found:** 2026-08-19 by lm during 6.7

`autoload/defeat_service.gd` added `net_run_defeated` (host → everyone, reliable) — a real new wire
shape, same class of change `core/net/net_version.gd`'s own header says must bump
`PROTOCOL_VERSION`. `core/net/net_version.gd` and `tools/handshake_check.gd` were both held by lane
slate17's 3.7 claim for this task's entire session, so neither could be edited under AGENTS.md's
claim rule. This is the same gap F-161 (task 5.3) and F-165 (task 6.5) already recorded, for the
same reason, against the same held files — D-102 covers why this is an acceptable transient risk
for a project that ships from one evolving source tree rather than staggered binaries.

**What closes this:** whoever next holds `core/net/net_version.gd` — likely the same pass that
closes F-161/F-165, since all three are one bump apiece:
1. Bump `PROTOCOL_VERSION` past whatever F-161/F-165 left it at.
2. Add a `## N (task 6.7)` comment naming `net_run_defeated`, matching every entry above it.
3. Raise `tools/handshake_check.gd`'s version assertion to match, updating its label.
4. `agent godot --script tools/handshake_check.gd` green is the actual closing proof.

No code change to `defeat_service.gd` itself is needed — the RPC is already correct and covered by
`tools/defeat_check.gd` (`failures=0`), which calls it directly the way a real client receiving it
would (see that check's own "net_run_defeated" section).

---

### F-170 · `tools/lobby_menu_check.gd` fails (5/24) whenever the dev machine's own Steam client is actually running

**Area:** tooling/checks · **Severity:** low · **Found:** 2026-08-19 by lm during 6.10

The check's "Steam-less machine" branch (join/host/copy all refused, status naming Steam as the
reason) assumes `SteamLobby` cannot reach a real Steam client. On a machine where Steam.app is
actually running and logged in, `SteamAPI_Init()` succeeds, so `request_join`/`request_host` attempt
a REAL join/host instead of failing fast — the five assertions that expect a Steam-unavailable status
line fail because the status line says something else (a real, in-flight join attempt) instead.
Reproduced on a clean `agent baseline` checkout of HEAD (`5a09b1c`), so it is not caused by any
change in this task or a regression to chase — it is a standing gap between the check's assumption
and this dev machine's actual state.

**What closes this:** either mock/stub `SteamAPI_Init()` away for this check specifically (the check
already accepts that "the happy path... needs a live Steam client and is 1.12's run"; the SAD paths
it asserts should not depend on Steam's absence either), or have the check skip its Steam-unavailable
assertions when `SteamLobby` reports Steam as actually available, printing which branch it took so a
run against either machine state still means something.

---

### F-174 · No dev machine can stand in for "mid-range" — `tools/perf_probe.gd`'s baseline is only ever measured on the fastest hardware in the project

**Area:** perf · **Severity:** low · **Found:** 2026-08-18 by lm during 7.7

Task 7.7 ("Performance pass … target 60fps mid-range") re-ran `tools/perf_probe.gd`
(`.agent/bin/agent godot --display-driver macos --script tools/perf_probe.gd`) to get a current
baseline before deciding where to spend the task. Every config it printed for the shipped Hollowmere
level was already comfortably above 60fps at 1x resolution scale on this machine — "0 as shipped
(vsync ON)" alone reads 120fps, and every other toggle in the sweep (undergrowth hidden, shadows off,
render scale 50%, `gfx` presets) only goes up from there:

```
display: (3024, 1898) px backing store | screen scale 2.0x | refresh 120 Hz
  0 as shipped (vsync ON)         120 fps  med   7.17 ms  p95   9.86 ms
  1 vsync OFF (baseline)          140 fps  med   6.99 ms  p95   8.69 ms
  11 gfx preset low               285 fps  med   3.57 ms  p95   4.99 ms
```

This machine is an Apple M5 Pro — the fastest hardware anyone develops MIRE on, not the worst.
`docs/DECISIONS.md` (referencing F-090) already names "Sequoyah['s machine]" as the actual worst
computer this game must run well on, and F-006 already records that this project has no Windows or
Linux machine at all. Put together: nobody has ever run `perf_probe.gd` against hardware anywhere
near the "mid-range" the roadmap's own task title names, on any platform. Every perf decision made so
far (F-090's frame-budget audit, F-095, F-098's dynamic resolution, F-144's LOD/batching work) is
correct in relative terms — a toggle that saves 1.5ms here will save roughly proportional time on
slower hardware too — but the absolute "hits 60fps on mid-range" claim in the roadmap has never
actually been checked against anything but the fastest box in the project.

**Not fixed here** — there is no second machine to fix it with. Filed so the gap is visible rather
than silently assumed away by every perf task (including this one) that runs `perf_probe.gd`,
sees a number well above 60, and calls it done. **What closes this:** the same thing that closes
F-006 — Sequoyah (or a CI runner) with access to actual mid-range/worst-case hardware runs
`perf_probe.gd` there at least once, so the roadmap's "target 60fps mid-range" line has ever been
checked against anything but relative deltas on the fastest machine in the project.

---

### F-176 · `tools/audio/render_music.py`'s ambient tracks are not byte-identical on re-render, contradicting `docs/AUDIO.md`'s "reproduces the committed files bit-for-bit" claim

**Area:** audio · **Severity:** low · **Found:** 2026-08-18 by lp during 5.5

Task 5.5 added a third render (`BOSS_STINGER`) to `tools/audio/render_music.py` and ran the script's
`main()` to generate it, which re-renders `DAY`/`NIGHT` too (same `for cfg in (DAY, NIGHT):` loop the
committed tracks came from). Both fixed-seed tracks came out numerically identical in RMS/peak
(`ambient_day: 224s loop, peak -6.4 dBFS, rms -19.0 dBFS` — the exact numbers already in
`docs/AUDIO.md`), but the re-rendered `.ogg` files are NOT byte-identical to the committed ones:

```
git diff --stat: ambient_day.ogg 2896114 -> 2893916 bytes, ambient_night.ogg 2024105 -> 2024015 bytes
```

`docs/AUDIO.md` states "Renders are seeded: re-running reproduces the committed files bit-for-bit."
That is false on this machine — the numpy DSP synthesis itself is almost certainly deterministic
(fixed seeds throughout `mire_audio.py`, and the RMS/peak numbers matched exactly), so the divergence
is most likely in `encode()`'s OGG Vorbis path (`tools/audio/render_music.py`'s own comment notes it
routes through `soundfile`'s chunked writer specifically because the local ffmpeg build lacks
libvorbis) — a libvorbis/libsndfile version difference between whatever machine originally rendered
the committed files and this one would produce numerically-equivalent but not byte-identical Vorbis
streams, since Vorbis encoding is not required to be bit-reproducible across encoder versions the way
the underlying PCM synthesis is.

**Not investigated further, not fixed here** — out of task 5.5's claim (`ambient_day.ogg`/
`ambient_night.ogg` were never claimed; the working tree was restored with `git checkout --` before
this session's commit, so the two files ship unchanged). **What closes this:** either confirm the
PCM masters ARE bit-identical across machines (proving the gap is purely encoder-version drift in the
lossy OGG step, which would make `docs/AUDIO.md`'s claim technically about the WAV masters rather
than the shipped `.ogg`s and worth rewording rather than fixing) or pin/vendor a specific
libvorbis/libsndfile version so the encode step itself becomes reproducible. Whoever next touches
`render_music.py` should `git status` immediately after running its `main()` and `git checkout --`
away any diff to `ambient_day.ogg`/`ambient_night.ogg` they did not mean to produce — this session
nearly committed an unrelated ~4 KB regen of both tracks as a side effect of adding one new asset.

---

### F-178 · F-157's three new display-name RPCs shipped with no `PROTOCOL_VERSION` bump — `net_version.gd` was held all session by another lane's claim

**Area:** netcode · **Severity:** medium · **Found:** 2026-08-19 by lp during F-157

`autoload/net_transport.gd` added `net_request_display_name` (client → host), `net_display_name_changed`
and `net_display_name_snapshot` (both host → peers) — a real new wire shape, same class of change
`core/net/net_version.gd`'s own header says must bump `PROTOCOL_VERSION`. `core/net/net_version.gd`
and `tools/handshake_check.gd` were both held by lane slate17's 3.7 claim for this task's entire
session, the identical contention D-102/F-161 (task 5.3), F-165 (task 6.5), and F-169 (task 6.7) each
already hit and shipped through. D-120 records the call for this instance.

**What closes this:** whoever next holds `core/net/net_version.gd`:
1. Bump `const PROTOCOL_VERSION: int = 19` to `20`.
2. Add a `## 20 (F-157)` comment naming the three RPCs, matching every entry above it.
3. Raise `tools/handshake_check.gd`'s pinned-version assertion to `== 20` and update its label.

Consider, while there: F-161/F-165/F-169 name the SAME two files and are very likely still unbumped
too (each was blocked by the same claim, in the same order — task 5.3, then 6.5, then 6.7, then this
one) — check whether the version needs to jump by more than one, and whether all four RPC trios need
their own `## N (task X)` comment rather than collapsing into a single bump.

---

### F-180 · construction_check.gd's door-swing check now finds real strap-vs-frame overlaps at 0 degrees, previously hidden by F-148's crash

**Area:** tooling · **Severity:** medium · **Found:** 2026-08-18 by lm during F-148

F-148 fixed `_check_doors()`'s `AABB.grow(-0.004)` going negative on thin per-triangle bounds (see
`## Resolved` below). With that crash gone, `agent godot --script tools/construction_check.gd` now
runs `_check_doors()` to completion and reports real content:

```
FAIL  door_wood_leaf: Leaf_Strap_0 is inside the frame at 0 degrees
FAIL  gate_double_leaf_left: Gate_L_Strap_0 is inside the frame at 0 degrees
FAIL  gate_double_leaf_right: Gate_R_Strap_0 is inside the frame at 0 degrees
CONSTRUCTION_CHECK FAIL failures=3
```

Reproduced twice, deterministic both times. Every failure is a `_Strap_0` part (leaf-side hinge
strap hardware) reported inside the frame at 0 degrees (fully closed) — not a random assortment of
parts, so this reads as a real geometry issue with how the strap hinges are authored on these three
leaves, not check noise.

Before F-148's fix, `_check_doors()` built a per-triangle `AABB` that went negative-size on any
near-planar triangle, and `AABB.has_point()` errors out and returns `false` on an invalid box instead
of throwing — so every comparison against a degenerate frame solid was silently skipped rather than
evaluated. F-135's 2026-08-18 verification note (this file, `## Resolved`) recorded `CONSTRUCTION_
CHECK PASS` on `_check_doors()` at the time, which is consistent with this: the crash was masking
whatever overlap already existed then, not proof there was none.

**Why not fixed here.** `door.tscn`, `gate.tscn`, and `palisade_gate.tscn` — the source scenes for
these three leaves — are task 3.7's (slate17) uncommitted, actively-claimed work this whole session
(`git status` shows all three modified, unclaimed by F-148). F-148's own claim was scoped to
`tools/construction_check.gd` only. Whoever next holds those scenes should re-run `agent godot
--script tools/construction_check.gd` first — if task 3.7 finishes strap placement and the failures
clear on their own, this closes for free; if not, the strap hinge geometry on these three leaves
needs adjusting so the closed-leaf strap plate doesn't intersect the frame's collision volume.

---

### F-181 · `Wellspring._finish_recorruption()` has the same host-only-guard `EventBus` emit bug F-168 fixed for `wellspring_capped` — `wellspring_recorrupted` still only fires on the host

**Area:** systems/wellspring · netcode · **Severity:** low · **Found:** 2026-08-18 by lm during F-168

F-168 moved `EVENT_BUS.emit_wellspring_capped()` out of `_finish_cap()`'s host-only body and into
`capped`'s setter, because `EventBus` is a per-process static and a host-only emit never reaches a
client's own local bus. `_finish_recorruption()` (`systems/wellspring/wellspring.gd`) has the
identical shape: `EVENT_BUS.emit_wellspring_recorrupted(name, global_position)` sits directly in a
body only `host_tick()` calls, itself gated on `_owns_mutation()` at the top — so a non-host peer's
process never runs this line even though its own `capped` correctly replicates back to `false`.

**Why not fixed alongside F-168:** nothing subscribes to `wellspring_recorrupted` yet.
`core/events/event_bus.gd`'s own header comments call it a seam for a future system (same
"future systems hook into this" role D-092 already gives `wellspring_capped`), and grepping the
codebase for `subscribe_wellspring_recorrupted` today only turns up `event_bus.gd` itself. There is
no live undercount to fix — this is a landmine for whichever future system (MireGrid's per-peer
spread-rate bookkeeping is the obvious future consumer per `wellspring.gd`'s own header) is the
first to subscribe on a client, not a bug with a present-day symptom.

**What closes this:** the exact same move, applied to `capped`'s setter's true→false transition
(guard on `capped == false` after being `true`, since `capped`'s setter already fires
`_maybe_refresh_visual()` on every change and needs the emit gated the same way `wellspring_capped`
is gated on false→true). Re-run `tools/wellspring_recorruption_check.gd` — it already asserts
`EventBus.emit_wellspring_recorrupted fired exactly once`, so the existing coverage should catch a
regression here for free once whoever fixes this adds a replication-shaped case the way F-168's
`tools/wellspring_check.gd` change did for `wellspring_capped`.

---

### F-182 · tools/unlock_check.gd's corrupt-save test provokes two engine ERROR lines with no EXPECTED_ERROR_PATTERNS declaration

**Area:** verification · **Severity:** low · **Found:** 2026-08-19 by lm

_check_save_versioning() deliberately writes an invalid JSON file to TEST_CORRUPT_PATH and calls
UNLOCK_SAVE.load_data() on it, expecting (and correctly getting) the safe-default fallback — but
that fallback path logs two real engine lines ("Parse JSON failed" and "did not contain a JSON
object, starting fresh") that the check's own finish() print never declares, unlike
tools/chest_check.gd's own provoked-error line ("references unknown loot tail" ->
EXPECTED_ERROR_PATTERNS="references unknown loot tail" -- SPECS.md's standing rule 4). Found while
adding F-173's chest-gate integration tests to this file and grepping the run's own output for
ERROR lines as usual.

Not fixed here: pre-existing behavior, unrelated to F-173's own scope (unlock_service.gd,
loot_table_def.gd, chest.gd's new gate). failures=0 was already correct before and after my
change -- the check() counter never counted these push_error calls as failures either way, so
nothing is silently passing that should fail. This is a standing-rule-4 paperwork gap, not a
correctness bug.

What closes this: add `· EXPECTED_ERROR_PATTERNS="Parse JSON failed|did not contain a JSON
object"` to unlock_check.gd's finish() print, same shape chest_check.gd already uses.

---

## Resolved

### F-173 · `UnlockService.is_content_unlocked()` (task 6.9) has no caller anywhere in the game — wiring the first real gate needs a cross-peer design decision, not just a call site — **fixed**

**Area:** meta-progression/netcode · **Severity:** medium · **Found:** 2026-08-19 by lm during 6.9

`autoload/unlock_service.gd`'s `is_content_unlocked(content_id)` correctly reads locked/unlocked
against this PEER's own `user://unlocks.json` (docs/ARCHITECTURE.md §2.2's new "Unlocks" row is
**None** — deliberately unreplicated, same shape as Salvage). Nothing calls it. The worked example,
`content/unlocks/unlock_deep_pocket.tres`, gates the real `deep_pocket` PowerupDef that
`content/loot/bog.tres` already rolls — the natural first real gate — but `LootTableDef.roll()` runs
once, host-side, for whichever peer opened the chest. Checking the gate there means picking one of:
gate the whole party's roll off the HOST's own unlock set regardless of who actually opened the
chest (wrong the instant a non-host peer is the one who bought the unlock), or ask the OPENING
peer's own save — for which no seam exists, since Salvage/Unlocks were built with no RPC of their
own on purpose. POI placement and enemy-roster expansion (`WaveSpawner.host_unlock_next_enemy()` —
an unrelated, in-run "unlock," not this system) have the same conflict one level worse: §2.2 already
requires those derived lists to be byte-identical across every peer, which a per-peer unlock set
cannot give them without either replicating purchases or making unlocks session-wide rather than
per-player.

**Why not fixed here:** task 6.9's own scope was the purchase/persistence/UI framework
(`docs/ROADMAP.md`'s "Unlock tree + UI"); resolving which of the two designs above is correct is a
call about Salvage's whole authority model, not something this task should decide as a side effect
of wiring one gate. D-111 records the full reasoning and what would change it.

**What closes this:** a task that picks one of D-111's two options — replicate purchases (a new
reliable RPC broadcasting `unlock_purchased`, the same shape `salvage_banked` would need if Salvage
itself ever needed cross-peer visibility), or make the unlock tree a HOST-only, session-wide setting
(no RPC needed, `is_content_unlocked()` only ever asked of the host's own service) — and then wires
`LootTableDef.roll()`'s POWERUP entries through it as the first real consumer. POI/enemy-roster
gating is a natural follow-up once that pattern exists.

---

**Resolved 2026-08-19 by lm.** Wired D-111's option (b) — the HOST's own UnlockService gates the whole party's roll, no RPC. No
new seam was needed: LootTableDef.roll() runs only inside Chest._accept_open_request(), which only
ever executes in the host process (locally, or behind net_request_open's own
_transport_is_host() guard), so the /root/UnlockService that codepath resolves is already,
structurally, the host's own instance -- never the opening peer's.

Fix, three files:
- systems/loot/loot_table_def.gd: roll() takes a new optional `is_unlocked: Callable` (default
  invalid Callable, so every pre-F-173 caller is unaffected). A POWERUP entry is zero-weighted for
  that draw when the callable returns false; ITEM entries are never gated.
- systems/loot/chest.gd: _accept_open_request() now passes _unlock_check() into roll() --
  Callable(unlock_service, "is_content_unlocked") if /root/UnlockService is present, else an
  invalid Callable (fail-open, same posture is_content_unlocked() itself takes when Registry is
  missing).
- autoload/unlock_service.gd: header + is_content_unlocked() doc updated to record the one rule
  this design depends on -- only ever call it from a codepath that runs in the asking process's
  OWN host, never trust a value carried in from another peer.
- content/unlocks/unlock_deep_pocket.tres: description no longer says "no pool checks this."

Also: docs/DELEGATION.md 'Current state' (the F-173 section) rewritten to describe the shipped
gate instead of the still-open question; docs/ARCHITECTURE.md §2.2's "Unlocks" row gets a
clarifying sentence about the host-only-caller rule; docs/SPECS.md gets a block (this finding had
none). New finding filed along the way: F-182 (tools/unlock_check.gd's corrupt-save test provokes
two undeclared engine ERROR lines -- pre-existing, unrelated to this fix, not fixed here).

Verified: `.agent/bin/agent godot --script tools/unlock_check.gd` -> UNLOCK_CHECK failures=0, run
twice. New coverage: a pure LootTableDef.roll() unit (gated POWERUP never drawn when locked, rolls
normally when unlocked, an ITEM entry is never gated, no-argument call is unaffected) plus a real
Chest-open integration test against the worked example's own gate (deep_pocket) -- locked grants
nothing, and the identical chest tier grants the powerup once unlock_deep_pocket is purchased
(same UnlockService instance, no RPC). No regressions: tools/chest_check.gd (CHEST_CHECK
failures=0) and tools/loot_content_check.gd (LOOT_CONTENT_CHECK failures=0), both re-run after
this change.

POI placement and WaveSpawner's in-run enemy-roster expansion are NOT wired -- D-111 already flags
those as "one level worse" (byte-identical-across-every-peer state a per-peer unlock set cannot
satisfy without either replicating purchases or making unlocks session-wide), and F-173's own "what
closes this" scoped the first consumer to the loot roll only. That remains open work for whoever
picks up POI/enemy-roster gating; no new finding filed for it since D-111 already describes exactly
what would need to change.

### F-179 · `CommandService.spec_names()`/`function_names()` are the fourth and fifth `Array[StringName].sort()` sites F-175 found — not fixed here, `autoload/command_service.gd` was held all session by another lane's claim — **fixed**

**Area:** core · **Severity:** low · **Found:** 2026-08-19 by lm while closing F-175

F-175 named two call sites (`ui/loot/chest_ui.gd`, `autoload/rule_service.gd`) as needing the same
`sort_custom` fix `CraftingService.recipes_for_station()` got under F-167, and asked whoever closed it
to grep the rest of the codebase for any other `Array[StringName]` site before assuming that list was
complete. It was not: `autoload/command_service.gd` has two more —
- `spec_names()` (`autoload/command_service.gd:141-144`) — `names: Array[StringName]`, plain
  `.sort()` at line 143.
- `function_names()` (`autoload/command_service.gd:466-469`) — same shape, `.sort()` at line 469.

Both are real: `spec_names()` backs the `help` console command's listing (see its own doc comment,
"a caller … that wants to list commands without going through execute()/submit()"), so the same
`StringName`-identity-not-content bug F-167 fixed for the crafting panel silently orders `help`'s
command list by registration order, not alphabetically, exactly like F-167 and F-175's other two sites.
`autoload/command_service.gd` was claimed by lane lp for F-157 for this session's entire duration
(confirmed via `.agent/state.json`), so it was out of reach here — same shape of contention as F-161/
F-165/F-169/F-178, just against this file instead of `core/net/net_version.gd`.

**What closes this:** whoever next holds `autoload/command_service.gd`, apply the identical
`names.sort_custom(func(a, b): return String(a) < String(b))` fix at both sites (pattern already
landed at three other call sites under F-175: `rule_service.gd`, `chest_ui.gd`,
`inventory_store.gd`, plus `crafting_service.gd` under F-167) and extend
`tools/stringname_sort_check.gd` with a `spec_names()`/`function_names()` case the same shape as its
existing `RuleService.rule_ids()` check.

---

**Resolved 2026-08-19 by lm.** Fixed both sites in autoload/command_service.gd — `spec_names()` (line ~143) and `function_names()`
(line ~469) — with `names.sort_custom(func(a, b): return String(a) < String(b))`, the identical
sort_custom fix F-175 landed at three other Array[StringName] sites (rule_service.gd, chest_ui.gd,
inventory_store.gd). Extended tools/stringname_sort_check.gd with `_check_command_service()`:
registers three throwaway specs/functions via the public register_spec()/register_function() APIs,
named out of alphabetical order on purpose, and asserts spec_names()/function_names() both come back
lexicographic. New SPECS.md block written per this file's own preamble (none existed for F-179).

Verified: `agent godot --script tools/stringname_sort_check.gd` -> STRINGNAME_SORT_CHECK failures=0,
14/14 PASS, run twice back to back. No regression: tools/command_check.gd (COMMAND_CHECK
failures=0), tools/command_catalog_check.gd (COMMAND_CATALOG_CHECK failures=0).

### F-168 · `Wellspring._finish_cap()` still emits `wellspring_capped` from a host-only guard, so a non-host peer's `SalvageService` milestone bonus silently undercounts — **fixed**

**Area:** systems/wellspring · netcode · **Severity:** low · **Found:** 2026-08-19 by lm during 6.6

`EventBus` is a per-process static (see its own header comment) — an emit call that only runs
inside a host-only `if` never reaches a client's own local bus at all, only the host's. Task 6.6
hit exactly this bug in `ExtractionShip.departed` (fixed: the emit now lives in the property's
setter, so it fires identically whether this process set the value itself or received it over the
wire) because `SalvageService`'s milestone bonus needs every peer to see `wellspring_capped`, not
just the host. `Wellspring._finish_cap()` (`systems/wellspring/wellspring.gd:218`) still has the
original shape: `EVENT_BUS.emit_wellspring_capped()` sits directly in the host-only branch, never in
`capped`'s setter. Consequence: on a non-host peer, capping a Wellspring correctly updates the
replicated `capped`/mesh state (that part IS a property, already synced), but that peer's own
`SalvageService` never sees the milestone and its Salvage payout is short by
`WELLSPRING_CAP_BONUS` per cap it didn't personally trigger as host.

**Why not fixed in 6.6:** `wellspring.gd` was untouched, working, fully-tested territory this task
had no other reason to enter — the fix is a two-line move (same shape as `extraction_ship.gd`'s),
but it is a second system's file for a T2/est-3 task whose own scope was already Salvage, not a
Wellspring regression pass. `tools/wellspring_check.gd`/`wellspring_recorruption_check.gd` both stay
green either way — they only assert against the host's own state, which is unaffected.

**What closes this:** move `EVENT_BUS.emit_wellspring_capped(name, global_position)` out of
`_finish_cap()`'s body and into `capped`'s setter, guarded on the false->true transition, the exact
diff `extraction_ship.gd`'s `departed` setter already shows. Re-run `wellspring_check.gd` and
`wellspring_recorruption_check.gd` (both should stay `failures=0`) plus `salvage_check.gd`.

---

**Resolved 2026-08-19 by lm.** Moved EVENT_BUS.emit_wellspring_capped() out of _finish_cap()'s host-only body into capped's setter
(false->true transition), mirroring the fix task 6.6 already applied to extraction_ship.gd's
departed setter. A non-host peer only ever learns capped went true via a replicated property delta
from MultiplayerSynchronizer, never by calling _finish_cap() itself — so the emit now fires on every
peer, not just the host that ran the ritual.

New regression coverage: tools/wellspring_check.gd's _check_capped_event_via_replication() sets
`capped = true` directly (bypassing the ritual/_finish_cap() entirely, the exact shape a client's
sync delta takes) and asserts the event fires exactly once and does not re-fire on a redundant set.
This would have failed before the fix (the emit lived only in _finish_cap()'s body).

Verified: agent godot --script tools/wellspring_check.gd -> WELLSPRING_CHECK failures=0 (incl. the
new F-168 section). agent godot --script tools/wellspring_recorruption_check.gd -> failures=0.
agent godot --script tools/salvage_check.gd -> SALVAGE_CHECK failures=0 (milestone-bonus behavior
unchanged).

Filed F-181: _finish_recorruption() has the identical host-only-guard bug for
wellspring_recorrupted, but nothing subscribes to that event yet (no live undercount), so left for
whoever gives it a first subscriber. SPECS.md F-168 block written (no spec existed).

### F-148 · construction_check.gd's door-swing solids AABB goes negative-size on thin per-triangle bounds, throwing an UNDECLARED engine error on every run — **fixed**

**Area:** tooling · **Severity:** medium (raised from low, see update) · **Found:** 2026-08-18 by lm

**Update 2026-08-18 (lm, hit again while verifying F-137):** this got much worse than "ten-plus
times per run" — `agent godot --script tools/construction_check.gd` today logged 213,000+ repeats of
the `AABB size is negative` error from `_check_doors()` and the process did not reach `_finish()`
inside a 5-minute budget at all (killed by the shell timeout mid-error-spam, output truncated to a
1.4 GB log). Root cause is unchanged (a `.grow(-0.004)` on a degenerate per-triangle box), but the
blow-up is likely proportional to how many door/gate/palisade-gate parts exist to swing-check, and
task 3.7 was mid-authoring more of them (uncommitted `door.tscn`/`gate.tscn`/`palisade_gate.tscn`
edits in the working tree at the time) — so this bug is no longer a cosmetic UNDECLARED-error line,
it can make the whole check unusable as a verification gate. Raised to medium for that reason. Worked
around it for F-137's own verification by temporarily commenting out the `_check_doors()` call for a
single local run (not committed) to confirm the new `_check_buildable_defs()` check in isolation;
`_check_doors()` itself was left untouched and still runs in the shipped file. Not fixed here — still
task 3.7's `.tres`/`.tscn`-adjacent territory per this finding's own original scope note.

`tools/construction_check.gd::_check_doors()` builds each frame collision solid from one triangle's
three vertices — `AABB(low, high - low)` — then calls `.grow(-0.004)` to shave 4 mm off every face so
a near-touch doesn't misreport. A triangle is planar, so its per-axis extent is routinely near zero
on at least one axis (any triangle lying flat against an axis-aligned face has exactly zero extent
there); shrinking that already-thin box by 4 mm on both sides drives that axis negative.
`AABB.has_point()` refuses a negative-size box outright — `ERROR: AABB size is negative, this is not
supported. Use AABB.abs() to get an AABB with a positive size.` — logged once per vertex-vs-solid
comparison that hits a degenerate solid, ten-plus times per `agent godot --script
tools/construction_check.gd` run today.

This is an UNDECLARED error under SPECS.md's standing rule #4 (grep every run for `ERROR:`, treat any
undeclared line as failure regardless of exit code), so `CONSTRUCTION_CHECK PASS` is not a trustworthy
verdict as written — the harness's own convention says this run should read as a failure. Found while
verifying F-135 (unrelated: F-135 is deck_field's mating-plane fix, confirmed working via the
CONSTRUCTION_WALKWAY/DOCK_CORNER/PALISADE_CORNER 0.0000 mm lines in the same run); this bug lives
entirely inside `_check_doors()`'s collision-solid construction and never touches deck geometry.

**Not the same bug as F-138.** F-138 was rotating each part's AABB *corners* instead of its vertices,
which inflated the box; today's code already does the vertex/per-triangle rewrite F-138 describes, so
that fix is in place. This is a new defect the rewrite's own `.grow(-0.004)` introduced: a per-triangle
box is degenerate in a way a per-part box mostly wasn't, and shrinking a degenerate box goes negative
instead of just staying thin.

**Likely fix:** call `.abs()` on the triangle AABB before `.grow(-0.004)`, or clamp the grow so no
axis can cross zero — either keeps the 4 mm tolerance intent without asking `has_point()` to evaluate
an invalid box. Whatever the fix, re-run `agent godot --script tools/construction_check.gd` and grep
for `ERROR:` to confirm zero UNDECLARED lines, not just that `CONSTRUCTION_DOORS swung=4` prints.

---

**Resolved 2026-08-19 by lm.** Fixed tools/construction_check.gd:_check_doors() — replaced the single AABB(low, high - low).grow(-0.004)
call with a new _shrunk_solid(low, high, margin) helper that clamps each axis's half-extent at 0.0
instead of letting grow() push it negative on a near-planar triangle. Rejected .abs() (the finding's
other suggested fix): pre-grow it's a no-op, post-grow it flips a degenerate box to extend past the
triangle's real bounds instead of collapsing to them.

Verified: `agent godot --script tools/construction_check.gd` run twice, `grep -c 'ERROR:'` -> 0 both
times (previously 213,000+ repeats / a 1.4 GB log per the finding's own update). CONSTRUCTION_DOORS
swung=4 prints both runs; the check now reaches CONSTRUCTION_CHECK FAIL failures=3 deterministically
instead of hanging mid-error-spam.

Those 3 failures are real (strap-vs-frame overlaps at 0 degrees) and were previously hidden by the
crash (AABB.has_point() errors and returns false on an invalid box rather than throwing, so degenerate
comparisons were silently skipped, not evaluated) -- not a regression from this fix. Out of scope
here: door.tscn/gate.tscn/palisade_gate.tscn (the source geometry) are task 3.7's uncommitted,
actively-claimed work this session. Filed as F-180 with full repro and a pointer for whoever next
holds those scenes.

SPECS.md F-148 block written (no spec existed before this task).

### F-147 · F-145's fix protects new sessions only — already-collided identities stay live for up to SESSION_KEEP_DAYS — **fixed**

**Area:** tooling · **Severity:** medium · **Found:** 2026-08-18 by nettle12

F-145 fixed the *generator*: a session assigned a name from now on gets a token-unique one. It
deliberately did not rename anyone, because `whoami()` resolves a registered token from
`sessions.json` before `_auto_name()` is reached, and claims are keyed by name — renaming a live
session would orphan its claims mid-task.

The consequence is a residual window. Every identity that already collided stays collided until
`_prune_sessions()` drops it at `SESSION_KEEP_DAYS` = 14 days. At the time of writing that is eleven
names covering 25 sessions (`ivy8` x5, `nettle12` x4, `reed16` x4, `pike14` x3, `yarrow21` x3, and
`moss11`, `tine18`, `wick20`, `flint5`, `dusk3`, `kiln9` x2 each).

**Live example, recorded so the risk is concrete rather than theoretical.** While F-145 was being
fixed, two different chat sessions were both named `nettle12` and both running in this one working
tree. The other one held five claims for F-144:

    autoload/graphics_quality.gd      nettle12  F-144
    tools/_probe_lods.gd              nettle12  F-144
    tools/render_census.gd            nettle12  F-144
    world/environment/draw_policy.gd  nettle12  F-144
    world/gen/authored_world.gd       nettle12  F-144
    world/gen/undergrowth.gd          nettle12  F-144

To the session fixing F-145 those are indistinguishable from its own claims. `agent claim` on any of
them would have been granted, and the pre-commit `agent check` would have let it commit them, because
both compare a bare `c["agent"] != me`.

**The durable fix is to compare the session token, not the name** — store the token beside `agent` in
each claim and prefer it when both sides have one, falling back to the name for lane agents and for
claims written before the schema change.

**Deliberately not done in F-145,** and this is the part worth keeping: `.agent/bin/agent` is the hot
path for every session and lane, and at that moment four agents were mid-task through it (LM on F-136,
plus F-140, F-144, and the F-145 session itself). A claims-schema change is not additive the way the
one-line `_auto_name` return was, and shipping it under those conditions risked breaking running work
to close a window that is already shrinking on its own. Do it when the tree is quiet.

Until then: if two agents may share a name, do not trust a claim's `agent` field alone — check
`agent report`'s In-flight list for which *task* holds the file, since task ids do not collide.

---

**Resolved 2026-08-19 by lm.** Checked the premise first per the brief's warning: still reproduced. F-145 only fixed the
generator (_auto_name); every comparison that decides claim ownership (`agent claim`, `agent
brief`, the pre-commit `agent check`, `_blame_foreign_break`) still compared bare `agent` names,
so two sessions that already share a name (F-147's own live example: two chats both auto-named
`nettle12`) remain indistinguishable to those checks for up to SESSION_KEEP_DAYS.

Fix, in .agent/bin/agent: new `whoami_token()` (the session's token, None for a lane/MIRE_AGENT
identity) and `_is_mine(record, me, me_token)` (prefers comparing the stored session token when
both sides have one, falls back to the name otherwise). `cmd_claim` now stores `"token":
whoami_token()` in every in_flight/claims record; `_release()` carries it into the `recent`
snapshot. Every ownership comparison across cmd_claim/cmd_brief/cmd_check(+in_grace)/
_blame_foreign_break now goes through `_is_mine()` instead of comparing `["agent"]` directly.
`agent order`'s pre-dispatch conflict check (line ~2140) is deliberately untouched — it checks a
claim against a target LANE's fixed name before that lane's own session exists, not against the
caller's identity, and lane names don't collide.

Does not shrink the residual SESSION_KEEP_DAYS window itself (F-145's documented, deliberate
tradeoff — renaming a live session would orphan its claims) — it changes the consequence of a
collision from "silently grants the wrong session a claim" to "correctly refused."

Verified: two new tools/harness_check.py cases reproduce the finding's exact live example inside
its existing sandboxed-repo harness (two session tokens rigged via sessions.json to resolve to the
same auto-name, `nettle12`) — one proves `agent check` now refuses a same-name/different-token
commit over another session's claim, the other is the no-regression control proving the same
session's own claim still commits clean. Confirmed the first case is a real regression test by
running it against the pre-fix harness (`python3 tools/harness_check.py --rev HEAD` -> 21/22,
that case FAILs) versus the fixed working tree (`python3 tools/harness_check.py` -> 22/22, all
pass). Also unit-verified `_is_mine()` and the claim-write path directly against a scratch state
directory (never touching the live shared board): a same-name/different-token claim is blocked, a
legacy claim with no `token` field still falls back to name comparison, and a lane's claim stores
no token and is still recognized as its own. `python3 -m py_compile .agent/bin/agent` clean.

### F-175 · `Array[StringName].sort()` does not sort lexicographically — at least two other call sites besides F-167's rely on it anyway — **fixed**

**Area:** core · **Severity:** low · **Found:** 2026-08-19 by lm during F-167

`StringName`'s comparison operator compares interned identity, not string content, so
`Array[StringName].sort()` silently does **not** produce alphabetical order — confirmed with a
throwaway probe script (`tools/_probe_sn_sort.gd`, deleted after use, not committed): sorting
`["iron_sword","stone_pickaxe","arrow","cleaver","wooden_axe"]` as `Array[String]` gives
`[arrow, cleaver, iron_sword, stone_pickaxe, wooden_axe]` as expected; the identical values as
`Array[StringName]` give `[iron_sword, stone_pickaxe, wooden_axe, cleaver, arrow]`. F-167 hit this in
`CraftingService.recipes_for_station()`, fixed there with `ids.sort_custom(func(a, b): return
String(a) < String(b))`.

Two more call sites build an `Array[StringName]` and call plain `.sort()` expecting alphabetical
order, neither touched here because neither file was in F-167's claim set:
- `ui/loot/chest_ui.gd:347` (`var ids: Array[StringName]` at line 344)
- `autoload/rule_service.gd:118-120` (`ids.sort()` on a `Array[StringName] = []`, plus a second read
  of the now-stale-order result at `rule_service.gd:279`)

Neither had an obvious player-visible symptom yet (chest UI isn't wired to anything — F-151 — and
rule_service's list order may not be presentation-facing), which is likely why F-167's exact failure
shape (a hardcoded index silently pointing at the wrong entry once a list grows past one item) hadn't
been noticed there yet.

---

**Resolved 2026-08-19 by lm.** Fixed both named sites plus a third the finding's own "grep for more"
instruction turned up: `systems/inventory/inventory_store.gd`'s `_sorted_ids()` (feeds
`apply_transaction()`'s removal/addition order) had the identical shape. All three now use
`sort_custom(func(a, b): return String(a) < String(b))`, the same fix F-167 landed in
`crafting_service.gd`. A full-codebase grep for `Array[StringName]` declarations paired with a
plain `.sort()` call also found `autoload/command_service.gd`'s `spec_names()`/`function_names()` —
same bug, not fixed here because that file was held by lane lp's F-157 claim for this session's
entire duration; filed as F-179 rather than left silently undiscovered. No other `Array[StringName]`
site in the codebase pairs with a plain `.sort()` call as of this session.

New check `tools/stringname_sort_check.gd` proves all three fixes together: `RuleService.rule_ids()`
returns its 8 rules in lexicographic order, `InventoryStore._sorted_ids()` sorts a 3-key dict
correctly, and `ChestUI._populate_rewards()` renders its reward rows in the same order. Verified via
`agent godot --script tools/stringname_sort_check.gd` → `STRINGNAME_SORT_CHECK failures=0`, all 8
assertions PASS, run twice to rule out flakiness.

---

### F-157 · No system tracks a player's display name anywhere in the project — F-126's `peer` name resolution has nothing to resolve against, and 3.16 shipped without adding one — **fixed**

**Area:** netcode · **Severity:** low · **Found:** 2026-08-18 by lp while closing F-126

F-126 named task 3.16 (the command catalog sweep) as the most natural owner of a per-player
display-name registry; 3.16 has since shipped (`docs/ROADMAP.md` marks it done) without adding one,
so that pointer is now stale. Confirmed still true project-wide: no file anywhere defines a peer id
→ display name map. `NetTransport` (`autoload/net_transport.gd`) tracks only a `PackedInt32Array` of
bare peer ids (`_peers`/`peer_joined`/`peer_left`); `NetDebugPanel`/`net_debug_panel.gd` prints raw
`peer %d`; `SteamLobby` (`autoload/steam_lobby.gd`) resolves a Steam persona name per lobby *member*
(`_persona()`), but that is lobby membership before a session starts, keyed by Steam id, not by the
in-session ENet/net peer id every other system uses, and it does not exist at all in LOCAL/LAN mode.

**What would close this:** whoever adds the registry should own a single canonical peer id → display
name map, not one invented per-caller. `NetTransport` is the natural home — it already owns peer
bookkeeping (`_peers`, `_track_peer`/`_add_peer`, `peer_joined`/`peer_left`) and the correct
lobby-agnostic keying (net peer id, works in every `NetConfig.Mode`). Needs: a name source per mode
(LOCAL/LAN has none today — a client would need to submit one, e.g. `OS.get_environment("USERNAME")`
as a placeholder default, over a new reliable client→host RPC; STEAM already has one in
`SteamLobby._persona()` and just needs threading through), sanitization/length cap on the host side
(never trust the client's string raw), and a signal so `NetDebugPanel`, a future lobby roster label,
and a future kill-feed can all read the same map instead of separately reinventing "what does peer N
call itself". Once it exists, `CommandService._parse_peer()` (`autoload/command_service.gd`) should
resolve a non-numeric token against it before failing, per `docs/COMMANDS.md` §2.2's `peer` type spec
— see the doc comment on `_parse_peer()` itself, which already names this file as the successor.

Not filed as blocking anything: `op <peer_id>` and every other `peer`-typed command work fine today
with the raw id, same as F-126 already established. This is scheduling information, not a defect.

---

**Resolved 2026-08-19 by lp.** Fixed. NetTransport now owns the peer id -> display name registry (D-098's named owner):
display_name()/display_names()/submit_display_name() public API, HOST-authoritative
(new ARCHITECTURE.md §2.2 row), sanitized only on the host (_sanitize_display_name: strip
control chars, trim, cap 24, empty -> "Player N"). New wire shape (no existing seam fit):
net_request_display_name (client -> host), net_display_name_changed (host -> every remote),
net_display_name_snapshot (host -> a newly admitted peer, sent at admission time). Default
name auto-submitted on connect: STEAM threads through new SteamLobby.local_persona_name();
LOCAL/LAN falls back to OS username. No name-entry UI exists yet -- out of scope, a future
one just calls submit_display_name() again.

CommandService._parse_peer() now consumes the registry: a non-numeric token resolves
case-insensitively against NetTransport.display_names(); duplicate names are allowed
(not deduped) and an ambiguous match refuses listing every candidate peer id rather than
guessing (D-120). tools/command_check.gd's peer-arg-type section (F-126's own coverage)
updated for the new refusal wording. ui/debug/net_debug_panel.gd's session line and
join/left log now show id(name) instead of a bare id -- one of the two consumers F-157's
own text named.

Ships without a PROTOCOL_VERSION bump -- core/net/net_version.gd/tools/handshake_check.gd
were held by slate17's 3.7 claim for this task's whole session, the same recurring gap
D-102/F-161/F-165/F-169 already hit. Filed as F-178, continuing that chain.

Verified: agent godot --script tools/display_name_check.gd (new file, real two-process
ENet round trip) -> DISPLAY_NAME_CHECK failures=0, 11/11 PASS (submission round trip,
sanitization of a padded/control-char/overlong name, snapshot delivery to a peer that
joined after the name was already set, case-insensitive op <name> resolving to the right
peer id, ambiguous-name refusal naming both candidate ids). agent godot --script
tools/command_check.gd -> COMMAND_CHECK failures=0 (24 assertions). Regression: agent
godot --script tools/command_net_check.gd -> COMMAND_NET_CHECK failures=0; agent godot
--script tools/net_debug_panel_check.gd -> 0 failure(s); agent godot --script
tools/verify_setup.gd -> all checks passed. Zero unexpected ERROR: lines across all four
runs (only the pre-existing gfx deprecation warning, F-130, unrelated). Full writeup:
docs/SPECS.md F-157, docs/DECISIONS.md D-120, docs/DELEGATION.md Current state,
docs/ARCHITECTURE.md §2.2.

### F-172 · Seed entry (task 6.10) only reaches the host-session path — solo/offline play draws its seed before any menu can be opened — **fixed**

**Area:** UI/worldgen · **Severity:** low · **Found:** 2026-08-19 by lm during 6.10

`ui/menu/main_menu.gd`'s seed field stages a value via `GameState.set_pending_seed()`, consumed by
`GameState.host_generate_seed()` the next time `NetTransport.server_started` fires — i.e. the moment
`LobbyMenu`'s HOST button succeeds. Solo/offline play never reaches that path: `run/main_scene` boots
straight into `levels/hollowmere.tscn`, and `world/mire/mire_grid.gd`'s own `_ready()` calls
`GameState.ensure_seed()` immediately, which draws (or would consume a pending value for) the seed
before the player has had a single frame in which to open `MainMenu` and type one. In practice a solo
player can stage a seed and watch the status line update, but it will sit unused — nothing hosts,
so `host_generate_seed()` never fires, and `ensure_seed()` already ran before the field existed to be
read from.

**Why not fixed here:** closing this properly means gating world-gen's first `ensure_seed()` call
behind an explicit "start" decision — i.e. an actual boot-time main menu that the game does not enter
gameplay past until dismissed. That is a materially bigger, riskier change (touches `run/main_scene`
or `world/mire/mire_grid.gd`'s boot ordering) than the CanvasLayer-overlay shell 6.10 shipped, and
was explicitly rejected for this task on blast-radius grounds — see `docs/DECISIONS.md`'s 6.10 entry.

**What closes this:** whichever future task actually gates the boot flow behind a start screen (not
scheduled anywhere on `docs/ROADMAP.md` today) should route solo seed entry through that gate; until
then, `ensure_seed()` staying eager is the safer default, and solo players wanting a specific seed
have no way to set one.

**Resolved 2026-08-19 by lm.** Fixed with a launch argument, not the boot-gate D-110 explicitly reserved for its own future task:
`--seed=<value>` now reaches `GameState._apply_launch_seed_arg()` (first line of `_ready()`, before
`MireGrid` in [autoload] order) and stages it via the existing `set_pending_seed()` — the exact
mechanism 6.10 already built, just reachable one process-launch earlier than a menu can open. Parsing
mirrors `ui/menu/main_menu.gd`'s `request_set_seed()`: a pure integer is used as-is, other text hashes
with `String.hash()`, 0 bumps to 1. Not debug-only (unlike `dev_launch.gd`) — `steam_lobby.gd`'s
STEAM_CONNECT_LOBBY_ARG already establishes a retail-build cmdline arg reaching an autoload as a
normal shape here, and this is a real player-facing feature (Steam "Launch Options" reaches it).

Verified: `agent godot --script tools/seed_launch_arg_check.gd -- --seed=204060517`, twice back to
back, SEED_LAUNCH_ARG_CHECK failures=0, all 8 assertions PASS — including that MireGrid's own real
boot-time draw (not a value the check script drew itself) used the launch-arg seed. No regression:
tools/main_menu_check.gd (28/28) and tools/seed_sync_check.gd (12/12) both stayed clean.

Full spec/rationale: docs/SPECS.md's F-172 block.

### F-171 · `tools/crafting_ui_check.gd` fails 19/22 independent of task 6.10 — reproduced on a clean HEAD checkout — **fixed**

**Area:** crafting/UI · **Severity:** medium · **Found:** 2026-08-19 by lm during 6.10 (regression sweep)

Ran as part of 6.10's regression sweep (nothing in 6.10 touches crafting). `CRAFTING_UI_CHECK
confirmations=3 failures=19` against the working tree; `agent baseline --script
tools/crafting_ui_check.gd` reproduces the identical `failures=19` against a clean checkout of
`5a09b1c`, so this predates 6.10 and is not something this task caused. First failing assertion is
"furnace craft grants one iron ingot" (`tools/crafting_ui_check.gd:161`), which points at either the
crafting UI's confirm path or `CraftingService`/`furnace` content itself rather than at the check's
own scaffolding — worth a look before trusting crafting UI checks green elsewhere.

**What closes this:** whoever next touches `ui/crafting/crafting_ui.gd` or `systems/crafting/*`
should run `tools/crafting_ui_check.gd` first (not just after their change) to see which of the 19
are pre-existing versus newly caused, then chase the furnace-craft failure specifically as the
likely root rather than treating all 19 as independent.

---

**Resolved 2026-08-19 by lm.** Fixed tools/crafting_ui_check.gd: replaced hardcoded row index 0 (valid only while the workbench had
one recipe, task 2.6) with a _row_for(ui, recipe_id) helper that scans displayed_recipe_id(i) — the
identical fix F-167 already applied to crafting_net_check.gd, just not to this sibling check.
recipe_row_count() == 1 assertions became > 0 ("renders its registered recipes"), each station gained a
check(row >= 0, ...) that the expected recipe is present, and every downstream row-0 use became the
resolved axe_row/ingot_row. Root cause was stale-check, not content or crafting-UI: content authoring
(tasks 3.2-3.4) legitimately grew the workbench to 11 recipes and the furnace to 2, and
recipes_for_station()'s alphabetical order puts stone_axe/iron_ingot past row 0. Full root cause and
fix detail in docs/SPECS.md's new F-171 block.

Verified: agent godot --script tools/crafting_ui_check.gd -> CRAFTING_UI_CHECK confirmations=3
failures=0, all 34 assertions PASS. Ran twice to rule out timing flakiness in the timed-craft phase;
both green.

### F-164 · A capped Wellspring's re-corruption clock (task 6.4) has no HUD or ambient warning before it finishes — only the in-world mesh swap tells a player — **fixed**

**Area:** UI/UX · **Severity:** low · **Found:** 2026-08-18 by lm during 6.4

`ui/hud/wellspring_hud.gd` only ever shows a prompt for an uncapped Wellspring (`_refresh_nearby()`
skips any node where `capped == true`), so a player who is not standing right next to a decaying
Wellspring gets no signal at all that it is losing its cap — no toast, no map marker, no ambient cue —
until either they happen to walk past and see the `wellspring_recorrupting.glb` state, or it finishes
outright and the "Hold [key] to begin capping" prompt reappears. This is a real, deliberate scope cut
(`docs/SPECS.md` §6.4: "the in-world mesh swap is the only signal today") — task 6.4 is the backend
clock, and ARCHITECTURE.md §2.2's "VFX, audio, camera, UI" row makes this presentation, a different
system's job — but it is a genuine gap: DESIGN.md's whole framing is that the Mire's state should be
"visible on the horizon," and a capped Wellspring quietly expiring off-screen cuts against that.

**What closes this:** a future UI/polish task adds a warning once `recorruption_sec` crosses
`RECORRUPTING_VISUAL_FRACTION` (or some other threshold) on any Wellspring the local player has ever
capped — `EventBus.subscribe_wellspring_recorrupted()` already exists for the "it's gone" case;
crossing the visual threshold has no event of its own yet and would need one, or a poll against the
replicated `recorruption_sec` field the way `wellspring_hud.gd` already polls `progress_sec`.

**Resolved 2026-08-19 by lp.** Fixed both the reported gap and a bigger one it uncovered: `WellspringHud` had never been added to
`[autoload]` (registered now via `agent autoload WellspringHud res://ui/hud/wellspring_hud.gd`) — the
whole HUD, capping prompt included, was unreachable in the live game since task 4.8, not just this
finding's warning. `ui/hud/wellspring_hud.gd` gained a second, top-centre ambient panel
(`_refresh_recorruption_warning()`, polled alongside the existing prompt) that shows once ANY capped
Wellspring's `recorruption_sec` crosses `Wellspring.RECORRUPTION_DURATION_SEC *
RECORRUPTING_VISUAL_FRACTION` — the same fraction the in-world mesh already swaps at — with an m:ss
countdown, independent of proximity or who capped it (DESIGN.md's "visible on the horizon"; full
reasoning and the "why not gate on the local player's own cap history" call in SPECS.md's new F-164
block). New `tools/wellspring_hud_check.gd`: `agent godot --script tools/wellspring_hud_check.gd` ->
`WELLSPRING_HUD_CHECK failures=0`, 11/11 PASS, run twice. No regressions: `wellspring_check.gd` and
`wellspring_recorruption_check.gd` both `failures=0`. `agent godot --quit-after 20` boots with zero
`ERROR:` lines.

### F-163 · `expr as Array[T]` silently fails to convert an untyped Array's element type — a `.set()` onto a typed-array `@export` then no-ops with no error — **fixed**

**Area:** GDScript/tooling · **Severity:** medium · **Found:** 2026-08-18 by lm during 6.2

Building synthetic `CycleModifierDef` instances for `tools/cycle_modifier_check.gd`, assigning an
untyped `Array` parameter into a `tags: Array[StringName]` `@export` var via
`def.set(&"tags", tags as Array[StringName])` produced an empty array every time — no error, no
warning, no exception, just silently discarded. `as Array[StringName]` does not perform an
element-wise runtime conversion of an already-untyped `Array`; it appears to leave the array's
element type unchanged, and `Object.set()` on a strictly-typed `Array[T]` `@export` property then
rejects the mismatched Variant without complaint. This is the same class of trap `ARCHITECTURE.md`
§6b already catalogues for the Recast bridge — wrong result, no diagnostic — just in core GDScript
typed-array handling rather than an engine subsystem.

The fix is the constructor call form: `Array[StringName](expr)`, not `expr as Array[StringName]`.
`content/powerups/*.tres` already uses this exact syntax for typed array/dictionary literals
(`tags = Array[StringName]([&"Blood", &"Kinetic"])`), which turns out to be load-bearing at runtime
too, not just inside `.tres` resource text — any GDScript that builds a typed array from an untyped
one (a test harness constructing synthetic content defs, a loader normalizing a dynamically-sourced
list) needs the constructor form. A plain array literal assigned directly to a typed-array-declared
local (`var x: Array[StringName] = [...]`) converts correctly at declaration time; the failure is
specific to converting an *already-untyped* `Array` value via `as`.

**What closes this:** promoting this note into `docs/SPECS.md`'s "four standing rules" list (same
tier as F-016's class_name rule) the next time that file is touched for an unrelated task, so it is
read before the mistake rather than after. No code fix needed — `tools/cycle_modifier_check.gd`
already uses the constructor form throughout.

**Resolved 2026-08-19 by lm.** No code fix needed — tools/cycle_modifier_check.gd (the file the finding was filed against) already
used the constructor form throughout, confirmed by re-running it: `agent godot --script
tools/cycle_modifier_check.gd` -> CYCLE_MODIFIER_CHECK failures=0, no engine ERROR:/SCRIPT ERROR lines.

Closed by promoting the rule into docs/SPECS.md's standing-rules list (now five) as the finding's own
"what closes this" specified, one tier with F-016's class_name rule, and added a matching ## F-163
spec block there with Claim/Root cause/Fix/Verify.

Correction made along the way: the finding's own suggested fix, `Array[StringName](expr)` bracket-
generic constructor-call syntax, is valid inside a .tres text resource's literal parser but is a
PARSE ERROR ("Cannot call on an expression") when written as an executable statement in real .gd
script code -- confirmed directly with a new throwaway probe, tools/_probe_typed_array_convert.gd.
The forms that actually compile and work in script code are the 4-arg builtin constructor
`Array(expr, TYPE_STRING_NAME, &"", null)` (what cycle_modifier_check.gd actually uses) or declare-
then-assign() (`var typed: Array[T] = []; typed.assign(expr)`). Both round-trip correctly through
.set()/.get() on a real typed-array @export; `as Array[T]` does not, stores []. The standing rule in
docs/SPECS.md and the ## F-163 spec block both carry the corrected guidance, not the finding's
original (subtly wrong) fix text.

Verified: `agent godot --script tools/cycle_modifier_check.gd` -> failures=0, clean.
`agent godot --script tools/_probe_typed_array_convert.gd` -> reproduces the as-Array[T] silent-empty
trap and confirms both working alternatives store the full array.

### F-162 · `tools/viewmodel_check.gd` fails independently of task 5.3 — three food items have no authored viewmodel — **fixed**

**Area:** content · **Severity:** low · **Found:** 2026-08-18 by lp during 5.3

`tools/viewmodel_check.gd`'s `PASS/FAIL: every tool and weapon has a viewmodel (mushroom, berry,
raw_meat)` assertion fails at HEAD, before any of this task's changes — confirmed with
`agent baseline --script tools/viewmodel_check.gd`, which fails identically on a clean checkout of
the commit this task started from. Three consumable `ItemDef`s (`mushroom`, `berry`, `raw_meat`)
have no `view_model` set, so equipping one shows an empty hand instead of the item. Not chased here:
it is pure content authoring (an export on three `.tres` files, no code), outside this task's claim,
and every other `viewmodel_check.gd` assertion — including the new ones a bow/arrow viewmodel would
exercise if 5.3 had added its own arc — passes. Whoever authors those three items' viewmodels next
closes this; `agent godot --script tools/viewmodel_check.gd` going `failures=0` is the proof.

**Resolved 2026-08-19 by lp.** **fixed** — content/items/{mushroom,berry,raw_meat}.tres now set view_model (reusing the shipped
world_model PackedScene per D-117, not a new asset batch), with per-item grip_offset/
grip_rotation_degrees/grip_scale computed from a measured AABB (tools/_probe_food_grip.gd) rather than
guessed, and attack_style = NONE (same as short_bow/arrow — "carried, never swung").

Verified: `agent godot --script tools/viewmodel_check.gd` -> `VIEWMODEL_CHECK failures=0`, all 21
assertions PASS (including "every tool and weapon has a viewmodel ()" and "every item with a viewmodel
was measured (14)" — 11 tools/weapons + these 3). Ran twice, both clean. Windowed screenshots via
`agent godot --windowed --script tools/_probe_food_grip.gd` (saved /tmp/mire_food_*.png, read back)
confirm all three render on-screen, correctly sized, non-clipping. Full spec: docs/SPECS.md "F-162".
Decision record: docs/DECISIONS.md D-117.

### F-159 · Placed buildables are invisible to the nav map — agents path straight through walls — **fixed**

**Area:** world · **Severity:** medium · **Found:** 2026-08-19 by hollow7

`world/chunk/nav_baker.gd` (task 4.5) bakes navigation from `ChunkMesher.collision_faces()` — the
terrain triangles, and only those. Every other collider in the world is absent from the source
geometry, so the navigation mesh describes bare terrain.

The consequence is concrete: a wall placed through `BuildService` (task 3.6/3.7) is a real physics
collider that an agent's *path* passes straight through. `NavigationAgent3D` steering will drive an
enemy into it and it will grind against the collider rather than route around. The same applies to
Ward structures, crafting stations, and anything else 3.7 places — the whole point of a Ward is that
enemies must deal with it, and right now the pathfinder does not know it exists.

Terrain-only was the right scope for 4.5 (D-101 records it): the streaming/bake budget D-016 measured
is a terrain measurement, and folding in dynamic geometry changes both the cost and the invalidation
rules. But it is a gap, not a design position.

**What a fix probably looks like.** `NavigationMeshSourceGeometryData3D` accepts more than one
`add_faces` call, so a placed piece's collision faces can be appended to its chunk's source geometry
before the bake. The hard half is invalidation: placing or destroying a piece must re-bake the chunk
it sits in, which means BuildService needs to tell NavBaker (a signal it already emits —
`piece_placed`/`piece_destroyed`), and the one-bake-in-flight queue has to absorb build spam without
falling behind. Obstacle avoidance (`NavigationObstacle3D`) is the cheaper alternative for small or
temporary pieces and may be the better answer for anything a player throws down mid-fight.

Verify a fix with `tools/nav_bake_check.gd`'s existing shape: place a piece across the seam path it
already tests, and assert the route detours rather than passing through.

---

**Resolved 2026-08-19 by lm.** Fixed in world/chunk/nav_baker.gd's own bake, per the scoping decision recorded in docs/SPECS.md's
F-159 block: bind() now also connects to BuildService's piece_placed/piece_destroyed signals, tracks
every placed piece's {coord, position, yaw, size}, and _source_geometry(coord) folds each tracked
piece (as a closed 12-triangle box, via new static _box_faces()) into the SAME
NavigationMeshSourceGeometryData3D as that chunk's terrain faces before baking -- one combined pass,
so Recast genuinely carves a hole around the piece rather than compositing two regions that never saw
each other's geometry. A new _rebake_chunk() re-queues an already-attached chunk when a piece changes
it (the opposite case from request_bake()'s existing redundant-signal dedupe guard), and _attach() now
frees a stale region before replacing it so a rebake cannot leak the old RID. autoload/build_service.gd's
piece_destroyed signal widened to carry the piece's name and last position, since its node is already
freed by the time the signal fires and NavBaker needs both to find the right chunk. NavBaker (task 4.5)
is not yet wired into the live game (F-139), so this fix does not yet reach an actual playing session --
EnemyWorld.bake_navigation(), the baker the shipped game runs today, still has this exact gap, tracked
separately as F-177 since fixing it needed a file (autoload/enemy_world.gd) held by another lane for
this whole session.

Verified: agent godot --script tools/nav_bake_check.gd -> NAV_BAKE_CHECK failures=0, including new
_check_buildable_obstruction() -- places a real ward piece dead-centre on a proven-walkable point and
asserts NavigationServer3D.map_get_closest_point() for that exact point moves measurably farther away,
then destroys it and asserts the query returns close to its own pre-piece baseline. Ran twice, both
clean. No regressions: build_check.gd, build_net_check.gd (real two-process ENet), combat_check.gd
(exercises host_piece_destroyed_by_damage's new signal arity) all failures=0. agent godot --quit-after 20:
no new ERROR:/SCRIPT ERROR: lines.

### F-177 · `EnemyWorld.bake_navigation()` — the LIVE nav baker — still ignored placed buildables; only `NavBaker` (task 4.5, unreachable per F-139) got F-159's fix — **fixed**

**Area:** world / netcode · **Severity:** low · **Found:** 2026-08-19 by lm during F-159

F-159 asked for placed buildables (walls, Wards, anything `BuildService` spawns) to stop being
invisible to navigation. The fix landed entirely in `world/chunk/nav_baker.gd` — `NavBaker`, task
4.5's per-chunk baker — because `NavBaker` is not what the shipped game actually paths against:
nothing instantiates a `ChunkStreamer` in the live level yet (F-139). The baker the live game DOES
run — `EnemyWorld.bake_navigation()`, called at session bootstrap and re-triggered by
`BuildService._request_nav_rebake()` on every placement/destroy — still walked only `get_tree().
current_scene`, and `BuildService`'s placed-piece container is a child of the `BuildService` autoload,
not of the scene, so a wall placed in a live LOCAL/LAN/Steam session was still a collider
`NavigationAgent3D` steering drove straight through.

**Resolved 2026-08-19 by lp.** `autoload/enemy_world.gd`'s `bake_navigation()` still walks
`scene_root` exactly as before, then separately walks `/root/BuildService/Buildings` (the placed-piece
container, a SIBLING of the level under `/root` — D-023's usual reason: an autoload keeps its own
spawned content as its own child so it survives a scene reload) into a second
`NavigationMeshSourceGeometryData3D` and `.merge()`s that into the first before the ONE
`bake_from_source_geometry_data()` call — same "has to be one combined pass" requirement D-118 already
recorded (Recast carves a hole around solid geometry by seeing it alongside whatever it is carving, so
two independently-baked regions cannot produce that result). This lands directly in the live baker
rather than porting `NavBaker`'s per-piece box-tracking approach (D-121): `bake_navigation()` already
does one full-scene reparse+rebake on every call (no per-chunk incremental state to keep in step), so
the two-root-parse-and-merge shape is the smaller, more directly equivalent change, and it uses each
piece's REAL collider geometry (whatever `BuildService._generated_piece()` or an authored `.tscn`
actually placed) rather than a synthetic box reconstructed from `BuildableDef.size` alone.

Verified: `agent godot --script tools/nav_bake_check.gd` -> `NAV_BAKE_CHECK failures=0`, run twice, new
`_check_enemy_world_buildable_obstruction()` — a real `BuildService.request_place()` (funded inventory,
real host-decides round trip, not a synthetic body) puts a `ward` piece across a two-point route
`EnemyWorld.bake_navigation()` had just baked, and asserts `NavigationServer3D.map_get_path()` between
the same two points goes from the straight line (6.000m, 3 waypoints) to a real detour (7.525m, 5
waypoints) after the piece lands, then back to the straight line after `request_destroy()`. Deliberately
NOT a point-snap `map_get_closest_point()` assertion at the piece's own centre (F-159's own check uses
that shape, and still does): a piece resting exactly flush on a perfectly flat floor — the simplest,
most controllable test fixture — hits a Recast/Godot rasterization quirk where the piece's
coincident-height bottom face and the floor's own top can leave a tiny walkable "island" polygon
surviving at the exact centre, snappable despite sharing no edge with anything else on the map (and
therefore never actually walkable in practice — `map_get_path()` only ever routes across connected
edges). Confirmed this is a property of the geometry, not of the two-root-merge approach specifically:
the same island appears baking a single combined parse over one shared root too. Real, uneven heightmap
terrain does not reliably avoid it either at THIS seed (a 2.4 m `ward` footprint routinely fails the
placement validator's own support probes there before slope even enters it — the terrain is hillier
than a footprint that size tolerates), which is why this check's fixture is a flat synthetic floor
(same shape build_check.gd's own `_build_world()` already uses) rather than real terrain. No
regressions: `build_check.gd`, `build_net_check.gd` (real two-process ENet), `combat_check.gd`,
`enemy_check.gd` all `failures=0`.

### F-167 · `tools/crafting_net_check.gd` fails (24/24) against a clean checkout of HEAD, independent of any in-flight change — **fixed**

**Area:** netcode · **Severity:** medium · **Found:** 2026-08-19 by lm during 6.5

Run standalone (`agent godot --script tools/crafting_net_check.gd`) it fails every assertion from
"client completes accepted and rejected craft requests" onward — `axe_count=-1`, `granted=true`,
`complete=false`. `agent baseline --script tools/crafting_net_check.gd` reproduces the identical
24 failures against a throwaway checkout of `b6f7329` (the committed HEAD at the time), so this is
not a symptom of any lane's uncommitted work, including this task's — it is a standing regression in
the two-process crafting network path itself. `docs/FINDINGS.md`'s own history (search
"crafting_net_check") shows it passing 0 failures after an earlier fix, so something between then and
`b6f7329` broke it again without a check catching the reintroduction.

Not investigated further here — out of 6.5's scope, and the two-process ENet harness this check uses
is expensive to bisect blind. Whoever picks this up should start by finding the last commit where
`agent baseline --script tools/crafting_net_check.gd` was green, since the file itself hasn't
changed recently (`git log --oneline -- tools/crafting_net_check.gd`).

---

**Resolved 2026-08-19 by lm.** Fixed two layers. (1) autoload/crafting_service.gd's recipes_for_station() sorted an
Array[StringName] with plain .sort(), which does NOT sort lexicographically -- StringName's
comparison compares interned identity, not string content (confirmed with a throwaway probe
script). Fixed with ids.sort_custom(func(a,b): return String(a) < String(b)) -- a real UX fix,
the workbench panel was never actually alphabetical. (2) tools/crafting_net_check.gd hardcoded
row index 0 as "the recipe the client crafts", true only while the workbench had one recipe
(task 2.6); tasks 3.2-3.4 grew it to 11, so index 0 stopped being stone_axe. Fixed by scanning
displayed_recipe_id(i) for &"stone_axe" and using that row index throughout, degrading
gracefully (existing assertions already fail loudly) if the recipe is ever missing.

Filed F-175 for two more Array[StringName].sort() sites (ui/loot/chest_ui.gd,
autoload/rule_service.gd) that likely have the same latent bug -- out of this task's claim set,
not fixed here.

Verified: agent godot --script tools/crafting_net_check.gd ->
CRAFTING_NET_CHECK axe_count=1 failures=0, all 24 assertions PASS. Ran twice to rule out
two-process ENet timing flakiness; both green.

### F-155 · `PlayerHealth._is_dodging()` throws "Nonexistent 'bool' constructor" against any body with — **fixed**
no `dodging` property, on every enemy attack

**Area:** health · **Severity:** low · **Found:** 2026-08-18 by lp during 5.1

`systems/health/player_health.gd:315` — `_is_dodging(peer_id)` does `bool(body.get(&"dodging"))`. A
real player body (`entities/player/player_controller.gd`) always has `dodging` (task 3.8b), so this is
silent in a real session. But `.get()` on a node with no such property returns Variant NIL, and
`bool(NIL)` is not a valid conversion in Godot 4 — it throws `Invalid call. Nonexistent 'bool'
constructor` rather than degrading to `false`. Any test harness that stands in a bare `Node3D` for a
player (2.10's own `tools/enemy_check.gd` does exactly this, and 5.1's `tools/enemy_ai_check.gd`
inherits it) hits this on every `_resolve_attack()` that reaches `EventBus.emit_enemy_attack_landed`
— a `SCRIPT ERROR:` line on an otherwise passing check. Neither check's own `failures` tally catches
it (it is an engine-level crash inside a signal handler, not a `check()` assertion), so it is only
visible by reading the console output, not the printed verdict line.

**Not fixed here** — `player_health.gd` was not in 5.1's claim, and this is pre-existing: it already
fires the same way on 2.10/2.9's unmodified `enemy_check.gd`, which has shipped and stayed green since
before this task. **What would close this:** `body != null and body.get(&"dodging") == true` — `==` against a bool
literal degrades NIL to "not equal" instead of attempting a constructor call. One-line fix once
someone holds the file.

**Resolved 2026-08-19 by lm.** Fixed: `_is_dodging()` now compares `body.get(&"dodging") == true` instead of `bool(body.get(&"dodging"))`,
so a body with no `dodging` property (NIL) degrades to false instead of throwing. Verified with
`agent godot --script tools/enemy_check.gd` and `agent godot --script tools/enemy_ai_check.gd` — the
`SCRIPT ERROR: Invalid call. Nonexistent 'bool' constructor` line at player_health.gd:349 is gone,
both still `failures=0`. Also re-ran `tools/player_health_check.gd` (0 failures) and
`tools/player_health_net_check.gd` (failures=0) as the health system's own regression bar. Spec block
written at docs/SPECS.md (F-155, near F-150/F-152).

### F-160 · A transient API error kills a saturate chain, and nothing restarts it — the lane sits idle until a human notices — **fixed**

**Area:** tooling · **Severity:** medium · **Found:** 2026-08-19 by bram1

`--watch` sleeps out a quota wall and resumes, but every other non-zero exit ends the chain. That rule
is right for a broken task — retrying one on a loop just burns the window — and wrong for the case
where the service, not the task, failed.

Observed 2026-08-19. LM lost 6.1 twenty-three minutes and 12.4M tokens in to
`API Error: 521 — "Web server is down"`, Cloudflare unable to reach the origin. The CLI's own message
calls it a server-side issue and says to try again in a moment. Instead the chain exited with four
orders still queued, and the lane sat idle. It was caught inside two minutes only because a monitor
happened to be armed and someone was awake to read it; overnight it would have idled until the
window expired unspent, which is the one loss this whole harness exists to prevent.

**Fixed:** `_run_with_resume` now retries once per attempt, after a 90-second pause, when the lane's
recorded error names itself an infrastructure failure. The classifier is deliberately narrow — 5xx
status codes, "web server is down", "bad gateway", "service unavailable", "overloaded_error",
"server-side issue", "connection refused/reset", "temporarily unavailable" — and shares
`MAX_RESUMES` with the quota path, so a persistent outage stops the chain rather than spinning on it.

**Verified both directions, because a classifier that over-matches is worse than none.** It fires on
the verbatim 521 body, the CLI's "server-side issue" wording, an `overloaded_error` payload, a 502,
and a refused connection. It does NOT fire on: not-logged-in, a quota-limit message, a GDScript parse
error, `exited 0 without closing out`, a check reporting `failures=2`, or a claim collision — the six
failure shapes seen in this project that genuinely need a human. 0 wrong across 11 cases.
`lane selftest` 23/23; both lanes still dispatching.

---

### F-152 · `core/render/mesh_merge.gd` builds an invalid surface at boot, so merged undergrowth silently draws nothing — **fixed**

**Area:** rendering · **Severity:** medium · **Found:** 2026-08-18 by slate17 during 3.7 · **Owner:** F-144 (nettle12)

At HEAD (`e5f96b1`, F-144's mesh merging) a plain boot — `.agent/bin/agent godot --quit-after 5` —
emits a repeating error triple from the same call site:

```
ERROR: Condition "array.size() != p_vertex_array_len" is true. Returning: ERR_INVALID_PARAMETER
ERROR: Invalid array format for surface.       at: mesh_create_surface_data_from_arrays
ERROR: Index p_idx = -1 is out of bounds (surfaces.size() = 0).
  [0] _build (res://core/render/mesh_merge.gd:202)
  [1] merged (res://core/render/mesh_merge.gd:37)
  [2] _emit (res://world/gen/undergrowth.gd:517)
  [3] _scatter (res://world/gen/undergrowth.gd:294)
```

The surface is rejected, so the merge produces a mesh with zero surfaces and the following
`surface_get_material(-1)` is out of bounds. Every affected undergrowth batch therefore draws
nothing — the failure is loud in the log and invisible on screen, which is the worst combination:
it reads as "the grass is a bit sparse".

Most likely one of the merged source arrays is missing a channel the others have (a mesh with no UV,
no colour or no tangent among meshes that have them), so the concatenated arrays disagree with the
declared format. A per-source format mask, intersected across the batch before concatenating, is the
usual fix.

**Not fixed here:** both files are claimed by F-144, which is still in flight. Filed rather than
touched (AGENTS.md). Reproduce with the boot command above; grep for `mesh_merge.gd:202`.

**Resolved 2026-08-19 by lp.** Already fixed by the time this task picked it up: F-144's attribute-mask bucketing (commit
76d48bc, in flight under nettle12's claim the whole time this task ran) keys merge buckets on
`_attribute_mask(arrays)` as well as material appearance, so two parts can only share a bucket
when they carry the same optional vertex channels -- the mismatched-array-length case this
finding describes can no longer happen. No code change was needed or made; both
core/render/mesh_merge.gd and world/gen/undergrowth.gd stayed under F-144's claim untouched.

Verified: wrote tools/mesh_merge_check.gd (none existed) -- clears MeshMerge's disk cache, then
calls MeshMerge.merged() directly on every .glb under every assets/*/exports/ kit dir (discovered,
not hardcoded) and asserts a non-null mesh whose every surface's present channels each carry
exactly one entry per vertex (four for tangents). `agent godot --script tools/mesh_merge_check.gd`
-> `MESH_MERGE_CHECK checked=337 surfaces=1287`, `MESH_MERGE_CHECK_GODOT PASS`. Cross-checked
against the finding's own repro: `agent godot --quit-after 20` on levels/hollowmere.tscn (the
boot scene the original stack trace came from) -> zero ERROR: lines total, none mentioning
mesh_merge.gd, array.size(), p_idx, or surfaces.size(). Full spec + verification detail in
docs/SPECS.md under F-152.

### F-126 · CommandService's `peer` argument type has no display-name resolution — peer ids only — **fixed**

**Area:** netcode · **Severity:** low · **Found:** 2026-08-18 by lp during 3.13

`docs/COMMANDS.md` §2.2 specifies the `peer` argument type as "peer id int or player display name —
resolves against connected peers." `autoload/command_service.gd`'s `_parse_peer()` only implements
the first half: it validates the token is a positive int and accepts it outright (see D-078's
neighbor decision in `_parse_peer`'s own doc comment for why it does not even require the id to
currently be connected — that part is deliberate, not part of this gap). There is no per-player
display-name registry anywhere in the project yet for the second half to resolve against — `op
<name>` and any future `peer`-typed command that would want to accept a friendly name instead of a
raw id cannot.

Nothing is broken today: `op <peer_id>` and every other `peer`-typed command work fine with the raw
integer id, which is what `NetDebugPanel`/`net_debug_panel.gd` and the lobby roster already surface
to a player who needs to look one up. This is scheduling information for whichever task first wants
`give bob 5` to work rather than `give 988921899 5` — most naturally task 3.16 (the catalog sweep,
which owns the rest of §2.2's argument-type completeness) or whatever eventually adds player display
names to the project for other reasons (a lobby roster label, a kill-feed name) — `_parse_peer`
should grow a name lookup against that same registry rather than inventing its own.

---

**Resolved 2026-08-19 by lp.** Closed as D-098: no display-name registry built (F-126's own text says _parse_peer should consume
one, not invent one; also blocked regardless — the honest LOCAL/LAN fix needs a new client->host RPC,
which requires bumping PROTOCOL_VERSION in core/net/net_version.gd, held by slate17's exact-file claim
for 3.7 the entire time). Filed F-157 to carry the actual registry forward (3.16 shipped without
adding one, so F-126's original pointer at it is stale). Updated _parse_peer()'s doc comment to point
at F-157. Added tools/command_check.gd's new "peer arg type" section pinning current behavior: a
display-name token refused with the exact documented message (not silently mis-resolved), 0/negative/
non-integer tokens refused, and an unconnected int still accepted (D-078) as its own explicit
assertion. Verified: agent godot --script tools/command_check.gd -> COMMAND_CHECK failures=0, all 7
new assertions PASS, zero ERROR: lines. Regression: agent godot --script tools/verify_setup.gd -> all
checks passed. Full spec + verification in docs/SPECS.md's new F-126 block.

### F-138 · Rotating an AABB's corners is still the wrong ruler when the thing you are rotating is a moving part — **fixed**

**Area:** tooling · **Severity:** low · **Found:** 2026-08-18 by slate17 during 2.1d (A-010)

F-094 established that measuring a rotated object through `Transform3D * AABB` inflates it, and
`tools/ship_check.gd` and `mire_art.world_bounds` both measure vertices for that reason. The first
draft of `tools/construction_check.gd` reintroduced the same error in a **third** form: not to
measure a static asset, but to *move* one — the door-swing test rotated each part's eight AABB
corners and took the AABB of the result, at ten angles.

The box around a rotated box is bigger the more the part is turned, so the test reported four
innocent leaves colliding with their own frames at 60–90°, and the frames' diagonal knee braces —
themselves rotated boxes — were inflated obstacles on the other side of the same comparison. It read
exactly like a real art defect, and the tempting fix was to move the art.

**The general rule:** a checker that *moves* geometry has to move the geometry. The fix was to expand
each mesh through its index buffer into a triangle soup once, then rotate leaf **vertices** and test
them against frame **per-triangle** bounds — after which all four leaves swing their full documented
arc with zero contact, and the two defects that were real (a threshold the leaf was buried in, knee
braces standing in the gateway) stayed reported.

**Resolved 2026-08-19 by lm.** No code change needed — the fix described in this finding's own text was already shipped in
tools/construction_check.gd by the time this task picked it up: _measure() expands each mesh into a
triangle soup through its index buffer, and _check_doors() rotates leaf VERTICES against frame
PER-TRIANGLE bounds (never transform * get_aabb() on either side). This task's job was verification
and closing the doc trail SPECS.md never got (see the new ## F-138 block in docs/SPECS.md).

Verified: `agent godot --script tools/construction_check.gd` -> CONSTRUCTION_DOORS swung=4,
CONSTRUCTION_CHECK PASS, zero door-swing failures on a clean tree. Confirmed the test is live, not
vacuous: temporarily changed line 419's `+ hinge_at` to `+ hinge_at * 0.0` (rotating a leaf about the
world origin instead of its real hinge post) and reran -> FAIL palisade_gate_leaf: Gate_Bar_3 is
inside the frame at 0 degrees, CONSTRUCTION_CHECK FAIL failures=1. Reverted immediately after;
`git diff tools/construction_check.gd` shows no changes.

Noted but out of scope: a bare run logs 4.8M+ repeats of F-148's unrelated "AABB size is negative"
error (1.4 GB log, triggered by task 3.7's still-uncommitted door/gate/palisade-gate scenes) but the
process still completes and reaches _finish() — F-148 is signal-to-noise, not a hang, so this task
did not need to route around it the way F-137 did.

### F-137 · The build module lives in one `.tres` and nothing else knows it — **fixed**

**Area:** process · **Severity:** low · **Found:** 2026-08-18 by slate17 during 2.1d (A-010)

`content/buildables/wall.tres` is the only place that states MIRE's build module: `size = Vector3(2, 3, 0.25)`
with `snap_step = 1.0` and `rotation_step_degrees = 90`. Nothing in the art pipeline referenced it —
A-010 had to read that resource by hand and re-declare 2.00 m / 3.00 m as constants in
`tools/blender/build_construction_set.py`, and `mire_art.SCALE` now carries eighteen entries derived
from them.

Two copies of a number that must agree, in two languages, with no check between them. The next
buildable authored at 2.5 m, or the next art batch that assumes 2 m after someone changes the wall,
silently produces a kit that does not tile — and the failure appears as art that looks fine in
isolation (F-129's shape again).

**What to do about it:** either have the art generators read the module out of `content/buildables/`
at build time, or add a check that asserts the two agree — `tools/construction_check.gd` already
loads both the catalog and the engine's resources, so asserting `wall.tres`'s `size.x` equals the
catalog's `run_span_m` is a few lines in a place that already runs. Not done here because it needs a
claim on `content/buildables/` and task 3.7 is the owner.

**Resolved 2026-08-19 by lm.** tools/construction_check.gd gained _check_buildable_defs(): wall.tres is checked directly against
this file's MODULE/WALL_H constants (no catalog counterpart exists for it), and door/gate/palisade/
palisade_gate/dock/bridge/ladder — all authored since this finding was filed — are each checked
against their matching catalog entry's engine-measured run_span_m/height_m. Depth is deliberately
never compared (buildable_def.gd's own doc comment: a footprint may be thinner than its art on
purpose). Full spec + trap notes in docs/SPECS.md under F-137.

Verified: `agent godot --script tools/construction_check.gd` -> CONSTRUCTION_BUILDABLE_DEFS
checked=8, CONSTRUCTION_CHECK PASS (run with _check_doors() temporarily skipped to route around
F-148's unrelated hang, which is now much worse than when filed - see F-148 update). Confirmed the
check is live, not vacuous: temporarily set MODULE=2.5 -> FAIL wall.tres: size.x is 2.000 m, the
kit's module is 2.50 m; reverted, git diff shows only the intended addition.

### F-156 · A finding goes stale when a neighbouring task fixes it in passing, and nothing tells the next lane before it spends a window — **fixed**

**Area:** tooling · **Severity:** medium · **Found:** 2026-08-19 by bram1

The most repeated waste in this project, measured across a single day: six dispatches (F-103, F-107,
F-108, F-111, F-135, F-151) went to findings that had stopped being true. A neighbouring task fixes
the underlying bug in passing, nobody moves the entry out of `## Open`, and it sits there looking
exactly like work. The lane arrives, discovers the fix already landed, and spends its window writing
the docs the original task skipped. That is not nothing — but it is not what was ordered, and the
director keeps choosing it over real work because the board cannot tell the difference.

**Fixed:** `agent brief` on an F-number now checks whether the files that finding names have changed
since it was filed, and warns before the lane reads a word of the spec. It reads paths from the
heading as well as the body — findings name their file in the title as often as in the prose — and
tells the reader to run the check first, because that is the one cheap thing that settles it. It
warns rather than blocks: a changed file does not prove a fix, and a finding that is still true
should still be worked.

**The bug that made the first version useless, and it is worth knowing generally:**
`git log --since=2026-08-18` does **not** mean midnight. Git's approxidate reads a bare date as that
day *at the current time of day*, so running it at 17:00 silently excludes everything committed
earlier the same day — precisely the window in which a finding goes stale. Three test runs printed
no warning and looked like a healthy guard with nothing to report. The fix is to pin the time:
`--since=<date> 00:00`.

That failure shape has now appeared three times in one day: the F-104 watchdog gated on an exit code
Godot never returns, F-107's check whose closure captured a peer id by value, and this. **A mechanism
that silently does nothing is indistinguishable from a mechanism with nothing to report.** Test the
positive case before believing a quiet one.

**Verified:** fires correctly on F-126 (`autoload/command_service.gd`, 5 commits since), F-152
(`core/render/mesh_merge.gd`, 1 commit since) and F-137, both of the first two being orders queued to
LP at the time of writing; the raw `git log` counts were confirmed by hand against each path.

---

### F-132 · A remote client's scattered harvestable proxy may have no host counterpart to reach, because `ChunkStreamer` streams per-peer independently — **fixed**

**Area:** world-gen / netcode · **Severity:** medium · **Found:** 2026-08-18 by lm during 4.4

`ARCHITECTURE.md` §2.2 deliberately makes chunk streaming client-local, independently per peer: "a
host and a client streaming different chunk sets around their own local players is correct, not a
desync" (D-080's own reasoning for task 4.3). Task 4.4's `ResourceScatterField` builds its
harvestable proxies exactly on top of that same per-peer ring (`chunk_has_collision()`, D-083), and
the proxy's depletion is real, host-authoritative `Harvestable` state living on whichever holder
node happens to exist at that world position — same as any other harvestable.

That composition has a gap the terrain-only case never had: a client's own `Harvestable` node for a
point near ITS player sends `net_request_hit.rpc_id(NetConfig.HOST_PEER_ID)` targeting a specific
NodePath. If the HOST's own player is far enough away that the host's `ChunkStreamer` never loaded
that chunk, the host has no node at that path to receive the call at all — nothing types-checks or
crashes today because nothing yet instantiates `ChunkStreamer`/`ResourceScatterField` in the live
game (4.6 is the task that does), so this has not been reachable in practice, but it will be the
moment 4.6 wires both into a running multiplayer session.

**Why not fixed inside 4.4:** the honest fix is either (a) the host maintaining chunk-load state for
the union of every connected player's position, not just its own local player's ring, or (b) a real
chunk-keyed request/response that does not depend on a live node existing at a specific path on the
receiving peer. Both are genuine multiplayer-interest-management design decisions that belong with
whichever task first puts these systems in a real session — almost certainly 4.6 (seed replication +
client regen + delta sync), whose whole job is "every mutation... replicates as deltas keyed by
chunk" (`ARCHITECTURE.md` §4). Solving it inside 4.4 would mean guessing at 4.6's own wire format.

**What fixing it will look like, most likely:** the host's own `ChunkStreamer`/`ResourceScatterField`
pair gets anchored not just to the host's local player but to every connected peer's last-known
position (a host-side "union of interest," the same shape `NetInterest` already applies per-entity
for replication filtering, generalized to chunk residency) — so any point a REMOTE client can reach
is guaranteed to have a host-side holder loaded to receive its request, even when the host's own
player is elsewhere.

**Claim:** none yet — no file to fix until the task that wires `ChunkStreamer` into a live session
picks this up.

---

**Resolved 2026-08-19 by lm.** Resolved without code changes to ChunkStreamer/ResourceScatterField's ring or proxy mechanics — set_anchors()
already takes Array[Vector3] and _ring_distance() already unions over the nearest of every anchor, so a chunk
stays resident as long as ANY anchor's ring reaches it; ResourceScatterField already builds/tears down scatter
per chunk, never per anchor. The fix is the calling contract (D-096): whichever task wires a live session
(F-139, still open) must anchor the host's ChunkStreamer/ResourceScatterField pair to the union of every
connected peer's last-known position, not just its own local player — now a header-level doc comment on both
files instead of implicit. Also documented a real ordering trap found while proving this: attach_to_streamer()
only reacts to future signals, so it must be called before the streamer is given anchors, or already-resident
chunks silently get no scatter.

Verified: agent godot --windowed --script tools/chunk_stream_check.gd's new union-of-interest section — a real
ChunkStreamer fed two anchors >= LOAD_RADIUS_CHUNKS + HYSTERESIS_CHUNKS + 1 chunks apart (so neither anchor's
own ring could reach the other's target by construction) with a real ResourceScatterField attached, proving
both anchors' chunks load at LOD0 with a collider and both materialize a live, HarvestWorld-wired Harvestable.
0 functional failure(s) across the whole file (all pre-existing phase 1/phase 2 assertions still pass).
Regression: agent godot --script tools/resource_scatter_check.gd -> RESOURCE_SCATTER_CHECK failures=0;
agent godot --script tools/verify_setup.gd -> all checks passed.

### F-153 · COMMANDS.md §7 lists 'clear' under both Inventory and Meta — one name, two systems — **fixed**

**Area:** docs · **Severity:** low · **Found:** 2026-08-18 by hollow7

`docs/COMMANDS.md` §7's catalog table gives the name `clear` to two different rows:

| Inventory | `give`, `clear [target]`, `inv <peer>` |
| Meta      | `help`, `commands [--json]`, `function <name>`, `op/deop`, `clear`(console), `quit` |

`CommandService.register_spec()` replaces a name silently (deliberately — content reload and test
setup both want that), so implementing §7 literally means whichever autoload registers second wins
and nothing says so. Task 3.16 resolved the conflict in code — the console keeps `clear`, the
inventory wipe became `inv clear [peer]` — and recorded that as **D-093**.

**What is left:** the spec table still says `clear [target]` under Inventory, so the next person to
read §7 as a checklist will look for a verb that does not exist, or re-add it and silently break the
console's. `tools/command_catalog_check.gd` now pins the shipped truth (it asserts `inv` is HOST and
`clear` is LOCAL/console), so the code cannot drift back — but the doc and the check now disagree.

Fix: edit the §7 Inventory row to read `inv <peer> [clear]` (or `inv list|clear`), leaving the Meta
row's `clear`(console) alone. Doc-only change; the check already encodes the intended end state.

**Resolved 2026-08-18 by hollow7.** Fixed in the same task that found it (3.16). `docs/COMMANDS.md` §7's Inventory row now reads
`inv [list|clear] [peer]` instead of `clear [target]`, and the paragraph under the table records
why the console keeps the bare `clear` (D-093), plus the two other things building the coverage
check turned up.

Verified by `tools/command_catalog_check.gd`, which pins the shipped truth from both directions:
`inv` must be HOST scope and `clear` must be LOCAL (listed as "Meta (console)"), so the code cannot
drift back to the collision and the doc no longer describes a verb that does not exist. Run:
`.agent/bin/agent godot --script tools/command_catalog_check.gd` — 41 assertions, failures=0.

### F-141 · `Wellspring.net_request_toggle_channel` has no two-process net check — only the host-side logic it calls into is proven — **fixed**

**Area:** worldgen / netcode · **Severity:** low · **Found:** 2026-08-18 by lm during 4.8

`tools/wellspring_check.gd` proves the ritual state machine directly — `wellspring.call(&
"request_toggle_channel")` and `host_tick()` in a single process, exactly the offline/host-of-one
path. It does not prove the RPC itself: that a REMOTE client's `net_request_toggle_channel.rpc_id()`
actually reaches `_process_toggle(multiplayer.get_remote_sender_id())` on a real second ENet
process, the way `tools/chest_check.gd`'s sibling `chest_net_check.gd` (and
`attunement_service.gd`'s, `haulable.gd`'s) two-process checks prove their own request/grant RPCs.

Left this way because `net_request_toggle_channel` is a two-line pass-through into
`_process_toggle`, which the single-process check exercises exhaustively (start, cancel,
out-of-range rejection, solo vs co-op sizing, presence-gated pausing, completion) — the marginal risk
is in the RPC annotation itself (`@rpc("any_peer", "call_remote", "reliable")`) and the
`multiplayer.get_remote_sender_id()` call, not in logic a second process would exercise
differently. Still a real gap: a two-process `wellspring_net_check.gd` in `chest_net_check.gd`'s
shape (driver process + `--` probe arg, talk through a `user://` JSON file, per `docs/SPECS.md`'s
"Two-process checks" seam) is the way to close it, and should claim `tools/wellspring_net_check.gd`
plus `systems/wellspring/wellspring.gd` when someone picks it up.

**Resolved 2026-08-18 by lm.** Fixed: `tools/wellspring_net_check.gd`, a real two-process ENet check in `chest_net_check.gd`'s shape
(driver + `-- wellspring-probe` probe arg, `user://wellspring_net_client.json`). Both processes build
the same bare `Wellspring` at the same node path before branching. The client's own
`request_toggle_channel()` toggle-start and toggle-cancel each go out as a real `net_request_toggle_channel.rpc_id()`
over loopback ENet; the driver asserts the HOST's `Wellspring` flips `channeling` true then false from
that remote RPC alone (never a local call), that `required_players`/`duration_sec` land on the co-op
values now that a real second peer is connected, and — via the client's own result file — that the
client only ever learns either state through replication, never a direct reply. `PRESENCE_RANGE_M` is
a fixed constant the check cannot override, so the driver snaps the host's `Wellspring.global_position`
onto the client's actual `PlayerNet`-spawned position rather than assuming a spawn-offset value.

Verified 2026-08-18: `agent godot --script tools/wellspring_net_check.gd`, twice back to back —
`WELLSPRING_NET_CHECK failures=0` both runs, all 12 assertions PASS. Full spec in docs/SPECS.md
under F-141 (includes the trap paid for: hit F-107's exact lambda-by-value bug a second time, on
`client_player` this run instead of `client_peer` — fixed the same way, polling a boolean and
re-fetching outside the closure).

### F-135 · A modular piece can measure its module exactly and still leave a seam: the bounding box is not the walking surface — **fixed**

**Area:** art-pipeline · **Severity:** medium · **Found:** 2026-08-18 by slate17 during 2.1d (A-010)

`build_construction_set.py`'s `deck_field()` laid each deck plank centred in its slot and shrank it
by the plank gap, which left **half a gap of nothing at both ends of every field**. Every affected
piece still measured exactly 2.000 m wide — the beams, kerbs and bearers reach the module edge — so
the Blender build contract, which checks the piece's overall run span, passed 18/18 with a **12 mm
stripe of daylight at every joint in a run** and 6 mm where a ramp met a dock.

Nothing that looks at one asset can see this. It showed up the first time `tools/construction_check.gd`
assembled five modules in the engine and measured the gap between consecutive **deck** bounds rather
than between piece bounds.

**The general rule:** when a kit's contract is "these tile", measure the surface that does the
tiling — the deck planks, the rail run, the wall face — not the asset's bounding box. The bounding
box is decided by whatever sticks out furthest, which is exactly the geometry a player never touches.
Fixed by having `deck_field()` run its outer planks to the field edge and put the gaps only between
them; the engine check now reports worst joint **0.0000 mm** across a five-module walkway, a
boardwalk corner and a fence corner.

**Resolved 2026-08-18 by lm.** Verified, not re-fixed: `build_construction_set.py::deck_field()` already runs its outer planks to
the field edge (only inner gaps are subtracted, `index > 0`/`index < count - 1` guard the two ends) —
this landed in the same 63cc37c commit the finding's own "Fixed by..." sentence describes, from task
2.1d. Confirmed against every other candidate seam in the kit: `palisade_logs()`'s mating plane is
its rail boxes, which already span the full MODULE width as a single box rather than a gapped field,
so it was never exposed to this bug class.

Verified with `agent godot --script tools/construction_check.gd`:
CONSTRUCTION_WALKWAY modules=5 worst_joint=0.0000 mm deck=1.000 m
CONSTRUCTION_DOCK_CORNER arms=0.0000 mm / 0.0000 mm
CONSTRUCTION_PALISADE_CORNER arms=0.0000 mm / 0.0000 mm
— a five-module walkway (ramp, two docks, straight bridge, broken bridge), a dock corner and a
palisade corner all close to 0.0000 mm, matching the finding's own closing numbers exactly.

Added the missing docs/SPECS.md block (§ "F-135") so the next agent doesn't have to re-derive this
from the finding text alone. Did not write a new focused check: `tools/construction_check.gd`
already IS that check — `_check_walkway`/`_check_dock_corner`/`_check_palisade_corner` measure deck
and rail bounds specifically, never piece bounding boxes — so a second script would only duplicate
it. The work order's "no focused check exists yet" was stale against the same 2.1d commit.

Unrelated defect surfaced during this verification run, filed separately as F-148 (not fixed here,
out of scope): `_check_doors()` throws an UNDECLARED `AABB size is negative` error ~10x per run from
a `.grow(-0.004)` on a degenerate per-triangle box. It does not touch deck/gap measurement and the
walkway/corner numbers above are unaffected by it.

### F-140 · Task 3.5 closed without the four chest changes `ITEMS.md` §6 assigned to it, so two shipped stats had no consumer — **fixed**

**Area:** loot · **Severity:** medium · **Found:** 2026-08-18 by slate17 during 3.2

`docs/ITEMS.md` §6 names four small things as 3.5's, "so they're noticed decisions (F-078 rule)":
`LootEntry.kind: ITEM | POWERUP`, `LootEntry.rarity`, `Chest.cost_coins` + `locked_by`, and a
placement budget for the gilded tier. 3.5 shipped and closed with none of them. The consequences
were not cosmetic:

- **Chests could not grant powerups at all**, though `DESIGN.md` §4.4 has always said they do. Every
  tier in §5 is mostly powerups — "common powerups 55%" is most of what a Bog Chest is — so the
  authored chest economy could not be written.
- **`loot_luck` and `chest_price` were shipped stats with no reader.** `second_glance`,
  `fruiting_call` and `hollow_bargain` were authored against them, so three of the sixty-four
  powerups in the game promised better loot and cheaper chests and did **nothing at all**. A powerup
  that lies is worse than a missing one: the player pays a chest slot for it.
- Every chest was free and unlocked, so the coin economy had a source and no sink.

**Fixed here, inside 3.2**, because the content this task exists to author cannot be expressed
without it: `kind` and `rarity` on `LootEntry`; `LootTableDef.roll(rng, luck)` returning a third
`powerups` bucket and weighting each line by `(1 + luck * rarity)`; `Chest.cost_coins` and
`locked_by`, charged in one `host_transaction` **before** the roll so a failed payment grants nothing
and leaves the chest re-openable; powerups granted through `PowerupService.host_grant`. Proof is
`tools/loot_content_check.gd`. The fourth item — a placement budget for `gilded` — is still open and
belongs to whatever places chests in the world.

**The trap inside the trap, worth more than the fix:** `loot_luck` read on a base of `0.0` is always
`0.0`. `PowerupService.stat()` computes `(base + flat * N) * (1 + mult * N)`, and every authored
`loot_luck` modifier is multiplicative, so the first working version of this code still read zero
luck from a powerup that grants +30%. Percentage-authored stats must be read against a base of
`1.0` and the surplus taken (D-091). Any future consumer of `coin_gain`, `harvest_yield`,
`craft_seconds` or the other multiplicative stats has exactly this decision to make, and getting it
wrong looks like the stat working.

**Also noticed, not fixed:** `tools/chest_check.gd` emits one undeclared engine ERROR line from its
deliberate unknown-tier case, which `docs/AUDIT-2026-08-17.md`'s "0 engine-error lines" claim says
should not exist. It needs either an `EXPECTED_ERROR_PATTERNS` declaration or an assertion that
swallows it.

**Resolved 2026-08-18 by reed16.** Resolved by reed16. F-140 had two halves and both are now closed out.

**The substantive half was already fixed inside 3.2** and F-140's own text records it. Re-verified in
code before resolving, rather than taken on the text's word: `LootEntry` carries `kind` and `rarity`;
`LootTableDef.roll(rng, luck)` returns the third `powerups` bucket; `Chest.cost_coins` and
`locked_by` are real exported properties on `systems/loot/chest.gd` (lines 41 and 44) and are charged
before the roll. `tools/loot_content_check.gd` exercises all of it.

**The half that was still open — the undeclared engine error — is fixed here** (commit eb23dc1).
F-140 closed noting that `tools/chest_check.gd` emits one undeclared ERROR line from its deliberate
unknown-tier case, which falsifies `docs/AUDIT-2026-08-17.md`'s "0 engine-error lines" claim for that
check. The check builds a chest on an unresolvable tier on purpose, to prove the refusal happens;
that fires `Chest._validate_configuration`'s own `push_error` at `systems/loot/chest.gd:270`.

Declared by pattern on the existing verdict line — the placement `haul_check.gd` already uses — per
standing rule 4 in `docs/SPECS.md`, rather than silencing the production log call:

    print("CHEST_CHECK failures=%d · EXPECTED_ERROR_PATTERNS=\"references unknown loot tier\"" % failures)

Verified with the grading rule the spec prescribes: `agent godot --script tools/chest_check.gd` gives
`CHEST_CHECK failures=0`, and `grep 'ERROR:' | grep -vE 'references unknown loot tier' | wc -l` gives
**0**. Note the file already had a verdict line — the fix amends it in place; adding a second print
in `finish()` duplicates the line and is wrong.

**The fourth `ITEMS.md` §6 item is NOT resolved here — it is now F-146.** The gilded placement budget
(≈1–2 per island) still has no owner because nothing in the game places a chest at all; `grep -rn
chest --include='*.gd' world/` is empty. F-140 flagged that as belonging to "whatever places chests
in the world", and it is filed separately so resolving this one does not bury it.

### F-136 · The player controller has no step-up, so any lip in a walkable surface is a wall — **fixed**

**Area:** movement · **Severity:** medium · **Found:** 2026-08-18 by slate17 during 2.1d (A-010)

`entities/player/player.tscn` sets `floor_max_angle` to 46° and `floor_snap_length` to 0.3, and
`entities/player/player_controller.gd` implements **no step-up logic at all** — there is no
`test_move` and re-place, no ledge probe, nothing. Godot's `CharacterBody3D` does not provide one
either. A capsule will scuff over a very small lip because its bottom is round, but nothing in the
project guarantees a height, and no test covers it.

This is an authoring constraint on every asset and every level, and it is invisible until someone
walks into it: a 60 mm door threshold, a dock deck edge, a kerb across a path, or a bridge module
sitting a centimetre proud of its neighbour is a **wall**, not a step. A-010 hit it twice — the wood
door was authored with a 60 mm sill across its opening (removed; a doorway is a hole), and the whole
reason its ramp exists at 26.57° with a 12 mm feathered toe rather than a square end is this.

**What to do about it:** either author to it — ramps under 46°, no thresholds, mating planes to the
millimetre, which is what A-010 now does and what `tools/construction_check.gd` enforces — or give
the controller a real step-up (probe forward at knee height, snap up if the surface above is
walkable) and pick a documented maximum. The second is a movement-feel change and belongs to whoever
owns the controller, not to an asset batch. Until then, **assume a lip stops the player.**

**Resolved 2026-08-18 by lm.** Fixed: `entities/player/player_controller.gd` gained `_apply_step_up(delta)`, called every physics
tick right before `move_and_slide()`, grounded only. New `@export var step_height: float = 0.4`
(Step group) is the documented maximum — comfortably above the 60 mm threshold/12 mm ramp-toe cases
A-010 authors around (D-090), comfortably below `jump_height` (1.1 m) so a step never substitutes
for a jump.

Three `test_move()` probes: is flat forward motion blocked; is there room to rise `step_height` with
nothing overhead; from the raised height, sweep `motion + Vector3(0,-step_height,0)` — forward AND
down together, in ONE `test_move()` call — and take its first contact as the landing. That combined
sweep (not a separate horizontal-advance-then-vertical-drop) is the load-bearing detail: a real
per-tick `motion` (~0.067 m at 4 m/s / 60 Hz) is far smaller than the capsule's 0.4 m radius, so
testing/advancing horizontally by only that much and then dropping separately leaves the capsule
still straddling the lip's corner — move_and_slide() then fights that self-overlap back out every
following tick, which reads as the player bouncing in place at the lip rather than climbing it
(reproduced empirically while building the check below, before landing on the combined-sweep fix).

Verified: `agent godot --script tools/step_up_check.gd` (new) -> 0 failure(s). Spawns a real
player.tscn against code-built StaticBody3D geometry (tools/build_check.gd's technique) and hand-
drives _apply_gravity/_apply_horizontal_movement/_apply_step_up/move_and_slide in that order (same
technique tools/dodge_check.gd already uses for this controller) rather than real WASD input, because
AttunementUI (autoload) opens a blocks_gameplay_input role picker ~0.5s after any node joins the
`players` group and would otherwise starve a real-input-driven walk before it reaches the lip. Proves:
a 0.15 m lip is climbed without a stall, landing at the lip's own height (not a flat step_height
higher); a 0.6 m wall is refused (the walk stops at its face; ordinary capsule-corner "scuff" under
move_and_slide() can still ride a short way up per the finding's own description, but never near-
mounts it); and a step_height=0 control proves the same low lip now blocks, so the suite is a real
regression guard.

Also reran the two other checks that already exercise this controller's _physics_process() path to
confirm no regression: `agent godot --script tools/dodge_check.gd` -> 0 failure(s),
`agent godot --script tools/spawn_ground_probe.gd` -> failures=0 (real main-scene terrain spawn/
settle, which now runs _apply_step_up() every grounded tick, unaffected on ordinary flat terrain),
`agent godot --script tools/verify_setup.gd` -> all checks passed.

New docs/SPECS.md block written (F-136 had none) per this task's own instruction that a missing spec
is fixed by the task that discovers it.

### F-145 · Auto-name collisions defeat the claim guard: the exhaustion fallback ignores the taken set, so concurrent sessions share one identity — **fixed**

**Area:** tooling · **Severity:** high · **Found:** 2026-08-18 by nettle12

`_auto_name()` in `.agent/bin/agent` picks a name by walking `AUTO_NAMES` from a crc32 of the session
token and returning the first candidate not in `taken`. That part is correct. The fallback when the
whole pool is taken is not:

    return "%s%d" % (AUTO_NAMES[start], start)

It never consults `taken`. `start` has only `len(AUTO_NAMES)` = 24 possible values, so **every**
session whose token lands on the same base name collapses onto one identical string, forever.

**This is not hypothetical — the pool is already exhausted.** `.agent/sessions.json` holds 66
registered sessions across 44 distinct names. Eleven auto-names are each shared by two to five
different session tokens: `ivy8` ×5, `nettle12` ×4, `reed16` ×4, `pike14` ×3, `yarrow21` ×3, plus
`moss11`, `tine18`, `wick20`, `flint5`, `dusk3`, `kiln9` ×2 each.

**Why it matters more than cosmetics: identity is what the claim system compares.** Both guards test
a bare name string —

- `agent claim` (line ~765): `conflicts = [... if st["claims"][f]["agent"] != me]`
- the pre-commit `agent check` (line ~1363): `if c and c["agent"] != me:`

so when two *concurrent* sessions share a name, a peer's live claim is indistinguishable from your
own. The conflict branch never runs. Concretely, the protection AGENTS.md calls non-negotiable
silently fails open:

- `agent claim` grants a file another live agent is holding — the die() on "two agents in one file
  will conflict" cannot fire.
- the pre-commit hook lets an agent commit a file another live agent holds.
- journal and finding attribution merge two agents into one name.

**Observed live, this session.** Session `40988e99…0f6f` (registered 21:48:04) and session
`92a26246…c5bc` (registered 21:49:38, 94 seconds later) are both named `nettle12` and were both
running. F-144 was filed by the second one and is stamped "Found: 2026-08-18 by nettle12" — the same
attribution this session writes. Two agents, one identity, one working tree.

Reproduced directly: crc32 of all four `nettle12` tokens returns `start = 12`, base `nettle`, and the
fallback returns the constant `nettle12` for every one of them.

**Fix must stay a pure function of the token.** The existing docstring is right that the name has to
be derivable from the token alone, because a git hook is a separate process that must resolve the
same name — so the fallback cannot be "search `taken` again", which would hand one chat a different
name once `taken` grew. It needs a wider deterministic suffix instead of the 24-value pool index.

**Resolved 2026-08-18 by nettle12.** Fixed in `.agent/bin/agent`. The pool-exhausted fallback in `_auto_name()` now suffixes the base name
with 24 bits of the token's own crc32 instead of the pool index:

    return "%s%06x" % (AUTO_NAMES[start], binascii.crc32(token.encode()) & 0xFFFFFF)

The index had only `len(AUTO_NAMES)` = 24 possible values, so every chat landing on the same base
collapsed onto one string. The suffix is still a pure function of the token and still deliberately
ignores `taken`, which the original docstring is right to require: a git hook is a separate process
that resolves the name later, when `taken` has grown, and re-searching there would hand one chat a
different name than the one it registered.

Verified by lifting `_auto_name` out of the script and exercising it directly:

- The four real session tokens that had all become `nettle12` now return four distinct names
  (`nettle303b44`, `nettle7ae874`, `nettle47b42c`, `nettleb8a1a4`).
- Determinism holds: repeat calls, and a call with a `taken` set that has since grown, all return the
  same name — the git-hook requirement.
- No regression while the pool has room: with nothing taken the token still gets the plain `nettle`,
  and with `nettle` held it still walks to `onyx`.
- 5,000 synthetic session ids against an exhausted pool produced 5,000 distinct names, 0 duplicates.
- `python3 -m py_compile` clean; `agent board` runs.

Two things the next agent should know:

1. **Existing sessions are not renamed and must not be.** `whoami()` resolves a registered token from
   `sessions.json` before it ever calls `_auto_name`, so this changes new assignments only. The eleven
   already-collided names (`ivy8` ×5, `nettle12` ×4, `reed16` ×4, …) stay as they are and age out via
   `_prune_sessions` after SESSION_KEEP_DAYS. Renaming a live session would orphan its claims, which
   are keyed by name.

2. **Exhaustion is the steady state here, not an edge case.** `taken` is every unpruned session, and
   this repo carries 66 of them against a 24-name pool. The fallback was therefore the common path,
   not a rare one — which is why eleven names collided rather than one. If collisions reappear, the
   real lever is a larger `AUTO_NAMES` pool or a shorter `SESSION_KEEP_DAYS`, not the fallback.

### F-143 · Audit contact sheets escape .gitignore when written to a per-audit subdirectory — **fixed**

**Area:** tooling · **Severity:** medium · **Found:** 2026-08-18 by nettle12

`.gitignore` ignores `assets/audit/sheets/` with an explicit rationale: rendered PNGs are never
byte-identical between runs (F-042), so committing them would put a fresh multi-megabyte diff into
permanent history on every re-run, while the small structured reports beside them stay committed.

The rule is a literal path, so it only covers sheets written directly under `assets/audit/`. A-009
wrote its sheets to `assets/audit/a009/sheets/` instead — a per-audit subdirectory — and that path
matches nothing in `.gitignore`. 15 PNGs / 6.4 MB are currently untracked but stageable: any
`git add -A`, or any agent that stages broadly rather than by claim, commits them.

`agent ship` is not the exposure, because it stages only the claiming task's files. The exposure is
every other path into the index, and the fact that the next audit writing to `a010/sheets/` inherits
the same gap silently.

Fixed by matching sheets at any depth under `assets/audit/` rather than at one fixed level.

---

**Resolved 2026-08-18 by nettle12.** Fixed in `.gitignore` by matching sheets at any depth under `assets/audit/` —
`assets/audit/**/sheets/` — rather than the single literal `assets/audit/sheets/`. `**/` matches zero
or more directories, so the one rule now covers both the original top-level shape and the per-audit
subdirectories the audit tool actually writes.

Verified with `git check-ignore`, both directions: `assets/audit/a009/sheets/…png`, the top-level
`assets/audit/sheets/…png`, a hypothetical future `assets/audit/a010/sheets/…png` and a deeper nested
case are all ignored; `assets/audit/a009/geometry_report.json`, `assets/audit/geometry_report.jsonl`
and a hypothetical `a010/geometry_report.json` all stay tracked. `git ls-files -i -c` reports no
tracked file newly caught by the rule. The 6.4 MB of A-009 PNGs left `git status` as a result.

Note for whoever touches this next: three `*.import` files (`assets/audio/music/ambient_day.ogg.import`,
`ambient_night.ogg.import`, `icon.svg.import`) are tracked *and* ignored by the older `*.import` rule.
That predates this finding and is untouched here.

### F-142 · A quota park is counted as a lane failure, so three ordinary window resets in a row mark a healthy lane blocked — **fixed**

**Area:** tooling · **Severity:** low · **Found:** 2026-08-18 by bram1

`_apply_finish` incremented `failures` and `consecutive_failures` for every non-zero exit, including
the one that is not a failure at all: hitting a quota wall. The lane did the work asked of it, stopped
cleanly, released nothing, and will run again when its window rolls — that is the system working.

Two costs, one cosmetic and one not. The ledger misreports: LP read **40 runs / 5 fails** at a point
where nothing had actually failed, so the only honest signal of lane health was noise. And
`cmd_report` marks a lane blocked at `consecutive_failures >= 3` — so a lane that simply parked three
windows in a row, which is normal for a heavily-used subscription, would be reported as broken and
routed around. The failure mode is quiet and expensive: the director stops dispatching to a lane whose
only problem was that it was waiting.

**Fixed:** the two counters now increment only on a genuine error exit. A quota park sets `status`,
`exhausted_until` and `last_error` as before — the forensic record is unchanged — but does not count
against the lane. The `incomplete` case (exit 0 without closing out) still counts, because that one
really is a failure and three in a row really should trip the guard.

**Verified:** `lane selftest` 23/23; `agent lanes` renders both live lanes correctly; the existing
park record on LP is left as-is rather than rewritten, since the counter is a running tally and not a
claim about the current window.

---

### F-122 · `tools/flora_check.gd:126` measures rotated flora through the same inflated `Transform3D * AABB` ruler as F-108 — **fixed**

**Area:** tooling · **Severity:** low · **Found:** 2026-08-18 by lm, while closing F-108

F-108 fixed `tools/ship_check.gd`'s dimension check, which built a mesh's world-space bound as
`instance.transform * instance.get_aabb()` — an AABB is axis-aligned in the mesh's own local space, so
pushing one through a rotation returns the box around the rotated box, strictly larger than the true
extent. `tools/flora_check.gd:126` has the identical construction (`box = instance.transform * box`)
and measures the flora kit with the same wrong ruler. It has stayed green only because its tolerance
is 20 mm and it compares height alone (`_check_asset()`, line ~144), where the inflation happens to
stay under that threshold — it is not proof the measurement is correct, only that this kit's rotations
haven't yet been large enough to trip it.

**Fix, not done here:** it belongs to A-000V's file set, which this task had no claim on. Port
`ship_check.gd`'s `_check_asset()` vertex-measurement — walk `Mesh.ARRAY_VERTEX` per surface,
transform each vertex to the scene root, bound the points directly instead of the mesh's local
`get_aabb()` — into `flora_check.gd`'s `_check_asset()`. Expect the flora kit's reported heights to
move slightly (tighter, matching F-108's cone finding) when it lands, and confirm the 20 mm tolerance
still holds against the corrected numbers rather than assuming it does.

---

**Resolved 2026-08-18 by lm.** Ported ship_check.gd's vertex-measurement into flora_check.gd's `_check_asset()`: added
`_transform_to_root()` (identical to ship_check.gd's), replaced `box = instance.transform *
instance.get_aabb()` with a per-surface walk of `Mesh.ARRAY_VERTEX`, transforming each vertex to the
scene root and accumulating a min/max bound directly, instead of pushing the mesh's local AABB through
a rotation.

Verified 2026-08-18 (lm): `agent godot --script tools/flora_check.gd` -> `FLORA_IMPORT checked=84
triangles=30984`, `FLORA_CHECK_GODOT PASS` (all 84 flora exports, height within the 20 mm tolerance
against the corrected vertex-based numbers, not assumed).

Regression-proved the fix is a real change, not a no-op: temporarily reverted `_check_asset()` to the
naive `instance.transform * instance.get_aabb()` construction and reran -> also `FLORA_CHECK_GODOT
PASS`, confirming the finding's own claim that this kit's current rotations are not large enough to
trip the 20 mm tolerance either way. The vertex-based ruler is still the correct fix (F-108's cone
case shows the naive construction inflates by tens of mm once a rotation is steep enough); this kit
just hasn't authored one yet. Reverted the temporary edit and reran to confirm `git diff
tools/flora_check.gd` matches only the intended fix (`FLORA_CHECK_GODOT PASS` again).

Wrote the missing docs/SPECS.md block for F-122 (none existed), following F-108's shape as the
neighbouring precedent.

### F-036 · Task 2.9's gate cannot be met in its roadmap position — the enemy it tunes against lands in 2.10 — **resolved**

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

### F-134 · Hand-moving a finding to '## Resolved' eats the heading when it is the last entry under '## Open' — twice now, and the second time made all 121 resolved findings parse as open — **fixed**

**Area:** tooling · **Severity:** high · **Found:** 2026-08-18 by yarrow21

**It is not `agent finding`.** That command inserts correctly — it does
`text.replace("\n## Resolved\n", "\n" + entry + "## Resolved\n", 1)`, which preserves the heading. The
damage comes from the *other* half of a finding's life, which has no command at all: **moving a
resolved entry from `## Open` to `## Resolved`**. Every agent hand-rolls that with a script, and the
natural way to write it has a bug that only fires in one case.

The natural extraction is "from this finding's heading up to the next `### F-` heading". When the
finding being moved is the **last entry under `## Open`**, the next `### F-` heading is the first
entry *inside* `## Resolved` — so the slice swallows the `## Resolved` heading itself, and writing
the remainder back deletes it.

**Two incidents, both this shape:**

- `89fea39` (filing F-117) overwrote **F-112's heading**, orphaning its body. That silently closed
  F-112 through the sync rule, which is the whole of F-131.
- `9505cfd` (4.4 docs, lm) deleted the **`## Resolved` heading itself**. Every one of the 121
  resolved findings then parsed as open: `tools/findings_numbering_check.gd` went from
  `open=15 resolved=121 failures=0` to `open=136 resolved=0 failures=2`. Restored by hand in the
  commit that files this.

I hit the identical bug in my own F-131 script an hour earlier and only escaped it because my version
used `src.index(...)`, which *raised* when the anchor was missing, instead of `find(...)`, which
returns a bad offset and writes. That is luck, not skill, and it is not a basis for the next agent
avoiding it.

**Fix: `agent resolve <F-NNN>`, resolution note on stdin** — the mirror of `agent finding`, and the
same shape:

- bound the extraction at `min(next '### F-' heading, index of '## Resolved')`, never at the heading
  alone;
- append ` — **fixed**` to the title line, append the note to the body, splice it in directly after
  the `## Resolved` heading;
- refuse loudly if the finding is not under `## Open`, or if `## Resolved` is missing — a missing
  heading means the file is already damaged and the right move is to say so, not to append blindly;
- write through the same `.tmp` + `os.replace()` the filing path already uses.

Then `AGENTS.md`'s close-out rule ("closing one means the fix **and** moving its section to
`## Resolved`") names a command instead of describing an edit, and nobody writes the slice again.
`tools/findings_numbering_check.gd` already exists and is the acceptance test — it catches both
incidents — but it only runs when somebody thinks to run it, which neither offending commit did.

**Resolved 2026-08-18 by yarrow21.** `agent resolve <F-NNN>` now exists — the mirror of `agent finding`, with the resolution note on
stdin. It marks the title `**fixed**`, appends the note, and splices the section in under
`## Resolved`. **This entry was moved by the command itself**, and F-134 was the last entry under
`## Open` at the time — the exact case that broke both previous times.

The bug was never in `agent finding`, which inserts correctly. It was in the move, which had no
command, so every agent hand-rolled the slice. The fix is one line of intent: bound the extraction at
`min(next '### F-' heading, index of '## Resolved')`, never at the heading alone, and treat `find()`
returning -1 as "no later finding" rather than as an offset — a negative index silently slices from
the end, which is how a refusal becomes a write.

Everything else here is a refusal rather than a write: a finding already under `## Resolved`, an id
that is not in the file, a roadmap task id, an empty note, and — the important one — a file whose
`## Resolved` heading is *already* missing. That last case appends blindly under the old approach and
hides the damage; it now names the structure check and stops.

`AGENTS.md`'s close-out rule names the command instead of describing an edit.

**Verified:** `python3 tools/harness_check.py` → **20/20**, with two new cases — one moving the last
open entry and asserting both section headings survive (counting *headings*, not substrings: the
real file quotes "'## Open'" in prose, and a substring count reads that as a second heading), one
driving all five refusals and asserting the file is byte-identical afterwards. `--rev HEAD`
reproduces the pre-fix state at **18/20**. A third assertion catches the one defect this did ship on its first run — a doubled `---` where the moved entry's own separator met the previous entry's — found by reading the result on the real file, fixed, and now asserted. And on the real `docs/FINDINGS.md`:
`agent godot --script tools/findings_numbering_check.gd` → `open=13 resolved=124 failures=0` after
this move, against `open=14 resolved=123` before it.

### F-125 · Thin Step authors dodge_iframe_seconds, but D-072 left no i-frame timer for it to extend — **fixed**

**Area:** netcode · **Severity:** medium · **Found:** 2026-08-18 by wick20

Task 3.4 authored `content/powerups/thin_step.tres` (Void, `dodge_iframe_seconds` (0.04, 0),
max_stacks 3) because `dodge_iframe_seconds` is in `PowerupDef.KNOWN_STATS` and in POWERUPS.md §2's
pending table. The data is correct and validates. The problem is that there is nothing for it to
modify, and the reason is a decision made the same day.

**D-072 (task 3.8b) collapsed the i-frame window into the dash duration.** Its words: "The i-frame
window IS `dodge_duration_sec`, not a separate `dodge_iframe_sec` ... there is no state where the
flag is true without the dash also being in progress or vice versa." The replicated `dodging` bool
on the player's SceneReplicationConfig is the whole mechanism, and the host reads it in
`systems/health/player_health.gd` `_on_enemy_attack_landed()`.

So whoever routes `dodge_iframe_seconds` through `PowerupService.stat()` faces a choice that is a
design decision, not a wiring detail, and should not be made silently in a hurry:

1. **Feed it into `dodge_duration_sec`.** Cheapest, and keeps D-072's invariant exactly. But the
   stat then lengthens the dash *movement* too — at 3 stacks Thin Step adds 0.12s of travel, which
   changes where the player ends up, not only whether they were hit. That is a different powerup
   from the one the description promises.
2. **Decouple the two.** D-072 explicitly left room for this: "`_execute_dodge()` was kept a
   wrappable function precisely so that kind of change has somewhere to live." Costs a second
   timer and breaks the "flag true implies dash in progress" invariant, so the ALWAYS-replication
   reasoning in D-072 §2 has to be re-checked against the longer window (it gets safer, not
   riskier — a longer true-window is more likely to be observed, not less).

**Why this is filed rather than fixed:** 3.4 authors content, and POWERUPS.md is explicit that a
`pending` stat is correct data that waits for its system's own task. This is a note for that task,
so the choice above is made deliberately with D-072 in front of whoever makes it.

Nothing is broken today: the stat is inert until something reads it, exactly like the rest of the
pending table. Thin Step's description ("untouchable for the whole of the trip rather than most of
it") is written for option 2 and should be re-read if option 1 is chosen.

**Resolved 2026-08-18 by yarrow21 — option 2, decoupled.** The finding was right that this is a
design decision, not a wiring detail, and the authored content turned out to settle it: Thin Step's
own description promises *"untouchable for the whole of the trip rather than most of it"* — a claim
about invulnerability, not travel. Option 1 would have added 0.12 s of dash at 3 stacks and moved
where the player ends up. **D-087** records the call and its three consequences.

**What changed** (`entities/player/player_controller.gd`):

- `_iframe_time_remaining` is a second timer alongside `_dodge_time_remaining`. `_execute_dodge()`
  sets the dash window to `dodge_duration_sec` and the i-frame window to `dodge_duration_sec +
  PowerupService.local_stat(&"dodge_iframe_seconds", 0.0)`.
- `_apply_horizontal_movement()`'s dash branch now keys off `_dodge_time_remaining`, **not**
  `dodging`. This is the line that matters: leaving it on the flag would have made the i-frame stat
  silently lengthen the dash — shipping option 1 while claiming option 2.
- `dodging` clears with the *later* window, so it now means "invulnerable". D-072's invariant is
  relaxed in the direction D-072 itself called safe (a longer true-window is more likely to be
  observed, not less).
- The window is floored at `dodge_duration_sec` via `maxf`. A negative modifier must not undercut
  D-072's replication guarantee — that would produce intermittently *missing* i-frames, not shorter
  ones.

**Deliberately not done: renaming `dodging` to `invulnerable`.** The host reads the property by name
off the synchronizer, and its reader (`systems/health/player_health.gd` `_is_dodging()`) was held by
task 3.14 throughout. It is a pure rename with no wire-format change — the property name is already
the wire name — and worth doing whenever both files are free in one task. The flag's doc comment
states what it now means in the meantime. `_is_dodging()` was already asking the right question: it
exists to decide whether a hit should be ignored.

**No protocol bump** — same property, same slot, same `ALWAYS` mode; only its duration changed.
`core/net/net_version.gd` untouched.

**Verified**, all through `agent godot`:

- `tools/dodge_check.gd` → **0 failures**, with a new section that grants 3 real stacks of
  `content/powerups/thin_step.tres` (+0.120 s, read back off `PowerupService`) and asserts the pair
  that matters *at the same instant*: `dodging` still true past `dodge_duration_sec`, while
  `_dodge_time_remaining == 0` and horizontal speed has dropped below `dodge_impulse`. It calls
  `host_clear` afterwards so no later check inherits the powerup.
- **The new section was proved to catch the bug**, not merely to pass: reintroducing the old
  `if dodging:` movement branch fails it with `horizontal speed 10.00 m/s` — still dashing — then
  reverted and re-run green.
- No regressions: `tools/dodge_net_check.gd` (real two-process ENet) `failures=0`, including "the
  client's `dodging` flag replicates to the host over the real synchronizer wire";
  `tools/powerup_check.gd` `failures=0`; `tools/player_health_check.gd` 0 failures.

`docs/POWERUPS.md` moves `dodge_iframe_seconds` out of the "Pending systems" table into the wired
one, with its floor rule.


### F-131 · A finding auto-closed by the F-049 sync rule can never reopen, so a transient FINDINGS.md error permanently hides real work — F-112 and F-036 are both invisible to the board right now — **fixed**

**Area:** tooling · **Severity:** high · **Found:** 2026-08-18 by yarrow21

`agent start` has been printing "2 finding(s) closed but still under '## Open'" for a while, naming
**F-036** and **F-112**, and telling the reader to move each section to `## Resolved`. That advice is
wrong for both, because in both cases **the doc is right and `state.json` is wrong** — the opposite
of the drift direction F-071 was written for.

**F-112 — auto-closed by a rule, with no human or agent in the loop at all.** Its state entry is
`"status": "done"` with **no `done_at` and no `done_by`**: nobody ever ran `agent done F-112`. What
happened is in the journal (2026-08-18, `.agent/JOURNAL.md`): the commit that filed F-117 (`89fea39`)
accidentally overwrote F-112's `### F-112 ...` heading, orphaning its body. With the heading gone,
`_open_findings()` stopped seeing it, and the next `_sync_findings()` applied F-049's rule — "a
finding that has LEFT '## Open' while still marked todo gets marked done" — and closed it. A later
task restored the heading, so the doc has been correct ever since. The status has not, because
**`_sync_findings()` never downgrades a status**: the rule is one-way by design, so a transient
five-minute error in a markdown file became a permanent, silent state change with no way back.

**F-036 — `agent done` recorded a session, not a closure.** It has `done_at`/`done_by: lp`, but lp's
own journal entry for it says: *"F-036 intentionally stays Open in FINDINGS.md — closing it needs
Sequoyah's playtest verdict (D-039's canonical hand-off case), which no agent can substitute."* lp
did real work (wrote the missing `SPECS.md` block) and closed out the way the protocol tells you to;
there is no other verb for "I finished my session on this finding but it is not resolved" except
`agent handoff`, and the finding was not being handed off mid-work either.

**What it costs.** `board` lists findings from state, so both are in the Done row; `brief` lists them
from the doc, so both still read as claimable. A director routing work off the board — which
`ORCHESTRATION.md` says is how lanes get fed — will never dispatch either one. F-112 is a real
missing check (F-076's third system, never lifted). F-036 is the 2.9 combat-feel gate, which is one
of the few genuine Sequoyah hand-offs in the repo. Both are effectively deleted from the queue while
looking, on the board, like completed work.

**Fix, in two halves that match the two causes:**

1. **`_sync_findings()` heals the no-evidence case.** A finding under `## Open` whose state says
   `done` **but carries no `done_at`** was closed by inference, not by anyone — and the inference is
   now contradicted by the source of truth the same function already defers to. Restore it to
   `todo`. This can never resurrect a finding an agent actually closed, because a real `agent done`
   always stamps `done_at`. F-112 heals on the next sync with no human action.
2. **An explicit verb for the deliberate case.** `agent reopen <F-NNN> "why"` — journalled, so
   "this was marked done but is not resolved" is a recorded act rather than a hand-edit of
   `state.json`. F-036 needs this, and so does any future finding whose `agent done` meant "my
   session ended", not "this is fixed".

Then `_findings_drift()`'s warning should offer both actions instead of only "move it to Resolved",
since that is the wrong action in both cases it is currently firing on.

---

**Resolved 2026-08-18 by yarrow21.** Both halves shipped, and both live cases are cleared.

- `_sync_findings()` restores a finding to `todo` when it is under `## Open`, marked `done`, and
  carries **no `done_at`** — closed by the inference rule rather than by anyone. **F-112 healed on
  the very next sync with no human action**, verified before/after against the real `state.json`:
  `done` → `todo`, while `F-036` (which has a real `done_at`) was correctly left alone by the same
  pass.
- `agent reopen <id> "why"` for the case a tool cannot judge. **F-036 is reopened**, with lp's own
  journal quote as the reason, its `done_at`/`done_by` cleared and a `REOPEN` entry written.
- `_findings_drift()`'s warning now offers both actions instead of only "move it to Resolved" —
  which was the wrong advice on both findings it was firing on.

`agent start` no longer prints the drift warning at all, and **F-036 is back in the claimable list**
where a director can route it. D-082 records the rule and where its line sits.

**Verified:** `python3 tools/harness_check.py` → **18/18**, with two new cases; `--rev HEAD`
reproduces the pre-fix state at **16/18** — and the sync case fails there on its behavioural
assertion (the finding stays `done`), not merely on a missing subcommand.

**Two crashes found while testing, fixed in passing.** A task lacking `milestone` raised `KeyError`
in `_roadmap_progress()`, and one lacking `est`/`tier`/`title` raised it in `render_board()`. Both
run inside `save()`, so a single malformed task took down every command that writes state — `start`,
`board`, `claim`, `done`, `ship`. Both now read with `.get()` and sane defaults: a thin row gets
drawn instead of the harness falling over.

**Deliberately not changed:** F-071's decision that a `done_at`-stamped finding still open in the doc
is *printed*, not auto-resolved. A tool cannot tell which of the two records is wrong there, and
guessing would either resurrect finished work or bury a real hand-off.


### F-120 · AGENTS.md's own documented manual editor check misses a real launch shape (`-e <scene>`), reading a running editor as closed — **fixed**

**Area:** tooling/protocol · **Severity:** high · **Found:** 2026-08-18 by lp during 3.10

AGENTS.md's "Godot-authored files require a closed editor" section gives the by-hand check as
`pgrep -fl 'Godot.app.*--editor'` (mirrored in this task's own work order). During 3.10 that command
printed nothing — read as "editor not running" — while the editor was in fact open, launched as
`Godot --path <proj> -e res://levels/hollowmere.tscn`. Godot's `-e` is the short flag for `--editor`;
the process command line never contains the literal substring `--editor` when launched that way, so
the documented pgrep misses it. `agent autoload` caught this correctly (it refused, citing D-021) —
its own check must match on something other than the `--editor` substring — but the manual command
AGENTS.md tells an agent to run by hand does not, and a `.tscn`/`.tres`/`project.godot` edit made
after trusting that false negative is exactly the corruption D-031 exists to prevent (F-045 already
named the inverse trap — a raw `pgrep -fl Godot` overmatching the agent's own tooling — this is the
same root cause pointing the other way: pattern-matching a command line instead of asking the engine).

**Not fixed here:** no claim on AGENTS.md this task, and the safe subset (`agent godot`, `agent
autoload`, `agent claim` on Godot-authored files) already goes through the harness's own — apparently
correct — detection, so nothing shipped was at risk. What's open is the *documented by-hand fallback*
for an agent working without the harness's own gate, or double-checking it by eye. Fix is either a
better pattern (matching `-e |--editor` at minimum, though a positional scene argument after `-e`
could still slip past a naive grep) or, better, a small `agent editor-running` subcommand that reuses
whatever check `agent autoload`/the pre-commit hook already trusts, so there is exactly one
implementation instead of one correct one and one documented-wrong one.

**Resolved 2026-08-18 by yarrow21.** The finding proposed either a better pattern or "a small `agent
editor-running` subcommand that reuses whatever check `agent autoload`/the pre-commit hook already
trusts". It is the second, and the audit on the way there found the problem was wider than the
by-hand check: there were **four** implementations, not two, and `agent check` — the pre-commit
hook's own guard — was one of the blunt `pgrep -fl Godot` ones, as was `_stage_uid_sidecars`.
`_godot_running()` also had a false positive of its own that nobody had noticed: an
`agent godot --windowed` render check carries no `--headless` by design (F-077), so every render
check made `agent autoload` and `agent order` refuse while it ran.

Now: one classifier (`_godot_process_kind`), one predicate (`_godot_running`), and `agent
editor-running` so the documented check *is* the enforced one. `AGENTS.md` and `docs/AI-WORKFLOW.md`
name the command instead of a pgrep, and the order template `agent order` writes for the lanes does
too. Rationale and the classification rule are D-081.

**Verified:** `python3 tools/harness_check.py` → **16/16**, including two new cases; `--rev HEAD`
reproduces the pre-fix state at **14/16** (the old harness has no `_godot_process_kind` and no
`editor-running` command). The classifier is asserted against all four launch shapes plus four
non-engine lines, and against `ps` itself failing (it must answer "editor open", not "all clear" —
the old `_godot_running()` failed *open* there). Measured misreads, old vs new, are the table in
D-081: 2-of-2 missed editors for the documented pgrep, 2-of-2 false alarms for the blunt one, 0 for
the replacement.

**One thing this deliberately does not do:** the two `pgrep -fl Godot` mentions left in
`docs/DELEGATION.md` (lines ~2967, ~3414) are inside archived work-order prompts, under that file's
own archive disclaimer. They are history, not instructions.


### F-129 · Players spawn on top of each other: the spawn slot is a live child count, not a held claim — **fixed**

**Area:** net · **Severity:** high · **Found:** 2026-08-18 by pike14

Two players spawn at the identical point, putting the second one's first-person camera inside the
first one's body. The victim sees a full-screen dark quad — `DebugAvatarFace`'s `#182331` plate seen
from the inside — and reads it as "the renderer is broken". Reported 2026-08-18 by Sequoyah from a
live three-machine session, who isolated the trigger precisely: it depends on **which peer joins
first and which joins second**, and it reproduces on demand by having one client **leave the lobby
and rejoin**.

**Cause.** `autoload/player_net.gd:184`:

```gdscript
var slot: int = _players.get_child_count() % SPAWN_OFFSETS.size()
```

The slot is derived from how many players happen to be in the container *right now*. A child count
is not an identity — it is only accidentally unique, and it stops being unique the moment anyone
leaves. Walk it through: host takes slot 0, client A slot 1, client B slot 2. A leaves, so the count
falls to 2. A rejoins and computes `2 % 6` = **slot 2 — which B is standing on**. The file's own
comment above `SPAWN_OFFSETS` states the intent this defeats: "so six players do not spawn inside
one another."

There is a second, rarer path to the same collision: `_spawner.spawn()` adds the child, so two peers
admitted close enough together can both read the pre-increment count and both take the same slot.
That one is timing-dependent, which is why the bug looks intermittent and can appear "fixed" on a
retry — the leave/rejoin path, by contrast, is deterministic.

**Fix.** Hold the slot as a claim keyed by peer id: assign the lowest index not currently claimed,
and release it in `_despawn()`. Never derive placement from a mutable count.

**Diagnostic note worth keeping.** This presented as a *rendering* fault on the slowest machine, and
two plausible rendering explanations fit the evidence (a software D3D12 rasterizer, and the debug
face plate). Both were wrong. What identified it was Sequoyah's observation that the fault followed
join order rather than hardware — the Windows VM was blamed only because it was usually second.


**Resolved 2026-08-18 by pike14** (`48d6909`). `_claim_slot(peer_id)` hands out the lowest
SPAWN_OFFSETS index nobody currently holds and records it in `_slots`; `_despawn()` releases it.
Lowest-free rather than next-highest keeps a churning session reusing the tight cluster near the
level's spawn point instead of drifting outward, and makes the result depend only on who is present
— never on arrival order or on how many players have come and gone.

**Verified** by `tools/spawn_slot_check.gd`, which walks the exact sequence that broke it: join,
join, join, leave, rejoin. **The check was confirmed to fail against the old algorithm before it was
trusted to pass against the new one** — temporarily restoring the count-based expression produced
`FAIL a rejoining player does not land on a peer who stayed — rejoined into slot 2, but host=0 and
b=2 are still occupied`. A check that passes against both the bug and the fix proves nothing, and
this session had already produced one of those (see F-123's method note).

**Diagnostic lesson, which is the durable part.** This looked like a graphics bug and stayed looking
like one through two plausible and completely wrong explanations: the Windows VM runs on
`Microsoft Basic Render Driver` (software D3D12, confirmed in its log), and `DebugAvatarFace` really
is a dark plate. Both fit the evidence. Neither was the cause. The thing that identified it was a
behavioural observation — the fault followed **join order**, and reproduced on leave-and-rejoin —
rather than anything about the rendering. When a visual symptom correlates with a *sequence* instead
of with hardware, stop investigating the renderer.

---

### F-127 · Steam overlay's Join Game does nothing: only the lobby-invite callback is connected, not the rich-presence one — **fixed**

**Area:** net · **Severity:** high · **Found:** 2026-08-18 by pike14

Clicking **Join Game** in the Steam overlay does nothing at all — no log line, no join attempt.
Pasting the lobby id into the join field works, and the two clients then connect normally, so the
transport and the lobby are fine. Reported 2026-08-18 by Sequoyah from a live three-machine session,
immediately after F-123 made the friends-list entry appear in the first place.

**Cause.** GodotSteam exposes two different join callbacks and they are not interchangeable:

- `join_requested(lobby_id: int, steam_id: int)` — Steam's `GameLobbyJoinRequested_t`, raised for a
  direct **lobby invite**.
- `join_game_requested(user: int, connect: String)` — Steam's `GameRichPresenceJoinRequested_t`,
  raised when a friend is joinable via the **`connect` rich presence key**, carrying that key's raw
  string rather than a lobby id.

`_connect_steam_signals()` connected only the first. F-123 made the game publish `connect`, which is
what put a Join Game entry in the friends list — but clicking it raises the *second* callback, which
nothing listened to. So the feature became visible and non-functional in the same change. The two
signal names are similar enough that this reads as correct code, and it cannot fail in any headless
check because neither callback ever fires without a live friend clicking.

**Fix.** Connect `join_game_requested`, parse `+connect_lobby <id>` out of the connect string, and
route it into the same acceptance path as a lobby invite so the "never yank someone out of a running
game" rule cannot drift between the two entry points. Refuse an unparseable string rather than
guessing at a lobby id — a wrong id fails far more confusingly than no join.

**Check the round trip, not the parse.** The value published by `_advertise_joinable()` and the value
accepted by `_lobby_id_from_connect()` must agree; asserting them separately would let them drift.


**Resolved 2026-08-18 by pike14** (`48d6909`). `_connect_steam_signals()` now connects
`join_game_requested` alongside `join_requested`; `_on_join_game_requested()` parses the connect
string and hands off to `_accept_invite()`, which both join paths share so the "never yank someone
out of a running game" rule has exactly one home. `_lobby_id_from_connect()` returns 0 for anything
that is not `+connect_lobby <id>` rather than guessing.

**Verified** by `tools/rich_presence_check.gd`, which now asserts the **round trip** rather than the
halves: it feeds the parser exactly the string the advertiser publishes. Checking that
`_advertise_joinable()` emits the right format and that `_lobby_id_from_connect()` accepts the right
format, separately, is precisely the assertion shape that would let the two drift apart and
reintroduce this. It also asserts Steam still exposes *both* callbacks, since the two names differ by
one word and picking the wrong one is what caused this.

---

### F-005 · R2's chunk benchmark excludes GPU upload cost — **fixed**

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

**Resolved 2026-08-18 by lm (4.0a).** `tools/bench_chunk_gpu.gd` measures both costs on a real
renderer — the exact same 32 m/1 m-spacing/2048-tri chunk R2 built, this time with
`ConcavePolygonShape3D.set_faces()`, a real `MeshInstance3D` upload, and a shared-material bind
all timed on the main thread, plus a separate first-frame GPU-sync measurement for anything the
immediate calls don't capture (shader/pipeline compilation, deferred buffer upload).

**Verified:** `.agent/bin/agent godot --windowed --script tools/bench_chunk_gpu.gd` (Metal 4.0,
Apple M5 Pro), run twice — 60 chunks, 0 `ERROR:` lines both times. Result **inverts** the risk
this finding was filed for: GPU upload (0.013–0.020 ms/chunk) and material bind (~0.001 ms/chunk)
are both cheap. **Collision cooking is the real cost, at 1.15–1.48 ms/chunk mean** across the two
runs (worst single chunk 3.9 ms) — ~4–4.5× R2's own mesh-build number. Steady-state main-thread
cost per streamed-in chunk: **1.17–1.50 ms**. Full numbers, the per-frame chunk budget
(2.7–3.4 chunks in a 4 ms streaming slice), and what it means for 4.3 are in `DECISIONS.md` D-074.

---

### F-124 · macOS builds cannot show the Steam overlay: hardened runtime without the dyld entitlement blocks injection — **fixed**

**Area:** build · **Severity:** high · **Found:** 2026-08-18 by pike14

The Steam overlay never appears in a macOS build, however the game is launched from Steam, and
re-binding the overlay hotkey changes nothing. Reported 2026-08-18 by Sequoyah, who had tried
Shift+Q as an alternative binding.

**Cause.** Steam's macOS overlay works by injecting `gameoverlayrenderer.dylib` through
`DYLD_INSERT_LIBRARIES`. macOS strips all `DYLD_*` variables from the environment of a binary signed
with the hardened runtime unless it carries
`com.apple.security.cs.allow-dyld-environment-variables`. Our build is signed exactly that way —
`codesign -dv` reports `flags=0x10002(adhoc,runtime)` — and `codesign -d --entitlements` shows only
`com.apple.security.cs.disable-library-validation`, which Godot adds by itself for ad-hoc signing.

So the overlay library is never loaded into the process at all. No hotkey can open a thing that was
never injected, which is why re-binding produced no result and why the failure looks like a broken
keybind rather than a signing problem.

**Fix.** In the macOS export preset set both
`codesign/entitlements/allow_dyld_environment_variables=true` and
`codesign/entitlements/disable_library_validation=true` (the latter explicitly rather than relying on
Godot's automatic fixup). Verify with `codesign -d --entitlements - export/macos/MIRE.app`: both keys
must be present before any overlay behaviour is worth testing.

**Wider consequence.** Anything routed through the overlay is dead on macOS until this lands —
`SteamLobby.open_invite_overlay()` is the invite UI the project deliberately chose not to rebuild, so
macOS currently has no working invite path at all. Any macOS result in a Steam test taken before this
fix should be treated as untested rather than passing.


**Resolved 2026-08-18 by pike14** (`1754bd1`). The macOS preset now sets
`codesign/entitlements/allow_dyld_environment_variables=true` and
`codesign/entitlements/disable_library_validation=true`.

**Verified** on the rebuilt bundle: `codesign -d --entitlements - export/macos/MIRE.app` now lists
both `com.apple.security.cs.allow-dyld-environment-variables` and
`com.apple.security.cs.disable-library-validation`, where before it listed only the latter. Signing
flags are unchanged at `0x10002(adhoc,runtime)` — the hardened runtime is still on, which is correct;
the entitlement is what makes `DYLD_INSERT_LIBRARIES` survive it rather than turning the protection
off.

**What this does not prove.** The entitlement makes injection *possible*; that the overlay actually
draws still needs one human launch through Steam, because a headless run has no renderer for it to
draw into. The diagnosis is nonetheless certain rather than probable: with `DYLD_*` stripped, the
overlay library was never loaded into the process, which is exactly why re-binding the hotkey (to
Shift+Q, in the report) produced no effect at all — a missing overlay and a broken keybind look
identical from the outside, and only the former ignores every possible binding.

---

### F-123 · Friends list offers no Join Game: the lobby is never advertised via the 'connect' rich presence key — **fixed**

**Area:** net · **Severity:** high · **Found:** 2026-08-18 by pike14

A friend running MIRE shows as **In Game** in the Steam friends list, but right-clicking them
offers only *Invite to Watch* — there is no **Join Game**. Observed 2026-08-18 on the Windows VM
with a live host lobby, screenshotted by Sequoyah.

**Cause.** Steam decides a friend is joinable purely from the `connect` rich presence key. If it is
unset, Steam knows the player is in the game but has no way to put anyone else into their session,
so it hides Join Game and degrades the menu to Invite to Watch. `grep` across the project for
`setRichPresence` returns nothing: the key is never set, in any code path.

The asymmetry is what makes this easy to miss. The *receiving* half is fully built —
`core/net/net_config.gd` defines `STEAM_CONNECT_LOBBY_ARG = "+connect_lobby"` and
`autoload/steam_lobby.gd` `_check_launch_invite()` parses it off the command line for a cold start,
with `_on_join_requested()` handling the running-game case. So the game correctly *accepts* a join
it never *advertises*. Every invite path that works today (`open_invite_overlay`, `invite_user`)
works because it names the lobby explicitly; only the friends-list path depends on rich presence.

**Fix.** Set `connect` to `+connect_lobby <lobby_id>` whenever `_lobby_id` becomes non-zero — in
both `_on_lobby_created()` and `_on_lobby_joined()`, so a joiner is joinable too and a third player
can come in through either of the first two — and clear it in `_leave_lobby()` so a friend who has
quit does not advertise a dead lobby.

**Note for the Steam test.** This is a prerequisite for the friends-list half of task 1.12. It does
not affect the invite-overlay path, which is why the earlier LAN and lobby runs passed without it.


**Resolved 2026-08-18 by pike14** (`1754bd1`). `SteamLobby._advertise_joinable()` sets `connect` to
`+connect_lobby <lobby_id>` in both `_on_lobby_created()` and `_on_lobby_joined()`, and
`_clear_joinable()` clears it in `_leave_lobby()`. Advertising on join as well as create is
deliberate: it makes a joiner joinable too, so a third player can arrive through either of the first
two rather than only through the original host.

**Verified** by `tools/rich_presence_check.gd`, added with the fix. It asserts the things that
otherwise only fail in a live session with a friend watching: that GodotSteam still exposes
`setRichPresence` under exactly that name, that the advertise/clear/parse trio all exist, and that
the advertised argument still matches `NetConfig.STEAM_CONNECT_LOBBY_ARG` — the two halves must not
drift, or an accepted invite cold-starts the game with an argument it does not recognise. All six
assertions pass.

**Method note worth keeping.** The check asserts against the *live* `SteamLobby` autoload, not the
script object. `load("res://autoload/steam_lobby.gd").get_script_method_list()` reports only
`_ready`, and `has_method()` on a bare `.new()` instance returns false even for long-standing
methods such as `_check_launch_invite`. A reflection-based assertion therefore fails identically
whether the code is present or absent — it looks like a working check and proves nothing. The first
draft of this check did exactly that and reported three false failures.

---

### F-109 · The all-sides audit's inside-out test cannot judge an open sheet, and this is the first batch made of them — **fixed**

**Area:** tooling · **Severity:** low · **Found:** 2026-08-18 by ivy8

`tools/blender/audit_all_sides.py` detected inverted normals by the divergence theorem: sum
`(n · c) * area` over an object, positive when a closed shell faces outward. For a closed low-poly
solid that works. A-009 is the first batch whose assets are largely **open** surfaces — a hull is a
planked shell, a sail is a thin panel, a cap rail is a ribbon — and for those the sum has no enclosed
volume to measure; it is dominated by where the sheet sits relative to the world origin instead. A
bottom-strake patch board with a correct downward normal and a positive z centre scored negative and
read as a defect; a genuinely inverted sheet on the far side of the origin would score positive and
read as fine. On the finished, verified A-009 set the metric reported 96 correct `panel()`/`ribbon()`
back, rim and underside faces on `ship_hull_repaired` alone as "inside out" (94 on an earlier
snapshot, per the original finding).

**Fixed** by teaching the audit to recognize which of its own objects it can actually judge, rather
than leaving that job to the generator alone. `is_closed_shell(bm)` welds vertices by position (the
same rounding key the duplicate-vertex count already used — every mesh here is unwelded face soup,
which defeats bmesh's own `edge.is_manifold` regardless of whether the surface is a closed shell or a
flat sheet) and checks that every welded edge borders exactly two faces. `geometry_report()` now runs
the signed-volume test only on objects that pass that check, and reports everything else under a new
`open_surface_objects` key instead of `inside_out_objects` — so the number a human reads as a defect
count no longer includes objects the test was never able to judge. The generator-side proof
(`WINDING_LOG` in `build_extraction_ship_set.py`) is still what actually judges an open sheet's
winding and is unchanged; this fix stops the audit from contradicting it.

**Verified 2026-08-18 (lm):** `/Applications/Blender.app/Contents/MacOS/Blender --background --python
tools/blender/audit_all_sides_check.py` → `AUDIT_ALL_SIDES_CHECK PASS`, six assertions covering the
exact false-positive shape from the finding (a downward-facing plank at positive z), a correctly-wound
closed cube (unflagged either way), and a genuinely inverted closed cube (still caught) — reverting
`audit_all_sides.py` to HEAD makes the check fail on import, confirming it actually exercises the fix.
Re-ran the real instrument against the shipped A-009 batch (`--only ships/exports`): `inside_out_objects`
is 0 across all fifteen exports, down from 96 on `ship_hull_repaired` alone; the 504 sheet-back/rim/
underside faces the old test misread now land in `open_surface_objects`. Full detail and the exact
numbers: `docs/SPECS.md`'s F-109 block.

### F-110 · `audit_all_sides.py` silently resumes, so a re-run after fixing an asset re-reports the old defect — **fixed**

**Area:** tooling · **Severity:** medium · **Found:** 2026-08-18 by ivy8

The audit's resume ledger (`geometry_report.jsonl`) keyed on the asset's repo-relative path, so a
second run with the same `--outdir` skipped every asset already recorded regardless of whether the
GLB at that path still matched what was recorded. During A-009 that produced a full contact-sheet
report describing geometry that had been fixed and re-exported minutes earlier — including an
inverted transom that the rebuild had already corrected. Nothing warned; the run simply finished
fast, because from the ledger's point of view every asset was already done.

**Fixed** by teaching the ledger to record the GLB's mtime, not just its path. Every entry now carries
`_source_mtime` (the GLB's `os.stat().st_mtime` at render time), and the new `pending_glbs()` — pulled
out of `main()` so it's directly testable — treats an asset as pending again whenever its current
mtime disagrees with the mtime its ledger entry was recorded under, same as one never audited. A
re-export into the same path now gets re-rendered on the very next run, and the run prints which
paths it's re-rendering and why. mtime, not a content hash, per the finding's own two suggested fixes
— every asset in this pipeline is a fresh Blender export whose mtime always moves on a real
re-export, so a hash would only earn its cost against a rewrite that happened to be byte-identical,
which nothing here does.

**Verified 2026-08-18 (lm):** `/Applications/Blender.app/Contents/MacOS/Blender --background --python
tools/blender/audit_all_sides_check.py` → `AUDIT_ALL_SIDES_CHECK PASS`, F-109's six assertions plus
seven new ones built against real temp files (mtime needs a real filesystem): an unrecorded asset is
pending, a recorded-and-unchanged one is skipped, a recorded asset whose mtime moved is pending again
and is the one flagged as a stale re-render, and a re-recorded entry round-trips its mtime exactly
through JSON. Real end-to-end proof against a shipped asset with a scratch `--outdir`: run 1 renders
`ship_departure_bell.glb`; run 2 resumes and re-renders nothing; `touch`ing the GLB (mtime only — `git
status --porcelain` stayed clean, confirming no content change) and running a third time re-renders
exactly that one asset and prints `1 asset(s) changed since their last audit; re-rendering:
ships/exports/ship_departure_bell.glb` — the finding's exact failure mode, now caught instead of
silent. Full detail: `docs/SPECS.md`'s F-110 block.

### F-121 · Exported builds load zero content: .tres scan misses Godot's .remap suffix — **fixed**

**Area:** content · **Severity:** high · **Found:** 2026-08-18 by pike14

Every exported build — macOS, Windows and Linux — boots with **no content at all**: zero items,
recipes, stations, weapons, loot tables, powerups, buildables, haulables and enemies. Source runs of
the same commit load 23 items, 13 recipes and 1 enemy, so `verify_setup` and every headless check
pass while the shipped artifact is empty. This was found on 2026-08-18 by exporting all three
platforms from `764a8e1` and smoke-running each on its native OS.

**Cause.** Godot converts text resources to binary during export. `res://content/items/arrow.tres`
is packed as `arrow.tres.remap` (a stub pointing at the binary payload); the literal `arrow.tres`
entry is gone. Both runtime directory scans filter on the raw extension:

- `autoload/registry.gd` `_tres_files_in()` — `file_name.ends_with(".tres")`
- `autoload/enemy_world.gd` `_load_defs()` — `file_name.ends_with(".tres")`

`DirAccess.open()` succeeds and `list_dir` returns the packed names, so nothing errors — the filter
simply matches zero files and the loaders report a clean "loaded 0". The absence of any error is why
this survived: the failure looks exactly like an empty content directory.

**Fix.** Strip a trailing `.remap` from each listed name before the extension test, and pass the
de-remapped `.tres` path to `load()`, which resolves the remap itself. One source run and one
exported run must both be checked from now on; a source-only check cannot see this class of defect.

**Wider risk.** Any other runtime `DirAccess` scan that filters on `.tres`, `.tscn`, `.gd` or `.res`
has the same latent bug. These two were the only content scans at the time of filing, but the
pattern is the thing to grep for before shipping.


**Resolved 2026-08-18 by pike14** (`1a11541`, half in `8ab5e38`). Both scans now strip a trailing
`.remap` before the extension test and hand `load()` the original `.tres` path:

- `autoload/enemy_world.gd` `_load_defs()`
- `autoload/registry.gd` `_tres_files_in()` — this one additionally de-duplicates, so a directory
  that somehow held both `x.tres` and `x.tres.remap` cannot yield the same def twice.

**How it was verified — a source run cannot see this defect, so both halves were checked.** The two
fixes were landed separately and the export re-run between them, which isolated the cause rather
than assuming it: with only `enemy_world.gd` patched, a re-exported macOS build went from
`loaded 0 enemy definition(s)` to `loaded 1` while items stayed at `0`, confirming the `.remap`
mechanism and pinning the remainder to `registry.gd`. After both, all three platforms were
re-exported and smoke-run **on their native OS** — macOS on the host, Windows on `192.168.50.47`,
Linux on `192.168.50.124` — and each reported the identical
`23 item(s), 13 recipe(s), 2 station(s), 9 weapon(s), 1 loot table(s), 5 powerup(s), 2 buildable(s),
1 haulable(s), 4 attunement(s)` and `1 enemy definition(s)` that a source run reports. The Windows
build's `Harvestable references unknown yield item` error spam disappeared with it. `verify_setup`
stayed green throughout, which is precisely the point: it was green while the bug shipped.

**Standing consequence.** Green headless checks are not evidence that the shipped artifact works.
Any change to content loading, or to any runtime `DirAccess` scan filtering on `.tres`/`.tscn`/`.gd`/
`.res`, needs one exported-build smoke run as well as a source run.

---

### F-119 · `agent godot`'s own `--import` pre-pass logs two UNDECLARED `ERROR:` lines on every single invocation — **fixed**

**Area:** tooling · **Severity:** low · **Found:** 2026-08-18 by lp during F-103 ·
**Resolved:** 2026-08-18 by lp.

F-093's fix made every `agent godot <...>` call run a `--headless --import` pass before the caller's
own run. That pre-pass itself emitted, every time, on this machine:

```
ERROR: Couldn't open external text editor, falling back to the internal editor. Review your `text_editor/external/` editor settings.
   at: edit (editor/script/script_editor_plugin.cpp:2229)
```

twice, during `loading_editor_layout` — before the caller's own `--script`/`--quit-after` section
starts. SPECS.md's standing rule 4 (F-021) says to grep every check run for `ERROR:` and treat any
undeclared line as failure; taken literally, this made every check on this machine fail that rule,
because the line was emitted by the shared pre-pass rather than by the check's own script and nobody
had been grepping that section. Spotted while verifying F-103's check — its own `--script` section
was clean, only the pre-pass emitted the lines, which is presumably why this had gone unnoticed: an
agent greps the run after the point it prints its own `PASS`/`FAIL` lines, not the boot before it.

**Root cause:** not repo state at all — the shared per-user editor settings,
`~/Library/Application Support/Godot/editor_settings-4.7.tres`, had
`text_editor/external/use_external_editor = true` with an empty `text_editor/external/exec_path`.
`loading_editor_layout`'s "Reopening scenes..." step tries to reopen every script the last real
editor session had open, through the external editor if one is configured; an empty `exec_path`
means that open always fails, twice (two scripts were open in the last saved layout), and it falls
back to the internal editor rather than actually failing the boot — hence no non-zero exit, only the
two `ERROR:` lines.

**Fixed 2026-08-18 by lp.** Flipped `text_editor/external/use_external_editor` to `false` in that
`.tres`. No `exec_path` was ever configured, so the external-editor path was dead weight, not a
feature in use — nothing on this machine relies on it. This is a per-user global file, outside the
repo entirely (not under `.godot/`, which is project-local and per-clone); the fix does not travel
with `git clone` and is scoped to this machine only, same as the pre-pass boot it silences.

**Verified 2026-08-18:** `tools/godot_prepass_check.py` (new — plain Python, no fake-godot double,
since the bug lives in real per-user state a double can't reproduce) runs
`.agent/bin/agent godot --import` for real and fails on any `ERROR:` line in its output:

```
python3 tools/godot_prepass_check.py
GODOT_PREPASS_CHECK ok (0 ERROR: lines from `agent godot --import`)
```

Confirmed the check is a real regression guard, not a vacuous pass: flipped
`use_external_editor` back to `true` and reran — `GODOT_PREPASS_CHECK FAIL (2 undeclared ERROR:
line(s))`, both lines the exact ones this finding describes — then flipped it back to `false` and
confirmed green again. Full spec: `docs/SPECS.md` F-119.

### F-117 · F-072's docs-file claim enforcement blocks the second lane's commit, but the first lane's `ship` still sweeps the second lane's uncommitted edits into its own commit — **fixed**

**Area:** tooling · **Severity:** medium · **Found:** 2026-08-18 by lp while closing F-094 ·
**Resolved:** 2026-08-18 by lp.

F-072 made `agent check` enforce an exact claim on a `docs/` path once one exists (`agent claim` had
always accepted the claim; enforcement was the part that was missing). It does fix what it says it
fixes — a lane without the claim is correctly refused at commit time rather than waved through
silently. It does not fix the collision it looks like it fixes, because the two docs files every
finding-closing task needs — `docs/FINDINGS.md` and `docs/SPECS.md` — are the ones a task most often
claims explicitly (to get F-072's protection while it writes them), and this repo runs every lane in
**one shared working directory** (F-102), not separate worktrees.

Sequence observed: F-093 (`lm`) claimed `docs/FINDINGS.md` and `docs/SPECS.md` as part of its file
set. While that claim was held, F-094 (`lp`, this task) edited both files in the same working tree —
legal, since docs edits need no claim to *write*, only to *commit* (F-006/F-072) — and then could not
commit them: `agent check` correctly refused, naming `lm`'s claim. Waiting the ~100 seconds for `lm`'s
claim to release (foreground poll, not backgrounded) and then re-checking found the F-094 content
already on `origin/main` — inside `lm`'s own F-093 commit (`e9c232b`). `agent ship F-093` staged the
files *that task's claim named*, which is exactly what `ship` is documented to do, and at the moment
it ran the working tree's copy of both files held F-094's uncommitted prose alongside F-093's. `ship`
has no way to know a hunk in a file it legitimately claimed was authored by a different lane's
different task; it isn't `git add -A` and did nothing the harness tells it not to do.

The content itself survived intact and correctly placed (verified: exactly one `### F-094` heading,
`tools/findings_numbering_check.gd` reports `failures=0` against the merged result) — this is a
misattribution risk, not a data-loss one, and less severe than F-102's finding, where the alternative
was uncommitted work staying invisible. But it means an explicit claim on `docs/FINDINGS.md` or
`docs/SPECS.md` buys the claiming task nothing against *this* failure mode, only against a lane with no
claim at all — the two lanes most likely to collide (both closing out a finding at the same time) are
exactly the two an explicit claim cannot separate, because both legitimately need to write the same two
files and only one of them can hold the claim.

**Fixed 2026-08-18 by lp**, per **D-067**: `_release()` (fires on `done`/`handoff`/`drop`) now
snapshots a sha256 of each released file's bytes into `recent[f]["hash"]`. `ship` recomputes the hash
of every file it is about to stage and, when the file's most recent releasing task was this one but
its current bytes no longer match that snapshot, prints a non-blocking warning naming the file(s) and
suggesting `git diff -- <files>` before trusting the commit's attribution — the F-102 migration
(generated `docs/FINDINGS.md`) would remove the collision outright but is a bigger call than one task
should make unilaterally; see D-067 for why the cheaper heuristic was picked over the finding's own
claim-time/hunk-range sketch.

**Verified 2026-08-18:** `python3 tools/harness_check.py` — 14/14 cases pass, including two new ones
(`ship warns when a claimed file drifted after done() (F-117)`, `ship stays quiet when a claimed
file's hash matches its done()-time snapshot`). Confirmed the new case is a real regression guard, not
a vacuous pass: `python3 tools/harness_check.py --rev HEAD` (pre-fix harness) fails exactly that one
case, 13/14. No Godot involved — this is pure Python harness logic, nothing it touches loads through
the engine.

Also found while in this file: the `### F-112` heading had been overwritten by an earlier hand-edit
that filed this finding (commit `89fea39`) — it replaced the `### F-112` heading line instead of
inserting `### F-117` above it, leaving F-112's own body (referenced by name from `docs/SPECS.md`,
`docs/DELEGATION.md`, and F-076's own entry below) as an orphaned, unheaded tail with no F-number of
its own. Restored the `### F-112` heading; F-112 itself is unrelated to this finding and still open.

### F-042 · Rendered PNGs can never be byte-identical, so every rebuild reads as a broken one — **fixed**

**Area:** asset pipeline · **Severity:** low · **Found:** 2026-08-17 by reed16 during 2.1d (A-021S) ·
**Resolved:** 2026-08-18 by lp.

Blender writes non-deterministic metadata into every PNG it renders: `RenderTime` and `Date` `tEXt`
chunks from EEVEE, `cycles.ViewLayer.total_time` from Cycles. The pixels are reproducible; the files
are not, and never can be.

The concrete failure is a false alarm that costs a session. A-021S added one icon to
`render_item_icons.py`, which re-renders all of them, and `git status` came back with all 24
pre-existing icons modified — against A-042a's recorded evidence that "two rebuilds [were]
pixel-identical on every channel". Decompressing the `IDAT` chunks showed 24/24 pixel-identical and
zero changed. An agent reading only the file hashes concludes the icon pipeline lost determinism and
goes looking for a bug that is not there, or commits 24 meaningless binary diffs.

Second-order, and separate: EEVEE also jitters anti-aliasing on thin diagonal silhouettes between
runs — the same instability that moved the icons to Cycles in A-042a. A-021S's viewmodel preview
differed by 9 bytes in 4,992,780 with a maximum delta of 3/255, which is the noise floor rather than
a rebuild that changed. The world and scale previews were exactly pixel-identical, so this only bites
frames full of near-diagonal edges. Left as documented, accepted behaviour — not a fix target.

**Fixed 2026-08-18 by lp.** Both halves of the finding's recommended fix already existed before this
task: the habit (compare rendered PNGs by decoded pixels, never file hash) was already written into
`docs/ASSET_TRACKER.md`'s verification contract, and the tool the finding asked for if this recurred,
`tools/png_pixels_equal.py`, was already built by **F-079** — this task's own contribution is the
missing `docs/SPECS.md` block, pointing the contract at the tool by name instead of describing manual
`IDAT` decompression, and closing this section.

**Verified 2026-08-18:** reproduced the exact original scenario against the live pipeline, not just
F-079's synthetic unit test — re-ran `Blender --background --python tools/blender/render_item_icons.py`
unchanged (26 icons at the current `SOURCES` count, grown from 24 since this finding was filed).
`item_icons_sheet.png` hashed identical; all 26 individual `assets/icons/exports/*.png` came back
file-modified per `git status`. `tools/png_pixels_equal.py` against each file's HEAD copy: 26/26
`identical`, 0 real pixel changes — the false alarm this finding describes, confirmed still false.
Working tree restored (`git checkout -- assets/icons/exports/`) rather than committing the churn.
`python3 tools/png_pixels_equal_check.py` → `PNG_PIXELS_EQUAL_CHECK ok`. Full spec: `docs/SPECS.md`
F-042.

### F-118 · The forest has no ambient life: nothing falls, drifts or settles, so a still frame of the map is a still frame — **fixed**

**Area:** environment · **Severity:** low · **Found:** 2026-08-18 by vane19

Playtest, 2026-08-18 (Sequoyah): "ambient particles would be nice too kind of simulate leaves coming
off the trees".

`world/environment/asset_vfx_library.gd` already animates every plant on the map — `Sway.CANOPY`
drifts the crowns, `GROUND_COVER` rustles the grass — and `EnvironmentVfx` already runs a budgeted,
distance-sorted emitter pool for campfires, forges, crystals and spore motes. What none of it does is
put anything **in the air between** those things. Stand still in the Hollowmere woods and the only
motion is the sway shader; there is nothing falling, nothing catching the light, nothing to make a
held frame read as a living place rather than a diorama.

The seam for it already exists and is the right one: `AssetVfx.Emitter` + `EMITTER_PROFILES`
(`max_live`, `shadow_live`, `radius`, scaled by the graphics preset) + `EnvironmentVfx._make_effect()`,
keyed by asset id so a generated world inherits it (F-097). A canopy asset should carry a leaf-fall
emitter the same way a campfire carries firelight — bound to the asset, never to a scene or a map,
because release worlds are procedurally generated and there is no level author to place an emitter.

Constraints this has to respect:

- **Budgeted like every other emitter.** Hollowmere holds 62 wild trees, 44 harvest trees and 7
  broadleaf trees; that is not a number of particle systems you can run at once on the machine this
  game targets. Nearest-N only, scaled down by the `low` preset like the rest.
- **No lights and no shadows.** Falling leaves are the cheapest kind of emitter there is; adding
  either would put this in the same cost class as a campfire for none of the payoff.
- The existing `Emitter.SPORE` (mire tendrils, drifting motes, no light) is the closest worked
  example to copy.

**Fixed 2026-08-18 by vane19.** `AssetVfx.Emitter.LEAF_FALL`, bound to canopy assets and budgeted
like every other emitter class.

- **`EMITTER_RULES` gained six rows, three of which are `Emitter.NONE`.** `tree_snag` and
  `tree_bare` (dead and winter timber), and `harvest_tree_`'s stumps and felled trunk, shed nothing
  — and because matching is longest-prefix-first-wins, those exclusions have to come *before*
  `tree_` or a dead snag drops leaves.
- **`_leaf_fall()`**: twelve leaves per crown, seven-second lifetime, gravity of `(0.22, -0.85, 0.13)`
  so they slip sideways rather than plummet, and a slow tumble — the one thing leaves read wrong
  without. Shape 3 in `particle_billboard.gdshader` is a new pointed ellipse with a darker midrib,
  and it is the first shape there with **no emission**: a self-lit leaf is a firefly.
- **Twelve live at a time**, nearest first, no light and no shadow. Hollowmere holds 94 canopies and
  a generated forest could hold thousands; the budget is what makes the class affordable, not the
  per-emitter cost.

**Two bugs this uncovered in the existing VFX registration, both fixed here:**

1. **`EnvironmentVfx` hid every tree it registered.** `_register_emitter`'s non-batched branch set
   `node.visible = false` for any emitter that was not `GLOW`, on the assumption that a
   non-instanced emitter is a hand-authored placeholder mesh to be replaced. That is true of exactly
   two assets, so `AssetVfxLibrary.replaces_host_mesh()` now names them (`flame_outer`,
   `furnace_fire`) and everything else is decorated rather than replaced. Since F-114 made every
   harvestable tree a node of its own rather than a MultiMesh slot, the old assumption would have
   deleted 94 trees the moment they registered.
2. **One emitter site per MESH PART, not per prop.** A GLB canopy arrives as around forty separate
   `MeshInstance3D` nodes; each resolved the same asset id from the holder above it, and each sat
   far enough from its siblings to survive the site-merge test — **1,925 leaf sites for 94 trees**,
   after which the O(n²) merge loop compared 1.8 million pairs at load. `_emitter_host()` now walks
   up to the ancestor carrying the asset id and takes one site from it. Total emitter sites on
   Hollowmere fell from 2,194 to **363**, which speeds up the crystal and spore classes too.

**Follow-up, deliberately not done here:** `particle_billboard.gdshader` is `render_mode unshaded`,
so a leaf is as bright at midnight as at noon. It is muted enough not to read as a bug, and fixing
it properly means a second shader or a tint driven from the atmosphere — worth doing when something
else needs a lit particle.

**Verified:** `agent godot --script tools/environment_vfx_hollowmere_check.gd` → `failures=0`, with
two new assertions that pin the site count to trees rather than to mesh parts (`leaf_sites > 40` and
`< 200`; actual **94**), and its budget ceiling now derived from `EMITTER_PROFILES` instead of a
hardcoded 32 that adding a class was always going to break. `environment_vfx_check`,
`ground_fog_check`, `atmosphere_night_check` all `failures=0`.
`tools/atmosphere_look_shot.gd --windowed` renders two close canopy framings; the leaves are visible
and deliberately sparse.

---

### F-103 · MultiMesh instance transforms are write-only under `--headless`, so anything that reads them back silently gets the origin — **fixed**

**Area:** tooling/rendering · **Severity:** high · **Found:** 2026-08-18 by larch10 during F-097

`MultiMesh` instance transforms live in the RenderingServer, not in the resource. Under
`--headless` — which is *every* way an agent can verify anything (F-077) — the dummy driver stores
nothing, so `multimesh.buffer` is empty and `get_instance_transform(i)` returns `Transform3D()` for
every `i`, however many were written. There is no error and no warning.

Minimal reproduction, via `agent godot --script`:

```
multimesh.transform_format = MultiMesh.TRANSFORM_3D
multimesh.mesh = BoxMesh.new()
multimesh.instance_count = 3
set_instance_transform(i, Transform3D(Basis.IDENTITY, Vector3(i * 10, 0, 0)))
->  READBACK 0/1/2 all (0.0, 0.0, 0.0);  buffer size = 0
```

The failure mode is nastier than a crash. F-097's first implementation read emitter positions back
out of the prop batches to place firelight; every one of Hollowmere's 99 mire crystals, 163 tendrils
and 5 fires collapsed onto a single point at the world origin, and the check *passed* — one site per
class is still ≥ 1. A count-based assertion cannot see this. It was only caught by asserting the
number of sites against what the layout file actually holds.

**Consequences.** Never read placement back from a MultiMesh. The system that wrote the transforms
already has them, so it should publish them: `world/gen/authored_world.gd` and
`world/gen/undergrowth.gd` now stamp a `placements` PackedVector3Array on the holder for any asset
whose presentation is per-copy, and `EnvironmentVfx` reads that instead. Any check that walks
MultiMesh transforms is measuring nothing, and any check whose assertion is satisfied by the number
1 cannot distinguish "found everything" from "found one".

**Fixed 2026-08-18, already shipped inside F-097 (`4919d26`)** — the `placements`-meta publish
described above, plus `tools/multimesh_readback_check.gd` as the regression guard. This task (lp) was
the missing piece: no `docs/SPECS.md` block existed for F-103 and the finding itself was never moved
here, so the board still listed it `todo` even though the code fix was on disk. Closed by writing the
spec block (`docs/SPECS.md`, next to F-107) and re-running the check clean:

```
agent godot --script tools/multimesh_readback_check.gd
MULTIMESH_READBACK distinct_origins=1 buffer=0
PASS: headless MultiMesh readback is still write-only (F-103 assumption holds)
PASS: published placements survive where MultiMesh transforms do not
MULTIMESH_READBACK_CHECK failures=0
```

The check asserts the trap, not the fix, on purpose: if `distinct_origins` ever comes back > 1 it
`push_warning`s that headless MultiMesh readback may no longer be write-only, which is the signal to
revisit every `placements`-meta workaround built around this limitation rather than a silent free win.

---

### F-115 · Hollowmere's only fog is a uniform world-wide haze: the three FogVolumes the atmosphere controller drives do not exist on this map — **fixed**

**Area:** environment · **Severity:** medium · **Found:** 2026-08-18 by vane19

Playtest, 2026-08-18 (Sequoyah): "the fog that's currently on the map looks really bad. It's
covering everything and like a flattening haze rather than being low to the ground and in specific
areas".

`world/environment/playtest_atmosphere.gd::_ready` looks for siblings `MireGroundFog`, `ForestMist`
and `RuinsMist` and drives their `FogMaterial.density`. **`levels/hollowmere.tscn` contains none of
those nodes** — they are Playtest Hollow's. So `_local_fog_materials` is empty on the shipped map and
every localized pocket the controller was written to drive is missing.

What is left is `Environment.volumetric_fog_density = 0.00035 * haze_strength` applied uniformly over
`volumetric_fog_length = 120 m`, plus `ambient_inject` up to 0.62. Uniform density over the whole
froxel volume is by definition a flat full-screen haze with no height falloff, no variation and no
motion — exactly what was reported. The authored `fog_height`/`fog_height_density` on the Environment
never take effect either: `apply_atmosphere()` writes `fog_density = 0.0` on every apply, which
switches the non-volumetric depth fog off entirely.

Fix shape: kill the uniform blanket, and put the fog in a `FogVolume` running a procedural `fog`
shader — height falloff so it hugs the ground, scrolling fbm so it is patchy and drifts, density
keyed to world position so it pools in low ground and near water. Asset/position-keyed, never
scene-keyed, so a generated world inherits it (F-097). Must no-op cleanly on the `low` graphics
preset, which turns volumetric fog off.

**Fixed 2026-08-18 by vane19,** and the lighting pass Sequoyah asked for in the same breath came
with it.

**The fog is now a function of world position, not a single number.**
`world/environment/ground_fog.gdshader` is a `shader_type fog` shader whose density is built from
three terms: a squared falloff with height above a base level so it hugs the ground, a gentler
falloff *below* it so hollows and water fill instead of clipping, and two scrolling fbm layers at
different rates so banks are patchy, have real clearings between them, and drift and shear rather
than sliding as one sheet. `world/environment/ground_fog.gd` is the `FogVolume` it runs in — a
260 m box that follows the camera **in XZ only**. Because density is evaluated in world space the
mist does not move with the box; following in Y is what would make a plateau as foggy as the mere,
which is the "covers everything" complaint in a different costume.

**Nobody has to place it.** `PlaytestAtmosphere` builds one for any level with an `Atmosphere` node,
exactly as it already does for the star field, and measures where the mist sits off the level's own
terrain — a quarter of the way up the terrain AABB, which on Hollowmere is **y = 4.33**: over the
mere (-3.2), the fen (-1.2) and the valley floor (median 4.5), with the plateau (23 m) standing
clear above it. A generated world gets the same relationship to its own terrain with no tuning.
**The measurement is taken on the first frame terrain exists, not in `_ready()`** — `Atmosphere` is
an earlier sibling than `World`, so the first version measured an empty group and silently sat the
mist at y=0.

**The uniform blanket is down from 0.00045 to 0.00006** — an eighth — and `volumetric_fog_ambient_inject`
now *falls* with daylight (0.34 → 0.16) instead of rising to 0.62, because ambient injection is what
washes a volumetric medium out into milk. It is not zero, deliberately: it is the thin medium a
sunbeam needs in order to be visible at all.

**Density is on a clock.** Thickest at dawn and dusk (×1.75), still present at noon (×0.55), heavy
at night (×1.35) — which is also when the sun is low enough to rake through it, so the mist and the
shafts pay for each other.

**Lighting (the Valheim ask).** `light_volumetric_fog_energy` is driven by a `god_ray_strength` of
2.4 (was 1.35) with a further **+60% at golden hour**, since a sun overhead has nothing to rake
through. Warmer daylight (1.0, 0.94, 0.815), the sunrise tint held further up the sky, sun energy
1.22 → 1.45, ACES tonemapping at 1.14 exposure, saturation ×1.14, glow bloom 0.08 → 0.14 with an
HDR threshold of 0.92, and `volumetric_fog_anisotropy` 0.8 → 0.92 so scattering is forward-biased
and shafts read as beams instead of a wash. The day-end ambient floor went 0.5 → 0.62 after the
first render pass: at 0.5, with ACES and a contrast lift, a hillside facing away from a low sun
crushed to pure black and read as a hole in the map.

**Degrades for free on the `low` preset**, which disables volumetric fog on the Environment and
makes every FogVolume inert without this file knowing.

**Verified:** `agent godot --script tools/ground_fog_check.gd` — new, 20 assertions, `failures=0`,
including that the mist sits in the low half of the terrain (4.33 < 16.45), follows the viewer
horizontally but **not** vertically, is thicker at dawn than noon (1.36 vs 0.55), and that the
uniform haze is gone (0.00006). `tools/atmosphere_night_check.gd` still `failures=0`.
`tools/atmosphere_look_shot.gd` — also new, **run `--windowed`** — renders the map at eight times of
day plus sunward and forest-interior views to PNGs, which is how the look above was judged rather
than guessed; it drives **DayNight**, not the atmosphere directly, because DayNight re-applies the
hour every physics tick and overwrites anything set on the controller.

---

### F-093 · A headless `--script` run never re-imports changed assets, so a check can validate the *previous* build — **fixed**

*Renumbered from F-059 on 2026-08-18 by lp (F-087) — that number collided with the original F-059
(`InventoryService._publish_snapshot`'s unguarded `rpc_id`, below, cited by `983da6c`). See F-087 for
the full renumbering.*

**Area:** verification · **Found:** 2026-08-17 by moss11 · **Fixed:** 2026-08-18 by lm

`docs/ASSET_TRACKER.md` already warned that "a check run immediately after a rebuild can report the
previous import" and said to re-run to confirm. **Re-running does not help.** Measured: after
rebuilding all 84 flora GLBs, `agent godot --script tools/flora_check.gd` reported the same stale
triangle counts and heights on three consecutive runs, and would have kept doing so indefinitely —
`--script` loads whatever `.godot/imported/` holds and never runs an import pass. The manual two-step
remedy (`agent godot --import`, then run the check) worked for that one kit but relied on every future
agent remembering it, which is exactly the kind of trap that recurs — F-098's item-icon check hit the
same root cause the very next day, and F-104's `class_name` cache staleness is the same shape again.

**Fixed by generalising the remedy into the harness itself**, so no agent has to remember it:
`cmd_godot` in `.agent/bin/agent` now runs a synchronous `<godot> --headless --path <ROOT> --import`
pass before the caller's own run, inside the same `file_lock("godot", ...)` acquisition that already
serialises lanes against the shared import cache (F-044) — so the import and the run it protects are
one atomic unit, not two lock windows another lane could interleave with. The pre-pass is skipped only
when the caller's own args already contain `--import` (so `agent godot --import` doesn't import twice),
and its output is always relayed rather than swallowed, both so a silent subprocess doesn't read like a
hang (F-104) and so a test double has a signal that it ran. A failed pre-pass warns and still runs the
caller's command rather than blocking every check on one broken asset.

**Verified:** `python3 tools/harness_check.py` → 12/12 passed, including two new cases exercising the
existing `fake-godot` argv-echo test double: `agent godot --script tools/x_check.gd` invokes the engine
twice (import-only, then the caller's own args, in that order and each free of the other's flag);
`agent godot --import` invokes it once. Regression-proved: `python3 tools/harness_check.py --rev HEAD`
(same new test file against the pre-fix committed `.agent/bin/agent`) fails the two-invocation
assertion with a single-invocation argv, exactly the bug — then the working-tree run with the fix
passes clean. Also ran a real end-to-end pass, `agent godot --quit-after 5`, twice: the import pass and
the boot both complete, project loads normally (content, world gen, harvest wiring all logged), exit 0.

No focused `tools/*_check.gd` was written — the bug and the fix are both in the harness (`agent godot`
itself), not in any one asset pipeline, so the project's existing harness-regression file
(`tools/harness_check.py`, the same one F-081 used) is the right and sufficient home for the guard.
`docs/SPECS.md`'s `## F-093` block (placed next to `## F-094`, its renumbering sibling) has the full
spec.

### F-116 · Two items now own the same branch art: harvesting ships 'stick' while ITEMS.md and task 3.2 plan 'branch' — **fixed**

**Area:** content · **Severity:** low · **Found:** 2026-08-18 by vane19

F-114 needed a stick item the moment 794 bushes and saplings started yielding one, and shipped
`content/items/stick.tres` (id `stick`, display "Stick") using `assets/pickups/exports/pickup_branch.glb`
and `assets/icons/exports/icon_branch.png`.

`docs/ITEMS.md` plans the same concept as **`branch`** — it is the D1 bootstrap raw in §"Ground
scavenge (hands)" and an input to Mushroom Skewer, Meat Skewer, Glow Flare, Branch Club, Reed
Machete and Held Torch — and task 3.2 (ivy8) holds `content/items/branch.tres` right now.

Deliberate, and recorded rather than resolved, because the alternative was worse: pointing
`bush.tres`/`sapling.tres` at `&"branch"` before that file exists makes `Harvestable`'s
`Registry.has_item()` validation fail on 794 props, i.e. the feature Sequoyah asked for is dead
until another lane's task lands. Shipping a working `stick` and converging later costs three lines.

**Converging is a one-file decision, whichever way it goes:**

- Keep `branch` (matches ITEMS.md and every planned recipe): delete `content/items/stick.tres`, set
  `yield_item_id = &"branch"` in `content/harvestables/bush.tres` and `sapling.tres`. Do this only
  once `content/items/branch.tres` is committed.
- Keep `stick`: 3.2 drops `branch.tres` and ITEMS.md's recipe table renames the ingredient.

Nothing else references `stick`; there is no save data and no recipe using it yet, so there is no
migration either way. Whoever gets there second should just check `Registry` for both ids.

**Fixed 2026-08-18 by vane19, within the hour, the `branch` way.** 3.2 landed
`content/items/branch.tres` and six recipes that consume it — arrow, short bow, skewer, repair
hammer, wooden axe, wooden pickaxe — while this finding was still open. So `content/items/stick.tres`
was deleted and `content/harvestables/bush.tres` and `sapling.tres` now set
`yield_item_id = &"branch"`. Nothing else referenced `stick`; no migration was needed, exactly as the
finding predicted.

The effect is the one that matters: the 794 bushes and saplings F-114 made harvestable now feed
real recipes rather than a dead-end resource.

**Verified:** `agent godot --script tools/harvest_tool_ladder_check.gd` →
`PASS: res://content/harvestables/bush.tres yields a registered item 'branch'` (and the same for
`sapling.tres`), `HARVEST_TOOL_LADDER failures=0`.

---

### F-113 · One axe swing depletes a whole tree: the harvest raycast and the combat swing both damage it, and neither knows what tool you are holding — **fixed**

**Area:** harvesting · **Severity:** high · **Found:** 2026-08-18 by vane19

Playtest, 2026-08-18 (Sequoyah): "the axe and pickaxe both break trees and rocks in one hit when it
should take three".

Two independent causes, both required to explain it:

1. **Two damage sources fire on one click.** `entities/player/player_controller.gd` handles
   `attack` and calls `CombatService.request_attack()` WITHOUT `set_input_as_handled()` outside
   build mode, so `autoload/harvest_world.gd::_unhandled_input` also sees the press and calls
   `try_harvest_from_camera() -> Harvestable.request_hit()`. That applies
   `HarvestableDef.damage_per_hit` on top of the weapon's own `WeaponDef.damage`. This is the
   untested ordering F-101 flagged; it is real.

2. **Health is authored in the wrong units.** `content/harvestables/tree.tres` and
   `stone_node.tres` leave `max_health` at the resource default of 3 while every real tool does
   4-6 damage, so ONE connect depletes them even without the double hit. Nothing in the content
   expresses "a tree should take three swings of the tool it is meant for".

3. **No tool matters.** `CombatService._resolve_hit` passes `weapon.damage` straight into
   `host_apply_damage`. A pickaxe fells a tree exactly as fast as an axe, and bare hands do too.

Fix shape: one damage source per click (combat owns it), a tool class + harvest power on
`WeaponDef`, a required tool class on `HarvestableDef`, and harvestable health authored so the
intended tool takes three swings.

---

**Fixed 2026-08-18 by vane19.** All three causes, because any one of them left alone still one-shots
a tree:

1. **`autoload/harvest_world.gd` no longer listens for `attack`.** Combat is the single damage
   source: it is host-resolved, it already targets everything in `&"damageable"`, and it knows the
   weapon. `try_harvest_from_camera()` stays as an API for checks and for a future interact verb.
   This closes the untested half of F-101 as well.
2. **A tool axis, separate from combat damage.** `WeaponDef` gained `tool_class`
   (`Any`/`Chop`/`Mine`) and `harvest_power` — **wooden 1, stone 2, iron 3**. `HarvestableDef`
   gained `required_tool` and `wrong_tool_scale` (default 0.34, floored), and its health is now
   authored in tool power, so `max_health = 6` literally reads "three swings of a stone axe".
   `CombatService._resolve_hit` prefers a new `Harvestable.host_apply_tool_damage()` by feature
   test, so enemies and anything else in `&"damageable"` are untouched.
3. **A wrong-tool connect still registers as a hit with 0 damage,** rather than as a miss — the
   thunk of a pickaxe bouncing off a pine is the feedback that tells you to switch, and reporting
   it as a miss would delete it.

The ladder now: stone axe fells a tree in **3**, a wooden axe in 6, an iron pickaxe in 6, bare hands
never. Stone pickaxe takes a stone node in 3, iron pickaxe an iron node in 3. Bare hands strip a
bush in 3.

**Verified:** `agent godot --script tools/harvest_tool_ladder_check.gd` — new, asserts 17
weapon×harvestable swing counts against the SHIPPED `.tres` files plus a live prop taken down in
exactly three (`HARVEST_TOOL_LADDER failures=0`). Regression: `harvestable_check`,
`harvest_world_check`, `harvestable_net_check`, `harvest_world_net_check`, `combat_check` all
`failures=0`.

---

### F-114 · Only 83 of Hollowmere's 2,869 props can be harvested: harvestability is authored per-placement in the layout instead of per-asset — **fixed**

**Area:** world · **Severity:** high · **Found:** 2026-08-18 by vane19

Playtest, 2026-08-18 (Sequoyah): "a lot of rocks are not harvestable ... a lot of trees are not
harvestable", and "I would like bushes and little trees to give sticks".

Ground truth from `world/gen/layouts/hollowmere.json`: 2,869 props, of which 44
`harvest_tree_intact`, 29 `stone_node_intact` and 10 `iron_node_intact` carry `"harvestable": true`.
Everything else is scenery, including 62 trees (`tree_pine_*`, `tree_birch_*`, `tree_crooked_*`,
`tree_bare_*`, `tree_willow_*`, `mire_broadleaf_tree`), 198 rocks (`boulder_a..h`,
`rock_cluster_a..f`, `mire_mossy_boulder`) and 794 bushes and saplings.

Two structural causes:

1. **`autoload/harvest_world.gd::DEFINITION_PATHS` has exactly three entries**, keyed to the three
   `assets/harvestables` exports. Any other tree or rock is unreachable no matter how it is placed.

2. **The decision lives in the layout, not the asset.** `tools/mapgen/hollowmere_layout.py` passes
   `harvestable=True` per placement and `world/gen/authored_world.gd::_build_props` reads
   `prop["harvestable"]`. That is the exact failure shape F-097 wrote `AssetVfxLibrary` to end:
   behaviour keyed to one map's authored data is silently absent on the next one, and release worlds
   are procedurally generated. A generated world would ship inert scenery again.

3. **Bushes and saplings are placed `solid=False`**, so they have no collider at all and cannot be
   raycast or swung at even in principle.

Fix shape: an asset-keyed harvest library alongside `AssetVfxLibrary`, consumed by BOTH the world
builder and `HarvestWorld`, so any world containing a pine gets a choppable pine by stamping the
asset id — the same contract F-097 established.

---

**Fixed 2026-08-18 by vane19.** **83 → 1,181 live harvestables on Hollowmere**, and 11 → 178 on
Playtest Hollow, with no layout regenerated and no map edited — because the decision moved to the
asset.

- **`systems/harvesting/harvest_library.gd`** is the new table, modelled on `AssetVfxLibrary` and
  keyed the same way: asset id → definition path, longest-prefix-first. `world/gen/authored_world.gd`
  and `autoload/harvest_world.gd` both read it, so there is one answer rather than two. A layout's
  own `harvestable` flag is still honoured, but nothing new needs it: a generated world gets a
  choppable pine by stamping `tree_pine_c`.
- **Seven new definitions, no new art:** `wild_tree`, `boulder`, `rock_cluster`, `fallen_log`,
  `stump`, `bush`, `sapling`. `HarvestableDef.active_state_scenes` may now be **empty**, meaning
  "this asset is its own intact visual" — `Harvestable` then leaves the world builder's geometry
  alone and only hides it on depletion, through a `set_visual_hook()` Callable. That is what lets
  ONE definition cover 62 wild trees or 794 bushes instead of demanding a three-state Blender
  export per species.
- **Bushes and saplings yield `branch`** — the item 3.2 authored, which six recipes (arrow, short
  bow, skewer, repair hammer, wooden axe, wooden pickaxe) already consume. It shipped for an hour as
  a duplicate `stick` item because `branch.tres` did not exist yet; F-116 records that and its
  convergence.
- **Density did not cost frame time.** `HarvestLibrary.Represent` splits the families: `NODE` gets
  its own holder and mesh (trees, ore, boulders — **387** of them, up from 83), `BATCH` stays
  inside the chunk's `MultiMesh` and gets a logic-only holder (**794** bushes and saplings, **zero**
  extra draw calls). A batched prop is hidden by zeroing that one instance's transform, which is
  the only handle a batched copy has. Promoting all of them would have traded a handful of batched
  draws for eight hundred, on a game targeting the worst machine someone might play it on.
- **No collider is synthesised for soft flora,** and none is needed: `CombatService` picks its
  target out of `&"damageable"` by distance and arc, not by raycast, so a walk-through bush is
  still swingable. `Harvestable` now treats a missing `CollisionBody` as legal for these families
  and still errors for a definition that ships damage states.

**Verified:** `agent godot --script tools/world_contract_check.gd` →
`WORLD_CONTRACT_HARVEST layout_props=1181 wired=1181`, `PASS`. `tools/hollowmere_check.gd` →
`HOLLOWMERE_HARVEST live=1181`, `PASS`. `tools/harvest_world_check.gd` reworked and `failures=0`
(the 11 multi-state A-001 props are still asserted exactly). `tools/harvest_batch_check.gd` — new,
**must run `--windowed`** — proves a batched bush's own instance collapses on depletion, its
neighbour in the same batch does not, and respawn restores the exact placed transform
(`batched=794 skipped=0 failures=0`).

---

### F-105 · Per-frame costs found by the F-099 review in files claimed by F-086/F-097 — **fixed**

**Area:** perf · **Severity:** low · **Found:** 2026-08-18 by kiln9

Three items, one per file, found mid-sweep while `build_ghost.gd`/`player_controller.gd` (F-086) and
`environment_vfx.gd` (F-097) were held by other in-flight tasks. All three had landed by the time this
was picked up, so all three were claimed and checked fresh rather than reused from the finding's own
description.

1. **`build_ghost.gd:update_aim()`** ran `PlacementValidator.evaluate()` (5 support raycasts + a shape
   cast, fresh allocations) every physics tick even with a stationary ghost. **Fixed:** cache the last
   evaluated placement + builder position; skip `evaluate()` unless either changed, or
   `REEVALUATE_INTERVAL_S` (0.2s) has passed — the timer catches a world change under a ghost that
   never moves. `set_piece()` invalidates the cache, since `evaluate()` also depends on the piece def,
   not just the transform. A new `evaluate_count()` getter lets a check prove the skip is real.

2. **`player_controller.gd`'s physics tick** re-derived `gameplay_input_allowed()` (group scan) and
   `_is_downed()`/`_is_dead()` (`get_node_or_null(/root/PlayerHealth)` + `.call()`) up to 3x each,
   independently, across `_apply_horizontal_movement`/`_try_jump`/`_tick_revive_hold`. **Fixed:**
   `_physics_process()` resolves all three exactly once and threads them through as parameters;
   `_health_node()` caches the resolved autoload in a member var instead of re-walking `/root`.

3. **`environment_vfx.gd`**'s finding text described `_fire_lights` as an append-only array with
   unscaled shadows — **that code no longer exists.** F-097 (landed the same day, ahead of this task)
   replaced fire-light discovery with the `_sites`/`_pools` budget system: pools are capped by
   `profile.max_live * preset_scale` and reused in place, `_reset()` clears them on every scene
   change, and `shadow_enabled` is already gated by `shadow_live * preset_scale` — confirmed against
   `AssetVfx.EMITTER_PROFILES`. The one part still true — `_process()` did its scene-change check
   every frame regardless of fire count — now short-circuits before the budget timer and light-flicker
   pass when both `_sites` and `_pools` are empty.

**Fixed 2026-08-18 by lp.** Claim deviated from the work order's suggested `autoload/build_service.gd`
(no per-frame cost exists there — it's a full re-derivation of the actual files the finding's own body
names, see `docs/SPECS.md`'s F-105 block for the reasoning and the exact call-site changes two test
files needed). **Verified:** `agent godot --script tools/build_check.gd` (failures=0, four new F-105
assertions added), `tools/player_vitals_check.gd`, `tools/environment_vfx_check.gd`,
`tools/environment_vfx_hollowmere_check.gd`, `tools/verify_setup.gd`, `tools/combat_self_hit_check.gd`,
`tools/build_net_check.gd`, `tools/player_health_net_check.gd`, `tools/player_vitals_net_check.gd` —
all 0 failures, covering every function whose signature changed end to end (offline and networked).

---

### F-076 · A new map inherits none of the systems keyed to the old map's group names — **fixed for EnemyWorld/HarvestWorld; Undergrowth follows in F-112**

**Area:** worldgen · **Severity:** high · **Found:** 2026-08-18 by ivy8 during 2.1k

`levels/hollowmere.tscn` became the main scene while **three** systems still looked exclusively for
Playtest Hollow's node groups. All three were fixed by hand in 2.1k; the finding stayed open because
the *class* of bug — a group name matching nothing is indistinguishable from a level that has none of
that thing, so nothing ever errored — was not, and the next map would have hit it again with no check
to catch it before it shipped.

**Fixed 2026-08-18 by lp**, for two of the three systems (the third is `F-112`, filed above — it
needed a claim outside this task's files). The durable fix asked for was "a check that asserts each
map satisfies each system... lifted into something a new map gets for free" — that is
`tools/world_contract_check.gd`, and it needed no map-specific code because it never trusts a group
name for ground truth:

* **`EnemyWorld.expected_nest_count(layout: Dictionary) -> int`** and
  **`HarvestWorld.expected_harvestable_count(layout: Dictionary) -> int`** are new pure functions that
  read a map's raw layout JSON directly — `markers[].kind` and `props[].harvestable` — never through
  a Godot group. That is what makes the comparison meaningful: the *same* group-name blind spot that
  broke `ambient_spawn_points()`/`wired_harvestables()` on Hollowmere cannot also hide the ground
  truth they're compared against, because the ground truth doesn't go through a group at all.
* **`tools/world_contract_check.gd`** boots whatever `project.godot` names as `main_scene`, finds the
  layout the same way `Undergrowth` already does generically (a `World` node exporting
  `layout_path`), and fails loudly if `expected_nest_count() > 0` but `ambient_spawn_points()` is
  empty or no crawler ever actually spawns, or if `expected_harvestable_count() > 0` but
  `wired_harvestables()` is empty. A map not built on the `AuthoredWorld` layout convention has
  nothing to compare against and the layout-shaped checks are skipped, not failed.
* **`EnemyWorld.CANONICAL_NEST_KIND = &"enemy_nest"`** is now the one marker `kind` a new map's
  generator should publish — see **D-062**. `NEST_SOURCES` still separately reads Playtest Hollow's
  legacy `enemy_spawn` for backward compatibility; ground truth deliberately does not, so it measures
  against the convention going forward rather than every historical spelling.
* Deliberately **not** attempted: renaming `authored_world_marker`/`authored_world_harvestable`
  themselves, or migrating Playtest Hollow's groups. Both are read by other files outside this task's
  claim (`autoload/crafting_service.gd`, `world/gen/authored_world.gd`) and the deprecated Hollow path
  is confirmed dead code (F-075's note) — a rename there is pure churn with no bug behind it.

**Verified:**
`agent godot --script tools/world_contract_check.gd` → `WORLD_CONTRACT_ENEMY layout_nests=4
spawn_points=4`, `live=4`, `WORLD_CONTRACT_HARVEST layout_props=83 wired=83`,
`WORLD_CONTRACT_CHECK PASS`. Regression-proved the check actually catches the F-076 bug shape: with
`EnemyWorld.NEST_SOURCES`'s Hollowmere entry temporarily commented out (simulating a system not yet
taught a new map's marker group), the same run reported `spawn_points=0` and failed with `layout
declares 4 enemy_nest marker(s) but EnemyWorld.ambient_spawn_points() found none`; reverted
immediately after (confirmed via `git diff --stat` showing only the intended 23-line addition).
No regressions: `agent godot --script tools/hollowmere_check.gd` (`HOLLOWMERE_CHECK PASS`, unchanged
numbers), `agent godot --script tools/harvest_world_check.gd` (`failures=0`), `agent godot --script
tools/enemy_check.gd` (`failures=5`, the same pre-existing telegraph failures F-111 already
attributes to the check itself, not this task).

Missing `docs/SPECS.md` block written as part of this task — see `## F-076` there.

### F-075 · World statics and props shared collision layer 1, so a placement overlap query could not tell ground from obstruction — **fixed**

**Area:** physics · **Severity:** low · **Found:** 2026-08-18 by gale6

Task 3.6's `PlacementValidator` asked two different questions of the physics world — "is there
ground under this piece" (support) and "is something already occupying this space" (overlap) — of
the same collision layer. Terrain, props, harvestables and buildables all shared layer 1, so the
ground itself registered as the overlap: on any slope the uphill side of the footprint rose into the
query box, and the validator worked around it by lifting the box by a clearance derived from the
piece's steepest permitted slope. That workaround cost real detection — an obstruction lying
entirely below the clearance (up to 0.58 m for a 2 m wall permitting 30°) was invisible to the check.

**Fixed 2026-08-18 by lp.** Gave terrain a dedicated layer, `PlacementValidator.TERRAIN_LAYER = 2`
(`project.godot` now names both: `3d_physics/layer_1="solid"`, `3d_physics/layer_2="terrain"`).
`world/gen/authored_world.gd`'s terrain `StaticBody3D` is the only thing on layer 2 — props,
harvestables, placed buildable pieces, players and enemies all stay on the shared layer 1.
`_probe_support()` ORs `TERRAIN_LAYER` into the caller's mask so ground is always found for support
regardless of what "solid" mask the caller passed; `_overlaps()` never adds it, so the ground a
piece rests on no longer reads as an obstruction and its clearance collapsed from the slope-derived
formula to the flat `MIN_GROUND_CLEARANCE_M` floor — the blind band is gone. Two more masks needed
the same terrain bit or they would have silently broken: `build_ghost.gd`'s own aim ray (a second,
independent query from `evaluate()`'s internal one — it finds *where* the player is pointing before
`evaluate()` ever runs) and, less obviously, `entities/player/player.tscn` and
`systems/enemies/enemy.gd`'s `CharacterBody3D.collision_mask`, which defaults to `1` and would have
had both walking straight through Hollowmere's terrain the instant it moved off layer 1 — the
"whatever masks the player and enemies use" cost the original finding named. `world/gen/playtest_hollow.gd`
was deliberately left on layer 1 (deprecated, locked by another lane's claim, and confirmed by grep
to have no `PlacementValidator` caller at all — nothing regresses).

**Verified:** `agent godot --script tools/build_check.gd` (0 failures — its own fixtures now model
the layer split: ground goes on the new `TERRAIN_LAYER` default, the one true obstruction stays on
`WORLD_LAYER`), `agent godot --script tools/hollowmere_check.gd` (terrain/grounding/nav probes clean
against the real 356 m map, navmesh bakes 9,486 polygons unaffected — `NavigationMesh`'s
`geometry_collision_mask` defaults to all layers, so parsing was never layer-restricted),
`agent godot --script tools/enemy_check.gd` / `tools/combat_check.gd` / `tools/enemy_net_check.gd` /
`tools/harvest_world_check.gd` (no new failures anywhere; `enemy_check.gd`'s 5 pre-existing telegraph
failures reproduce identically via `agent baseline` at HEAD before this task — filed separately as
F-111, not this task's to chase), and `agent godot --quit-after 120` (Hollowmere boots clean over the
full window). Missing `docs/SPECS.md` block written as part of this task — see `## F-075` there,
placed after F-082 in the 3.6 cluster.

### F-111 · `enemy_check.gd`'s telegraph/swing assertions fail at HEAD, unrelated to F-075 — **fixed**

**Area:** combat/enemies · **Severity:** medium · **Found:** 2026-08-18 by lp during F-075

`tools/enemy_check.gd` failed 5 assertions from "a player in reach makes it telegraph" onward: state
never reached `2`/telegraph in the scenario at `enemy_check.gd:92-106`, so the swing, its damage, its
target and the commit-to-swing state all failed downstream of that one miss. Confirmed at the time
**not** caused by F-075: `agent baseline --script tools/enemy_check.gd` against HEAD (`e028365`,
before any F-075 edit) reproduced the identical 5 failures.

**Root cause was in the check, not in `enemy.gd`.** The telegraph scenario pins the enemy at the
origin, holds a target between the aggro/deaggro radii, then moves the player to 400 m and steps
once — the target is dropped and `_resolve_target()` falls through to an immediate rescan, which
finds nobody and, on the way out, sets `_rescan_wait = RESCAN_INTERVAL_SEC` (0.2 s; F-099's
throttle — an untargeted enemy scans the `players` group at most once per interval, by design). The
next lines teleport the player to 1 m away and took a **single** 0.05 s step expecting
`state == TELL` immediately — landing inside that freshly-reset 0.2 s cooldown, so
`_resolve_target()` returned null without ever looking at the group, the enemy stayed `IDLE`, and
every downstream assertion failed as a chain reaction from that one miss. `combat_check.gd`,
`enemy_net_check.gd` and `hollowmere_check.gd` were all green throughout, confirming this was scoped
to the standalone harness, never to enemy combat generally — matching the original finding's guess.
The second telegraph a few lines further down (`_step_until_state(enemy, 2, 0.05, 200)`) was always
green because it already steps until the state actually changes rather than assuming one tick
suffices.

**Fixed 2026-08-18 by lp.** `tools/enemy_check.gd`: the first telegraph assertion now uses the same
`_step_until_state(enemy, 2, 0.05, 20)` pattern as the second one, instead of one bare
`_step(enemy, 0.05)`. No production file touched — `systems/enemies/enemy.gd` was read and is correct
as committed.

**Verified:** `agent godot --script tools/enemy_check.gd` on the pre-fix tree reproduced the exact 5
failures (`ENEMY_CHECK attacks=0 failures=5`); after the fix, all 44 assertions PASS,
`ENEMY_CHECK attacks=0 failures=0`.

Missing `docs/SPECS.md` block written as part of this task — see `## F-111` there, placed after F-103.

### F-107 · chest_net_check's two host-side grant assertions fail at HEAD; client side is green — **fixed**

**Area:** netcode · **Severity:** medium · **Found:** 2026-08-18 by kiln9

Root cause was in the check, not in `chest.gd` or `InventoryService` — both were already correct.
`_run_driver()` derived `client_peer` by assigning it inside the `_until()` poll's lambda
(`client_peer = peer_id; return true`), then read `client_peer` in the outer scope afterward. A
GDScript lambda captures an outer local **by value, not by reference**, so the assignment updated
only the closure's private copy; the outer `client_peer` stayed at its `-1` sentinel even once
`got_peer` reported success. `host_count(-1, ...)` then hit `_valid_host_peer()`'s `peer_id <= 0`
guard and read back `0` unconditionally — which reads exactly like a grant race or a polluted store,
but was neither. The adjacent PASSes ("client's grant reply carries the rolled coins/item") already
proved the host had granted correctly; only the check's own read of it was broken.

**Fixed 2026-08-18 by lp.** `tools/chest_net_check.gd`: the `_until()` closure now only reports
whether a non-host peer exists; once it does, `client_peer` is assigned by a second scan of
`transport.call("peer_ids")` run directly in the outer scope, not inside the closure.

**Verified:** `agent godot --script tools/chest_net_check.gd`, two consecutive runs, `failures=0`
both times, all 12 assertions PASS including the two that were red at HEAD (confirmed red first,
with `host_count()` logged: `client_peer=-1`, all three host-side counts read `0`).

Missing `docs/SPECS.md` block written as part of this task — see `## F-107` there, placed after
3.5 (the task that authored `chest_net_check.gd`).

### F-104 · A new `class_name` is invisible to every headless run until the editor rescans, and it fails as a silent hang — **the hang is now caught; the advice stands**

**Area:** tooling · **Severity:** medium · **Found:** 2026-08-18 by larch10 during F-097

Godot resolves `class_name` through `.godot/global_script_class_cache.cfg`, which is written by an
**editor** scan. `agent godot --script` never scans (the same root cause as F-093), so a script file
added in this session is not in the cache, and every reference to its global name fails to parse:

```
SCRIPT ERROR: Parse Error: Identifier "AssetVfxLibrary" not declared in the current scope.
SCRIPT ERROR: Compile Error: Failed to compile depended scripts.
```

What makes it expensive is the shape of the failure. The parse error kills the check script, so
`quit()` is never reached, and a `SceneTree` with no one to stop it **runs forever**. The run does
not fail — it hangs, produces no output at all because stdout to a pipe is block-buffered, and
burns the shared `agent godot` lock until something kills it. It cost roughly eight minutes here
before `sample <pid>` showed the main thread parked in `nanosleep` with no work in flight.

**Consequences.** Declare `class_name` if you like — the editor will register it eventually — but
**reference new scripts by `preload()`**, which resolves through the path and needs no cache.
`autoload/environment_vfx.gd`, `world/gen/authored_world.gd` and `world/gen/undergrowth.gd` all
preload `asset_vfx_library.gd` for exactly this reason. Two cheap habits make the failure survivable
when it does happen: run `agent godot --check-only --script <file>` first, which parses in seconds
instead of hanging, and treat *no output at all* from a headless run as a parse failure rather than
as slowness.

**Fixed 2026-08-18 by bram1 (director).** The advice above is still right, but it only helps an agent
who already knows. `agent godot` now ends the hang itself: it watches the engine output it streams,
and if a `SCRIPT ERROR` / `Parse Error` / `Compile Error` has gone by and the run then produces no
output for 45 seconds while still alive, it kills the process and explains exactly this finding —
that a check whose script fails to compile never reaches `quit()`, so its SceneTree runs forever
holding the shared lock. Silence *after* an error is conclusive; silence on its own is not, which is
why the watchdog is armed by the error rather than by time alone (real two-process net checks sit
quiet on timers for long stretches).

Reproduced before fixing, because the shape matters and the obvious guess is wrong. A script whose
own body fails to parse does **not** hang — Godot fails the load and exits cleanly (measured: exit 0,
which is its own trap). The hang needs the entry script to parse while a *dependency* fails to
compile: `preload()` of a script referencing an uncached `class_name` reproduced it exactly, running
past 30 seconds with **no output whatsoever**.

Two smaller repairs fell out of the same work. Relaying the engine's output through Python had added
a second layer of block buffering, so a running check's progress was invisible until it exited —
every relayed line is now flushed. And a killed run cannot run its own cleanup, so `.agent/locks/`
holder records outlived their processes and told the next waiter a free lock was held; a holder whose
pid is gone now reports itself as stale.

**Verified:** the reproduction is killed at 45s with exit 247, the explanation printed, and no orphan
engine left behind; `wave_spawner_check` (16 PASS, `failures=0`) streams live and is untouched by the
watchdog. Both probes were removed after each run.

---

### F-061 · content/items/coins.tres has no icon — the render_item_icons.py pipeline needs a SOURCES entry — **fixed**

**Area:** content · **Severity:** low · **Found:** 2026-08-18 by lp · **Resolved:** 2026-08-18 by lp

Task 3.5 added `content/items/coins.tres` (stack_size 999, world_model =
assets/loot/exports/loot_coin_pouch.glb) with `icon` left null — every other item's icon comes from
`tools/blender/render_item_icons.py` (D-033), and coins had no entry in its `SOURCES` list.

**Fix:** added `("coins", "loot/exports/loot_coin_pouch.glb")` to `SOURCES` (kept the plural item id,
matching `coins.tres`'s own `id`, distinct from the existing singular `coin`/`coin_stack` pickup
icons already in the list) and reran
`/Applications/Blender.app/Contents/MacOS/Blender --background --python tools/blender/render_item_icons.py`.
Default azimuth/elevation framed the pouch cleanly with no `AZIMUTH`/`ROLL_OVERRIDE_DEG` entry needed
— checked visually against `preview/item_icons_sheet.png`. Wired `content/items/coins.tres`'s `icon`
to the new `res://assets/icons/exports/icon_coins.png`, same pattern as `log.tres`. Updated
`assets/icons/README.md`'s icon count (25 → 26) and family table.

The rerun touched all 25 pre-existing export PNGs on disk (Blender stamps wall-clock metadata into
every render, F-042) but only added pixels for the new `icon_coins.png` — verified with
`tools/png_pixels_equal.py`'s `pixel_diff_bbox` against each file's committed `HEAD` copy, all 25
came back `None` (pixel-identical), so those 25 were reverted with `git checkout --` and only the
catalog entry, the new PNG, and the regenerated contact sheet (which now includes the 26th cell) are
part of this change.

**Verified:** `.agent/bin/agent godot --script tools/item_icons_check.gd` → `item_icons_check: PASS`,
run twice consecutively for stability. The very first run after adding the untracked `icon_coins.png`
reported 2 failures before any check output was inspected — consistent with F-093 (a headless
`--script` run doesn't reimport a brand-new asset on the same pass it appears); the immediate rerun,
and a third run after that, both came back clean, so this is not a new flake.

---

### F-099 · Optimization sweep: per-frame costs and dead weight across runtime scripts — **fixed**

**Area:** perf · **Severity:** medium · **Found:** 2026-08-18 by kiln9 · **Resolved:** 2026-08-18 by kiln9

Two read-only reviewers swept every runtime script (autoload/, core/, entities/, systems/, ui/,
world/ — minus files claimed by in-flight tasks); 54 findings, fixes applied in 20 files under this
claim. By weight:

- **Per-frame allocations.** viewmodel and vitals_hud each duplicated all 32 inventory slot
  Dictionaries every rendered frame through `local_slots()`; both (and combat_service's
  `weapon_for_hotbar_index`) now use the new `InventoryService.local_slot()/local_item_id()`
  single-slot accessors. Enemy `_apply_overlay` re-ran `find_children` per frame per enemy during
  flashes and corpse dissolves — mesh list cached at build, overlay assigned once, per-frame work is
  one colour write. The inventory commit path made up to 3 full-array copies; now 1.
- **Polling → state-driven.** Enemy `_process` idles off until a hit or death; harvestable's
  respawn tick is off while the prop stands (hundreds of props × 60 Hz → zero); build_service's
  nav-rebake tick and crafting_service's timed-craft `_process` toggle with their queues;
  net_session's identity sweep runs only on a hosting peer. vitals_hud rebuilds its hint only when
  selection/inventory change, layout only on resize/visibility flips, banner strings once per
  displayed second.
- **Per-tick lookups cached.** `harvest_world._on_node_added` scheduled a full multi-group scene
  rescan for EVERY node the game ever added — now filtered to holder-group members (both generators
  group before add_child, so membership is visible at node_added time). day_night's Atmosphere and
  transport lookups cached per scene / once. Transport refs cached across player_health and the
  inventory/build/powerup/enemy_world services; powerup definitions memoized (`stat()` is
  per-physics-tick); station positions cached per scene behind a group-census guard; player_net
  reads each body's peer id from meta instead of String-parsing per player per tick. New
  `NetTransport.has_peer()` replaces the `peer_ids()` array copy in every F-059 guard. Enemy AI:
  held target cached by reference, acquisition rescans at 0.2 s, nav repath only when the goal
  moves >1 m — the attack itself still measures live positions.
- **Bugs.** `host_health_changed` declared 4 args but emitted 5 (no subscribers existed).
  `_builder_position` documented a placement fallback but returned `Vector3.ZERO`, so with no
  player bodies the range rule measured from the world origin. chest_ui's nearest-chest scan let an
  opened chest shadow an unopened one in range. The enemy hit clip ended frozen until the next
  state change. Downed flags travel only on change now — with a one-shot sync to late joiners and a
  flag-clear broadcast on run-player expiry, which also fixes the F-089-shaped ghost
  "TEAMMATE DOWN" an expired downed peer left on every client.
- **Bloat.** registry.gd's seven copy-pasted loaders → one spec-driven `_load_dir()` (~130 lines);
  duplicated viewmodel comment block; redundant crafting write-backs; harvestable's no-op setter.

Deliberately NOT done: enemy state/health/hit_counter replication stays ALWAYS — under D-025's
interest hysteresis a peer whose visibility is off during a change could miss an ON_CHANGE delta
permanently. crafting_ui's `_on_inventory_changed` stays ungated — crafting_net_check asserts
closed-panel row state is a public contract. world/chunk's expired R2/R3 spikes stay until 4.0a
re-measures on a real renderer (F-005). Per-frame items in files other tasks held are F-105.

Verified, all green: verify_setup, combat_self_hit, combat_feel, player_health, vitals_hud,
viewmodel, powerup, inventory, build, hollowmere (4 crawlers, 9,486 navmesh polys), and two-process:
session_lifecycle 8/8, player_health_net, player_vitals_net, inventory_net, crafting_net,
powerup_net, build_net, day_night_net, harvest_world_net, harvestable_net, combat_net, interest.
chest_net_check's 2 host-side failures reproduce identically at HEAD baseline aa3f764 —
pre-existing, filed as F-107.

---

### F-097 · Environmental VFX was keyed to node types the shipped map never produces, so wind and firelight were dead on Hollowmere — **fixed**

**Area:** presentation · **Severity:** high · **Found:** 2026-08-18 by larch10 while starting visual work

`autoload/environment_vfx.gd` discovers what to animate by walking the tree for **`MeshInstance3D`**
(`_on_node_added` line 42, `_apply_recursive` line 47). Both world generators emit
**`MultiMeshInstance3D`** instead — `world/gen/authored_world.gd:450` for the 2,869 authored props and
`world/gen/undergrowth.gd:546` for the ~10,240 scattered plants (both batched per chunk/cell by F-090).
`MultiMeshInstance3D` does not extend `MeshInstance3D`, so the walk matches none of them.

The result on `levels/hollowmere.tscn` — which is `project.godot:14`'s `main_scene`, the map people
actually play — is that no grass sways, and no campfire, forge or furnace gets its flame, spark, smoke
or flickering light. `systems/crafting/station_def.gd:19` and `autoload/crafting_service.gd:19` already
record that stations are baked into MultiMesh batches "with no per-instance node of their own", which is
the same root cause seen from the crafting side.

**Measured** on `hollowmere` (`agent godot --script tools/environment_vfx_hollowmere_check.gd`):

```
CENSUS mesh_instance3d=2808 multimesh_instance3d=1740 multimesh_copies=13026
VFX    foliage_mesh_count=0  fire_source_count=0
```

Every one of the 13,026 instanced copies — the props and the whole undergrowth field — is invisible to
the system, and the 2,808 loose `MeshInstance3D` nodes that do exist are terrain, water and
harvestables, none of which match a foliage or fire name. Both counters are **zero**, not low.

It reads as green because `tools/environment_vfx_check.gd:3` boots
`res://levels/playtest_hollow.tscn` — the map deprecated by 2.1k — where props were still individual
`MeshInstance3D` nodes. This is F-076's exact shape a second time: a system keyed to the old map's
representation silently does nothing on the new one, and the check that should have caught it is
pinned to the old map too.

Fixing it must not re-key the system to Hollowmere either. Release worlds are procedurally generated,
so the binding has to be to **the asset** — its kind, travelling with the asset — not to a scene, a map,
or a node name a level author chose.

---

### F-100 · Static chunk batching for authored props — designed, measured-in-principle, blocked on F-097

**Area:** perf · **Severity:** medium · **Found:** 2026-08-18 by coil23

BLOCKED until F-097 (larch10) releases world/gen/authored_world.gd — do not claim that file while their VFX wiring is in flight. The design, from F-098's research (DOOM ~1,331 draws/frame; Roblox merges identical/static geometry): authored props run 2,869 props in 1,028 MultiMeshes = 2.8 instances per draw, which is instancing overhead without instancing's payoff (~3.3k of our 5.4k total draws are its shadow-pass copies). Replace per-(chunk,asset) MultiMeshes with ONE merged ArrayMesh per chunk, one surface per material bucket: SurfaceTool.append_from(mesh, surface, placement) per prop (C++-speed transform bake), bucket key = material resource_name + albedo fingerprint (kit shares one palette so buckets merge across assets), disk-cache per chunk keyed by layout mtime (mesh_cache pattern from F-095). Keep harvestables as nodes (they swap when felled) and keep flora as MultiMesh (14+ instances/draw pays). VFX-compatible with F-097: wind sway keys off materials, and bucketing preserves material identity. Expected: prop draws 1,028 -> ~chunks x 1-3 buckets, same ratio in all four shadow cascades. Verify with tools/perf_probe.gd and tools/hollowmere_check.gd.

---

### F-101 · Build-mode "attack" (confirm/swing) and `harvest_world.gd`'s own independent listener are unmediated

**Area:** gameplay · **Severity:** low · **Found:** 2026-08-18 by lp while closing F-086

F-086 wired `entities/player/player_controller.gd`'s own "attack" handling to confirm a build
placement instead of swinging while build mode is active, and calls
`get_viewport().set_input_as_handled()` on that branch so nothing downstream reads the same click
twice. But `autoload/harvest_world.gd:49` listens for `"attack"` independently, in its own
`_unhandled_input`, and nothing in this codebase establishes (or tests) which of two nodes'
`_unhandled_input` runs first for the same event — `set_input_as_handled()` only suppresses
handlers that have not run yet by the time it is called, and this codebase has never had two
listeners on the same action disagree about what it means before now (combat and harvest already
both react to "attack" today, apparently by design, so precedent here is "let both fire," not "one
wins"). Worst case: aiming at a harvestable while placing a piece also registers a harvest hit on
the same click. Not fixed here because the only fix is inside `harvest_world.gd`, which this task's
claim does not name.

Would take: either an explicit input-priority contract (documented, and enforced by a check that
constructs both nodes and asserts delivery order) or a shared "is anything else claiming this attack
press" query `harvest_world.gd` checks before it acts — `PlayerController.is_build_mode_active()` is
already public and would be the cheapest version of the second.

---

### F-102 · docs/FINDINGS.md is the one file every lane must write and no lane can hold, so every close-out commit carries other lanes' half-written findings

**Area:** tooling · **Severity:** medium · **Found:** 2026-08-18 by yarrow21

Sibling of F-081, one level up. F-081 fixed `ship` carrying harness *source* it had no claim on; this
is the same shape in a file where the carrying cannot be switched off, because the work genuinely
belongs there.

Observed 2026-08-18 while closing F-080. `git diff` on `docs/FINDINGS.md` at ship time held, besides
my own resolution: LP's F-086 resolution, an F-098 rewrite, and three newly filed findings
(F-099/F-100/F-101) from two other lanes. All of it uncommitted, none of it mine. The choices at that
moment are both bad — ship the file and commit three other agents' in-progress writing under my name
and message, or leave it and let my own resolution stay invisible to everyone (uncommitted work is
invisible to Codex). I shipped it, because invisible is worse than misattributed.

An exact claim does not help. Every lane must write this file to close anything out, so a claim on it
either blocks every other lane or is ignored — and it is ignored: I held an exact claim on
`docs/FINDINGS.md` for F-080 while three lanes wrote to it, because a claim blocks the *commit*
(`agent check`), not the editor. F-058 is the same collision seen from the numbering side; the two
findings share a cause.

**Sketch of a fix, not yet decided:** one file per finding (`docs/findings/F-099.md`), with
`docs/FINDINGS.md` generated from the directory the way `.agent/BOARD.md` is generated from
`state.json`. Then a finding is an ordinary claimable file that exactly one task owns, filing is a
create (no merge conflict, no number race — the filename *is* the number), and `agent finding`/`agent
brief` read the directory. The cost is a generated 1,000-line file in git and a migration of ~100
existing sections; both are one-time. An append-only convention alone does not fix it, because
resolving a finding *moves* a section rather than appending one.

---

**A third defect, found while fixing this:** `EnvironmentVfx` was **never registered as an
autoload**. The script had existed since 2.1g and nothing loaded it, so even on Playtest Hollow the
effects only ever appeared in a check that constructed the controller by hand. That is F-051's rule
and F-068's failure again — a script nothing loads is not shipped. Registered via
`agent autoload EnvironmentVfx autoload/environment_vfx.gd`; there are 27 autoloads now.

**Fixed** by binding presentation to the asset instead of to the level (D-060):

- `world/environment/asset_vfx_library.gd` — new. Asset id -> sway class + emitter class, with no
  reference to any scene, map, layout or node. Ten sway profiles and six emitter classes.
- `autoload/environment_vfx.gd` — rewritten. Handles `MultiMeshInstance3D` as well as
  `MeshInstance3D`; dresses the **mesh resource** once per asset rather than per node, so 13,026
  instanced copies cost one material swap; serves emitters from a **fixed pool** ranked by distance,
  so the cost is bounded by the budget and not by the world. Falls back to node names when the meta
  is absent, which is what keeps hand-authored scenes working.
- `world/environment/foliage_wind.gdshader` — the per-instance `instance uniform`s are gone; they
  never reached MultiMesh copies. Phase now comes from the copy's own transform, the wind direction
  is rotated into model space so each prop's yaw stops making it lean its own way, and
  `vertex_phase` lets small assets take phase from world position so the field keeps rippling
  per-plant if F-098 later merges the batches into static chunk meshes.
- `world/gen/authored_world.gd`, `world/gen/undergrowth.gd` — both stamp the `asset` meta on what
  they emit, reusing the meta the harvestable holders already carried, and publish a `placements`
  array for assets whose presentation is per-copy (F-103).

**Verified** — `agent godot --script tools/environment_vfx_hollowmere_check.gd`, which reads
`main_scene` out of `project.godot` so it can never again be pinned to a map nobody plays:

```
CENSUS   mesh_instance3d=2809 multimesh_instance3d=1740 multimesh_copies=13026
WIND     multimesh_nodes=1183 mesh_nodes=2508 swaying_copies=9972 assets=197
EMITTER  CAMPFIRE sites=2  EMBER sites=2  FORGE sites=1  CRYSTAL sites=101  SPORE sites=163
BUDGET   sites=269 effect_nodes=23 live=23
failures=0
```

Every site count matches what `world/gen/layouts/hollowmere.json` actually holds (2 campfires, 2
cooking spits, 1 stone furnace, 99 mire crystals + the wellspring and ward crystals, 163 tendrils),
which is the assertion that catches F-103's collapse-to-origin failure — a count-based check cannot.
**269 emitter sites cost 23 effect nodes**, which is the scalability property a generated world
needs. Also green at 0 failures and 0 engine-error lines:
`tools/environment_vfx_check.gd` (Playtest Hollow, 8,378 wind meshes through the name-fallback path),
`tools/multimesh_readback_check.gd` (new, guards F-103), `tools/verify_setup.gd`, and a clean
`agent godot --quit-after 5` boot of the real main scene.

**Not done here, deliberately:** nobody has *looked* at it. Headless cannot screenshot (F-077), so
the numbers prove wind and firelight reach the geometry, not that the sway rates and light colours
read well. That judgement is Sequoyah's and the tuning knobs are all in `SWAY_PROFILES` and
`EMITTER_PROFILES`.

---


### F-106 · A neighbour's half-finished refactor breaks every other agent's checks, and the failure looks like your own — **fixed**

**Area:** tooling · **Severity:** medium · **Found:** 2026-08-18 by bram1

Six agents boot the project out of **one** shared working directory. A script somebody is halfway
through refactoring is therefore a parse error in everybody's verification run, and the error names a
file rather than a person — so it reads as your own regression. Both honest responses to that are
wrong: chase a bug you did not write, or edit a file another agent holds.

Observed directly, 2026-08-18. `agent godot --script tools/crafting_check.gd` died on
`Parse Error: Function "_load_dir()" not found in base self` at `autoload/registry.gd:60`. The calls
existed at lines 60-64, the definition did not, and `_load_dir` does not appear at HEAD at all —
kiln9 was mid-refactor with that file under claim. Minutes later the same check passed 7/7 without
anyone touching anything, because kiln9 had finished the function. Any agent whose check landed in
that window would have had a failure with no owner on it. LP was mid-F-037 at the time, and that
check boots the autoloads.

**Fixed:** `agent godot` now watches the engine output it streams. When a `SCRIPT ERROR` / `Parse
Error` names a `.gd` the caller does not own, it prints who does — the claim holder and their task,
or "uncommitted, and claimed by nobody" — tells the caller not to edit it or chase it, and points at
`agent baseline --script <check>` to confirm against a clean checkout. A file the caller itself
claims is skipped: that break really is theirs.

**The non-obvious part, and the reason a first attempt of this did nothing:** it must NOT be gated on
the exit code. Measured — Godot exits **0** when a script fails to load outright with a parse error,
which is exactly the failure being warned about. This is the same trap that makes every check in
`tools/` print its own `failures=N` rather than trust `$?`.

**Verified:** a deliberately broken probe script fires the warning and names it as uncommitted and
unclaimed; `wave_spawner_check` (16 PASS, failures=0) stays silent, so a passing run gains no noise;
`crafting_check` streams and passes unchanged. The probe was removed after each run.

---

### F-053 · Agents still told Sequoyah they can't edit scene files; the docs' hand-off-by-default tone was why — **fixed**

**Area:** docs/process · **Severity:** medium · **Found:** 2026-08-17, from Sequoyah directly ·
**Resolved 2026-08-18 by yarrow21.**

D-031 already *permits* Godot-file edits under exact claim with the editor closed — but permission
is not disposition, and several documents still carry the old default: `AI-WORKFLOW.md`'s Tier 0
framing reads as "editor work belongs to the human" and calls agents "consistently bad" at UI
layout; `ASSET_TRACKER.md` says "Sequoyah adds simple collision and scene wiring in the editor when
needed" and "Godot scene hookup remains Sequoyah's work"; nothing anywhere states the rule Sequoyah
actually wants: **an agent never hands him work it could do itself unless he is significantly
faster.** Recorded as D-039; this finding is the doc alignment.

**Fixed.** Two of the three documents had already been brought into line by the tasks that owned
them, and were re-read to confirm it rather than taken on trust: `AI-WORKFLOW.md`'s Tier 0 heading
now reads "a cost label, not an ownership rule (D-039)" and names the only two T0 items an agent
genuinely cannot do (playtesting, and how something feels); `ASSET_TRACKER.md` now says scene hookup
is done by whichever task needs it under D-031 claims, with visual tuning staying his.

What was left was the sentence blocked behind 2.1j's claim when this was filed, and it was the worst
one — the *first* thing AGENTS.md said about roles: "Sequoyah (human) is the only fixed role:
**Integrator** — all Godot editor work, asset import, tuning, playtesting, commits." An agent that
read only the top of the protocol came away believing editor work was not its to do, and it was
right to, because that is what the document said. It now states D-039 positively and in the same
breath as the mechanical rules, so the two cannot be confused for each other:

> He is **not** the person who does your editor work. **An agent never hands him something it could
> do itself, unless he would be significantly faster (D-039)** … The exact-file claim on
> `.tscn`/`.tres`/`.import` with the editor closed (D-031), and `agent autoload` for
> `project.godot` (F-051), are corruption protection, not permission gates. "You'll need to wire
> this up in the editor" is not a hand-off; it is the part of the task you have not finished.

That last distinction is the whole finding. D-031 and F-051 exist because Godot's editor overwrites
files and `project.godot` does not merge — mechanical hazards with mechanical answers. Read as
*permission* rules they became a standing excuse, and the excuse cost Sequoyah a hand-off on every
task that touched a scene.

**Verified** by reading, which is what a docs finding admits of: no remaining sentence in
`AGENTS.md`, `docs/AI-WORKFLOW.md` or `docs/ASSET_TRACKER.md` assigns editor work to Sequoyah by
default. `CLAUDE.md` already carried the rule as non-negotiable #2 and needed no change — the gap
was in the shared protocol that Codex and the dispatched lanes read.

---

### F-037 · `net_debug_panel_check` fakes its second peer in-process, so host and client share one tree — **fixed**

**Area:** tests/netcode · **Severity:** low · **Found:** 2026-08-16 by dusk3 while fixing F-021 ·
**Resolved:** 2026-08-18 by lp.

F-021 fixed the uninitialized-root errors, but the harness still emitted two:

```
ERROR: Condition "parent->has_node(name)" is true. Returning: ERR_INVALID_DATA
```

Cause: the "client" was a second `MultiplayerAPI` in the *same process*, and F-021's fix correctly
pointed its `root_path` at `/root` so autoload-addressed RPCs resolve — but that is the host's tree
too, so when `PlayerNet` spawned a body for the fake peer, the `MultiplayerSpawner` also replicated it
back into the same container and the name was already taken. Harmless (the panel numbers the harness
checks — RTT, bandwidth, peer list — were all correct), but it was the last thing standing between
this harness and a clean error-free run.

**Fix:** rewrote `_check_real_session()` as a real second process, copying `inventory_net_check.gd`'s
shape exactly (docs/SPECS.md's "Two-process checks" seam) — the driver hosts via `NetTransport`,
spawns itself again with `OS.create_process` and a `-- panel-probe` argument, and the two talk through
`user://net_debug_panel_client.json`. Each side reads its own `NetDebugPanel` instance's
`_session_line()`/`_rtt_line()`/`_bandwidth_line()` off its own real ENet connection — no shared tree,
no fake peer, so `MultiplayerSpawner` never sees two claims on one name. The probe's readiness gate
(`is_active()` and `local_peer_id() > HOST_PEER_ID`, same line) follows F-060's rule rather than
reintroducing its trap.

**Verified:** `agent godot --script tools/net_debug_panel_check.gd`, twice back to back —
`0 failure(s)`, `0` lines matching `ERROR:` in either run's output (no declared-error allowance
needed, unlike `session_lifecycle_check`). `agent godot --script tools/net_check_pattern_check.gd`
stays clean — `net_debug_panel_check.gd`'s new ready-gate is correctly flagged as gated
(`gate_reads=9`, `failures=0`), confirming the rewrite didn't reintroduce F-060's trap.

---

### F-038 · `inventory_net_check` intermittently fails its grant wait under machine load, and `combat_net_check`'s sibling flake — **fixed**

**Area:** tests/netcode · **Severity:** medium · **Found:** 2026-08-16 by dusk3 during the findings
sweep · **Resolved:** 2026-08-18 by lp.

Running the four two-process ENet checks back to back, `inventory_net_check` failed 10 assertions with
the client reporting `"error": "grant timeout"` — it never saw the host's granted items inside the
15 s `TIMEOUT_SEC`. An immediate re-run passed with 0 failures, and `harvestable_net`, `crafting_net`
and `combat_net` all passed in the same sequence. **2026-08-17, flint5:** `combat_net_check` showed a
sibling flake — 5 failures on the third of three back-to-back runs, timing out waiting to "complete
both swings and the spam rejection," roughly 1-in-3 on this machine.

**Root cause 1, both checks — confirmed the harness diagnosis.** The driver granted
(`EVENT_BUS.emit_harvest_yielded` / `inventory.host_add`) as soon as the CLIENT self-reported
"connected" (its own `is_active()` + `local_peer_id() > HOST_PEER_ID` + `local_revision() >= 0`),
which can precede the HOST's own `InventoryService` creating that peer's store.
`_publish_snapshot()`'s `rpc_id` send is one-shot, gated on `_peer_connected()`, with nothing to
resend it — a grant landing in that window is lost for the rest of the run. The driver's own
`host_count(peer, item) == 0` assertion looked like a precondition check but wasn't one: it reads `0`
identically whether the peer's store doesn't exist yet or exists and is empty, so it passed either
way and proved nothing. Same class of bug `combat_net_check`'s host-player race was already fixed for
(`player_net.call("player_for", peer_id) != null`, polled). **Fix, both checks:** poll
`(inventory.call("host_slots", peer_id) as Array).size() == 32` before granting —
`host_slots()` returns `[]` before the store exists and a real 32-entry array after, so this actually
distinguishes the two states. D-059 records the general rule.

**Root cause 2, `combat_net_check` only — a second, unrelated flake, found retesting both checks
together per the finding's own instruction.** Reproduced with root cause 1's fix already applied:
`missed_count: 1` on the *second* swing, `axe_damage: 3` (the first, armed swing landed correctly).
`TestTarget` trails an unfloored, permanently-falling player two metres along its forward — the check
predates 2.13's floor-having maps and never gave it one. By the second swing the player's fall speed
has grown enough that `TestTarget._process()`'s one-frame-stale copy of `follow.global_position` can
clear the swung weapon's `vertical_reach_m`, an intermittent miss with nothing wrong in
`CombatService`. **Fix:** `_build_ground()`, the same shape `tools/build_net_check.gd` already uses,
built in both processes (a floor only one side has is its own desync) before the driver/client
branch — removes the unbounded fall instead of loosening the follow or any reach tolerance.

**Verified:** `agent godot --script tools/net_check_pattern_check.gd` clean (0 failures, neither
F-060 trap reintroduced). Two full back-to-back sequences of `inventory_net_check` /
`harvestable_net_check` / `crafting_net_check` / `combat_net_check` (the original repro shape) —
`failures=0` and 0 undeclared `ERROR:` lines, every check, both passes. `combat_net_check` alone: 8
consecutive runs post-fix, `missed_count: 0` every time (a pre-fix baseline reproduced a miss within
2–6 runs). `inventory_net_check` alone: 3 consecutive runs, `failures=0`. Full spec and file list:
`docs/SPECS.md` F-038.

---

### F-077 · `agent godot` was always headless, so no in-engine screenshot could be captured — **fixed**

**Area:** tooling · **Severity:** medium · **Found:** 2026-08-18 by ivy8 during 2.1k · **Resolved
2026-08-18 by yarrow21.**

`tools/hollowmere_render_check.gd` exists to let the map be *looked at* without opening the editor,
and it cannot: `agent godot` passes `--headless`, headless has no framebuffer, and the script
correctly prints `capture skipped`. The only documented alternative is to run Godot bare, which is
what `agent godot` exists to prevent (F-044 — the shared import cache).

So between "the validator passed" and "a human opened the editor" there is nothing, on a project whose
whole point is that agents verify their own work. 2.1k worked around it with
`tools/mapgen/hollowmere_plan.py`, which draws the layout as a plan view in pure Python — useful, and
not a screenshot.

**What to do about it:** `agent godot` should take a `--windowed` passthrough that keeps the lock and
drops `--headless`, which is a few lines in `.agent/bin/agent` and makes every render check usable.
It was left alone here because that file belongs to the whole protocol and this was a map task.

**Correction, 2026-08-17 by flint5 during F-073 — no tool change is needed, this already works.**
`cmd_godot` builds `[binary, "--headless", "--path", ROOT] + args`, and because your arguments are
**appended**, a later flag wins. Appending `--display-driver macos` overrides the injected
`--headless` while keeping the lock and the wrapper:

```bash
.agent/bin/agent godot --display-driver macos --resolution 64x64 --position 2400,1400 \
  --script tools/hollowmere_render_check.gd
```

`--resolution 64x64 --position 2400,1400` shrinks the OS window and parks it offscreen; a
`SubViewport` still renders at its own full size, so the capture is unaffected. Verified against the
*unmodified* `tools/viewmodel_check.gd`, which goes from `capture skipped` to four real 1280x720 PNGs
of the running game — that is how both the F-073 bug and its fix were confirmed. Two cautions: a
script that errors inside `_initialize()` before its `call_deferred` hangs forever with no main loop
to quit it, so keep `--quit-after` or an external kill guard; and this opens a real window, so it is
for a deliberate render run, not for every check.

So this can be closed without touching `.agent/bin/agent`. Left in Open rather than moved because it
is 2.1k's finding and `hollowmere_render_check.gd` is ivy8's file to re-run.

**Fixed** by making it a flag instead of an incantation. `agent godot --windowed --script
tools/viewmodel_check.gd` *drops* the injected `--headless` rather than overriding it, keeps the
lock, and parks a 64x64 window offscreen at 2400,1400 — a `SubViewport` still renders at its own
full size, so captures are unaffected. The injected flags go first and the caller's last, so an
explicit `--resolution` of your own still wins; `--windowed` is consumed by the wrapper and never
reaches the engine. `agent baseline` accepts it too — both build their argv through one
`_godot_argv`.

flint5's append-override trick above still works and is still worth knowing. But a correction buried
in a finding is not a feature: it was findable only by someone who already knew to look, which is
how this stayed open for a day after it had been solved.

**Verified** end to end. `agent baseline --windowed --script tools/viewmodel_check.gd` printed
`VIEWMODEL_CHECK failures=0` and wrote four real 1280x720 PNGs to `/tmp` — first-person axe
mid-swing over Hollowmere, hotbar and vitals drawn, the sky and undergrowth from F-090's work all
present. The same check headless prints `capture skipped`. Two cases in `tools/harness_check.py`
pin the argv (headless by default; `--windowed` drops it, parks the window, and does not leak the
flag through to the engine), both failing against the previous harness.

---

### F-080 · `git stash` in this repo stashed every other lane's uncommitted work too — **fixed**

**Area:** tooling · **Severity:** high · **Found:** 2026-08-17 by flint5 during F-073 · **Resolved
2026-08-18 by yarrow21.**

AGENTS.md warns against `git add -A` because several agents share one working directory. `git stash`
is the same hazard and a worse one: it is repo-wide by default, so it rips out every other lane's
uncommitted files at once. I used it to establish that an `item_icons_check` failure pre-dated my
change, and in doing so briefly stashed an in-flight `autoload/registry.gd` plus five files belonging
to task 2.1k. The pop succeeded and nothing was lost — but that was luck. A concurrent write inside
that window, or another agent reading its own file mid-stash, and it would not have been.

**Fixed** by building the safe path rather than only writing the rule down, because "remember not to
use the obvious command" is a rule that survives exactly as long as nobody is in a hurry.
`agent baseline` checks a revision out into a throwaway worktree, runs what you give it there, and
removes it:

```bash
agent baseline --script tools/steam_check.gd        # the check, at HEAD
agent baseline --rev 4aa5d43 --script tools/x.gd    # at some other commit
agent baseline python3 tools/harness_check.py       # anything else; cwd is the checkout
agent baseline --keep --script tools/x.gd           # leave it behind to poke at
```

A leading `-` means engine arguments (same shape as `agent godot`, same lock, exit code propagated);
anything else is a command to run. The parts that are not obvious, and are the reason this is a
command rather than the `git worktree add` line this finding originally suggested:

- **A bare checkout of this repo does not run.** `addons/godotsteam` is ~95 MB of binaries kept out
  of git (D-022) and `.godot` is the import cache; without them a baseline measures a broken project
  and cheerfully reports that your change broke something. Both are grafted in with APFS
  copy-on-write clones (`cp -Rc`), so ~190 MB costs no disk and no wait — the whole round trip,
  checkout to cleanup, is under a second, and 1.4 s with a real headless engine run inside it.
- **Cloned, not symlinked.** A symlinked `.godot` would point two Godot processes at one import
  cache, which is F-044 exactly. A symlinked `addons/godotsteam` additionally fails to match
  `.gitignore`'s `/addons/godotsteam/`, so it shows up as untracked inside the checkout and misleads
  anything that reads git status there.
- **The worktree path carries the pid**, not just the short sha. Two lanes asking the same question
  about the same commit at the same time is ordinary, and cleanup is `worktree remove --force` — a
  shared path would mean one lane deleting the other's checkout mid-run, which is F-080 again
  wearing the uniform of its own fix.

The rule now sits beside the `git add -A` rule in AGENTS.md, where the same reasoning produces it.

**Verified** by two new cases in `tools/harness_check.py` (7/7): a baseline run reads the *committed*
content of a file the working tree has modified, and the shared tree's `git status` is byte-identical
before and after with no worktree left registered. Both fail against the pre-baseline harness. Also
run for real here — `agent baseline --script tools/steam_check.gd` loaded the GodotSteam extension
inside the throwaway checkout (`736 methods, 2003 constants`) and reached the same
Steam-client-not-running failure the shared tree gives, in 1.4 s total. The graft is doing its job.

**Not fixed, and not fixable from here:** git has no pre-stash hook, so nothing can *block*
`git stash` in this repo. This is a better road, not a fence.

**Correction, 2026-08-18 by yarrow21 (same day, while verifying F-077).** The graft above was
written as "clone the directory unless it already exists", and `.godot` *always* already exists:
`.gitignore` ignores `.godot/*` but un-ignores `.godot/extension_list.cfg`, so a fresh checkout has
a `.godot` holding exactly one file. The import cache was therefore never grafted at all, and the
claim above that it was is wrong. Two things were missing with it:

- **The global class cache.** Without `.godot/global_script_class_cache.cfg`, every `class_name` in
  the project is "not declared in the current scope", so any check naming one fails to parse.
- **`*.import` sidecars**, gitignored as well (547 files, 1.8 MB) and sitting beside their assets
  rather than in one directory. Without them no `ext_resource` pointing at a `.glb` or `.png`
  resolves, so every `content/items/*.tres` loads as null and reports "does not contain an ItemDef".

Both symptoms read as *this revision is broken*, which is the worst failure available to a tool
whose entire job is telling you whether the revision is broken — it would have sent someone hunting
a bug that did not exist. The graft is now entry by entry with anything git already placed winning,
plus a walk for `*.import`, and `tools/harness_check.py` has a case for each shape. A baseline
`viewmodel_check` run goes from a parse error to `failures=0` and four PNGs. The round trip is ~6 s
with a real engine run rather than the 1.4 s claimed above, which was 1.4 s of not running the
project.

**Also changed:** `baseline` no longer takes the shared `godot` lock. That lock exists for one thing
— concurrent runs corrupting one import cache (F-044) — and a baseline run has its own cache in its
own worktree, so the hazard is absent. Taking it anyway put "did this already fail?" behind whatever
long check a lane happened to be running, which is precisely when the answer is wanted. Not
hypothetical: it is what happened the first time this tool was used, queued behind a 25-minute
check in another lane.

---

### F-086 · The building system has no gameplay caller, so no player can place, rotate, or destroy anything — **fixed**

**Area:** gameplay · **Severity:** high · **Found:** 2026-08-18 by lc1 during the 3.6 review ·
**Resolved 2026-08-18 by lp.**

`systems/building/build_ghost.gd:3` said to attach a `BuildGhost` to the player, but nothing did;
`update_aim()`/`rotate_step()`/`confirm()`/`BuildService.request_destroy()` were reachable only from
`tools/build_check.gd`'s own private ghost. Fixed by wiring the local presentation/input path
straight into `entities/player/player_controller.gd`, the only production caller a player ever runs
through:

- **`BuildGhost` and a new `ui/building/build_bar.gd`** are built eagerly in `_ready()` for the local
  player only (same reasoning as the viewmodel), both hidden until build mode is entered.
  `BuildBar` is **not** an autoload like every other UI in this codebase (`CraftingUI`, `InventoryUI`,
  `VitalsHud`) — `project.godot` was held by another lane's task (F-095) as this shipped, so it
  follows `ui/hud/vitals_hud.gd`'s own EAT_KEY precedent instead: no new InputMap action, no
  autoload registration, everything reachable through a direct child reference or the existing
  `/root/BuildService` and `/root/Registry` singletons.
- **Input**: the existing "build" action (3.6) toggles the mode — `is_build_mode_active()` reads
  `BuildGhost.visible` directly rather than a second flag, so the two can never disagree. Rotate (R)
  and destroy (right-click) are raw input, same EAT_KEY reasoning as above. Confirm reuses the
  existing "attack" action: build mode is checked first, in the same function, before the existing
  combat routing, so a click can never both swing and place regardless of node traversal order.
  Selecting a piece from `BuildBar`'s own slot click reaches the ghost through one seam
  (`PlayerController.set_selected_build_piece()`), the same one a bare toggle-on's auto-selected
  default piece uses.
- **Destroy targets independently of what's selected to place** — `BuildGhost.aim_destroy_target()`
  is a second ray (new method, matches `BuildService.PIECE_GROUP` by a duplicated literal, same
  reasoning `harvest_world.gd`'s own `HARVESTABLE_GROUP` duplicate uses) so a player can tear down an
  existing piece while a different one (or none) is queued to place.
- **F-101 filed, not fixed here**: build-mode confirm and `harvest_world.gd`'s own independent
  "attack" listener are not mediated against each other; the only fix touches a file outside this
  task's claim.

Verified with a new `tools/build_check.gd` section, `_check_player_integration()`, that drives a
**real** `entities/player/player.tscn` through the exact input events a player sends — the real
`"build"` action, a real `BuildBar` slot click, a real `R` keypress, the real `"attack"` action, and a
real right-click — rather than constructing a private ghost, closing the finding's own complaint.
`agent godot --script tools/build_check.gd` — `failures=0`. `tools/build_net_check.gd` — `failures=0`,
unaffected (its own scenarios drive `BuildService` directly, never through a player).

---

### F-098 · Draw-call discipline: what DOOM and Roblox actually do, dynamic resolution shipped, batching handed to F-100 — **fixed**

**Area:** perf · **Severity:** medium · **Found:** 2026-08-18 by coil23 · **Resolved 2026-08-18 by
coil23.**

Sequoyah asked why DOOM 2016 and Roblox reach hundreds of fps. The research answer, condensed:
**draw-call discipline plus precomputation plus resolution flexibility.** DOOM renders a typical
frame in ~1,331 draw calls (clustered forward renderer), caches the static portion of every shadow
map and composites only dynamic casters, precomputes aggressively, and dynamically scales render
resolution to hold 60. Roblox collapses identical meshes into single draws, merges static geometry
into clusters, and auto-degrades quality tiers on weak devices. MIRE at the time of asking: 5.4k
draws — the gap is structural, not shader-deep.

**Shipped here: dynamic resolution** (`GraphicsQuality.set_dynamic_scale()`, console
`gfx auto [<fps>|off]`). Steps `scaling_3d_scale` between 0.59 and the active preset's own scale,
every 0.5 s, down fast / up slow, steering by fps (Metal's GPU timer reads 0 in this build,
F-090). Probe row "13 dynamic res @240": against an unreachable target the controller drove scale
to its floor and held **204 fps / 4.98 ms** — vs 149 fps at native. Off by default; it is the
worst-computer safety net, not the look.

**Not shipped here: static chunk batching** — `world/gen/authored_world.gd` was claimed by
larch10 (F-097, VFX wiring) mid-task; per protocol the full design moved to **F-100**, claimable
the moment that file frees. Cross-checked against F-097: sway/fire VFX key off materials, and
F-100's material-bucketed merge preserves material identity, so the two do not fight.

Verified: probe fullscreen (14 rows), `flora_check` / `atmosphere_night_check` /
`day_night_check` / `hollowmere_check` all pass.

---

### F-081 · Every ship blanket-staged `.agent/`, so one agent's commit carried another's in-progress harness edits — **fixed**

**Area:** tooling · **Severity:** medium · **Found:** 2026-08-18 by ivy8 · **Resolved 2026-08-18 by
yarrow21.**

`cmd_ship` stages `[f for f in changed if f.startswith(".agent/")]` for **every** task, not just the
ones that touched the harness. The intent is coordination state — `BOARD.md`, `JOURNAL.md`,
`state.json` — which every task legitimately updates and nobody claims. But the glob does not stop
there: `.agent/bin/agent` and `.agent/bin/lane` are source code that a director may be halfway
through editing, and they sit under the same prefix.

Observed directly, 2026-08-18. The director (ivy8) was editing `.agent/bin/agent` and
`.agent/bin/lane` to fix F-070. Before it shipped, reed16 ran `agent ship F-078` for an unrelated
content-validation task, and commit `882993d` — titled *"F-078: PowerupDef validates its
vocabulary"* — carried both harness files with it. By the time the director shipped F-070, its own
fixes were already committed under another agent's name and message, so `058aace` contains only the
findings write-up and the change log for the code is in the wrong commit.

This is the same hazard F-014 and F-034 were written for, and it dodged both: the no-blanket-add
rule stages only what a task claimed, but `.agent/` is exempt from claims by design, so nothing
checks whether the shipping task has any business with these files. It got lucky here — the harness
happened to be in a compiling state at that instant. A ship landing 90 seconds earlier would have
committed an `agent` with a `NameError` at import, which every lane and every hook shells out to.

**Fixed** by replacing the glob with an allowlist and giving harness source the same rule as any
other source. Three changes, all in `.agent/bin/agent`:

- `COORDINATION_PATHS` names the generated files explicitly — `.agent/BOARD.md`, `.agent/JOURNAL.md`,
  `.agent/state.json` — and `cmd_ship` stages `f in COORDINATION_PATHS` instead of
  `f.startswith(".agent/")`. An allowlist rather than a `.agent/bin/` exclusion, because the failure
  here was a glob reaching further than its author meant it to, and an exclusion list has the same
  shape as the thing that broke. The cost is bounded and visible: a future generated file nobody adds
  to the list shows up in ship's "left alone" block instead of being carried silently.
- `UNFREE_PREFIXES = (".agent/bin/",)` carves the harness back out of `FREE_PREFIXES`, so `agent
  check` stops treating it as claim-free. An unclaimed harness edit now warns, and committing a
  harness file another agent holds is blocked outright.
- Ship's "left alone" block now names any harness file it declined to carry, and states the rule.
  That is not decoration — the fix opens a new way to lose work. A director who edits the harness
  without claiming it used to have it committed by *someone else*; now it is committed by *nobody*,
  and ship's output is the moment they would notice. Claim harness source under the task that edits
  it, and claim it before `agent done`: `ship` reads its file list from `recent`, which only `done`
  populates.

**Verified** by `tools/harness_check.py`, new with this fix — the harness had no automated test of
any kind before it, despite being the file every lane, every hook and every check shells out to. It
builds a throwaway git repo, copies a real `agent` into it (so `ROOT` resolves there, not here), and
drives real `ship`/`check` runs against a reconstruction of the 2026-08-18 scenario: task 9.9 ships
one ordinary file while another agent has uncommitted edits to `.agent/bin/agent` and
`.agent/bin/lane`. Five cases — the stowaways stay out of the commit; they stay in the *working
tree* (a scoped reset would lose them just as thoroughly as a commit); coordination state still
ships; harness source *does* ship for a task that claimed it; and `check` blocks a harness file
another agent holds.

```bash
python3 tools/harness_check.py              # 5/5 on the fixed harness
python3 tools/harness_check.py --rev HEAD   # 3/5 on the harness as of b0d7d57
```

The `--rev` form is the red half, and it is why the check is worth keeping rather than deleting
after the fix: against b0d7d57 the first two cases fail with `ship carried harness source it had no
claim on: ['.agent/bin/agent', '.agent/bin/lane']`, which is F-081 reproduced from a cold start. The
three cases that pass at *both* revisions are the guard against over-correcting.

---

### F-095 · Post-F-090 frame/load seams: world build was 9 s of duplicate work; two frame ideas measured and rejected — **fixed**

**Area:** perf · **Severity:** medium · **Found:** 2026-08-18 by coil23 · **Resolved 2026-08-18 by
coil23.**

Three hypotheses went in; the probe kept one and killed two. All three outcomes are the record.

**The win — world build 9,145 ms → 117 ms warm.** New per-phase timing
(`AUTHORED_WORLD ... phase_ms=[...]`) showed `props=9,055` of 9,145. Two causes, both fixed:

1. **`cache.get_or_add(key, _mesh_parts(kit, asset))` evaluates its default argument EAGERLY** —
   the merge ran once per (chunk, asset) *group* (1,028×, plus 83 harvestables) while the cache
   sat there preventing nothing. Both call sites now test `has()` first. This trap is repo-wide:
   never pass an expensive call as `get_or_add`'s default. Fix alone: 9,145 → 2,865 ms.
2. The ~40 genuine merges are now **disk-cached to `user://mesh_cache/<kit>_<asset>_<mtime>.res`**
   (`FLAG_BUNDLE_RESOURCES|FLAG_COMPRESS`; a stamp change orphans the entry, a torn file loads
   null and rebuilds over itself). Warm loads: **117 ms**. A player's first-ever load still pays
   ~2.9 s — baking merged meshes at *export* time is the durable fix and belongs to the art
   pipeline (2.1j-adjacent), not to a runtime cache.

**Rejected with numbers — do not re-attempt without new evidence:**

- **Flora part-merge in the scatter.** The flora exports are already ONE mesh part each (the
  pre-F-090 scatter's 78 assets cost exactly 78 multimeshes — the proof was on screen the whole
  time), so the merge's de-indexing only threw away vertex reuse on smooth-shaded meshes:
  primitives 1.6M → 3.6M, baseline 6.77 → 6.97 ms. Reverted; `undergrowth.gd` carries the
  warning above `_emit`.
- **Terrain under-shell occluder + raster occlusion culling.** Hollowmere is a bowl: from inside,
  the ridge occludes only the outside. ~2 draws culled, real per-frame CPU raster paid. Reverted
  (project setting included); worth retrying only for worlds with blocking sightlines —
  interiors, canyons — and only probe-verified.

**Also measured: night is not a cliff.** New probe row jumps to 02:00 (which fires
`night_started` and spawns a live wave): **158 fps / 6.26 ms** — stars + moonlight + wave
enemies cost about the same as day. No night-specific work needed at current enemy counts.

Verified: probe ×2 (cold + warm), `--quit-after 30` warm load at 117 ms, `flora_check` /
`atmosphere_night_check` / `day_night_check` all 0 failures.

---

### F-083 · Snapping the aim hit's Y coordinate rejects or floats pieces on ordinary terrain heights — **fixed**

**Area:** building · **Severity:** high · **Found:** 2026-08-18 by lc1 during the 3.6 review ·
**Resolved 2026-08-18 by lp.**

`BuildGhost.update_aim()` fed the surface hit directly to `snap_transform()`
(`systems/building/build_ghost.gd:100`), and `snap_transform()` rounded Y to the same metre grid as X
and Z (`systems/building/placement_validator.gd:56`). The support ray began only 0.15 m above that
rounded origin. On flat ground at Y=0.4, the placement rounded down to Y=0, the ray began inside the
terrain, and the validator returned `NO_SUPPORT`; on ground at Y=0.6, it rounded up to Y=1 and
accepted a wall floating 0.4 m above the surface. Hollowmere is not restricted to integer-metre
elevations, so this broke placement across the shipped map rather than at an exotic edge case.

**Fixed:** `snap_transform()` now snaps X and Z to `snap_step` as before but leaves Y exactly as
given (D-056). `origin.y` is never an arbitrary value that needs rounding — it is wherever the
caller's physics ray actually hit, so preserving it places the piece flush with the real surface,
terrain or another piece's top. That last part means flush stacking needs no separate anchor rule:
a ray against an already-placed piece reports that piece's own exact top surface, satisfying the
finding's "vertical snapping for stacked pieces needs an explicit anchor" concern for free — see
D-056 for what would change that call.

**Verified:** `agent godot --script tools/build_check.gd` — new `_check_ground_height_is_preserved()`
reproduces the review's exact probes (isolated flat pads with top surfaces at y=0.4 and y=0.6) and
asserts both evaluate to `OK` with the height unchanged, plus an end-to-end assertion that
`BuildGhost.update_aim()` aiming straight down at the y=0.4 pad keeps the ghost at 0.4 rather than
snapping to 0. `failures=0` (reran twice). `tools/build_net_check.gd` (13 assertions, two real ENet
processes) also `failures=0`, unaffected — it never places on non-integer ground.

---

### F-096 · The quota parser only understands the word reset, so Codex's dated try-again message falls through to a blind five-hour default — **fixed**

**Area:** tooling · **Severity:** medium · **Found:** 2026-08-18 by bram1

`parse_reset` anchors `CLOCK_PAT` and `CLOCK24_PAT` on the literal word `reset`, and has no pattern
for a calendar date at all. Codex does not use that word: it says *"or try again at Aug 19th, 2026
8:57 PM."* Nothing matched, so `cmd_run` fell through to its blind fallback — `now + 5 hours` — and
parked the lane for five hours over a wall that had **thirty-nine** hours left on it.

Observed on LC1, 2026-08-18. Its weekly window was exhausted, and the account said so precisely in
the failure body every single time. The harness recorded 10:08Z, then 12:07Z, then 17:08Z — three
five-hour guesses in a row. Each expiry woke the chain, spent a dispatch discovering the wall was
still there, and re-guessed. Left alone it would have burned `MAX_RESUMES` and exited, stranding a
queued review that nothing would then restart. The one piece of information that would have prevented
all of it was sitting in `last_error` the whole time.

Worth noting the shape of the failure: a bare clock pattern is *more* dangerous than no pattern here,
because "8:57 PM" also appears in the dated message. Had `CLOCK_PAT` matched it, `parse_reset`'s
"next time that clock reads it" rule would have returned Aug 18th 8:57 PM — confidently, and a full
day early.

**Fixed:** the clock patterns now anchor on `(?:reset\w*|try again)`, and a new `DATE_PAT` handles the
month-name form (`Aug 19th, 2026 8:57 PM`, `Sep 3, 2026`), tried *before* any clock-only pattern
precisely because a stated date is the only wording that can be more than 24 hours out. A dated match
with no time defaults to midnight local, which parks slightly long rather than slightly short.

**Verified:** `lane selftest` is 23/23 with three new samples covering the dated form, a dateless
`try again at 8:57 PM`, and a date with no clock. Against LC1's verbatim message, `parse_reset` now
returns `2026-08-20T03:57:00+00:00` where it previously returned `None`. LC1 has been re-parked to
that stamp and `lane-revive` re-armed for 04:02Z on the 20th.

---

### F-090 · Frame budget audit: ~100 fps where hundreds are expected — **fixed**

**Area:** perf · **Severity:** high · **Found:** 2026-08-18 by coil23 · **Resolved 2026-08-18 by
coil23.**

Hollowmere rendered at ~107 fps (9.3 ms median) fullscreen on the M5 Pro (3024×1898 retina backing
store) — and vsync was **not** the cap: disabling it changed nothing, the frame was genuinely that
slow. `tools/perf_probe.gd` (new) launches the real level fullscreen and toggles one suspect per
config; reading the code had ranked the suspects wrong, which is why the probe exists:

- **Undergrowth: −4.1 ms of 9.3** — ~10,240 plants in 78 *map-wide* MultiMeshes. One map-sized AABB
  per asset means frustum/distance culling can never discard anything, and every plant fed the main
  view plus all four PSSM cascades (its shadow share alone was −2.4 ms).
- **Sun shadow pass: −3.1 ms** — 5,069 total draw calls, ~3,700 of them shadow-pass.
- **Per-tick sun/sky writes: −0.3 ms** — DayNight re-applies atmosphere every physics tick;
  identical-value rewrites of PhysicalSkyMaterial plus a sun transform that moved ~0.001°/tick kept
  the sky radiance perpetually regenerating.
- **Volumetric fog — suspected from reading, measured innocent: −0.2 ms.** Glow −0.65 ms.
  Render resolution (50% scale) −2.2 ms, recorded as the biggest preset lever.

**Fixes** (all verified by re-probing): undergrowth scatter now buckets into 48 m cells — one
MultiMesh per (asset, cell), each positioned at its cell centre *including mean ground height*
(visibility ranges measure to the node origin; an origin at y=0 would cull a plateau's plants
standing next to you), ground cover (merged AABB < 0.75 m) casts no shadows and fades by 60 m,
taller flora keeps shadows to 110 m; `playtest_atmosphere.gd` steps the applied sun hour at 0.005 h
(~0.1° / ~5 Hz at the 900 s day, under the sun's own 1.1 shadow blur) and skips all material/
environment writes while its drivers hold (every tick outside dawn/dusk); hollowmere's Sun
`directional_shadow_max_distance` 105 → 85 (flag for Sequoyah's eyes at next playtest; casters past
85 m read as nothing at this art scale); `vsync` console command in DevFrameCap (default stays ON —
measured free below refresh, and it is what pins the counter to 120 once the frame is faster than
the panel); **GraphicsQuality autoload** (see D-055) with `gfx low|medium|high`.

**After** (same probe, same machine): shipped default 120 fps vsync-pinned (was 107); uncapped
**149 fps / 6.77 ms**; preset medium **190 fps**; preset low **283 fps / 3.54 ms** with draws
5,399 → 3,324 — and low's relative win grows on the weak-iGPU machines it exists for. Regression
checks `flora_check`, `atmosphere_night_check`, `day_night_check`: 0 failures; rescatter returns to
an identical full field (±2 plants when a wandering enemy body intercepts a probe ray —
presentation-only).

**Still open for the worst-computer target** (release worlds are generated; the *patterns* are the
deliverable — undergrowth.gd is the reference): the world generator must inherit chunk + height-tier
+ range for everything it scatters; ~2,144 main-view draws remain (authored kit merges at
`_mesh_parts`, already chunked); Metal reports 0 through `viewport_get_measured_render_time_gpu` in
this Godot build, so the probe infers GPU cost from frame deltas; FSR2 vs bilinear at reduced scale
is 7.5's evaluation to run.

---

### F-085 · Buildables join `damageable` without implementing its required damage method — **fixed**

**Area:** building · **Severity:** medium · **Found:** 2026-08-18 by lc1 during the 3.6 review ·
**Resolved 2026-08-18 by lp.**

`BuildService._net_spawn_piece()` added every piece to `&"damageable"` but neither generated pieces
nor authored-scene roots gained `host_apply_damage(amount, instigator_peer_id) -> bool` — the group's
documented contract, which `CombatService._best_target()` explicitly requires
(`autoload/combat_service.gd:251`). The shipped check asserted only group membership and claimed that
proved the piece could be attacked, so it passed while weapons could not target or destroy a
buildable.

**Fix:** a new `systems/building/buildable_piece.gd` (`extends Node3D`, no `class_name` — it is
attached dynamically, never instantiated directly) is the group's actual implementation:
`host_apply_damage()` re-checks host authority itself (same `_owns_world_mutation()` shape as
`Harvestable`/`Enemy`), decrements `hp`, and on lethal damage calls a new
`BuildService.host_piece_destroyed_by_damage(piece_name, instigator_peer_id)`. `_net_spawn_piece()`
attaches this script to whichever piece root doesn't already carry `host_apply_damage` of its own —
today that is every piece, since task 3.7's art has no scripts yet, but an authored root that brings
a richer implementation (staged damage states) is left alone rather than clobbered.
`BuildableDef` gained `max_hp: int = 25` (new `Combat` export group, validated non-positive same as
the other numeric fields) — host-only and deliberately unreplicated, same reasoning as `hp` itself:
nothing shows chip damage yet (task 3.7), and a piece's existence already replicates through
`MultiplayerSpawner`'s despawn the moment the host `queue_free()`s it (D-023). Destruction by damage
refunds nothing, unlike a teardown request — a piece fought and lost is not one its owner meant to
reclaim, matching `Harvestable`/`Enemy` never paying out on death either.

`tools/build_check.gd` no longer treats group membership as proof: it asserts `has_method` directly,
calls `host_apply_damage` for a nonlethal hit and confirms the piece still stands, then (new
`_check_damage_destroys_piece`) places a second piece, kills it with a lethal hit, and confirms
`BuildService` forgets it, the node frees, no refund lands, and a nav rebake was queued — the same
shape `_check_host_placement`'s teardown test already used for `request_destroy`.

**Verified:** `agent godot --script tools/build_check.gd` — `BUILD_CHECK failures=0`, two clean
reruns, zero `ERROR:` lines. `agent godot --script tools/combat_check.gd` also still passes
(`COMBAT_CHECK landed=1 missed=2 rejected=1 failures=0`) — buildable pieces becoming real targets
changed nothing about combat's own harvestable/enemy-only scenarios.

---

### F-082 · Placement support succeeded when only one of five footprint probes hit — **fixed**

**Area:** building · **Severity:** medium · **Found:** 2026-08-18 by lc1 during the 3.6 review ·
**Resolved 2026-08-18 by lp.**

`PlacementValidator._probe_support()` skipped missing probes and returned the flattest hit it found
(`systems/building/placement_validator.gd:197`). `evaluate()` therefore treated any non-empty result
as supported (`systems/building/placement_validator.gd:101`). A 2 m wall resting on a 20 cm pillar
under its centre returned `Reason.OK` even though all four corner rays missed; a cliff-edge piece was
similarly accepted if only one corner remained over ground. This contradicted the function's stated
reason for using five probes and the spec's support validation.

The review's real-physics probe printed `PARTIAL_SUPPORT reason=ok`.

**Fix:** `_probe_support` now returns `{}` — the same "unsupported" sentinel `evaluate()` already
checked via `is_empty()` — the moment any one of the five probes misses, instead of skipping it and
carrying on. When all five hit, it returns the WORST (steepest) slope among them, not the flattest
survivor, so a single grounded corner can no longer hide three ungrounded ones. There is no authored
field on `BuildableDef` distinguishing "required" from "optional" probes, so the decision (there's no
call for a `D-0NN` here — it falls straight out of the finding's own wording) is that all five count
as required; a piece meant to bridge a gap already has the escape hatch, `requires_support = false`.
Full reasoning and the trap this exposed in the existing test geometry are in `docs/SPECS.md`'s
F-082 block.

**Verified:** `agent godot --script tools/build_check.gd` → `BUILD_CHECK failures=0`, 66 assertions
PASS including three new ones for this fix (pillar-under-centre, one-corner-over-a-cliff, and mixed
flat/steep footprint all correctly resolving to `NO_SUPPORT`/`TOO_STEEP` instead of `OK`), re-run
twice for determinism. `agent godot --script tools/build_net_check.gd` → `BUILD_NET_CHECK
failures=0`, 13 assertions, confirming the host's real placement path over ENet — same validator,
same rule — is unaffected.

---

### F-089 · Powerup lifecycle never removed obsolete family counts from clients, leaving ghost Resonances after reconnect or expiry — **fixed**

**Area:** netcode · **Severity:** high · **Found:** 2026-08-18 by lc1 during the 3.3 review ·
**Resolved 2026-08-18 by lp.**

`autoload/powerup_service.gd:336-351` updated only the host's old peer-id entries. Rebound erased the
old id locally and published the new id through `_commit(new_peer_id)`; expiry erased locally and
published nothing. `net_powerup_counts()` had no other deletion path, so teammates retained the last
family counts for every obsolete peer id and disagreed with the host after either lifecycle event.

`tools/powerup_review_check.gd` reproduced both failures over two real ENet processes: peer 701's
Kinetic count reached the client as 3; after rebound, peer 702 also reached 3 but 701 stayed 3; after
expiry, 702 stayed 3 as well. The check ended `POWERUP_REVIEW_CHECK failures=2`, with one concrete
failure for rebound and one for expiry.

**Fix:** a new `_retire_broadcast(peer_id, before)` in `autoload/powerup_service.gd` is now the shared
tail of both lifecycle events. Called for the *old* id in `_on_run_player_rebound` (before that id's
`_family_counts` entry moves onto the new id) and for the expiring id in `_on_run_player_expired`, it
emits the downward `resonance_changed(peer_id, family, Resonance.NONE)` transition for every family
`peer_id` was resonant in, then — guarded the same way `_publish()` already guards, by
`NetTransport.is_active` — broadcasts `net_powerup_counts.rpc(peer_id, {})` so every teammate's
`_family_counts[peer_id]` reads empty before the host erases its own entry. The rebound path still
moves the pre-rebind counts onto the new id *before* calling `_retire_broadcast`, so `_commit
(new_peer_id)`'s before/after diff sees no change and does not spuriously re-fire `resonance_changed`
for thresholds the player already crossed under the old id — confirmed in the offline
`tools/powerup_check.gd` run, which logs the old id's downward transition and nothing extra for the
new one.

**Verified:** `agent godot --script tools/powerup_review_check.gd` → `POWERUP_REVIEW_CHECK
failures=0`, all 6 assertions PASS including both new ones ("rebound clears the obsolete peer id on
teammates", "expiry clears the departed player's family count on teammates"), zero unlisted `ERROR:`
lines. Re-ran `tools/powerup_check.gd` (offline, 0 failures) and `tools/powerup_net_check.gd` (two
real ENet processes, 0 failures) to confirm no regression to the framework or its replication split.

---

### F-087 · Three open findings share their F-number with a different finding, so brief routes to the wrong one and start reports two of them as already closed — **fixed**

**Area:** tooling · **Severity:** medium · **Found:** 2026-08-18 by ivy8 · **Resolved 2026-08-18 by lp.**

This is F-058's failure mode recurring, and it was costing routing decisions rather than tidiness.
Concurrent lanes each read `agent brief`'s "next number" before either had written, so three numbers
named two different findings apiece:

| Number | Kept (original, already cited by commits) | Renumbered (was colliding) |
|---|---|---|
| F-058 | the meta-finding about duplicate F-numbers, above | → **F-092** · `mire_art.mat()`'s cache never hits |
| F-059 | `InventoryService._publish_snapshot`'s unguarded `rpc_id` (cited by `983da6c`), below | → **F-093** · a headless `--script` run never re-imports changed assets |
| F-060 | two-process net-check authoring traps (cited by `adfaa78`, `abcf9bd`), below | → **F-094** · `mire_art.world_bounds` measures rotated objects through their local box |

Two distinct harms, both observed before the fix:

1. `agent brief F-059` picked one arbitrarily and could hand a lane the wrong finding.
2. `agent start` reported F-059 and F-060 as "closed but still under '## Open'", because it matched by
   number and found the resolved twin — reading both open findings as finished work, which would have
   buried two live bugs (the asset-reimport trap is a correctness gotcha for every headless check in
   the repo) had anyone acted on the warning by moving them to Resolved.

**Fix:** renumbered only the three collided entries (the *later* arrivals in each pair) to F-092/F-093/
F-094, fresh numbers above the prior high-water mark (F-091). The originals — F-058, F-059, F-060 —
are untouched: their numbers are cited by shipped commit messages, and renumbering those would rewrite
history git already carries. Each renumbered entry carries a one-line provenance note (the pattern
F-036 already established) naming its old number and why it moved.

Repointed every reference in `docs/` and `.agent/` that meant a collided finding:

- `docs/ASSET_TRACKER.md`'s A-000V row ("Filed F-058, F-059, F-060") → F-092, F-093, F-094 (it names the
  flora-kit trio, i.e. the collided findings).
- `.agent/state.json`'s `F-059`/`F-060` task titles had been overwritten by the collided findings' text
  (a symptom of the same dict-key collision — `_sync_findings()` mirrors whichever entry it reads under
  `## Open`, and the *last* one read wins). Corrected both titles back to the originals; their
  `status: done` / `done_at` / `done_by` were already correct, since that recorded the real work
  (`agent done F-059`/`F-060`) against the right commits — only the display title had drifted.
  `F-058`, `F-092`, `F-093`, `F-094` need no manual state.json edit: `_sync_findings()` (run via
  `agent board`) adds/refreshes them correctly on its own now that each number maps to exactly one
  open entry.
- **Left alone, on purpose:** `docs/SPECS.md`'s `## F-059` and `## F-060` blocks (about the original
  findings — correct as written); `docs/DELEGATION.md`'s F-059/F-060 mentions (same); `tools/*.gd` and
  `tools/blender/*.py` code comments citing F-058/F-059/F-060 (out of scope per this finding's own fix
  note — `docs/` and `.agent/` only — and F-071's resolution already recorded why: those files are a
  cross-cutting pass of their own, with real collision risk against whoever holds them); `.agent/
  JOURNAL.md` and `.agent/logs/*.jsonl` (append-only history, same principle as not touching numbers
  cited by commits). `docs/FINDINGS.md`'s own F-071 entry still cites "F-058, F-059, F-060" as the
  historical example of the collision — left as written, since it's Resolved and describes what was
  true when gale6 wrote it.
- `F-058` was **not** renumbered and is **not** resolved by this fix — its own text is a different,
  still-open concern (the F-055/F-056 Resolved-section duplicates), which this finding's "cosmetic"
  clause explicitly leaves as historical record.

Also fixed, cosmetic: deduped the literal double-paste of F-052 under Resolved (was two identical
back-to-back headers). Left F-055/F-056's multiple Resolved entries alone, as instructed — no routing
risk.

**Verified:** `.agent/bin/agent board` before the fix showed `⚠ 1 F-number(s) used by more than one
open finding: F-058` and `⚠ 2 finding(s) closed but still under '## Open': F-059  F-060`. After the
fix, both warnings are gone — `_duplicate_findings()` finds no F-number shared by two open entries, and
`_findings_drift()` finds no closed-but-open finding, because the two collided numbers no longer have
an Open entry to disagree with their Resolved twin. `agent brief F-058`/`F-059`/`F-060` now each print
exactly one finding (the original, correctly labelled Open/Resolved as FINDINGS.md says); `agent brief
F-092`/`F-093`/`F-094` print the renumbered ones. `grep -c 'F-058\|F-059\|F-060' docs/FINDINGS.md`
still finds them — as the originals, and as provenance notes on the renumbered entries — never as a
second live heading.

Wrote `tools/findings_numbering_check.gd` as the standing regression guard (source-text scan of
`docs/FINDINGS.md`, `net_check_pattern_check.gd`-style): fails if any F-number heads two entries under
`## Open`, or heads an entry under both `## Open` and `## Resolved`. Self-tested against both injected
defects (duplicated an Open heading's number onto another Open entry; gave an Open heading a
Resolved entry's number) — each correctly failed with the colliding id named, then a clean revert
passed again. `agent godot --script tools/findings_numbering_check.gd` → `open=30 resolved=67
failures=0`. Deliberately does not flag same-number entries where both are Resolved (F-052, F-055,
F-056) — no routing risk, and the "cosmetic" clause above leaves those as historical record on
purpose, so the check would otherwise fail forever against a decision already made.

Wrote `docs/SPECS.md`'s missing F-087 block (this finding had none — SPECS.md's own preamble says
fixing a missing spec belongs to the task that discovers it). Recorded the "renumber only in a
dedicated pass, not ad hoc" policy as **D-053** in `docs/DECISIONS.md`, since two prior findings
(F-058, F-071) had already independently deferred this same renumbering for the same reason and a
third deferral would have been the real bug.

`agent godot --quit-after 120` boots clean — this task touched only `docs/`, `.agent/state.json` and
one new standalone `tools/` script, no gameplay code.

---

### F-084 · Any client can destroy any buildable by its guessable node name from any distance — **fixed**

**Area:** netcode · **Severity:** high · **Found:** 2026-08-18 by lc1 during the 3.6 review ·
**Resolved 2026-08-18 by lp.**

`net_request_destroy()` correctly routed the request to the host, but `_process_destroy()` only
checked that `_placed` contained the supplied name (`autoload/build_service.gd:165`). It never
checked the requesting player's position, range, ownership, line of sight, or any other destruction
rule before freeing shared state and refunding the requester. Names are sequential (`Piece1`,
`Piece2`, ...) at `autoload/build_service.gd:269`, so a guest could remotely delete every structure
on the map and collect each refund by enumerating names. This violated 3.6's "Destruction mirrors
it" contract: host execution alone is not host validation.

**Fix:** `_process_destroy` now resolves the requester's own host-known body through
`_builder_position(peer_id)` — the exact function `_process_place` already trusts nobody about —
and, before any refund or `queue_free()`, refuses with `Reason.OUT_OF_RANGE` ("too far away") if
that body is farther from the piece than the piece def's own `max_build_range_m`. This is scoped
deliberately to range only: **ownership is not checked**, because 3.6 already made "refund goes to
whoever tears it down, not to whoever built it" an intentional design choice (comment left in place
in `build_service.gd`) — any teammate clearing a misplaced piece is meant to work. Line of sight is
out of scope for the same reason placement itself doesn't check it. Decision recorded in
`docs/SPECS.md`'s new F-084 block rather than a `D-0NN`, since it only narrows this one finding's
fix and doesn't bind a future task.

**Verified** with `agent godot --script tools/build_net_check.gd` — the "missing path" the finding
asked for. The driver plants a second piece 100 m from the real client (bypassing `_process_place`'s
own range check via a direct `_spawn_piece` call, since faithfully placing it that far would require
a second player body) and gives it a `_placed` entry; the real client then sends two genuine
`net_request_destroy` RPCs over ENet: the far piece is refused (`"too far away"`, `placed_count`
unchanged, no refund), and the piece the client actually built and is standing beside is destroyed
and refunded `floor(4 * 0.5) = 2 log` as before. 19/19 PASS, `failures=0`, `BUILD_NET_CHECK
failures=0`, zero `ERROR:` lines. The pre-existing offline `tools/build_check.gd` (59 assertions) is
unaffected and stays green — its host peer's body-less fallback position (`Vector3.ZERO`) sits
within `wall_wood`'s 6 m range of every spot it destroys. `tools/net_check_pattern_check.gd` (F-060's
regression guard) stayed clean against the new code: the `_placed` reflection mutation captures to a
`Dictionary` local and `.set()`s it back explicitly rather than chaining off `.get()`.

No RPC was added or changed and no replicated shape moved, so `PROTOCOL_VERSION` did not bump.

---

### F-091 · Two ways the harness lets a fed lane sit idle: a parked lane is never restarted, and a lane's own claim blocks deepening its queue — **fixed**

**Area:** tooling · **Severity:** medium · **Found:** 2026-08-18 by ivy8

Both surfaced on 2026-08-18 while keeping LP and LC1 saturated, and both waste the one resource that
cannot be recovered — a subscription window's unused tokens are gone at reset.

**1. A lane parked past the sleep ceiling is never restarted.** `agent saturate --watch` sleeps out a
quota wall only when the reset is within `MAX_WAIT_HOURS` (8). Beyond that it returns and the chain
exits, correctly leaving its orders queued — but nothing then brings the lane back, so a weekly
window that returns overnight is spent idle until a human notices. LC1 hit this: its five-hour wall
was recorded as `2026-08-18T10:08:04+00:00`, but its **weekly** was the exhausted one, and a chain
sleeping to the five-hour mark would have woken, run `lane reset` (clearing any park), retried
against a dead window, and burned its four resumes for nothing.

**Fixed:** `.agent/bin/lane-revive <LANE> <iso-utc>` — double-fork + setsid daemon (macOS has no
`setsid(1)`, so this cannot be a shell one-liner) that sleeps until the window is due, clears the
park, and relaunches the lane's detached chain. If the window has not actually returned, the first
dispatch is refused cheaply and the lane re-parks itself with a real reset time, so an early estimate
costs one refused probe while a late one costs a day of a fresh weekly window. Armed for LC1 at
`2026-08-18T07:05:00+00:00`.

**2. A lane's own live claim refuses the next order for that same lane.** `cmd_order`'s live-claims
check rejected any file appearing in `state.json`'s claims, regardless of who held it. But one
account runs one agent at a time, so a lane's queue is strictly sequential and the claim is released
before the next order starts — the open-orders loop directly below already reasons exactly this way.
The result was that a lane could not have its queue deepened on the subsystem it was actively
working: ordering F-085 was refused over `autoload/build_service.gd`, held by LP for F-084, the task
immediately ahead of it in the same queue.

**Fixed:** the live-claims check now ignores claims whose holder is the ordering lane itself.
Cross-lane overlap still dies exactly as before — that is the property the claim system exists for.

**Verified:** `agent order F-085 --lane LP --files autoload/build_service.gd tools/build_check.gd`
now writes the order while LP still holds that file for F-084, and `agent report` lists F-085 behind
F-084 in LP's queue. A cross-lane overlap still refuses. `python3 -m py_compile .agent/bin/agent`
clean; `.agent/bin/lane-revive` running detached under pid 1.

---

### F-074 · InventoryService._valid_host_peer's connectivity check silently drops a host grant for a peer mid-D-035-grace-window, instead of parking it — **fixed**

**Area:** netcode · **Severity:** low · **Found:** 2026-08-18 by lp · **Resolved:** 2026-08-18 by lp

`_valid_host_peer(peer_id)` (`autoload/inventory_service.gd`) required `peer_id` to appear in
`_transport().call("peer_ids")` whenever the transport was active — written before D-035's grace
window existed, so `host_add`/`host_remove`/`host_move_stack`/`host_transaction` all rejected a
parked (mid-grace-window) peer outright. A harvest yield landing for someone between a drop and a
reconnect was silently lost, logged only as `MireLog.warn` "could not collect ... (invalid or full)"
by `_on_harvest_yielded`, not queued or retried.

**Fixed:** `_valid_host_peer` now returns true immediately when `_host_stores.has(peer_id)` — a live
store entry, whether the peer is currently connected or parked mid-grace-window, is the mutation
target, matching `player_health.gd`'s `host_apply_damage` (`_states.has(peer_id)`, no connectivity
check at all). A peer with no store yet still needs a live transport connection — or, offline, must
be the host — before `_ensure_host_store` creates one, so an unseen/spoofed peer id is still rejected.
Publishes immediately rather than waiting for rebind, per the finding's own recommendation: the store
already carries state across the rebind, a lost grant is worse than a stale snapshot the reconnect
overwrites, and `_publish_snapshot`'s `rpc_id` send is already gated on `_peer_connected` (F-059), so
nothing unguarded reaches the transport for a parked peer.

**Verified:** `tools/inventory_net_check.gd`'s driver used to call `inventory.call("_commit",
client_peer_id)` directly on a parked peer specifically because the public API couldn't reach it.
Rewrote that section to call the real public API instead — `host_add(client_peer_id, "log", 4)` on
the same parked peer — and assert it now returns `true` and the store's count increases by exactly 4.
`agent godot --script tools/inventory_net_check.gd`: 21/21 `PASS`, `failures=0`, zero `ERROR:` lines
in the full run (three consecutive clean runs). `agent godot --script tools/inventory_check.gd` (pure
mechanics, no transport, includes "offline authority rejects an unknown peer") stayed green at
failures=0, confirming an unseen peer id is still refused.

---

### F-088 · A review order inherits the reviewed task's claim set, so it is refused exactly when that task is being worked on — **fixed**

**Area:** tooling · **Severity:** medium · **Found:** 2026-08-18 by ivy8

`cmd_order` derives `files` from the reviewed task's `docs/SPECS.md` claim block and then runs the
cross-lane overlap checks against it — but a reviewer claims nothing. The review template says so in
its own text, and the `--review` branch that writes it never passes `files` to anything.

The result is backwards: a review is refused precisely when the task it reviews is live. Ordering
`3.3 --review` and `3.5 --review` for LC1 both died on `autoload/registry.gd is claimed by lp for
3.1` — three tasks that share a registry file in their specs, none of which a reviewer would open.
With LC2 parked until 2026-08-23 and LC1 finishing its only queued review, this left the review lane
with nothing it was permitted to be given, which is the one state the saturate machinery exists to
prevent.

**Fixed:** `cmd_order` empties the claim set when `--review` is passed, before the conflict checks
run. Every downstream guard then falls through naturally on the empty set rather than needing its
own exemption — including the Godot-open guard, which likewise has no business blocking a read-only
review.

**Verified:** re-ran both refused commands. `agent order 3.3 --lane LC1 --review --sha 17e26f8` and
the 3.5 equivalent now write their orders while LP still holds `autoload/registry.gd` for 3.1, and
`agent report` lists both under *Orders waiting* for LC1. `python3 -m py_compile .agent/bin/agent`
is clean.

Adjacent, same root, fixed in the same pass: `cmd_order` refused any task already marked `done`,
which is the normal state of a commit worth reviewing. `--review` is now exempt from that guard too.

---

### F-070 · Generated review orders cannot use their mandated review task id — **fixed**

**Area:** tooling · **Severity:** medium · **Found:** 2026-08-17 by lc1 during the 2.12 review ·
**Fixed:** 2026-08-18 by ivy8 (director)

Both halves are fixed, and a third failure the finding did not reach was found while fixing it.

**Registration.** `cmd_order`'s `--review` branch invents the id `<tid>-review`, so it now registers
it there — the one place that knows the id exists — as a real task carrying `review_of: <tid>`.
`brief`, `claim`, `done` and `ship` all resolve it, and the review lands on the board and in the
journal like any other work.

**Ship path.** `cmd_ship` gives a task with `review_of` set explicit ownership of `docs/FINDINGS.md`
and nothing else, so the one artifact a reviewer produces can ship through the mandated command
while the no-blanket-add rule (F-014) stays intact.

**The third break: an unregistered review order is immortal.** Nothing retires an order file; the
queue skips an order only when its task reads `done`. A review id that was never registered can
therefore never read `done`, so `agent saturate` re-runs it on every pass, forever. LC1's 2.12
review cost ~530k tokens and was already queued to run a second time — registration is what retires
it. That review is now recorded as done, with its verdict in the journal where it belongs.

A fourth, adjacent: `cmd_order` refused any task already marked `done`, which is the normal state of
a commit worth reviewing — so no finished work could be reviewed at all. `--review` is now exempt.

**Verified:** `agent order 3.6 --lane LC1 --review --sha dc86116` writes the order, registers
`3.6-review`, and LC1 picked it up and is running it. `agent report` no longer lists the completed
`2.12-review` under *Orders waiting*. Both files compile (`python3 -m py_compile`).

---

### F-078 · PowerupDef validates shape but not vocabulary — a typo'd stat name or tag loads clean and is dead forever — **fixed**

**Area:** content pipeline · **Severity:** medium · **Found:** 2026-08-18 by reed16 · **Fixed:** same session

Surfaced by the pre-3.4 design pass (docs/POWERUPS.md): a 60-powerup sketch against the shipped
schema found **no powerup that needs a new field** — but ~a third of them route through stat names
and tags that nothing checked. `validation_errors()` rejected an empty id, an empty stat KEY, an
empty tag — every structural mistake — and accepted any well-formed name whatsoever. Three silent
failure classes for a task that hand-types 40–60 `.tres` files in the inspector:

1. **Stat-name typos and synonym drift.** `move_sped`, or `max_health` where the wired name will be
   `max_hp`. No system consumes any stat yet (3.4's spec says so explicitly), so nothing could catch
   it at author time, and at wire time the system's task had no list of what content already named.
   The powerup loads, validates, displays — and does nothing, forever.
2. **Tag typos mint phantom families.** `&"fire"` ≠ `&"Fire"`. `_recompute_families` counts them
   separately, so the powerup shows its icon and feeds a family that can never resonate — exactly
   the failure D-044 killed `resonance_family` to prevent, resurrected one typo at a time.
3. **The linear-stacking zero-crossing.** D-044 stacks multipliers linearly: `(1 + mult·N)`. A
   reduction authored as a negative multiplier inverts the stat where `mult·max_stacks ≤ −1` —
   `hunger_drain` at `−0.15` × 7 stacks = −5% drain, i.e. hunger that refills itself. No content
   hit it yet; the 60-file batch will author dozens of negative multipliers.

**Fixed:** `KNOWN_FAMILIES` (§4.4's six) and `KNOWN_STATS` (docs/POWERUPS.md §2's catalog, the two
kept in step by that doc's rule) as consts on `PowerupDef`; `validation_errors()` now rejects
unknown stat names, unknown tags, `Vector2.ZERO` no-op entries, and multipliers that cross zero at
`max_stacks` — each with a message naming the fix. Boot already skip-and-names anything failing
validation, so all of these are loud named errors instead of dead content. Tag-only Resonance
feeders (tags, no modifiers) stay deliberately legal.

**Verified:** `agent godot --script tools/powerup_check.gd` — 42 assertions, `failures=0`, zero
engine-error lines. Seven new F-078 assertions: catalog names + in-bounds reduction accepted,
typo'd stat rejected, lowercase `fire` tag rejected, `−0.15 × 7` crossing rejected while `−0.15 × 5`
is accepted, `Vector2.ZERO` rejected, tag-only feeder accepted. The shipped worked example
(`swift_stride.tres`) still loads and validates clean through the real registry.

---

### F-073 · Every tool shares one grip rotation authored for a sword, so the axe is held edge-on and every weapon swings the same chop — **fixed**

**Area:** gameplay/presentation · **Severity:** high · **Found:** 2026-08-17 by flint5 from Sequoyah's playtest

Sequoyah: *"the side of the axe is facing the player for some reason also the swing animation sucks,
the spear should have a thrust animation instead of a swing"*.

Three separate problems, one root each.

1. **One grip for eleven designs.** `tools/setup_tool_content.gd:90-92` writes
   `grip_rotation_degrees = Vector3(-6, 158, 10)` for every design it generates, and the two
   hand-authored items (`stone_axe`, `iron_sword`) carry the same numbers. 158° of yaw is ~180°,
   which leaves a head whose bit-to-poll axis runs along the export's local X pointing across the
   screen — so an axe presents its cheek to the camera instead of its edge. The value was tuned for
   the sword, whose broad side *is* the readable face, and copied outward.
2. **One swing for every weapon.** `entities/player/viewmodel.gd` has a single
   `WINDUP`/`COMMIT` constant pair, so a skewer, a bow and a sledge-weight repair hammer all perform
   the same diagonal chop. A thrust weapon that swings sideways reads as the wrong weapon.
3. **The chop itself is thin.** Position and rotation lerp linearly between two poses with no
   follow-through, no lateral arc and no roll, so the commit reads as a slide rather than an
   acceleration through a contact point.

Also: `assets/icons/exports/icon_wooden_axe.png` and `icon_stone_axe.png` are the only two tool icons
`render_item_icons.py` frames upright — every other tool lands on the 45° roll — so the axes read as
facing the opposite way from the rest of the hotbar.

Fixing it means per-design grip data derived from each export's real geometry, a per-weapon attack
style on `WeaponDef`, a swing with an actual arc, and an authored roll for the two axe icons.

---

**Resolved:** 2026-08-17 by flint5 · fixed

**The grips are solved from each export's own geometry now, not guessed.** Parsing the eleven
`*_viewmodel.glb` files shows every A-004 head runs bit-to-poll along its own local **+X** with the
flat cheeks on local **±Z** — `wooden_axe`'s bright `MIRE_WoodCut` bit sits at X +0.29 against a head
spanning −0.16…+0.47, and the sword's two `MIRE_IronLight` edges sit at X ∓0.04 either side of the
blade. A yaw of 158° therefore left every axe, pickaxe, cleaver and hammer presenting its cheek to
the camera. Measured as |cheek · view|, the old grip scored **0.92 on all seven** — 23° off dead
square. The replacement grips score **0.45–0.67**, and `viewmodel_check.gd` now fails above 0.80.

Each grip is derived by naming where the haft and the working end should point in camera space, then
decomposing that basis into Godot's YXZ Euler order, and by placing the *hand* at a fixed screen
position instead of dropping the model's ground-level origin at a fixed offset.
`tools/setup_tool_content.gd` carries the solved table as `GRIPS`, so regenerating content reproduces
these values rather than reverting to the sword's.

**`ItemDef.attack_style` gives each family its own arc** — CHOP (axes, cleaver), SMASH (pickaxes,
repair hammer), SLASH (sword), THRUST (skewer), NONE (bow, arrow). It lives on `ItemDef` and not on
`WeaponDef` because coverage decides it: `short_bow` and `arrow` ship a `view_model` and have no
`WeaponDef` at all, and `CombatService`'s `unarmed` fallback is built in code and never inserted into
`Registry.weapons` — on `WeaponDef` all three would silently fall back to a chop, which is the bug
this enum exists to fix. See D-050.

**Two things about the old arc were simply wrong, and both are worth remembering.**

1. **It struck a phase late.** `CombatService` resolves the hit at `elapsed >= wind_up_seconds`
   (`combat_service.gd:197`) — the WIND_UP→COMMIT boundary. The old table drove the weapon *down*
   during COMMIT, so damage, hitstop and shake all fired while the weapon was still cocked at the top
   of its wind-up, and the visible strike happened a whole phase late. Every arc now reaches its
   contact pose at the **end of the wind-up**: it cocks for the first 55% (ease-out, so it hangs —
   that hang is the telegraph) and drives for the last 45% (ease-in, fastest at contact).
2. **The X-rotation sign was inverted, and the comment agreed with the table rather than with the
   engine.** The file asserted "a positive X rotation is always swing down". It is not — this node
   sits above the swing pivot, so a positive X rotation *raises* the weapon. The old constants cocked
   at −32 and struck at +38: they dipped, then threw the weapon up and out of frame on contact.

**The swing turns about a shoulder now, not about the eye.** The node sits at the camera's own
origin, so rotating it alone orbits the whole weapon around the player's eyeball — 30° of pitch drags
a tool half a metre away clean off the screen, which is why the original angles had to be too small
to read as a swing. `SWING_PIVOT` moves the centre of rotation down and back, expressed as
`position = pivot − R·pivot`, which is all a `Node3D` can say. On top of that the strike follows a
quadratic Bezier rather than a chord, rotation leads translation (that lag is most of what reads as
weight), COMMIT is a decelerating follow-through *past* contact, RECOVERY overshoots rest and settles,
and the idle sway ramps in over 0.18 s instead of snapping on the frame the swing clock is zeroed.

**The two axe icons were a separate cause with the same symptom.** `render_item_icons.py` keeps
whichever of upright / rolled-45 packs the silhouette smaller, and the axes won upright by under 1.1%
— the only two tools not on the diagonal. Measured over all eleven tool icons, the silhouette's
principal axis sat at 33–45° for every other design and at 67–68° for these two. `ROLL_OVERRIDE_DEG`
forces them to 45°; they now measure 22–23° and the hotbar reads as one family. An override rather
than a tuned tie-break because `iron_pickaxe` prefers the roll by only 0.54% — any threshold wide
enough to catch the axes flips the pickaxe too. Mirroring was tried and rejected: it returns the long
axis to ~67° *and* hides the cutting bevel, so the axe reads as a wooden mallet.

**A second generator also owned `stone_axe.tres`, and would have reverted it.**
`tools/setup_crafting_content.gd` re-authors that item from scratch for the crafting recipe and
carried its own copy of the old grip with no `attack_style` — the same clobber class as the F-041
postscript, where regenerating the file silently dropped its icon. It now reads
`setup_tool_content.gd`'s `GRIPS` rather than repeating the numbers, so the values cannot diverge
again. `stone_axe` is hotbar slot 1, so this would have been the first thing to break.

**Verified — 21 assertions, 0 failures.** The load-bearing ones, and each was confirmed by
reintroducing the defect and watching it fail, because an assertion nobody has seen fail is not
evidence:

- **Every item with a viewmodel is measured (11 of 11).** The first version of these checks walked
  the hotbar, and the dev loadout carries only six of the eleven holdable items — so it never
  exercised SLASH at all and measured four of the seven bladed designs, while still printing PASS
  with an empty failure list. They now walk the `Registry` and drive the pose functions directly.
  `PlayerViewmodel.swing_pose()` and `swing_transform()` are public for exactly this.
- **No bladed design's grip turns its cheek to the camera.** Tightening the threshold to 0.40 makes
  it name all seven with real numbers (0.45–0.67), which is how it was proved live rather than vacuous.
- **Nothing crosses the camera near plane during its swing**, over every mesh AABB corner of every
  item across 24 samples of the arc. This caught a real defect: a skewer's hand sits 0.72 up a 1.97 m
  shaft, leaving its butt cap ~12 cm from the camera, and the original 0.11 m thrust pull-back pushed
  it to **z +0.015 against a 0.05 near plane** — sliced open on every wind-up. The first draft of this
  assertion passed anyway, because `root` is a `Window` and not a `Node3D`, so the parent cast nulled
  and the corner list came back empty. Watch for that shape.
- **No tool or weapon silently inherits the default CHOP.**
- Plus the style-dispatch, cheek, bit-downrange and wind-up-moves checks against the live scene.

Framing is measured at each design's **extreme** point — the axe's bit corner, the sword's tip 1.72 m
up — not at a centroid. Measuring the centroid is what hid a sword tip sitting 75% past the right
edge of the frame at full cock. All eleven now stay inside the frame for every frame of the swing.

**The renders are real in-game frames, not a mock-up.** Appending `--display-driver macos` to
`agent godot` overrides the `--headless` it injects, so the check writes four real 1280×720 frames of
the running game; the exact command is in DELEGATION.md *Current state*, and it also answers F-077.
Both the bug and the fix were confirmed that way.

*Left open and not caused by this work at the time:* `tools/item_icons_check.gd` reported one failure,
`coins.tres has an inventory icon` — filed as **F-061** and fixed 2026-08-18 (see `## Resolved`).

---

### F-060 · Two-process net check authors: `local_peer_id() > HOST_PEER_ID` is not proof of a live connection, and mutating what `Node.get()` returns on a typed Dictionary property may not stick — **fixed**

**Resolved 2026-08-18 by lp.** Both traps were already fixed in the one file each was found in
(`tools/player_vitals_net_check.gd`, `tools/player_vitals_check.gd`) before this finding was filed;
closing it meant sweeping every OTHER `tools/*_check.gd`/`tools/*_net_check.gd` that shared the same
unfixed shape, and adding a check that keeps it swept.

**Trap 1 (ready-gate missing `is_active()`), fixed in seven files:**
`tools/player_health_net_check.gd` (the file the finding names as the shape's origin),
`tools/combat_net_check.gd`, `tools/crafting_net_check.gd`, `tools/inventory_net_check.gd`,
`tools/harvest_world_net_check.gd`, `tools/enemy_net_check.gd`, `tools/harvestable_net_check.gd`. Each
now requires `bool(transport.call("is_active"))` alongside the `local_peer_id() > HOST_PEER_ID`
comparison, matching `tools/player_vitals_net_check.gd`'s and `tools/chest_net_check.gd`'s own already-
fixed shape (the latter had independently applied and cited this same finding while authoring task
3.5, before it was resolved here).

**Trap 2 (`.get()` mutated without `.set()`-ing back), fixed in three files:**
`tools/harvestable_net_check.gd` and `tools/harvestable_check.gd` (the injection itself was silently
not reaching `Registry.items`) and `tools/chest_check.gd` (its cleanup `erase()` calls, chained
straight off `.get()`, were silently not reaching the registry either — cosmetic since each check runs
in its own process, but the same discarded-mutation bug the finding describes). `player_vitals_check.gd`
and `player_vitals_net_check.gd` already had the fix.

**New regression guard: `tools/net_check_pattern_check.gd`.** A source-text check, same style as
`tools/interp_coverage_check.gd` (D-043) — the bug is that broken code runs zero iterations or silently
no-ops, so there is nothing for a runtime check to fail against. It walks every `.gd` file and fails on
(1) a `local_peer_id() > HOST_PEER_ID` comparison with no `is_active()` check within 8 lines above it,
and (2) a `.get("prop")` reflection read chained directly into `[...]=` or `.erase()` with no
intervening `Dictionary` local and `.set()`-back. Verified it actually catches both: injected a
throwaway file with one of each defect, ran clean, saw exactly the expected `FAIL:` lines and count
(`gate_reads` +1 unguarded, `mutate_hits` 2), removed the file, reran — 0 failures.

**Verified the real edits didn't just satisfy the lint.** Every two-process check whose ready-gate or
injection changed was re-run for real over ENet, not just re-linted:
`agent godot --script tools/player_health_net_check.gd`, `combat_net_check.gd`, `crafting_net_check.gd`,
`inventory_net_check.gd`, `harvest_world_net_check.gd`, `enemy_net_check.gd`,
`harvestable_net_check.gd`, plus the offline `harvestable_check.gd` and `chest_check.gd` — all
`failures=0`. Then `agent godot --script tools/net_check_pattern_check.gd` clean across the whole repo
(131 scripts, 8 gate reads all guarded, 0 mutate hits).

**Area:** tooling/testing · **Severity:** low · **Found:** 2026-08-17 by lp during 3.8, writing
`tools/player_vitals_net_check.gd`

Two traps that cost real debugging time, worth naming so the next `tools/*_net_check.gd` author does
not re-find them the hard way:

**1. A "ready" gate built from `local_peer_id() > HOST_PEER_ID and local_revision >= 0` (the exact
shape `tools/player_health_net_check.gd`'s own `_client_health_ready()` uses) can resolve TRUE before
the connection is actually established.** `autoload/net_transport.gd`'s `join()` sets `_local_id =
multiplayer.get_unique_id()` the instant `create_client()` succeeds — ENet hands a client its own
unique id locally, before the handshake with the host completes — and `PlayerHealth`'s own OFFLINE
bootstrap already sets `local_revision` to 0 at process boot, before `join()` is ever called. Both
halves of that gate can be true while `NetTransport.is_active()` is still false (status CONNECTING,
not CONNECTED). `player_health_net_check.gd` never noticed because everything after its own ready-gate
is ALSO gated on real cross-peer events that inherently require a live connection to ever become true.
This check's own stamina-reporting ticker started a `while is_active(): ...` loop directly off that
gate, evaluated `is_active()` as false on its first and only check, and exited with zero iterations,
silently. Fix: gate on `is_active()` directly (now added to this file's own `_client_health_ready()`),
not on side effects that happen to usually-but-not-always imply it.

**2. Reading a strictly-typed `Dictionary[K, V]` script property through the generic `Object.get()`
reflection API and mutating what it returns does not reliably mutate the original.** Both
`tools/player_vitals_check.gd` and `tools/player_vitals_net_check.gd` inject a synthetic `ItemDef`
into `Registry.items` for a test-only CONSUMABLE (AGENTS.md: real food content is task 3.2's job, not
this one's) via `var items: Dictionary = registry.get("items"); items[id] = item` — and
`InventoryService.host_add()` kept rejecting it as unknown until an explicit `registry.set("items",
items)` was added after the mutation. Dictionaries are reference types in GDScript, so this is not
true of an ordinary untyped Dictionary property; something about the typed-Dictionary boundary crossed
by generic property reflection converts rather than aliases. Always `.set()` back explicitly after
mutating a typed Dictionary/Array property read through `.get()` from outside its own script.

---

### F-059 · `InventoryService._publish_snapshot`'s `net_inventory_snapshot.rpc_id()` is unguarded against a departed peer, same shape as the bug task 3.8 fixed in `player_health.gd` — **fixed**

**Resolved 2026-08-18 by lp.** Copied `player_health.gd`'s fix exactly: added a `_peer_connected(peer_id)`
helper (`_transport().call("peer_ids").has(peer_id)`) and gated both unguarded `rpc_id(peer_id, ...)`
sends on it — `_publish_snapshot`'s `net_inventory_snapshot.rpc_id()` and `_confirm_peer`'s
`net_operation_confirmed.rpc_id()`. Those were the only two specific-peer `rpc_id` calls in the file;
`net_request_remove`/`net_request_move_stack` always target `NetConfig.HOST_PEER_ID`, which is never
parked, so they needed no guard.

**Verified by reproducing the bug, then proving the fix kills it.** Extended
`tools/inventory_net_check.gd` to call `inventory.call("_commit", client_peer_id)` directly on a
parked (post-`peer_left`, mid-grace-window) peer — the exact call this finding names. Stashed the fix,
ran `agent godot --script tools/inventory_net_check.gd`: reproduced
`ERROR: Attempt to call RPC with unknown peer ID: <id>` at `_publish_snapshot
(inventory_service.gd:370) <- _commit (inventory_service.gd:358)`, verbatim the failure this finding
describes. Restored the fix, ran it three more times: 0 `ERROR:` lines, all assertions green
(one flaked on the pre-existing F-038 grant-timeout race, unrelated to this file — a clean re-run
confirmed it). `tools/inventory_check.gd` (pure mechanics, no transport) also stayed green throughout.

**Found while fixing it, not fixed here — filed as F-074:** the public host-mutation API
(`host_add`/`host_remove`/`host_move_stack`/`host_transaction`) cannot actually reach `_commit()` for
a parked peer today — `_valid_host_peer()` already refuses to mutate a disconnected peer's store, a
check written before D-035's grace window existed and never updated to match it. That makes this
finding's specific crash unreachable through the public API right now, but the guard added here is
still correct and necessary: it protects the exact `rpc_id` sends named above regardless of how they
get reached, and F-074's fix (letting a parked peer's grants land during the grace window, the way
`player_health.gd` already lets damage/starvation accrue for one) will make them reachable again the
moment it ships.

**Area:** netcode · **Severity:** low (today) · **Found:** 2026-08-17 by lp during 3.8

D-035 keeps a departed peer's state alive through NetSession's grace window rather than releasing it
on `peer_left` — deliberately, so a reconnect under a new peer id can rebind instead of resetting. But
that means a peer id can sit in a host-owned dictionary with no live transport connection behind it,
and `autoload/inventory_service.gd`'s `_publish_snapshot` sends `net_inventory_snapshot.rpc_id(peer_id,
...)` to whatever peer id owns the store being published, gated only on `_transport().is_active()` —
never on whether THAT SPECIFIC peer id is still connected. Any code path that calls `_commit(peer_id)`
for a peer mid-grace-window (a harvest yield landing for them, a crafting response, anything routed
through `host_add`/`host_transaction`) sends an RPC to an unknown peer id, which Godot logs as
`ERROR: Attempt to call RPC with unknown peer ID`.

Not fixed here — `inventory_service.gd` was not in 3.8's claim set. `systems/health/player_health.gd`
had the exact same shape (`net_health_snapshot`, `net_force_respawn`, `net_revive_confirmed`,
`net_consume_confirmed`, all `rpc_id(peer_id, ...)` with no connectivity check) and now has a
`_peer_connected(peer_id)` guard before every one of them — copy that fix: check
`_transport().call("peer_ids").has(peer_id)` before an `rpc_id` send to a specific peer, everywhere
one exists. Lower severity than task 3.8's own instance because InventoryService's RPCs fire on
discrete gameplay events, not an ambient per-tick timer — the window to hit is much narrower, but the
failure mode is identical once hit.

---

### F-072 · A claim on a docs/ file is accepted, shown on the board, and enforced by nothing — **fixed**

**Resolved 2026-08-18 by gale6.** `agent check` now enforces an exact claim on a free-prefix path
when one exists, and only then. F-006's actual property — *nobody blocks on a doc nobody claimed* —
is untouched: an unclaimed docs path is as free as it ever was, so two lanes appending to this file
still never collide. What changed is that claiming one now means something.

**Verified** by staging `docs/ROADMAP.md`, which task 2.1k (`ivy8`) holds, and running `agent check`:
it refuses with the holder and their task named, where minutes earlier it had waved the same file
through. The message explains why docs are normally free, so nobody reads the refusal as the rule
having changed.

**Found while fixing it:** this file was itself truncating. A body line began with the four
characters that open a heading, because a move script indexed on the substring `##` + `Resolved`
rather than on the line, and split a backticked mention of it mid-line. Every reader that scans for
a heading prefix stopped counting the Open section 46 lines early — which is why F-072 was
unclaimable the moment it was filed. Repaired, and the sentence rejoined.

**Area:** tooling · **Severity:** medium · **Found:** 2026-08-18 by gale6

`FREE_PREFIXES` (`.agent/bin/agent:52`) exempts `docs/`, `.agent/`, `CLAUDE.md`, `AGENTS.md`,
`README.md` and `.gitignore` from the claim check, so no lane ever blocks on a doc (F-006). But
`agent claim` still *accepts* a `docs/` path, records it in `state.json`, and prints it on the board
under that agent's name — where it reads exactly like every other claim, i.e. like protection.

It is not protection. Task 2.1k (`ivy8`) claims `docs/ROADMAP.md`. I committed that file anyway, in
`d948abf`, and the pre-commit hook passed without a murmur — it saw a `docs/` path and stopped
asking. The immediate cause was my own blanket `git add docs/` (now written up in AGENTS.md), but the
hook is what turned a careless add into a silent one: with any other claimed file it would have
refused the commit and I would have noticed in a second.

The fix keeps F-006 intact rather than trading it away. F-006's property is that **nobody blocks on a
doc nobody claimed** — not that docs are unprotectable. So: leave every unclaimed `docs/` path free,
and enforce only the exact paths some agent has actually claimed. An explicit claim then means what
it looks like it means, and the common case (two lanes appending to FINDINGS.md, which nobody claims)
is untouched.

`agent claim` should also say which of it is advisory, if any survives that change.

---

### F-045 · `pgrep -fl Godot` is too blunt to be the closed-editor guard — **fixed**

**Resolved 2026-08-18 — tool half earlier, docs half by gale6.**

`_godot_running()` in `.agent/bin/agent` already matched the real editor binary and excluded
`--headless` invocations. What this entry had left was its last sentence — "the docs still say
`pgrep`" — and they did, in live guidance, not just archived prompts:

- **`docs/AI-WORKFLOW.md`** told agents to run bare `pgrep -fl Godot` before touching any
  Godot-authored file. Rewritten to name the precise check (`pgrep -fl 'Godot.app.*--editor'`), to
  point at the tool that already asks correctly for you (`agent order` refuses the dispatch, the
  pre-commit hook refuses the commit), and to state the *reason* the rule exists — the editor
  rewrites these files on save, a `--headless --script` run does not — so blocking on a headless run
  costs the edit and buys nothing.
- **`docs/DELEGATION.md`'s archive disclaimer** ("prompts below predate D-031... not policy now")
  was correct but sat *below* three historical prompts that make exactly the stale claim, including
  one reading "NEVER create or edit `.tscn`/`.tres` — human-only, hook-enforced". Moved above the
  first of them so it covers every archived prompt, and widened to name D-039 as well. That half is
  shared with F-053, which stays open for the rest of its ground.

**Verified** by re-grepping every `.md` for `pgrep`: the only remaining hits outside this file are
`AGENTS.md` and `docs/ORCHESTRATION.md`, both of which already describe the precise check and cite
F-045, plus the `.agent/JOURNAL.md` entries that recorded the problem historically.

**Area:** tooling · **Severity:** medium · **Found:** 2026-08-17 by yarrow21 during 0.12

`AGENTS.md` and `AI-WORKFLOW.md` both tell agents to run `pgrep -fl Godot` before touching a
`.tscn`/`.tres`/`project.godot`, and to stop if it matches. It has two failure modes, and they point
in opposite directions:

- **False positives.** It matches any process whose command line contains "Godot" — including the
  shell running a check loop, and the `agent` command itself. Measured on this repo mid-audit: nine
  matches, one actual engine. An agent following the rule literally would refuse a legitimate edit.
- **Wrong question.** The rule exists because *the editor* rewrites these files on save and silently
  discards an agent's edit. A `--headless --script` check does not. So it blocks on runs that are
  harmless while giving no signal about the one that isn't.

`_godot_running()` in `.agent/bin/agent` now matches the real binary path and excludes `--headless`
invocations, which is the question the rule was always trying to ask. The docs still say `pgrep`;
they should say `agent order` refuses the dispatch for you, or point at the same check.

---

---

### F-067 · The pre-commit hook blocks project.godot even when agent autoload wrote it — **fixed**

**Verified resolved 2026-08-18 by gale6.** The entry already said fixed and had been sitting in
`## Open` regardless, which is what motivated the new self-declared-resolved detector below. The fix
is live and was exercised twice today rather than read: registering `WaveSpawner` (F-068) and
committing the resulting one-line `project.godot` change printed
`⚠ project.godot — autoload registration only, no claim needed (F-051)` and went through the hook
without `--no-verify`.

`agent board`/`agent start` now print any finding under `## Open` whose own text says it is resolved.
This one was invisible to every other check: `_sync_findings()` mirrors the doc into `state.json` and
`_findings_drift()` compares the two records, but here **both records agreed the finding was open** —
only the prose knew otherwise. Hence a text scan rather than a status comparison.

**Area:** tooling · **Severity:** medium · **Found:** 2026-08-18 by reed16

F-051 created `agent autoload` precisely so that registering an autoload never requires claiming
`project.godot` — holding that file for a whole task would serialise every autoload-producing task
against every other one, and five upcoming specs each need to register one. CLAUDE.md states the rule
flatly: "**`project.godot`**: never claimed; register autoloads via `agent autoload <Name> <script>`".

The pre-commit hook does not know about that path. Committing the one appended line that
`agent autoload` itself wrote fails with:

    ✗ project.godot — Godot file requires an exact-file claim and a closed editor (D-031)
    Commit blocked. Use --no-verify only if you are certain.

So the sanctioned workflow ends in a blocked commit, and the only way through is `--no-verify`, which
disables *every* other check in the hook at the same time — including the editor-open check that D-031
actually cares about. A rule that can only be satisfied by turning off the rules trains everyone to
reach for `--no-verify` on this file, which is the opposite of what D-031 wants.

Hit while committing `609a471` (DevFrameCap for F-066). Worked around by verifying by hand that no
Godot process was running and that the staged diff was exactly the one autoload line, then
`--no-verify`.

The fix is for the hook to recognise the autoload-registration shape rather than the filename: if the
staged diff to `project.godot` consists only of added lines in the `[autoload]` section, and no Godot
process is running, it is the F-051 path and should pass. Anything else about the file — a changed
rendering setting, a reordered line, a deletion — should still demand the exact-file claim, since
D-019 makes autoload registration append-only and any other edit is genuinely a claimed change.

**Fixed 2026-08-17 by claude**, as described. `_autoload_only_project_change()` in `.agent/bin/agent`
gates the carve-out on three conditions, all of which must hold: the diff is pure additions with no
deletion, every added line matches `Name="*res://path"`, and every one of those lines actually lands
inside `[autoload]` in the resulting file — a registration-shaped line appended to `[rendering]` is
not this path. It reads the staged blob under a hook and the working tree otherwise, and any
exception falls back to demanding the claim, so it never fails open.

The closed-editor half of D-031 is deliberately kept for this path. That half is what protects against
the editor overwriting the file and has nothing to do with claims, so an autoload registration with
Godot running is still an error — just a clearer one than before.

Verified against four cases through the real `agent check` code path with `GIT_INDEX_FILE` set, as
git invokes it: an appended autoload line is allowed; a changed rendering setting, an autoload-shaped
line outside `[autoload]`, and a deleted autoload line are each still blocked. No re-install is
needed — `.git/hooks/pre-commit` only execs `agent check`, so every lane picks this up on pull.

---

---

### F-004 · Interpolation is only planned for remote players, not enemies or props — **fixed**

**Resolved 2026-08-18 by gale6 — the prop half is a no-op by construction, and now has a tripwire.**

The remaining question was whether on-change props were worth interpolating. They are not, because
there is nothing to interpolate: the shipped game has exactly four `SceneReplicationConfig`s, and
`Harvestable` (`health`, `visual_state`, `active`) and `Chest` (`opened`) put **no transform on the
wire at all**. `Harvestable._physics_process` is a respawn countdown, not motion. `RemoteInterp`
smooths a transform, so on those two it would have nothing to act on — and blending toward a discrete
`ON_CHANGE` mesh swap would be an artefact, not a fix. D-043 records the call and the rule it implies:
**interpolate iff the entity replicates a transform**, which is about the wire contract rather than
whether something is called a prop, so the next moving object is covered without another debate.

`tools/interp_coverage_check.gd` enforces it. It finds every `SceneReplicationConfig` in the project,
sorts them by whether they replicate a transform, and fails if a transform-replicating entity is
neither smoothed nor exempted with a stated reason. Deliberately a source-text check: the runtime
proofs already exist and are better (`interp_check` measured 67% of frames motionless without
smoothing versus 1.5% with, D-026; `enemy_net_check` asserts a real client's enemy is smoothed over
real ENet), but no runtime check can catch an entity nobody wired up, because an unwired entity has
no test to fail.

**Verified.** `agent godot --script tools/interp_coverage_check.gd` — 11/11, 0 failures,
`moving=3 still=2`. It earned itself on the first run by flagging `core/net/dummy_replicant.gd`,
which does replicate a transform and is smoothed by nothing; that turned out to be R1's spike fixture,
consumed only by two harnesses and watched by no player, so it is now an explicit EXEMPT entry with
that reasoning attached rather than a silent omission.

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

---

### F-071 · Eight closed findings were still listed under '## Open', so a quarter of the board's work queue was finished work — **fixed**

**Resolved 2026-08-18 by gale6.** Two parts, because the instance and the cause are different jobs.

**The eight entries were moved**, each with a resolution note naming who fixed it, in which commit
where one exists, and the proof re-run today rather than taken on trust: `lan_launch_check`
(`address=192.168.50.176 failures=0`), `combat_self_hit_check`, `player_health_check` (0),
`vitals_hud_check` (0), `frame_cap_check`, `verify_setup` and `hollowmere_check` all green, plus
`grep -c TestMapProps project.godot` returning 0 and the 2.11 **Claim:** line in `docs/SPECS.md` now
naming the two files it had omitted. Thirty-three open became twenty-five; nothing was lost (77 -> 78
sections, the extra being this one).

**The cause is that `board` and `brief` read different records.** `_sync_findings()` mirrors the doc
into `state.json` and deliberately never downgrades a status (F-049 relies on that), so a finding
closed with `agent done` but left under `## Open` ends up *done* in state and *open* in the doc —
and then `board`, which lists from state, hides it, while `brief`, which lists from the doc, offers
it as claimable work. `_findings_drift()` + `_print_findings_drift()` now print that disagreement
wherever stale claims already print, in both `start` and `board`. It deliberately does not rewrite
either record: only someone who knows what was actually fixed can write the resolution note that
makes the move worth anything.

It earned its keep immediately — the first run flagged a ninth entry this pass had skipped (the Jolt
`F-056`, which already carried its own resolution note and so did not match the sweep), and it is
quiet now.

**Also surfaced, not fixed:** `_duplicate_findings()` prints the F-numbers used by more than one open
finding — `F-058`, `F-059`, `F-060` today. `agent finding` allocates under a lock now so no new
collision can occur, but `brief`/`claim` still silently pick one of an existing pair. Renumbering
remains deferred for the third time, and for the same good reason: code comments
(`tools/chest_check.gd`, `tools/chest_net_check.gd`, `systems/loot/chest.gd`,
`world/gen/playtest_hollow.gd`, `tools/blender/mire_art.py`) and queued work orders cite *both*
members of most pairs, so it is a cross-cutting pass with real collision risk against agents holding
those files — not a doc edit. Printing it is what stops it being a trap you can only find by reading
the file in order.

**Area:** process · **Severity:** medium · **Found:** 2026-08-18 by gale6

`agent done <F-number>` releases the claim, writes the journal and marks the task done in
`.agent/state.json` — but it does **not** move the finding's section from `## Open` to `## Resolved`
in `docs/FINDINGS.md`. It only *warns* you to. Eight entries had been closed without that move:
F-054 (LAN launch), F-055 (the dead `TestMapProps` registration), all three F-056s, F-062, F-063,
F-064 and F-066.

The board's "Open findings" list is synced from that section, so it was advertising eight finished
jobs as available work — a quarter of the 33 it listed. This is not hypothetical: I claimed F-054,
read it, opened `core/dev/dev_launch.gd` to write the fix, and found the fix already there, shipped
by flint5 in `fcdd87d`/`019ac7a` the previous evening. `agent claim` refused with "F-054 is already
done" only because `state.json` disagreed with the doc; had the claim succeeded I would have spent
the session re-implementing it.

The doc and `state.json` are two records of the same fact and they had drifted apart. `agent done`
can detect the drift — it already knows the F-number and already greps the file to warn — so the
cheap fix is for it to also *check* at `board`/`start` time and print the disagreement, the way it
already prints stale claims. Renumbering the duplicate F-numbers is a separate, larger job that
F-058 describes and that two agents have now deferred because other docs and code comments cite both
members of each pair.

---

### F-056 · Jolt treats the heightfield as one-sided, so you fall through the map on join — **fixed**

**Resolved 2026-08-17 by flint5.** The title above was my first hypothesis and it was **wrong** —
the spawn placement was correct all along. Corrected diagnosis, then the fix:

`world/gen/playtest_hollow.gd` builds the ground as a `ConcavePolygonShape3D`. Everything about it
was right: 1814 correctly-wound faces (1922 up-facing, 0 down-facing, verified against the layout
data), `StaticBody3D` on layer 1 at `y=0.000`, shape enabled, and the physics **server** confirmed
holding all 1814 faces with an identity transform in a valid space. It still collided with nothing.
The cause is the **Jolt** backend: it treats a concave mesh as one-sided and does not agree with
Godot Physics on which side that is, so a correctly-wound heightfield is invisible from above. Its
box-shaped sibling terrain bodies (`Mire_BasinFloor` et al.) collided normally throughout, which is
what made this look like a spawn bug rather than a shape bug.

Fix is one line — `shape.backface_collision = true`. Two-sided costs nothing for static ground and
removes the winding question permanently. Verified: the player now settles at `y=0.001` with
`on_floor=true` and stays there, and all five `SPAWN_OFFSETS` peer slots report ground on
`GroundHeightfield`. `playtest_hollow_check`, `verify_setup`, `harvest_world_check` and
`dev_loadout_check` all pass with 0 failures and 0 engine errors.

**The blind spot is the durable lesson, and it now has a guard.** `verify_setup`'s "player rests at
ground level" runs against a flat *fixture* level, never the real map; `playtest_hollow_check`
validates 323 colliders, grid sanity and facet angles but never asks whether a player can stand
anywhere. Both were green while the map was unplayable. `tools/spawn_ground_probe.gd` now drops the
real player into the real main scene, asserts it reaches the floor, and asserts every peer slot has
ground beneath it — the one question that decides playability.

*Original (incorrect) diagnosis retained below, because the measurements are still useful and the
wrong turn is instructive: two of my probe readings were artifacts — it first measured the Player's
own capsule as "ground", then read the Player's position after it had already fallen.*

---

### F-054 · There is no launch path into LAN mode, so a second physical machine cannot join at all — **fixed**

**Resolved 2026-08-17 by flint5** in `fcdd87d` (`--lan-host`, `--lan-join=<address>`, `--port=<n>`
in `DevLaunch`, reusing the existing retry path) and `019ac7a` (the log tag names the real mode,
verified by a macOS-to-Linux two-machine run). Section moved out of `## Open` 2026-08-18 by gale6
after re-running `agent godot --script tools/lan_launch_check.gd` — `LAN_LAUNCH_CHECK
address=192.168.50.176 failures=0`.

**Area:** netcode/tooling · **Severity:** medium — it blocks the cheapest cross-platform test we
have · **Found:** 2026-08-17 by flint5, setting up a two-VM session for Sequoyah

`NetConfig.Mode.LAN` exists, `NetTransport.host(Mode.LAN)` binds to `ANY_ADDRESS` and
`join(Mode.LAN, "<ip>")` works — the transport half has been finished since 1.2. But `DevLaunch`
parses only `--host`/`--client` (LOCAL, hard-coded loopback) and `--steam-host`/`--steam-join`.
**Nothing in the shipped project can open or join a LAN session**, so testing against a real second
machine requires either Steam (three accounts, a friends list, and F-025's frame-rate-bound callback
pump on a 2–3 FPS VM) or hand-editing code at test time.

That is backwards for the thing being tested. ENet over a routable address exercises the entire
gameplay stack — admission, version handshake, spawning, replication, harvest/inventory/craft/combat
— with no Steam prerequisites and no dependence on render frame rate, which is exactly what a
correctness-only VM session wants. D-030 already argued the cheap-testing case for Steam console
commands; this is the same argument one layer down, and cheaper still.

Fix: `--lan-host`, `--lan-join=<address>`, and a shared `--port=<n>` in `DevLaunch`, reusing the
existing retry path so a client started before its host still connects (which is also half of F-024's
complaint).

---

### F-056 · `docs/SPECS.md`'s 2.11 block omitted `net_version.gd`/`handshake_check.gd` despite adding a new RPC — **fixed**

**Resolved 2026-08-17 by lp.** `docs/SPECS.md`'s 2.11 **Claim:** line now names
`core/net/net_version.gd` + `tools/handshake_check.gd` and states why. Section moved out of `##
Open` 2026-08-18 by gale6, verified by reading that line.

**Area:** docs/tooling · **Severity:** low · **Found:** 2026-08-17 by lp during 2.11

2.11's spec (`docs/SPECS.md`) listed only `systems/environment/day_night.gd`,
`tools/day_night_check.gd` and `tools/day_night_net_check.gd` as its claim set, and named "code-built
synchronizer per D-023, or an unreliable RPC push" as the replication mechanism with no mention of a
protocol bump either way. Both options add a new item to the wire contract (a new RPC, or a new
`SceneReplicationConfig` entry), and the SPECS preamble's own standing rule 5 is unconditional: "New
RPCs ⇒ bump `PROTOCOL_VERSION`... extend `tools/handshake_check.gd`." Following the preamble rule over
the task's own claim list, `net_version.gd` and `handshake_check.gd` were added to the 2.11 claim
directly (no other lane held them) and the bump happened in the same task — 7 → 8 for `net_push_time`.
Not blocking, since the fix was cheap and immediate, but the pattern is worth naming: **a task's own
`docs/SPECS.md` claim list can omit a file a standing preamble rule requires**, and an agent should
default to the standing rule, extending its claim on the spot, rather than skipping the bump because
the block didn't list the file. Whoever next edits the 2.11 spec block should add `core/net/
net_version.gd` to its claim list so the next reader doesn't have to rediscover this.

---

### F-055 · Committed HEAD boots with a failed autoload — `c187ede` deleted a script but left it registered — **fixed**

**Resolved 2026-08-17 by flint5.** `TestMapProps` is gone from `project.godot`'s `[autoload]`
section. Section moved out of `## Open` 2026-08-18 by gale6, verified by `grep -c TestMapProps
project.godot` returning 0 and a clean `agent godot --quit-after 5` boot with no error lines.

**Area:** build/boot · **Severity:** high — every fresh clone of HEAD is affected, on every platform
· **Found:** 2026-08-17 by flint5, during the three-platform LAN run

`c187ede` ("Map: one map, and the Hollow's ground is a real heightfield") deleted
`world/gen/test_map_props.gd` but left `TestMapProps="*res://world/gen/test_map_props.gd"` in
`project.godot`. Booting HEAD therefore emits, on macOS, Linux and Windows identically:

```
ERROR: Attempt to open script 'res://world/gen/test_map_props.gd' resulted in error 'File not found'.
ERROR: Failed loading resource: res://world/gen/test_map_props.gd.
ERROR: Failed to instantiate an autoload, can't load from path: res://world/gen/test_map_props.gd.
```

The game still runs — the old greybox prop scatterer is obsolete under the one-map consolidation —
so this reads as harmless noise, which is exactly why it needs closing: it is three permanent
`ERROR:` lines in every run, and standing rule 4 grades undeclared error lines. Left alone it
re-creates the F-021 condition where a real error hides inside an allowance everyone has learned to
ignore.

Caught by `verify_setup`'s all-autoloads check added in F-046; the previous version checked 2 of 19
registrations and would have shipped straight past it. This is the exact inverse of D-021's rule —
a task that *removes* a script must deregister it in the same task, just as one that adds an autoload
registers it.

**Not fixed here, deliberately.** The fix already exists uncommitted in the working tree, but that
same `project.godot` diff also carries 2.11's `DayNight` and 2.13's `PlayerHealth` registrations from
lanes still in flight, so committing it would ship other agents' half-finished work. Whoever lands
2.11 should include the `TestMapProps` removal; if 2.11 is dropped, this needs its own one-line
commit.

---

### F-056 · The player spawn sits 1.8 m under the new heightfield, so you fall through the map on join — **fixed**

**Resolved 2026-08-17 by flint5** — the real cause turned out to be the Jolt one-sided heightfield
in the neighbouring F-056, not the spawn height; the spawn was correct all along. Section moved out
of `## Open` 2026-08-18 by gale6, verified by `tools/verify_setup.gd` (player is on the floor, rests
at ground level, is not still falling) and `tools/hollowmere_check.gd` (`HOLLOWMERE_SPAWN ...
clear=true`).

**Area:** level/gameplay · **Severity:** critical — the game is unplayable; it blocks 2.9 and 2.14 ·
**Found:** 2026-08-17 by flint5, from Sequoyah: *"i fall through the map immediately on join"*

`PlayerNet._claim_spawn_point()` reads the level's hand-placed `Player` body and uses its transform
as the spawn, fanning peers out by `SPAWN_OFFSETS`. Measured against the live tree with
`tools/spawn_ground_probe.gd`:

```
spawn transform (PlayerNet reads this): (0.000, -1.867, 7.302)
slot                  spawn y   ground y        gap   verdict
x+0.0 z+0.0            -1.867     -0.066     -1.801   BURIED — falls through
x+1.6 z+0.0            -1.867          -          -   NO GROUND ANYWHERE
x-1.6 z+0.0            -1.867          -          -   NO GROUND ANYWHERE
x+0.0 z+1.6            -1.867          -          -   NO GROUND ANYWHERE
x+0.0 z-1.6            -1.867          -          -   NO GROUND ANYWHERE
```

A `CharacterBody3D` starting inside collision is pushed through it rather than resting on it, so the
fall is immediate and total. The four peer slots are worse than the base: nothing under them at all,
so in multiplayer every joining client falls too.

**This is not `c187ede` by itself.** The three-platform LAN run earlier the same day logged
`PlayerNet: spawn point taken from level at (0.000000, 0.194556, 7.400000)` and players landed fine
(`verify_setup`: *player rests at ground level*). The spawn is now `(0.000, -1.867, 7.302)`, so it
moved *after* that run — the uncommitted `world/gen/playtest_hollow.gd` +
`world/gen/layouts/playtest_hollow.json` work in the tree. The heightfield gives the ground 2.67 m of
relief, so any spawn Y authored against the old flat floor is now wrong by whatever the relief is at
that XZ.

**Why every existing check missed it, which is the more useful half of this finding.**
`verify_setup`'s physics assertions ("player is on the floor", "rests at ground level") run against a
**fixture level with a flat `Ground`**, never the real map — they passed while the real map was
unplayable. `playtest_hollow_check` validates the level thoroughly (325 colliders, grid sanity,
facet angles, 2.67 m relief) but never asks *whether a player can stand at the spawn*. So the one
question that decides playability was owned by no check at all.

Fix: re-place the level's `Player` node onto the heightfield surface (sample the layout's height at
its XZ rather than hand-placing a Y), and confirm every `SPAWN_OFFSETS` slot has ground under it —
the offsets fan sideways and can walk a peer off a shelf even when the base point is fine.
`tools/spawn_ground_probe.gd` is the standing instrument; it belongs in `playtest_hollow_check` so
this can never regress silently again.

---

### F-062 · Every melee swing hits the attacker's own body first — **fixed**

**Resolved 2026-08-17 by nettle12.** Section moved out of `## Open` 2026-08-18 by gale6, verified by
re-running `agent godot --script tools/combat_self_hit_check.gd` — all PASS, including "a swing at
empty air costs the attacker nothing (F-062)".

**Area:** combat · **Severity:** high · **Found:** 2026-08-18 by nettle12

`CombatService._best_target()` (autoload/combat_service.gd:227) iterates the whole `&"damageable"`
group and never excludes the swinging player. Task 2.13 put the player body into that group
(entities/player/player_controller.gd:111) so crawler hits could land — which silently turned every
player swing into a self-hit.

The geometry makes the attacker win the target contest almost every time:

- `eye = player.global_position + UP * 1.5`, so for the attacker itself `to_target = (0, -1.5, 0)`.
- `|y| = 1.5` is inside `vertical_reach_m` (2.4 default) — passes the vertical band.
- `distance = 1.5` is inside `range_m + tolerance` (2.6 + 0.75 = 3.35) — passes reach.
- `to_flat` is exactly zero, so the `to_flat.length_squared() < 0.000001` early branch assigns
  `best = self` and **skips the arc test entirely** — direction is irrelevant.
- `best_distance` is then 1.5 m, so any crawler further than 1.5 m loses the nearest-target contest.

Net effect in play: the stone axe chops the player for `damage` (3) on every swing, and crawlers in
the 1.5–3.35 m band — most of the axe's actual reach — can never be hit. Observed live in
Sequoyah's 2.9 playtest: `PlayerHealth: peer 1 downed (instigator 1)` in the session log, i.e. the
player downed himself, and "attacking the enemies doesn't seem to work anymore".

Fix: skip the attacker's own node in the loop. The zero-horizontal-offset branch is still wanted for
an enemy standing exactly on your axis, so exclude by identity, not by distance.

---

### F-063 · Offline respawn teleports the player to world origin — **fixed**

**Resolved 2026-08-17 by nettle12.** Section moved out of `## Open` 2026-08-18 by gale6, verified by
re-running `agent godot --script tools/player_health_check.gd` — 0 failure(s), including the
scenario that deliberately does not fake `player_spawned`.

**Area:** health · **Severity:** medium · **Found:** 2026-08-18 by nettle12

`PlayerHealth._teleport_to_spawn()` reads `_spawn_transforms[peer_id]` and falls back to
`Vector3.ZERO` when the peer has no entry. That dictionary is only ever written by
`_on_player_spawned()`, which is driven by `PlayerNet.player_spawned` — and PlayerNet only spawns
bodies inside a session (`autoload/player_net.gd:78`, `_claim_spawn_point()`'s own note: "Offline
this is never called and the node is left alone").

So in a solo Play-from-editor run — the exact configuration task 2.9's gate is played in — the
dictionary is empty and every respawn slams the player to `(0, 0, 0)` instead of the level's spawn
point. In `levels/playtest_hollow.tscn` the hand-placed Player sits at `(0, 0.2, 7.4)`, so you
respawn 7.4 m away and 0.2 m below where the level says players belong.

Confirmed live: Sequoyah's 2.9 session log shows two complete `downed -> bled out -> respawning`
cycles that he did not recognise as deaths at all.

Fix: fall back to the level's spawn point rather than to the origin — PlayerNet already reads that
transform off the hand-placed Player, and offline the placeholder is still in the tree to read.
Leaving the body where it stands is strictly better than the origin if neither is available.

---

### F-064 · Downed, bleeding out and dead are invisible to the player — **fixed**

**Resolved 2026-08-17 by nettle12.** Section moved out of `## Open` 2026-08-18 by gale6, verified by
re-running `agent godot --script tools/vitals_hud_check.gd` — 0 failure(s).

**Area:** ui · **Severity:** medium · **Found:** 2026-08-18 by nettle12

`ui/hud/vitals_hud.gd._on_health_changed(hp, max_hp, _state, _bleed_out_remaining)` discards both the
state and the bleed-out timer — the underscore prefixes are the whole story. The HUD draws an hp bar
and nothing else, so the entire 2.13 state machine is invisible from the player's chair.

What a player actually experiences when hp reaches 0: the bar empties, movement drops to
`crawl_speed`, the axe stops responding, and nothing on screen says why or that a 30-second clock is
running. Sequoyah's report from the 2.9 playtest, verbatim: "now it's at zero, and I have not died
... I'm really slow with my health at zero, and then also attacking the enemies doesn't seem to work
anymore." He had in fact died and respawned twice by then; the session log proves it and the screen
did not.

This blocks 2.9's gate on its own terms — the spec asks for a verdict on whether combat is
dangerous, and danger that the player cannot perceive cannot be judged.

Needed: a downed banner with the bleed-out countdown, a distinct dead/respawning state, and the
revive prompt teammates need (the broadcast `downed_flag_changed` already carries who needs help).

---

### F-066 · Play-from-editor costs ~2.2 CPU cores and ~90% GPU, none of it the game's rendering — **partly fixed**

**Resolved 2026-08-17 by reed16, partly** — un-embedding the game window was the real fix; the frame
cap it prompted was reverted and survives only as the `fps_cap` knob. Shipped-game video settings
remain open as roadmap 7.5. Section moved out of `## Open` 2026-08-18 by gale6, verified by
re-running `agent godot --script tools/frame_cap_check.gd` — all PASS.

**Area:** tooling/performance · **Severity:** medium · **Found:** 2026-08-18 by reed16

Sequoyah reported his MacBook getting very hot within seconds of pressing Play Scene, on hardware
(M5 Pro, 16 GPU cores) that should idle through this project. It does not appear to be the game.

**Measured on his live session, before anything else was launched** — the editor (pid 18279) and the
embedded game (pid 18304) each sustained just over 100% CPU, i.e. a full core apiece, while
`ioreg -c IOAccelerator` reported `Device Utilization % = 91`. That is ~2.2 cores and a nearly
saturated GPU for a greybox level.

**The scene's rendering is not the cause.** `tools/perf_probe.gd` (added by this investigation)
renders the real `playtest_hollow.tscn` at a 4800x2700 backing store — four times the shipped
1152x648-at-2x — and steps down a ladder of features. Every configuration held the 120 Hz vsync cap
at 8.33 ms, including the shipped one. Turning off the per-frame atmosphere re-apply, volumetric fog,
all three FogVolumes, glow, the 4-split PSSM sun shadows *and* the cloud deck gave back **0.08 ms per
frame in total**. The renderer settings are not what is heating the machine, and the intuition that
this should run on a potato is correct.

**The editor is not expensive on its own either** — opening the project and sitting idle measured
6.5% CPU, with `interface/editor/display/update_continuously = false`. The ~105% only appears while a
game is running under it. The running game's command line shows `--remote-debug tcp://127.0.0.1:6007`
and `--embedded --wid ...`; `run/window_placement/game_embed_mode = 0` (auto-embed) in his editor
settings. So the editor is compositing the game's output at the game's frame rate on top of its own
UI, at Retina resolution, and paying a debugger link on top.

Two other candidates were checked and cleared: log volume (21 lines of stdout across a 12-second run,
so nothing is being spammed over the debugger socket) and physics (323 static collision shapes).

**Also worth naming: nothing in `project.godot` caps the frame rate.** There is no
`application/run/max_fps` and no `display/window/vsync/vsync_mode` entry at all, so the game targets
the 120 Hz ProMotion panel by default and the editor composites every one of those frames. For a
co-op game that will ship to laptops on Steam this is a player-facing gap as much as a dev-machine
one — there is currently no way for anyone to cap it.

**What is NOT established, and why.** The split between the three plausible contributors — vsync
frame pacing, the debugger attach, and the embedded-window compositing — could not be measured
cleanly. On macOS an occluded or backgrounded Godot window stops really presenting: it free-runs at
~145 fps and its CPU collapses to ~15%, versus ~120 fps and ~80% when genuinely on screen. Sequoyah
was using the machine during the runs and clicking away from the windows I launched, which silently
flipped runs between those two states and produced results that inverted between trials (at one point
`--max-fps 60` appeared to cost more than uncapped). Any future perf run of this kind has to happen on
a quiet machine with the window verifiably foregrounded, and should use the reported fps as a
validity check — a run well above the display refresh was never really rendering.

**Partly fixed 2026-08-17 by claude: the frame cap.** `core/dev/dev_frame_cap.gd` (autoload
`DevFrameCap`) caps editor and debug runs to 60 fps; `tools/frame_cap_check.gd` covers it, 11 checks.
Measured before and after on a foregrounded window, 7/7 samples valid: **120 fps at 104.5% CPU became
60 fps at 59.5% CPU**, a 43% cut in the game process alone. The editor's share should fall with it,
because it composites the embedded game at the game's frame rate — halving the frames halves the
compositing — though that half was not measured, since triggering a real Play needs the GUI.

Capping frames rather than turning down renderer settings is the deliberate call: the ladder above
shows the settings are worth 0.08 ms combined, so there was nothing to win there. Retail is
untouched — the cap is behind `OS.has_feature("editor")`, and an explicit `--max-fps` or
`application/run/max_fps` wins over it, so the flag keeps working for anyone testing high-frame-rate
behaviour. `fps_cap [n]` in the debug console changes it live.

**Un-embedded 2026-08-17 by Sequoyah, and it was the larger half.** `game_embed_mode` is now
`-1` — worth recording, because **Disabled is -1, not 2**, and 2 was the value a reasonable guess
would have landed on. Guessing it would have written *Enabled*. The editor no longer composites the
game over its own UI and falls back to its ~6.5% idle, removing roughly half of the original 2.2
cores on its own.

**That made the 60 fps default the wrong call, and it has been reverted.** DevFrameCap now defaults
to uncapped and lets vsync decide, exactly as a retail build does; `fps_cap 60` remains as a
one-command knob for when the machine runs hot. Halving the frame rate of a first-person game to
save a load the un-embedding had already dealt with was over-correction — a game using about one
core is not pathological. The measured trade on a 120 Hz panel is uncapped 120 fps at ~104% CPU
versus 60 fps at ~60%.

**Un-embedding exposed two window settings nobody had looked at**, because the embedded panel had
been supplying its own geometry: `window/size/resizable=false` meant the run window could not be
resized at all, and no `viewport_width`/`viewport_height` were set, so it opened at Godot's 1152x648
default on a 1512x982-point screen. Neither was a deliberate call — no decision covers window sizing
and `verify_setup.gd` does not pin either — so the false was dropped and the default is now 1280x720.

**Still open.** The shipped game has no vsync or frame-rate control of any kind, which for a co-op
game aimed at laptops on Steam wants a real video-settings surface. That is roadmap task 7.5, not a
fix to make here; Sequoyah has asked for it explicitly and wants it comprehensive rather than a
partial menu.

---

### F-068 · The night wave spawner shipped without being registered, so no waves run — **fixed**

**Area:** gameplay · **Severity:** high · **Found:** 2026-08-17 by lc1 during the 2.12 review · **Fixed:** 2026-08-18 by gale6

Task 2.12's code was complete, correct, and never ran. Commit `915c881` shipped
`systems/waves/wave_spawner.gd` but did not register it, so nothing ever instantiated it, its
`_ready()` never subscribed to `night_started`/`day_started`, and the shipped game had no night waves
and no dawn cleanup at all. The task was staged behind 2.11's gate and then never finished after
2.11 registered `DayNight`.

Fixed with `agent autoload WaveSpawner res://systems/waves/wave_spawner.gd` — it appends, so it lands
after `DayNight` and the dependency order `_ready()` needs is satisfied. Twenty-three autoloads at that point (25 now, after 3.3 and 3.6);
`verify_setup` scans the `[autoload]` section rather than a hard-coded list and only asserts a floor,
so it stayed green without editing.

**The lesson is not "somebody forgot".** It is that `wave_spawner_check` passed the whole time, because
it built its own private WaveSpawner — a harness that instantiates the thing it is testing cannot tell
you whether the *project* has it. That is F-069, and the two findings are really one bug seen from two
ends. `wave_spawner_check.gd` now resolves `/root/WaveSpawner` and fails on its first assertion if the
autoload is absent, which is the regression anchor this needed and did not have.

**Verified.** `agent godot --script tools/wave_spawner_check.gd` — 18/18, 0 failures, including the
two new assertions that WaveSpawner is actually connected to the real DayNight's dusk and dawn.
Clean boot with `agent godot --quit-after 5` (no errors). `verify_setup` (all checks passed),
`day_night_check` (0), `day_night_net_check` (0, two real processes), `enemy_check` (0),
`enemy_crawler_check` (PASSED) and `combat_check` (0) all unchanged and green — a new autoload
is a global change, so this is the blast radius, checked rather than assumed.

---

### F-069 · `wave_spawner_check` signals a shadow DayNight node that WaveSpawner never subscribes to — **fixed**

**Area:** testing · **Severity:** medium · **Found:** 2026-08-17 by lc1 during the 2.12 review · **Fixed:** 2026-08-18 by gale6

The check added its own `FakeDayNight` named `DayNight` to the root. Once 2.11 registered the real
autoload, Godot made the second name unique, so the production script resolved `/root/DayNight` (the
autoload) while the check emitted on its fake — four assertions reading a signal nobody had
subscribed to, and `WAVE_SPAWNER_CHECK failures=4`.

Rewritten to drive the **registered** pair: it resolves `/root/DayNight` and `/root/WaveSpawner`,
freezes the real clock with `set_physics_process(false)` so no stray crossing spawns a wave mid-
assertion, and crosses each threshold by advancing that clock with `host_advance()` rather than by
emitting a signal — "the host's own clock reaches 0.75 and something happens" being the actual claim
under test. The `FakeDayNight` class is gone; there is nothing left in the file to shadow anything.

**The general shape, worth not repeating:** a harness that constructs its own copy of the system
under test proves the *script* works and says nothing about whether the *project* runs it. Where a
system is an autoload, the check should reach for the autoload. Both of `tools/day_night_check.gd`'s
deliberate exceptions (it must pass *before* registration, by 2.11's own ordering) are documented in
its header — that is the bar for building a private instance instead.

**Verified.** `agent godot --script tools/wave_spawner_check.gd` — 18/18, 0 failures, 0 engine-error
lines, up from 4 failures before the rewrite.

---

### F-065 · Night sky still reads as daytime — white clouds, no stars — **fixed**

**Area:** environment · **Severity:** low · **Found:** 2026-08-18 by nettle12 · **Fixed:** 2026-08-18 by gale6

Observed by Sequoyah during the 2.9 playtest, verbatim: "it's night time now, but the clouds are
still bright white, and there's no stars."

Task 2.11's clock was correct and host-authoritative all along; nothing downstream of it made night
look like night. Three separate causes, all client-local presentation, none touching replication or
the protocol version (still 7):

1. **The cloud deck is `SHADING_MODE_UNSHADED`**, so dropping the sun's `light_energy` could never
   darken it — no light reaches an unshaded material by definition. `low_poly_clouds.gd` gained
   `set_sky_light(daylight, golden)`, which drives `albedo_color` (multiplied into each puff's vertex
   colour) from white at noon, through a warm sunset at the horizon, to a dark blue-grey at night.
2. **There was no star layer at all.** `world/environment/star_field.gd` is new: a deterministic
   380 m dome of 520 soft points that rides the camera (so a 356 m valley produces no parallax),
   fades in across a sun-elevation window of −1° to −16°, and wheels on the same clock the sun turns
   on. Geometry rather than `PhysicalSkyMaterial.night_sky`, for the reasons in **D-042**.
   `playtest_atmosphere.gd` creates it, so no level scene had to be edited to get a night sky.
3. **The sky material's own night colours were driven off `daylight`**, which is already ~0.3 with
   the sun exactly on the horizon — so sunset was washed to grey at the moment it should have been
   warmest. `rayleigh_color`/`mie_color`/`ground_color`/`energy_multiplier` now follow a later
   `sky_night` curve (−1° to −14°), leaving `PhysicalSkyMaterial` to do its own dimming while the sun
   is still up. Their **day** ends are read off the authored resource in `_ready()` rather than
   written into the script, so full daylight restores the scene author's sky exactly.

Ambient was also given a cool floor (`NIGHT_AMBIENT_COLOR`, night `ambient_light_energy` 0.16 → 0.22)
because the now-genuinely-dark sky supplies 74% of ambient in both levels: night should be dangerous,
not unreadable. 2.12's waves land on this.

**Verified.** `agent godot --script tools/atmosphere_night_check.gd` — 33 assertions, 0 failures, 0
engine-error lines; it covers the fade being monotonic and gradual, determinism across two peers, the
dome tracking the camera, a level with no cloud deck being a silent no-op, and (the load-bearing one)
full daylight restoring the authored sky byte-for-byte. `verify_setup`, `day_night_check` and
`hollowmere_check` are unchanged and green. Looked at as well as measured:
`tools/hollowmere_night_render.gd` renders Hollowmere at noon / 18:00 / 18:42 / 23:00 from two
vantages — mean frame luminance 0.43 → 0.13 → 0.054 → 0.052. That tool needs a real framebuffer, so
it does **not** go through `agent godot` (always `--headless`, F-044); its header carries the
five-line snippet that takes the same lock by hand.

Two things deliberately left out, either would be its own task: a **moon** (the strongest remaining
night cue, and the honest fix for the sun light still pointing *up* from below the horizon at 0.04
energy), and **twinkle**, which wants a shader rather than more geometry.

---

### F-055 · `core/util/mire_log.gd`'s `CHANNELS` list has no `health` channel — **fixed**

**Area:** tooling · **Severity:** low · **Found:** 2026-08-17 by lp during 2.13 · **Fixed:** 2026-08-17 by lp during 3.8

`MireLog.write()` silently dropped `INFO`/`DEBUG` lines for any channel not in `CHANNELS` —
`_enabled` is only pre-seeded for the listed channels, so an unlisted one read as permanently off
rather than "default on in a debug build" like every other channel. `systems/health/player_health.gd`
logged under `&"combat"` instead of a `health` channel of its own because `mire_log.gd` was not in
2.13's claim set (`WARN`/`ERROR` always got through regardless, so nothing was silently lost — a
visibility gap, not a correctness one).

**Fixed by adding `&"health"` to `CHANNELS`** and switching `player_health.gd`'s `LOG_CHANNEL`
constant over to it, both as part of 3.8 (which was already deep in `player_health.gd` for hunger/
stamina and needed `mire_log.gd` in its own claim set anyway).

### F-043 · The iron sword ships complete and nothing puts it in a player's hand — **decided, won't add**

**Area:** content/playability · **Severity:** medium · **Found:** 2026-08-17 by reed16 during 2.1d
(A-021S) · **Decided:** 2026-08-17 by lp during 2.13

A-021S delivered `iron_sword` end to end, but the starting loadout in `core/dev/dev_loadout.gd` never
listed it, so the hero weapon of the vertical slice was reachable only through `give iron_sword`.
`docs/SPECS.md`'s F-043 block named the decision for this task: (a) add it to the dev loadout, (b)
leave it console-only until 3.x loot places it in the world, or (c) seed it into 3.5's chest loot.

**Decided (b), console-only, for two independent reasons — either alone would have been enough:**

1. `DevLoadout.loadout`'s `hotbar: true` entries already fill 8/8 hotbar slots
   (`HOTBAR_SLOT_COUNT`). Adding the sword `hotbar: true` would silently land in the backpack instead
   per `_move_to_hotbar`'s own documented behaviour — not "in someone's hand," which was the entire
   point of the finding.
2. `content/weapons/iron_sword.tres`'s numbers are still 2.9's unpassed placeholders (F-036).
   Defaulting every player into the strongest melee option would bias 2.14's playtest signal on the
   weapons that are actually tuned, in the same session crawlers become lethal (2.13).

`core/dev/dev_loadout.gd` carries a comment recording this at the `loadout` array itself, so the next
reader sees the decision at the point they'd naturally add the line. `give iron_sword` still reaches
it for deliberate testing.

---

### F-052 · The morning's DevLoadout and D-035 commits broke four net checks, and nobody ran the suite to see it — **fixed**

*Deduplicated 2026-08-18 by lp (F-087) — this entry was pasted twice, back to back, with identical
content. No routing risk (resolved findings aren't claimable), so this is just tidiness.*

**Area:** tests/netcode · **Severity:** high — every lane order tells lanes to run these checks ·
**Found:** 2026-08-17 by flint5, from the audit's baseline run of the multi-process suite

Baseline (all via `agent godot`, sequential): `inventory_net_check` 14 fails, `crafting_net_check`
19, `combat_net_check` 15, `session_lifecycle_check` exit 1 — while `harvestable_net`,
`harvest_world_net` and `enemy_net` stay green. Sessions establish fine (first four PASSes
everywhere); everything inventory-shaped dies from the first content assertion on.

Two roots, both shipped this morning, neither followed by a net-suite run:

1. **`DevLoadout` (6471403, 09:22) grants its 13-entry kit on `player_spawned` in real sessions** —
   and every net-check probe opens a real session. Its `current_scene` gate only covers the offline
   path; `core/dev/dev_loadout.gd:123` records fixing the four *offline* harnesses and the
   in-session class was left open. First failing assertion is literally "host creates the client
   inventory empty". All four red checks were last modified before that commit.
2. **D-035 (975382a, 08:43) parks a departed peer's inventory for 90 s by design**, and
   `inventory_net_check:103` still polls for `host_slots(peer)` to empty on departure — a stale
   assertion against a settled decision. F-032's fix updated `session_lifecycle_check` and shipped
   `run_identity_check`, but never revisited this one.

The general lesson is F-047's, one level up: a change to what a *spawn* does must re-run the checks
that spawn players — which is now cheap to say: `docs/SPECS.md`'s verify sections name them.

**2026-08-17, flint5 — both roots fixed, three of four checks recovered; two tails remain.**
`DevLoadout` now refuses grants in any `--script` process unless it opts in via
`MIRE_DEV_LOADOUT=1` set in `_initialize()` — `dev_loadout_check` and `viewmodel_check` opt in and
stay green. The departed-peer assertions in `inventory_net_check` and `crafting_net_check` now
assert D-035 *parking* (slots survive + `orphaned_run_players() == 1`). Two per-frame engine errors
from reading transforms on despawned/mid-spawn nodes were guarded in `combat_net_check` and
`crafting_net_check`. Post-fix: inventory 0/0, crafting 0 failures, combat 0/0 twice with a
residual ~1-in-3 intermittent recorded under F-038 (its proper home).

**2026-08-17 (later), flint5 — tails triaged; resolved.** `session_lifecycle_check`'s baseline
exit-1 did not reproduce across three post-gate runs — attributed to the DevLoadout kit
contaminating a section, uncertainty noted. Its 2 recurring ERROR lines, and `connect_retry_check`'s
2, are the **refusals and timeouts under test**: production code correctly reports them through
`MireLog.error` → `push_error`, and the checks assert those very refusals as `ok`. Both checks now
declare them in their verdict line as `EXPECTED_ERROR_PATTERNS="…"` (patterns, not counts — one
sweep run logged a timing-dependent third timeout line), and standing rule 4 in SPECS.md/DELEGATION
now grades undeclared-error lines only. Final suite: 7 of 8 checks at 0 failures / 0 undeclared
errors; `combat_net_check`'s ~1-in-3 probe stall is F-038's, documented there with today's data.

---

### F-049 · The board never closed a finding resolved out-of-band, and never learned of new ones until a claim — **fixed**

**Area:** coordination tooling · **Severity:** low · **Found:** 2026-08-17 by flint5 during the
project audit · **Resolved:** 2026-08-17 by flint5, after 0.12 released the file

Two halves, both in `.agent/bin/agent`. (1) `_sync_findings()` "never touches status", so a finding
moved to `## Resolved` without `agent done` kept `status: todo` forever — F-027 sat on the board as
claimable work for a day after being resolved, and once a director routes off the board that is a
mis-dispatch waiting to happen. (2) The sync ran only from `cmd_sync` and `_require_task`, so a
freshly filed finding was invisible until somebody happened to claim one — at audit time the board
said 11 open findings, the truth was 12, and one of the 11 was false.

Fixed: `_sync_findings()` now marks a Findings-milestone task done when its id has left `## Open`
(FINDINGS.md is the source of truth for openness; journal entries are append-only and unaffected),
and both `cmd_start` and `cmd_board` sync-and-save before rendering, so the board mirrors the file
at read time. Verified with a live before/after: F-027 `todo → done` on the first `agent board`
after the fix, and the state's open-finding set became exactly FINDINGS.md's `## Open` section.
Deliberately deferred while 0.12 (yarrow21) held this file — taken the moment its claim released.

---

### F-051 · Five SPECS blocks claimed `project.godot`, which would collapse three lanes back to one — **fixed**

**Area:** docs/orchestration · **Severity:** medium · **Found:** 2026-08-17 by yarrow21 during 0.12
· **Resolved:** 2026-08-17 by flint5

`docs/SPECS.md` put `project.godot` in the opening `**Claim:**` line of every autoload-producing
task — 2.11, 2.12, 2.13, 3.3 and 3.6. Claims are exclusive and order templates say a failed claim
drops the whole task, so two such orders dispatched concurrently would stall a lane on a file whose
real use is a one-line append at the end. D-021 is right that the task shipping an autoload
registers it; holding the file for the task's *duration* was never the requirement.

Fixed in two halves. Harness (`9dc536a`, yarrow21): `agent autoload <Name> res://<script>` performs
the registration as one short-locked, editor-checked, atomic append — no claim held — and
`agent order` strips `project.godot` from any spec-derived claim set, injecting the `agent autoload`
instruction instead. Specs (this commit, flint5): `project.godot` removed from all five Claim lines,
registration rewritten as an `agent autoload` end-of-task step (load order = registration order, so
register after your dependencies), and the rule added to the preamble so an interactive agent
working from the spec directly — not through an order — gets the same behaviour, and future specs
cannot reintroduce the pattern. Verified: `grep -n 'project.godot' docs/SPECS.md` returns only the
preamble rule and two "never claim" reminders; `agent order`'s strip branch stays as
belt-and-suspenders for any spec written carelessly later.

---

### F-050 · Governing docs contradicted D-031 in six places; an unclosed fence hid eight decisions; the budget table was 51 sessions stale — **fixed**

**Area:** docs · **Severity:** high · **Found & resolved:** 2026-08-17 by flint5 during the project audit

Full inventory in `docs/AUDIT-2026-08-17.md` §3–§6; resolution in its addendum. The
`DECISIONS.md:436` fence hid D-028–D-035 as template sample text — closed, template moved below
D-038, D-033/D-034 reordered, supersession markers added to D-005/D-014/D-017, D-038 recorded (art
is authored, not CC0; Blender pinned). `CLAUDE.md`, `ASSET_TRACKER.md`, `AGENTS.md` and six
DELEGATION prompt blocks aligned with D-031 (the historical prompts got a banner instead of a
rewrite). Budget table recomputed from the rows (M2 = 80, total ~388, T2 ~32%) and marked derived.
`NEXT.md` rewritten to the day's reality. `docs/SPECS.md` created — per-task execution specs for
the whole remaining roadmap. Verified by re-reading each contradiction pair side-by-side; the
structural check is `grep -c '^\`\`\`' docs/DECISIONS.md` = 4 (two balanced fences) and D-001–D-038
all matching `^### D-` in order.

---

### F-048 · Three content generators overwrote tuned or later-batch values silently — **fixed**

**Area:** tooling · **Severity:** medium · **Found & resolved:** 2026-08-17 by flint5 during the project audit

`setup_harvest_content.gd` never set `icon`, so a re-run stripped A-042a's icons from
`log`/`stone`/`iron_ore` — the same loss `setup_crafting_content.gd:26` records for `stone_axe`.
`_save_item()` now carries an existing resource's icon forward, and both it and
`setup_crafting_content.gd` carry RE-RUNNING OVERWRITES headers naming exactly what dies.
`setup_project.gd` no longer claims "re-running is safe", and only sets `main_scene` when the
project has none — it can no longer revert `playtest_hollow` to the greybox. All three parse clean
under `--check-only`; none were executed (they overwrite by design). The window mattered: no
hand-tuning exists yet, so nothing was lost before the fix.

---

### F-047 · `harvest_world_check` asserted an absolute log count that DevLoadout's grant breaks — **fixed**

**Area:** tests · **Severity:** low · **Found & resolved:** 2026-08-17 by flint5 during the project audit

The check asserted `local_count("log") == 3` after the lifecycle harvest; DevLoadout grants 20 at
spawn, so it read 23 and failed — the fifth harness broken by that autoload,
`core/dev/dev_loadout.gd:123` having recorded four. Now captures the count before the kill and
asserts the delta is exactly +3. Verified: `agent godot --script tools/harvest_world_check.gd` →
`failures=0`, 0 `ERROR:` lines.

---

### F-046 · `viewmodel.gd` named autoloads bare, so any harness compiling `PlayerController` got a viewmodel-less player — **fixed**

**Area:** player/harness · **Severity:** medium · **Found & resolved:** 2026-08-17 by flint5 during the project audit

Standing rule 1 (F-011), reintroduced one file over from where F-041's close-out cited it:
`verify_setup` reaches `viewmodel.gd` at compile time through the `PlayerController` class_name →
preload chain, before autoloads exist. Five SCRIPT ERRORs under "all checks passed";
`interp_check` and `combat_feel_check` carried four each from the same chain; `viewmodel_check`
(runtime `load()`) could not see it.

Fixed with cached `get_node_or_null(^"/root/…")` + `call(&"…")` and **local phase constants** — the
key subtlety being that preloading `combat_service.gd` for its `Phase` enum would have dragged that
autoload's own (legitimate) bare references into the same early compile pass. Also: `verify_setup`
now asserts all 19 registered autoloads (it checked 2), and `viewmodel_check` detects the headless
DisplayServer before touching the viewport texture, so its render evidence is an explicit skip
rather than two engine errors per shot. Verified: verify_setup, viewmodel_check,
harvest_world_check, interp_check, combat_feel_check, dev_loadout_check — all 0 failures, **0
`ERROR:` lines** (rule 4's grep, run on every one).

---

### F-041 · Held items are invisible in first person, so there is no swing to read — **fixed**

**Area:** gameplay/presentation · **Severity:** high · **Found:** 2026-08-17 by dusk3 from Sequoyah's playtest

Sequoyah: *"the tools in my hotbar don't render in my hand when I'm holding them so there's obviously
no swing animation... I can click when facing the crawlers and see that they flash white and there's
a sound effect"*.

Everything behind the swing works — 2.8 resolves the hit, the enemy flashes and takes damage, hitstop
and shake fire — and none of it is legible, because **nothing renders the held item at all**. The
player sees an empty screen, clicks, and things die. `D-004` chose first-person *with a viewmodel*
specifically so melee would read; the viewmodel half was never built.

The assets have been ready since A-004: ten designs, each with a `*_viewmodel.glb` posed for
first-person, twenty exports total. Nothing consumed them — `ItemDef` had `world_model` and no
viewmodel field, so there was no path from "slot 1 is selected" to "a thing is on screen".

This is the largest gap between what the game does and what it looks like it does, and it makes 2.9's
gate unassessable: you cannot judge whether a 0.4 s telegraph reads when your own swing has no
animation to compare it against.

---

**Resolved:** 2026-08-17 by dusk3 · fixed

`entities/player/viewmodel.gd` renders the selected hotbar item under the camera and drives a
procedural swing from `CombatService.local_phase_progress()`. Only the owning player builds one; it
is client-local and tells nobody anything. `ItemDef` gained `view_model`, `grip_offset`,
`grip_rotation_degrees` and `grip_scale`, and all ten A-004 viewmodel exports are now wired up.

**The swing is procedural, not authored, on purpose.** Every weapon's phase durations are already
data that task 2.9 retunes, so an authored clip per weapon would need re-authoring every time a
number moved. Driving the pose from phase progress means a weapon given a slower wind-up gets a
slower wind-up animation for free — and hitstop freezes the pose with no extra code, because the
swing clock simply stops advancing.

**The structural mistake worth remembering: swing and grip must live on different nodes.** The first
version applied the swing rotation on top of a grip that already yaws the weapon ~160°, so "pitch
down" was expressed in the weapon's own rotated axes and came out as an upward flail. The node now
carries the swing in camera axes and the item carries only its grip, and neither has to know about
the other.

Two things this cost on the way, both of them rules I had promoted to `DELEGATION.md` that same
morning and then walked into: naming `CombatService` bare in a `--script` harness (F-011), and
naming the new `PlayerViewmodel` class bare in `player_controller.gd` (F-016) — the second failed as
*"the level has a player"* rather than as anything about viewmodels, because a controller whose
script will not compile never joins the `players` group.

Verified by `tools/viewmodel_check.gd` against the **real main scene**: the viewmodel exists under
the camera, resolves the held item, instantiates its mesh, follows a hotbar change, and renders one
frame per swing phase to `/tmp/mire_viewmodel_*.png`. Grip values and the three swing constants are
starting points — judging an arc needs motion, which is 2.9's playtest, not a still.

*Also fixed in passing: regenerating `content/items/stone_axe.tres` had silently dropped the icon
A-042 wired to it, so slot 1 fell back to rendering the letters "SA". The generator now sets it.*

### F-039 · A-006's crawler faces +Z, but its generator, catalog and docs all say -Z — **fixed**

**Area:** assets/gameplay · **Severity:** medium · **Found:** 2026-08-17 by dusk3 from Sequoyah's playtest

Sequoyah: *"they come after me but they walk backwards and when they attack they're facing away"*.
Both symptoms are one bug, and it is not in the AI.

`tools/blender/build_enemy_crawler.py:82` says *"Forward is -Y in Blender, which becomes -Z after the
exporter's +Y-up conversion"*, `assets/enemies/README.md:65` repeats it, and
`DELEGATION.md` states *"facing -Z"*. `Enemy._face()` was written against that and is correct for it:
`atan2(-flat.x, -flat.z)` is exactly the yaw that points a node's -Z at a target.

The asset does not agree. Rendered at yaw 0 from both sides (`tools/enemy_facing_check.gd`), the **+Z
side shows two glowing eyes and mandibles** and the -Z side shows the abdomen. So the model's front
is +Z, the code points its back at the player, and a crawler chasing you arrives rear-first.

**Worked around, not fixed:** `EnemyDef.model_yaw_offset_degrees` rotates the visual only, and the
crawler is set to 180. That corrects presentation without touching an asset other things may already
be placed against, and it is a real knob any future enemy with a different export convention needs.

**The actual fix is an asset one** and belongs with whoever next rebuilds A-006: either rotate the
model 180° in `build_enemy_crawler.py` so the export matches its own stated convention, or change the
three places that claim -Z. Doing the first means re-checking the nest prop and the two fragment
meshes, which is why it is not done here. Whoever does it must also reset the yaw offset to 0.

---

**Resolved:** 2026-08-17 by dusk3 · worked around; the asset fix is still owed

`EnemyDef.model_yaw_offset_degrees` rotates the visual only, and `content/enemies/crawler.tres` is
set to 180. Verified by rendering a real spawned crawler, turned by the real `_face()` toward a real
player, from the player's own eye position: it now shows its eyes and mandibles instead of its
abdomen (`tools/enemy_facing_check.gd`, `/tmp/mire_crawler_facing_player.png`).

Closing this because the symptom is gone and the knob is one a second enemy would have needed
anyway. **The asset half is not done and is recorded above**: three places still document a facing
the export does not have, and whoever rebuilds A-006 should make them agree and reset the offset.

### F-040 · A dead enemy falls through the world — **fixed**

**Area:** gameplay · **Severity:** medium · **Found:** 2026-08-17 by dusk3 from Sequoyah's playtest

Sequoyah: *"they die after a few hits and fall through the ground"*.

`Enemy._enter_death()` disabled **every** `CollisionShape3D` on the body so a corpse would not block
the player. But an `Enemy` is a `CharacterBody3D` that keeps applying gravity through `_tick_corpse`,
and a body with no shape has no floor to stand on — so it accelerates through the terrain for the
whole `corpse_seconds` window, in full view.

Fixed by zeroing `collision_layer` instead of disabling shapes: nothing detects or collides *with* a
corpse, but its `collision_mask` still finds the ground, so it lands where it died. The layer is
restored on respawn — enemies are pooled by nothing today, but leaving a one-way door in state that
is meant to be reusable is how the next bug gets written.

---

**Resolved:** 2026-08-17 by dusk3 · fixed

`collision_layer = 0` on death instead of disabling every `CollisionShape3D`. The corpse keeps its
`collision_mask`, so it still finds the ground and lands where it died, while nothing detects or
collides with it. The alive layer is stored at `_ready` and restored on respawn.

Verified by `tools/enemy_check.gd` (44 assertions, 0 failures), which already covers death and the
corpse window.

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

---

### F-079 · The obvious way to "compare decoded pixels" silently reports every RGB-only change as identical — **fixed**

**Area:** tooling · **Severity:** medium · **Found:** 2026-08-17 by flint5 during F-073 · **Resolved:**
2026-08-18 by lp.

F-042 correctly says renders must be compared by decoded pixels rather than by file hash, because
Blender stamps wall-clock into PNG `tEXt`. The natural way to do that in Python is
`ImageChops.difference(a, b).getbbox()` — and for an **RGBA** image `Image.getbbox()` defaults to
`alpha_only=True` (Pillow >= 9.2). The difference image's alpha channel is zero wherever both inputs
are equally opaque, so the call returns `None` and reports "identical" for any change that moved only
colour. Not hypothetical: it bit F-073's task twice in a row — `item_icons_sheet.png` is fully opaque,
so a rebuild that visibly re-rendered both axe cells inside it was classified as byte-only churn and
reverted, the second time *after* a direct `.convert("RGB")` comparison of the same two files had
already printed a difference bbox of `(531, 530, 1005, 749)`.

**Fix:** `tools/png_pixels_equal.py`, the reusable tool F-042 asked for if this recurred. Its
`pixel_diff_bbox(a, b)` diffs each `Image.split()` band on its own and unions the boxes — a
single-band image has no alpha channel to default `getbbox()` to, so the trap has nothing to key off.
`images_pixel_equal(a, b)` wraps it as a bool for callers that just need a keep/revert decision, and
the module is also runnable directly (`python3 tools/png_pixels_equal.py a.png b.png`) for ad hoc use.
Also handles the two neighbouring edge cases an ad hoc script tends to get wrong: differing canvas
size reports a full-canvas box instead of raising, and RGB-vs-RGBA of the same visible colour compares
equal instead of raising on a `split()` band-count mismatch.

**Verified:** `python3 tools/png_pixels_equal_check.py` → `PNG_PIXELS_EQUAL_CHECK ok`. It reproduces
the exact regression (a single RGB-only pixel changed on an otherwise-opaque RGBA image, alpha
untouched) and asserts the tool catches it with the correct 1×1 bbox; also covers an alpha-only change,
identical pixels under different `tEXt` metadata (the F-042 case, must still read identical), a
self-compare, a size mismatch, and RGB-vs-RGBA of the same colour. No Godot involved — this is a
pure-Python tool bug, so the check is pure Python too rather than a `tools/*_check.gd` run through
`agent godot`. Full spec: `docs/SPECS.md` F-079.

---

### F-058 · `docs/FINDINGS.md` carried two F-055s and two F-056s at once — concurrent lanes both used `agent brief`'s "next number" — **fixed**

**Resolved 2026-08-18 by lp.** The routing half of this finding was fixed by **F-087**, a later,
same-root-cause collision (F-058/F-059/F-060 each headed two unrelated findings) that F-087 renumbered
to F-092/F-093/F-094 and recorded the general policy as **D-053**: a colliding F-number is renumbered
only in a dedicated cross-cutting pass, never inline, because doing it correctly means reading every
citing file's surrounding sentence — real work, real collision risk, for a payoff that only exists
when a live routing decision (`agent brief`/`board`) could pick the wrong one.

That payoff does not exist for the pair this finding actually names: every entry under **both** F-055
and F-056 is already `## Resolved`, so `_duplicate_findings()` (the check `agent board`/`start` run)
and `tools/findings_numbering_check.gd` (the standing regression guard, shipped by F-087) both leave
them alone on purpose — a Resolved/Resolved pair cannot make `agent brief` hand a lane the wrong *live*
task, which is the only failure mode either check exists to catch. F-087's own fix note says this
explicitly for this exact pair, and `findings_numbering_check.gd`'s docstring documents the same
exclusion in code, under "Deliberately NOT checked." Renumbering it anyway would still need the
cross-reference sweep D-053 describes (`tools/spawn_ground_probe.gd:3`, `world/gen/playtest_hollow.gd:248`,
`docs/DELEGATION.md:1019`, `docs/STEAM_CROSS_PLATFORM_TEST.md:182`, `systems/health/player_health.gd:45`,
and every historical `.agent/JOURNAL.md` line cite one member or the other) for zero routing benefit —
so this task made the same call D-053 already generalized, rather than relitigating it.

**What this task actually closed:** the one open thread F-087 didn't — this finding's own text asked
whether `agent sync`/`agent brief` had been audited under an ambiguous number, and nobody had run that
check. Ran it: `agent brief F-055` reports `already done` off `state.json`'s single merged entry with
no finding text shown at all (state doesn't carry two bodies per key), so there is no wrong-finding
routing failure to find — confirms D-053's reasoning rather than surfacing a new gap. Also wrote the
missing `docs/SPECS.md` **## F-058** block (`agent brief F-058` was landing on nothing), and deduped
the doc-only decision trail so a future reader hits the reasoning once instead of re-deriving it.

**Verified:** `agent godot --script tools/findings_numbering_check.gd` (unmodified — F-087 shipped it
already correct) → `FINDINGS_NUMBERING_CHECK open=22 resolved=91 failures=0`, both traps PASS. `agent
board` shows no "F-number(s) used by more than one open finding" warning. No production or tool file
needed a change. Full spec: `docs/SPECS.md` F-058.

**Area:** process/tooling · **Severity:** low · **Found:** 2026-08-17 by lp during 3.8

`docs/` is deliberately unclaimed (F-006/AGENTS.md) so no lane blocks on it — but that also means two
lanes filing a finding in the same window can both read the same "highest number so far" and both
append as the same next id. Concretely: lp filed F-055 (mire_log's missing `health` channel) and
F-056 (a SPECS.md omission) during 2.11/2.13; flint5 separately filed an UNRELATED F-055 (a dead
`TestMapProps` autoload registration — since fixed, its own entry says so) and F-056 (the spawn-under-
heightfield bug) during the three-platform LAN run. Both pairs landed in the doc; nothing merged badly
at the git level (plain text, no structural conflict), so this was silent until someone read the
numbers in order.

---

### F-092 · `mire_art.mat()`'s cache never hits, so a generator that calls it in a loop mints a material per call — **fixed**

*Renumbered from F-058 on 2026-08-18 by lp (F-087) — that number collided with the original F-058, the
meta-finding about duplicate F-numbers above. See F-087 for the full renumbering.*

**Resolved 2026-08-18 by lp.** The code fix was already committed before this task existed — `c0cced0`,
the same commit that migrated the flora kit and is what surfaced the bug. This task closed the two
things that were still missing: a `docs/SPECS.md` block (there wasn't one — `agent brief F-092` was
landing on nothing) and a regression guard, since nothing had ever verified the fix. Wrote
`tools/blender/mat_cache_check.py`: exercises the bug's exact repro shape (the same palette token
requested 22 times from inside a loop, not hoisted into a `mats = {...}` dict once per build the way
the four originally-migrated kits happen to) and asserts one material minted, every call returns the
identical datablock, a second token mints its own material, a `suffix` variant is an independent
itself-cached entry, and a cache entry orphaned by removing its datablock out from under
`_MATERIAL_CACHE` is rebuilt rather than returned dangling or raised.

**Verified 2026-08-18 (lp):** `/Applications/Blender.app/Contents/MacOS/Blender --background --python
tools/blender/mat_cache_check.py` → `MAT_CACHE_CHECK PASS`, no failures, against HEAD. Regression-
proved the check itself: temporarily reverted `mat()`'s guard to the pre-fix `key in
bpy.data.materials` line and reran — `MAT_CACHE_CHECK FAIL (20)`, all 22 loop calls minted a distinct
material plus three other assertions failed with it — then restored `mire_art.py` to its committed
state (`git diff` clean) and reran clean. No production file needed a change; the new check and this
doc move are the whole task. Full spec: `docs/SPECS.md` F-092.

**Area:** art pipeline · **Found:** 2026-08-17 by moss11 while building the flora kit

The guard read `if cached is not None and key in bpy.data.materials`. `key` is a palette token such as
`wood_bark`; the datablock it created is named `MIRE_WoodBark`. The membership test was therefore
**always false**, the cache never returned anything, and every `mat()` call created another material.

It hid for as long as it did because of how the four fully migrated generators happen to be written:
each hoists its `mat()` calls into a `mats = {...}` dictionary once per build and then reuses the
dictionary, so each token is asked for exactly once and a broken cache costs nothing. Write the
natural thing instead — `mat("leaf")` inside the loop that builds leaves — and it compounds:
`bracken_a` exported **twenty-two** near-identical `MIRE_Bracken.0NN` materials, and the flora kit
averaged five materials per asset before the fix and two after.

Fixed by testing the datablock rather than the key: `bpy.data.materials.get(cached.name) is cached`,
wrapped against `ReferenceError` so a cache entry left dangling by a scene wipe is re-created rather
than crashing. No existing kit changes, because none of them ever hit the cache path.

Not filing this to relitigate either finding — both are independently sound and now correctly
resolved/open on their own merits (this task resolves its own F-055 below; the `agent` tool's F-number
sync reads `docs/FINDINGS.md` fresh each time, so a human or agent grepping for a SPECIFIC number
should read the SURROUNDING TEXT, not trust the number alone, until this is renumbered). Whoever next
does a documentation pass: renumber the second-filed pair (flint5's) to the next free numbers in
sequence and fix any cross-references, or accept that `F-0NN` is a filing-order label, not a stable
key, and say so once in `AGENTS.md` so nobody is surprised again. `agent sync`/`agent brief` were not
audited for how they behave when a number is ambiguous — that is itself worth checking before relying
on either during a renumbering pass.

---

### F-094 · `mire_art.world_bounds` measured rotated objects through their local bounding box, so grounded assets float — **fixed**

*Renumbered from F-060 on 2026-08-18 by lp (F-087) — that number collided with the original F-060
(two-process net-check authoring traps, Resolved above, cited by `adfaa78`, `abcf9bd`). See F-087 for
the full renumbering.*

**Resolved 2026-08-18 by lp.** The code fix was already committed before this task existed — `c0cced0`,
the same commit that migrated the flora kit and fixed F-092's material cache (both bugs surfaced in the
same build). This task closed the two things still missing: a `docs/SPECS.md` block (there wasn't one)
and a regression guard, since nothing had verified the fix. Wrote `tools/blender/world_bounds_check.py`:
builds a `tapered_between()` cone rotated diagonally and asserts the old bound_box-corners measurement
(reconstructed inline in the check, never imported — `mire_art.py` no longer has it) gives a strictly
larger box than vertex measurement; asserts `world_bounds()` matches the true vertex extent exactly;
composes a second rotation onto a cone (the shape that defeats `to_track_quat`'s single-rotation z-axis
cancellation, reproducing `fork()`'s branch hierarchy) and asserts `ground_and_centre()` seats the real
lowest vertex at z=0; and asserts `world_bounds()` reads a `bpy.ops.object.join()`-merged mesh's true
extent immediately after the join.

**Verified 2026-08-18 (lp):** `/Applications/Blender.app/Contents/MacOS/Blender --background --python
tools/blender/world_bounds_check.py` → `WORLD_BOUNDS_CHECK PASS`, no failures, against HEAD.
Regression-proved the check itself: temporarily reverted `world_bounds()` to the pre-fix
bound_box-corners measurement and reran — `WORLD_BOUNDS_CHECK FAIL (4)`, the rotated-cone comparison,
both exact-vertex-match assertions, and `ground_and_centre()` (floated the composed-rotation object
**101 mm** above z=0, the same scale as the finding's 76 mm) all failed — then restored `mire_art.py`
to its committed state (`git diff` clean) and reran clean. The join-staleness assertion could not be
made to fail even with the buggy measurement: Blender 5.2.0 (this repo's pinned version) already reads
`bound_box` correctly immediately after `join()`, unlike the version that found the bug. Left the
assertion in as a direct ground-truth check rather than dropped — it costs nothing and defends against a
future Blender version regressing there. No production file needed a change; the new check and this doc
move are the whole task. Full spec: `docs/SPECS.md` F-094.

**Area:** art pipeline · **Found:** 2026-08-17 by moss11 while building the flora kit

`world_bounds` transformed the eight corners of each object's `bound_box`. That box is axis-aligned in
the object's **local** space, so for any rotated object the transformed corners enclose a volume
strictly larger than the geometry — and every cone `cylinder_between` and `tapered_between` produce is
rotated. `ground_and_centre` then sat that inflated box on z=0 and left the real mesh hanging above it.

Measured on the flora kit before the fix: up to **76 mm of air** under every willow and every snag.
It would have shipped describing itself as grounded, because the only check available was made with
the same wrong ruler. `bound_box` is also **stale immediately after `bpy.ops.object.join()`**, even
through a depsgraph update — that variant put a willow at 6.97 m tall and 800 mm underground.

Fixed by measuring vertices through `matrix_world`. Vertices are exact and never stale.

**This is shared, so it has a blast radius.** Every kit built with rotated primitives — the map kit's
128 assets, harvestables, tools, the crawler — is currently sitting a few tens of millimetres high,
and will settle onto the ground the next time its generator is rebuilt. That is a move toward
correctness and the shift is well under a centimetre for most assets, but it *is* a geometry change,
so a rebuild of any of those families should diff its catalog and expect small `height_m` reductions
rather than the usual zero.

The same over-measurement exists on the Godot side of the fence: `MeshInstance3D.get_aabb()` is local,
so anything that transforms it by a rotated node transform inherits the identical error. The flora
kit sidesteps it by baking every asset's transform to identity before export, which is worth copying —
and is exactly the over-measurement F-108 caught independently on the Godot side (`tools/ship_check.gd`,
`tools/flora_check.gd:126`), because the Blender-side fix here does not travel across the fence.

---

### F-108 · A Godot-side dimension check built on `Transform3D * AABB` reports every rotated asset as oversized — **fixed**

**Resolved 2026-08-18 by lm.** The code fix was already committed before this task existed —
`3beb6b0`, the same pass that added the A-009 export batch — so this task was verify + regression
guard + spec, the same shape as F-094 on the Blender side of this exact bug.

**Area:** tooling · **Severity:** medium · **Found:** 2026-08-18 by ivy8

`tools/ship_check.gd` cross-checks each export's measured size against the catalog. Built the obvious
way — `instance.transform * instance.get_aabb()`, merged over the mesh instances — it would report
seven of the fifteen A-009 exports as larger than the generator said: all four hull states 50 mm long,
the broken mast 72 mm, the debris cluster 38 mm, and the broken mast's origin 23 mm low.

Nothing was wrong with the assets. An `AABB` is axis-aligned in the mesh's own space, so pushing one
through a rotation returns the box around the rotated box, which is strictly larger than the geometry
inside it and larger the more the part is turned. Every `cone`/`tapered_between` primitive is a
rotated object, so a kit built out of them measures wide by exactly the amount the check is wrong.
This is F-094 — `mire_art.world_bounds` measuring `obj.bound_box` in Blender — on the engine side of
the fence, and it is worth stating separately because the Blender fix does not travel: the two
codebases have to learn it independently.

**Fixed by measuring vertices.** `_check_asset()` walks every mesh instance's `Mesh.ARRAY_VERTEX`
array, transforms each vertex to the scene root via `_transform_to_root()`, and bounds those points
directly — vertices are exact and never inflate under rotation.

**Verified 2026-08-18 (lm):** `agent godot --script tools/ship_check.gd` → `SHIP_CHECK_GODOT PASS`,
all fifteen A-009 exports agree with the catalog to the millimetre. Wrote
`tools/dimension_check.gd` — a synthetic-cone regression guard that hand-computes the expected
divergence between the naive `transform * get_aabb()` construction (~2.1213 m on the test fixture) and
the vertex-transform fix (~1.7678 m) and asserts both, so a future edit reintroducing the naive
construction fails before it ever misreads a real asset. `agent godot --script
tools/dimension_check.gd` → `DIMENSION_CHECK naive_x=2.1213 vertex_x=1.7678`,
`DIMENSION_CHECK_GODOT PASS` — both within 0.001 of the hand-computed values.

Regression-proved the check itself: temporarily reverted `_check_asset()`'s vertex loop back to
`instance.transform * instance.get_aabb()` and reran — `SHIP_CHECK_GODOT FAIL (8)`, reproducing the
exact failure shape from the finding (all three drift-linked hull states +50 mm, the mast +34 mm
across, the broken mast +72 mm long and its origin 23 mm low, the debris cluster 35 mm long and
off-centre) — then `git checkout -- tools/ship_check.gd` restored the committed fix (`git diff` clean)
and the PASS rerun above confirmed it. Full spec: `docs/SPECS.md` F-108.

**`tools/flora_check.gd:126` has the identical construction** and is currently green only because its
20 mm tolerance and height-only comparison happen to absorb the error. It belongs to A-000V's file
set, outside this task's claim — filed separately as **F-122**.

### F-128 · Task 4.3's chunk streamer has no LOD-boundary stitching — adjacent chunks at different LOD tiers crack — **fixed**

**Area:** world-gen · **Severity:** low · **Found:** 2026-08-18 by lm during 4.3

`world/chunk/chunk_mesher.gd` samples `IslandHeightmap.height()` at world coordinates, so two
neighbouring chunks at the **same** LOD tile seamlessly — both sample the identical world-space
point at their shared edge, byte-for-byte. Two neighbouring chunks at **different** LOD tiers do
not: `ChunkStreamer`'s ring design puts a different LOD on every tier boundary by construction
(D-080), and a chunk's outer edge has `verts_per_side(lod)` vertices along it — 33 at LOD0, 17 at
LOD1, 9 at LOD2. The coarser chunk's edge samples a subset of the finer chunk's edge samples in
world space, but the two meshes connect those samples with different triangle counts, so wherever
the terrain isn't flat along that edge the two surfaces diverge — a classic T-junction crack.

**Not fixed as part of 4.3.** The task's acceptance test (`docs/SPECS.md`'s 4.3 block) is
specifically about per-frame streaming *cost* — "walk 500 m ... zero hitches over 16 ms" — not
visual continuity, and nothing yet instantiates a `ChunkStreamer` in the shipped game to look at
(4.6, seed replication + client regen, is the task that will). `agent godot` runs headless for
everything except the collision-cook measurement itself, so there was no way to visually confirm
or deny this by eye during the task either way — it follows directly from the vertex-count
mismatch, not from a render.

**Likely fix, when it matters:** vertical skirts — extend each chunk's outer border ring of
vertices down by a fixed depth, forming a thin wall that hides the gap without solving the vertex
mismatch itself (the standard cheap mitigation for this exact problem). Proper stitching
(welding/re-triangulating the coarser edge to match the finer one) is the alternative if skirts
read as visibly wrong at a real camera angle; either is additive to `chunk_mesher.gd` and does not
require reworking the ring/LOD design in `chunk_streamer.gd`.

**Resolved 2026-08-18 by wick20.** Vertical skirts, per this finding's own suggested fix and now
recorded as **D-084** — a wall hanging `SKIRT_DEPTH` metres below every chunk's outer border, on
both sides of every boundary, so the gap is covered whichever surface sits higher along the seam.
Stitching was rejected deliberately: it would take the neighbours' tiers as a fifth input to
`build_mesh()` and force a re-mesh of the finer chunk whenever a neighbour changed tier, cascading
work through the very frame budget task 4.3 exists to protect. The skirt needs no neighbour
knowledge at all, so the function stays pure in `(chunk_x, chunk_z, world_seed, lod)`.

**Depth is 10% of `IslandHeightmap.HEIGHT_SCALE`, not a metre count**, because 4.1 calls that scale
a placeholder. Measured worst-case divergence over the whole island across four seeds: **0.52 m**
at a LOD0/LOD1 boundary, **1.78 m** at LOD1/LOD2 — against a 6.00 m skirt, a 3.4x margin that
survives the terrain being retuned.

**The skirt never reaches the physics server.** New `ChunkMesher.collision_faces()` slices the
terrain triangles off the front of the index buffer; `ChunkStreamer._cook_collision()` and
`tools/bench_chunk_gpu.gd` both use it in place of `ArrayMesh.get_faces()`. A skirt is a vertical
wall standing exactly on the seam a player walks across — free snagging, plus ~12% more faces
(LOD0) to cook against D-074's gating main-thread cost.

**Verified** by `tools/chunk_stream_check.gd` (windowed) — **21 assertions, 0 failures**, including
the pre-existing 4.3 acceptance test, which now reports **zero hitches in total frame time**, not
just in the streamer's own cost. New assertions: skirt counts/layout at every LOD; `collision_faces()`
returning exactly `tri_count(lod) * 3` faces with its minimum y exactly `SKIRT_DEPTH` above the
mesh's; every skirt triangle facing outward; an island-wide re-sweep of the divergence asserting
the skirt still clears it (so retuning the heightmap fails here rather than silently reopening the
crack); and the precondition the sizing rests on — that neighbouring chunks never differ by more
than one LOD tier — checked on the settled ring and again after the 500 m walk.

**Verified by eye as well, which is what this finding asked for** ("if skirts read as visibly wrong
at a real camera angle"). New `tools/chunk_seam_shot.gd` renders a LOD0/LOD1 seam twice from an
identical camera — once with the skirt, once with the index buffer truncated back to the terrain
triangles, which is exactly the pre-fix geometry — and diffs the two. **541 of 921,600 pixels
changed (0.059%)**, and they trace the crack line and nothing else: no solid band along the
boundary, which is the flange failure mode skirts are warned about. The tool locates its own seam
(roughest west edge that is also above water), so it does not rot when the heightmap changes.

**API note for 4.4 / 4.6, since `docs/DELEGATION.md` was held by another lane when this landed.**
`ChunkMesher.build_mesh()` now returns terrain **plus** a skirt in one surface, terrain first:
vertices `0 ..< vert_count(lod)` and triangles `0 ..< tri_count(lod)` are the terrain grid exactly
as before, with `skirt_vert_count(lod)` / `skirt_tri_count(lod)` appended after. Anything cooking
collision from a chunk must call **`ChunkMesher.collision_faces(mesh, lod)`**, never
`ArrayMesh.get_faces()`. `ChunkStreamer`'s own colliders already do.

**This is what surfaced F-133.** The first render came back as skirts standing in a lattice with
sky where the ground should be: the 4.3 mesher had every terrain triangle wound inside-out. The
seam fix could not be judged visually until that was fixed too.

---

### F-133 · Task 4.3's chunk mesher winds every terrain triangle inside-out — the ground renders and collides only from below — **fixed**

**Area:** world-gen · **Severity:** high · **Found:** 2026-08-18 by wick20

`world/chunk/chunk_mesher.gd`'s `_build_indices()` emitted each quad as `a, c, b` / `b, c, d`.
That is the winding whose right-hand-rule cross product points up — but Godot's front face is the
one whose vertices run CLOCKWISE as seen from the front, so the engine read the whole terrain
surface as facing DOWN. Asked directly, via a terrain-only surface run through
`SurfaceTool.generate_normals()` (which applies the engine's own convention rather than anyone's
recollection of it), **1089 of 1089 LOD0 vertices came back facing down**, and the same at LOD1 and
LOD2. The legacy `build_mesh_surface_tool()` path carried the identical inversion.

The authored `ARRAY_NORMAL` values were correct throughout — `(-dx, 1, -dz).normalized()`, pointing
up. That is exactly what hid this: the shading data said "up" while the triangles said "down", and
only the triangles decide what renders and what a trimesh collider presents to Jolt.

**Two consequences, both severe:**

1. **Rendering.** With `StandardMaterial3D`'s default `CULL_BACK`, the ground is invisible from
   above and solid from below. Rendered, a 7x7 chunk grid showed only the F-128 skirts standing at
   the chunk boundaries, in a lattice, with sky where the terrain should have been.
2. **Collision.** `ConcavePolygonShape3D` faces are one-sided (`backface_collision` defaults off),
   so this is not cosmetic — it is a floor players fall through. Confirmed by the inverse: after
   the fix a ray straight down onto the centre chunk's cooked collider hits, and that assertion is
   now part of `tools/chunk_stream_check.gd`.

**Why 4.3 shipped green anyway.** Nothing instantiates a `ChunkStreamer` in the game yet (4.6 is
the task that will), `tools/bench_chunks.gd` and `tools/bench_chunk_gpu.gd` measure cost rather
than appearance, and `tools/chunk_stream_check.gd` asserted counts, determinism, ring membership
and frame budget — every one of which an inside-out mesh satisfies perfectly. No check anywhere
asked which way the surface faced. Found only because F-128's fix was taken as far as actually
looking at a render instead of stopping at the numbers.

**The general lesson worth keeping:** a mesh's authored normals are not evidence about its winding.
Any future check of geometry we generate should derive facing from the index buffer through the
engine, never from `ARRAY_NORMAL`.

**Resolved 2026-08-18 by wick20.** Winding flipped to `a, b, c` / `b, d, c` in `_build_indices()`,
in the skirt quads added for F-128, and in the legacy `build_mesh_surface_tool()` path, which
carried the same inversion.

**Verified** three independent ways, in `tools/chunk_stream_check.gd` (windowed, 21 assertions, 0
failures):

- **Facing, asked of the engine.** `SurfaceTool.generate_normals()` over a terrain-only index slice
  applies Godot's own front-face convention. Before: **0 of 1089** LOD0 vertices faced up (0/289 at
  LOD1, 0/81 at LOD2). After: **1089/1089, 289/289, 81/81**. The check now asserts this at every
  LOD, deriving facing from the index buffer via the engine and never from `ARRAY_NORMAL` — the
  authored normals were correct the whole time and are precisely what hid the bug.
- **Collision.** A ray straight down onto the centre chunk's cooked `ConcavePolygonShape3D` now
  hits. That is the assertion that makes this a gameplay failure rather than a cosmetic one: trimesh
  faces are one-sided, so the pre-fix terrain was a floor players fall through.
- **Rendering.** `tools/chunk_seam_shot.gd` renders solid, continuous ground where the same camera
  previously showed only the chunk-boundary skirt lattice against sky.

**The durable lesson** is in the finding above: a mesh's authored normals are not evidence about its
winding, and no check that measured counts, determinism, ring membership or frame budget could ever
have caught this — every one of those passes perfectly on an inside-out mesh. What caught it was
taking F-128's fix as far as actually looking at a render.

---

### F-150 · An authored collider is unverifiable by eye, and a .tscn's Transform3D floats are basis ROWS — **fixed**

**Area:** building · **Severity:** low · **Found:** 2026-08-18 by slate17 during 3.7

Task 3.7's ramp is the one piece whose collider cannot be a box: the controller implements no
step-up (F-136), so a ramp shaped like a 1.1 m box is a wall with a picture of a ramp on it. Its
collider is therefore a slab rotated to the slope — and authoring that in a `.tscn` hit two traps in
a row, neither of which changes how the piece looks in a still frame.

**First, the sign.** A `.tscn` writes `Transform3D(xx, xy, xz, yx, ...)` as the basis **rows**, not
as its column vectors, so the obvious reading is the transpose and the ramp was rotated the wrong
way — it descended into the ground along the axis it was supposed to climb. The art was still
correct, so every screenshot looked right.

**Second, the seat.** Placing the slab's centre on the ramp's mid-height leaves its top FACE half a
thickness below the planks — and the correction is along the slope's own tilted normal, so it has an
x component as well as a y one. Ignoring that put the ramp's head 38 mm under the 1.00 m deck it
exists to marry, which is exactly the lip F-136 says is a wall.

**Both were found by a physics query, not by reading the numbers:**
`tools/buildable_content_check.gd` drops three rays on a placed ramp and asserts where they land —
toe 21 mm, middle 506 mm, head 990 mm, 26.3°. That is the transferable part: **an authored collider
is verified by asking the physics server where the surface is, never by inspecting the transform.**
The same check measures every piece's art against the footprint its `BuildableDef` declares, because
`size` is deliberately data rather than a measurement of the scene (which is the right call, and
also exactly how the two drift — F-137's shape).

**Resolved 2026-08-18 by lm.** Already fixed by the time this task picked it up: the same 3.7 commit
(`2012b44`) that authored `ramp.tscn`'s sloped collider also wrote
`tools/buildable_content_check.gd`'s `_check_ramp_is_walkable()`, the physics-query verification this
finding asks for. No code change was needed or made; `ramp.tscn` and `buildable_content_check.gd`
stayed untouched. What was actually missing was the paper trail: no `docs/SPECS.md` block existed for
F-150, so this task wrote one (full verification detail there) and closes the finding here.

Verified: `agent godot --script tools/buildable_content_check.gd` →
`BUILDABLE_CONTENT defs=13 with_art=12 without_art=["wall_wood"]`,
`BUILDABLE_RAMP toe=0.021 middle=0.506 head=0.990 angle=26.3`, `BUILDABLE_CONTENT_CHECK failures=0` —
matching this finding's own cited numbers exactly. `docs/DELEGATION.md` *Current state* already
credited the ramp's slope collider to F-150 (2026-08-18 — Task 3.7 entry), so no delegation update
was owed either.

---

