extends SceneTree

## SPIKE R1 (task 1.9) — replication load. Throwaway. Run headless:
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/bench_replication.gd
##
## Answers one question with measurements: can Godot 4.7's high-level multiplayer carry 6 peers and
## 200 synced entities? (docs/ARCHITECTURE.md §6, risk R1.) Prints numbers only; the verdict goes in
## docs/DECISIONS.md.
##
## HOW SIX PEERS FIT IN ONE PROCESS. SceneTree.set_multiplayer(api, root_path) registers a separate
## MultiplayerAPI per subtree, so /root/Peer0 … /root/Peer5 each get their own peer, their own ENet
## socket and their own replication state. Node paths resolve relative to each API's root, so the
## host's Peer0/Entities/d17 and a client's Peer3/Entities/d17 are the same node to the high-level
## API. This is real ENet over real loopback sockets — real serialization, real packets, one process.
## What that does and does not measure is spelled out in the caveats at the end of the run.
##
## AUTHORITY (docs/ARCHITECTURE.md §2.2): host-authoritative. The host owns every dummy; clients only
## receive. No client is given authority over anything.

# Preloaded rather than referenced by class_name, matching tools/bench_chunks.gd: a --script run
# should not depend on the editor having refreshed the global class cache.
const Dummy = preload("res://core/net/dummy_replicant.gd")

const ENTITY_COUNT: int = 200

## Deliberately NOT NetConfig.DEFAULT_PORT. Task 1.5 is in flight in this same working directory and
## runs headless host/client pairs on 27515; a shared port would make either run fail confusingly.
const BENCH_PORT: int = 27615

const BENCH_SEED: int = 20260816

## The bench paces itself to a real 60 Hz wall clock. It has to: replication_interval is measured in
## seconds, so a free-running headless loop would poll thousands of times a second and make both the
## bandwidth and the ms/frame figures meaningless.
const FRAME_HZ: float = 60.0
const FRAME_SEC: float = 1.0 / FRAME_HZ
const FRAME_BUDGET_MS: float = 1000.0 / FRAME_HZ

const WARMUP_SEC: float = 1.0
const SAMPLE_SEC: float = 3.0
const CONNECT_TIMEOUT_SEC: float = 10.0
const SPAWN_TIMEOUT_SEC: float = 20.0

## ENet's own counters measure what it hands the socket: ENet protocol header + payload. The wire
## costs 20 bytes of IPv4 header and 8 of UDP on top of every packet, and a home upload budget is
## spent in wire bytes, so the report shows both.
const UDP_IP_HEADER_BYTES: int = 28

## The budget from the prompt: ~1 Mbit/s typical home upload, so 125 KB/s is the hard ceiling and
## 60 KB/s at the host is the GREEN line for 200 entities.
const GREEN_HOST_UP_KBPS: float = 60.0
const CEILING_HOST_UP_KBPS: float = 125.0
const GREEN_CPU_MS: float = 2.0

enum Interest { OFF, SPREAD, CLUSTERED }

## Where each of the 5 clients' players stand. SPREAD is the flattering case — players fanned out
## across the island. CLUSTERED is the honest one: this is a co-op survival game and players spend
## most of a run within shouting distance of each other, which is when interest management culls
## least. Measuring only SPREAD would tell task 1.8 a comfortable lie.
const OBSERVERS_SPREAD: Array[Vector3] = [
	Vector3(-200.0, 0.0, -200.0),
	Vector3(200.0, 0.0, -200.0),
	Vector3(-200.0, 0.0, 200.0),
	Vector3(200.0, 0.0, 200.0),
	Vector3(0.0, 0.0, 0.0),
]
const OBSERVERS_CLUSTERED: Array[Vector3] = [
	Vector3(0.0, 0.0, 0.0),
	Vector3(10.0, 0.0, 4.0),
	Vector3(-8.0, 0.0, 6.0),
	Vector3(5.0, 0.0, -9.0),
	Vector3(-3.0, 0.0, 12.0),
]

var _peer_count: int = NetConfig.MAX_PLAYERS
var _client_count: int = NetConfig.MAX_CLIENTS

