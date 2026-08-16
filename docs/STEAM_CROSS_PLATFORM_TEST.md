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
