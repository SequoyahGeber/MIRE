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

**Each parallel chat gets its own identity automatically, and you no longer supply it (F-007).** The
name is derived from the chat's own session id, which every command carries in its environment — git
included, so the pre-commit hook resolves the same agent your `agent` commands do. Stable for a whole
session, unique per chat, nothing to pass:

```bash
.agent/bin/agent claim 1.2 autoload/net_transport.gd
```

**The archived prompt blocks below still carry `MIRE_AGENT=<name>` prefixes.** They shipped under the
old scheme and are kept verbatim as worked examples. The prefix still works — it overrides everything —
but do not copy that pattern into a new prompt, and never reintroduce `export`: each shell call is a
fresh process, which is what made the old scheme fail silently.

**Prefer `agent ship` for commits**, and it is now safe to prefer: **F-014 is fixed** (`ce8128a`), so
`ship` commits by pathspec and can no longer be blocked by, or unstage, another agent's staged work,
and **F-010 is fixed** (`60e85cc`), so it carries `.uid` sidecars along with the scripts that own them
instead of leaving them untracked.

**Roles are not fixed (D-020).** Any agent can take any task; which one gets it depends on which plan
has quota. Nothing below is reserved for a particular chat.

**Standing trap — most of `.godot/` is gitignored, and real setup can hide in it.** One task still
depends on local editor state:

| Task | What lives in `.godot/` |
|---|---|
| 1.3 | Run-instance config (Debug → Customize Run Instances) — the two-window launch args |

F-009 is fixed: `.godot/extension_list.cfg` is the sole tracked exception and registers GodotSteam in
a fresh clone or headless VM. Any prompt whose work touches other editor state should still say so
explicitly and hand back either a click-path or a committed script.

---

### Task 1.11 — version handshake is wired through `NetSession`

`core/net/net_version.gd` remains the pure version source: `PROTOCOL_VERSION: int` and
`mismatch_reason(local_version, remote_version) -> String`. Task 1.7 integrated it at the lifecycle
policy layer instead of the transport mechanism. On connection, a client calls
`NetSession.net_client_hello(PROTOCOL_VERSION)` on the host. The host compares versions, sends the
same human-readable refusal used by capacity/policy admission, waits 0.25 s for the reliable notice
to flush, then kicks the peer.

Version is necessarily checked just after ENet admits the connection, so the mismatched peer may
briefly spawn before the refusal arrives; it is then despawned and leaves no player behind. D-027
records that tradeoff and what would justify moving to `SceneMultiplayer.auth_callback`. The real
multi-process lifecycle harness verifies the complete path. `tools/handshake_check.gd` remains the
smaller pure-mechanics probe.

F-016 still applies to `NetVersion`: headless `--script` entry points should preload
`res://core/net/net_version.gd` rather than relying on the gitignored global-class cache.

Bump `NetVersion.PROTOCOL_VERSION` in the same commit as any change that would desync two builds
silently — see the constant's own doc comment for the exact list (replicated property, RPC signature,
`SceneReplicationConfig`).

---

## Current state — check `.agent/BOARD.md` before pasting anything

**Asset batches A-001 through A-004 are complete; A-005 is next.** Harvest states live under
`assets/harvestables/` (12 GLBs), basic pickups under `assets/pickups/` (14 GLBs), the eight
vertical-slice stations under `assets/crafting_stations/`, and ten tool/weapon designs under
`assets/tools_weapons/` as 20 paired `*_world` and `*_viewmodel` exports. Each family has its own
catalog, previews, editable source, and deterministic generator. Pickups, stations, and tools are
horizontally centred and ground-origin normalized. The paired tool exports deliberately share
geometry and materials so Godot scenes can tune world and first-person transforms without silhouette
drift. None contain collision or authority: harvest mutation, pickup grants, station placement/use,
crafting validation, fuel, repairs, attacks, hits, and inventory changes remain host-owned. Static
fire meshes are cosmetic placeholders for later client-local VFX. A-005 added ten loot meshes under
`assets/loot/`, and A-006 the first rigged family under `assets/enemies/`. The next asset run takes
the single `NEXT` row in `docs/ASSET_TRACKER.md` — currently A-007, the Ward set — and should use a
separate generator per family.

