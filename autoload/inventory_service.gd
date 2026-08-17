extends Node

## One host-owned inventory per peer, plus the confirmed local snapshot task 2.5 renders.
##
## NETWORK AUTHORITY (ARCHITECTURE.md section 2.2, Inventory / crafting row): HOST. Harvesting and
## other trusted host systems call host_add()/host_transaction(). A client can request removal or
## slot movement only for itself; peer id, grants, stack limits and the resulting snapshot all come
## from the host. Clients never receive an add-items RPC.

const EVENT_BUS := preload("res://core/events/event_bus.gd")
const INVENTORY_STORE_SCRIPT := preload("res://systems/inventory/inventory_store.gd")

const INVENTORY_SLOT_COUNT: int = 24
const HOTBAR_SLOT_COUNT: int = 8
const HOTBAR_START_INDEX: int = INVENTORY_SLOT_COUNT
const SLOT_COUNT: int = INVENTORY_SLOT_COUNT + HOTBAR_SLOT_COUNT

signal local_inventory_changed(slots: Array[Dictionary], revision: int)
signal host_inventory_changed(peer_id: int, slots: Array[Dictionary], revision: int)
signal operation_confirmed(request_id: int, accepted: bool, detail: String)

var _host_stores: Dictionary[int, RefCounted] = {}
var _revisions: Dictionary[int, int] = {}
var _local_slots: Array[Dictionary] = []
var _local_revision: int = -1
var _next_request_id: int = 1
var _session_open: bool = false


func _ready() -> void:
	_reset_local_cache()
	EVENT_BUS.subscribe_harvest_yielded(_on_harvest_yielded)
	var transport: Node = _transport()
	transport.get("server_started").connect(_on_session_opened)
	transport.get("connected_to_host").connect(_on_session_opened)
	transport.get("disconnected").connect(_on_disconnected)
	transport.get("peer_joined").connect(_on_peer_joined)
	transport.get("peer_left").connect(_on_peer_left)
	if bool(transport.call("is_active")):
		_on_session_opened.call_deferred()
	else:
		_ensure_host_store(NetConfig.HOST_PEER_ID)
		_publish_snapshot(NetConfig.HOST_PEER_ID)


func _exit_tree() -> void:
	EVENT_BUS.unsubscribe_harvest_yielded(_on_harvest_yielded)


func local_slots() -> Array[Dictionary]:
	return _duplicate_slots(_local_slots)


func slot_count() -> int:
	return SLOT_COUNT


func inventory_slot_count() -> int:
	return INVENTORY_SLOT_COUNT


func hotbar_slot_count() -> int:
	return HOTBAR_SLOT_COUNT


func hotbar_start_index() -> int:
	return HOTBAR_START_INDEX


func local_revision() -> int:
	return _local_revision


func local_count(item_id: StringName) -> int:
	var total: int = 0
	for slot: Dictionary in _local_slots:
		if StringName(String(slot.get("item_id", ""))) == item_id:
			total += int(slot.get("amount", 0))
	return total


func host_slots(peer_id: int) -> Array[Dictionary]:
	if not _owns_mutation() or not _host_stores.has(peer_id):
		return []
	return _store(peer_id).call("slots_snapshot") as Array[Dictionary]


func host_count(peer_id: int, item_id: StringName) -> int:
	if not _owns_mutation() or not _host_stores.has(peer_id):
		return 0
	return int(_store(peer_id).call("count", item_id))


func host_can_add(peer_id: int, item_id: StringName, amount: int) -> bool:
	return _valid_host_peer(peer_id) and bool(_store(peer_id).call("can_add", item_id, amount))


func host_can_remove(peer_id: int, item_id: StringName, amount: int) -> bool:
	return _valid_host_peer(peer_id) and bool(_store(peer_id).call("can_remove", item_id, amount))


## Trusted host grant. All-or-nothing; there is deliberately no client RPC equivalent.
func host_add(peer_id: int, item_id: StringName, amount: int) -> bool:
	if not _valid_host_peer(peer_id):
		return false
	if not bool(_store(peer_id).call("add", item_id, amount)):
		return false
	_commit(peer_id)
	return true


func host_remove(peer_id: int, item_id: StringName, amount: int) -> bool:
	if not _valid_host_peer(peer_id):
		return false
	if not bool(_store(peer_id).call("remove", item_id, amount)):
		return false
	_commit(peer_id)
	return true


