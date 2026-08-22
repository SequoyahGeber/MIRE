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
## THE SHIPPED MAP since 4.19's cutover: `levels/procedural_island.tscn` puts this script on the
## scene root under the same environment shell (WorldEnvironment/Sun/Atmosphere/CloudDeck node
## names) the authored maps use, and `project.godot` boots it as `run/main_scene`. Hollowmere
## (`levels/hollowmere.tscn`) stays in the repo as the authored fixture/reference its pinned checks
## boot. `tools/procedural_world_check.gd` boots this headless and is the harness the parity work
## (4.16) extends.

const IslandHeightmapScript := preload("res://world/gen/island_heightmap.gd")
const BiomeMapScript := preload("res://world/gen/biome_map.gd")
const PoiMapScript := preload("res://world/gen/poi_map.gd")
const PoiStructuresScript := preload("res://world/gen/poi_structures.gd")
const ChunkStreamerScript := preload("res://world/chunk/chunk_streamer.gd")
const ChunkMesherScript := preload("res://world/chunk/chunk_mesher.gd")
const NavBakerScript := preload("res://world/chunk/nav_baker.gd")
const ScatterFieldScript := preload("res://world/gen/resource_scatter_field.gd")
const RiverWaterScript := preload("res://world/environment/river_water.gd")
const PlayerScene := preload("res://entities/player/player.tscn")
const EVENT_BUS := preload("res://core/events/event_bus.gd")
## The layer `ChunkStreamer._cook_collision()` puts terrain bodies on. Taken from the same file it
## takes it from, so a spawn probe can never be looking at a layer the ground is not on.
const TERRAIN_LAYER: int = preload("res://systems/building/placement_validator.gd").TERRAIN_LAYER

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
## How far above the ground a body is stood up. Small on purpose: it is settle clearance, not a
## drop. It used to be 1.2 m, which was the old code's only defence against F-324 — enough height
## that a player MIGHT still be falling when a collider finally cooked under them. With the ground
## primed solid before anyone is placed on it, that margin buys nothing and costs a visible 0.35 s
## drop at every spawn; what is left is just enough that the capsule never starts inside a triangle.
const SPAWN_CLEARANCE_M: float = 0.05
## How far above and below the intended spawn `_ground_height_at()` sweeps for the real collider
## surface. Up covers the heightmap reading low against the meshed triangle; down covers a spawn
## point published over a dip the mesh resolves more coarsely than the pure surface does.
const GROUND_PROBE_UP_M: float = 4.0
const GROUND_PROBE_DOWN_M: float = 8.0

