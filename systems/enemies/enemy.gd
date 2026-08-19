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
##
## Task 5.1 generalises three of 2.10's per-enemy behaviours into framework any `EnemyDef` can tune:
## **perception** (`_can_perceive()` — a facing cone plus an optional line-of-sight ray gate
## ACQUISITION only; an already-held target is kept on distance alone, per the existing hysteresis),
## **alerting** (`_alert_nearby()`/`alert()` — a fresh acquisition hands the same target directly to
## any untargeted packmate in `alert_radius_m`, one hop, no perception check of its own), and an
## **attack-slot cap** (`_engaged_attackers()` — at most `max_concurrent_attackers` of one kind may be
## telegraphing or swinging at the same target; the rest hold position instead of piling on). All
## three are still host-only decisions inside the same state machine; no new replicated property, no
## new RPC.
##
## F-240 adds a fourth tunable to the same TELL/ATTACK/RECOVER span: `_tick_lunge()` lets a kind whose
## `EnemyDef.lunge_speed_m_s` is above 0.0 close ground during its own TELL instead of standing fully
## still. The hit still resolves at the tell's END against wherever the target then is
## (`_resolve_attack()`, unchanged) — this only changes whether the enemy stood still while that gap
## opened, not when or how the hit is judged. Default 0.0 keeps every existing `EnemyDef` stationary,
## bit-for-bit.

const EVENT_BUS := preload("res://core/events/event_bus.gd")
const ENEMY_DEF := preload("res://systems/enemies/enemy_def.gd")
## For TERRAIN_LAYER only (F-075) — see _build_body().
const PlacementValidator := preload("res://systems/building/placement_validator.gd")

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

## How stale a chased target's pathed-to position may get, and how often an idle enemy rescans for
## someone to chase (F-099). Both trade at most a fifth of a second of reaction for not hammering
## the navigation server and the group system every tick; the attack itself always measures live
## positions, so neither affects whether a hit lands.
const REPATH_DISTANCE_M: float = 1.0
const RESCAN_INTERVAL_SEC: float = 0.2

## Client-local render LOD (7.7). Waves grow without bound as Cycles escalate
## (`WaveSpawner.cycle_count_multiplier()`, DESIGN's "endless, no win condition"), and unlike F-144's
## props/undergrowth an enemy can't be merged into a static batched mesh — each is independently
## animated. A visibility-range self-fade is the lever that's actually available: past this distance
## an enemy is already outside both aggro (`deaggro_radius_m` tops out at 26 m by default) and any
## readable telegraph (DESIGN.md §6), so nothing gameplay-relevant is lost by not drawing it. Purely
## cosmetic — no two peers can disagree about when a mesh fades (ARCHITECTURE.md §2.2, "VFX, audio,
## camera, UI" row) — so this needs no replication.
const VISIBILITY_RANGE_END_M: float = 90.0
const VISIBILITY_RANGE_FADE_MARGIN_M: float = 8.0

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
		if value == State.DEAD:
			# The dissolve runs in _process, which idles off until something animates (F-099).
			set_process(true)
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
## The held target's node, validated by reference each tick instead of re-found by a group scan
## (F-099). Reacquisition scans for a NEW target run at RESCAN_INTERVAL_SEC, not every tick.
var _target_node: Node3D
var _rescan_wait: float = 0.0
## Where the nav agent was last asked to path to. Re-pathing only when the goal has moved more than
## REPATH_DISTANCE_M keeps a moving target from forcing a repath every physics tick (F-099).
var _path_goal: Vector3 = Vector3(INF, INF, INF)
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
## The visual's mesh list, walked once at build time — not re-found per overlay frame (F-099).
var _overlay_meshes: Array[MeshInstance3D] = []
var _overlay_active: bool = false
var _dissolve_elapsed: float = 0.0
var _visual_rest_y: float = 0.0
## Restored if this body is ever revived or reused; death zeroes it (F-040).
var _alive_collision_layer: int = 1
## F-245: set by `_maybe_bloom_split()` on a freshly spawned child so its own death does not split
## again — one kill grows a fight by exactly two, not without bound. Host-only bookkeeping, never
## replicated: a client never runs `_enter_death()` at all (see `host_apply_damage()`'s own guard).
var _bloom_child: bool = false


