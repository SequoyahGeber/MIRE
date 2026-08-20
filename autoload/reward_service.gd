extends Node

## RewardService — autoload. Closes F-183: `docs/ITEMS.md` §5 authors a `wellspring` tier ("granted
## on a cap — never priced ... the objective's paycheck") and a `boss` tier ("guardian / titan
## kills"), and both pass `tools/loot_content_check.gd`'s id-resolution sweep, but nothing ever
## called `LootTableDef.roll()` against either one — `Wellspring._finish_cap()` only ever flips
## `capped`, and `Boss._play_state_animation()` only ever flips `state`. This file is the missing
## caller for both.
##
## `EventBus.emit_wellspring_capped()`/`emit_boss_defeated()` already fire identically on every
## peer, straight from a replicated property's own setter (`Wellspring.capped`,
## `Boss._play_state_animation()` off `Enemy.state`) — the D-107/D-108/F-168/F-181 fix pattern. This
## listens for both and, HOST-ONLY, rolls the trigger's tier once PER currently present player and
## grants that player their own roll — the same "everyone loots" shape a party sees at any other
## chest, just without a container to walk up to and open. See D-123 for the two calls this file
## makes that the finding itself left open:
##   1. Direct grant, not a spawned `Chest` — a dynamically-instanced networked node has no
##      established cross-peer NodePath-sync story in this codebase outside `MultiplayerSpawner`
##      (enemies/players) and `ChestPlacementService`'s marker-derived, boot-deterministic bridge;
##      an event-timed trigger fits neither.
##   2. One independent roll per present player, not one shared roll — matches how a party actually
##      experiences a world chest today (whoever gets there loots it; nobody is shut out because a
##      teammate opened first).
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, new "Event-granted loot" row): HOST. No RPC of its
## own — every grant flows through `InventoryService.host_add()`/`PowerupService.host_grant()`,
## both of which already reach a remote peer through their own existing snapshot RPC (`_commit()`).
## Those two calls already no-op on a non-host caller (`_valid_host_peer()`/`_owns_mutation()`), but
## this file gates first anyway so a client never rolls a roll nobody will see granted, the same
## discipline `Wellspring`/`Chest` themselves already carry in this file's `_owns_mutation()` copy.

const EVENT_BUS := preload("res://core/events/event_bus.gd")

const LOG_CHANNEL: StringName = &"reward"
const WELLSPRING_TIER: StringName = &"wellspring"
const BOSS_TIER: StringName = &"boss"
## Coins are an item (ItemDef stack_size 999, content/items/coins.tres), not a parallel currency —
## same constant `Chest.COIN_ITEM_ID` carries, granted through the identical `InventoryService.
## host_add()` seam.
const COIN_ITEM_ID: StringName = &"coins"

## F-219: same boot-time-`randomize()` bug D-041/F-210 fixed for `Chest` — two runs sharing a
## `GameState.run_seed` must grant the same party rewards. `Chest` had an obvious stable id (its own
## node `name`, authored by `ChestPlacementService`); a Wellspring cap / boss kill has none, so this
## file mints one: a monotonic per-run counter, incremented once per trigger (not per peer — two caps
## in the same run must not roll the same), combined with the receiving peer's id so independent
## peers' rolls from the same trigger never coincide. Reset on `GameState.seed_ready`, the same "a run
## has begun" hook `autoload/salvage_service.gd` already uses to zero its own per-run tally — without
## the reset, a deliberate same-seed replay (F-172's seed entry) started from a fresh boot would still
## diverge if this process had granted a different NUMBER of rewards before that replay began.
##
## F-273 on the trigger frequency, which this comment used to get wrong: `seed_ready` is a RUN
## boundary, not a session one — it fires at session start, at every restart (F-258/D-161) and on a
## client adopting the host's seed, and it can fire MORE THAN ONCE for a single boundary (a restart
## emits twice on the host). That is safe here only because the handler assigns 1 rather than
## advancing anything; see the signal's declaration in `core/game_state.gd` for the full contract.
## `_grant_tier_to_party()` is `_owns_mutation()`-gated, so a client's copy of this counter is never
## read and a client-side reset cannot desync the party's rolls.
var _next_reward_event_id: int = 1


