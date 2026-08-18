class_name PlayerController
extends CharacterBody3D

## First-person ground movement: walk, sprint, jump, coyote time, jump buffering.
##
## Network authority: OWN PLAYER MOVEMENT — CLIENT (ARCHITECTURE.md §2.2, row 1).
## The peer that owns this node simulates it locally and its transform is replicated outward by a
## MultiplayerSynchronizer. Remote copies of this node run no input and no physics — they are moved
## purely by replication (interpolation lands in task 1.6). The host sanity-checks the resulting
## speed in autoload/player_net.gd and warns; nothing here is trusted by anyone but the owner.
##
## Everything below is @export'd on purpose. Task 0.5 is "tune until movement feels good", and that
## tuning should happen in the inspector with the game running, not in this file.

## Emitted the frame a jump leaves the ground. Client-local — audio/VFX only, never networked.
signal jumped
## Emitted on landing, with the downward speed at the moment of impact (positive, m/s).
signal landed(impact_speed: float)

## Temporary network-test colours. The real third-person character belongs to the player-art task;
## these code-built proxies make movement and facing observable before that asset exists, without
## putting generated debug geometry in the human-owned player scene.
const DEBUG_AVATAR_COLOURS: Array[Color] = [
	Color("55b9ff"),
	Color("ff7a59"),
	Color("8ee05d"),
	Color("d687ff"),
	Color("ffd45a"),
	Color("55e0cf"),
]
const BLOCKING_UI_GROUP: StringName = &"blocks_gameplay_input"
## Shared melee target seam (2.8/2.10) — see autoload/combat_service.gd and systems/enemies/enemy.gd.
## A player joining it is what lets 2.13's downed/revive flow exist without new plumbing: damage in
## is already "anything in this group", and what it costs a player is systems/health/player_health.gd.
const DAMAGEABLE_GROUP: StringName = &"damageable"
## preload, not the bare `PlayerViewmodel` (F-016): a new class_name is not in the global class cache
## until an editor scan puts it there, so naming it here stops this script compiling in every
## `--script` harness — and a player whose script failed to compile never joins the `players` group,
## which fails as "the level has no player" rather than as a missing viewmodel.
const PLAYER_VIEWMODEL := preload("res://entities/player/viewmodel.gd")

@export_group("Speed")
## Base ground speed, metres per second.
@export_range(1.0, 15.0, 0.1) var walk_speed: float = 4.0
## Ground speed while the sprint action is held.
@export_range(1.0, 25.0, 0.1) var sprint_speed: float = 6.0

@export_group("Acceleration")
## How fast we reach target speed on the ground. Higher = snappier, more arcade.
@export_range(1.0, 200.0, 1.0) var ground_acceleration: float = 60.0
## How fast we stop on the ground with no input. Higher = less slide.
@export_range(1.0, 200.0, 1.0) var ground_friction: float = 50.0
## Steering authority in the air. Low values make jumps feel committed.
@export_range(0.0, 100.0, 1.0) var air_acceleration: float = 14.0

@export_group("Jump")
## Apex height of a standing jump, in metres. Converted to launch velocity via gravity.
@export_range(0.1, 5.0, 0.05) var jump_height: float = 1.1
## Grace period after walking off a ledge during which a jump still counts. The single biggest
## "why does this feel bad" fix in first-person movement.
@export_range(0.0, 0.5, 0.01) var coyote_time: float = 0.12
## Grace period for a jump pressed just before landing; it fires on touchdown instead of being eaten.
@export_range(0.0, 0.5, 0.01) var jump_buffer_time: float = 0.12
## Releasing jump early cuts upward velocity by this factor, giving variable jump height.
@export_range(0.0, 1.0, 0.05) var jump_cut_multiplier: float = 0.45

@export_group("Gravity")
## Multiplies project gravity. >1 makes jumps feel heavier without changing apex height.
@export_range(0.1, 5.0, 0.05) var gravity_scale: float = 2.0
## Downward speed cap, metres per second.
@export_range(10.0, 200.0, 1.0) var terminal_velocity: float = 60.0

