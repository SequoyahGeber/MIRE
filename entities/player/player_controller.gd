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
## The group both world scripts publish themselves or their terrain into — how `_water_source_node()`
## finds whichever map is loaded without preloading either map script (F-375). Restated as a literal
## rather than reached through `ProceduralWorld.TERRAIN_GROUP` on purpose: both world scripts already
## keep their own copy (`world/gen/procedural_world.gd:40`, `world/gen/authored_world.gd:36`), and a
## `const` reference to one of them would make the player controller — which every check scene builds
## — drag a whole world generator into its compile.
const TERRAIN_GROUP: StringName = &"authored_world_terrain"
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

## F-543: the live speeds movement actually uses — `walk_speed`/`sprint_speed` after
## PowerupService's `move_speed`/`sprint_speed` modifiers (docs/POWERUPS.md §2). Own movement is
## client-authoritative (ARCHITECTURE §2.2 row 1) and a client is only sent its OWN powerup map, so
## `local_stat()` is the honest seam here, exactly as `dodge_iframe_seconds` already uses.
##
## Cached rather than asked per tick: `stat()` walks every held powerup's modifier dictionary, and
## this is the one consumer that would run it twice a physics frame forever. `local_powerups_changed`
## is the only thing that can change the answer, so recomputing there is exact, not an approximation.
## `maxf(..., MIN_EFFECTIVE_SPEED_MPS)` keeps a stacked negative multiplier from producing a zero or
## reversed walk — a powerup that wants you immobile is a status effect, not a speed number.
var _effective_walk_speed: float = 0.0
var _effective_sprint_speed: float = 0.0

## F-580: the same two speeds under every combination of the two movement conditions
## docs/POWERUPS.md §2 authorises (`move_speed_low_hp`, `move_speed_in_mire`). Indexed by
## `CONDITION_LOW_HP | CONDITION_IN_MIRE`, so index 0 is the unconditional pair and index 3 is both
## chained. Precomputed for the same reason the unconditional pair is: `stat()` walks every held
## powerup's modifier dictionary, and this is read twice a physics frame.
##
## D-179 is why the CONDITION lives here and not in PowerupService: the service stays condition-blind
## and the consumer that already owns the fact (this controller knows its own hp and its own
## position) evaluates it.
var _conditional_walk_speed: PackedFloat32Array = PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
var _conditional_sprint_speed: PackedFloat32Array = PackedFloat32Array([0.0, 0.0, 0.0, 0.0])

const CONDITION_LOW_HP: int = 1
const CONDITION_IN_MIRE: int = 2

## docs/POWERUPS.md §2: the `_low_hp` suffix means "health below a third".
const LOW_HP_FRACTION: float = 1.0 / 3.0

## The Mire condition is a world-grid query, not a local field, so it is sampled on a timer rather
## than every physics tick — the grid answers a cell at a time out of WorldDeltaLog on a client
## (mire_grid.gd's own note), and a player cannot cross a corruption boundary meaningfully faster
## than this.
const MIRE_SAMPLE_INTERVAL_SEC: float = 0.25
var _time_since_mire_sample: float = INF
var _in_mire: bool = false

## F-580: `jump_height` and `air_acceleration` after their powerup stats, recomputed on the same
## signal as the speeds. `_extra_jumps` is the flat count `extra_jumps` grants (docs/POWERUPS.md §2,
## "additional mid-air jumps"); `_air_jumps_used` counts them down between groundings.
var _effective_jump_height: float = 0.0
var _effective_air_acceleration: float = 0.0
var _extra_jumps: int = 0
var _air_jumps_used: int = 0

## Floor for any modified speed. Slow enough to be a real penalty, fast enough that the player is
## never stuck in place with no way to know why.
const MIN_EFFECTIVE_SPEED_MPS: float = 0.5

## F-580's equivalent floor for the jump. Low enough to be a real penalty, high enough that the
## player can still clear `step_height` and is never trapped by a stacked negative modifier.
const MIN_EFFECTIVE_JUMP_HEIGHT_M: float = 0.45

@export_group("God Mode Flight")
## Playtesting flight speed while GodModeService has approved this peer. Flight stays in the own-
## player-movement authority row: this controller is the only process that moves its body.
@export_range(1.0, 50.0, 0.5) var god_flight_speed: float = 12.0
## Sprint is a traversal accelerator in God mode rather than a stamina cost.
@export_range(1.0, 5.0, 0.1) var god_flight_sprint_multiplier: float = 2.0
## Acceleration/deceleration in every axis. High enough for precise playtest positioning without an
## instantaneous velocity snap when God mode is toggled in mid-air.
@export_range(1.0, 200.0, 1.0) var god_flight_acceleration: float = 48.0

