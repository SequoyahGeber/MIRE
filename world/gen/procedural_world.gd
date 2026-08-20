class_name ProceduralWorld
extends Node3D

## Task 4.15 (D-143) — the composer F-139 was waiting for: one node that turns the shipped, pure
## pipeline (ChunkStreamer 4.3 · ResourceScatterField 4.4 · NavBaker 4.5 · PoiMap 4.7) into a
## playable level, by publishing the SAME marker/group contract the authored maps publish. The
## world services (Wellspring, Extraction, ChestPlacement, Crafting, EnemyWorld, HarvestWorld)
## discover their sites by scanning these groups and metas — so they light up here unchanged, which
## is the whole of D-143: the cutover composes, it does not rewrite.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2): none of its own. Every placement below is derived
## from `GameState.run_seed` (4.6) through pure functions, identically on every peer; mutations ride
## the systems that already own them (Harvestable/HOST, WorldDeltaLog, MireGrid). This node never
## sends or receives anything.
##
## Reachable only through `DevLaunch --procedural` until 4.19's default cutover — Hollowmere remains
## the shipped map (F-139's own record of that decision). `tools/procedural_world_check.gd` boots
## this headless and is the harness the parity work (4.16) extends.

const IslandHeightmapScript := preload("res://world/gen/island_heightmap.gd")
const BiomeMapScript := preload("res://world/gen/biome_map.gd")
const PoiMapScript := preload("res://world/gen/poi_map.gd")
const ChunkStreamerScript := preload("res://world/chunk/chunk_streamer.gd")
const ChunkMesherScript := preload("res://world/chunk/chunk_mesher.gd")
const NavBakerScript := preload("res://world/chunk/nav_baker.gd")
const ScatterFieldScript := preload("res://world/gen/resource_scatter_field.gd")
const PlayerScene := preload("res://entities/player/player.tscn")
const EVENT_BUS := preload("res://core/events/event_bus.gd")

## Same contract constants `world/gen/authored_world.gd` publishes — duplicated by value, not
## imported, for the same reason EntityDirectory duplicates its group names: the string IS the
## contract, and a rename on either side must fail a check loudly rather than silently retarget.
const MARKER_GROUP: StringName = &"authored_world_marker"
const TERRAIN_GROUP: StringName = &"authored_world_terrain"

## Where the ocean's surface sits. `IslandHeightmap` measures every height against this, so it is
## the datum "below this is water" already meant everywhere it was written as a bare 0.0.
const SEA_LEVEL: float = 0.0

## How far (m) the spawn probe walks in from the island edge looking for standable shore, and the
## band of heights that read as "beach, above the waterline". WORLDGEN.md §3.1: shore start is a
## pacing choice — the first minutes walk inland.
## Probed outermost-first: the shore's radius depends on the seed (the falloff crosses the beach
## band at a different distance per island), so the probe walks rings inward and takes the first
## ring that yields standable beach — landfall stays as close to the water as this seed allows.
const SPAWN_RING_FRACTIONS: Array[float] = [0.85, 0.8, 0.75, 0.7, 0.65, 0.6, 0.55, 0.5]
const SPAWN_HEIGHT_MIN: float = 1.0
const SPAWN_HEIGHT_MAX: float = 5.0
const SPAWN_MAX_SLOPE: float = 0.45          # rise over 1 m run — comfortably under walkable
const SPAWN_CANDIDATES: int = 64             # angles probed around the shore ring
## Extra clearance beyond a POI's own `clearance_m` so nobody spawns inside a defense wave.
const SPAWN_POI_MARGIN_M: float = 8.0

## True in the shipped game; the check turns it off to boot faster and to keep the harness free of
## a live player body (the same switch `authored_world.gd` gives its props).
@export var build_player: bool = true

var world_seed: int = 0
var streamer: Node3D
var nav_baker: Node
var scatter_field: Node3D
var poi_sites: Array[Dictionary] = []
var spawn_position: Vector3 = Vector3.ZERO

var _markers_built: int = 0
var _scenes_instanced: int = 0
## `Registry.biomes.values()`, read ONCE per world build and handed to every consumer of the
## surface (F-274). Read once rather than per consumer because the whole point of the seam is that
## the mesh, the collider, the navmesh, the POI sites, the scatter and `height_at()` all agree —
## and three separate reads of the same autoload is three chances for one of them to be empty.
var _biome_defs: Array = []


