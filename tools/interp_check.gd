extends SceneTree

## Task 1.6 — proof that remote-player interpolation actually removes the stutter. Run headless:
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/interp_check.gd
##
## Exits non-zero if any check fails, so it is usable as a gate. It follows the pattern of
## tools/bench_replication.gd rather than inventing a fourth harness shape: real peers, real ENet,
## one process, paced against a real wall clock.
##
## It answers F-004 with a measurement instead of an argument. Both control streams are sampled
## through Node3D.get_global_transform_interpolated() — the transform the camera actually draws with
## `physics/common/physics_interpolation` on — so the comparison is "engine interpolation alone" vs
## "engine interpolation plus snapshot interpolation", not "nothing vs something".
##
## Three phases:
##   A · synthetic — 30 Hz arrivals with jitter and 6% loss, driven straight into RemoteInterpolator.
##       This is where the hard cases live, because loopback has neither jitter nor loss.
##   B · teleport  — a 100 m jump must snap, not smear across the level for a second.
##   C · live      — two real ENet peers, a real player.tscn spawned by a real MultiplayerSpawner,
##       measured with the interpolator off and then on. This is what proves the wiring.
##
## AUTHORITY: none. Interpolation is client-local presentation (docs/ARCHITECTURE.md §2.2, last row).

const RemoteInterp = preload("res://core/net/remote_interp.gd")
const PLAYER_SCENE: PackedScene = preload("res://entities/player/player.tscn")

## Not NetConfig.DEFAULT_PORT and not the bench's 27615: several headless runs share this working
## directory and a shared port fails confusingly rather than loudly.
const CHECK_PORT: int = 27715

## Frames per second we pace to. Above the 60 Hz physics rate on purpose — a high-refresh display is
## exactly where 30 Hz replication looks worst, and this machine has one.
const RENDER_HZ: float = 120.0

## Nominal arrival rate, matching NetConfig.PLAYER_SYNC_HZ.
const SEND_HZ: float = 30.0

## Arrival jitter, ± seconds. Real numbers for a home connection; loopback has none of this.
const JITTER_SEC: float = 0.008

## Every Nth packet is dropped. 1 in 17 is ~6% — bad but not pathological.
const DROP_EVERY: int = 17

## Sprint speed, so the numbers are the scale of real gameplay.
const SPEED_MPS: float = 6.0

const PHASE_A_SEC: float = 4.0
const LIVE_PASS_SEC: float = 3.0
const WARMUP_SEC: float = 0.6
const CONNECT_TIMEOUT_SEC: float = 10.0
const SPAWN_TIMEOUT_SEC: float = 10.0

# Thresholds. A "still frame" is one where the node moved less than 5% of its average per-frame
# distance — i.e. it visibly stopped. That is the stutter, expressed as a number.
const STILL_THRESHOLD: float = 0.05
const MAX_INTERP_STILL_PCT: float = 5.0
const MIN_CONTROL_STILL_PCT: float = 25.0
const MAX_INTERP_CV: float = 0.35

var _failures: PackedStringArray = PackedStringArray()
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()

# Live phase.
var _apis: Array[MultiplayerAPI] = []
var _enet: Array[ENetMultiplayerPeer] = []
var _containers: Array[Node3D] = []
var _spawners: Array[MultiplayerSpawner] = []
var _host_body: Node3D = null


func _initialize() -> void:
	_rng.seed = 20260816
	print("=== MIRE 1.6 — remote-player interpolation check ===")
	print("Godot %s | %s | render %.0f Hz, send %.0f Hz, jitter ±%.0f ms, drop 1 in %d" % [
		Engine.get_version_info()["string"], OS.get_name(), RENDER_HZ, SEND_HZ,
		JITTER_SEC * 1000.0, DROP_EVERY,
	])
	print("physics_interpolation=%s (project setting) — controls below are sampled through" % [
		ProjectSettings.get_setting("physics/common/physics_interpolation", false),
	])
	print("get_global_transform_interpolated(), so the engine's own smoothing is included in them.")
	print("")
	_run()


