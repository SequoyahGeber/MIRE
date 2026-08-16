# NEXT — what am I doing right now?

> **Open this first, every time.** It exists so that coming back after a week or a month costs you ten
> minutes instead of a weekend. Update it before you stop working. Always.

---

## Status

**Milestone:** M0 · Foundations & spikes — 5 of 10 tasks done
**Last session:** 2026-08-15 (claude/planner) — wired the input map, autoloads, player scene and greybox
level; verified against a real Godot 4.7.1 install.

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

## Next task

### → 0.5 · Tune the controller until it feels good — `[T0]` · ~2h · **yours**

This is the one that can't be delegated. Press Play, open the Player node, and adjust the exported
sliders **while the game is running**. Every feel number is exposed on purpose.

The greybox is built to answer specific questions:

| Feature | What it's testing |
|---|---|
| Ramps at 15° / 30° / 45° / 50° | `floor_max_angle` is 46° — you should climb the 45° and slide off the 50° |
| Stairs at 0.2 / 0.3 / 0.4m | Whether `floor_snap_length` (0.3) carries you up cleanly or catches |
| Gaps at 1.5 / 2.5 / 3.5 / 4.5m | Where your jump distance actually lands |
| Corridor + low lip | Wall slide, and stepping over small obstacles |

Start with `walk_speed`, `sprint_speed`, `jump_height`, `gravity_scale`. Muck feels fast — don't be shy.
When it feels right, write the numbers into `DECISIONS.md` so a future refactor can't quietly lose them.

---

## Then, in order

| # | Task | Tier | Who | Est |
|---|---|---|---|---|
| 0.7 | **Spike R2** — 100 chunked terrain meshes, measure frame times | T2 | coder | 1.5h |
| 0.8 | **Spike R3** — runtime NavMesh bake on a generated chunk | T2 | coder | 1.5h |
| 0.10 | **Spike R6** — determinism: Linux ✅ done (D-017), **Windows outstanding** (below) | T0 | you | 30m |
| 0.9 | Record all spike results in `DECISIONS.md`; pick fallbacks if any failed | T0 | you | 30m |

**0.7 and 0.8 are the ones that matter.** They're the two things most likely to force a redesign, and
they're far cheaper to discover now than in M4/M5.

---

## Cross-platform (D-013)

Shipping macOS + Windows + Linux with cross-play. Steam P2P makes cross-play itself nearly free, but it
creates one real risk: clients regenerate terrain from a shared seed, and float results aren't
guaranteed identical across architectures and C libraries.

**Linux is done — see D-017.** Noise and PRNG are bit-identical across macOS arm64 and Linux x86_64;
raw `sin`/`cos`/`pow`/`exp`/`log` are not. §4 stands, and the price is the world-gen safe set now
written into `ARCHITECTURE.md` §7.

**Task 0.10, remaining — the same two commands on a Windows x86_64 guest:**

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
