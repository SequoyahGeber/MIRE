extends SceneTree

## F-542: remote player copies render the selected ItemDef.world_model while the owner keeps the
## existing camera-only first-person viewmodel.

const PLAYER_SCENE: PackedScene = preload("res://entities/player/player.tscn")

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var registry: Node = root.get_node_or_null(^"Registry")
	check(registry != null, "Registry autoload exists")
	if registry == null:
		finish()
		return
	var stone_axe: ItemDef = registry.call(&"get_item", &"stone_axe")
	check(stone_axe != null and stone_axe.world_model != null,
		"the test item has a third-person world model")
	var inventory: Node = root.get_node_or_null(^"InventoryService")
	var inventory_ui: Node = root.get_node_or_null(^"InventoryUI")
	check(inventory != null and inventory_ui != null, "inventory and hotbar selection are available")
	if inventory != null and inventory_ui != null:
		check(bool(inventory.call(&"host_add", 1, &"stone_axe", 1)),
			"the owner receives an item")
		var source_index: int = -1
		var owner_slots: Array = inventory.call(&"host_slots", 1)
		for index: int in owner_slots.size():
			if StringName(String((owner_slots[index] as Dictionary).get("item_id", ""))) == &"stone_axe":
				source_index = index
				break
		var moved: bool = source_index == 24 \
			or bool(inventory.call(&"host_move_stack", 1, source_index, 24, 0))
		check(moved,
			"the owner moves it into selected hotbar slot 1")
		inventory_ui.call(&"select_hotbar_slot", 0)
		var owner := PLAYER_SCENE.instantiate() as CharacterBody3D
		owner.name = "1"
		root.add_child(owner)
		await process_frame
		check(StringName(owner.get(&"replicated_held_item_id")) == &"stone_axe",
			"the owning player publishes its selected hotbar item")
		check(owner.call(&"remote_held_instance") == null,
			"the owner does not duplicate a third-person model into its own camera")
		owner.queue_free()

	var remote := PLAYER_SCENE.instantiate() as CharacterBody3D
	remote.name = "2"
	root.add_child(remote)
	await process_frame
	check(not bool(remote.get(&"is_local_authority")), "peer 2 is a remote presentation copy")
	check(remote.get_node_or_null(^"Viewmodel") == null,
		"a remote player never builds the first-person camera viewmodel")
	var sync: MultiplayerSynchronizer = remote.get_node_or_null(
		NodePath(NetConfig.PLAYER_SYNC_NODE)) as MultiplayerSynchronizer
	check(sync != null, "the remote player has its replication synchronizer")
	if sync != null:
		var config: SceneReplicationConfig = sync.replication_config
		check(config.get_properties().has(^".:replicated_held_item_id"),
			"held item identity rides the existing player replication stream")

	remote.set(&"replicated_held_item_id", &"stone_axe")
	await process_frame
	var shown: Node3D = remote.call(&"remote_held_instance") as Node3D
	check(shown != null, "a replicated held id creates a third-person item")
	check(shown != null and shown.name == "RemoteHeldItem", "the model is attached to the remote hand")
	check(shown != null and shown.scene_file_path == stone_axe.world_model.resource_path,
		"the visible model comes from ItemDef.world_model")

	remote.set(&"replicated_held_item_id", &"")
	await process_frame
	await process_frame
	check(remote.call(&"remote_held_instance") == null, "selecting an empty slot clears the held item")

	remote.queue_free()
	print("REMOTE_HELD_ITEM_CHECK failures=%d" % failures)
	finish()


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
