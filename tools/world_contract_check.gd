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
## 4.16 turned this into the BOTH-MAP MATRIX, and 4.19's cutover re-aimed it: every contract phase
## runs against the map `project.godot` ships (the procedural island since 4.19) AND the pinned
## authored fixture (`levels/hollowmere.tscn`), in one process, and the loop-facing contract — the
## fixtures `tools/loop_audit_check.gd` proved the run arc needs — is asserted per map: nests that
## spawn, harvestables that wire, at least one REGISTERED station, chests with a resolvable tier,
## a Wellspring, exactly one extraction ship, a standable spawn, and a MireGrid that seeded inside
## the island and recedes from a cap.
##
## F-284 finished that sentence: "a standable spawn" was asserted only on the procedural half until
## then. It is now one shared phase (`_check_spawn_standable`) reading each map's own real spawn
## source against each map's own ground and water.
##
## Layout-shaped phases (F-076's originals) still run only where a layout JSON exists — the
## procedural map has no layout by design, and its ground truths are asserted directly instead.
## The Undergrowth phase (F-112) is REQUIRED on the authored map and asserted ABSENT on the
## procedural one: flora there is ResourceScatterField's job, so an Undergrowth node appearing on
## a procedural world would mean two systems scattering over each other.
##
## Run with: .agent/bin/agent godot --script tools/world_contract_check.gd

## How much dry ground a spawn has to have over the water standing on it. Set so that a map whose
## water surface is sea level (every procedural island) demands the same `ground > 0.5` this check
## has always demanded of the composer.
const SPAWN_DRY_CLEARANCE_M: float = 0.5
## How far a spawn may sit off the ground under it before it is a bug rather than a nudge. Below is
## nearly zero — a spawn under the terrain is the failure F-284 exists for, and the shipped map's
## own record clears its ground by centimetres. Above is generous: a spawn is authored a step over
## the surface on purpose, and PlayerNet adds its own 1.2 m stand-up offset on top.
const SPAWN_BURIED_TOLERANCE_M: float = 0.35
const SPAWN_FLOATING_TOLERANCE_M: float = 2.5

## 4.19: the map project.godot ships is the procedural island, and Hollowmere is the authored
## fixture/reference. The matrix keeps asking both kinds their own contract: the shipped arm gets
## whichever contract its scene root actually is, and the fixture arm pins the authored one so
## authored-map coverage cannot silently vanish with the cutover.
const AUTHORED_FIXTURE_PATH: String = "res://levels/hollowmere.tscn"
## Preloaded at class level (F-016's standing rule): a --script run must not depend on the
## gitignored global-class cache to know what a ProceduralWorld is.
const ProceduralWorldScript := preload("res://world/gen/procedural_world.gd")
## D-191: this check asks the Mire simulation where it seeded rather than searching for it.
const MireGridSimLib := preload("res://world/mire/mire_grid_sim.gd")