func _run() -> void:
	await _phase_synthetic()
	await _phase_teleport()
	await _phase_live()

	print("")
	# `agent verify` reads this line and fails the check outright when it is absent — an explicit,
	# greppable verdict is what stops a half-finished or crashed run passing by saying nothing
	# (F-293). This check reported in prose but never in that shape, so it was red however green
	# it ran (F-555).
	print("INTERP_CHECK failures=%d" % _failures.size())
	if _failures.is_empty():
		print("PASS — all checks met")
		quit(0)
		return
	print("FAIL — %d check(s):" % _failures.size())
	for line: String in _failures:
		print("  · %s" % line)
	quit(1)


# ── Phase A · synthetic arrivals ──────────────────────────────────────────────────────────────────
#
# The interpolator is driven directly, with no network involved, so jitter and loss are exact and
# reproducible instead of whatever loopback happened to do. A control node receives the identical
# arrivals applied straight to its transform — which is what the game does today.


func _phase_synthetic() -> void:
	print("[A] synthetic — %.0f s, straight-line motion at %.0f m/s" % [PHASE_A_SEC, SPEED_MPS])

	var control: Node3D = _make_body("ControlA")
	var smoothed: Node3D = _make_body("SmoothedA")

	var interp: RemoteInterp = RemoteInterp.new()
	interp.name = "RemoteInterp"
	interp.configure(smoothed, smoothed.get_node(^"CameraPivot") as Node3D)
	smoothed.add_child(interp)

	var control_samples: PackedVector3Array = PackedVector3Array()
	var smoothed_samples: PackedVector3Array = PackedVector3Array()

	var frame_usec: int = int(1_000_000.0 / RENDER_HZ)
	var send_sec: float = 1.0 / SEND_HZ
	var start_usec: int = Time.get_ticks_usec()
	var next_frame_usec: int = start_usec
	var next_send: float = 0.0
	var sent: int = 0
	var delivered: int = 0

	while true:
		next_frame_usec += frame_usec
		var elapsed: float = float(Time.get_ticks_usec() - start_usec) / 1_000_000.0
		if elapsed >= PHASE_A_SEC:
			break

		while next_send <= elapsed:
			# The state the owner had at the moment this packet left, not at the moment it lands —
			# that difference is what an arrival-time buffer is for.
			var state: Array = _true_state(next_send)
			sent += 1
			if sent % DROP_EVERY != 0:
				delivered += 1
				interp.push_snapshot(state[0], state[1], state[2])
				control.position = state[0]
				control.rotation.y = state[1]
			next_send += send_sec + _rng.randf_range(-JITTER_SEC, JITTER_SEC)

		await _wait_until(next_frame_usec)
		control_samples.append(_drawn_position(control))
		smoothed_samples.append(_drawn_position(smoothed))

	var control_stats: Dictionary = _motion_stats(control_samples)
	var smoothed_stats: Dictionary = _motion_stats(smoothed_samples)
	print("     %d packets sent, %d delivered (%.1f%% lost)" % [
		sent, delivered, 100.0 * float(sent - delivered) / maxf(float(sent), 1.0),
	])
	_print_stats("engine interp only", control_stats)
	_print_stats("+ RemoteInterpolator", smoothed_stats)

	var stats: Dictionary = interp.debug_stats()
	print("     derived delay %.1f ms from a measured %.1f ms arrival interval; %d/%d frames starved" % [
		stats["delay_ms"], stats["interval_ms"], stats["starved_frames"], stats["frames"],
	])

	_expect(
		float(control_stats["still_pct"]) >= MIN_CONTROL_STILL_PCT,
		"A: control should visibly stutter, but only %.1f%% of frames were still — the test cannot see the problem it exists to measure" % control_stats["still_pct"]
	)
	_expect(
		float(smoothed_stats["still_pct"]) <= MAX_INTERP_STILL_PCT,
		"A: interpolated stream still stutters — %.1f%% still frames (limit %.1f%%)" % [
			smoothed_stats["still_pct"], MAX_INTERP_STILL_PCT,
		]
	)
	_expect(
		float(smoothed_stats["cv"]) <= MAX_INTERP_CV,
		"A: interpolated per-frame motion is uneven — CV %.3f (limit %.2f)" % [
			smoothed_stats["cv"], MAX_INTERP_CV,
		]
	)

	control.queue_free()
	smoothed.queue_free()
	await process_frame


