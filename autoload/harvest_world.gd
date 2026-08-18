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
## What each asset harvests as, keyed by the asset alone (F-114). Replaces the three-entry table
## this file used to carry, which is why 62 trees, 198 rocks and 794 bushes were painted scenery.
const HarvestLib := preload("res://systems/harvesting/harvest_library.gd")
## Both maps' harvestable holders. Playtest Hollow groups every authored prop and this file
## filters by the `asset` meta; Hollowmere instances its props through MultiMesh and so gives only
## its harvestable props a node of their own, in a group of their own. Until this was a list,
## Hollowmere — the main scene — had 77 trees and ore nodes that could not be harvested, because
## the group this looked for was one no node on that map was ever in.
const HOLDER_GROUPS: Array[StringName] = [
	&"playtest_hollow_asset", &"authored_world_harvestable",
]
const HARVESTABLE_GROUP: StringName = &"harvestable"
const WIRED_META: StringName = &"mire_harvestable_wired"
const ORIGINAL_VISUAL_META: StringName = &"mire_harvestable_original_visual"
const MAX_RAY_DISTANCE_M: float = 4.0
## Set by `world/gen/authored_world.gd` on a harvestable that stays inside a chunk's MultiMesh
## batch: the batch's meshes, and this prop's instance index within every one of them.
const BATCH_MESHES_META: StringName = &"batch_meshes"
const BATCH_INDEX_META: StringName = &"batch_index"
const BATCH_TRANSFORMS_META: StringName = &"batch_transforms"

## Definition path -> loaded resource. Keyed by path rather than by asset because one definition
## covers a whole family — every `tree_*` is one `wild_tree.tres`.
var _definitions: Dictionary[String, Resource] = {}
var _refresh_scheduled: bool = false
var _last_reported_count: int = -1
var _observed_scene_id: int = 0


func _ready() -> void:
	_load_definitions()
	get_tree().node_added.connect(_on_node_added)
	_schedule_refresh()


## F-113/F-101: this file used to listen for `attack` itself. `PlayerController` handles the same
## press and calls `CombatService.request_attack()` without marking it handled, so ONE click applied
## `HarvestableDef.damage_per_hit` here AND `WeaponDef.damage` through combat — which is most of why
## a single axe swing felled a whole tree. Combat is the only damage source now: it is host-resolved,
## it knows which tool you are holding, and it already targets everything in `&"damageable"`.
## `try_harvest_from_camera()` below stays as an API for checks and for any future interact verb.


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
	for group: StringName in HOLDER_GROUPS:
		for candidate: Node in get_tree().get_nodes_in_group(group):
			if candidate is Node3D and (scene == candidate or scene.is_ancestor_of(candidate)):
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


## F-076: ground truth for "does this map's layout actually have harvestable props" — read
## straight from the raw layout JSON's `props` array, never through `HOLDER_GROUPS`. Unlike
## EnemyWorld's nest kind, this needed no new convention: every generator already marks a prop
## `"harvestable": true` in its own layout regardless of what it names the prop's holder group.
## `wired_harvestables()` above is the other half — what this file actually wired — and keeping
## the two independent is what lets `tools/world_contract_check.gd` catch a future map whose
## holder group `HOLDER_GROUPS` does not yet list, the exact shape Hollowmere shipped in with 77
## dead trees before this task's group was added.
func expected_harvestable_count(layout: Dictionary) -> int:
	var count: int = 0
	for prop_value: Variant in (layout.get("props", []) as Array):
		var prop := prop_value as Dictionary
		if prop == null:
			continue
		# F-114 moved the decision from the placement to the asset, so ground truth moved with it.
		# The layout's own flag is still counted, for a layout authored before the table existed.
		var asset_id := StringName(String(prop.get("asset", "")))
		if bool(prop.get("harvestable", false)) or HarvestLib.is_harvestable(asset_id):
			count += 1
	return count


## Only a holder entering the tree warrants a rescan. Both map generators add a holder to its group
## BEFORE add_child (and packed scenes instantiate with their groups set), so membership is already
## visible here. Without this filter, every node the game ever adds — audio one-shots, enemies,
## build pieces — scheduled a full multi-group scene rescan, which under steady spawn churn meant
## one per frame for the life of the game (F-099).
func _on_node_added(node: Node) -> void:
	for group: StringName in HOLDER_GROUPS:
		if node.is_in_group(group):
			_schedule_refresh()
			return


func _schedule_refresh() -> void:
	if _refresh_scheduled:
		return
	_refresh_scheduled = true
	call_deferred("refresh_current_scene")


func _load_definitions() -> void:
	for path: String in HarvestLib.definition_paths():
		var definition: Resource = load(path)
		if definition == null:
			MireLog.error(&"harvest", "cannot load harvestable definition %s" % path)
			continue
		_definitions[path] = definition


## The definition this asset harvests as, or null when the asset is scenery.
func definition_for(asset_id: StringName) -> Resource:
	var path: String = HarvestLib.definition_path_for(asset_id)
	if path.is_empty():
		return null
	return _definitions.get(path, null)