func _ready() -> void:
	add_to_group(TERRAIN_GROUP)

	# The one seam a procedural world needs that an authored one does not: the shared run seed.
	# get_node_or_null, not a bare autoload name — this scene is booted by a --script harness whose
	# compile pass runs before autoloads exist (F-011's standing rule).
	var game_state: Node = get_node_or_null(^"/root/GameState")
	if game_state == null:
		push_error("ProceduralWorld: no GameState autoload — cannot derive a world without a seed")
		return
	world_seed = int(game_state.call(&"ensure_seed"))

	_load_biome_defs()
	_build_streamer()
	_build_nav()
	_build_scatter()
	_build_poi_sites()
	spawn_position = _pick_spawn()
	_publish_spawn_marker()
	if build_player:
		_build_player()

	EVENT_BUS.subscribe_run_restarted(_on_run_restarted)

	MireLog.info(&"world", "ProceduralWorld: seed %d — %d POI site(s), %d marker(s), spawn %s" % [
		world_seed, poi_sites.size(), _markers_built, spawn_position])


func _exit_tree() -> void:
	EVENT_BUS.unsubscribe_run_restarted(_on_run_restarted)


# ── F-258: the fresh island ───────────────────────────────────────────────────────────────────────


## Fires on every peer (`EventBus.run_restarted` is re-derived client-side from the WorldDeltaLog
## record — `CycleService._on_world_delta_applied()`), which is exactly right for this node: it has
## no network authority of its own (see the header), every placement below is a pure function of the
## seed, and every peer therefore has to re-derive the SAME new island independently. Reads
## `GameState.run_seed` directly rather than `ensure_seed()` — by the time `run_restarted` lands, the
## host has already drawn the new value and a client has already adopted it off the same reliable
## channel, so there is nothing left to lazily draw and a peer that somehow has none should not
## invent one that disagrees with everyone else's.
func _on_run_restarted() -> void:
	var game_state: Node = get_node_or_null(^"/root/GameState")
	if game_state == null or not bool(game_state.call(&"is_seed_ready")):
		return
	var next_seed: int = int(game_state.get(&"run_seed"))
	if next_seed == world_seed:
		return
	rebuild_for_seed(next_seed)


## Re-derives the whole world from a new seed, in place. Public so a check (and a future "reroll"
## console verb) can drive it without faking a restart.
##
## Everything derived is torn down and rebuilt rather than mutated: `ChunkStreamer`/`NavBaker`/
## `ResourceScatterField` each cache per-chunk work keyed to the OLD seed (meshes, nav regions,
## scatter proxies) and none of them has, or should grow, a "forget everything" path — one exists
## already and it is `_exit_tree()`, which `remove_child()` runs synchronously. Synchronous matters:
## `queue_free()` alone would leave the old streamer in the tree until the end of the frame, so the
## new one would collide with its name and keep meshing the old island for a frame in between.
##
## The PLAYER is not rebuilt — it is repositioned. A player body is not derived from the seed (it
## carries inventory, health and, in a session, a peer's own authority), so freeing and re-instancing
## it would throw away live run state to move a body three hundred metres.
func rebuild_for_seed(seed_value: int) -> void:
	world_seed = seed_value
	_teardown_derived()
	_markers_built = 0
	_scenes_instanced = 0
	poi_sites.clear()

	_load_biome_defs()
	_build_streamer()
	_build_nav()
	_build_scatter()
	_build_poi_sites()
	spawn_position = _pick_spawn()
	_publish_spawn_marker()
	_replace_players()

	# LAST, and only on the rebuild path — every contract node above is published by now, so a
	# handler that re-reads the tree sees THIS island and never the one just torn down (F-286,
	# D-175). The boot path deliberately does not emit: a first build changes `current_scene`, which
	# every scene-keyed consumer already watches, and "rebuilt in place" is the fact this announces.
	EVENT_BUS.emit_world_rebuilt()

	MireLog.info(&"world", "ProceduralWorld: rebuilt on seed %d — %d POI site(s), %d marker(s), spawn %s" % [
		world_seed, poi_sites.size(), _markers_built, spawn_position])


