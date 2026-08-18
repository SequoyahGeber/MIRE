extends SceneTree

## F-097: does environmental VFX reach the map people actually play?
##
## The check this replaces booted `playtest_hollow`, which 2.1k deprecated, and passed for a day
## while the shipped map had no wind and no firelight at all. This one reads `main_scene` out of
## `project.godot`, so it cannot drift away from the map again, and it exercises the real
## `EnvironmentVfx` autoload rather than a private copy of the script.
##
## It asserts three things a name-keyed system could never satisfy:
##   1. wind materials land on **MultiMesh** geometry, which is all the world's foliage;
##   2. emitter sites are found through the asset id, including inside instanced batches;
##   3. the effect pool stays **bounded** — 99 mire crystals must not cost 99 lights.

const VFX_SCRIPT := preload("res://autoload/environment_vfx.gd")
const FOLIAGE_SHADER := preload("res://world/environment/foliage_wind.gdshader")
const AssetVfx := preload("res://world/environment/asset_vfx_library.gd")

var failures: int = 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var scene_path := String(ProjectSettings.get_setting("application/run/main_scene", ""))
	print("main_scene = %s" % scene_path)
	var packed := load(scene_path) as PackedScene
	check(packed != null, "main scene loads")
	if packed == null:
		finish()
		return
	var scene := packed.instantiate() as Node3D
	root.add_child(scene)
	current_scene = scene

	# The shipped autoload, not a fresh instance — a check that builds its own controller cannot
	# tell you whether the registered one runs.
	var controller: Node = root.get_node_or_null(^"EnvironmentVfx")
	check(controller != null, "EnvironmentVfx is registered as an autoload")
	if controller == null:
		controller = VFX_SCRIPT.new()
		root.add_child(controller)
	# World build is deferred, and the budget pass runs on a 0.25 s timer.
	for _frame: int in 60:
		await process_frame

	var mesh_instances: int = 0
	var multimesh_instances: int = 0
	var multimesh_copies: int = 0
	var wind_multimeshes: int = 0
	var wind_meshes: int = 0
	var swaying_copies: int = 0
	for node: Node in _all_descendants(scene):
		if node is MultiMeshInstance3D:
			multimesh_instances += 1
			var multimesh := (node as MultiMeshInstance3D).multimesh
			if multimesh == null:
				continue
			multimesh_copies += multimesh.instance_count
			if _uses_wind(multimesh.mesh):
				wind_multimeshes += 1
				swaying_copies += multimesh.instance_count
		elif node is MeshInstance3D:
			mesh_instances += 1
			if _uses_wind((node as MeshInstance3D).mesh):
				wind_meshes += 1

	print("CENSUS mesh_instance3d=%d multimesh_instance3d=%d multimesh_copies=%d"
		% [mesh_instances, multimesh_instances, multimesh_copies])
	print("WIND multimesh_nodes=%d mesh_nodes=%d swaying_copies=%d assets=%d"
		% [wind_multimeshes, wind_meshes, swaying_copies, int(controller.get("sway_asset_count"))])

	var sites: Dictionary = controller.call(&"site_counts")
	var pools: Dictionary = controller.call(&"pool_counts")
	for emitter: int in sites:
		var profile: Dictionary = AssetVfx.emitter_profile(emitter)
		var site_count: int = int(sites[emitter])
		var pool_count: int = int(pools.get(emitter, 0))
		print("EMITTER %-9s sites=%-4d pool=%-3d cap=%d"
			% [_emitter_name(emitter), site_count, pool_count, int(profile.get("max_live", 0))])
		check(pool_count <= maxi(int(profile.get("max_live", 0)), 1),
			"%s pool stays within its budget" % _emitter_name(emitter))
		check(pool_count <= site_count, "%s builds no more effects than there are sites"
			% _emitter_name(emitter))

	# The bug this check exists for: both were zero on this map while the old check was green.
	check(wind_multimeshes > 0, "wind reaches instanced geometry, not just loose meshes")
	check(swaying_copies > 1000, "wind reaches the scatter field, not a handful of props")
	check(int(controller.get("fire_source_count")) >= 3, "the map's fires are found")
	check(sites.has(AssetVfx.Emitter.CRYSTAL), "mire crystals register as emitters")
	# F-118. The number matters as much as the presence: one site per TREE, not one per mesh part
	# of a tree — a GLB canopy arrives as around forty MeshInstance3D nodes and the first version of
	# this registered 1,925 sites for 94 trees.
	var leaf_sites: int = int(sites.get(AssetVfx.Emitter.LEAF_FALL, 0))
	check(leaf_sites > 40, "the map's canopies shed leaves (%d sites)" % leaf_sites)
	check(leaf_sites < 200,
		"one leaf site per tree, not one per mesh part of a tree (%d)" % leaf_sites)

	# Scalability: the world holds hundreds of emitter sites and must not build hundreds of nodes.
	var total_sites: int = 0
	var total_pool: int = 0
	for emitter: int in sites:
		total_sites += int(sites[emitter])
	for emitter: int in pools:
		total_pool += int(pools[emitter])
	print("BUDGET sites=%d effect_nodes=%d live=%d"
		% [total_sites, total_pool, int(controller.call(&"live_count"))])
	check(total_sites > 100, "the map really does hold hundreds of emitter sites")
	# Derived, not a magic number. The bound IS the sum of every class's own cap, so adding an
	# emitter class raises it by exactly that class's budget and nothing else — a hardcoded 32 went
	# red the moment F-118 added leaf fall, which is a check failing at the arithmetic rather than
	# at the property it exists to protect.
	var budget_ceiling: int = 0
	for emitter: int in AssetVfx.EMITTER_PROFILES:
		budget_ceiling += int((AssetVfx.EMITTER_PROFILES[emitter] as Dictionary).get("max_live", 0))
	check(total_pool <= budget_ceiling,
		"effect nodes are bounded by the budget, not by the world (%d <= %d)"
		% [total_pool, budget_ceiling])
	check(total_pool < total_sites / 4,
		"the pool is far smaller than the world it covers (%d nodes for %d sites)"
		% [total_pool, total_sites])

	print("ENVIRONMENT_VFX_HOLLOWMERE_CHECK failures=%d" % failures)
	finish()


func _uses_wind(mesh: Mesh) -> bool:
	if mesh == null:
		return false
	for surface: int in mesh.get_surface_count():
		var material := mesh.surface_get_material(surface)
		if material is ShaderMaterial and (material as ShaderMaterial).shader == FOLIAGE_SHADER:
			return true
	return false


func _emitter_name(emitter: int) -> String:
	var names: PackedStringArray = [
		"NONE", "CAMPFIRE", "FORGE", "EMBER", "CRYSTAL", "SPORE", "GLOW", "LEAF_FALL"
	]
	return names[emitter] if emitter < names.size() else str(emitter)


func _all_descendants(node: Node) -> Array[Node]:
	var result: Array[Node] = []
	for child: Node in node.get_children():
		result.append(child)
		result.append_array(_all_descendants(child))
	return result


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
