extends SceneTree

## **Does the client keep anything?** Two-process proof of the between-run path: Salvage banking and
## Unlock purchase, on a peer that is NOT the host.
##
##   .agent/bin/agent godot --script tools/progression_net_check.gd
##
## This is the only failure mode on the co-op list that DESTROYS something. A respawn bug is visible
## while you are sitting there; a persistence bug is invisible during the session and unrecoverable
## after it — you find out because the second session is inexplicably identical to the first, and by
## then the data is gone.
##
## Both services are documented as authority NONE: per-player account state in that peer's own
## `user://`, reacting only to events on its OWN process-local `EventBus`. That design is why this
## needs testing rather than why it doesn't — it means a client banks **only** if `run_extracted`
## genuinely reaches its own bus, and nothing else will notice if it doesn't.
##
## So the extraction here is REAL, not synthetic: a live `ExtractionShip`, the client initiating the
## departure hold, the host ticking it out. Emitting `run_extracted` by hand would test the banking
## arithmetic while assuming away the exact link that can break.
##
## Both peers override `save_path` to their own throwaway file. That is not only hygiene — two
## processes on one machine share a `user://` directory, so without it the two peers would write the
## same save and the check would be measuring a collision it invented. It also opts persistence back
## in: both services disable disk writes when `current_scene` is null (D-107, after a check banked
## 116 real Salvage into a developer's actual save).

const EXTRACTION_SHIP_SCRIPT := preload("res://systems/extraction/extraction_ship.gd")

const PORT: int = 47435
const RESULT_PATH: String = "user://progression_net_client.json"
const HOST_SALVAGE_PATH: String = "user://progression_net_host_salvage.json"
const CLIENT_SALVAGE_PATH: String = "user://progression_net_client_salvage.json"
const HOST_UNLOCK_PATH: String = "user://progression_net_host_unlocks.json"
const CLIENT_UNLOCK_PATH: String = "user://progression_net_client_unlocks.json"
const SHIP_NAME: StringName = &"ProgressionNetShip"
const TIMEOUT_SEC: float = 25.0
const ON_DECK := Vector3(1.5, 0.0, 0.0)
## The cheapest authored unlock, so the banked reward from one extraction can plausibly cover it.
const CHEAP_UNLOCK: StringName = &"unlock_loping_gait"
## Comfortably more than one extraction pays, so the "cannot afford" branch is real rather than
## dependent on tuning.
const EXPENSIVE_UNLOCK: StringName = &"unlock_cauter_seal"
## Enough for the cheap unlock and not the expensive one, so both branches are real.
const STARTING_BALANCE_FOR_PURCHASE: int = 200

var failures: int = 0
var transport: Node
var player_net: Node
var salvage: Node
var unlocks: Node
var ship: Node3D
var child_pid: int = 0
var is_client: bool = false


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	await process_frame
	transport = root.get_node_or_null(^"NetTransport")
	player_net = root.get_node_or_null(^"PlayerNet")
	salvage = root.get_node_or_null(^"SalvageService")
	unlocks = root.get_node_or_null(^"UnlockService")
	if transport == null or player_net == null or salvage == null or unlocks == null:
		fail("NetTransport, PlayerNet, SalvageService and UnlockService autoloads must exist")
		finish()
		return
	var args: PackedStringArray = OS.get_cmdline_user_args()
	is_client = not args.is_empty() and args[0] == "progression-probe"
	_isolate_saves()
	_build_world()
	if is_client:
		_run_client()
	else:
		_run_driver()


## Each peer to its own file, and freshly emptied, so a rerun cannot pass on the previous run's
## balance. See the header for why sharing `user://` matters here.
func _isolate_saves() -> void:
	salvage.set(&"save_path", CLIENT_SALVAGE_PATH if is_client else HOST_SALVAGE_PATH)
	unlocks.set(&"save_path", CLIENT_UNLOCK_PATH if is_client else HOST_UNLOCK_PATH)
	for path: String in [salvage.get(&"save_path"), unlocks.get(&"save_path")]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	# Re-read from the now-empty files so the in-memory caches match disk. This is not tidiness:
	# `SalvageService` loads its balance into `_total_salvage_cache` during `_ready()`, which happens
	# BEFORE this override, so without resetting it the service reports the developer's REAL balance
	# from memory while `spend_salvage()` reads the new, empty file from disk. The first run of this
	# check showed 4323 Salvage and refused every purchase for insufficient funds, which is exactly
	# that split — and it would have made "the client banked" pass while nothing was banked at all.
	salvage.set(&"_total_salvage_cache", 0)
	if unlocks.has_method(&"_load"):
		unlocks.call(&"_load")
	check(int(salvage.call(&"total_salvage")) == 0,
		"this peer starts from an empty, isolated save (%d)" % int(salvage.call(&"total_salvage")))