**A-006 is the first rig, and combat code needs three facts from it.** `assets/enemies/exports/`
holds `enemy_crawler.glb` (skinned, 17 bones, 6 clips) plus static `enemy_crawler_nest`,
`enemy_crawler_fragment_shell` and `enemy_crawler_fragment_leg`.

1. **Ask the `AnimationPlayer` for `idle`, `locomotion`, `attack_tell`, `attack`, `hit`, `death`.**
   The GLB names the first two `idle-loop` and `locomotion-loop`; Godot 4 reads that suffix as
   "loop this clip" and then strips it. The exported name will not resolve at runtime.
2. **`attack_tell` (0.4 s) and `attack` (0.4 s) chain.** The attack's first frame is the tell's last,
   so they play back to back without a pop, and the tell can be held or cancelled on its own. The
   0.4 s tell is `docs/DESIGN.md` §6's readable-telegraph target, not an arbitrary length.
3. **`death` (1.0 s) ends settled and flat**, so a corpse mesh, ragdoll or fragment burst can take
   over from its final pose.

The crawler is 1.10 m long, 0.59 m tall, origin at the ground between its feet, facing -Z. It carries
no collision, health, AI, aggro, or authority; spawning, targeting, attack timing, hit registration
and death stay host-authoritative. Rebuild with Blender 5.2 via `tools/blender/build_enemy_crawler.py`;
verify with `Godot --headless --path . --script tools/enemy_crawler_check.gd`, which asserts the
skeleton, the skin, all six clip names and exactly which two loop.

**Blender generator naming trap:** never put raw float values in object or datablock names. Blender
5.2 treats the text after the last `.` as a numeric duplicate suffix; a coordinate such as
`.30600000000000005` aborts background Blender in libc++ with `stoi: out of range`. Use integer
indices in procedural names.

**The playtest map is an authored asset as of 2.1e.** Its editable source is
`assets/source/playtest_map.blend`, exported as the single `assets/maps/playtest_map.glb`; Godot no
longer chooses visible prop positions at runtime. The GLB contains named camp, forest, ruins, Mire,
ridge, routes, and terrain hierarchies, plus the A-001 harvestables and A-003 crafting stations. The
current export produces 1,732 visible mesh nodes in Godot. `TestMapProps` loads that one map and adds
178 collision placement markers / 120 simplified shapes; static collision remains client-local,
while future harvesting, construction, damage, or map mutation stays host-authoritative. Rebuild
with Blender 5.2 using `tools/blender/build_playtest_map.py`; verify with `Godot --headless --path .
--script tools/playtest_map_check.gd`.

**`playtest_hollow` is the larger replacement playtest level from 2.1f.** Open
`levels/playtest_hollow.tscn` directly; the project default remains the older greybox until Sequoyah
chooses to switch it after an editor playtest. Its 463 prop placements and 26 terrain records live in
the single deterministic `world/gen/layouts/playtest_hollow.json`. Blender consumes that file to
produce `assets/source/playtest_hollow.blend`, the 4,102-mesh `assets/maps/playtest_hollow.glb`, and
its preview; `world/gen/playtest_hollow.gd` consumes the same records to create 20 terrain bodies and
254 prop collision shapes. The new scene has six zones, a four-gate camp, clear roads, a lowered Mire
basin, two ridge terraces, five traversable ramps, a closed boundary, loot/pickup/tool placements, and
the crawler nest marker. Rebuild with `tools/mapgen/hollow_layout.py` then
`tools/blender/build_playtest_hollow.py`; verify with `tools/playtest_hollow_check.gd`. Static map
collision remains client-local; harvesting, inventory, loot, enemies, damage, and mutation remain
host-authoritative. `world/environment/playtest_atmosphere.gd` controls its physical sky, sun, and
localized volumetric light shafts; `world/environment/low_poly_clouds.gd` builds deterministic,
faceted mesh-cloud clusters that drift locally. Blanket fog is disabled; the only readable fog
volumes are Mire haze, forest-floor mist, and a thin ruins layer. The optional local clock
defaults off; task 2.11 must drive `set_time_of_day()` from replicated host time rather than letting
peers advance it independently.

