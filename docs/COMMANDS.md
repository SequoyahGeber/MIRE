# COMMANDS — runtime data control for every system

**Status: approved plan, tasks 3.13–3.17 (see ROADMAP.md M3 and their SPECS.md blocks).**
This document is the execution spec those tasks build against, the way `POWERUPS.md` serves 3.4.
Written 2026-08-18 from Sequoyah's directive: *make the game data-driven the way Minecraft's
commands can control and affect almost every aspect of the game.*

D-006 already made **content** data (`.tres` families, `Registry`). What Minecraft has that MIRE
does not is that **runtime state** is equally addressable: any item grantable, any entity
targetable, any rule tunable, any scenario scriptable — from a console line, at runtime, with
authority respected. That is what this track adds. It is not a cheat console bolted on; it is the
universal seam the debug console, the playtest director, the headless check harness, and future
Cycle-Modifier scripting all share.

| Minecraft | MIRE today | Gap this track closes |
|---|---|---|
| Every thing has a data id | 7 `.tres` families in `Registry` (D-006) | ✅ content; runtime *entities* have no ids |
| `/give /summon /time /kill` reach every system | `DebugConsole` + ~14 ad-hoc commands | No shared grammar; host-gating hand-rolled per command; a client's mutating command is refused, not routed |
| Selectors `@a @p @e[...]` | node groups only | EntityDirectory + selector arguments |
| `/gamerule` | scattered `@export` knobs per autoload | RuleDef family + replicated RuleService |
| Functions / datapacks | none | command files + data-driven event hooks |
| Server console (headless control) | bespoke `.gd` harness per check | one command-file runner every check can use |

---

## 1. Architecture

### 1.1 One front door

`CommandService` (new autoload, `autoload/command_service.gd`) owns parsing, validation, routing,
permissions, and execution. Every source funnels into it:

- **Console UI** — `DebugConsole` keeps the `~` drop-down, history, and printing, and becomes a
  thin client: it forwards the line to `CommandService.execute(line, ctx)` and prints the result.
  Its existing `register()` API keeps working (see §2.4) so nothing breaks on day one.
- **Headless runner** — `tools/run_commands.gd` executes a command file and reports structured
  results (§6).
- **Functions** — `content/functions/*.mcmd` files run line-by-line through the same door (§5).
- **Hooks** — data-bound events fire functions (§5.2).

### 1.2 Network authority (the §2.2 row 3.13 adds to ARCHITECTURE.md)

> | Command execution | **Host** for mutating commands; client submits, host validates op status
> and executes; results return to the issuer. Parsing/UI/read-only commands are client-local. |
> One brain for every mutation, same as the systems the commands drive. |

Every command declares a **scope**:

- `LOCAL` — reads and presentation (`help`, `items`, `entities`, `overlay`, `log`). Runs on the
  machine that typed it, against that machine's replicated view.
- `HOST` — anything that mutates authoritative state (`give`, `spawn`, `rule`, `tp`, `kill`).
  Typed on the host: validate and execute directly. Typed on a client: the raw line is sent over
  a new reliable RPC (`net_submit_command`), the **host re-parses and re-validates from scratch**
  (the client's parse is a convenience check, never trusted — same disposition as BuildService's
  ghost), executes, and returns the result via `net_command_result`. Protocol version bumps;
  `tools/handshake_check.gd` extends, per the standing rule.

