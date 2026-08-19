extends SceneTree

## Real two-process ENet proof for F-228: `craft`/`build`/`demolish` typed by an OP'D NON-HOST CLIENT
## must charge/credit and confirm THAT CLIENT, never the host's own peer id.
##
## `_cmd_craft`/`_cmd_build`/`_cmd_demolish` used to go through `request_craft()`/`request_place()`/
## `request_destroy()` — the same entry points the crafting UI / placement ghost / demolish tool call
## on their OWN local process, where resolving the actor via `_local_peer_id()` is correct. A
## HOST-scope command handler is different: it always executes ON THE HOST regardless of who typed
## the line (`command_service.gd`'s `execute()`/`_execute_locally()` never reach a handler anywhere
## else — a non-host submission re-enters over `net_submit_command`, which re-parses and re-executes
## on the host too). So `_local_peer_id()` inside the handler was always the HOST's own id, and a
## non-host op's `craft`/`build`/`demolish` silently acted on the host's inventory/build ledger
## instead of the op's — and, since `_confirm_peer()`/`_answer()` also gate the RPC-back-to-issuer on
## `peer_id == _local_peer_id()`, the op's own client never even received the confirmation signal.
##
## The fix reads the issuing peer off `ctx.peer_id` (accurate for both the host's own console and a
## re-executed `net_submit_command` line — `command_service.gd`'s `_build_ctx()` populates it from
## `multiplayer.get_remote_sender_id()` for the latter) and calls `_process_craft()`/`_process_place()`/
## `_process_destroy()` directly, skipping the local-actor-assuming entry points entirely.
##
##   .agent/bin/agent godot --script tools/command_craft_build_net_check.gd
##
## Same driver/probe shape as tools/build_net_check.gd: a DRIVER_SIGNAL_PATH file gates the client
## into each phase only once the driver has finished asserting the PREVIOUS one — on loopback ENet
## the client can run three console commands to completion faster than the driver's own poll
## interval notices the first, so nothing here relies on catching an intermediate RESULT_PATH
## snapshot the client might have already raced past.

const CommandServiceScript = preload("res://autoload/command_service.gd")

const PORT: int = 47519
const RESULT_PATH: String = "user://command_craft_build_client.json"
const DRIVER_SIGNAL_PATH: String = "user://command_craft_build_driver.json"
const TIMEOUT_SEC: float = 15.0
const RECIPE_ID: StringName = &"stone_axe"
const PIECE_ID: StringName = &"wall_wood"

var failures: int = 0
var transport: Node
var player_net: Node
var inventory: Node
var command_service: CommandServiceScript
var build_service: Node
var level: Node3D
var child_pid: int = 0


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	await process_frame
	transport = root.get_node_or_null(^"NetTransport")
	player_net = root.get_node_or_null(^"PlayerNet")
	inventory = root.get_node_or_null(^"InventoryService")
	command_service = root.get_node_or_null(^"CommandService") as CommandServiceScript
	build_service = root.get_node_or_null(^"BuildService")
	if (
		transport == null or player_net == null or inventory == null
		or command_service == null or build_service == null
	):
		fail(
			"NetTransport, PlayerNet, InventoryService, CommandService and BuildService "
			+ "autoloads must exist")
		finish()
		return
	_build_level()
	await physics_frame
	await physics_frame
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.is_empty() and args[0] == "craft-build-probe":
		_run_client()
	else:
		_run_driver()


## Both processes need the same floor (build_net_check's own reasoning: the host validates
## placement against a real collider) and the same crafting station (crafting_net_check's own
## reasoning), co-located with the client's spawn once the driver knows where that is.
func _build_level() -> void:
	level = Node3D.new()
	level.name = "CommandCraftBuildNetLevel"
	root.add_child(level)
	current_scene = level
	var floor_body := StaticBody3D.new()
	floor_body.collision_layer = 1
	floor_body.position = Vector3(0.0, -0.5, 0.0)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(40.0, 1.0, 40.0)
	shape.shape = box
	floor_body.add_child(shape)
	level.add_child(floor_body)
	var workbench := Node3D.new()
	workbench.name = "NetworkCheckWorkbench"
	workbench.set_meta(&"asset", "station_workbench_primitive")
	workbench.add_to_group(&"playtest_hollow_asset")
	level.add_child(workbench)


