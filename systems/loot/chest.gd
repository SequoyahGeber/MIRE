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
const EVENT_BUS := preload("res://core/events/event_bus.gd")

const SYNC_NODE_NAME: StringName = &"ChestSync"
const VISUAL_NODE_NAME: StringName = &"ChestVisual"
const LOCATOR_NODE_NAME: StringName = &"ChestLocator"
const LOCATOR_LIGHT_NAME: StringName = &"ChestLocatorLight"
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
## Locator mote/light colour for this chest's tier, set per placed instance by
## ChestPlacementService the same way `closed_scene` is. Presentation only — it never reaches the
## roll, the price or the wire. The default is the original warm amber every chest used before the
## tier ladder existed, so an instance nothing tints still looks exactly as it did.
@export var locator_tint: Color = Color(1.0, 0.64, 0.12)
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
var _locator: MeshInstance3D
var _locator_light: OmniLight3D
var _sync: MultiplayerSynchronizer
var _visual_refresh_scheduled: bool = false
## Per-chest, independent of every other chest's stream. Never the global randi() (AGENTS.md).
## F-210: seeded from (GameState.run_seed, this node's own name) rather than boot-time entropy, so
## two runs sharing a seed (a deliberate replay, a --seed= repro, F-172's solo seed entry) roll the
## same loot — D-041's own reversal trigger, fired once GameState.run_seed shipped in task 4.6. A
## chest roll still happens ONLY on the host and is granted directly, so nothing requires cross-peer
## agreement on the VALUE; this is about run-to-run reproducibility, not replication. `name` is the
## stable per-chest id: ChestPlacementService sets it to "Chest_<marker name>" before add_child(), so
## it comes from the authored map layout, not from anything generated — see _seed_for_run() below.
var _rng := RandomNumberGenerator.new()
var _next_request_id: int = 1


func _ready() -> void:
	set_multiplayer_authority(NetConfig.HOST_PEER_ID)
	add_to_group(CHEST_GROUP)
	if _owns_world_mutation():
		_rng.seed = _seed_for_run(_run_seed(), String(name))
	_configuration_valid = _validate_configuration()
	_build_synchronizer()
	_build_locator()
	_refresh_visual()
	EVENT_BUS.subscribe_run_restarted(_on_run_restarted)


func _exit_tree() -> void:
	EVENT_BUS.unsubscribe_run_restarted(_on_run_restarted)


## F-243: re-closes this chest for a new run. Host-only; a client's own copy no-ops and picks up the
## reset through the normal replicated-property sync `opened` already uses.
##
## F-258 reverses this method's original "`_rng`'s sequence is deliberately left running rather than
## reseeded" — that was correct only while D-149 kept the same world seed across a restart, and D-161
## draws a fresh one. Re-seeding from `(the NEW run_seed, this chest's name)` is what makes the
## second run's loot genuinely a different run rather than the tail of the first one's stream, and it
## restores F-210's actual contract: a chest's roll is a pure function of (run seed, chest id), so
## two processes replaying the same seed still open the same chest onto the same loot. Order is safe
## by construction — `CycleService.host_restart_run()` reseeds `GameState` before it emits
## `run_restarted`, so `_run_seed()` here already reads the new value.
func host_reset_for_new_run() -> void:
	if not _owns_world_mutation():
		return
	opened = false
	_rng.seed = _seed_for_run(_run_seed(), String(name))


func _on_run_restarted() -> void:
	host_reset_for_new_run()


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
## nothing read until now (F-140) — and after Cycle Modifier `static`'s own halving (F-245,
## content/cycle_modifiers/static.tres: "every chest's coin cost is halved"). Never below zero, and
## never below 1 while the chest costs anything at all: a discount that reaches "free" would make a
## priced tier unpriced.
func _price_for(peer_id: int) -> int:
	if cost_coins <= 0:
		return 0
	var powerups: Node = get_node_or_null(^"/root/PowerupService")
	var price: float = (
		float(powerups.call("stat", peer_id, &"chest_price", float(cost_coins)))
		if powerups != null else float(cost_coins)
	)
	if _static_active():
		price *= 0.5
	return maxi(1, int(roundf(price)))


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
##
## Cycle Modifier `static` (F-245, content/cycle_modifiers/static.tres: "no chest rolls a powerup
## entry this Cycle") reuses this exact gate rather than adding a second one to `LootTableDef.roll()`
## — `roll()` already treats a POWERUP entry this Callable refuses as zero-weight, the identical
## mechanism D-111 built for the unlock tree, so a Callable that refuses everything while `static` is
## active needs no change to that file at all.
func _unlock_check() -> Callable:
	if _static_active():
		return func(_content_id: StringName) -> bool: return false
	var unlock_service: Node = get_node_or_null(^"/root/UnlockService")
	if unlock_service == null or not unlock_service.has_method("is_content_unlocked"):
		return Callable()
	return Callable(unlock_service, "is_content_unlocked")


