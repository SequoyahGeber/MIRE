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


static func _prune_invalid(subscribers: Array[Callable]) -> void:
	for index: int in range(subscribers.size() - 1, -1, -1):
		if not subscribers[index].is_valid():
			subscribers.remove_at(index)