func _run_driver() -> void:
	print("\n== craft/build/demolish console-command peer attribution check (F-228) ==")
	for path: String in [RESULT_PATH, DRIVER_SIGNAL_PATH]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_write_driver_signal({"phase": "idle"})

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
		return false
	, TIMEOUT_SEC)
	check(got_peer, "host observes the client's peer id")
	if not got_peer:
		finish()
		return
	for peer_id: int in transport.call("peer_ids") as PackedInt32Array:
		if peer_id != NetConfig.HOST_PEER_ID:
			client_peer = peer_id
			break

	# Move the station onto the client's own (host-authoritative) body so the client's craft is
	# genuinely in range once it submits.
	var workbench: Node3D = level.get_node(^"NetworkCheckWorkbench")
	workbench.global_position = _host_player_position(client_peer)

	# ── phase 0: non-op refusal — nothing crafted for ANYONE while refused ──────────────────────────
	var phase0: Dictionary = await _wait_for_result(
		func(r: Dictionary) -> bool: return r.has("craft_refused_ok"))
	check(bool(phase0.get("craft_refused_ok", false)), "client's craft is refused before being opped: "
		+ String(phase0.get("craft_refused_message", "")))
	check(
		int(inventory.call("host_count", client_peer, &"stone_axe")) == 0
		and int(inventory.call("host_count", NetConfig.HOST_PEER_ID, &"stone_axe")) == 0,
		"nothing crafted for anyone while the client was refused")

	# ── the host ops the client, over the same front door a console command would use ──────────────
	var op_ctx: Dictionary = command_service.build_local_ctx(&"console")
	var op_result: Dictionary = await command_service.execute("op %d" % client_peer, op_ctx)
	check(bool(op_result.get("ok", false)), "host ops the client: %s" % op_result.get("message"))

	# ── grant ingredients + build cost to the CLIENT only; the host's own stack stays untouched ─────
	check(bool(inventory.call("host_add", client_peer, &"log", 10)), "host grants client 10 log")
	check(bool(inventory.call("host_add", client_peer, &"stone", 3)), "host grants client 3 stone")

	# ── phase 1: opped client submits `craft stone_axe` over the console command path ──────────────
	_write_driver_signal({"phase": "craft"})
	var craft_phase: Dictionary = await _wait_for_result(
		func(r: Dictionary) -> bool: return r.has("craft_done"))
	check(bool(craft_phase.get("craft_done", false)),
		"client's craft command actually resolves (craft_confirmed reaches the issuing client)")
	check(bool(craft_phase.get("craft_accepted", false)),
		"craft accepted: %s" % craft_phase.get("craft_message", ""))
	check(int(inventory.call("host_count", client_peer, &"stone_axe")) == 1,
		"the crafted axe lands in the ISSUING CLIENT's own inventory")
	check(int(inventory.call("host_count", NetConfig.HOST_PEER_ID, &"stone_axe")) == 0,
		"F-228: the host's own inventory receives nothing from the client's craft")
	check(int(inventory.call("host_count", client_peer, &"log")) == 8,
		"the CLIENT's own log stack is the one the recipe spent (10 - 2)")
	check(int(inventory.call("host_count", client_peer, &"stone")) == 0,
		"the CLIENT's own stone stack is the one the recipe spent (3 - 3)")
	check(int(inventory.call("host_count", NetConfig.HOST_PEER_ID, &"log")) == 0,
		"F-228: the host's own log stack — never granted anything — is untouched")

	# ── phase 2: opped client submits `build wall_wood ~ ~ ~3` (relative to its own ctx position) ────
	_write_driver_signal({"phase": "build"})
	var build_phase: Dictionary = await _wait_for_result(
		func(r: Dictionary) -> bool: return r.has("build_done"))
	check(bool(build_phase.get("build_done", false)),
		"client's build command actually resolves (build_confirmed reaches the issuing client)")
	check(bool(build_phase.get("build_accepted", false)),
		"build accepted: %s" % build_phase.get("build_message", ""))
	check(int(build_service.call(&"placed_count")) == 1, "one piece exists on the host")
	var placed_name := StringName(String(build_phase.get("placed_name", "")))
	var record: Dictionary = build_service.call(&"placed_record", placed_name)
	check(int(record.get("owner", -1)) == client_peer,
		"F-228: the placed piece's recorded owner is the ISSUING CLIENT, not the host (%s)" % record)
	check(int(inventory.call("host_count", client_peer, &"log")) == 4,
		"the CLIENT's own log stack paid the wall's cost (8 - 4)")
	check(int(inventory.call("host_count", NetConfig.HOST_PEER_ID, &"log")) == 0,
		"F-228: the host's own log stack — never granted anything — still paid nothing")

	# ── phase 3: opped client submits `demolish @e[type=buildable]`, refunding the CLIENT ───────────
	_write_driver_signal({"phase": "demolish"})
	var demolish_phase: Dictionary = await _wait_for_result(
		func(r: Dictionary) -> bool: return r.has("demolish_done"))
	check(bool(demolish_phase.get("demolish_done", false)),
		"client's demolish command actually resolves (build_confirmed reaches the issuing client)")
	check(int(demolish_phase.get("demolish_count", 0)) == 1, "demolish targeted exactly the one piece")
	check(bool(demolish_phase.get("demolish_accepted", false)),
		"demolish accepted: %s" % demolish_phase.get("demolish_message", ""))
	var demolished: bool = await _until(
		func() -> bool: return int(build_service.call(&"placed_count")) == 0, TIMEOUT_SEC)
	check(demolished, "the piece is actually gone")
	check(int(inventory.call("host_count", client_peer, &"log")) == 6,
		"F-228: the demolish refund (floor(4*0.5)=2) lands on the ISSUING CLIENT (4 + 2)")
	check(int(inventory.call("host_count", NetConfig.HOST_PEER_ID, &"log")) == 0,
		"F-228: the host's own log stack never receives a refund it did not earn")

	_write_driver_signal({"phase": "exit"})
	var child_exited: bool = await _until(func() -> bool:
		return child_pid <= 0 or not OS.is_process_running(child_pid), TIMEOUT_SEC)
	check(child_exited, "client exits cleanly")
	if child_exited:
		child_pid = 0

	transport.call("leave")
	print("COMMAND_CRAFT_BUILD_NET_CHECK failures=%d" % failures)
	finish()