@export_group("Downed")
## Ground speed while downed. Far below walk_speed on purpose — DESIGN.md §4.5's "downed, not dead"
## is a crawl toward a teammate, not an escape; sprint and jump are blocked outright (see
## gameplay_input_allowed()'s callers below).
@export_range(0.1, 5.0, 0.05) var crawl_speed: float = 1.0

## Set false on remote copies of this player so they are driven by replication only.
var is_local_authority: bool = true

@onready var camera: PlayerCamera = $CameraPivot

## Built in _ready(), never authored in the scene (D-023). Replicates the minimum that makes a
## remote player look right; 1.6 owns smoothing what arrives through it.
var net_sync: MultiplayerSynchronizer

var _gravity: float = 9.8
var _time_since_grounded: float = INF
var _time_since_jump_pressed: float = INF
var _was_on_floor: bool = true

## Client-local prediction of a revive hold (task 2.13). The host re-validates range and both
## players' states the moment the hold completes — see systems/health/player_health.gd's own note on
## why the timing itself does not have to be authoritative.
var _revive_target_peer: int = 0
var _revive_hold_elapsed: float = 0.0
var _revive_request_sent: bool = false


func _ready() -> void:
	_gravity = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))

	_adopt_spawn_authority()

	# Offline this returns true (no peer -> unique id 1, default authority 1), so the controller
	# works standalone for M0. In a session it is the peer this body was spawned for.
	is_local_authority = is_multiplayer_authority()

	add_to_group(&"players")
	add_to_group(DAMAGEABLE_GROUP)
	_build_debug_avatar()
	_build_synchronizer()

	# Only the owning player builds a viewmodel: it hangs off the camera, and a remote player has no
	# camera of ours to hang it off (F-041). Built in code rather than authored into player.tscn,
	# same reasoning as the synchronizer.
	if is_local_authority:
		_build_viewmodel()

	camera.set_active(is_local_authority)
	set_physics_process(is_local_authority)
	set_process_unhandled_input(is_local_authority)

	if is_local_authority:
		_capture_mouse(true)


## The held item lives under the Camera3D, not the pivot, so it inherits pitch as well as yaw and
## stays locked to the view the way a first-person weapon has to.
func _build_viewmodel() -> void:
	var camera_3d: Camera3D = camera.get_node_or_null(^"Camera3D") as Camera3D
	if camera_3d == null:
		return
	var viewmodel: Node3D = PLAYER_VIEWMODEL.new()
	viewmodel.name = "Viewmodel"
	camera_3d.add_child(viewmodel)


## Until a third-person character asset exists, remote players still need a visible body for the
## cross-platform replication test. This subtree is built identically on every peer and is purely
## client-local presentation; the owning player hides its own proxy so it cannot obstruct the
## first-person camera.
func _build_debug_avatar() -> void:
	var colour_index: int = absi(get_multiplayer_authority()) % DEBUG_AVATAR_COLOURS.size()
	var material := StandardMaterial3D.new()
	material.albedo_color = DEBUG_AVATAR_COLOURS[colour_index]
	material.roughness = 0.8

	var body_mesh := CapsuleMesh.new()
	body_mesh.radius = 0.4
	body_mesh.height = 1.8

	var body := MeshInstance3D.new()
	body.name = "DebugAvatar"
	body.position.y = 0.9
	body.mesh = body_mesh
	body.material_override = material
	body.visible = not is_local_authority
	add_child(body)

	# Godot's forward direction is -Z. The dark face plate makes replicated yaw obvious instead of
	# presenting a rotationally symmetric capsule that appears not to turn.
	var face_mesh := BoxMesh.new()
	face_mesh.size = Vector3(0.42, 0.28, 0.08)

	var face_material := StandardMaterial3D.new()
	face_material.albedo_color = Color("182331")
	face_material.roughness = 0.45

	var face := MeshInstance3D.new()
	face.name = "DebugAvatarFace"
	face.position = Vector3(0.0, 1.42, -0.37)
	face.mesh = face_mesh
	face.material_override = face_material
	face.visible = not is_local_authority
	add_child(face)


