extends SceneTree

## Real two-process ENet proof for tasks 2.6 and 2.7. A client submits only a recipe id; the host
## derives its peer/player, validates workbench range, atomically spends ingredients, and confirms
## the result. 2.7 drives that request through the client's own CraftingUI button, so the panel's
## waiting/confirmed states and its requirement counts are proven against a genuinely remote host
## rather than a same-process one that answers before the call returns.

const PORT: int = 47426
const RESULT_PATH: String = "user://crafting_net_client.json"
const TIMEOUT_SEC: float = 15.0

var failures: int = 0
var transport: Node
var player_net: Node
var inventory: Node
var crafting: Node
var crafting_ui: Node
var child_pid: int = 0
var confirmations: Dictionary[int, Dictionary] = {}


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	await process_frame
	transport = root.get_node_or_null(^"NetTransport")
	player_net = root.get_node_or_null(^"PlayerNet")
	inventory = root.get_node_or_null(^"InventoryService")
	crafting = root.get_node_or_null(^"CraftingService")
	crafting_ui = root.get_node_or_null(^"CraftingUI")
	if (
		transport == null
		or player_net == null
		or inventory == null
		or crafting == null
		or crafting_ui == null
	):
		fail("NetTransport, PlayerNet, InventoryService, CraftingService and CraftingUI must exist")
		finish()
		return
	crafting.get("craft_confirmed").connect(_on_craft_confirmed)
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.is_empty() and args[0] == "crafting-probe":
		_run_client()
	else:
		_run_driver()


