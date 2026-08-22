extends SceneTree

## Verifies task 4.4 — world/gen/resource_scatter.gd's pure placement generator, the
## content/scatter/*.tres worked examples, and world/gen/resource_scatter_field.gd's chunk-driven
## visual + harvest-proxy wiring.
##
## Runs fully headless. The pure generator needs no renderer at all. The wiring half drives
## ResourceScatterField against a small fake streamer double (declared below) instead of a real
## ChunkStreamer, so it needs neither `--windowed` (F-005/D-074's collision-cook timing caveat)
## nor real `MultiMesh` readback (F-103) to prove the state machine — pending, built, torn down,
## depletion remembered, rebuilt — is correct. It DOES exercise the real `Registry` and
## `HarvestWorld` autoloads, so the proof that a scattered point becomes a live, host-authoritative
## `Harvestable` is a proof about the shipped wiring, not a private copy of it (F-068/F-069
## precedent, same reasoning tools/biome_check.gd's own header gives).
##
##   .agent/bin/agent godot --script tools/resource_scatter_check.gd

const ResourceScatterLib := preload("res://world/gen/resource_scatter.gd")
const ScatterDefLib := preload("res://world/gen/scatter_def.gd")
const ResourceScatterFieldScript := preload("res://world/gen/resource_scatter_field.gd")
const IslandHeightmap := preload("res://world/gen/island_heightmap.gd")
const BiomeMap := preload("res://world/gen/biome_map.gd")
const HarvestLib := preload("res://systems/harvesting/harvest_library.gd")

const SEED_A: int = 20260818
const SEED_B: int = 4242

var failures: int = 0
var registry: Node


