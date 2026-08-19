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
## F-112: `Undergrowth`'s prop-avoidance is generalized the same way, once `Undergrowth` is found —
## `sample_ground_gaps()` reads its OWN ground truth (the layout heightfield, via the same
## `_layout_height()` it scatters against) rather than through `prop_group`, so a map whose
## `prop_group` export is misconfigured — the F-076 blind spot, transplanted to this system —
## still shows up here instead of grading itself against its own mistake. It reads world-space
## transforms `Undergrowth` already computed at scatter time rather than reading its live
## `MultiMeshInstance3D`s back — that RenderingServer round trip answers identity under
## `--headless` with no error (F-103) — so this runs and asserts under a plain headless run same
## as everything else in this file.
##
## 4.16 turned this into the BOTH-MAP MATRIX: every contract phase now runs against the shipped
## authored map AND a code-built ProceduralWorld (same composer `--procedural` boots), in one
## process, and the loop-facing contract — the fixtures `tools/loop_audit_check.gd` proved the run
## arc needs — is asserted per map: nests that spawn, harvestables that wire, at least one
## REGISTERED station, chests with a resolvable tier, a Wellspring, exactly one extraction ship,
## a standable spawn, and a MireGrid that seeded inside the island and recedes from a cap.
##
## Layout-shaped phases (F-076's originals) still run only where a layout JSON exists — the
## procedural map has no layout by design, and its ground truths are asserted directly instead.
## The Undergrowth phase (F-112) is REQUIRED on the authored map and asserted ABSENT on the
## procedural one: flora there is ResourceScatterField's job, so an Undergrowth node appearing on
## a procedural world would mean two systems scattering over each other.
##
## Run with: .agent/bin/agent godot --script tools/world_contract_check.gd

var failures: Array[String] = []
var _map_label: String = ""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	# ── map 1: whatever project.godot actually ships ──────────────────────────────────────────────
	var scene_path := String(ProjectSettings.get_setting("application/run/main_scene", ""))
	print("WORLD_CONTRACT map=authored main_scene=%s" % scene_path)
	_map_label = "authored"
	var packed: PackedScene = load(scene_path) as PackedScene
	if packed == null:
		failures.append("[authored] main scene %s does not load" % scene_path)
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
	_check_undergrowth_required(level)
	await _check_loop_fixtures(level, false)

	level.queue_free()
	await process_frame
	await process_frame

	# ── map 2: the composer, exactly as --procedural builds it ────────────────────────────────────
	print("\nWORLD_CONTRACT map=procedural (ProceduralWorld, build_player=false)")
	_map_label = "procedural"
	var ProceduralWorldScript := preload("res://world/gen/procedural_world.gd")
	var world: Node3D = ProceduralWorldScript.new()
	world.name = "ProceduralWorld"
	world.set(&"build_player", false)
	root.add_child(world)
	current_scene = world
	for frame in 16:
		await process_frame
		await physics_frame

	_check_no_undergrowth(world)
	await _check_loop_fixtures(world, true)

	world.queue_free()
	_finish()


## The loop-facing contract, identical question on both maps: does every fixture the run arc needs
## actually stand? [param procedural] only decides HOW ground truth is read (layout JSON vs the
## composer's own site list), never WHAT is demanded.
func _check_loop_fixtures(level: Node, procedural: bool) -> void:
	# Wellsprings, chests, ship — the placement services build all three from markers, so this is
	# also the assertion that the marker contract (kind AND name) survived this map's publisher.
	var wellsprings: int = get_nodes_in_group(&"wellspring").size()
	if wellsprings < 1:
		_fail("no Wellspring was built — the objective marker contract broke")
	var ships: int = get_nodes_in_group(&"extraction_ship").size()
	if ships != 1:
		_fail("%d extraction ship(s) — the run needs exactly one exit" % ships)

	var chests: Array[Node] = []
	for node: Node in get_nodes_in_group(&"chest"):
		if is_instance_valid(node):
			chests.append(node)
	if chests.is_empty():
		_fail("no chest was built — ChestPlacementService found no marker it could tier "
			+ "(kind 'loot' plus a Cache_*/Chest_<tier>_* NAME)")
	else:
		var tiered: int = 0
		for chest: Node in chests:
			if StringName(String(chest.get(&"tier"))) != &"":
				tiered += 1
		if tiered < chests.size():
			_fail("%d of %d chests carry no tier" % [chests.size() - tiered, chests.size()])

	# A REGISTERED station — one whose marker asset resolves through a StationDef, because six of
	# Hollowmere's eight station props are scenery and 'a station marker exists' proves nothing
	# (the loop audit's own lesson).
	var registered_assets: Array[StringName] = []
	var registry: Node = root.get_node_or_null(^"Registry")
	for id: Variant in (registry.get(&"stations") as Dictionary):
		registered_assets.append(StringName(String(
			((registry.get(&"stations") as Dictionary)[id] as Resource).get(&"world_scene"))))
	var registered_markers: int = 0
	for node: Node in get_nodes_in_group(&"authored_world_marker"):
		if String(node.get_meta(&"kind", "")) != "station":
			continue
		if registered_assets.has(StringName(String(node.name).trim_prefix("Station_"))):
			registered_markers += 1
	if registered_markers < 1:
		_fail("no REGISTERED station marker (name Station_<asset> matching a StationDef."
			+ "world_scene) — crafting is unreachable on this map")

	# Enemy spawn ground truth, map-appropriately: the layout's nests on the authored map, the
	# composer's published markers on the procedural one.
	var enemy_world: Node = root.get_node_or_null(^"EnemyWorld")
	enemy_world.call("refresh_spawn_points") if enemy_world.has_method(&"refresh_spawn_points") \
		else null
	var spawn_points: int = (enemy_world.call("ambient_spawn_points") as Array).size()
	if spawn_points < 1:
		_fail("EnemyWorld.ambient_spawn_points() is empty — night waves have nowhere to spawn")

	if procedural:
		await _check_procedural_specifics(level)

	# MireGrid binding — the same question on both maps: seeded somewhere real, and a cap recedes
	# it. corruption_at is bound-clamped, so a grid that failed to bind reads as all zeros.
	var mire: Node = root.get_node_or_null(^"MireGrid")
	mire.call("ensure_ready")
	var hot: Vector3 = Vector3.ZERO
	var hottest: float = -1.0
	for x: int in range(-480, 481, 48):
		for z: int in range(-480, 481, 48):
			var value: float = float(mire.call("corruption_at", Vector3(float(x), 0.0, float(z))))
			if value > hottest:
				hottest = value
				hot = Vector3(float(x), 0.0, float(z))
	if hottest <= 0.05:
		_fail("MireGrid has no seeded corruption anywhere on the island (max %.3f)" % hottest)
	else:
		var EventBus := preload("res://core/events/event_bus.gd")
		EventBus.emit_wellspring_capped(&"contract_probe", hot)
		await physics_frame
		var after: float = float(mire.call("corruption_at", hot))
		if after >= hottest:
			_fail("a Wellspring cap did not recede the Mire (%.3f -> %.3f)" % [hottest, after])
	print("WORLD_CONTRACT_%s wellsprings=%d ships=%d chests=%d registered_stations=%d "
		% [_map_label.to_upper(), wellsprings, ships, chests.size(), registered_markers]
		+ "spawn_points=%d mire_peak=%.2f" % [spawn_points, hottest])


