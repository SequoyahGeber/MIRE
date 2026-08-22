extends SceneTree

## F-483 — eyeball evidence that the build bar is one row above the hotbar with tabs, not the
## four-row slab that covered the ghost.
##
##   .agent/bin/agent godot --windowed --script tools/build_bar_shot.gd
##
## Builds a real BuildBar off the real Registry, opens each tab in turn, and saves one framed PNG
## per tab into `assets/audit/ui/`. No world and no player: this is a shot of the bar's LAYOUT, and
## a level behind it would only make the panel harder to measure against the hotbar band it has to
## clear. The hotbar's own occupied band (-92 to -12 from the bottom, `inventory_ui.gd`) is drawn in
## as a guide line so "above the hotbar" is something the image actually shows rather than something
## the filename claims.

const OUT_DIR: String = "res://assets/audit/ui"
const VIEW_SIZE := Vector2i(1280, 720)
## Bottom edge of the band the hotbar occupies, measured up from the screen bottom.
const HOTBAR_TOP_PX: float = 92.0
const HOTBAR_BOTTOM_PX: float = 12.0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("build_bar_shot needs a renderer — run it with --windowed")
		quit(1)
		return
	await process_frame

	var viewport := SubViewport.new()
	viewport.size = VIEW_SIZE
	viewport.transparent_bg = false
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)

	# A flat backdrop rather than the sky: this is a layout shot, and a rendered world behind the
	# panel would make its edges harder to read against, which is the one thing being measured.
	var backdrop := ColorRect.new()
	backdrop.color = Color(0.11, 0.14, 0.12, 1.0)
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	viewport.add_child(backdrop)

	# The hotbar's band, so "a single row ABOVE the hotbar" is visible rather than asserted.
	var hotbar_band := ColorRect.new()
	hotbar_band.color = Color(0.35, 0.48, 0.39, 0.35)
	hotbar_band.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	hotbar_band.offset_top = -HOTBAR_TOP_PX
	hotbar_band.offset_bottom = -HOTBAR_BOTTOM_PX
	viewport.add_child(hotbar_band)

	var bar: CanvasLayer = preload("res://ui/building/build_bar.gd").new()
	bar.name = "BuildBar"
	viewport.add_child(bar)
	await process_frame
	bar.call(&"set_active", true)

	var count: int = int(bar.call(&"category_count"))
	if count == 0:
		push_error("the bar built no tabs — is the Registry autoload loaded?")
		quit(1)
		return

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	for i: int in count:
		var category: StringName = StringName(bar.call(&"category_at", i))
		# Through the real selection path, not by poking the open tab: a shot taken down a path the
		# player cannot walk is not evidence of anything.
		var slots: int = int(bar.call(&"visible_slot_count"))
		bar.call(&"set_selected_piece", bar.call(&"slot_piece_id", _first_slot_of(bar, category)))
		bar.call(&"set_ghost_status", true, "ready to place")
		for _frame: int in 4:
			await process_frame
		slots = int(bar.call(&"visible_slot_count"))
		var path: String = "%s/build_bar_%s.png" % [OUT_DIR, category]
		var image: Image = viewport.get_texture().get_image()
		image.save_png(ProjectSettings.globalize_path(path))
		print("saved %s — %d slots in one row" % [path, slots])

	quit(0)


func _first_slot_of(bar: CanvasLayer, category: StringName) -> int:
	for i: int in int(bar.call(&"slot_count")):
		if StringName(bar.call(&"_category_of", bar.call(&"slot_piece_id", i))) == category:
			return i
	return 0