var failures: Array[String] = []
var _map_label: String = ""
## The authored map's spawn, read off the instantiated scene BEFORE a physics frame runs — see
## `_run`. `null` when the level has no `Player` node at all, which is itself a failure (F-284).
var _authored_spawn: Variant = null


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	# Load the shipped map first so its kind decides the matrix; boot order is fixture-first below.
	var scene_path := String(ProjectSettings.get_setting("application/run/main_scene", ""))
	var packed: PackedScene = load(scene_path) as PackedScene
	if packed == null:
		failures.append("[shipped] main scene %s does not load" % scene_path)
		_finish()
		return
	var level: Node = packed.instantiate()
	# Which contract the shipped map owes depends on which kind it is: a scene root carrying
	# procedural_world.gd IS the composer; anything else is an authored-convention map.
	var shipped_procedural: bool = level.get_script() == ProceduralWorldScript
	print("WORLD_CONTRACT map=shipped main_scene=%s kind=%s" % [
		scene_path, "procedural" if shipped_procedural else "authored"])

	# ── the authored fixture, pinned, and FIRST (4.19: Hollowmere is reference, not shipped). It
	# runs before the shipped arm because its live-spawn phase watches EnemyWorld's first ambient
	# top-up, which happens once per process right after the first navmesh bake — the position the
	# authored arm has always held in this check. Skipped when the shipped map IS the fixture.
	if scene_path != AUTHORED_FIXTURE_PATH:
		print("WORLD_CONTRACT map=authored fixture=%s" % AUTHORED_FIXTURE_PATH)
		_map_label = "authored"
		var fixture_packed: PackedScene = load(AUTHORED_FIXTURE_PATH) as PackedScene
		if fixture_packed == null:
			failures.append("[authored] fixture %s does not load" % AUTHORED_FIXTURE_PATH)
			_finish()
			return
		var fixture: Node = fixture_packed.instantiate()
		await _run_authored_arm(fixture)
		fixture.queue_free()
		await process_frame
		await process_frame

	# ── the map that actually ships ───────────────────────────────────────────────────────────────
	print("\nWORLD_CONTRACT map=shipped")
	_map_label = "shipped"
	if shipped_procedural:
		await _run_procedural_arm(level)
	else:
		await _run_authored_arm(level)
	level.queue_free()
	await process_frame
	await process_frame

	# ── the composer exactly as --procedural builds it — only when the shipped arm was authored;
	# otherwise the shipped arm already booted this exact script as the scene root ────────────────
	if not shipped_procedural:
		print("\nWORLD_CONTRACT map=procedural (ProceduralWorld, build_player=false)")
		_map_label = "procedural"
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


## The authored-convention contract. [param level] is instantiated but not yet in the tree.
func _run_authored_arm(level: Node) -> void:
	# The spawn, read off the instantiated scene before a single frame runs. The level's `Player` is
	# a real CharacterBody3D, so sixteen frames of physics later its position is wherever it SETTLED
	# — which grades the terrain's ability to catch a falling body, not where the map put the spawn.
	# The first run of this check measured the authored 2.423 as 2.023 for exactly that reason, and a
	# spawn authored ten metres in the air, or one metre under the terrain, would have read as ground
	# level too (F-284).
	var placeholder := level.get_node_or_null(^"Player") as Node3D
	_authored_spawn = placeholder.position if placeholder != null else null
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


