extends SceneTree

## Direct proof for task 6.4 (DESIGN.md §5.1 item 1, "Capped Wellsprings begin re-corrupting"):
##   1. A freshly capped Wellspring does NOT start degrading on its own — the clock only starts at
##      the NEXT real Cycle turnover (`EventBus.cycle_advanced`), not the instant it caps.
##   2. Once a Cycle advances, `recorruption_sec` climbs, crosses `RECORRUPTING_VISUAL_FRACTION` (the
##      mesh swaps to the decaying state while still `capped`), then finishes: `capped` flips back to
##      false, `has_recorrupted` becomes true, and `EventBus.emit_wellspring_recorrupted()` fires
##      exactly once.
##   3. ROADMAP.md's own 6.4 line ("decay on a host timer unless Warded"): the clock PAUSES, not
##      resets, while a placed Ward's radius covers the Wellspring, and resumes the instant it does not.
##   4. `MireGrid` is the finish event's real consumer: `capped_wellspring_count()` goes up on cap and
##      back down on full re-corruption — the spread-rate reduction a cap grants is undone, not permanent.
##   5. A fully re-corrupted Wellspring is a normal uncapped one: the same ritual recaptures it, and
##      the new cap waits for its OWN next Cycle turnover before degrading again.
##
##   .agent/bin/agent godot --script tools/wellspring_recorruption_check.gd

const WELLSPRING_SCRIPT := preload("res://systems/wellspring/wellspring.gd")
const EVENT_BUS := preload("res://core/events/event_bus.gd")

var failures: int = 0
var world: Node
var mire_grid: Node
var cycle_service: Node
var build_service: Node
var _recorrupted_events: Array = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	if not _check_wiring():
		finish()
		return

	EVENT_BUS.subscribe_wellspring_recorrupted(_on_wellspring_recorrupted)
	# Seeded up front, not just inside the MireGrid section: `_on_wellspring_capped` is a no-op on an
	# empty grid, so every section's cap/recorrupt events must land on a real, already-seeded grid for
	# `capped_wellspring_count()` to mean anything by the time section 3 reads it.
	mire_grid.call("ensure_ready")
	await _check_no_recorruption_without_a_cycle()
	await _check_recorruption_clock_and_visual_states()
	await _check_recorruption_pauses_under_a_ward()
	await _check_mire_grid_spread_reduction_is_undone()
	await _check_recapture_waits_for_its_own_next_cycle()

	print("\nWELLSPRING_RECORRUPTION_CHECK failures=%d" % failures)
	finish()


func _check_wiring() -> bool:
	print("== the shipped project has everything this check touches ==")
	world = root.get_node_or_null(^"EnemyWorld")
	mire_grid = root.get_node_or_null(^"MireGrid")
	cycle_service = root.get_node_or_null(^"CycleService")
	build_service = root.get_node_or_null(^"BuildService")
	check(world != null, "EnemyWorld autoload exists")
	check(mire_grid != null, "MireGrid autoload exists")
	check(cycle_service != null, "CycleService autoload exists")
	check(build_service != null, "BuildService autoload exists")
	return world != null and mire_grid != null and cycle_service != null and build_service != null


func _make_wellspring(pos: Vector3, wellspring_name: String) -> Node3D:
	var wellspring := WELLSPRING_SCRIPT.new() as Node3D
	wellspring.name = wellspring_name
	root.add_child(wellspring)
	wellspring.global_position = pos
	return wellspring


func _make_player(pos: Vector3, peer_id: int, player_name: String) -> Node3D:
	var player := Node3D.new()
	player.name = player_name
	player.add_to_group(&"players")
	player.set_multiplayer_authority(peer_id)
	root.add_child(player)
	player.global_position = pos
	return player


## Solo-completes the ritual (fast: `host_tick` crosses the whole 150s in one call) and returns the
## Wellspring capped, with `world` cleared of the defense wave it spawned.
func _cap_solo(pos: Vector3, wellspring_name: String, player: Node3D) -> Node3D:
	var wellspring := _make_wellspring(pos, wellspring_name)
	player.global_position = pos
	wellspring.call(&"request_toggle_channel")
	wellspring.call(&"host_tick", 200.0)
	world.call("host_despawn_all")
	return wellspring


