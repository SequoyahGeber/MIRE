extends Node
class_name NetDebugPanel

## Live network readout, so 1.5-1.8 are debuggable instead of guessed at. Owns no UI of its own —
## it is a set of DebugOverlay.watch() readouts (autoload/debug_overlay.gd), shown only in F3's
## FULL mode. That file's doc comment names watch()/track_group() as the extension point for exactly
## this: "other systems add their own readouts without touching this file."
##
## Network authority: CLIENT-LOCAL (ARCHITECTURE.md §2.2, last row). Reads NetTransport and the
## active MultiplayerPeer; never mutates state. Display-only, and must never be the sole caller of
## anything it reads — if it were, that API would be dead code the moment this panel is stripped
## from a release build.
##
## NOT WIRED BY ITSELF: nothing here runs until one instance is added to the tree once at startup.
## _ready() is where the watch() registrations happen. Two ways to trigger it, pick one:
##   · a one-line autoload entry: NetDebugPanel="*res://ui/debug/net_debug_panel.gd"
##   · `add_child(NetDebugPanel.new())` from an existing autoload's own _ready()
## This file does not claim project.godot, so that line is not added here.
##
## CONVENTION for the synced-entity count: this calls DebugOverlay.track_group(&"synced") rather
## than counting MultiplayerSynchronizer nodes itself, matching the group-count pattern DebugOverlay
## already uses for &"players"/&"enemies". Whatever spawns synchronizers (task 1.5) needs to add
## them to group &"synced" for that line to read anything but 0 — which is what it correctly reads
## until then.

const EVENT_LOG_LIMIT: int = 5

var _events: Array[String] = []
var _last_bw_poll_msec: int = 0


func _ready() -> void:
	DebugOverlay.watch(&"net_session", _session_line)
	DebugOverlay.watch(&"net_rtt", _rtt_line)
	DebugOverlay.watch(&"net_bw", _bandwidth_line)
	DebugOverlay.watch(&"net_log", _log_line)
	DebugOverlay.track_group(&"synced")

	NetTransport.peer_joined.connect(_on_peer_joined)
	NetTransport.peer_left.connect(_on_peer_left)
	NetTransport.connection_failed.connect(_on_connection_failed)
	NetTransport.connected_to_host.connect(_on_connected_to_host)
	NetTransport.server_started.connect(_on_server_started)
	NetTransport.disconnected.connect(_on_disconnected)

	_last_bw_poll_msec = Time.get_ticks_msec()


# ── Session / identity ───────────────────────────────────────────────────────────────────────────


func _session_line() -> String:
	var mode: NetConfig.Mode = NetTransport.current_mode()
	if mode == NetConfig.Mode.OFFLINE:
		return "OFFLINE"
	if NetTransport.is_connecting():
		return "%s connecting…" % NetTransport.mode_name(mode)
	var role: String = "host" if NetTransport.is_host() else "client"
	return "%s  %s  id %d  peers %s" % [
		NetTransport.mode_name(mode),
		role,
		NetTransport.local_peer_id(),
		_format_peers(NetTransport.peer_ids()),
	]


func _format_peers(peers: PackedInt32Array) -> String:
	var parts: Array[String] = []
	for id: int in peers:
		parts.append(str(id))
	return "[%s]" % ", ".join(parts)


# ── RTT ───────────────────────────────────────────────────────────────────────────────────────────


## Per remote peer, from ENetPacketPeer.get_statistic(PEER_ROUND_TRIP_TIME) — verified against the
## pinned 4.7.1 engine source (modules/enet). "n/a" in STEAM mode: SteamMultiplayerPeer does not
## inherit ENetMultiplayerPeer, so this build exposes no equivalent stat for it — not invented.
##
## get_peer(id) ERR_FAILs (loud engine error, not a quiet null) for any id ENet does not directly
## hold a connection to. A client is only ever directly connected to the host (id 1); relayed peers
## are not reachable this way. So a client only ever probes id 1, and a host probes its own
## peer_ids() list, which for the host IS the set of direct ENet connections.
func _rtt_line() -> String:
	if not NetTransport.is_active():
		return "n/a (offline)"
	var peer: MultiplayerPeer = multiplayer.multiplayer_peer
	if not (peer is ENetMultiplayerPeer):
		return "n/a (STEAM: SteamMultiplayerPeer exposes no RTT stat in this build)"

	var enet_peer := peer as ENetMultiplayerPeer
	var targets: PackedInt32Array = (
		NetTransport.peer_ids() if NetTransport.is_host() else PackedInt32Array([1])
	)
	var parts: Array[String] = []
	for id: int in targets:
		if id == NetTransport.local_peer_id():
			continue
		var packet_peer: ENetPacketPeer = enet_peer.get_peer(id)
		if packet_peer == null:
			continue
		var rtt_ms: float = packet_peer.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME)
		parts.append("%d:%dms" % [id, int(rtt_ms)])

	if parts.is_empty():
		return "n/a (no remote peers)"
	return ", ".join(parts)


# ── Bandwidth ─────────────────────────────────────────────────────────────────────────────────────


## ENetConnection.pop_statistic zeroes the counter it reads (verified against the pinned 4.7.1
## engine source, modules/enet/enet_connection.cpp) — the value returned IS the total moved since
## the last call, not a running total. Divided by wall time actually elapsed since that last call
## (not a fixed 1/REFRESH_HZ), so a panel that was hidden for a while doesn't under-report the
## instant it's shown again. "n/a" in STEAM mode for the same reason as RTT above.
func _bandwidth_line() -> String:
	if not NetTransport.is_active():
		_last_bw_poll_msec = Time.get_ticks_msec()
		return "n/a (offline)"
	var peer: MultiplayerPeer = multiplayer.multiplayer_peer
	if not (peer is ENetMultiplayerPeer):
		return "n/a (STEAM: SteamMultiplayerPeer exposes no bandwidth stat in this build)"
	var host: ENetConnection = (peer as ENetMultiplayerPeer).host
	if host == null:
		return "n/a"

	var now_msec: int = Time.get_ticks_msec()
	var elapsed_sec: float = maxf(0.001, (now_msec - _last_bw_poll_msec) / 1000.0)
	_last_bw_poll_msec = now_msec

	var sent_bytes: float = host.pop_statistic(ENetConnection.HOST_TOTAL_SENT_DATA)
	var recv_bytes: float = host.pop_statistic(ENetConnection.HOST_TOTAL_RECEIVED_DATA)
	return "up %.1f KB/s  down %.1f KB/s" % [
		(sent_bytes / 1024.0) / elapsed_sec, (recv_bytes / 1024.0) / elapsed_sec
	]


# ── Event log ─────────────────────────────────────────────────────────────────────────────────────


func _log_line() -> String:
	if _events.is_empty():
		return "(none yet)"
	return "\n  ".join(_events)


func _record(text: String) -> void:
	_events.append(text)
	if _events.size() > EVENT_LOG_LIMIT:
		_events.pop_front()


func _on_peer_joined(peer_id: int) -> void:
	_record("joined  peer %d" % peer_id)


func _on_peer_left(peer_id: int) -> void:
	_record("left    peer %d" % peer_id)


func _on_connection_failed(reason: String) -> void:
	_record("FAILED  %s" % reason)


func _on_connected_to_host() -> void:
	_record("connected to host")


func _on_server_started() -> void:
	_record("hosting started")


func _on_disconnected() -> void:
	_record("disconnected")
