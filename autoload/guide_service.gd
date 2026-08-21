extends Node

## GuideService — autoload. The game's entire tutorial, and deliberately not a tutorial: one
## objective line that always names the next thing, and one-shot tips fired by the situations that
## otherwise teach nothing (`docs/PROGRESSION.md` §5). Before task 3.19 the build shipped no
## guidance of any kind, which is the whole of Sequoyah's "the game feels directionless".
##
## Network authority: **none.** This is presentation (`ARCHITECTURE.md` §2.2, "VFX, audio, camera,
## UI" row). Every peer evaluates the authored steps against state it already holds and shows its
## own line; nothing is sent, requested or validated, and a peer with guidance switched off is
## indistinguishable to every other system.
##
## **Party facts are read, never subscribed to.** `wellspring_capped`, `ship_repaired` and friends
## are HOST-ONLY emits — a client's own bus never fires them, which is the bug F-250 and F-254 each
## cost a task to find. So the conditions below POLL replicated state (`Wellspring.capped`,
## `CycleService.current_cycle()`, `ProgressionService.tier_reached()`) rather than listening. The
## two exceptions are `EventBus.tier_reached` and `EventBus.boss_defeated`, which are already
## re-derived on every peer by their own owners; those are subscriptions, and they are safe ones.
##
## `GuideHud` draws what this decides. Nothing else reads it, and nothing here touches the tree
## except to look.

const EVENT_BUS := preload("res://core/events/event_bus.gd")
const GUIDE_STEP := preload("res://systems/guide/guide_step_def.gd")

## Matches the int `SettingsService.guidance_mode()` stores.
enum Mode {
	## Objectives and tips. The default, and what a first-time player gets.
	FULL,
	## The objective line only — for a player who knows the game but likes knowing the next rung.
	OBJECTIVES_ONLY,
	## Nothing at all.
	OFF,
}

const WELLSPRING_GROUP: StringName = &"wellspring"
const ENEMY_GROUP: StringName = &"enemy"
const PLAYERS_GROUP: StringName = &"players"
const SHIP_GROUP: StringName = &"extraction_ship"

## Conditions are polled, not watched, so this is the resolution of the whole system. 4 Hz: fast
## enough that "craft an axe" clears while the player is still looking at the craft confirmation,
## slow enough that a group scan per condition is free.
const POLL_SEC: float = 0.25

## A tip never interrupts another tip. Queued ones wait out the current card plus this gap.
const TIP_GAP_SEC: float = 1.5

## How long the tier fanfare holds. Longer than a tip because it is the payoff for a rung, and the
## player should have time to read what it opened.
const FANFARE_SEC: float = 6.0

signal objective_changed(step_id: StringName, text: String)
signal tip_shown(step_id: StringName, text: String, seconds: float)
signal tip_cleared()
signal fanfare_shown(tier: int, title: String, text: String, seconds: float)

var _objectives: Array[Resource] = []
var _tips: Array[Resource] = []
## Step ids satisfied this run. An objective never comes back once cleared, even if the state that
## satisfied it reverses — you do not get told to craft an axe again because you dropped it.
var _completed: Dictionary = {}
## Tip ids fired this run, on top of the per-profile record `SettingsService` persists.
var _fired_this_run: Dictionary = {}
var _current_objective: StringName = &""
var _pending_tips: Array[Resource] = []
var _tip_cooldown: float = 0.0
var _poll_elapsed: float = 0.0
var _bosses_defeated: int = 0
var _loaded: bool = false


func _ready() -> void:
	EVENT_BUS.subscribe_tier_reached(_on_tier_reached)
	EVENT_BUS.subscribe_boss_defeated(_on_boss_defeated)
	EVENT_BUS.subscribe_run_restarted(_on_run_restarted)
	var game_state: Node = get_node_or_null(^"/root/GameState")
	if game_state != null and game_state.has_signal(&"seed_ready"):
		game_state.connect(&"seed_ready", _on_seed_ready)
	set_process(true)


func _exit_tree() -> void:
	EVENT_BUS.unsubscribe_tier_reached(_on_tier_reached)
	EVENT_BUS.unsubscribe_boss_defeated(_on_boss_defeated)
	EVENT_BUS.unsubscribe_run_restarted(_on_run_restarted)


