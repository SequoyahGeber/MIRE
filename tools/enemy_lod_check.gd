extends SceneTree

## Direct proof for task 7.7 (docs/SPECS.md §7.7): enemy render LOD. Unlike F-144's props/
## undergrowth/harvestables, an enemy can't be merged into a static batched mesh — each is
## independently animated — so the lever here is a visibility-range self-fade
## (`Enemy.VISIBILITY_RANGE_END_M`/`VISIBILITY_RANGE_FADE_MARGIN_M`, set on every MeshInstance3D
## under an enemy's visual in `_build_visual()`).
##
##   .agent/bin/agent godot --script tools/enemy_lod_check.gd
##
## Spawns through the REGISTERED EnemyWorld autoload's real `host_spawn()` (F-068's lesson — a
## private harness copy would test nothing real), for every enemy def currently authored in
## content/enemies/, so a future kind added without a model reference is caught here too.

var failures: int = 0
var world: Node


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	if not _check_wiring():
		finish()
		return

	var defs: Dictionary = world.get(&"defs")
	check(not defs.is_empty(), "EnemyWorld has at least one enemy def loaded")

	for def_id: StringName in defs.keys():
		var enemy: Node3D = world.call(&"host_spawn", def_id, Vector3.ZERO)
		check(enemy != null, "EnemyWorld.host_spawn('%s') returns a live enemy" % def_id)
		if enemy == null:
			continue
		await process_frame

		var meshes: Array[Node] = enemy.find_children("*", "MeshInstance3D", true, false)
		check(not meshes.is_empty(), "'%s' visual has at least one MeshInstance3D" % def_id)
		for node: Node in meshes:
			var mesh: MeshInstance3D = node as MeshInstance3D
			check(mesh.visibility_range_end > 0.0,
				"'%s' mesh '%s' has a nonzero visibility_range_end" % [def_id, mesh.name])
			check(mesh.visibility_range_end_margin > 0.0,
				"'%s' mesh '%s' has a fade margin (dithered, not a hard pop)" % [def_id, mesh.name])
			check(mesh.visibility_range_fade_mode == GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF,
				"'%s' mesh '%s' fades itself, not its dependencies" % [def_id, mesh.name])

	world.call(&"host_despawn_all")
	await process_frame
	check(int(world.call(&"live_count")) == 0, "field is clear after host_despawn_all()")

	# The loop above spawns bog_crawler too (it walks every authored def), so F-158's visual_tint
	# (systems/enemies/enemy.gd `_apply_visual_tint()`) runs for real and can — observed
	# intermittently, not every run — provoke the dummy renderer's own harmless
	# `material_get_instance_shader_parameters` noise on a surface override. See
	# tools/bog_crawler_check.gd's header for why. Standing rule 4 (docs/SPECS.md): declare by pattern
	# rather than let an occasional run fail on undeclared engine noise.
	print("EXPECTED_ERROR_PATTERNS=\"Parameter \\\"material\\\" is null\"")
	finish()


func _check_wiring() -> bool:
	print("== the shipped project actually has EnemyWorld ==")
	world = root.get_node_or_null(^"EnemyWorld")
	check(world != null, "EnemyWorld autoload exists")
	if world == null:
		return false
	check(world.has_method(&"host_spawn"), "EnemyWorld exposes host_spawn()")
	world.call(&"host_despawn_all")
	return true


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	print("\n%d failure(s)" % failures)
	quit(0 if failures == 0 else 1)