func _ready() -> void:
	set_multiplayer_authority(NetConfig.HOST_PEER_ID)
	# Feedback is presentation and runs on every peer — but only while something is animating.
	# Hits and death switch _process on; the end of a flash switches it back off (F-099).
	set_process(false)
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


## Cycle Modifier `the_hunt`'s tracking elite (F-245, content/cycle_modifiers/the_hunt.tres):
## `WaveSpawner`'s own retarget ticker calls this on a schedule to keep the elite beelining for
## whoever currently holds the most powerups. Unlike `alert()`, which only ever hands a target to an
## UNENGAGED enemy, this always overrides — the elite's whole point is ignoring the normal perception/
## aggro-range acquisition gate every other target change on this file goes through.
func host_force_target(peer_id: int) -> void:
	if not _owns_simulation() or state == State.DEAD:
		return
	var node: Node3D = _player_for(peer_id)
	if node == null:
		return
	_acquire_target(peer_id, node)


# ── Host simulation ───────────────────────────────────────────────────────────────────────────────


func _physics_process(delta: float) -> void:
	if definition == null:
		return
	_rescan_wait = maxf(_rescan_wait - delta, 0.0)
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
		# Group behaviour (5.1): a full attack-slot cap on THIS target holds the enemy at range rather
		# than telegraphing, so a pack surrounds and takes turns instead of alpha-striking together.
		# Checked fresh every tick — a slot can free up the instant another attacker's swing resolves.
		if _engaged_attackers(_target_peer) < definition.max_concurrent_attackers:
			_enter_tell()
		else:
			state = State.CHASE
		return

	state = State.CHASE
	var step: Vector3 = _steer_toward(target.global_position)
	velocity.x = step.x * definition.move_speed
	velocity.z = step.z * definition.move_speed


func _tick_attack(delta: float) -> void:
	if state == State.TELL and definition.lunge_speed_m_s > 0.0:
		_tick_lunge()
	else:
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


## F-240: only called during TELL, and only when `definition.lunge_speed_m_s > 0.0` — every existing
## `EnemyDef` leaves that at its 0.0 default and keeps 2.10/5.1's fully-stationary tell untouched. A
## kind that opts in closes ground toward its live target for the tell's duration, the missing answer
## to "just take one step back": the hit still resolves at the tell's END against wherever the target
## then is (`_resolve_attack()`, unchanged), but the enemy is no longer guaranteed to have stood still
## while that gap opened. Stops at `stop_distance_m` — the same arrival distance pursuit itself stops
## at — so a lunge cannot carry the enemy through its own target.
func _tick_lunge() -> void:
	var target: Node3D = _resolve_target()
	if target == null:
		velocity.x = 0.0
		velocity.z = 0.0
		return
	var to_target: Vector3 = target.global_position - global_position
	var flat: Vector3 = Vector3(to_target.x, 0.0, to_target.z)
	if flat.length() <= definition.stop_distance_m:
		velocity.x = 0.0
		velocity.z = 0.0
		return
	var step: Vector3 = flat.normalized()
	velocity.x = step.x * definition.lunge_speed_m_s
	velocity.z = step.z * definition.lunge_speed_m_s


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
	_target_node = null
	velocity = Vector3.ZERO
	_corpse_remaining = definition.corpse_seconds + _clip_length(ANIM_DEATH)
	# F-040: zero the LAYER, never disable the shapes. A corpse still needs its collision_mask to
	# find the ground — gravity keeps running through _tick_corpse, so a body with no shape falls
	# through the terrain for the whole corpse window, in full view. Zeroing the layer alone means
	# nothing detects or collides with it while it still lands where it died.
	collision_layer = 0
	remove_from_group(DAMAGEABLE_GROUP)
	_maybe_bloom_split()
	died.emit(instigator_peer_id)