@export_group("Wade")
## F-375: how deep the water has to be over the feet before it costs any speed, metres. Sequoyah,
## from play: "the water should slow player movement down slightly".
##
## Not 0.0 on purpose. The shoreline is where the seabed crosses the waterline, so a player walking
## the beach sits within millimetres of zero depth for a long stretch — a threshold at exactly the
## surface would have the multiplier chattering on and off every tick along the whole coast, which
## is a visible speed stutter for no gameplay reason. 0.25 m is roughly ankle-deep on the 1.8 m
## capsule: splashing through the shallows is free, which is also what it looks like.
@export_range(0.0, 2.0, 0.01) var wade_shallow_depth: float = 0.25
## Foot-depth at which the slowdown reaches its floor and stops deepening, metres. Two thirds of the
## capsule (`entities/player/player.tscn`'s CapsuleShape3D is 1.8 m) — chest deep. Past this the
## honest answer is swimming, which MIRE does not have; the multiplier simply holds rather than
## pretending a 5 m-deep ocean floor (`IslandHeightmap.OCEAN_FLOOR_DEPTH`) is walkable at a crawl.
@export_range(0.1, 3.0, 0.01) var wade_deep_depth: float = 1.2
## Speed multiplier at `wade_deep_depth` and beyond. 0.55 makes a chest-deep SPRINT (6.0 -> 3.3 m/s)
## slower than a dry WALK (4.0 m/s), which is the one property that matters: deep water must not be
## a fast route. Knee-deep (~0.5 m) lands near x0.88 and waist-deep (~0.9 m) near x0.69, which is
## the "slightly" the report asked for over the depths a player actually spends time in.
@export_range(0.1, 1.0, 0.01) var wade_min_speed_scale: float = 0.55

@export_group("Acceleration")
## How fast we reach target speed on the ground. Higher = snappier, more arcade.
@export_range(1.0, 200.0, 1.0) var ground_acceleration: float = 60.0
## How fast we stop on the ground with no input. Higher = less slide.
## F-404: 26, down from 50.
##
## At 50 a 4 m/s walk stopped dead in 0.08 s — not friction, a wall. Reported as "the ground friction
## is higher while walking". 26 gives roughly 0.15 s to a standstill, which reads as weight rather
## than as ice or as a brick.
@export_range(1.0, 200.0, 1.0) var ground_friction: float = 26.0
## Steering authority in the air. Low values make jumps feel committed.
@export_range(0.0, 100.0, 1.0) var air_acceleration: float = 14.0
## F-404: how far above `sprint_speed` airborne momentum may reach. Above 1.0 so a player who jumps
## while sprinting downhill keeps what they had; low enough that air-strafing cannot be stacked into
## a movement tech faster than running.
const AIR_SPEED_CEILING_FACTOR: float = 1.35

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
## F-404: 18, down from 60.
##
## Reported from play: "it feels fine if you're just jumping from the ground, but if you jump off of
## something, you go really fast into the ground." The obvious lever looks like `gravity_scale`, and
## it is the wrong one — `_try_jump()` derives launch speed as `sqrt(2 * g * gravity_scale *
## jump_height)`, so lowering gravity keeps the apex exactly at `jump_height` but stretches the whole
## arc, making the STANDING jump floatier. That is the one part he said already feels right.
##
## A fall cap is surgical instead: it can only ever engage on a fall long enough to reach it. At
## `gravity_scale` 2.0 that is about 8 m of drop, so every ordinary hop and every kerb is untouched
## and only the "jumped off something" case changes. 60 m/s was high enough that nothing a player
## survives ever reached it, which is why it read as no cap at all.
@export_range(5.0, 200.0, 1.0) var terminal_velocity: float = 18.0

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
## F-405: how long an accepted step may keep stepping after the body leaves the floor. Long enough to
## cross a lip at walking pace (a few ticks), far too short to read as flight — and only ever set by
## an accepted step, never by falling.
const STEP_CONTINUE_GRACE_SEC: float = 0.12

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

## F-542: selected hotbar identity published by the owning player for third-person presentation.
## This is not inventory authority: it grants nothing and remote peers only use it to choose an
## ItemDef.world_model. It rides the same owner-authoritative synchronizer as look and movement.
var replicated_held_item_id: StringName = &""

## Set false on remote copies of this player so they are driven by replication only.
var is_local_authority: bool = true

@onready var camera: PlayerCamera = $CameraPivot

## Built in _ready(), never authored in the scene (D-023). Replicates the minimum that makes a
## remote player look right; 1.6 owns smoothing what arrives through it.
var net_sync: MultiplayerSynchronizer

var _gravity: float = 9.8
var _time_since_grounded: float = INF
## F-405: counts down after an accepted step, letting the next tick finish a climb already begun.
## Only ever set by an accepted step, so it cannot become a general "step up while falling".
var _step_grace: float = 0.0
var _time_since_jump_pressed: float = INF
var _was_on_floor: bool = true
## F-520: set when the mouse capture this body wanted at spawn had to be refused because a
## cursor-owning UI was open. Taken on the first physics tick after that UI closes.
var _capture_deferred: bool = false

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

## F-375: how far this tick's water surface sits above the FEET, metres; 0.0 on dry land and on any
## map that cannot say where its water is. Sampled once per physics tick by `_tick_wade()` and read
## by `wade_speed_scale()`, rather than re-derived at each use, so every consumer in a tick agrees
## about one depth — the same reason `_physics_process` resolves downed/dead/input_allowed once.
## Public because it is the only "am I in the water" answer in the codebase and the next thing that
## wants one (splash audio, a wet-screen overlay, a swim state) should read it rather than sample
## `water_surface_at()` a second time and drift.
var wade_depth: float = 0.0

## The node that answers `water_surface_at()` for the map currently loaded — `ProceduralWorld` (which
## is the level root) or `AuthoredWorld` (the level's "World" child). Cached, same F-105 reasoning as
## `_health` below: this is resolved from a group scan plus two `get_node_or_null` walks, and a
## physics tick should pay for that once per map, not 60 times a second. Left null rather than
## resolved-once-and-trusted so a harness that builds the player before the world exists still finds
## it the moment it does, and so a world freed by a map change is re-resolved instead of leaking.
var _water_source: Node = null

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

