extends SceneTree

## Task 1.8 — interest management: per-class replication intervals and distance visibility filters
## with hysteresis (docs/ARCHITECTURE.md §2.5).
##
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/interest_check.gd
##
## Exits non-zero on failure.
##
## Three parts, cheapest first:
##
##   1. CONFIGURATION — build one entity per §2.5 class, plus the real PlayerController, and read the
##      intervals, the visibility mode and the group membership back off the synchronizers that
##      actually got built. Grepping for the call would pass on a synchronizer that is never added.
##   2. FILTER SEMANTICS — drive NetInterest.RadiusFilter directly across the hysteresis band, in both
##      directions, and count the transitions. This is the part that proves the entity does not flap.
##   3. LIVE SESSION — one host and two clients as three real ENet peers over loopback in this one
##      process, with a real MultiplayerSpawner. Move a client's observer and watch the entity appear
##      and disappear on that client's side of the wire. Everything before this is a unit test of our
##      own arithmetic; only this proves the engine agrees with it.
##
## Part 3 borrows tools/bench_replication.gd's trick: SceneTree.set_multiplayer(api, root_path) gives
## each /root/PeerN subtree its own MultiplayerAPI, its own peer and its own replication state, and
## node paths resolve relative to each API's root — so the host's Peer0/Entities/e0 and a client's
## Peer1/Entities/e0 are the same node to the high-level API.
##
## AUTHORITY (§2.2): the entities here are host-authoritative, like the enemies and props they stand
## in for. Clients receive and never send.

const PORT: int = 27715
const PEER_COUNT: int = 3  # host + 2 clients
const CONNECT_TIMEOUT_SEC: float = 10.0
const CONVERGE_TIMEOUT_SEC: float = 5.0

## 60 Hz, because visibility is re-evaluated on the physics tick (VISIBILITY_PROCESS_PHYSICS) and
## replication_interval is measured in seconds. A free-running headless loop would spin thousands of
## process frames between two physics ticks and prove nothing about either.
const FRAME_SEC: float = 1.0 / 60.0

## An arbitrary peer id for the offline parts — no session exists there, so any int does.
const TEST_PEER: int = 7

var _failures: int = 0

## Bumped by each section as its LAST statement, and asserted at the end. A runtime error inside an
## awaited coroutine kills that coroutine and nothing else — the run carries on and reports PASS on
## whatever checks happened to have run already. This is the guard against that false green; it cost
## a real one to notice.
var _sections_done: int = 0

var _apis: Array[MultiplayerAPI] = []
var _enet: Array[ENetMultiplayerPeer] = []
var _containers: Array[Node3D] = []
var _spawners: Array[MultiplayerSpawner] = []
var _client_ids: PackedInt32Array = PackedInt32Array()
var _host_entities: Array[Node3D] = []


## A host-authoritative entity of a given §2.5 class. Stands in for the enemies and props that do not
## exist yet: the only thing 1.8 ships for them is this configuration call, so this is the whole of
## what there is to test. Built in code and identically on every peer (D-023).
class InterestEntity extends Node3D:

	const SYNC_NODE_NAME: StringName = &"NetSync"

	## The filter NetInterest installed, or null for an unfiltered class.
	var filter: NetInterest.RadiusFilter = null
	var sync: MultiplayerSynchronizer = null

	var _entity_class: NetInterest.Class = NetInterest.Class.ENEMY

	## Called on every peer before the node enters the tree, with identical arguments — on the host
	## because it called spawn(), on each client because the spawn packet arrived.
	func configure(index: int, entity_class: NetInterest.Class, at: Vector3) -> void:
		name = "e%d" % index
		_entity_class = entity_class
		position = at

	func _ready() -> void:
		# Authority before the synchronizer enters the tree (F-012).
		set_multiplayer_authority(NetConfig.HOST_PEER_ID)

		var config := SceneReplicationConfig.new()
		var position_path := NodePath(".:position")
		config.add_property(position_path)
		config.property_set_spawn(position_path, true)
		config.property_set_replication_mode(
			position_path, SceneReplicationConfig.REPLICATION_MODE_ALWAYS
		)

		sync = MultiplayerSynchronizer.new()
		sync.name = SYNC_NODE_NAME
		sync.root_path = NodePath("..")
		sync.replication_config = config
		sync.set_multiplayer_authority(NetConfig.HOST_PEER_ID)
		filter = NetInterest.configure(sync, self, _entity_class)
		add_child(sync)

		# Nothing self-drives; the harness moves observers, not entities.
		set_process(false)
		set_physics_process(false)