var _apis: Array[MultiplayerAPI] = []
var _enet: Array[ENetMultiplayerPeer] = []
var _containers: Array[Node3D] = []
var _spawners: Array[MultiplayerSpawner] = []
var _host_entities: Array[Dummy] = []
var _client_ids: PackedInt32Array = PackedInt32Array()

var _poll_usec: PackedInt64Array = PackedInt64Array()
var _move_usec: int = 0
var _frames: int = 0
var _next_frame_usec: int = 0
var _results: Array[Dictionary] = []


func _initialize() -> void:
	print("=== MIRE Spike R1 — replication load ===")
	print("Godot %s | %s | %d logical cores" % [
		Engine.get_version_info()["string"], OS.get_name(), OS.get_processor_count(),
	])
	print("%d peers (1 host + %d clients), %d entities, %.0f Hz frame pacing, %.0f s samples" % [
		_peer_count, _client_count, ENTITY_COUNT, FRAME_HZ, SAMPLE_SEC,
	])
	print("World %.0f m square, interest radius %.0f m" % [
		Dummy.WORLD_HALF_EXTENT * 2.0, Dummy.INTEREST_RADIUS_M,
	])
	print("")
	_run()


func _run() -> void:
	# We poll every API by hand and time each one, which is the only way to attribute CPU to the host
	# and to a client when they share a process.
	multiplayer_poll = false
	_poll_usec.resize(_peer_count)

	if not _setup_peers():
		quit(1)
		return
	if not await _connect():
		quit(1)
		return
	if not await _spawn_entities():
		quit(1)
		return

	var intervals: Array[Dictionary] = [
		{"label": "every frame", "hz": 60.0, "interval": 0.0},
		{"label": "30 Hz", "hz": 30.0, "interval": 1.0 / 30.0},
		{"label": "15 Hz", "hz": 15.0, "interval": 1.0 / 15.0},
	]
	var interests: Array[Interest] = [Interest.OFF, Interest.SPREAD, Interest.CLUSTERED]

	for interest: Interest in interests:
		for entry: Dictionary in intervals:
			var result: Dictionary = await _measure(
				String(entry["label"]), float(entry["interval"]), interest
			)
			_results.append(result)
			_print_phase(result)

	_print_summary()
	_teardown()
	quit()


# ── Setup ─────────────────────────────────────────────────────────────────────────────────────────

func _setup_peers() -> bool:
	for i: int in _peer_count:
		var peer_root: Node = Node.new()
		peer_root.name = "Peer%d" % i
		root.add_child(peer_root)

		var api: MultiplayerAPI = MultiplayerAPI.create_default_interface()
		# Registered before any child is added, so the spawner and every entity below it bind to this
		# API rather than to the process-wide default one.
		set_multiplayer(api, NodePath("/root/Peer%d" % i))

		var enet: ENetMultiplayerPeer = ENetMultiplayerPeer.new()
		var err: Error = (
			enet.create_server(BENCH_PORT, _client_count)
			if i == 0
			else enet.create_client(NetConfig.LOOPBACK_ADDRESS, BENCH_PORT)
		)
		if err != OK:
			push_error("peer %d failed to start: %s" % [i, error_string(err)])
			print("FAILED: peer %d could not %s — %s" % [
				i, "create_server" if i == 0 else "create_client", error_string(err),
			])
			return false
		api.multiplayer_peer = enet

		var container: Node3D = Node3D.new()
		container.name = "Entities"
		peer_root.add_child(container)

		var spawner: MultiplayerSpawner = MultiplayerSpawner.new()
		spawner.name = "Spawner"
		spawner.spawn_path = NodePath("../Entities")
		spawner.spawn_limit = ENTITY_COUNT + 8
		# Custom spawn function: with no .tscn to point at, this is how the entity gets built on the
		# receiving side (D-023). Bound to the peer index so the host can keep hold of its own copies.
		spawner.spawn_function = _spawn_dummy.bind(i)
		peer_root.add_child(spawner)

		_apis.append(api)
		_enet.append(enet)
		_containers.append(container)
		_spawners.append(spawner)

	print("[setup] %d peers created, host on port %d" % [_peer_count, BENCH_PORT])
	return true


## Runs on every peer: on the host because it called spawn(), on each client because the spawn packet
## arrived. Same index in, same starting state out.
func _spawn_dummy(data: Variant, peer_index: int) -> Node:
	var dummy: Dummy = Dummy.new()
	dummy.configure(int(data), BENCH_SEED)
	if peer_index == 0:
		_host_entities.append(dummy)
	return dummy


