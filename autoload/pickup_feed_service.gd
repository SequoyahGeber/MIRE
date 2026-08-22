extends Node

## PickupFeedService — autoload. The single "you just received something" channel: whatever grants a
## player an item, a coin pile or a powerup tells this service, and this service tells THAT player's
## own machine. Everything the player then sees or hears about a pickup — the bottom-left message
## feed, the held-powerup row, the screen flash on a powerup, the pickup cue — hangs off one signal
## here (`ui/hud/pickup_hud.gd`).
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, "VFX, audio, camera, UI" row for the presentation,
## world-mutation row for the grant): the GRANT is host-authoritative and already happened before
## anyone calls this. This service carries **notification only** — it never grants, never validates
## and never changes gameplay state. A malicious host can make your screen say you got a mushroom;
## it cannot put one in your pack through this path, because the pack is `InventoryService`'s.
##
## Why a service and not "each system tells its own UI": the grant happens on the HOST and the
## message has to appear on the RECEIVER, who is usually somebody else. `ItemDrop.collected` and
## `Chest.open_confirmed` both fire in the host process, so a client walking over a drop learnt
## nothing at all (F-581). One `rpc_id` to the one peer who earned it is the whole mechanism, and
## putting it here means the next grant seam (a quest reward, a kill drop) is one call, not another
## RPC surface.

const LOG_CHANNEL: StringName = &"inventory"

## What a feed entry is about. `ITEM` resolves against `Registry.get_item`, `POWERUP` against
## `Registry.get_powerup` — the two namespaces a grant can name, exactly as `Chest`'s `granted`
## dictionary already mixes them.
const KIND_ITEM: StringName = &"item"
const KIND_POWERUP: StringName = &"powerup"

## Where it came from, so presentation can differ without the producer having to know how.
const SOURCE_GROUND: StringName = &"ground"
const SOURCE_CHEST: StringName = &"chest"
const SOURCE_OTHER: StringName = &"other"

## Fires on the RECEIVING peer only, once per granted id. Client-local: connect UI, audio and VFX
## to it and nothing else.
signal pickup_received(kind: StringName, id: StringName, amount: int, source: StringName)

var _transport_node: Node


## Host-side entry point. `peer_id` is who earned it; the message is delivered locally when that is
## us, and by targeted RPC otherwise. Silently does nothing for an amount of zero — callers hand us
## the result of a grant that may legitimately have been capped or refused, and "you received 0
## Mushroom" is worse than saying nothing.
func host_notify(peer_id: int, kind: StringName, id: StringName, amount: int,
		source: StringName = SOURCE_OTHER) -> void:
	if peer_id <= 0 or amount <= 0 or id == &"":
		return
	if kind != KIND_ITEM and kind != KIND_POWERUP:
		push_warning("PickupFeedService: unknown pickup kind '%s' for '%s'" % [kind, id])
		return
	if peer_id == _local_peer_id():
		pickup_received.emit(kind, id, amount, source)
		return
	if _transport_is_active() and _peer_connected(peer_id):
		net_pickup.rpc_id(peer_id, kind, id, amount, source)


## Convenience for a whole `granted`-style dictionary: `{ id -> amount }`, where an id is an item id
## unless the registry knows it as a powerup. That "ask the registry which namespace this is" rule is
## the same one `ui/loot/chest_ui.gd` already applies when it labels a reward row, kept in one place.
func host_notify_granted(peer_id: int, granted: Dictionary,
		source: StringName = SOURCE_OTHER) -> void:
	var ids: Array[StringName] = []
	for id: StringName in granted:
		ids.append(id)
	# StringName's `<` compares interned identity, not string content — F-175.
	ids.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))
	for id: StringName in ids:
		host_notify(peer_id, kind_of(id), id, int(granted[id]), source)


## Which namespace an id belongs to. Items win ties: every powerup id is authored distinct from the
## item ids, and an unknown id is far more likely to be an item than a powerup.
func kind_of(id: StringName) -> StringName:
	var registry: Node = get_node_or_null(^"/root/Registry")
	if registry != null and registry.has_method(&"has_powerup") \
			and bool(registry.call(&"has_powerup", id)):
		return KIND_POWERUP
	return KIND_ITEM


## Display name for either namespace, falling back to a humanised id so a message is never a raw
## snake_case token in front of a player.
func display_name_of(kind: StringName, id: StringName) -> String:
	var registry: Node = get_node_or_null(^"/root/Registry")
	if registry != null:
		var definition: Resource = null
		if kind == KIND_POWERUP:
			definition = registry.call(&"get_powerup", id) as Resource
		else:
			definition = registry.call(&"get_item", id) as Resource
		if definition != null:
			var display: String = String(definition.get(&"display_name"))
			if not display.is_empty():
				return display
	return String(id).replace("_", " ").capitalize()


## Icon for either namespace, or null. Both `ItemDef` and `PowerupDef` author an `icon`.
func icon_of(kind: StringName, id: StringName) -> Texture2D:
	var registry: Node = get_node_or_null(^"/root/Registry")
	if registry == null:
		return null
	var definition: Resource = null
	if kind == KIND_POWERUP:
		definition = registry.call(&"get_powerup", id) as Resource
	else:
		definition = registry.call(&"get_item", id) as Resource
	if definition == null:
		return null
	return definition.get(&"icon") as Texture2D


@rpc("authority", "call_remote", "reliable")
func net_pickup(kind: StringName, id: StringName, amount: int, source: StringName) -> void:
	pickup_received.emit(kind, id, amount, source)


# ── Transport ────────────────────────────────────────────────────────────────────────────────────


func _transport() -> Node:
	if _transport_node == null or not is_instance_valid(_transport_node):
		_transport_node = get_node_or_null(^"/root/NetTransport")
	return _transport_node


func _transport_is_active() -> bool:
	var transport: Node = _transport()
	return transport != null and bool(transport.call("is_active"))


func _peer_connected(peer_id: int) -> bool:
	var transport: Node = _transport()
	return transport != null and (transport.call("peer_ids") as PackedInt32Array).has(peer_id)


func _local_peer_id() -> int:
	var transport: Node = _transport()
	if transport == null or not _transport_is_active():
		return NetConfig.HOST_PEER_ID
	return int(transport.call("local_peer_id"))