func _run_driver() -> void:
	print("\n== crafting network check (task 2.6) ==")
	if FileAccess.file_exists(RESULT_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(RESULT_PATH))
	var workbench := Node3D.new()
	workbench.name = "NetworkCheckWorkbench"
	workbench.set_meta(&"asset", "station_workbench_primitive")
	workbench.add_to_group(&"playtest_hollow_asset")
	root.add_child(workbench)
	# Task 3.1: co-located with the workbench so a single client player position is in range of
	# both; request_craft() targets a specific recipe id, so which station is "nearest" for UI
	# purposes never enters into this proof.
	var furnace := Node3D.new()
	furnace.name = "NetworkCheckFurnace"
	furnace.set_meta(&"asset", "station_stone_furnace")
	furnace.add_to_group(&"playtest_hollow_asset")
	root.add_child(furnace)

	var error: Error = transport.call("host", NetConfig.Mode.LOCAL, PORT)
	check(error == OK, "host starts on port %d" % PORT)
	if error != OK:
		finish()
		return
	await process_frame
	child_pid = _spawn_client()
	check(child_pid > 0, "client process launches")
	var connected: bool = await _until(
		func() -> bool: return bool(_read_result().get("connected", false)), TIMEOUT_SEC
	)
	check(connected, "client receives its initial authoritative inventory")
	if not connected:
		finish()
		return
	var peer_id: int = int(_read_result().get("peer_id", 0))
	check(peer_id > NetConfig.HOST_PEER_ID, "client reports a real peer id")
	check(player_net.call("player_for", peer_id) != null,
		"host owns the requesting client's player")

	check(bool(inventory.call("host_add", peer_id, &"log", 2)), "host grants client recipe logs")
	check(bool(inventory.call("host_add", peer_id, &"stone", 3)), "host grants client recipe stone")
	var granted: bool = await _until(
		func() -> bool: return bool(_read_result().get("granted", false)), TIMEOUT_SEC
	)
	check(granted, "client receives both authoritative ingredients")

	var complete: bool = await _until(
		func() -> bool: return bool(_read_result().get("complete", false)), TIMEOUT_SEC
	)
	check(complete, "client completes accepted and rejected craft requests")
	var result: Dictionary = _read_result()
	check(bool(result.get("craft_accepted", false)), "client receives accepted craft confirmation")
	check(bool(result.get("repeat_rejected", false)), "client receives rejected repeat confirmation")
	check(int(result.get("axe_count", -1)) == 1, "client snapshot contains one crafted stone axe")
	check(int(result.get("log_count", -1)) == 0, "client snapshot spent its logs")
	check(int(result.get("stone_count", -1)) == 0, "client snapshot spent its stone")
	check(int(inventory.call("host_count", peer_id, &"stone_axe")) == 1,
		"host owns the crafted output")
	check(int(inventory.call("host_count", peer_id, &"log")) == 0,
		"host owns the spent log count")
	check(int(inventory.call("host_count", peer_id, &"stone")) == 0,
		"host owns the spent stone count")
	check(int(inventory.call("host_count", NetConfig.HOST_PEER_ID, &"stone_axe")) == 0,
		"client craft does not leak output to host inventory")

	check(bool(result.get("ui_in_range", false)), "client panel sees its own workbench")
	check(bool(result.get("ui_craftable_before", false)),
		"client panel enables the recipe from the host's granted ingredients")
	check(String(result.get("ui_requirements_before", "")) == "2/2 Log  ·  3/3 Stone",
		"client panel counts requirements from the replicated snapshot")
	check(String(result.get("ui_waiting_status", "")).contains("Waiting for the host"),
		"client panel waits for a remote answer instead of predicting one")
	check(String(result.get("ui_confirmed_status", "")).contains("crafted"),
		"client panel shows the host's acceptance")
	check(String(result.get("ui_requirements_after", "")) == "0/2 Log  ·  0/3 Stone",
		"client panel spends requirements only on the host's snapshot")
	check(not bool(result.get("ui_craftable_after", true)),
		"client panel disables the spent recipe")
	check(String(result.get("ui_rejected_status", "")).contains("missing ingredients"),
		"client panel shows the host's rejection verbatim")

	# --- Task 3.1: the furnace's timed craft, resolved by the HOST's own timer and confirmed to a
	# genuinely remote peer through the same net_craft_confirmed RPC as the instant path. ---
	check(bool(inventory.call("host_add", peer_id, &"iron_ore", 2)), "host grants client iron ore")
	var furnace_granted: bool = await _until(
		func() -> bool: return bool(_read_result().get("furnace_granted", false)), TIMEOUT_SEC
	)
	check(furnace_granted, "client receives its authoritative iron ore")
	var furnace_complete: bool = await _until(
		func() -> bool: return bool(_read_result().get("furnace_complete", false)), TIMEOUT_SEC
	)
	check(furnace_complete, "client's timed furnace craft resolves")
	var furnace_result: Dictionary = _read_result()
	check(bool(furnace_result.get("furnace_accepted", false)), "remote timed craft is accepted")
	check(bool(furnace_result.get("furnace_progress_seen", false)),
		"remote client observes craft_progress rising before its confirmation arrives")
	check(int(furnace_result.get("ingot_count", -1)) == 1, "client snapshot contains one iron ingot")
	check(int(inventory.call("host_count", peer_id, &"iron_ingot")) == 1,
		"host owns the crafted iron ingot")
	check(int(inventory.call("host_count", NetConfig.HOST_PEER_ID, &"iron_ingot")) == 0,
		"remote furnace craft does not leak output to host inventory")

	var child_exited: bool = await _until(
		func() -> bool: return child_pid <= 0 or not OS.is_process_running(child_pid), TIMEOUT_SEC
	)
	check(child_exited, "client exits cleanly")
	if child_exited:
		child_pid = 0
	# D-035 (F-052): parked, not released — same rewrite as inventory_net_check. The crafted axe
	# must SURVIVE the departure; emptying here is the bug F-032 fixed.
	var session: Node = root.get_node_or_null(^"NetSession")
	var parked: bool = await _until(
		func() -> bool: return (not (inventory.call("host_slots", peer_id) as Array).is_empty()
			and session != null and int(session.call("orphaned_run_players")) == 1),
		TIMEOUT_SEC
	)
	check(parked, "host parks the departed client's crafted inventory for the D-035 grace window")
	transport.call("leave")
	print("CRAFTING_NET_CHECK peer=%d axe_count=%d failures=%d result=%s" % [
		peer_id, int(result.get("axe_count", -1)), failures, result
	])
	finish()


