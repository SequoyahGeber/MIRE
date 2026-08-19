extends Node

## Host-authoritative mutation log for world state that has no permanently networked node to carry
## it — docs/ARCHITECTURE.md §4: "every mutation... replicates as deltas keyed by chunk," task 4.6's
## first real payload.
##
## This is deliberately NOT how every mutation in the game reaches a late joiner. A placed
## buildable (task 3.6) is a real node under `autoload/build_service.gd`'s own `MultiplayerSpawner`,
## which already replays every existing spawn to a newly connected peer on its own
## (`core/net/net_session.gd`'s own header note) — nothing here duplicates that. This log exists for
## the case that has no such node: `world/gen/resource_scatter_field.gd`'s harvest proxies are
## created and freed as their chunk streams in and out of each peer's own independent ring
## (`ARCHITECTURE.md` §2.2's chunk-streaming row), so there may be no live `Harvestable` on a given
## peer to replicate FROM at the moment another peer needs to know its state — D-083's "depletion
## memory is best-effort... until 4.6." The Mire grid (task 4.9, not yet built) is this log's next
## intended consumer: same per-cell-keyed-by-chunk shape, a different `kind`.
##
## NETWORK AUTHORITY (ARCHITECTURE.md §2.2, world-mutation row): HOST. Only a host (or a
## host-of-one offline run, same convention `systems/harvesting/harvestable.gd._owns_world_mutation()`
## uses) ever calls [method host_record]; a client only ever receives values through the two RPCs
## below and reads them back through [method latest]/[method entries_for_chunk].
##
## Latest-value-wins per (chunk, kind, key), not an append-only event journal: every consumer this
## task has (and the Mire tick 4.9 will add) only ever asks "what does this look like RIGHT NOW",
## never "what happened to it" — cheaper to snapshot and replay, and there is nothing today that
## would read a history.

## chunk -> kind (as String) -> key -> value.
var _state: Dictionary = {}


func _ready() -> void:
	var session: Node = get_node_or_null(^"/root/NetSession")
	if session != null:
		session.connect(&"peer_admitted", _on_peer_admitted)


## Host-only. Records one mutation locally and, when a real session is running, broadcasts it to
## every already-connected peer immediately — the "every mutation replicates as deltas" half of the
## design. A client call is silently ignored, the same authority gate every other world-mutation
## seam in this project uses (`Harvestable.host_apply_damage`, `BuildService`'s request handlers).
func host_record(chunk: Vector2i, kind: StringName, key: String, value: Variant) -> void:
	if not _owns_world_state():
		return
	_apply(chunk, kind, key, value)
	if _transport_is_active():
		net_delta_applied.rpc(chunk.x, chunk.y, String(kind), key, value)


## The current value for one (chunk, kind, key), or `default` when nothing was ever recorded —
## either because it never mutated, or because this peer has not yet received the snapshot/delta
## that would tell it. Callers that need to fall back to their own best-effort memory (as
## `ResourceScatterField.is_point_depleted()` still does, for the moment before a snapshot lands)
## check for that `null` explicitly rather than treating it as "known intact".
func latest(chunk: Vector2i, kind: StringName, key: String, default: Variant = null) -> Variant:
	var chunk_state: Dictionary = _state.get(chunk, {})
	var kind_state: Dictionary = chunk_state.get(String(kind), {})
	return kind_state.get(key, default)


## Every recorded (key -> value) for one (chunk, kind) — for a consumer that wants to replay a
## whole chunk's known state at once rather than asking per-point.
func entries_for_chunk(chunk: Vector2i, kind: StringName) -> Dictionary:
	var chunk_state: Dictionary = _state.get(chunk, {})
	return (chunk_state.get(String(kind), {}) as Dictionary).duplicate()


## For checks/logs: total number of recorded (chunk, kind, key) triples.
func entry_count() -> int:
	var total: int = 0
	for chunk_state: Variant in _state.values():
		for kind_state: Variant in (chunk_state as Dictionary).values():
			total += (kind_state as Dictionary).size()
	return total


func _apply(chunk: Vector2i, kind: StringName, key: String, value: Variant) -> void:
	var chunk_state: Dictionary = _state.get_or_add(chunk, {})
	var kind_state: Dictionary = chunk_state.get_or_add(String(kind), {})
	kind_state[key] = value


## Host -> one newly admitted peer: the run seed and the whole accumulated log in one reliable RPC
## (`ARCHITECTURE.md` 4.6: "late joiner gets seed + compressed delta log"). Fired once per peer by
## `NetSession.peer_admitted`, so a peer joining mid-run catches up in a single message instead of
## replaying every mutation since session start individually. `original_size` is carried alongside
## the compressed bytes because `PackedByteArray.decompress()` needs the uncompressed size up front —
## there is no self-describing compressed format here to read it from.
@rpc("authority", "call_remote", "reliable")
func net_world_snapshot(seed_value: int, original_size: int, compressed: PackedByteArray) -> void:
	var game_state: Node = get_node_or_null(^"/root/GameState")
	if game_state != null:
		game_state.call("set_replicated_seed", seed_value)
	if original_size <= 0:
		return
	var raw: PackedByteArray = compressed.decompress(original_size, FileAccess.COMPRESSION_GZIP)
	var decoded: Variant = bytes_to_var(raw)
	if decoded is Dictionary:
		_state = decoded as Dictionary


## Host -> everyone already connected, one live mutation. Reliable: a dropped delta is a point that
## reads intact on one peer and depleted on another until its chunk happens to reload on the peer
## that missed it — the same "must never desync silently" reasoning every other mutation RPC in this
## project already follows.
@rpc("authority", "call_remote", "reliable")
func net_delta_applied(chunk_x: int, chunk_z: int, kind: String, key: String, value: Variant) -> void:
	_apply(Vector2i(chunk_x, chunk_z), StringName(kind), key, value)


func _on_peer_admitted(peer_id: int) -> void:
	if not _owns_world_state() or not _transport_has_peer(peer_id):
		return
	var game_state: Node = get_node_or_null(^"/root/GameState")
	var seed_value: int = int(game_state.call("ensure_seed")) if game_state != null else 0
	var raw: PackedByteArray = var_to_bytes(_state)
	var compressed: PackedByteArray = raw.compress(FileAccess.COMPRESSION_GZIP)
	net_world_snapshot.rpc_id(peer_id, seed_value, raw.size(), compressed)


func _owns_world_state() -> bool:
	return not _transport_is_active() or _transport_is_host()


func _transport_is_active() -> bool:
	var transport: Node = get_node_or_null(^"/root/NetTransport")
	return transport != null and bool(transport.call("is_active"))


func _transport_is_host() -> bool:
	var transport: Node = get_node_or_null(^"/root/NetTransport")
	return transport != null and bool(transport.call("is_host"))


## F-059's guard: peer_admitted fires the instant a hello resolves, but a peer that disconnects in
## that same instant is still an rpc_id() target nothing is listening on.
func _transport_has_peer(peer_id: int) -> bool:
	var transport: Node = get_node_or_null(^"/root/NetTransport")
	return transport != null and bool(transport.call("has_peer", peer_id))