## Frees every node this file derived from the previous seed, and nothing else. Named children, not
## "all children": `_build_player()`'s Player and anything a future task parents here are not this
## function's to remove.
func _teardown_derived() -> void:
	var derived: Array[Node] = []
	for candidate: Node in [streamer, nav_baker, scatter_field]:
		if candidate != null and is_instance_valid(candidate):
			derived.append(candidate)
	for child_name: String in ["PoiSites", "SpawnMarker"]:
		var node: Node = get_node_or_null(NodePath(child_name))
		if node != null:
			derived.append(node)
	for node: Node in derived:
		remove_child(node)          # synchronous _exit_tree — see rebuild_for_seed()'s note
		node.queue_free()
	streamer = null
	nav_baker = null
	scatter_field = null


## Stands THIS peer's own player back up on the new island's shore, and re-anchors the respawn point
## that goes with it.
##
## Own-player only, deliberately: a player body's movement is CLIENT-authoritative (§2.2 row 1), so a
## peer writing another peer's transform would be overwritten by the next synchronizer tick anyway —
## and it does not need to, because `run_restarted` reaches every peer, so every peer moves its own.
## `PlayerHealth.rebind_local_spawn()` is the one call because both halves have to happen together:
## moving the body alone leaves that file's captured spawn transform pointing at a shore the previous
## seed had and this one may not, so the next death would respawn the player into open ocean — F-063's
## own bug (respawning at a position nobody chose) arriving by a different route. The direct-move
## fallback covers a harness that boots this scene without the autoloads (F-011's standing shape).
func _replace_players() -> void:
	var standing: Vector3 = spawn_position + Vector3.UP * 1.2
	var player_health: Node = get_node_or_null(^"/root/PlayerHealth")
	if player_health != null and player_health.has_method(&"rebind_local_spawn"):
		player_health.call("rebind_local_spawn", standing, NAN)
	else:
		var body: Node3D = _local_player_body()
		if body != null:
			body.position = standing
	if streamer != null:
		var anchors: Array[Vector3] = [standing]
		streamer.call(&"set_anchors", anchors)


## Same rule `PlayerHealth._local_player_body()` uses — the body this peer has authority over. Only
## reached by the fallback above; duplicated rather than exposed because it is two lines and the
## alternative is a public accessor on PlayerHealth that nothing else wants.
func _local_player_body() -> Node3D:
	for node: Node in get_tree().get_nodes_in_group(&"players"):
		var player := node as Node3D
		if player != null and player.is_multiplayer_authority():
			return player
	return null


## The same passthrough `authored_world.gd` exposes, so anything asking "the world" for ground
## height keeps one call shape across both map kinds.
func height_at(x: float, z: float) -> float:
	return BiomeMapScript.surface_at(x, z, world_seed, _biome_defs)


## The other half of that pair (F-284): the water surface over (x, z).
##
## Constant, because this generator has exactly one body of water — the ocean the island stands out
## of — and `IslandHeightmap` measures every height it produces against y = 0. It is a function of
## (x, z) anyway so that a caller cannot tell this map from an authored one, whose surface genuinely
## varies per point. A generator that later grows inland lakes changes this, not its callers.
func water_surface_at(_x: float, _z: float) -> float:
	return SEA_LEVEL


# ── the pipeline, composed ────────────────────────────────────────────────────────────────────────


## get_node_or_null, not a bare autoload name — this scene is booted by a --script harness whose
## compile pass runs before autoloads exist (F-011's standing rule), and a harness with no Registry
## is a legitimate configuration. It gets the biome-blind surface, which is honest: it has no biomes.
func _load_biome_defs() -> void:
	var registry: Node = get_node_or_null(^"/root/Registry")
	_biome_defs = (registry.get(&"biomes") as Dictionary).values() if registry != null else []


func _build_streamer() -> void:
	streamer = ChunkStreamerScript.new()
	streamer.name = "ChunkStreamer"
	streamer.set(&"world_seed", world_seed)
	# F-274: the mesh, the collider, the navmesh (via NavBaker.bind), the POI sites, the scatter and
	# `height_at()` all read the SAME table, so every one of them describes the same ground.
	streamer.set(&"biome_defs", _biome_defs)
	add_child(streamer)


func _build_nav() -> void:
	nav_baker = NavBakerScript.new()
	nav_baker.name = "NavBaker"
	add_child(nav_baker)
	nav_baker.call(&"bind", streamer, world_seed)


