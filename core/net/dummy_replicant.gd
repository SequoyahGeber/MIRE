extends Node3D

## SPIKE R1 (task 1.9) — a throwaway host-authoritative entity that moves and replicates.
##
## THIS IS NOT THE REAL REPLICATED-ENTITY BASE CLASS. It exists to produce one number for
## docs/ARCHITECTURE.md §6 R1 — "can Godot's high-level multiplayer carry 6 peers and 200 synced
## entities?" — and nothing else consumes it. Delete or rewrite it when the real entity layer lands;
## do not grow features onto it.
##
## AUTHORITY (docs/ARCHITECTURE.md §2.2): host-authoritative, unconditionally. The host simulates
## and sends. Clients receive and never write a replicated field, and never run step().
##
## The MultiplayerSynchronizer and its SceneReplicationConfig are built IN CODE (D-023). A headless
## spike cannot author .tscn files, and building them in _ready() is also the only way to guarantee
## every peer arrives at a byte-identical node tree — the high-level API matches nodes by path, so a
## synchronizer that exists on one side and not the other fails as silence, not as an error.

## Child synchronizer's name. Identical on every peer by construction.
const SYNC_NODE_NAME: StringName = &"NetSync"

## §2.5: enemies and props replicate only to peers within ~120 m. Task 1.8 ships the real thing;
## this is here so the spike can measure what that decision is worth.
const INTEREST_RADIUS_M: float = 120.0

## Wander speed, m/s — about a sprinting player, so each frame's position delta is the same order of
## magnitude as real gameplay traffic. A stationary dummy would replicate almost nothing and flatter
## the result.
const MOVE_SPEED: float = 6.0

## Seconds between direction changes.
const RETARGET_SEC: float = 1.5

## Half-extent of the square the dummies wander inside, metres. Paired with INTEREST_RADIUS_M this
## is what sets how much interest management can possibly cull.
const WORLD_HALF_EXTENT: float = 300.0

## How often the rarely-changing field actually changes, in seconds. Stands in for §2.5's
## "props replicate on-change" class.
const STATE_CHANGE_SEC: float = 5.0

## Peer id -> that peer's observer position. Host-side only, written by the bench, read by the
## visibility filter. Static because the filter runs once per entity per peer per frame — 1000 calls
## a frame at 200 entities and 5 clients — so it must not allocate or search the scene tree.
static var observer_positions: Dictionary[int, Vector3] = {}

# ── Replicated state ──────────────────────────────────────────────────────────────────────────────
# Three fields, deliberately: position is the expensive one, and the other two are there so the
# packet has the shape of a real entity rather than a bare Vector3.

## Facing. Replicated ALWAYS, like position.
var rot_y: float = 0.0

## A small, rarely-changing field — replicated ON_CHANGE, which is the §2.5 "props" class.
var state: int = 0

var _index: int = 0
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _direction: Vector3 = Vector3.FORWARD
var _retarget_in: float = 0.0
var _state_change_in: float = 0.0
var _sync: MultiplayerSynchronizer = null
var _filter: Callable = Callable()


## Called by the bench's spawn_function on EVERY peer, before the node enters the tree, with the same
## index on each — so host and client agree on the starting position without it having to be sent.
func configure(index: int, seed_value: int) -> void:
	_index = index
	name = "d%d" % index
	# Per-entity seeded stream. Never global randi(): two runs of this spike have to be comparable,
	# and in the real game a divergent stream is a desync (AGENTS.md, code conventions).
	_rng.seed = hash(seed_value) + index * 7919
	position = Vector3(
		_rng.randf_range(-WORLD_HALF_EXTENT, WORLD_HALF_EXTENT),
		0.0,
		_rng.randf_range(-WORLD_HALF_EXTENT, WORLD_HALF_EXTENT),
	)
	_retarget_in = _rng.randf_range(0.0, RETARGET_SEC)
	_state_change_in = _rng.randf_range(0.0, STATE_CHANGE_SEC)
	_pick_direction()


func _ready() -> void:
	# Authority BEFORE the synchronizer enters the tree. A synchronizer registers itself with the
	# replication interface on tree entry and reads its authority there; set it afterwards and the
	# host never becomes the sender.
	set_multiplayer_authority(NetConfig.HOST_PEER_ID)
	_build_synchronizer()
	# Nothing self-drives. The bench calls step() on host copies only, with a fixed delta, so the
	# movement cost is measured separately from the replication cost and two runs match exactly.
	set_process(false)
	set_physics_process(false)


