extends SceneTree

## F-351 — do enemies navigate the map the world actually bakes?
##
## `world/chunk/nav_baker.gd` mints its OWN navigation map (`NavigationServer3D.map_create()`) and
## registers every streamed chunk's region on it. `Enemy._build_agent()` creates a plain
## `NavigationAgent3D`, which queries the viewport's DEFAULT world map. If those are two different
## maps then none of the island's terrain navmesh is reachable by anything that walks on it, and an
## enemy paths on whatever stale region happens to be on the default map instead — which is what a
## player sees as an enemy wandering off instead of chasing.
##
## Boots the SHIPPED level rather than a synthetic scene on purpose: this bug cannot exist in a
## harness that builds its own enemies in an empty tree, which is why `tools/enemy_ai_check.gd` and
## `tools/enemy_check.gd` both pass while the game does not. The pursuit trace at the end is a
## secondary reading — see the finding for why a crawler can still close here despite the split.
##
## Authority: none (docs/ARCHITECTURE.md §2.2). Read-only diagnostic.
##
##   .agent/bin/agent godot --windowed --script tools/enemy_nav_map_check.gd

const SCENE: String = "res://levels/procedural_island.tscn"
## Frames to let the level build, prime, stream and bake before reading anything.
const SETTLE_FRAMES: int = 240
## How far from the spawn marker the stand-in player is placed.
const PLAYER_OFFSET_M: float = 12.0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	root.size = Vector2i(640, 360)
	var packed: PackedScene = load(SCENE) as PackedScene
	var level: Node = packed.instantiate()
	root.add_child(level)
	# The scene tree's "current scene" is what EnemyWorld.bake_navigation() parses.
	current_scene = level
	for _i: int in SETTLE_FRAMES:
		await process_frame

	var world: Node = root.get_node_or_null(^"EnemyWorld")
	if world == null:
		print("NO EnemyWorld"); quit(1); return

	print("nav regions on the default map:")
	var map: RID = root.world_3d.navigation_map
	print("  map valid=%s iteration=%d regions=%d"
		% [map.is_valid(), NavigationServer3D.map_get_iteration_id(map),
		   NavigationServer3D.map_get_regions(map).size()])
	var total: int = 0
	for r: RID in NavigationServer3D.map_get_regions(map):
		total += NavigationServer3D.region_get_connections_count(r)
	print("  total region connections=%d" % total)

	var pw: Node = current_scene
	var baker: Node = pw.get_node_or_null(^"NavBaker")
	if baker != null:
		var bmap: RID = baker.call("map_rid")
		_baker_map = bmap
		_baked_regions = int(baker.call("region_count"))
		print("NavBaker's OWN map:")
		print("  map valid=%s regions=%d  (chunk regions baked=%d)"
			% [bmap.is_valid(), NavigationServer3D.map_get_regions(bmap).size(),
			   int(baker.call("region_count"))])
		print("  same map as the enemies query? %s" % (bmap == map))

	var points: Array = world.call("ambient_spawn_points")
	print("ambient spawn points: %d" % points.size())
	var origin: Vector3 = points[0] if not points.is_empty() else Vector3.ZERO
	print("using origin %v" % origin)

	# Player 12 m away on +X from the spawn point.
	var player := CharacterBody3D.new()
	player.name = "1"
	player.add_to_group(&"players")
	root.add_child(player)
	player.global_position = origin + Vector3(PLAYER_OFFSET_M, 0.0, 0.0)

	var enemy: Node3D = world.call("host_spawn", &"crawler", origin)
	if enemy == null:
		print("SPAWN FAILED"); quit(1); return
	await process_frame
	await process_frame
	print("enemy _nav_ready = %s" % enemy.get("_nav_ready"))

	var start: float = enemy.global_position.distance_to(player.global_position)
	print("\n t(s)  dist(m)   enemy_pos                 step_dir        direct_dir")
	for tick: int in 180:
		enemy.call("_physics_process", 1.0 / 60.0)
		if tick % 20 == 0:
			var d: float = enemy.global_position.distance_to(player.global_position)
			var direct: Vector3 = (player.global_position - enemy.global_position)
			direct.y = 0.0
			var step: Vector3 = enemy.call("_steer_toward", player.global_position)
			print("  %4.1f  %6.2f   %-24s  %-14s  %s"
				% [float(tick) / 60.0, d, str(enemy.global_position).pad_decimals(1),
				   str(step).pad_decimals(2), str(direct.normalized()).pad_decimals(2)])
	var finish: float = enemy.global_position.distance_to(player.global_position)
	print("\ndistance %.2f -> %.2f m  (%s)"
		% [start, finish, "CLOSED" if finish < start - 0.5 else "DID NOT CLOSE"])

	var shared: bool = _baker_map == map
	print("")
	if shared:
		print("  ok    enemies and the chunk baker share one navigation map")
	else:
		print("  FAIL  enemies query a map with %d region(s) while %d chunk navmesh(es) sit on a"
			% [NavigationServer3D.map_get_regions(map).size(), _baked_regions])
		print("        map nothing that walks can see (F-351)")
	print("ENEMY_NAV_MAP_CHECK shared_map=%s enemy_map_regions=%d baker_map_regions=%d failures=%d"
		% [shared, NavigationServer3D.map_get_regions(map).size(), _baked_regions,
		   0 if shared else 1])
	quit(0 if shared else 1)


var _baker_map: RID
var _baked_regions: int = 0
