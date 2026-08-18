extends SceneTree

## F-076: does the map `project.godot` actually ships satisfy every system keyed to a level's
## authored content — with NO map-specific code, so a future map gets this check for free.
##
## Three systems shipped Hollowmere as the main scene while still reading exclusively for
## Playtest Hollow's group names: zero enemies, zero harvestables, and undergrowth growing on top
## of props. Nothing errored — a group name that matches no node is indistinguishable from a
## level that genuinely has none of that thing, and every consumer is correctly written to treat
## "none" as legitimate. All three were hand-patched for Hollowmere specifically
## (`tools/hollowmere_check.gd`); this is the generalized version of two of them.
##
## The trick that makes it map-agnostic: `EnemyWorld.expected_nest_count()` and
## `HarvestWorld.expected_harvestable_count()` read ground truth straight from the map's own raw
## layout JSON — never through a Godot group, so they cannot inherit the blind spot they exist to
## catch — and this script compares that against what the live system actually produced
## (`ambient_spawn_points()`/`live_count()`, `wired_harvestables()`). A future map's generator
## that publishes nests or harvestables under a group neither system recognizes fails loudly here
## instead of shipping silent, on ANY map built on `world/gen/authored_world.gd`'s layout
## convention (`zones`/`props`/`markers`/`heightfield`/`bound` — the same one `Undergrowth`
## already reads generically). A map not built that way has nothing to compare against and the
## layout-shaped checks are skipped rather than failed.
##
## Undergrowth's prop-group bug (grass growing on top of props) is NOT covered here: it needs a
## per-instance ground-height probe against the specific map's terrain, which is what
## `tools/hollowmere_check.gd::_check_undergrowth_stays_off_props` already does; lifting that one
## the same way is follow-up work, noted in `docs/DELEGATION.md`.
##
## Run with: .agent/bin/agent godot --script tools/world_contract_check.gd

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var scene_path := String(ProjectSettings.get_setting("application/run/main_scene", ""))
	print("WORLD_CONTRACT main_scene=%s" % scene_path)
	var packed: PackedScene = load(scene_path) as PackedScene
	if packed == null:
		failures.append("main scene %s does not load" % scene_path)
		_finish()
		return

	var level: Node = packed.instantiate()
	root.add_child(level)
	# EnemyWorld/HarvestWorld find the level through current_scene, which nothing sets when a
	# scene is added by hand (same trap tools/hollowmere_check.gd documents).
	current_scene = level
	for frame in 16:
		await process_frame
		await physics_frame

	var layout: Dictionary = _layout_for(level)
	if layout.is_empty():
		print("WORLD_CONTRACT this map has no World.layout_path — layout-shaped checks skipped")
	else:
		_check_enemy_world(layout)
		await _check_enemy_world_live(layout)
		await _check_harvest_world(layout)

	level.queue_free()
	_finish()


## The layout convention `world/gen/authored_world.gd` and `Undergrowth` already share: a node
## named "World" exporting `layout_path`. A generator not built that way (a future streamed/
## chunked one, F-075's named pairing) has nothing to compare against here.
func _layout_for(level: Node) -> Dictionary:
	var world: Node = level.get_node_or_null(^"World")
	if world == null:
		return {}
	var path_value: Variant = world.get("layout_path")
	if path_value == null or String(path_value).is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(String(path_value)))
	return parsed as Dictionary if parsed is Dictionary else {}


func _check_enemy_world(layout: Dictionary) -> void:
	var world: Node = root.get_node_or_null(^"EnemyWorld")
	if world == null:
		failures.append("EnemyWorld autoload is not registered")
		return
	var expected: int = int(world.call("expected_nest_count", layout))
	var points: int = (world.call("ambient_spawn_points") as Array).size()
	print("WORLD_CONTRACT_ENEMY layout_nests=%d spawn_points=%d" % [expected, points])
	if expected > 0 and points <= 0:
		failures.append(
			"layout declares %d enemy_nest marker(s) but EnemyWorld.ambient_spawn_points() found "
			% expected + "none — its group list has not been taught this map's marker group")


## Wired is not the same as working, so this waits for the ambient bootstrap and counts live
## bodies rather than trusting the spawn-point lookup alone — a nest on ground the navmesh does
## not cover would still produce zero crawlers with an identical symptom.
func _check_enemy_world_live(layout: Dictionary) -> void:
	var world: Node = root.get_node_or_null(^"EnemyWorld")
	if world == null:
		return
	if int(world.call("expected_nest_count", layout)) <= 0:
		return
	if (world.call("ambient_spawn_points") as Array).is_empty():
		return  # already failed above; nothing new to learn from waiting
	for frame in 240:
		await physics_frame
		if int(world.call("live_count")) > 0:
			break
	var live: int = int(world.call("live_count"))
	print("WORLD_CONTRACT_ENEMY live=%d" % live)
	if live <= 0:
		failures.append("EnemyWorld found nest spawn points but no crawler ever actually spawned")


func _check_harvest_world(layout: Dictionary) -> void:
	var harvest: Node = root.get_node_or_null(^"HarvestWorld")
	if harvest == null:
		failures.append("HarvestWorld autoload is not registered")
		return
	var expected: int = int(harvest.call("expected_harvestable_count", layout))
	harvest.call("refresh_current_scene")
	await process_frame
	var live: int = (harvest.call("wired_harvestables") as Array).size()
	print("WORLD_CONTRACT_HARVEST layout_props=%d wired=%d" % [expected, live])
	if expected > 0 and live <= 0:
		failures.append(
			"layout declares %d harvestable prop(s) but HarvestWorld wired none — its "
			% expected + "HOLDER_GROUPS has not been taught this map's holder group")


func _finish() -> void:
	if failures.is_empty():
		print("WORLD_CONTRACT_CHECK PASS")
	else:
		print("WORLD_CONTRACT_CHECK FAIL (%d)" % failures.size())
		for failure in failures:
			print("  ", failure)
	quit(0 if failures.is_empty() else 1)
