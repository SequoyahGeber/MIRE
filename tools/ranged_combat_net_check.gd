extends SceneTree

## Real two-process ENet proof for task 5.3. A client sends only a hotbar slot index; the host reads
## its OWN authoritative inventory for that slot and for ammo, resolves the arrow's flight against its
## own copy of the world, applies the damage, and broadcasts both the cosmetic spawn and the
## authoritative resolution. The client renders the consequences and decides none of them — same
## shape as tools/combat_net_check.gd (task 2.8).

const PORT: int = 47439
const RESULT_PATH: String = "user://ranged_combat_net_client.json"
const TIMEOUT_SEC: float = 15.0
## The client draws, fires, misses on purpose, then runs dry — outlast the sum of its own waits.
const CLIENT_COMPLETE_TIMEOUT_SEC: float = 60.0

## `RangedCombatService.Phase.RECOVERY`. Duplicated by value rather than reached through the autoload
## because this is read in the DRIVER, which asserts on a result the probe process wrote — the enum
## has to be a constant on both sides of that file, and a rename must fail loudly here.
const RANGED_PHASE_RECOVERY: int = 3

var failures: int = 0
var transport: Node
var player_net: Node
var inventory: Node
var ranged: Node
var level: Node3D
var child_pid: int = 0
var landed: Array[Dictionary] = []
var missed: Array[Dictionary] = []
var rejections: Array[Dictionary] = []
var target: Node3D


## Host-side damage seam stand-in, same contract Harvestable/Enemy/PlayerController implement, and
## deliberately its OWN CollisionObject3D child rather than being one itself — the shape
## systems/harvesting/harvestable.gd actually uses, and the one RangedCombatService's raycast has to
## resolve back to the &"damageable" node through (see its _damageable_owner()).
class TestTarget extends Node3D:
	var damage_taken: int = 0
	var last_peer_id: int = -1
	var hit_count: int = 0
	## The host's copy of the attacking client's player, followed at a fixed offset so the check does
	## not depend on where PlayerNet happens to spawn it (same F-038 shape as combat_net_check.gd).
	var follow: Node3D

	func _ready() -> void:
		add_to_group(&"damageable")
		var body := StaticBody3D.new()
		body.collision_layer = 1
		body.collision_mask = 0
		var shape := CollisionShape3D.new()
		var sphere := SphereShape3D.new()
		sphere.radius = 1.0
		shape.shape = sphere
		shape.position.y = 1.0
		body.add_child(shape)
		add_child(body)

	func _process(_delta: float) -> void:
		if follow != null and is_instance_valid(follow) and follow.is_inside_tree():
			global_position = follow.global_position + follow.global_transform.basis.z * -8.0

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
	ranged = root.get_node_or_null(^"RangedCombatService")
	if transport == null or player_net == null or inventory == null or ranged == null:
		fail("NetTransport, PlayerNet, InventoryService and RangedCombatService autoloads must exist")
		finish()
		return
	ranged.get("shot_landed").connect(_on_landed)
	ranged.get("shot_missed").connect(_on_missed)
	ranged.get("shot_rejected").connect(_on_rejected)
	_build_ground()
	await physics_frame
	await physics_frame
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.is_empty() and args[0] == "ranged-probe":
		_run_client()
	else:
		_run_driver()


## F-038 shape: both processes need the same ground or a player that lands host-side but keeps
## falling client-side (or vice versa) desyncs exactly the position this check's aim/flight depends
## on. Also gives PlayerNet's spawn-point claim a `current_scene`.
func _build_ground() -> void:
	level = Node3D.new()
	level.name = "RangedCombatNetLevel"
	root.add_child(level)
	current_scene = level
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.position = Vector3(0.0, -0.5, 0.0)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(80.0, 1.0, 80.0)
	shape.shape = box
	body.add_child(shape)
	level.add_child(body)