func _process(delta: float) -> void:
	_tip_cooldown = maxf(_tip_cooldown - delta, 0.0)
	_poll_elapsed += delta
	if _poll_elapsed < POLL_SEC:
		return
	_poll_elapsed = 0.0
	evaluate()


## The whole system, in one call. Public so `tools/guide_check.gd` can step a scripted run one
## evaluation at a time instead of waiting out real seconds.
func evaluate() -> void:
	_ensure_loaded()
	if mode() == Mode.OFF:
		_set_objective(&"", "")
		return
	_refresh_objective()
	if mode() == Mode.FULL:
		_refresh_tips()
		_drain_tip_queue()


func mode() -> int:
	var settings: Node = get_node_or_null(^"/root/SettingsService")
	if settings == null:
		return Mode.FULL
	return int(settings.call("guidance_mode"))


## The step id currently on screen, or &"" when the line is empty — which is the correct end state:
## a party that has climbed the ladder and capped a Wellspring is told nothing until the endgame
## step takes over.
func current_objective_id() -> StringName:
	return _current_objective


func current_objective_text() -> String:
	var step: Resource = _step_by_id(_objectives, _current_objective)
	return _expand(String(step.get(&"text"))) if step != null else ""


## Run-scoped reset. Objectives come back for the next run; tips marked once-per-profile do not.
func reset_run() -> void:
	_completed.clear()
	_fired_this_run.clear()
	_pending_tips.clear()
	_bosses_defeated = 0
	_set_objective(&"", "")


# ── Objectives ───────────────────────────────────────────────────────────────────────────────────


func _refresh_objective() -> void:
	# Satisfy first, then choose. Doing it in this order means a step completed by the same state
	# change that made the NEXT one eligible never flashes for a frame before moving on.
	for step: Resource in _objectives:
		var step_id: StringName = StringName(step.get(&"id"))
		if _completed.has(step_id):
			continue
		if not _holds(step, &"require"):
			continue
		if _holds(step, &"satisfied_by"):
			_completed[step_id] = true

	for step: Resource in _objectives:
		var step_id: StringName = StringName(step.get(&"id"))
		if _completed.has(step_id) or not _holds(step, &"require"):
			continue
		_set_objective(step_id, _expand(String(step.get(&"text"))))
		return
	_set_objective(&"", "")


func _set_objective(step_id: StringName, text: String) -> void:
	if step_id == _current_objective:
		return
	_current_objective = step_id
	objective_changed.emit(step_id, text)


# ── Tips ─────────────────────────────────────────────────────────────────────────────────────────


func _refresh_tips() -> void:
	var settings: Node = get_node_or_null(^"/root/SettingsService")
	for step: Resource in _tips:
		var step_id: StringName = StringName(step.get(&"id"))
		if _fired_this_run.has(step_id) or _pending_tips.has(step):
			continue
		if bool(step.get(&"once_per_profile")) and settings != null \
				and bool(settings.call("has_seen_tip", step_id)):
			continue
		if not _holds(step, &"require") or not _holds(step, &"satisfied_by"):
			continue
		_pending_tips.append(step)


func _drain_tip_queue() -> void:
	if _pending_tips.is_empty() or _tip_cooldown > 0.0:
		return
	var step: Resource = _pending_tips.pop_front()
	var step_id: StringName = StringName(step.get(&"id"))
	var seconds: float = float(step.get(&"seconds"))
	_fired_this_run[step_id] = true
	if bool(step.get(&"once_per_profile")):
		var settings: Node = get_node_or_null(^"/root/SettingsService")
		if settings != null:
			settings.call("mark_tip_seen", step_id)
	_tip_cooldown = seconds + TIP_GAP_SEC
	tip_shown.emit(step_id, _expand(String(step.get(&"text"))), seconds)


func _on_tier_reached(tier: int, item_id: StringName) -> void:
	if mode() == Mode.OFF:
		return
	var progression: Node = get_node_or_null(^"/root/ProgressionService")
	var tier_label: String = String(progression.call("tier_name", tier)) if progression != null \
		else str(tier)
	var opened: String = ""
	if item_id != &"":
		var registry: Node = get_node_or_null(^"/root/Registry")
		if registry != null and bool(registry.call("has_item", item_id)):
			var item: Resource = registry.call("get_item", item_id) as Resource
			if item != null:
				opened = String(item.get(&"display_name"))
	# Deliberately not routed through the tip queue: a rung is the loudest thing that happens
	# outside combat and must never be delayed behind "walls help at night".
	fanfare_shown.emit(
		tier,
		"THE %s AGE" % tier_label.to_upper(),
		"%s — tier %d of 5" % [opened, tier] if not opened.is_empty() else "tier %d of 5" % tier,
		FANFARE_SEC
	)


