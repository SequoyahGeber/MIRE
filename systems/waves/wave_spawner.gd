extends Node

## One-shot night population director. It disables EnemyWorld's ambient replacement loop while a
## night is active, then clears the wave and restores the daytime field at dawn.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, "Day/night, wave director, Cycle state, active
## modifiers"): **HOST**. Only the host creates or clears the population; EnemyWorld's existing
## MultiplayerSpawner replicates those host-owned bodies, so this service adds no RPC.
##
## Task 5.9 (docs/SPECS.md §5.9): Cycle-aware pacing (`cycle_count_multiplier()`) and composition
## weighting (`_roll_roster()`) on top of the player-count scaling and roster-unlock mechanics 2.12/
## 3.14/4.11/6.1 already shipped. `_current_cycle` is cached from `EventBus.subscribe_cycle_advanced`
## — the same read-only subscription `CycleModifierService` already uses — never queried live, so a
## wave already on the ground is never resized mid-flight.

const EVENT_BUS := preload("res://core/events/event_bus.gd")
## F-226: `current_cycle()`'s client fallback reads `WorldDeltaLog` at the exact address
## `CycleService._announce()` writes to — preloading the script (not hand-copying its
## `GLOBAL_CHUNK`/`KIND`/`KEY` consts here) keeps the two getters unable to drift apart.
const CYCLE_SERVICE_SCRIPT := preload("res://systems/cycle/cycle_service.gd")

const DEFAULT_SEED: int = 0x57415645  # "WAVE"
## Task 4.11's "corrupted spawn tables": a spawn landing on corrupted ground has a chance to produce
## this Mire-tainted variant instead of the requested kind. Substitution only ever applies to the
## default `enemy_id` slot (bog_crawler is a crawler variant, not a stand-in for anything else a
## future caller might request).
const CORRUPTED_ENEMY_ID: StringName = &"bog_crawler"
## Ceiling probability at full (1.0) corruption — never certainty, so a heavily corrupted wave reads
## as "worse," not "a different game."
const CORRUPTED_SPAWN_CAP_PROBABILITY: float = 0.75

## Gamerules `wave_base_count` and `wave_per_player` (task 3.14). Both exports stay as the
## COMMANDS.md §4.3 fallback and are adopted from RuleService by `_bind_rules()` when authored.
## Nothing re-sizes a wave already on the ground: these are read once, at dusk, in `_on_night_started`
## — so a change mid-night lands on the NEXT night, which is the only reading that does not leave
## players fighting a population that grew around them.
@export_range(0, 128, 1) var base_count: int = 4
@export_range(0, 32, 1) var per_player: int = 2
@export_range(0.0, 20.0, 0.25) var scatter_m: float = 4.0
@export var enemy_id: StringName = &"crawler"
## Task 6.1's "enemy roster expands" (DESIGN.md §5.1): archetypes that join the night pool alongside
## `enemy_id`, one per `host_unlock_next_enemy()` call, in order. `bog_crawler` already exists as a
## distinct-stats archetype (task 4.11 authored it for corrupted-spawn substitution); no new content
## was authored for this task — AGENTS.md forbids bulk-generating `.tres` content, and task 5.2 ("8-12
## enemy types") is the one that grows this list with real new archetypes. See D-100.
@export var roster_order: Array[StringName] = [&"bog_crawler"]

## Cycle-aware pacing (task 5.9, DESIGN.md §5.3's "comfortable -> contested -> desperate -> the end"
## curve). Additive, not compounding like `CycleService.SPREAD_ESCALATION_PER_CYCLE` — DESIGN.md
## §5.4 is explicit that replayability comes from STACKING MODIFIERS, not raw content/enemy volume,
## so a wave's SIZE deliberately saturates while its COMPOSITION (`_roll_roster()` below) keeps
## shifting for the life of the run. Placeholder-tuned like every other Cycle constant in this
## codebase — nothing tunes this until a real playtest measures the wall (Q3). The cap lands at
## Cycle 11 (1.0 + 10 * 0.15 = 2.5), inside DESIGN.md §5.3's own "wall around Cycle 8-12" window.
const CYCLE_COUNT_STEP_PER_CYCLE: float = 0.15
const CYCLE_COUNT_CAP_MULTIPLIER: float = 2.5

