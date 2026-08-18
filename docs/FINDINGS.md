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

### F-076 · A new map inherits none of the systems keyed to the old map's group names

**Area:** worldgen · **Severity:** high · **Found:** 2026-08-18 by ivy8 during 2.1k

`levels/hollowmere.tscn` became the main scene while **three** systems still looked exclusively for
Playtest Hollow's node groups. All three were fixed in 2.1k; the finding is open because the *class*
of bug is not, and the next map will hit it again.

* `autoload/enemy_world.gd` read only `playtest_hollow_marker` / kind `enemy_spawn`. Hollowmere
  publishes `authored_world_marker` / kind `enemy_nest`, so the shipped main scene had four crawler
  nests modelled into it and **zero enemies in the game**.
* `autoload/harvest_world.gd` read only `playtest_hollow_asset`, so every tree and ore node on the
  map was inert scenery — the whole gathering loop was absent on the map you actually spawn into.
* `world/gen/undergrowth.gd` tested the *parent* of the collider it hit for the prop group.
  Hollowmere puts that group on the StaticBody the ray hits, so every prop read as open ground and
  **grass grew on top of the trees and rocks.**

None of them errored, logged, or failed a check. A group name that matches nothing is indistinguishable
from a level that has none of that thing, and every one of these systems is written to treat "none"
as legitimate — correctly, since a map may genuinely have no nests.

**What to do about it:** the durable fix is a check that asserts each *map* satisfies each *system*,
which `tools/hollowmere_check.gd` now does for this map (`_check_crawlers_actually_spawn`,
`_check_harvestables_are_live`, `_check_undergrowth_stays_off_props` — each asks the system itself
rather than counting markers). That pattern should be lifted into something a new map gets for free,
and the group names themselves should probably converge on one map-agnostic set.

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

### F-042 · Rendered PNGs can never be byte-identical, so every rebuild reads as a broken one

**Area:** asset pipeline · **Severity:** low · **Found:** 2026-08-17 by reed16 during 2.1d (A-021S)

Blender writes non-deterministic metadata into every PNG it renders: `RenderTime` and `Date` `tEXt`
chunks from EEVEE, `cycles.ViewLayer.total_time` from Cycles. The pixels are reproducible; the files
are not, and never can be.

The concrete failure is a false alarm that costs a session. A-021S added one icon to
`render_item_icons.py`, which re-renders all of them, and `git status` came back with all 24
pre-existing icons modified — against A-042a's recorded evidence that "two rebuilds [were]
pixel-identical on every channel". Decompressing the `IDAT` chunks showed 24/24 pixel-identical and
zero changed. An agent reading only the file hashes concludes the icon pipeline lost determinism and
goes looking for a bug that is not there, or commits 24 meaningless binary diffs.

The fix is a habit, not code: compare the decompressed `IDAT` stream, not the file. It is now written
into the verification contract in `docs/ASSET_TRACKER.md`. A tool worth having, if this recurs: a
small `tools/png_pixels_equal.py` that any batch can run.

Second-order, and separate: EEVEE also jitters anti-aliasing on thin diagonal silhouettes between
runs — the same instability that moved the icons to Cycles in A-042a. A-021S's viewmodel preview
differed by 9 bytes in 4,992,780 with a maximum delta of 3/255, which is the noise floor rather than
a rebuild that changed. The world and scale previews were exactly pixel-identical, so this only bites
frames full of near-diagonal edges.

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

### F-058 · `docs/FINDINGS.md` carried two F-055s and two F-056s at once — concurrent lanes both used `agent brief`'s "next number"

**Area:** process/tooling · **Severity:** low · **Found:** 2026-08-17 by lp during 3.8