func _connect() -> bool:
	var deadline: int = Time.get_ticks_usec() + int(CONNECT_TIMEOUT_SEC * 1_000_000.0)
	while Time.get_ticks_usec() < deadline:
		await process_frame
		_pump_frame()
		if _apis[0].get_peers().size() == _client_count:
			var all_up: bool = true
			for i: int in range(1, _peer_count):
				if _apis[i].get_unique_id() <= 1:
					all_up = false
					break
			if all_up:
				_client_ids = PackedInt32Array()
				for i: int in range(1, _peer_count):
					_client_ids.append(_apis[i].get_unique_id())
				print("[setup] all %d clients connected — host id %d, client ids %s" % [
					_client_count, _apis[0].get_unique_id(), _client_ids,
				])
				return true
	print("FAILED: only %d/%d clients connected within %.0f s" % [
		_apis[0].get_peers().size(), _client_count, CONNECT_TIMEOUT_SEC,
	])
	return false


func _spawn_entities() -> bool:
	var start: int = Time.get_ticks_usec()
	for i: int in ENTITY_COUNT:
		_spawners[0].spawn(i)
	var spawn_call_ms: float = float(Time.get_ticks_usec() - start) / 1000.0

	# The spawn packets go out over the following frames; nothing is measurable until every client
	# has all 200.
	var deadline: int = Time.get_ticks_usec() + int(SPAWN_TIMEOUT_SEC * 1_000_000.0)
	var converged_usec: int = 0
	while Time.get_ticks_usec() < deadline:
		await process_frame
		_pump_frame()
		var done: bool = true
		for i: int in _peer_count:
			if _containers[i].get_child_count() < ENTITY_COUNT:
				done = false
				break
		if done:
			converged_usec = Time.get_ticks_usec()
			break

	if converged_usec == 0:
		var counts: PackedInt32Array = PackedInt32Array()
		for i: int in _peer_count:
			counts.append(_containers[i].get_child_count())
		print("FAILED: entities did not replicate within %.0f s — per-peer counts %s" % [
			SPAWN_TIMEOUT_SEC, counts,
		])
		return false

	var converge_ms: float = float(converged_usec - start) / 1000.0
	print("[spawn] %d entities: host spawn() calls %.1f ms, all %d peers converged in %.1f ms" % [
		ENTITY_COUNT, spawn_call_ms, _peer_count, converge_ms,
	])
	print("[spawn] host copies tracked: %d | client 1 child count: %d" % [
		_host_entities.size(), _containers[1].get_child_count(),
	])
	print("")
	return true


# ── Frame loop ────────────────────────────────────────────────────────────────────────────────────

## One paced frame: simulate on the host, then poll each peer's API with the clock running on each.
func _pump_frame() -> void:
	var t0: int = Time.get_ticks_usec()
	for dummy: Dummy in _host_entities:
		dummy.step(FRAME_SEC)
	_move_usec += Time.get_ticks_usec() - t0

	for i: int in _peer_count:
		var t1: int = Time.get_ticks_usec()
		_apis[i].poll()
		_poll_usec[i] += Time.get_ticks_usec() - t1

	_frames += 1
	_pace()


## Hold the loop to FRAME_HZ against the wall clock. Without this, bytes/sec is divided by a
## meaningless denominator and replication_interval never throttles anything.
func _pace() -> void:
	var now: int = Time.get_ticks_usec()
	if _next_frame_usec == 0:
		_next_frame_usec = now
	_next_frame_usec += int(FRAME_SEC * 1_000_000.0)
	var wait: int = _next_frame_usec - Time.get_ticks_usec()
	if wait > 0:
		OS.delay_usec(wait)
	else:
		# Behind schedule. Resync rather than trying to catch up, which would spiral.
		_next_frame_usec = Time.get_ticks_usec()


func _run_frames(seconds: float) -> void:
	var count: int = int(seconds * FRAME_HZ)
	for i: int in count:
		await process_frame
		_pump_frame()


# ── Measurement ───────────────────────────────────────────────────────────────────────────────────

