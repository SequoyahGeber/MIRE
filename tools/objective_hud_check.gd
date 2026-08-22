extends SceneTree

## F-599 — the objective readout says something true.
##
## Sequoyah: *"id like the base objective to be pretty simple and make sure the whole thing actually
## does something."* `ObjectiveHud` is the "pretty simple" half. This asserts it is also TRUE, which
## is the half a HUD can silently fail at — a bearing that points the wrong way is worse than no
## bearing, because a player will walk it.
##
## Driven through `refresh()` with real nodes rather than by waiting on frames, so each assertion
## fails for its own reason (the rule wick1c650c earned today: split an assertion whenever its
## failure text would name the wrong subsystem).
##
## Authority: none.

var failures: int = 0
## The live autoload. `_compass` is static, but GDScript refuses `Script.call()` on a class that
## also has instance members, so it is reached through the running HUD.
var hud: Node


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	hud = root.get_node_or_null(^"ObjectiveHud")
	check(hud != null, "ObjectiveHud is registered as an autoload")
	if hud == null:
		_finish()
		return
	_check_compass()
	await _check_readout()
	_finish()


## The bearing is the one thing a player will act on physically.
func _check_compass() -> void:
	print("\n== the compass points where the thing actually is ==")
	# -Z is north. Each case is a direction someone would turn towards.
	for probe: Array in [
		[Vector3(0, 0, -10), "N"], [Vector3(10, 0, -10), "NE"], [Vector3(10, 0, 0), "E"],
		[Vector3(10, 0, 10), "SE"], [Vector3(0, 0, 10), "S"], [Vector3(-10, 0, 10), "SW"],
		[Vector3(-10, 0, 0), "W"], [Vector3(-10, 0, -10), "NW"],
	]:
		var got: String = hud.call(&"_compass", probe[0] as Vector3)
		check(got == String(probe[1]), "%s -> %s (got %s)" % [probe[0], probe[1], got])


## The readout counts what is really there, and changes when the world does.
func _check_readout() -> void:
	print("\n== the readout tracks the actual Wellspring states ==")
	var holder := Node3D.new()
	root.add_child(holder)
	var player := CharacterBody3D.new()
	player.add_to_group(&"players")
	holder.add_child(player)
	player.global_position = Vector3.ZERO

	var springs: Array[Node3D] = []
	for index: int in 3:
		var spring := Node3D.new()
		spring.set_script(load("res://systems/wellspring/wellspring.gd"))
		holder.add_child(spring)
		# 40 m north, 80 m east, 120 m south — distinct distances AND distinct bearings, so a bug
		# that picks the wrong one shows up in both fields rather than only in the number.
		spring.global_position = [Vector3(0, 0, -40), Vector3(80, 0, 0), Vector3(0, 0, 120)][index]
		springs.append(spring)
	for _frame: int in 3:
		await process_frame

	hud.call(&"refresh")
	var task: String = _label_text(hud, 0)
	var bearing: String = _label_text(hud, 1)
	var state: String = _label_text(hud, 2)
	check(task.contains("0 / 3"), "counts every Wellspring, none capped yet (%s)" % task)
	check(bearing.contains("N ") and bearing.contains("40"),
		"points at the NEAREST one, 40 m north (%s)" % bearing)
	check(state.contains("%"), "reports a corruption percentage (%s)" % state)

	# Cap the near one: the objective must move on rather than keep pointing at solved work.
	springs[0].set(&"capped", true)
	hud.call(&"refresh")
	check(_label_text(hud, 0).contains("1 / 3"), "the capped count follows a cap")
	var moved: String = _label_text(hud, 1)
	check(moved.contains("E ") and moved.contains("80"),
		"and the bearing moves to the next uncapped one, 80 m east (%s)" % moved)

	# The negative control for the whole readout: with everything capped it must say so, not keep
	# showing a stale bearing to a Wellspring that no longer needs anything.
	for spring: Node3D in springs:
		spring.set(&"capped", true)
	hud.call(&"refresh")
	check(_label_text(hud, 0).contains("All Wellsprings capped"),
		"says so when there is nothing left to cap (%s)" % _label_text(hud, 0))
	check(not _label_text(hud, 1).contains(" m"),
		"and stops showing a bearing (%s)" % _label_text(hud, 1))

	holder.queue_free()


func _label_text(hud: Node, index: int) -> String:
	var root_box: Node = hud.get_node_or_null(^"Objective")
	if root_box == null or index >= root_box.get_child_count():
		return ""
	return String((root_box.get_child(index) as Label).text)


func check(ok: bool, label: String) -> void:
	if ok:
		print("  ok   %s" % label)
	else:
		failures += 1
		print("  FAIL %s" % label)


func _finish() -> void:
	print("\nOBJECTIVE_HUD_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)
