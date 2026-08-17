extends SceneTree

## Rendered smoke proof for task 2.7. Places a workbench beside a stand-in player, grants exactly the
## authored recipe cost, and saves the in-range prompt plus the open panel at two widths.

const PROMPT_OUTPUT_PATH: String = "/tmp/mire_crafting_prompt.png"
const OUTPUT_PATH: String = "/tmp/mire_crafting_ui.png"
const NARROW_OUTPUT_PATH: String = "/tmp/mire_crafting_ui_narrow.png"


func _initialize() -> void:
	_render.call_deferred()


func _render() -> void:
	root.size = Vector2i(1280, 720)
	await process_frame
	await process_frame
	var inventory: Node = root.get_node(^"InventoryService")
	var ui: Node = root.get_node(^"CraftingUI")

	var player := Node3D.new()
	player.name = "CraftingRenderPlayer"
	player.add_to_group(&"players")
	root.add_child(player)
	var workbench := Node3D.new()
	workbench.name = "CraftingRenderWorkbench"
	workbench.position = Vector3(2.0, 0.0, 0.0)
	workbench.set_meta(&"asset", "station_workbench_primitive")
	workbench.add_to_group(&"playtest_hollow_asset")
	root.add_child(workbench)

	inventory.call("host_add", 1, &"log", 2)
	inventory.call("host_add", 1, &"stone", 1)
	ui.call("poll_station")
	if not await _save(PROMPT_OUTPUT_PATH):
		return

	ui.call("set_open", true)
	if not await _save(OUTPUT_PATH):
		return

	inventory.call("host_add", 1, &"stone", 2)
	root.content_scale_size = Vector2i(375, 667)
	root.size = Vector2i(375, 667)
	ui.call("_apply_layout_for_width", 375.0)
	if not await _save(NARROW_OUTPUT_PATH):
		return
	quit(0)


func _save(path: String) -> bool:
	await process_frame
	await process_frame
	await process_frame
	var image: Image = root.get_texture().get_image()
	var error: Error = image.save_png(path)
	if error != OK:
		push_error("crafting UI screenshot failed: %s" % error_string(error))
		quit(1)
		return false
	print("CRAFTING_UI_RENDER %s %dx%d" % [path, image.get_width(), image.get_height()])
	return true
