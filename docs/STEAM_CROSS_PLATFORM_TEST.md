# MIRE Steam cross-platform test — task 1.12

This is the M1 exit test: one macOS host, one Windows client, and one Linux client in the same
friends-only Steam lobby using App ID 480. It exercises the real `SteamMultiplayerPeer` transport,
the lobby callback path, version admission, player spawning, and remote-player replication.

Run it only when all three machines and three distinct Steam accounts are available at the same time.
Use the same committed revision on every machine. This is a debug-build test; it does not need port
forwarding, and it does not require an export — though **an exported debug build is a valid and much
cheaper substitute for a checkout on the client machines**; see *Running it from exported builds*
below for the launch commands and the two pass criteria that change. If either client is a VM, read
*Testing on VMs* before you record a single timing number.

## Before the call

1. Each machine uses stock Godot `4.7.1.stable.official.a13da4feb` and has the Steam desktop client
   running and signed into a different account. The three accounts must be Steam friends.
2. Each checkout is clean and at the same commit. Record `git rev-parse HEAD` and `git status --short
   --branch` in that machine's log.
3. Install the pinned GodotSteam 4.21 addon from D-022 in **every** clone; it is intentionally
   gitignored and a plain clone does not include it. Then run one import scan before launching the
   game:

   ```bash
   Godot --headless --editor --path . --quit
   ```

   Substitute the absolute pinned Godot executable on Windows. Do not open and save scenes.
4. On each machine, run `tools/steam_check.gd` with the Steam client still running. It must pass.
   Keep complete command output, including errors, in a platform-labelled text file.
5. On Windows, run the preflight and game in the signed-in interactive desktop session. A process
   launched directly by the OpenSSH service cannot see Steam's per-user IPC even when Steam is open
   on the console; an interactive scheduled task is acceptable for remote orchestration.
6. Keep Windows Firewall enabled. Add a program allow rule scoped to the pinned Godot executable and
   the active network profile. Disabling an entire firewall profile is diagnostic state, not a valid
   test or completed VM configuration.

## Run the lobby

The task adds debug-only launch arguments to `DevLaunch`; they invoke the existing `SteamLobby`
API rather than bypassing it. Start from a terminal so each process writes an independent log.

On the **macOS host**, launch the project with:

```bash
Godot --path . -- --steam-host
```

The host log must show both `lobby <id> created` and `hosting STEAM`. Copy the numeric lobby ID.

On the **Windows client**, then the **Linux client**, launch with that exact ID:

```bash
Godot --path . -- --steam-join=<lobby_id>
```

Windows PowerShell requires the call operator for a quoted executable path, for example
`& "C:\\path\\Godot_v4.7.1-stable_win64.exe" --path . -- --steam-join=<lobby_id>`.

On all three windows press **F3** until the full overlay appears. The host must report STEAM / host
and peers `[1, 2, 3]`; each client must report STEAM / client and the same three peers. `RTT` and
bandwidth show `n/a` in Steam mode by design—GodotSteam exposes no equivalent ENet statistic.

## Evidence and pass criteria

For at least 60 seconds, each person walks, jumps, sprints, and turns while the other two observe.
Take one screenshot per machine showing all three players and the full F3 overlay. Preserve all three
launch logs from creation through clean exit.

PASS requires all of the following:

- all three `steam_check` runs pass on the pinned engine;
- exactly one MIRE friends-only lobby is created, and both clients enter it;
- every machine reaches the three-peer STEAM session and displays three spawned players;
- remote player movement is visible and smooth enough to follow on both other platforms for 60 s;
- no connection failure, version refusal, duplicate player, or unexpected disconnect occurs;
- each client leaves cleanly, then the host leaves, with logs showing player removal and lobby exit.

If it fails, retain the logs and screenshots, report the platform and first failure line, and do not
change code during the session. A Steam client/account/addon/engine prerequisite failure is BLOCKED;
a reproducible lobby/session failure with valid prerequisites is FAIL.

## The first-join timeout, and the measurement this run owes (F-023)

Windows has a known intermittent first-join failure: the connection timer can expire even with valid
prerequisites, while an immediate retry against the same lobby connects. **As of 2026-08-16 that
retry is automatic** (D-029) — Steam's budget is now its own constant, provisionally 20 s, and
`NetSession` retries a timed-out first join twice by itself, at 0.5 s and 2.0 s. Expect these lines
rather than a dead end:

