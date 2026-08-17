extends SceneTree

## Proves F-041 is actually fixed, and renders the swing so the grip values can be judged by eye.
##
## Runs against the REAL main scene with the real player, because the bug was that nothing connected
## "slot 1 is selected" to "a mesh is on screen" — every part in isolation already worked.
##
##   Godot --path . --script tools/viewmodel_check.gd

var failures: int = 0
var level: Node
var viewmodel: Node3D
## By path, never as the bare identifier (F-011) — a --script main loop compiles before autoloads
## are registered, which is the rule this file's own subject matter went and tripped over.
var combat: Node


func _initialize() -> void:
	# The held-item assertions need the starting kit; opt in past F-052's harness gate.
	OS.set_environment("MIRE_DEV_LOADOUT", "1")
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1280, 720)
	var packed: PackedScene = load(
		str(ProjectSettings.get_setting("application/run/main_scene", ""))
	) as PackedScene
	if packed == null:
		push_error("FAIL: no main scene")
		quit(1)
		return
	level = packed.instantiate()
	root.add_child(level)
	root.get_tree().current_scene = level
	await process_frame
	await process_frame

	# Poll rather than assert once: the level's Player joins the group in its own _ready, which is not
	# guaranteed to have run two frames after add_child on a scene this size.
	await _until(func() -> bool: return not root.get_tree().get_nodes_in_group(&"players").is_empty(), 8.0)
	var player: Node3D = null
	for node: Node in root.get_tree().get_nodes_in_group(&"players"):
		player = node as Node3D
		break
	check(player != null, "the level has a player")
	if player == null:
		finish()
		return

	combat = root.get_node_or_null(^"CombatService")
	check(combat != null, "CombatService is registered")
	viewmodel = player.get_node_or_null(^"CameraPivot/Camera3D/Viewmodel") as Node3D
	check(viewmodel != null, "the owning player built a viewmodel under its camera")
	if viewmodel == null:
		finish()
		return

	# Wait for the loadout, which lands a frame or two after the level does.
	var armed: bool = await _until(
		func() -> bool: return StringName(viewmodel.call("held_item_id")) != &"", 8.0
	)
	check(armed, "the selected hotbar slot resolves to a held item (%s)"
		% String(viewmodel.call("held_item_id")))
	await process_frame
	check(viewmodel.call("current_instance") != null,
		"and that item's viewmodel mesh is instantiated on screen")

	var registry: Node = root.get_node_or_null(^"Registry")
	var missing: PackedStringArray = PackedStringArray()
	for id: StringName in (registry.get("items") as Dictionary):
		var item: ItemDef = registry.call("get_item", id)
		# Resources are carried, not held — no viewmodel is the right answer for a log.
		if item.category != ItemDef.Category.RESOURCE and item.view_model == null:
			missing.append(String(id))
	check(missing.is_empty(), "every tool and weapon has a viewmodel (%s)" % ", ".join(missing))

	# Switching slots switches the mesh, which is the other half of "it renders what I'm holding".
	var ui: Node = root.get_node_or_null(^"InventoryUI")
	var first: StringName = StringName(viewmodel.call("held_item_id"))
	ui.call("select_hotbar_slot", 1)
	await process_frame
	await process_frame
	var second: StringName = StringName(viewmodel.call("held_item_id"))
	check(second != first and second != &"", "changing hotbar slot changes the held item (%s -> %s)"
		% [first, second])
	ui.call("select_hotbar_slot", 0)
	await process_frame
	await process_frame

	# ── the swing, one frame per phase ────────────────────────────────────────────────────────────
	await _shoot("/tmp/mire_viewmodel_idle.png", "idle")
	check(int(combat.call("request_attack")) > 0, "the swing starts")
	await _shoot("/tmp/mire_viewmodel_windup.png", "wind-up")
	var reached_commit: bool = await _until(
		func() -> bool: return int(combat.call("local_phase")) == 2, 3.0
	)
	check(reached_commit, "it reaches the commit")
	await _shoot("/tmp/mire_viewmodel_commit.png", "commit")
	var reached_recovery: bool = await _until(
		func() -> bool: return int(combat.call("local_phase")) == 3, 3.0
	)
	check(reached_recovery, "it reaches the recovery")
	await _shoot("/tmp/mire_viewmodel_recovery.png", "recovery")

	print("\nVIEWMODEL_CHECK failures=%d" % failures)
	finish()


func _shoot(path: String, label: String) -> void:
	await process_frame
	await process_frame
	# The dummy rasterizer in a plain --headless run has no frame to read back — get_texture()
	# hands back a ViewportTexture whose RID is dead, and merely calling get_image() on it logs an
	# engine ERROR per shot (F-046). The renders are evidence for eyes, not assertions, so detect
	# headless BEFORE touching the texture and skip loudly. Run WITHOUT --headless to capture PNGs.
	if DisplayServer.get_name() == "headless":
		print("VIEWMODEL_RENDER skipped (%s) — headless dummy renderer, no frame to save" % label)
		return
	var texture: ViewportTexture = root.get_texture()
	var image: Image = texture.get_image() if texture != null else null
	if image == null:
		print("VIEWMODEL_RENDER skipped (%s) — no frame to save" % label)
		return
	if image.save_png(path) != OK:
		push_error("FAIL: could not save %s" % path)
		failures += 1
		return
	print("VIEWMODEL_RENDER %s (%s)" % [path, label])


func _until(condition: Callable, timeout_seconds: float) -> bool:
	var deadline: int = Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await process_frame
	return bool(condition.call())


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
