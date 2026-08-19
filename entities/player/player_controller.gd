class_name PlayerController
extends CharacterBody3D

## First-person ground movement: walk, sprint, jump, coyote time, jump buffering, dodge (task 3.8b),
## step-up over short lips and thresholds (F-136).
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
## Emitted the instant a dodge is accepted (stamina spent, dash committed). Client-local — audio/VFX
## only; nothing about damage is decided here. See _execute_dodge()'s own note.
signal dodged

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
## F-086: 3.6 shipped these two with no production caller. Same F-016 preload reasoning as the
## viewmodel above.
const BUILD_GHOST := preload("res://systems/building/build_ghost.gd")
const BUILD_BAR := preload("res://ui/building/build_bar.gd")

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

@export_group("Step")
## Maximum height of a lip, threshold or kerb the controller steps over automatically, metres
## (F-136). CharacterBody3D has no built-in step-up, so a capsule's flat vertical face otherwise reads
## any rise this tall or shorter as a wall. Chosen as roughly knee height on the 1.8 m capsule
## (`entities/player/player.tscn`'s CapsuleShape3D) — comfortably above the 60 mm door threshold and
## ~12 mm ramp-toe feather A-010 authors around this same limit (DECISIONS.md D-090), comfortably
## below `jump_height` (1.1 m) so a step never substitutes for a deliberate jump. Anything taller is a
## wall on purpose: `_apply_step_up()`'s forward probe from the raised height still collides with it,
## so raising this number is the one documented way to change what counts as "a step" project-wide.
@export_range(0.0, 1.0, 0.01) var step_height: float = 0.4

@export_group("Downed")
## Ground speed while downed. Far below walk_speed on purpose — DESIGN.md §4.5's "downed, not dead"
## is a crawl toward a teammate, not an escape; sprint and jump are blocked outright (see
## gameplay_input_allowed()'s callers below).
@export_range(0.1, 5.0, 0.05) var crawl_speed: float = 1.0

@export_group("Dodge")
## Discrete stamina cost of one dodge (task 3.8b), spent through the same PlayerHealth seam jump uses.
## DESIGN.md §6: stamina gates dodging, not attacking.
@export_range(0.0, 200.0, 1.0) var dodge_stamina_cost: float = 30.0
## Dash speed, metres per second, held constant for dodge_duration_sec — a committed impulse, not an
## accelerated target like walk/sprint (DESIGN.md §6's "you can't cancel a swing" chunkiness applies
## here too: once thrown, a dodge finishes on its own terms).
@export_range(1.0, 40.0, 0.5) var dodge_impulse: float = 10.0
## How long the dash MOVEMENT lasts. D-072 made this the i-frame window too; F-125/D-087 separated
## them, because `dodge_iframe_seconds` (Thin Step) has to lengthen invulnerability without
## lengthening the trip — its own description promises "untouchable for the whole of the trip rather
## than most of it", and feeding the stat in here would move where the player ends up. This is now
## the FLOOR of the i-frame window, never the whole of it: see `dodging`.
## Floor is well above NetConfig.PLAYER_SYNC_INTERVAL_SEC (30 Hz, ~0.033 s): `dodging` rides the
## player's existing REPLICATION_MODE_ALWAYS synchronizer (task 3.8b's spec names this seam
## explicitly), so a duration anywhere near one sync tick risks the host never observing the flag
## before it flips back to false.
@export_range(0.1, 1.0, 0.01) var dodge_duration_sec: float = 0.25
## Minimum time between dodges, counted from the moment one is accepted.
@export_range(0.1, 10.0, 0.1) var dodge_cooldown_sec: float = 1.2