This generalizes what `dev_loadout.gd` hand-rolls today (`_owns_grants()` + "only the host can
grant items") and what `debug_console.gd`'s header already demands ("a command that mutates host
state must go through the same RPC path as gameplay"). It also *upgrades* the client experience:
today a client typing `give` is refused; after 3.13 it works if the host has opped them.

### 1.3 Permissions: the op set

- The **host is always op**. Offline play is host-of-one (`_owns_mutation()` shape) — always op.
- `op <player>` / `deop <player>` — HOST-scope, and additionally restricted to the host peer
  itself (op cannot grant op). Ops are per-session, keyed by run-player token (D-035), so a
  reconnect keeps op status through the grace window.
- A non-op submitting a HOST command gets a structured refusal, same words on every command —
  never a silent no-op.
- **Commands ship in release builds.** Cheating is irrelevant among friends (D-002's reasoning);
  Muck-likes have a cheats culture; and D-030 explicitly wants console commands for cross-play
  testing. What ships gated behind op is strictly more controlled than today's `~` console.

### 1.4 Execution context

`CommandCtx` carries: issuing peer id, source (`CONSOLE | RUNNER | FUNCTION | HOOK | RPC`), and
the issuer's position/facing when a body exists (host reads its replicated copy — needed for `~`
relative coordinates and `@p`-style selectors). Handlers never call `get_tree().multiplayer`
directly for identity; they read the context.

---

## 2. Command registration

### 2.1 CommandSpec

```gdscript
CommandService.register_spec(&"give", {
    scope = CommandService.Scope.HOST,
    args = [
        {name = "target",  type = &"selector", optional = true, default = "@s"},
        {name = "item",    type = &"item_id"},
        {name = "count",   type = &"int",      optional = true, default = 1, min = 1, max = 999},
    ],
    handler = _cmd_give,     # func(ctx: CommandCtx, args: Dictionary) -> CommandResult
    help = "give [target] <item_id> [count] — grant items",
})
```

Registration happens in the owning system's `_ready()`, exactly as today. `CommandService` must
therefore be registered **early** (right after `DebugConsole` in the autoload order) so every
later autoload can register into it.

### 2.2 Argument types

Central parsers, one error voice, and validation against `Registry` where a type names content:

| Type | Parse/validate | Notes |
|---|---|---|
| `int`, `float`, `bool`, `string` | the obvious | optional `min`/`max` clamp metadata |
| `item_id`, `recipe_id`, `enemy_id`, `powerup_id`, `buildable_id`, `station_id`, `loot_table_id`, `rule_id` | `Registry`/`RuleService` lookup | unknown id fails parse with "no such … — try `items`" |
| `peer` | peer id int or player display name | resolves against connected peers |
| `selector` | §3 grammar | resolves to an entity list at execution time, on the executing side |
| `vec3` | three floats, each optionally `~` / `~<offset>` | relative to `CommandCtx` position |
| `enum(a,b,c)` | one of a closed word set | for subcommands like `time set|add` |

A parse failure returns usage automatically — handlers never see malformed args and never write
their own "usage:" strings again.

### 2.3 CommandResult

Handlers return `{ok: bool, message: String, data: Dictionary}`. The console prints `message`;
the runner and checks assert on `ok`/`data` instead of string-matching output. Refusals (not op,
bad target, service missing) are results, not log lines, so they travel back over the RPC.

### 2.4 Migration, not a rewrite

`DebugConsole.register(command, callable, usage)` stays as a compatibility path that wraps the
callable in a LOCAL-scope spec with one `string...` rest-argument. 3.13 migrates every existing
registration to real specs — the builtins in `debug_console.gd`, `dev_loadout.gd`'s
give/loadout/items, and `enemy_world.gd`'s spawn/killall/enemies (grep `register(` for the full
set at claim time). After 3.13 the compat path logs a deprecation warning so new ad-hoc commands
don't accrete beside the typed system.

### 2.5 Introspection is part of the contract

`commands` lists every spec with scope and help; `commands --json` dumps the whole registry
(name, scope, arg types, help) as JSON through `CommandResult.data`. That dump is how the 3.16
coverage check asserts "every service seam has a verb", and how any future UI (or agent) learns
the surface without reading source.

---

## 3. Selectors and the EntityDirectory

### 3.1 EntityDirectory (new autoload)

**Authority: HOST-side registry; not replicated in v1.** Selectors resolve where the command
executes — HOST commands resolve on the host's complete directory; LOCAL reads resolve against
the local (possibly partial) view, which is fine for what LOCAL commands may do.

Every live gameplay entity registers at the spawn seams that already exist, and unregisters on
despawn:

