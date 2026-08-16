# AGENTS.md

Instructions for AI coding agents working on **MIRE** — a co-op roguelike survival game.
Godot 4.7 · Forward+ · Jolt · GDScript · first-person · 3–6 players · host-authoritative multiplayer.

Multiple agents work on this repo. This file is the shared protocol. Follow it exactly — it's what lets
one of us pick up where another left off.

## Who does what (D-014, role split superseded by D-020)

Any agent — Claude Code chat, Codex, a second Claude session — can take any task. There's no fixed
planner/coder identity; which agent picks up a task depends on which plan has usage quota available.
Sequoyah (human) is the only fixed role: **Integrator** — all Godot editor work, asset import, tuning,
playtesting, commits.

If the spec for a task is ambiguous, **ask rather than explore** — exploration is the most expensive
thing an agent can do here, and Sequoyah can answer in one line.

---

## Start every session with this

```bash
MIRE_AGENT=<your-name> .agent/bin/agent start <your-name>     # claude | codex | net | ...
```

It prints the board, your claims, stale work, and recent commits. **Do not skip it** — it's the
cheapest way to load context, and nothing else you do is safe until you know what's in flight.

**Put `MIRE_AGENT=<your-name>` on every `agent` command — and on `git commit` too — and never
`export` it once.** The pre-commit hook re-runs `agent check`, and git invokes that hook, so a commit
without the prefix resolves your identity from the session file and can block a commit whose claims
are perfectly valid. `agent ship` handles this for you; a hand-rolled `git commit` does not. Most agent
tools run each shell call in a separate process, so an exported value is gone by your next command.
The script then falls back to `.agent/session`, which holds a single name shared by every chat in
this repo — so with two chats running you file claims under the other agent's identity, with no
error. That is precisely the collision claiming exists to prevent, and it fails silently.

Then read `docs/NEXT.md` for the current focus.

---

## The protocol

### 1. Claim before you edit

```bash
MIRE_AGENT=<your-name> .agent/bin/agent claim 2.4 systems/inventory/inventory.gd core/net/rpc_util.gd
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

### 4. Ship it — commit, push, and sign off

```bash
.agent/bin/agent ship 2.4 "Inventory: host-validated add/remove"
```

`ship` stages **only the files your task claimed**, plus the coordination state, then commits and
pushes to `origin`. It deliberately does not `git add -A`: several agents share one working directory,
so a blanket add sweeps another agent's half-written files into your commit. Never hand-roll
`git add -A && git commit` — use `ship`.

Uncommitted work is invisible to everyone else. The pre-commit hook re-runs `agent check` against the
staged set and blocks you if you've touched a file you don't hold.

### 5. Tell Sequoyah where things actually stand

`ship` prints a template. Fill it in as your final chat message — he is deciding whether to start the
next task based on what you say here, so be precise:

- **What you verified, and how.** The command you ran, the numbers it produced. Not "it works."
- **Whether it actually runs, or only compiles.** Register your own autoload (D-021, see Hard
  rules) so these stop being different things. If something still needs a `.tscn`/`.tres` change —
  a node added, an exported value set — then **the feature does not work yet**, in those words.
- **Whether it is safe to move on.** Say it plainly, either way.

> "Done and pushed" and "working" are different claims. A pushed script that still needs an autoload
> registered is the first, not the second. Conflating them costs him an hour of confused debugging —
> he will trust what you write here.

---

## Hard rules

### Never edit Godot scene files

`.tscn` · `.tres` · `.import` · `export_presets.cfg`

These carry internal sub-resource and node-path IDs. They do not merge, and a bad edit silently
corrupts a scene. **Only Sequoyah touches these, in the Godot editor.** The pre-commit hook enforces it.

### `project.godot` IS yours — claim it by name

Not on the list above (D-021). It's a flat INI file that merges and reviews fine, so the corruption
argument never applied to it. **A task that produces an autoload registers it, in that same task**,
under a claim naming `project.godot`. Shipping a script nothing loads is not shipping.

Two conditions, both real:

1. **Check the editor is closed first** — `pgrep -fl Godot`. It rewrites the file on save and will
   silently discard your edit. If it's running, stop and say so.
2. **Append only.** Don't reorder or reformat, and never hand-write a setting equal to the engine
   default — Godot prunes those on its next save, so it isn't a fix, it's a fix with a timer (D-019).

If your work needs a genuine *scene* change, say so explicitly in your `done`/`handoff` note:

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

Prefix each of these with `MIRE_AGENT=<your-name>` — see the top of this file for why `export` is
not good enough.

```bash
.agent/bin/agent start <name>          begin a session, print full context
.agent/bin/agent board                 what's happening right now
.agent/bin/agent claim <id> [files]    claim a task and its files
.agent/bin/agent note <id> "..."       record something mid-task
.agent/bin/agent done <id> "..."       finish: release claims, write journal
.agent/bin/agent ship <id> ["msg"]     commit THIS TASK's files + push, print the sign-off
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
