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

signal enemy_spawned(enemy: Node3D)
signal enemy_died(enemy_id: StringName, instigator_peer_id: int, position: Vector3)

var defs: Dictionary[StringName, Resource] = {}

var _container: Node3D
var _spawner: MultiplayerSpawner
var _region: NavigationRegion3D
var _next_index: int = 1
var _nav_polygon_count: int = 0


func _ready() -> void:
	_load_defs()
	_build_replication_nodes()
	var transport: Node = get_node_or_null(^"/root/NetTransport")
	if transport != null:
		transport.get("server_started").connect(_on_session_opened)
		transport.get("connected_to_host").connect(_on_session_opened)
		transport.get("disconnected").connect(_on_disconnected)
	MireLog.info(&"content", "loaded %d enemy definition(s)" % defs.size())


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
	if _owns_spawning():
		bake_navigation()


func _on_disconnected() -> void:
	host_despawn_all()


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


func _owns_spawning() -> bool:
	var transport: Node = get_node_or_null(^"/root/NetTransport")
	if transport == null:
		return true
	if bool(transport.call("is_host")):
		return true
	return not bool(transport.call("is_active")) and not bool(transport.call("is_connecting"))