`docs/` is deliberately unclaimed (F-006/AGENTS.md) so no lane blocks on it — but that also means two
lanes filing a finding in the same window can both read the same "highest number so far" and both
append as the same next id. Concretely: lp filed F-055 (mire_log's missing `health` channel) and
F-056 (a SPECS.md omission) during 2.11/2.13; flint5 separately filed an UNRELATED F-055 (a dead
`TestMapProps` autoload registration — since fixed, its own entry says so) and F-056 (the spawn-under-
heightfield bug) during the three-platform LAN run. Both pairs landed in the doc; nothing merged badly
at the git level (plain text, no structural conflict), so this was silent until someone read the
numbers in order.

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

### F-061 · content/items/coins.tres has no icon — the render_item_icons.py pipeline needs a SOURCES entry

**Area:** content · **Severity:** low · **Found:** 2026-08-18 by lp

Task 3.5 added `content/items/coins.tres` (stack_size 999, world_model =
assets/loot/exports/loot_coin_pouch.glb) so Chest has a real item to grant coins as. Every other
item in content/items/ carries an icon rendered by `tools/blender/render_item_icons.py` (D-033: icons
are renders of the shipped GLBs, never drawn) — DELEGATION's "Current state" says "All 14 item .tres
files carry their icon." coins.tres is the 15th and does not; `ItemDef.icon` is left null.

Not fixed here: appending to that script's SOURCES list, re-rendering, and comparing decoded pixels
(F-042 — PNGs are never byte-identical rebuild to rebuild) is an art-pipeline task, not this one's
framework claim (systems/loot/, ui/loot/, autoload/registry.gd). InventoryUI and ChestUI both already
render a null icon gracefully (existing items without a world_model/icon exercise the same path), so
nothing is broken — coins just show without an icon until this is picked up.

Fix: add `"coins": "res://assets/loot/exports/loot_coin_pouch.glb"` (or equivalent) to
render_item_icons.py's SOURCES, rerun it, and set coins.tres's `icon` field, following A-004R's
"appending to SOURCES, not starting a second pipeline" note in DELEGATION.

---

### F-092 · `mire_art.mat()`'s cache never hits, so a generator that calls it in a loop mints a material per call

*Renumbered from F-058 on 2026-08-18 by lp (F-087) — that number collided with the original F-058, the
meta-finding about duplicate F-numbers above. See F-087 for the full renumbering.*

**Area:** art pipeline · **Found:** 2026-08-17 by moss11 while building the flora kit — **fixed**

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

---

### F-093 · A headless `--script` run never re-imports changed assets, so a check can validate the *previous* build

*Renumbered from F-059 on 2026-08-18 by lp (F-087) — that number collided with the original F-059
(`InventoryService._publish_snapshot`'s unguarded `rpc_id`, Resolved below, cited by `983da6c`). See
F-087 for the full renumbering.*

**Area:** verification · **Found:** 2026-08-17 by moss11 — **fixed for this kit, and the remedy generalises**

`docs/ASSET_TRACKER.md` already warned that "a check run immediately after a rebuild can report the
previous import" and said to re-run to confirm. **Re-running does not help.** Measured: after
rebuilding all 84 flora GLBs, `agent godot --script tools/flora_check.gd` reported the same stale
triangle counts and heights on three consecutive runs, and would have kept doing so indefinitely —
`--script` loads whatever `.godot/imported/` holds and never runs an import pass.

The remedy is one command, and it is not "open the editor":

```
.agent/bin/agent godot --import      # then run the check
```

Deleting the `.glb.import` sidecars forces a full re-import, but the run that regenerates them cannot
also load them, so that path always needs two passes.

The reason this was caught rather than shipped is worth keeping: `tools/flora_check.gd` compares the
**engine's** measurements against the generator's catalog instead of just asserting that files load.
A check that only asks "did it import?" cannot detect staleness by construction — it will pass
happily against art that no longer exists. Any future asset check should cross the fence the same way.

---

### F-094 · `mire_art.world_bounds` measured rotated objects through their local bounding box, so grounded assets float

*Renumbered from F-060 on 2026-08-18 by lp (F-087) — that number collided with the original F-060
(two-process net-check authoring traps, Resolved below, cited by `adfaa78`, `abcf9bd`). See F-087 for
the full renumbering.*

**Area:** art pipeline · **Found:** 2026-08-17 by moss11 — **fixed**

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
kit sidesteps it by baking every asset's transform to identity before export, which is worth copying.

---

### F-075 · World statics and props share collision layer 1, so a placement overlap query cannot tell ground from obstruction

**Area:** physics · **Severity:** low · **Found:** 2026-08-18 by gale6

Task 3.6's `PlacementValidator` asks two different questions of the physics world: "is there ground
under this piece" (support) and "is something already occupying this space" (overlap). They want
different answers from different geometry, and the project gives them the same layer to ask about —
terrain, props, harvestables and buildables are all on collision layer 1, with no named layer
convention in `project.godot` at all.

The consequence is that the ground IS the overlap. On flat ground the piece's base face is flush
with the surface, and on any slope the uphill side of the footprint rises into the query box, so
every sloped placement reports "something is in the way". The validator works around it by lifting
the query box by a clearance derived from the steepest slope the piece permits
(`half_footprint * tan(max_ground_slope)`), which is principled and self-tuning — a piece that
allows steeper ground lifts further — but it is a workaround for missing layer separation, and it
costs real detection: an obstruction lying entirely below that clearance is invisible to the check.
For a 2 m wall permitting 30 degrees that blind band is the bottom 0.58 m.

The clean fix is a dedicated terrain layer so the overlap query simply does not look at the ground,
at which point the clearance drops to a hair and the blind band goes away. That is a project-wide
change — every StaticBody3D the world generator emits, plus the harvestable and prop paths, plus
whatever masks the player and enemies use — so it is not 3.6's to make unilaterally, and it wants
doing once with named layer constants rather than piecemeal. Worth pairing with 4.x chunk streaming,
which is already going to touch every collider the world creates.

---

### F-097 · Environmental VFX is keyed to node types the shipped map never produces, so wind and firelight are dead on Hollowmere

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

### F-099 · Optimization sweep: per-frame costs and dead weight across runtime scripts

**Area:** perf · **Severity:** medium · **Found:** 2026-08-18 by kiln9

Two-reviewer optimization sweep over runtime scripts (autoload/core/entities and systems/ui/world) found per-frame allocation and polling hotspots: enemy overlay find_children per frame, per-tick NavigationAgent repaths, always-on HUD rebuilding hint/layout per frame with a full inventory duplicate, unchanged downed-flag rebroadcasts, per-tick node re-resolution in day_night, always-on physics polling in harvestable, plus a host_health_changed signal declared with 4 args but emitted with 5. Fixes applied under this finding by kiln9; per-file details in the session review ledgers.

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

## Resolved

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

*Left open and not caused by this work:* `tools/item_icons_check.gd` still reports one failure,
`coins.tres has an inventory icon`. That is **F-061**, and it fails identically at HEAD.

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