## Same lazy autoload-cache shape as `_health`/`_powerups`. A bare controller harness may not load
## GodModeService; that means ordinary movement, never an error or accidental flight.
var _god_mode: Node = null

## F-086: client-local building presentation, built only for the local player (see
## _build_building_presentation()). Neither ever decides anything — BuildService is the only
## authority (§2.2 world mutation row). "Build mode active" has no separate flag: it IS
## `_build_ghost.visible`, which BuildGhost.set_piece() already toggles, so there is exactly one
## place this can ever disagree with itself.
var _build_ghost: Node3D
var _build_bar: CanvasLayer
var _remote_hand: Node3D
var _remote_held_instance: Node3D
var _presented_remote_item_id: StringName = &""
var _inventory_service: Node
var _inventory_ui: Node
var _registry: Node


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

	# F-543. Seeded unconditionally (a remote body never reads them, but a harness that flips
	# is_local_authority later must not find zeroes) and kept live for the owner only.
	_refresh_effective_speeds()
	if is_local_authority:
		var powerups: Node = _powerup_service()
		if powerups != null and powerups.has_signal(&"local_powerups_changed"):
			powerups.connect(&"local_powerups_changed", _on_local_powerups_changed)

	camera.set_active(is_local_authority)
	set_physics_process(is_local_authority)
	set_process_unhandled_input(is_local_authority)

	if is_local_authority:
		# F-520: NOT unconditionally. A body can legitimately be built while a cursor-owning UI is up
		# — a lobby opened from the expedition dock brings the session up in the FRONT END — and
		# capturing there hides the cursor behind a menu the player is still clicking on, which reads
		# as the game having frozen. Whoever holds the blocking group keeps the cursor; the capture
		# happens on the first frame after they let go (see `_physics_process`).
		if gameplay_input_allowed():
			_capture_mouse(true)
		else:
			_capture_deferred = true


func _process(_delta: float) -> void:
	if is_local_authority:
		replicated_held_item_id = _local_selected_item_id()
	else:
		_refresh_remote_held_item()


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
	_build_bar.connect(&"placement_aim_requested", _on_build_placement_aim_requested)


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

	# A separate socket keeps third-person presentation out of the first-person camera/viewmodel.
	# It follows body yaw and sits at the proxy's right hand until a real character rig replaces the
	# debug capsule. The world model is intentionally static; F-542 is visibility, not an animation
	# pipeline.
	_remote_hand = Node3D.new()
	_remote_hand.name = "RemoteHand"
	_remote_hand.position = Vector3(0.48, 1.05, -0.18)
	_remote_hand.rotation_degrees = Vector3(-18.0, 0.0, -12.0)
	_remote_hand.visible = not is_local_authority
	add_child(_remote_hand)


func _local_selected_item_id() -> StringName:
	if not is_instance_valid(_inventory_service):
		_inventory_service = get_node_or_null(^"/root/InventoryService")
	if not is_instance_valid(_inventory_ui):
		_inventory_ui = get_node_or_null(^"/root/InventoryUI")
	if _inventory_service == null or _inventory_ui == null:
		return &""
	var hotbar_index: int = int(_inventory_ui.call(&"selected_hotbar_slot"))
	return StringName(_inventory_service.call(&"local_item_id", 24 + hotbar_index))


func _refresh_remote_held_item() -> void:
	if _remote_hand == null or replicated_held_item_id == _presented_remote_item_id:
		return
	_presented_remote_item_id = replicated_held_item_id
	if _remote_held_instance != null:
		_remote_held_instance.queue_free()
		_remote_held_instance = null
	if replicated_held_item_id == &"":
		return
	if not is_instance_valid(_registry):
		_registry = get_node_or_null(^"/root/Registry")
	if _registry == null:
		return
	var item: ItemDef = _registry.call(&"get_item", replicated_held_item_id)
	if item == null or item.world_model == null:
		return
	_remote_held_instance = item.world_model.instantiate() as Node3D
	if _remote_held_instance == null:
		return
	_remote_held_instance.name = "RemoteHeldItem"
	_remote_hand.add_child(_remote_held_instance)


func remote_held_instance() -> Node3D:
	return _remote_held_instance


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