| Kind | Registration seam |
|---|---|
| `player` | `PlayerNet.player_spawned` (F-018's signal, same one DevLoadout uses) |
| `enemy` | `EnemyWorld` spawn/despawn |
| `harvestable` | `HarvestWorld._wire_holder` (both maps' holder groups) |
| `buildable` | `BuildService` placement/destruction |
| `chest` | `Chest._ready()` / exit |

Entries: stable id (`<kind>:<serial>`, host-assigned, monotonic per boot), kind, NodePath,
tags (`Array[StringName]`, directory-side — node groups remain the engine-level mechanism systems
use for behavior; directory tags are for *addressing* only). `tag <selector> add|remove|list
<tag>` manages them. Players are additionally addressable by peer id and display name.

### 3.2 Selector grammar

```
@s                      the issuer
@p                      nearest player to the issuer
@a                      all players
@r                      one random player
@e[type=enemy,tag=wave,r=30,limit=5,sort=nearest]    filtered entities
```

Filters: `type=` (kind or enemy def id), `tag=`, `r=` (radius in metres from issuer or from
`x=,y=,z=`), `limit=`, `sort=nearest|random`. Bare `@e` is everything. A selector argument
resolves to a (possibly empty) list; commands report how many they affected — `killed 4
entities`, Minecraft-style. Randomness uses a dedicated `RandomNumberGenerator` (convention), and
never touches world-gen RNG.

### 3.3 Respecting the authority table

`tp <selector> <vec3|selector>` on an **enemy** moves the body directly (host owns enemies). On a
**player** it must not write the transform — own movement is CLIENT-authoritative (§2.2 row 1) —
so it reuses the `net_force_respawn` shape PlayerHealth already shipped: the host tells that
peer's own client to place itself. Same for any future command that would move a player. `kill`
on a player routes through `PlayerHealth.host_apply_damage` (lethal), on an enemy through the
enemy's damage path — commands **wrap existing host seams; they never grow a second mutation
path**. That sentence is the whole safety argument of this track: if a command needs a seam that
doesn't exist, the seam is added to the owning service first, command second.

---

## 4. Gamerules

### 4.1 RuleDef — a content family like any other

`systems/rules/rule_def.gd` → `content/rules/*.tres`, loaded by `Registry._load_rules()` (same
boot-log count line, same duplicate/validation discipline as the other seven families):

```
id: StringName            # &"day_length_seconds"
display_name: String
type: BOOL | INT | FLOAT  # enum
default_value: float      # stored as float; BOOL is 0/1, INT rounds
min_value / max_value     # clamp; equal means unclamped
description: String       # shown by `rules`
```

### 4.2 RuleService (new autoload) — HOST-authoritative values

§2.2 row: same as "day/night, wave director, Cycle state, active modifiers" — **Host**,
replicated. Holds `rule_id -> current value`, seeded from defaults at boot.

- Read seam: `RuleService.value(&"day_length_seconds")` (+ typed `value_bool/int` helpers) and a
  `rule_changed(id, value)` signal. Systems ask; the service never reaches in — the exact
  direction PowerupService set (3.3).
- Replication: host broadcasts a change; joiners get a full snapshot in the same
  peer-joined path other services use. Protocol bump + handshake_check extension.
- Commands: `rule <rule_id> [value]` (HOST scope to set; read answers locally),
  `rules` (list all with values and descriptions).
- Persistence: **none.** A run is one sitting (D-010); rules reset to defaults per boot. A
  `content/functions/autoexec.mcmd` (§5.3) is how a dev keeps preferred rules across boots.

### 4.3 First-wave migration (part of 3.14, defaults unchanged)

The pattern per knob: **the `@export` stays and becomes the fallback**; the system reads
`RuleService.value(id)` when a RuleDef with that id exists, else its export. Boot order or a
missing `.tres` can never brick a system, and inspector tuning keeps working until a knob
formally moves.

*As shipped (3.14):* an owner **adopts** the value into its own export — it calls `value()` once in
`_bind_rules()` and then follows the `rule_changed` signal — rather than calling the service at each
use. The seam direction is unchanged (the owner asks and decides; the service never reaches in), and
it buys two things a per-use read would not: `hunger_drain_per_sec` stays a plain field read in a
per-physics-tick loop on the low-end machines this project targets, and every *existing* reader of
the property keeps working untouched — including `entities/player/player_controller.gd`, which reads
`revive_seconds` off the `PlayerHealth` autoload by name, on the client.

| Rule id | Today | Owner file |
|---|---|---|
| `day_length_seconds` | `DayNight.day_length_seconds` (via Atmosphere export) | `systems/environment/day_night.gd` |
| `ambient_enemy_population` | `EnemyWorld.ambient_population` (4) | `autoload/enemy_world.gd` |
| `wave_base_count` / `wave_per_player` | `WaveSpawner` exports | `systems/waves/wave_spawner.gd` |
| `revive_seconds` / `bleed_out_seconds` | `PlayerHealth` exports | `systems/health/player_health.gd` |
| `hunger_drain_per_sec` | `PlayerHealth` export | same |
| `dev_loadout_enabled` | `DevLoadout.enabled` | `core/dev/dev_loadout.gd` |

Deliberately **excluded** from wave 1: anything in `NetConfig` (its own doc forbids per-peer
divergence and the replication timing of a mid-session change is a real design question) and
anything world-gen-seeded (rules are runtime; gen determinism is §7's territory). Later waves add
knobs opportunistically — one line in the owner + one `.tres`, which is the point.

---

## 5. Functions and hooks — the datapack seed

### 5.1 Command files

`content/functions/<name>.mcmd`: plain text, one command per line, `#` comments, blank lines
ignored. `function <name>` runs it through the front door with the caller's context. Effective
scope is the max of its lines' scopes (any HOST line makes the function HOST). Recursion depth
cap (4) so a function calling itself is an error, not a hang. `.mcmd` files are content like any
other — Sequoyah authors scenarios for free, no code.

### 5.2 Hooks — data-driven event → function binding

`systems/rules/hook_def.gd` → `content/hooks/*.tres`: `{event: StringName, function: StringName,
host_only: bool = true}`. `CommandService` subscribes once to the named `EventBus`/autoload
signals and runs the bound function when they fire, host-side. Event vocabulary starts with what
exists: `run_started`, `night_started`, `day_started`, `player_downed`, `enemy_died` — all five now
bind to a real signal (F-154 closed the last two: `CycleService.run_started` fires the instant a
run's Cycle 1 is live, `PlayerHealth.player_downed` is the real ALIVE→DOWNED edge, distinct
from the broadcast `downed_flag_changed` bool that also fires on revive). **Every one of the five is
a per-RUN event, not a per-process one** — `run_started` fires again for each restart in the same
lobby (F-280/D-168; it shipped one-shot under F-154, when a run's lifetime still was the process's,
and F-243's play-again flow made that silently wrong), so a hook wired once at boot keeps running for
the second and tenth run the way its name promises. There is deliberately no public
`run_restarted` word: the `EventBus` signal of that name means "throw the ENDED run's state away",
which is a service-internal reset broadcast with no first-run counterpart, not vocabulary for
scenario authors. A worked example ships:
`content/hooks/night_siege.tres` + `night_siege.mcmd` (dusk → announce + spawn a themed wave) —
then is **disabled by default** (`enabled: bool` on HookDef), because shipping gameplay-by-hook is a
design decision for M6's Cycle Modifiers, not this track. The mechanism is what ships; M6 gets to
build modifiers as data on top of it.

### 5.3 Autoexec

If `user://autoexec.mcmd` exists, it runs at boot (host/offline only, after autoloads settle) —
dev convenience for rules and loadout preferences, per D-010 the sanctioned way to "persist"
rules. Not shipped content; `content/functions/autoexec.mcmd` is read too if present, for the
project-level equivalent.

*Shipped (3.17):* `systems/rules/hook_def.gd`, `content/hooks/night_siege.tres` +
`content/functions/night_siege.mcmd` (disabled by default, D-094), function loading/execution and
hook wiring inside `autoload/command_service.gd`, `systems/commands/function_runner.gd` (pure
parsing/scope helper). `docs/DELEGATION.md`'s *Current state* has the full API.

---

## 6. The headless runner — how this pays the harness back

`tools/run_commands.gd`: `agent godot --script tools/run_commands.gd -- --file <path> [--json]`.
Boots offline (host-of-one), waits for autoloads + `Registry`, executes the file line-by-line,
prints each `CommandResult` (JSON lines with `--json`), exits non-zero if any `ok=false` (a
`# expect-fail` line-prefix inverts, so refusal paths are testable). F-016 applies: preload any
new class_name it touches.

Why this matters more here than in most projects: this repo's whole verification model is
headless self-checks (D-023, F-044, ~49 of them). Today every check hand-pokes services to build
its scenario. After 3.17, scenario setup is a command file — `give iron_sword`, `spawn crawler 3`,
`time set 0.8`, `rule wave_base_count 10` — and the check asserts on state. New checks get
shorter, and the command surface itself gets exercised by every check that uses it. The two-process
pattern (`tools/*_net_check.gd`) composes: the client submits over the real RPC and the check
asserts the host executed and the result returned.

*Shipped (3.17):* `tools/run_commands.gd`. `content/functions/dev_scenario.mcmd` is the worked
example — `tools/command_check.gd`'s own give/spawn setup, ported to a command file (its check is
NOT migrated to consume it — deliberately deferred, "do not port the suite").

---

## 7. Command catalog v1 (the 3.16 coverage checklist)

Verbs wrap **existing** host seams (§3.3 rule). Exact handler names bind at claim time; seams
listed are already shipped unless marked *(new seam)*.

| System | Commands | Seam |
|---|---|---|
| Inventory | `give`, `inv [list\|clear] [peer]` | `InventoryService.host_add/host_remove/host_slots` |
| Enemies | `spawn <enemy_id> [count] [vec3]`, `kill <selector>`, `killall`, `enemies` | `EnemyWorld.host_spawn/host_despawn_all` |
| Health | `damage <selector> <n>`, `heal <selector> [n]`, `down <peer>`, `revive <peer>`, `starve <peer>` | `PlayerHealth.host_apply_damage` + host state *(small new seams for heal/set)* |
| Time | `time set <0..1|dawn|noon|dusk|midnight>`, `time add <sec>`, `time query` | `DayNight.host_advance` (its doc already predicted this caller) |
| Waves | `wave start [count]`, `wave stop` | `WaveSpawner`/`EnemyWorld.top_up_ambient` *(start/stop seam formalized)* |
| Powerups | `powerup give <peer> <id> [stacks]`, `powerup clear <peer>`, `stat <peer> <name>` | `PowerupService` host grant seams + `stat()` |
| Crafting | `craft <recipe_id>`, `recipes [station]` | `CraftingService.request_craft` (goes through the normal request path, not around it) |
| Building | `build <buildable_id> <vec3>`, `demolish <selector>` | `BuildService` placement/destroy request seams |
| Harvest | `harvest respawn [selector]` | `HarvestWorld` respawn path *(seam exposed)* |
| Loot | `loot roll <table_id> [peer]` | LootTable roll + `host_add` |
| Rules | `rule`, `rules` | §4 |
| Entities | `entities [selector]`, `tag …`, `tp …` | §3 |
| Session | `lobby host`, `lobby join <id>`, `lobby invite` | `SteamLobby.host_session/join_by_id/open_invite_overlay` — **this is D-030's cheap cross-play test, delivered** |
| Meta | `help`, `commands [--json]`, `function <name>`, `op/deop`, `clear`(console), `quit` | — |

The 3.16 check asserts every table row exists in `commands --json` and that every HOST-scope
command refuses a non-op — coverage and permission tested mechanically, so a new service that
forgets its verbs fails a check instead of a code review.

*Shipped (3.16): `tools/command_catalog_check.gd`.* Three notes on what building it turned up.
The Inventory row above **used to read `clear [target]`**, which collided with the Meta row's
`clear`(console) — the check caught it on its first run, and D-093/F-153 record the resolution (the
console keeps the bare name; the inventory wipe is `inv clear`). The check also refuses to accept a
verb still registered through `DebugConsole.register()`'s deprecation shim as coverage, because the
shim produces an untyped LOCAL spec and a HOST mutation hiding behind one would pass a name-only
check unprotected — `fps_cap` and `vsync` were the last two, and 3.16 migrated them. And a
dynamic-scope verb (D-086) is probed for the non-op refusal **with** the arguments that make it
mutate: `time` and `rule` are LOCAL in their bare form, which is the feature, so probing them bare
asserted the opposite of what they promise.

---

## 8. Deliberately out of scope

- **No JSON datapacks / no re-platforming content.** D-006's `.tres` + inspector authoring stands;
  it is load-bearing for the quota model. External mod packs would revisit this — not before ship.
- **No namespaced ids** (`mire:stone_axe`). Bare `StringName`s until a second content source
  exists; retrofitting a default namespace later is mechanical.
- **No command blocks / no in-world command entities.** Hooks + functions cover the need.
- **No RCON / no network console port.** The RPC path is peers-only, inside the session.
- **No chat.** The console is not a chat surface; a future chat is its own task and may *feed*
  CommandService with `/`-prefixed lines, which costs one call site.
- **No tab-completion UI in v1** (the spec metadata makes it a cheap later add).

---

## 9. Decisions to file as D-numbers when their task ships

Numbers are allocated at ship time by the implementing task (concurrent lanes are filing D/F
numbers daily; a plan must not squat on numbers — F-058/F-087 are the scar tissue). The calls,
with reasoning, so the tasks file them verbatim rather than relitigating:

1. **(3.13)** One front door; commands are thin wrappers over host seams; scope LOCAL/HOST; op
   set; ships in release. *Would change my mind:* a mutation that genuinely cannot route through
   an existing seam without duplicating validation — that is a missing seam in the owning
   service, and the fix is there, never a special-cased command.
2. **(3.13)** Host re-parses the raw line rather than trusting a client-parsed structure — same
   trust stance as BuildService re-snapping the ghost's transform. *Would change:* parse cost
   ever mattering at 6 peers (it won't).
3. **(3.14)** Rules are a content family with host-replicated values and export-fallback reads;
   no persistence (D-010). *Would change:* meta-progression wanting persistent difficulty
   settings — that lands in `core/save/` beside Salvage, not here. **Filed as shipped**, plus two
   calls this item did not anticipate: **D-085** (a rule at its authored default defers to a
   level-authored value; only an overridden one wins — `day_length_seconds` is the single knob with
   a competing source) and **D-086** (a CommandSpec's `scope` may be a `Callable`, which is how one
   `rule` verb reads locally and sets on the host as §4.2 asks).
4. **(3.15)** EntityDirectory is host-side and unreplicated; selectors resolve on the executing
   side. *Would change:* a client-side UI needing to browse entities it can't see — replicate a
   filtered view then, not the registry. **Filed as shipped**, plus **D-088**: the directory
   discovers by node group rather than subscribing to the five spawn seams §3.1 tabulates — every
   one of those paths already ends in `add_to_group()`, so scanning the groups asks the tree what is
   actually alive instead of maintaining a second list that can drift from it.
5. **(3.17)** Hooks ship disabled-by-default; gameplay-by-data waits for M6 Cycle Modifiers to
   own it. *Would change:* 2.14/3.11 playtests wanting scripted variety sooner. **Filed as shipped**
   (D-094), plus **F-154** (since resolved — `docs/SPECS.md`'s own block): two of this section's
   illustrative events (`run_started`, `player_downed`) had no shipped signal to bind to; naming
   either in a HookDef still fails loudly at wire time instead of silently never firing for any event
   genuinely absent from the table, but both of these two now have a real row.

---

## 10. Task map

| Task | What | Gate |
|---|---|---|
| 3.13 | Command core: CommandService, specs/scopes/results, RPC + op set, migrate all existing commands, §2.2 row, protocol bump | none — see below |
| 3.14 | Gamerules: RuleDef family, RuleService, replication, `rule`/`rules`, first-wave knob migration | 3.13 |
| 3.15 | EntityDirectory + selectors + entity verbs (`tp/kill/tag/entities`) | 3.13 |
| 3.16 | Catalog sweep: every §7 verb + coverage check + D-030's lobby commands | 3.13 (3.15 for selector-taking verbs) |
| 3.17 | Functions, hooks, autoexec, `tools/run_commands.gd` | 3.13 |

**On M3's "start only after 2.14's re-read" gate:** that gate exists so gameplay-shape work
doesn't build on unvalidated design (`DESIGN.md` §8). This track encodes **zero design answers**
— no values change, no mechanics are added, defaults are untouched — and 3.13/3.17 materially
*help run* 2.14 itself (a director spawning waves and granting gear live during the playtest) and
D-030's cross-play test. Recorded call: **the command track is exempt from the 2.14 gate.**
Sequoyah can override by note; nothing else in M3 inherits the exemption.

Sizing: 3.13 (T2, 3) · 3.14 (T2, 2.5) · 3.15 (T2, 3) · 3.16 (T1, 2) · 3.17 (T1, 2) — 12.5
sessions, ROADMAP budget updated. Every task lands its own headless check(s) + a net check where
a wire shape changes, per the M3 preamble in SPECS.md.

One implementation wrinkle 3.13 must verify early: `DebugConsole.pause_while_open` pauses the
local tree, and a client's submitted command needs the RPC to flow while paused. `SceneTree`
polls multiplayer outside the pause gate in 4.7, so this should already work — but prove it in
`tools/command_net_check.gd` with the console genuinely open, and if it doesn't, the console
unpauses for the round trip. Do not discover this during 2.14.
