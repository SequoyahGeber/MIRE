extends Node

## AttunementService — autoload. Who picked which of DESIGN.md §4.5's four roles, host-recorded and
## broadcast to everyone.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, "Attunement selection" row): **HOST**. Only the host
## records a pick or grants its modifier; a client only ever requests. One RPC pair carries that
## (protocol 14):
##
##   · `net_request_attunement` — client -> host, "I want this one".
##   · `net_attunement_confirmed` — host -> the requester only, accepted/refused + why.
##   · `net_attunement_selected` — host -> everyone (broadcast), peer_id's pick (or &"" if cleared).
##
## Unlike PowerupService's owner-full/teammate-counts split, a role pick is not private — DESIGN
## §4.5's whole point is that the party can SEE who is playing what and self-organize around it — so
## the full `{peer_id: attunement_id}` map is broadcast to every peer, not summarized.
##
## D-070: an Attunement grants exactly ONE stack of a backing PowerupDef through PowerupService's
## existing host seam — this service adds no stat plumbing of its own, only the one-time selection
## and lock. D-071: it triggers at the local player's first spawn this session ("run start"), not
## DESIGN §4.5's unbuilt "first Wellspring cap".
##
## F-277 / D-167: a selection is RUN-scoped, not session-scoped. `run_restarted` clears every peer's
## pick through `host_clear_all()` and broadcasts the clear, because the PowerupService stack the
## pick granted is cleared by that same event — leaving the lock behind would mean a second run with
## no Attunement effect and no way to choose one.
##
## D-035 DISCIPLINE: selections are keyed by peer id, and peer ids change across a reconnect. This
## service does **not** drop state on `peer_left` — it waits for
## `NetSession.run_player_rebound(old, new)` to move it or `run_player_expired(peer)` to drop it,
## exactly like PowerupService and InventoryService before it.

const EVENT_BUS := preload("res://core/events/event_bus.gd")

const LOG_CHANNEL: StringName = &"attunement"

## Host-side (and mirrored identically on every peer, since this is a full broadcast): peer id ->
## attunement id. An absent key or an empty StringName both mean "has not chosen yet" — `selection_of`
## normalizes both to &"".
var _selections: Dictionary[int, StringName] = {}

var _transport_node: Node
var _definition_cache: Dictionary[StringName, Resource] = {}

## Fires on every peer whenever ANY peer's pick becomes known or is cleared (rebind/expiry). Drives
## the UI's roster display.
signal selection_changed(peer_id: int, attunement_id: StringName)
## Fires only on the peer that made the request, once the host has answered it. Drives the selection
## UI closing (accepted) or showing a refusal (refused).
signal selection_confirmed(accepted: bool, attunement_id: StringName, detail: String)


func _ready() -> void:
	var transport: Node = _transport()
	transport.get("peer_joined").connect(_on_peer_joined)

	# D-035's consumer contract. NetSession owns run-player identity; this service only follows it.
	var session: Node = get_node_or_null(^"/root/NetSession")
	if session != null and session.has_signal(&"run_player_rebound"):
		session.connect(&"run_player_rebound", _on_run_player_rebound)
		session.connect(&"run_player_expired", _on_run_player_expired)

	# F-277. D-071 ties a pick to "run start", and D-010 says a run is one sitting — so a selection
	# is RUN-scoped, exactly like the PowerupService stack it grants. PowerupService already clears
	# that stack on `run_restarted`; without this line the effect went away and the lock did not.
	EVENT_BUS.subscribe_run_restarted(_on_run_restarted)


func _exit_tree() -> void:
	EVENT_BUS.unsubscribe_run_restarted(_on_run_restarted)


# ── Client-facing request ───────────────────────────────────────────────────────────────────────