## F-324's second half — the net under everything above. A body this far BELOW the surface at its
## own (x, z) is not swimming, not in a cave (this generator has none) and not walking a seabed: it
## is under the terrain mesh, where a `ConcavePolygonShape3D` with no backface collision gives it
## nothing to land on ever again. Generous enough that no legitimate slope, seam or step can reach
## it, small enough that recovery happens within a second of the fall starting.
const VOID_DEPTH_M: float = 8.0
## How often that check runs. Not per-tick: `height_at()` goes through `BiomeMap.surface_at()`,
## which rebuilds a noise set and a terrain table per call — cheap enough twice a second, wasteful
## sixty times. Falling is a state that persists, so a coarse sampler cannot miss it.
const VOID_CHECK_INTERVAL_SEC: float = 0.5

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
## F-493. Structure pieces instanced across every POI site this build — ruin walls and columns
## today. Reported in the build log so a seed that produced no building is visible without a
## screenshot.
var _structure_pieces: int = 0
var _scenes_instanced: int = 0
var _void_accum: float = 0.0
## How many times this world has pulled a body back out from under itself. Read by the check; a
## non-zero value in a real session means something upstream still places bodies over holes.
var _void_recoveries: int = 0
## `Registry.biomes.values()`, read ONCE per world build and handed to every consumer of the
## surface (F-274). Read once rather than per consumer because the whole point of the seam is that
## the mesh, the collider, the navmesh, the POI sites, the scatter and `height_at()` all agree —
## and three separate reads of the same autoload is three chances for one of them to be empty.
var _biome_defs: Array = []
## The warp fields `water_surface_at()` bends through, built once per world (F-478). `bend()` would
## construct two `FastNoiseLite` per call and this is asked once a frame per player.
var _water_noise: IslandHeightmap.NoiseSet = null
## The Shape `water_surface_at()` fills per call. One instance, reused, exactly as `ChunkMesher`
## reuses one per chunk — and the reason this is safe is the same reason that is: main thread only.
var _water_shape: IslandHeightmap.Shape = IslandHeightmap.Shape.new()
## The river's water sheet — presentation only; see `world/environment/river_water.gd`.
var river_water: Node3D = null


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
	_build_river_water()
	_build_poi_sites()
	spawn_position = _pick_spawn()
	_publish_spawn_marker()
	# BEFORE the player, and unconditionally (F-324). Unconditional because the spawn point is a
	# published contract, not a private argument to `_build_player()`: offline this file stands a
	# body on it, in a session `PlayerNet` reads it off that body and stands up to six there, and a
	# check may stand nothing on it at all. All three want the same guarantee — that the ground
	# under the point this world just advertised is real by the time anyone acts on it.
	_prime_ground_at(spawn_position)
	if build_player:
		_build_player()

	EVENT_BUS.subscribe_run_restarted(_on_run_restarted)

	MireLog.info(&"world", "ProceduralWorld: seed %d — %d POI site(s), %d marker(s), %d structure piece(s), spawn %s" % [
		world_seed, poi_sites.size(), _markers_built, _structure_pieces, spawn_position])


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
	_structure_pieces = 0
	_scenes_instanced = 0
	poi_sites.clear()

	_load_biome_defs()
	_build_streamer()
	_build_nav()
	_build_scatter()
	_build_river_water()
	_build_poi_sites()
	spawn_position = _pick_spawn()
	_publish_spawn_marker()
	_prime_ground_at(spawn_position)
	_replace_players()

	# LAST, and only on the rebuild path — every contract node above is published by now, so a
	# handler that re-reads the tree sees THIS island and never the one just torn down (F-286,
	# D-175). The boot path deliberately does not emit: a first build changes `current_scene`, which
	# every scene-keyed consumer already watches, and "rebuilt in place" is the fact this announces.
	EVENT_BUS.emit_world_rebuilt()

	MireLog.info(&"world", "ProceduralWorld: rebuilt on seed %d — %d POI site(s), %d marker(s), %d structure piece(s), spawn %s" % [
		world_seed, poi_sites.size(), _markers_built, _structure_pieces, spawn_position])


