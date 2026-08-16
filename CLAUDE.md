# MIRE

Co-op roguelike survival game. Godot 4.7 · Forward+ · Jolt · GDScript · first-person · 3–6 players.
Endless escalating runs, no win condition. Shipping on Steam.

## Read AGENTS.md

**[AGENTS.md](AGENTS.md) is the shared protocol** for every agent on this repo — Claude Code, Codex, and
the human. It is the source of truth for how work is claimed, tracked, and handed off. Read it before
doing anything. This file only adds what's specific to Claude Code.

Non-negotiables, repeated here because they're the ones that cost the most when broken:

1. **`.agent/bin/agent start claude`** at the beginning of every session, and **claim before you edit**.
2. **Never edit `.tscn` / `.tres`.** Scene files don't merge. Sequoyah wires scenes in the editor.
   **`project.godot` is different (D-021)** — claim it by name and register your own autoload, after
   checking the Godot editor is closed. A script nothing loads isn't shipped.
3. **Never explore speculatively** — but never stop to ask, either. Quota, not time, is the
   constraint. Run `agent brief <id>`, read the four docs it names, then the files your task touches.
   Ambiguous spec? Decide it, record why, keep going.
4. **Finish by putting what you learned in the repo,** not in your closing message: findings →
   `docs/FINDINGS.md`, settled calls → `docs/DECISIONS.md`, APIs the next task builds on →
   `docs/DELEGATION.md` *Current state*. Sequoyah starts tasks; he does not relay between them.
5. **Every system declares its network authority** (`docs/ARCHITECTURE.md` §2.2). No "multiplayer later."

## Claude Code specifics

- Prefer `Read` on a named file over `Grep`/`Glob` sweeps — searching burns quota for little gain here.
- Batch related edits in one session while context is warm; `/clear` between unrelated tasks.
- Before you stop: `agent done` or `agent handoff`, then commit. Uncommitted work is invisible to Codex.
- **Verify it yourself, headless** — `Godot --headless --path . --quit-after 120`, or two processes
  with `-- host` / `-- client` (D-023, task 1.5). Do not open the editor, and do not ask Sequoyah to
  run it and report back; that is only for things that genuinely need a window or a human's eyes.

## Keep this file short

It loads on every request. Bloat here is a tax on every future call, forever. Prune it when it grows.
