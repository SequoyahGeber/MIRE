extends SceneTree

## F-243 — THE RUN RESTART CHECK. Boots the SHIPPED map (same pattern as `tools/loop_audit_check.gd`),
## seeds run-scoped state across every system F-243's fix touches, drives a real defeat, calls
## `CycleService.host_restart_run()` (the same call `ui/hud/defeat_hud.gd`'s "Start Next Run" button
## makes for the local host), and asserts every one of those systems actually reset — then proves the
## restarted run is genuinely playable, not just reset-and-frozen, by advancing its Cycle again.
##
## Solo/offline (no real NetTransport session) — the SAME path `_owns_cycle()`/`_owns_mutation()`
## treat as "host" everywhere in this codebase (an offline host-of-one is exactly host authority with
## no peer to disagree). This exercises `CycleService.host_restart_run()`'s direct
## `EVENT_BUS.emit_run_restarted()` path — the same one a real solo player's restart takes. It does
## NOT exercise the `WorldDeltaLog`-relayed re-derivation a CONNECTED CLIENT takes
## (`CycleService._on_world_delta_applied()`'s new `RUN_KIND` branch) — that branch reuses the exact
## dispatch `tools/cycle_advanced_net_check.gd` already proves correct for the sibling `KIND` branch,
## just gated on a different `(kind, key)` pair; no two-process check exercises it directly for
## `run_restarted` itself. Filed as F-260, not fixed here.
##
##   .agent/bin/agent godot --script tools/run_restart_check.gd

const CommandServiceScript = preload("res://autoload/command_service.gd")
const VALIDATOR := preload("res://systems/building/placement_validator.gd")
const EVENT_BUS := preload("res://core/events/event_bus.gd")

const SCENE_PATH: String = "res://levels/hollowmere.tscn"
const HOST_PEER: int = 1
const TEST_SAVE_PATH: String = "user://run_restart_check_salvage.json"
const TEST_ITEM_ID: StringName = &"iron_ingot"
const TEST_BUILDABLE_ID: StringName = &"wall_wood"
const TEST_ENEMY_ID: StringName = &"crawler"

var failures: int = 0
var command_service: CommandServiceScript
var level: Node
var player: Node3D


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await _phase_boot()
	if level == null:
		_finish()
		return
	await _phase_seed_state()
	await _phase_defeat()
	await _phase_restart()
	await _phase_playable_again()
	_finish()


# ── 1 · boot ─────────────────────────────────────────────────────────────────────────────────────


func _phase_boot() -> void:
	print("\n== RESTART 1 · the shipped scene boots ==")
	var packed: PackedScene = load(SCENE_PATH) as PackedScene
	check(packed != null, "the main scene loads")
	if packed == null:
		return
	level = packed.instantiate()
	root.add_child(level)
	current_scene = level
	for i: int in 30:
		await process_frame
		await physics_frame

	command_service = root.get_node_or_null(^"CommandService") as CommandServiceScript
	check(command_service != null, "CommandService is up")
	player = _player_body()
	check(player != null, "a player body exists in the shipped scene")

	# D-107's guard: a real save write must never land in a developer's actual user://salvage.json.
	var salvage: Node = root.get_node_or_null(^"SalvageService")
	if salvage != null:
		salvage.set(&"save_path", TEST_SAVE_PATH)


# ── 2 · seed run-scoped state across every system the fix touches ──────────────────────────────────


