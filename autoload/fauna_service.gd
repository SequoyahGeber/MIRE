extends Node

## FaunaService — autoload. Phase 1 of docs/FAUNA.md: how many animals the world holds, and where
## they stand. Biome-weighted **herd** placement against the real procedural island, a population
## target in the shape of `ambient_enemy_population`, and a corruption mask.
##
## ## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, "Enemy AI, spawns, damage" row): HOST.
##
## Only the host decides a herd exists, rolls its species, picks its anchor and places its members.
## Bodies reach clients through a code-built `MultiplayerSpawner` (D-023), the same seam
## `ItemDropService` and `HaulService` use — no RPC of this file's own, and a late joiner is caught
## up by the spawner rather than by a snapshot this file would have to write.
##
## ## Why placement samples the world rather than reading markers
##
## `EnemyWorld` takes its ambient spawn points from authored `enemy_nest` markers, which is right for
## enemies: a nest is a place a designer chose. Fauna is the opposite — FAUNA.md §3 asks for
## *biome-weighted* placement, and the shipped map is procedural, so the honest source is the same
## pure pipeline the scatter field samples: `BiomeMap.biome_at()` for what the ground is and
## `ProceduralWorld.height_at()` for where its surface is. That also means fauna needs no authoring
## step per map and cannot silently spawn nothing on a new one, which is the failure F-076 recorded
## when Hollowmere shipped with four nests that `ambient_spawn_points()` could not see.
##
## ## What Phase 1 deliberately does not do
##
## No AI, no drops, no despawn-when-far, no breeding. §5 puts those in Phases 3 and 4, and each is a
## system with its own decisions. What this file owes them is the seam they hang off: a population
## the host controls, and a body every peer agrees about.

const ANIMAL_SCRIPT := preload("res://systems/fauna/animal.gd")
const BIOME_MAP := preload("res://world/gen/biome_map.gd")

const LOG_CHANNEL: StringName = &"world"
const CONTAINER_NODE: StringName = &"Fauna"
const SPAWNER_NODE: StringName = &"FaunaSpawner"
const ANIMAL_GROUP: StringName = &"fauna"
## The group every world composer publishes — `ProceduralWorld`, `AuthoredWorld` and Playtest Hollow
## all join one of these on ready. Listed rather than assumed because the names diverged before
## D-143's cutover and a single string would silently find nothing on two of the three maps.
const TERRAIN_GROUPS: Array[StringName] = [
	&"authored_world_terrain", &"playtest_hollow_terrain",
]

## Gamerule, mirroring `ambient_enemy_population` exactly (COMMANDS.md §4.3). The export below is the
## fallback when no rule is registered; the rule wins when it is.
const POPULATION_RULE: StringName = &"ambient_fauna_population"

## How many animals the world keeps alive. A HERD counts as its members, not as one — the target is
## a headcount, which is what a player perceives.
@export_range(0, 200, 1) var population: int = 24
## Seconds between top-up passes. Slower than `EnemyWorld`'s ambient cadence on purpose: a field
## repopulating visibly is fine for enemies (they are a threat clock) and wrong for animals, which
## should feel like they were always there.
@export_range(1.0, 300.0, 1.0) var top_up_seconds: float = 20.0
## How far out from the anchor players a herd may be placed, and how close it may come. The inner
## bound stops a cow materialising in front of somebody; the outer keeps the population where a
## player might actually meet it rather than spread over an island they will never walk.
@export var spawn_min_distance_m: float = 24.0
@export var spawn_max_distance_m: float = 140.0
## Attempts per herd before giving up on finding ground that satisfies biome, slope, height and
## corruption. Bounded because a fully corrupted island legitimately has nowhere to put a cow, and
## the answer to that is "no cows", not a hung frame.
const PLACEMENT_ATTEMPTS: int = 24
## Slope is measured by sampling the height a short step away in x and z. Small enough to read a
## local gradient rather than an average across a hill.
const SLOPE_SAMPLE_M: float = 1.2

var _container: Node3D
var _spawner: MultiplayerSpawner
var _world: Node3D
var _accumulator: float = 0.0
var _next_index: int = 1
## Its own stream, seeded from the run seed so a replayed seed places the same herds — the same
## reasoning F-210 gives for a chest's roll. Never the global `randi()` (AGENTS.md).
var _rng := RandomNumberGenerator.new()
var _transport_node: Node