func _ready() -> void:
	EVENT_BUS.subscribe_wellspring_capped(_on_wellspring_capped)
	EVENT_BUS.subscribe_boss_defeated(_on_boss_defeated)
	var game_state: Node = get_node_or_null(^"/root/GameState")
	if game_state != null:
		game_state.connect(&"seed_ready", _on_seed_ready)


func _exit_tree() -> void:
	EVENT_BUS.unsubscribe_wellspring_capped(_on_wellspring_capped)
	EVENT_BUS.unsubscribe_boss_defeated(_on_boss_defeated)


func _on_seed_ready(_value: int) -> void:
	_next_reward_event_id = 1


func _on_wellspring_capped(_wellspring_name: StringName, _world_position: Vector3) -> void:
	_grant_tier_to_party(WELLSPRING_TIER)


func _on_boss_defeated(_boss_id: StringName, _world_position: Vector3) -> void:
	_grant_tier_to_party(BOSS_TIER)


## Host-only. One independent `LootTableDef.roll()` per currently present player, granted straight
## into that player's own inventory/powerup stacks — see the class doc for why this is a direct
## grant rather than a spawned `Chest`, and why each player gets their own roll rather than one
## shared one.
func _grant_tier_to_party(tier: StringName) -> void:
	if not _owns_mutation():
		return
	var peers: PackedInt32Array = _present_peers()
	if peers.is_empty():
		return
	var loot_table: Resource = _resolve_loot_table(tier)
	if loot_table == null:
		push_warning("RewardService: tier '%s' has no loot table to roll" % tier)
		return
	var event_id: int = _next_reward_event_id
	_next_reward_event_id += 1
	var run_seed: int = _run_seed()
	var unlock_check: Callable = _unlock_check()
	for peer_id: int in peers:
		var rng := RandomNumberGenerator.new()
		rng.seed = _seed_for_run(run_seed, "%s:%d:%d" % [tier, event_id, peer_id])
		var roll: Dictionary = loot_table.call("roll", rng, 0.0, unlock_check)
		_grant_roll(peer_id, tier, roll)


## Same three buckets `Chest._accept_open_request()` grants from — coins and items through
## `InventoryService.host_add()`, powerups through `PowerupService.host_grant()` (they hold no
## inventory slot of their own).
func _grant_roll(peer_id: int, tier: StringName, roll: Dictionary) -> void:
	var inventory: Node = get_node_or_null(^"/root/InventoryService")
	var powerup_service: Node = get_node_or_null(^"/root/PowerupService")
	var granted: Dictionary = {}

	var coin_amount: int = int(roll.get("coins", 0))
	if coin_amount > 0 and inventory != null and bool(inventory.call("host_add", peer_id, COIN_ITEM_ID, coin_amount)):
		granted[COIN_ITEM_ID] = coin_amount

	var items: Dictionary = roll.get("items", {})
	for item_id: StringName in items:
		var amount: int = int(items[item_id])
		if amount > 0 and inventory != null and bool(inventory.call("host_add", peer_id, item_id, amount)):
			granted[item_id] = int(granted.get(item_id, 0)) + amount

	var powerups: Dictionary = roll.get("powerups", {})
	for powerup_id: StringName in powerups:
		var count: int = int(powerups[powerup_id])
		if count <= 0 or powerup_service == null:
			continue
		var given: int = int(powerup_service.call("host_grant", peer_id, powerup_id, count))
		if given > 0:
			granted[powerup_id] = int(granted.get(powerup_id, 0)) + given

	MireLog.info(LOG_CHANNEL, "tier '%s' paycheck -> peer %d: %s" % [tier, peer_id, granted])