## Cycle Modifier `the_hunt` (F-245, content/cycle_modifiers/the_hunt.tres: "a roaming elite ...
## beelines for whichever player is carrying the most powerups"). Reuses `tusker` — this project's
## single toughest existing `EnemyDef` (45 HP vs. 7-9 for everything else) — as the elite rather than
## authoring new content for the role; AGENTS.md's "framework, not content" rule and D-152 (see
## docs/DECISIONS.md) forbid a new hand-authored enemy for a single Cycle Modifier's sake.
const HUNT_ELITE_ENEMY_ID: StringName = &"tusker"
## How often the elite's target is re-checked against the current leaderboard while it lives — often
## enough that a mid-Cycle chest opening actually redirects it, rare enough this is not a per-tick
## group scan across every connected peer.
const HUNT_RETARGET_INTERVAL_SEC: float = 2.0

var _rng := RandomNumberGenerator.new()
var _night_active: bool = false
var _ambient_was_enabled: bool = true
## Cached MireGrid ref (F-099). MireGrid registers after this autoload, so it is resolved lazily
## rather than in _ready() (F-011).
var _mire_grid_node: Node
## Archetypes unlocked so far from `roster_order`, in the order they were unlocked. `enemy_id` is
## always in the pool implicitly and is never duplicated in here.
var _unlocked_pool: Array[StringName] = []
## Cached from `EventBus.subscribe_cycle_advanced` (task 5.9). Starts at 1 — the same "no Cycle has
## advanced yet" default `CycleService._current_cycle` itself uses — so `cycle_count_multiplier()`
## is exactly 1.0 before the first advance and every pre-existing wave-size assertion is unchanged.
var _current_cycle: int = 1
## `the_hunt`'s live tracking elite, or null between draws/before one is drawn. Host-only; a client
## never reaches `_maybe_spawn_hunt_elite()` (`_owns_wave_director()` guards it) or `_physics_process`'s
## retarget branch below the same way.
var _hunt_elite: Node3D
var _hunt_retarget_elapsed: float = 0.0


func _ready() -> void:
	_rng.seed = DEFAULT_SEED
	# Before the DayNight lookup, which returns early when there is none (a harness, the main menu).
	# Binding rules is not conditional on a day cycle existing — the wave sizes are still the sizes.
	_bind_rules()
	EVENT_BUS.subscribe_cycle_advanced(_on_cycle_advanced)
	var day_night: Node = get_node_or_null(^"/root/DayNight")
	if day_night == null:
		return
	if day_night.has_signal(&"night_started"):
		day_night.connect(&"night_started", _on_night_started)
	if day_night.has_signal(&"day_started"):
		day_night.connect(&"day_started", _on_day_started)
	_register_commands()



## COMMANDS.md §4.3's export-fallback seam — this file asks, the service never reaches in. Both
## values are adopted into their exports so `_on_night_started`'s arithmetic stays one expression.
func _bind_rules() -> void:
	var rules: Node = get_node_or_null(^"/root/RuleService")
	if rules == null:
		return
	rules.connect(&"rule_changed", _on_rule_changed)
	if bool(rules.call("has_rule", &"wave_base_count")):
		base_count = int(rules.call("value_int", &"wave_base_count", base_count))
	if bool(rules.call("has_rule", &"wave_per_player")):
		per_player = int(rules.call("value_int", &"wave_per_player", per_player))


func _on_rule_changed(id: StringName, new_value: float) -> void:
	if id == &"wave_base_count":
		base_count = roundi(new_value)
	elif id == &"wave_per_player":
		per_player = roundi(new_value)


func _on_cycle_advanced(cycle: int) -> void:
	_current_cycle = cycle
	_maybe_spawn_hunt_elite()


## Host-only, self-guarded like every other spawn path here. A Cycle where the level has no ambient
## spawn point to start from spawns nothing, the same silent no-op `host_start_wave()` already accepts
## for the identical reason.
func _maybe_spawn_hunt_elite() -> void:
	if not _owns_wave_director():
		return
	var modifiers: Node = get_node_or_null(^"/root/CycleModifierService")
	if modifiers == null or not bool(modifiers.call(&"has_modifier", &"the_hunt")):
		return
	var world: Node = get_node_or_null(^"/root/EnemyWorld")
	if world == null:
		return
	var points: Array[Vector3] = world.call(&"ambient_spawn_points")
	if points.is_empty():
		return
	var origin: Vector3 = points[_rng.randi_range(0, points.size() - 1)]
	var elite: Node3D = world.call(&"host_spawn", HUNT_ELITE_ENEMY_ID, origin) as Node3D
	if elite == null:
		return
	_hunt_elite = elite
	_hunt_retarget_elapsed = HUNT_RETARGET_INTERVAL_SEC
	_retarget_hunt_elite()


