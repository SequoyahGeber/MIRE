class_name Chest
extends Node3D

## Placed-prop loot container: closed until a nearby player opens it. Opens exactly once — there is
## no respawn clock, unlike Harvestable.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, world mutation row): HOST. A client's open request
## carries no roll, no items and no amount — same "harvest pattern" Harvestable already established:
## request → host validates range/state → host rolls its own trusted LootTableDef from a per-chest
## RandomNumberGenerator (never randi()) → grants through InventoryService.host_add() → replies to
## the requester with what it got. The resulting `opened` bool is the only thing replicated to
## everyone else, through a code-built MultiplayerSynchronizer (D-023), same as Harvestable's `active`.
## Offline play runs the same authority path locally. The roll's POWERUP entries are gated by the
## HOST's own UnlockService (D-111/F-173) regardless of who opened the chest — the same
## host-decides-for-everyone shape as the roll itself, chosen over replicating purchases so the
## per-peer "Unlocks" row (§2.2) needs no RPC of its own.

## F-016: brand-new class_names this task introduces are not bare-resolvable in a fresh headless
## clone (no editor scan has rebuilt .godot/global_script_class_cache.cfg yet) — preload them.
const LOOT_TABLE_DEF := preload("res://systems/loot/loot_table_def.gd")

const SYNC_NODE_NAME: StringName = &"ChestSync"
const VISUAL_NODE_NAME: StringName = &"ChestVisual"
const CHEST_GROUP: StringName = &"chest"
## Coins are an item (ItemDef stack_size 999, content/items/coins.tres), not a parallel currency
## system — granted through the exact same InventoryService.host_add() seam as any other loot.
const COIN_ITEM_ID: StringName = &"coins"

## (request_id, accepted, granted, detail). [param granted] is Dictionary[StringName, int], empty on
## rejection. Fired locally on the requester only — everyone else learns the chest opened from the
## replicated `opened` property, never from this signal.
signal open_confirmed(request_id: int, accepted: bool, granted: Dictionary, detail: String)

@export var tier: StringName = &""
## Set per placed instance, same as Harvestable's per-instance visual assignment — presentation is a
## placement detail even though the loot TABLE behind `tier` is shared, registry-indexed content.
@export var closed_scene: PackedScene
@export var open_scene: PackedScene
@export_range(0.5, 20.0, 0.1, "or_greater") var request_range_m: float = 3.0
## Coins the opener pays, before their `chest_price` stat is applied. 0 is a free scatter-cache —
## Muck's proven loop, kept: free caches seed coins, priced chests spend them (`docs/ITEMS.md` §5).
## The price is charged in the SAME host transaction as the key, so a failed payment grants nothing
## and leaves the chest closed and re-openable.
@export_range(0, 999, 1) var cost_coins: int = 0
## Item id of the key this chest needs, or empty for none. Consumed on a successful open — a key is
## spent, not carried. Host-side validation like any other, exactly `docs/ITEMS.md` §6.3.
@export var locked_by: StringName = &""

## Replicated. Setter keeps presentation correct when a network delta arrives on a client.
var opened: bool = false:
	set(value):
		if opened == value:
			return
		opened = value
		_schedule_visual_refresh()

var _configuration_valid: bool = false
var _visual: Node3D
var _sync: MultiplayerSynchronizer
var _visual_refresh_scheduled: bool = false
## Per-chest, independent of every other chest's stream. Never the global randi() (AGENTS.md).
## Seeded from boot-time entropy rather than a fixed constant: unlike EnemyWorld's ambient scatter,
## which must look identical across peers because every peer would otherwise compute it, a chest
## roll happens ONLY on the host and is granted directly — there is nothing for other peers to
## recompute, so nothing requires a fixed seed. This is a stand-in for a real per-run seed: once a
## GameState.run_seed authority exists, re-derive this from (run_seed, a stable per-chest id) instead
## of randomize() — see docs/DECISIONS.md D-041.
var _rng := RandomNumberGenerator.new()
var _next_request_id: int = 1


