extends Node

## Host-owned enemy spawning, the navigation map they path on, and the registry task 2.12's wave
## spawner drives.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, "Enemies (spawn, AI, damage)"): **HOST**. Only the
## host calls `host_spawn()`; clients receive bodies through a code-built `MultiplayerSpawner`
## (D-023) and simulate none of them. There is no client spawn RPC and there must not be one — an
## enemy a client can conjure is an enemy a client can duplicate.
##
## Navigation is built here rather than per-enemy because a navmesh is a property of the level, not
## of the thing walking on it. The region is baked once from the level's static collision at session
## start; enemies then just have a map to query.

const ENEMY_SCRIPT := preload("res://systems/enemies/enemy.gd")
const ENEMY_DEF := preload("res://systems/enemies/enemy_def.gd")

const DEFS_PATH: String = "res://content/enemies"
const CONTAINER_NODE: StringName = &"Enemies"
const SPAWNER_NODE: StringName = &"EnemySpawner"
const ENEMY_GROUP: StringName = &"enemies"
## Matches A-006's crawler: 0.45 m radius, and it climbs the playtest ramps but not walls.
const NAV_AGENT_RADIUS_M: float = 0.5
const NAV_AGENT_HEIGHT_M: float = 0.7
const NAV_MAX_CLIMB_M: float = 0.6
const NAV_MAX_SLOPE_DEG: float = 46.0
const NAV_CELL_SIZE_M: float = 0.25
## Grace before the first bake/spawn, so the level has entered the tree. Short enough that crawlers
## are there by the time you have finished looking around.
const BOOTSTRAP_DELAY_SEC: float = 0.75

## Ambient spawning: enough crawlers to make the world not empty, and nothing more. This is NOT task
## 2.12's wave director — there is no day/night gate, no scaling with Cycle, no despawn at dawn. It
## exists because the map had a nest marker and no enemies, and 2.12 is expected to turn it off and
## take over.
@export var ambient_enabled: bool = true
@export_range(0, 24, 1) var ambient_population: int = 4
@export_range(1.0, 60.0, 0.5) var ambient_respawn_seconds: float = 12.0
## Spread around the marker, so four crawlers do not stack in one spot.
@export_range(0.0, 20.0, 0.5) var ambient_scatter_m: float = 4.0
@export var ambient_enemy: StringName = &"crawler"

signal enemy_spawned(enemy: Node3D)
signal enemy_died(enemy_id: StringName, instigator_peer_id: int, position: Vector3)

var defs: Dictionary[StringName, Resource] = {}

var _container: Node3D
var _spawner: MultiplayerSpawner
var _region: NavigationRegion3D
var _next_index: int = 1
var _nav_polygon_count: int = 0
var _ambient_accumulator: float = 0.0
## Seeded, never randi(): every peer boots the same registry, and a spawn scatter that differs per
## machine is the kind of thing that looks fine until it does not (AGENTS.md).
var _ambient_rng := RandomNumberGenerator.new()
var _bootstrapped: bool = false
var _bootstrap_elapsed: float = 0.0
## Cached transport ref (F-099) — _owns_spawning() runs every physics tick on every peer, and was
## re-resolving /root/NetTransport by path each time. Path-based on purpose (F-011 — harnesses
## install their transport at /root), cached once found.
var _transport_node: Node


func _ready() -> void:
	_ambient_rng.seed = 0x4352414d  # "CRAM"
	_load_defs()
	_build_replication_nodes()
	var transport: Node = _transport()
	if transport != null:
		transport.get("server_started").connect(_on_session_opened)
		transport.get("connected_to_host").connect(_on_session_opened)
		transport.get("disconnected").connect(_on_disconnected)
	_register_commands()
	MireLog.info(&"content", "loaded %d enemy definition(s)" % defs.size())


func _register_commands() -> void:
	var console: Node = get_node_or_null(^"/root/DebugConsole")
	if console == null or not console.has_method("register"):
		return
	console.call("register", &"spawn", _cmd_spawn, "spawn [enemy_id] [count] — spawn near you")
	console.call("register", &"killall", _cmd_killall, "killall — despawn every enemy")
	console.call("register", &"enemies", _cmd_enemies, "enemies — how many are alive, and where")