func _phase_seed_state() -> void:
	print("\n== RESTART 2 · seeding run-scoped state before the run ends ==")

	await _cmd("give %s 5" % TEST_ITEM_ID, true)
	var inventory: Node = root.get_node_or_null(^"InventoryService")
	check(int(inventory.call("host_count", HOST_PEER, TEST_ITEM_ID)) >= 5,
		"inventory holds the granted item before restart")

	await _cmd("spawn %s 1" % TEST_ENEMY_ID, true)
	await physics_frame
	var enemy_world: Node = root.get_node_or_null(^"EnemyWorld")
	check(int(enemy_world.call("live_count")) >= 1, "an enemy is alive before restart")

	var build_service: Node = root.get_node_or_null(^"BuildService")
	var registry: Node = root.get_node_or_null(^"Registry")
	var wall_def: Resource = registry.call("get_buildable", TEST_BUILDABLE_ID)
	if wall_def != null and player != null and build_service != null:
		# `wall_wood`'s own cost (content/buildables/wall.tres) is `log`, not TEST_ITEM_ID —
		# granted separately so the inventory-persistence assertions above stay on their own item.
		await _cmd("give log 4", true)
		var spot: Vector3 = player.global_position + Vector3(3.0, 0.0, 0.0)
		var snapped: Transform3D = VALIDATOR.snap_transform(wall_def, spot, 0.0)
		build_service.call("request_place", TEST_BUILDABLE_ID, snapped)
		await physics_frame
	check(int(build_service.call("placed_count")) >= 1, "a buildable piece is placed before restart")

	var wellspring: Node = _first_node_in_group(&"wellspring")
	if wellspring != null:
		wellspring.set(&"capped", true)
	check(wellspring != null and bool(wellspring.get(&"capped")), "a Wellspring is capped before restart")

	var chest: Node = _first_node_in_group(&"chest")
	if chest != null:
		chest.set(&"opened", true)
	check(chest != null and bool(chest.get(&"opened")), "a chest is opened before restart")

	var ship: Node = _first_node_in_group(&"extraction_ship")
	if ship != null:
		ship.set(&"repair_stage", 2)
	check(ship != null and int(ship.get(&"repair_stage")) == 2, "the ship has repair progress before restart")

	var cycle_service: Node = root.get_node_or_null(^"CycleService")
	cycle_service.call("host_advance_cycle")
	await physics_frame
	check(int(cycle_service.call("current_cycle")) == 2, "the Cycle advanced to 2 before restart")

	# F-259: the Cycle advance above is also what widens the wave roster —
	# `CycleService._expand_enemy_pool()` calls `WaveSpawner.host_unlock_next_enemy()` once per
	# advance. One advance is enough: `roster_order` ships with a single archetype, so an unlocked
	# pool of exactly 1 is the whole of what a restart has to clear.
	var wave: Node = root.get_node_or_null(^"WaveSpawner")
	check(wave != null, "WaveSpawner is up")
	check(not (wave.call("unlocked_enemy_pool") as Array).is_empty(),
		"the wave roster unlocked an archetype before restart")

	# F-259: and the night latch, the second piece of WaveSpawner's run-scoped state. A run that
	# ends AT NIGHT — the common case, since that is when the wave that kills you is on the ground —
	# leaves `_night_active` true and EnemyWorld's ambient field switched off behind it.
	check(int(wave.call("host_start_wave")) >= 0, "a night wave is running before restart")
	check(bool(wave.get(&"_night_active")), "WaveSpawner's night latch is set before restart")
	check(not bool(enemy_world.get(&"ambient_enabled")),
		"the ambient field is suppressed by that night wave before restart")


# ── 3 · a real defeat ────────────────────────────────────────────────────────────────────────────


func _phase_defeat() -> void:
	print("\n== RESTART 3 · a real defeat ends the run ==")
	var defeat: Node = root.get_node_or_null(^"DefeatService")
	await _cmd("damage @s 1000000", true)
	await physics_frame
	var wiped: bool = await _until(func() -> bool: return bool(defeat.call("is_defeated")), 15.0) \
		if defeat.has_method(&"is_defeated") else await _until(
			func() -> bool: return bool(defeat.get(&"defeated")), 15.0)
	check(wiped, "the run actually ended in defeat")
	var hud: Node = root.get_node_or_null(^"DefeatHud")
	check(hud != null and get_nodes_in_group(&"blocks_gameplay_input").has(hud),
		"the defeat screen is up and blocking input")


# ── 4 · restart, and every system resets ────────────────────────────────────────────────────────