## What only the procedural map has to prove: the composer's spawn is standable ground (its own
## check owns the full spawn rule; this is the contract-level restatement), and the scatter field
## actually wires harvest proxies once the streamer has chunks around an anchor — the harvest link
## of the loop, which has no layout JSON to compare against.
func _check_procedural_specifics(world: Node) -> void:
	var spawn: Vector3 = world.get(&"spawn_position")
	var ground: float = float(world.call(&"height_at", spawn.x, spawn.z))
	if ground < 0.5:
		_fail("the spawn stands in the sea (ground %.2f at %s)" % [ground, spawn])

	var streamer: Node = world.get(&"streamer")
	if streamer == null:
		_fail("composer built no ChunkStreamer")
		return
	streamer.call(&"set_anchors", [spawn] as Array[Vector3])
	var harvest: Node = root.get_node_or_null(^"HarvestWorld")
	var wired: int = 0
	# Chunk meshing is WorkerThreadPool + budgeted upload, proxies materialize per resident chunk —
	# give it a real streaming window, then insist. 20 s of frames is far beyond D-074's budget.
	for frame in 1200:
		await physics_frame
		harvest.call("refresh_current_scene")
		wired = (harvest.call("wired_harvestables") as Array).size()
		if wired > 0:
			break
	print("WORLD_CONTRACT_PROCEDURAL wired_harvestables=%d loaded_chunks=%d" % [
		wired, int(streamer.call(&"loaded_chunk_count"))])
	if wired < 1:
		_fail("ResourceScatterField wired no harvestable proxy around the spawn — the harvest "
			+ "link of the loop is broken on the procedural map")


## F-112, both halves. On the authored map the Undergrowth node is REQUIRED — silently skipping
## when it is missing is how F-076-shaped blind spots ship.
func _check_undergrowth_required(level: Node) -> void:
	var undergrowth: Node = level.get_node_or_null(^"Undergrowth")
	if undergrowth == null or not undergrowth.has_method(&"sample_ground_gaps"):
		_fail("the authored map has no Undergrowth node — the flora layer went missing")
		return
	var gaps: Array = undergrowth.call("sample_ground_gaps")
	var perched := 0
	var worst := 0.0
	for gap: float in gaps:
		if gap > 0.6:
			perched += 1
			worst = maxf(worst, gap)
	print("WORLD_CONTRACT_UNDERGROWTH sampled=%d perched=%d worst=%.2fm" % [
		gaps.size(), perched, worst
	])
	if gaps.size() > 0 and float(perched) / float(gaps.size()) > 0.02:
		_fail("%d of %d sampled undergrowth plants (%.1f%%) grow on top of props" % [
			perched, gaps.size(), 100.0 * float(perched) / float(gaps.size())])


## The retirement half: procedural flora belongs to ResourceScatterField (WORLDGEN.md §3.2), so an
## Undergrowth node on this map means two scatter systems fighting over the same ground.
func _check_no_undergrowth(world: Node) -> void:
	if world.get_node_or_null(^"Undergrowth") != null:
		_fail("a procedural world grew an Undergrowth node — flora is ResourceScatterField's here")


func _fail(message: String) -> void:
	failures.append("[%s] %s" % [_map_label, message])


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
