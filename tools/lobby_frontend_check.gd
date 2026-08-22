extends SceneTree

## F-520 proof: a session opened while the FRONT END is on screen must not spawn player bodies and
## must not take the cursor — that combination is what made the expedition dock's lobby buttons read
## as "the game froze". The spawns are owed until landfall, and then taken.
##
## Uses Mode.LOCAL rather than Steam so the check is real on a machine with no Steam client: the
## path under test is NetTransport.server_started → PlayerNet, which is identical either way.
##
## Run with: .agent/bin/agent godot --script tools/lobby_frontend_check.gd

const FRONTEND_GROUP: StringName = &"mire_frontend"

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame

	var transport: Node = root.get_node_or_null(^"/root/NetTransport")
	var player_net: Node = root.get_node_or_null(^"/root/PlayerNet")
	check(player_net != null, "PlayerNet autoload exists")
	if player_net == null:
		finish()
		return

	# Stand in for ui/frontend/frontend.gd: the group IS the marker that file publishes, and holding
	# it is the whole of what "the front end is up" means to PlayerNet.
	var frontend := Node.new()
	frontend.name = "FrontendStandIn"
	frontend.add_to_group(FRONTEND_GROUP)
	root.add_child(frontend)

	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var err: int = int(transport.call("host", NetConfig.Mode.LOCAL))
	check(err == OK, "a session opens from the front end (the lobby has to be joinable)")
	for _i: int in 12:
		await process_frame

	check(bool(transport.call("is_active")), "the session is live while the front end is still up")
	check(PackedInt32Array(player_net.call("spawned_peers")).is_empty(),
		"no player body is spawned into the front end (%d spawned)"
			% PackedInt32Array(player_net.call("spawned_peers")).size())
	check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE,
		"the cursor still belongs to the menu (mouse_mode=%d)" % Input.mouse_mode)

	# Landfall: the front end goes away and a world takes its place.
	var world := Node3D.new()
	world.name = "WorldStandIn"
	root.add_child(world)
	current_scene = world
	frontend.queue_free()
	for _i: int in 12:
		await process_frame

	var spawned: PackedInt32Array = PackedInt32Array(player_net.call("spawned_peers"))
	check(not spawned.is_empty(), "the owed spawns are taken at landfall (%d spawned)" % spawned.size())
	check(spawned.has(int(transport.call("local_peer_id"))), "the local player is one of them")

	transport.call("leave")
	await process_frame
	print("LOBBY_FRONTEND_CHECK failures=%d" % failures)
	quit(1 if failures > 0 else 0)


func check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: %s" % label)
		return
	failures += 1
	push_error("FAIL: %s" % label)


func finish() -> void:
	print("LOBBY_FRONTEND_CHECK failures=%d" % failures)
	quit(1)
