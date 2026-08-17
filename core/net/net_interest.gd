class_name NetInterest
extends RefCounted

## Interest management — docs/ARCHITECTURE.md §2.5. One call configures a synchronizer's replication
## class: its interval, its on-change check rate, and (for host-authoritative entities) a per-peer
## visibility filter with hysteresis.
##
##     NetInterest.configure(sync, self, NetInterest.Class.ENEMY)
##
## Call it exactly where the synchronizer's authority is set — before add_child(), while the node is
## still out of the tree (F-012). It is the only place a synchronizer joins NetConfig.SYNCED_GROUP
## (D-024), so a construction site that skips it is visibly absent from the debug panel's count
## rather than silently mis-replicating.
##
## NETWORK AUTHORITY (§2.2): none of its own. Interest management does not decide state, it decides
## who is TOLD about state, and it runs on whichever peer already holds authority over the
## synchronizer — the host for enemies, props and world mutation. Nothing here is replicated: the
## sending peer alone evaluates visibility, and the receiving peer learns the answer as the presence
## or absence of the entity.
##
## WHY THIS IS NOT AN AUTOLOAD. The observer registry is static because the visibility filter runs
## once per entity per peer per physics tick — 1.9's spike shape is 200 entities × 5 clients = 1000
## calls a tick — so it must not walk the scene tree or resolve a singleton to answer. autoload/
## player_net.gd pushes observer positions in; nothing here processes.


## The §2.5 replication classes. Every host-authoritative entity is one of these; the numbers behind
## them are in NetConfig, not here.
enum Class {
	PLAYER = 0,  ## 30Hz, never culled. Six of them, and a player that pops in is the worst artifact.
	ENEMY = 1,   ## 15Hz, culled at NetConfig.INTEREST_ENTER_RADIUS_M.
	PROP = 2,    ## On-change only, culled. Harvestables, containers, anything mostly-still.
}

## Indexed by Class. Tables rather than a match statement, so adding a class is one row in each.
const CLASS_NAMES: PackedStringArray = ["PLAYER", "ENEMY", "PROP"]

const SYNC_INTERVALS: PackedFloat32Array = [
	NetConfig.PLAYER_SYNC_INTERVAL_SEC,
	NetConfig.ENEMY_SYNC_INTERVAL_SEC,
	NetConfig.PROP_SYNC_INTERVAL_SEC,
]

## How often on-change ("delta") properties are checked. Players and enemies have none today, so
## matching their sync interval costs nothing and means a class that grows one behaves sensibly.
const DELTA_INTERVALS: PackedFloat32Array = [
	NetConfig.PLAYER_SYNC_INTERVAL_SEC,
	NetConfig.ENEMY_SYNC_INTERVAL_SEC,
	NetConfig.PROP_DELTA_INTERVAL_SEC,
]

## Which classes get a distance filter. Players deliberately do not — six players is not a bandwidth
## problem worth solving, and a teammate who vanishes at 121 m is a bug report, not an optimization.
const FILTERED: Array[bool] = [false, true, true]

## Strong reference owned by the synchronizer. Callable does not retain a RefCounted target strongly
## in Godot 4.7.1 (F-027), so configure() stores the filter as metadata as well as registering it.
const RADIUS_FILTER_META: StringName = &"mire_radius_filter"

# ── Observer registry ─────────────────────────────────────────────────────────────────────────────
#
# Where each peer is looking from — its own player's position. Written by autoload/player_net.gd once
# per physics tick on the peer that evaluates filters (the host), read by every filter.

static var _observers: Dictionary[int, Vector3] = {}


## Record where [param peer_id] observes the world from. Called once per physics tick per player.
static func set_observer(peer_id: int, observer_position: Vector3) -> void:
	_observers[peer_id] = observer_position


## Forget a peer. Its entities go invisible to it immediately, which is correct: a peer with no
## player has no viewpoint, and one that has left has nothing to receive.
static func clear_observer(peer_id: int) -> void:
	_observers.erase(peer_id)


## Session over. Called from PlayerNet on disconnect — stale positions across a session boundary
## would make the first tick of the next one filter against wherever the last one ended.
static func clear_observers() -> void:
	_observers.clear()


static func has_observer(peer_id: int) -> bool:
	return _observers.has(peer_id)


## Vector3.ZERO for a peer with no observer — check [method has_observer] first if that matters. It
## matters to the filter, and the filter does.
static func observer_of(peer_id: int) -> Vector3:
	return _observers.get(peer_id, Vector3.ZERO)


static func observer_count() -> int:
	return _observers.size()


## For the net debug panel and the headless checks. Allocates; not for per-frame use.
static func debug_observers() -> Dictionary[int, Vector3]:
	return _observers.duplicate()


# ── Configuration ─────────────────────────────────────────────────────────────────────────────────


