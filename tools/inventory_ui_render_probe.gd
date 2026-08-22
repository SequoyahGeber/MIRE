extends SceneTree

## Rendered smoke proof for task 2.5. Populates representative stable slots, opens the inventory,
## and saves a frame for visual inspection without changing authored content.
##
## A PROBE, not a check (F-562). It photographs and asserts nothing: its only non-zero exit is a
## failed PNG write, which is an I/O fault rather than a verdict about the subject. The verdict is a
## human looking at the images. It was named `_check.gd`, so `_verify_checks()` — which globs
## `tools/*_check.gd` — collected it and scored it red for never printing the `failures=N` it was
## never written to produce. Renaming it takes it out of the suite honestly, the same move F-559
## made for `enemy_facing_probe.gd` and F-555 for `f410_asset_material_probe.gd`.

const OUTPUT_PATH: String = "/tmp/mire_inventory_ui.png"
const NARROW_OUTPUT_PATH: String = "/tmp/mire_inventory_ui_narrow.png"


func _initialize() -> void:
	_render.call_deferred()


func _render() -> void:
	root.size = Vector2i(1280, 720)
	await process_frame
	await process_frame
	var inventory: Node = root.get_node(^"InventoryService")
	var ui: Node = root.get_node(^"InventoryUI")
	inventory.call("host_add", 1, &"log", 37)
	inventory.call("host_add", 1, &"stone", 18)
	inventory.call("host_add", 1, &"iron_ore", 6)
	inventory.call("host_move_stack", 1, 0, 24, 12)
	inventory.call("host_move_stack", 1, 1, 31, 5)
	inventory.call("host_move_stack", 1, 2, 29, 2)
	ui.call("select_hotbar_slot", 7)
	ui.call("set_open", true)
	await process_frame
	await process_frame
	await process_frame
	var image: Image = root.get_texture().get_image()
	var error: Error = image.save_png(OUTPUT_PATH)
	if error != OK:
		push_error("inventory UI screenshot failed: %s" % error_string(error))
		quit(1)
		return
	print("INVENTORY_UI_RENDER %s %dx%d" % [OUTPUT_PATH, image.get_width(), image.get_height()])

	root.content_scale_size = Vector2i(375, 667)
	root.size = Vector2i(375, 667)
	ui.call("_apply_layout_for_width", 375.0)
	await process_frame
	await process_frame
	await process_frame
	image = root.get_texture().get_image()
	error = image.save_png(NARROW_OUTPUT_PATH)
	if error != OK:
		push_error("narrow inventory UI screenshot failed: %s" % error_string(error))
		quit(1)
		return
	print("INVENTORY_UI_RENDER %s %dx%d" % [
		NARROW_OUTPUT_PATH, image.get_width(), image.get_height()
	])
	quit(0)