func _mesh_path(wellspring: Node3D) -> String:
	var visual: Node = wellspring.get_node_or_null(^"WellspringVisual")
	return visual.scene_file_path if visual != null else ""


func _check_no_recorruption_without_a_cycle() -> void:
	print("\n== a capped Wellspring does not degrade without a Cycle turnover ==")
	var player := _make_player(Vector3(100.0, 0.0, 100.0), 1, "CheckPlayerA")
	var wellspring := _cap_solo(Vector3(100.0, 0.0, 100.0), "CheckWellspringNoTurnover", player)
	check(bool(wellspring.get("capped")), "the ritual still caps it")

	wellspring.call(&"host_tick", 500.0)
	check(is_equal_approx(float(wellspring.get("recorruption_sec")), 0.0),
		"recorruption_sec stays 0 with no Cycle turnover, however long host_tick runs")
	check(bool(wellspring.get("capped")), "still capped with no Cycle turnover")

	await process_frame
	await process_frame
	check(_mesh_path(wellspring) == "res://assets/wellsprings/exports/wellspring_capped.glb",
		"mesh stays the capped state with no Cycle turnover")

	wellspring.queue_free()
	player.queue_free()
	await process_frame


func _check_recorruption_clock_and_visual_states() -> void:
	print("\n== a Cycle turnover starts the clock; it degrades, then flips back to uncapped ==")
	var player := _make_player(Vector3(200.0, 0.0, 200.0), 1, "CheckPlayerB")
	var wellspring := _cap_solo(Vector3(200.0, 0.0, 200.0), "CheckWellspringClock", player)
	check(bool(wellspring.get("capped")), "capped before the Cycle advances")

	cycle_service.call("host_advance_cycle")
	check(bool(wellspring.get("capped")),
		"a Cycle turnover alone does not instantly re-corrupt it — the clock just starts")

	var duration: float = WELLSPRING_SCRIPT.RECORRUPTION_DURATION_SEC
	var threshold_fraction: float = WELLSPRING_SCRIPT.RECORRUPTING_VISUAL_FRACTION

	print("-- crossing the visual threshold while still capped --")
	wellspring.call(&"host_tick", duration * threshold_fraction + 1.0)
	check(bool(wellspring.get("capped")), "still capped just past the visual threshold")
	check(float(wellspring.get("recorruption_sec")) >= duration * threshold_fraction,
		"recorruption_sec has crossed the visual threshold")
	await process_frame
	await process_frame
	check(_mesh_path(wellspring) == "res://assets/wellsprings/exports/wellspring_recorrupting.glb",
		"mesh swaps to the re-corrupting state past the threshold, while still capped")

	print("-- finishing the clock --")
	wellspring.call(&"host_tick", duration)
	check(not bool(wellspring.get("capped")), "a full clock flips capped back to false")
	check(bool(wellspring.get("has_recorrupted")), "has_recorrupted is now true")
	check(is_equal_approx(float(wellspring.get("recorruption_sec")), 0.0),
		"recorruption_sec resets to 0 once it finishes")
	check(_recorrupted_events.size() == 1, "EventBus.emit_wellspring_recorrupted fired exactly once")
	if not _recorrupted_events.is_empty():
		check(String(_recorrupted_events[0].get("name", "")) == "CheckWellspringClock",
			"the recorrupted event names the right Wellspring")
	await process_frame
	await process_frame
	check(_mesh_path(wellspring) == "res://assets/wellsprings/exports/wellspring_corrupted.glb",
		"mesh shows the (worse) corrupted state, not the original uncapped one")

	wellspring.queue_free()
	player.queue_free()
	await process_frame