func _check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		print("  ok    %s" % label)
	else:
		_failures += 1
		print("  FAIL  %s%s" % [label, ("  — " + detail) if detail != "" else ""])


func _initialize() -> void:
	print("=== MIRE 1.8 — interest management ===")
	print("Godot %s | %s" % [Engine.get_version_info()["string"], OS.get_name()])
	print("enter %.0f m, leave %.0f m | player %.1f Hz, enemy %.1f Hz, prop on-change (%.0f ms)" % [
		NetConfig.INTEREST_ENTER_RADIUS_M,
		NetConfig.INTEREST_LEAVE_RADIUS_M,
		NetConfig.PLAYER_SYNC_HZ,
		NetConfig.ENEMY_SYNC_HZ,
		NetConfig.PROP_DELTA_INTERVAL_SEC * 1000.0,
	])
	_run()


func _run() -> void:
	# Every API is polled by hand below, so the SceneTree must not also poll the default one.
	multiplayer_poll = false

	await _check_configuration()
	_check_filter_semantics()
	await _check_live_session()

	print("\n-- run integrity --")
	_check("all 3 sections ran to completion", _sections_done == 3,
		"%d of 3 — a script error aborted one" % _sections_done)

	print("")
	if _failures == 0:
		print("PASS — interest management configured, hysteretic, and enforced over a real wire")
	else:
		print("FAIL — %d check(s) failed" % _failures)
	_teardown()
	quit(1 if _failures > 0 else 0)


# ── 1. Configuration ──────────────────────────────────────────────────────────────────────────────


func _check_configuration() -> void:
	print("\n-- per-class configuration (§2.5) --")

	var expected: Array[Dictionary] = [
		{
			"class": NetInterest.Class.PLAYER,
			"interval": NetConfig.PLAYER_SYNC_INTERVAL_SEC,
			"delta": NetConfig.PLAYER_SYNC_INTERVAL_SEC,
			"filtered": false,
		},
		{
			"class": NetInterest.Class.ENEMY,
			"interval": NetConfig.ENEMY_SYNC_INTERVAL_SEC,
			"delta": NetConfig.ENEMY_SYNC_INTERVAL_SEC,
			"filtered": true,
		},
		{
			"class": NetInterest.Class.PROP,
			"interval": NetConfig.PROP_SYNC_INTERVAL_SEC,
			"delta": NetConfig.PROP_DELTA_INTERVAL_SEC,
			"filtered": true,
		},
	]

	var built: Array[InterestEntity] = []
	for row: Dictionary in expected:
		var entity := InterestEntity.new()
		entity.configure(built.size(), row["class"], Vector3.ZERO)
		root.add_child(entity)
		built.append(entity)

	# _ready() runs off the deferred queue: nothing above is in the tree yet.
	await process_frame

	for i: int in expected.size():
		var row: Dictionary = expected[i]
		var entity: InterestEntity = built[i]
		var label: String = NetInterest.CLASS_NAMES[row["class"]]
		var sync: MultiplayerSynchronizer = entity.sync

		_check("%s built a synchronizer" % label, sync != null)
		if sync == null:
			continue

		_check("%s replication_interval is %.4f s" % [label, row["interval"]],
			is_equal_approx(sync.replication_interval, float(row["interval"])),
			"got %.4f" % sync.replication_interval)
		_check("%s delta_interval is %.4f s" % [label, row["delta"]],
			is_equal_approx(sync.delta_interval, float(row["delta"])),
			"got %.4f" % sync.delta_interval)
		# D-024: one synchronizer, one member, joined at the single configuration seam.
		_check("%s joined %s" % [label, NetConfig.SYNCED_GROUP],
			sync.is_in_group(NetConfig.SYNCED_GROUP))

		if row["filtered"]:
			_check("%s has a visibility filter" % label, entity.filter != null)
			_check("%s synchronizer retains its filter target" % label,
				sync.get_meta(NetInterest.RADIUS_FILTER_META) == entity.filter)
			_check("%s re-evaluates on the physics tick, not the render frame" % label,
				sync.visibility_update_mode == MultiplayerSynchronizer.VISIBILITY_PROCESS_PHYSICS,
				"mode %d" % sync.visibility_update_mode)
		else:
			_check("%s is deliberately unfiltered" % label, entity.filter == null)
			_check("%s does not run visibility processing" % label,
				sync.visibility_update_mode == MultiplayerSynchronizer.VISIBILITY_PROCESS_NONE,
				"mode %d" % sync.visibility_update_mode)

	# There is no offline way to ask the engine what a filter answered. MultiplayerSynchronizer in
	# 4.7.1 exposes update_visibility(), set/get_visibility_for() and add/remove_visibility_filter()
	# — and get_visibility_for() reads back only the MANUAL per-peer override, not the filter result,
	# while update_visibility() pushes its answer straight into the replicator, which needs a live
	# session to exist at all. So "the engine actually calls our filter" is proven in part 3 and
	# nowhere else; that is why part 3 is not optional.

	print("\n-- the real player synchronizer goes through the same seam --")
	var player: Node = load("res://entities/player/player.tscn").instantiate()
	player.name = "1"  # named for a peer id, so it adopts spawn authority like a real spawn
	root.add_child(player)
	await process_frame
	var player_sync: MultiplayerSynchronizer = player.get_node_or_null(
		NodePath(NetConfig.PLAYER_SYNC_NODE)
	) as MultiplayerSynchronizer
	_check("PlayerController built a synchronizer", player_sync != null)
	if player_sync != null:
		_check("player replicates at %.0f Hz" % NetConfig.PLAYER_SYNC_HZ,
			is_equal_approx(player_sync.replication_interval, NetConfig.PLAYER_SYNC_INTERVAL_SEC),
			"got %.4f" % player_sync.replication_interval)
		_check("player is never distance-culled",
			player_sync.visibility_update_mode == MultiplayerSynchronizer.VISIBILITY_PROCESS_NONE)
		_check("player is still counted in %s" % NetConfig.SYNCED_GROUP,
			player_sync.is_in_group(NetConfig.SYNCED_GROUP))

	player.queue_free()
	for entity: InterestEntity in built:
		entity.queue_free()
	NetInterest.clear_observers()
	_sections_done += 1