func host_move_stack(peer_id: int, from_index: int, to_index: int, amount: int = 0) -> bool:
	if not _valid_host_peer(peer_id):
		return false
	if not bool(_store(peer_id).call("move_stack", from_index, to_index, amount)):
		return false
	_commit(peer_id)
	return true


## Task 2.6 seam: removals and additions commit together or not at all, with one snapshot revision.
func host_transaction(peer_id: int, removals: Dictionary, additions: Dictionary) -> bool:
	if not _valid_host_peer(peer_id):
		return false
	if not bool(_store(peer_id).call("apply_transaction", removals, additions)):
		return false
	_commit(peer_id)
	return true


## Returns a local request id immediately. Completion always arrives through operation_confirmed.
func request_remove(item_id: StringName, amount: int) -> int:
	var request_id: int = _take_request_id()
	if _owns_mutation():
		_process_remove_request(_local_peer_id(), item_id, amount, request_id)
	elif bool(_transport().call("is_active")):
		net_request_remove.rpc_id(NetConfig.HOST_PEER_ID, item_id, amount, request_id)
	else:
		_emit_confirmation(request_id, false, "no authoritative session")
	return request_id


func request_move_stack(from_index: int, to_index: int, amount: int = 0) -> int:
	var request_id: int = _take_request_id()
	if _owns_mutation():
		_process_move_request(_local_peer_id(), from_index, to_index, amount, request_id)
	elif bool(_transport().call("is_active")):
		net_request_move_stack.rpc_id(
			NetConfig.HOST_PEER_ID, from_index, to_index, amount, request_id
		)
	else:
		_emit_confirmation(request_id, false, "no authoritative session")
	return request_id


@rpc("any_peer", "call_remote", "reliable")
func net_request_remove(item_id: StringName, amount: int, request_id: int) -> void:
	if not bool(_transport().call("is_host")):
		return
	_process_remove_request(multiplayer.get_remote_sender_id(), item_id, amount, request_id)


@rpc("any_peer", "call_remote", "reliable")
func net_request_move_stack(from_index: int, to_index: int, amount: int, request_id: int) -> void:
	if not bool(_transport().call("is_host")):
		return
	_process_move_request(
		multiplayer.get_remote_sender_id(), from_index, to_index, amount, request_id
	)


@rpc("authority", "call_remote", "reliable")
func net_inventory_snapshot(peer_id: int, revision: int, slots: Array) -> void:
	if peer_id != _local_peer_id() or revision < _local_revision:
		return
	var registry: Node = _registry()
	if not bool(INVENTORY_STORE_SCRIPT.snapshot_is_valid(slots, registry, SLOT_COUNT)):
		MireLog.error(&"inventory", "rejected invalid inventory snapshot r%d" % revision)
		return
	_accept_local_snapshot(
		INVENTORY_STORE_SCRIPT.normalize_snapshot(slots), revision
	)


@rpc("authority", "call_remote", "reliable")
func net_operation_confirmed(request_id: int, accepted: bool, detail: String) -> void:
	_emit_confirmation(request_id, accepted, detail)


func _process_remove_request(
	peer_id: int, item_id: StringName, amount: int, request_id: int
) -> void:
	var accepted: bool = host_remove(peer_id, item_id, amount)
	_confirm_peer(
		peer_id,
		request_id,
		accepted,
		"removed %d %s" % [amount, item_id] if accepted else "remove rejected"
	)


func _process_move_request(
	peer_id: int, from_index: int, to_index: int, amount: int, request_id: int
) -> void:
	var accepted: bool = host_move_stack(peer_id, from_index, to_index, amount)
	_confirm_peer(
		peer_id,
		request_id,
		accepted,
		"moved inventory stack" if accepted else "move rejected"
	)


func _confirm_peer(peer_id: int, request_id: int, accepted: bool, detail: String) -> void:
	if peer_id == _local_peer_id():
		_emit_confirmation(request_id, accepted, detail)
	elif bool(_transport().call("is_active")):
		net_operation_confirmed.rpc_id(peer_id, request_id, accepted, detail)


func _emit_confirmation(request_id: int, accepted: bool, detail: String) -> void:
	operation_confirmed.emit(request_id, accepted, detail)


