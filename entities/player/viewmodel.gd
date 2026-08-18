class_name PlayerViewmodel
extends Node3D

## The thing in your hand, and the swing you can actually see (F-041).
##
## NETWORK AUTHORITY: **CLIENT-LOCAL, always** (ARCHITECTURE.md §2.2, last row). This is a mesh
## parented to a camera. It reads the local inventory snapshot to decide what to show and
## `CombatService`'s local swing clock to decide where to put it, and it tells nobody anything. Only
## the owning player builds one — a remote player's arm is their business, and D-004 says we never
## build a third-person animation pipeline anyway.
##
## The swing is procedural rather than authored. Every weapon's timings are already data
## (`WeaponDef.wind_up_seconds` and friends) and task 2.9 tunes them, so an authored clip per weapon
## would have to be re-authored every time a number moved. Driving the pose from
## `CombatService.local_phase_progress()` means a weapon that gets a slower wind-up gets a slower
## wind-up animation for free.

const HOTBAR_START_INDEX: int = 24

## CombatService.Phase, mirrored. This script is preloaded by player_controller.gd, which harnesses
## reach at compile time through the PlayerController class_name — BEFORE autoloads exist (F-011,
## F-046). So no autoload may appear in this file as a bare identifier, not even for an enum. And
## preloading combat_service.gd just for Phase would drag its bare autoload references (legitimate
## there — an autoload compiles at registration time) into the same early pass. Raw ints are how
## viewmodel_check.gd already reads the phase, for the same reason.
const PHASE_WIND_UP: int = 1
const PHASE_COMMIT: int = 2
const PHASE_RECOVERY: int = 3

## THE SWING LIVES ON THIS NODE, THE GRIP LIVES ON THE CHILD. That split is the whole reason this
## reads as a chop: applying a swing rotation on top of a grip that already yaws the item ~160° means
## "pitch down" is expressed in the item's rotated axes and comes out as some other motion entirely.
## Here the node rotates in the CAMERA's axes — +X right, +Y up, -Z forward — so a positive X
## rotation is always "swing down", whatever the weapon's own grip happens to be.
const REST_POSITION := Vector3.ZERO

## `ItemDef.AttackStyle`, mirrored as raw ints for the same reason `PHASE_*` above is (F-011, F-046),
## and kept honest by `viewmodel_check.gd`, which asserts these agree with the enum rather than
## trusting the comment.
const STYLE_NONE: int = 0
const STYLE_CHOP: int = 1
const STYLE_SMASH: int = 2
const STYLE_SLASH: int = 3
const STYLE_THRUST: int = 4
const DEFAULT_STYLE: int = STYLE_CHOP

## WHERE THE HIT LANDS, AND WHY THE OLD ARC READ AS A SLIDE (F-073). `CombatService` resolves the
## hit at `elapsed >= wind_up_seconds` (`combat_service.gd:197`) — the WIND_UP→COMMIT boundary, not
## somewhere inside COMMIT. The previous pose table drove the weapon *down* during COMMIT, so damage,
## hitstop and shake all fired while the weapon was still cocked at the top of its wind-up, and the
## visible strike happened a whole phase late. Every arc below therefore reaches its `hit` key at the
## END of the wind-up, so the contact frame is the frame the player is already being told about.
##
## Inside the wind-up the weapon first cocks (ease-out, hangs — the telegraph) and then drives
## (ease-in, accelerating). COCK_FRACTION is where one becomes the other.
const COCK_FRACTION: float = 0.55
## Rotation leads translation through the strike; that lag is most of what reads as weight.
const ROTATION_LEAD: float = 0.78
## Recovery overshoots rest slightly and settles, instead of easing monotonically home.
const RECOVERY_OVERSHOOT: float = 0.14