# ── 2. Filter semantics ───────────────────────────────────────────────────────────────────────────


func _check_filter_semantics() -> void:
	print("\n-- hysteresis: the band is sticky in both directions --")

	var source := Node3D.new()
	source.name = "FilterSource"
	root.add_child(source)
	var filter := NetInterest.RadiusFilter.new(source)

	var enter: float = NetConfig.INTEREST_ENTER_RADIUS_M
	var leave: float = NetConfig.INTEREST_LEAVE_RADIUS_M
	# Squarely inside the band: further than the enter radius, nearer than the leave radius. This is
	# the distance where "was it visible last tick?" is the only thing that decides.
	var mid_band: float = (enter + leave) * 0.5

	NetInterest.clear_observers()
	_check("a peer with no observer sees nothing", not filter.evaluate(TEST_PEER))
	_check("the authoritative host stays addressable without an observer",
		filter.evaluate(NetConfig.HOST_PEER_ID))

	NetInterest.set_observer(TEST_PEER, Vector3.ZERO)

	source.position = Vector3(0.0, 0.0, leave + 20.0)
	_check("out of range: invisible", not filter.evaluate(TEST_PEER))

	source.position = Vector3(0.0, 0.0, mid_band)
	_check("approaching, still in the band: stays invisible", not filter.evaluate(TEST_PEER))

	source.position = Vector3(0.0, 0.0, enter - 1.0)
	_check("inside the enter radius: becomes visible", filter.evaluate(TEST_PEER))

	source.position = Vector3(0.0, 0.0, mid_band)
	_check("leaving, back in the band: stays VISIBLE", filter.evaluate(TEST_PEER))

	source.position = Vector3(0.0, 0.0, leave + 1.0)
	_check("past the leave radius: becomes invisible", not filter.evaluate(TEST_PEER))

	_check("one round trip cost exactly 2 transitions", filter.transitions == 2,
		"got %d" % filter.transitions)

	# Without hysteresis this is the flap 1.9 paid for on the reliable channel: 40 evaluations at a
	# distance that a single radius would put on the wrong side of the line every other tick.
	var before: int = filter.transitions
	for i: int in 20:
		source.position = Vector3(0.0, 0.0, mid_band)
		filter.evaluate(TEST_PEER)
		source.position = Vector3(0.0, 0.0, mid_band + 1.0)
		filter.evaluate(TEST_PEER)
	_check("40 evaluations loitering in the band cost 0 further transitions",
		filter.transitions == before, "got %d" % (filter.transitions - before))

	print("\n-- degenerate sources answer 'invisible' rather than erroring --")
	source.position = Vector3.ZERO
	_check("back in range: visible again", filter.evaluate(TEST_PEER))
	root.remove_child(source)
	_check("source out of the tree: invisible", not filter.evaluate(TEST_PEER))
	source.free()
	_check("source freed: invisible", not filter.evaluate(TEST_PEER))

	print("\n-- forgetting a peer resets it to the enter radius --")
	var second := Node3D.new()
	root.add_child(second)
	var f2 := NetInterest.RadiusFilter.new(second)
	second.position = Vector3.ZERO
	_check("visible at zero distance", f2.evaluate(TEST_PEER))
	second.position = Vector3(0.0, 0.0, mid_band)
	_check("sticky in the band", f2.evaluate(TEST_PEER))
	f2.forget(TEST_PEER)
	_check("after forget(), the band reads as out of range", not f2.evaluate(TEST_PEER))
	second.queue_free()

	NetInterest.clear_observers()
	_check("clear_observers() empties the registry", NetInterest.observer_count() == 0)
	_sections_done += 1


