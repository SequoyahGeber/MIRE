extends SceneTree

## F-330: a client must not stream terrain around other people's players.
##
## `ProceduralWorld._physics_process()` used to hand `ChunkStreamer` the whole `players` group on
## every peer. The host needs that union — it owns the authoritative world every peer acts in
## (F-132) — but a client only renders and simulates around its own viewpoint, and `ChunkStreamer`
## multiplies an anchor list in three places at once:
##
##   * `_ring_distance()` is a MINIMUM over anchors, so every anchor earns its own LOD0 ring and
##     therefore its own block of cooked colliders (~1.33 ms each by `bench_chunk_gpu.gd`)
##   * `_evaluate_rings()` scans a 19x19 candidate box PER anchor, every 0.2 s
##   * the resident set is the union of every anchor's neighbourhood
##
## Two phases:
##
##   A. **Policy** — `_stream_anchors()` returns one anchor off-host and every player on-host. Read
##      straight off the shipped method, with a real `NetTransport` LAN session for the host case
##      rather than a stubbed flag, because "am I the host" is the entire decision being tested.
##   B. **Budget** — what that policy actually costs, measured through `ChunkStreamer.prime()`, which
##      cooks each anchor's collision block synchronously and returns how many it cooked. A client
##      must cook exactly the single-anchor number; the host's must be strictly larger, or the check
##      has no teeth and would keep passing if `_stream_anchors()` were reverted to the union.
##
##   .agent/bin/agent godot --script tools/client_stream_budget_check.gd
##
## Authority: this check reads the host/client split in docs/ARCHITECTURE.md §2.2's world-streaming
## row. It opens a real LAN host on a non-default port so a concurrent check cannot collide with it.

const ProceduralWorldScript := preload("res://world/gen/procedural_world.gd")

## Far enough apart that no two players' collision blocks touch. `prime()` cooks a 3x3 chunk block
## (PRIME_RADIUS_CHUNKS = 1) at 32 m per chunk, so anchors three chunks apart cannot overlap — which
## is what makes the cooked counts add up cleanly instead of partially cancelling.
const PARTY_POSITIONS: Array = [
	Vector3(0.0, 0.0, 0.0),
	Vector3(96.0, 0.0, 0.0),
	Vector3(-96.0, 0.0, 0.0),
	Vector3(0.0, 0.0, 96.0),
	Vector3(0.0, 0.0, -96.0),
	Vector3(96.0, 0.0, 96.0),
]
## Deliberately not `NetConfig.DEFAULT_PORT`: several checks run concurrently under one lock queue
## and a bound default port is the kind of collision that reads as a product failure.
const CHECK_PORT: int = 27_931
const TEST_SEED: int = 4242