```
[warn] net: [client] connect timed out (…) — NetSession retries from here
[info] net: NetSession: connect retry 1/2 to steam:<lobby_id>
```

This changes nothing about the verdict. **A first join that times out is still a connection failure,
so a run the retry rescues is not a PASS** — the criteria above require none. Preserve the failed
attempt rather than overwriting it, exactly as before.

**This run also owes a measurement, and it is the reason F-023 is still open.** Nobody has ever
recorded how long a Steam first join actually takes, on any platform; 20 s is an allowance, not
evidence. Every successful join now prints its own duration:

```
[info] net: connected to steam:<lobby_id> as peer N (STEAM) in 4.31s
```

Capture that line from **all three** platforms, including any retried attempt, and report the three
numbers with the logs. `STEAM_CONNECT_TIMEOUT_SEC` gets set from the observed tail afterwards, and
F-023 moves to Resolved on the strength of it. If Windows connects well inside 10 s every time, say
so — that is evidence the budget was never the problem, and it points somewhere else.

Before the session, confirm the mechanism itself still passes on the machine you are driving from:

```bash
godot --headless --path . --script tools/connect_retry_check.gd
```

## Running it from exported builds instead of three checkouts

The procedure above assumes a source checkout, stock Godot and the gitignored addon on every machine.
**An exported build is a valid substitute** and is far cheaper to stage — one directory copy per
machine, no engine install, no addon install, no import scan. Everything 1.12 tests
(`SteamMultiplayerPeer`, the lobby callback path, version admission, spawning, replication) runs
identically. What changes is the launch command, the preflight, and how version parity is evidenced.

**The debug-only launch arguments still work, and that is what makes this route possible at all.**
`core/dev/dev_launch.gd:70` gates them on `OS.is_debug_build()`, which an export built from the
**debug** templates satisfies. Confirm it per machine by looking at the GodotSteam library shipped
beside the binary — `libgodotsteam.<platform>.template_debug.*` is the debug template. A
`template_release` export ignores `--steam-host` / `--steam-join` entirely, and there is no other way
to drive the lobby from a command line; use the in-game lobby UI (**M**) or re-export as debug.
Arguments work with or without a bare `--` separator: `_parse_launch()` reads
`OS.get_cmdline_user_args()` and falls back to `OS.get_cmdline_args()`.

| | host | client |
|---|---|---|
| macOS | `./MIRE.app/Contents/MacOS/MIRE --steam-host` | `./MIRE.app/Contents/MacOS/MIRE --steam-join=<lobby_id>` |
| Windows | `.\MIRE.console.exe --steam-host` | `.\MIRE.console.exe --steam-join=<lobby_id>` |
| Linux | `./MIRE.sh --steam-host` | `./MIRE.sh --steam-join=<lobby_id>` |

Use `MIRE.console.exe` on Windows, never `MIRE.exe`: the plain executable is a GUI-subsystem binary
that writes nothing to the terminal, and the launch log is required evidence.

**Preflight, in place of `tools/steam_check.gd`.** That harness is a `--script` tool and needs a
checkout, so a machine holding only an exported build cannot run it. What stands in for it:

- The Steam client is running and signed into a **distinct** account on each machine, and all three
  accounts are mutual friends. Not optional — the lobby is friends-only.
- `steam_appid.txt` is **not** shipped beside the binaries and does not need to be:
  `autoload/steam_lobby.gd:129` passes `NetConfig.STEAM_APP_ID` (480) to `steamInitEx()` explicitly,
  rather than the app-id-0 path that reads the file. If Steamworks nevertheless fails to initialise
  on a machine, dropping a one-line `steam_appid.txt` containing `480` next to the executable is the
  first thing to try.
- The game's own startup log replaces the harness output: the Steam identity line from
  `steam_lobby.gd:141` (persona name, SteamID, app id 480) is the proof Steamworks came up.

