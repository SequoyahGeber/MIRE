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

## The array carried by local_inventory_changed is the service's own snapshot — read it, don't
## mutate it, and duplicate it if you keep it past the handler (F-099). Every subscriber gets the
## same instance, so a mutation would corrupt what the others (and this service) see.
signal local_inventory_changed(slots: Array[Dictionary], revision: int)
signal host_inventory_changed(peer_id: int, slots: Array[Dictionary], revision: int)
signal operation_confirmed(request_id: int, accepted: bool, detail: String)

var _host_stores: Dictionary[int, RefCounted] = {}
var _revisions: Dictionary[int, int] = {}
var _local_slots: Array[Dictionary] = []
var _local_revision: int = -1
var _next_request_id: int = 1
var _session_open: bool = false
## Cached transport ref (F-099). Path-resolved (F-011 — harnesses install theirs at /root).
var _transport_node: Node
## Cached MireGrid ref (F-099), same reason. MireGrid registers after this autoload, so it is
## resolved lazily rather than in _ready() (F-011).
var _mire_grid_node: Node


func _ready() -> void:
	_reset_local_cache()
	EVENT_BUS.subscribe_harvest_yielded(_on_harvest_yielded)
	EVENT_BUS.subscribe_run_restarted(_on_run_restarted)
	var transport: Node = _transport()
	transport.get("server_started").connect(_on_session_opened)
	transport.get("connected_to_host").connect(_on_session_opened)
	transport.get("disconnected").connect(_on_disconnected)
	transport.get("peer_joined").connect(_on_peer_joined)
	transport.get("peer_left").connect(_on_peer_left)
	# F-032: NetSession owns run-player identity, so it decides when a departure is final. Connected
	# by path rather than by identifier because this autoload is reached from --script harnesses
	# (F-011), and guarded because a harness may drive InventoryService without a session layer.
	var session: Node = get_node_or_null(^"/root/NetSession")
	if session != null and session.has_signal(&"run_player_rebound"):
		session.connect(&"run_player_rebound", _on_run_player_rebound)
		session.connect(&"run_player_expired", _on_run_player_expired)
	if bool(transport.call("is_active")):
		_on_session_opened.call_deferred()
	else:
		_ensure_host_store(NetConfig.HOST_PEER_ID)
		_publish_snapshot(NetConfig.HOST_PEER_ID)
	_register_commands()



func _exit_tree() -> void:
	EVENT_BUS.unsubscribe_harvest_yielded(_on_harvest_yielded)
	EVENT_BUS.unsubscribe_run_restarted(_on_run_restarted)


func local_slots() -> Array[Dictionary]:
	return _duplicate_slots(_local_slots)


## One confirmed local slot, copied, without duplicating the whole array. {} when out of range.
func local_slot(index: int) -> Dictionary:
	if index < 0 or index >= _local_slots.size():
		return {}
	return _local_slots[index].duplicate()


## Allocation-light read of one local slot's item id, for per-frame callers (F-099).
## &"" for an out-of-range, empty, or exhausted slot — same answer held-item logic wants.
func local_item_id(index: int) -> StringName:
	if index < 0 or index >= _local_slots.size():
		return &""
	var slot: Dictionary = _local_slots[index]
	if int(slot.get("amount", 0)) <= 0:
		return &""
	return StringName(String(slot.get("item_id", "")))


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
	elif bool(_transport().call("is_active")) and _peer_connected(peer_id):
		net_operation_confirmed.rpc_id(peer_id, request_id, accepted, detail)


func _emit_confirmation(request_id: int, accepted: bool, detail: String) -> void:
	operation_confirmed.emit(request_id, accepted, detail)


## Task 4.11's "rotted resource yields": ground rich enough in corruption spoils part of the
## harvest before it ever reaches a pack. Reduction only, never a substitution — no new item exists
## to substitute in (content is hand-authored, D-073, and this task authors none), so "rotted" reads
## as a smaller yield rather than a different one.
func _on_harvest_yielded(
	_harvestable_id: StringName,
	peer_id: int,
	item_id: StringName,
	amount: int,
	world_position: Vector3
) -> void:
	if not _owns_mutation():
		return
	var granted: int = _rot_adjusted_amount(amount, world_position)
	if host_add(peer_id, item_id, granted):
		if granted < amount:
			MireLog.info(&"inventory", "peer %d collected %d/%d %s — the Mire rotted the rest" % [
				peer_id, granted, amount, item_id
			])
		else:
			MireLog.info(&"inventory", "peer %d collected %d %s" % [peer_id, granted, item_id])
	else:
		MireLog.warn(
			&"inventory",
			"peer %d could not collect %d %s (invalid or full)" % [peer_id, granted, item_id]
		)