func _build_scatter() -> void:
	var registry: Node = get_node_or_null(^"/root/Registry")
	scatter_field = ScatterFieldScript.new()
	scatter_field.name = "ResourceScatterField"
	scatter_field.set(&"world_seed", world_seed)
	if registry != null:
		scatter_field.set(&"scatter_defs", (registry.get(&"scatter_tables") as Dictionary).values())
		scatter_field.set(&"biome_defs", _biome_defs)
	add_child(scatter_field)
	scatter_field.call(&"attach_to_streamer", streamer)


## One site loop, dumb on purpose (D-143): WHAT a site is to the services lives on `PoiDef.
## marker_kind`, WHERE it goes came from PoiMap. This function only instances and publishes.
func _build_poi_sites() -> void:
	var registry: Node = get_node_or_null(^"/root/Registry")
	if registry == null:
		return
	var poi_defs: Array = (registry.get(&"poi") as Dictionary).values()
	poi_sites = PoiMapScript.sites_for_island(world_seed, poi_defs, _biome_defs)

	var defs_by_id: Dictionary = {}
	for def: Resource in poi_defs:
		defs_by_id[def.get(&"id")] = def

	var holder := Node3D.new()
	holder.name = "PoiSites"
	add_child(holder)

	for site: Dictionary in poi_sites:
		var def: Resource = defs_by_id.get(site.get("def_id"), null)
		var site_root := Node3D.new()
		site_root.name = String(site.get("site_id", "site"))
		holder.add_child(site_root)
		site_root.global_position = site.get("position", Vector3.ZERO)
		site_root.rotation.y = float(site.get("rotation_y", 0.0))

		var scene_path: String = String(site.get("scene_path", ""))
		if not scene_path.is_empty():
			var packed: Resource = load(scene_path)
			if packed is PackedScene:
				site_root.add_child((packed as PackedScene).instantiate())
				_scenes_instanced += 1

		# The marker IS the contract. Kind comes from content; an empty kind is scenery and gets
		# no marker — same as an authored map simply not placing one.
		var kind: String = "" if def == null else String(def.get(&"marker_kind"))
		if kind.is_empty():
			continue
		var marker := Marker3D.new()
		# An authored marker_name is the contract for name-keyed services (PoiDef's own note);
		# the default suits every kind-only consumer.
		var authored_name: String = "" if def == null else String(def.get(&"marker_name"))
		marker.name = authored_name if not authored_name.is_empty() else "%sMarker" % site_root.name
		# Group and meta BEFORE add_child — the services discover markers on `node_added`, which
		# fires during add_child, so a marker configured afterwards enters the tree invisible to
		# them. F-012's lesson (NetInterest before add_child), same mechanism, new consumer.
		marker.add_to_group(MARKER_GROUP)
		marker.set_meta(&"kind", kind)
		site_root.add_child(marker)
		_markers_built += 1


# ── spawn (WORLDGEN.md §3.1) ──────────────────────────────────────────────────────────────────────


## Deterministic from the seed and the POI layout: probe a ring of shore candidates, keep the
## standable ones clear of every POI, prefer the one nearest the Wellsprings' centroid so the first
## walk inland points at the game. Falls back to the least-bad candidate rather than failing —
## a spawn that is slightly steep beats no spawn, and the check asserts the normal case is clean.
func _pick_spawn() -> Vector3:
	var objective_centroid: Vector3 = _objective_centroid()
	var fallback: Vector3 = Vector3.ZERO
	var fallback_height_error: float = INF

	for ring_fraction: float in SPAWN_RING_FRACTIONS:
		var best: Vector3 = Vector3.ZERO
		var best_score: float = -INF
		var radius: float = IslandHeightmapScript.ISLAND_RADIUS * ring_fraction
		for index: int in range(SPAWN_CANDIDATES):
		# TAU * i / N is a transcendental-free angle only if we avoid sin/cos... which we cannot
		# for a ring. But determinism here needs same-input-same-output ACROSS PEERS for gameplay
		# placement, and D-017's ban is scoped to WORLD-GEN state that must hash identically.
		# A spawn point is gameplay state the host could even override; still, keep it in the safe
		# set anyway by walking the square's perimeter instead of a trig circle — cheap and exact.
			var t: float = float(index) / float(SPAWN_CANDIDATES)   # 0..1 around the perimeter
			var direction: Vector2 = _square_perimeter_direction(t)
			var x: float = direction.x * radius
			var z: float = direction.y * radius
			var height: float = height_at(x, z)

			var height_error: float = 0.0
			if height < SPAWN_HEIGHT_MIN:
				height_error = SPAWN_HEIGHT_MIN - height
			elif height > SPAWN_HEIGHT_MAX:
				height_error = height - SPAWN_HEIGHT_MAX
			if height_error < fallback_height_error:
				fallback_height_error = height_error
				fallback = Vector3(x, maxf(height, SPAWN_HEIGHT_MIN), z)
			if height_error > 0.0:
				continue
			if _slope_at(x, z) > SPAWN_MAX_SLOPE:
				continue
			if not _clear_of_pois(x, z):
				continue
			# Standable shore. Score by closeness to the objectives so landfall faces the game.
			var to_objectives: float = \
				Vector2(x - objective_centroid.x, z - objective_centroid.z).length()
			var score: float = -to_objectives
			if score > best_score:
				best_score = score
				best = Vector3(x, height, z)
		if best_score > -INF:
			return best

	return fallback