func _resolve_loot_table(tier: StringName) -> Resource:
	var registry: Node = get_node_or_null(^"/root/Registry")
	if registry == null or not registry.has_method("get_loot_table"):
		return null
	return registry.call("get_loot_table", tier) as Resource


## D-111/F-173's chosen design, reused verbatim from `Chest._unlock_check()`: the HOST's own unlock
## tree gates POWERUP entries for whoever the host is granting to, no RPC needed. This only ever
## runs inside `_grant_tier_to_party()`, which `_owns_mutation()` already restricts to the host
## process, so `/root/UnlockService` resolved here is always the host's own save.
func _unlock_check() -> Callable:
	var unlock_service: Node = get_node_or_null(^"/root/UnlockService")
	if unlock_service == null or not unlock_service.has_method("is_content_unlocked"):
		return Callable()
	return Callable(unlock_service, "is_content_unlocked")


## The distinct multiplayer authorities among the `&"players"` group — same "who is actually here
## right now" signal `DefeatService._present_peers()`/`Wellspring._session_player_total()` already
## use instead of `NetTransport.peer_ids()`, so a peer mid-D-035-grace-window with no live body
## never receives a paycheck it cannot be told it won. Works offline too: even solo, the local
## player is its own multiplayer authority in this group.
func _present_peers() -> PackedInt32Array:
	var peers: PackedInt32Array = PackedInt32Array()
	for node: Node in get_tree().get_nodes_in_group(&"players"):
		var player := node as Node3D
		if player == null:
			continue
		var peer_id: int = player.get_multiplayer_authority()
		if peer_id > 0 and not peers.has(peer_id):
			peers.append(peer_id)
	return peers


## Host-only caller (F-219, same contract as `Chest._run_seed()`). GameState is a project-wide
## autoload, present in every scene including a headless SceneTree check, so this never needs the
## null guard the transport lookups below carry. `ensure_seed()` lazily draws one from real entropy
## if nothing has drawn it yet (offline/host-of-one boot order) and is a no-op once a seed exists.
func _run_seed() -> int:
	var game_state: Node = get_node_or_null(^"/root/GameState")
	if game_state == null:
		return 0
	return int(game_state.call("ensure_seed"))


## Salt distinguishes this file's seed derivation from every other file mixing the same run_seed
## (`systems/loot/chest.gd`'s `0xC4E57`, `world/gen/poi_map.gd`'s `0x9017A11`, `world/gen/
## resource_scatter.gd`'s `0x5CA77E5`) — same "own salt per file" convention those establish. Integer
## multiply/xor only, never Godot's `hash()`, for the identical cross-platform-stability reason
## `chest.gd` documents on its own copy of this constant.
const _SEED_SALT: int = 0x9E3779B9


## Copy of `Chest._seed_for_run()` — see that file's header for why this is duplicated per file
## rather than shared. [param event_key] is "<tier>:<event_id>:<peer_id>", the "chest id" half F-210's
## fix needed a stable node name for; here it is a monotonic per-run trigger counter plus the
## receiving peer's id instead, since a Wellspring cap / boss kill has no placement to derive one from.
func _seed_for_run(run_seed: int, event_key: String) -> int:
	const PRIME: int = 1000003
	var id_hash: int = 0x1000193
	for byte: int in event_key.to_utf8_buffer():
		id_hash = (id_hash ^ byte) * 16777619
	var h: int = run_seed ^ _SEED_SALT
	h = h * PRIME + id_hash
	return h


func _owns_mutation() -> bool:
	return not _transport_is_active() or _transport_is_host()


func _transport() -> Node:
	return get_node_or_null(^"/root/NetTransport")


func _transport_is_active() -> bool:
	var transport: Node = _transport()
	return transport != null and bool(transport.call("is_active"))


func _transport_is_host() -> bool:
	var transport: Node = _transport()
	return transport != null and bool(transport.call("is_host"))