## Never returns less than 1 for a positive `amount` — corruption spoils PART of a harvest, it does
## not make gathering pointless. Loss scales linearly with corruption (0..1): full corruption costs
## up to ROT_LOSS_FRACTION of the yield, clean ground costs nothing.
const ROT_LOSS_FRACTION: float = 0.6


func _rot_adjusted_amount(amount: int, world_position: Vector3) -> int:
	if amount <= 1:
		return amount
	var mire_grid: Node = _mire_grid()
	if mire_grid == null:
		return amount
	var corruption: float = float(mire_grid.call(&"corruption_at", world_position))
	if corruption <= 0.0:
		return amount
	var lost: int = floori(float(amount) * corruption * ROT_LOSS_FRACTION)
	return maxi(1, amount - lost)


func _mire_grid() -> Node:
	if _mire_grid_node == null or not is_instance_valid(_mire_grid_node):
		_mire_grid_node = get_node_or_null(^"/root/MireGrid")
	return _mire_grid_node


func _on_session_opened() -> void:
	if _session_open:
		return
	_session_open = true
	_host_stores.clear()
	_revisions.clear()
	_reset_local_cache()
	if bool(_transport().call("is_active")):
		if not bool(_transport().call("is_host")):
			return
		for peer_id: int in _transport().call("peer_ids"):
			_ensure_host_store(peer_id)
			_publish_snapshot(peer_id)
	else:
		# Mirrors `_ready()`'s own offline branch (`peer_ids()` is empty offline, so the loop above
		# would silently skip the local peer) — F-243's restart needed to reach this path a second
		# time, which is what surfaced this gap; `_ready()` only ever hit it once, at boot.
		_ensure_host_store(NetConfig.HOST_PEER_ID)
		_publish_snapshot(NetConfig.HOST_PEER_ID)


## F-243: a new run wants exactly what a fresh session already gives every store — empty, re-
## published to every connected peer — without actually tearing down and reopening the real
## `NetTransport` session (D-243's scope: the run resets, the multiplayer session does not). Toggling
## `_session_open` off first is what lets `_on_session_opened()`'s own guard re-run instead of no-op-
## ping on the "already open" branch.
func host_reset_for_new_run() -> void:
	_session_open = false
	_on_session_opened()


## Two halves, split the same way `systems/health/player_health.gd`'s handler is and for the same
## reason (F-308, the sibling of F-298 — that entry states the general rule: an `_owns_mutation()`
## gate on a `run_restarted` handler is correct only when every field behind it is replicated).
##
## **Before the gate — every peer.** `_local_revision` is not replicated; it is this peer's private
## record of the last snapshot it accepted, and `net_inventory_snapshot()` drops anything below it.
## The restart resets the host's counters — `_on_session_opened()` clears `_revisions` and
## `_ensure_host_store()` re-seeds each peer at 0 — so the new run's snapshots come in BELOW a
## client's carried-over value and every one of them is discarded as stale. A client that ran 40
## inventory transactions last run therefore keeps showing last run's items and silently swallows the
## first 40 transactions of the new one. Unlike `PlayerHealth`, nothing here republishes on a timer,
## so there is no drift back to correct: it stays wrong until the counter climbs past the old value.
## `_reset_local_cache()` fixes both halves at once — the stale slots and the guard.
##
## **After the gate — the host's rebuild.** `_owns_mutation()`, not `is_host()` (F-243's original
## bug, caught by `tools/run_restart_check.gd`): solo/offline is this file's whole other mode
## (`_ready()`'s own else-branch), and `is_host()` reads false there (`NetTransport.is_host()`'s own
## doc comment — it is true only while an actual session is HOSTING). A solo restart never called
## `host_reset_for_new_run()` at all until this was fixed.
func _on_run_restarted() -> void:
	_reset_local_cache()
	if _owns_mutation():
		host_reset_for_new_run()


func _on_peer_joined(peer_id: int) -> void:
	if not bool(_transport().call("is_host")):
		return
	_ensure_host_store(peer_id)
	_publish_snapshot(peer_id)


## Deliberately does NOT release the inventory (F-032). Between a drop and a rejoin the player is
## still a player, and this used to be where their whole inventory went — 1.7 proved a reconnecting
## client returns under a new peer id, so releasing here made every reconnect a wipe. NetSession
## holds the identity for its grace window and then says which of the two things happened:
## `run_player_rebound` (move it) or `run_player_expired` (release it). If no session layer is
## present at all, nothing here holds state anyway — an offline host is the only peer.
func _on_peer_left(_peer_id: int) -> void:
	pass


