extends SceneTree

## Real-level integration proof for F-029: load playtest_hollow, let HarvestWorld discover its
## generated holders, then exercise one of the actual wired A-001 props through depletion/respawn.

const SCENE_PATH: String = "res://levels/playtest_hollow.tscn"
const EXPECTED_ACTIVE: Dictionary[StringName, int] = {
	&"harvest_tree_intact": 5,
	&"stone_node_intact": 4,
	&"iron_node_intact": 2,
}

var failures: int = 0
var yield_events: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed := load(SCENE_PATH) as PackedScene
	check(packed != null, "playtest_hollow loads")
	if packed == null:
		finish()
		return
	var scene := packed.instantiate() as Node3D
	root.add_child(scene)
	current_scene = scene
	for _frame: int in 12:
		await process_frame
	await physics_frame

	var registry: Node = root.get_node_or_null(^"Registry")
	var harvest_world: Node = root.get_node_or_null(^"HarvestWorld")
	var inventory: Node = root.get_node_or_null(^"InventoryService")
	check(registry != null, "Registry autoload exists")
	check(harvest_world != null, "HarvestWorld autoload exists")
	check(inventory != null, "InventoryService autoload exists")
	for item_id: StringName in [&"log", &"stone", &"iron_ore"]:
		check(bool(registry.call("has_item", item_id)), "Registry loaded item '%s'" % item_id)
	if harvest_world == null:
		finish()
		return

	# F-114 made harvestability a property of the ASSET, so this map's pines, boulders and bushes
	# are live too and the total is no longer a fixed 11. What is still exactly 11 — and is what
	# this check was written to protect — is the multi-state A-001 set: those are the only props
	# that swap geometry as they take damage, hand their collider to the Harvestable, and hide an
	# authored duplicate. Every family added since keeps the world builder's own mesh instead.
	var harvestables: Array = harvest_world.call("wired_harvestables")
	check(harvestables.size() >= 11,
		"the A-001 props are still live among %d harvestables" % harvestables.size())
	var counts: Dictionary[StringName, int] = {}
	var state_scene_props: int = 0
	for value: Variant in harvestables:
		var harvestable := value as Node3D
		var asset := StringName(String(harvestable.get_meta(&"asset", "")))
		counts[asset] = counts.get(asset, 0) + 1
		check(harvestable.get_node_or_null(^"HarvestSync") != null,
			"%s has host replication" % harvestable.get_path())
		var definition: Resource = harvestable.get("definition")
		if definition == null or bool(definition.call("uses_authored_visual")):
			# Drawn by the world builder: no instantiated state visual is the CORRECT answer, and a
			# collider is optional because soft flora has none and is targeted by arc, not by ray.
			check(harvestable.get_node_or_null(^"HarvestVisual") == null,
				"%s draws the world's own mesh, not a state scene" % harvestable.get_path())
			continue
		state_scene_props += 1
		check(harvestable.get_node_or_null(^"CollisionBody") != null,
			"%s owns its existing collision" % harvestable.get_path())
		check(harvestable.get_node_or_null(^"HarvestVisual") != null,
			"%s has a live state visual" % harvestable.get_path())
	for asset_id: StringName in EXPECTED_ACTIVE:
		check(counts.get(asset_id, 0) == EXPECTED_ACTIVE[asset_id],
			"%s wired %d time(s)" % [asset_id, counts.get(asset_id, 0)])
	check(state_scene_props == 11, "exactly 11 multi-state A-001 props are live (%d)" % state_scene_props)

	var hidden_originals: int = 0
	for candidate: Node in scene.find_children("*", "Node3D", true, false):
		if candidate.has_meta(&"mire_harvestable_original_visual"):
			hidden_originals += 1
			check(not (candidate as Node3D).visible, "%s authored duplicate is hidden" % candidate.name)
	check(hidden_originals == state_scene_props,
		"every authored duplicate hidden is a state-scene prop (%d)" % hidden_originals)

	# The families F-114 added must actually be reachable on a real map, not just in principle.
	var authored_visual_props: int = harvestables.size() - state_scene_props
	check(authored_visual_props > 0,
		"asset-keyed families wired on this map (%d)" % authored_visual_props)

	var event_bus: GDScript = load("res://core/events/event_bus.gd") as GDScript
	event_bus.subscribe_harvest_yielded(_on_yield)
	var tree: Node3D = _first_asset(harvestables, &"harvest_tree_intact")
	check(tree != null, "an actual map tree is available for lifecycle proof")
	if tree != null:
		# Delta, not absolute (F-047): DevLoadout grants 20 logs at spawn, so asserting a total of 3
		# is asserting the starting kit doesn't exist — the fifth harness that autoload broke.
		var logs_before: int = int(inventory.call("local_count", &"log")) if inventory != null else 0
		var definition: Resource = tree.get("definition")
		check(bool(tree.call("host_apply_damage", int(definition.get("max_health")), 1)),
			"actual map tree accepts lethal host damage")
		await physics_frame
		check(not bool(tree.get("active")), "actual map tree depletes")
		check(yield_events.size() == 1, "actual map tree emits one yield")
		if yield_events.size() == 1:
			check(yield_events[0].get("item_id") == &"log", "actual tree yields log")
			check(int(yield_events[0].get("amount", 0)) == 3, "actual tree yields three logs")
		if inventory != null:
			check(int(inventory.call("local_count", &"log")) - logs_before == 3,
				"actual map harvest grants three more logs to offline inventory (started at %d)"
				% logs_before)
		var body := tree.get_node_or_null(^"CollisionBody") as CollisionObject3D
		check(body != null and body.collision_layer == 0, "depleted map collision is disabled")
		check(bool(tree.call("host_respawn")), "actual map tree respawns")
		await physics_frame
		check(bool(tree.get("active")), "actual map tree is active after respawn")
		check(body != null and body.collision_layer != 0, "respawn restores map collision")
		check(harvest_world.call("request_harvest_from_collider", body),
			"attack adapter resolves the map collider to its Harvestable")
		await create_timer(0.3).timeout
		var health_before_ray: int = int(tree.get("health"))
		var camera := Camera3D.new()
		camera.name = "HarvestCheckCamera"
		scene.add_child(camera)
		camera.global_position = tree.global_position + Vector3(0.0, 1.5, 3.0)
		camera.look_at(tree.global_position + Vector3(0.0, 1.5, 0.0))
		camera.make_current()
		await physics_frame
		check(bool(harvest_world.call("try_harvest_from_camera")),
			"4 m first-person ray targets the actual map tree")
		check(int(tree.get("health")) == health_before_ray - 1,
			"first-person ray submits one definition-authored hit")
	event_bus.unsubscribe_harvest_yielded(_on_yield)

	print("HARVEST_WORLD_CHECK live=%d hidden=%d events=%d failures=%d" % [
		harvestables.size(), hidden_originals, yield_events.size(), failures
	])
	finish()


func _first_asset(harvestables: Array, asset_id: StringName) -> Node3D:
	for value: Variant in harvestables:
		var harvestable := value as Node3D
		if StringName(String(harvestable.get_meta(&"asset", ""))) == asset_id:
			return harvestable
	return null


func _on_yield(
	harvestable_id: StringName,
	peer_id: int,
	item_id: StringName,
	amount: int,
	world_position: Vector3
) -> void:
	yield_events.append({
		"harvestable_id": harvestable_id,
		"peer_id": peer_id,
		"item_id": item_id,
		"amount": amount,
		"world_position": world_position,
	})


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
