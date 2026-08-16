# NEXT — what am I doing right now?

> **Open this first, every time.** It exists so that coming back after a week or a month costs you ten
> minutes instead of a weekend. Update it before you stop working. Always.

---

## Status

**Milestone:** M1 · Network spine — **1.5, 1.9 and 1.10 landed, 9/14.** M0 is closed, 10/10.
**Last session:** 2026-08-16 — networked players replicating between two processes (1.5), R1 measured
**AMBER** (1.9), live net debug readout (1.10), and the delegation model replaced with self-briefing
agents (`agent brief`). Nothing is in flight.

The M0 spikes came back **GREEN**: chunked terrain meshing stays in GDScript (D-015), runtime NavMesh
baking stays and the grid-A* fallback is dropped (D-016). Neither is unconditional — see *M0 debts*.
**R1 (netcode) is AMBER**, which is not a blocker but does promote task 1.8 from optional to required;
the numbers are under *What changed this session*.

**The game runs.** Open the project and press Play: you spawn in a greybox level and can walk, sprint,
jump and look around. **F3** overlay · **`~`** console · **Esc** releases the mouse.

**Seven autoloads live, verified booting 2026-08-16** on `4.7.1.stable.official.a13da4feb`, Metal
Forward+ on an M5 Pro: `DebugOverlay`, `DebugConsole`, `Registry`, `NetTransport`, `DevLaunch`,
`SteamLobby`, `PlayerNet` — plus `NetDebugPanel`, which you wired. Boot log reads
`content: loaded 0 item(s), 0 recipe(s)` and `net: NetTransport ready (offline)` — 0/0 is correct,
no `.tres` content is authored yet. `NetConfig` is a `class_name`, **not** an autoload; don't add it.

Godot 4.7.1-stable, pinned — don't upgrade mid-milestone. That build hash is also the determinism
baseline in `ARCHITECTURE.md` §6a, so upgrading invalidates R6.

---

## Roles (D-014, superseded by D-020)

No fixed planner/coder split — any agent (Claude Code chat, Codex, a second Claude session) can take
any task; who picks it up depends on which plan has quota available. Sequoyah is the only fixed role:
**Integrator** — Godot editor, assets, tuning, playtesting, commits.

Protocol: [AGENTS.md](../AGENTS.md). Start every session with `.agent/bin/agent start <name>`.

---

## Next task — say "start 1.6" and stop there

**Starting a task no longer means pasting a prompt.** Open a fresh chat, give it the task id, and the
agent runs `agent brief <id>` itself: that prints the task, the open findings, what the last tasks in
this milestone left it, and who holds which files. It claims, works, verifies headless, files what it
learned in the repo, and ships. What comes back to you is what only you can act on.

Any of these can run at once — no two touch the same file. Pick by quota, not by order:

| Say this | Task | Why it's next |
|---|---|---|
| **"start 1.8"** | Interest management | **Now mandatory, not optional** — R1 came back AMBER and filtering is the only thing that fits the budget. Start here |
| **"start 1.6"** | Remote-player interpolation | Remote players currently arrive at 30Hz and stutter. Read F-004 first — it argues engine `physics_interpolation` may cover this |
| **"start 1.7"** | Connection lifecycle | Join mid-session, host quits, timeouts. 1.5 did the obvious signal handling only, deliberately |
| **"start 1.11"** | Version handshake | Refuse mismatched builds legibly. Independent of the other three |

Effort: Opus 5 · high for 1.6/1.7/1.8; Sonnet 5 · medium is enough for 1.11. Give each parallel chat
its own `MIRE_AGENT` name — that is the one thing that still has to come from you.

---

## What changed this session

**M1 netcode is real.** 1.5 (networked player), 1.9 (R1 spike) and 1.10 (debug panel) all shipped, and
none of them needed anything from you in the editor.

- **Two players, two windows, each driving their own** — `PlayerNet` spawns one player per peer under
  `/root/PlayerNet/Players`, authority derived from the node's name, position/yaw/pitch replicated at
  30Hz. Verified with two headless processes, both directions.
- **R1 is AMBER, and that has teeth.** 200 entities unfiltered = 918 KB/s host up, 7.3× over the
  125 KB/s ceiling. With §2.5 interest management: 105 KB/s at 30Hz, 57 KB/s at 15Hz. CPU was never
  the constraint (1.18 ms/frame worst case). So the §6 R1 fallback — hand-rolled binary packets — is
  **not** needed, but **1.8 stops being optional**: it is the thing that makes the budget fit.
- **Agents now brief themselves.** `agent brief <id>` plus a close-out contract in `AGENTS.md` step 3
  replaced the hand-written-prompt model. Findings go to `FINDINGS.md`, settled calls to
  `DECISIONS.md`, APIs the next task needs to `DELEGATION.md` *Current state* — so nothing has to
  travel through you to reach the next agent.

---

## Then, in order