# ── Phase B · teleport ────────────────────────────────────────────────────────────────────────────


func _phase_teleport() -> void:
	print("")
	print("[B] teleport — a %.0f m jump must snap, not be drawn as movement" % 100.0)

	var body: Node3D = _make_body("TeleportB")
	var interp: RemoteInterp = RemoteInterp.new()
	interp.name = "RemoteInterp"
	interp.configure(body, body.get_node(^"CameraPivot") as Node3D)
	body.add_child(interp)

	# A short normal stream first, so the buffer is warm and would happily interpolate.
	for i: int in 8:
		interp.push_snapshot(Vector3(float(i) * 0.2, 0.0, 0.0), 0.0, 0.0)
		await _wait_until(Time.get_ticks_usec() + 33_000)

	var destination: Vector3 = Vector3(100.0, 0.0, 0.0)
	interp.push_snapshot(destination, 0.0, 0.0)
	await process_frame
	await process_frame

	var drawn: Vector3 = body.position
	var error: float = drawn.distance_to(destination)
	print("     drawn %.2f m from the destination after 2 frames; %d teleport(s) detected" % [
		error, interp.debug_stats()["teleports"],
	])
	_expect(error < 1.0, "B: teleport was interpolated through — drawn %.1f m short of the destination" % error)
	_expect(int(interp.debug_stats()["teleports"]) == 1, "B: teleport not detected")

	body.queue_free()
	await process_frame


# ── Phase C · live, over real ENet ────────────────────────────────────────────────────────────────


func _phase_live() -> void:
	print("")
	print("[C] live — 2 ENet peers in one process, a real player.tscn spawned by MultiplayerSpawner")

	if not _setup_peers():
		_expect(false, "C: peers could not be created")
		return
	if not await _await_connection():
		_expect(false, "C: client never connected")
		return

	var client_body: Node3D = await _spawn_and_receive()
	if client_body == null:
		_expect(false, "C: the client never received the host's player")
		return

	# The host copy is authoritative and runs its own physics; headless there is no floor, so leave
	# it running and it falls forever and move_and_slide() overwrites everything we set. We are
	# measuring replication, not movement, so drive the transform directly instead.
	_host_body.set_physics_process(false)

	print("     client sees %s, authority %d, local id %d — %s" % [
		client_body.name, client_body.get_multiplayer_authority(), _apis[1].get_unique_id(),
		"remote" if not client_body.is_multiplayer_authority() else "LOCAL (wrong)",
	])
	_expect(
		not client_body.is_multiplayer_authority(),
		"C: the client thinks it owns the host's player — nothing below means anything"
	)

	var control: Dictionary = await _live_pass(client_body, LIVE_PASS_SEC)
	_print_stats("engine interp only", control)

	var net_interp: Node = root.get_node_or_null(^"/root/NetInterp")
	_expect(net_interp != null, "C: NetInterp autoload is not registered")
	if net_interp == null:
		return
	_expect(
		bool(net_interp.call("is_watching")),
		"C: NetInterp did not find PlayerNet's container — spawned players would never be smoothed"
	)
	_expect(
		bool(net_interp.call("attach_to", client_body)),
		"C: NetInterp refused to attach an interpolator to a remote player"
	)

	await _live_pass(client_body, WARMUP_SEC)
	var smoothed: Dictionary = await _live_pass(client_body, LIVE_PASS_SEC)
	_print_stats("+ RemoteInterpolator", smoothed)

	var lag_m: float = absf(_host_body.position.x - client_body.position.x)
	print("     drawn %.2f m behind the host = %.0f ms of deliberate latency, the price of the above" % [
		lag_m, 1000.0 * lag_m / SPEED_MPS,
	])

	_expect(
		float(control["still_pct"]) >= MIN_CONTROL_STILL_PCT,
		"C: control should visibly stutter, but only %.1f%% of frames were still" % control["still_pct"]
	)
	_expect(
		float(smoothed["still_pct"]) <= MAX_INTERP_STILL_PCT,
		"C: interpolated stream still stutters — %.1f%% still frames (limit %.1f%%)" % [
			smoothed["still_pct"], MAX_INTERP_STILL_PCT,
		]
	)
	_expect(
		float(smoothed["cv"]) <= MAX_INTERP_CV,
		"C: interpolated per-frame motion is uneven — CV %.3f (limit %.2f)" % [
			smoothed["cv"], MAX_INTERP_CV,
		]
	)

	print("     CAVEAT: loopback has no latency, no jitter and no loss. Phase A is where those are")
	print("     exercised; this phase proves the wiring, the spawner path and the authority check.")

	# Order matters on the way out: take the replicated subtree off the tree first so the
	# synchronizers deregister, then detach the peer, then close the socket. Closing underneath a
	# live MultiplayerAPI leaves it polling a dead peer and it says so, loudly, after a passing run.
	for i: int in _enet.size():
		var peer_root: Node = _containers[i].get_parent()
		root.remove_child(peer_root)
		peer_root.queue_free()
		_apis[i].multiplayer_peer = null
		_enet[i].close()
	await process_frame


