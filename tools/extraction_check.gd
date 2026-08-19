extends SceneTree

## Direct proof for task 6.5:
##   1. The shipped project actually wires ExtractionService and ExtractionHud (F-068's lesson — a
##      script that is merely correct but never registered is exactly the failure this class of check
##      exists to catch, and the same gap `ui/hud/wellspring_hud.gd` shipped and never closed).
##   2. `shipwreck`-kind markers get a live ExtractionShip; other kinds don't.
##   3. The repair recipe: gated on Cycle >= 3, in-range, holding a repair hammer, and the current
##      stage's resources actually present — and only THEN consumed, advancing one hull state per
##      call through all three stages to fully repaired.
##   4. The departure hold: unreachable before repair completes, toggles start/cancel the same way
##      Wellspring's channel does, PAUSES (not resets) while under the session's full player count,
##      and finishes into a terminal `departed` state that fires `EventBus.run_extracted` exactly once.
##
##   .agent/bin/agent godot --script tools/extraction_check.gd

const EXTRACTION_SHIP_SCRIPT := preload("res://systems/extraction/extraction_ship.gd")
const EVENT_BUS := preload("res://core/events/event_bus.gd")

const REPAIR_HAMMER: StringName = &"repair_hammer"

var failures: int = 0
var inventory: Node
var cycle_service: Node
var _repaired_events: Array = []
var _extracted_events: Array = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	if not _check_wiring():
		finish()
		return

	await _check_marker_consumption()
	_check_repair_fsm()
	_check_departure_fsm()

	print("\nEXTRACTION_CHECK failures=%d" % failures)
	finish()


func _check_wiring() -> bool:
	print("== the shipped project actually has the extraction autoloads ==")
	var service: Node = root.get_node_or_null(^"ExtractionService")
	var hud: Node = root.get_node_or_null(^"ExtractionHud")
	inventory = root.get_node_or_null(^"InventoryService")
	cycle_service = root.get_node_or_null(^"CycleService")
	check(service != null, "ExtractionService is registered as an autoload")
	check(hud != null, "ExtractionHud is registered as an autoload")
	check(inventory != null, "InventoryService autoload exists")
	check(cycle_service != null, "CycleService autoload exists")
	return service != null and hud != null and inventory != null and cycle_service != null


func _check_marker_consumption() -> void:
	print("\n== 'shipwreck' marker -> live ExtractionShip ==")
	var wreck_marker := Marker3D.new()
	wreck_marker.name = "CheckShipwreckMarker"
	wreck_marker.add_to_group(&"authored_world_marker")
	wreck_marker.set_meta(&"kind", "shipwreck")
	wreck_marker.position = Vector3(700.0, 0.0, 700.0)
	root.add_child(wreck_marker)

	var decoy := Marker3D.new()
	decoy.name = "CheckDecoyMarker"
	decoy.add_to_group(&"authored_world_marker")
	decoy.set_meta(&"kind", "standing_stones")
	root.add_child(decoy)

	await process_frame
	await process_frame

	var built: Node3D = null
	for child: Node in wreck_marker.get_children():
		if child.is_in_group(&"extraction_ship"):
			built = child as Node3D
	check(built != null, "a 'shipwreck' marker gets a live ExtractionShip child")
	check(wreck_marker.get_children().size() == 1,
		"exactly one ExtractionShip is built per marker (no double-build)")

	var decoy_built := false
	for child: Node in decoy.get_children():
		if child.is_in_group(&"extraction_ship"):
			decoy_built = true
	check(not decoy_built, "a non-'shipwreck' marker gets no ExtractionShip")