**1.5, 1.9 and 1.10 shipped earlier** (`8d6ddab`, `ef1bc16`, `4f17bcd`), and 1.10 is now actually
*wired* (`9f56451`). **1.6, 1.7, 1.8 and 1.11 are now implemented and headlessly verified** — read
the table and the per-task sections below rather than assuming a clean slate. The only remaining M1
task is 1.12, whose three-machine Steam transport has now worked but whose formal evidence run is
still incomplete.

**Task 1.12 live state (2026-08-16):** all three `tools/steam_check.gd` preflights passed on stock
Godot `4.7.1.stable.official.a13da4feb`, GodotSteam 4.21 and App ID 480. The accounts are macOS
`TheQuoy`, Windows `quoygeber`, and Linux `sequoyahgeber`, and they are mutual friends. The Windows
current test checkout is `C:\MIRE-main` with Godot at `C:\Tools\Godot\Godot_v4.7.1-stable_win64.exe`;
the stale `C:\MIRE` copy still predates D-029 and must not be used. The Linux
checkout is `/home/ubuntu/mire-task-1.12` with Godot at `/home/ubuntu/.local/bin/godot-4.7.1`.
Windows Steam IPC is unavailable to an OpenSSH service session, so launch Steam checks and the game
in the signed-in interactive console session (an interactive scheduled task is suitable).

A Mac-hosted lobby reached three peers and displayed all three spawned players after
`player_controller.gd` gained code-built coloured remote debug capsules and `players` group
registration. Linux movement visibly replicated on the Mac host. Windows first join remains flaky:
it twice hit `connect to steam:<lobby_id> timed out after 10.0s`, then connected on an immediate
retry to the same lobby; one of those first-attempt failures occurred with Windows Firewall already
fully disabled, so F-023 tracks the brittle timeout independently of firewall configuration.
Windows Firewall was restored and verified enabled on all three profiles before a later two-platform
rerun. That rerun used a fresh `origin/main` archive at `C:\MIRE-main`: Windows peer `579922246`
joined a Mac-hosted lobby, showed `STEAM client`, peers `[1, 579922246]`, and two players in F3, and
the host despawned it on exit. The old checkout's 10-second timeout was retained as failure evidence;
the fresh checkout used D-029's 20-second budget. Remaining 1.12 work is a fresh run on
the shipped revision with the firewall enabled, 60 seconds of movement by every player, one F3
screenshot and complete log per platform, then clients exiting before the host.
The retained evidence logs are in `/Users/sequoyahgeber/Desktop/MIRETestLogs`; the final diagnostic
run ended host-first, so both client logs correctly record `CONNECTION_LOST` and are not pass evidence.

**F-023's mechanism is fixed as of 2026-08-16 (vane, D-029) — 1.12's rerun inherits new behaviour and
one job.** A Steam client no longer gets one 10 s attempt and a dead end:

| API | What it is |
|---|---|
| `NetConfig.STEAM_CONNECT_TIMEOUT_SEC` | Steam's own connect budget, **provisionally 20 s**, separate from ENet's `CONNECT_TIMEOUT_SEC` |
| `NetTransport.connect_timeout_sec(mode)` | static; the budget for a mode. Anything that waits on a connect must derive its own deadline from this, never hard-code one |
| `NetTransport.EndKind.CONNECT_TIMEOUT` | split from `CONNECT_FAILED`. A refusal is an answer; a timeout is the absence of one, and only the second is retried |
| `NetTransport.last_connect_msec()` | how long the last successful join took, or -1. Also logged as `connected … in N.NNs` |
| `NetSession.connect_retry_attempted(attempt, of)` | a first join is being retried. **Not** `rejoin_attempted` — nothing has been lost yet, so a UI must not say "Reconnecting…" |
| `NetSession.connect_failed(detail)` | the first join gave up. `session_ended` does not fire; there was never a session |
| `NetSession.is_connect_retrying()` / `auto_connect_retry` | state, and the off switch for probes |