## Two peers, each with its own MultiplayerAPI, socket and replication state — the same
## one-process-many-peers trick tools/bench_replication.gd documents.
func _setup_peers() -> bool:
	for i: int in 2:
		var peer_root: Node = Node.new()
		peer_root.name = "Peer%d" % i
		root.add_child(peer_root)

		var api: MultiplayerAPI = MultiplayerAPI.create_default_interface()
		# Registered before any child is added, so everything below binds to this API and not to the
		# process-wide default one.
		set_multiplayer(api, NodePath("/root/Peer%d" % i))

		var enet: ENetMultiplayerPeer = ENetMultiplayerPeer.new()
		var err: Error = (
			enet.create_server(CHECK_PORT, 1)
			if i == 0
			else enet.create_client(NetConfig.LOOPBACK_ADDRESS, CHECK_PORT)
		)
		if err != OK:
			print("     peer %d failed: %s" % [i, error_string(err)])
			return false
		api.multiplayer_peer = enet

		var container: Node3D = Node3D.new()
		container.name = NetConfig.PLAYER_CONTAINER_NODE
		peer_root.add_child(container)

		var spawner: MultiplayerSpawner = MultiplayerSpawner.new()
		spawner.name = NetConfig.PLAYER_SPAWNER_NODE
		spawner.spawn_path = NodePath("../%s" % NetConfig.PLAYER_CONTAINER_NODE)
		spawner.spawn_limit = 4
		spawner.spawn_function = _spawn_player.bind(i)
		peer_root.add_child(spawner)

		_apis.append(api)
		_enet.append(enet)
		_containers.append(container)
		_spawners.append(spawner)

	return true


## Runs on both peers — on the host because it called spawn(), on the client when the packet lands.
## Authority is set here, before the node enters the tree (F-012), and the controller re-derives the
## same value from the node's name.
func _spawn_player(data: Variant, peer_index: int) -> Node:
	var body: Node3D = PLAYER_SCENE.instantiate() as Node3D
	body.name = str(int(data))
	body.position = Vector3.ZERO
	body.set_multiplayer_authority(int(data))
	if peer_index == 0:
		_host_body = body
	return body


func _await_connection() -> bool:
	var deadline: int = Time.get_ticks_usec() + int(CONNECT_TIMEOUT_SEC * 1_000_000.0)
	while Time.get_ticks_usec() < deadline:
		await process_frame
		if _apis[1].get_unique_id() > 1 and _apis[0].get_peers().size() == 1:
			print("     connected: host id %d, client id %d" % [
				_apis[0].get_unique_id(), _apis[1].get_unique_id(),
			])
			return true
	return false


func _spawn_and_receive() -> Node3D:
	_spawners[0].spawn(NetConfig.HOST_PEER_ID)
	var deadline: int = Time.get_ticks_usec() + int(SPAWN_TIMEOUT_SEC * 1_000_000.0)
	while Time.get_ticks_usec() < deadline:
		await process_frame
		if _containers[1].get_child_count() > 0:
			return _containers[1].get_child(0) as Node3D
	return null


