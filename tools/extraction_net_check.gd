extends SceneTree

## **Can two people actually finish a run?** Real two-process ENet proof of the extraction verb —
## the one that ends the run, and therefore the one whose client-side failure is unrecoverable: a
## party that cannot depart cannot finish, and no amount of playing better fixes it.
##
##   .agent/bin/agent godot --script tools/extraction_net_check.gd
##
## Why this check exists at all: `tools/extraction_check.gd` proves the departure FSM in ONE process,
## where the local player is trivially "present" and trivially "the whole session". Neither is true
## in co-op, and the two facts the whole verb rests on are both cross-process:
##
##   · `_start_departure()` snapshots `departure_required_players = _session_player_total()`
##   · `host_tick()` only advances while `_present_count(BOARD_RANGE_M) >= departure_required_players`
##
## So the host must be able to SEE the client's body standing on the ship. If a client's replicated
## position does not reach the host, or its body is not in the `players` group there, the hold sits
## at zero forever with no error anywhere — the run simply never ends. That is the exact shape of
## hard-lock a playtest cannot recover from, and nothing tested it before this file.
##
## Mirrors `chest_net_check.gd`'s driver/probe structure: the driver hosts and relaunches this same
## script as a client, both build an identical ship at an identical node path, and the client alone
## initiates.

const EXTRACTION_SHIP_SCRIPT := preload("res://systems/extraction/extraction_ship.gd")

const PORT: int = 47431
const RESULT_PATH: String = "user://extraction_net_client.json"
const SHIP_NAME: StringName = &"NetCheckShip"
const TIMEOUT_SEC: float = 20.0
## The ship sits at the origin and both players are moved onto it. Well inside BOARD_RANGE_M (7 m).
const SHIP_POSITION := Vector3.ZERO
const ON_DECK := Vector3(1.5, 0.0, 0.0)
## Far enough to be off deck by any reading of BOARD_RANGE_M.
const OFF_DECK := Vector3(40.0, 0.0, 0.0)

var failures: int = 0
var transport: Node
var player_net: Node
var ship: Node3D
var child_pid: int = 0


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	await process_frame
	transport = root.get_node_or_null(^"NetTransport")
	player_net = root.get_node_or_null(^"PlayerNet")
	if transport == null or player_net == null:
		fail("NetTransport and PlayerNet autoloads must exist")
		finish()
		return
	_build_ship()
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.is_empty() and args[0] == "extraction-probe":
		_run_client()
	else:
		_run_driver()


## Built identically on both peers, at the same path, so the synchroniser's NodePath resolves — the
## same construction `chest_net_check.gd` uses. `repair_stage` is set to REPAIR_STAGE_COUNT BEFORE
## add_child(), which is `extraction_check.gd`'s documented shortcut past the repair minigame: this
## check is about DEPARTURE, and making the client grind three repair stages first would only add
## ways for it to fail before reaching the thing under test.
func _build_ship() -> void:
	# A floor, built identically on both peers. Without one, both player bodies fall forever the
	# instant they spawn and drift out of BOARD_RANGE_M — which read as "present=0" and looked
	# exactly like a replication failure on the first run. The bare-scene harness has no terrain, so
	# the check has to supply the one thing the real world always has.
	var floor_body := StaticBody3D.new()
	floor_body.name = "NetCheckFloor"
	var floor_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200.0, 2.0, 200.0)
	floor_shape.shape = box
	floor_body.add_child(floor_shape)
	root.add_child(floor_body)
	floor_body.global_position = Vector3(0.0, -1.0, 0.0)

	ship = Node3D.new()
	ship.set_script(EXTRACTION_SHIP_SCRIPT)
	ship.name = SHIP_NAME
	ship.set(&"repair_stage", int(EXTRACTION_SHIP_SCRIPT.REPAIR_STAGE_COUNT))
	root.add_child(ship)
	ship.global_position = SHIP_POSITION


