# NEXT — what am I doing right now?

> **Open this first, every time.** It exists so that coming back after a week or a month costs you ten
> minutes instead of a weekend. Update it before you stop working. Always.

---

## Status

**Milestone:** M1 · Network spine — 0 of 12 tasks done. **M0 is closed, 10/10.**
**Last session:** 2026-08-16 (claude/planner) — closed M0, filed the two spike verdicts, and booked the
two M0 debts as M4 gates (4.0a, 4.0b) so they can't quietly go missing.

Both risk spikes came back **GREEN**: chunked terrain meshing stays in GDScript (D-015), runtime
NavMesh baking stays and the grid-A* fallback is dropped (D-016). Neither result is unconditional —
see *M0 debts* below.

**The game runs.** Open the project and press Play: you spawn in a greybox level and can walk, sprint,
jump and look around. **F3** overlay · **`~`** console · **Esc** releases the mouse.

Godot 4.7.1-stable, at `/Applications/Godot.app`. Pinned — don't upgrade mid-milestone.

---

## Roles (D-014)

| Role | Who | Owns |
|---|---|---|
| **Planner** | Claude Code chat | Design, architecture, roadmap, specs, decisions, reviewing landed work |
| **Coder** | Codex · second Claude | Implementing claimed tasks in `.gd`, from the planner's spec |
| **Integrator** | You | Godot editor, assets, tuning, playtesting, commits |

Protocol: [AGENTS.md](../AGENTS.md). Start every session with `.agent/bin/agent start <name>`.

---

## Next task — two, and they run in parallel

They don't share a file and neither blocks the other. Start the coder chat first, then do 1.1 while it
works.

### → 1.2 · `NetTransport` autoload — `[T2]` · ~3h · **coder chat**

**The unblock.** Seven of the twelve M1 tasks (1.3, 1.5, 1.6, 1.7, 1.8, 1.10, 1.11) are written
against this interface, so the API shape matters more than the implementation behind it.

Ready-to-paste prompt: [DELEGATION.md](DELEGATION.md) → *Task 1.2*.
**Opus 5 · effort xhigh · `export MIRE_AGENT=net`.**

It does **not** need GodotSteam installed. The prompt scopes `STEAM` to a stubbed seam that returns a
clear "not yet installed" error, and task 1.4 fills it in as a drop-in.

### → 1.1 · Install GodotSteam GDExtension — `[T0]` · ~1h · **yours**

Can't be delegated: it's a GDExtension drop plus `project.godot`, both human-only under D-007.
4.4+ branch, confirm it loads in stock Godot 4.7.1, and pin the engine version.

**Use App ID 480 (Spacewar) — don't pay the $100 yet.** [STEAM.md](STEAM.md) §2. It gives you lobbies,
P2P and the overlay with no Steamworks account. Always join by invite or direct lobby ID; 480's public
lobby list is worldwide junk, so never build against a lobby browser.

Gates 1.4 (lobbies) and 1.12 (cross-platform join).

---

## Then, in order

| # | Task | Tier | Who | Est |
|---|---|---|---|---|
| 1.3 | `LOCAL` mode — two windows, one keypress, no menus | T2 | coder | 2h |
| 1.4 | Steam lobby: create, invite via overlay, join by ID, member list | T2 | coder | 3h |
| 1.5 | Networked player: spawner + synchronizer, client-auth movement | T2 | coder | 3h |
| 1.6 | Remote-player interpolation | T2 | coder | 2h |

**1.3 is worth more than it looks.** One-keypress two-window multiplayer testing makes every
multiplayer bug for the rest of the project cheaper to find. Don't let it slip down the list.

---

## M0 debts — booked as M4 gates, don't lose them

Both spikes went green with half the question unanswered. Both are now real tasks (`4.0a`, `4.0b`) at
the top of M4 rather than notes in a findings file, because M4's chunk streaming budget gets designed
against whatever they return.

| # | What's actually unmeasured | Who | Est |
|---|---|---|---|
| 4.0a | `ConcavePolygonShape3D` cooking + GPU mesh upload per chunk. R2 ran headless — no upload, no material, no collision. R3 measured *navigation* baking, a different code path. F-005, and the standing caveat on D-015. | coder | 1.5h |
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

You have a Linux guest already; a Windows VM is the missing piece. This is a quota-free afternoon —
good work for a day when the AI budget is spent.

---

## Tools

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

1. `.agent/bin/agent start <name>` — the board tells you what's in flight
2. Read this file
3. Skim the last entry or two in `.agent/JOURNAL.md` if someone handed off
4. `agent claim <id> <files...>` **before** editing
5. Do the work
6. `agent done <id> "..."` or `agent handoff <id> "..."`, update this file, **commit**

---

## Parking lot

- Seed sharing / daily seed with a friends leaderboard by Cycle depth
- Spectator mode for dead players
- A "Cycle 1 speedrun" mode
- Cosmetic hats. There must be hats.
