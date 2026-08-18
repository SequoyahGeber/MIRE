# MIRE Steam cross-platform test — task 1.12

This is the M1 exit test: one macOS host, one Windows client, and one Linux client in the same
friends-only Steam lobby using App ID 480. It exercises the real `SteamMultiplayerPeer` transport,
the lobby callback path, version admission, player spawning, and remote-player replication.

Run it only when all three machines and three distinct Steam accounts are available at the same time.
Use the same committed revision on every machine. This is a debug-build test; it does not need an
export preset or port forwarding.

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