## Cycle Modifier `bloom` (F-245, content/cycle_modifiers/bloom.tres): an enemy that dies while it is
## active spawns two reduced-health children of its own kind at the death position instead of just
## dying. `_bloom_child` stops a spawned child from splitting again. Only ever reached from
## `_enter_death()`, itself only reached through `host_apply_damage()`'s `_owns_simulation()` guard —
## a client never runs this.
func _maybe_bloom_split() -> void:
	if _bloom_child or definition == null:
		return
	var modifiers: Node = get_node_or_null(^"/root/CycleModifierService")
	if modifiers == null or not bool(modifiers.call(&"has_modifier", &"bloom")):
		return
	var world: Node = get_node_or_null(^"/root/EnemyWorld")
	if world == null:
		return
	var child_health: int = maxi(definition.max_health / 2, 1)
	var damage: int = maxi(definition.max_health - child_health, 0)
	for _index: int in 2:
		var child: Node = world.call(&"host_spawn", definition.id, global_position)
		if child is Enemy:
			var enemy_child: Enemy = child as Enemy
			enemy_child.mark_as_bloom_child()
			if damage > 0:
				enemy_child.host_apply_damage(damage, 0)


## Public cross-instance setter (same shape as `alert()` above) — `_bloom_child` stays private-by-
## convention, only ever flipped through here.
func mark_as_bloom_child() -> void:
	_bloom_child = true


func _aggro_on(peer_id: int) -> void:
	if peer_id > 0:
		_acquire_target(peer_id, _player_for(peer_id))


## Nearest PERCEIVED player inside aggro range, with hysteresis: an acquired target is kept until it
## leaves the larger deaggro radius, so an enemy on the boundary does not flicker every tick.
func _resolve_target() -> Node3D:
	# Held target: validated by cached reference, re-looked-up only when the cache is stale (F-099).
	# Distance-only, deliberately — perception (below) gates ACQUISITION, not retention (5.1).
	if _target_peer > 0:
		if _target_node == null or not is_instance_valid(_target_node):
			_target_node = _player_for(_target_peer)
		if _target_node != null and is_instance_valid(_target_node):
			if global_position.distance_to(_target_node.global_position) <= definition.deaggro_radius_m:
				return _target_node
	_target_peer = 0
	_target_node = null

	# Acquisition: at most once per RESCAN_INTERVAL_SEC — an untargeted enemy has no reason to walk
	# the players group every tick. The first scan after losing a target is immediate.
	if _rescan_wait > 0.0:
		return null
	_rescan_wait = RESCAN_INTERVAL_SEC

	var best: Node3D = null
	var best_distance: float = definition.aggro_radius_m
	for node: Node in get_tree().get_nodes_in_group(&"players"):
		var player := node as Node3D
		if player == null:
			continue
		var distance: float = global_position.distance_to(player.global_position)
		if distance > best_distance:
			continue
		if not _can_perceive(player):
			continue
		best = player
		best_distance = distance
	if best != null:
		_acquire_target(_peer_of(best), best)
	return best


## Sets the held target, and — only on a genuinely NEW acquisition, not a re-affirmed hold of the
## same peer — wakes nearby packmates (5.1). Both callers above (a fresh hit, a fresh scan) funnel
## through here so alerting cannot be triggered from more than these two places.
func _acquire_target(peer_id: int, node: Node3D) -> void:
	var is_new: bool = peer_id > 0 and peer_id != _target_peer
	_target_peer = peer_id
	_target_node = node
	if is_new:
		_alert_nearby(peer_id)


## Hands `peer_id` directly to every enemy within `alert_radius_m` that has no target of its own —
## no perception check, because this is "a packmate shouted", not "a packmate saw" (5.1). Deliberately
## ONE HOP: `alert()` below never calls this again, so a spotted player draws the local pack without
## a chain reaction across every enemy on the map.
func _alert_nearby(peer_id: int) -> void:
	if definition.alert_radius_m <= 0.0:
		return
	var radius_sq: float = definition.alert_radius_m * definition.alert_radius_m
	for node: Node in get_tree().get_nodes_in_group(ENEMY_GROUP):
		if node == self:
			continue
		var packmate := node as Enemy
		if packmate == null or not is_instance_valid(packmate):
			continue
		if global_position.distance_squared_to(packmate.global_position) <= radius_sq:
			packmate.alert(peer_id)