Retries are **STEAM-only** and that is load-bearing: a timed-out attempt tears down without announcing,
so SteamLobby never leaves the lobby and the retry is a plain `join()`. That is why this is not F-020,
which is the rejoin-*after-drop* case where the lobby genuinely was left. LOCAL/LAN first joins are
still DevLaunch's — F-024 records the gap that leaves in a shipped LAN join.

**The one job 1.12's rerun inherits:** every join now prints its own duration, so the run produces the
first-join latency nobody has ever measured. Collect the `connected … in N.NNs` line from all three
platforms, then set `STEAM_CONNECT_TIMEOUT_SEC` from the observed tail — 20 s is an allowance, not
evidence. A Windows timeout that the automatic retry recovers is the fix working, and is still not a
clean PASS. Verify the mechanism first with
`Godot --headless --path . --script tools/connect_retry_check.gd` (PASS, 0 failures on macOS).

**Three open findings were closed this session, all of them process rather than game code:** F-013
(the `&"synced"` convention, D-024 — 1.8 inherits it), F-015 (an F-number is a task id, so a finding
is startable exactly like a roadmap task), and F-007 (agents name themselves from their chat; no
`MIRE_AGENT`, no prefix, commits included). Practical effect on starting work: *"start 1.6"* and
*"fix F-004"* are now the same shape of instruction, and neither needs a name attached.

**Reading the table.** *Agent name* `auto` means the chat names itself on `agent start` (F-007) —
the named ones are historical, hand-assigned under the old scheme. *Model* and *Effort* are the only
things left for you to set, because they are set in the client before the chat starts and no script
can choose them: **Opus 5 · high** for anything that reasons about replication or lifecycle,
**Sonnet 5 · medium** where the work is mechanical and well-specified. The rows below are ordered by
what to start next, not by task number.

| # | Task | Agent name | Model | Effort | Status |
|---|---|---|---|---|---|
| **1.8** | Interest management — visibility filters, per-class intervals | `birch` | Opus 5 | high | **done and verified over a real wire.** `NetInterest` is the seam every replicated entity goes through — see below |
| **1.6** | Remote-player interpolation | `ash` | Opus 5 | high | **done and verified.** F-004's question answered as D-026: engine `physics_interpolation` does *not* cover it. See below |
| **1.7** | Connection lifecycle — mid-session join, disconnect, host quit, timeout | `reed` | Opus 5 | high | **done and verified over real multi-process ENet.** `NetSession` owns host admission and client-local LOCAL/LAN rejoin — see below |
| **1.11** | Protocol/build version handshake | auto | Sonnet 5 | medium | **done and wired through `NetSession`.** A mismatched build gets a readable refusal and leaves no player behind |
| 1.5 | Networked player — spawner + synchronizer | `spawn` | Opus 5 | high | **done** — runs; prompt kept for reference |
| 1.9 | Spike R1 — replication load | `load` | Opus 5 | high | **done — AMBER.** Read the verdict below before writing 1.8 |
| 1.10 | Network debug panel | `netui` | Sonnet 5 | medium | **done, wired, and reading real numbers** — F-013 closed, entity count live |
| 1.1 · 1.2 · 1.3 · 1.4 | GodotSteam · NetTransport · LOCAL loop · Steam lobby | | | | done and verified |
| 2.2 | Content framework | `content` | Sonnet 5 | medium | done — prompt kept for reference |

**1.6 took `project.godot`** and registered `NetInterp` with it; it is free again once 1.6 ships. It is
still the one file only one task at a time may hold, so claim it by name and check `agent board`
first. **Keep `NetInterp` last in `[autoload]`** — it resolves `PlayerNet` at `_ready()`, and autoload
order is load order. Two things wiring one cost us
already (`9f56451`): **an autoload script may not carry a `class_name` equal to its own singleton
name** — Godot rejects it as hiding the singleton and the autoload never registers — and **autoload
order is load order**: a script whose `_ready()` resolves `DebugOverlay`/`NetTransport`/`PlayerNet` by
bare identifier must be registered *after* them.