## Apply [param entity_class] to [param sync], whose replicated node is [param source].
##
## [param source] is what the filter measures distance from — the entity root, i.e. the node
## [code]sync.root_path[/code] points at, not the synchronizer. Returns the filter it installed, or
## null for an unfiltered class; the return value exists for tests and diagnostics, and a caller that
## ignores it loses nothing (the synchronizer holds the only reference that matters).
static func configure(
	sync: MultiplayerSynchronizer, source: Node3D, entity_class: Class
) -> RadiusFilter:
	sync.replication_interval = SYNC_INTERVALS[entity_class]
	sync.delta_interval = DELTA_INTERVALS[entity_class]

	# D-024: one synchronizer, one member. Joined here rather than at each construction site, so the
	# panel's count cannot drift from what actually sends.
	sync.add_to_group(NetConfig.SYNCED_GROUP)

	if not FILTERED[entity_class]:
		sync.visibility_update_mode = MultiplayerSynchronizer.VISIBILITY_PROCESS_NONE
		return null

	var filter := RadiusFilter.new(source)
	# The Callable alone does NOT retain its RefCounted target strongly in the pinned engine. Metadata
	# gives the filter the same lifetime as the synchronizer and makes discarding this return value safe.
	sync.set_meta(RADIUS_FILTER_META, filter)
	sync.add_visibility_filter(filter.evaluate)

	# PHYSICS, not IDLE. Visibility changes cost despawn/respawn packets, so how often it is
	# re-evaluated is a bandwidth decision, and §5a is explicit that nothing about how the game plays
	# may follow the monitor's refresh rate. On IDLE a 240Hz host would re-evaluate four times as
	# often as a 60Hz one and pay four times the churn for the same movement.
	sync.visibility_update_mode = MultiplayerSynchronizer.VISIBILITY_PROCESS_PHYSICS
	return filter


# ── The filter ────────────────────────────────────────────────────────────────────────────────────


## Per-peer visibility for one synchronizer, with hysteresis: an entity becomes visible inside
## NetConfig.INTEREST_ENTER_RADIUS_M and stops being visible outside the larger
## NetConfig.INTEREST_LEAVE_RADIUS_M, so an entity loitering on the boundary changes state once
## instead of every tick. Between the two radii the answer is whatever it was last time — which is
## why this is an object with state and not a static function.
class RadiusFilter extends RefCounted:

	## Whose position is measured. A raw Object reference, not a strong one — Node is not RefCounted —
	## so it is validity-checked on every call rather than trusted.
	var _source: Node3D

	var _enter_sq: float = NetConfig.INTEREST_ENTER_RADIUS_M * NetConfig.INTEREST_ENTER_RADIUS_M
	var _leave_sq: float = NetConfig.INTEREST_LEAVE_RADIUS_M * NetConfig.INTEREST_LEAVE_RADIUS_M

	## peer id -> currently visible. Absent means "not visible", so the entry only exists for peers
	## that have seen this entity at least once.
	var _visible: Dictionary[int, bool] = {}

	## How many times this entity has entered or left a peer's interest. Diagnostic only: it is the
	## churn number 1.9 could only infer from reliable-channel volume, and it is what to read if
	## bandwidth is high and you want to know whether hysteresis is wide enough.
	var transitions: int = 0

	func _init(source: Node3D) -> void:
		_source = source

	## The Callable handed to MultiplayerSynchronizer.add_visibility_filter(). Hot path: called once
	## per peer per physics tick, so no allocation, no tree walk, no sqrt.
	func evaluate(peer_id: int) -> bool:
		# Out of the tree has no global position to compare, and freed has none at all. Both answer
		# "invisible", which is the safe direction: a client is told the entity is gone.
		if not is_instance_valid(_source) or not _source.is_inside_tree():
			return false

		# The host owns every filtered entity and must always be addressable. This matters on client
		# copies too: clients do not publish observer positions, but Godot consults local visibility
		# before allowing an RPC to peer 1. Returning false here makes a valid client->host request fail
		# in the RPC layer as "peer cannot see this node" before authority validation can run.
		if peer_id == NetConfig.HOST_PEER_ID:
			return true

		# A peer with no player has no viewpoint. Sending it the world would be the one case where
		# interest management costs more than it saves.
		if not NetInterest.has_observer(peer_id):
			_visible.erase(peer_id)
			return false

		var distance_sq: float = _source.global_position.distance_squared_to(
			NetInterest.observer_of(peer_id)
		)
		var was_visible: bool = _visible.get(peer_id, false)
		var now_visible: bool = distance_sq <= (_leave_sq if was_visible else _enter_sq)

		if now_visible != was_visible:
			_visible[peer_id] = now_visible
			transitions += 1

		return now_visible

	## What the filter last answered for [param peer_id], without re-evaluating.
	func is_visible_to(peer_id: int) -> bool:
		return _visible.get(peer_id, false)

	## Forget a peer's hysteresis state — on disconnect, so a reconnecting peer starts from the enter
	## radius rather than inheriting the leave radius it left on.
	func forget(peer_id: int) -> void:
		_visible.erase(peer_id)