## F-543: recompute the two live speeds from the authored exports. Called at _ready and on every
## change to this peer's own powerup stacks — an Attunement pick (DESIGN §4.5's Warden is `-10%`
## move_speed) arrives through exactly that signal, since `AttunementService` grants its backing
## PowerupDef through `PowerupService.host_grant()`.
##
## `sprint_speed` is routed through BOTH stats, in that order: docs/POWERUPS.md §2 defines
## `sprint_speed` as "sprint speed, applied after move_speed", so a generic movement modifier moves
## the sprint too and a sprint-only powerup stacks on top of it.
func _refresh_effective_speeds() -> void:
	var powerups: Node = _powerup_service()
	if powerups == null:
		_effective_walk_speed = walk_speed
		_effective_sprint_speed = sprint_speed
		_effective_jump_height = jump_height
		_effective_air_acceleration = air_acceleration
		_extra_jumps = 0
		for condition: int in 4:
			_conditional_walk_speed[condition] = walk_speed
			_conditional_sprint_speed[condition] = sprint_speed
		return
	_effective_walk_speed = maxf(
		float(powerups.call(&"local_stat", &"move_speed", walk_speed)), MIN_EFFECTIVE_SPEED_MPS
	)
	var sprint_after_move: float = float(powerups.call(&"local_stat", &"move_speed", sprint_speed))
	_effective_sprint_speed = maxf(
		float(powerups.call(&"local_stat", &"sprint_speed", sprint_after_move)),
		_effective_walk_speed
	)

	# F-580. Each condition chains onto the unconditional result, exactly as docs/POWERUPS.md §2's
	# worked example does, and the two chain onto each other when both hold — a player who is both
	# hurt and standing in the Mire gets both, which is the only reading that does not make one
	# powerup silently cancel the other.
	for condition: int in 4:
		var walk: float = _effective_walk_speed
		var sprint: float = _effective_sprint_speed
		if condition & CONDITION_LOW_HP:
			walk = float(powerups.call(&"local_stat", &"move_speed_low_hp", walk))
			sprint = float(powerups.call(&"local_stat", &"move_speed_low_hp", sprint))
		if condition & CONDITION_IN_MIRE:
			walk = float(powerups.call(&"local_stat", &"move_speed_in_mire", walk))
			sprint = float(powerups.call(&"local_stat", &"move_speed_in_mire", sprint))
		_conditional_walk_speed[condition] = maxf(walk, MIN_EFFECTIVE_SPEED_MPS)
		_conditional_sprint_speed[condition] = maxf(sprint, _conditional_walk_speed[condition])

	# F-580: jump apex, air steering authority and the mid-air jump allowance. `jump_height` is
	# floored well above zero — a jump that launches at 0 m/s is not a nerfed jump, it is a lost
	# verb — and `air_control` cannot go negative, which would invert steering rather than remove it.
	_effective_jump_height = maxf(
		float(powerups.call(&"local_stat", &"jump_height", jump_height)), MIN_EFFECTIVE_JUMP_HEIGHT_M
	)
	_effective_air_acceleration = maxf(
		float(powerups.call(&"local_stat", &"air_control", air_acceleration)), 0.0
	)
	# Asked on a base of 0.0: `extra_jumps` is authored flat (skip_step is Vector2(1, 0)), so the
	# service's `(0 + 1*N) * (1 + 0)` is exactly "N extra jumps" and a peer holding none gets 0.
	_extra_jumps = maxi(int(roundf(float(powerups.call(&"local_stat", &"extra_jumps", 0.0)))), 0)
	_air_jumps_used = mini(_air_jumps_used, _extra_jumps)


## F-580: which of the two authorised movement conditions currently hold, as the index into
## `_conditional_walk_speed`/`_conditional_sprint_speed`.
func _movement_condition() -> int:
	var condition: int = 0
	var health: Node = _health_node()
	if health != null:
		var max_hp: int = int(health.call(&"local_max_hp"))
		if max_hp > 0 and float(health.call(&"local_hp")) / float(max_hp) < LOW_HP_FRACTION:
			condition |= CONDITION_LOW_HP
	if _in_mire:
		condition |= CONDITION_IN_MIRE
	return condition


## Resamples the Mire grid at MIRE_SAMPLE_INTERVAL_SEC. Absent grid (a bare check scene) means "not
## in the Mire", which is the same answer as an uncorrupted world and never a speed change.
func _tick_mire_condition(delta: float) -> void:
	_time_since_mire_sample += delta
	if _time_since_mire_sample < MIRE_SAMPLE_INTERVAL_SEC:
		return
	_time_since_mire_sample = 0.0
	var mire_grid: Node = get_node_or_null(^"/root/MireGrid")
	_in_mire = mire_grid != null and bool(mire_grid.call(&"is_corrupted", global_position))


func _on_local_powerups_changed(_stacks: Dictionary) -> void:
	_refresh_effective_speeds()


## Same F-011-guarded, F-105-cached shape as _health_node(). PowerupService is an autoload, so the
## reference outlives the session once resolved; null is a legitimate answer in a bare check scene
## that boots the player without the full autoload tree, and every caller treats it as "no powerups".
func _powerup_service() -> Node:
	if not is_instance_valid(_powerups):
		_powerups = get_node_or_null(^"/root/PowerupService")
	return _powerups


