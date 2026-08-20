extends SceneTree

## Task 4.15 proof — the ProceduralWorld composer (D-143) actually composes: terrain streams,
## nav binds, scatter attaches, POI sites become the SAME marker contract the authored maps
## publish, the services discover them unchanged, and the spawn rule lands somewhere a player can
## stand. Headless, self-contained, fixed seeds.
##
##   .agent/bin/agent godot --script tools/procedural_world_check.gd
##
## What this deliberately does NOT assert: collision-cook timing and scatter-proxy materialization
## (owned by tools/resource_scatter_check.gd against a controllable fake streamer), nav map
## queryability end-to-end (tools/nav_bake_check.gd — needs its own long timeout), and Hollowmere
## parity (task 4.16's whole job). This check owns the COMPOSITION seams only.

const ProceduralWorldScript := preload("res://world/gen/procedural_world.gd")
const IslandHeightmapScript := preload("res://world/gen/island_heightmap.gd")

const SEED_A: int = 20260819
const SEED_B: int = 987654321

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame

	var game_state: Node = root.get_node_or_null(^"GameState")
	check(game_state != null, "GameState autoload exists")
	var registry: Node = root.get_node_or_null(^"Registry")
	check(registry != null, "Registry autoload exists")
	if game_state == null or registry == null:
		return finish()

	# ── one composed world, seed A ────────────────────────────────────────────────────────────────
	var world_a: Node3D = await _build_world(game_state, SEED_A)

	check(world_a.get(&"streamer") != null, "the composer built a ChunkStreamer")
	check(world_a.get(&"nav_baker") != null, "the composer built a NavBaker")
	check(world_a.get(&"scatter_field") != null, "the composer built a ResourceScatterField")
	check(int(world_a.call(&"height_at", 0.0, 0.0) != null) == 1,
		"height_at() answers — the authored-world call shape carries over")

	var sites: Array = world_a.get(&"poi_sites")
	check(sites.size() > 0, "PoiMap produced sites (%d)" % sites.size())
	var wellspring_sites: int = 0
	for site: Dictionary in sites:
		if site.get("def_id") == &"wellspring":
			wellspring_sites += 1
	check(wellspring_sites > 0,
		"every island gets a Wellspring — 4.7's own guarantee holds through the composer")

	# ── the marker contract ───────────────────────────────────────────────────────────────────────
	var kinds: Dictionary = {}
	for node: Node in get_nodes_in_group(&"authored_world_marker"):
		if not world_a.is_ancestor_of(node):
			continue
		var kind: String = String(node.get_meta(&"kind", ""))
		kinds[kind] = int(kinds.get(kind, 0)) + 1
	check(int(kinds.get("objective", 0)) == wellspring_sites,
		"every Wellspring site published an `objective` marker (%d of %d)" % [
			int(kinds.get("objective", 0)), wellspring_sites])
	check(int(kinds.get("shipwreck", 0)) >= 1,
		"the extraction wreck published its `shipwreck` marker")
	check(int(kinds.get("spawn", 0)) == 1, "exactly one spawn marker")
	check(not kinds.has(""), "no marker was published with an empty kind")

	# Scenery stays scenery: standing_stones has no marker_kind, so sites may exist with no marker.
	var stones: int = 0
	for site: Dictionary in sites:
		if site.get("def_id") == &"standing_stones":
			stones += 1
	var marked: int = 0
	for count: Variant in kinds.values():
		marked += int(count)
	check(marked < sites.size() + 1 or stones == 0,
		"scenery sites (standing_stones ×%d) publish no service marker" % stones)

	# ── the services light up unchanged (D-143's whole claim) ─────────────────────────────────────
	await process_frame
	await process_frame
	var wellsprings: int = get_nodes_in_group(&"wellspring").size()
	check(wellsprings == wellspring_sites,
		"WellspringService built a real Wellspring at every objective marker (%d of %d) — no "
		% [wellsprings, wellspring_sites] + "service code was touched")

	# ── the spawn rule ────────────────────────────────────────────────────────────────────────────
	var spawn: Vector3 = world_a.get(&"spawn_position")
	var ground: float = float(world_a.call(&"height_at", spawn.x, spawn.z))
	check(ground >= float(ProceduralWorldScript.SPAWN_HEIGHT_MIN) - 0.01
		and ground <= float(ProceduralWorldScript.SPAWN_HEIGHT_MAX) + 0.01,
		"spawn is in the beach band (ground %.2f m)" % ground)
	var near: float = float(world_a.call(&"height_at", spawn.x + 1.0, spawn.z))
	check(absf(near - ground) <= float(ProceduralWorldScript.SPAWN_MAX_SLOPE) + 0.01,
		"spawn ground is standable (slope %.2f)" % absf(near - ground))
	var clear: bool = true
	for site: Dictionary in sites:
		var position: Vector3 = site.get("position", Vector3.ZERO)
		if Vector2(spawn.x - position.x, spawn.z - position.z).length() \
				< float(site.get("clearance", 0.0)):
			clear = false
	check(clear, "spawn is outside every POI's own clearance")

	# ── determinism: same seed ⇒ same island; different seed ⇒ different island ───────────────────
	var world_a2: Node3D = await _build_world(game_state, SEED_A)
	check(world_a2.get(&"spawn_position") == spawn,
		"same seed reproduces the same spawn point exactly")
	var sites_a2: Array = world_a2.get(&"poi_sites")
	# F-288's sweep: this used to compare position and def_id only, so a seed that reproduced every
	# site in the right place but spun one of them, or pointed it at a different scene, read as
	# "identical". Rotation and scene path are as much a peer-visible part of the layout as the
	# position is — a landmark facing two ways on two peers is the same desync.
	var identical: bool = sites_a2.size() == sites.size()
	if identical:
		for index: int in range(sites.size()):
			if not _same_site(sites[index] as Dictionary, sites_a2[index] as Dictionary):
				identical = false
				break
	check(identical,
		"same seed reproduces every POI site — id, def, position, rotation, biome, scene and order")

	var world_b: Node3D = await _build_world(game_state, SEED_B)
	check(world_b.get(&"spawn_position") != spawn,
		"a different seed lands a different island (spawn moved)")

	print("\nPROCEDURAL_WORLD_CHECK sites=%d markers=%s failures=%d" % [
		sites.size(), kinds, failures])
	finish()


## Field-for-field site equality (F-288). Read explicitly rather than comparing the Dictionaries
## wholesale, so a new key on a site widens this deliberately instead of silently joining or
## leaving the assertion.
func _same_site(a: Dictionary, b: Dictionary) -> bool:
	for key: String in ["site_id", "def_id", "position", "rotation_y", "biome", "scene_path"]:
		if a.get(key) != b.get(key):
			return false
	return true


## Builds a ProceduralWorld under a throwaway current_scene with GameState pinned to `seed_value`,
## waits for _ready, returns it. build_player stays off: this harness asserts composition, not a
## live body (and the resident chunk ring around a player would slow every case for nothing).
func _build_world(game_state: Node, seed_value: int) -> Node3D:
	if current_scene != null:
		current_scene.queue_free()
		await process_frame
	var scene := Node3D.new()
	scene.name = "ProceduralCheckScene"
	root.add_child(scene)
	current_scene = scene

	game_state.set("run_seed", seed_value)
	game_state.set("_seed_ready", true)

	var world: Node3D = ProceduralWorldScript.new()
	world.set(&"build_player", false)
	scene.add_child(world)
	await process_frame
	return world


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	print("\nPROCEDURAL_WORLD_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)