## True for the I-FRAME window, which is `dodge_duration_sec` plus whatever `dodge_iframe_seconds`
## adds (Thin Step: +0.04 s a stack, +0.12 s at 3). Set by _execute_dodge(), cleared by _tick_dodge().
## Replicated ALWAYS on the same synchronizer as position/rotation (see _build_synchronizer()) so the
## HOST can read it before applying an enemy_attack_landed hit — systems/health/player_health.gd's
## _on_enemy_attack_landed() is the reader; the i-frame DECISION is the host's, this flag is only the
## client's own (trusted, same as position) presentation of intent.
##
## **It is no longer "a dash is in progress"** (D-072's original invariant, relaxed by F-125/D-087).
## The dash's MOVEMENT is `_dodge_time_remaining`, and that is what _apply_horizontal_movement()
## keys off; this flag outlives it by the powerup bonus. The name is kept because the host reads it
## by name across the wire and `systems/health/player_health.gd` is another task's file — but what it
## answers is "should a hit be ignored", which is what `_is_dodging()` was always really asking.
##
## The window can only ever GROW, never shrink below `dodge_duration_sec` (see _execute_dodge) —
## D-072's whole replication-reliability argument rests on that floor comfortably exceeding one sync
## tick, so a negative modifier must not be able to quietly undercut it.
var dodging: bool = false

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

## Dodge (task 3.8b) — see `dodging`'s own doc for the replication story. Direction is locked in at
## the moment the dash is accepted, not re-read from input each tick: a committed dash, same
## "wind-up -> commit -> recovery, can't cancel" philosophy DESIGN.md §6 states for melee.
var _dodge_velocity: Vector3 = Vector3.ZERO
## The dash MOVEMENT window. Drives _apply_horizontal_movement()'s dash branch.
var _dodge_time_remaining: float = 0.0
## The I-FRAME window (F-125). Always >= _dodge_time_remaining at the moment of the dash; the two are
## equal for a player holding no `dodge_iframe_seconds` powerup, which is the default and is why this
## changes nothing about a base dodge.
var _iframe_time_remaining: float = 0.0
var _dodge_cooldown_remaining: float = 0.0

## F-105: PlayerHealth is an autoload, so this reference outlives the whole session once resolved —
## caching it kills the ~6-8 `get_node_or_null(/root/PlayerHealth)` path lookups a single physics tick
## was otherwise making across _apply_horizontal_movement/_try_jump/_tick_revive_hold. Left null (not
## resolved once and trusted forever) so a harness that builds this node before PlayerHealth exists
## still finds it the moment it does.
var _health: Node = null

## Same story as `_health`, for the one call in _execute_dodge() that asks how long i-frames run
## (F-125). Resolved lazily rather than in _ready() for the same reason: a check scene may build the
## player before the autoload tree exists.
var _powerups: Node = null

## F-086: client-local building presentation, built only for the local player (see
## _build_building_presentation()). Neither ever decides anything — BuildService is the only
## authority (§2.2 world mutation row). "Build mode active" has no separate flag: it IS
## `_build_ghost.visible`, which BuildGhost.set_piece() already toggles, so there is exactly one
## place this can ever disagree with itself.
var _build_ghost: Node3D
var _build_bar: CanvasLayer


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
		_build_building_presentation()

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


## F-086: nothing before this attached a BuildGhost or gave a player any way to pick a piece.
## Built eagerly (like the viewmodel) rather than on the first "build" press, so BuildBar's slots
## exist the moment a check or a player looks for them; both start hidden until build mode is
## entered. BuildBar is NOT an autoload (see its own doc comment) — connecting its signal here is
## the whole wiring between "a slot was clicked" and "the ghost shows something new".
func _build_building_presentation() -> void:
	_build_ghost = BUILD_GHOST.new()
	_build_ghost.name = "BuildGhost"
	add_child(_build_ghost)

	_build_bar = BUILD_BAR.new()
	_build_bar.name = "BuildBar"
	add_child(_build_bar)
	_build_bar.connect(&"piece_selected", _on_build_piece_selected)


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
## started to be the noisier option. F-105: cached in `_health` once resolved rather than re-walking
## `/root` on every call — see that var's own comment.
func _health_node() -> Node:
	if not is_instance_valid(_health):
		_health = get_node_or_null(^"/root/PlayerHealth")
	return _health