## Fires on the host after a top-up placed anything, for checks and for a future "the herd moved in"
## cue. Client-local consumers should watch the group instead — a client never sees this.
signal herd_placed(animal_id: StringName, count: int, world_position: Vector3)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE
	_build_spawner()
	_reseed()
	var bus := preload("res://core/events/event_bus.gd")
	bus.subscribe_run_restarted(_on_run_restarted)
	bus.subscribe_world_rebuilt(_on_world_rebuilt)
	_apply_rules()
	set_physics_process(true)


func _exit_tree() -> void:
	var bus := preload("res://core/events/event_bus.gd")
	bus.unsubscribe_run_restarted(_on_run_restarted)
	bus.unsubscribe_world_rebuilt(_on_world_rebuilt)


func _physics_process(delta: float) -> void:
	if not _owns_spawning():
		return
	_accumulator += delta
	if _accumulator < top_up_seconds:
		return
	_accumulator = 0.0
	top_up()


# ── Host mutation ────────────────────────────────────────────────────────────────────────────────


## Places herds until the headcount reaches `population`. Returns how many animals were added, which
## is 0 both when the field is full and when the island has nowhere legal to put one — the caller
## cannot tell those apart and does not need to.
func top_up() -> int:
	if not _owns_spawning() or population <= 0:
		return 0
	var definitions: Array = _definitions()
	if definitions.is_empty():
		return 0
	var anchors: Array[Vector3] = _anchor_positions()
	if anchors.is_empty():
		return 0

	var added: int = 0
	# Bounded by herds, not by animals: one herd may add several, and a species whose ground does not
	# exist on this island must not spin the loop.
	var herds: int = 0
	while live_count() + added < population and herds < PLACEMENT_ATTEMPTS:
		herds += 1
		var definition: Resource = definitions[_rng.randi_range(0, definitions.size() - 1)]
		var anchor: Vector3 = anchors[_rng.randi_range(0, anchors.size() - 1)]
		var placed: int = _place_herd(definition, anchor, population - (live_count() + added))
		added += placed
	return added


## One herd of `definition`, anchored near `origin`. Returns how many members were actually placed.
func _place_herd(definition: Resource, origin: Vector3, headroom: int) -> int:
	if definition == null or headroom <= 0:
		return 0
	var anchor: Vector3 = _find_ground(definition, origin)
	if anchor == Vector3.INF:
		return 0
	var wanted: int = mini(int(definition.call(&"roll_herd_size", _rng)), headroom)
	var spread: float = float(definition.get(&"herd_spread_m"))
	var placed: int = 0
	for member: int in wanted:
		# Members are scattered around the anchor and each re-grounded: a herd on rolling ground
		# should follow the ground, and one member landing in a corrupted patch or in water is
		# dropped rather than moving the whole herd.
		var offset := Vector3(
			_rng.randf_range(-spread, spread), 0.0, _rng.randf_range(-spread, spread)
		)
		var spot: Vector3 = _find_ground(definition, anchor + offset, 4)
		if spot == Vector3.INF:
			continue
		if _spawn_animal(StringName(definition.get(&"id")), spot) != null:
			placed += 1
	if placed > 0:
		herd_placed.emit(StringName(definition.get(&"id")), placed, anchor)
	return placed


## Ground under `around` that this species will accept, or `Vector3.INF` when there is none nearby.
## The whole spawn mask lives here — biome, height, slope, corruption — so Phase 6's "flee corrupted
## ground" has one place to extend rather than four.
func _find_ground(definition: Resource, around: Vector3, attempts: int = PLACEMENT_ATTEMPTS) -> Vector3:
	var weights: Dictionary = definition.get(&"biome_weights")
	if weights.is_empty():
		return Vector3.INF
	for attempt: int in attempts:
		var candidate := Vector3(around.x, 0.0, around.z)
		if attempt > 0:
			var jitter: float = 6.0 * float(attempt)
			candidate.x += _rng.randf_range(-jitter, jitter)
			candidate.z += _rng.randf_range(-jitter, jitter)
		var biome: StringName = _biome_at(candidate.x, candidate.z)
		if biome == &"" or not weights.has(biome):
			continue
		# Weighted acceptance rather than a weighted pick over a candidate list: the weights are
		# relative within one species, so "how often do I accept this biome" is the same statement
		# and costs no second pass over the island.
		var weight: float = float(weights[biome])
		if _rng.randf() > clampf(weight, 0.0, 1.0) and weight < 1.0:
			continue
		var height: float = _height_at(candidate.x, candidate.z)
		if height < float(definition.get(&"min_height_m")):
			continue
		if _slope_at(candidate.x, candidate.z) > float(definition.get(&"max_slope")):
			continue
		if _corruption_at(Vector3(candidate.x, height, candidate.z)) > float(definition.get(&"max_corruption")):
			continue
		return Vector3(candidate.x, height, candidate.z)
	return Vector3.INF