### What 1.7 shipped — one lifecycle policy above every transport

**`NetSession` is registered** between `NetTransport` and `DevLaunch`. `NetTransport` remains the
pipe; `NetSession` owns host-authoritative admission, player-facing end reasons, clean host shutdown,
and client-local rejoin policy. Mid-session roster replay remains `MultiplayerSpawner`'s job.

```gdscript
NetSession.end_session()                         # awaitable clean close; tells clients first
NetSession.refuse_peer(peer_id, detail)          # host-only readable refusal
NetSession.free_slots() -> int                   # host-side capacity remaining
NetSession.is_rejoining() -> bool
NetSession.capacity · accepting_joins · auto_rejoin

session_opened(is_host)
connection_interrupted(detail)
rejoin_attempted(attempt, of) · rejoined()
session_ended(reason, detail)                    # LOCAL_LEAVE / HOST_CLOSED / CONNECTION_LOST / REFUSED
peer_refused(peer_id, detail)                    # host-side
```

`NetTransport` gained the mechanism needed underneath: `last_end_kind()`, `has_rejoin_target()`,
`rejoin_last_target()`, `set_admission_gate()`, and `kick_peer()`. ENet accepts two short-lived
connections beyond game capacity so the host can say *why* it refused them (D-027), and dead-peer
timeouts are capped at 8 s. The lifecycle harness measured a killed client being detected and
despawned in **2.6 s** on this machine.

`tools/session_lifecycle_check.gd` is the real-process regression command. Its eight sections cover
autoload registration, host capacity, ordinary admission, over-capacity refusal without a spawn,
late joining with the complete roster, version mismatch cleanup, automatic rejoin after an unclean
drop, dead-process timeout, and clean host close without a rejoin loop. It completed 8/8 with zero
failures. LOCAL and LAN can retry their retained direct address; Steam requires asynchronous lobby
re-entry and deliberately does not pretend otherwise (F-020).

### What 1.6 leaves you — the smoothing seam, and the rule about who may read it

**`NetInterp` is registered** (`autoload/net_interp.gd`, last in the `[autoload]` list because it
resolves `PlayerNet`). It watches PlayerNet's `Players` container and gives every player this peer
does **not** own a `RemoteInterpolator`. Nothing else has to do anything: spawn a body under that
container and it is smoothed, or is skipped because it is yours. Offline it does nothing.

```gdscript
NetInterp.attach_to(body) -> bool        # give it an interpolator; false if it owns it / has no NetSync
NetInterp.interpolator_for(body) -> RemoteInterpolator
NetInterp.is_watching() -> bool          # false means "wiring is broken", not "netcode is broken"
NetInterp.debug_snapshot() -> Array[Dictionary]   # {peer, lag_ms, buffered} — 1.10's panel can read this
```

**`RemoteInterpolator` (`core/net/remote_interp.gd`) is entity-agnostic on purpose** — it is the
whole of F-004's answer for enemies (2.10) and props too, and it needs no new numbers for them
because it derives its delay from the *observed* arrival interval rather than being told the class
rate. 30 Hz players settle at ~67 ms, 15 Hz enemies at ~133 ms, automatically.

```gdscript
configure(target: Node3D, pitch_target: Node3D = null, sync: MultiplayerSynchronizer = null)
push_snapshot(position: Vector3, yaw: float, pitch: float)   # for a source that is not a synchronizer
reset()                                                       # after a teleport/respawn/level swap
lag_seconds() · buffered() · debug_stats()
```

Three things it would be expensive to rediscover:

1. **Nothing gameplay-authoritative may read an interpolated transform.** The interpolator overwrites
   `position`/`rotation.y` every rendered frame with a value ~67 ms in the past. It is attached only
   on the *receiving* side, so `player_net.gd`'s host speed check is unaffected today — but a future
   host-side check that runs on a client's copy of another client would be reading fiction. Read the
   synchronizer's value, or read it on the peer that owns it.
2. **It hooks `MultiplayerSynchronizer.synchronized`** and samples the node right after the engine
   writes to it, which is why 1.6 needed *no* change to `player_controller.gd` and added **nothing to
   the wire** — velocity is still deliberately absent (1.5's call stands; interpolation did not need
   it, and extrapolation derives it from the last two snapshots).
