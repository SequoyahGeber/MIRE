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
3. **Never explore speculatively.** Quota, not time, is the constraint. Ask which file.
4. **Every system declares its network authority** (`docs/ARCHITECTURE.md` §2.2). No "multiplayer later."

## Claude Code specifics

- Prefer `Read` on a named file over `Grep`/`Glob` sweeps — searching burns quota for little gain here.
- Batch related edits in one session while context is warm; `/clear` between unrelated tasks.
- Before you stop: `agent done` or `agent handoff`, then commit. Uncommitted work is invisible to Codex.
- Don't run the Godot editor or try to launch the game — ask Sequoyah to run and report.

## Keep this file short

It loads on every request. Bloat here is a tax on every future call, forever. Prune it when it grows.