## Public: called by a nearby packmate's `_alert_nearby()`. Only takes the target if this enemy is
## currently unengaged — an alert must not rip an enemy off a fight it is already in. Host-only, like
## every other decision this class makes; a client's copy never runs `_physics_process`, so it never
## reaches the caller that would invoke this.
func alert(peer_id: int) -> void:
	if not _owns_simulation() or definition == null or state == State.DEAD or _target_peer != 0:
		return
	var node: Node3D = _player_for(peer_id)
	if node == null:
		return
	_target_peer = peer_id
	_target_node = node


## How many OTHER enemies of any kind are currently telegraphing or swinging at `peer_id` (5.1's
## attack-slot cap). Walks the same group `_alert_nearby()` does rather than a maintained counter —
## counters drift when an enemy dies mid-swing; a live scan cannot.
func _engaged_attackers(peer_id: int) -> int:
	if peer_id <= 0:
		return 0
	var count: int = 0
	for node: Node in get_tree().get_nodes_in_group(ENEMY_GROUP):
		if node == self:
			continue
		var other := node as Enemy
		if other == null or not is_instance_valid(other):
			continue
		if other.target_peer() == peer_id and (other.state == State.TELL or other.state == State.ATTACK):
			count += 1
	return count


## Facing cone plus an optional line-of-sight ray, both acquisition-only (5.1) — see the doc comment
## on `EnemyDef.vision_angle_deg`. `vision_angle_deg >= 360.0` skips the cone math entirely, which is
## both the common case (most enemies are omnidirectional) and what keeps Enemy v1's original
## acquisition behaviour bit-for-bit for any `EnemyDef` that never sets this.
func _can_perceive(player: Node3D) -> bool:
	if definition.vision_angle_deg < 360.0:
		var flat: Vector3 = player.global_position - global_position
		flat.y = 0.0
		if flat.length_squared() > 0.0001:
			var forward: Vector3 = -global_transform.basis.z
			forward.y = 0.0
			if forward.length_squared() > 0.0001:
				var angle_deg: float = rad_to_deg(forward.normalized().angle_to(flat.normalized()))
				if angle_deg > definition.vision_angle_deg * 0.5:
					return false
	if not definition.requires_line_of_sight:
		return true
	return _has_line_of_sight(player)


## True if nothing solid sits between this enemy and `player`. Fails OPEN (visible) whenever the
## question cannot be answered — no space state yet, no world — matching the rest of this file's
## pattern of degrading to the simpler behaviour rather than freezing (see `_steer_toward()`'s comment
## on an unbaked navmesh).
func _has_line_of_sight(player: Node3D) -> bool:
	if not is_inside_tree():
		return true
	var world: World3D = get_world_3d()
	if world == null:
		return true
	var eye: Vector3 = global_position + Vector3.UP * (definition.height_m * 0.5)
	var target_point: Vector3 = player.global_position + Vector3.UP * 0.9
	var query := PhysicsRayQueryParameters3D.create(eye, target_point, collision_mask, [get_rid()])
	var result: Dictionary = world.direct_space_state.intersect_ray(query)
	if result.is_empty():
		return true
	return result.get("collider") == player


