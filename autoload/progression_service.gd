extends Node

## ProgressionService — autoload. Owns the one fact the tool ladder needs and nothing else had:
## **how far up the ladder this party has climbed, this run** (`docs/PROGRESSION.md` §4).
##
## Five rungs — 1 wood, 2 stone, 3 iron, 4 bogsilver, 5 wellglass — authored on `ItemDef.tool_tier`.
## The mark is a high-water mark: it only ever rises inside a run, and `host_reset_run()` puts it
## back to 0 when a new run starts. It is a PARTY fact, not a per-player one. One player forging the
## first iron pickaxe means the party reached the iron age: the fanfare plays for everyone, the
## objective line advances for everyone, and `SalvageService` scores the rung once.
##
## Network authority: **HOST-owned** (`ARCHITECTURE.md` §2.2, world-mutation row). The host raises
## the mark when a craft transaction commits, records it into `WorldDeltaLog` under its own
## `(chunk, kind, key)` address, and every peer — host included — emits `EventBus.tier_reached` from
## its own process. No new RPC: this is D-099/D-100's reuse of the delta log for a small replicated
## scalar, exactly as `CycleService` does for the Cycle number, and for the same reason. A party fact
## emitted behind a host-only guard is the bug shape F-250 and F-254 each cost a task to find.
##
## A late joiner needs no bespoke path either: the delta log folds the record into the snapshot it
## already sends, so a peer joining at Cycle 4 reads the party's real tier immediately.

const EVENT_BUS := preload("res://core/events/event_bus.gd")

## Rungs, for readers that would otherwise write bare integers. `NONE` is "not a rung" — the value
## every resource, food and buildable carries.
const TIER_NONE: int = 0
const TIER_WOOD: int = 1
const TIER_STONE: int = 2
const TIER_IRON: int = 3
const TIER_BOGSILVER: int = 4
const TIER_WELLGLASS: int = 5
const TIER_MAX: int = TIER_WELLGLASS

## Display names for the fanfare and for any readout. Index is the tier.
const TIER_NAMES: Array[String] = ["", "Wood", "Stone", "Iron", "Bogsilver", "Wellglass"]

## `WorldDeltaLog` addressing. Same pseudo-chunk convention `CycleService` and `MireGrid` use — the
## ladder has no position — with a `kind` of its own, so it can never collide with theirs.
const GLOBAL_CHUNK: Vector2i = Vector2i.ZERO
const KIND: StringName = &"progression"
const KEY: String = "tier"

const LOG_CHANNEL: StringName = &"world"

var _tier: int = TIER_NONE
## What raised the mark, per rung, so a consumer can name the item and not just the number. Purely
## local colour: it is rebuilt on the host and left empty on a client, and nothing gates on it.
var _tier_source: Dictionary = {}
var _transport_node: Node


func _ready() -> void:
	var world_delta_log: Node = get_node_or_null(^"/root/WorldDeltaLog")
	if world_delta_log != null and world_delta_log.has_signal(&"delta_applied"):
		world_delta_log.connect(&"delta_applied", _on_world_delta_applied)
	EVENT_BUS.subscribe_run_restarted(_on_run_restarted)


## The party's high-water rung this run, 0..5. Safe to call from any peer at any time.
func tier_reached() -> int:
	return _tier


func is_tier_reached(tier: int) -> bool:
	return _tier >= tier


## The rung an item sits on, or 0 if it is not a rung. Reads the registry, so an id that does not
## resolve is 0 rather than an error — an unknown item cannot advance a ladder.
func tier_of_item(item_id: StringName) -> int:
	if item_id == &"":
		return TIER_NONE
	var registry: Node = get_node_or_null(^"/root/Registry")
	if registry == null or not bool(registry.call("has_item", item_id)):
		return TIER_NONE
	var item: Resource = registry.call("get_item", item_id) as Resource
	if item == null:
		return TIER_NONE
	return clampi(int(item.get(&"tool_tier")), TIER_NONE, TIER_MAX)


func tier_name(tier: int) -> String:
	if tier <= TIER_NONE or tier >= TIER_NAMES.size():
		return ""
	return TIER_NAMES[tier]