## Same F-011-guarded, F-105-cached shape as _health_node(). PowerupService is an autoload, so the
## reference outlives the session once resolved; null is a legitimate answer in a bare check scene
## that boots the player without the full autoload tree, and every caller treats it as "no powerups".
func _powerup_service() -> Node:
	if not is_instance_valid(_powerups):
		_powerups = get_node_or_null(^"/root/PowerupService")
	return _powerups


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
## Replicates position, body yaw, camera pitch, and (task 3.8b) the `dodging` i-frame flag, and
## nothing else. Yaw is on the body and pitch is on the pivot (see player_camera.gd), so a remote
## player needs both to face the right way. Velocity is deliberately absent: if 1.6 needs it for
## interpolation, 1.6 adds it and pays for it.
##
## `dodging` is ALWAYS mode, not ON_CHANGE, on purpose: ON_CHANGE only sends when the value differs
## from the last value SENT, so a flag that flips true then false again between two checks (a dash
## shorter than the sync interval) can be missed entirely. ALWAYS resends the current value on every
## tick regardless, so as long as dodge_duration_sec comfortably exceeds one sync interval (see that
## export's own note), at least one send lands inside the window.
func _build_synchronizer() -> void:
	var config: SceneReplicationConfig = SceneReplicationConfig.new()
	for property: NodePath in [
		^".:position", ^".:rotation:y", ^"CameraPivot:rotation:x", ^".:dodging"
	]:
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

	# F-086: the existing "build" action (3.6) toggles the mode; is_build_mode_active() reads
	# _build_ghost.visible directly, so there is nothing else to keep in sync here.
	if event.is_action_pressed(&"build") and gameplay_input_allowed() \
			and not _is_downed() and not _is_dead():
		toggle_build_mode()
		get_viewport().set_input_as_handled()
		return

	# Rotate/destroy (task 7.6: promoted from raw key/mouse-button reads to real InputMap actions,
	# each keyboard/mouse-PLUS-gamepad-bound — see project.godot's own "build_rotate"/"build_destroy"
	# entries) only ever mean anything while a piece is being previewed, so both branches fall through
	# to the rest of this function on any other input rather than swallowing it.
	if is_build_mode_active() and event.is_action_pressed(&"build_rotate") \
			and gameplay_input_allowed():
		_build_ghost.call(&"rotate_step", 1)
		get_viewport().set_input_as_handled()
		return
	if is_build_mode_active() and event.is_action_pressed(&"build_destroy") \
			and gameplay_input_allowed():
		_request_build_destroy()
		get_viewport().set_input_as_handled()
		return

	# Dodge (task 3.8b): a discrete press, not a held/buffered action like jump — the dash either
	# commits now or it doesn't, so there is nothing to buffer. gameplay_input_allowed() gates it the
	# same as attack/build; downed/dead block it the same way jump and sprint already are (crawl_speed
	# leaves no dash to spend, and a dead player is mid-respawn with no body to move at all).
	if event.is_action_pressed(&"dodge") and gameplay_input_allowed() \
			and not _is_downed() and not _is_dead():
		_execute_dodge()
		get_viewport().set_input_as_handled()
		return

	# The swing starts locally on the press (own-action prediction) and the host resolves the hit —
	# see autoload/combat_service.gd. Nothing about damage is decided here.
	#
	# Resolved by path, never as the bare identifier `CombatService` (F-011). A `--script` main loop
	# compiles the scripts it depends on in the same pass, before autoloads are registered — and
	# `tools/verify_setup.gd` depends on this file through `PlayerController`. Naming the autoload
	# here took the whole harness down with "Identifier not found: CombatService".
	#
	# F-086: while building, the SAME press confirms placement instead of swinging — checked first,
	# in this one function, so the two can never both react to a single click regardless of node
	# traversal order. set_input_as_handled() is new for this branch only, to also stop
	# autoload/harvest_world.gd's own independent "attack" listener from reading a placement click as
	# a harvest attempt; whether that actually reaches it before this handler runs is untested here —
	# see F-101.
	if event.is_action_pressed(&"attack") and gameplay_input_allowed() \
			and not _is_downed() and not _is_dead():
		if is_build_mode_active():
			_build_ghost.call(&"confirm")
			get_viewport().set_input_as_handled()
		else:
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
	# F-105: downed/dead/input-allowed do not change mid-tick — _apply_horizontal_movement,
	# _try_jump and _tick_revive_hold were each re-deriving all three independently, which meant a
	# group scan (gameplay_input_allowed) up to 3x and a PlayerHealth round trip (_is_downed/_is_dead)
	# up to 3x, every physics frame, for an answer that cannot have changed since the first call.
	# Resolved once here and threaded through instead.
	var input_allowed: bool = gameplay_input_allowed()
	var downed: bool = _is_downed()
	var dead: bool = _is_dead()

	# Gamepad look (task 7.6): a held analog value sampled every tick, unlike mouse look's one-shot
	# InputEventMouseMotion in _unhandled_input — see PlayerCamera.apply_look_gamepad()'s own note.
	# Applied before movement reads transform.basis below so a stick turn and the move it causes land
	# in the same tick, the way a mouse turn already does relative to whichever tick move runs in.
	camera.apply_look_gamepad(delta, input_allowed)

	_tick_timers(delta)
	_tick_dodge(delta)
	_apply_gravity(delta)
	_apply_horizontal_movement(delta, input_allowed, downed, dead)
	_try_jump(input_allowed, downed, dead)
	_tick_revive_hold(delta, input_allowed, downed, dead)
	_tick_build_ghost(delta, downed, dead)
	_apply_step_up(delta)

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


