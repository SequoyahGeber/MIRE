extends Node

## Runtime bridge between the authored playtest map and task 2.3's Harvestable component.
##
## The map's deterministic layout builder creates one holder per prop, with collision and `asset`
## metadata. This autoload discovers those holders after scene construction, replaces only intact
## A-001 resource props with live Harvestable nodes, hides the matching authored-map visual, and
## lets Harvestable instantiate the definition's damage/depleted states in the same transform.
## No map scene or generated layout file needs gameplay-specific edits.
##
## NETWORK AUTHORITY (ARCHITECTURE.md section 2.2): world mutation remains HOST-owned inside
## Harvestable. This bridge runs identically on every peer so RPC and synchronizer node paths match.
## The attack ray is client-local input; it only calls Harvestable.request_hit(), whose host validates
## range/cooldown and supplies damage/yield.

const HARVESTABLE_SCRIPT := preload("res://systems/harvesting/harvestable.gd")
const HOLDER_GROUP: StringName = &"playtest_hollow_asset"
const HARVESTABLE_GROUP: StringName = &"harvestable"
const WIRED_META: StringName = &"mire_harvestable_wired"
const ORIGINAL_VISUAL_META: StringName = &"mire_harvestable_original_visual"
const MAX_RAY_DISTANCE_M: float = 4.0

const DEFINITION_PATHS: Dictionary[StringName, String] = {
	&"harvest_tree_intact": "res://content/harvestables/tree.tres",
	&"stone_node_intact": "res://content/harvestables/stone_node.tres",
	&"iron_node_intact": "res://content/harvestables/iron_node.tres",
}

var _definitions: Dictionary[StringName, Resource] = {}
var _refresh_scheduled: bool = false
var _last_reported_count: int = -1
var _observed_scene_id: int = 0


func _ready() -> void:
	_load_definitions()
	get_tree().node_added.connect(_on_node_added)
	_schedule_refresh()


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed(&"attack") or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	if try_harvest_from_camera():
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	# The engine may assign the initial main scene after this autoload's first deferred refresh.
	# Observe that assignment directly; node_added still handles holders built later inside the scene.
	var scene: Node = get_tree().current_scene
	var scene_id: int = scene.get_instance_id() if is_instance_valid(scene) else 0
	if scene_id == _observed_scene_id:
		return
	_observed_scene_id = scene_id
	_schedule_refresh()


## Raycast from the active first-person camera and request a hit on the Harvestable owning the
## collider. Returns true when a live harvestable was targeted, whether or not the host accepts it.
func try_harvest_from_camera() -> bool:
	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera == null or camera.get_world_3d() == null:
		return false
	var origin: Vector3 = camera.global_position
	var destination: Vector3 = origin - camera.global_basis.z * MAX_RAY_DISTANCE_M
	var query := PhysicsRayQueryParameters3D.create(origin, destination)
	query.collide_with_areas = true
	var player_body: CollisionObject3D = _collision_ancestor(camera)
	if player_body != null:
		query.exclude = [player_body.get_rid()]
	var hit: Dictionary = camera.get_world_3d().direct_space_state.intersect_ray(query)
	var collider: Node = hit.get("collider") as Node
	return request_harvest_from_collider(collider)


## Public for combat adapters and checks: walk from a hit collider to its harvestable root.
func request_harvest_from_collider(collider: Node) -> bool:
	var cursor: Node = collider
	while cursor != null:
		if cursor.is_in_group(HARVESTABLE_GROUP) and cursor.has_method("request_hit"):
			cursor.call("request_hit")
			return true
		cursor = cursor.get_parent()
	return false


func refresh_current_scene() -> void:
	_refresh_scheduled = false
	var scene: Node = get_tree().current_scene
	if scene == null:
		return
	for candidate: Node in get_tree().get_nodes_in_group(HOLDER_GROUP):
		if scene == candidate or scene.is_ancestor_of(candidate):
			_wire_holder(candidate as Node3D, scene)
	var count: int = wired_harvestables().size()
	if count != _last_reported_count:
		_last_reported_count = count
		MireLog.info(&"harvest", "wired %d live harvestable prop(s)" % count)


func wired_harvestables() -> Array[Node3D]:
	var result: Array[Node3D] = []
	var scene: Node = get_tree().current_scene
	if scene == null:
		return result
	for candidate: Node in get_tree().get_nodes_in_group(HARVESTABLE_GROUP):
		if candidate is Node3D and (scene == candidate or scene.is_ancestor_of(candidate)):
			result.append(candidate as Node3D)
	return result


func _on_node_added(_node: Node) -> void:
	_schedule_refresh()


func _schedule_refresh() -> void:
	if _refresh_scheduled:
		return
	_refresh_scheduled = true
	call_deferred("refresh_current_scene")


func _load_definitions() -> void:
	for asset_id: StringName in DEFINITION_PATHS:
		var path: String = DEFINITION_PATHS[asset_id]
		var definition: Resource = load(path)
		if definition == null:
			MireLog.error(&"harvest", "cannot load definition %s for %s" % [path, asset_id])
			continue
		_definitions[asset_id] = definition


func _wire_holder(holder: Node3D, scene: Node) -> void:
	if holder == null or holder.has_meta(WIRED_META):
		return
	var asset_id := StringName(String(holder.get_meta(&"asset", "")))
	if not _definitions.has(asset_id):
		return

	var layout_index: int = _layout_index(holder.name)
	if layout_index < 0:
		MireLog.error(&"harvest", "cannot derive layout index from %s" % holder.name)
		return
	var visual_name := "Placed_%03d_%s" % [layout_index, asset_id]
	var authored_root: Node = scene.get_node_or_null(^"AuthoredVisuals")
	var original_visual: Node3D = (
		authored_root.find_child(visual_name, true, false) as Node3D if authored_root != null else null
	)
	if original_visual == null:
		MireLog.error(&"harvest", "cannot find authored visual %s" % visual_name)
		return

	var collision_body: CollisionObject3D = holder.get_node_or_null(^"CollisionBody") as CollisionObject3D
	if collision_body == null:
		MireLog.error(&"harvest", "%s has no CollisionBody" % holder.name)
		return

	var harvestable: Node3D = HARVESTABLE_SCRIPT.new() as Node3D
	harvestable.name = "Harvestable"
	harvestable.set("definition", _definitions[asset_id])
	harvestable.set_meta(&"layout_index", layout_index)
	harvestable.set_meta(&"asset", asset_id)

	# Reparent while Harvestable is still outside the tree, so its _ready() discovers collision and
	# builds its synchronizer only after the complete, identical subtree exists on every peer.
	holder.remove_child(collision_body)
	harvestable.add_child(collision_body)
	holder.add_child(harvestable)

	original_visual.visible = false
	original_visual.set_meta(ORIGINAL_VISUAL_META, true)
	holder.set_meta(WIRED_META, true)


func _layout_index(holder_name: StringName) -> int:
	var value := String(holder_name)
	var separator: int = value.rfind("_")
	if separator < 0:
		return -1
	var suffix: String = value.substr(separator + 1)
	return suffix.to_int() if suffix.is_valid_int() else -1


func _collision_ancestor(node: Node) -> CollisionObject3D:
	var cursor: Node = node
	while cursor != null:
		if cursor is CollisionObject3D:
			return cursor as CollisionObject3D
		cursor = cursor.get_parent()
	return null