## Host-only. Re-checks the leaderboard every `HUNT_RETARGET_INTERVAL_SEC` while an elite is alive —
## `_hunt_elite` going invalid (death, despawn, run restart) simply stops this without any cleanup
## needed, the same "stale ref, no unsubscribe" shape `_mire_grid_node` above already uses.
func _physics_process(delta: float) -> void:
	if _hunt_elite == null or not is_instance_valid(_hunt_elite):
		_hunt_elite = null
		return
	_hunt_retarget_elapsed += delta
	if _hunt_retarget_elapsed < HUNT_RETARGET_INTERVAL_SEC:
		return
	_hunt_retarget_elapsed = 0.0
	_retarget_hunt_elite()


func _retarget_hunt_elite() -> void:
	if _hunt_elite == null or not is_instance_valid(_hunt_elite):
		return
	var powerups: Node = get_node_or_null(^"/root/PowerupService")
	if powerups == null:
		return
	var best_peer: int = 0
	var best_total: int = -1
	for node: Node in get_tree().get_nodes_in_group(&"players"):
		var player := node as Node3D
		if player == null:
			continue
		var node_name: String = String(player.name)
		var peer_id: int = node_name.to_int() if node_name.is_valid_int() else NetConfig.HOST_PEER_ID
		var total: int = int(powerups.call(&"total_stacks", peer_id))
		if total > best_total:
			best_total = total
			best_peer = peer_id
	if best_peer > 0 and _hunt_elite.has_method(&"host_force_target"):
		_hunt_elite.call(&"host_force_target", best_peer)


## Readable on any peer — same naming convention as `CycleService.current_cycle()`. Task 5.9;
## per-peer split added by F-226. Host/solo returns the cached `_current_cycle` (kept live by
## `_on_cycle_advanced`'s local `EventBus` subscription, which only ever fires in-process for the
## peer that owns the wave director). A real connected client never receives that emission —
## `CycleService._announce()` gates it behind `_owns_cycle()`, host-only — so it instead reads
## `WorldDeltaLog`, the same replicated record `CycleService.current_cycle()` itself falls back to,
## at the identical chunk/kind/key, so both getters agree on every peer.
func current_cycle() -> int:
	if _owns_wave_director():
		return _current_cycle
	var world_delta_log: Node = get_node_or_null(^"/root/WorldDeltaLog")
	if world_delta_log == null:
		return _current_cycle
	return int(world_delta_log.call(
		&"latest",
		CYCLE_SERVICE_SCRIPT.GLOBAL_CHUNK, CYCLE_SERVICE_SCRIPT.KIND, CYCLE_SERVICE_SCRIPT.KEY,
		_current_cycle
	))


## Additive, capped Cycle-driven size multiplier — see the constants' own header note for why this
## does not compound the way `CycleService`'s spread multiplier does. `cycle < 0` (the default) reads
## the live `current_cycle()` — F-226's per-peer split, not just the local cache — so
## `host_start_wave()` can call it bare; an explicit non-negative `cycle` arg lets a check (or a
## future balance tool) probe any Cycle without waiting for a real advance. A GDScript default
## parameter value cannot itself be a method call, hence the sentinel rather than `= current_cycle()`.
func cycle_count_multiplier(cycle: int = -1) -> float:
	var target_cycle: int = cycle if cycle >= 0 else current_cycle()
	return minf(
		1.0 + maxf(float(target_cycle - 1), 0.0) * CYCLE_COUNT_STEP_PER_CYCLE,
		CYCLE_COUNT_CAP_MULTIPLIER
	)


## Starts exactly one population for the night. A repeated threshold signal cannot add a second
## population, and deaths do not feed any replacement loop because ambient spawning stays disabled.
##
## A thin adapter over `host_start_wave()` since task 3.16, so `wave start` and dusk drive the same
## code — two copies of this would be two things to keep in step, and the command is the one that
## would quietly rot.
func _on_night_started() -> void:
	host_start_wave()


## Spawns `count` enemies scattered around a single fixed `position`, independent of night/day
## state or the ambient population — task 4.8's Wellspring ritual defense wave is the first caller,
## giving its own position override rather than one of EnemyWorld's ambient_spawn_points(). Host-only
## (`_owns_wave_director()`, same guard every other mutation here uses); returns the number actually
## spawned. Does not touch `ambient_enabled` — an ambient population and a ritual wave are
## independent one-shot populations that may coexist.
func host_spawn_wave_at(
	position: Vector3, count: int, wave_enemy_id: StringName = enemy_id,
	wave_scatter_m: float = scatter_m
) -> int:
	if not _owns_wave_director() or count <= 0:
		return 0
	var world: Node = get_node_or_null(^"/root/EnemyWorld")
	if world == null:
		return 0
	for _index: int in count:
		_spawn_one(world, position, wave_scatter_m, wave_enemy_id)
	return count


