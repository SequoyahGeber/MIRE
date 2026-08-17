# MIRE

Co-op roguelike survival game. Godot 4.7 · Forward+ · Jolt · GDScript · first-person · 3–6 players.
Endless escalating runs, no win condition. Shipping on Steam.

## Read AGENTS.md

**[AGENTS.md](AGENTS.md) is the shared protocol** for every agent on this repo — Claude Code, Codex, and
the human. It is the source of truth for how work is claimed, tracked, and handed off. Read it before
doing anything. This file only adds what's specific to Claude Code.

Non-negotiables, repeated here because they're the ones that cost the most when broken:

1. **`.agent/bin/agent start`** at the beginning of every session, and **claim before you edit**.
   It names this chat itself — no `MIRE_AGENT`, no prefix, commits included (F-007).
2. **Godot-authored files (`.tscn` / `.tres` / `.import`) only under an exact per-file claim, with
   the editor closed (D-031).** They don't merge, so never share one. **`project.godot` (D-021)**:
   claim it by name, append only — a task that ships an autoload registers it in that same task.
   A script nothing loads isn't shipped.
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
- **Verify it yourself, headless** — `agent godot --script tools/x_check.gd`, or `--quit-after 120`,
  or two processes with `-- host` / `-- client` (D-023, task 1.5). Always through `agent godot`, never
  bare: it locks the shared import cache that every check races on (F-044). Do not open the editor,
  and do not ask Sequoyah to run it and report back; that is only for things that genuinely need a
  window or a human's eyes.

## Directing the other accounts

Two ChatGPT Plus lanes and a Claude Pro lane run headlessly from here — `agent order` → `agent
dispatch` → `agent report`. **[docs/ORCHESTRATION.md](docs/ORCHESTRATION.md)** is the protocol; read
it before dispatching. As director you route and verify, you don't implement (D-036).

## Keep this file short

It loads on every request. Bloat here is a tax on every future call, forever. Prune it when it grows.