## What did it. Empty when this peer did not witness the raise locally (a client that joined after
## the fact, say) — never gate on this, it is a label.
func tier_source(tier: int) -> StringName:
	return StringName(_tier_source.get(tier, &""))


## HOST-ONLY. Called by `CraftingService` the instant a craft transaction commits, with the
## additions dictionary it just granted. Every other caller is a check.
##
## Takes the whole dictionary rather than one id because a recipe may in principle output more than
## one kind of item, and the rung it opens is the highest of them.
func host_note_crafted(additions: Dictionary) -> void:
	if not _owns_progression():
		return
	var best_tier: int = TIER_NONE
	var best_item: StringName = &""
	for item_id: StringName in additions:
		var tier: int = tier_of_item(item_id)
		if tier > best_tier:
			best_tier = tier
			best_item = item_id
	if best_tier > TIER_NONE:
		host_raise_tier(best_tier, best_item)


## HOST-ONLY. Raise the mark to `tier` if it is higher than the current one, recording and
## announcing exactly once. Idempotent: a second call at or below the mark does nothing, which is
## what makes "once per rung per run" true without the caller tracking anything.
func host_raise_tier(tier: int, item_id: StringName = &"") -> void:
	if not _owns_progression():
		return
	var clamped: int = clampi(tier, TIER_NONE, TIER_MAX)
	if clamped <= _tier:
		return
	_tier = clamped
	_tier_source[clamped] = item_id
	var world_delta_log: Node = get_node_or_null(^"/root/WorldDeltaLog")
	if world_delta_log != null:
		world_delta_log.call("host_record", GLOBAL_CHUNK, KIND, KEY, _tier)
	EVENT_BUS.emit_tier_reached(_tier, item_id)
	MireLog.info(
		LOG_CHANNEL,
		"tier %d (%s) reached via %s" % [_tier, tier_name(_tier), String(item_id)]
	)


## HOST-ONLY. A new run starts at the bottom of the ladder — nothing about the tool tree carries
## between runs (`DESIGN.md` §4.6: the meta tree buys variety, never power). Recorded like a raise
## so a client's mark falls with the host's rather than keeping the last run's number.
func host_reset_run() -> void:
	if not _owns_progression():
		return
	_tier = TIER_NONE
	_tier_source.clear()
	var world_delta_log: Node = get_node_or_null(^"/root/WorldDeltaLog")
	if world_delta_log != null:
		world_delta_log.call("host_record", GLOBAL_CHUNK, KIND, KEY, _tier)


## A client's own re-derivation of the host's raise, off the record the host wrote. Guarded on
## `_owns_progression()` so the host — whose `host_record()` also runs through `WorldDeltaLog._apply()`
## and fires this same signal — never double-emits; it emitted directly in `host_raise_tier()`.
##
## Only ever emits on a RISE. The log re-emits `delta_applied` even when the stored value is
## unchanged, and a run reset writes a LOWER value; neither is a rung being reached.
func _on_world_delta_applied(chunk: Vector2i, kind: StringName, key: String, value: Variant) -> void:
	if _owns_progression() or chunk != GLOBAL_CHUNK or kind != KIND or key != KEY:
		return
	var received: int = clampi(int(value), TIER_NONE, TIER_MAX)
	if received == _tier:
		return
	var rose: bool = received > _tier
	_tier = received
	if rose:
		EVENT_BUS.emit_tier_reached(_tier, tier_source(_tier))


func _on_run_restarted() -> void:
	host_reset_run()


## Same host/solo gate `CycleService._owns_cycle()` uses, and for the same reason: a single-player
## run with no transport at all still owns its own world.
func _owns_progression() -> bool:
	var transport: Node = _transport()
	if transport == null:
		return true
	if bool(transport.call("is_host")):
		return true
	return not bool(transport.call("is_active")) and not bool(transport.call("is_connecting"))


func _transport() -> Node:
	if is_instance_valid(_transport_node):
		return _transport_node
	_transport_node = get_node_or_null(^"/root/NetTransport")
	return _transport_node
