class_name Enemy
extends CharacterBody3D

## One enemy: chase → telegraph → attack → recover, with health, death and a corpse.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, "Enemies (spawn, AI, damage)"): **HOST**, entirely.
## The host picks the target, paths, turns, decides when the attack lands and how much it does, and
## owns health and death. Clients run no AI at all — they receive position, yaw, state and health
## through a code-built `MultiplayerSynchronizer` (D-023) and play the animation that matches the
## state they were given. There is no client prediction here and there must never be: two clients
## disagreeing about whether an attack landed is the exact bug §2.2 exists to prevent.
##
## Damage comes IN through the shared melee seam (2.8): this joins `&"damageable"` and implements
## `host_apply_damage(amount, instigator_peer_id) -> bool`, so `CombatService` needed no change to
## make enemies hittable. Damage goes OUT as an `EventBus` event, because player health does not
## exist yet — task 2.13 (downed → bleed-out → revive) subscribes to it.

const EVENT_BUS := preload("res://core/events/event_bus.gd")
const ENEMY_DEF := preload("res://systems/enemies/enemy_def.gd")

const DAMAGEABLE_GROUP: StringName = &"damageable"
const ENEMY_GROUP: StringName = &"enemies"
const VISUAL_NODE: StringName = &"EnemyVisual"

## The six clips A-006 authored. `idle` and `locomotion` are exported as `idle-loop` and
## `locomotion-loop`; Godot reads that suffix as "loop this clip" and strips it, so the runtime names
## are the ones below and the exported ones will not resolve.
const ANIM_IDLE: StringName = &"idle"
const ANIM_LOCOMOTION: StringName = &"locomotion"
const ANIM_TELL: StringName = &"attack_tell"
const ANIM_ATTACK: StringName = &"attack"
const ANIM_HIT: StringName = &"hit"
const ANIM_DEATH: StringName = &"death"

## Feel constants (2.9). Short enough to read as an impact rather than a state change.
const HIT_FLASH_SEC: float = 0.12
const HIT_FLASH_ALPHA: float = 0.75
## Fraction of the corpse's life spent lying still before it starts sinking, so the death clip lands
## before anything moves.
const DISSOLVE_HOLD_FRACTION: float = 0.35

enum State { IDLE, CHASE, TELL, ATTACK, RECOVER, DEAD }

## Host-only. Cosmetic consumers on every peer should watch `state` through the synchronizer instead.
signal died(instigator_peer_id: int)

@export var definition: ENEMY_DEF

## ── Replicated state. Setters keep a client's presentation correct when a delta arrives. ──────────
var state: int = State.IDLE:
	set(value):
		if state == value:
			return
		state = value
		_play_state_animation()

var health: int = 0

## Bumped by the host on every accepted hit. Replicated as a counter rather than as a "was hit" flag
## because a flag that goes true and false again can land between two snapshots and be missed
## entirely — a counter that changes is a hit, however many packets it took to arrive (2.9).
var hit_counter: int = 0:
	set(value):
		var jumped: bool = value > hit_counter
		hit_counter = value
		if jumped:
			_react_to_hit()

var _target_peer: int = 0
var _phase_remaining: float = 0.0
var _corpse_remaining: float = 0.0
var _agent: NavigationAgent3D
var _sync: MultiplayerSynchronizer
var _visual: Node3D
var _anim: AnimationPlayer
var _gravity: float = 9.8
var _nav_ready: bool = false

## Client-local hit/death feedback (2.9). Runs on EVERY peer, including the host's own copy, and is
## never networked beyond the two replicated values that trigger it — §2.2's last row.
var _flash_remaining: float = 0.0
var _flash_material: StandardMaterial3D
var _dissolve_elapsed: float = 0.0
var _visual_rest_y: float = 0.0
## Restored if this body is ever revived or reused; death zeroes it (F-040).
var _alive_collision_layer: int = 1


func _ready() -> void:
	set_multiplayer_authority(NetConfig.HOST_PEER_ID)
	# Feedback is presentation, so it runs everywhere — a client that only saw the host's physics
	# would see a crawler die with no reaction at all.
	set_process(true)
	add_to_group(ENEMY_GROUP)
	add_to_group(DAMAGEABLE_GROUP)
	_gravity = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))

	if definition != null:
		health = definition.max_health
	_alive_collision_layer = collision_layer

	_build_body()
	_build_visual()
	_build_agent()
	_build_synchronizer()
	_play_state_animation()

	# Only the host simulates. A client's copy is moved entirely by replication, and 1.6's
	# interpolator smooths it — the enemy's synchronizer is named NetConfig.PLAYER_SYNC_NODE for
	# exactly that reason, so `NetInterp.attach_to()` works on it with no change (F-004).
	set_physics_process(_owns_simulation())
	if not _owns_simulation():
		var interp: Node = get_node_or_null(^"/root/NetInterp")
		if interp != null:
			interp.call_deferred(&"attach_to", self)


