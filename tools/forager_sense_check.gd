extends SceneTree

## F-543 — offline proof that DESIGN §4.5's "sees resources through terrain" is a real, gated sense.
##
##   .agent/bin/agent godot --script tools/forager_sense_check.gd
##
## Three things have to be true for that line to mean anything, and each has its own failure mode:
##
##   1. **It is off for everyone else.** A sense every role gets is not a role. The cost gate is the
##      same code path as the design rule here — `set_process(false)` — so this is one assertion, not
##      two.
##   2. **It turns on when the pick lands**, from the signal rather than from a poll, because a
##      selection is RUN-scoped (F-277) and a run restart clears it.
##   3. **It marks props THROUGH terrain.** A prop fully enclosed in solid geometry must still be
##      marked; this is the whole point, and it is the one thing an occlusion-tested HUD would fail.
##
## Drives the REGISTERED /root/ForagerSenseHud and /root/AttunementService (F-068/F-069), offline, so
## the pick resolves synchronously through the real host path.

const HOST_PEER: int = 1

var failures: int = 0
var hud: Node
var attunements: Node
var powerups: Node
var _world: Node3D
var _camera: Camera3D
var _props: Array[Node3D] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	if not _check_wiring():
		finish()
		return
	_build_scene()
	await process_frame

	_check_off_for_other_roles()
	await _check_on_for_a_forager()
	_check_sees_through_solid_geometry()
	_check_range_and_cap()
	await _check_cleared_on_run_restart()

	print("\nFORAGER_SENSE_CHECK failures=%d" % failures)
	finish()


func _check_wiring() -> bool:
	print("== the shipped project loads the Forager sense as an autoload ==")
	hud = root.get_node_or_null(^"ForagerSenseHud")
	attunements = root.get_node_or_null(^"AttunementService")
	powerups = root.get_node_or_null(^"PowerupService")
	check(hud != null,
		"ForagerSenseHud is registered in project.godot — a HUD nothing loads grants nothing")
	check(attunements != null, "AttunementService is registered as an autoload")
	check(powerups != null, "PowerupService is registered as an autoload")
	return hud != null and attunements != null and powerups != null


## A camera, a wall, and three harvestables: one in the open, one sealed inside the wall, one far
## outside the sense radius.
func _build_scene() -> void:
	_world = Node3D.new()
	root.add_child(_world)

	_camera = Camera3D.new()
	_camera.position = Vector3.ZERO
	_camera.current = true
	_world.add_child(_camera)

	# A solid slab between the camera and the buried prop, on the shared world layer — the same mask
	# `TargetHealthHud` occlusion-tests against, so if this file ever grew an occlusion ray it would
	# fail the "through terrain" assertion below rather than silently passing.
	var wall := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(40.0, 20.0, 2.0)
	shape.shape = box
	wall.add_child(shape)
	wall.position = Vector3(0.0, 0.0, -8.0)
	wall.collision_layer = 1
	_world.add_child(wall)

	_props.append(_spawn_prop(Vector3(2.0, 0.0, -4.0)))    # in the open
	_props.append(_spawn_prop(Vector3(0.0, 0.0, -8.0)))    # inside the wall
	_props.append(_spawn_prop(Vector3(0.0, 0.0, -400.0)))  # far outside RANGE_M


func _spawn_prop(position: Vector3) -> Node3D:
	var prop := Node3D.new()
	prop.position = position
	# Group membership is the whole contract the HUD reads — matching what `Harvestable._ready()`
	# does — so a stand-in needs no script, and this check cannot pass by accident on a real prop
	# that happened to be in the scene.
	prop.add_to_group(&"harvestable")
	prop.set(&"active", true)
	_world.add_child(prop)
	return prop


func _check_off_for_other_roles() -> void:
	print("\n== the sense is OFF for every role but Forager, and costs nothing ==")
	for role_id: StringName in [&"warden", &"tinker", &"reaver"]:
		powerups.call(&"host_clear", HOST_PEER)
		attunements.call(&"host_clear_selection", HOST_PEER)
		attunements.call(&"request_select", role_id)
		check(String(attunements.call(&"local_selection")) == String(role_id),
			"a %s pick lands" % role_id)
		check(not bool(hud.call(&"sense_active")), "a %s has no resource sense" % role_id)
		check(not bool(hud.is_processing()),
			"and the HUD is not processing at all for a %s — the design gate IS the cost gate" % role_id)
		check((hud.call(&"tracked_markers") as Array).is_empty(),
			"and draws nothing")


func _check_on_for_a_forager() -> void:
	print("\n== picking Forager turns it on, driven by selection_changed ==")
	powerups.call(&"host_clear", HOST_PEER)
	attunements.call(&"host_clear_selection", HOST_PEER)
	check(not bool(hud.call(&"sense_active")), "cleared back off between roles")
	attunements.call(&"request_select", &"forager")
	await process_frame
	check(bool(hud.call(&"sense_active")), "a Forager has the sense")
	check(bool(hud.is_processing()),
		"and the HUD started processing off the signal, without anything polling it")


func _check_sees_through_solid_geometry() -> void:
	print("\n== a prop sealed inside solid geometry is still marked — the point of the whole thing ==")
	hud.call(&"refresh_now")
	var marked: Array = _marked_nodes()
	check(marked.has(_props[0]), "the prop in the open is marked")
	check(marked.has(_props[1]),
		"the prop INSIDE the wall is marked too — no occlusion test stands between a Forager and a node")


func _check_range_and_cap() -> void:
	print("\n== the sense has a horizon, and a ceiling ==")
	var marked: Array = _marked_nodes()
	check(not marked.has(_props[2]),
		"a prop 400 m out is not marked — RANGE_M is a real limit, not decoration")

	var extra: Array[Node3D] = []
	for i: int in range(40):
		extra.append(_spawn_prop(Vector3(float(i) * 0.4 - 8.0, 0.0, -5.0)))
	hud.call(&"refresh_now")
	var count: int = (hud.call(&"tracked_markers") as Array).size()
	check(count <= 24,
		"a grove of 43 props draws at most MAX_MARKERS (%d) — a sense, not fog" % count)
	check(count > 0, "and still draws something")
	for prop: Node3D in extra:
		prop.queue_free()


func _check_cleared_on_run_restart() -> void:
	print("\n== a run restart clears the pick, and the sense goes with it (F-277's discipline) ==")
	attunements.call(&"host_clear_all")
	await process_frame
	check(not bool(hud.call(&"sense_active")),
		"a new run starts with no sense until the picker is answered again")
	check((hud.call(&"tracked_markers") as Array).is_empty(),
		"and nothing is left drawn from the previous run")


func _marked_nodes() -> Array:
	var nodes: Array = []
	for marker: Object in (hud.call(&"tracked_markers") as Array):
		nodes.append(marker.get(&"node"))
	return nodes


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