3. **`physics_interpolation_mode` is forced OFF on the subtree it drives**, and restored in
   `_exit_tree()`. D-026 says why: leaving it on makes the engine resample our per-frame output onto
   the 60 Hz grid and adds a tick of lag. If 1.7 ever detaches an interpolator on an authority change,
   free the node — don't just stop it — or that restore never runs.

`RemoteInterpolator` is a new `class_name`, so **F-016 applies to it**: both call sites `preload()`
the script instead of naming the class bare, and anything run via `--script` must keep doing that
until Sequoyah has opened the editor once since this landed.

**`tools/interp_check.gd`** is the fourth headless harness (`Godot --headless --path .
--script tools/interp_check.gd`, exits non-zero on failure, currently green). It measures judder as
*% of frames where the node visibly stopped*, and its control stream is read through
`get_global_transform_interpolated()` so the engine's own smoothing is included rather than being
handicapped. Numbers on this machine: **engine interpolation alone 67% still frames / CV 1.64 → plus
snapshot interpolation 1.5% / CV 0.21**, at a cost of ~67-84 ms of drawn latency. Extend it rather
than writing a fifth: phase A drives the interpolator directly with jitter and 6% loss (loopback has
neither), phase B checks a 100 m teleport snaps instead of smearing, phase C is two real ENet peers
and a real `player.tscn`.

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

**F-013 is closed, and 1.8 inherits its answer.** The convention is settled as **D-024**: the
`&"synced"` group holds *every `MultiplayerSynchronizer`, one member each* — it counts update streams,
because that is what maps to the bandwidth budget above. The name lives once as
`NetConfig.SYNCED_GROUP` and is joined at construction, next to the authority assignment; 1.8's
per-class synchronizers just do the same and the panel's count stays meaningful.

### What 1.8 shipped — every replicated entity from here on goes through one call

`core/net/net_interest.gd`, `class_name NetInterest`. **Not an autoload**, so it costs nobody a
`project.godot` claim, and the observer registry is `static` because the filter runs once per entity
per peer per physics tick — 1.9's shape is 1000 calls a tick, which must not resolve a singleton or
walk the tree to answer.

```gdscript
# In the entity's _ready(), where authority is set, BEFORE add_child() (F-012):
sync.set_multiplayer_authority(NetConfig.HOST_PEER_ID)
NetInterest.configure(sync, self, NetInterest.Class.ENEMY)   # returns the filter, or null
add_child(sync)
```

`configure()` is the only seam, and it does three things so a construction site cannot half-opt-in:
sets `replication_interval` and `delta_interval` from the class, joins `NetConfig.SYNCED_GROUP`
(D-024 — nothing else joins it any more, including `PlayerController`), and installs the distance
filter for the filtered classes. The numbers live in `NetConfig`, not in `NetInterest`.

| `NetInterest.Class` | interval | delta | filtered | for |
|---|---|---|---|---|
| `PLAYER` | 30 Hz | 30 Hz | **no** | six of them; a teammate vanishing at 121 m is a bug report |
| `ENEMY` | 15 Hz | 15 Hz | yes | host-simulated, many, 15 Hz + interpolation is indistinguishable |
| `PROP` | 1 s | 100 ms | yes | on-change only — the 1 s interval is a cheap ceiling on a mistake, not a rate |

Observers — where each peer looks from — are pushed by `autoload/player_net.gd:_publish_observers()`,
every physics tick, **host only**, because every filtered row of §2.2 is host-authoritative. If a
client ever owns something filtered, that is the line to move. `NetInterest.clear_observer(peer)` on
despawn and `clear_observers()` on disconnect are already wired.

**D-025 settles the two calls that look like tuning and aren't:** two radii instead of one (enter
120 m / leave 144 m, so a boundary-hugging entity does not pay a despawn+respawn per peer per tick —
this is the churn 1.9 could only infer from reliable-channel volume), and
`VISIBILITY_PROCESS_PHYSICS` instead of `IDLE`, because re-evaluation rate *is* bandwidth and §5a
forbids hanging that off the render frame. `RadiusFilter.transitions` counts churn if you want to
measure rather than infer it.