## The same player is back under a new peer id. Carry the store and its revision across, so the
## client's next snapshot continues its own history instead of starting from an empty pack.
func _on_run_player_rebound(old_peer_id: int, new_peer_id: int) -> void:
	# _owns_mutation(), not is_host(): offline the local peer owns every store, and that is the mode
	# the focused check drives these signals in.
	if not _owns_mutation() or not _host_stores.has(old_peer_id):
		return
	# A rejoining peer may already have had an empty store created for it by _on_peer_joined, which
	# fires before the hello that identifies it. The old store wins; the placeholder is discarded.
	_host_stores[new_peer_id] = _host_stores[old_peer_id]
	_revisions[new_peer_id] = int(_revisions.get(old_peer_id, 0))
	_host_stores.erase(old_peer_id)
	_revisions.erase(old_peer_id)
	_publish_snapshot(new_peer_id)


func _on_run_player_expired(peer_id: int) -> void:
	if not _owns_mutation():
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


## F-074: a peer with a live `_host_stores` entry is a valid mutation target even while parked
## mid-D-035-grace-window with no live transport connection behind it — the same way
## player_health.gd's host_apply_damage only checks `_states.has(peer_id)` and lets
## damage/starvation keep accruing for a parked player. Before D-035 this connectivity check and
## "valid target" were the same fact, because peer_left released the store immediately; now the
## store outlives peer_left on purpose, so requiring transport.peer_ids() here silently dropped
## every grant/removal/move for someone mid-drop or laggy. `_publish_snapshot` already gates its
## `rpc_id` send on `_peer_connected` (F-059), so publishing to a parked peer's store immediately
## is safe — it just updates host-side state that either rebinds to the reconnect or expires with
## the grace window, and a lost grant is worse than a stale snapshot the reconnect overwrites.
## A peer with no store yet (never joined, or a spoofed id) still needs a live transport
## connection — or, offline, must be the host — before one is created for it.
func _valid_host_peer(peer_id: int) -> bool:
	if not _owns_mutation() or peer_id <= 0:
		return false
	if _host_stores.has(peer_id):
		return true
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


## Guards every rpc_id(peer_id, ...) send in this file (F-059). D-035 keeps a departed peer's store
## alive through NetSession's grace window (rebind or expire) rather than releasing it on peer_left,
## so a peer id can sit in _host_stores/_revisions with no live transport connection behind it. Any
## _commit(peer_id) reached while that peer is mid-grace-window — a harvest yield landing, a crafting
## response, anything routed through host_add()/host_transaction() — would otherwise send
## net_inventory_snapshot to a peer id the transport no longer recognises, which Godot logs as an
## engine error ("Attempt to call RPC with unknown peer ID"), not a silent no-op. Same fix as
## systems/health/player_health.gd's own _peer_connected — see its class doc for the fuller shape.
func _peer_connected(peer_id: int) -> bool:
	return bool(_transport().call("has_peer", peer_id))


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
	elif bool(_transport().call("is_active")) and _peer_connected(peer_id):
		net_inventory_snapshot.rpc_id(peer_id, peer_id, revision, slots)


func _accept_local_snapshot(slots: Array[Dictionary], revision: int) -> void:
	# Both callers hand over a freshly built array (slots_snapshot()/normalize_snapshot), so it is
	# owned here without another copy, and the emit shares it read-only — see the signal doc (F-099).
	_local_slots = slots
	_local_revision = revision
	local_inventory_changed.emit(_local_slots, revision)


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
	if _transport_node == null or not is_instance_valid(_transport_node):
		_transport_node = get_node(^"/root/NetTransport")
	return _transport_node


func _registry() -> Node:
	return get_node(^"/root/Registry")


func _duplicate_slots(slots: Array[Dictionary]) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for slot: Dictionary in slots:
		result.append(slot.duplicate())
	return result


# ── Commands (docs/COMMANDS.md §7 — task 3.16) ───────────────────────────────────────────────────


## Every verb here wraps a seam that already existed (§3.3). `give` is NOT registered here: it lives
## in core/dev/dev_loadout.gd, which owned it before the command track and still owns the
## grant-with-a-loadout-policy shape it applies.
func _register_commands() -> void:
	var command_service: Node = get_node_or_null(^"/root/CommandService")
	if command_service == null:
		return
	# COMMANDS.md §7 lists `clear` twice — once under Inventory ("clear [target]") and once under
	# Meta ("clear (console)"). They cannot both own the name, and `register_spec` replaces silently,
	# so shipping both would have quietly broken whichever registered second. The console's `clear`
	# wins: it predates the command track, it is what every user of a console already expects that
	# word to do, and an inventory wipe is the rarer of the two by a wide margin. The inventory verb
	# becomes a subcommand of `inv`, which reads better anyway. Recorded as D-093, found by
	# tools/command_catalog_check.gd rather than by reading the spec.
	command_service.call("register_spec", &"inv", {
		"scope": &"host",
		"args": [
			{"name": "op", "type": &"enum", "optional": true, "default": "list",
				"values": ["list", "clear"]},
			{"name": "target", "type": &"peer", "optional": true, "default": 0},
		],
		"handler": _cmd_inv,
		"help": "inv [list|clear] [peer] — list or empty a player's inventory",
	})
	command_service.call("register_spec", &"loot", {
		"scope": &"host",
		"args": [
			{"name": "op", "type": &"enum", "values": ["roll"]},
			{"name": "table", "type": &"loot_table_id"},
			{"name": "target", "type": &"peer", "optional": true, "default": 0},
		],
		"handler": _cmd_loot,
		"help": "loot roll <table_id> [peer] — roll a loot table into an inventory",
	})