## Frees every node this file derived from the previous seed, and nothing else. Named children, not
## "all children": `_build_player()`'s Player and anything a future task parents here are not this
## function's to remove.
func _teardown_derived() -> void:
	var derived: Array[Node] = []
	for candidate: Node in [streamer, nav_baker, scatter_field, river_water]:
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
	river_water = null
	_water_noise = null


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
	var standing: Vector3 = _standing_position(spawn_position)
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
## It used to be the constant `SEA_LEVEL`, on the grounds that this generator has exactly one body
## of water. It has two (F-478). The river `IslandHeightmap` carves across every island runs its bed
## from +1.2 m at the source down to -1.2 m at the mouth, so for the first ~81% of its length there
## is a channel well above the sea with water standing in it, and answering `SEA_LEVEL` there told
## `PlayerController` the river was dry ground to walk down.
##
## `maxf`, so the estuary is not a special case: the river's own level is clamped at sea level from
## t = 0.81 on, both bodies are at exactly 0 across the mouth, and neither one wins a fight it could
## lose to floating point. Everywhere off the river `river_water_level()` answers -INF and the ocean
## is the whole answer, exactly as before.
##
## MAIN THREAD ONLY, like everything that samples through `_water_noise`: `FastNoiseLite` is not
## safe to read from two `WorkerThreadPool` tasks at once (D-075), and the shipped callers of this
## are `PlayerController`'s per-frame depth probe and `GroundFog`, both on the main thread. A worker
## that wants the same number builds its own `NoiseSet` and calls `IslandHeightmap` directly, which
## is what `RiverWater` does.
func water_surface_at(x: float, z: float) -> float:
	if _water_noise == null:
		return SEA_LEVEL
	# The BIOME-BLIND ground, not `height_at()`'s. `river_water_level()` needs both a shape and a
	# ground height to answer at all — the shape carries the land that contains the water, the ground
	# tells bank from channel — and this is asked once a frame per player, while `height_at()` goes
	# through `BiomeMap.surface_at()`, which rebuilds a noise set AND a terrain table per call. The
	# two differ by the biome's own detail/ridge amplitudes, which is centimetres of roughness on a
	# channel floor carved metres below its banks, and they differ in the safe direction: amplitude
	# 1.0 is the roughest the generator gets, so this reads the ground no lower than it really is.
	IslandHeightmapScript.shape_into(x, z, _water_noise, world_seed, _water_shape)
	var ground: float = IslandHeightmapScript.height_from_shape(
		x, z, _water_shape, _water_noise)
	return maxf(SEA_LEVEL, IslandHeightmapScript.river_water_level(
		_water_shape, world_seed, ground))


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
## The river's water (F-478). After the streamer, because the sheet is drawn against the same
## channel the terrain is carved from and building it before there is any terrain would put water on
## screen a frame ahead of the ground under it; before the POI sites, because it costs a fraction of
## what they do and a partial world is better ordered cheap-first.
func _build_river_water() -> void:
	_water_noise = IslandHeightmapScript.make_noise_set(world_seed)
	river_water = RiverWaterScript.new()
	river_water.name = "RiverWater"
	river_water.set(&"world_seed", world_seed)
	river_water.set(&"biome_defs", _biome_defs)
	add_child(river_water)
	river_water.call(&"build")


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

		# F-493: a site whose content names a structure gets one built out of kit pieces, laid out
		# from the site's own seed. `site_id` is the seed: it is already unique per site and already
		# derived from the world seed, so two peers on the same seed build the identical ruin and
		# two ruins on one island are not twins.
		var structure_id: StringName = &"" if def == null else StringName(String(def.get(&"structure_id")))
		if PoiStructuresScript.has_structure(structure_id):
			_structure_pieces += PoiStructuresScript.build(
				site_root, structure_id, hash(String(site.get("site_id", ""))), height_at
			)

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
	player.position = _standing_position(spawn_position)
	# Anchor the streamer on the player from the first frame, exactly how D-080's API expects to
	# be driven; without an anchor nothing streams. The literal must be TYPED — `set_anchors(
	# Array[Vector3])` rejects a plain Array through `call()`.
	#
	# The anchor is not what keeps this player up, and never was (F-324): `set_anchors()` schedules
	# streaming, it does not wait for it. `_ready()` primed the spawn chunks synchronously before
	# calling this, so the collider under `player.position` exists on the frame the body enters the
	# tree — the anchor only carries it onward from there.
	var anchors: Array[Vector3] = [player.position]
	streamer.call(&"set_anchors", anchors)


## The public half of `_standing_position()`, for anything OUTSIDE this file that has to put a body
## down on this island — `PlayerNet`, which offsets each peer horizontally from the level's spawn
## point and so needs its own ground reading, and any future teleport/extraction that lands someone
## somewhere. Primes first, so the answer is about ground that exists rather than ground that is
## scheduled.
##
## Optional by design: `PlayerNet` calls this through `has_method()`, so an authored map — whose
## collision is all present the moment the scene loads, and which therefore never had this problem —
## simply does not implement it and keeps its own placement.
func standing_position_at(position: Vector3) -> Vector3:
	_prime_ground_at(position)
	return _standing_position(position)