func _wire_holder(holder: Node3D, scene: Node) -> void:
	if holder == null or holder.has_meta(WIRED_META):
		return
	var asset_id := StringName(String(holder.get_meta(&"asset", "")))
	var definition: Resource = definition_for(asset_id)
	if definition == null:
		return

	var harvestable: Node3D = HARVESTABLE_SCRIPT.new() as Node3D
	harvestable.name = "Harvestable"
	harvestable.set("definition", definition)
	harvestable.set_meta(&"layout_index", _layout_index(holder.name))
	harvestable.set_meta(&"asset", asset_id)

	if holder.has_meta(BATCH_MESHES_META):
		_wire_batch_holder(holder, harvestable)
		return
	_wire_node_holder(holder, scene, asset_id, definition, harvestable)


## The common case since F-114: hundreds of bushes and saplings whose geometry never leaves the
## chunk's MultiMesh. There is no visual node to hide and no collider to reparent — the whole prop
## is one slot in a batch — so the holder gets the Harvestable and a hook that zeroes that slot.
func _wire_batch_holder(holder: Node3D, harvestable: Node3D) -> void:
	harvestable.call("set_visual_hook", _batch_visual_hook(holder))
	holder.add_child(harvestable)
	holder.set_meta(WIRED_META, true)


## A harvestable drawn as its own node: a tree, an ore node, a boulder. Its authored mesh is either
## replaced by the definition's damage-state scenes (the three multi-state harvestables) or kept and
## merely hidden on depletion (every family added by F-114, which ships no per-species state art).
func _wire_node_holder(
	holder: Node3D, scene: Node, asset_id: StringName, definition: Resource, harvestable: Node3D
) -> void:
	# The visual, found two ways because the two maps store it two ways. A holder that carries its
	# own `Visual` child answers directly; the Hollow keeps its visuals in a parallel
	# `AuthoredVisuals` tree and is matched by index.
	var original_visual: Node3D = holder.get_node_or_null(^"Visual") as Node3D
	if original_visual == null:
		var layout_index: int = _layout_index(holder.name)
		if layout_index < 0:
			MireLog.error(&"harvest", "cannot derive layout index from %s" % holder.name)
			return
		var visual_name := "Placed_%03d_%s" % [layout_index, asset_id]
		var authored_root: Node = scene.get_node_or_null(^"AuthoredVisuals")
		original_visual = (
			authored_root.find_child(visual_name, true, false) as Node3D if authored_root != null else null
		)
	if original_visual == null:
		MireLog.error(&"harvest", "cannot find authored visual for %s" % holder.name)
		return

	var keeps_authored_visual: bool = bool(definition.call("uses_authored_visual"))

	# Collision is optional, and only since F-114. A prop that brings its own damage-state geometry
	# must hand its collider over — the states swap under it and something has to own the shape —
	# but a family that keeps the world builder's own mesh may legitimately have no collider at all
	# (soft flora is walked through). `CombatService` finds its target in the `&"damageable"` group
	# by distance and arc, not by raycast, so a collider-less harvestable is still swingable.
	var collision_body: CollisionObject3D = holder.get_node_or_null(^"CollisionBody") as CollisionObject3D
	if collision_body == null and not keeps_authored_visual:
		MireLog.error(&"harvest", "%s has no CollisionBody" % holder.name)
		return
	if keeps_authored_visual:
		harvestable.call("set_visual_hook", func(shown: bool) -> void:
			if is_instance_valid(original_visual):
				original_visual.visible = shown
		)

	# Reparent while Harvestable is still outside the tree, so its _ready() discovers collision and
	# builds its synchronizer only after the complete, identical subtree exists on every peer.
	if collision_body != null:
		holder.remove_child(collision_body)
		harvestable.add_child(collision_body)
	holder.add_child(harvestable)

	# Only a definition that brings its own intact geometry hides the authored mesh, and only that
	# hidden mesh is marked. One that does not IS the authored mesh: hiding it here would delete the
	# tree the moment it was wired, and marking it would claim a duplicate that does not exist.
	if not keeps_authored_visual:
		original_visual.visible = false
		original_visual.set_meta(ORIGINAL_VISUAL_META, true)
	holder.set_meta(WIRED_META, true)


## Hides or restores ONE instance of a MultiMesh by zeroing its transform, which is the only handle
## a batched copy has — it is not a node and has no `visible`. The intact transforms come from the
## world builder's own `batch_transforms` meta rather than from `get_instance_transform()`: that
## read is a RenderingServer round trip, and under the dummy renderer every headless check runs on
## it answers identity, which would restore the bush at the world origin.
func _batch_visual_hook(holder: Node3D) -> Callable:
	var meshes: Array = holder.get_meta(BATCH_MESHES_META, []) as Array
	var index: int = int(holder.get_meta(BATCH_INDEX_META, -1))
	var intact: Array = holder.get_meta(BATCH_TRANSFORMS_META, []) as Array
	if intact.size() != meshes.size():
		MireLog.error(&"harvest", "%s batch transforms do not match its meshes" % holder.name)
		return func(_shown: bool) -> void: pass

	return func(shown: bool) -> void:
		for slot: int in meshes.size():
			var multimesh := meshes[slot] as MultiMesh
			if multimesh == null or index < 0 or index >= multimesh.instance_count:
				continue
			var placement: Transform3D = intact[slot] as Transform3D
			multimesh.set_instance_transform(
				index,
				placement if shown else Transform3D(Basis().scaled(Vector3.ZERO), placement.origin)
			)


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
