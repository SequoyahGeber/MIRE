extends SceneTree

## F-599 — can two people actually START, without ten minutes of walking?
##
## Sequoyah, before a co-op session with a friend: *"i dont want to get hard locked in progression
## during the play test."* `progression_reachability_check` proves nothing is UNREACHABLE. This asks
## the different and more likely question: **is the opening within reach of where you land?**
##
## A run that technically works but opens with a ten-minute hunt for sticks is not a hard lock, and
## it is still the thing that decides whether his friend is enjoying the game in minute five. Nobody
## has measured it, because reachability and proximity are different properties and only one of them
## had an instrument.
##
## ## What "the opening" costs, derived rather than restated
##
## Read from the content: `content/buildables/workbench.tres` costs its own materials, and
## `content/recipes/wooden_axe.tres` costs its own. Deriving them means this check cannot drift from
## a rebalance — the numbers below come out of the same files a designer edits.
##
## Both are gathered BARE-HANDED (`required_tool == 0`): `nettle` and `sedge` give fibre, `bush` and
## `sapling` give branches. That is the real bootstrap, and it is why the game does not lock at
## minute one — `damage_from_tool()` floors a wrong-tool swing to zero, so if the opening needed a
## tool it would need an axe to build the bench that crafts the axe.
##
## Authority: none. Read-only measurement over a real generated island.

const HarvestLibrary := preload("res://systems/harvesting/harvest_library.gd")

const WorldScene: String = "res://levels/procedural_island.tscn"
const HARVESTABLE_HOLDER_GROUP: StringName = &"authored_world_harvestable"

## Seeds to sample. Proximity is a property of one island's layout, so a single seed says nothing —
## the same trap `progression_reachability_check` avoids by running five.
const SEEDS: Array[int] = [20260822, 11, 777001]

## What a reasonable opening walk looks like. Not a physics number — a patience number. At the
## player's ~4.5 m/s this is roughly a minute of walking to the furthest thing you need.
const COMFORTABLE_M: float = 260.0
## Past this the opening is a chore rather than an exploration.
const TOLERABLE_M: float = 450.0

var failures: int = 0
## spawn position per seed — two seeds landing in the same place means the reseed did not take.
var _fingerprints: Dictionary = {}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var registry: Node = root.get_node_or_null(^"Registry")
	check(registry != null, "Registry autoload exists")
	if registry == null:
		_finish()
		return

	var needed: Dictionary = _opening_cost(registry)
	print("\nThe opening costs: %s" % str(needed))
	check(not needed.is_empty(), "the opening cost was derived from content, not restated")

	var sources: Dictionary = _bare_hand_sources(registry)
	print("Bare-hand sources: %s" % str(sources))
	for item_id: StringName in needed:
		var yielding: Array[StringName] = []
		for def_id: StringName in sources:
			if StringName((sources[def_id] as Dictionary)["item"]) == item_id:
				yielding.append(def_id)
		check(not yielding.is_empty(),
			"'%s' has at least one bare-hand source (%s)" % [item_id, str(yielding)])

	for seed_value: int in SEEDS:
		await _check_seed(seed_value, needed, sources)

	_finish()


## Build a real island and measure how far from the spawn a player must walk to gather the opening.
func _check_seed(seed_value: int, needed: Dictionary, sources: Dictionary) -> void:
	print("\n== seed %d ==" % seed_value)
	var packed: PackedScene = load(WorldScene) as PackedScene
	var world: Node = packed.instantiate()
	root.add_child(world)
	for _frame: int in 10:
		await process_frame
	# `rebuild_for_seed()`, NOT `world.set(&"world_seed", ...)` before add_child. `_ready()` assigns
	# `world_seed` from `GameState.ensure_seed()` and overwrites anything set beforehand — so the
	# first version of this check ran three "different" seeds and got byte-identical placements from
	# one island three times over. The tell was two seeds agreeing to the metre; asserted below now
	# rather than trusted, because a seeded check that isn't actually reseeding is worse than no
	# check at all (it reports coverage it does not have).
	world.call(&"rebuild_for_seed", seed_value)
	for _frame: int in 10:
		await process_frame
	check(int(world.get(&"world_seed")) == seed_value,
		"seed %d actually took (world reports %d)" % [seed_value, int(world.get(&"world_seed"))])

	var spawn: Vector3 = world.get(&"spawn_position")

	# A STANDING PLAYER, or this measures an empty island. `ProceduralWorld._physics_process()`
	# re-anchors the chunk streamer on the `players` group every physics tick, so a world booted
	# with nobody in it streams almost nothing and every harvestable count comes back near zero —
	# which reads exactly like "the island has no sticks on it" and is really "no chunks loaded".
	# Same family as F-563, where a render probe photographed open ocean for the same reason.
	var stand_in := CharacterBody3D.new()
	stand_in.add_to_group(&"players")
	root.add_child(stand_in)
	stand_in.global_position = spawn
	# Long enough for the spawn ring to finish streaming. Asserted below rather than assumed: if
	# nothing streamed, the check says so instead of reporting a barren island.
	for _frame: int in 240:
		await process_frame
	var streamed: int = get_nodes_in_group(HARVESTABLE_HOLDER_GROUP).size()
	check(streamed > 0, "seed %d streamed harvestables around the spawn (%d holder(s))"
		% [seed_value, streamed])
	if streamed == 0:
		world.queue_free()
		stand_in.queue_free()
		return
	# Distance at which the Nth unit of each needed item has been gathered — i.e. how far you must
	# range to finish the opening, not how far to the first stick. Counting only the nearest source
	# would pass an island with exactly one nettle on it.
	var worst_item: StringName = &""
	var worst_distance: float = 0.0
	for item_id: StringName in needed:
		var distances: Array[float] = _distances_to(item_id, spawn, sources)
		var required: int = int(needed[item_id])
		var per_node: int = 1
		for source: Dictionary in sources.values():
			if StringName(source["item"]) == item_id:
				per_node = maxi(per_node, int(source["per_node"]))
		var nodes_needed: int = ceili(float(required) / float(per_node))
		if distances.size() < nodes_needed:
			check(false, "seed %d has %d placed source(s) of '%s', needs %d"
				% [seed_value, distances.size(), item_id, nodes_needed])
			continue
		var reach: float = distances[nodes_needed - 1]
		print("  %-14s need %2d from %2d node(s) | nearest %4.0f m | furthest needed %4.0f m | %d placed"
			% [item_id, required, nodes_needed, distances[0], reach, distances.size()])
		if reach > worst_distance:
			worst_distance = reach
			worst_item = item_id

	for other_seed: int in _fingerprints:
		check(spawn.distance_to(_fingerprints[other_seed] as Vector3) > 1.0,
			"seed %d generated a different island from seed %d" % [seed_value, other_seed])
	_fingerprints[seed_value] = spawn

	check(worst_distance <= TOLERABLE_M,
		"seed %d: the whole opening is within %.0f m (worst: %s at %.0f m)"
			% [seed_value, TOLERABLE_M, worst_item, worst_distance])
	if worst_distance > COMFORTABLE_M:
		print("  NOTE  seed %d opens with a %.0f m walk — past the %.0f m comfortable mark"
			% [seed_value, worst_distance, COMFORTABLE_M])
	world.queue_free()
	stand_in.queue_free()
	await process_frame