# ── The damage seam (2.8) ─────────────────────────────────────────────────────────────────────────


## Host-only, rejects everything else. Returning false is a miss, not a phantom hit — `CombatService`
## relies on that to avoid announcing a connect that did not happen.
func host_apply_damage(amount: int, instigator_peer_id: int) -> bool:
	if not _owns_simulation() or amount <= 0 or state == State.DEAD or definition == null:
		return false

	health = maxi(health - amount, 0)
	hit_counter += 1
	# Being hit does not interrupt a committed attack. An enemy whose swing can be cancelled by any
	# chip of damage cannot threaten a group, and DESIGN.md §6's readable telegraph only means
	# anything if the thing it telegraphs actually arrives.
	if health > 0:
		if state == State.CHASE or state == State.IDLE:
			_aggro_on(instigator_peer_id)
		return true

	_enter_death(instigator_peer_id)
	return true


func is_alive() -> bool:
	return state != State.DEAD


func target_peer() -> int:
	return _target_peer


# ── Host simulation ───────────────────────────────────────────────────────────────────────────────


func _physics_process(delta: float) -> void:
	if definition == null:
		return
	if not is_on_floor():
		velocity.y -= _gravity * delta
	else:
		velocity.y = minf(velocity.y, 0.0)

	match state:
		State.DEAD:
			_tick_corpse(delta)
		State.TELL, State.ATTACK, State.RECOVER:
			_tick_attack(delta)
		_:
			_tick_pursuit(delta)

	move_and_slide()


func _tick_pursuit(delta: float) -> void:
	var target: Node3D = _resolve_target()
	if target == null:
		velocity.x = 0.0
		velocity.z = 0.0
		state = State.IDLE
		return

	var to_target: Vector3 = target.global_position - global_position
	var distance: float = Vector3(to_target.x, 0.0, to_target.z).length()
	_face(to_target, delta)

	if distance <= definition.attack_range_m:
		velocity.x = 0.0
		velocity.z = 0.0
		_enter_tell()
		return

	state = State.CHASE
	var step: Vector3 = _steer_toward(target.global_position)
	velocity.x = step.x * definition.move_speed
	velocity.z = step.z * definition.move_speed


func _tick_attack(delta: float) -> void:
	velocity.x = 0.0
	velocity.z = 0.0
	_phase_remaining -= delta
	if _phase_remaining > 0.0:
		return

	match state:
		State.TELL:
			# The hit resolves at the END of the tell, against where the target is NOW. That is what
			# makes backing out of a telegraphed swing work, and it is the whole point of the 0.4 s.
			_resolve_attack()
			state = State.ATTACK
			_phase_remaining = definition.attack_seconds
		State.ATTACK:
			state = State.RECOVER
			_phase_remaining = definition.attack_recovery_seconds
		_:
			state = State.CHASE
			_phase_remaining = 0.0


func _resolve_attack() -> void:
	var target: Node3D = _resolve_target()
	if target == null:
		return
	var to_target: Vector3 = target.global_position - global_position
	if Vector3(to_target.x, 0.0, to_target.z).length() > definition.attack_range_m:
		return
	# Player health is task 2.13's. Emitting the event rather than inventing a health field here
	# keeps the authority story honest: the host decided a hit landed, and whoever owns player state
	# decides what that costs.
	EVENT_BUS.emit_enemy_attack_landed(
		definition.id, _target_peer, definition.attack_damage, target.global_position
	)


func _tick_corpse(delta: float) -> void:
	velocity.x = 0.0
	velocity.z = 0.0
	_corpse_remaining -= delta
	if _corpse_remaining <= 0.0:
		queue_free()


func _enter_tell() -> void:
	state = State.TELL
	_phase_remaining = definition.attack_tell_seconds


func _enter_death(instigator_peer_id: int) -> void:
	state = State.DEAD
	_target_peer = 0
	velocity = Vector3.ZERO
	_corpse_remaining = definition.corpse_seconds + _clip_length(ANIM_DEATH)
	# F-040: zero the LAYER, never disable the shapes. A corpse still needs its collision_mask to
	# find the ground — gravity keeps running through _tick_corpse, so a body with no shape falls
	# through the terrain for the whole corpse window, in full view. Zeroing the layer alone means
	# nothing detects or collides with it while it still lands where it died.
	collision_layer = 0
	remove_from_group(DAMAGEABLE_GROUP)
	died.emit(instigator_peer_id)


func _aggro_on(peer_id: int) -> void:
	if peer_id > 0:
		_target_peer = peer_id