func _apply_config(interval: float, interest: Interest) -> void:
	var observers: Array[Vector3] = []
	if interest == Interest.SPREAD:
		observers = OBSERVERS_SPREAD
	elif interest == Interest.CLUSTERED:
		observers = OBSERVERS_CLUSTERED

	Dummy.observer_positions.clear()
	for i: int in _client_ids.size():
		if i < observers.size():
			Dummy.observer_positions[_client_ids[i]] = observers[i]

	var enabled: bool = interest != Interest.OFF
	for dummy: Dummy in _host_entities:
		dummy.set_intervals(interval, interval)
		dummy.set_interest_management(enabled)


func _reset_counters() -> void:
	for i: int in _peer_count:
		_poll_usec[i] = 0
		# pop_statistic resets the counter, so this clears warmup traffic out of the sample.
		_enet[i].host.pop_statistic(ENetConnection.HOST_TOTAL_SENT_DATA)
		_enet[i].host.pop_statistic(ENetConnection.HOST_TOTAL_RECEIVED_DATA)
		_enet[i].host.pop_statistic(ENetConnection.HOST_TOTAL_SENT_PACKETS)
		_enet[i].host.pop_statistic(ENetConnection.HOST_TOTAL_RECEIVED_PACKETS)
	_move_usec = 0
	_frames = 0


func _measure(label: String, interval: float, interest: Interest) -> Dictionary:
	_apply_config(interval, interest)
	await _run_frames(WARMUP_SEC)
	_reset_counters()

	var wall_start: int = Time.get_ticks_usec()
	await _run_frames(SAMPLE_SEC)
	var wall_sec: float = float(Time.get_ticks_usec() - wall_start) / 1_000_000.0
	var frames: int = _frames

	var host_up: float = _enet[0].host.pop_statistic(ENetConnection.HOST_TOTAL_SENT_DATA)
	var host_down: float = _enet[0].host.pop_statistic(ENetConnection.HOST_TOTAL_RECEIVED_DATA)
	var host_up_packets: float = _enet[0].host.pop_statistic(ENetConnection.HOST_TOTAL_SENT_PACKETS)
	var host_down_packets: float = _enet[0].host.pop_statistic(ENetConnection.HOST_TOTAL_RECEIVED_PACKETS)

	var client_up: float = _enet[1].host.pop_statistic(ENetConnection.HOST_TOTAL_SENT_DATA)
	var client_down: float = _enet[1].host.pop_statistic(ENetConnection.HOST_TOTAL_RECEIVED_DATA)
	var client_down_packets: float = _enet[1].host.pop_statistic(ENetConnection.HOST_TOTAL_RECEIVED_PACKETS)

	var client_poll_usec: int = 0
	for i: int in range(1, _peer_count):
		client_poll_usec += _poll_usec[i]

	var worst_loss: float = 0.0
	for peer_id: int in _apis[0].get_peers():
		var packet_peer: ENetPacketPeer = _enet[0].get_peer(peer_id)
		if packet_peer != null:
			var loss: float = packet_peer.get_statistic(ENetPacketPeer.PEER_PACKET_LOSS)
			worst_loss = maxf(worst_loss, loss / float(ENetPacketPeer.PACKET_LOSS_SCALE) * 100.0)

	return {
		"label": label,
		"interest": interest,
		"interval": interval,
		"frames": frames,
		"wall_sec": wall_sec,
		"fps": float(frames) / wall_sec,
		"host_up_bps": host_up / wall_sec,
		"host_down_bps": host_down / wall_sec,
		"host_up_wire_bps": (host_up + host_up_packets * UDP_IP_HEADER_BYTES) / wall_sec,
		"host_up_pps": host_up_packets / wall_sec,
		"host_down_pps": host_down_packets / wall_sec,
		"client_up_bps": client_up / wall_sec,
		"client_down_bps": client_down / wall_sec,
		"client_down_wire_bps": (client_down + client_down_packets * UDP_IP_HEADER_BYTES) / wall_sec,
		"host_poll_ms": float(_poll_usec[0]) / float(frames) / 1000.0,
		"client_poll_ms": float(client_poll_usec) / float(_client_count) / float(frames) / 1000.0,
		"move_ms": float(_move_usec) / float(frames) / 1000.0,
		"visible_fraction": _visible_fraction(interest),
		"packet_loss_pct": worst_loss,
	}


