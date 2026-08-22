extends SceneTree

## Scratch visual probe for F-162: grants the three food items (mushroom, berry, raw_meat) to the
## host peer, selects each into the hotbar in turn, and screenshots the held viewmodel so the reused
## pickup-mesh grip transforms (content/items/{mushroom,berry,raw_meat}.tres) can be judged by eye —
## same purpose as tools/viewmodel_check.gd's own screenshots, just aimed at items the dev loadout
## does not carry. Throwaway, like tools/_probe_lods.gd and tools/_probe_merge.gd.
##
##   Godot --windowed --path . --script tools/_probe_food_grip.gd

## The MAP, not `run/main_scene` (F-564). Since MENU-3's cutover the main scene is the front
## end, so loading that setting and treating the result as a level boots a menu. `ProbeScene`
## asks the front end what world it bypasses into (F-561).
const ProbeScene := preload("res://tools/probe_scene.gd")


const ITEMS: Array[StringName] = [&"sling"]

var viewmodel: Node3D


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1280, 720)
	var packed: PackedScene = load(ProbeScene.shipped_map_path()) as PackedScene
	var level: Node = packed.instantiate()
	root.add_child(level)
	root.get_tree().current_scene = level
	await process_frame
	await process_frame
	await _until(func() -> bool: return not root.get_tree().get_nodes_in_group(&"players").is_empty(), 8.0)
	var player: Node3D = null
	for node: Node in root.get_tree().get_nodes_in_group(&"players"):
		player = node as Node3D
		break
	if player == null:
		print("FAIL: no player")
		quit(1)
		return
	viewmodel = player.get_node_or_null(^"CameraPivot/Camera3D/Viewmodel") as Node3D
	await _until(func() -> bool: return StringName(viewmodel.call("held_item_id")) != &"", 8.0)

	# Dismiss the attunement-pick modal (D-070/D-071) so it stops occluding the viewmodel in frame.
	var attunement: Node = root.get_node_or_null(^"AttunementService")
	if attunement != null:
		attunement.call("request_select", &"forager")
		await process_frame
		await process_frame

	var inventory: Node = root.get_node_or_null(^"InventoryService")
	var ui: Node = root.get_node_or_null(^"InventoryUI")
	var hotbar_start: int = int(inventory.call("hotbar_start_index"))
	var previous: StringName = &""
	for item_id: StringName in ITEMS:
		# Clear the last one out first: leaving it in hotbar slot 0 means the move below has nowhere
		# to land and every screenshot after the first shows the same tool.
		if previous != &"":
			inventory.call("host_remove", 1, previous, 1)
			await process_frame
		previous = item_id
		inventory.call("host_add", 1, item_id, 1)
		var slots: Array = inventory.call("host_slots", 1)
		var source: int = -1
		for index: int in mini(hotbar_start, slots.size()):
			if StringName(String((slots[index] as Dictionary).get("item_id", ""))) == item_id:
				source = index
				break
		if source >= 0:
			inventory.call("host_move_stack", 1, source, hotbar_start, 0)
		ui.call("select_hotbar_slot", 0)
		await process_frame
		await process_frame
		await process_frame
		print("%s -> held %s" % [item_id, viewmodel.call("held_item_id")])
		var current: Node3D = viewmodel.call("current_instance") as Node3D
		if current != null:
			print("  instance global_pos=%s local_pos=%s scale=%s" % [
				current.global_position, current.position, current.scale
			])
		await _shoot("/private/tmp/claude-501/-Users-sequoyahgeber-Desktop-MIRE/cb3fcf45-50ae-4641-9de5-eba004768381/scratchpad/grip_%s.png" % item_id)

	quit()


func _shoot(path: String) -> void:
	await process_frame
	await process_frame
	var texture: ViewportTexture = root.get_texture()
	var image: Image = texture.get_image() if texture != null else null
	if image == null:
		print("RENDER skipped — no frame to save")
		return
	image.save_png(path)
	print("saved %s" % path)


func _until(predicate: Callable, timeout_seconds: float) -> bool:
	var deadline: int = Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(predicate.call()):
			return true
		await process_frame
	return bool(predicate.call())