func _build_world() -> void:
	var floor_body := StaticBody3D.new()
	floor_body.name = "NetCheckFloor"
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200.0, 2.0, 200.0)
	shape.shape = box
	floor_body.add_child(shape)
	root.add_child(floor_body)
	floor_body.global_position = Vector3(0.0, -1.0, 0.0)

	ship = Node3D.new()
	ship.set_script(EXTRACTION_SHIP_SCRIPT)
	ship.name = SHIP_NAME
	ship.set(&"repair_stage", int(EXTRACTION_SHIP_SCRIPT.REPAIR_STAGE_COUNT))
	root.add_child(ship)
	ship.global_position = Vector3.ZERO


func _run_driver() -> void:
	print("\n== progression network check — does the CLIENT keep anything? ==")
	if FileAccess.file_exists(RESULT_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(RESULT_PATH))
	var error: Error = transport.call("host", NetConfig.Mode.LOCAL, PORT)
	check(error == OK, "host starts on port %d" % PORT)
	if error != OK:
		finish()
		return
	child_pid = _spawn_client()
	check(child_pid > 0, "client process launches")

	var got_peer: bool = await _until(func() -> bool:
		for peer_id: int in transport.call("peer_ids") as PackedInt32Array:
			if peer_id != NetConfig.HOST_PEER_ID:
				return true
		return false, TIMEOUT_SEC)
	check(got_peer, "client connects to the host")
	var both: bool = await _until(func() -> bool:
		return get_nodes_in_group(&"players").size() >= 2, TIMEOUT_SEC)
	check(both, "the host sees both player bodies")

	var host_player: Node3D = player_net.call("player_for", NetConfig.HOST_PEER_ID) as Node3D
	if host_player != null:
		host_player.global_position = ON_DECK

	var aboard: bool = await _until(func() -> bool:
		return int(ship.call(&"_present_count", EXTRACTION_SHIP_SCRIPT.BOARD_RANGE_M)) >= 2,
		TIMEOUT_SEC)
	check(aboard, "both players are aboard")

	var channeling: bool = await _until(func() -> bool:
		return bool(ship.get(&"departure_channeling")), TIMEOUT_SEC)
	check(channeling, "the client starts the departure hold")
	for step: int in 12:
		ship.call(&"host_tick", 10.0)
		await process_frame
	check(bool(ship.get(&"departed")),
		"the run really extracts (not a synthetic event) — progress %.1f/%d, present %d, required %d" % [
			float(ship.get(&"departure_progress_sec")),
			int(EXTRACTION_SHIP_SCRIPT.DEPARTURE_HOLD_SEC),
			int(ship.call(&"_present_count", EXTRACTION_SHIP_SCRIPT.BOARD_RANGE_M)),
			int(ship.get(&"departure_required_players")),
		])

	# The host's own banking is the control: if the host banked and the client did not, the bug is
	# the event reaching one bus and not the other, which is precisely the case D-107 reworked
	# `departed`'s setter for.
	var host_banked: bool = await _until(func() -> bool:
		return int(salvage.call(&"total_salvage")) > 0, TIMEOUT_SEC)
	check(host_banked, "the HOST banked its own Salvage (%d)" % int(salvage.call(&"total_salvage")))

	var result: Dictionary = await _wait_for_result()
	print("PROGRESSION_NET_CHECK failures=%d result=%s" % [failures, JSON.stringify(result, "  ")])

	check(bool(result.get("banked", false)),
		"the CLIENT banked its own Salvage after the extraction (%d)" % int(result.get("total", 0)))
	check(int(result.get("total", 0)) > 0, "the client's balance is non-zero")
	check(bool(result.get("persisted_to_disk", false)),
		"the client's balance survives a reload from ITS OWN save file — the whole point")
	check(bool(result.get("purchase_accepted", false)),
		"the CLIENT can purchase an unlock")
	check(bool(result.get("deducted", false)),
		"the purchase DEDUCTED from the client's own balance (%d -> %d)" %
		[int(result.get("balance_before_purchase", 0)), int(result.get("total_after_purchase", 0))])
	check(bool(result.get("double_buy_refused", false)),
		"buying the same unlock twice is refused — no double spend, no lost balance")
	check(bool(result.get("unaffordable_refused", false)),
		"an unlock the client cannot afford is refused")
	check(bool(result.get("unlock_persisted", false)),
		"the purchased unlock survives a reload on the client")
	finish()


