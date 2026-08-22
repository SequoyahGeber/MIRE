extends SceneTree

## Proves F-041 is actually fixed, and renders the swing so the grip values can be judged by eye.
##
## Runs against the REAL main scene with the real player, because the bug was that nothing connected
## "slot 1 is selected" to "a mesh is on screen" — every part in isolation already worked.
##
##   Godot --path . --script tools/viewmodel_check.gd

## Designs whose head runs bit-to-poll along local +X with its flat cheeks on local ±Z, so "which way
## is it turned" is a meaningful question. A skewer and an arrow are axial and a bow has no edge.
const BLADE_PLANE_ITEMS: Dictionary[StringName, bool] = {
	&"wooden_axe": true, &"stone_axe": true, &"cleaver": true,
	&"wooden_pickaxe": true, &"stone_pickaxe": true, &"iron_pickaxe": true,
	&"repair_hammer": true,
	# Tiers 3-5. Same head-along-local-+X construction as their wooden and stone siblings, so "which
	# way is it turned" is just as meaningful a question about them.
	&"iron_axe": true, &"bogsilver_axe": true, &"wellglass_axe": true,
	&"bogsilver_pickaxe": true, &"wellglass_pickaxe": true,
}
## Items whose declared style genuinely IS chop, so the "did anyone forget to set it" check does not
## fire on them. Everything else with a viewmodel must have chosen something deliberately.
const CHOP_ITEMS: Dictionary[StringName, bool] = {
	&"wooden_axe": true, &"stone_axe": true, &"cleaver": true,
	# The three forged/knapped axes the five-tier ladder added (D-200). They swing exactly like the
	# two above — CHOP is the deliberate answer for every axe in the game, and this list is how a
	# deliberate CHOP is told apart from a forgotten one.
	&"iron_axe": true, &"bogsilver_axe": true, &"wellglass_axe": true,
}
## How finely the whole swing is walked when looking for near-plane clipping.
const SWING_SAMPLES: int = 24