## THE SWING TURNS ABOUT A SHOULDER, NOT ABOUT THE EYE. This node sits at the camera's own origin, so
## rotating it alone orbits the whole weapon around the player's eyeball: 30° of pitch drags a tool
## half a metre away right off the screen, which is why the first version had to use angles too small
## to read as a swing. Rotating about a point down and back instead — roughly where a shoulder is —
## lets the head sweep a real arc while the grip stays near the hand. Camera axes, metres.
const SWING_PIVOT := Vector3(0.22, -0.40, 0.10)

## One entry per AttackStyle, indexed by the raw ints above.
##   cock   — top of the wind-up, the anticipation
##   hit    — the contact pose, reached exactly as the hit resolves
##   follow — follow-through past contact, reached at the end of COMMIT
##   arc    — mid-strike control point; a straight lerp is a chord, this makes it a curve
##
## SIGN, because the previous table had it backwards and the comment above it agreed with the table
## rather than with the engine: this node is ABOVE `SWING_PIVOT`, so a POSITIVE X rotation raises the
## weapon and a NEGATIVE one drives it down. The old constants cocked at -32 and struck at +38, i.e.
## they dipped and then threw the weapon up and out of frame on the contact frame.
##
## Magnitudes are bounded by a real constraint, not by taste: every design's EXTREME point — the axe's
## bit corner, the sword's tip 1.72 m up — must stay inside the frame for every frame of the swing,
## since the contact frame is the one the player reads the hit from. Measured at the extremes rather
## than at a centroid, which is what hid a sword tip sitting 75% past the right edge at full cock.
## `viewmodel_check.gd` additionally asserts nothing crosses the camera near plane.
const STYLE_POSES: Array[Dictionary] = [
	{   # NONE — a bow or a carried thing. Enough motion that a click is not dead.
		"cock_pos": Vector3(0.008, 0.020, 0.020), "cock_rot": Vector3(6.0, -3.0, 3.0),
		"hit_pos": Vector3(-0.012, -0.012, -0.030), "hit_rot": Vector3(-6.0, 4.0, -4.0),
		"follow_pos": Vector3(-0.018, -0.018, -0.012), "follow_rot": Vector3(-8.0, 5.0, -5.0),
		"arc": Vector3(0.004, 0.006, -0.010),
	},
	{   # CHOP — axes and the cleaver. Up over the shoulder, then down and across to the left with the
		# edge leading, because these are the designs whose bit points downrange.
		"cock_pos": Vector3(0.015, 0.030, 0.030), "cock_rot": Vector3(13.5, -7.0, 8.0),
		"hit_pos": Vector3(-0.020, -0.015, -0.045), "hit_rot": Vector3(-13.0, 9.0, -10.0),
		"follow_pos": Vector3(-0.040, -0.025, -0.020), "follow_rot": Vector3(-19.0, 14.0, -15.0),
		"arc": Vector3(0.008, 0.014, -0.022),
	},
	{   # SMASH — pickaxes and the repair hammer. Straight up, straight down. The yaw and roll are
		# almost nil on purpose: weight reads as a lack of flourish.
		"cock_pos": Vector3(0.000, 0.045, 0.030), "cock_rot": Vector3(19.0, -2.0, 3.0),
		"hit_pos": Vector3(-0.010, -0.020, -0.050), "hit_rot": Vector3(-11.0, 2.0, -3.0),
		"follow_pos": Vector3(-0.020, -0.030, -0.020), "follow_rot": Vector3(-15.0, 4.0, -5.0),
		"arc": Vector3(0.000, 0.018, -0.026),
	},
	{   # SLASH — the sword. Mostly yaw: a horizontal arc across the view, not a chop. Its cock is the
		# shallowest of any style because the sword is the longest blade in the set and its framing is
		# measured at the TIP, 1.72 m up: a cock big enough to look right on the axes threw the point
		# clean off the right edge of the frame.
		"cock_pos": Vector3(0.020, 0.015, 0.025), "cock_rot": Vector3(5.0, -3.0, 4.0),
		"hit_pos": Vector3(-0.050, -0.010, -0.050), "hit_rot": Vector3(-7.0, 18.0, -10.0),
		"follow_pos": Vector3(-0.055, -0.020, -0.020), "follow_rot": Vector3(-10.0, 27.0, -14.0),
		"arc": Vector3(0.000, 0.020, -0.030),
	},
	{   # THRUST — the skewer. Pull back, drive down the view axis, and deliberately DO NOT arc: a
		# spear that swings sideways reads as the wrong weapon, which is the complaint that opened
		# F-073. Almost all of the motion is translation in Z.
		#
		# The pull-back is SMALL and the drive carries the read instead. A skewer's hand sits 0.72 up
		# a 1.97 m shaft, which leaves its butt cap only ~12 cm in front of the camera at rest, so a
		# 0.11 m pull-back put the butt behind the 0.05 m near plane and clipped it every wind-up.
		"cock_pos": Vector3(0.020, -0.010, 0.020), "cock_rot": Vector3(5.0, -4.0, 2.0),
		"hit_pos": Vector3(-0.010, 0.005, -0.240), "hit_rot": Vector3(-3.0, 3.0, -2.0),
		"follow_pos": Vector3(-0.005, 0.000, -0.190), "follow_rot": Vector3(-4.0, 4.0, -2.0),
		"arc": Vector3(0.000, 0.000, 0.000),
	},
]

