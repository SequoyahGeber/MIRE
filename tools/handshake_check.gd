extends SceneTree

## Verifies task 1.11 — protocol/build version handshake (docs/ARCHITECTURE.md §2.2).
##
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/handshake_check.gd
##
## Two parts. First, NetVersion.mismatch_reason() as a pure function — no session needed. Second, a
## real two-peer ENet exchange proving the WIRE MECHANICS a host-side handshake will use: send a hello
## naming the sender's version, and when it disagrees, reject with a reason the other side can read
## before the connection drops. Built the same way tools/bench_replication.gd puts multiple real peers
## in one process — a separate Node subtree per peer, each with its own MultiplayerAPI and ENet socket
## (SceneTree.set_multiplayer(api, root_path) scopes RPC routing to that subtree) — because that is the
## only way to get two ends of a real ENet connection talking inside a single headless process.
##
## THIS DOES NOT WIRE THE HANDSHAKE INTO NetTransport. autoload/net_transport.gd is where the client
## hello send and the host-side reject belong (it already owns connected_to_host / peer_connected), but
## it was claimed by another in-flight task (1.7) when 1.11 started, so wiring it in would have been
## two agents in one file. docs/DELEGATION.md 'Current state' has the exact drop-in: what to add to
## _on_connected_to_server() and where the two @rpc methods go. What's proven here is that the
## mechanism NetVersion.mismatch_reason() feeds is sound: a real client sending a bad version over a
## real ENet connection gets a legible reason and is disconnected, not left to desync.

## Preloaded rather than referenced by bare class_name: a script new to this session is not yet in
## .godot/global_script_class_cache.cfg (that only regenerates when the editor scans the project), so
## a --script run that names it bare fails "Identifier not declared" even though the class is real and
## Sequoyah's next editor session will resolve it fine either way. Same fix bench_replication.gd used
## for Dummy. Filed as F-016 — every brand-new class_name a --script harness touches needs this.
const NetVersion = preload("res://core/net/net_version.gd")

const _PORT: int = 47511
const _TIMEOUT_SEC: float = 5.0

var _failures: int = 0


func _check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		print("  ok    %s" % label)
	else:
		_failures += 1
		print("  FAIL  %s%s" % [label, ("  — " + detail) if detail != "" else ""])


func _initialize() -> void:
	print("\n-- NetVersion.mismatch_reason(), pure --")
	_check("matching versions produce no reason",
		NetVersion.mismatch_reason(3, 3) == "")
	var reason: String = NetVersion.mismatch_reason(3, 2)
	_check("mismatched versions name both sides",
		reason.contains("3") and reason.contains("2"), reason)
	_check("mismatch reason is never empty when versions differ",
		not NetVersion.mismatch_reason(1, 0).is_empty())
	_check("PROTOCOL_VERSION is a positive int",
		NetVersion.PROTOCOL_VERSION > 0, str(NetVersion.PROTOCOL_VERSION))
	# Task 2.13 bumped 6 -> 7 for the health RPCs (net_request_revive, net_health_snapshot,
	# net_downed_flag, net_force_respawn); task 2.11 bumped 7 -> 8 for day_night.gd's net_push_time;
	# task 3.8 bumped 8 -> 9 for net_health_snapshot's two new arguments (hunger, hunger_max) plus the
	# consume-item and stamina-reconciliation RPCs; task 3.5 bumped 9 -> 10 for chest.gd's
	# request/grant pair; task 3.3 bumped 10 -> 11 for powerup_service.gd's snapshot/counts pair;
	# task 3.6 bumped 11 -> 12 for build_service.gd's place/destroy/result trio; task 3.10 bumped
	# 12 -> 13 for haulable.gd's pickup/drop request/result pairs plus its own SceneReplicationConfig.
	# A hard-coded expectation here is deliberate: this check's whole point is to fail loudly the day
	# someone adds a wire-shape change and forgets the bump.
	_check("PROTOCOL_VERSION reflects task 3.10's haul pickup/drop RPCs",
		NetVersion.PROTOCOL_VERSION == 13, str(NetVersion.PROTOCOL_VERSION))

	call_deferred(&"_run_wire_checks")


func _run_wire_checks() -> void:
	print("\n-- real ENet hello/reject exchange --")
	await _check_matching_versions()
	await _check_mismatched_versions()

	print("\n%d failure(s)\n" % _failures)
	quit(1 if _failures > 0 else 0)


# ── Peer harness — mirrors tools/bench_replication.gd's one-process-two-peers technique ─────────────