func _check_repair_fsm() -> void:
	print("\n== repair recipe ==")
	EVENT_BUS.subscribe_ship_repaired(_on_ship_repaired)

	var ship := EXTRACTION_SHIP_SCRIPT.new() as Node3D
	ship.name = "CheckShipRepair"
	root.add_child(ship)
	ship.global_position = Vector3(-500.0, 0.0, -500.0)

	var player := Node3D.new()
	player.name = "CheckRepairPlayer"
	player.add_to_group(&"players")
	player.set_multiplayer_authority(NetConfig.HOST_PEER_ID)
	root.add_child(player)
	player.global_position = ship.global_position

	print("-- gated on Cycle >= 3 --")
	check(int(cycle_service.call(&"current_cycle")) < 3, "sanity: the run starts before Cycle 3")
	inventory.call(&"host_add", NetConfig.HOST_PEER_ID, REPAIR_HAMMER, 1)
	_grant_cost(ship.call(&"current_repair_cost") as Dictionary)
	ship.call(&"request_repair")
	check(int(ship.get("repair_stage")) == 0,
		"rejected before Cycle 3 even though the hammer, resources and range are all otherwise fine")

	while int(cycle_service.call(&"current_cycle")) < 3:
		cycle_service.call(&"host_advance_cycle")
	check(int(cycle_service.call(&"current_cycle")) >= 3, "sanity: Cycle 3 reached")

	print("-- out of range is rejected --")
	player.global_position = ship.global_position + Vector3(500.0, 0.0, 0.0)
	ship.call(&"request_repair")
	check(int(ship.get("repair_stage")) == 0,
		"a requester outside REPAIR_RANGE_M cannot repair, even with the hammer and resources in hand")
	player.global_position = ship.global_position

	print("-- missing the repair hammer is rejected --")
	inventory.call(&"host_remove", NetConfig.HOST_PEER_ID, REPAIR_HAMMER, 1)
	ship.call(&"request_repair")
	check(int(ship.get("repair_stage")) == 0, "no repair hammer in hand -> rejected")
	inventory.call(&"host_add", NetConfig.HOST_PEER_ID, REPAIR_HAMMER, 1)

	print("-- missing resources is rejected --")
	_remove_cost(ship.call(&"current_repair_cost") as Dictionary)
	ship.call(&"request_repair")
	check(int(ship.get("repair_stage")) == 0, "the stage-0 cost was withdrawn again -> rejected")

	print("-- funded, in-range repair consumes the recipe and advances one stage per call --")
	for expected_stage: int in range(3):
		var cost: Dictionary = ship.call(&"current_repair_cost") as Dictionary
		_grant_cost(cost)
		ship.call(&"request_repair")
		check(int(ship.get("repair_stage")) == expected_stage + 1,
			"stage %d -> %d" % [expected_stage, expected_stage + 1])
		for item_id: StringName in cost.keys():
			check(int(inventory.call(&"host_count", NetConfig.HOST_PEER_ID, item_id)) == 0,
				"%s was fully consumed by the repair, none left over" % item_id)

	check(int(ship.get("repair_stage")) == 3, "the wreck reaches fully repaired")
	check(_repaired_events.size() == 1, "EventBus.emit_ship_repaired fired exactly once")

	print("-- a fully repaired ship rejects further repair requests --")
	ship.call(&"request_repair")
	check(int(ship.get("repair_stage")) == 3, "repair is a no-op once fully repaired")

	EVENT_BUS.unsubscribe_ship_repaired(_on_ship_repaired)
	player.remove_from_group(&"players")
	ship.queue_free()
	player.queue_free()


func _grant_cost(cost: Dictionary) -> void:
	for item_id: StringName in cost.keys():
		inventory.call(&"host_add", NetConfig.HOST_PEER_ID, item_id, int(cost[item_id]))


func _remove_cost(cost: Dictionary) -> void:
	for item_id: StringName in cost.keys():
		inventory.call(&"host_remove", NetConfig.HOST_PEER_ID, item_id, int(cost[item_id]))


