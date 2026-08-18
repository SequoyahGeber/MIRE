extends SceneTree

## Real two-process ENet proof for task 3.8's wire surface: a CLIENT's net_health_snapshot carries
## the new hunger/hunger_max fields, request_consume_item() round-trips over net_request_consume_item
## / net_consume_confirmed and actually removes the item from the client's own inventory, and a
## client's stamina reaches the host through net_report_local_stamina (advisory, unreliable — see
## player_health.gd's own note on why the host never gates on it).
##
## Two players, real PlayerController bodies via PlayerNet, same shape as
## tools/player_health_net_check.gd. The host (this driver process) grants itself the test ration and
## eats it locally (no RPC needed for the host's own request — trivial, not the interesting case);
## the CLIENT eating is the cross-peer proof, same reasoning player_health_net_check.gd gives for why
## the host downs ITSELF and the client is what has to learn about it.
##
## No food ItemDef is authored as real content — see tools/player_vitals_check.gd's own note. This
## check injects the identical synthetic ItemDef into Registry.items on BOTH processes (driver and
## client each run this same script, so both boot the same Registry autoload independently — nothing
## is shared over the wire except the item id).

const PORT: int = 47434
const RESULT_PATH: String = "user://player_vitals_net_client.json"
const DRIVER_SIGNAL_PATH: String = "user://player_vitals_net_driver.json"
const TIMEOUT_SEC: float = 15.0

const ITEM_DEF := preload("res://systems/inventory/item_def.gd")
const RATION_ID: StringName = &"test_ration"

var failures: int = 0
var transport: Node
var player_net: Node
var health: Node
var inventory: Node
var registry: Node
var child_pid: int = 0
var max_hp: int = 100
var max_hunger: float = 100.0


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	await process_frame
	transport = root.get_node_or_null(^"NetTransport")
	player_net = root.get_node_or_null(^"PlayerNet")
	health = root.get_node_or_null(^"PlayerHealth")
	inventory = root.get_node_or_null(^"InventoryService")
	registry = root.get_node_or_null(^"Registry")
	if transport == null or player_net == null or health == null or inventory == null or registry == null:
		fail("NetTransport, PlayerNet, PlayerHealth, InventoryService and Registry autoloads must exist")
		finish()
		return
	max_hp = int(health.get("max_hp"))
	max_hunger = float(health.get("max_hunger"))
	_inject_test_ration()

	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.is_empty() and args[0] == "player-vitals-probe":
		_run_client()
	else:
		_run_driver()


## Same synthetic CONSUMABLE both processes need — see the file doc. Each process injects its own
## copy into its own Registry; nothing about the item definition itself crosses the wire.
func _inject_test_ration() -> void:
	var food := ITEM_DEF.new()
	food.id = RATION_ID
	food.display_name = "Test Ration"
	food.category = ITEM_DEF.Category.CONSUMABLE
	food.hunger_restore = 40.0
	food.hp_restore = 15
	# .set() back explicitly — see tools/player_vitals_check.gd's own note on why a plain mutation of
	# what .get() returns can silently fail to reach a strictly-typed Dictionary property.
	var items: Dictionary = registry.get("items")
	items[food.id] = food
	registry.set("items", items)


