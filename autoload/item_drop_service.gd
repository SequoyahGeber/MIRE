extends Node

## ItemDropService — autoload. Spawns and tracks the items lying on the ground (F-535).
##
## Every yield now takes a physical form before it reaches a pack: `InventoryService` no longer
## credits `harvest_yielded` straight into a store, it asks this service for a drop, and the drop
## grants itself when a player walks into it or presses [E] (`systems/loot/item_drop.gd`).
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, "World item drops" row): HOST. This autoload only
## spawns/tracks; the per-drop request/host-validate/grant story lives entirely in
## `systems/loot/item_drop.gd`, the same split `autoload/haul_service.gd` and
## `autoload/build_service.gd` use for their own spawned entities.
##
## Drops replicate through a code-built MultiplayerSpawner (D-023), mirroring HaulService — same
## reason: a headless spike cannot author .tscn files, and building the node tree in code is the only
## way to guarantee every peer arrives at a byte-identical tree, because the high-level API matches
## nodes by PATH and a mismatch fails as silence rather than an error.

const ITEM_DROP_SCRIPT := preload("res://systems/loot/item_drop.gd")
const EVENT_BUS := preload("res://core/events/event_bus.gd")

const LOG_CHANNEL: StringName = &"inventory"
const CONTAINER_NODE: StringName = &"ItemDrops"
const SPAWNER_NODE: StringName = &"ItemDropSpawner"

## A second yield of the same item this close folds into the existing pile instead of spawning its
## own body — a bush hit twice leaves one heap of berries, not two overlapping ones. Wider than the
## pop-out spread below, so a burst from one prop always lands as a single drop.
const MERGE_RADIUS_M: float = 1.2
## The pop. Small and mostly upward: the item should hop clear of the stump it came from and settle
## within arm's reach, not scatter across the clearing.
const POP_UP_SPEED: float = 2.4
const POP_SIDE_SPEED: float = 1.1
## Where the item appears relative to the harvested prop's origin. Chest-high rather than at the
## feet, so the arc reads as "it fell out" rather than "it grew".
const SPAWN_HEIGHT_M: float = 0.9
## Bounded so a pathological run cannot fill the world with rigid bodies.
##
## F-590: eviction is oldest-first among TRANSIENT drops only, and never touches a persistent one.
## The original rule was "oldest first, because the drop a player is standing over is the newest
## one" — sound for harvest yields and exactly wrong for authored loot. Placed loot is spawned at
## world build, so it is the oldest thing in the container by a wide margin, and a player harvesting
## steadily was deleting the island's loot behind them, oldest first, with one `MireLog.warn` as the
## only trace. `host_spawn_placed_drop()` promises the opposite in its own docstring — "it never
## expires before a player discovers it" — a promise honoured against `LIFETIME_SEC` and then broken
## here.
const MAX_LIVE_DROPS: int = 256
## The persistent half of that budget, and the answer to the question exempting them raises: if
## authored loot cannot be evicted, what stops it starving the budget entirely?
##
## It is capped at spawn time instead. `MAX_LIVE_DROPS - MAX_PERSISTENT_DROPS` slots are therefore
## always reachable by transient drops no matter what the world places, which is what makes the
## exemption safe rather than a deadlock waiting for a big enough island.
##
## 128 is chosen against the MEASURED population, not the documented one: `LooseLootService` places
## 71-86 live drops on the procedural island (F-536 measured that across three seeds, after the
## comment there claimed 20-30 for a long time). 128 clears the real ceiling by half again, so
## content can grow substantially before anyone has to think about this number, and still leaves 128
## transient slots — comfortably more than a harvesting player generates between pickups.
const MAX_PERSISTENT_DROPS: int = 128

var _container: Node3D
var _spawner: MultiplayerSpawner
var _next_index: int = 1
## Never `randf()` — the host's own generator, seeded once, exactly as `systems/loot/chest.gd` rolls.
var _rng := RandomNumberGenerator.new()
## Cached transport ref (F-099 pattern). Path-resolved (F-011 — harnesses install theirs at /root).
var _transport_node: Node


func _ready() -> void:
	_rng.randomize()
	_build_spawner()
	EVENT_BUS.subscribe_run_restarted(_on_run_restarted)


func _exit_tree() -> void:
	EVENT_BUS.unsubscribe_run_restarted(_on_run_restarted)


## Run-scoped world state, same as a placed buildable or a haulable: the next run draws a FRESH SEED
## (F-258/D-161), so a log left lying on last run's shoreline sits on terrain that no longer exists.
func _on_run_restarted() -> void:
	host_clear_all()


