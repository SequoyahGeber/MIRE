extends SceneTree

## Direct proof for task 6.7 (DESIGN.md §5.3): "Losing = all players down simultaneously with no
## revive available, or the Mire consumes the island."
##
##   1. `MireGrid.consumed_fraction()` reports the real fraction of the 256x256 grid at/above a
##      threshold — the raw signal `DefeatService` polls for "the island consumed" half.
##   2. Team wipe needs EVERY present peer down, not just one — and "down" alone (not a further
##      bleed-out timer) is already enough, since a downed player cannot revive anyone else either.
##   3. The verdict freezes `PlayerHealth`: `_run_over` latches, `host_apply_damage` rejects, and a
##      huge `_physics_process` delta no longer advances a downed peer through bleed-out into an
##      auto-respawn — the trap this task's own class doc names (a wipe that quietly un-wipes
##      itself a few seconds later).
##   4. The verdict is terminal: a second `_physics_process` tick fires `run_wiped` zero more times.
##   5. Island-consumed fires the second, independent cause.
##   6. `net_run_defeated` — the code path an actual CLIENT takes, not the host's own direct
##      trigger — drives the identical `defeated` setter and reaches `EventBus.run_wiped` on its
##      own. This is D-108's actual requirement: the emit must not live behind a host-only guard.
##
##   .agent/bin/agent godot --script tools/defeat_check.gd

const EVENT_BUS := preload("res://core/events/event_bus.gd")
const DEFEAT_SERVICE_SCRIPT := preload("res://autoload/defeat_service.gd")
const MIRE_GRID_SIM := preload("res://world/mire/mire_grid_sim.gd")

var failures: int = 0
var defeat_service: Node
var player_health: Node
var mire_grid: Node
var cycle_service: Node
var _wiped_events: Array = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	if not _check_wiring():
		finish()
		return

	EVENT_BUS.subscribe_run_wiped(_on_run_wiped)

	await _check_consumed_fraction()
	await _check_team_wipe_and_freeze()
	await _check_island_consumed()
	await _check_net_run_defeated_fires_locally()

	print("\nDEFEAT_CHECK failures=%d" % failures)
	finish()


func _check_wiring() -> bool:
	print("== the shipped project has everything this check touches ==")
	defeat_service = root.get_node_or_null(^"DefeatService")
	player_health = root.get_node_or_null(^"PlayerHealth")
	mire_grid = root.get_node_or_null(^"MireGrid")
	cycle_service = root.get_node_or_null(^"CycleService")
	check(defeat_service != null, "DefeatService autoload exists")
	check(player_health != null, "PlayerHealth autoload exists")
	check(mire_grid != null, "MireGrid autoload exists")
	check(cycle_service != null, "CycleService autoload exists")
	check(root.get_node_or_null(^"DefeatHud") != null, "DefeatHud autoload exists")
	check(root.get_node_or_null(^"SalvageService") != null, "SalvageService autoload exists")
	return defeat_service != null and player_health != null and mire_grid != null \
		and cycle_service != null


# ── 1. MireGrid.consumed_fraction() ─────────────────────────────────────────────────────────────


func _check_consumed_fraction() -> void:
	print("== MireGrid.consumed_fraction() reports the real fraction at/above a threshold ==")
	mire_grid.call(&"ensure_ready")
	var seeded: float = float(mire_grid.call(&"consumed_fraction", 0.95))
	check(seeded < 0.01, "a freshly seeded grid is nowhere near fully corrupted (%.4f)" % seeded)

	var all_saturated := PackedFloat32Array()
	all_saturated.resize(MIRE_GRID_SIM.CELL_COUNT)
	for i: int in all_saturated.size():
		all_saturated[i] = 1.0
	mire_grid.set(&"_grid", all_saturated)
	check(
		is_equal_approx(float(mire_grid.call(&"consumed_fraction", 0.95)), 1.0),
		"a fully saturated grid reports fraction 1.0"
	)

	var half := PackedFloat32Array()
	half.resize(MIRE_GRID_SIM.CELL_COUNT)
	for i: int in half.size():
		half[i] = 1.0 if i < half.size() / 2 else 0.0
	mire_grid.set(&"_grid", half)
	check(
		is_equal_approx(float(mire_grid.call(&"consumed_fraction", 0.95)), 0.5),
		"a half-saturated grid reports fraction 0.5"
	)


# ── 2. Team wipe + the freeze it must cause ────────────────────────────────────────────────────


