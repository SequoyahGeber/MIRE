# NEXT — what am I doing right now?

> **Open this first, every time.** It exists so that coming back after a week or a month costs you ten
> minutes instead of a weekend. Update it before you stop working. Always.

---

## Status

**Milestone:** M1 · Network spine — **1.4 landed, 6/14.** M0 is closed, 10/10.
**Last session:** 2026-08-16 (claude) — unblocked 1.5–1.8 with D-023 (replication nodes are built in
code, not authored in scenes) and wrote the 1.5 prompt. Nothing is in flight.

Both risk spikes came back **GREEN**: chunked terrain meshing stays in GDScript (D-015), runtime
NavMesh baking stays and the grid-A* fallback is dropped (D-016). Neither result is unconditional —
see *M0 debts* below.

**The game runs.** Open the project and press Play: you spawn in a greybox level and can walk, sprint,
jump and look around. **F3** overlay · **`~`** console · **Esc** releases the mouse.

**Four autoloads live, verified booting 2026-08-16** on `4.7.1.stable.official.a13da4feb`, Metal
Forward+ on an M5 Pro: `DebugOverlay`, `DebugConsole`, `Registry`, `NetTransport`. Boot log reads
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

## Next task — three ready-to-paste prompts, none of them yours

All three are agent chats, none of them share a file, and all three can run at once. Everything you do
here is copy, paste, and read the sign-off.

### → 1.5 · Networked player: spawner + synchronizer — `[T2]` · ~3h · **an agent chat**

**Paste this one first.** It's what turns "two windows connect" into "two players see each other", and
1.6, 1.7 and 1.8 are all written against the node layout it establishes.

Ready-to-paste prompt: [DELEGATION.md](DELEGATION.md) → *Task 1.5*. **Opus 5 · effort high · agent
name `spawn`.**

**It needs nothing from you in the editor.** That's new — see D-023 below. It holds `project.godot`
while it runs, so **close the Godot editor before you paste it**, or its autoload registration gets
silently discarded on your next save.

### → 1.9 · Spike R1 — replication load — `[T2]` · ~1.5h · **an agent chat**

The last unspiked risk in `ARCHITECTURE.md` §6. If it comes back red, the fallback rewrites how every
replicated system in the project gets written — so it wants answering while 1.6–1.8 are still unwritten.

**Opus 5 · effort high · agent name `load`.**

### → 1.10 · Network debug panel — `[T1]` · ~1h · **an agent chat**

Cheap quota, and it's what makes 1.5–1.8 debuggable instead of guessable. **Sonnet 5 · effort medium ·
agent name `netui`.**

---

## What changed this session — D-023

1.5, 1.6 and 1.8 had been parked for three sessions as *"scene work, only Sequoyah can wire it."*
That was wrong. `MultiplayerSpawner`, `MultiplayerSynchronizer` and `SceneReplicationConfig` all have
full script APIs — task 1.9's prompt had been requiring exactly that construction all along, because a
headless benchmark can't author scenes either. So they get **built in code**, and **1.5 needs no
`.tscn` change at all**.

Two things fall out of that, both written into D-023 so nobody relitigates them:

- Networked players live at `/root/PlayerNet/Players` — a fixed path, identical on every peer, that
  survives the level swaps M4 introduces.
- The `Player` hard-instanced in `greybox_test.tscn` becomes a **spawn point**: in a session the
  spawner reads its transform, frees it, and spawns per-peer copies. Offline it's untouched, so
  "press Play and walk around" still works.

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