func _apply_horizontal_movement(
		delta: float, input_allowed: bool, downed: bool, dead: bool) -> void:
	# Dodge overrides normal locomotion outright for its whole window: a committed dash at a constant
	# speed, not an accelerated target move_toward chases (same reasoning as jump's velocity.y — set
	# once, not steered). Stamina still ticks (never sprinting mid-dash) so the bar keeps regenerating
	# through the dash instead of freezing for its short duration.
	# `_dodge_time_remaining`, NOT `dodging` (F-125): the flag now outlives the dash by whatever
	# `dodge_iframe_seconds` adds, and reading it here would keep applying the dash velocity through
	# that tail — turning an i-frame powerup into a longer dash, which is the exact thing F-125 said
	# makes it "a different powerup from the one the description promises".
	if _dodge_time_remaining > 0.0:
		var health: Node = _health_node()
		if health != null:
			health.call(&"local_tick_stamina", delta, false)
		velocity.x = _dodge_velocity.x
		velocity.z = _dodge_velocity.z
		camera.set_sprinting(false)
		return

	# Cursor-owning UI suppresses gameplay input without pausing the simulation, and a dead player
	# (mid-respawn) gets no input at all — downed still allows the crawl. Pausing a multiplayer
	# client would stall networking and is not a valid UI boundary.
	var input_2d: Vector2 = Vector2.ZERO
	if input_allowed and not dead:
		input_2d = Input.get_vector(
			&"move_left", &"move_right", &"move_forward", &"move_back"
		)
	# Body yaw defines the movement basis; the camera only pitches (see player_camera.gd).
	var wish_dir: Vector3 = (transform.basis * Vector3(input_2d.x, 0.0, input_2d.y)).normalized()

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


func _try_jump(input_allowed: bool, downed: bool, dead: bool) -> void:
	if not input_allowed or downed or dead:
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