func _god_mode_enabled() -> bool:
	if not is_instance_valid(_god_mode):
		_god_mode = get_node_or_null(^"/root/GodModeService")
	return _god_mode != null and bool(_god_mode.call(&"is_local_enabled"))


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
## Replicates position, body yaw, camera pitch, the `dodging` i-frame flag, and F-542's held-item
## presentation id. Yaw is on the body and pitch is on the pivot (see player_camera.gd), so a remote
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
		^".:position", ^".:rotation:y", ^"CameraPivot:rotation:x", ^".:dodging",
		^".:replicated_held_item_id",
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
	# Snap toggle (F-472/D-202). Client-local and instant: it changes nothing but how the NEXT
	# resolve reads, and update_aim() runs on the physics tick, so the ghost jumps flush or comes
	# free within a frame of the press. Gated on build mode like rotate/destroy — outside it the key
	# has no meaning and must fall through rather than be swallowed.
	if is_build_mode_active() and event.is_action_pressed(&"build_snap_toggle") \
			and gameplay_input_allowed():
		var snapping: bool = bool(_build_ghost.call(&"toggle_snapping"))
		if _build_bar != null:
			_build_bar.call(&"set_snapping", snapping)
		get_viewport().set_input_as_handled()
		return

	# Dodge (task 3.8b): a discrete press, not a held/buffered action like jump — the dash either
	# commits now or it doesn't, so there is nothing to buffer. gameplay_input_allowed() gates it the
	# same as attack/build; downed/dead block it the same way jump and sprint already are (crawl_speed
	# leaves no dash to spend, and a dead player is mid-respawn with no body to move at all).
	if event.is_action_pressed(&"dodge") and gameplay_input_allowed() and not _god_mode_enabled() \
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

	# F-520: a capture refused at spawn time (a UI owned the cursor) is taken the moment that UI
	# closes, so the player never lands in the world with a free cursor and a dead camera.
	if _capture_deferred and input_allowed:
		_capture_deferred = false
		_capture_mouse(true)
	var downed: bool = _is_downed()
	var dead: bool = _is_dead()

	# Gamepad look (task 7.6): a held analog value sampled every tick, unlike mouse look's one-shot
	# InputEventMouseMotion in _unhandled_input — see PlayerCamera.apply_look_gamepad()'s own note.
	# Applied before movement reads transform.basis below so a stick turn and the move it causes land
	# in the same tick, the way a mouse turn already does relative to whichever tick move runs in.
	camera.apply_look_gamepad(delta, input_allowed)

	_tick_timers(delta)
	_tick_dodge(delta)
	# F-580: the `_in_mire` half of the conditional-speed condition, resampled on its own interval.
	_tick_mire_condition(delta)
	if _god_mode_enabled():
		_apply_god_flight(delta, input_allowed)
		move_and_slide()
		return
	# F-375, before movement reads it: how deep the water is over the feet decides this tick's speed
	# cap, so it has to be sampled at the position the tick STARTS from, not left over from the last.
	_tick_wade()
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


## Approved playtesting flight. Horizontal input follows the full camera look vector (including
## pitch), jump adds world-up and dodge adds world-down. Collision remains enabled: this is flight,
## not noclip, so a tester cannot accidentally move inside terrain and invalidate what they see.
func _apply_god_flight(delta: float, input_allowed: bool) -> void:
	# A dodge that was already in flight when God mode turned on must not keep its i-frame flag or
	# committed horizontal impulse alive behind this movement branch.
	dodging = false
	_dodge_time_remaining = 0.0
	_iframe_time_remaining = 0.0
	_dodge_velocity = Vector3.ZERO

	var health: Node = _health_node()
	if health != null:
		health.call(&"local_tick_stamina", delta, false)

	var wish: Vector3 = Vector3.ZERO
	if input_allowed:
		var input_2d: Vector2 = Input.get_vector(
			&"move_left", &"move_right", &"move_forward", &"move_back"
		)
		var camera_basis: Basis = camera.global_transform.basis
		wish = camera_basis.x * input_2d.x + (-camera_basis.z) * -input_2d.y
		if Input.is_action_pressed(&"jump"):
			wish += Vector3.UP
		if Input.is_action_pressed(&"dodge"):
			wish += Vector3.DOWN
	if wish.length_squared() > 1.0:
		wish = wish.normalized()

	var sprinting: bool = input_allowed and Input.is_action_pressed(&"sprint") \
		and wish != Vector3.ZERO
	var speed: float = god_flight_speed * (god_flight_sprint_multiplier if sprinting else 1.0)
	velocity = velocity.move_toward(wish * speed, god_flight_acceleration * delta)
	camera.set_sprinting(sprinting)