## Move the host's player in a straight line for [param seconds], sampling what the client draws.
func _live_pass(client_body: Node3D, seconds: float) -> Dictionary:
	var samples: PackedVector3Array = PackedVector3Array()
	var frame_usec: int = int(1_000_000.0 / RENDER_HZ)
	var start_usec: int = Time.get_ticks_usec()
	var next_frame_usec: int = start_usec
	var previous_usec: int = start_usec

	while true:
		next_frame_usec += frame_usec
		var now_usec: int = Time.get_ticks_usec()
		if float(now_usec - start_usec) / 1_000_000.0 >= seconds:
			break
		_host_body.position.x += SPEED_MPS * float(now_usec - previous_usec) / 1_000_000.0
		previous_usec = now_usec
		await _wait_until(next_frame_usec)
		samples.append(_drawn_position(client_body))

	return _motion_stats(samples)


# ── Measurement ───────────────────────────────────────────────────────────────────────────────────


## What the camera would draw this frame. With physics interpolation on, that is NOT `position` —
## reading the property would hand the control stream a disadvantage it does not actually have, and
## the whole point of this harness is to compare the two mechanisms honestly.
func _drawn_position(node: Node3D) -> Vector3:
	if node.has_method(&"get_global_transform_interpolated"):
		return node.get_global_transform_interpolated().origin
	return node.global_position


## Per-frame distance moved, reduced to the three numbers that describe judder:
##   still_pct — frames where the node barely moved. This is the stutter you see.
##   cv        — spread of per-frame distance over its mean. Constant motion tends to 0.
##   peak      — largest single-frame jump as a multiple of the mean. This is the lurch after a stall.
func _motion_stats(samples: PackedVector3Array) -> Dictionary:
	var count: int = samples.size() - 1
	if count < 2:
		return {"still_pct": 100.0, "cv": 99.0, "peak": 99.0, "mean_mm": 0.0, "frames": samples.size()}

	var deltas: PackedFloat64Array = PackedFloat64Array()
	deltas.resize(count)
	var total: float = 0.0
	for i: int in count:
		var d: float = samples[i + 1].distance_to(samples[i])
		deltas[i] = d
		total += d

	var mean: float = total / float(count)
	if mean <= 0.0:
		return {"still_pct": 100.0, "cv": 99.0, "peak": 0.0, "mean_mm": 0.0, "frames": samples.size()}

	var variance: float = 0.0
	var still: int = 0
	var peak: float = 0.0
	for i: int in count:
		var d: float = deltas[i]
		variance += (d - mean) * (d - mean)
		if d < mean * STILL_THRESHOLD:
			still += 1
		peak = maxf(peak, d)

	return {
		"still_pct": 100.0 * float(still) / float(count),
		"cv": sqrt(variance / float(count)) / mean,
		"peak": peak / mean,
		"mean_mm": mean * 1000.0,
		"frames": samples.size(),
	}


func _print_stats(label: String, stats: Dictionary) -> void:
	print("     %-22s %5.1f%% still frames | CV %5.3f | peak %5.2fx mean | %.2f mm/frame over %d" % [
		label, stats["still_pct"], stats["cv"], stats["peak"], stats["mean_mm"], stats["frames"],
	])


# ── Helpers ───────────────────────────────────────────────────────────────────────────────────────


## The owner's true state at [param t]. Straight-line motion and triangle-wave angles: no trig, so
## this reproduces bit-for-bit anywhere it is ever run (D-017).
func _true_state(t: float) -> Array:
	var pitch: float = absf(wrapf(t, -1.0, 1.0)) * 0.5
	return [Vector3(t * SPEED_MPS, 0.0, 0.0), wrapf(t, -PI, PI), pitch]


func _make_body(body_name: String) -> Node3D:
	var body: Node3D = Node3D.new()
	body.name = body_name
	var pivot: Node3D = Node3D.new()
	pivot.name = "CameraPivot"
	body.add_child(pivot)
	root.add_child(body)
	return body


func _wait_until(usec: int) -> void:
	var remaining: int = usec - Time.get_ticks_usec()
	if remaining > 0:
		OS.delay_usec(remaining)
	await process_frame


func _expect(condition: bool, failure: String) -> void:
	if not condition:
		_failures.append(failure)