func _check_departure_fsm() -> void:
	print("\n== board-to-leave / group confirm ==")
	EVENT_BUS.subscribe_run_extracted(_on_run_extracted)

	print("-- unreachable before the ship is repaired --")
	var unrepaired := EXTRACTION_SHIP_SCRIPT.new() as Node3D
	unrepaired.name = "CheckShipUnrepaired"
	root.add_child(unrepaired)
	unrepaired.global_position = Vector3(-100.0, 0.0, -100.0)
	var lone_player := Node3D.new()
	lone_player.name = "CheckLonePlayer"
	lone_player.add_to_group(&"players")
	lone_player.set_multiplayer_authority(1)
	root.add_child(lone_player)
	lone_player.global_position = unrepaired.global_position
	unrepaired.call(&"request_toggle_departure")
	check(not bool(unrepaired.get("departure_channeling")),
		"boarding before repair_stage reaches 3 is a no-op")
	lone_player.remove_from_group(&"players")
	lone_player.queue_free()
	unrepaired.queue_free()

	print("-- solo hold: toggle start/cancel, then completes and fires run_extracted --")
	var ship := EXTRACTION_SHIP_SCRIPT.new() as Node3D
	ship.name = "CheckShipDepartSolo"
	ship.set("repair_stage", 3)
	root.add_child(ship)
	ship.global_position = Vector3(-900.0, 0.0, -900.0)

	var player := Node3D.new()
	player.name = "CheckDepartPlayerSolo"
	player.add_to_group(&"players")
	player.set_multiplayer_authority(1)
	root.add_child(player)
	player.global_position = ship.global_position

	print("-- out of range is rejected --")
	player.global_position = ship.global_position + Vector3(500.0, 0.0, 0.0)
	ship.call(&"request_toggle_departure")
	check(not bool(ship.get("departure_channeling")),
		"a requester outside BOARD_RANGE_M cannot start the hold")
	player.global_position = ship.global_position

	ship.call(&"request_toggle_departure")
	check(bool(ship.get("departure_channeling")), "an in-range press starts the departure hold")
	check(int(ship.get("departure_required_players")) == 1, "one live player -> solo requirement")
	ship.call(&"request_toggle_departure")
	check(not bool(ship.get("departure_channeling")), "a second press cancels the hold")
	check(is_equal_approx(float(ship.get("departure_progress_sec")), 0.0),
		"cancelling forfeits progress rather than pausing it")

	ship.call(&"request_toggle_departure")
	ship.call(&"host_tick", 70.0)
	check(bool(ship.get("departed")), "a full-duration tick with the sole player present departs")
	check(not bool(ship.get("departure_channeling")), "departing ends the hold")
	check(_extracted_events.size() == 1, "EventBus.emit_run_extracted fired exactly once")
	ship.call(&"request_toggle_departure")
	check(bool(ship.get("departed")), "departed is terminal — no further toggle reopens it")
	player.remove_from_group(&"players")
	player.queue_free()
	ship.queue_free()

	print("-- co-op hold pauses under-presence, resumes once the whole crew is aboard --")
	var ship_coop := EXTRACTION_SHIP_SCRIPT.new() as Node3D
	ship_coop.name = "CheckShipDepartCoop"
	ship_coop.set("repair_stage", 3)
	root.add_child(ship_coop)
	ship_coop.global_position = Vector3(-1200.0, 0.0, -1200.0)

	var player_one := Node3D.new()
	player_one.name = "CheckDepartPlayerOne"
	player_one.add_to_group(&"players")
	player_one.set_multiplayer_authority(1)
	root.add_child(player_one)
	player_one.global_position = ship_coop.global_position

	var player_two := Node3D.new()
	player_two.name = "CheckDepartPlayerTwo"
	player_two.add_to_group(&"players")
	player_two.set_multiplayer_authority(2)
	root.add_child(player_two)
	player_two.global_position = ship_coop.global_position + Vector3(500.0, 0.0, 0.0)

	ship_coop.call(&"request_toggle_departure")
	check(int(ship_coop.get("departure_required_players")) == 2,
		"two live players this session -> both required")
	ship_coop.call(&"host_tick", 20.0)
	check(is_equal_approx(float(ship_coop.get("departure_progress_sec")), 0.0),
		"progress does not advance while one of two required players is missing")
	check(not bool(ship_coop.get("departed")), "not departed while under-presence")

	player_two.global_position = ship_coop.global_position
	ship_coop.call(&"host_tick", 70.0)
	check(bool(ship_coop.get("departed")), "progress resumes and finishes once the whole crew is aboard")

	EVENT_BUS.unsubscribe_run_extracted(_on_run_extracted)
	player_one.remove_from_group(&"players")
	player_two.remove_from_group(&"players")
	player_one.queue_free()
	player_two.queue_free()
	ship_coop.queue_free()


func _on_ship_repaired(_ship_name: StringName, _world_position: Vector3) -> void:
	_repaired_events.append(true)


func _on_run_extracted(cycle: int, _world_position: Vector3) -> void:
	_extracted_events.append(cycle)


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