| # | Task | Tier | Who | Est |
|---|---|---|---|---|
| 1.6 | Remote-player interpolation | T2 | agent | 2h |
| 1.7 | Connection lifecycle: join mid-session, disconnect, host quits, timeouts | T2 | agent | 2h |
| 1.8 | Interest management: visibility filters + per-class `replication_interval` | T2 | agent | 1.5h |
| 1.11 | Protocol/build version handshake | T2 | agent | 1.5h |

1.6 and 1.8 want 1.5's node layout in hand before their prompts get written — writing them now means
guessing at names. 1.7 and 1.11 are writable earlier if you'd rather accept a rebase.

---

## M0 debts — booked as M4 gates, don't lose them

Both spikes went green with half the question unanswered. Both are now real tasks (`4.0a`, `4.0b`) at
the top of M4 rather than notes in a findings file, because M4's chunk streaming budget gets designed
against whatever they return.

| # | What's actually unmeasured | Who | Est |
|---|---|---|---|
| 4.0a | `ConcavePolygonShape3D` cooking + GPU mesh upload per chunk. R2 ran headless — no upload, no material, no collision. R3 measured *navigation* baking, a different code path. F-005, and the standing caveat on D-015. | agent | 1.5h |
| 4.0b | Determinism on Windows x86_64 — the third column in `ARCHITECTURE.md` §6a is still empty. | you | 30m |

Nothing in M1 depends on either. Don't pull them forward; just don't start 4.1 without them.

---

## Cross-platform (D-013)

Shipping macOS + Windows + Linux with cross-play. Steam P2P makes cross-play itself nearly free, but it
creates one real risk: clients regenerate terrain from a shared seed, and float results aren't
guaranteed identical across architectures and C libraries.

**Linux is done — see D-017.** Noise and PRNG are bit-identical across macOS arm64 and Linux x86_64;
raw `sin`/`cos`/`pow`/`exp`/`log` are not. §4 stands, and the price is the world-gen safe set now
written into `ARCHITECTURE.md` §7.

**Task 4.0b — the same two commands on a Windows x86_64 guest:**

```bash
godot.exe --headless --path . --script tools/check_determinism.gd
```

```bash
godot.exe --headless --path . --script tools/check_determinism_ops.gd
```

Godot **4.7.1-stable build `a13da4feb`**, or the comparison means nothing. Compare against
`ARCHITECTURE.md` §6a and fill in the Windows column. MSVC is a third C library, so this is a real
test and not a formality — but the outcome that matters is narrow: `rng_sequence` and `noise_*` must
match, and the four rows in the ops probe's *first* group must match. Divergence in the second group
is expected and already accounted for. **Do this before M4 builds anything on seeded generation.**

You have a Linux guest already; a Windows VM is the missing piece — that's the actual work in 4.0b,
and it's yours because it's provisioning, not code.

**The two commands themselves are not yours to type.** Once the VM exists and is reachable, hand
4.0b to an agent chat the same way as any other task — the Linux half was driven that way over SSH.
Getting a Windows guest to that point is the part only you can do.

---

## Tools

**You don't run these — ask an agent chat to.** Your side of this project is the Godot editor, asset
work, tuning, playtesting and pasting task prompts. Anything with a shell belongs to an agent.

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/verify_setup.gd
```

Input map responds to real key presses, autoloads registered, scenes have the node names the scripts
expect, the player actually falls and lands, and the §5a physics/vsync/fps settings resolve to their
correct *effective* values regardless of whether `project.godot` spells them out or Godot is silently
supplying its own default (F-003) — no need to re-run this after every editor save just to catch a
prune, since a pruned default-equal value still reads correct. Run it after anything structural.

`tools/setup_project.gd` regenerates the input map, autoloads and both scenes. **Don't re-run it once
you start tuning in the editor** — it overwrites the scenes.

---

## Open questions waiting on playtests

None yet — first real answers arrive at **M2 task 2.14**. Tracked in `DESIGN.md` §8.

---

## Cold-start ritual

**Yours, coming back after a break:**

1. Read this file — the *Next task* section is the answer
2. Open `.agent/BOARD.md` if you want the full picture of what's done
3. Copy the matching block out of `DELEGATION.md` into a fresh chat at the model it names

**The agent's, in that fresh chat** (already written into every prompt, listed here for reference):

1. `MIRE_AGENT=<name> .agent/bin/agent start <name>` — prints what's in flight
2. Read `AGENTS.md`, then this file
3. Skim the last entry or two in `.agent/JOURNAL.md` if someone handed off
4. `MIRE_AGENT=<name> .agent/bin/agent claim <id> <files...>` **before** editing
5. Do the work
6. `done` or `handoff`, then `ship`, and update this file

The `MIRE_AGENT=` prefix goes on every one of those commands rather than being `export`ed once —
each shell call is a fresh process, so an exported name is silently lost and claims land under the
wrong agent.

---

## Parking lot

- Seed sharing / daily seed with a friends leaderboard by Cycle depth
- Spectator mode for dead players
- A "Cycle 1 speedrun" mode
- Cosmetic hats. There must be hats.
