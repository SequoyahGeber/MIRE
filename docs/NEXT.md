# NEXT — what am I doing right now?

> **Open this first, every time.** It exists so that coming back after a week or a month costs you ten
> minutes instead of a weekend. Update it before you stop working. Always.

---

## Status

**Milestone:** M0 · Foundations & spikes — 4 of 9 tasks done
**Last session:** 2026-08-15 (claude) — folder structure (0.2), first-person controller (0.4), debug
overlay + log channels + console (0.6).

The scripts exist but **nothing is wired yet**. Next session is yours, in the editor: the input map,
the two autoloads, the Player scene, and the grey-box level. After that it's playable.

---

## Start here, every session

```bash
.agent/bin/agent start <your-name>
```

`claude` · `codex` · `sequoyah`. It prints the board, what's in flight, stale claims, and recent
commits. Protocol is in [AGENTS.md](../AGENTS.md); live board is `.agent/BOARD.md`.

---

## Next task

### → 0.3 · Input map — `[T0]` · ~30 min

*Project → Project Settings → Input Map.* Add these exact names — the controller reads them by
string, so a typo shows up as "why won't it move".

| Action | Bind | Also |
|---|---|---|
| `move_forward` | W | Left stick up |
| `move_back` | S | |
| `move_left` | A | |
| `move_right` | D | |
| `jump` | Space | A |
| `sprint` | Shift | Left stick click |
| `attack` | Left mouse | RT |
| `interact` | E | X |
| `inventory` | Tab | Y |
| `build` | B | |

Look is raw mouse motion, not an action — sensitivity lives on the camera. `attack`, `interact`,
`inventory` and `build` are unused for now; adding them here is free and saves a trip back later.

### → then wire what's written — `[T0]` · ~30 min

**Autoloads** (Project Settings → Autoload). Names matter — the console calls `DebugOverlay` by name.

| Name | Path |
|---|---|
| `DebugOverlay` | `res://autoload/debug_overlay.gd` |
| `DebugConsole` | `res://autoload/debug_console.gd` |

`core/util/mire_log.gd` is a `class_name`, **not** an autoload. Don't add it.

**Player scene** — `entities/player/player.tscn`:

```
Player            CharacterBody3D    player_controller.gd
├── CollisionShape3D                 CapsuleShape3D · height 1.8 · radius 0.4
└── CameraPivot   Node3D  (y = 1.6)  player_camera.gd
    └── Camera3D
```

Node names must be exactly `CameraPivot` and `Camera3D`. On the Player set *Floor Max Angle* ≈ 46°
and *Floor Snap Length* ≈ 0.3. Every feel-related number is exported with a slider — tune in the
inspector while running, that's what 0.5 is.

Controls once it runs: **F3** overlay · **`~`** console · **Esc** releases the mouse.

---

## Then, in order

| # | Task | Tier | Est |
|---|---|---|---|
| 0.5 | Grey-box test level; **tune until movement feels good** | T0 | 2h |
| 0.7 | **Spike R2** — 100 chunked terrain meshes, measure frame times | T2 | 1.5h |
| 0.8 | **Spike R3** — runtime NavMesh bake on a generated chunk, measure hitch | T2 | 1.5h |
| 0.9 | Write spike results into `DECISIONS.md`; if R3 failed, pick the fallback now | T0 | 30 min |

Done: 0.1 · 0.2 · 0.4 · 0.6. Full plan: `ROADMAP.md`. Live status: `.agent/BOARD.md`.

**0.7 is the one that matters.** Don't let the grey-box level turn into level design — it exists to
answer "does the controller feel right", nothing more.

---

## Open questions waiting on playtests

None yet — nothing is playable. First real answers arrive at **M2 task 2.14**.
Tracked in `DESIGN.md` §8.

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

Ideas that are not in scope yet. Write them here instead of building them.

- Seed sharing / daily seed with a friends leaderboard by Cycle depth
- Spectator mode for dead players (better than staring at a respawn timer)
- A "Cycle 1 speedrun" mode
- Cosmetic hats. There must be hats.