## (x,z) unit-square perimeter walk — four linear segments, no trig, exact on every platform.
func _square_perimeter_direction(t: float) -> Vector2:
	var s: float = t * 4.0
	if s < 1.0:
		return Vector2(1.0, -1.0 + 2.0 * s).normalized()
	if s < 2.0:
		return Vector2(1.0 - 2.0 * (s - 1.0), 1.0).normalized()
	if s < 3.0:
		return Vector2(-1.0, 1.0 - 2.0 * (s - 2.0)).normalized()
	return Vector2(-1.0 + 2.0 * (s - 3.0), -1.0).normalized()


func _slope_at(x: float, z: float) -> float:
	var here: float = height_at(x, z)
	var dx: float = absf(height_at(x + 1.0, z) - here)
	var dz: float = absf(height_at(x, z + 1.0) - here)
	return maxf(dx, dz)


func _clear_of_pois(x: float, z: float) -> bool:
	for site: Dictionary in poi_sites:
		var position: Vector3 = site.get("position", Vector3.ZERO)
		var clearance: float = float(site.get("clearance", 0.0)) + SPAWN_POI_MARGIN_M
		if Vector2(x - position.x, z - position.z).length() < clearance:
			return false
	return true


func _objective_centroid() -> Vector3:
	var total := Vector3.ZERO
	var count: int = 0
	for site: Dictionary in poi_sites:
		if site.get("def_id") == &"wellspring":
			total += site.get("position", Vector3.ZERO) as Vector3
			count += 1
	return total / float(count) if count > 0 else Vector3.ZERO


## Published so a future session-spawn consumer can read it the way layout JSON is read today;
## kind `spawn` is new with this file and deliberately not yet consumed by any service (the
## authored flow's F-063 capture continues to work through the Player node below).
func _publish_spawn_marker() -> void:
	var marker := Marker3D.new()
	marker.name = "SpawnMarker"
	marker.position = spawn_position          # local == global: this node sits at the origin
	marker.add_to_group(MARKER_GROUP)         # before add_child — same F-012 ordering as above
	marker.set_meta(&"kind", "spawn")
	add_child(marker)
	_markers_built += 1


func _build_player() -> void:
	var player := PlayerScene.instantiate() as Node3D
	player.name = "Player"           # the authored maps' convention: offline local authority
	add_child(player)
	player.position = spawn_position + Vector3.UP * 1.2
	# Anchor the streamer on the player from the first frame, exactly how D-080's API expects to
	# be driven; without an anchor nothing streams and the player falls through the void. The
	# literal must be TYPED — `set_anchors(Array[Vector3])` rejects a plain Array through `call()`.
	var anchors: Array[Vector3] = [player.position]
	streamer.call(&"set_anchors", anchors)


func _physics_process(_delta: float) -> void:
	if streamer == null:
		return
	var anchors: Array[Vector3] = []
	for node: Node in get_tree().get_nodes_in_group(&"players"):
		var body := node as Node3D
		if body != null:
			anchors.append(body.global_position)
	if anchors.is_empty():
		anchors.append(spawn_position)
	streamer.call(&"set_anchors", anchors)