func _tick_timers(delta: float) -> void:
	if is_on_floor():
		_time_since_grounded = 0.0
		# F-580: the mid-air jump allowance refills on the ground, not on a timer — one extra jump
		# per airborne stretch is what "additional mid-air jumps" means.
		_air_jumps_used = 0
	else:
		_time_since_grounded += delta

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
	# F-375: ONE speed modifier, applied to both branches below. Read from `wade_depth`, which
	# `_physics_process` sampled for this tick before calling in here; 1.0 on dry land, so nothing
	# about movement out of the water is touched by this line existing.
	var wade: float = wade_speed_scale()

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
		# The dash is scaled by the CURRENT depth, not by the depth it was accepted at (F-375). The
		# direction is committed at accept time — that is D-072's whole point — but the speed is not,
		# or a dodge would be a full-speed dash across water that a walk cannot cross, i.e. the exact
		# "deep water is a fast route" hole `wade_min_speed_scale` exists to close. Scaling here
		# rather than at `_execute_dodge()` also means dodging OUT of the water speeds back up over
		# the dash instead of staying slow for its whole window.
		velocity.x = _dodge_velocity.x * wade
		velocity.z = _dodge_velocity.z * wade
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
	# F-580: the conditional pair for whichever of `_low_hp`/`_in_mire` currently hold. Index 0 is
	# the unconditional pair, so a peer holding no conditional powerup reads exactly the old values.
	var condition: int = _movement_condition()
	var walk_now: float = _conditional_walk_speed[condition]
	var sprint_now: float = _conditional_sprint_speed[condition]
	var move_speed: float = crawl_speed if downed else walk_now
	# F-375: wading multiplies the TARGET speed, not the acceleration, so water changes how fast you
	# can go and not how sharply you can steer — a player who walks into the sea decelerates to the
	# wade speed through the ordinary `ground_friction`/`ground_acceleration` ramp rather than
	# snapping to it. A downed crawl is scaled too: crawling through water is the slowest thing in
	# the game, which is correct and is DESIGN.md §4.5's point about downed being a predicament.
	var target: Vector3 = wish_dir * (sprint_now if sprinting else move_speed) * wade

	var horizontal: Vector3 = Vector3(velocity.x, 0.0, velocity.z)

	if is_on_floor():
		# F-404: which rate applies is decided by whether the player is SPEEDING UP or SLOWING DOWN,
		# not by whether a key is held.
		#
		# The old test was `wish_dir != Vector3.ZERO`, so `ground_friction` only ever applied with no
		# input at all — and releasing sprint while still steering decelerated at
		# `ground_acceleration` (60), which is FASTER than the friction constant (50). That inversion
		# is what "the ground friction is higher while walking than when I start sprinting" was
		# describing, and it is a real one, not a misreading.
		var rate: float = ground_acceleration if target.length() > horizontal.length() \
			else ground_friction
		horizontal = horizontal.move_toward(target, rate * delta)
	elif wish_dir != Vector3.ZERO:
		# F-404: in the air, ACCELERATE ALONG the wish direction instead of walking the whole
		# velocity vector toward a target point.
		#
		# `move_toward` on a Vector3 interpolates position-in-velocity-space, so steering mid-air
		# dragged the vector through lower magnitudes — the player lost speed simply for turning and
		# then had to win it back. That is exactly "you kind of fly forward rather than moving
		# linearly, and then you slow down too much".
		#
		# Adding along `wish_dir` and clamping by how much speed already exists in that direction is
		# the conventional air-control model: momentum perpendicular to the input is preserved, so
		# steering REDIRECTS the arc instead of eating it, and the clamp means air control can never
		# push past the speed the same input would reach on the ground.
		var speed_along: float = horizontal.dot(wish_dir)
		var add: float = clampf(
			target.length() - speed_along, 0.0, _effective_air_acceleration * delta
		)
		horizontal += wish_dir * add
		# The clamp above only limits speed ALONG the input, so repeatedly steering into a new
		# direction can compound total speed — the air-strafe/bunny-hop accumulation every game with
		# this model has to answer for. A ceiling answers it without touching the feel: a single
		# steer still redirects freely and still keeps its momentum, it just cannot be stacked into
		# something faster than sprinting. Measured: one hard perpendicular steer takes 6.00 m/s to
		# 6.95, comfortably under this.
		var airborne_ceiling: float = sprint_now * AIR_SPEED_CEILING_FACTOR * wade
		if horizontal.length() > airborne_ceiling:
			horizontal = horizontal.normalized() * airborne_ceiling
	# ...and with no input in the air, nothing is applied at all. Momentum carries, which is what
	# makes a jump read as a linear arc rather than as something being steered for you.

	velocity.x = horizontal.x
	velocity.z = horizontal.z

	camera.set_sprinting(sprinting and is_on_floor())


# ── Wade (F-375) ──────────────────────────────────────────────────────────────────────────────────
#
# Network authority: OWN PLAYER MOVEMENT — CLIENT (ARCHITECTURE.md §2.2, row 1), exactly like the
# sprint gate and the dodge above it, and applied on the SAME path they are: it scales the velocity
# this body simulates, never a camera effect or a client-only overlay. Three things make that safe
# rather than "the client decides how fast it goes in water", which it would be if the depth were
# the client's opinion:
#
#   1. The depth is not an opinion. `water_surface_at()` is a pure function of (x, z) published by
#      the world script, and worldgen is deterministic across peers (D-017), so the host's own copy
#      of the map computes the identical surface for the identical position. Nothing new goes on the
#      wire and there is nothing for two peers to disagree about.
#   2. It can only ever SLOW a player down — `wade_speed_scale()` returns (0, 1]. The host's
#      advisory speed check (`autoload/player_net.gd` `_check_speed()`, §2.2 row 1) is an upper
#      bound of `sprint_speed * SPEED_CHECK_TOLERANCE`, so wading cannot trip it and the check needs
#      no knowledge of this at all. A client that ignored the slowdown would look to the host exactly
#      like a client that stayed on dry land, which is the pre-existing trust boundary, not a new one.
#   3. It costs nothing that is authoritative. Wading spends no stamina, deals no damage and sets no
#      replicated flag, so there is no resource a lying client could gain by skipping it.
#
# Before this the player scripts did not mention water anywhere — a recursive search returned zero
# hits — so a sprint straight off the beach carried on at 6 m/s across the sea with no drag and no
# feedback of any kind.


## Samples the water surface over the FEET and stores this tick's depth in `wade_depth`.
##
## `global_position.y` IS foot height: `player.tscn` puts the CapsuleShape3D's centre at y = 0.9 on a
## 1.8 m capsule, so the body origin sits on the soles. Reading the origin rather than measuring the
## shape keeps this a single float read per tick.
##
## Degrades to "dry" in every failure mode rather than guessing, because every one of them is a real
## configuration:
##   * no world node resolved yet — a `--script` harness that stands a player up before a map, or the
##     first ticks of a level whose world is still building;
##   * a world that does not implement `water_surface_at()` at all — the F-284 pair is a convention,
##     not an interface the engine enforces, and an authored map is free to predate it;
##   * a non-finite answer — `AuthoredWorld.water_surface_at()` returns -INF for a point no water
##     body covers, which is its way of saying "no water here", and NAN must never propagate into a
##     velocity.
func _tick_wade() -> void:
	var source: Node = _water_source_node()
	if source == null:
		wade_depth = 0.0
		return
	var surface: float = float(source.call(&"water_surface_at", global_position.x, global_position.z))
	if not is_finite(surface):
		wade_depth = 0.0
		return
	wade_depth = maxf(surface - global_position.y, 0.0)


