extends SceneTree

## Focused offline proof for F-158: `bog_crawler` (task 4.11's corrupted spawn-table variant) reused
## `enemy_crawler.glb` as-is, with no tint or VFX to tell it apart from a normal `crawler` — mechanically
## real, invisible to a player. The fix is `EnemyDef.visual_tint` (systems/enemies/enemy_def.gd),
## applied as a per-surface albedo multiply in `Enemy._build_visual()` (systems/enemies/enemy.gd).
##
## This checks the fix at the level a player would notice it — the actual rendered material — not just
## that the field round-trips: it spawns one of each, walks their built visuals, and asserts the two
## carry genuinely different albedo colours while still sharing the same model resource (no new art was
## authored, matching D-073 and the finding's own reasoning for why 4.11 didn't fix this itself).
##
## Prefer `--windowed` over plain `--headless` here: setting a duplicated material as a surface
## override triggers harmless `material_get_instance_shader_parameters` ERROR spam under the dummy
## renderer (no material RID to query) that a real backend never produces. Assertions are identical
## either way — CPU-side `albedo_color` reads, never a render — but a clean run is easier to trust.

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame
	var world: Node = root.get_node_or_null(^"EnemyWorld")
	check(world != null, "EnemyWorld autoload exists")
	if world == null:
		finish()
		return

	check(bool(world.call("has_def", &"crawler")), "the crawler definition is registered")
	check(bool(world.call("has_def", &"bog_crawler")), "the bog_crawler definition is registered")
	var crawler_def: Resource = world.call("get_def", &"crawler")
	var bog_def: Resource = world.call("get_def", &"bog_crawler")
	if crawler_def == null or bog_def == null:
		check(false, "both definitions loaded")
		finish()
		return
	check((bog_def.call("validation_errors") as PackedStringArray).is_empty(),
		"bog_crawler's definition validates")

	check(crawler_def.get("visual_tint") == Color(1.0, 1.0, 1.0, 1.0),
		"the default crawler keeps EnemyDef's no-op tint — untouched enemies render unchanged")
	check(bog_def.get("visual_tint") != Color(1.0, 1.0, 1.0, 1.0),
		"bog_crawler is authored with a real tint")
	check(bog_def.get("model") == crawler_def.get("model"),
		"bog_crawler still reuses enemy_crawler.glb — no new art authored (D-073)")

	var crawler: Node3D = world.call("host_spawn", &"crawler", Vector3(0.0, 0.0, 0.0))
	var bog: Node3D = world.call("host_spawn", &"bog_crawler", Vector3(20.0, 0.0, 0.0))
	check(crawler != null and bog != null, "the host spawns one of each")
	if crawler == null or bog == null:
		finish()
		return
	await process_frame

	var crawler_meshes: Array[MeshInstance3D] = _meshes_of(crawler)
	var bog_meshes: Array[MeshInstance3D] = _meshes_of(bog)
	check(not crawler_meshes.is_empty() and not bog_meshes.is_empty(),
		"both instances built a visual with at least one mesh")
	if crawler_meshes.is_empty() or bog_meshes.is_empty():
		finish()
		return

	check(_all_overrides_null(crawler_meshes),
		"the untinted crawler carries no surface material override — _apply_visual_tint() is a true no-op")

	var any_tinted: bool = false
	var any_mismatch: bool = false
	for index: int in mini(crawler_meshes.size(), bog_meshes.size()):
		var base_mesh: Mesh = crawler_meshes[index].mesh
		if base_mesh == null:
			continue
		for surface: int in base_mesh.get_surface_count():
			var original: Material = crawler_meshes[index].get_active_material(surface)
			var tinted: Material = bog_meshes[index].get_surface_override_material(surface)
			if tinted == null:
				continue
			any_tinted = true
			if not (original is BaseMaterial3D) or not (tinted is BaseMaterial3D):
				continue
			var expected: Color = (
				(original as BaseMaterial3D).albedo_color * (bog_def.get("visual_tint") as Color)
			)
			if not (tinted as BaseMaterial3D).albedo_color.is_equal_approx(expected):
				any_mismatch = true
			if (tinted as BaseMaterial3D).albedo_color.is_equal_approx(
				(original as BaseMaterial3D).albedo_color
			):
				any_mismatch = true
	check(any_tinted, "bog_crawler's visual carries at least one tinted surface override")
	check(not any_mismatch, "every tinted surface equals the original albedo times visual_tint")

	# Standing rule 4 (docs/SPECS.md): declare the dummy renderer's own provoked noise by pattern
	# rather than silencing it. `--windowed` never produces this line at all (see the header note);
	# declaring it here is only for a plain `--headless` run.
	print(
		"BOG_CRAWLER_CHECK failures=%d · EXPECTED_ERROR_PATTERNS=\"Parameter \\\"material\\\" is null\""
		% failures
	)
	finish()


func _meshes_of(enemy: Node3D) -> Array[MeshInstance3D]:
	var visual: Node = enemy.get_node_or_null(^"EnemyVisual")
	var result: Array[MeshInstance3D] = []
	if visual == null:
		return result
	for node: Node in visual.find_children("*", "MeshInstance3D", true, false):
		result.append(node as MeshInstance3D)
	return result


func _all_overrides_null(meshes: Array[MeshInstance3D]) -> bool:
	for mesh_instance: MeshInstance3D in meshes:
		if mesh_instance.mesh == null:
			continue
		for surface: int in mesh_instance.mesh.get_surface_count():
			if mesh_instance.get_surface_override_material(surface) != null:
				return false
	return true


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