func host_clear_all() -> void:
	if not _owns_mutation() or _container == null:
		return
	var cleared: int = _container.get_child_count()
	if cleared == 0:
		return
	for child: Node in _container.get_children():
		# Detached before freeing, not merely queued: `queue_free()` alone leaves the child in the
		# container until the frame ends, so `live_count()` would keep reporting drops that are
		# already gone — which is exactly the kind of stale count a caller clearing the ground is
		# about to make a decision on.
		_container.remove_child(child)
		child.queue_free()
	MireLog.info(LOG_CHANNEL, "run restarted — cleared %d ground drop(s)" % cleared)


# ── Spawning (D-023: built in code so every peer's tree is identical) ─────────────────────────────


func _build_spawner() -> void:
	_container = Node3D.new()
	_container.name = CONTAINER_NODE
	add_child(_container)

	_spawner = MultiplayerSpawner.new()
	_spawner.name = SPAWNER_NODE
	_spawner.spawn_limit = 0
	_spawner.spawn_function = _net_spawn_drop
	add_child(_spawner)
	_spawner.spawn_path = _spawner.get_path_to(_container)


## Host-only. The one entry point: everything that wants to give a player something through the
## world — a harvest yield today, a corpse or a dropped hotbar slot later — calls this rather than
## `InventoryService.host_add()` directly.
##
## Returns the drop the amount ended up in, which may be an EXISTING pile: a merge is not a lesser
## outcome, it is the intended one when two yields land together.
func host_spawn_drop(item_id: StringName, amount: int, world_position: Vector3) -> Node3D:
	if not _owns_mutation() or amount <= 0:
		return null
	if not _item_exists(item_id):
		MireLog.error(LOG_CHANNEL, "ItemDropService: unknown item id '%s'" % item_id)
		return null

	var origin: Vector3 = world_position + Vector3.UP * SPAWN_HEIGHT_M
	var mate: Node3D = _merge_target(item_id, origin)
	if mate != null and bool(mate.call(&"host_merge", amount)):
		return mate

	if not _enforce_budget():
		return null
	var angle: float = _rng.randf_range(0.0, TAU)
	return _spawner.spawn({
		"item": String(item_id),
		"amount": amount,
		"index": _take_index(),
		"origin": origin,
		"velocity": Vector3(
			cos(angle) * POP_SIDE_SPEED, POP_UP_SPEED, sin(angle) * POP_SIDE_SPEED
		),
	}) as Node3D


## Host-only placement seam for authored or seed-derived loot that already has a world position.
## Unlike a harvest yield it does not pop sideways and it never expires before a player discovers
## it. Run restart still clears it, and collection still goes through ItemDrop's normal range,
## inventory-capacity and replication checks.
func host_spawn_placed_drop(item_id: StringName, amount: int, world_position: Vector3) -> Node3D:
	if not _owns_mutation() or amount <= 0 or not _item_exists(item_id):
		return null
	# F-590: placed loot is bounded at PLACEMENT rather than by eviction. Refusing the 129th cache
	# is visible and recoverable — the world simply has one fewer pile, and the warning says so —
	# whereas evicting to make room silently deletes loot a player may already have seen from
	# across a clearing. It also never calls `_enforce_budget()`: authored loot must not be able to
	# despawn a yield the player is walking towards either, and its own cap already guarantees the
	# transient half of the budget stays reachable.
	if persistent_count() >= MAX_PERSISTENT_DROPS:
		MireLog.warn(LOG_CHANNEL,
			"placed loot is at its %d cap — refusing to place another rather than evicting one already in the world"
				% MAX_PERSISTENT_DROPS)
		return null
	return _spawner.spawn({
		"item": String(item_id),
		"amount": amount,
		"index": _take_index(),
		"origin": world_position + Vector3.UP * SPAWN_HEIGHT_M,
		"velocity": Vector3.ZERO,
		"persistent": true,
	}) as Node3D


## Runs on every peer with the same data, so host and client build identical bodies. Mirrors
## HaulService._net_spawn_haulable()'s shape, including the has_method guard that lets a future
## authored scene root bring its own richer script without this ever clobbering it.
func _net_spawn_drop(data: Variant) -> Node:
	var payload: Dictionary = data as Dictionary
	if payload == null:
		return null
	var item_id: StringName = StringName(String(payload.get("item", "")))
	if item_id == &"":
		return null

	var body := RigidBody3D.new()
	body.set_script(ITEM_DROP_SCRIPT)
	body.name = "ItemDrop%d" % int(payload.get("index", 0))
	body.position = payload.get("origin", Vector3.ZERO)
	body.set(&"item_id", item_id)
	body.set(&"amount", int(payload.get("amount", 0)))
	body.set(&"persistent", bool(payload.get("persistent", false)))
	# The pop is part of the spawn payload rather than an impulse applied afterwards, so a client
	# that joins mid-flight reconstructs the same arc the host is already simulating.
	body.linear_velocity = payload.get("velocity", Vector3.ZERO)
	return body