## What the workbench and the first axe cost, read out of their own content files.
func _opening_cost(registry: Node) -> Dictionary:
	var needed: Dictionary = {}
	var bench: Resource = registry.call("get_buildable", &"workbench")
	if bench != null:
		for item_id: StringName in (bench.get(&"cost") as Dictionary):
			needed[item_id] = int(needed.get(item_id, 0)) + int((bench.get(&"cost") as Dictionary)[item_id])
	var axe: Resource = registry.call("get_recipe", &"wooden_axe")
	if axe != null:
		for ingredient: Resource in (axe.get(&"inputs") as Array):
			if ingredient == null or ingredient.get(&"item") == null:
				continue
			var item_id: StringName = (ingredient.get(&"item") as Resource).get(&"id")
			needed[item_id] = int(needed.get(item_id, 0)) + int(ingredient.get(&"count"))
	return needed


## Every bare-hand harvestable, as `{def_id: {item, per_node}}`.
##
## Read off `HarvestLibrary.definition_paths()` rather than a Registry accessor: harvestables are
## per-instance content and the registry does not index them by yield. This is the same list the
## game itself resolves a placed asset through, so the check cannot disagree with the world.
func _bare_hand_sources(_registry: Node) -> Dictionary:
	var sources: Dictionary = {}
	for path: String in HarvestLibrary.definition_paths():
		var def: Resource = load(path)
		if def == null or int(def.get(&"required_tool")) != 0:
			continue
		var item_id := StringName(def.get(&"yield_item_id"))
		if item_id == &"":
			continue
		sources[StringName(def.get(&"id"))] = {
			"item": item_id, "per_node": maxi(int(def.get(&"yield_amount")), 1),
		}
	return sources


## Distances from `spawn` to every placed bare-hand source of `item_id`, nearest first.
##
## Reads the `placements` meta where a batched group has one — a MultiMesh holder is ONE node
## standing for many instances, so counting nodes would undercount the world by an order of
## magnitude (the trap wick1c650c hit measuring colliders: `get_instance_transform()` reads back as
## identity under headless, and the meta is the reliable source).
func _distances_to(item_id: StringName, spawn: Vector3, sources: Dictionary) -> Array[float]:
	var distances: Array[float] = []
	for holder: Node in get_nodes_in_group(HARVESTABLE_HOLDER_GROUP):
		var node := holder as Node3D
		if node == null:
			continue
		var asset := StringName(node.get_meta(&"asset", &""))
		var def_path: String = HarvestLibrary.definition_path_for(asset)
		if def_path.is_empty():
			continue
		var def_id := StringName(def_path.get_file().get_basename())
		var source: Dictionary = sources.get(def_id, {})
		if source.is_empty() or StringName(source["item"]) != item_id:
			continue
		if node.has_meta(&"placements"):
			for origin: Vector3 in (node.get_meta(&"placements") as Array):
				distances.append((node.global_position + origin).distance_to(spawn))
		else:
			distances.append(node.global_position.distance_to(spawn))
	distances.sort()
	return distances


func check(ok: bool, label: String) -> void:
	if ok:
		print("  ok   %s" % label)
	else:
		failures += 1
		print("  FAIL %s" % label)


func _finish() -> void:
	print("\nFIRST_MINUTES_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)
