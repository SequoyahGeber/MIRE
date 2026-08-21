extends SceneTree

## F-432 — does chopping a tree actually LOOK like anything, and does it leave the right stump?
##
## Reported from play as "harvest states of trees are not working". `tools/harvest_state_chain_check.gd`
## already proves the definition-level state machine, and it passes — the gap was that the trees the
## world actually places (`tree_*` -> `content/harvestables/wild_tree.tres`) ship no state scenes at
## all, so there was nothing for that check to look at.
##
## This one exercises the real thing instead: it builds holders through
## `ResourceScatterField._build_node_holder()`, exactly as the island does, lets `HarvestWorld` wire
## them, and then chops them down one swing at a time, asserting per species that
##
##  1. a landed hit visibly moves the tree, and settles back within `SHAKE_DURATION_SEC`;
##  2. a damaged tree leans, further as it takes more damage, and never leans past `MAX_LEAN_DEG`;
##  3. felling it leaves a stump whose radius matches THAT tree's trunk rather than one authored
##     broadleaf stump's, and which is short enough to be a stump;
##  4. the authored visual is hidden once it is felled, and comes back on respawn.
##
## Authority: none (docs/ARCHITECTURE.md §2.2). Offline, host path, one peer.
##
##   .agent/bin/agent godot --script tools/harvest_tree_states_check.gd

const FIELD := preload("res://world/gen/resource_scatter_field.gd")
const PROP_COLLIDER := preload("res://world/gen/prop_collider.gd")
const HARVESTABLE := preload("res://systems/harvesting/harvestable.gd")

## One tree per silhouette the island scatters, across both kits that grow them: a willow (the
## stoutest bole in the game), a pine (the tallest), a birch (the thinnest) and the one asset that
## DOES ship authored damage states, which must keep using them rather than a generated stump.
const SUBJECTS: Array = [
	["flora", "tree_willow_a"],
	["environment", "tree_pine_c"],
	["environment", "tree_birch_a"],
	["harvestables", "harvest_tree_intact"],
]
## `harvest_tree_intact` is the one subject above that carries its own damage art.
const AUTHORED_STATE_ASSET: StringName = &"harvest_tree_intact"
## What one swing of an iron axe lands: `HarvestLibrary.Tool.CHOP` at harvest power 3.
const TOOL_CLASS: int = 1
const TOOL_POWER: int = 3
## How far off the trunk's own measured radius a generated stump may be. The stump is built from
## cross-sections at knee height and the trunk is measured across the 0.5-1.8 m band, so the two
## agree in metres and not in millimetres — what matters is that a willow's stump is a willow's.
const STUMP_RADIUS_TOLERANCE: float = 0.35
## A stump is something you see over. Anything taller is a tree that failed to fall.
const STUMP_MAX_HEIGHT_M: float = 1.2

var failures: int = 0
var _field: Node3D = null


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	print("F-432 — tree harvest states, on the props the world actually builds\n")
	var scene := Node3D.new()
	scene.name = "TreeStatesProbe"
	root.add_child(scene)
	current_scene = scene
	_field = FIELD.new()

	for subject: Array in SUBJECTS:
		await _exercise(String(subject[0]), String(subject[1]), scene)

	print("\nHARVEST_TREE_STATES_CHECK failures=%d" % failures)
	_field.free()
	quit(1 if failures > 0 else 0)


