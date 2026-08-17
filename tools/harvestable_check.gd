extends SceneTree

## Headless lifecycle proof for task 2.3. Uses the real Registry and EventBus but builds tiny state
## scenes in memory, so the framework is verified without bulk-authoring gameplay .tres content.

const HARVESTABLE_SCRIPT := preload("res://systems/harvesting/harvestable.gd")
const HARVESTABLE_DEF_SCRIPT := preload("res://systems/harvesting/harvestable_def.gd")
const ITEM_DEF_SCRIPT := preload("res://systems/inventory/item_def.gd")
const EVENT_BUS := preload("res://core/events/event_bus.gd")

const TEST_ITEM_ID: StringName = &"check_log"

var failures: int = 0
var yield_events: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var registry: Node = root.get_node_or_null(^"Registry")
	check(registry != null, "Registry autoload exists")
	if registry == null:
		finish()
		return

	var item: Resource = ITEM_DEF_SCRIPT.new()
	item.set("id", TEST_ITEM_ID)
	registry.get("items")[TEST_ITEM_ID] = item

	var definition: Resource = HARVESTABLE_DEF_SCRIPT.new()
	definition.set("id", &"check_tree")
	definition.set("max_health", 3)
	definition.set("damage_per_hit", 1)
	definition.set("yield_item_id", TEST_ITEM_ID)
	definition.set("yield_amount", 2)
	definition.set("respawn_seconds", 0.1)
	definition.set("request_cooldown_seconds", 0.0)
	var active_scenes: Array[PackedScene] = [
		_state_scene("Intact"),
		_state_scene("DamagedA"),
		_state_scene("DamagedB"),
	]
	definition.set("active_state_scenes", active_scenes)
	definition.set("depleted_scene", _state_scene("Depleted"))

	var prop: Node3D = HARVESTABLE_SCRIPT.new() as Node3D
	prop.name = "CheckHarvestable"
	prop.set("definition", definition)
	var body := StaticBody3D.new()
	body.name = "CollisionBody"
	body.collision_layer = 1
	body.collision_mask = 1
	var shape := CollisionShape3D.new()
	shape.name = "CollisionShape"
	shape.shape = BoxShape3D.new()
	body.add_child(shape)
	prop.add_child(body)
	root.add_child(prop)
	await process_frame
	await physics_frame

	EVENT_BUS.subscribe_harvest_yielded(_on_harvest_yielded)
	check(EVENT_BUS.harvest_yielded_subscriber_count() == 1, "EventBus registers one yield listener")
	check(int(prop.get("health")) == 3, "prop starts at full health")
	check(bool(prop.get("active")), "prop starts active")
	check(_visual_source_name(prop) == "Intact", "intact visual is selected")
	check(not shape.disabled, "collision starts enabled")
	_check_replication(prop)

	prop.call("request_hit")
	check(int(prop.get("health")) == 2, "definition-authored request damage is applied")
	check(int(prop.get("visual_state")) == 1, "first hit advances visual damage state")
	check(_visual_source_name(prop) == "DamagedA", "first damaged visual is selected")
	check(yield_events.is_empty(), "non-lethal hit emits no yield")

	check(bool(prop.call("host_apply_damage", 1, 1)), "host accepts trusted combat damage")
	check(int(prop.get("health")) == 1, "trusted damage reduces health")
	check(_visual_source_name(prop) == "DamagedB", "second damaged visual is selected")
	check(not bool(prop.call("host_apply_damage", 0, 1)), "non-positive damage is rejected")

	check(bool(prop.call("host_apply_damage", 1, 1)), "lethal host damage is accepted")
	await physics_frame
	check(int(prop.get("health")) == 0, "lethal hit reaches zero health")
	check(not bool(prop.get("active")), "lethal hit logically despawns the prop")
	check(_visual_source_name(prop) == "Depleted", "depleted remnant visual is selected")
	check(shape.disabled, "depleted collision is disabled")
	check(not bool(prop.call("host_apply_damage", 1, 1)), "depleted prop rejects duplicate damage")
	check(yield_events.size() == 1, "lethal hit emits exactly one yield event")
	if yield_events.size() == 1:
		var event: Dictionary = yield_events[0]
		check(event.get("harvestable_id") == &"check_tree", "yield identifies the harvestable kind")
		check(int(event.get("peer_id", 0)) == 1, "yield identifies the receiving peer")
		check(event.get("item_id") == TEST_ITEM_ID, "yield carries the registry item id")
		check(int(event.get("amount", 0)) == 2, "yield carries the definition-authored amount")

	# The respawn clock advances on the fixed physics tick. Ten ticks comfortably exceed 0.1 s.
	for _tick: int in 10:
		await physics_frame
	await process_frame
	check(bool(prop.get("active")), "host respawn clock reactivates the prop")
	check(int(prop.get("health")) == 3, "respawn restores full health")
	check(int(prop.get("visual_state")) == 0, "respawn restores intact state")
	check(_visual_source_name(prop) == "Intact", "respawn restores intact visual")
	check(not shape.disabled, "respawn restores collision")
	check(yield_events.size() == 1, "respawn does not duplicate yield")

	EVENT_BUS.unsubscribe_harvest_yielded(_on_harvest_yielded)
	check(EVENT_BUS.harvest_yielded_subscriber_count() == 0, "EventBus listener unsubscribes cleanly")
	registry.get("items").erase(TEST_ITEM_ID)
	prop.queue_free()
	print("HARVESTABLE_CHECK events=%d failures=%d" % [yield_events.size(), failures])
	finish()


func _check_replication(prop: Node3D) -> void:
	var sync := prop.get_node_or_null(^"HarvestSync") as MultiplayerSynchronizer
	check(sync != null, "code-built HarvestSync exists")
	if sync == null:
		return
	check(sync.get_multiplayer_authority() == NetConfig.HOST_PEER_ID, "HarvestSync is host-authoritative")
	check(sync.root_path == NodePath(".."), "HarvestSync replicates its parent")
	check(sync.is_in_group(NetConfig.SYNCED_GROUP), "HarvestSync is counted by the net debug panel")
	check(
		is_equal_approx(sync.replication_interval, NetConfig.PROP_SYNC_INTERVAL_SEC),
		"HarvestSync uses the prop replication interval"
	)
	check(
		is_equal_approx(sync.delta_interval, NetConfig.PROP_DELTA_INTERVAL_SEC),
		"HarvestSync uses the prop delta interval"
	)
	var properties: Array[NodePath] = sync.replication_config.get_properties()
	check(properties == [NodePath(".:health"), NodePath(".:visual_state"), NodePath(".:active")],
		"health, visual state and active state form the replicated schema")


func _state_scene(source_name: String) -> PackedScene:
	var state_root := Node3D.new()
	state_root.name = source_name
	state_root.set_meta(&"source_name", source_name)
	var packed := PackedScene.new()
	var error: Error = packed.pack(state_root)
	check(error == OK, "%s state scene packs" % source_name)
	state_root.free()
	return packed


func _visual_source_name(prop: Node3D) -> String:
	var visual := prop.get_node_or_null(^"HarvestVisual") as Node3D
	if visual == null:
		return ""
	return String(visual.get_meta(&"source_name", ""))


func _on_harvest_yielded(
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