func _run_driver() -> void:
	print("\n== extraction network check — can two people finish a run? ==")
	if FileAccess.file_exists(RESULT_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(RESULT_PATH))
	var error: Error = transport.call("host", NetConfig.Mode.LOCAL, PORT)
	check(error == OK, "host starts on port %d" % PORT)
	if error != OK:
		finish()
		return

	child_pid = _spawn_client()
	check(child_pid > 0, "client process launches")

	var client_peer: int = -1
	var got_peer: bool = await _until(func() -> bool:
		for peer_id: int in transport.call("peer_ids") as PackedInt32Array:
			if peer_id != NetConfig.HOST_PEER_ID:
				return true
		return false, TIMEOUT_SEC)
	check(got_peer, "client connects to the host")
	if got_peer:
		for peer_id: int in transport.call("peer_ids") as PackedInt32Array:
			if peer_id != NetConfig.HOST_PEER_ID:
				client_peer = peer_id

	# Both bodies must exist on the HOST before anything about presence means anything.
	var both_spawned: bool = await _until(func() -> bool:
		return get_nodes_in_group(&"players").size() >= 2, TIMEOUT_SEC)
	check(both_spawned, "the host sees BOTH player bodies (%d)" %
		get_nodes_in_group(&"players").size())

	# Put the host's own player on deck. The client moves its own body — that is client-authoritative
	# movement (ARCHITECTURE §2.2 row 1) and the host must not do it for them, because doing so here
	# would fake the very replication this check exists to test.
	var host_player: Node3D = player_net.call("player_for", NetConfig.HOST_PEER_ID) as Node3D
	check(host_player != null, "the host has its own player body")
	if host_player != null:
		host_player.global_position = ON_DECK

	# First prove the host can see the client ABSENT. Without this, "present == 2" is satisfied by two
	# bodies that never moved off the origin the ship sits on, and the check would pass on a build
	# where position replication was entirely broken.
	var saw_client_leave: bool = await _until(func() -> bool:
		return int(ship.call(&"_present_count", EXTRACTION_SHIP_SCRIPT.BOARD_RANGE_M)) == 1,
		TIMEOUT_SEC)
	check(saw_client_leave,
		"the host sees the client LEAVE the deck (present=%d, expected 1) — proves this is reading " %
		int(ship.call(&"_present_count", EXTRACTION_SHIP_SCRIPT.BOARD_RANGE_M)) +
		"replicated position, not two bodies parked on the spawn point")

	# THE ASSERTION THIS FILE EXISTS FOR: the host can see the client standing on the ship.
	var client_on_deck: bool = await _until(func() -> bool:
		return int(ship.call(&"_present_count", EXTRACTION_SHIP_SCRIPT.BOARD_RANGE_M)) >= 2,
		TIMEOUT_SEC)
	check(client_on_deck,
		"the HOST counts the client as aboard once it walks on deck (present=%d of 2) — if this " % 
		int(ship.call(&"_present_count", EXTRACTION_SHIP_SCRIPT.BOARD_RANGE_M)) +
		"fails, the departure hold can never complete and the run cannot be finished")

	# The client initiates departure. A verb the client cannot START is as run-ending as one it
	# cannot finish.
	var channeling: bool = await _until(func() -> bool:
		return bool(ship.get(&"departure_channeling")), TIMEOUT_SEC)
	check(channeling, "the CLIENT can start the departure hold (host reports channeling)")
	check(int(ship.get(&"departure_required_players")) == 2,
		"the hold requires both players, not one (%d)" % int(ship.get(&"departure_required_players")))

	# Cross the hold. host_tick is public precisely so a check need not wait 60 real seconds.
	for step: int in 8:
		ship.call(&"host_tick", 10.0)
		await process_frame
	check(bool(ship.get(&"departed")), "the hold completes and the ship departs with both aboard")
	check(float(ship.get(&"departure_progress_sec")) >= 0.0, "progress is a real number, not NAN")

	# Waits for the client's TERMINAL write, not merely for a parseable file: the client writes its
	# progress several times, and the driver reaching the file first read an in-progress record and
	# reported every client assertion as failed. The marker is what makes the handshake ordered.
	var result: Dictionary = await _wait_for_result(func() -> bool: return true)
	print("EXTRACTION_NET_CHECK failures=%d result=%s" % [failures, JSON.stringify(result, "  ")])
	check(bool(result.get("connected", false)), "client reported a live session")
	check(bool(result.get("saw_channeling", false)),
		"the CLIENT sees the departure hold it started (replicated departure_channeling)")
	check(bool(result.get("saw_departed", false)),
		"the CLIENT sees the ship depart — without this the client's own run never ends")
	check(bool(result.get("run_extracted_fired", false)),
		"run_extracted fires on the CLIENT's own EventBus, which is what banks its Salvage")
	finish()


func _run_client() -> void:
	_write_result({"connected": false, "saw_channeling": false, "saw_departed": false,
		"run_extracted_fired": false})
	var error: Error = transport.call("join", NetConfig.Mode.LOCAL, NetConfig.LOOPBACK_ADDRESS, PORT)
	if error != OK:
		_write_result({"error": error_string(error)})
		finish()
		return
	_client_drive()


