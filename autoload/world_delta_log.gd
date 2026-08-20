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

## F-250: fired every time `_apply()` actually stores a value — on the host from its own
## `host_record()` call, and on a client from `net_delta_applied` (a live turnover) or nowhere else
## (`net_world_snapshot` replaces `_state` wholesale for a late joiner and does not go through
## `_apply()`, so a snapshot never re-fires this — a joiner reads the caught-up value directly via
## [method latest] instead, same as before this signal existed). Generic across every `kind` this log
## ever carries, so `CycleService` can hang a real-time client-side re-derivation of
## `EventBus.cycle_advanced` off it (F-250's fix) without this file knowing anything about Cycle
## specifically, and any future kind gets the same for free.
signal delta_applied(chunk: Vector2i, kind: StringName, key: String, value: Variant)

## chunk -> kind (as String) -> key -> value.
var _state: Dictionary = {}


## F-258 addressing for the run seed itself. Not a real spatial chunk — a seed has no position —
## the same pseudo-chunk reuse `CycleService`'s `GLOBAL_CHUNK` already makes of this log, and safe
## for the same reason: the log keys by `(chunk, kind, key)`, so a `kind` no terrain system uses can
## never collide with a real chunk record.
const SEED_CHUNK: Vector2i = Vector2i.ZERO
const SEED_KIND: StringName = &"world"
const SEED_KEY: String = "seed"


func _ready() -> void:
	var session: Node = get_node_or_null(^"/root/NetSession")
	if session != null:
		session.connect(&"peer_admitted", _on_peer_admitted)


## F-258. Host-only. Replaces the run seed mid-session and gets the new value to every ALREADY-
## connected peer — the gap D-149 cut out of F-243's restart and this log's own header only ever
## solved for a NEWLY joining one (`net_world_snapshot`, fired from `NetSession.peer_admitted`).
##
## No new RPC and therefore no `NetVersion.PROTOCOL_VERSION` bump: the value rides the existing
## `net_delta_applied` broadcast as one more (chunk, kind, key, value) record, the same no-new-RPC
## reuse D-099/D-100 established and `CycleService` already leans on twice (`cycle`/`run`). The wire
## SHAPE is untouched, which is exactly the condition `core/net/rpc_manifest.gd` scans for.
##
## Clearing `_state` is the half that is easy to miss and expensive to skip: every record in here is
## keyed by a chunk of the island that just ended — harvest depletion at a point that no longer has
## a tree on it, Mire cells for a grid about to be re-seeded. Carried into the new world they would
## deplete resources nobody harvested, at coordinates chosen by the PREVIOUS seed. So the reseed
## wipes the log and re-lays the seed record as its first entry; `CycleService.host_restart_run()`
## therefore calls this BEFORE recording its own Cycle/run-generation values, so the wipe cannot
## take them with it.
func host_reseed(seed_value: int) -> void:
	if not _owns_world_state():
		return
	_reseed_local(seed_value)
	if _transport_is_active():
		net_delta_applied.rpc(SEED_CHUNK.x, SEED_CHUNK.y, String(SEED_KIND), SEED_KEY, seed_value)


## Both sides of a reseed, so the host and a receiving client cannot drift in what a reseed MEANS.
## `set_replicated_seed()` is idempotent by its own contract and fires `GameState.seed_ready` on
## every peer, which is what re-derives `SalvageService`/`RewardService`'s per-run counters; the
## systems that re-derive their world from the seed hang off `EventBus.run_restarted` instead, which
## arrives immediately after this on the same reliable channel (`CycleService`'s `RUN_KIND` record).
func _reseed_local(seed_value: int) -> void:
	_state.clear()
	_apply(SEED_CHUNK, SEED_KIND, SEED_KEY, seed_value)
	var game_state: Node = get_node_or_null(^"/root/GameState")
	if game_state != null:
		game_state.call("set_replicated_seed", seed_value)


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
	delta_applied.emit(chunk, kind, key, value)


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
	var chunk := Vector2i(chunk_x, chunk_z)
	# F-258: one record on this channel is not a mutation OF the world, it is a new world. Routed to
	# `_reseed_local()` rather than `_apply()` so a client wipes the ended run's chunk records and
	# adopts the seed in the same step the host did, off the same value. Deliberately not a second
	# RPC — see `host_reseed()` above for why the wire shape must not move for this.
	if chunk == SEED_CHUNK and StringName(kind) == SEED_KIND and key == SEED_KEY:
		_reseed_local(int(value))
		return
	_apply(chunk, StringName(kind), key, value)


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