## Idle sway, so a held item does not look pasted onto the screen.
const SWAY_AMPLITUDE_M: float = 0.006
const SWAY_SPEED: float = 1.7
## The swing clock stops dead at the end of RECOVERY rather than reaching rest (`combat_service.gd`
## zeroes it the frame `elapsed >= swing_seconds()`), so the pose would snap from its recovery
## residual straight to the sway offset. Ramping the sway back in over this long absorbs that.
const SWAY_BLEND_SECONDS: float = 0.18

var _item_id: StringName = &""
var _instance: Node3D
var _grip_offset: Vector3 = Vector3.ZERO
var _grip_rotation: Vector3 = Vector3.ZERO
var _grip_scale: float = 1.0
var _attack_style: int = DEFAULT_STYLE
var _sway_time: float = 0.0
var _sway_blend: float = 1.0

## Resolved by path, never bare (F-011, F-046). Fetched once in _ready: this node only exists inside
## a running scene, where the autoloads are already up.
var _combat: Node
var _inventory: Node
var _registry: Node
var _hotbar_ui: Node


func _ready() -> void:
	# Viewmodels are drawn very close to the near plane; without this a long weapon clips through the
	# camera the moment it swings toward it.
	set_process(true)
	_combat = get_node_or_null(^"/root/CombatService")
	_inventory = get_node_or_null(^"/root/InventoryService")
	_registry = get_node_or_null(^"/root/Registry")
	_hotbar_ui = get_node_or_null(^"/root/InventoryUI")
	_refresh_item()
	if _inventory != null:
		_inventory.connect(&"local_inventory_changed", _on_inventory_changed)


func _exit_tree() -> void:
	if _inventory != null and _inventory.is_connected(&"local_inventory_changed", _on_inventory_changed):
		_inventory.disconnect(&"local_inventory_changed", _on_inventory_changed)


func _process(delta: float) -> void:
	_refresh_item()
	_apply_pose(delta)


## What the local player is holding: the item in the selected hotbar slot. While a swing is running,
## the weapon that STARTED it wins, so changing slots mid-arc does not make the weapon vanish
## halfway through its own animation.
func held_item_id() -> StringName:
	if _combat != null:
		var swinging := StringName(_combat.call(&"local_swing_item"))
		if swinging != &"" and swinging != &"unarmed":
			return swinging
	if _inventory == null:
		return &""
	# One slot read, no whole-array snapshot: this runs every rendered frame (F-099). The accessor
	# already answers &"" for an empty, exhausted, or out-of-range slot.
	var slot_index: int = HOTBAR_START_INDEX + _selected_hotbar_index()
	return StringName(_inventory.call(&"local_item_id", slot_index))


## The node actually on screen, or null for an empty hand. Public so a check can assert on it.
func current_instance() -> Node3D:
	return _instance