## Probes this tick's horizontal motion for a lip no taller than `step_height` and, if that is all
## that is blocking it, teleports the body up and over it before move_and_slide() runs — the same
## tick, so the rest of the frame (sliding, floor snap) proceeds as if the lip were never there.
## Godot's CharacterBody3D has no step-up of its own (F-136).
## Grounded-only on purpose: an airborne player clipping a ledge should bonk it, not auto-mantle.
##
## The forward-then-down settle is ONE combined diagonal `test_move()`, not two separate axis-aligned
## ones. A real player's per-tick `motion` is small next to `radius` (a 4 m/s walk is ~0.067 m per
## physics tick against a 0.4 m capsule radius), so a separate horizontal advance almost never clears
## the capsule's own radius past the lip's corner — the landing probe then finds it still overlapping
## the riser, and move_and_slide() spends the next tick fighting that self-intersection back out,
## which reads as the player bouncing in place at the lip instead of climbing it (caught empirically
## with tools/step_up_check.gd during F-136; a plain rise→forward→fall sequence stalled at the seam
## on every low-lip case). Sweeping `motion + Vector3(0, -step_height, 0)` in a single test_move()
## lets Godot's own shape sweep — which already accounts for the whole capsule, not its centre point —
## find the true first contact, so `travel` can never leave the capsule embedded in the step.
func _apply_step_up(delta: float) -> void:
	if not is_on_floor():
		return
	var motion: Vector3 = Vector3(velocity.x, 0.0, velocity.z) * delta
	if motion.length_squared() < 0.0001:
		return

	# 1. If flat forward motion is already clear, there is no lip to step over — leave move_and_slide
	# to handle the frame exactly as it always has.
	if not test_move(global_transform, motion):
		return

	# 2. Is there room to rise step_height with nothing overhead? A low doorway or ceiling must still
	# refuse the player rather than have this probe shove them into it.
	var raised: Transform3D = global_transform
	if test_move(raised, Vector3(0.0, step_height, 0.0)):
		return
	raised.origin.y += step_height

	# 3. From the raised height, sweep forward AND down together and take the point of first contact.
	# An ordinary wall taller than step_height still blocks the forward component of this same sweep,
	# so it is refused here exactly as step 2's plain rise would refuse a ceiling.
	var landing: KinematicCollision3D = KinematicCollision3D.new()
	var settle: Vector3 = motion + Vector3(0.0, -step_height, 0.0)
	var travel: Vector3 = landing.get_travel() if test_move(raised, settle, landing) else settle

	# The sweep found nothing within reach (fell the full probe depth without contact) — a step this
	# tall would be a gap or an actual wall, not a lip, so leave move_and_slide to resolve the frame
	# normally rather than depositing the player onto whatever is far below.
	if travel.y <= -step_height + 0.02:
		return

	global_position = raised.origin + travel


# ── Dodge (task 3.8b) ─────────────────────────────────────────────────────────────────────────────
# Client-auth own movement (ARCHITECTURE.md §2.2 row 1): the dash itself is decided and simulated
# entirely here, same as walk/sprint/jump. The i-frame CONSEQUENCE is the host's call — see
# systems/health/player_health.gd's _on_enemy_attack_landed(), which reads the `dodging` flag this
# replicates before ever applying an enemy hit.


