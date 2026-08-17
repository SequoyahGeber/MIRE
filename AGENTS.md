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

**Sequoyah starts tasks. He does not carry information between them.** If you find yourself writing
"tell the next agent X" or "paste this into the 1.7 prompt", stop: that X belongs in the repo, and
putting it there is part of your task, not an optional extra. See *Close out* below for where each
kind of X goes.

If the spec for a task is ambiguous, **decide it, write down why, and keep going.** Pick whatever is
most consistent with `ARCHITECTURE.md` and `DECISIONS.md`, record the call with `agent note` (or as a
new `D-0NN` if others must not relitigate it), and finish. He reviews at commit level. Stopping
mid-task to ask costs him more than a wrong-but-documented call, which is cheap to reverse. Ask only
when proceeding either way would be unsafe or would waste the whole task — and then ask at the end,
having finished everything that did not depend on the answer.

---

## Start every session with this

```bash
.agent/bin/agent start
```

It prints the board, your claims, stale work, and recent commits. **Do not skip it** — it's the
cheapest way to load context, and nothing else you do is safe until you know what's in flight.

**No name, and no `MIRE_AGENT` prefix on anything (F-007).** Your identity is derived from your
chat's own session id, which every command you run carries in its environment — including `git`, so
the pre-commit hook resolves you the same way your `agent` commands do. It is stable for the whole
session and unique per chat, so two agents working in parallel cannot file claims under each other's
name. `agent start` tells you the name you were given; use it when you talk about yourself.

You can still pass a name (`agent start sequoyah`) if you want a specific one on the board, and
`MIRE_AGENT=<name>` still overrides everything. Neither is needed any more.

Then read `docs/NEXT.md` for the current focus.

---

## Given only a task id? That is a complete instruction

"Start 1.6" is all you should need. Run this before anything else:

```bash
.agent/bin/agent brief 1.6
```

It prints the task, the open findings (traps someone already paid for), what recent tasks in the same
milestone left you, who holds which files right now, and any prior handoff on that task. Then read the
four files it names — `AGENTS.md`, `ARCHITECTURE.md` §2.2, `DELEGATION.md`'s *Current state*, and
`DECISIONS.md`. That list is bounded on purpose: it is the cheap alternative to exploring, and it is
where the previous agent was required to leave what you need.

Derive your own claim set from the task and claim it. If `DELEGATION.md` happens to hold a written
prompt for the task, use it — but its absence does not block you, and nobody needs to write you one.

**A finding is a task id too (F-015).** "Fix F-013" works exactly like "start 1.6" — `agent brief
F-013` prints the finding in full as its spec, and `claim` / `note` / `done` / `ship` all take the
F-number. Open findings are synced from `docs/FINDINGS.md` and shown on the board as their own
section; they are deliberately kept out of the milestone progress count, so filing one never moves
the roadmap number. Closing one means the fix **and** moving its section to `## Resolved` with what
you did and how you verified it — `agent done` warns you if you forget.

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

### 3. Put what you learned where the next agent will look

Not in your final chat message — that is a dead end, and it makes Sequoyah the courier. Four places,
and the right one is usually obvious:

| What you have | Where it goes |
|---|---|
| A problem outside your task — dead code, a stale doc, a bug you must not chase now | `docs/FINDINGS.md`, next `F-0NN`. Thirty seconds, then back to work |
| A call others must not relitigate, with what would change your mind | `docs/DECISIONS.md`, next `D-0NN` |
| An API, node layout, constant or verified command the NEXT task builds on | `docs/DELEGATION.md`, *Current state*. Stale state here is what forces hand-written prompts |
| How the task went, what bit you, what you'd do next | the journal, via `agent note` and `agent done` |

`docs/` needs no claim (F-006 — it is exempt from the hook), so none of this can block on another
agent. Doing it is the difference between a task that ends and a task that hands off.

### 4. Close out — always, even if you didn't finish

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