## Where the host thinks that peer's body is (same helper build_net_check.gd uses).
func _host_player_position(peer_id: int) -> Vector3:
	if player_net == null or not player_net.has_method(&"players_root"):
		return Vector3.ZERO
	var players: Node = player_net.call(&"players_root") as Node
	if players == null:
		return Vector3.ZERO
	var body := players.get_node_or_null(NodePath(str(peer_id))) as Node3D
	return Vector3.ZERO if body == null else body.global_position


# ── Client (probe) ───────────────────────────────────────────────────────────────────────────────

## F-107's shape (see chest_net_check.gd/command_net_check.gd): signal handlers write to member
## state via a bound method, never a lambda that closes over a local by value.
##
## Keyed by request_id, NEVER a reset-then-wait boolean: _cmd_craft/_cmd_build's own synchronous
## {ok, message, data} reply (over net_command_result) and the async craft_confirmed/build_confirmed
## RPC race each other on the wire — nothing orders one before the other from the caller's side, so
## a confirmation can arrive and fire before the "request accepted" reply even resolves this await.
## Resetting a single flag right before waiting on it is exactly the F-223 shape: it can clobber a
## confirmation that already landed, and then wait forever for one that will never come again.
## crafting_net_check.gd's own `confirmations: Dictionary[int, Dictionary]` is the proven pattern.
var _craft_confirmations: Dictionary = {}
var _build_confirmations: Dictionary = {}


func _run_client() -> void:
	_write_result({})
	var error: Error = transport.call("join", NetConfig.Mode.LOCAL, NetConfig.LOOPBACK_ADDRESS, PORT)
	if error != OK:
		_write_result({"error": error_string(error)})
		finish()
		return
	_client_drive()


func _client_drive() -> void:
	var connected: bool = await _until(
		func() -> bool: return bool(transport.call("is_active")), TIMEOUT_SEC)
	if not connected:
		_write_result({"error": "connect timeout"})
		finish()
		return
	var peer_id: int = int(transport.call("local_peer_id"))
	var spawned: bool = await _until(
		func() -> bool: return player_net.call("player_for", peer_id) != null, TIMEOUT_SEC)
	if not spawned:
		_write_result({"error": "player spawn timeout"})
		finish()
		return

	var crafting: Node = root.get_node_or_null(^"CraftingService")
	if crafting == null:
		_write_result({"error": "no CraftingService autoload"})
		finish()
		return
	crafting.connect(&"craft_confirmed", _on_craft_confirmed)
	build_service.connect(&"build_confirmed", _on_build_confirmed)

	# ── phase 0: refused, not opped yet — happens immediately, no driver signal needed ──────────────
	var ctx: Dictionary = command_service.build_local_ctx(&"console")
	var refusal: Dictionary = await command_service.execute("craft %s" % RECIPE_ID, ctx)
	_write_result({
		"craft_refused_ok": not bool(refusal.get("ok", true)),
		"craft_refused_message": String(refusal.get("message", "")),
	})

	# ── every later phase waits for the DRIVER to say it is ready — see file header. `handled`
	# tracks which phases have already run, same shape as build_net_check.gd's own client loop. ──────
	var handled: Dictionary = {}
	while true:
		var phase: String = String(_read_driver_signal().get("phase", "idle"))
		if phase == "exit":
			break
		if phase != "idle" and not handled.has(phase):
			handled[phase] = true
			match phase:
				"craft":
					await _do_craft()
				"build":
					await _do_build()
				"demolish":
					await _do_demolish()
		await create_timer(0.05).timeout

	await create_timer(0.2).timeout
	finish()