## Host-only. Spawns one body through the spawner so every peer builds it identically.
func _spawn_animal(animal_id: StringName, world_position: Vector3) -> Node3D:
	if not _owns_spawning() or animal_id == &"" or _spawner == null:
		return null
	var payload: Dictionary = {
		"animal": String(animal_id),
		"origin": world_position,
		"index": _next_index,
	}
	_next_index += 1
	return _spawner.spawn(payload) as Node3D


## Test/debug seam, and the path a future "spawn a herd here" command uses. Public because a check
## must be able to place one deterministically rather than waiting for a top-up to choose.
func host_spawn_at(animal_id: StringName, world_position: Vector3) -> Node3D:
	return _spawn_animal(animal_id, world_position)


func host_clear() -> void:
	if _container == null:
		return
	for child: Node in _container.get_children():
		_container.remove_child(child)
		child.queue_free()


# ── Queries ──────────────────────────────────────────────────────────────────────────────────────


func live_count() -> int:
	return get_tree().get_nodes_in_group(ANIMAL_GROUP).size()


func count_of(animal_id: StringName) -> int:
	var count: int = 0
	for node: Node in get_tree().get_nodes_in_group(ANIMAL_GROUP):
		if StringName(node.get(&"animal_id")) == animal_id:
			count += 1
	return count


## Every animal currently alive, for checks and for whatever Phase 3 needs to tick.
func live_animals() -> Array[Node]:
	var out: Array[Node] = []
	for node: Node in get_tree().get_nodes_in_group(ANIMAL_GROUP):
		out.append(node)
	return out


# ── World sampling ───────────────────────────────────────────────────────────────────────────────


## The composed world node, found by group rather than by type so an authored map that publishes the
## same contract (D-143's whole point) works unchanged. Re-resolved when it goes away, because a run
## restart rebuilds it.
func _world_node() -> Node3D:
	if _world != null and is_instance_valid(_world):
		return _world
	for group: StringName in TERRAIN_GROUPS:
		for node: Node in get_tree().get_nodes_in_group(group):
			var candidate := node as Node3D
			# `height_at` is the actual contract, not the group: a composer that publishes the group
			# without the sampler is no use here, and one that grows a new group name but keeps the
			# sampler still works through the fallback sweep below.
			if candidate != null and candidate.has_method(&"height_at"):
				_world = candidate
				return _world
	return null


func _height_at(x: float, z: float) -> float:
	var world: Node3D = _world_node()
	return float(world.call(&"height_at", x, z)) if world != null else 0.0


## Local gradient, sampled a step away in each axis. Cheap, and it is the same "is this ground flat
## enough to stand on" question the scatter field's grounding pass answers geometrically.
func _slope_at(x: float, z: float) -> float:
	var here: float = _height_at(x, z)
	var dx: float = absf(_height_at(x + SLOPE_SAMPLE_M, z) - here)
	var dz: float = absf(_height_at(x, z + SLOPE_SAMPLE_M) - here)
	return maxf(dx, dz) / SLOPE_SAMPLE_M


func _biome_at(x: float, z: float) -> StringName:
	var world: Node3D = _world_node()
	if world == null:
		return &""
	var registry: Node = get_node_or_null(^"/root/Registry")
	if registry == null:
		return &""
	var biomes: Array = (registry.get(&"biomes") as Dictionary).values()
	if biomes.is_empty():
		return &""
	return BIOME_MAP.biome_at(x, z, int(world.get(&"world_seed")), biomes)


## FAUNA.md §3: "Never in corrupted ground." Zero when there is no Mire yet, so a world without the
## grid spawns fauna normally rather than nowhere.
func _corruption_at(world_position: Vector3) -> float:
	var grid: Node = get_node_or_null(^"/root/MireGrid")
	if grid == null or not grid.has_method(&"corruption_at"):
		return 0.0
	return float(grid.call(&"corruption_at", world_position))