func _on_boss_defeated(_boss_id: StringName, _world_position: Vector3) -> void:
	_bosses_defeated += 1


func _on_run_restarted() -> void:
	reset_run()


func _on_seed_ready(_value: int) -> void:
	reset_run()


# ── Conditions ───────────────────────────────────────────────────────────────────────────────────


## Evaluates one of a step's two condition slots. `slot` is &"require" or &"satisfied_by"; the arg
## and count live beside it under the matching `<slot>_arg` / `<slot>_count` names, which is why
## those field names are worth keeping parallel.
func _holds(step: Resource, slot: StringName) -> bool:
	var condition: int = int(step.get(slot))
	var arg_field: StringName = &"require_arg" if slot == &"require" else &"satisfied_arg"
	var count_field: StringName = &"require_count" if slot == &"require" else &"satisfied_count"
	var arg: StringName = StringName(step.get(arg_field))
	var count: int = int(step.get(count_field))
	match condition:
		GUIDE_STEP.Condition.ALWAYS:
			return true
		GUIDE_STEP.Condition.NEVER:
			return false
		GUIDE_STEP.Condition.HAS_ITEM:
			return _local_item_count(arg) >= count
		GUIDE_STEP.Condition.TIER_REACHED:
			var progression: Node = get_node_or_null(^"/root/ProgressionService")
			return progression != null and int(progression.call("tier_reached")) >= count
		GUIDE_STEP.Condition.STATION_BUILT:
			return _station_count(arg) >= count
		GUIDE_STEP.Condition.WELLSPRINGS_CAPPED:
			return _capped_wellspring_count() >= count
		GUIDE_STEP.Condition.CYCLE_AT_LEAST:
			var cycle: Node = get_node_or_null(^"/root/CycleService")
			return cycle != null and int(cycle.call("current_cycle")) >= count
		GUIDE_STEP.Condition.BOSS_KILLED:
			return _bosses_defeated >= count
		GUIDE_STEP.Condition.NIGHT:
			return _is_night()
		GUIDE_STEP.Condition.ENEMY_NEARBY:
			return _nearest_enemy_distance() <= float(maxi(count, 1))
		GUIDE_STEP.Condition.TOOL_BLOCKED:
			var prompt: Node = get_node_or_null(^"/root/FocusPrompt")
			return prompt != null and prompt.has_method(&"focus_is_blocked") \
				and bool(prompt.call("focus_is_blocked"))
		GUIDE_STEP.Condition.ON_CORRUPTED_GROUND:
			var mire: Node = get_node_or_null(^"/root/MireGrid")
			var player: Node3D = _local_player()
			if mire == null or player == null:
				return false
			return bool(mire.call("is_corrupted", player.global_position))
		GUIDE_STEP.Condition.SELF_DOWNED:
			var health: Node = get_node_or_null(^"/root/PlayerHealth")
			return health != null and bool(health.call("local_is_downed"))
		GUIDE_STEP.Condition.SHIP_REPAIRED:
			return _ship_is_repaired()
		_:
			return false


func _local_item_count(item_id: StringName) -> int:
	var inventory: Node = get_node_or_null(^"/root/InventoryService")
	if inventory == null or item_id == &"":
		return 0
	return int(inventory.call("local_count", item_id))


## A party fact: any station of this kind anywhere in the world, whoever placed it. Asks
## `CraftingService`, which already resolves both world shapes a station can take and caches the
## answer against `EventBus.world_generation()` (F-286) — re-deriving that here would be a second
## copy of a lookup that has already been wrong twice.
func _station_count(station_id: StringName) -> int:
	var crafting: Node = get_node_or_null(^"/root/CraftingService")
	if crafting == null or station_id == &"" or not crafting.has_method(&"station_count"):
		return 0
	return int(crafting.call("station_count", station_id))


func _capped_wellspring_count() -> int:
	var count: int = 0
	for node: Node in get_tree().get_nodes_in_group(WELLSPRING_GROUP):
		if bool(node.get(&"capped")):
			count += 1
	return count