## Opped and ingredients already granted by the driver before it set this phase — one attempt is
## always enough, unlike the op-refusal probe above.
func _do_craft() -> void:
	var ctx: Dictionary = command_service.build_local_ctx(&"console")
	var submit: Dictionary = await command_service.execute("craft %s" % RECIPE_ID, ctx)
	var request_id: int = int((submit.get("data", {}) as Dictionary).get("request", -1))
	var confirmed: bool = (
		bool(submit.get("ok", false))
		and await _until(func() -> bool: return _craft_confirmations.has(request_id), TIMEOUT_SEC)
	)
	var entry: Dictionary = _craft_confirmations.get(request_id, {}) as Dictionary
	_write_result({
		"craft_refused_ok": true,
		"craft_done": confirmed,
		"craft_accepted": confirmed and bool(entry.get("accepted", false)),
		"craft_message": String(entry.get("detail", "")),
	})


## Relative vec3 — the host re-parses the raw line from scratch (COMMANDS.md §1.1) and resolves `~`
## against ITS OWN ctx for this peer, i.e. the host's authoritative view of the client's body, not
## anything computed here — so this reaches 3 m past the client's own position either way.
func _do_build() -> void:
	var ctx: Dictionary = command_service.build_local_ctx(&"console")
	var submit: Dictionary = await command_service.execute("build %s ~ ~ ~3" % PIECE_ID, ctx)
	var request_id: int = int((submit.get("data", {}) as Dictionary).get("request", -1))
	var confirmed: bool = (
		bool(submit.get("ok", false))
		and await _until(func() -> bool: return _build_confirmations.has(request_id), TIMEOUT_SEC)
	)
	var entry: Dictionary = _build_confirmations.get(request_id, {}) as Dictionary
	var placed_name: String = ""
	if confirmed and bool(entry.get("accepted", false)):
		var piece_seen: bool = await _until(
			func() -> bool: return not get_nodes_in_group(&"buildable_piece").is_empty(), TIMEOUT_SEC)
		if piece_seen:
			placed_name = String((get_nodes_in_group(&"buildable_piece")[0] as Node).name)
	_write_result({
		"craft_refused_ok": true, "craft_done": true,
		"build_done": confirmed,
		"build_accepted": confirmed and bool(entry.get("accepted", false)),
		"build_message": String(entry.get("reason", "")),
		"placed_name": placed_name,
	})


## Targets every buildable, of which exactly one exists. No per-piece request_id comes back from
## `demolish` itself (its CommandResult carries a count, not an id), so correlate by which NEW key
## showed up in `_build_confirmations` — build_confirmed is shared by both place and destroy.
func _do_demolish() -> void:
	var known_keys: Array = _build_confirmations.keys()
	var ctx: Dictionary = command_service.build_local_ctx(&"console")
	var submit: Dictionary = await command_service.execute("demolish @e[type=buildable]", ctx)
	var confirmed: bool = (
		bool(submit.get("ok", false))
		and await _until(
			func() -> bool: return _build_confirmations.keys().size() > known_keys.size(), TIMEOUT_SEC)
	)
	var entry: Dictionary = {}
	for key: Variant in _build_confirmations.keys():
		if not known_keys.has(key):
			entry = _build_confirmations[key] as Dictionary
			break
	_write_result({
		"craft_refused_ok": true, "craft_done": true, "build_done": true,
		"demolish_done": confirmed,
		"demolish_count": int((submit.get("data", {}) as Dictionary).get("count", 0)),
		"demolish_accepted": confirmed and bool(entry.get("accepted", false)),
		"demolish_message": String(entry.get("reason", "")),
	})


func _on_craft_confirmed(request_id: int, accepted: bool, detail: String) -> void:
	_craft_confirmations[request_id] = {"accepted": accepted, "detail": detail}


func _on_build_confirmed(request_id: int, accepted: bool, reason: String) -> void:
	_build_confirmations[request_id] = {"accepted": accepted, "reason": reason}


func _spawn_client() -> int:
	var project_dir: String = ProjectSettings.globalize_path("res://")
	var args := PackedStringArray([
		"--headless", "--path", project_dir, "--script", "tools/command_craft_build_net_check.gd",
		"--", "craft-build-probe",
	])
	return OS.create_process(OS.get_executable_path(), args)


func _wait_for_result(done: Callable) -> Dictionary:
	var deadline_msec: int = Time.get_ticks_msec() + int(TIMEOUT_SEC * 1000.0)
	var result: Dictionary = _read_result()
	while Time.get_ticks_msec() < deadline_msec:
		result = _read_result()
		if bool(done.call(result)):
			return result
		await create_timer(0.05).timeout
	return result


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