func _run_driver() -> void:
	print("\n== player vitals network check (task 3.8) ==")
	for path: String in [RESULT_PATH, DRIVER_SIGNAL_PATH]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

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
	check(connected, "client connects and receives its authoritative snapshot")
	if not connected:
		finish()
		return
	var client_peer_id: int = int(_read_result().get("peer_id", 0))
	check(client_peer_id > NetConfig.HOST_PEER_ID, "client reports a real peer id")

	# ── Hunger rides the same snapshot as hp, over the real wire ────────────────────────────────────
	check(bool(health.call(&"host_apply_damage", client_peer_id, 25, 0)), "host damages the client")
	# Force an immediate publish rather than waiting out HUNGER_SNAPSHOT_INTERVAL_SEC — damage already
	# does that (see player_health.gd's _tick_hunger note), so this proves the discrete-event path.
	var saw_damage: bool = await _until(
		func() -> bool: return int(_read_result().get("hp", -1)) == max_hp - 25, TIMEOUT_SEC
	)
	check(saw_damage, "client's own net_health_snapshot carries the new hp AND arrives")

	# Live drain, not a hand-computed target: both processes are REAL running engines here (unlike
	# tools/player_vitals_check.gd's offline harness, physics_process is never disabled), so hunger is
	# already draining every real physics frame regardless of anything this script does. Proving the
	# wire carries a value that keeps dropping over real wall-clock time is the honest proof; a
	# formula predicting an exact number would drift with however long connect/spawn actually took.
	var hunger_baseline: float = float(_read_result().get("hunger", max_hunger))
	var saw_hunger_drop: bool = await _until(
		func() -> bool: return float(_read_result().get("hunger", hunger_baseline)) < hunger_baseline - 0.05,
		TIMEOUT_SEC
	)
	check(saw_hunger_drop,
		"client's net_health_snapshot ALSO carries a live-draining hunger field (%.3f -> %.3f)" % [
			hunger_baseline, float(_read_result().get("hunger", -1.0))
		])

	# ── Consume — the client requests, the host removes the item and applies the restore ────────────
	check(bool(inventory.call("host_add", client_peer_id, RATION_ID, 1)), "host grants the client one ration")
	var hp_before_eat: int = int(health.call(&"host_hp", client_peer_id))
	var hunger_before_eat: float = float(health.call(&"host_hunger", client_peer_id))

	_write_driver_signal({"go_eat": true})
	var ate: bool = await _until(
		func() -> bool: return bool(_read_result().get("consume_accepted", false)), TIMEOUT_SEC
	)
	check(ate, "client's request_consume_item() is accepted over the real RPC")
	check(int(inventory.call("host_count", client_peer_id, RATION_ID)) == 0,
		"the host's own inventory copy actually lost the item — not just a client-side illusion")
	check(int(health.call(&"host_hp", client_peer_id)) == mini(hp_before_eat + 15, max_hp),
		"host hp reflects hp_restore exactly (hp only ever changes on an explicit event, never drifts)")
	# hunger keeps draining in real time between the "before" read above and the request actually
	# landing, so this is a tolerance, not an exact match — 2.0 comfortably covers several seconds of
	# real elapsed time at the default drain rate while still proving the restore, not just noise.
	check(absf(
		float(health.call(&"host_hunger", client_peer_id)) - minf(hunger_before_eat + 40.0, max_hunger)
	) < 2.0, "host hunger reflects hunger_restore, within real-time drain tolerance")

	var unknown_rejected: bool = await _until(
		func() -> bool: return _read_result().has("unknown_item_rejected"), TIMEOUT_SEC
	)
	check(unknown_rejected and bool(_read_result().get("unknown_item_rejected", false)),
		"a second, unknown-item consume request is rejected over the same RPC")

	# ── Stamina — advisory report reaches the host, unreliable, never gates anything ────────────────
	var reported: bool = await _until(
		func() -> bool: return float(health.call(&"host_stamina", client_peer_id)) < float(health.get("max_stamina")) - 0.5,
		TIMEOUT_SEC
	)
	check(reported, "the client's net_report_local_stamina reaches the host's advisory copy")

	var child_exited: bool = await _until(
		func() -> bool: return child_pid <= 0 or not OS.is_process_running(child_pid), TIMEOUT_SEC
	)
	check(child_exited, "client exits cleanly")
	if child_exited:
		child_pid = 0
	transport.call("leave")
	print("PLAYER_VITALS_NET_CHECK client=%d failures=%d" % [client_peer_id, failures])
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
	var ready: bool = await _until(_client_health_ready, TIMEOUT_SEC)
	if not ready:
		_write_result({"error": "initial health snapshot timeout"})
		finish()
		return
	var peer_id: int = int(transport.call("local_peer_id"))
	_write_result({"connected": true, "peer_id": peer_id})

	health.connect(&"local_health_changed", func(hp: int, _max_hp: int, _state: int, _bo: float) -> void:
		_merge_result({"hp": hp})
	)
	health.connect(&"local_hunger_changed", func(hunger: float, _max_hunger: float) -> void:
		_merge_result({"hunger": hunger})
	)
	_merge_result({"hp": int(health.call(&"local_hp")), "hunger": float(health.call(&"local_hunger"))})

	# Drains stamina continuously so there is something real to report over net_report_local_stamina.
	# tools/player_vitals_check.gd's offline controller integration already proves
	# player_controller.gd calls local_tick_stamina() correctly; this check's own job is the RPC that
	# method triggers, so calling it directly here (rather than re-simulating sprint input) is enough.
	var stamina_ticker := func() -> void:
		while bool(transport.call("is_active")):
			health.call(&"local_tick_stamina", 1.0 / 30.0, true)
			await create_timer(1.0 / 30.0).timeout
	stamina_ticker.call()

	var go_eat: bool = await _until(
		func() -> bool: return bool(_read_driver_signal().get("go_eat", false)), TIMEOUT_SEC
	)
	if not go_eat:
		_merge_result({"error": "driver never signalled go_eat"})
		finish()
		return

	var confirmations: Dictionary[int, Dictionary] = {}
	var on_confirmed := func(request_id: int, accepted: bool, detail: String) -> void:
		confirmations[request_id] = {"accepted": accepted, "detail": detail}
	health.connect(&"consume_confirmed", on_confirmed)

	var eat_request: int = int(health.call(&"request_consume_item", RATION_ID))
	var eat_confirmed: bool = await _until(
		func() -> bool: return confirmations.has(eat_request), TIMEOUT_SEC
	)
	_merge_result({
		"consume_accepted": eat_confirmed and bool(confirmations[eat_request].get("accepted", false))
	})

	var unknown_request: int = int(health.call(&"request_consume_item", &"not_a_real_item"))
	var unknown_confirmed: bool = await _until(
		func() -> bool: return confirmations.has(unknown_request), TIMEOUT_SEC
	)
	_merge_result({
		"unknown_item_rejected": unknown_confirmed and not bool(confirmations[unknown_request].get("accepted", true))
	})
	health.disconnect(&"consume_confirmed", on_confirmed)

	await create_timer(3.0).timeout # give the ticker a few reconcile intervals to report
	transport.call("leave")
	finish()