func _ready() -> void:
	set_multiplayer_authority(NetConfig.HOST_PEER_ID)
	add_to_group(CHEST_GROUP)
	if _owns_world_mutation():
		_rng.randomize()
	_configuration_valid = _validate_configuration()
	_build_synchronizer()
	_refresh_visual()


## Returns a local request id immediately; the answer always arrives through open_confirmed.
func request_open() -> int:
	var request_id: int = _take_request_id()
	if not _configuration_valid or opened:
		_confirm_peer(_local_peer_id(), request_id, false, {}, "chest cannot be opened")
		return request_id
	if not _transport_is_active() or _transport_is_host():
		_accept_open_request(_local_peer_id(), request_id)
	else:
		net_request_open.rpc_id(NetConfig.HOST_PEER_ID, request_id)
	return request_id


## Test/debug seam: force a specific seed rather than the boot-time entropy _ready() chose. Host-only,
## same reasoning as DayNight.host_advance() — genuinely useful for a future debug "reroll" command,
## not scaffolding bolted on only for checks.
func host_seed_rng(seed_value: int) -> bool:
	if not _owns_world_mutation():
		return false
	_rng.seed = seed_value
	return true


@rpc("any_peer", "call_remote", "reliable")
func net_request_open(request_id: int) -> void:
	if not _transport_is_host():
		return
	_accept_open_request(multiplayer.get_remote_sender_id(), request_id)


@rpc("authority", "call_remote", "reliable")
func net_open_result(request_id: int, accepted: bool, granted: Dictionary, detail: String) -> void:
	open_confirmed.emit(request_id, accepted, granted, detail)


func _accept_open_request(peer_id: int, request_id: int) -> void:
	if not _owns_world_mutation() or not _configuration_valid or opened or peer_id <= 0:
		_confirm_peer(peer_id, request_id, false, {}, "chest cannot be opened")
		return
	if not _requester_in_range(peer_id):
		_confirm_peer(peer_id, request_id, false, {}, "too far from the chest")
		return

	var loot_table: Resource = _resolve_loot_table()
	if loot_table == null:
		_confirm_peer(peer_id, request_id, false, {}, "chest has no loot table")
		return

	var inventory: Node = get_node_or_null(^"/root/InventoryService")
	if inventory == null:
		_confirm_peer(peer_id, request_id, false, {}, "chest cannot reach the inventory")
		return

	# Price and key are charged FIRST, in one transaction, and a failure leaves the chest closed.
	# The order matters: rolling first and charging after would hand out a jackpot the opener could
	# not afford, and charging in two steps could take the key and leave the coins (or the reverse).
	var price: int = _price_for(peer_id)
	var removals: Dictionary = {}
	if price > 0:
		removals[COIN_ITEM_ID] = price
	if locked_by != &"":
		removals[locked_by] = 1
	if not removals.is_empty():
		if not bool(inventory.call("host_transaction", peer_id, removals, {})):
			var reason: String = "you need %d coins" % price
			if locked_by != &"" and int(inventory.call("host_count", peer_id, locked_by)) <= 0:
				reason = "locked — you need a %s" % _display_name_for(locked_by)
			_confirm_peer(peer_id, request_id, false, {}, reason)
			return

	var roll: Dictionary = loot_table.call("roll", _rng, _luck_for(peer_id), _unlock_check())
	var granted: Dictionary = {}

	var coin_amount: int = int(roll.get("coins", 0))
	if coin_amount > 0 and bool(inventory.call("host_add", peer_id, COIN_ITEM_ID, coin_amount)):
		granted[COIN_ITEM_ID] = coin_amount
	var items: Dictionary = roll.get("items", {})
	for item_id: StringName in items:
		var amount: int = int(items[item_id])
		if amount > 0 and bool(inventory.call("host_add", peer_id, item_id, amount)):
			granted[item_id] = int(granted.get(item_id, 0)) + amount
	# Powerups do not go through the inventory at all — they are held state on PowerupService, which
	# owns its own replication. Same open, same host, different seam.
	var powerups: Dictionary = roll.get("powerups", {})
	if not powerups.is_empty():
		var powerup_service: Node = get_node_or_null(^"/root/PowerupService")
		for powerup_id: StringName in powerups:
			var count: int = int(powerups[powerup_id])
			if count <= 0:
				continue
			if powerup_service == null:
				push_warning("Chest %s rolled powerup '%s' with no PowerupService" % [name, powerup_id])
				continue
			var given: int = int(powerup_service.call("host_grant", peer_id, powerup_id, count))
			if given > 0:
				granted[powerup_id] = int(granted.get(powerup_id, 0)) + given

	# Opens even when every individual grant above was rejected (e.g. a full inventory) — a chest
	# that silently stays closed and re-rollable is worse than an empty-handed open. The requester's
	# detail reflects exactly what they walked away with, empty Dictionary included.
	opened = true
	_confirm_peer(peer_id, request_id, true, granted, "chest opened")