func _static_active() -> bool:
	var modifiers: Node = get_node_or_null(^"/root/CycleModifierService")
	return modifiers != null and bool(modifiers.call(&"has_modifier", &"static"))


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
	_refresh_locator()


## The smallest chest is only 0.75 m wide on an island hundreds of metres across. This warm mote
## keeps an unopened chest legible through grass without changing placement, collision, interaction,
## or network authority. It disappears from every peer when the replicated `opened` state changes.
func _build_locator() -> void:
	_locator = MeshInstance3D.new()
	_locator.name = LOCATOR_NODE_NAME
	_locator.position = Vector3(0.0, 1.35, 0.0)
	var mote := SphereMesh.new()
	mote.radius = 0.13
	mote.height = 0.34
	_locator.mesh = mote
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(locator_tint, 1.0)
	material.emission_enabled = true
	# The emission is the tint pushed toward saturation rather than the tint itself: a mote emitting
	# its own albedo washes to white at 3.5x energy, which is how five differently tinted motes would
	# all end up as the same white dot at exactly the range this exists to work at. Saturating in HSV
	# keeps each tier's HUE, which is the only channel that survives the wash.
	material.emission = Color.from_hsv(
		locator_tint.h, minf(1.0, locator_tint.s * 1.35 + 0.12), locator_tint.v
	)
	material.emission_energy_multiplier = 3.5
	_locator.material_override = material
	add_child(_locator)

	_locator_light = OmniLight3D.new()
	_locator_light.name = LOCATOR_LIGHT_NAME
	_locator_light.position = Vector3(0.0, 0.85, 0.0)
	_locator_light.light_color = Color(locator_tint, 1.0)
	_locator_light.light_energy = 1.8
	_locator_light.omni_range = 5.0
	_locator_light.shadow_enabled = false
	add_child(_locator_light)


func _refresh_locator() -> void:
	if _locator != null:
		_locator.visible = not opened
	if _locator_light != null:
		_locator_light.visible = not opened


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


## Host-only caller (F-210). GameState is a project-wide autoload (project.godot), present in every
## scene including a headless SceneTree check, so this never needs a null guard the way NetTransport
## lookups above do. ensure_seed() lazily draws one from real entropy if nothing has drawn it yet
## (offline/host-of-one boot order), matching game_state.gd's own documented contract, and is a no-op
## once a seed already exists — the common case, since MireGrid/NetTransport draw one earlier.
func _run_seed() -> int:
	# A procedural rebuild may detach this chest before its turn in the current EventBus dispatch.
	if not is_inside_tree():
		return 0
	var game_state: Node = get_node_or_null(^"/root/GameState")
	if game_state == null:
		return 0
	return int(game_state.call("ensure_seed"))


## Salt distinguishes this file's seed derivation from any other system mixing the same run_seed
## (world/gen/poi_map.gd's 0x9017A11, world/gen/resource_scatter.gd's 0x5CA77E5) — same "XOR-a-salt"
## convention those two files already establish. Integer multiply/xor only, same rule they state:
## never Godot's hash(), whose StringName/String stability across platforms and engine versions is
## not a documented guarantee the way fixed-width 64-bit int overflow is.
const _SEED_SALT: int = 0xC4E57


func _seed_for_run(run_seed: int, chest_id: String) -> int:
	const PRIME: int = 1000003
	var id_hash: int = 0x1000193
	for byte: int in chest_id.to_utf8_buffer():
		id_hash = (id_hash ^ byte) * 16777619
	var h: int = run_seed ^ _SEED_SALT
	h = h * PRIME + id_hash
	return h


func _transport() -> Node:
	if not is_inside_tree():
		return null
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