## Where a body's feet actually belong over (x, z) — the "dynamic spawn height" half of F-324.
##
## `_pick_spawn()` works in the PURE heightmap, which is the right domain for choosing a spot (it is
## deterministic, and it can answer for ground that is not resident). It is not the right domain for
## placing a body: what a capsule rests on is the LOD0 collision mesh, whose triangles are linear
## between 1 m samples and so sit a few centimetres off the smooth surface either way, and which may
## also have a POI's own geometry standing on it. So the height is chosen from the heightmap and then
## SNAPPED to whatever the physics world really has there.
##
## Ray, not heightmap arithmetic, for exactly that reason — and it is safe to cast here because the
## caller primed first: the collider under [param position] is in the space before this runs. If the
## ray finds nothing anyway, the pure surface is the honest fallback, and the void net below is what
## catches the case where even that is wrong.
func _standing_position(position: Vector3) -> Vector3:
	var surface: float = maxf(height_at(position.x, position.z), SEA_LEVEL)
	var from := Vector3(position.x, surface + GROUND_PROBE_UP_M, position.z)
	var to := Vector3(position.x, surface - GROUND_PROBE_DOWN_M, position.z)

	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	if space != null:
		var query := PhysicsRayQueryParameters3D.create(from, to)
		query.collision_mask = TERRAIN_LAYER
		var hit: Dictionary = space.intersect_ray(query)
		if not hit.is_empty():
			var ground: Vector3 = hit.get("position", Vector3.ZERO)
			return Vector3(position.x, ground.y + SPAWN_CLEARANCE_M, position.z)

	return Vector3(position.x, surface + SPAWN_CLEARANCE_M, position.z)


## Makes the ground under [param position] solid before anything is placed on it — F-324. Blocking,
## by design; see `ChunkStreamer.prime()`'s own header for why this one call is allowed to ignore
## the streaming budget.
func _prime_ground_at(position: Vector3) -> void:
	if streamer == null:
		return
	var anchors: Array[Vector3] = [position]
	# `prime()` takes its anchors as an argument and does NOT set the streamer's — the anchor set is
	# whatever `_stream_anchors()` decides for this peer (the union on a host, the local player on a
	# client — F-132 and F-330), and a rescue narrowing it to one point, even for a tick, would drop
	# a remote peer's proxies on the host. Every caller here sets anchors properly on its own path
	# immediately after.
	var cooked: int = int(streamer.call(&"prime", anchors))
	if not bool(streamer.call(&"has_ground_at", position)):
		# Not fatal, and deliberately not a push_error: the void recovery below still catches the
		# body. But it means `prime()` came back without a collider under the spawn, which should
		# be impossible, so it must be visible when it happens.
		MireLog.warn(&"world", "ProceduralWorld: spawn %v has no collider after priming" % position)
		return
	MireLog.info(&"world", "ProceduralWorld: primed %d collider(s) under spawn %v" % [
		cooked, position])