# ── 3. Live session ───────────────────────────────────────────────────────────────────────────────


func _check_live_session() -> void:
	print("\n-- live: 1 host + 2 clients, real ENet, real spawner --")

	if not _setup_peers():
		return
	if not await _connect():
		return

	# One entity at the origin. Client A's observer stands on it; client B's is a third of the island
	# away. Neither client is told where to look — the host decides what they are allowed to know.
	NetInterest.clear_observers()
	NetInterest.set_observer(_client_ids[0], Vector3.ZERO)
	NetInterest.set_observer(_client_ids[1], Vector3(0.0, 0.0, 300.0))

	_spawners[0].spawn({"index": 0, "class": NetInterest.Class.ENEMY, "at": Vector3.ZERO})
	await _pump(1.0)

	_check("host has the entity", _containers[0].get_child_count() == 1,
		"%d children" % _containers[0].get_child_count())
	_check("near client received it", _containers[1].get_child_count() == 1,
		"%d children" % _containers[1].get_child_count())
	_check("far client was never sent it", _containers[2].get_child_count() == 0,
		"%d children" % _containers[2].get_child_count())

	# Walk the far client in. Nothing about the entity changes — only where its owner is looking from.
	NetInterest.set_observer(_client_ids[1], Vector3(0.0, 0.0, 50.0))
	await _pump(1.0)
	_check("walking in spawns it on that client", _containers[2].get_child_count() == 1,
		"%d children" % _containers[2].get_child_count())

	# Back out to the middle of the hysteresis band. A single 120 m radius would drop it here.
	var mid_band: float = (NetConfig.INTEREST_ENTER_RADIUS_M
		+ NetConfig.INTEREST_LEAVE_RADIUS_M) * 0.5
	NetInterest.set_observer(_client_ids[1], Vector3(0.0, 0.0, mid_band))
	await _pump(1.0)
	_check("loitering in the band keeps it (hysteresis, over the wire)",
		_containers[2].get_child_count() == 1, "%d children" % _containers[2].get_child_count())

	# Past the leave radius for real.
	NetInterest.set_observer(_client_ids[1], Vector3(0.0, 0.0, 300.0))
	await _pump(1.0)
	_check("past the leave radius despawns it on that client",
		_containers[2].get_child_count() == 0, "%d children" % _containers[2].get_child_count())
	_check("the near client never lost it", _containers[1].get_child_count() == 1,
		"%d children" % _containers[1].get_child_count())

	# And the band is sticky from outside too — 130 m must NOT re-spawn it.
	NetInterest.set_observer(_client_ids[1], Vector3(0.0, 0.0, mid_band))
	await _pump(1.0)
	_check("re-approaching into the band does not respawn it",
		_containers[2].get_child_count() == 0, "%d children" % _containers[2].get_child_count())

	var host_entity: InterestEntity = _host_entities[0] as InterestEntity
	if host_entity != null and host_entity.filter != null:
		var churn: int = host_entity.filter.transitions
		print("  info  host-side visibility transitions across the whole walk: %d" % churn)
		# Two peers: the near client entered once (1) and the far one entered and left once (2).
		_check("transition count matches the walk", churn == 3, "got %d" % churn)
	_sections_done += 1