func _run_driver() -> void:
	print("\n== ranged combat network check (task 5.3) ==")
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

	var player_spawned: bool = await _until(
		func() -> bool: return player_net.call("player_for", peer_id) != null, TIMEOUT_SEC
	)
	var host_player: Node3D = player_net.call("player_for", peer_id) as Node3D
	check(player_spawned and host_player != null, "host owns the shooting client's player")
	if host_player == null:
		finish()
		return

	target = TestTarget.new()
	target.name = "RangedNetworkCheckTarget"
	target.set("follow", host_player)
	root.add_child(target)

	var host_inventory_ready: bool = await _until(
		func() -> bool: return (inventory.call("host_slots", peer_id) as Array).size() == 32,
		TIMEOUT_SEC
	)
	check(host_inventory_ready, "host creates the client's inventory store before granting anything")
	if not host_inventory_ready:
		finish()
		return
	check(bool(inventory.call("host_add", peer_id, &"short_bow", 1)), "host grants the client a bow")
	check(bool(inventory.call("host_move_stack", peer_id, 0, 24, 1)),
		"host places the bow in the client's first hotbar slot")
	check(bool(inventory.call("host_add", peer_id, &"arrow", 1)),
		"host grants the client exactly ONE arrow — enough for the first shot, not the second")
	var armed: bool = await _until(
		func() -> bool: return bool(_read_result().get("armed", false)), TIMEOUT_SEC
	)
	check(armed, "client sees the bow in its replicated hotbar slot")
	check(int(inventory.call("host_count", peer_id, &"arrow")) == 1,
		"the arrow is held, not consumed, while the bow is only drawn")

	var complete: bool = await _until(
		func() -> bool: return bool(_read_result().get("complete", false)),
		CLIENT_COMPLETE_TIMEOUT_SEC
	)
	var result: Dictionary = _read_result()
	check(complete, "client completes the connect and the out-of-ammo rejection (stage: %s)" % [
		result.get("stage", "?")
	])

	check(target.get("hit_count") == 1, "host resolved exactly one connect")
	check(target.get("last_peer_id") == peer_id, "host attributes damage to the shooting client")
	check(target.get("damage_taken") == 4, "host applies its own authored bow damage, not a client's")
	check(int(result.get("shot_damage", -1)) == 4, "the client is told the damage the host applied")
	check(StringName(String(result.get("shot_target", ""))) == &"RangedNetworkCheckTarget",
		"the broadcast names the target the host's own raycast actually hit")
	check(int(result.get("landed_peer", 0)) == peer_id,
		"the connect is attributed to the client on the client")
	check(bool(result.get("hitstop_applied", false)),
		"a host-confirmed connect freezes the client's own local clock, measured at the emit itself")
	check(int(result.get("recovery_at_emit", -1)) == RANGED_PHASE_RECOVERY,
		"local recovery is already committed when shot_landed fires (F-327 ordering), phase=%d"
			% int(result.get("recovery_at_emit", -1)))
	check(bool(result.get("local_predicted", false)),
		"the client's draw started locally without waiting for the host")
	check(int(inventory.call("host_count", peer_id, &"arrow")) == 0,
		"the host consumed the client's one arrow, not zero and not more than one")
	check(bool(result.get("second_draw_predicted_locally", false)),
		"the client's local clock cannot know it is out of ammo — it still predicts the draw")
	check(bool(result.get("out_of_ammo_rejected", false)),
		"the host refuses the second draw once the client's ammo is actually gone")
	check(String(result.get("rejection_detail", "")).contains("ammo"), "the rejection says why")
	check(landed.size() == 1, "host also observes the one connect locally")

	var child_exited: bool = await _until(
		func() -> bool: return child_pid <= 0 or not OS.is_process_running(child_pid), TIMEOUT_SEC
	)
	check(child_exited, "client exits cleanly")
	if child_exited:
		child_pid = 0
	transport.call("leave")
	print("RANGED_COMBAT_NET_CHECK peer=%d damage=%d failures=%d missed=%s rejections=%s result=%s" % [
		peer_id, int(target.get("damage_taken")), failures, missed, rejections, result
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
			return (ranged.call("ranged_weapon_for_hotbar_index", 0) as RangedWeaponDef) != null,
		TIMEOUT_SEC
	)
	if not armed:
		_write_result({"connected": true, "peer_id": peer_id, "error": "bow never replicated"})
		finish()
		return
	_stage("armed", peer_id)
	await create_timer(0.25).timeout

	# Shot one: the bow, drawn with its one authored arrow.
	ranged.call("request_shot", 0)
	_stage("draw_sent", peer_id)
	var local_predicted: bool = int(ranged.call("local_phase")) != 0
	# A second request while drawing must not even leave the client...
	var suppressed_locally: bool = int(ranged.call("request_shot", 0)) == -1
	# ...so the spam path is exercised against the host directly, bypassing the local guard.
	Callable(ranged, "net_request_shot").rpc_id(NetConfig.HOST_PEER_ID, 0, 9001)
	var shot_landed_flag: bool = await _until(func() -> bool: return landed.size() >= 1, TIMEOUT_SEC)
	_stage("shot_landed=%s" % shot_landed_flag, peer_id)

	await _until(func() -> bool: return int(ranged.call("local_phase")) == 0, TIMEOUT_SEC)
	await create_timer(0.35).timeout
	_stage("recovered", peer_id)

	# Shot two: no ammo left. The client cannot know that locally, so it still predicts the draw.
	var missed_before: int = missed.size()
	var rejections_before: int = rejections.size()
	ranged.call("request_shot", 0)
	var second_predicted: bool = int(ranged.call("local_phase")) != 0
	_stage("second_draw_sent", peer_id)
	var out_of_ammo_rejected: bool = await _until(
		func() -> bool: return rejections.size() > rejections_before, TIMEOUT_SEC
	)
	_stage("out_of_ammo_rejected=%s" % out_of_ammo_rejected, peer_id)

	var first: Dictionary = landed[0] if not landed.is_empty() else {}
	_write_result({
		"connected": true,
		"peer_id": peer_id,
		"armed": true,
		"complete": shot_landed_flag and out_of_ammo_rejected,
		"shot_damage": int(first.get("damage", -1)),
		"shot_target": String(first.get("target_name", "")),
		"landed_peer": int(first.get("peer_id", 0)),
		"landed_count": landed.size(),
		"missed_count": missed.size(),
		"rejection_count": rejections.size(),
		# Both sampled inside `_on_landed`, at the emit — see its header. RECOVERY is phase 3 in
		# `RangedCombatService.Phase`; observing it here is what proves the ordering, not just the
		# hitstop value.
		"hitstop_applied": float(first.get("hitstop_at_emit", 0.0)) > 0.0,
		"recovery_at_emit": int(first.get("phase_at_emit", -1)),
		"local_predicted": local_predicted and suppressed_locally,
		"second_draw_predicted_locally": second_predicted,
		"out_of_ammo_rejected": out_of_ammo_rejected,
		# The LAST rejection, not the first — the first is the earlier spam-reject from shot one's own
		# bypass RPC (Callable(...).rpc_id(...) above), which is a real and expected rejection too, just
		# not the one this stage is about.
		"rejection_detail": (
			String(rejections[rejections.size() - 1].get("detail", "")) if not rejections.is_empty() else ""
		),
	})
	await create_timer(1.0).timeout
	finish()


## Breadcrumb for the driver: a stalled client is otherwise silent, because its stdout does not come
## back through OS.create_process.
func _stage(stage: String, peer_id: int) -> void:
	_write_result({
		"connected": true, "peer_id": peer_id, "armed": true, "complete": false, "stage": stage
	})


## F-327: the feel state is read HERE, synchronously inside the emit, not by a later poll.
##
## The driver used to sample `local_hitstop_remaining()` after `_until(...)` noticed `landed` had
## grown. `_until` polls every 50 ms and hitstop is a sub-frame effect, so the sample could land
## after the freeze had already decayed — the assertion was intermittently red on correct code, which
## is worse than useless: it trains people to rerun until green. A signal callback is synchronous, so
## this observes the exact transition instead of racing its aftermath.
##
## It is also what makes F-327's source fix observable: `RangedCombatService._apply_resolved()` now
## commits local recovery and hitstop BEFORE emitting, so a listener here sees committed state. Read
## in the old order, these two fields would be the pre-shot values every time.
func _on_landed(peer_id: int, position: Vector3, damage: int, target_name: StringName) -> void:
	landed.append({
		"peer_id": peer_id, "position": position, "damage": damage, "target_name": target_name,
		"hitstop_at_emit": float(ranged.call("local_hitstop_remaining")),
		"phase_at_emit": int(ranged.call("local_phase")),
	})


func _on_missed(peer_id: int, position: Vector3) -> void:
	missed.append({"peer_id": peer_id, "position": position})


func _on_rejected(request_id: int, detail: String) -> void:
	rejections.append({"request_id": request_id, "detail": detail})


## F-060 shape: gate on is_active() directly, not just a positive peer id — ENet hands a client its
## own unique id locally before the host<->client handshake actually completes.
func _client_inventory_ready() -> bool:
	return (
		bool(transport.call("is_active"))
		and int(transport.call("local_peer_id")) > NetConfig.HOST_PEER_ID
		and int(inventory.call("local_revision")) >= 0
	)


func _spawn_client() -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	var args := PackedStringArray([
		"--headless", "--path", project_dir, "--script", "tools/ranged_combat_net_check.gd",
		"--", "ranged-probe",
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