## The positions this peer streams terrain around — F-330.
##
## **The host anchors on every player.** It owns the authoritative world every peer acts in, so a
## chunk under any player has to be resident here even when nobody local is standing near it. That is
## F-132's contract and it does not change.
##
## **A client anchors on its own player only.** Feeding it the whole `players` group made every peer
## pay for every other peer's terrain, and `ChunkStreamer` multiplies that in three places at once:
## `_ring_distance()` is a MINIMUM over anchors, so each anchor earns its own LOD0 ring and therefore
## its own 5x5 block of cooked colliders (~1.33 ms each); `_evaluate_rings()` scans a 19x19 candidate
## box PER anchor every 0.2 s; and the resident set is the union of every anchor's neighbourhood.
## Six separated players turned a client's 25 collision cooks into as many as 150 and its ring scan
## into 2,166 cells — the exact opposite of interest management, on the machine least able to afford
## it.
##
## Nothing on a client needs the extra ground. A remote player's body runs
## `set_physics_process(false)` (`entities/player/player_controller.gd`), so it is a replicated visual
## proxy that never touches a collider; and at 32 m chunks the local 8-chunk load radius already
## reaches ~256 m, past the island's own ~200 m bound, so a remote peer on the same island is inside
## the local anchor's loaded set regardless. No transition margin is added because there is no case
## that needs one — if the island bound ever exceeds the load radius, that is the moment to add one
## deliberately rather than to have been carrying it unexamined.
##
## Offline takes the client branch and is identical to the union: there is one player, and it holds
## its own authority (`_local_player_body()`'s rule). Before this peer's player exists — boot, or a
## client that has not been spawned yet — the list is empty and falls back to the spawn point, which
## is what streams the ground the player is about to arrive on.
func _stream_anchors() -> Array[Vector3]:
	var anchors: Array[Vector3] = []
	# Resolved by path, not through the bare `NetTransport` identifier. This file carries a
	# `class_name`, so Godot compiles it during the global class scan — before autoload singletons
	# are registered — and the shorthand every autoload-to-autoload call in this project uses fails
	# to compile here. Same reason `Enemy._owns_simulation()` reaches for `/root/NetTransport`.
	var transport: Node = get_node_or_null(^"/root/NetTransport")
	if transport != null and bool(transport.call(&"is_host")):
		for node: Node in get_tree().get_nodes_in_group(&"players"):
			var body := node as Node3D
			if body != null:
				anchors.append(body.global_position)
	else:
		var local: Node3D = _local_player_body()
		if local != null:
			anchors.append(local.global_position)
	if anchors.is_empty():
		anchors.append(spawn_position)
	return anchors


func _physics_process(delta: float) -> void:
	if streamer == null:
		return
	streamer.call(&"set_anchors", _stream_anchors())

	_void_accum += delta
	if _void_accum >= VOID_CHECK_INTERVAL_SEC:
		_void_accum = 0.0
		_recover_from_void()


# ── F-324: the net ────────────────────────────────────────────────────────────────────────────────


## Pulls this peer's own player back onto the island if it has ended up under the terrain.
##
## Priming closes the boot hole, but it cannot be the only defence: a collider is a per-peer,
## per-frame fact, and any path that gets a body over a chunk that is not yet LOD0-resident — a
## sprint outrunning the cook budget on a slow machine, a teleport a future task adds, a seed
## rebuild landing mid-fall — reopens it. Under the mesh there is no recovery by physics, because
## the terrain collider has no backface collision, so recovery has to be someone's explicit job.
##
## OWN PLAYER ONLY, the same rule `_replace_players()` follows and for the same reason: movement is
## CLIENT-authoritative (§2.2 row 1), so a peer writing another peer's transform would be overwritten
## by the next synchronizer tick. Every peer runs this, so every peer rescues its own.
func _recover_from_void() -> void:
	var body: Node3D = _local_player_body()
	if body == null:
		return
	var here: Vector3 = body.global_position
	var surface: float = height_at(here.x, here.z)
	if here.y >= surface - VOID_DEPTH_M:
		return

	# Stand them back up where they fell, not at the spawn point: the (x, z) they reached is theirs,
	# and dragging someone across the island because a chunk cooked late is a bigger disruption than
	# the fall was. Prime first — whatever hole they went through is still a hole.
	var standing := Vector3(here.x, maxf(surface, SEA_LEVEL), here.z)
	_prime_ground_at(standing)
	standing = _standing_position(standing)
	body.global_position = standing
	if body is CharacterBody3D:
		(body as CharacterBody3D).velocity = Vector3.ZERO
	_void_recoveries += 1
	MireLog.warn(&"world", "ProceduralWorld: recovered a player from %.1f m under the surface at %v" % [
		surface - here.y, standing])