var failures: int = 0
var _transport: Node = null


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	_transport = root.get_node_or_null(^"NetTransport")
	if _transport == null:
		push_error("FAIL: NetTransport autoload missing")
		quit(1)
		return

	await _check_anchor_policy()
	await _check_collider_budget()

	if bool(_transport.call("is_host")):
		_transport.call("leave")
		await process_frame
	print("\nCLIENT_STREAM_BUDGET_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)


## Phase A — who this peer streams around, read off the shipped method.
func _check_anchor_policy() -> void:
	print("\n== A · a client anchors on itself, the host on everyone ==")
	var world: Node3D = await _build_world()
	var party: Array[Node3D] = _spawn_party(world)
	check(party.size() == PARTY_POSITIONS.size(),
		"%d player bodies in the players group" % PARTY_POSITIONS.size())

	# Offline first. `is_host()` is false with no session, and the local body holds its own
	# authority, so this is also the shape a real single-player run runs in.
	check(not bool(_transport.call("is_host")), "no session yet, so this peer is not the host")
	var client_anchors: Array = world.call(&"_stream_anchors")
	check(client_anchors.size() == 1,
		"off-host, %d player(s) produce ONE anchor (got %d)" % [party.size(), client_anchors.size()])
	if client_anchors.size() == 1:
		check(client_anchors[0].is_equal_approx(PARTY_POSITIONS[0]),
			"that anchor is this peer's own player, not someone else's")

	var err: int = int(_transport.call("host", NetConfig.Mode.LAN, CHECK_PORT))
	check(err == OK, "opened a LAN host on port %d (%s)" % [CHECK_PORT, error_string(err)])
	if err != OK:
		world.queue_free()
		return
	await process_frame
	check(bool(_transport.call("is_host")), "this peer now reports itself host")

	# Against the LIVE group, not this check's own party: opening a session makes `PlayerNet` spawn
	# the host's own player, and that body is a real player the host must stream around. The contract
	# is "every player in the group", so that is what is asserted.
	var live_players: int = get_nodes_in_group(&"players").size()
	var host_anchors: Array = world.call(&"_stream_anchors")
	check(host_anchors.size() == live_players,
		"on-host, every player in the group is an anchor (%d of %d, party of %d + any PlayerNet spawned)"
			% [host_anchors.size(), live_players, party.size()])
	check(host_anchors.size() > client_anchors.size(),
		"and the host anchors on strictly more than the client does (%d vs %d)"
			% [host_anchors.size(), client_anchors.size()])

	_transport.call("leave")
	await process_frame
	check(not bool(_transport.call("is_host")), "session closed again")
	world.queue_free()
	await process_frame


## Phase B — what the policy costs, in colliders actually cooked.
##
## `prime()` is the measurement seam because it is synchronous and returns its own count: no
## settling, no frame budget, no timing. The number it returns for a policy's anchors is exactly the
## per-anchor collision work that policy commits the peer to on every ring evaluation afterwards.
func _check_collider_budget() -> void:
	print("\n== B · the anchor policy is what the collision budget costs ==")

	var solo_world: Node3D = await _build_world()
	_spawn_party(solo_world, 1)
	var solo_cooked: int = _prime_cost(solo_world)
	check(solo_cooked > 0, "a lone player cooks %d collider(s)" % solo_cooked)
	solo_world.queue_free()
	await process_frame

	var client_world: Node3D = await _build_world()
	_spawn_party(client_world)
	var client_cooked: int = _prime_cost(client_world)
	check(client_cooked == solo_cooked,
		"a CLIENT with %d players cooks the same %d collider(s) as a lone player (got %d)"
			% [PARTY_POSITIONS.size(), solo_cooked, client_cooked])
	client_world.queue_free()
	await process_frame

	# The negative control. If the host number ever equals the client number, the two policies have
	# stopped differing and phase A's assertion above would pass on a reverted fix.
	var host_world: Node3D = await _build_world()
	_spawn_party(host_world)
	var err: int = int(_transport.call("host", NetConfig.Mode.LAN, CHECK_PORT))
	check(err == OK, "reopened the LAN host for the negative control (%s)" % error_string(err))
	await process_frame
	var host_cooked: int = _prime_cost(host_world)
	check(host_cooked > client_cooked,
		"a HOST with the same party cooks strictly more (%d vs %d) — the policies really differ"
			% [host_cooked, client_cooked])
	print("  budget: solo %d · client %d · host %d collider(s) for %d separated player(s)"
		% [solo_cooked, client_cooked, host_cooked, PARTY_POSITIONS.size()])
	host_world.queue_free()
	await process_frame


## Colliders `prime()` cooks for whatever `_stream_anchors()` decides — the shipped policy, not a
## list this check assembles.
func _prime_cost(world: Node3D) -> int:
	var streamer: Node = world.get(&"streamer") as Node
	if streamer == null:
		fail("world has no ChunkStreamer")
		return -1
	return int(streamer.call(&"prime", world.call(&"_stream_anchors")))


func _build_world() -> Node3D:
	if current_scene != null:
		current_scene.queue_free()
		await process_frame
	var scene := Node3D.new()
	scene.name = "ClientStreamBudgetScene"
	root.add_child(scene)
	current_scene = scene

	var game_state: Node = root.get_node_or_null(^"GameState")
	if game_state != null:
		game_state.set("run_seed", TEST_SEED)
		game_state.set("_seed_ready", true)

	var world: Node3D = ProceduralWorldScript.new()
	world.set(&"build_player", false)
	scene.add_child(world)
	await process_frame
	return world


## A party in the `players` group where exactly ONE body holds this peer's authority, which is what
## `_local_player_body()` keys on. Without the explicit authority ids every body would answer yes —
## the local peer id is 1 both offline and while hosting — and the client branch would be untestable.
func _spawn_party(world: Node3D, count: int = -1) -> Array[Node3D]:
	var wanted: int = PARTY_POSITIONS.size() if count < 0 else count
	# `get_multiplayer()`, not the bare `multiplayer` property: that shorthand belongs to `Node`, and
	# this check extends `SceneTree`, where the identifier does not exist.
	var local_id: int = get_multiplayer().get_unique_id()
	var party: Array[Node3D] = []
	for i: int in wanted:
		var body := Node3D.new()
		body.name = "StreamBudgetPlayer%d" % i
		world.add_child(body)
		body.global_position = PARTY_POSITIONS[i]
		# Body 0 is "us"; the rest are remote peers whose ids cannot collide with the local one.
		body.set_multiplayer_authority(local_id if i == 0 else 1000 + i)
		body.add_to_group(&"players")
		party.append(body)
	return party


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	fail(description)


func fail(description: String) -> void:
	failures += 1
	push_error("FAIL: %s" % description)
