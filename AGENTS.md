# AGENTS.md

Instructions for AI coding agents working on **MIRE** — a co-op roguelike survival game.
Godot 4.7 · Forward+ · Jolt · GDScript · first-person · 3–6 players · host-authoritative multiplayer.

Multiple agents work on this repo. This file is the shared protocol. Follow it exactly — it's what lets
one of us pick up where another left off.

## Who does what (D-014)

| Role | Who | Owns |
|---|---|---|
| **Planner** | Claude Code (chat session) | Design, architecture, roadmap, task breakdown, decisions, specs, reviewing landed work. **Does not implement gameplay code.** |
| **Coder** | Codex · second Claude | Implementing claimed tasks in `.gd`. Works from the planner's spec. |
| **Integrator** | Sequoyah (human) | All Godot editor work, asset import, tuning, playtesting, commits. |

If you are a coder and the spec is ambiguous, **ask rather than explore** — exploration is the most
expensive thing an agent can do here, and the planner can answer in one line.

---

## Start every session with this

```bash
.agent/bin/agent start <your-name>     # claude | codex | sequoyah
```

It prints the board, your claims, stale work, and recent commits. **Do not skip it** — it's the
cheapest way to load context, and nothing else you do is safe until you know what's in flight.

Then read `docs/NEXT.md` for the current focus.

---

## The protocol

### 1. Claim before you edit

```bash
.agent/bin/agent claim 2.4 systems/inventory/inventory.gd core/net/rpc_util.gd
```

Fails loudly if another agent holds that task or any of those files. **If it fails, pick a different
task** — do not work around it. Two agents in one file is the failure mode this whole system exists to
prevent.

### 2. Leave a trail while you work

```bash
.agent/bin/agent note 2.4 "Host validates the craft; client only sends the recipe id"
```

Cheap, and it's what makes a handoff readable later.

**Spotted a problem outside your task?** Don't fix it, don't stay silent — append it to
`docs/FINDINGS.md` and carry on. Chasing it blows your scope and your quota; dropping it loses a real
observation forever. Thirty seconds, then back to work.

### 3. Close out — always, even if you didn't finish

```bash
# finished it
.agent/bin/agent done 2.4 "Inventory add/remove with host validation. Stacking capped at 99."

# ran out of quota or hit a wall
.agent/bin/agent handoff 2.4 "Add/remove works and is host-validated. Stack merging is half done —
merge_stacks() handles the simple case but not partial overflow across three stacks. The RPC signature
is settled, don't change it. Next: finish the overflow case, then wire the UI signal."
```

Both release your claims and write to `.agent/JOURNAL.md`. **A `handoff` note is the single most
valuable thing you produce when you stop mid-task.** Write it for someone with no memory of your
session — because that is literally who reads it. Say what works, what doesn't, what you'd already
decided, and what you'd do next.

### 4. Commit before you stop

Uncommitted work is invisible to the next agent. The pre-commit hook runs `agent check` and will block
you if you've touched a file you don't hold.

---

## Hard rules

### Never edit Godot scene or resource files

`.tscn` · `.tres` · `.import` · `project.godot` · `export_presets.cfg`

These carry internal sub-resource and node-path IDs. They do not merge, and a bad edit silently
corrupts a scene. **Only Sequoyah touches these, in the Godot editor.** The pre-commit hook enforces it.

You write `.gd` scripts. He wires them into scenes. If your work needs a scene change, say so
explicitly in your `done`/`handoff` note:

> *Needs wiring: attach `inventory.gd` to the Player node, add a `MultiplayerSynchronizer` child, and
> expose `held_items` on it.*

### Never explore the codebase speculatively

Sequoyah is limited by AI usage quota across three plans, not by time. "Let me search the codebase to
understand…" is the most expensive thing you can do. **Ask him which file.** He knows.

### Never bulk-generate content data

Items, powerups, recipes, enemy stats and Cycle Modifiers are `.tres` resources authored by hand in the
Godot inspector — free. Build the *framework*; he builds the *content*. If you find yourself about to
write the 40th powerup definition, stop.

### Never build a system without deciding its network authority

Every system declares which row of the authority table it's in — see `docs/ARCHITECTURE.md` §2.2.
Host-authoritative by default; client-authoritative only for a player's own movement. There is no
"add multiplayer later" in this project.

---

## Code conventions

- **Typed GDScript everywhere** — `var hp: int = 100`. Faster and catches errors at parse time.
- `snake_case` files and functions · `PascalCase` classes and nodes · `SCREAMING_CASE` constants
- Networked functions prefixed `net_`
- Cross-system communication through `event_bus`; direct references only within a system
- **Never `randi()` in world generation** — seeded `RandomNumberGenerator` per subsystem, or clients desync
- Keep files small and single-purpose. A 2,000-line file costs ten times a 200-line one to read.
- Godot version is **pinned**. Do not upgrade it.

---

## Where things are

| Path | What |
|---|---|
| `.agent/BOARD.md` | Live status — what's in flight, what's ready. Generated; don't hand-edit. |
| `.agent/JOURNAL.md` | Append-only history of every completed task and handoff. |
| `docs/NEXT.md` | Current focus and the immediate next task. |
| `docs/ARCHITECTURE.md` | Netcode, authority table, world gen, known risks. **Read before writing gameplay code.** |
| `docs/DESIGN.md` | What the game is and why. |
| `docs/ROADMAP.md` | All 97 tasks with IDs. Task IDs in commands come from here. |
| `docs/DECISIONS.md` | Settled decisions, each with what would change our mind. **Check before relitigating.** |
| `docs/FINDINGS.md` | Problems noticed but not yet scheduled. **File what you spot outside your task here.** |
| `docs/AI-WORKFLOW.md` | How work is split across agents and the human. |

---

## Commands

```bash
.agent/bin/agent start <name>          begin a session, print full context
.agent/bin/agent board                 what's happening right now
.agent/bin/agent claim <id> [files]    claim a task and its files
.agent/bin/agent note <id> "..."       record something mid-task
.agent/bin/agent done <id> "..."       finish: release claims, write journal
.agent/bin/agent handoff <id> "..."    stop mid-task: what's left, what to watch for
.agent/bin/agent drop <id>             abandon, release claims
.agent/bin/agent check                 verify changes respect claims
.agent/bin/agent sync                  re-read tasks from docs/ROADMAP.md
```

Run `.agent/bin/install-hooks` once per clone to install the pre-commit hook.

---

## If you can't run shell commands

Some agents (a chat-only Claude or ChatGPT session) can't execute anything. Then:

1. Ask Sequoyah to paste `.agent/BOARD.md` and the relevant source file.
2. Do the work in chat; hand back complete file contents, not fragments.
3. End with a handoff note in the exact shape `agent handoff` would have written, so he can paste it in.