## The arc the held item is currently animating with, as an `ItemDef.AttackStyle` int. Public so
## `viewmodel_check.gd` can assert the dispatch actually happened — a style that never reaches the
## animator is exactly the failure F-073 was, and it is invisible from the outside otherwise.
func current_attack_style() -> int:
	return _attack_style


func _refresh_item() -> void:
	var wanted: StringName = held_item_id()
	if wanted == _item_id:
		return
	_item_id = wanted

	if _instance != null:
		_instance.queue_free()
		_instance = null
	_grip_offset = Vector3.ZERO
	_grip_rotation = Vector3.ZERO
	_grip_scale = 1.0
	_attack_style = DEFAULT_STYLE
	if _item_id == &"":
		return

	if _registry == null:
		return
	var item: ItemDef = _registry.call(&"get_item", _item_id)
	# No view_model is a legitimate answer, not a failure: a log or a lump of ore is carried, not
	# held up. An empty hand is the correct picture for it.
	if item == null or item.view_model == null:
		return

	_instance = item.view_model.instantiate() as Node3D
	if _instance == null:
		return
	_instance.name = "HeldItem"
	_grip_offset = item.grip_offset
	_grip_rotation = item.grip_rotation_degrees
	_grip_scale = item.grip_scale
	_attack_style = clampi(int(item.attack_style), 0, STYLE_POSES.size() - 1)
	add_child(_instance)
	# The grip is constant for the item's lifetime — applied once here, not per frame (F-099).
	_instance.position = _grip_offset
	_instance.rotation = Vector3(
		deg_to_rad(_grip_rotation.x), deg_to_rad(_grip_rotation.y), deg_to_rad(_grip_rotation.z)
	)
	_instance.scale = Vector3.ONE * _grip_scale


## Pose = the item's own grip, plus wherever the swing has got to. Lerped in local space rather than
## through an AnimationPlayer so it stays correct when 2.9 retunes a weapon's phase durations.
func _apply_pose(delta: float) -> void:
	if _instance == null:
		return

	var phase: int = int(_combat.call(&"local_phase")) if _combat != null else 0
	var progress: float = float(_combat.call(&"local_phase_progress")) if _combat != null else 0.0
	var position_offset := Vector3.ZERO
	var rotation_offset := Vector3.ZERO

	if phase == PHASE_WIND_UP or phase == PHASE_COMMIT or phase == PHASE_RECOVERY:
		_sway_blend = 0.0
		var keyed: Array = swing_pose(_attack_style, phase, progress)
		position_offset = keyed[0]
		rotation_offset = keyed[1]
	else:
		# Idle. The swing clock is zeroed the frame it completes, so the pose would otherwise snap
		# from its recovery residual to the sway offset; ramp the sway in instead.
		_sway_time += delta
		_sway_blend = minf(_sway_blend + delta / SWAY_BLEND_SECONDS, 1.0)
		position_offset = Vector3(
			sin(_sway_time * SWAY_SPEED) * SWAY_AMPLITUDE_M,
			sin(_sway_time * SWAY_SPEED * 1.6) * SWAY_AMPLITUDE_M * 0.7,
			0.0
		) * _sway_blend

	# Hitstop freezes the swing clock, so the pose freezes with it and the impact reads as a stop
	# rather than as a stutter. Nothing extra to do — local_phase_progress() simply stops advancing,
	# and because the arc reaches `hit` exactly when the hit resolves, what it freezes on is the
	# contact frame itself.
	transform = swing_transform(position_offset, rotation_offset)
	# ...the grip on the child was applied once in _refresh_item, in the item's own axes.


