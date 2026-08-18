extends SceneTree

## F-114: a bush that stays inside a chunk's MultiMesh batch must still vanish when you strip it,
## and come back when it respawns.
##
## This is the half of the asset-keyed harvest work that cannot be proven by arithmetic. The 794
## bushes and saplings on this map were deliberately NOT promoted to a mesh each — that would have
## traded a handful of batched draw calls for eight hundred on the machines this game targets — so
## the only handle a depleted bush has is its own slot inside a shared `MultiMesh`, hidden by
## zeroing that one instance's transform. If that hook is wrong, the failure is silent and cosmetic:
## you harvest a bush, collect the sticks, and the bush is still standing there.
##
## Runs against whatever `application/run/main_scene` is, so it follows the shipped map.
##
## **Run it windowed.** `MultiMesh` instance transforms live on the RenderingServer, and under the
## dummy renderer every `--headless` run gets, the buffer is empty and every read answers identity
## (F-077, and `autoload/environment_vfx.gd` hit the same wall). The wiring half of this check still
## runs headless and is still worth running; the four readback assertions announce themselves as
## SKIPPED rather than passing on an identity they cannot distinguish from success.
##
## The reads also have to settle. `physics_interpolation` is on for this project, so a transform
## written this frame is read back part-way between its old and new value — a bush caught at 82% of
## its size, which is not a bug and is why the assertions below wait for the tick to land.
##
## Run with: .agent/bin/agent godot --windowed --script tools/harvest_batch_check.gd

var failures: int = 0
var skipped: int = 0
## False under the dummy renderer, where MultiMesh reads cannot see what was written.
var can_read_instances: bool = false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	can_read_instances = DisplayServer.get_name() != "headless"
	if not can_read_instances:
		print("NOTE: dummy renderer — MultiMesh readback assertions will be skipped")
	var scene_path := String(ProjectSettings.get_setting("application/run/main_scene", ""))
	var packed := load(scene_path) as PackedScene
	check(packed != null, "main scene %s loads" % scene_path)
	if packed == null:
		_finish()
		return
	var scene := packed.instantiate() as Node3D
	root.add_child(scene)
	current_scene = scene
	for _frame: int in 12:
		await process_frame
	await physics_frame

	var harvest: Node = root.get_node_or_null(^"HarvestWorld")
	check(harvest != null, "HarvestWorld autoload exists")
	if harvest == null:
		_finish()
		return
	harvest.call("refresh_current_scene")
	await process_frame

	var batched: Array[Node3D] = []
	for value: Variant in (harvest.call("wired_harvestables") as Array):
		var harvestable := value as Node3D
		var holder := harvestable.get_parent() as Node3D
		if holder != null and holder.has_meta(&"batch_meshes"):
			batched.append(harvestable)
	check(not batched.is_empty(), "this map wires batched harvestables (%d)" % batched.size())
	if batched.is_empty():
		_finish()
		return

	var subject: Node3D = batched[0]
	var holder := subject.get_parent() as Node3D
	var meshes: Array = holder.get_meta(&"batch_meshes", []) as Array
	var index: int = int(holder.get_meta(&"batch_index", -1))
	var multimesh := (meshes[0] if not meshes.is_empty() else null) as MultiMesh
	check(multimesh != null and index >= 0 and index < multimesh.instance_count,
		"%s points at a real slot in its batch" % holder.name)
	if multimesh == null or index < 0 or index >= multimesh.instance_count:
		_finish()
		return

	var placed: Array = holder.get_meta(&"batch_transforms", []) as Array
	check(placed.size() == meshes.size(),
		"the builder recorded one placement per mesh part of this batch")
	var standing: Transform3D = (placed[0] as Transform3D) if not placed.is_empty() else Transform3D.IDENTITY
	check(standing.basis.determinant() != 0.0, "the bush was placed at a real size")
	check(standing.origin.is_equal_approx(holder.global_position),
		"the recorded placement is where the holder stands")
	observe(multimesh.get_instance_transform(index).is_equal_approx(standing),
		"the batch really draws the bush at its recorded placement")

	var definition: Resource = subject.get("definition")
	check(definition != null, "the batched prop carries a definition")
	check(bool(definition.call("uses_authored_visual")),
		"a batched prop's definition ships no state scenes of its own")
	check(bool(subject.call("host_apply_damage", int(definition.get("max_health")), 1)),
		"the batched prop accepts a lethal host hit")
	await _settle()
	check(not bool(subject.get("active")), "the batched prop depletes")
	var flattened: Transform3D = multimesh.get_instance_transform(index)
	observe(flattened.basis.determinant() == 0.0,
		"the depleted bush's own instance is collapsed, not just its logic")
	observe(flattened.origin.is_equal_approx(standing.origin),
		"collapsing the instance leaves it where it stood, so respawn restores in place")

	# Its neighbours in the same batch must be untouched — an off-by-one here would strip a whole
	# hillside's worth of bushes on one swing and nothing would report it.
	var neighbour: int = 0 if index != 0 else mini(1, multimesh.instance_count - 1)
	if neighbour != index:
		observe(multimesh.get_instance_transform(neighbour).basis.determinant() != 0.0,
			"the bush next to it in the same batch is still standing")

	check(bool(subject.call("host_respawn")), "the batched prop respawns")
	await _settle()
	observe(multimesh.get_instance_transform(index).is_equal_approx(standing),
		"respawn restores the exact placed transform")

	print("HARVEST_BATCH_CHECK batched=%d skipped=%d failures=%d" % [
		batched.size(), skipped, failures
	])
	_finish()


## Physics interpolation means a transform written this frame reads back part-way to its new value.
## Two physics frames plus a process frame is enough for the write to be the whole answer.
func _settle() -> void:
	await physics_frame
	await physics_frame
	await process_frame


## An assertion that can only be made with a real renderer. Announced as skipped otherwise, never
## silently passed: an identity readback is indistinguishable from a correct one, so counting it as
## a pass is how a check starts lying.
func observe(condition: bool, description: String) -> void:
	if not can_read_instances:
		skipped += 1
		print("SKIP (no renderer): %s" % description)
		return
	check(condition, description)


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func _finish() -> void:
	quit(1 if failures > 0 else 0)