func _run_client() -> void:
	_write_result({"connected": false})
	var error: Error = transport.call(
		"join", NetConfig.Mode.LOCAL, NetConfig.LOOPBACK_ADDRESS, PORT
	)
	if error != OK:
		_write_result({"error": error_string(error)})
		finish()
		return
	_client_drive()


func _client_drive() -> void:
	var ready: bool = await _until(_client_inventory_ready, TIMEOUT_SEC)
	if not ready:
		_write_result({"error": "initial inventory snapshot timeout"})
		finish()
		return
	var peer_id: int = int(transport.call("local_peer_id"))
	_write_result({"connected": true, "peer_id": peer_id, "granted": false, "complete": false})
	var ingredients_seen: bool = await _until(
		func() -> bool:
			return (
				int(inventory.call("local_count", &"log")) == 2
				and int(inventory.call("local_count", &"stone")) == 3
			),
		TIMEOUT_SEC
	)
	if not ingredients_seen:
		_write_result({"connected": true, "peer_id": peer_id, "error": "ingredient timeout"})
		finish()
		return
	_write_result({"connected": true, "peer_id": peer_id, "granted": true, "complete": false})
	await create_timer(0.25).timeout

	# The client's own workbench sits on its own replicated player, so its panel presents the same
	# proximity the host will independently revalidate.
	# GDScript lambdas capture locals by value, so the poll must not try to assign one.
	var player_spawned: bool = await _until(
		func() -> bool: return _local_player() != null, TIMEOUT_SEC
	)
	var local_player: Node3D = _local_player()
	if not player_spawned or local_player == null:
		_write_result({"connected": true, "peer_id": peer_id, "error": "no replicated local player"})
		finish()
		return
	var workbench := Node3D.new()
	workbench.name = "ClientCheckWorkbench"
	# Add to the tree BEFORE reading/writing global transforms (F-052 cleanup): the read of
	# local_player.global_position on a node mid-spawn logged one engine ERROR per run.
	root.add_child(workbench)
	if local_player.is_inside_tree():
		workbench.global_position = local_player.global_position
	workbench.set_meta(&"asset", "station_workbench_primitive")
	workbench.add_to_group(&"playtest_hollow_asset")
	crafting_ui.call("poll_station")

	var ui_in_range: bool = bool(crafting_ui.call("is_station_in_range"))
	var ui_craftable_before: bool = bool(crafting_ui.call("is_recipe_craftable", 0))
	var ui_requirements_before: String = String(crafting_ui.call("recipe_requirement_text", 0))

	var craft_id: int = int(crafting_ui.call("request_craft_at", 0))
	# Captured before any answer can have arrived: a remote host cannot confirm inside the call.
	var ui_waiting_status: String = String(crafting_ui.call("status_text"))
	var craft_confirmed: bool = await _until(
		func() -> bool: return confirmations.has(craft_id), TIMEOUT_SEC
	)
	var craft_accepted: bool = (
		craft_confirmed and bool((confirmations.get(craft_id, {}) as Dictionary).get("accepted", false))
	)
	var craft_applied: bool = await _until(
		func() -> bool:
			return (
				int(inventory.call("local_count", &"stone_axe")) == 1
				and int(inventory.call("local_count", &"log")) == 0
				and int(inventory.call("local_count", &"stone")) == 0
			),
		TIMEOUT_SEC
	)

	var ui_confirmed_status: String = String(crafting_ui.call("status_text"))
	var ui_requirements_after: String = String(crafting_ui.call("recipe_requirement_text", 0))
	var ui_craftable_after: bool = bool(crafting_ui.call("is_recipe_craftable", 0))

	var repeat_id: int = int(crafting_ui.call("request_craft_at", 0))
	var repeat_confirmed: bool = await _until(
		func() -> bool: return confirmations.has(repeat_id), TIMEOUT_SEC
	)
	var repeat_rejected: bool = (
		repeat_confirmed
		and not bool((confirmations.get(repeat_id, {}) as Dictionary).get("accepted", true))
	)
	_write_result({
		"connected": true,
		"peer_id": peer_id,
		"granted": true,
		"complete": craft_applied and repeat_confirmed,
		"craft_accepted": craft_accepted,
		"repeat_rejected": repeat_rejected,
		"axe_count": int(inventory.call("local_count", &"stone_axe")),
		"log_count": int(inventory.call("local_count", &"log")),
		"stone_count": int(inventory.call("local_count", &"stone")),
		"ui_in_range": ui_in_range,
		"ui_craftable_before": ui_craftable_before,
		"ui_craftable_after": ui_craftable_after,
		"ui_requirements_before": ui_requirements_before,
		"ui_requirements_after": ui_requirements_after,
		"ui_waiting_status": ui_waiting_status,
		"ui_confirmed_status": ui_confirmed_status,
		"ui_rejected_status": String(crafting_ui.call("status_text")),
	})

	# --- Task 3.1: the furnace's timed craft over a genuinely remote connection, run AFTER the axe
	# phase's result is already on disk — the driver's "complete" wait above must resolve on the axe
	# fields alone, since it is what unblocks the driver into granting furnace ore in the first place.
	var ore_seen: bool = await _until(
		func() -> bool: return int(inventory.call("local_count", &"iron_ore")) == 2, TIMEOUT_SEC
	)
	var furnace_progress_seen: bool = false
	var furnace_accepted: bool = false
	var furnace_complete: bool = false
	if ore_seen:
		var furnace_id: int = int(crafting.call("request_craft", &"iron_ingot"))
		furnace_progress_seen = await _until(
			func() -> bool: return float(crafting.call("craft_progress", furnace_id)) > 0.0, TIMEOUT_SEC
		)
		var furnace_confirmed: bool = await _until(
			func() -> bool: return confirmations.has(furnace_id), TIMEOUT_SEC
		)
		furnace_accepted = (
			furnace_confirmed
			and bool((confirmations.get(furnace_id, {}) as Dictionary).get("accepted", false))
		)
		furnace_complete = await _until(
			func() -> bool: return int(inventory.call("local_count", &"iron_ingot")) == 1, TIMEOUT_SEC
		)
	_write_result({
		"furnace_granted": ore_seen,
		"furnace_complete": furnace_complete,
		"furnace_accepted": furnace_accepted,
		"furnace_progress_seen": furnace_progress_seen,
		"ingot_count": int(inventory.call("local_count", &"iron_ingot")),
	})

	await create_timer(1.0).timeout
	finish()