## `spawn_enemy_id` left at its default (`&""`) rolls the unlocked roster (`_roll_roster()`) — the
## path `host_start_wave()`'s own night population takes. A caller with an explicit id (task 4.8's
## Wellspring defense wave, both checks) always gets exactly that id, never a roster substitution.
func _spawn_one(
	world: Node, origin: Vector3, spawn_scatter_m: float, spawn_enemy_id: StringName = &""
) -> void:
	var chosen_id: StringName = spawn_enemy_id if spawn_enemy_id != &"" else _roll_roster()
	var offset := Vector3(
		_rng.randf_range(-spawn_scatter_m, spawn_scatter_m),
		0.0,
		_rng.randf_range(-spawn_scatter_m, spawn_scatter_m)
	)
	var position: Vector3 = origin + offset
	world.call("host_spawn", _corrupted_enemy_id_for(position, chosen_id), position)


## Weighted across `enemy_id` plus every archetype `host_unlock_next_enemy()` has unlocked so far
## (task 5.9 — was flat/even odds before this task). `enemy_id` always keeps weight 1; the Nth
## unlocked archetype (1-indexed, in unlock order) gets weight `N + 1`, so the most-recently-unlocked
## archetype is always the single most common pick — composition keeps shifting for the life of the
## run instead of diluting toward a flat average as the roster grows. An empty `_unlocked_pool`
## (Cycle 1, before any advance) always returns `enemy_id` — 4.9's own shipped behaviour, unchanged.
func _roll_roster() -> StringName:
	if _unlocked_pool.is_empty():
		return enemy_id
	var total_weight: float = 1.0
	for index: int in _unlocked_pool.size():
		total_weight += float(index + 2)
	var roll: float = _rng.randf() * total_weight
	if roll < 1.0:
		return enemy_id
	var cursor: float = 1.0
	for index: int in _unlocked_pool.size():
		cursor += float(index + 2)
		if roll < cursor:
			return _unlocked_pool[index]
	return _unlocked_pool[_unlocked_pool.size() - 1]


## Host-only. Task 6.1's `CycleService` calls this once per Cycle advance. Returns the archetype
## just unlocked, or `&""` when `roster_order` is exhausted (or this peer does not own the wave
## director) — `CycleService` treats either the same way DayNight's crossing already does when a
## downstream system is missing: nothing to do, not an error.
func host_unlock_next_enemy() -> StringName:
	if not _owns_wave_director() or _unlocked_pool.size() >= roster_order.size():
		return &""
	var next_id: StringName = roster_order[_unlocked_pool.size()]
	_unlocked_pool.append(next_id)
	return next_id


func unlocked_enemy_pool() -> Array[StringName]:
	return _unlocked_pool.duplicate()


## Substitutes CORRUPTED_ENEMY_ID with probability scaling linearly with corruption at the actual
## spawn point, capped at CORRUPTED_SPAWN_CAP_PROBABILITY. Only ever touches the default `enemy_id`
## slot — a caller that explicitly asked for some other kind gets exactly that, never a surprise
## reskin.
func _corrupted_enemy_id_for(position: Vector3, base_id: StringName) -> StringName:
	if base_id != enemy_id:
		return base_id
	var mire_grid: Node = _mire_grid()
	if mire_grid == null:
		return base_id
	var corruption: float = float(mire_grid.call(&"corruption_at", position))
	if corruption <= 0.0:
		return base_id
	if _rng.randf() < corruption * CORRUPTED_SPAWN_CAP_PROBABILITY:
		return CORRUPTED_ENEMY_ID
	return base_id


func _mire_grid() -> Node:
	if _mire_grid_node == null or not is_instance_valid(_mire_grid_node):
		_mire_grid_node = get_node_or_null(^"/root/MireGrid")
	return _mire_grid_node


## Clears the one-shot night population, restores the exact ambient setting found at dusk, and
## refills only after queued enemy frees have left the tree so live_count() cannot suppress refill.
## An adapter over `host_stop_wave()` for the same reason `_on_night_started` is one.
func _on_day_started() -> void:
	host_stop_wave()