func _phase_restart() -> void:
	print("\n== RESTART 4 · CycleService.host_restart_run() — the button's own call ==")
	var cycle_service: Node = root.get_node_or_null(^"CycleService")
	var new_cycle: int = int(cycle_service.call("host_restart_run"))
	check(new_cycle == 1, "host_restart_run() reports Cycle 1 (was Cycle %d)" % new_cycle)
	for i: int in 10:
		await process_frame
		await physics_frame

	check(int(cycle_service.call("current_cycle")) == 1, "CycleService reads Cycle 1 after restart")

	var defeat: Node = root.get_node_or_null(^"DefeatService")
	check(not bool(defeat.get(&"defeated")), "DefeatService.defeated cleared")
	var hud: Node = root.get_node_or_null(^"DefeatHud")
	check(not get_nodes_in_group(&"blocks_gameplay_input").has(hud),
		"the defeat screen released input again")

	var wellspring: Node = _first_node_in_group(&"wellspring")
	check(wellspring != null and not bool(wellspring.get(&"capped")) \
		and not bool(wellspring.get(&"has_recorrupted")), "the Wellspring reads as never-capped again")

	var chest: Node = _first_node_in_group(&"chest")
	check(chest != null and not bool(chest.get(&"opened")), "the chest re-closed")

	var ship: Node = _first_node_in_group(&"extraction_ship")
	check(ship != null and int(ship.get(&"repair_stage")) == 0, "the ship's repair progress cleared")

	var build_service: Node = root.get_node_or_null(^"BuildService")
	check(int(build_service.call("placed_count")) == 0, "every placed buildable was cleared")

	var enemy_world: Node = root.get_node_or_null(^"EnemyWorld")
	check(int(enemy_world.call("live_count")) == 0, "every live enemy was despawned")

	# F-259: the three pieces of WaveSpawner's own run-scoped state. The roster is the finding
	# itself; the night latch and the ambient restore are the same bug in the same file, found by
	# reading what else `host_start_wave()` leaves set (see docs/FINDINGS.md F-259).
	var wave: Node = root.get_node_or_null(^"WaveSpawner")
	check((wave.call("unlocked_enemy_pool") as Array).is_empty(),
		"WaveSpawner's unlocked roster reset to the Cycle-1 starting roster")
	check(not bool(wave.get(&"_night_active")), "WaveSpawner's night latch cleared")
	check(bool(enemy_world.get(&"ambient_enabled")),
		"the ambient field the night wave suppressed is switched back on")
	check(int(wave.call("current_cycle")) == 1, "WaveSpawner reads Cycle 1 again")

	var inventory: Node = root.get_node_or_null(^"InventoryService")
	check(int(inventory.call("host_count", HOST_PEER, TEST_ITEM_ID)) == 0,
		"the inventory reset to empty")

	var player_health: Node = root.get_node_or_null(^"PlayerHealth")
	check(bool(player_health.call("host_is_alive", HOST_PEER)),
		"the player is alive again after restart")

	var salvage: Node = root.get_node_or_null(^"SalvageService")
	check(int(salvage.call("wellsprings_capped_this_run")) == 0,
		"SalvageService's this-run tally is 0 (already self-resets at bank time, unrelated to this fix)")


# ── 5 · the restarted run is actually playable ──────────────────────────────────────────────────


func _phase_playable_again() -> void:
	print("\n== RESTART 5 · the restarted run keeps working ==")
	var cycle_service: Node = root.get_node_or_null(^"CycleService")
	var new_cycle: int = int(cycle_service.call("host_advance_cycle"))
	check(new_cycle == 2, "a second Cycle advance works after restart (Cycle %d)" % new_cycle)

	# F-259: the reset has to leave the roster REFILLABLE, not merely empty — `roster_order` is an
	# export `_bind_rules()`-style adoption never touches, so clearing `_unlocked_pool` alone should
	# put the next run back on the same unlock curve the first one walked.
	var wave: Node = root.get_node_or_null(^"WaveSpawner")
	check((wave.call("unlocked_enemy_pool") as Array).size() == 1,
		"the restarted run unlocks its roster again from Cycle 1")
	# And the cleared latch has to let a night actually start again — a stuck latch makes every
	# subsequent `_on_night_started()` a silent no-op for the rest of the process.
	check(int(wave.call("host_start_wave")) >= 0, "a night wave can start again after restart")


# ── helpers ──────────────────────────────────────────────────────────────────────────────────────


func _cmd(line: String, expect_ok: bool) -> Dictionary:
	var result: Dictionary = await command_service.execute(
		line, command_service.build_local_ctx(&"runner"))
	if expect_ok and not bool(result.get("ok", false)):
		check(false, "command `%s` failed: %s" % [line, result.get("message", "")])
	return result


func _player_body() -> Node3D:
	for node: Node in get_nodes_in_group(&"players"):
		return node as Node3D
	return null


func _first_node_in_group(group: StringName) -> Node:
	for node: Node in get_nodes_in_group(group):
		if is_instance_valid(node):
			return node
	return null


func _until(condition: Callable, timeout_seconds: float) -> bool:
	var deadline_msec: int = Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline_msec:
		if bool(condition.call()):
			return true
		await create_timer(0.1).timeout
	return bool(condition.call())


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func _finish() -> void:
	print("\nRUN_RESTART_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)