## The procedural contract, asked of the shipped scene itself: no Undergrowth (flora there is
## ResourceScatterField's job), and the loop fixtures read through the composer's published sites.
func _run_procedural_arm(level: Node) -> void:
	root.add_child(level)
	current_scene = level
	for frame in 16:
		await process_frame
		await physics_frame
	_check_no_undergrowth(level)
	await _check_loop_fixtures(level, true)


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

	# A standable spawn, asserted per map (F-284). The demand is identical on both sides; only where
	# the spawn is READ from differs, because the two map kinds publish one differently.
	_check_spawn_standable(level, procedural)

	if procedural:
		await _check_procedural_specifics(level)

	# MireGrid binding — the same question on both maps: seeded somewhere real, and a cap recedes
	# it. corruption_at is bound-clamped, so a grid that failed to bind reads as all zeros.
	var mire: Node = root.get_node_or_null(^"MireGrid")
	mire.call("ensure_ready")
	var hot: Vector3 = Vector3.ZERO
	var hottest: float = -1.0
	# D-191 dropped the seed from four clusters to one, and this probe used to hunt for corruption on
	# a fixed 48 m lattice — a stride wider than a 32 m cluster's diameter, which found one of four
	# by luck and finds one of one almost never. So ask the simulation where it seeded instead of
	# searching for it: `seed_cluster_centres()` is the same list `seed_initial()` stamps, in the
	# same order. The lattice is still swept afterwards, because "hot only where the sim says" is a
	# weaker claim than "hot there, and the binding is live across the island".
	var game_state: Node = root.get_node_or_null(^"GameState")
	var world_seed: int = int(game_state.call("ensure_seed")) if game_state != null else 0
	var probes: Array[Vector3] = []
	for centre: Vector2 in MireGridSimLib.seed_cluster_centres(world_seed):
		probes.append(Vector3(centre.x, 0.0, centre.y))
	for x: int in range(-480, 481, 48):
		for z: int in range(-480, 481, 48):
			probes.append(Vector3(float(x), 0.0, float(z)))
	for probe: Vector3 in probes:
		var value: float = float(mire.call("corruption_at", probe))
		if value > hottest:
			hottest = value
			hot = probe
	if hottest <= 0.05:
		_fail("MireGrid has no seeded corruption anywhere on the island (max %.3f)" % hottest)
	else:
		var EventBus := preload("res://core/events/event_bus.gd")
		EventBus.emit_wellspring_capped(&"contract_probe", hot)
		await physics_frame
		var after: float = float(mire.call("corruption_at", hot))
		if after >= hottest:
			_fail("a Wellspring cap did not recede the Mire (%.3f -> %.3f)" % [hottest, after])
		# D-191: the cap clears 48 m and the run now seeds a SINGLE 32 m cluster, so this probe
		# erases the world's only corruption. That was invisible while there were four — the other
		# three carried the second map's arm — and it left the next arm asserting against a grid
		# this check had itself wiped. Put it back; a probe must not be a mutation.
		mire.call("host_reset")
		# The reset re-seeds and broadcasts its deltas; give them the frame they are queued for
		# before this arm tears its level down, or the next arm builds on a half-applied grid.
		await physics_frame
	print("WORLD_CONTRACT_%s wellsprings=%d ships=%d chests=%d registered_stations=%d "
		% [_map_label.to_upper(), wellsprings, ships, chests.size(), registered_markers]
		+ "spawn_points=%d mire_peak=%.2f" % [spawn_points, hottest])


## What only the procedural map has to prove: the scatter field actually wires harvest proxies once
## the streamer has chunks around an anchor — the harvest link of the loop, which has no layout JSON
## to compare against, so `_check_harvest_world` cannot ask it.
##
## The spawn assertion that used to live here moved to `_check_spawn_standable` and now runs on both
## maps (F-284): it was never procedural-specific, and keeping it here meant the map that actually
## ships asserted no spawn position at all.
func _check_procedural_specifics(world: Node) -> void:
	var spawn: Vector3 = world.get(&"spawn_position")
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