## The nearest live drop of the same item within MERGE_RADIUS_M, or null.
func _merge_target(item_id: StringName, origin: Vector3) -> Node3D:
	if _container == null:
		return null
	var best: Node3D = null
	var best_distance: float = MERGE_RADIUS_M * MERGE_RADIUS_M
	for child: Node in _container.get_children():
		var drop := child as Node3D
		if drop == null or StringName(drop.get(&"item_id")) != item_id:
			continue
		if not drop.has_method(&"host_merge") or not bool(drop.call(&"is_mergeable")):
			continue
		var distance: float = drop.global_position.distance_squared_to(origin)
		if distance > best_distance:
			continue
		best_distance = distance
		best = drop
	return best


## Frees the oldest drops rather than refusing the new one: the item a player just knocked loose is
## the one they are about to walk to, and silently dropping THAT is the failure this budget exists to
## avoid. Container children are in spawn order, so the front of the list is the oldest.
## Makes room for one more TRANSIENT drop, by despawning the oldest transient drops and nothing
## else. Returns false when it could not — the caller must then decline to spawn rather than reach
## for a persistent drop (F-590).
##
## Declining is safe, and that is not an accident of this file: `InventoryService._on_harvest_yielded()`
## treats a null from `host_spawn_drop()` as "no drop service" and credits the pack directly instead.
## So the worst case of a full budget is a yield that skips the ground and goes straight to the
## player — which is the pre-F-535 behaviour, not a lost item. Evicting authored loot to make room
## would have destroyed something to avoid that.
func _enforce_budget() -> bool:
	if _container == null:
		return true
	var over: int = _container.get_child_count() - (MAX_LIVE_DROPS - 1)
	if over <= 0:
		return true
	var freed: int = 0
	for child: Node in _container.get_children():
		if freed >= over:
			break
		# The whole fix: a persistent drop is skipped, not taken. Children are in spawn order, so
		# walking forward still takes the OLDEST transient drop first — the original policy, now
		# applied to the only population it was ever correct for.
		if bool(child.get(&"persistent")):
			continue
		_container.remove_child(child)
		child.queue_free()
		freed += 1
	if freed > 0:
		MireLog.warn(LOG_CHANNEL, "ground drops hit the %d cap — despawned %d oldest transient drop(s)" % [
			MAX_LIVE_DROPS, freed
		])
	if freed < over:
		MireLog.warn(LOG_CHANNEL,
			"ground drops are at the %d cap with nothing transient left to despawn — declining the new drop rather than deleting authored loot (%d persistent live)"
				% [MAX_LIVE_DROPS, persistent_count()])
		return false
	return true


## How many of the live drops are authored world loot rather than harvest yields.
func persistent_count() -> int:
	if _container == null:
		return 0
	var total: int = 0
	for child: Node in _container.get_children():
		if bool(child.get(&"persistent")):
			total += 1
	return total


func live_count() -> int:
	return 0 if _container == null else _container.get_child_count()


func live_drops() -> Array[Node]:
	return [] if _container == null else _container.get_children()


# ── Helpers ──────────────────────────────────────────────────────────────────────────────────────


func _item_exists(item_id: StringName) -> bool:
	var registry: Node = get_node_or_null(^"/root/Registry")
	if registry == null or not registry.has_method(&"has_item"):
		# No registry at all (a bare --script harness): trust the caller rather than swallow the
		# drop, same guard shape HaulService's definition lookup makes.
		return true
	return bool(registry.call(&"has_item", item_id))


func _take_index() -> int:
	var result: int = _next_index
	_next_index += 1
	return result


func _owns_mutation() -> bool:
	var transport: Node = _transport()
	if transport == null:
		return true
	if bool(transport.call("is_host")):
		return true
	return not bool(transport.call("is_active")) and not bool(transport.call("is_connecting"))


func _transport() -> Node:
	if _transport_node == null or not is_instance_valid(_transport_node):
		_transport_node = get_node_or_null(^"/root/NetTransport")
	return _transport_node