## The opener's own price, after `chest_price` — a stat three shipped powerups already grant and
## nothing read until now (F-140). Never below zero, and never below 1 while the chest costs
## anything at all: a discount that reaches "free" would make a priced tier unpriced.
func _price_for(peer_id: int) -> int:
	if cost_coins <= 0:
		return 0
	var powerups: Node = get_node_or_null(^"/root/PowerupService")
	if powerups == null:
		return cost_coins
	return maxi(1, int(roundf(float(powerups.call("stat", peer_id, &"chest_price", float(cost_coins))))))


## Read against a base of 1.0, not 0.0. Every authored `loot_luck` modifier is multiplicative
## (`second_glance` and `fruiting_call` are Vector2(0, 0.06); The Landlord is Vector2(0, -0.5)'s
## sibling at +0.3), and PowerupService computes `(base + flat * N) * (1 + mult * N)` — so asking
## for it on a base of zero returns zero however many stacks you hold, which is exactly the shape
## of bug F-140 was about. Asking on 1.0 and taking the surplus makes both authoring shapes work:
## a +6% stack reads as 0.06, a flat +0.5 reads as 0.5.
func _luck_for(peer_id: int) -> float:
	var powerups: Node = get_node_or_null(^"/root/PowerupService")
	if powerups == null:
		return 0.0
	return maxf(0.0, float(powerups.call("stat", peer_id, &"loot_luck", 1.0)) - 1.0)


## D-111/F-173's chosen design: the HOST's own unlock tree gates the roll for the whole party, no
## RPC needed. This runs only inside `_accept_open_request()`, which only ever executes in the host
## process (either locally, or via `net_request_open`'s `_transport_is_host()` guard above) — so
## `/root/UnlockService` resolved here is always the host's own save, never the opening peer's,
## exactly the shape D-111 picked over replicating purchases.
func _unlock_check() -> Callable:
	var unlock_service: Node = get_node_or_null(^"/root/UnlockService")
	if unlock_service == null or not unlock_service.has_method("is_content_unlocked"):
		return Callable()
	return Callable(unlock_service, "is_content_unlocked")


func _display_name_for(item_id: StringName) -> String:
	var registry: Node = get_node_or_null(^"/root/Registry")
	if registry == null or not registry.has_method("get_item"):
		return String(item_id)
	var item: Resource = registry.call("get_item", item_id) as Resource
	if item == null:
		return String(item_id)
	var display: String = String(item.get("display_name"))
	return display if not display.is_empty() else String(item_id)


func _requester_in_range(peer_id: int) -> bool:
	# Offline mode has no PlayerNet spawn. The local interact that owns this call is the validation
	# seam there; in a session the host must independently verify the remote player's position —
	# exactly Harvestable._request_is_valid's reasoning.
	if not _transport_is_active():
		return true
	var player_net: Node = get_node_or_null(^"/root/PlayerNet")
	if player_net == null or not player_net.has_method("player_for"):
		return false
	var player: Node3D = player_net.call("player_for", peer_id) as Node3D
	if player == null:
		return false
	var range_sq: float = request_range_m * request_range_m
	return global_position.distance_squared_to(player.global_position) <= range_sq


func _resolve_loot_table() -> Resource:
	var registry: Node = get_node_or_null(^"/root/Registry")
	if registry == null or not registry.has_method("get_loot_table"):
		return null
	return registry.call("get_loot_table", tier) as Resource