func _on_craft_confirmed(request_id: int, accepted: bool, detail: String) -> void:
	confirmations[request_id] = {"accepted": accepted, "detail": detail}


func _local_player() -> Node3D:
	for node: Node in root.get_tree().get_nodes_in_group(&"players"):
		var player := node as Node3D
		if player != null and player.is_multiplayer_authority():
			return player
	return null


## F-060: gate on is_active() directly. local_peer_id() > HOST_PEER_ID and local_revision >= 0 can
## both already read true while the connection is still CONNECTING, not CONNECTED — ENet hands a
## client its own unique id locally before the host<->client handshake completes.
func _client_inventory_ready() -> bool:
	return (
		bool(transport.call("is_active"))
		and int(transport.call("local_peer_id")) > NetConfig.HOST_PEER_ID
		and int(inventory.call("local_revision")) >= 0
	)


func _spawn_client() -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	var args := PackedStringArray([
		"--headless", "--path", project_dir, "--script", "tools/crafting_net_check.gd",
		"--", "crafting-probe",
	])
	return OS.create_process(OS.get_executable_path(), args)


func _until(condition: Callable, timeout_seconds: float) -> bool:
	var deadline_msec: int = Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline_msec:
		if bool(condition.call()):
			return true
		await create_timer(0.05).timeout
	return bool(condition.call())


func _write_result(result: Dictionary) -> void:
	var file := FileAccess.open(RESULT_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(result))
	file.close()


func _read_result() -> Dictionary:
	if not FileAccess.file_exists(RESULT_PATH):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(RESULT_PATH))
	return parsed if parsed is Dictionary else {}


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	fail(description)


func fail(description: String) -> void:
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	if child_pid > 0 and OS.is_process_running(child_pid):
		OS.kill(child_pid)
		child_pid = 0
	if transport != null and bool(transport.call("is_active")):
		transport.call("leave")
	quit(0 if failures == 0 else 1)