func _on_harvest_yielded(
	_harvestable_id: StringName,
	peer_id: int,
	item_id: StringName,
	amount: int,
	_world_position: Vector3
) -> void:
	if not _owns_mutation():
		return
	if host_add(peer_id, item_id, amount):
		MireLog.info(&"inventory", "peer %d collected %d %s" % [peer_id, amount, item_id])
	else:
		MireLog.warn(
			&"inventory",
			"peer %d could not collect %d %s (invalid or full)" % [peer_id, amount, item_id]
		)


func _on_session_opened() -> void:
	if _session_open:
		return
	_session_open = true
	_host_stores.clear()
	_revisions.clear()
	_reset_local_cache()
	if not bool(_transport().call("is_host")):
		return
	for peer_id: int in _transport().call("peer_ids"):
		_ensure_host_store(peer_id)
		_publish_snapshot(peer_id)


func _on_peer_joined(peer_id: int) -> void:
	if not bool(_transport().call("is_host")):
		return
	_ensure_host_store(peer_id)
	_publish_snapshot(peer_id)


func _on_peer_left(peer_id: int) -> void:
	if not bool(_transport().call("is_host")):
		return
	_host_stores.erase(peer_id)
	_revisions.erase(peer_id)


func _on_disconnected() -> void:
	_session_open = false
	_host_stores.clear()
	_revisions.clear()
	_reset_local_cache()
	_ensure_host_store(NetConfig.HOST_PEER_ID)
	_publish_snapshot(NetConfig.HOST_PEER_ID)


func _valid_host_peer(peer_id: int) -> bool:
	if not _owns_mutation() or peer_id <= 0:
		return false
	if bool(_transport().call("is_active")):
		var peers: PackedInt32Array = _transport().call("peer_ids")
		if not peers.has(peer_id):
			return false
	else:
		if peer_id != NetConfig.HOST_PEER_ID:
			return false
	_ensure_host_store(peer_id)
	return true


func _owns_mutation() -> bool:
	var transport: Node = _transport()
	if bool(transport.call("is_host")):
		return true
	return not bool(transport.call("is_active")) and not bool(transport.call("is_connecting"))


func _ensure_host_store(peer_id: int) -> void:
	if _host_stores.has(peer_id):
		return
	_host_stores[peer_id] = INVENTORY_STORE_SCRIPT.new(
		_registry(), SLOT_COUNT, INVENTORY_SLOT_COUNT
	)
	_revisions[peer_id] = 0


func _store(peer_id: int) -> RefCounted:
	return _host_stores.get(peer_id) as RefCounted


func _commit(peer_id: int) -> void:
	_revisions[peer_id] = int(_revisions.get(peer_id, 0)) + 1
	_publish_snapshot(peer_id)


func _publish_snapshot(peer_id: int) -> void:
	if not _host_stores.has(peer_id):
		return
	var slots: Array[Dictionary] = _store(peer_id).call("slots_snapshot") as Array[Dictionary]
	var revision: int = int(_revisions.get(peer_id, 0))
	host_inventory_changed.emit(peer_id, _duplicate_slots(slots), revision)
	if peer_id == _local_peer_id():
		_accept_local_snapshot(slots, revision)
	elif bool(_transport().call("is_active")):
		net_inventory_snapshot.rpc_id(peer_id, peer_id, revision, slots)


func _accept_local_snapshot(slots: Array[Dictionary], revision: int) -> void:
	_local_slots = _duplicate_slots(slots)
	_local_revision = revision
	local_inventory_changed.emit(local_slots(), revision)


func _reset_local_cache() -> void:
	_local_slots.clear()
	for _index: int in SLOT_COUNT:
		_local_slots.append({})
	_local_revision = -1


func _take_request_id() -> int:
	var result: int = _next_request_id
	_next_request_id += 1
	if _next_request_id <= 0:
		_next_request_id = 1
	return result


func _local_peer_id() -> int:
	var peer_id: int = int(_transport().call("local_peer_id"))
	return peer_id if peer_id > 0 else NetConfig.HOST_PEER_ID


func _transport() -> Node:
	return get_node(^"/root/NetTransport")


func _registry() -> Node:
	return get_node(^"/root/Registry")


func _duplicate_slots(slots: Array[Dictionary]) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for slot: Dictionary in slots:
		result.append(slot.duplicate())
	return result