**Two API facts worth not rediscovering.** `MultiplayerSynchronizer` in 4.7.1 has **no**
`is_visible_to()`; `get_visibility_for()` reads back only the *manual* `set_visibility_for()`
override, never the filter's answer, and `update_visibility()` pushes straight into the replicator,
which needs a live session. So there is no offline way to ask the engine what a filter decided —
proving the engine calls your filter at all requires real peers. And `replication_interval = 0.0`
means *every frame*, not "never", which is why `PROP` is 1 s.

### Headless verification you inherit — extend these rather than writing a fourth harness

All three run without an editor, exit non-zero on failure, and are the pattern 1.6/1.7/1.8 should
copy. **Verify your own work with them; do not ask Sequoyah to press Play and report back.**

| Tool | What it proves | Command |
|---|---|---|
| `tools/synced_group_check.gd` | Every synchronizer construction site joins `&"synced"` — builds both for real and reads the live tree back | `Godot --headless --path . --script tools/synced_group_check.gd` |
| `tools/net_debug_panel_check.gd` | The panel's 19 checks, including a real ENet host+client session with genuine RTT and bandwidth | same form |
| `tools/bench_replication.gd` | 1.9's spike: 6 peers, 200 entities, interest management on and off | same form |
| `tools/interest_check.gd` | 1.8's 40 checks: per-class intervals, hysteresis in both directions, and a live 1-host/2-client ENet session where moving one observer makes the entity appear and disappear on that client only | same form |

Two process notes that cost time when they were learned: a `--script` main loop compiles before
autoloads register, so `load()` them at runtime rather than preloading at class scope (**F-011**); and
nodes added in `_initialize()` have not run `_ready()` yet, so anything a node builds for itself must
be checked on the next frame via `call_deferred`.

Three more, all paid for on 2026-08-16:

- **A new `class_name` resolves nowhere until you rebuild the class cache** (**F-016**, hit
  independently by 1.8 and 1.11). `.godot/global_script_class_cache.cfg` is gitignored and only the
  editor's project scan writes it, so a brand-new global class is "not declared in the current scope"
  in every headless run *and* in the game itself. Fix, once, no editor window:
  `Godot --headless --path . --import`. It also generates the new script's `.uid` (**F-017**).
- **Do not pace a two-process game run with `--fixed-fps`.** It pins the *delta*, not the wall clock,
  so 420 "seconds" of simulation elapse in a fraction of a real one and the ENet handshake never gets
  time to happen — the client just sits on "connecting" and quits. `--max-fps 60 --quit-after 900`
  paces against the real clock and connects reliably.
- **A script error inside an `await`ed harness coroutine kills only that coroutine.** The run
  continues and prints `PASS` over whatever checks happened to have already run. `interest_check.gd`
  guards against that with a section counter asserted at the end; copy it.

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
| 1.12 | ~~Windows guest~~ **Nothing technical.** The physical Windows PC passed the pinned determinism probes; the Linux KVM guest exists. | Run the simultaneous Steam session in `docs/STEAM_CROSS_PLATFORM_TEST.md` |
| 4.0b | ~~A Windows guest existing at all~~ **done** | closed by `aa2efb2` |

The foundation is settled: `NetTransport` (1.2), `DevLaunch` (1.3), `SteamLobby` (1.4) and GodotSteam
4.21 (1.1) are all registered, booting and verified, so every prompt here is written against a real API
rather than a proposed one.

**1.12 test driver:** `DevLaunch` accepts debug-only `--steam-host` and
`--steam-join=<lobby_id>` arguments. They call the normal asynchronous `SteamLobby` flow, not
`NetTransport` directly, so lobby membership and Steam P2P start in the only supported order. The
complete three-machine commands, fresh-clone addon/import prerequisite, observed-state checks, and
PASS/FAIL/BLOCKED criteria are in `docs/STEAM_CROSS_PLATFORM_TEST.md`.

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
