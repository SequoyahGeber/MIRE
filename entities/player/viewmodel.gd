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
## Up and slightly back over the shoulder, tipping the head backwards.
const WINDUP_POSITION := Vector3(0.02, 0.10, 0.06)
const WINDUP_ROTATION_DEG := Vector3(-32.0, 10.0, -12.0)
## Down and across to the left, driving through where the hit resolves.
## Stops short of driving the head off the bottom of the screen: the contact frame is the one the
## player reads the hit from, so the weapon has to still be in it.
const COMMIT_POSITION := Vector3(-0.08, -0.085, -0.10)
const COMMIT_ROTATION_DEG := Vector3(38.0, -14.0, 16.0)
## Idle sway, so a held item does not look pasted onto the screen.
const SWAY_AMPLITUDE_M: float = 0.006
const SWAY_SPEED: float = 1.7

var _item_id: StringName = &""
var _instance: Node3D
var _grip_offset: Vector3 = Vector3.ZERO
var _grip_rotation: Vector3 = Vector3.ZERO
var _grip_scale: float = 1.0
var _sway_time: float = 0.0

## Resolved by path, never bare (F-011, F-046). Fetched once in _ready: this node only exists inside
## a running scene, where the autoloads are already up.
var _combat: Node
var _inventory: Node
var _registry: Node


func _ready() -> void:
	# Viewmodels are drawn very close to the near plane; without this a long weapon clips through the
	# camera the moment it swings toward it.
	set_process(true)
	_combat = get_node_or_null(^"/root/CombatService")
	_inventory = get_node_or_null(^"/root/InventoryService")
	_registry = get_node_or_null(^"/root/Registry")
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
	var index: int = _selected_hotbar_index()
	var slots: Array = _inventory.call(&"local_slots")
	var slot_index: int = HOTBAR_START_INDEX + index
	if slot_index < 0 or slot_index >= slots.size():
		return &""
	var slot: Dictionary = slots[slot_index]
	if int(slot.get("amount", 0)) <= 0:
		return &""
	return StringName(String(slot.get("item_id", "")))


## The node actually on screen, or null for an empty hand. Public so a check can assert on it.
func current_instance() -> Node3D:
	return _instance


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
	add_child(_instance)


## Pose = the item's own grip, plus wherever the swing has got to. Lerped in local space rather than
## through an AnimationPlayer so it stays correct when 2.9 retunes a weapon's phase durations.
func _apply_pose(delta: float) -> void:
	if _instance == null:
		return

	var phase: int = int(_combat.call(&"local_phase")) if _combat != null else 0
	var progress: float = float(_combat.call(&"local_phase_progress")) if _combat != null else 0.0
	var position_offset := Vector3.ZERO
	var rotation_offset := Vector3.ZERO

	match phase:
		PHASE_WIND_UP:
			# Ease out: the weapon reaches the top of the wind-up early and hangs there, which is
			# what makes a telegraph readable rather than a blur.
			var eased: float = 1.0 - pow(1.0 - progress, 2.0)
			position_offset = WINDUP_POSITION * eased
			rotation_offset = WINDUP_ROTATION_DEG * eased
		PHASE_COMMIT:
			# Ease in: slow off the top, fastest through the contact point.
			var eased: float = progress * progress
			position_offset = WINDUP_POSITION.lerp(COMMIT_POSITION, eased)
			rotation_offset = Vector3(WINDUP_ROTATION_DEG).lerp(COMMIT_ROTATION_DEG, eased)
		PHASE_RECOVERY:
			var eased: float = 1.0 - pow(1.0 - progress, 3.0)
			position_offset = COMMIT_POSITION.lerp(REST_POSITION, eased)
			rotation_offset = Vector3(COMMIT_ROTATION_DEG).lerp(Vector3.ZERO, eased)
		_:
			_sway_time += delta
			position_offset = Vector3(
				sin(_sway_time * SWAY_SPEED) * SWAY_AMPLITUDE_M,
				sin(_sway_time * SWAY_SPEED * 1.6) * SWAY_AMPLITUDE_M * 0.7,
				0.0
			)

	# Hitstop freezes the swing clock, so the pose freezes with it and the impact reads as a stop
	# rather than as a stutter. Nothing extra to do — local_phase_progress() simply stops advancing.
	#
	# Swing on this node, in camera axes...
	position = position_offset
	rotation = Vector3(
		deg_to_rad(rotation_offset.x), deg_to_rad(rotation_offset.y), deg_to_rad(rotation_offset.z)
	)
	# ...grip on the child, in the item's own. Neither has to know about the other.
	_instance.position = _grip_offset
	_instance.rotation = Vector3(
		deg_to_rad(_grip_rotation.x), deg_to_rad(_grip_rotation.y), deg_to_rad(_grip_rotation.z)
	)
	_instance.scale = Vector3.ONE * _grip_scale


func _on_inventory_changed(_slots: Array[Dictionary], _revision: int) -> void:
	# Force a re-read: the selected slot's contents may have changed without the selection moving.
	_item_id = &"￿"


func _selected_hotbar_index() -> int:
	var ui: Node = get_node_or_null(^"/root/InventoryUI")
	if ui == null or not ui.has_method("selected_hotbar_slot"):
		return 0
	return int(ui.call("selected_hotbar_slot"))