## |cheek · view| above this means the flat face is square enough to the camera to read as "the side
## of the axe is facing the player" (F-073). Calibrated against both ends rather than guessed: the
## grip this replaced measured 0.92 on all seven of these designs, and the solved grips measure
## 0.45–0.67. 0.80 — about 37° off square — sits between with margin either side.
const MAX_CHEEK_TO_CAMERA: float = 0.80

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

	# ── orientation and style dispatch (F-073) ────────────────────────────────────────────────────
	# The bug these replace was invisible to every assertion above: the mesh was on screen, the right
	# mesh, and it moved — it was just turned the wrong way and animating the wrong arc. Nothing here
	# renders anything, so it all holds under a plain --headless run.
	var camera_3d: Camera3D = player.get_node_or_null(^"CameraPivot/Camera3D") as Camera3D
	check(camera_3d != null, "the player has a Camera3D to measure the grip against")

	# The raw ints viewmodel.gd mirrors must actually be ItemDef.AttackStyle. A silent renumber here
	# would map every weapon onto the wrong arc while every other check still passed.
	var mirror_ok: bool = (
		PlayerViewmodel.STYLE_NONE == ItemDef.AttackStyle.NONE
		and PlayerViewmodel.STYLE_CHOP == ItemDef.AttackStyle.CHOP
		and PlayerViewmodel.STYLE_SMASH == ItemDef.AttackStyle.SMASH
		and PlayerViewmodel.STYLE_SLASH == ItemDef.AttackStyle.SLASH
		and PlayerViewmodel.STYLE_THRUST == ItemDef.AttackStyle.THRUST
	)
	check(mirror_ok, "viewmodel.gd's STYLE_* ints still match ItemDef.AttackStyle")

	# Every hotbar slot: the style the item declares is the style the animator actually received.
	var style_failures: PackedStringArray = PackedStringArray()
	var checked_styles: int = 0
	for slot: int in 8:
		ui.call("select_hotbar_slot", slot)
		await process_frame
		await process_frame
		var id: StringName = StringName(viewmodel.call("held_item_id"))
		if id == &"" or viewmodel.call("current_instance") == null:
			continue
		var item: ItemDef = registry.call("get_item", id)
		if item == null:
			continue
		checked_styles += 1
		var got: int = int(viewmodel.call("current_attack_style"))
		if got != int(item.attack_style):
			style_failures.append("%s wanted %d got %d" % [id, int(item.attack_style), got])
	check(checked_styles > 0, "at least one hotbar slot held something to check (%d)" % checked_styles)
	check(style_failures.is_empty(), "every held item animates with its own declared style (%s)"
		% ", ".join(style_failures))

	# THE ACTUAL REPORTED BUG: "the side of the axe is facing the player". Every A-004 head runs
	# bit-to-poll along its own local +X with the flat cheeks facing local ±Z, so a grip that leaves
	# local +Z pointing back down the view axis presents the cheek. Measured in CAMERA space, where
	# forward is -Z, this is one dot product per item.
	var cheek_failures: PackedStringArray = PackedStringArray()
	var bit_failures: PackedStringArray = PackedStringArray()
	for slot: int in 8:
		ui.call("select_hotbar_slot", slot)
		await process_frame
		await process_frame
		var id: StringName = StringName(viewmodel.call("held_item_id"))
		var held: Node3D = viewmodel.call("current_instance") as Node3D
		if held == null or not BLADE_PLANE_ITEMS.has(id):
			continue
		var to_camera: Basis = camera_3d.global_transform.basis.inverse() * held.global_transform.basis
		var cheek: Vector3 = (to_camera * Vector3(0.0, 0.0, 1.0)).normalized()
		var bit: Vector3 = (to_camera * Vector3(1.0, 0.0, 0.0)).normalized()
		# |cheek · forward| near 1 means the flat face is square to the camera — the bug.
		if absf(cheek.z) > MAX_CHEEK_TO_CAMERA:
			cheek_failures.append("%s cheek·view %.2f" % [id, absf(cheek.z)])
		# The working edge must be downrange (-Z), not pointing back at the player.
		if bit.z > 0.0:
			bit_failures.append("%s bit·view %+.2f" % [id, -bit.z])
	check(cheek_failures.is_empty(),
		"no bladed tool presents its flat cheek to the camera (%s)" % ", ".join(cheek_failures))
	check(bit_failures.is_empty(),
		"every bladed tool points its working edge downrange (%s)" % ", ".join(bit_failures))
	ui.call("select_hotbar_slot", 0)
	await process_frame
	await process_frame

	# ── every holdable item, whether or not the loadout happens to carry it ───────────────────────
	# The hotbar loops above only ever see the six items the dev loadout grants, so on their own they
	# never exercise SLASH and never measure three of the seven bladed designs — and they still print
	# PASS, with an empty failure list, which is the most dangerous shape an assertion can have. These
	# two walk the Registry instead, and drive the real pose functions directly.
	var cheek_all: PackedStringArray = PackedStringArray()
	var style_unset: PackedStringArray = PackedStringArray()
	var measured: int = 0
	for id: StringName in (registry.get("items") as Dictionary):
		var item: ItemDef = registry.call("get_item", id)
		if item == null or item.view_model == null:
			continue
		measured += 1
		# A tool or weapon that never declares a style silently inherits CHOP, which is right for an
		# axe and wrong for a spear — the exact shape of the bug being fixed.
		if item.category != ItemDef.Category.RESOURCE and item.attack_style == ItemDef.AttackStyle.CHOP \
				and not CHOP_ITEMS.has(id):
			style_unset.append(String(id))
		if not BLADE_PLANE_ITEMS.has(id):
			continue
		var grip := Basis.from_euler(Vector3(
			deg_to_rad(item.grip_rotation_degrees.x),
			deg_to_rad(item.grip_rotation_degrees.y),
			deg_to_rad(item.grip_rotation_degrees.z)
		))
		var cheek: Vector3 = (grip * Vector3(0.0, 0.0, 1.0)).normalized()
		if absf(cheek.z) > MAX_CHEEK_TO_CAMERA:
			cheek_all.append("%s %.2f" % [id, absf(cheek.z)])
	check(measured >= 11, "every item with a viewmodel was measured (%d)" % measured)
	check(cheek_all.is_empty(),
		"no bladed design's GRIP turns its cheek to the camera (%s)" % ", ".join(cheek_all))
	check(style_unset.is_empty(),
		"no tool or weapon silently inherits the default CHOP (%s)" % ", ".join(style_unset))

	# NEAR-PLANE CLEARANCE, every style, every part, across the whole arc. A viewmodel is drawn very
	# close to the camera, so a pose that pulls back far enough can push a long weapon's butt cap
	# through the near plane and slice it open — and nothing else here would notice, because the mesh
	# is still present, still the right mesh, and still animating.
	var near: float = camera_3d.near
	var clipped: PackedStringArray = PackedStringArray()
	for id: StringName in (registry.get("items") as Dictionary):
		var item: ItemDef = registry.call("get_item", id)
		if item == null or item.view_model == null:
			continue
		var probe: Node3D = item.view_model.instantiate() as Node3D
		if probe == null:
			continue
		root.add_child(probe)
		probe.position = item.grip_offset
		probe.rotation = Vector3(
			deg_to_rad(item.grip_rotation_degrees.x),
			deg_to_rad(item.grip_rotation_degrees.y),
			deg_to_rad(item.grip_rotation_degrees.z)
		)
		probe.scale = Vector3.ONE * item.grip_scale
		# Relative to the probe, then the grip transform applied explicitly. `root` is a Window, not a
		# Node3D, so anything that reaches for the parent's global_transform silently yields null here
		# and the corner list comes back empty — which makes this whole assertion pass vacuously.
		var corners: Array[Vector3] = _mesh_corners(probe)
		var grip_xf: Transform3D = probe.transform
		probe.queue_free()
		if corners.is_empty():
			clipped.append("%s produced no mesh corners to test" % id)
			continue
		var worst: float = -INF
		for step: int in SWING_SAMPLES:
			var t: float = float(step) / float(SWING_SAMPLES - 1)
			var phase: int = 1 if t < 0.5 else (2 if t < 0.68 else 3)
			var progress: float = fmod(t * 3.0, 1.0)
			var keyed: Array = viewmodel.call("swing_pose", int(item.attack_style), phase, progress)
			var node_xf: Transform3D = viewmodel.call("swing_transform", keyed[0], keyed[1])
			for corner: Vector3 in corners:
				worst = maxf(worst, (node_xf * grip_xf * corner).z)
		# Camera space: forward is -Z, so a corner at z greater than -near is through the near plane.
		if worst > -near:
			clipped.append("%s reaches z %+.3f (near %.2f)" % [id, worst, near])
	check(clipped.is_empty(),
		"no held item crosses the camera near plane during its swing (%s)" % ", ".join(clipped))

	# ── the swing, one frame per phase ────────────────────────────────────────────────────────────
	await _shoot("/tmp/mire_viewmodel_idle.png", "idle")
	var rest_position: Vector3 = viewmodel.position
	check(int(combat.call("request_attack")) > 0, "the swing starts")
	await _shoot("/tmp/mire_viewmodel_windup.png", "wind-up")
	# The wind-up must ARRIVE somewhere: CombatService resolves the hit at the wind-up/commit
	# boundary, so a pose still sitting at rest here is a swing whose strike lands a phase late.
	var travelled: float = viewmodel.position.distance_to(rest_position)
	check(travelled > 0.01, "the wind-up actually moves the weapon (%.3f m)" % travelled)
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


## Every mesh AABB corner under `node`, in `node`'s OWN space. An AABB is enough here: it strictly
## contains the mesh, so a bound that clears the near plane guarantees the mesh does too.
func _mesh_corners(node: Node3D) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var into_node: Transform3D = node.global_transform.affine_inverse()
	for child: Node in node.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := child as MeshInstance3D
		if mesh_instance.mesh == null:
			continue
		var box: AABB = mesh_instance.mesh.get_aabb()
		var to_node: Transform3D = into_node * mesh_instance.global_transform
		for corner: int in 8:
			out.append(to_node * box.get_endpoint(corner))
	return out


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