## Nav-driven where a navigation map exists, straight-line where it does not. `EnemyWorld` bakes a
## region from the level's static collision at session start; if that produced nothing — an empty
## test scene, a level with no colliders — the agent has no map and would return the enemy's own
## position forever, which reads as a frozen enemy rather than a missing navmesh.
func _steer_toward(destination: Vector3) -> Vector3:
	var direct: Vector3 = destination - global_position
	direct.y = 0.0
	if _agent == null or not _nav_ready:
		return direct.normalized()

	# Setting target_position dirties the path; against a continuously moving player that meant a
	# repath every physics tick. The goal is allowed to go REPATH_DISTANCE_M stale instead (F-099).
	if destination.distance_squared_to(_path_goal) > REPATH_DISTANCE_M * REPATH_DISTANCE_M:
		_path_goal = destination
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
	# Ground moved off the shared solid layer onto its own (F-075) — the engine default
	# collision_mask (1) alone would let an enemy fall straight through Hollowmere's terrain.
	collision_mask = 1 | PlacementValidator.TERRAIN_LAYER
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
	for node: Node in _visual.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance: MeshInstance3D = node as MeshInstance3D
		mesh_instance.visibility_range_end = VISIBILITY_RANGE_END_M
		mesh_instance.visibility_range_end_margin = VISIBILITY_RANGE_FADE_MARGIN_M
		mesh_instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		_overlay_meshes.append(mesh_instance)
	_apply_visual_tint()
	var players: Array[Node] = _visual.find_children("*", "AnimationPlayer", true, false)
	if not players.is_empty():
		_anim = players[0] as AnimationPlayer
		# The one-shot hit clip otherwise ends frozen on its last pose: nothing replays the state
		# clip until the next state CHANGE, so a chased-and-hit enemy walked with a locked pose.
		_anim.animation_finished.connect(_on_animation_finished)


## `EnemyDef.visual_tint` (F-158) as a per-surface albedo multiply, duplicated off the imported GLB's
## own material so tinting one enemy's instance never touches the shared resource every other instance
## of the same model references. `Color(1,1,1,1)` is the field's own no-op default, so this is a no-op
## for every EnemyDef that never sets it — skipped outright rather than duplicating materials for
## nothing.
func _apply_visual_tint() -> void:
	if definition.visual_tint == Color(1.0, 1.0, 1.0, 1.0):
		return
	for mesh_instance: MeshInstance3D in _overlay_meshes:
		if mesh_instance.mesh == null:
			continue
		for surface: int in mesh_instance.mesh.get_surface_count():
			var base_material: Material = mesh_instance.get_active_material(surface)
			var tinted: Material = (
				base_material.duplicate() if base_material != null else StandardMaterial3D.new()
			)
			if tinted is BaseMaterial3D:
				var base_colour: Color = (tinted as BaseMaterial3D).albedo_color
				(tinted as BaseMaterial3D).albedo_color = base_colour * definition.visual_tint
			mesh_instance.set_surface_override_material(surface, tinted)


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
	set_process(true)
	if _anim != null and state != State.DEAD and _anim.has_animation(String(ANIM_HIT)):
		if state != State.TELL and state != State.ATTACK:
			_anim.play(String(ANIM_HIT))


func _on_animation_finished(anim_name: StringName) -> void:
	if anim_name == ANIM_HIT:
		_play_state_animation()


func _tick_flash(delta: float) -> void:
	if _visual == null:
		return
	if _flash_remaining <= 0.0:
		return
	_flash_remaining = maxf(_flash_remaining - delta, 0.0)
	var strength: float = _flash_remaining / HIT_FLASH_SEC
	_apply_overlay(Color(1.0, 1.0, 1.0, strength * HIT_FLASH_ALPHA))
	if _flash_remaining <= 0.0:
		if _dissolve_elapsed <= 0.0:
			_clear_overlay()
		if state != State.DEAD:
			# Nothing left to animate; _process idles off until the next hit or death (F-099).
			set_process(false)


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


## Per-frame calls only tint the shared material; the overlay itself is assigned to the cached mesh
## list once per flash/dissolve and released once, never re-walked per frame (F-099).
func _apply_overlay(colour: Color) -> void:
	if _flash_material == null:
		_flash_material = StandardMaterial3D.new()
		_flash_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_flash_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_flash_material.albedo_color = colour
	if _overlay_active:
		return
	_overlay_active = true
	for mesh: MeshInstance3D in _overlay_meshes:
		mesh.material_overlay = _flash_material


func _clear_overlay() -> void:
	if not _overlay_active:
		return
	_overlay_active = false
	for mesh: MeshInstance3D in _overlay_meshes:
		mesh.material_overlay = null


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