func _refill_daytime(world: Node) -> void:
	if not is_instance_valid(world) or not _owns_wave_director():
		return
	# Preserve an intentionally disabled daytime field. The common true case refills immediately;
	# false means another director owned the field before dusk and remains authoritative after dawn.
	if _ambient_was_enabled:
		world.call("top_up_ambient")


func _live_player_count() -> int:
	var player_net: Node = get_node_or_null(^"/root/PlayerNet")
	var live_bodies: int = 0
	if player_net != null and player_net.has_method(&"players_root"):
		var players: Node = player_net.call("players_root") as Node
		if players != null:
			live_bodies = players.get_child_count()

	var transport: Node = get_node_or_null(^"/root/NetTransport")
	var offline: bool = transport == null or (
		not bool(transport.call("is_active")) and not bool(transport.call("is_connecting"))
	)
	return maxi(live_bodies, 1) if offline else live_bodies


func _owns_wave_director() -> bool:
	var transport: Node = get_node_or_null(^"/root/NetTransport")
	if transport == null:
		return true
	if bool(transport.call("is_host")):
		return true
	return not bool(transport.call("is_active")) and not bool(transport.call("is_connecting"))


# ── Commands (docs/COMMANDS.md §7 — task 3.16) ───────────────────────────────────────────────────


func _register_commands() -> void:
	var command_service: Node = get_node_or_null(^"/root/CommandService")
	if command_service == null:
		return
	command_service.call("register_spec", &"wave", {
		"scope": &"host",
		"args": [
			{"name": "op", "type": &"enum", "values": ["start", "stop", "status"]},
			{"name": "count", "type": &"int", "optional": true, "default": 0, "min": 0, "max": 128},
		],
		"handler": _cmd_wave,
		"help": "wave start [count] | wave stop | wave status — drive a night wave without waiting for dusk",
	})


func _cmd_wave(_ctx: Dictionary, args: Dictionary) -> Dictionary:
	var operation: String = String(args.get("op", "status"))
	if operation == "status":
		return {"ok": true, "message": "wave %s — base %d + %d per player, Cycle %d (x%.2f)" % [
			"active" if _night_active else "idle", base_count, per_player,
			_current_cycle, cycle_count_multiplier()
		], "data": {
			"active": _night_active, "base": base_count, "per_player": per_player,
			"cycle": _current_cycle, "cycle_multiplier": cycle_count_multiplier(),
		}}

	if operation == "stop":
		if not host_stop_wave():
			return {"ok": true, "message": "no wave was running", "data": {"active": false}}
		return {"ok": true, "message": "wave cleared, daytime field restored", "data": {"active": false}}

	var requested: int = int(args.get("count", 0))
	var spawned: int = host_start_wave(requested)
	if spawned < 0:
		return {"ok": false, "message": "a wave is already running — `wave stop` first", "data": {}}
	if spawned == 0:
		return {"ok": false,
			"message": "nowhere to spawn — the level has no enemy_spawn markers", "data": {}}
	return {"ok": true, "message": "wave started: %d enemies" % spawned,
		"data": {"active": true, "spawned": spawned}}


## The start/stop seams COMMANDS.md §7 marks as "formalized" for this task. `_on_night_started` and
## `_on_day_started` are now thin signal adapters over them, so the command and the day cycle drive
## the SAME code — a wave started by hand behaves identically to one dusk started, including the
## ambient-field suppression and the dawn restore that goes with it.
##
## Returns how many spawned, 0 for "nowhere to put them", or -1 for "already running".
func host_start_wave(override_count: int = 0) -> int:
	if _night_active or not _owns_wave_director():
		return -1
	var world: Node = get_node_or_null(^"/root/EnemyWorld")
	if world == null:
		return -1
	_night_active = true
	_ambient_was_enabled = bool(world.get("ambient_enabled"))
	world.set("ambient_enabled", false)

	var points: Array = world.call("ambient_spawn_points")
	if points.is_empty():
		return 0
	var spawn_count: int = override_count if override_count > 0 \
		else roundi((base_count + per_player * _live_player_count()) * cycle_count_multiplier())
	for _index: int in spawn_count:
		var origin: Vector3 = points[_rng.randi_range(0, points.size() - 1)] as Vector3
		_spawn_one(world, origin, scatter_m)
	return spawn_count


func host_stop_wave() -> bool:
	if not _night_active or not _owns_wave_director():
		return false
	var world: Node = get_node_or_null(^"/root/EnemyWorld")
	if world == null:
		return false
	_night_active = false
	world.call("host_despawn_all")
	world.set("ambient_enabled", _ambient_was_enabled)
	_refill_daytime.call_deferred(world)
	return true