## This tick's movement-speed multiplier from `wade_depth`, in (0, 1]. Exactly 1.0 on dry land and
## through the shallows, so nothing about movement on land is touched by this feature existing.
##
## smoothstep, not a straight lerp: a linear ramp puts a hard kink in the speed curve at
## `wade_shallow_depth`, and walking down a beach at a shallow angle crosses that depth slowly enough
## that the kink is felt as a lurch. smoothstep eases in and out, so the water takes hold and lets go
## gradually — which is also what wading feels like.
func wade_speed_scale() -> float:
	if wade_depth <= wade_shallow_depth:
		return 1.0
	# maxf guards a hand-tuned `wade_deep_depth` set at or below `wade_shallow_depth` in the
	# inspector: smoothstep with from >= to is undefined, and a designer sliding two numbers past
	# each other should get a hard cutover, not a NAN in `velocity`.
	var deep: float = maxf(wade_deep_depth, wade_shallow_depth + 0.01)
	return lerpf(1.0, wade_min_speed_scale, smoothstep(wade_shallow_depth, deep, wade_depth))


## Resolves whichever node answers the F-284 `height_at()`/`water_surface_at()` pair for the map that
## is loaded, cached in `_water_source`. The first two shapes are the two
## `tools/world_contract_check.gd` `_check_spawn_standable()` already knows about, tried in the same
## order it tries them:
##   procedural — `ProceduralWorld` IS the level root, so `current_scene` answers directly.
##   authored   — `AuthoredWorld` is the level's "World" child.
## Deliberately NOT by walking this node's ancestors, which is the obvious third option and is wrong:
## in a session `PlayerNet` parents every player under its own `players_root()`, not under the world,
## so a body that is standing in the sea has no world anywhere above it.
##
## The `authored_world_terrain` scan is a last resort for a `--script` harness whose `current_scene`
## is a check root rather than the level. It is last, not first, because on the procedural map that
## group also holds every streamed chunk MeshInstance3D (`world/chunk/chunk_streamer.gd:487`) — a
## scan that allocates and walks dozens of nodes to find the one that is also `current_scene`.
##
## Returns null — never a stand-in — when nothing answers, and `_tick_wade()` reads that as dry land.
func _water_source_node() -> Node:
	if is_instance_valid(_water_source):
		return _water_source

	_water_source = null
	var scene: Node = get_tree().current_scene
	if scene != null:
		if scene.has_method(&"water_surface_at"):
			_water_source = scene
			return _water_source
		var world: Node = scene.get_node_or_null(^"World")
		if world != null and world.has_method(&"water_surface_at"):
			_water_source = world
			return _water_source

	for node: Node in get_tree().get_nodes_in_group(TERRAIN_GROUP):
		if node.has_method(&"water_surface_at"):
			_water_source = node
			return _water_source
	return null


func _try_jump(input_allowed: bool, downed: bool, dead: bool) -> void:
	if not input_allowed or downed or dead:
		return
	var buffered: bool = _time_since_jump_pressed <= jump_buffer_time
	if not buffered:
		return
	var grounded_recently: bool = _time_since_grounded <= coyote_time
	# F-580: `extra_jumps` — a mid-air jump, allowed only once the ground/coyote jump is spent and
	# only as many times per airborne stretch as the stat grants. A peer holding none has
	# `_extra_jumps == 0`, so this whole branch collapses to the old "grounded or coyote, or nothing".
	var air_jump: bool = not grounded_recently and _air_jumps_used < _extra_jumps
	if not (grounded_recently or air_jump):
		return
	# Stamina gates jump (task 3.8, same client-local row as sprint) — a harness with no PlayerHealth
	# jumps freely rather than losing the verb. The buffered press is NOT consumed on rejection, so a
	# player who regens enough stamina before jump_buffer_time expires still gets the jump they asked for.
	var health: Node = _health_node()
	if health != null and not bool(
		health.call(&"local_try_spend_stamina", health.call(&"local_jump_stamina_cost"))
	):
		return

	# F-580: the powerup-modified apex, not the raw export. Set outright rather than added to, the
	# same as it always was — an air jump that added to a falling velocity would give a weaker second
	# jump the faster you were falling, which reads as the jump failing.
	velocity.y = sqrt(2.0 * _gravity * gravity_scale * _effective_jump_height)
	if air_jump:
		_air_jumps_used += 1

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
	# F-405: a step already under way may continue for a moment after the body leaves the floor.
	#
	# The bare `is_on_floor()` guard was right for STARTING a step and wrong for finishing one. A lip
	# is climbed over several ticks — one tick of motion at walking pace is ~67 mm, far less than the
	# capsule's 0.4 m radius, so the first step lands the body on the lip's top EDGE, balanced on the
	# curve of its bottom hemisphere and momentarily airborne. This guard then made the next tick a
	# no-op, gravity returned the body to the bottom, and the player creeped at the kerb without ever
	# getting up it. Measured: a 0.3 m kerb, well under `step_height`, stalled the player at y=0.014
	# before F-403 and y=0.084 after it, where getting up means reaching 0.3.
	#
	# The grace window is short and only ever opened by an accepted step, so it cannot become a
	# general "step up while falling" — walking off a cliff still gets the ordinary refusal on the
	# first tick, because nothing set it.
	_step_grace = maxf(_step_grace - delta, 0.0)
	if not is_on_floor() and _step_grace <= 0.0:
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

	# 3. From the raised height, can the player actually move FORWARD? This is the test that
	# separates a lip from a wall, and it is the one F-403 found missing.
	#
	# The previous version swept forward and down together and judged the result on `travel.y`
	# alone. That cannot tell the two apart: a wall stops the combined sweep's forward component
	# before it ever descends, so it returns the same near-zero `travel.y` a lip does, and was
	# accepted — teleporting the player a clear `step_height` into the air onto nothing. Gravity
	# returned them the next frame and pushing forward lifted them again, which is the "bounce up
	# and down when I run into a tree" reported from play twice. Measured at 0.396 m of lift and 7
	# reversals in 90 ticks against a plain wall (`tools/step_up_check.gd`).
	#
	# Probing forward on its own is unambiguous. A kerb below `step_height` is now UNDER the raised
	# capsule and the move is clear; a wall is still in front of it and the move is blocked. No
	# threshold to tune, and no way for the two cases to produce the same answer.
	if test_move(raised, motion):
		return
	var stepped: Transform3D = raised
	stepped.origin += motion

	# 4. Settle back down onto whatever is under the new position.
	var landing: KinematicCollision3D = KinematicCollision3D.new()
	var drop: Vector3 = Vector3(0.0, -step_height, 0.0)
	var travel: Vector3 = landing.get_travel() if test_move(stepped, drop, landing) else drop

	# Nothing within reach: the player walked out over a gap rather than up onto a lip, so leave
	# move_and_slide to resolve the frame instead of depositing them on whatever is far below.
	if travel.y <= -step_height + 0.02:
		return

	global_position = stepped.origin + travel
	_step_grace = STEP_CONTINUE_GRACE_SEC


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
		# F-580: report the impact to PlayerHealth, which owns what a landing COSTS. This peer is the
		# only one that can observe its own impact speed (own movement is client authority), so it
		# reports the physical fact and never a damage number — the host applies
		# `fall_damage_taken` and decides. A harness with no PlayerHealth simply lands.
		var health: Node = _health_node()
		if health != null:
			health.call(&"local_report_landing", fall_speed)
	_was_on_floor = on_floor