## The shared melee target seam (2.8): entities that join &"damageable" implement this. Authority for
## what a hit actually costs lives in systems/health/player_health.gd, keyed by peer id — this only
## forwards the call with the peer id this body belongs to. Returning false while downed/dead is
## PlayerHealth's job (no corpse-kicking in M2); this never second-guesses that answer.
func host_apply_damage(amount: int, instigator_peer_id: int) -> bool:
	var health: Node = get_node_or_null(^"/root/PlayerHealth")
	if health == null or not health.has_method(&"host_apply_damage"):
		return false
	return bool(
		health.call(&"host_apply_damage", get_multiplayer_authority(), amount, instigator_peer_id)
	)


## Read-only presentation queries against PlayerHealth, resolved by path (F-011: this file is reached
## bare by tools/verify_setup.gd through the PlayerController class, so an autoload referenced here
## must never be a bare identifier).
func _is_downed() -> bool:
	var health: Node = _health_node()
	return health != null and bool(health.call(&"local_is_downed"))


func _is_dead() -> bool:
	var health: Node = _health_node()
	return health != null and bool(health.call(&"local_is_dead"))


## Shared resolver for the same F-011-guarded lookup every PlayerHealth call in this file needs —
## stamina gating (task 3.8) added enough call sites that repeating get_node_or_null everywhere
## started to be the noisier option.
func _health_node() -> Node:
	return get_node_or_null(^"/root/PlayerHealth")


## A player spawned by PlayerNet is NAMED for the peer that owns it, and that name is in place on
## every peer before the node enters the tree — so both sides derive the same authority from it with
## nothing extra on the wire. Any other name (the level's hand-placed "Player", or anything offline)
## is left alone, which is why pressing Play still works with no session.
func _adopt_spawn_authority() -> void:
	var node_name: String = String(name)
	if not node_name.is_valid_int():
		return

	var owner_peer: int = node_name.to_int()
	if owner_peer <= 0:
		return

	set_multiplayer_authority(owner_peer)


## Runs unconditionally, on every peer, so host and client build the same tree — only the
## CONFIGURATION differs, in who holds authority. A synchronizer built on one side only fails as
## silence, which is the expensive kind of bug.
##
## Replicates position, body yaw and camera pitch, and nothing else. Yaw is on the body and pitch is
## on the pivot (see player_camera.gd), so a remote player needs both to face the right way.
## Velocity is deliberately absent: if 1.6 needs it for interpolation, 1.6 adds it and pays for it.
func _build_synchronizer() -> void:
	var config: SceneReplicationConfig = SceneReplicationConfig.new()
	for property: NodePath in [^".:position", ^".:rotation:y", ^"CameraPivot:rotation:x"]:
		config.add_property(property)
		config.property_set_replication_mode(
			property, SceneReplicationConfig.REPLICATION_MODE_ALWAYS
		)

	net_sync = MultiplayerSynchronizer.new()
	net_sync.name = NetConfig.PLAYER_SYNC_NODE
	net_sync.root_path = ^".."
	net_sync.replication_config = config

	# The owning peer sends; everyone else receives — and this MUST be set before the synchronizer
	# enters the tree. Changing a synchronizer's authority once it is already in the tree makes the
	# replication interface reject the pending spawn ("no network ID"), which the engine reports as
	# an error on every client and which is exactly the trap this task was warned about.
	net_sync.set_multiplayer_authority(get_multiplayer_authority())
	# §2.5 replication class: 30Hz, and deliberately NOT distance-filtered — see NetInterest.FILTERED.
	# This also joins NetConfig.SYNCED_GROUP, which is why nothing here does (D-024).
	NetInterest.configure(net_sync, self, NetInterest.Class.PLAYER)
	add_child(net_sync)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		# Look input is routed through the controller rather than read by the camera directly, so
		# that authority gating lives in exactly one place.
		camera.apply_look((event as InputEventMouseMotion).relative)
		return

	# The swing starts locally on the press (own-action prediction) and the host resolves the hit —
	# see autoload/combat_service.gd. Nothing about damage is decided here.
	#
	# Resolved by path, never as the bare identifier `CombatService` (F-011). A `--script` main loop
	# compiles the scripts it depends on in the same pass, before autoloads are registered — and
	# `tools/verify_setup.gd` depends on this file through `PlayerController`. Naming the autoload
	# here took the whole harness down with "Identifier not found: CombatService".
	if event.is_action_pressed(&"attack") and gameplay_input_allowed() \
			and not _is_downed() and not _is_dead():
		var combat: Node = get_node_or_null(^"/root/CombatService")
		if combat != null:
			combat.call(&"request_attack")
		return

	# Temporary mouse release. Replaced by the pause menu in M7 — until then it is how you get your
	# cursor back without killing the process.
	if event.is_action_pressed(&"ui_cancel"):
		_capture_mouse(Input.mouse_mode != Input.MOUSE_MODE_CAPTURED)