func _check_team_wipe_and_freeze() -> void:
	print("== team wipe needs EVERY present peer down, and it freezes PlayerHealth ==")
	var peer_a := _make_player(Vector3(0.0, 0.0, 0.0), 201, "DefeatPeerA")
	var peer_b := _make_player(Vector3(1.0, 0.0, 0.0), 202, "DefeatPeerB")
	player_health.call(&"_ensure_host_state", 201)
	player_health.call(&"_ensure_host_state", 202)

	defeat_service.call(&"_physics_process", 0.0)
	check(not bool(defeat_service.get(&"defeated")), "both alive: no verdict yet")

	player_health.call(&"host_apply_damage", 201, 10000, 0)
	defeat_service.call(&"_physics_process", 0.0)
	check(not bool(defeat_service.get(&"defeated")), "one down, one still alive: still no verdict")

	_wiped_events.clear()
	player_health.call(&"host_apply_damage", 202, 10000, 0)
	defeat_service.call(&"_physics_process", 0.0)
	check(bool(defeat_service.get(&"defeated")), "everyone down: defeat fires")
	check(
		StringName(defeat_service.get(&"cause")) == &"team_wipe",
		"cause is team_wipe, not island_consumed"
	)
	check(_wiped_events.size() == 1, "run_wiped fired exactly once (got %d)" % _wiped_events.size())
	if _wiped_events.size() == 1:
		check(
			int(_wiped_events[0][0]) == int(cycle_service.call(&"current_cycle")),
			"run_wiped carries the real current Cycle"
		)

	# Terminal: a second tick must not fire a second event.
	defeat_service.call(&"_physics_process", 0.0)
	check(_wiped_events.size() == 1, "a second tick after defeat fires run_wiped no more times")

	check(bool(player_health.get(&"_run_over")), "PlayerHealth._run_over latched on run_wiped")
	var hp_before: int = int(player_health.call(&"host_hp", 201))
	check(
		not bool(player_health.call(&"host_apply_damage", 201, 5, 0)),
		"host_apply_damage is rejected once the run is over"
	)
	check(
		int(player_health.call(&"host_hp", 201)) == hp_before,
		"a rejected post-defeat hit changes nothing"
	)
	player_health.call(&"_physics_process", 100.0)
	check(
		not bool(player_health.call(&"host_is_alive", 201)),
		"a huge post-defeat delta does not auto-respawn a downed peer"
	)

	await _check_defeat_hud_centred()

	peer_a.queue_free()
	peer_b.queue_free()
	await process_frame
	check(
		not bool(defeat_service.call(&"_check_team_wipe")),
		"an empty player roster is never read as a wipe"
	)


## F-383: the overlay's text column used to be anchored with PRESET_CENTER + KEEP_SIZE, which bakes
## its offsets from the size the column had at BUILD time — zero, because every label was still
## empty. Filling them in `_on_run_wiped` then grew the column down and right from those stale
## offsets, so the block sat visibly low and right of centre in play.
##
## This asserts the property, not the mechanism: with real text in it, the column's centre is the
## overlay's centre. A CenterContainer satisfies that on every resize; the old preset satisfies it
## only for a control that never changes size.
func _check_defeat_hud_centred() -> void:
	var hud: Node = root.get_node_or_null(^"DefeatHud")
	check(hud != null, "DefeatHud autoload exists")
	if hud == null:
		return
	var overlay := hud.get_node_or_null(^"DefeatOverlay") as Control
	if overlay == null:
		for child: Node in hud.get_children():
			if child is ColorRect:
				overlay = child as Control
				break
	check(overlay != null, "the defeat overlay exists")
	if overlay == null:
		return

	# Let the labels' text reach the layout before measuring.
	await process_frame
	await process_frame

	var column: Control = _first_vbox(overlay)
	check(column != null, "the overlay has a text column")
	if column == null:
		return
	check(column.size.y > 0.0, "the column has been laid out with real text in it")

	var column_centre: Vector2 = column.global_position + column.size * 0.5
	var overlay_centre: Vector2 = overlay.global_position + overlay.size * 0.5
	var drift: Vector2 = (column_centre - overlay_centre).abs()
	check(
		drift.x <= 1.0 and drift.y <= 1.0,
		"the filled defeat column is centred on the overlay (drift %.1f, %.1f px)" % [drift.x, drift.y]
	)


func _first_vbox(node: Node) -> Control:
	for child: Node in node.get_children():
		if child is VBoxContainer:
			return child as Control
		var nested: Control = _first_vbox(child)
		if nested != null:
			return nested
	return null


# ── 3. Island consumed — the second, independent cause ────────────────────────────────────────


func _check_island_consumed() -> void:
	print("== a saturated grid trips the island-consumed cause ==")
	defeat_service.call(&"_reset")
	_wiped_events.clear()

	var all_saturated := PackedFloat32Array()
	all_saturated.resize(MIRE_GRID_SIM.CELL_COUNT)
	for i: int in all_saturated.size():
		all_saturated[i] = 1.0
	mire_grid.set(&"_grid", all_saturated)

	defeat_service.set(&"_elapsed", DEFEAT_SERVICE_SCRIPT.CHECK_INTERVAL_SEC)
	defeat_service.call(&"_physics_process", 0.0)
	check(bool(defeat_service.get(&"defeated")), "a saturated island trips defeat")
	check(
		StringName(defeat_service.get(&"cause")) == &"island_consumed",
		"cause is island_consumed, not team_wipe"
	)
	check(_wiped_events.size() == 1, "run_wiped fired once for island-consumed too")


# ── 4. net_run_defeated — the code path an actual client takes ────────────────────────────────


func _check_net_run_defeated_fires_locally() -> void:
	print("== net_run_defeated (the RPC a client receives) drives the same setter, not a host-only guard ==")
	defeat_service.call(&"_reset")
	_wiped_events.clear()

	defeat_service.call(&"net_run_defeated", "island_consumed", 9, Vector3(1.0, 2.0, 3.0))
	check(bool(defeat_service.get(&"defeated")), "net_run_defeated sets defeated locally")
	check(
		StringName(defeat_service.get(&"cause")) == &"island_consumed",
		"net_run_defeated carries the real cause through"
	)
	check(
		_wiped_events.size() == 1 and int(_wiped_events[0][0]) == 9,
		"net_run_defeated's own local EventBus received run_wiped with the right Cycle"
	)


# ── Helpers ────────────────────────────────────────────────────────────────────────────────────


func _make_player(pos: Vector3, peer_id: int, player_name: String) -> Node3D:
	var player := Node3D.new()
	player.name = player_name
	player.add_to_group(&"players")
	player.set_multiplayer_authority(peer_id)
	root.add_child(player)
	player.global_position = pos
	return player


func _on_run_wiped(cycle: int, world_position: Vector3) -> void:
	_wiped_events.append([cycle, world_position])


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	EVENT_BUS.unsubscribe_run_wiped(_on_run_wiped)
	quit(0 if failures == 0 else 1)