## is_active() is the load-bearing check here, not the other two: an ENet client is handed its own
## unique id locally the instant create_client() succeeds (net_transport.gd's join(), well before
## the handshake completes), and PlayerHealth's own OFFLINE bootstrap already sets local_revision to
## 0 at boot, before this process ever calls join() at all — so local_peer_id() > HOST_PEER_ID and
## local_revision >= 0 can BOTH already be true while the connection is still CONNECTING. Found via
## this file's own stamina ticker starting on that false-positive and never actually running (see
## _client_drive()'s note).
func _client_health_ready() -> bool:
	return (
		bool(transport.call("is_active"))
		and int(transport.call("local_peer_id")) > NetConfig.HOST_PEER_ID
		and int(health.call("local_revision")) >= 0
	)


func _spawn_client() -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	var args := PackedStringArray([
		"--headless", "--path", project_dir, "--script", "tools/player_vitals_net_check.gd",
		"--", "player-vitals-probe",
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


func _merge_result(patch: Dictionary) -> void:
	var current: Dictionary = _read_result()
	for key: String in patch:
		current[key] = patch[key]
	_write_result(current)


func _read_result() -> Dictionary:
	if not FileAccess.file_exists(RESULT_PATH):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(RESULT_PATH))
	return parsed if parsed is Dictionary else {}


func _write_driver_signal(result: Dictionary) -> void:
	var file := FileAccess.open(DRIVER_SIGNAL_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(result))
	file.close()


func _read_driver_signal() -> Dictionary:
	if not FileAccess.file_exists(DRIVER_SIGNAL_PATH):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(DRIVER_SIGNAL_PATH))
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
	if transport != null and bool(transport.call("is_active")):
		transport.call("leave")
	quit(0 if failures == 0 else 1)