## What fraction of the 200x5 entity-peer pairs interest management actually let through. A culling
## result without this number cannot be interpreted.
func _visible_fraction(interest: Interest) -> float:
	if interest == Interest.OFF:
		return 1.0
	var observers: Array[Vector3] = (
		OBSERVERS_SPREAD if interest == Interest.SPREAD else OBSERVERS_CLUSTERED
	)
	var visible: int = 0
	for dummy: Dummy in _host_entities:
		for observer: Vector3 in observers:
			if dummy.is_within_interest_of(observer):
				visible += 1
	return float(visible) / float(_host_entities.size() * observers.size())


# ── Reporting ─────────────────────────────────────────────────────────────────────────────────────

func _interest_name(interest: Interest) -> String:
	match interest:
		Interest.OFF:
			return "filters OFF"
		Interest.SPREAD:
			return "filters ON, players spread"
		_:
			return "filters ON, players clustered"


func _print_phase(r: Dictionary) -> void:
	print("[%s | %s] %d frames in %.2f s (%.1f fps)" % [
		_interest_name(r["interest"]), r["label"], r["frames"], r["wall_sec"], r["fps"],
	])
	print("    host   up %8.1f KB/s (%.1f KB/s on the wire, %.0f pkt/s)   down %7.1f KB/s" % [
		r["host_up_bps"] / 1024.0, r["host_up_wire_bps"] / 1024.0,
		r["host_up_pps"], r["host_down_bps"] / 1024.0,
	])
	print("    client down %6.1f KB/s (%.1f KB/s on the wire)              up %9.1f KB/s" % [
		r["client_down_bps"] / 1024.0, r["client_down_wire_bps"] / 1024.0,
		r["client_up_bps"] / 1024.0,
	])
	print("    per entity: %.1f B/s host up  |  %.1f B/s client down  |  visible %.1f%%" % [
		r["host_up_bps"] / float(ENTITY_COUNT),
		r["client_down_bps"] / float(ENTITY_COUNT),
		r["visible_fraction"] * 100.0,
	])
	print("    cpu: host poll %.3f ms/frame | client poll %.3f ms/frame | host sim %.3f ms/frame" % [
		r["host_poll_ms"], r["client_poll_ms"], r["move_ms"],
	])
	print("    packet loss (worst peer): %.2f%%" % r["packet_loss_pct"])
	print("")


func _print_summary() -> void:
	print("--- summary: %d peers, %d entities ---" % [_peer_count, ENTITY_COUNT])
	print("%-30s %-12s %10s %10s %9s %9s %8s" % [
		"interest", "rate", "host up", "wire up", "host ms", "clnt ms", "visible",
	])
	for r: Dictionary in _results:
		print("%-30s %-12s %8.1f KB %8.1f KB %8.3f %8.3f %7.1f%%" % [
			_interest_name(r["interest"]), r["label"],
			r["host_up_bps"] / 1024.0, r["host_up_wire_bps"] / 1024.0,
			r["host_poll_ms"], r["client_poll_ms"], r["visible_fraction"] * 100.0,
		])
	print("")
	print("Budget: GREEN host up < %.0f KB/s and CPU < %.0f ms/frame at 15-30 Hz." % [
		GREEN_HOST_UP_KBPS, GREEN_CPU_MS,
	])
	print("        Hard ceiling %.0f KB/s (~1 Mbit/s typical home upload). Frame budget %.2f ms." % [
		CEILING_HOST_UP_KBPS, FRAME_BUDGET_MS,
	])
	print("")
	_print_verdict()
	_print_caveats()