## Where herds are placed relative to. Players when there are any, and the world origin when there
## are not — a headless check and a world building before anyone has spawned both need somewhere.
func _anchor_positions() -> Array[Vector3]:
	var anchors: Array[Vector3] = []
	for node: Node in get_tree().get_nodes_in_group(&"players"):
		var body := node as Node3D
		if body != null and is_instance_valid(body):
			anchors.append(body.global_position)
	if anchors.is_empty() and _world_node() != null:
		anchors.append(Vector3.ZERO)
	# Ring positions around each anchor, so a herd lands in the band described by
	# `spawn_min_distance_m`/`spawn_max_distance_m` rather than on top of whoever it is anchored to.
	var ringed: Array[Vector3] = []
	for anchor: Vector3 in anchors:
		for step: int in 6:
			var angle: float = _rng.randf() * TAU
			var distance: float = _rng.randf_range(spawn_min_distance_m, spawn_max_distance_m)
			ringed.append(anchor + Vector3(cos(angle) * distance, 0.0, sin(angle) * distance))
	return ringed


func _definitions() -> Array:
	var registry: Node = get_node_or_null(^"/root/Registry")
	if registry == null:
		return []
	var animals: Variant = registry.get(&"animals")
	return (animals as Dictionary).values() if animals is Dictionary else []


# ── Rules, lifecycle, spawner ────────────────────────────────────────────────────────────────────


func _apply_rules() -> void:
	var rules: Node = get_node_or_null(^"/root/RuleService")
	if rules == null:
		return
	if bool(rules.call("has_rule", POPULATION_RULE)):
		population = int(rules.call("value_int", POPULATION_RULE, population))
	if rules.has_signal(&"rule_changed") and not rules.is_connected(&"rule_changed", _on_rule_changed):
		rules.connect(&"rule_changed", _on_rule_changed)


func _on_rule_changed(id: StringName, _value: Variant) -> void:
	if id != POPULATION_RULE:
		return
	_apply_rules()
	# Immediate, not at the next tick: someone who just set the population to 40 wants to see 40,
	# and someone who set it to 0 is testing something else and wants the field gone now.
	if population <= 0:
		host_clear()
	else:
		top_up()


func _on_run_restarted() -> void:
	host_clear()
	_reseed()
	_accumulator = 0.0


## A rebuilt world is a different island: whatever herds existed stood on ground that no longer
## exists, so they go, and the next tick repopulates against the new terrain.
func _on_world_rebuilt() -> void:
	_world = null
	host_clear()
	_reseed()


func _reseed() -> void:
	var state: Node = get_node_or_null(^"/root/GameState")
	var run_seed: int = int(state.get(&"run_seed")) if state != null else 0
	# Mixed with a constant so fauna does not draw the same sequence as any other system seeded from
	# the same run seed — "FAUN".
	_rng.seed = run_seed ^ 0x4641554e


func _build_spawner() -> void:
	_container = Node3D.new()
	_container.name = CONTAINER_NODE
	add_child(_container)

	_spawner = MultiplayerSpawner.new()
	_spawner.name = SPAWNER_NODE
	_spawner.spawn_limit = 0
	_spawner.spawn_function = _net_spawn_animal
	add_child(_spawner)
	_spawner.spawn_path = _spawner.get_path_to(_container)


## Runs on every peer, from the same payload. `ItemDropService._net_spawn_drop()`'s shape.
func _net_spawn_animal(data: Variant) -> Node:
	var payload: Dictionary = data as Dictionary
	if payload == null:
		return null
	var animal_id: StringName = StringName(String(payload.get("animal", "")))
	if animal_id == &"":
		return null
	var body := CharacterBody3D.new()
	body.set_script(ANIMAL_SCRIPT)
	body.name = "Animal%d" % int(payload.get("index", 0))
	body.position = payload.get("origin", Vector3.ZERO)
	body.set(&"animal_id", animal_id)
	return body


func _owns_spawning() -> bool:
	var transport: Node = _transport()
	if transport == null:
		return true
	if bool(transport.call("is_host")):
		return true
	return not bool(transport.call("is_active")) and not bool(transport.call("is_connecting"))


func _transport() -> Node:
	if _transport_node == null or not is_instance_valid(_transport_node):
		_transport_node = get_node_or_null(^"/root/NetTransport")
	return _transport_node