## A piece is planted directly into BuildService's own `_container`/`_placed` rather than going
## through the full placement pipeline — `build_check.gd` already covers that pipeline;
## `mire_interaction_check.gd`'s own Ward-resistance section plants a piece the identical way to test
## the seam, not the whole pipeline again.
func _check_recorruption_pauses_under_a_ward() -> void:
	print("\n== the clock PAUSES, not resets, while a Ward covers the Wellspring (ROADMAP.md 6.4) ==")
	var player := _make_player(Vector3(500.0, 0.0, 500.0), 1, "CheckPlayerWard")
	var wellspring := _cap_solo(Vector3(500.0, 0.0, 500.0), "CheckWellspringWard", player)
	cycle_service.call("host_advance_cycle")

	var container: Node3D = build_service.get(&"_container")
	var placed: Dictionary = build_service.get(&"_placed")
	var ward_piece := Node3D.new()
	ward_piece.name = "CheckWardPiece"
	ward_piece.position = wellspring.global_position
	container.add_child(ward_piece)
	placed[StringName("CheckWardPiece")] = {"def": &"ward_post", "owner": 1}

	wellspring.call(&"host_tick", WELLSPRING_SCRIPT.RECORRUPTION_DURATION_SEC * 2.0)
	check(is_equal_approx(float(wellspring.get("recorruption_sec")), 0.0),
		"recorruption_sec never accrues while a Ward covers the Wellspring, however long host_tick runs")
	check(bool(wellspring.get("capped")), "still capped — the clock paused, it did not finish")

	placed.erase(StringName("CheckWardPiece"))
	container.remove_child(ward_piece)
	ward_piece.queue_free()

	wellspring.call(&"host_tick", 10.0)
	check(float(wellspring.get("recorruption_sec")) > 0.0,
		"recorruption_sec starts accruing again the instant the Ward is gone")
	wellspring.call(&"host_tick", WELLSPRING_SCRIPT.RECORRUPTION_DURATION_SEC)
	check(not bool(wellspring.get("capped")), "and the clock still finishes once nothing pauses it")

	wellspring.queue_free()
	player.queue_free()
	await process_frame


func _check_mire_grid_spread_reduction_is_undone() -> void:
	print("\n== MireGrid's per-cap spread reduction is undone on full re-corruption ==")
	var before: int = int(mire_grid.call("capped_wellspring_count"))

	var player := _make_player(Vector3(300.0, 0.0, 300.0), 1, "CheckPlayerC")
	var wellspring := _cap_solo(Vector3(300.0, 0.0, 300.0), "CheckWellspringMireGrid", player)
	check(int(mire_grid.call("capped_wellspring_count")) == before + 1,
		"capping increments MireGrid's capped count")

	cycle_service.call("host_advance_cycle")
	wellspring.call(&"host_tick", 100000.0)
	check(not bool(wellspring.get("capped")),
		"a host_tick far larger than the clock still finishes recorruption cleanly, exactly once")
	check(int(mire_grid.call("capped_wellspring_count")) == before,
		"full re-corruption decrements MireGrid's capped count back down")

	wellspring.queue_free()
	player.queue_free()
	await process_frame


func _check_recapture_waits_for_its_own_next_cycle() -> void:
	print("\n== a re-corrupted Wellspring recaptures cleanly and waits for its OWN next Cycle ==")
	var player := _make_player(Vector3(400.0, 0.0, 400.0), 1, "CheckPlayerD")
	var wellspring := _cap_solo(Vector3(400.0, 0.0, 400.0), "CheckWellspringRecapture", player)
	cycle_service.call("host_advance_cycle")
	wellspring.call(&"host_tick", 100000.0)
	check(not bool(wellspring.get("capped")), "fully re-corrupted, ready to recapture")

	player.global_position = wellspring.global_position
	wellspring.call(&"request_toggle_channel")
	check(bool(wellspring.get("channeling")), "the identical ritual toggle recaptures it")
	wellspring.call(&"host_tick", 200.0)
	check(bool(wellspring.get("capped")), "the recapture completes")
	world.call("host_despawn_all")

	wellspring.call(&"host_tick", 100000.0)
	check(bool(wellspring.get("capped")) and is_equal_approx(float(wellspring.get("recorruption_sec")), 0.0),
		"the fresh cap does not degrade on its own — it needs its own next Cycle turnover")

	wellspring.queue_free()
	player.queue_free()
	await process_frame


func _on_wellspring_recorrupted(wellspring_name: StringName, world_position: Vector3) -> void:
	_recorrupted_events.append({"name": String(wellspring_name), "position": world_position})


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	EVENT_BUS.unsubscribe_wellspring_recorrupted(_on_wellspring_recorrupted)
	quit(0 if failures == 0 else 1)