## The dodge verb itself, deliberately a standalone function and not inlined into the input handler —
## DESIGN.md §4.4 (Void Resonance's "dodge blinks") wraps or replaces this exact call later; keeping
## it a function with no input-event dependency is what makes that a wrap instead of a rewrite. Its
## own downed/dead/cooldown/stamina guards are repeated here rather than trusted to whatever calls it
## (_unhandled_input already checks downed/dead too, redundantly) — a future caller that is not the
## input handler (a powerup, a command) must not be able to skip them by calling this directly.
## Returns false and changes nothing on cooldown or without enough stamina — same "the action just
## does not happen" contract as _try_jump()'s local_try_spend_stamina() check.
func _execute_dodge() -> bool:
	if dodging or _dodge_cooldown_remaining > 0.0 or _is_downed() or _is_dead():
		return false
	var health: Node = _health_node()
	if health != null and not bool(
		health.call(&"local_try_spend_stamina", dodge_stamina_cost)
	):
		return false

	var input_2d: Vector2 = Input.get_vector(
		&"move_left", &"move_right", &"move_forward", &"move_back"
	)
	var dash_dir: Vector3 = transform.basis * Vector3(input_2d.x, 0.0, input_2d.y)
	if dash_dir.length_squared() < 0.0001:
		# No movement input held: dodge in the direction the player is facing rather than refusing —
		# a "dodge in place" that does nothing would be a wasted stamina cost with no feedback.
		dash_dir = -transform.basis.z
	dash_dir = dash_dir.normalized()

	_dodge_velocity = dash_dir * dodge_impulse
	_dodge_time_remaining = dodge_duration_sec
	# The i-frame window is the dash window extended by `dodge_iframe_seconds` (F-125/D-087), asked of
	# PowerupService for THIS peer: dodging is client-authoritative movement (ARCHITECTURE §2.2
	# row 1) and a client is only sent its own powerup map, so local_stat() is the honest seam — on
	# a peer holding nothing it returns the base, i.e. exactly the old behaviour.
	# maxf() with the dash window is not defensive tidiness: D-072's replication guarantee is that
	# the flag is true for comfortably longer than one PLAYER_SYNC_INTERVAL_SEC, and a negative
	# modifier that shortened this below `dodge_duration_sec` would silently undercut that floor
	# rather than "balance" anything. A powerup that wants a SHORTER dodge changes the dash.
	var iframe_bonus: float = 0.0
	var powerups: Node = _powerup_service()
	if powerups != null:
		iframe_bonus = float(powerups.call(&"local_stat", &"dodge_iframe_seconds", 0.0))
	_iframe_time_remaining = maxf(dodge_duration_sec + iframe_bonus, dodge_duration_sec)
	_dodge_cooldown_remaining = dodge_cooldown_sec
	dodging = true
	dodged.emit()
	return true


## Counts the cooldown down unconditionally and, while dodging, counts BOTH dodge windows down: the
## dash's movement window and the i-frame window that outlasts it (F-125). `dodging` clears with the
## i-frame window, which is the later of the two. Runs every physics tick regardless of
## input/downed/dead state so a dash started the instant before a stun/UI-block still finishes and
## releases control normally rather than latching `dodging` true forever.
func _tick_dodge(delta: float) -> void:
	if _dodge_cooldown_remaining > 0.0:
		_dodge_cooldown_remaining = maxf(_dodge_cooldown_remaining - delta, 0.0)
	if not dodging:
		return
	_dodge_time_remaining = maxf(_dodge_time_remaining - delta, 0.0)
	_iframe_time_remaining -= delta
	if _iframe_time_remaining <= 0.0:
		dodging = false
		_iframe_time_remaining = 0.0
		_dodge_time_remaining = 0.0


func _detect_landing(fall_speed: float) -> void:
	var on_floor: bool = is_on_floor()
	if on_floor and not _was_on_floor:
		landed.emit(fall_speed)
	_was_on_floor = on_floor


func _capture_mouse(captured: bool) -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if captured else Input.MOUSE_MODE_VISIBLE


# ── Building (F-086) ──────────────────────────────────────────────────────────────────────────────


func is_build_mode_active() -> bool:
	return _build_ghost != null and _build_ghost.visible


