extends SceneTree

## MENU-3's eye check: render the title screen so the backdrop can be judged instead of argued
## about, at both the 1080p reference and the Steam Deck's 1280×800 (docs/MENU.md §9 makes the Deck
## a first-class layout target, and a menu that only ever gets looked at on a desktop is how a 13px
## floor turns out to have been the wrong number).
##
## Takes a shot at several points along the corruption creep, because the one thing a still frame
## cannot show is that the island is being eaten — three frames along the timeline can.
##
## Needs a real framebuffer, so run it through `agent godot --windowed` (F-077 parks the window
## offscreen). Headless it still runs and still reports each frame's mean luminance, which is a
## number rather than an opinion: a backdrop that has gone black or blown out shows up in the log
## even with no display.
##
## Run with: .agent/bin/agent godot --windowed --script tools/title_render.gd

const TitleScreen := preload("res://ui/frontend/title_screen.gd")
const TitleBackdrop := preload("res://ui/frontend/backdrop.gd")
const Frontend := preload("res://ui/frontend/frontend.gd")
const ExpeditionScreen := preload("res://ui/frontend/expedition_screen.gd")

const SETTLE_FRAMES: int = 16

## Seconds of simulated creep before each shot. 0 is landfall-clean; the later two show the Mire
## arriving, which is the whole point of the backdrop.
const CREEP_SECONDS: Array = [0.0, 42.0, 150.0]

const SIZES: Array = [
	{"name": "1080p", "size": Vector2i(1920, 1080)},
	{"name": "deck", "size": Vector2i(1280, 800)},
]

var _out_dir: String = ""


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_out_dir = _resolve_out_dir()
	DirAccess.make_dir_recursive_absolute(_out_dir)

	var stack: Node = root.get_node_or_null(^"MenuStack")
	if stack != null:
		stack.call("pop_all")

	# The same suppression the real front end applies. Without it these shots show the vitals bars,
	# the hotbar and the debug overlay stacked on the title screen — which is what the first render
	# of this scene actually showed, and how that bug was found.
	Frontend.suspend_gameplay_overlays()

	for size_entry: Dictionary in SIZES:
		var size: Vector2i = size_entry["size"]
		DisplayServer.window_set_size(size)
		root.content_scale_size = size
		await process_frame

		for creep: float in CREEP_SECONDS:
			var backdrop: Node3D = TitleBackdrop.new()
			root.add_child(backdrop)
			var title: Control = TitleScreen.new()
			# Pushed through MenuStack, not parented to the root directly — the stack is what gives a
			# screen its full-rect layout, and rendering it any other way produced shots with the
			# whole lower-left menu laid out at zero height and silently missing from the frame.
			if stack != null:
				stack.call("push", title, false)
			else:
				root.add_child(title)

			# Drive the backdrop's own clock rather than waiting out real seconds.
			backdrop._process(creep)
			for _i: int in SETTLE_FRAMES:
				await process_frame

			var shot_id: String = "title_%s_creep%03d" % [String(size_entry["name"]), int(creep)]
			var path: String = "%s/%s.png" % [_out_dir, shot_id]
			var luminance: float = -1.0
			var image: Image = root.get_texture().get_image() if root.get_texture() != null else null
			if image != null:
				image.save_png(path)
				luminance = _mean_luminance(image)
			else:
				path = "(no framebuffer — run through agent godot --windowed)"

			print("TITLE_SHOT %s creep=%.0fs mire_radius=%.1f luminance=%.4f %s" % [
				shot_id, creep, float(backdrop.call("mire_radius")), luminance, path,
			])

			if stack != null:
				stack.call("pop_all")
			title.free()
			backdrop.free()
			await process_frame

	# The dock, over the same backdrop it is shown against in the real front end.
	for size_entry: Dictionary in SIZES:
		var size: Vector2i = size_entry["size"]
		DisplayServer.window_set_size(size)
		root.content_scale_size = size
		await process_frame

		var backdrop: Node3D = TitleBackdrop.new()
		root.add_child(backdrop)
		var dock: Control = ExpeditionScreen.new()
		if stack != null:
			stack.call("push", dock, false)
		else:
			root.add_child(dock)
		for _i: int in SETTLE_FRAMES:
			await process_frame

		var dock_id: String = "dock_%s" % String(size_entry["name"])
		var dock_path: String = "%s/%s.png" % [_out_dir, dock_id]
		var dock_image: Image = root.get_texture().get_image() if root.get_texture() != null else null
		if dock_image != null:
			dock_image.save_png(dock_path)
		print("DOCK_SHOT %s %s" % [dock_id, dock_path])

		if stack != null:
			stack.call("pop_all")
		dock.free()
		backdrop.free()
		await process_frame

	print("TITLE_RENDER display=%s out=%s" % [DisplayServer.get_name(), _out_dir])
	quit(0)


func _mean_luminance(image: Image) -> float:
	var total: float = 0.0
	var samples: int = 0
	var step: int = maxi(1, image.get_width() / 96)
	for y: int in range(0, image.get_height(), step):
		for x: int in range(0, image.get_width(), step):
			var pixel: Color = image.get_pixel(x, y)
			total += 0.2126 * pixel.r + 0.7152 * pixel.g + 0.0722 * pixel.b
			samples += 1
	return total / float(maxi(1, samples))


func _resolve_out_dir() -> String:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	for index: int in range(args.size()):
		if args[index] == "--outdir" and index + 1 < args.size():
			return args[index + 1]
	return ProjectSettings.globalize_path("res://assets/audit/menu")