## Nearest player inside aggro range, with hysteresis: an acquired target is kept until it leaves the
## larger deaggro radius, so an enemy on the boundary does not flicker every tick.
func _resolve_target() -> Node3D:
	var held: Node3D = _player_for(_target_peer)
	if held != null:
		var held_distance: float = global_position.distance_to(held.global_position)
		if held_distance <= definition.deaggro_radius_m:
			return held
	_target_peer = 0

	var best: Node3D = null
	var best_distance: float = definition.aggro_radius_m
	for node: Node in get_tree().get_nodes_in_group(&"players"):
		var player := node as Node3D
		if player == null:
			continue
		var distance: float = global_position.distance_to(player.global_position)
		if distance > best_distance:
			continue
		best = player
		best_distance = distance
	if best != null:
		_target_peer = _peer_of(best)
	return best


## Nav-driven where a navigation map exists, straight-line where it does not. `EnemyWorld` bakes a
## region from the level's static collision at session start; if that produced nothing — an empty
## test scene, a level with no colliders — the agent has no map and would return the enemy's own
## position forever, which reads as a frozen enemy rather than a missing navmesh.
func _steer_toward(destination: Vector3) -> Vector3:
	var direct: Vector3 = destination - global_position
	direct.y = 0.0
	if _agent == null or not _nav_ready:
		return direct.normalized()

	_agent.target_position = destination
	if _agent.is_navigation_finished():
		return Vector3.ZERO
	var next: Vector3 = _agent.get_next_path_position() - global_position
	next.y = 0.0
	if next.length_squared() < 0.0001:
		return direct.normalized()
	return next.normalized()


func _face(to_target: Vector3, delta: float) -> void:
	var flat: Vector3 = Vector3(to_target.x, 0.0, to_target.z)
	if flat.length_squared() < 0.0001:
		return
	# The model faces -Z (A-006), which is Godot's forward, so the yaw is atan2 of the vector itself.
	var wanted: float = atan2(-flat.x, -flat.z)
	rotation.y = rotate_toward(rotation.y, wanted, definition.turn_speed_rad * delta)


# ── Construction (all in code — D-023) ────────────────────────────────────────────────────────────


func _build_body() -> void:
	var shape := CapsuleShape3D.new()
	shape.radius = definition.radius_m if definition != null else 0.45
	shape.height = maxf((definition.height_m if definition != null else 0.6), shape.radius * 2.0)
	var collider := CollisionShape3D.new()
	collider.name = "EnemyCollision"
	collider.shape = shape
	collider.position.y = shape.height * 0.5
	add_child(collider)


func _build_visual() -> void:
	if definition == null or definition.model == null:
		return
	_visual = definition.model.instantiate() as Node3D
	if _visual == null:
		return
	_visual.name = VISUAL_NODE
	# F-039: the body's yaw is the truth; this only corrects a model whose exported forward is not
	# Godot's. Applied to the visual so nothing about targeting, pathing or the hitbox has to know.
	_visual.rotation.y = deg_to_rad(definition.model_yaw_offset_degrees)
	_visual_rest_y = _visual.position.y
	add_child(_visual)
	var players: Array[Node] = _visual.find_children("*", "AnimationPlayer", true, false)
	if not players.is_empty():
		_anim = players[0] as AnimationPlayer


func _build_agent() -> void:
	_agent = NavigationAgent3D.new()
	_agent.name = "EnemyNav"
	_agent.path_desired_distance = 0.6
	_agent.target_desired_distance = definition.stop_distance_m if definition != null else 1.5
	_agent.avoidance_enabled = false
	add_child(_agent)
	# The map is not available on the frame the agent enters the tree. One deferred check is enough:
	# EnemyWorld bakes before it spawns anything.
	_confirm_nav_map.call_deferred()


func _confirm_nav_map() -> void:
	if _agent == null or not _agent.is_inside_tree():
		return
	var map: RID = _agent.get_navigation_map()
	_nav_ready = map.is_valid() and NavigationServer3D.map_get_iteration_id(map) > 0


func _build_synchronizer() -> void:
	var config := SceneReplicationConfig.new()
	for property: NodePath in [
		^".:position", ^".:rotation:y", ^".:state", ^".:health", ^".:hit_counter"
	]:
		config.add_property(property)
		config.property_set_spawn(property, true)
		config.property_set_replication_mode(
			property, SceneReplicationConfig.REPLICATION_MODE_ALWAYS
		)

	_sync = MultiplayerSynchronizer.new()
	# Same node name as a player's, so NetInterp smooths an enemy with no change (F-004).
	_sync.name = NetConfig.PLAYER_SYNC_NODE
	_sync.root_path = NodePath("..")
	_sync.replication_config = config
	# BEFORE add_child, never after (F-012): setting authority on a synchronizer already in the tree
	# makes the replication interface reject the pending spawn on every client, and the symptom is
	# error spam plus silently degraded state rather than a clean failure.
	_sync.set_multiplayer_authority(NetConfig.HOST_PEER_ID)
	NetInterest.configure(_sync, self, NetInterest.Class.ENEMY)
	add_child(_sync)


