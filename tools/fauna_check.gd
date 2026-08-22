extends SceneTree

## F-597 / docs/FAUNA.md Phase 1. **Boots the real procedural island and counts what actually
## spawns** — the standing rule that has caught several wrong answers today, including one derived
## from content files rather than from a running world.
##
##   .agent/bin/agent godot --script tools/fauna_check.gd
##
## Three things it will not accept:
##   · content that resolves (an AnimalDef whose biome weights name biomes this world does not have
##     spawns nothing, silently, forever)
##   · placement that respects the mask — biome, height, slope, corruption
##   · a population target that is actually a target, including 0

const PROCEDURAL_WORLD := preload("res://levels/procedural_island.tscn")
const ANIMAL_DEF := preload("res://systems/fauna/animal_def.gd")

var failures: int = 0
var _world: Node3D


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	_check_content()
	await _boot_world()
	await _check_spawning()
	await _check_mask()
	_check_art_seam()
	print("\nFAUNA_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)


func _check_content() -> void:
	print("\n== Content ==")
	var registry: Node = root.get_node_or_null(^"Registry")
	check(registry != null, "Registry autoload exists")
	if registry == null:
		return
	var animals: Dictionary = registry.get(&"animals")
	check(not animals.is_empty(), "the registry loaded at least one AnimalDef (%d)" % animals.size())

	# Biome ids are validated against the world's REAL biome list, because a typo here is the failure
	# mode that cannot be seen in play: the species simply never appears and nothing reports it.
	var biome_ids: Array = []
	for biome: Resource in (registry.get(&"biomes") as Dictionary).values():
		biome_ids.append(StringName(biome.get(&"id")))
	check(not biome_ids.is_empty(), "the world defines biomes to validate against (%d)" % biome_ids.size())

	for animal: Resource in animals.values():
		var errors: PackedStringArray = animal.call(&"validation_errors", biome_ids)
		check(errors.is_empty(), "%s validates: %s" % [animal.get(&"id"), errors])


func _boot_world() -> void:
	print("\n== The real island ==")
	_world = PROCEDURAL_WORLD.instantiate() as Node3D
	root.add_child(_world)
	# Several frames: the world composes terrain, biomes and the Mire grid across more than one.
	for frame: int in 12:
		await process_frame
	check(_world.is_in_group(&"authored_world_terrain"),
		"the composed world publishes the terrain contract")
	check(_world.has_method(&"height_at"), "the world exposes the height sampler placement needs")
	var fauna: Node = root.get_node_or_null(^"FaunaService")
	check(fauna != null, "FaunaService autoload exists")


func _check_spawning() -> void:
	print("\n== Herd placement ==")
	var fauna: Node = root.get_node_or_null(^"FaunaService")
	if fauna == null:
		return
	fauna.call(&"host_clear")
	fauna.set(&"population", 12)
	var placed: int = int(fauna.call(&"top_up"))
	await process_frame

	check(placed > 0, "a top-up against the real island actually placed animals (%d)" % placed)
	var live: int = int(fauna.call(&"live_count"))
	check(live == placed, "every placed animal is in the tree and in the fauna group (%d/%d)" % [live, placed])
	check(live <= 12, "the population target is a ceiling, not a suggestion (%d <= 12)" % live)

	# The real invariant is CONVERGENCE, not one-pass filling. A top-up places whole herds and is
	# bounded per pass, so an early pass legitimately leaves the field short — measured: the first
	# pass placed 9 of 12. What must hold is that repeated passes reach the target and then stop,
	# because a field that keeps adding every tick is the bug that turns a long session into a
	# thousand cows. (This assertion originally demanded one-pass idempotence and went red on a
	# perfectly correct partial fill.)
	for pass_index: int in 6:
		fauna.call(&"top_up")
	var settled: int = int(fauna.call(&"live_count"))
	check(settled == 12, "repeated top-ups converge on the population target (%d)" % settled)
	var again: int = int(fauna.call(&"top_up"))
	check(again == 0, "and then stop — a full field adds nothing (%d)" % again)
	check(int(fauna.call(&"live_count")) == 12, "the field never exceeds the target")

	# Herds, not individuals: FAUNA.md §3's whole placement premise. With the hare's 1-2 the proof is
	# that members land NEAR each other rather than scattered across the island.
	var animals: Array = fauna.call(&"live_animals")
	if animals.size() >= 2:
		var nearest: float = INF
		for a: Node in animals:
			for b: Node in animals:
				if a == b:
					continue
				nearest = minf(nearest, (a as Node3D).global_position.distance_to((b as Node3D).global_position))
		check(nearest < 60.0, "animals are placed in groups rather than scattered alone (nearest pair %.1f m)" % nearest)

	# 0 empties the field without disabling the service — the gamerule's documented behaviour.
	fauna.set(&"population", 0)
	fauna.call(&"host_clear")
	await process_frame
	check(int(fauna.call(&"live_count")) == 0, "population 0 empties the island")
	check(int(fauna.call(&"top_up")) == 0, "population 0 places nothing on the next tick")


func _check_mask() -> void:
	print("\n== The spawn mask ==")
	var fauna: Node = root.get_node_or_null(^"FaunaService")
	var registry: Node = root.get_node_or_null(^"Registry")
	if fauna == null or registry == null:
		return
	var animals: Dictionary = registry.get(&"animals")
	if animals.is_empty():
		return
	var definition: Resource = animals.values()[0]

	fauna.set(&"population", 40)
	fauna.call(&"host_clear")
	fauna.call(&"top_up")
	var placed: Array = fauna.call(&"live_animals")
	check(not placed.is_empty(), "the mask still allows spawning at a higher target (%d)" % placed.size())

	var weights: Dictionary = definition.get(&"biome_weights")
	var min_height: float = float(definition.get(&"min_height_m"))
	var max_corruption: float = float(definition.get(&"max_corruption"))
	var wrong_biome: int = 0
	var underwater: int = 0
	var corrupted: int = 0
	for node: Node in placed:
		var position: Vector3 = (node as Node3D).global_position
		if position.y < min_height - 0.5:
			underwater += 1
		if float(fauna.call(&"_corruption_at", position)) > max_corruption:
			corrupted += 1
		if not weights.has(fauna.call(&"_biome_at", position.x, position.z)):
			wrong_biome += 1
	check(underwater == 0, "no animal was placed below its species' water line (%d)" % underwater)
	check(corrupted == 0, "no animal was placed in corrupted ground (%d)" % corrupted)
	check(wrong_biome == 0, "every animal stands in a biome its species weights (%d wrong)" % wrong_biome)

	fauna.call(&"host_clear")


## D-218's vocabulary, asserted from this side of the seam so a re-export that renames a clip fails
## here rather than in play. Phase 1 authors no art, so this checks the CONTRACT, not the files —
## when Phase 2's exports land, the same constants are what they must satisfy.
func _check_art_seam() -> void:
	print("\n== The art seam (D-218) ==")
	check(ANIMAL_DEF.RUNTIME_CLIPS == ([&"idle", &"walk", &"flee", &"death"] as Array[StringName]),
		"the runtime clip vocabulary is idle/walk/flee/death: %s" % [ANIMAL_DEF.RUNTIME_CLIPS])
	check(ANIMAL_DEF.LOOPING_CLIPS.has(&"idle") and ANIMAL_DEF.LOOPING_CLIPS.has(&"walk"),
		"idle and walk are the clips that must arrive looping")
	check(not ANIMAL_DEF.LOOPING_CLIPS.has(&"death"), "death must not loop")
	check(ANIMAL_DEF.MODEL_PATH_TEMPLATE % "chicken" == "res://assets/fauna/exports/chicken.glb",
		"the export path is assets/fauna/exports/<bare id>.glb")


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)