## `host_remove` per stack rather than a new `host_clear`: the removal path already publishes and
## replicates correctly, and §3.3 is explicit that a command adds no second mutation path. An empty
## inventory is a handful of removals, not a reason to grow one.
func _cmd_inv(ctx: Dictionary, args: Dictionary) -> Dictionary:
	if String(args.get("op", "list")) == "clear":
		return _clear_inventory(ctx, args)
	return _list_inventory(ctx, args)


func _clear_inventory(ctx: Dictionary, args: Dictionary) -> Dictionary:
	var peer_id: int = _resolve_peer(ctx, args)
	var removed: int = 0
	for slot: Dictionary in host_slots(peer_id):
		# The store's snapshot shape is {item_id, amount} (inventory_store.gd) — F-239 was this
		# function reading {item, count} and silently clearing nothing.
		var item_id := StringName(String(slot.get("item_id", "")))
		var amount: int = int(slot.get("amount", 0))
		if item_id != &"" and amount > 0 and host_remove(peer_id, item_id, amount):
			removed += amount
	return {"ok": true, "message": "cleared %d item(s) from peer %d" % [removed, peer_id],
		"data": {"peer": peer_id, "removed": removed}}


func _list_inventory(ctx: Dictionary, args: Dictionary) -> Dictionary:
	var peer_id: int = _resolve_peer(ctx, args)
	var lines: PackedStringArray = []
	var total: int = 0
	for slot: Dictionary in host_slots(peer_id):
		var item_id := StringName(String(slot.get("item_id", "")))
		var amount: int = int(slot.get("amount", 0))
		if item_id == &"" or amount <= 0:
			continue
		total += amount
		lines.append("  %s x%d" % [item_id, amount])
	if lines.is_empty():
		return {"ok": true, "message": "peer %d is carrying nothing" % peer_id,
			"data": {"peer": peer_id, "slots": []}}
	lines.insert(0, "peer %d carries %d item(s):" % [peer_id, total])
	return {"ok": true, "message": "\n".join(lines),
		"data": {"peer": peer_id, "slots": host_slots(peer_id)}}


## Registered here rather than in a loot service because there is no loot autoload — a LootTableDef
## is content, `Chest` is the only thing that rolls one today, and the seam this verb actually needs
## is `host_add`, which is this file's. If M6 ever grows a LootService, this moves there whole.
func _cmd_loot(ctx: Dictionary, args: Dictionary) -> Dictionary:
	var peer_id: int = _resolve_peer(ctx, args)
	var table_id: StringName = args.get("table", &"")
	var registry: Node = get_node_or_null(^"/root/Registry")
	var table: Resource = registry.call("get_loot_table", table_id) if registry != null else null
	if table == null:
		return {"ok": false, "message": "no such loot table '%s' — try 'loot'" % table_id, "data": {}}
	# Its own RNG, seeded from the OS: a debug roll must never advance a run's shared or world-gen
	# streams, which is the same rule selectors follow (COMMANDS.md §3.2).
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var rolled: Dictionary = table.call("roll", rng, 0.0)
	var granted: PackedStringArray = []
	for key: Variant in rolled:
		var item_id := StringName(String(key))
		var amount: int = int(rolled[key])
		if amount > 0 and host_add(peer_id, item_id, amount):
			granted.append("%s x%d" % [item_id, amount])
	if granted.is_empty():
		return {"ok": true, "message": "%s rolled nothing" % table_id,
			"data": {"table": String(table_id), "peer": peer_id, "granted": {}}}
	return {"ok": true, "message": "%s -> peer %d: %s" % [table_id, peer_id, ", ".join(granted)],
		"data": {"table": String(table_id), "peer": peer_id, "granted": rolled}}


## `[peer]` defaults to the issuer, so `clear` and `inv` mean "mine" — the reading every one of these
## verbs wants at a console, and the one COMMANDS.md §2.1's own `give` example encodes with `@s`.
func _resolve_peer(ctx: Dictionary, args: Dictionary) -> int:
	var requested: int = int(args.get("target", 0))
	return requested if requested > 0 else int(ctx.get("peer_id", NetConfig.HOST_PEER_ID))