## GREEN/AMBER/RED as the R1 prompt defines them: GREEN is "fits as designed, filtering optional",
## AMBER is "fits only because of intervals or culling", RED is "does not fit at all". So the test is
## run twice — once against the unfiltered row, once against the configuration the game would
## actually ship in. The shipping row is the CLUSTERED one: this is a co-op game and players spend
## most of a run together, which is exactly when interest management culls least.
func _print_verdict() -> void:
	var unfiltered: Dictionary = _find(Interest.OFF, "30 Hz")
	var shipping_30: Dictionary = _find(Interest.CLUSTERED, "30 Hz")
	var shipping_15: Dictionary = _find(Interest.CLUSTERED, "15 Hz")
	if unfiltered.is_empty() or shipping_30.is_empty() or shipping_15.is_empty():
		return

	var worst_cpu: float = 0.0
	for r: Dictionary in _results:
		worst_cpu = maxf(worst_cpu, maxf(r["host_poll_ms"], r["client_poll_ms"]))

	var unfiltered_kb: float = unfiltered["host_up_wire_bps"] / 1024.0
	var ship_30_kb: float = shipping_30["host_up_wire_bps"] / 1024.0
	var ship_15_kb: float = shipping_15["host_up_wire_bps"] / 1024.0
	var best_shipping_kb: float = minf(ship_30_kb, ship_15_kb)

	var verdict: String = ""
	if unfiltered_kb < GREEN_HOST_UP_KBPS and worst_cpu < GREEN_CPU_MS:
		verdict = "GREEN — fits without interest management; §2.5 filtering stays optional"
	elif best_shipping_kb < CEILING_HOST_UP_KBPS and worst_cpu < GREEN_CPU_MS:
		verdict = "AMBER — fits ONLY with §2.5 interest management; task 1.8 is mandatory"
	else:
		verdict = "RED — does not fit even filtered; the §6 R1 binary-packet fallback is on the table"

	print("Unfiltered, 30 Hz  : %7.1f KB/s on the wire  (%.1fx the %.0f KB/s ceiling)" % [
		unfiltered_kb, unfiltered_kb / CEILING_HOST_UP_KBPS, CEILING_HOST_UP_KBPS,
	])
	print("Filtered,   30 Hz  : %7.1f KB/s on the wire  (%.1f%% visible, %.1fx cheaper)" % [
		ship_30_kb, shipping_30["visible_fraction"] * 100.0, unfiltered_kb / ship_30_kb,
	])
	print("Filtered,   15 Hz  : %7.1f KB/s on the wire  (%.1f%% visible, %.1fx cheaper)" % [
		ship_15_kb, shipping_15["visible_fraction"] * 100.0, unfiltered_kb / ship_15_kb,
	])
	print("Worst CPU seen in any phase: %.3f ms/frame of a %.2f ms budget (%.1f%%)." % [
		worst_cpu, FRAME_BUDGET_MS, worst_cpu / FRAME_BUDGET_MS * 100.0,
	])
	print("")
	print("VERDICT: %s" % verdict)
	print("")
	# The single most decision-relevant number in the run: it is what the R1 fallback would buy.
	var bytes_per_update: float = (
		unfiltered["host_up_bps"] / float(ENTITY_COUNT) / 30.0 / float(_client_count)
	)
	print("Wire cost per entity per update per client: %.1f bytes, carrying 16 bytes of actual" % bytes_per_update)
	print("state (Vector3 position + float rotation). So a perfectly packed hand-rolled binary")
	print("protocol — the §6 R1 fallback — could save at most %.1fx. Interest management saves" % (bytes_per_update / 16.0))
	print("%.1fx. The fallback is aimed at the smaller of the two problems." % (unfiltered_kb / ship_30_kb))


func _find(interest: Interest, label: String) -> Dictionary:
	for r: Dictionary in _results:
		if r["interest"] == interest and r["label"] == label:
			return r
	return {}


func _print_caveats() -> void:
	print("")
	print("--- what this does NOT measure ---")
	print("* Six peers on one machine over loopback is not a network. Zero real latency, zero real")
	print("  loss, no MTU path issues, no NAT, no wifi. Bandwidth and CPU numbers are honest — the")
	print("  bytes are really serialized and really pushed through ENet sockets — but any figure")
	print("  about loss, jitter or RTT here is an artifact and is reported only to show ENet was")
	print("  not silently dropping the load.")
	print("* All six peers share one CPU and one memory bus, so absolute ms/frame is pessimistic")
	print("  for the host and optimistic for nothing. Real clients each get their own core.")
	print("* 200 dummies is the spike's number, not the game's. Real entities carry more replicated")
	print("  state than position+rot+state, and M4 world streaming adds its own traffic.")
	print("* Only the host sends. Client-authoritative player movement (task 1.5) adds upstream")
	print("  traffic per client that this bench does not model.")


func _teardown() -> void:
	for i: int in _peer_count:
		_apis[i].multiplayer_peer = null
		_enet[i].close()