## Minimal stand-in for what autoload/net_transport.gd will do: a client sends its version once
## connected; a host that disagrees replies with a reason and drops the peer shortly after, giving the
## reliable RPC time to actually reach the wire before the socket closes.
class _HandshakeProbe:
	extends Node

	var is_host: bool = false
	var local_version: int = NetVersion.PROTOCOL_VERSION
	var rejected_reason: String = ""
	var was_disconnected: bool = false

	func _ready() -> void:
		multiplayer.server_disconnected.connect(func() -> void: was_disconnected = true)

	func send_hello() -> void:
		rpc_id(1, &"_hello", local_version)

	@rpc("any_peer", "reliable")
	func _hello(remote_version: int) -> void:
		if not is_host:
			return
		var sender_id: int = multiplayer.get_remote_sender_id()
		var reason: String = NetVersion.mismatch_reason(local_version, remote_version)
		if reason.is_empty():
			return
		rpc_id(sender_id, &"_rejected", reason)
		_disconnect_after_flush(sender_id)

	@rpc("authority", "reliable")
	func _rejected(reason: String) -> void:
		rejected_reason = reason

	func _disconnect_after_flush(peer_id: int) -> void:
		await get_tree().create_timer(0.2).timeout
		var peer: MultiplayerPeer = multiplayer.multiplayer_peer
		if peer != null:
			peer.disconnect_peer(peer_id)


func _make_peer(index: int, is_host: bool, local_version: int) -> Dictionary:
	var peer_root: Node = Node.new()
	peer_root.name = "HPeer%d" % index
	root.add_child(peer_root)

	var api: MultiplayerAPI = MultiplayerAPI.create_default_interface()
	set_multiplayer(api, NodePath("/root/HPeer%d" % index))

	var enet := ENetMultiplayerPeer.new()
	var err: Error = (
		enet.create_server(_PORT) if is_host else enet.create_client(NetConfig.LOOPBACK_ADDRESS, _PORT)
	)
	_check("peer %d %s" % [index, "create_server" if is_host else "create_client"],
		err == OK, error_string(err))
	api.multiplayer_peer = enet

	var probe: _HandshakeProbe = _HandshakeProbe.new()
	probe.name = "Handshake"
	probe.is_host = is_host
	probe.local_version = local_version
	peer_root.add_child(probe)

	return {"root": peer_root, "api": api, "enet": enet, "probe": probe}


func _poll(peers: Array[Dictionary]) -> void:
	for p: Dictionary in peers:
		(p["api"] as MultiplayerAPI).poll()


func _teardown(peers: Array[Dictionary]) -> void:
	for p: Dictionary in peers:
		(p["enet"] as ENetMultiplayerPeer).close()
		(p["root"] as Node).queue_free()


func _check_matching_versions() -> void:
	print("\nmatching versions:")
	var host: Dictionary = _make_peer(0, true, 8)
	var client: Dictionary = _make_peer(1, false, 8)
	var peers: Array[Dictionary] = [host, client]

	var deadline: int = Time.get_ticks_msec() + int(_TIMEOUT_SEC * 1000.0)
	while (client["enet"] as ENetMultiplayerPeer).get_connection_status() \
			!= MultiplayerPeer.CONNECTION_CONNECTED and Time.get_ticks_msec() < deadline:
		_poll(peers)
		await create_timer(0.02).timeout
	_check("client connected", (client["enet"] as ENetMultiplayerPeer).get_connection_status()
		== MultiplayerPeer.CONNECTION_CONNECTED)

	(client["probe"] as _HandshakeProbe).send_hello()
	for i: int in range(15):
		_poll(peers)
		await create_timer(0.05).timeout

	var probe: _HandshakeProbe = client["probe"]
	_check("no rejection when versions match", probe.rejected_reason.is_empty(), probe.rejected_reason)
	_check("connection still up when versions match", not probe.was_disconnected)

	_teardown(peers)
	await process_frame


func _check_mismatched_versions() -> void:
	print("\nmismatched versions:")
	var host: Dictionary = _make_peer(2, true, 8)
	var client: Dictionary = _make_peer(3, false, 4)
	var peers: Array[Dictionary] = [host, client]

	var deadline: int = Time.get_ticks_msec() + int(_TIMEOUT_SEC * 1000.0)
	while (client["enet"] as ENetMultiplayerPeer).get_connection_status() \
			!= MultiplayerPeer.CONNECTION_CONNECTED and Time.get_ticks_msec() < deadline:
		_poll(peers)
		await create_timer(0.02).timeout
	_check("client connected before handshake", (client["enet"] as ENetMultiplayerPeer)
		.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED)

	(client["probe"] as _HandshakeProbe).send_hello()

	var reject_deadline: int = Time.get_ticks_msec() + int(_TIMEOUT_SEC * 1000.0)
	var probe: _HandshakeProbe = client["probe"]
	while probe.rejected_reason.is_empty() and Time.get_ticks_msec() < reject_deadline:
		_poll(peers)
		await create_timer(0.02).timeout
	print("  reason: %s" % probe.rejected_reason)
	_check("client received a reason naming both versions",
		probe.rejected_reason.contains("8") and probe.rejected_reason.contains("4"),
		probe.rejected_reason)

	var disconnect_deadline: int = Time.get_ticks_msec() + int(_TIMEOUT_SEC * 1000.0)
	while not probe.was_disconnected and Time.get_ticks_msec() < disconnect_deadline:
		_poll(peers)
		await create_timer(0.02).timeout
	_check("client was disconnected after rejection", probe.was_disconnected)

	_teardown(peers)
	await process_frame