## False while any cursor-owning UI holds the blocking group (D-032). Suppressing input without
## pausing the tree is deliberate: pausing a multiplayer client would stall networking.
func gameplay_input_allowed() -> bool:
	return get_tree().get_first_node_in_group(BLOCKING_UI_GROUP) == null


func _physics_process(delta: float) -> void:
	_tick_timers(delta)
	_apply_gravity(delta)
	_apply_horizontal_movement(delta)
	_try_jump()
	_tick_revive_hold(delta)

	# move_and_slide() zeroes vertical velocity on contact, so read the fall speed before it runs.
	var fall_speed: float = maxf(-velocity.y, 0.0)

	move_and_slide()

	_detect_landing(fall_speed)


func _tick_timers(delta: float) -> void:
	_time_since_grounded = 0.0 if is_on_floor() else _time_since_grounded + delta

	if Input.is_action_just_pressed(&"jump"):
		_time_since_jump_pressed = 0.0
	else:
		_time_since_jump_pressed += delta


func _apply_gravity(delta: float) -> void:
	if is_on_floor():
		# A small downward bias keeps us glued to slopes and stairs instead of skipping off them.
		velocity.y = minf(velocity.y, -0.1)
		return

	velocity.y -= _gravity * gravity_scale * delta

	# Variable jump height: cut once on release, not every frame — repeated multiplication would
	# kill upward velocity almost instantly.
	if velocity.y > 0.0 and Input.is_action_just_released(&"jump"):
		velocity.y *= jump_cut_multiplier

	velocity.y = maxf(velocity.y, -terminal_velocity)


func _apply_horizontal_movement(delta: float) -> void:
	# Cursor-owning UI suppresses gameplay input without pausing the simulation, and a dead player
	# (mid-respawn) gets no input at all — downed still allows the crawl. Pausing a multiplayer
	# client would stall networking and is not a valid UI boundary.
	var input_2d: Vector2 = Vector2.ZERO
	if gameplay_input_allowed() and not _is_dead():
		input_2d = Input.get_vector(
			&"move_left", &"move_right", &"move_forward", &"move_back"
		)
	# Body yaw defines the movement basis; the camera only pitches (see player_camera.gd).
	var wish_dir: Vector3 = (transform.basis * Vector3(input_2d.x, 0.0, input_2d.y)).normalized()

	var downed: bool = _is_downed()
	var wants_sprint: bool = not downed and Input.is_action_pressed(&"sprint") and wish_dir != Vector3.ZERO
	# Stamina is CLIENT-LOCAL (§2.2 row 1, task 3.8) — the owning body is the only thing that ticks
	# or gates its own bar, every physics frame, for zero-latency feedback. A harness with no
	# PlayerHealth (bare SceneTree, no autoloads) sprints freely rather than silently losing the verb.
	var health: Node = _health_node()
	var has_stamina: bool = health == null or bool(health.call(&"local_can_sprint"))
	var sprinting: bool = wants_sprint and has_stamina
	if health != null:
		health.call(&"local_tick_stamina", delta, sprinting)
	var move_speed: float = crawl_speed if downed else walk_speed
	var target: Vector3 = wish_dir * (sprint_speed if sprinting else move_speed)

	var rate: float
	if is_on_floor():
		rate = ground_acceleration if wish_dir != Vector3.ZERO else ground_friction
	else:
		rate = air_acceleration

	var horizontal: Vector3 = Vector3(velocity.x, 0.0, velocity.z)
	horizontal = horizontal.move_toward(target, rate * delta)

	velocity.x = horizontal.x
	velocity.z = horizontal.z

	camera.set_sprinting(sprinting and is_on_floor())