func _cmd_spawn(args: PackedStringArray) -> String:
	if not _owns_spawning():
		return "only the host can spawn enemies"
	var id := StringName(args[0]) if not args.is_empty() else ambient_enemy
	if not has_def(id):
		return "no such enemy '%s' — have: %s" % [id, ", ".join(defs.keys())]
	var count: int = maxi(int(args[1]) if args.size() > 1 else 1, 1)
	# In front of the local player, not at the origin — a crawler spawned across the map is
	# indistinguishable from one that did not spawn.
	var origin: Vector3 = Vector3.ZERO
	for node: Node in get_tree().get_nodes_in_group(&"players"):
		var player := node as Node3D
		if player != null and player.is_multiplayer_authority():
			origin = player.global_position + player.global_transform.basis.z * -5.0
			break
	var made: int = 0
	for i: int in count:
		if host_spawn(id, origin + Vector3(float(i) * 1.5, 0.0, 0.0)) != null:
			made += 1
	return "spawned %d %s" % [made, id]


func _cmd_killall(_args: PackedStringArray) -> String:
	if not _owns_spawning():
		return "only the host can despawn enemies"
	var count: int = live_count()
	host_despawn_all()
	return "despawned %d" % count


func _cmd_enemies(_args: PackedStringArray) -> String:
	var points: Array[Vector3] = ambient_spawn_points()
	return "%d alive, ambient %s (population %d), %d spawn point(s), navmesh %d polygons" % [
		live_count(), "on" if ambient_enabled else "off", ambient_population,
		points.size(), _nav_polygon_count
	]


## Host-only, and the whole ambient loop. Deliberately coarse: it tops the population back up on a
## timer rather than tracking individual deaths, so a crawler killed at any moment is replaced within
## `ambient_respawn_seconds` and nothing has to be unsubscribed.
func _physics_process(delta: float) -> void:
	# Cheap constant checks first; the authority check dispatches into the transport (F-099).
	if not ambient_enabled or defs.is_empty() or not _owns_spawning():
		return

	# Pressing Play opens no session, so nothing calls _on_session_opened and neither the bake nor
	# the first spawn would ever happen — which is exactly how the game shipped with a nest marker
	# and no crawlers. The short delay is for the level: an autoload's _ready runs before
	# get_tree().current_scene exists, so there is nothing to bake from yet.
	if not _bootstrapped:
		_bootstrap_elapsed += delta
		if _bootstrap_elapsed < BOOTSTRAP_DELAY_SEC:
			return
		_bootstrapped = true
		if _nav_polygon_count == 0:
			bake_navigation()
		top_up_ambient()
		return

	_ambient_accumulator += delta
	if _ambient_accumulator < ambient_respawn_seconds:
		return
	_ambient_accumulator = 0.0
	top_up_ambient()


## Spawns up to `ambient_population` living enemies at the level's enemy_spawn markers. Returns how
## many it added. Public so a console command and task 2.12 can both drive it.
func top_up_ambient() -> int:
	if not _owns_spawning():
		return 0
	var points: Array[Vector3] = ambient_spawn_points()
	if points.is_empty():
		return 0
	var added: int = 0
	# live_count() alone, NOT live_count() + added: a spawned enemy joins the `enemies` group inside
	# its own _ready, so it is already counted by the next iteration. Adding both stopped the loop at
	# half the population.
	var attempts: int = 0
	while live_count() < ambient_population and attempts < ambient_population:
		attempts += 1
		var origin: Vector3 = points[_ambient_rng.randi_range(0, points.size() - 1)]
		var offset := Vector3(
			_ambient_rng.randf_range(-ambient_scatter_m, ambient_scatter_m),
			0.0,
			_ambient_rng.randf_range(-ambient_scatter_m, ambient_scatter_m)
		)
		if host_spawn(ambient_enemy, origin + offset) == null:
			break
		added += 1
	return added