### 5. Ship it — commit, push, and sign off

```bash
.agent/bin/agent ship 2.4 "Inventory: host-validated add/remove"
```

`ship` stages **only the files your task claimed**, plus the coordination state, then commits and
pushes to `origin`. It deliberately does not `git add -A`: several agents share one working directory,
so a blanket add sweeps another agent's half-written files into your commit. Never hand-roll
`git add -A && git commit` — use `ship`.

Uncommitted work is invisible to everyone else. The pre-commit hook re-runs `agent check` against the
staged set and blocks you if you've touched a file you don't hold.

### 6. Tell Sequoyah only what is genuinely his

By now everything another *agent* needs is in the repo (step 3). What is left is the short list only a
human can act on — he is deciding whether to start the next task based on this, so be precise:

- **What you verified, and how.** The command you ran, the numbers it produced. Not "it works."
- **Whether it actually runs, or only compiles.** Register autoloads and make required scene/resource
  edits in the same task when Godot is closed (D-021, D-031), so these stop being different things.
- **Whether it is safe to move on.** Say it plainly, either way.

> "Done and pushed" and "working" are different claims. A pushed script that still needs an autoload
> registered is the first, not the second. Conflating them costs him an hour of confused debugging —
> he will trust what you write here.

---

## Hard rules

### Any agent working a list must be killable at any moment without losing what it did

A subagent that gathers results in its context and reports them once, at the end, is a **total loss
if it is stopped** — and long fan-outs get stopped, by a quota ceiling, a timeout, a crash, or a
human who changed their mind. This is not hypothetical: task 2.1j launched nine inspectors over 224
render sheets, stopped them at the 5-hour quota ceiling, and recovered **408 characters** from 302
completed image reads. One of them had just written "I've reviewed all 24 sheets" and had not yet
emitted a single finding. Every token was spent; nothing was kept.

So, for any agent or script that processes a list of items:

1. **Append each result the moment that item is done** — one JSON object per line, to a file whose
   path is given up front. Never hold results in memory until the end. Flush after each write; a
   buffered line is a lost line when the process is killed.
2. **Read that file on start and skip what is already in it.** Being stopped then costs the one item
   in flight, and resuming costs nothing. Tolerate a torn final line — a hard kill mid-write leaves
   one, and it must not poison the resume.
3. **The orchestrator reads the ledger, not the return value.** A return value only exists if the
   agent finished. The ledger exists either way, so partial work is still usable work.
4. **Say where the ledger is in the prompt**, and tell the agent to write a line per item. An agent
   given no path will hold everything in context, because that is the natural thing to do.

`tools/blender/audit_all_sides.py` is the worked example: `--outdir X` writes `X/geometry_report.jsonl`
one asset at a time and rebuilds the tidy `.json` view from it each run; re-running prints
`resuming: N assets already done` and re-renders nothing. Copy that shape.

Prompt block to paste into any list-processing agent:

```text
Append your result for EACH item to <LEDGER>.jsonl as one JSON object per line, the moment
you finish that item — never batch them to the end, because you may be stopped at any time
and anything still in your context is lost. Before you start, read <LEDGER>.jsonl and skip
every item already recorded there. Your final message should summarise, not carry, the results.
```

### Godot-authored files require a closed editor and an exact claim

Agents may edit `.tscn`, `.tres`, `.import`, and `export_presets.cfg` when both conditions hold:

1. **Check the editor is closed first.** The agent tool does this correctly — `agent order` refuses
   dispatch and the pre-commit hook refuses the commit while the editor runs, matching the real
   editor process rather than any command line containing "Godot" (F-045 — a raw `pgrep -fl Godot`
   also matches your own check loop and the `agent` command itself). Checking by hand:
   `pgrep -fl 'Godot.app.*--editor'`. If the editor is running, stop and say so.
2. **Claim every file by its exact path before editing it.** Directory or implied ownership is not
   enough for these files.