func _try_jump() -> void:
	if not gameplay_input_allowed() or _is_downed() or _is_dead():
		return
	var buffered: bool = _time_since_jump_pressed <= jump_buffer_time
	var grounded_recently: bool = _time_since_grounded <= coyote_time
	if not (buffered and grounded_recently):
		return
	# Stamina gates jump (task 3.8, same client-local row as sprint) — a harness with no PlayerHealth
	# jumps freely rather than losing the verb. The buffered press is NOT consumed on rejection, so a
	# player who regens enough stamina before jump_buffer_time expires still gets the jump they asked for.
	var health: Node = _health_node()
	if health != null and not bool(
		health.call(&"local_try_spend_stamina", health.call(&"local_jump_stamina_cost"))
	):
		return

	velocity.y = sqrt(2.0 * _gravity * gravity_scale * jump_height)

	# Consume both windows so one press can never produce two jumps.
	_time_since_jump_pressed = INF
	_time_since_grounded = INF

	jumped.emit()


func _detect_landing(fall_speed: float) -> void:
	var on_floor: bool = is_on_floor()
	if on_floor and not _was_on_floor:
		landed.emit(fall_speed)
	_was_on_floor = on_floor


func _capture_mouse(captured: bool) -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if captured else Input.MOUSE_MODE_VISIBLE


# ── Revive (task 2.13) ────────────────────────────────────────────────────────────────────────────


## Holding interact near a downed teammate revives them. The hold itself is client-local prediction —
## exactly one net_request_revive is sent, the instant the local timer reaches PlayerHealth's
## revive_seconds — and the host is what actually decides whether it counts (range, both states).
func _tick_revive_hold(delta: float) -> void:
	var health: Node = get_node_or_null(^"/root/PlayerHealth")
	if health == null or _is_downed() or _is_dead():
		_reset_revive_hold()
		return
	if not gameplay_input_allowed() or not Input.is_action_pressed(&"interact"):
		_reset_revive_hold()
		return

	var target_peer: int = _nearest_downed_teammate(health)
	if target_peer <= 0:
		_reset_revive_hold()
		return
	if target_peer != _revive_target_peer:
		_revive_target_peer = target_peer
		_revive_hold_elapsed = 0.0
		_revive_request_sent = false

	_revive_hold_elapsed += delta
	if _revive_request_sent:
		return
	if _revive_hold_elapsed >= float(health.get(&"revive_seconds")):
		_revive_request_sent = true
		health.call(&"request_revive", target_peer)


func _reset_revive_hold() -> void:
	_revive_target_peer = 0
	_revive_hold_elapsed = 0.0
	_revive_request_sent = false


## Nearest OTHER player PlayerHealth's broadcast flag says is downed, within revive_radius_m. Reads
## only replicated data — a client has no business knowing more about a peer it might not even see.
func _nearest_downed_teammate(health: Node) -> int:
	var radius: float = float(health.get(&"revive_radius_m"))
	var best: int = 0
	var best_distance: float = radius
	for node: Node in get_tree().get_nodes_in_group(&"players"):
		var other := node as Node3D
		if other == null or other == self:
			continue
		var peer_id: int = other.get_multiplayer_authority()
		if not bool(health.call(&"is_downed_known", peer_id)):
			continue
		var distance: float = global_position.distance_to(other.global_position)
		if distance > best_distance:
			continue
		best = peer_id
		best_distance = distance
	return best