func _run_client() -> void:
	_write_result({"banked": false})
	var error: Error = transport.call("join", NetConfig.Mode.LOCAL, NetConfig.LOOPBACK_ADDRESS, PORT)
	if error != OK:
		_write_result({"final": true, "error": error_string(error)})
		finish()
		return
	_client_drive()


func _client_drive() -> void:
	var connected: bool = await _until(func() -> bool: return bool(transport.call("is_active")),
		TIMEOUT_SEC)
	if not connected:
		_write_result({"final": true, "error": "connect timeout"})
		finish()
		return
	var peer_id: int = int(transport.call("local_peer_id"))
	# F-107: the closure cannot hand the body back, so re-fetch outside it.
	var spawned: bool = await _until(func() -> bool:
		return player_net.call("player_for", peer_id) != null, TIMEOUT_SEC)
	var body: Node3D = player_net.call("player_for", peer_id) as Node3D
	if not spawned or body == null:
		_write_result({"final": true, "error": "player spawn timeout"})
		finish()
		return

	body.global_position = ON_DECK
	await _until(func() -> bool: return false, 1.5)
	ship.call(&"request_toggle_departure")

	# Banking is driven by `run_extracted` on THIS process's own EventBus, fired from `departed`'s
	# setter when the replicated value lands. Waiting on the balance rather than on the event proves
	# the whole chain, not just that a signal fired.
	var banked: bool = await _until(func() -> bool:
		return int(salvage.call(&"total_salvage")) > 0, TIMEOUT_SEC)
	var total: int = int(salvage.call(&"total_salvage"))
	var earned: int = total

	# Persistence, read back from disk rather than from the cache the service is holding — a balance
	# that only exists in memory is exactly the loss this check is about.
	var on_disk: int = _salvage_on_disk()

	# Top the client's OWN save up to a known balance before testing the purchase path. Measured on
	# the first run: one extraction at cycle 1 banks 10 Salvage and the cheapest authored unlock costs
	# 75, so the purchase was correctly refused for insufficient funds — the code was right and the
	# check was wrong. Where the balance came from is irrelevant to the three questions actually under
	# test (can a client buy, does it deduct, does it persist), and writing the file is the honest way
	# to set it because `spend_salvage()` reads the balance from DISK rather than from the cache.
	var topped_up: int = STARTING_BALANCE_FOR_PURCHASE
	var save_file := FileAccess.open(String(salvage.get(&"save_path")), FileAccess.WRITE)
	if save_file != null:
		save_file.store_string(JSON.stringify({"total_salvage": topped_up}))
		save_file.close()
	salvage.set(&"_total_salvage_cache", topped_up)

	var purchase_accepted: bool = bool(unlocks.call(&"purchase", CHEAP_UNLOCK))
	var total_after: int = int(salvage.call(&"total_salvage"))
	var double_buy: bool = bool(unlocks.call(&"purchase", CHEAP_UNLOCK))
	var balance_after_double: int = int(salvage.call(&"total_salvage"))
	var unaffordable: bool = bool(unlocks.call(&"purchase", EXPENSIVE_UNLOCK))

	# Reload from disk and confirm the unlock is still there.
	unlocks.call(&"_load")
	var still_purchased: bool = bool(unlocks.call(&"is_purchased", CHEAP_UNLOCK))

	_write_result({
		"final": true,
		"banked": banked,
		"total": total,
		"persisted_to_disk": on_disk == total and total > 0,
		"purchase_accepted": purchase_accepted,
		"total_after_purchase": total_after,
		"earned": earned,
		"balance_before_purchase": topped_up,
		"deducted": purchase_accepted and total_after < topped_up,
		# Refused AND the balance untouched: a refusal that still spent would be the worst of the
		# three outcomes and the easiest to miss.
		"double_buy_refused": not double_buy and balance_after_double == total_after,
		"unaffordable_refused": not unaffordable,
		"unlock_persisted": still_purchased,
	})
	finish()


func _salvage_on_disk() -> int:
	var path: String = String(salvage.get(&"save_path"))
	if not FileAccess.file_exists(path):
		return -1
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if parsed is Dictionary:
		return int((parsed as Dictionary).get("total_salvage", -1))
	return -1


func _read_result() -> Dictionary:
	if not FileAccess.file_exists(RESULT_PATH):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(RESULT_PATH))
	return parsed as Dictionary if parsed is Dictionary else {}


func _wait_for_result() -> Dictionary:
	await _until(func() -> bool: return bool(_read_result().get("final", false)), TIMEOUT_SEC * 2.0)
	return _read_result()


func _spawn_client() -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	return OS.create_process(OS.get_executable_path(), PackedStringArray([
		"--headless", "--path", project_dir, "--script", "tools/progression_net_check.gd",
		"--", "progression-probe",
	]))


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