## Built identically on every peer — only the authority differs, which is what makes one side send
## and the other receive.
func _build_synchronizer() -> void:
	var config: SceneReplicationConfig = SceneReplicationConfig.new()

	var position_path := NodePath(".:position")
	config.add_property(position_path)
	config.property_set_spawn(position_path, true)
	config.property_set_replication_mode(position_path, SceneReplicationConfig.REPLICATION_MODE_ALWAYS)

	var rot_path := NodePath(".:rot_y")
	config.add_property(rot_path)
	config.property_set_replication_mode(rot_path, SceneReplicationConfig.REPLICATION_MODE_ALWAYS)

	var state_path := NodePath(".:state")
	config.add_property(state_path)
	config.property_set_spawn(state_path, true)
	config.property_set_replication_mode(state_path, SceneReplicationConfig.REPLICATION_MODE_ON_CHANGE)

	_sync = MultiplayerSynchronizer.new()
	_sync.name = SYNC_NODE_NAME
	_sync.root_path = NodePath("..")
	_sync.replication_config = config
	_sync.set_multiplayer_authority(NetConfig.HOST_PEER_ID)
	# Interest management starts OFF; the bench turns it on for the phases that measure it.
	_sync.visibility_update_mode = MultiplayerSynchronizer.VISIBILITY_PROCESS_NONE
	# F-013: counted by the net debug panel. See NetConfig.SYNCED_GROUP for what the group means.
	_sync.add_to_group(NetConfig.SYNCED_GROUP)
	add_child(_sync)


## Host-only simulation. Fixed delta, no trig, seeded stream — reproducible between runs.
func step(delta: float) -> void:
	_retarget_in -= delta
	if _retarget_in <= 0.0:
		_retarget_in = RETARGET_SEC
		_pick_direction()

	position += _direction * MOVE_SPEED * delta

	# Reflect at the boundary rather than wrapping: a teleport across the world would look like a
	# 600 m position delta and is exactly the kind of thing that makes a bandwidth number a lie.
	if absf(position.x) > WORLD_HALF_EXTENT:
		position.x = signf(position.x) * WORLD_HALF_EXTENT
		_direction.x = -_direction.x
	if absf(position.z) > WORLD_HALF_EXTENT:
		position.z = signf(position.z) * WORLD_HALF_EXTENT
		_direction.z = -_direction.z

	rot_y = wrapf(rot_y + delta, -PI, PI)

	_state_change_in -= delta
	if _state_change_in <= 0.0:
		_state_change_in = STATE_CHANGE_SEC
		state = (state + 1) % 8


func _pick_direction() -> void:
	# Normalized from two seeded components — no sin/cos, per D-017.
	var candidate := Vector3(_rng.randf_range(-1.0, 1.0), 0.0, _rng.randf_range(-1.0, 1.0))
	if candidate.length_squared() < 0.0001:
		candidate = Vector3.FORWARD
	_direction = candidate.normalized()


## §2.5 interest management, on or off. Off is not "a filter that returns true" — the filter is
## removed entirely, because evaluating it is itself one of the costs this spike is measuring.
func set_interest_management(enabled: bool) -> void:
	if _sync == null:
		return
	if enabled:
		if _filter.is_null():
			_filter = _visibility_filter
			_sync.add_visibility_filter(_filter)
		_sync.visibility_update_mode = MultiplayerSynchronizer.VISIBILITY_PROCESS_IDLE
	else:
		if not _filter.is_null():
			_sync.remove_visibility_filter(_filter)
			_filter = Callable()
		_sync.visibility_update_mode = MultiplayerSynchronizer.VISIBILITY_PROCESS_NONE
	_sync.update_visibility()


## True if this entity is within INTEREST_RADIUS_M of that peer's observer. Squared distance: no
## sqrt, because this runs 1000 times a frame.
func _visibility_filter(peer_id: int) -> bool:
	var observer: Vector3 = observer_positions.get(peer_id, Vector3.ZERO)
	return position.distance_squared_to(observer) <= INTEREST_RADIUS_M * INTEREST_RADIUS_M


## Same test as the filter, for the bench to report what fraction of entities was actually visible —
## a culling number is meaningless without it.
func is_within_interest_of(observer: Vector3) -> bool:
	return position.distance_squared_to(observer) <= INTEREST_RADIUS_M * INTEREST_RADIUS_M


func set_intervals(sync_interval: float, delta_interval: float) -> void:
	if _sync == null:
		return
	_sync.replication_interval = sync_interval
	_sync.delta_interval = delta_interval
