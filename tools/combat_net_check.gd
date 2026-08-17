extends SceneTree

## Real two-process ENet proof for task 2.8. A client sends only a hotbar slot index; the host reads
## its OWN authoritative inventory for that slot, resolves the hitbox against its own copy of the
## world, applies the damage, and broadcasts the connect. The client renders the consequences and
## decides none of them.

const PORT: int = 47427
const RESULT_PATH: String = "user://combat_net_client.json"
const TIMEOUT_SEC: float = 15.0
## The client runs two full swings plus a rejection round trip, so the driver's wait for its final
## result has to outlast the sum of the client's own waits, not one of them.
const CLIENT_COMPLETE_TIMEOUT_SEC: float = 60.0

var failures: int = 0
var transport: Node
var player_net: Node
var inventory: Node
var combat: Node
var child_pid: int = 0
var landed: Array[Dictionary] = []
var rejections: Array[Dictionary] = []
var target: Node3D


## Host-side damage seam stand-in, same contract Harvestable and 2.10's enemies implement.
class TestTarget extends Node3D:
	var damage_taken: int = 0
	var last_peer_id: int = -1
	var hit_count: int = 0
	## The host's copy of the attacker. This harness spawns players into an empty root with no floor,
	## so they fall the whole time; pinning the target two metres along the player's forward keeps the
	## test about the arc and the authority path rather than about gravity.
	var follow: Node3D

	func _ready() -> void:
		add_to_group(&"damageable")

	func _process(_delta: float) -> void:
		# is_inside_tree too (F-052 cleanup): after the peer despawns, its body is valid-but-removed
		# for a frame or two, and reading global_transform then logs an engine ERROR per frame.
		if follow != null and is_instance_valid(follow) and follow.is_inside_tree():
			global_position = follow.global_position + follow.global_transform.basis.z * -2.0

	func host_apply_damage(amount: int, instigator_peer_id: int) -> bool:
		damage_taken += amount
		last_peer_id = instigator_peer_id
		hit_count += 1
		return true


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	await process_frame
	transport = root.get_node_or_null(^"NetTransport")
	player_net = root.get_node_or_null(^"PlayerNet")
	inventory = root.get_node_or_null(^"InventoryService")
	combat = root.get_node_or_null(^"CombatService")
	if transport == null or player_net == null or inventory == null or combat == null:
		fail("NetTransport, PlayerNet, InventoryService and CombatService autoloads must exist")
		finish()
		return
	combat.get("attack_landed").connect(_on_landed)
	combat.get("attack_rejected").connect(_on_rejected)
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.is_empty() and args[0] == "combat-probe":
		_run_client()
	else:
		_run_driver()


