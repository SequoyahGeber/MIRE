extends SceneTree

## Rendered smoke proof for task 2.7. Places a workbench beside a stand-in player, grants exactly the
## authored recipe cost, and saves the in-range prompt plus the open panel at three widths.
##
## F-380 added the Steam Deck shot and made this the render proof for the grid: the panel used to be
## a single 560 px column of recipes that ran off the bottom of the 1280x720 shot below, with no
## scrollbar and no way to reach the rows past the fold. What these PNGs have to show now is a short,
## wide, multi-column panel that fits inside every window it is rendered in.

const PROMPT_OUTPUT_PATH: String = "/tmp/mire_crafting_prompt.png"
const OUTPUT_PATH: String = "/tmp/mire_crafting_ui.png"
const DECK_OUTPUT_PATH: String = "/tmp/mire_crafting_ui_deck.png"
const NARROW_OUTPUT_PATH: String = "/tmp/mire_crafting_ui_narrow.png"


func _initialize() -> void:
	_render.call_deferred()


func _render() -> void:
	_resize(Vector2i(1280, 720))
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
	ui.call("_apply_layout_for_width", 1280.0, 720.0)
	if not await _save(OUTPUT_PATH):
		return

	# The Steam Deck's 1280x800 — same width as the desktop shot, 80 px more height, so it is the
	# resolution where a panel that is *nearly* too tall would still pass at 720p and fail here.
	_resize(Vector2i(1280, 800))
	ui.call("_apply_layout_for_width", 1280.0, 800.0)
	if not await _save(DECK_OUTPUT_PATH):
		return

	# Grant the rest of the stone axe's cost so the narrow shot carries a READY row, not a panel of
	# nothing but MISSING MATERIALS.
	inventory.call("host_add", 1, &"stone", 2)
	_resize(Vector2i(375, 667))
	ui.call("_apply_layout_for_width", 375.0, 667.0)
	if not await _save(NARROW_OUTPUT_PATH):
		return
	print("CRAFTING_UI_RENDER columns=%d scroll_overflows=%s" % [
		int(ui.call("recipe_columns")), str(bool(ui.call("recipe_scroll_overflows")))
	])
	quit(0)


func _resize(window_size: Vector2i) -> void:
	root.content_scale_size = window_size
	root.size = window_size


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
