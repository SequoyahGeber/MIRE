class_name EventBus
extends RefCounted

## Cross-system event seam. This is intentionally a static dispatcher rather than an autoload:
## callers can use it from code-built gameplay nodes without adding another singleton or touching a
## scene. Subscribers must unsubscribe when they leave the tree; invalid callables are also pruned
## before every dispatch.
##
## Network authority: none. The bus never sends an RPC or changes gameplay state. Producers are
## responsible for emitting only from the authority that owns their event. Harvestable emits its
## yield event on the host, and the host-owned inventory layer introduced by task 2.4 consumes it.

static var _harvest_yielded_subscribers: Array[Callable] = []
static var _enemy_attack_landed_subscribers: Array[Callable] = []
static var _wellspring_capped_subscribers: Array[Callable] = []


## Listener signature:
##     (harvestable_id: StringName, peer_id: int, item_id: StringName,
##      amount: int, world_position: Vector3) -> void
static func subscribe_harvest_yielded(listener: Callable) -> void:
	_prune_invalid(_harvest_yielded_subscribers)
	if listener.is_valid() and not _harvest_yielded_subscribers.has(listener):
		_harvest_yielded_subscribers.append(listener)


static func unsubscribe_harvest_yielded(listener: Callable) -> void:
	_harvest_yielded_subscribers.erase(listener)


static func emit_harvest_yielded(
	harvestable_id: StringName,
	peer_id: int,
	item_id: StringName,
	amount: int,
	world_position: Vector3
) -> void:
	_prune_invalid(_harvest_yielded_subscribers)
	# A listener may unsubscribe while handling the event. Iterate a snapshot so that does not skip
	# whichever listener happened to follow it in the live array.
	for listener: Callable in _harvest_yielded_subscribers.duplicate():
		listener.call(harvestable_id, peer_id, item_id, amount, world_position)


static func harvest_yielded_subscriber_count() -> int:
	_prune_invalid(_harvest_yielded_subscribers)
	return _harvest_yielded_subscribers.size()


## Listener signature:
##     (enemy_id: StringName, peer_id: int, damage: int, world_position: Vector3) -> void
##
## Emitted by the HOST only, at the moment an enemy's telegraphed swing resolves (task 2.10). It
## exists because player health does not: task 2.13 (downed → bleed-out → revive) owns what an
## enemy hit costs, and inventing a health field inside the enemy to avoid an event would have put
## player state under the wrong system.
static func subscribe_enemy_attack_landed(listener: Callable) -> void:
	_prune_invalid(_enemy_attack_landed_subscribers)
	if listener.is_valid() and not _enemy_attack_landed_subscribers.has(listener):
		_enemy_attack_landed_subscribers.append(listener)


static func unsubscribe_enemy_attack_landed(listener: Callable) -> void:
	_enemy_attack_landed_subscribers.erase(listener)


static func emit_enemy_attack_landed(
	enemy_id: StringName, peer_id: int, damage: int, world_position: Vector3
) -> void:
	_prune_invalid(_enemy_attack_landed_subscribers)
	for listener: Callable in _enemy_attack_landed_subscribers.duplicate():
		listener.call(enemy_id, peer_id, damage, world_position)


static func enemy_attack_landed_subscriber_count() -> int:
	_prune_invalid(_enemy_attack_landed_subscribers)
	return _enemy_attack_landed_subscribers.size()


## Listener signature: (wellspring_name: StringName, world_position: Vector3) -> void
##
## Emitted by the HOST only, the instant a Wellspring's ritual timer completes (task 4.8). No
## reward, chest, Mire hook or Attunement grant lives here — D-092 defers those to whichever future
## task actually has something to hook them to (4.9-4.11's Mire, a reward system not yet built);
## this event is that seam.
static func subscribe_wellspring_capped(listener: Callable) -> void:
	_prune_invalid(_wellspring_capped_subscribers)
	if listener.is_valid() and not _wellspring_capped_subscribers.has(listener):
		_wellspring_capped_subscribers.append(listener)


static func unsubscribe_wellspring_capped(listener: Callable) -> void:
	_wellspring_capped_subscribers.erase(listener)


static func emit_wellspring_capped(wellspring_name: StringName, world_position: Vector3) -> void:
	_prune_invalid(_wellspring_capped_subscribers)
	for listener: Callable in _wellspring_capped_subscribers.duplicate():
		listener.call(wellspring_name, world_position)


static func wellspring_capped_subscriber_count() -> int:
	_prune_invalid(_wellspring_capped_subscribers)
	return _wellspring_capped_subscribers.size()


static func _prune_invalid(subscribers: Array[Callable]) -> void:
	for index: int in range(subscribers.size() - 1, -1, -1):
		if not subscribers[index].is_valid():
			subscribers.remove_at(index)