## The "build" action's whole handler. A bare toggle-on with nothing already selected auto-picks the
## first registered piece (Registry iteration order — deterministic but not meaningfully orderable
## beyond that, same caveat CraftingService.nearby_station_id() documents for its own tie-break) so
## the ghost is visible immediately; BuildBar is how a player then picks something else.
func toggle_build_mode() -> void:
	if _build_ghost == null:
		return
	if is_build_mode_active():
		_build_ghost.call(&"set_piece", &"")
		if _build_bar != null:
			_build_bar.call(&"set_active", false)
		return
	var piece_id: StringName = StringName(_build_ghost.call(&"current_piece_id"))
	if piece_id == &"":
		piece_id = _first_registered_piece()
	if piece_id != &"":
		set_selected_build_piece(piece_id)


## Called both by BuildBar's own slot click (via the piece_selected signal) and by toggle_build_mode()
## entering the mode fresh — either path ends here, so the ghost and the bar can never show two
## different pieces. Selecting successfully counts as entering build mode; it is the only way in
## besides the raw toggle.
func set_selected_build_piece(piece_id: StringName) -> bool:
	if _build_ghost == null or not bool(_build_ghost.call(&"set_piece", piece_id)):
		return false
	if _build_bar != null:
		_build_bar.call(&"set_active", true)
		_build_bar.call(&"set_selected_piece", piece_id)
	return true


func _first_registered_piece() -> StringName:
	var registry: Node = get_node_or_null(^"/root/Registry")
	if registry == null:
		return &""
	var buildables: Dictionary = registry.get(&"buildables")
	for id: StringName in buildables:
		return id
	return &""


func _on_build_piece_selected(piece_id: StringName) -> void:
	set_selected_build_piece(piece_id)


## Every physics tick while building: re-aims the ghost from the real camera (mirrors update_aim()'s
## own doc comment — from/direction is the aim ray, builder_position is this body, for the range
## rule) and pushes the resulting verdict into BuildBar. Also the downed/dead exit — a player who goes
## down mid-build should not keep previewing a piece they cannot currently place (jump/sprint are
## gated the same way elsewhere in this file).
func _tick_build_ghost(delta: float, downed: bool, dead: bool) -> void:
	if _build_ghost == null:
		return
	if is_build_mode_active() and (downed or dead):
		toggle_build_mode()
		return
	if not is_build_mode_active():
		return
	var camera_3d: Camera3D = camera.get_node_or_null(^"Camera3D") as Camera3D
	if camera_3d == null:
		return
	_build_ghost.call(&"update_aim",
		camera_3d.global_position, -camera_3d.global_basis.z, global_position, delta)
	if _build_bar != null:
		_build_bar.call(&"set_ghost_status",
			bool(_build_ghost.call(&"is_valid")), String(_build_ghost.call(&"last_reason_text")))


## Right-click while building: a SECOND ray, independent of whichever piece is selected to place —
## see BuildGhost.aim_destroy_target()'s own comment for why placement preview and teardown targeting
## cannot share one ray. request_destroy() is fire-and-forget from here; BuildService.build_confirmed
## is how BuildBar learns whether it landed.
func _request_build_destroy() -> void:
	if _build_ghost == null:
		return
	var camera_3d: Camera3D = camera.get_node_or_null(^"Camera3D") as Camera3D
	if camera_3d == null:
		return
	var piece_name: StringName = StringName(_build_ghost.call(
		&"aim_destroy_target", camera_3d.global_position, -camera_3d.global_basis.z))
	if piece_name == &"":
		return
	var service: Node = get_node_or_null(^"/root/BuildService")
	if service != null:
		service.call(&"request_destroy", piece_name)


# ── Revive (task 2.13) ────────────────────────────────────────────────────────────────────────────


## Holding interact near a downed teammate revives them. The hold itself is client-local prediction —
## exactly one net_request_revive is sent, the instant the local timer reaches PlayerHealth's
## revive_seconds — and the host is what actually decides whether it counts (range, both states).
func _tick_revive_hold(delta: float, input_allowed: bool, downed: bool, dead: bool) -> void:
	var health: Node = _health_node()
	if health == null or downed or dead:
		_reset_revive_hold()
		return
	if not input_allowed or not Input.is_action_pressed(&"interact"):
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