## Where one style's arc has got to at `progress` through `phase`, as `[position, rotation_degrees]`.
##
## Public and pure so `viewmodel_check.gd` can walk a whole swing without needing that weapon in the
## hotbar. That matters more than it looks: the dev loadout carries six of the eleven holdable items,
## so assertions written against "whatever is selected" silently never exercise SLASH at all.
func swing_pose(style: int, phase: int, progress: float) -> Array:
	var pose: Dictionary = STYLE_POSES[clampi(style, 0, STYLE_POSES.size() - 1)]
	match phase:
		PHASE_WIND_UP:
			if progress <= COCK_FRACTION:
				# Cock. Ease out, so the weapon arrives at the top early and hangs there — that hang
				# is the telegraph, and it is the only part of the swing the player has time to read.
				var t: float = 1.0 - pow(1.0 - progress / maxf(COCK_FRACTION, 0.001), 2.0)
				return [REST_POSITION.lerp(pose["cock_pos"], t), Vector3.ZERO.lerp(pose["cock_rot"], t)]
			# Drive. Ease in, fastest at the contact frame, which is the END of this phase.
			var t: float = (progress - COCK_FRACTION) / maxf(1.0 - COCK_FRACTION, 0.001)
			var eased: float = t * t
			return [
				_arc(pose["cock_pos"], pose["hit_pos"], pose["arc"], eased),
				(pose["cock_rot"] as Vector3).lerp(pose["hit_rot"], _lead(eased)),
			]
		PHASE_COMMIT:
			# Past the contact frame. Decelerating follow-through — the weapon carries its own weight
			# through the target rather than stopping dead on it.
			var eased: float = 1.0 - pow(1.0 - progress, 2.0)
			return [
				(pose["hit_pos"] as Vector3).lerp(pose["follow_pos"], eased),
				(pose["hit_rot"] as Vector3).lerp(pose["follow_rot"], _lead(eased)),
			]
		PHASE_RECOVERY:
			# Home, overshooting rest and settling back rather than easing monotonically into it.
			var eased: float = 1.0 - pow(1.0 - progress, 3.0)
			var overshoot: float = eased + RECOVERY_OVERSHOOT * sin(progress * PI) * (1.0 - progress)
			return [
				(pose["follow_pos"] as Vector3).lerp(REST_POSITION, overshoot),
				(pose["follow_rot"] as Vector3).lerp(Vector3.ZERO, overshoot),
			]
	return [Vector3.ZERO, Vector3.ZERO]


## The node transform for one keyed pose, turning about `SWING_PIVOT` rather than this node's own
## origin: `R * (p - pivot) + pivot` is the same as rotating normally and then translating by
## `pivot - R * pivot`, which is all a Node3D can express. Public for the same reason as `swing_pose`.
func swing_transform(position_offset: Vector3, rotation_degrees_offset: Vector3) -> Transform3D:
	var swing := Basis.from_euler(Vector3(
		deg_to_rad(rotation_degrees_offset.x),
		deg_to_rad(rotation_degrees_offset.y),
		deg_to_rad(rotation_degrees_offset.z)
	))
	return Transform3D(swing, SWING_PIVOT - swing * SWING_PIVOT + position_offset)


## Quadratic Bezier from `from` to `to`, bulged by `arc` at the midpoint. A straight lerp between two
## keys is a chord; a weapon that travels a chord looks like it is being slid, not swung.
func _arc(from: Vector3, to: Vector3, arc: Vector3, t: float) -> Vector3:
	var control: Vector3 = (from + to) * 0.5 + arc
	var inv: float = 1.0 - t
	return from * (inv * inv) + control * (2.0 * inv * t) + to * (t * t)


## Rotation runs ahead of translation. The weapon has turned into the blow before it has finished
## travelling, which is what separates a swing from a slide.
func _lead(t: float) -> float:
	return clampf(pow(t, ROTATION_LEAD), 0.0, 1.0)


func _on_inventory_changed(_slots: Array[Dictionary], _revision: int) -> void:
	# Force a re-read: the selected slot's contents may have changed without the selection moving.
	_item_id = &"￿"


func _selected_hotbar_index() -> int:
	if _hotbar_ui == null or not _hotbar_ui.has_method("selected_hotbar_slot"):
		return 0
	return int(_hotbar_ui.call("selected_hotbar_slot"))