These files carry internal IDs and node-path references, and Godot may rewrite them on save. Never
edit one concurrently with Godot or another agent. Prefer generating complex scenes/resources via a
Godot tool script so the engine serializes its own format. The pre-commit hook enforces both the exact
claim and closed-editor conditions (D-031).

### `project.godot` IS yours — claim it by name

Not on the list above (D-021). It's a flat INI file that merges and reviews fine, so the corruption
argument never applied to it. **A task that produces an autoload registers it, in that same task**,
under a claim naming `project.godot`. Shipping a script nothing loads is not shipping.

Two additional rules apply:

1. **Check the editor is closed first** — same check as above (F-045). It rewrites the file on save
   and will silently discard your edit. If it's running, stop and say so.
2. **Append only.** Don't reorder or reformat, and never hand-write a setting equal to the engine
   default — Godot prunes those on its next save, so it isn't a fix, it's a fix with a timer (D-019).

If your work needs a genuine scene/resource change, make it in the same task under an exact claim.
Only leave editor wiring to Sequoyah when it requires visual judgment or interactive tuning that the
task cannot verify safely.

### Never explore the codebase speculatively

Sequoyah is limited by AI usage quota across three plans, not by time. "Let me search the codebase to
understand…" is the most expensive thing you can do — and it is not the same as being self-sufficient.

The cheap path, in order: `agent brief <id>`, the four docs it names, then the files your task
actually touches. If you still need something, name your single best guess and `Read` that one file
rather than grepping the repo. If the guess was wrong, say so in a finding — a doc that failed to
point you at the right file is itself a finding, and fixing it is how the next agent avoids the same
search.

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
| `docs/ROADMAP.md` | Every task with its ID. Task IDs in commands come from here. |
| `docs/SPECS.md` | **Per-task execution specs.** Read your task's block before touching code — it names the files to claim, the seams to build on, and what "done" means. |
| `docs/ORCHESTRATION.md` | The director/lane system (D-036/D-037): how work orders are routed to the three subscription lanes. |
| `docs/DECISIONS.md` | Settled decisions, each with what would change our mind. **Check before relitigating.** |
| `docs/FINDINGS.md` | Problems noticed but not yet scheduled. **File what you spot outside your task here.** |
| `docs/AI-WORKFLOW.md` | How work is split across agents and the human. |

---

## Commands

Run these as written — no prefix, no name (F-007).

```bash
.agent/bin/agent start                 begin a session, print full context
.agent/bin/agent brief <id>            everything you need to start that task
.agent/bin/agent board                 what's happening right now
.agent/bin/agent claim <id> [files]    claim a task and its files
.agent/bin/agent note <id> "..."       record something mid-task
.agent/bin/agent done <id> "..."       finish: release claims, write journal
.agent/bin/agent ship <id> ["msg"]     commit THIS TASK's files + push, print the sign-off
.agent/bin/agent handoff <id> "..."    stop mid-task: what's left, what to watch for
.agent/bin/agent drop <id>             abandon, release claims
.agent/bin/agent check                 verify changes respect claims
.agent/bin/agent sync                  re-read tasks from docs/ROADMAP.md
.agent/bin/agent godot <args>          run headless Godot under the shared lock — ALWAYS use this
                                       for checks; bare `Godot --headless` races other lanes on the
                                       one import cache (F-044, D-037)
```

Director-side commands (`order`/`dispatch`/`lanes`/`collect`/`report`/`reap`) are documented in
`docs/ORCHESTRATION.md` — worker agents and lanes never need them.

Run `.agent/bin/install-hooks` once per clone to install the pre-commit hook.

---

## If you can't run shell commands

Some agents (a chat-only Claude or ChatGPT session) can't execute anything. Then:

1. Ask Sequoyah to paste `.agent/BOARD.md` and the relevant source file.
2. Do the work in chat; hand back complete file contents, not fragments.
3. End with a handoff note in the exact shape `agent handoff` would have written, so he can paste it in.