func _run_driver() -> void:
	print("\n== combat network check (task 2.8) ==")
	if FileAccess.file_exists(RESULT_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(RESULT_PATH))

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
	check(connected, "client connects and receives its authoritative inventory")
	if not connected:
		finish()
		return
	var peer_id: int = int(_read_result().get("peer_id", 0))
	check(peer_id > NetConfig.HOST_PEER_ID, "client reports a real peer id")

	# The client reports "connected" as soon as it has an inventory revision, which can precede the
	# host finishing its spawn — PlayerNet has no spawn signal to wait on (F-018), so poll for it.
	var player_spawned: bool = await _until(
		func() -> bool: return player_net.call("player_for", peer_id) != null, TIMEOUT_SEC
	)
	var host_player: Node3D = player_net.call("player_for", peer_id) as Node3D
	check(player_spawned and host_player != null, "host owns the attacking client's player")
	if host_player == null:
		finish()
		return

	# Placed against the HOST's copy of that player, two metres along its forward (-Z).
	target = TestTarget.new()
	target.name = "NetworkCheckTarget"
	target.set("follow", host_player)
	root.add_child(target)

	check(bool(inventory.call("host_add", peer_id, &"stone_axe", 1)), "host grants the client an axe")
	check(bool(inventory.call("host_move_stack", peer_id, 0, 24, 1)),
		"host places the axe in the client's first hotbar slot")
	var armed: bool = await _until(
		func() -> bool: return bool(_read_result().get("armed", false)), TIMEOUT_SEC
	)
	check(armed, "client sees the axe in its replicated hotbar slot")
	# Read while the client is still connected: 2.4 releases a departed peer's inventory.
	check(int(inventory.call("host_count", peer_id, &"stone_axe")) == 1,
		"the axe is held, not consumed, while it is swung")

	var complete: bool = await _until(
		func() -> bool: return bool(_read_result().get("complete", false)),
		CLIENT_COMPLETE_TIMEOUT_SEC
	)
	var result: Dictionary = _read_result()
	check(complete, "client completes both swings and the spam rejection (stage: %s)" % [
		result.get("stage", "?")
	])

	check(target.get("hit_count") == 2, "host resolved exactly two swings")
	check(target.get("last_peer_id") == peer_id, "host attributes damage to the attacking client")
	check(target.get("damage_taken") == 4,
		"host reads its own inventory: 3 from the held axe, 1 unarmed from an empty slot")
	check(int(result.get("axe_damage", -1)) == 3, "client is told the axe damage the host applied")
	check(int(result.get("unarmed_damage", -1)) == 1,
		"an empty hotbar slot swings unarmed, decided by the host")
	check(StringName(String(result.get("axe_target", ""))) == &"NetworkCheckTarget",
		"the broadcast names the target the host chose")
	check(int(result.get("landed_peer", 0)) == peer_id,
		"the connect is attributed to the client on the client")
	check(bool(result.get("hitstop_applied", false)),
		"a host-confirmed connect freezes the client's own swing clock")
	check(bool(result.get("local_predicted", false)),
		"the client's swing started locally without waiting for the host")
	check(bool(result.get("spam_rejected", false)),
		"host refuses a second swing before the first has recovered")
	check(String(result.get("spam_detail", "")).contains("recovered"),
		"the spam rejection says why")
	check(landed.size() == 2, "host also observes both connects locally")

	var child_exited: bool = await _until(
		func() -> bool: return child_pid <= 0 or not OS.is_process_running(child_pid), TIMEOUT_SEC
	)
	check(child_exited, "client exits cleanly")
	if child_exited:
		child_pid = 0
	transport.call("leave")
	print("COMBAT_NET_CHECK peer=%d damage=%d failures=%d result=%s" % [
		peer_id, int(target.get("damage_taken")), failures, result
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
	_write_result({"connected": true, "peer_id": peer_id, "armed": false, "complete": false})

	var armed: bool = await _until(
		func() -> bool:
			return StringName(
				(combat.call("weapon_for_hotbar_index", 0) as WeaponDef).item_id
			) == &"stone_axe",
		TIMEOUT_SEC
	)
	if not armed:
		_write_result({"connected": true, "peer_id": peer_id, "error": "axe never replicated"})
		finish()
		return
	_stage("armed", peer_id)
	await create_timer(0.25).timeout

	# Swing one: the axe, held in hotbar slot zero.
	combat.call("request_attack")
	_stage("axe_swing_sent", peer_id)
	var local_predicted: bool = int(combat.call("local_phase")) != 0
	# A second request while committed must not even leave the client...
	var suppressed_locally: bool = int(combat.call("request_attack")) == -1
	# ...so the spam path is exercised against the host directly, bypassing the local guard.
	# Callable(node, "method"), not node.get("method") — get() resolves properties and signals, and
	# returns null for a method name.
	Callable(combat, "net_request_attack").rpc_id(NetConfig.HOST_PEER_ID, 0, 9001)
	var axe_landed: bool = await _until(func() -> bool: return landed.size() >= 1, TIMEOUT_SEC)
	var hitstop_applied: bool = float(combat.call("local_hitstop_remaining")) > 0.0
	_stage("axe_landed=%s" % axe_landed, peer_id)
	var spam_rejected: bool = await _until(func() -> bool: return rejections.size() >= 1, TIMEOUT_SEC)
	_stage("spam_rejected=%s" % spam_rejected, peer_id)

	await _until(func() -> bool: return int(combat.call("local_phase")) == 0, TIMEOUT_SEC)
	await create_timer(0.35).timeout
	_stage("recovered", peer_id)

	# Swing two: hotbar slot five is empty, so the host resolves it as unarmed.
	var ui: Node = root.get_node_or_null(^"InventoryUI")
	if ui != null:
		ui.call("select_hotbar_slot", 5)
	combat.call("request_attack")
	_stage("unarmed_swing_sent", peer_id)
	var unarmed_landed: bool = await _until(func() -> bool: return landed.size() >= 2, TIMEOUT_SEC)

	var first: Dictionary = landed[0] if not landed.is_empty() else {}
	var second: Dictionary = landed[1] if landed.size() > 1 else {}
	_write_result({
		"connected": true,
		"peer_id": peer_id,
		"armed": true,
		"complete": axe_landed and unarmed_landed,
		"axe_damage": int(first.get("damage", -1)),
		"axe_target": String(first.get("target_name", "")),
		"landed_peer": int(first.get("peer_id", 0)),
		"unarmed_damage": int(second.get("damage", -1)),
		"hitstop_applied": hitstop_applied,
		"local_predicted": local_predicted and suppressed_locally,
		"spam_rejected": spam_rejected,
		"spam_detail": String(rejections[0].get("detail", "")) if not rejections.is_empty() else "",
	})
	await create_timer(1.0).timeout
	finish()


## Breadcrumb for the driver: a stalled client is otherwise silent, because its stdout does not come
## back through OS.create_process.
func _stage(stage: String, peer_id: int) -> void:
	_write_result({
		"connected": true, "peer_id": peer_id, "armed": true, "complete": false, "stage": stage
	})


func _on_landed(peer_id: int, position: Vector3, damage: int, target_name: StringName) -> void:
	landed.append({
		"peer_id": peer_id, "position": position, "damage": damage, "target_name": target_name
	})


func _on_rejected(request_id: int, detail: String) -> void:
	rejections.append({"request_id": request_id, "detail": detail})


func _client_inventory_ready() -> bool:
	return (
		int(transport.call("local_peer_id")) > NetConfig.HOST_PEER_ID
		and int(inventory.call("local_revision")) >= 0
	)


func _spawn_client() -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	var args := PackedStringArray([
		"--headless", "--path", project_dir, "--script", "tools/combat_net_check.gd",
		"--", "combat-probe",
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