func _confirm_peer(peer_id: int, request_id: int, accepted: bool, granted: Dictionary, detail: String) -> void:
	if peer_id == _local_peer_id():
		open_confirmed.emit(request_id, accepted, granted, detail)
	elif _transport_is_active() and _peer_connected(peer_id):
		net_open_result.rpc_id(peer_id, request_id, accepted, granted, detail)


## F-059/3.8: D-035 keeps a departed peer's state alive through NetSession's grace window rather than
## releasing it on peer_left, so a peer id can outlive its live transport connection. Guard every
## rpc_id() send in this file against that, same fix player_health.gd already carries.
func _peer_connected(peer_id: int) -> bool:
	var transport: Node = _transport()
	if transport == null:
		return false
	var peers: PackedInt32Array = transport.call("peer_ids")
	return peers.has(peer_id)


func _validate_configuration() -> bool:
	if tier == &"":
		push_error("Chest %s has no tier" % name)
		return false
	var registry: Node = get_node_or_null(^"/root/Registry")
	if registry == null or not registry.has_method("get_loot_table"):
		push_error("Chest %s cannot validate its loot table without Registry" % name)
		return false
	var table: Resource = registry.call("get_loot_table", tier) as Resource
	if table == null:
		push_error("Chest %s references unknown loot tier '%s'" % [name, tier])
		return false
	if table.get_script() != LOOT_TABLE_DEF:
		push_error("Chest %s tier '%s' did not resolve to a LootTableDef" % [name, tier])
		return false
	var errors: PackedStringArray = table.call("validation_errors")
	if not errors.is_empty():
		push_error("Chest %s loot table is invalid: %s" % [name, "; ".join(errors)])
		return false
	return true


func _build_synchronizer() -> void:
	var config := SceneReplicationConfig.new()
	var property_path := NodePath(".:opened")
	config.add_property(property_path)
	config.property_set_spawn(property_path, true)
	config.property_set_replication_mode(
		property_path, SceneReplicationConfig.REPLICATION_MODE_ON_CHANGE
	)

	_sync = MultiplayerSynchronizer.new()
	_sync.name = SYNC_NODE_NAME
	_sync.root_path = NodePath("..")
	_sync.replication_config = config
	_sync.set_multiplayer_authority(NetConfig.HOST_PEER_ID)
	NetInterest.configure(_sync, self, NetInterest.Class.PROP)
	add_child(_sync)


func _refresh_visual() -> void:
	if not is_inside_tree():
		return
	var scene: PackedScene = open_scene if opened else closed_scene
	if _visual != null:
		remove_child(_visual)
		_visual.queue_free()
		_visual = null
	if scene == null:
		return
	_visual = scene.instantiate() as Node3D
	if _visual == null:
		push_error("Chest %s: state scene root must be Node3D" % name)
		return
	_visual.name = VISUAL_NODE_NAME
	add_child(_visual)


func _schedule_visual_refresh() -> void:
	if _visual_refresh_scheduled:
		return
	_visual_refresh_scheduled = true
	call_deferred("_flush_visual_refresh")


func _flush_visual_refresh() -> void:
	if not _visual_refresh_scheduled:
		return
	_visual_refresh_scheduled = false
	_refresh_visual()


func _owns_world_mutation() -> bool:
	return not _transport_is_active() or _transport_is_host()


func _transport() -> Node:
	return get_node_or_null(^"/root/NetTransport")


func _transport_is_active() -> bool:
	var transport: Node = _transport()
	return transport != null and bool(transport.call("is_active"))


func _transport_is_host() -> bool:
	var transport: Node = _transport()
	return transport != null and bool(transport.call("is_host"))


func _local_peer_id() -> int:
	var transport: Node = _transport()
	if transport == null or not _transport_is_active():
		return NetConfig.HOST_PEER_ID
	return int(transport.call("local_peer_id"))


func _take_request_id() -> int:
	var result: int = _next_request_id
	_next_request_id += 1
	if _next_request_id <= 0:
		_next_request_id = 1
	return result