## Every nest marker the level published, from either map's marker group.
##
## `playtest_hollow.gd` publishes `playtest_hollow_marker` with kind `enemy_spawn`;
## `authored_world.gd` publishes `authored_world_marker` with kind `enemy_nest` — the same idea
## under two names, because the two maps were built a milestone apart. Reading only the first is
## how Hollowmere shipped as the main scene with four crawler nests modelled into its Blight and
## **zero crawlers in the game**: nothing was broken, nothing logged, the group simply never
## matched. An empty result still means the level has no nest, and ambient spawning quietly does
## nothing rather than dropping crawlers at the origin.
const NEST_SOURCES: Array[Array] = [
	[&"playtest_hollow_marker", "enemy_spawn"],
	[&"authored_world_marker", "enemy_nest"],
]


func ambient_spawn_points() -> Array[Vector3]:
	var points: Array[Vector3] = []
	for source: Array in NEST_SOURCES:
		for node: Node in get_tree().get_nodes_in_group(source[0] as StringName):
			var marker := node as Node3D
			if marker == null:
				continue
			if String(marker.get_meta(&"kind", "")) != String(source[1]):
				continue
			points.append(marker.global_position)
	return points


func get_def(id: StringName) -> Resource:
	return defs.get(id)


func has_def(id: StringName) -> bool:
	return defs.has(id)


## Host-only. Returns the spawned body, or null. `position` is where it lands; the caller is
## responsible for that being somewhere sensible — task 2.12 owns spawn-point choice.
func host_spawn(def_id: StringName, position: Vector3) -> Node3D:
	if not _owns_spawning():
		return null
	var def: Resource = defs.get(def_id)
	if def == null:
		MireLog.error(&"content", "EnemyWorld: unknown enemy '%s'" % def_id)
		return null

	var spawned: Node = _spawner.spawn({
		"def": String(def_id),
		"index": _take_index(),
		"origin": position,
	})
	var enemy := spawned as Node3D
	if enemy == null:
		MireLog.error(&"content", "EnemyWorld: spawn failed for '%s'" % def_id)
		return null
	enemy.connect(&"died", _on_enemy_died.bind(def_id, enemy))
	enemy_spawned.emit(enemy)
	return enemy


func live_enemies() -> Array[Node]:
	return get_tree().get_nodes_in_group(ENEMY_GROUP)


func live_count() -> int:
	var total: int = 0
	for node: Node in live_enemies():
		if is_instance_valid(node) and bool(node.call("is_alive")):
			total += 1
	return total


## Host-only. Task 2.12 clears the field at dawn through this rather than freeing nodes itself.
func host_despawn_all() -> void:
	if not _owns_spawning():
		return
	for node: Node in live_enemies():
		node.queue_free()


## How many polygons the level's navmesh baked to. Zero means enemies fall back to straight-line
## steering — see `Enemy._steer_toward()`.
func nav_polygon_count() -> int:
	return _nav_polygon_count


func nav_region() -> NavigationRegion3D:
	return _region


# ── Construction ──────────────────────────────────────────────────────────────────────────────────


## Built unconditionally on every peer, exactly like PlayerNet's: both sides must build the same
## tree, and only the spawn CALLS are host-only. A spawner that exists on one side only fails as
## silence.
func _build_replication_nodes() -> void:
	_container = Node3D.new()
	_container.name = CONTAINER_NODE
	add_child(_container)

	_spawner = MultiplayerSpawner.new()
	_spawner.name = SPAWNER_NODE
	_spawner.spawn_limit = 0
	_spawner.spawn_function = _net_spawn_enemy
	add_child(_spawner)
	_spawner.spawn_path = _spawner.get_path_to(_container)


## Runs on every peer, with the same data, so host and client build identical bodies. The name is
## derived from the spawn index and is in place before the node enters the tree, matching how
## PlayerNet names players for their peer.
func _net_spawn_enemy(data: Variant) -> Node:
	var payload: Dictionary = data as Dictionary
	if payload == null:
		return null
	var def: Resource = defs.get(StringName(String(payload.get("def", ""))))
	if def == null:
		return null

	var enemy: CharacterBody3D = ENEMY_SCRIPT.new()
	enemy.name = "Enemy%d" % int(payload.get("index", 0))
	enemy.set("definition", def)
	enemy.position = payload.get("origin", Vector3.ZERO)
	return enemy