func _setup_peers() -> bool:
	for i: int in PEER_COUNT:
		var peer_root := Node.new()
		peer_root.name = "Peer%d" % i
		root.add_child(peer_root)

		var api: MultiplayerAPI = MultiplayerAPI.create_default_interface()
		# Registered before any child is added, so everything below binds to this API and not to the
		# process-wide default one.
		set_multiplayer(api, NodePath("/root/Peer%d" % i))

		var enet := ENetMultiplayerPeer.new()
		var err: Error = (
			enet.create_server(PORT, PEER_COUNT - 1)
			if i == 0
			else enet.create_client(NetConfig.LOOPBACK_ADDRESS, PORT)
		)
		if err != OK:
			_check("peer %d started" % i, false, error_string(err))
			return false
		api.multiplayer_peer = enet

		var container := Node3D.new()
		container.name = "Entities"
		peer_root.add_child(container)

		var spawner := MultiplayerSpawner.new()
		spawner.name = "Spawner"
		spawner.spawn_path = NodePath("../Entities")
		spawner.spawn_limit = 8
		spawner.spawn_function = _spawn_entity.bind(i)
		peer_root.add_child(spawner)

		_apis.append(api)
		_enet.append(enet)
		_containers.append(container)
		_spawners.append(spawner)

	return true


## Runs on every peer: on the host because it called spawn(), on each client when the spawn packet
## lands. Same data in, same node out — which is the whole of D-023.
func _spawn_entity(data: Variant, peer_index: int) -> Node:
	var info: Dictionary = data as Dictionary
	var entity := InterestEntity.new()
	entity.configure(int(info["index"]), info["class"], info["at"])
	if peer_index == 0:
		_host_entities.append(entity)
	return entity


func _connect() -> bool:
	var deadline: int = Time.get_ticks_usec() + int(CONNECT_TIMEOUT_SEC * 1_000_000.0)
	while Time.get_ticks_usec() < deadline:
		await process_frame
		_poll_all()
		if _apis[0].get_peers().size() == PEER_COUNT - 1:
			break
		OS.delay_usec(int(FRAME_SEC * 1_000_000.0))

	var connected: int = _apis[0].get_peers().size()
	_check("both clients connected", connected == PEER_COUNT - 1, "%d connected" % connected)
	if connected != PEER_COUNT - 1:
		return false

	# In peer order, so _client_ids[0] is the API at _apis[1]. ENet ids are random, not 2 and 3.
	for i: int in range(1, PEER_COUNT):
		_client_ids.append(_apis[i].get_unique_id())
	return true


func _poll_all() -> void:
	for api: MultiplayerAPI in _apis:
		api.poll()


## Run the loop at a real 60 Hz for [param seconds]. Both halves matter: polling moves the packets,
## and the wall-clock pacing is what lets physics ticks accumulate — visibility is re-evaluated on
## the physics tick, and a free-running headless loop would spin ~150 process frames between two of
## them and make the result depend on how fast this machine is.
func _pump(seconds: float) -> void:
	for i: int in int(seconds / FRAME_SEC):
		await process_frame
		_poll_all()
		OS.delay_usec(int(FRAME_SEC * 1_000_000.0))


## Entities out of the tree BEFORE the sockets close. A synchronizer freed while its peer is already
## gone tries to send one last packet and logs "the multiplayer instance isn't currently active" —
## noise that reads exactly like a failure in a harness whose whole output is pass/fail lines.
func _teardown() -> void:
	for i: int in _containers.size():
		var peer_root: Node = root.get_node_or_null(NodePath("Peer%d" % i))
		if peer_root != null:
			root.remove_child(peer_root)
			peer_root.free()
	for enet: ENetMultiplayerPeer in _enet:
		enet.close()
	NetInterest.clear_observers()