func _client_drive() -> void:
	var connected: bool = await _until(func() -> bool: return bool(transport.call("is_active")),
		TIMEOUT_SEC)
	if not connected:
		_write_result({"error": "connect timeout"})
		finish()
		return
	var peer_id: int = int(transport.call("local_peer_id"))
	# F-107: a GDScript lambda captures an outer local BY VALUE, so assigning `body` inside the
	# closure below updates only the closure's copy and the outer one stays null — which is exactly
	# how this check first crashed on `global_position` of a Nil. Re-fetch in the outer scope once
	# the wait says a body exists.
	var spawned: bool = await _until(func() -> bool:
		return player_net.call("player_for", peer_id) != null, TIMEOUT_SEC)
	if not spawned:
		_write_result({"error": "player spawn timeout"})
		finish()
		return
	var body: Node3D = player_net.call("player_for", peer_id) as Node3D
	if body == null:
		_write_result({"error": "player body vanished after spawn"})
		finish()
		return

	# The client's own EventBus, which is the half a host-only emit would never reach.
	var extracted: Array[bool] = [false]
	var bus := preload("res://core/events/event_bus.gd")
	var listener: Callable = func(_cycle: int, _position: Vector3) -> void: extracted[0] = true
	bus.subscribe_run_extracted(listener)

	# Start OFF deck and only then walk on. Both players spawn at the world origin, which is where
	# the ship is — so a check that never moves anyone proves nothing about replication, it just
	# observes two bodies that happened to start on top of the target. The host asserts it sees
	# exactly one player aboard before this moves, and two after.
	body.global_position = OFF_DECK
	await _until(func() -> bool: return false, 1.5)
	_write_result({"connected": true, "off_deck": true, "saw_channeling": false,
		"saw_departed": false, "run_extracted_fired": false})
	await _until(func() -> bool: return false, 1.5)
	body.global_position = ON_DECK

	# Give the host a moment to receive the position before asking it to start the hold; a request
	# that arrives before the body does is a legitimate refusal, not the bug under test.
	await _until(func() -> bool: return false, 1.5)
	ship.call(&"request_toggle_departure")

	var saw_channeling: bool = await _until(func() -> bool:
		return bool(ship.get(&"departure_channeling")), TIMEOUT_SEC)
	_write_result({"connected": true, "saw_channeling": saw_channeling, "saw_departed": false,
		"run_extracted_fired": false})

	var saw_departed: bool = await _until(func() -> bool: return bool(ship.get(&"departed")),
		TIMEOUT_SEC)
	# One more frame so the setter-driven EventBus emit lands before the result is written.
	await process_frame
	_write_result({
		"final": true,
		"connected": true,
		"saw_channeling": saw_channeling,
		"saw_departed": saw_departed,
		"run_extracted_fired": extracted[0],
	})
	bus.unsubscribe_run_extracted(listener)
	finish()


func _spawn_client() -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	var args := PackedStringArray([
		"--headless", "--path", project_dir, "--script", "tools/extraction_net_check.gd",
		"--", "extraction-probe",
	])
	return OS.create_process(OS.get_executable_path(), args)


## F-107 AGAIN, and worth naming because it bit this file twice: a GDScript lambda captures an outer
## local BY VALUE. Assigning `result` inside the closure below updates only the closure's copy, so
## the outer one stayed `{}` and every client assertion reported failed while the client's own file
## on disk said everything passed. The wait decides WHEN; the outer scope re-reads the file itself.
func _wait_for_result(done: Callable) -> Dictionary:
	var result: Dictionary = {}
	var arrived: bool = await _until(func() -> bool:
		if not FileAccess.file_exists(RESULT_PATH):
			return false
		var text: String = FileAccess.get_file_as_string(RESULT_PATH)
		var parsed: Variant = JSON.parse_string(text)
		return parsed is Dictionary and bool((parsed as Dictionary).get("final", false)) \
			and bool(done.call()), TIMEOUT_SEC * 2.0)
	if arrived and FileAccess.file_exists(RESULT_PATH):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(RESULT_PATH))
		if parsed is Dictionary:
			result = parsed
	return result


func _write_result(data: Dictionary) -> void:
	var file := FileAccess.open(RESULT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(data))
		file.close()


func _until(condition: Callable, seconds: float = TIMEOUT_SEC) -> bool:
	var waited: float = 0.0
	while waited < seconds:
		if bool(condition.call()):
			return true
		await process_frame
		waited += 1.0 / 60.0
	return bool(condition.call())


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func fail(description: String) -> void:
	check(false, description)


func finish() -> void:
	if child_pid > 0:
		OS.kill(child_pid)
	quit(0 if failures == 0 else 1)