func _nearest_enemy_distance() -> float:
	var player: Node3D = _local_player()
	if player == null:
		return INF
	var best: float = INF
	for node: Node in get_tree().get_nodes_in_group(ENEMY_GROUP):
		var enemy := node as Node3D
		if enemy == null:
			continue
		best = minf(best, player.global_position.distance_to(enemy.global_position))
	return best


## Same authority-based lookup `CraftingService._local_player()` uses. There is no autoload that
## hands out "the local player", and inventing one for a HUD service would be a third copy of a
## four-line loop.
func _local_player() -> Node3D:
	for node: Node in get_tree().get_nodes_in_group(PLAYERS_GROUP):
		var player := node as Node3D
		if player != null and player.is_multiplayer_authority():
			return player
	return null


## `DayNight` exposes the replicated `time_of_day` fraction and its two thresholds as properties but
## keeps the comparison private, so this reads the same three numbers rather than adding a public
## method to a file this task has no other reason to touch. Every peer has all three: time_of_day is
## replicated, the thresholds are authored content.
func _is_night() -> bool:
	var day_night: Node = get_node_or_null(^"/root/DayNight")
	if day_night == null:
		return false
	var fraction: float = float(day_night.get(&"time_of_day"))
	var night_at: float = float(day_night.get(&"night_started_at"))
	var day_at: float = float(day_night.get(&"day_started_at"))
	return fraction >= night_at or fraction < day_at


## The wreck is seaworthy — `ExtractionShip.repair_stage` at its final stage. Read off the node in
## its own group rather than through `ExtractionService`, which builds ships and does not track
## them, and rather than off `EventBus.ship_repaired`, which is a HOST-ONLY emit (see this file's
## header). `repair_stage` is replicated, so every peer's copy answers correctly.
func _ship_is_repaired() -> bool:
	for node: Node in get_tree().get_nodes_in_group(SHIP_GROUP):
		# `Object.get()` cannot read a GDScript const, so the stage count comes off the script's own
		# constant map — which keeps this in step with `ExtractionShip` if that number ever changes,
		# where a hardcoded 3 would silently drift.
		var stages: int = 3
		var script := node.get_script() as Script
		if script != null:
			var constants: Dictionary = script.get_script_constant_map()
			if constants.has(&"REPAIR_STAGE_COUNT"):
				stages = int(constants[&"REPAIR_STAGE_COUNT"])
		if int(node.get(&"repair_stage")) >= stages:
			return true
	return false


## Substitutes `[action]` with the player's real binding, so a rebound key is never wrong on screen
## — the failure mode every hard-coded "press E" tutorial line in every game has.
func _expand(text: String) -> String:
	if not text.contains("["):
		return text
	var settings: Node = get_node_or_null(^"/root/SettingsService")
	if settings == null or not settings.has_method(&"keybind_label"):
		return text
	var out: String = text
	var regex := RegEx.new()
	regex.compile("\\[([a-z_]+)\\]")
	for found: RegExMatch in regex.search_all(text):
		var action: StringName = StringName(found.get_string(1))
		if not InputMap.has_action(action):
			continue
		out = out.replace(found.get_string(0), String(settings.call("keybind_label", action)))
	return out


func _ensure_loaded() -> void:
	if _loaded:
		return
	var registry: Node = get_node_or_null(^"/root/Registry")
	if registry == null or not registry.has_method(&"guide_step_defs"):
		return
	var defs: Dictionary = registry.call("guide_step_defs") as Dictionary
	for step_id: StringName in defs:
		var step: Resource = defs[step_id] as Resource
		if step == null:
			continue
		if int(step.get(&"kind")) == GUIDE_STEP.Kind.TIP:
			_tips.append(step)
		else:
			_objectives.append(step)
	# Stable order, and `id` as the tiebreak so two steps authored at the same `order` cannot swap
	# places between runs depending on directory read order.
	_objectives.sort_custom(_by_order)
	_tips.sort_custom(_by_order)
	_loaded = true


static func _by_order(a: Resource, b: Resource) -> bool:
	var order_a: int = int(a.get(&"order"))
	var order_b: int = int(b.get(&"order"))
	if order_a == order_b:
		return String(a.get(&"id")) < String(b.get(&"id"))
	return order_a < order_b


static func _step_by_id(steps: Array[Resource], step_id: StringName) -> Resource:
	for step: Resource in steps:
		if StringName(step.get(&"id")) == step_id:
			return step
	return null