**Version parity is stronger on this route, and cheaper to evidence.** Step 2's "record `git
rev-parse HEAD` on every machine" exists to prove the three builds agree; three copies of one export
prove it outright. Hash the pack instead — one command per machine, and identical output is the whole
proof:

```bash
shasum -a 256 MIRE.pck
```

On macOS the pack is at `MIRE.app/Contents/Resources/MIRE.pck`. Record the three hashes with the
logs. This covers something `rev-parse` never did: an uncommitted working-tree difference between
machines, which is exactly how `PROTOCOL_VERSION` drift produced a false failure in the 2026-08-17
run below.

**One thing this route cannot skip.** A build exported before F-121's fix loads *zero* content —
no items, recipes, stations, weapons, loot, powerups, buildables, haulables or enemies — and does so
silently, because the runtime `.tres` scan misses Godot's `.remap` suffix. Boot one copy and read the
content line before staging the others:

```
[info] content: loaded 23 item(s), 13 recipe(s), 2 station(s), 9 weapon(s), 1 loot table(s), …
```

A `loaded 0 item(s)` there means the export predates the fix, and every downstream observation in the
session is worthless. Verified on the 2026-08-18 12:16 export set: macOS ran headless and reported 23
items, 13 recipes, 2 stations, 9 weapons, 1 loot table, 5 powerups, 2 buildables, 1 haulable, 4
attunements and 1 enemy definition, and all three packs hashed identically
(`92cc6f3bb8c83132e64905904b72af57f287f58a7cdafa3428e7f750a8a3927e`).

## Testing on VMs: read F-025 before you trust any timing number

Both client machines in this project's setup are VMs, and F-025 is specifically about what that does
to a Steam run. `SteamLobby._process()` pumps `run_callbacks()` **once per rendered frame**, so every
Steam callback — lobby entry, the P2P rendezvous, connection state — is serviced at whatever rate the
machine happens to be *rendering*. A VM without GPU passthrough software-rasterizes: the Windows VM
in the 2026-08-16 session ran at **2–3 FPS** against the macOS host's 113, which is roughly 20
callback pumps inside a 10 s connect window instead of ~1,130. That is the leading hypothesis for
F-023's intermittent first-join timeout, and it means a VM run can manufacture a failure that looks
like a network defect and is not.

What follows from it, for this run:

- **Enable 3D/GPU acceleration in both VMs if the hypervisor offers it.** Everything below is
  mitigation; this is the actual fix.
- **A retried first join is expected on a software-rendered client, and is still not a PASS.** D-029
  retries twice on its own (0.5 s, 2.0 s) inside a 20 s Steam budget, so the run will likely survive
  — but the criteria above require no connection failure, and a join the retry rescued is one.
- **Record the F3 frame rate beside every `connected … in N.NNs` line.** A latency measured on a
  2 FPS client measures the renderer, not the network. F-023 must not be closed from a
  software-rendered machine; that number has to come from the physical Windows PC.
- **Consider a LAN warm-up first.** `--lan-host` / `--lan-join=<ip>` exercises admission, the version
  handshake, spawning and replication over real sockets with **no dependence on frame rate** (F-054,
  and `dev_launch.gd`'s own header says as much). A failure there is a real defect, while the same
  failure over Steam may only be the pump. It does not close 1.12 — that is specifically the Steam
  transport — but it separates the two causes before you spend the three-account session.

## Three-platform LAN run — 2026-08-17 · PASS (ENet, not Steam)

**This is not a 1.12 pass, and the distinction is the whole point of reading this section.** 1.12
tests `SteamMultiplayerPeer`: the lobby, the callback path, and Steam's rendezvous. This run used
**ENet over the LAN** and therefore proves everything 1.12 is about *except the Steam transport
itself*. It is recorded here because it retires most of 1.12's risk at a fraction of the cost, and
because it establishes the machine setup the eventual Steam run needs.

Driven headlessly over SSH from the macOS host by `flint5`; all three machines on commit `c67eca7`,
`PROTOCOL_VERSION = 7`, stock Godot `4.7.1.stable.official.a13da4feb`.

| | macOS (host) | Linux VM `192.168.50.124` | Windows VM `192.168.50.47` |
|---|---|---|---|
| Role | `--lan-host` on `*:27515` | `--lan-join=192.168.50.176` | `--lan-join=192.168.50.176` |
| Peer id | 1 | 255386784 | 1840122116 |
| Connect latency | — | **0.20 s** | **0.28 s** |
| Final peer list | `[1, 255386784, 1840122116]` | identical | identical |
| Undeclared engine errors | 3 (all one known defect, below) | **0** | **0** |

What it establishes, criterion by criterion against the PASS list above:

- **Three-peer session, three spawned players** — host spawned peers 1, 255386784 and 1840122116 at
  three distinct spawn points; all three machines independently reported the same peer list.
- **Cross-platform replication in both directions** — Windows smoothed remote player `255386784`
  (Linux) and Linux smoothed `1840122116` (Windows), so this is not merely host↔client: each client
  received the other platform's player through the host. All four host-authoritative crawlers
  replicated to both clients, with `NetInterp` smoothing every one (F-004's enemy half, in the wild).
- **60 s stability** — peer list identical at T+0 and T+60, zero disconnects, zero timeouts.
- **Clean ordered exit** — Linux left first (host logged `peer 255386784 left — peers now
  [1, 1840122116]` then `despawned player 255386784`), then Windows (`peers now [1]`, despawn
  logged). No duplicate players, no version refusals, no unexpected drops at any point.

**Not covered, and still owed by a real 1.12 run:** the Steam transport, lobby creation/join,
`steam_check` on all three, 60 s of *observed* movement, and the three screenshots. Headless clients
have no renderer, so "movement is visible and smooth" cannot be judged this way — the closest
equivalent captured here is that replication and interpolation ran continuously for 60 s with no
error.

### The machine setup this run leaves behind (the expensive half of 1.12)

Both VMs are now provisioned and reachable, which is most of what made 1.12 costly to schedule:

- **Linux** `ubuntu@192.168.50.124` — Godot 4.7.1 at `~/Godot_v4.7.1-stable_linux.x86_64`, project at
  `~/mire-current`, GodotSteam addon installed at `addons/godotsteam/`, `verify_setup` green.
  Steam is **not** running; no git installed, so refresh by piping `git archive` over SSH.
- **Windows** `windows@192.168.50.47` (key `~/.ssh/mire_windows_vm`) — Godot at
  `C:\tools\godot\`, project at `C:\MIRE-current`, addon installed, Steam **running**, git now
  installed via winget so it can clone/pull directly (the repo is public).

Three traps this run paid for, all of which will bite the Steam run too:

1. **Admin accounts on Windows read `C:\ProgramData\ssh\administrators_authorized_keys`**, not
   `~/.ssh/authorized_keys`, and sshd *resets the connection* rather than denying it if that file's
   ACLs are loose. A blank-password account is additionally refused for any network logon by default
   policy — the account must have a password set for key auth to work at all.
2. **`start /b` over SSH silently spawns nothing on Windows.** Hold the SSH session open and let the
   process run under it instead; a detached launch produced no process and no log file.
3. **Protocol drift between provisioning and testing is the likeliest false failure.** During this
   session `PROTOCOL_VERSION` moved 6 → 7 → 8 (8 uncommitted, task 2.11 in flight). Re-check it on
   all three machines immediately before launching, or the version gate will correctly refuse a join
   and look like a network fault.

**One real defect surfaced, unrelated to networking:** commit `c187ede` deleted
`world/gen/test_map_props.gd` but left `TestMapProps` registered in `project.godot`, so committed
HEAD boots with a failed autoload on every platform — the 3 host errors above, reproduced identically
on all three machines. The fix exists uncommitted in the working tree, entangled with 2.11's
`DayNight` and 2.13's `PlayerHealth` registrations. Filed as F-055.

## Partial rerun — 2026-08-16

A two-platform cleanup run used macOS as host and a fresh `origin/main` archive at `C:\MIRE-main`
on the Windows Unraid VM. Windows Firewall was enabled on Domain, Private, and Public profiles.
Windows peer `579922246` joined lobby `109775242382594016`; its F3 overlay showed `STEAM client`,
peers `[1, 579922246]`, and two players. The host logged admission, spawned the remote player, then
logged its departure and despawn before exiting with code 0.

This is useful join/cleanup evidence but **not a task 1.12 PASS**: Linux was not present, the Windows
launch log did not flush its successful-join latency while the interactive scheduled task was live,
and the required three-platform movement/screenshots were not collected. Do not use the stale
`C:\MIRE` copy: it still has the superseded 10-second timeout. Refresh `C:\MIRE-main` from
`origin/main` before the final run.