func _load_defs() -> void:
	var dir: DirAccess = DirAccess.open(DEFS_PATH)
	if dir == null:
		return
	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	while file_name != "":
		if file_name.ends_with(".tres"):
			var res: Resource = load("%s/%s" % [DEFS_PATH, file_name])
			if res is ENEMY_DEF and StringName(res.get("id")) != &"":
				var errors: PackedStringArray = res.call("validation_errors")
				if errors.is_empty():
					defs[StringName(res.get("id"))] = res
				else:
					MireLog.error(&"content", "%s is invalid (%s), skipped"
						% [file_name, "; ".join(errors)])
		file_name = dir.get_next()
	dir.list_dir_end()


# ── Navigation ────────────────────────────────────────────────────────────────────────────────────


func _on_session_opened() -> void:
	# Re-bake for the session's level rather than trusting whatever the offline bootstrap found.
	_bootstrapped = false
	_bootstrap_elapsed = 0.0
	_nav_polygon_count = 0


func _on_disconnected() -> void:
	host_despawn_all()
	_bootstrapped = false
	_bootstrap_elapsed = 0.0


## Bakes one region from whatever static collision the current scene has. Synchronous on purpose:
## it runs once at session start, before anything is spawned, and an enemy that spawns into a
## half-baked map paths into walls. R3 measured this shape of bake as viable (D-016).
func bake_navigation() -> Node:
	var scene_root: Node = get_tree().current_scene
	if scene_root == null:
		_nav_polygon_count = 0
		return null

	var nav_mesh := NavigationMesh.new()
	nav_mesh.agent_radius = NAV_AGENT_RADIUS_M
	nav_mesh.agent_height = NAV_AGENT_HEIGHT_M
	nav_mesh.agent_max_climb = NAV_MAX_CLIMB_M
	nav_mesh.agent_max_slope = NAV_MAX_SLOPE_DEG
	nav_mesh.cell_size = NAV_CELL_SIZE_M
	nav_mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS

	var geometry := NavigationMeshSourceGeometryData3D.new()
	NavigationServer3D.parse_source_geometry_data(nav_mesh, geometry, scene_root)
	if geometry.has_data():
		NavigationServer3D.bake_from_source_geometry_data(nav_mesh, geometry)
	_nav_polygon_count = nav_mesh.get_polygon_count()

	if _region == null:
		_region = NavigationRegion3D.new()
		_region.name = "EnemyNavRegion"
		add_child(_region)
	_region.navigation_mesh = nav_mesh

	if _nav_polygon_count == 0:
		# Not an error: an empty test scene has nothing to bake, and Enemy falls back to straight-line
		# steering. Worth a line so a level that SHOULD have baked and did not is visible.
		MireLog.warn(&"content", "EnemyWorld: navmesh baked 0 polygons — enemies will steer directly")
	else:
		MireLog.info(&"content", "EnemyWorld: navmesh baked %d polygons" % _nav_polygon_count)
	return _region


func _on_enemy_died(instigator_peer_id: int, def_id: StringName, enemy: Node3D) -> void:
	enemy_died.emit(def_id, instigator_peer_id,
		enemy.global_position if is_instance_valid(enemy) else Vector3.ZERO)


func _take_index() -> int:
	var result: int = _next_index
	_next_index += 1
	return result


func _transport() -> Node:
	if _transport_node == null or not is_instance_valid(_transport_node):
		_transport_node = get_node_or_null(^"/root/NetTransport")
	return _transport_node


func _owns_spawning() -> bool:
	var transport: Node = _transport()
	if transport == null:
		return true
	if bool(transport.call("is_host")):
		return true
	return not bool(transport.call("is_active")) and not bool(transport.call("is_connecting"))