## Ask to lock in `attunement_id`. Host-of-one/offline resolves synchronously; otherwise the answer
## arrives later via `selection_confirmed`.
func request_select(attunement_id: StringName) -> void:
	if _owns_mutation():
		_process_selection(_local_peer_id(), attunement_id)
	elif bool(_transport().call("is_active")):
		net_request_attunement.rpc_id(NetConfig.HOST_PEER_ID, attunement_id)
	else:
		selection_confirmed.emit(false, attunement_id, "no authoritative session")


func selection_of(peer_id: int) -> StringName:
	return _selections.get(peer_id, &"")


func has_selected(peer_id: int) -> bool:
	return selection_of(peer_id) != &""


func local_selection() -> StringName:
	return selection_of(_local_peer_id())


## Every known peer id -> attunement id, copied. Empty entries are never stored, so this is exactly
## "who has chosen, and what".
func all_selections() -> Dictionary:
	return _selections.duplicate()


# ── Host mutation ────────────────────────────────────────────────────────────────────────────────


@rpc("any_peer", "call_remote", "reliable")
func net_request_attunement(attunement_id: StringName) -> void:
	if not bool(_transport().call("is_host")):
		return
	_process_selection(multiplayer.get_remote_sender_id(), attunement_id)


func _process_selection(peer_id: int, attunement_id: StringName) -> void:
	if not _owns_mutation():
		return
	if has_selected(peer_id):
		_confirm(peer_id, false, attunement_id, "already selected an Attunement — respec is out of scope")
		return
	var definition: Resource = _definition(attunement_id)
	if definition == null:
		_confirm(peer_id, false, attunement_id, "unknown Attunement '%s'" % attunement_id)
		return
	var powerup_id: StringName = StringName(definition.get(&"granted_powerup_id"))
	var powerups: Node = get_node_or_null(^"/root/PowerupService")
	if powerups == null:
		_confirm(peer_id, false, attunement_id, "PowerupService is not available")
		return
	var granted: int = int(powerups.call(&"host_grant", peer_id, powerup_id, 1))
	if granted <= 0:
		# host_grant only refuses on an unregistered/capped id, neither of which a fresh pick should
		# ever hit — a content mistake (D-070's backing PowerupDef missing or misnamed), not a normal
		# refusal path. Warn rather than silently locking a player out of ever picking again.
		MireLog.warn(LOG_CHANNEL, "peer %d picked '%s' but its backing powerup '%s' granted 0" % [
			peer_id, attunement_id, powerup_id
		])
		_confirm(peer_id, false, attunement_id, "could not grant this Attunement's effect")
		return
	_selections[peer_id] = attunement_id
	MireLog.info(LOG_CHANNEL, "peer %d attuned to %s" % [peer_id, attunement_id])
	_confirm(peer_id, true, attunement_id, "")
	_broadcast(peer_id, attunement_id)
	selection_changed.emit(peer_id, attunement_id)


## F-277: drop one peer's pick and tell every peer, so the next `request_select()` from them is no
## longer refused as "already selected". Host-only, like every other mutation here; a client's mirror
## follows through the same `net_attunement_selected(peer, &"")` broadcast a rebind/expiry uses.
## Returns true if there was actually something to clear, so callers can report real work.
func host_clear_selection(peer_id: int) -> bool:
	if not _owns_mutation() or not _selections.has(peer_id):
		return false
	_selections.erase(peer_id)
	_broadcast(peer_id, &"")
	selection_changed.emit(peer_id, &"")
	return true


## F-277: every peer's pick, for a fresh run. Shaped after `PowerupService.host_clear_all()` — it
## reuses the per-peer seam rather than wiping `_selections` directly, so each cleared peer still
## gets its own broadcast and its own `selection_changed`, which is what re-arms each peer's picker.
func host_clear_all() -> int:
	if not _owns_mutation():
		return 0
	var cleared: int = 0
	for peer_id: int in _selections.keys().duplicate():
		if host_clear_selection(peer_id):
			cleared += 1
	if cleared > 0:
		MireLog.info(LOG_CHANNEL, "cleared %d Attunement selection(s) for a new run" % cleared)
	return cleared