## F-580 — the receiving half of PlayerHealth's knockback. Called on the STRUCK player's own peer,
## which is the only one allowed to move this body (ARCHITECTURE §2.2 row 1).
##
## `knockback_taken` is applied here, by the receiver, through `local_stat()`: a client is only ever
## sent its own powerup map, so this is the one place the stat can be read honestly. A negative
## multiplier is stability (`root_hold`), and the result is clamped at zero so a stacked resist
## cannot invert the shove into a pull TOWARD the thing that just hit you.
##
## Added to horizontal velocity rather than assigned, so being hit while already moving reads as
## being shoved off course instead of having your momentum replaced. Vertical velocity is untouched:
## a hit does not pop you into the air, and leaving `velocity.y` alone means a knockback mid-fall
## cannot cancel the fall damage that fall was about to cost.
func local_apply_knockback(direction: Vector3, impulse: float) -> void:
	if not is_local_authority or _is_dead():
		return
	var flat := Vector3(direction.x, 0.0, direction.z)
	if flat.length_squared() < 0.000001:
		return
	var powerups: Node = _powerup_service()
	var scaled: float = impulse
	if powerups != null:
		scaled = maxf(float(powerups.call(&"local_stat", &"knockback_taken", impulse)), 0.0)
	if scaled <= 0.0:
		return
	var pushed: Vector3 = Vector3(velocity.x, 0.0, velocity.z) + flat.normalized() * scaled
	velocity.x = pushed.x
	velocity.z = pushed.z


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
		# Build mode owns a pointer so its tabs and pieces are genuinely clickable. Return to
		# first-person aiming only when no other cursor-owning UI has appeared in the meantime.
		if gameplay_input_allowed():
			_capture_mouse(true)
		else:
			_capture_deferred = true
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
	# F-527: the picker is a mouse UI. Camera look pauses while it is open; clicking outside the
	# Controls still reaches the existing attack/build-confirm branch and places the armed ghost.
	_capture_deferred = false
	_capture_mouse(false)
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


func _on_build_placement_aim_requested() -> void:
	if not is_build_mode_active():
		return
	# F-571: choosing is the boundary between the pointer-driven picker and first-person
	# placement. Keep the ghost (and therefore build mode) active, but get the bar out of the way
	# and give mouse motion/LMB back to aim + confirm. Without this transition F-527's visible
	# cursor remained in force forever, so a player could choose a piece but could neither turn nor
	# place it.
	if _build_bar != null:
		_build_bar.call(&"set_active", false)
	_capture_deferred = false
	_capture_mouse(true)


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
	# F-580: `revive_seconds` — how long THIS reviver has to hold (docs/POWERUPS.md §2: "peer = the
	# reviver"). Asked of PlayerHealth rather than read off its export, so the powerup applies.
	if _revive_hold_elapsed >= float(health.call(&"local_revive_seconds")):
		_revive_request_sent = true
		health.call(&"request_revive", target_peer)


func _reset_revive_hold() -> void:
	_revive_target_peer = 0
	_revive_hold_elapsed = 0.0
	_revive_request_sent = false


## Nearest OTHER player PlayerHealth's broadcast flag says is downed, within revive_radius_m. Reads
## only replicated data — a client has no business knowing more about a peer it might not even see.
func _nearest_downed_teammate(health: Node) -> int:
	# F-580: `revive_radius_m`, so the prompt appears at the range the host will actually accept.
	var radius: float = float(health.call(&"local_revive_radius_m"))
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