## The spawn fixture, asked identically of both maps: is the point a player is actually put down on
## dry, solid, standable ground?
##
## F-284: this assertion used to sit inside `_check_procedural_specifics`, so the authored map — the
## one `project.godot` ships — checked no spawn position at all, and Hollowmere's could drift into
## the Mere or under the terrain with `WORLD_CONTRACT_CHECK PASS` still green.
##
## The SOURCE is per map, and on both sides it is the real runtime source rather than a restatement
## of one:
##   procedural — `ProceduralWorld.spawn_position`, what `_build_player()` and `_replace_players()`
##                stand bodies on.
##   authored   — the level's own `Player` node, which `PlayerNet._claim_spawn_point()` reads the
##                transform off and then frees at session open (`autoload/player_net.gd`), captured
##                in `_run` before physics can move it. A level with no `Player` node spawns every
##                player at the world origin, so its absence is a failure here and not a skip — that
##                is the F-076 blind spot exactly. It is cross-checked against the layout's own
##                spawn record, which is the truth the scene node is a copy of.
## The GROUND is per map through one pair of public calls both world scripts answer, `height_at()`
## and `water_surface_at()`, so nothing below this line knows which map it is holding.
func _check_spawn_standable(level: Node, procedural: bool) -> void:
	var ground_source: Node = level if procedural else level.get_node_or_null(^"World")
	if ground_source == null or not ground_source.has_method(&"height_at"):
		_fail("no node answers height_at() — this map publishes no ground to stand a spawn on")
		return

	var spawn: Vector3 = Vector3.ZERO
	if procedural:
		spawn = ground_source.get(&"spawn_position")
	elif _authored_spawn is Vector3:
		spawn = _authored_spawn as Vector3
		_check_spawn_matches_layout(level, spawn)
	else:
		_fail("the level has no Player node — PlayerNet._claim_spawn_point() would put every "
			+ "player at the world origin")
		return

	var ground: float = float(ground_source.call(&"height_at", spawn.x, spawn.z))
	if not is_finite(ground):
		_fail("the ground under the spawn %s is not a number (%s)" % [spawn, ground])
		return

	# Not standing in water. A map that cannot answer where its water is cannot prove its spawn is
	# dry, and "no answer" must read as a failure rather than as "no water" (F-076 again).
	var water: float = -INF
	if ground_source.has_method(&"water_surface_at"):
		water = float(ground_source.call(&"water_surface_at", spawn.x, spawn.z))
	else:
		_fail("the map answers height_at() but not water_surface_at() — nothing can prove its "
			+ "spawn is out of the water")
	if is_finite(water) and ground < water + SPAWN_DRY_CLEARANCE_M:
		_fail("the spawn is in the water (ground %.2f, water surface %.2f at %s)"
			% [ground, water, spawn])

	# And standing ON that ground rather than inside it or over it.
	if spawn.y < ground - SPAWN_BURIED_TOLERANCE_M:
		_fail("the spawn is %.2f m BELOW the ground at %s — a player starts inside the terrain"
			% [ground - spawn.y, spawn])
	if spawn.y > ground + SPAWN_FLOATING_TOLERANCE_M:
		_fail("the spawn floats %.2f m above the ground at %s" % [spawn.y - ground, spawn])
	print("WORLD_CONTRACT_%s spawn=%s ground=%.2f water=%s" % [
		_map_label.to_upper(), spawn, ground,
		"none" if not is_finite(water) else "%.2f" % water])


## The layout is the source of truth and the scene's `Player` node is a copy of it; the first time
## those two disagreed, the player started inside a cabin under a floor with no collision
## (`tools/hollowmere_check.gd`'s lesson, generalized off that one map). Horizontal only — the
## authored Y is a stand-on-the-surface nudge that the ground band above already grades.
func _check_spawn_matches_layout(level: Node, spawn: Vector3) -> void:
	var layout: Dictionary = _layout_for(level)
	if layout.is_empty():
		return          # not a layout-convention map; nothing to compare against, same as elsewhere
	var record: Variant = _layout_spawn(layout)
	if not (record is Vector3):
		_fail("the layout declares no spawn record — nothing pins the scene's Player node to the "
			+ "map the generator built")
		return
	var authored: Vector3 = record as Vector3
	var drift: float = Vector2(spawn.x - authored.x, spawn.z - authored.z).length()
	if drift > 0.5:
		_fail("the Player node is %.2f m from the layout's spawn record %s — scene and layout have "
			% [drift, authored] + "drifted apart")


## The layout's own spawn record. ONE shape across every layout — `{"pos": [x, y, z], "yaw": r}`
## (F-302). This used to carry a second branch for `hollowmere.json`'s bare `[x, y, z]`; that
## layout and its generator were migrated, so the branch is gone and a layout that writes the old
## triple now returns `null` here instead of being quietly accommodated. Returns `null` when the
## layout has no usable record, which is a failure for the caller to report rather than a skip.
func _layout_spawn(layout: Dictionary) -> Variant:
	var record: Variant = (layout.get("spawn", {}) as Dictionary).get("pos")
	if not (record is Array):
		return null
	var values: Array = record as Array
	if values.size() < 3:
		return null
	return Vector3(float(values[0]), float(values[1]), float(values[2]))


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
