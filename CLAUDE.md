# MIRE

Co-op roguelike survival game. Godot 4.7 · Forward+ · Jolt · GDScript · first-person · 3–6 players.
Inspired by Muck; endless escalating runs, no win condition. Shipping on Steam.

> Keep this file short. It loads on every request — bloat here is a tax on every future call.

## Docs — read the relevant one before working

| File | When |
|---|---|
| `docs/NEXT.md` | **Always, first.** Current status and next task. |
| `docs/ARCHITECTURE.md` | Before writing any gameplay or network code |
| `docs/DESIGN.md` | Before changing what the game *does* |
| `docs/ROADMAP.md` | Planning what to build next |
| `docs/AI-WORKFLOW.md` | How work is split across agents and the human |
| `docs/DECISIONS.md` | Before revisiting a settled decision |
| `docs/STEAM.md` | Release process |

## Hard rules

1. **Every system is network-aware from the first line.** Declare its row in the authority table
   (`ARCHITECTURE.md` §2.2). Never build singleplayer-first.
2. **Agents edit `.gd` scripts only.** The human wires scenes in the editor — `.tscn`/`.tres` do not
   merge safely. (`AI-WORKFLOW.md` §3)
3. **Content is data, not code.** New items/powerups/modifiers are `.tres` files, never new code.
4. **Never `randi()` in world generation.** Seeded `RandomNumberGenerator` per subsystem, or clients desync.
5. **Typed GDScript everywhere** (`var hp: int = 100`).
6. **Don't upgrade Godot mid-milestone.** The version is pinned.

## Quota discipline

The binding constraint on this project is AI usage quota, not time. So:

- Don't explore the codebase — the user will point at the file. Ask if unsure.
- Prefer targeted edits over rewrites.
- Don't generate bulk content data; the user authors that by hand for free.
- Keep files small and single-purpose.

## Conventions

`snake_case` files/functions · `PascalCase` classes/nodes · `SCREAMING_CASE` constants ·
networked functions prefixed `net_` · cross-system comms via `event_bus`, direct refs within a system.