## A minimal stand-in for `ChunkStreamer` — just the two signals and the one method
## `ResourceScatterField.attach_to_streamer()` actually reads, with the collision timing under this
## check's own control instead of a real physics cook's.
class FakeStreamer:
	extends Node
	signal chunk_mesh_ready(coord: Vector2i, lod: int)
	signal chunk_unloaded(coord: Vector2i)
	var _collision: Dictionary[Vector2i, bool] = {}

	func chunk_has_collision(coord: Vector2i) -> bool:
		return _collision.get(coord, false)

	func set_collision(coord: Vector2i, value: bool) -> void:
		_collision[coord] = value


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	registry = root.get_node_or_null(^"Registry")
	check(registry != null, "Registry is registered as an autoload")

	_check_wiring()
	_check_determinism()
	_check_biome_gate()
	_check_bounds()
	_check_slope_grounding()
	await _check_field_lifecycle()

	print("\nRESOURCE_SCATTER_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)


func _check_wiring() -> void:
	print("== the shipped project actually loads scatter content ==")
	if registry == null:
		return
	var tables: Dictionary = registry.get(&"scatter_tables")
	check(tables.size() >= 2, "at least the 2 worked-example tables load (%d)" % tables.size())
	for id: StringName in [&"forest_canopy", &"forest_undergrowth"]:
		check(bool(registry.call(&"has_scatter_table", id)),
			"content/scatter/%s.tres is indexed by its id" % id)
		var def: Resource = registry.call(&"get_scatter_table", id)
		if def != null:
			var errors: PackedStringArray = def.call(&"validation_errors")
			check(errors.is_empty(), "%s has no validation errors (%s)" % [id, errors])


func _check_determinism() -> void:
	print("\n== ResourceScatter.placements_for_chunk() is pure and deterministic ==")
	var scatter_defs: Array = registry.get(&"scatter_tables").values()
	var biome_defs: Array = registry.get(&"biomes").values()

	var p1: Array[Dictionary] = ResourceScatterLib.placements_for_chunk(3, -2, SEED_A, scatter_defs, biome_defs)
	var p2: Array[Dictionary] = ResourceScatterLib.placements_for_chunk(3, -2, SEED_A, scatter_defs, biome_defs)
	check(_same_placements(p1, p2),
		"same (chunk, seed) returns the identical placement list twice (%d vs %d points)" % [p1.size(), p2.size()])

	var p3: Array[Dictionary] = ResourceScatterLib.placements_for_chunk(3, -2, SEED_B, scatter_defs, biome_defs)
	check(not _same_placements(p1, p3), "a different world seed changes the field")

	var ids: Dictionary = {}
	var unique_ok := true
	for placement: Dictionary in p1:
		var point_id: String = placement["point_id"]
		if ids.has(point_id):
			unique_ok = false
			break
		ids[point_id] = true
	check(unique_ok, "every placement in one chunk has a unique point_id")


func _check_biome_gate() -> void:
	print("\n== a table never places outside its own biome ==")
	var scatter_defs: Array = registry.get(&"scatter_tables").values()
	var biome_defs: Array = registry.get(&"biomes").values()

	var checked_any := false
	var all_in_biome := true
	for cx in range(-6, 6):
		for cz in range(-6, 6):
			var placements: Array[Dictionary] = ResourceScatterLib.placements_for_chunk(
				cx, cz, SEED_A, scatter_defs, biome_defs
			)
			for placement: Dictionary in placements:
				checked_any = true
				var def: Resource = registry.call(&"get_scatter_table", placement["def_id"])
				var pos: Vector3 = placement["position"]
				# F-271: re-derived from `continent()` + `moisture()` + `assign()`, spelled out
				# rather than calling `BiomeMap.biome_at()`, so this stays an INDEPENDENT witness to
				# D-144 rather than a mirror of whatever the shipped path happens to do. Before
				# F-271 these three lines used `height()` — the same mistake the code under test was
				# making — so the check and the bug agreed with each other and neither agreed with
				# D-144. If this ever has to change to keep passing, that is the finding.
				# F-445: a table may declare `ANY_BIOME` and gate on Mire corruption instead —
				# there is no biome claim to witness for those, and `tools/mire_scatter_check.gd`
				# is what holds them to their own gate.
				var def_biome: StringName = def.get(&"biome_id")
				if def_biome == ScatterDefLib.ANY_BIOME:
					continue
				var continent: float = IslandHeightmap.continent(pos.x, pos.z, SEED_A)
				var moisture: float = BiomeMap.moisture(pos.x, pos.z, SEED_A)
				var biome: StringName = BiomeMap.assign(continent, moisture, biome_defs)
				if biome != def_biome:
					all_in_biome = false
	check(checked_any, "at least one placement was produced across the sampled chunks")
	check(all_in_biome, "every placed point's world position actually resolves to its table's biome")


func _check_bounds() -> void:
	print("\n== placements land within their own chunk's footprint ==")
	var scatter_defs: Array = registry.get(&"scatter_tables").values()
	var biome_defs: Array = registry.get(&"biomes").values()
	var chunk_size: int = ResourceScatterLib.CHUNK_MESHER.CHUNK_SIZE
	var found_any := false
	var in_bounds := true
	for cx in range(-6, 6):
		for cz in range(-6, 6):
			var placements: Array[Dictionary] = ResourceScatterLib.placements_for_chunk(
				cx, cz, SEED_A, scatter_defs, biome_defs
			)
			var origin_x: float = float(cx * chunk_size)
			var origin_z: float = float(cz * chunk_size)
			for placement: Dictionary in placements:
				found_any = true
				var pos: Vector3 = placement["position"]
				if pos.x < origin_x or pos.x >= origin_x + chunk_size \
						or pos.z < origin_z or pos.z >= origin_z + chunk_size:
					in_bounds = false
	check(found_any, "at least one placement was produced to bounds-check")
	check(in_bounds, "every placement's X/Z stays inside its own chunk's %dm footprint" % chunk_size)


func _check_slope_grounding() -> void:
	print("\n== slope placements embed instead of floating from a centre-point origin ==")
	var scatter_defs: Array = registry.get(&"scatter_tables").values()
	var biome_defs: Array = registry.get(&"biomes").values()
	var table: BiomeMap.TerrainTable = BiomeMap.make_terrain_table(biome_defs)
	var noise_set: BiomeMap.NoiseSet = BiomeMap.make_noise_set(SEED_A)
	var found_embedded := false
	var never_above_surface := true
	var bounded_embed := true
	for cx in range(-6, 6):
		for cz in range(-6, 6):
			var placements: Array[Dictionary] = ResourceScatterLib.placements_for_chunk(
				cx, cz, SEED_A, scatter_defs, biome_defs
			)
			for placement: Dictionary in placements:
				var pos: Vector3 = placement["position"]
				var centre_surface: float = BiomeMap.surface_from_set(
					pos.x, pos.z, noise_set, SEED_A, table
				)
				var embed: float = centre_surface - pos.y
				if embed > 0.001:
					found_embedded = true
				if embed < -0.001:
					never_above_surface = false
				if embed > ResourceScatterLib.MAX_GROUNDING_EMBED_M + 0.001:
					bounded_embed = false
	check(found_embedded, "sampled sloped ground produces at least one embedded placement")
	check(never_above_surface, "no accepted placement is lifted above its centre surface")
	check(bounded_embed, "grounding embed never exceeds %.2fm" % ResourceScatterLib.MAX_GROUNDING_EMBED_M)


## F-588: what a harvest owes the player, asserted end to end.
##
## This used to read `host_count()` straight after the depleting hit and demand `+yield_amount`.
## F-535 moved that grant: `InventoryService._on_harvest_yielded()` no longer credits the pack, it
## asks `ItemDropService` for a physical drop at the prop, and the pack is filled when a player
## reaches it. So the old assertion started failing at `b8d8d67c` — the commit that REGISTERED the
## ItemDropService autoload, which is what first made the drop path reachable in a harness (before
## it, `_on_harvest_yielded()` fell through to its no-drop-service legacy credit and the check
## passed for a reason that no longer exists in a shipped run).
##
## The dangerous fix would have been to delete the assertion, or to relax it to "the yield left the
## prop". Both would pass equally well if the yield were being DESTROYED, which is exactly the
## question the failure raised and the reason it was briefly called a P0. So the check now walks
## the whole path instead, and each step can fail on its own:
##
##   1. the harvest puts a live drop in the world, carrying the right item and the right amount
##   2. the drop arms, and offers itself for collection rather than expiring or refusing
##   3. collecting it — through `request_pickup()`, the real [E] seam, with a real range check
##      against a real member of the `players` group — credits the pack exactly once
##
## A pack that ends up short is now attributable: which of the three failed says whether the yield
## was never dropped, dropped and unreachable, or reachable and not granted.
func _check_yield_is_recoverable(
	scene: Node3D, inventory: Node, item_id: StringName, expected: int, before: int
) -> int:
	var drops: Node = root.get_node_or_null(^"/root/ItemDropService")
	check(drops != null, "ItemDropService is registered as an autoload (b8d8d67c)")
	if drops == null:
		return int(inventory.call("host_count", NetConfig.HOST_PEER_ID, item_id))

	var drop: Node3D = null
	for candidate: Node in drops.call(&"live_drops"):
		if StringName(candidate.get(&"item_id")) == item_id:
			drop = candidate as Node3D
			break
	check(drop != null, "the harvest left a physical drop in the world, rather than voiding the yield")
	if drop == null:
		return int(inventory.call("host_count", NetConfig.HOST_PEER_ID, item_id))
	check(int(drop.get(&"amount")) == expected,
		"the drop carries the whole yield (%d, %d expected)" % [int(drop.get(&"amount")), expected])

	# A stand-in for the collector. `_accept_pickup()` gates on real distance to a real member of
	# the `players` group, so a check that skipped this would be asserting a code path the game
	# never takes.
	#
	# Stood at 2.4 m: deliberately OUTSIDE `AUTO_PICKUP_RANGE_M` (1.7) and inside
	# `MANUAL_PICKUP_RANGE_M` (3.2). Standing on top of the drop instead makes the physics scan
	# collect it during the arm wait, which proves the auto path but leaves the [E] seam untested
	# and frees the drop out from under this function. At 2.4 m the two gates are separable, so
	# each is asserted for itself.
	var collector := Node3D.new()
	collector.name = "PickupCollectorStandIn"
	collector.add_to_group(&"players")
	scene.add_child(collector)
	collector.global_position = drop.global_position + Vector3(2.4, 0.0, 0.0)

	# ARM_SEC is 0.5 s of PHYSICS time and the drop refuses collection before it elapses — "still
	# settling". Waited in real time rather than counted in frames, because a fixed frame loop is
	# satisfied identically by a world whose physics never ticked.
	await _wait_real_seconds(0.75)
	check(is_instance_valid(drop),
		"a drop 2.4 m away is not auto-collected — the auto range is a real gate, not a formality")
	if not is_instance_valid(drop):
		collector.queue_free()
		return int(inventory.call("host_count", NetConfig.HOST_PEER_ID, item_id))
	check(bool(drop.call(&"is_collectable")),
		"the drop arms and offers itself for collection instead of expiring or staying inert")

	drop.call(&"request_pickup")
	await _settle()
	var after: int = int(inventory.call("host_count", NetConfig.HOST_PEER_ID, item_id))
	check(after == before + expected,
		"pressing [E] on the drop credits the pack exactly once (%d -> %d, +%d expected)"
			% [before, after, expected])
	if is_instance_valid(collector):
		collector.queue_free()
	return after


func _check_field_lifecycle() -> void:
	print("\n== ResourceScatterField materializes/tears down proxies with the LOD0/collision ring ==")
	var biome_defs: Array = registry.get(&"biomes").values()
	var scatter_defs: Array = registry.get(&"scatter_tables").values()
	var coord: Vector2i = _find_chunk_with_both_representations(SEED_A, scatter_defs, biome_defs)
	check(coord != _NOT_FOUND,
		"found a chunk near the origin producing both a NODE and a BATCH harvestable to test against (%s)" % coord)
	if coord == _NOT_FOUND:
		return

	var scene := Node3D.new()
	scene.name = "ScatterCheckScene"
	root.add_child(scene)
	current_scene = scene

	var field := ResourceScatterFieldScript.new()
	field.world_seed = SEED_A
	field.scatter_defs = registry.get(&"scatter_tables").values()
	field.biome_defs = biome_defs
	scene.add_child(field)

	var fake_streamer := FakeStreamer.new()
	scene.add_child(fake_streamer)
	field.attach_to_streamer(fake_streamer)

	var harvest: Node = root.get_node_or_null(^"HarvestWorld")
	check(harvest != null, "HarvestWorld autoload exists")

	fake_streamer.chunk_mesh_ready.emit(coord, 0)
	await process_frame
	check(field.pending_count() == 1,
		"a LOD0 chunk_mesh_ready with no collider yet waits, rather than building immediately")
	# F-369: visuals no longer wait for a collider — they are dressing, and dressing does not need
	# something to stand on. PROXIES still do, and that is what this asserts.
	check(field.chunk_count() == 1, "the chunk is dressed with visuals immediately")
	check(field.proxy_chunk_count() == 0,
		"but no harvest proxy is built while the chunk still has no collider")

	fake_streamer.set_collision(coord, true)
	await _wait_real_seconds(0.35)
	check(field.chunk_count() == 1, "the chunk builds once chunk_has_collision() reports true")
	check(field.pending_count() == 0, "the pending queue drains once built")

	if harvest != null:
		harvest.call("refresh_current_scene")
	for _frame: int in 4:
		await process_frame

	var node_holders: Array[Node] = scene.find_children("Harvest_*", "", true, false)
	var batch_holders: Array[Node] = scene.find_children("HarvestBatch_*", "", true, false)
	check(not node_holders.is_empty(), "the forest canopy table produced at least one NODE proxy (%d)" % node_holders.size())
	check(not batch_holders.is_empty(), "the forest undergrowth table produced at least one BATCH proxy (%d)" % batch_holders.size())

	var wired_node: Node = null
	if not node_holders.is_empty():
		wired_node = (node_holders[0] as Node3D).get_node_or_null(^"Harvestable")
	check(wired_node != null,
		"HarvestWorld's existing wiring turned a scattered NODE holder into a live Harvestable, unmodified")

	var wired_batch: Node = null
	if not batch_holders.is_empty():
		wired_batch = (batch_holders[0] as Node3D).get_node_or_null(^"Harvestable")
	check(wired_batch != null,
		"HarvestWorld's existing wiring turned a scattered BATCH holder into a live Harvestable, unmodified")

	# Deplete the node proxy, unload its chunk, and rebuild — the whole point of the depletion
	# memory is that this exact point comes back down, not fresh.
	var inventory: Node = root.get_node_or_null(^"InventoryService")
	var point_id: String = ""
	var yield_item_id: StringName = &""
	var yield_amount: int = 0
	var count_before_harvest: int = 0
	if wired_node != null:
		var definition: Resource = wired_node.get(&"definition")
		point_id = String((node_holders[0] as Node3D).get_meta(&"point_id", ""))
		yield_item_id = definition.get(&"yield_item_id")
		yield_amount = int(definition.get(&"yield_amount"))
		if inventory != null:
			count_before_harvest = int(inventory.call("host_count", NetConfig.HOST_PEER_ID, yield_item_id))
		check(bool(wired_node.call("host_apply_damage", int(definition.get(&"max_health")), 1)),
			"the proxy accepts a lethal host hit like any other Harvestable")
		await _settle()
		check(not bool(wired_node.get(&"active")), "the proxy depletes")

	var count_after_harvest: int = count_before_harvest
	if inventory != null and not yield_item_id.is_empty():
		count_after_harvest = await _check_yield_is_recoverable(
			scene, inventory, yield_item_id, yield_amount, count_before_harvest
		)

	fake_streamer.chunk_unloaded.emit(coord)
	check(field.chunk_count() == 0, "the chunk tears down on chunk_unloaded")
	if not point_id.is_empty():
		check(field.is_point_depleted(point_id),
			"the field remembers this point was depleted before freeing its holder")

	fake_streamer.chunk_mesh_ready.emit(coord, 0)
	fake_streamer.set_collision(coord, true)
	await _wait_real_seconds(0.35)
	check(field.chunk_count() == 1, "the chunk rebuilds after coming back into range")
	if harvest != null:
		harvest.call("refresh_current_scene")
	for _frame: int in WIRE_WAIT_FRAMES:
		await process_frame

	if not point_id.is_empty():
		var rebuilt: Node3D = scene.find_child(
			"Harvest_%s" % point_id.replace(":", "_"), true, false
		)
		var rebuilt_harvestable: Node = rebuilt.get_node_or_null(^"Harvestable") if rebuilt != null else null
		check(rebuilt_harvestable != null, "the same point rebuilds a live Harvestable again")
		if rebuilt_harvestable != null:
			check(not bool(rebuilt_harvestable.get(&"active")),
				"the rebuilt proxy remembers it was depleted, instead of coming back full-health")
		# F-231: the rebuild replays remembered depletion through host_restore_depleted(), not a
		# second host_apply_damage() hit — it must NOT grant another copy of the yield.
		if inventory != null and not yield_item_id.is_empty():
			var count_after_rebuild: int = int(inventory.call("host_count", NetConfig.HOST_PEER_ID, yield_item_id))
			check(count_after_rebuild == count_after_harvest,
				"rebuilding an already-depleted point grants no duplicate yield (%d -> %d)"
					% [count_after_harvest, count_after_rebuild])

	# A chunk downgrading away from LOD0 (never unloading) tears down scatter too.
	# F-369: dropping out of the COLLISION ring costs a chunk its proxies and keeps its visuals —
	# the player can no longer reach it, but they can still see it. Only leaving the visual band
	# (or unloading) clears it entirely.
	fake_streamer.chunk_mesh_ready.emit(coord, 1)
	await process_frame
	check(field.proxy_chunk_count() == 0,
		"a chunk that drops out of the LOD0 ring loses its harvest proxies")
	check(field.chunk_count() == 1, "...and keeps its visuals, because you can still see it")

	fake_streamer.chunk_mesh_ready.emit(coord, 2)
	await process_frame
	check(field.chunk_count() == 0, "leaving the visual band entirely does clear the scatter")


const WIRE_WAIT_FRAMES: int = 32
const _NOT_FOUND := Vector2i(999999, 999999)


## Scans outward from the origin for a chunk whose ACTUAL placement list (not just its biome)
## contains at least one NODE-represented and one BATCH-represented harvestable — the two proxy
## shapes this check needs to exercise together. Checking the biome alone was not enough: a chunk
## can sit in the right biome and still roll zero trees at either table's own coverage chance.
func _find_chunk_with_both_representations(seed_value: int, scatter_defs: Array, biome_defs: Array) -> Vector2i:
	for radius: int in 16:
		for cx: int in range(-radius, radius + 1):
			for cz: int in range(-radius, radius + 1):
				if maxi(absi(cx), absi(cz)) != radius:
					continue
				var placements: Array[Dictionary] = ResourceScatterLib.placements_for_chunk(
					cx, cz, seed_value, scatter_defs, biome_defs
				)
				var has_node := false
				var has_batch := false
				for placement: Dictionary in placements:
					var asset_id: StringName = placement["asset"]
					if not HarvestLib.is_harvestable(asset_id):
						continue
					if HarvestLib.representation_for(asset_id) == HarvestLib.Represent.NODE:
						has_node = true
					else:
						has_batch = true
				if has_node and has_batch:
					return Vector2i(cx, cz)
	return _NOT_FOUND


func _same_placements(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i: int in a.size():
		var pa: Dictionary = a[i]
		var pb: Dictionary = b[i]
		if pa["point_id"] != pb["point_id"] or pa["asset"] != pb["asset"]:
			return false
		if not (pa["position"] as Vector3).is_equal_approx(pb["position"] as Vector3):
			return false
		if not is_equal_approx(float(pa["rotation_y"]), float(pb["rotation_y"])):
			return false
		if not is_equal_approx(float(pa["scale"]), float(pb["scale"])):
			return false
	return true


## Physics interpolation and deferred wiring both need a beat to settle — same margin
## tools/harvest_batch_check.gd already uses for the same reason.
func _settle() -> void:
	await physics_frame
	await physics_frame
	await process_frame


## Real wall-clock time, not a frame count — ResourceScatterField's own poll accumulates real
## `delta`, the same lesson task 4.3 already paid for (docs/DELEGATION.md's 4.3 entry).
func _wait_real_seconds(seconds: float) -> void:
	var deadline: int = Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await process_frame


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)