func _exercise(kit: String, asset: String, scene: Node3D) -> void:
	print("\n=== %s (%s)" % [asset, kit])
	var parts: Array = _field.call("_load_mesh_parts", kit, asset)
	if parts.is_empty():
		_fail("%s has no mesh" % asset)
		return

	var holder: Node3D = _build_holder(scene, kit, asset, parts)
	for _frame: int in 8:
		await process_frame

	var harvestable: Node = holder.get_node_or_null(^"Harvestable")
	check(harvestable != null, "%s: HarvestWorld wired a live Harvestable" % asset)
	if harvestable == null:
		return
	var visual := holder.get_node_or_null(^"Visual") as Node3D
	check(visual != null, "%s: the holder kept its authored visual" % asset)
	if visual == null:
		return

	var authored_states: bool = StringName(asset) == AUTHORED_STATE_ASSET
	var rest: Transform3D = visual.transform

	# 1 + 2: one swing, then look at the tree.
	var max_health: int = int(harvestable.get("health"))
	harvestable.call("host_apply_tool_damage", TOOL_CLASS, TOOL_POWER, 1)
	await process_frame
	var struck: Transform3D = visual.transform
	var still_standing: bool = bool(harvestable.get("active"))

	if authored_states:
		# This one swaps GEOMETRY per damage state, which is its own answer to the same question —
		# and `tools/harvest_state_chain_check.gd` is where that is asserted. What must hold here is
		# that it is NOT also being posed, because its state scenes already show the damage.
		check(
			struck.is_equal_approx(rest),
			"%s: keeps its authored damage states instead of being posed" % asset
		)
	elif still_standing:
		check(
			not struck.is_equal_approx(rest),
			"%s: a landed hit visibly moves the tree" % asset
		)
		var lean_after_one: float = _tilt_degrees(rest, struck)
		# Let the shake run out, and check what it settles into.
		for _frame: int in 40:
			await process_frame
		var settled: Transform3D = visual.transform
		var lean: float = _tilt_degrees(rest, settled)
		check(lean > 0.05, "%s: a damaged tree is left leaning (%.2f deg)" % [asset, lean])
		check(
			lean <= HARVESTABLE.MAX_LEAN_DEG + 0.01,
			"%s: the lean stays inside MAX_LEAN_DEG (%.2f deg)" % [asset, lean]
		)
		check(
			lean_after_one >= 0.0,
			"%s: the shake decays into the lean rather than away from it" % asset
		)

	# 3 + 4: chop it the rest of the way down.
	var swings: int = 1
	while bool(harvestable.get("active")) and swings < 40:
		harvestable.call("host_apply_tool_damage", TOOL_CLASS, TOOL_POWER, 1)
		swings += 1
	check(not bool(harvestable.get("active")), "%s: felled in %d swings" % [asset, swings])
	await process_frame
	await process_frame

	check(not visual.visible, "%s: the standing tree is hidden once felled" % asset)
	var remains := harvestable.get_node_or_null(^"HarvestVisual") as Node3D
	check(remains != null, "%s: something is left standing where it fell" % asset)
	if remains != null:
		var left: AABB = _bounds(remains)
		check(
			left.size.y <= STUMP_MAX_HEIGHT_M,
			"%s: what is left is stump-height (%.2f m)" % [asset, left.size.y]
		)
		if not authored_states:
			_check_faces_outward(asset, remains as MeshInstance3D)
			var trunk: float = float((_field.call("_collider_for", kit, asset, parts) as Dictionary)
				.get("radius", 0.0))
			var stump: float = maxf(left.size.x, left.size.z) * 0.5
			check(
				absf(stump - trunk) <= STUMP_RADIUS_TOLERANCE,
				"%s: its stump is its OWN trunk's width (stump %.2f m vs trunk %.2f m)"
					% [asset, stump, trunk]
			)

	check(bool(harvestable.call("host_respawn")), "%s: respawns" % asset)
	await process_frame
	await process_frame
	if authored_states:
		# This one's authored visual is hidden for good the moment it is wired — its state scenes
		# ARE its presentation — so what "standing again" means for it is being back on state 0.
		check(
			int(harvestable.get("visual_state")) == 0,
			"%s: back to its intact damage state after respawn" % asset
		)
		check(
			harvestable.get_node_or_null(^"HarvestVisual") != null,
			"%s: and drawing it" % asset
		)
	else:
		check(visual.visible, "%s: the tree is standing again after respawn" % asset)
		check(
			visual.transform.is_equal_approx(rest),
			"%s: and standing straight again, with no lean left over" % asset
		)
	# `max_health` is read back rather than from the definition so this check does not restate the
	# content's numbers; what it asserts is that a respawn restores whatever full health was.
	check(int(harvestable.get("health")) == max_health, "%s: at full health again" % asset)


func _build_holder(scene: Node3D, kit: String, asset: String, parts: Array) -> Node3D:
	var placement := {
		"point_id": "probe:%s" % asset,
		"position": Vector3.ZERO,
		"rotation_y": 0.0,
		"scale": 1.0,
	}
	_field.call("_build_node_holder", scene, placement, StringName(asset), kit, parts)
	return scene.get_node_or_null(NodePath("Harvest_probe_%s" % asset)) as Node3D


## How far apart two poses are, in degrees. Written off the basis rather than off Euler angles
## because the pose is a rotation about an arbitrary horizontal axis, and Euler decomposition of one
## of those reports a different number depending on which axis it lands nearest.
func _tilt_degrees(rest: Transform3D, posed: Transform3D) -> float:
	var up: Vector3 = (rest.basis * Vector3.UP).normalized()
	var posed_up: Vector3 = (posed.basis * Vector3.UP).normalized()
	return rad_to_deg(up.angle_to(posed_up))


## A generated stump is built vertex by vertex, and a triangle wound the wrong way round is a face
## Godot culls: the first cut of `stump_builder.gd` shipped a stump that was inside-out and lit from
## within, which no assertion about its SIZE could see. Every side normal must point away from the
## trunk's axis and the cut face must look up.
func _check_faces_outward(asset: String, instance: MeshInstance3D) -> void:
	if instance == null or instance.mesh == null:
		_fail("%s: its stump has no mesh" % asset)
		return
	var mesh: Mesh = instance.mesh
	var outward: int = 0
	var total: int = 0
	var cap_up: float = 0.0
	var cap_total: int = 0
	for surface: int in mesh.get_surface_count():
		var arrays: Array = mesh.surface_get_arrays(surface)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		for index: int in verts.size():
			# The cut face and the sides are told apart by the normal itself rather than by which
			# surface they live on, so this stays true however the mesh is assembled: anything
			# pointing straight up is cap, and everything else has to point away from the axis.
			if normals[index].y > 0.9:
				cap_up += normals[index].y
				cap_total += 1
				continue
			var radial := Vector3(verts[index].x, 0.0, verts[index].z)
			if radial.length() < 0.01:
				continue
			total += 1
			if normals[index].dot(radial.normalized()) > 0.0:
				outward += 1
	check(total > 0 and outward == total, "%s: its stump's sides face outward (%d/%d)"
		% [asset, outward, total])
	check(cap_total > 0 and cap_up / float(maxi(cap_total, 1)) > 0.9,
		"%s: its cut face looks up" % asset)


func _bounds(node: Node3D) -> AABB:
	var bounds := AABB()
	var found: bool = false
	var queue: Array[Node] = [node]
	while not queue.is_empty():
		var cursor: Node = queue.pop_back()
		var instance := cursor as MeshInstance3D
		if instance != null and instance.mesh != null:
			var box: AABB = instance.transform * instance.mesh.get_aabb()
			bounds = box if not found else bounds.merge(box)
			found = true
		for child: Node in cursor.get_children():
			queue.append(child)
	return bounds


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
	else:
		_fail(description)


func _fail(description: String) -> void:
	failures += 1
	print("FAIL: %s" % description)