# ── Feedback (client-local, every peer — never networked) ─────────────────────────────────────────


func _process(delta: float) -> void:
	_tick_flash(delta)
	_tick_dissolve(delta)


## A hit with no reaction reads as a hit that did not land. This is the cheap half of that: the
## `hit` clip, plus a brief white overlay so a connect is visible even when the clip is masked by a
## committed attack.
func _react_to_hit() -> void:
	_flash_remaining = HIT_FLASH_SEC
	if _anim != null and state != State.DEAD and _anim.has_animation(String(ANIM_HIT)):
		if state != State.TELL and state != State.ATTACK:
			_anim.play(String(ANIM_HIT))


func _tick_flash(delta: float) -> void:
	if _visual == null:
		return
	if _flash_remaining <= 0.0:
		return
	_flash_remaining = maxf(_flash_remaining - delta, 0.0)
	var strength: float = _flash_remaining / HIT_FLASH_SEC
	_apply_overlay(Color(1.0, 1.0, 1.0, strength * HIT_FLASH_ALPHA))
	if _flash_remaining <= 0.0 and _dissolve_elapsed <= 0.0:
		_clear_overlay()


## Stands in for a ragdoll. The corpse sinks and fades over its remaining time instead of blinking
## out, which is what makes a kill read as finished rather than as a despawn bug. Deliberately not a
## shader: a dissolve shader on an imported GLB means touching its materials, and this reads well at
## this art scale for a fraction of the work.
func _tick_dissolve(delta: float) -> void:
	if state != State.DEAD or _visual == null or definition == null:
		return
	_dissolve_elapsed += delta
	var total: float = maxf(definition.corpse_seconds, 0.001)
	var progress: float = clampf(_dissolve_elapsed / total, 0.0, 1.0)
	# Held still until the death clip has had its moment, then sunk.
	var sink: float = smoothstep(DISSOLVE_HOLD_FRACTION, 1.0, progress)
	_visual.position.y = _visual_rest_y - sink * (definition.height_m + 0.35)
	_apply_overlay(Color(0.05, 0.06, 0.05, sink * 0.85))


func _apply_overlay(colour: Color) -> void:
	if _flash_material == null:
		_flash_material = StandardMaterial3D.new()
		_flash_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_flash_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_flash_material.albedo_color = colour
	for node: Node in _visual.find_children("*", "MeshInstance3D", true, false):
		(node as MeshInstance3D).material_overlay = _flash_material


func _clear_overlay() -> void:
	if _visual == null:
		return
	for node: Node in _visual.find_children("*", "MeshInstance3D", true, false):
		(node as MeshInstance3D).material_overlay = null


# ── Presentation (client-local, every peer) ───────────────────────────────────────────────────────


func _play_state_animation() -> void:
	if _anim == null:
		return
	var clip: StringName = ANIM_IDLE
	match state:
		State.CHASE:
			clip = ANIM_LOCOMOTION
		State.TELL:
			clip = ANIM_TELL
		State.ATTACK:
			clip = ANIM_ATTACK
		State.RECOVER, State.IDLE:
			clip = ANIM_IDLE
		State.DEAD:
			clip = ANIM_DEATH
	if _anim.has_animation(String(clip)):
		_anim.play(String(clip))


func _clip_length(clip: StringName) -> float:
	if _anim == null or not _anim.has_animation(String(clip)):
		return 0.0
	return _anim.get_animation(String(clip)).length


# ── Shared lookups ────────────────────────────────────────────────────────────────────────────────


## The `players` group first, PlayerNet second. Deliberately that order: PlayerNet only knows about
## players IT spawned, so offline — and in any harness that builds a player directly — it returns
## null and the held-target lookup silently fails, which quietly disables aggro hysteresis. The group
## is the same source `_resolve_target()` scans, so both halves agree by construction.
func _player_for(peer_id: int) -> Node3D:
	if peer_id <= 0:
		return null
	for node: Node in get_tree().get_nodes_in_group(&"players"):
		var player := node as Node3D
		if player != null and _peer_of(player) == peer_id:
			return player
	var player_net: Node = get_node_or_null(^"/root/PlayerNet")
	if player_net != null and player_net.has_method("player_for"):
		return player_net.call("player_for", peer_id) as Node3D
	return null


func _peer_of(player: Node3D) -> int:
	var node_name: String = String(player.name)
	return node_name.to_int() if node_name.is_valid_int() else NetConfig.HOST_PEER_ID


func _owns_simulation() -> bool:
	var transport: Node = get_node_or_null(^"/root/NetTransport")
	if transport == null:
		return true
	if bool(transport.call("is_host")):
		return true
	return not bool(transport.call("is_active")) and not bool(transport.call("is_connecting"))