func _confirm(peer_id: int, accepted: bool, attunement_id: StringName, detail: String) -> void:
	if peer_id == _local_peer_id():
		selection_confirmed.emit(accepted, attunement_id, detail)
	elif _peer_connected(peer_id):
		net_attunement_confirmed.rpc_id(peer_id, accepted, attunement_id, detail)


func _broadcast(peer_id: int, attunement_id: StringName) -> void:
	if bool(_transport().call("is_active")):
		net_attunement_selected.rpc(peer_id, attunement_id)


# ── Replication (host -> clients, reliable: a dropped pick must never look unmade) ─────────────────


@rpc("authority", "call_remote", "reliable")
func net_attunement_confirmed(accepted: bool, attunement_id: StringName, detail: String) -> void:
	selection_confirmed.emit(accepted, attunement_id, detail)


@rpc("authority", "call_remote", "reliable")
func net_attunement_selected(peer_id: int, attunement_id: StringName) -> void:
	if _owns_mutation():
		return
	if attunement_id == &"":
		_selections.erase(peer_id)
	else:
		_selections[peer_id] = attunement_id
	selection_changed.emit(peer_id, attunement_id)


# ── Lifecycle ────────────────────────────────────────────────────────────────────────────────────


## A joiner (or a peer reconnecting to a session already mid-run) knows nothing about anyone's pick
## until told — same reasoning as PowerupService's `_on_peer_joined`, found there by writing the
## two-process check rather than by reading the file.
func _on_peer_joined(peer_id: int) -> void:
	if not _owns_mutation() or not _peer_connected(peer_id):
		return
	for known_peer: int in _selections:
		net_attunement_selected.rpc_id(peer_id, known_peer, _selections[known_peer])


func _on_run_player_rebound(old_peer_id: int, new_peer_id: int) -> void:
	if not _owns_mutation() or not _selections.has(old_peer_id):
		return
	var attunement_id: StringName = _selections[old_peer_id]
	_selections.erase(old_peer_id)
	_broadcast(old_peer_id, &"")  # retire the old id first, mirroring F-089's fix
	selection_changed.emit(old_peer_id, &"")
	_selections[new_peer_id] = attunement_id
	_broadcast(new_peer_id, attunement_id)
	selection_changed.emit(new_peer_id, attunement_id)


func _on_run_player_expired(peer_id: int) -> void:
	host_clear_selection(peer_id)


## F-277. Unconditional on authority, like every other `run_restarted` subscriber in this codebase —
## `host_clear_all()` self-guards, so a client's own copy of this event is a no-op and its mirror is
## updated by the host's broadcast instead. That keeps ARCHITECTURE §2.2's "Attunement selection =
## Host" row true across a restart: nothing but the host ever writes a selection.
func _on_run_restarted() -> void:
	host_clear_all()


# ── Internals ────────────────────────────────────────────────────────────────────────────────────


func _definition(attunement_id: StringName) -> Resource:
	var cached: Resource = _definition_cache.get(attunement_id)
	if cached != null:
		return cached
	var registry: Node = get_node_or_null(^"/root/Registry")
	if registry == null:
		return null
	var definition: Resource = registry.call(&"get_attunement", attunement_id)
	if definition != null:
		_definition_cache[attunement_id] = definition
	return definition


func _owns_mutation() -> bool:
	var transport: Node = _transport()
	if bool(transport.call("is_host")):
		return true
	return not bool(transport.call("is_active")) and not bool(transport.call("is_connecting"))


func _peer_connected(peer_id: int) -> bool:
	return bool(_transport().call("has_peer", peer_id))


func _local_peer_id() -> int:
	var peer_id: int = int(_transport().call("local_peer_id"))
	return peer_id if peer_id > 0 else NetConfig.HOST_PEER_ID


## Path-resolved (F-011 — harnesses install the transport at /root), cached once found (F-099).
func _transport() -> Node:
	if _transport_node == null or not is_instance_valid(_transport_node):
		_transport_node = get_node(^"/root/NetTransport")
	return _transport_node
