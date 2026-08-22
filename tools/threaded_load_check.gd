extends SceneTree

## F-591's proof, and it is deliberately NOT "I ran the game and it did not crash".
##
##   .agent/bin/agent godot --script tools/threaded_load_check.gd
##
## The defect is a data race, so its absence cannot be established by repetition — at F-495's
## measured one-in-six base rate, a handful of clean runs is worth nothing, and every reproduction
## costs a crash dialog on the machine of whoever is sitting at it. So this asserts the **invariant**
## that makes the race impossible, which is deterministic and free:
##
##     a path is either in flight through ThreadedLoadRegistry, or it is not being loaded at all.
##
## Concretely: a second threaded request over a live path is refused, and a blocking load over a live
## path takes the existing request over instead of starting a competing one.
##
## Each assertion is paired with a **negative control** — the same operation with the guard bypassed,
## proving the assertion can actually go red. An invariant check with no negative control is a check
## that never looked.

const REGISTRY := preload("res://core/loading/threaded_load_registry.gd")

## Any shipped GLB. Resolved by walking `assets/` rather than hard-coded, so this cannot rot when an
## asset is renamed — the check is about the registry, not about a particular mesh.
var _path: String = ""
var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	_path = _any_asset()
	check(not _path.is_empty(), "found a shipped asset to load: %s" % _path)
	if _path.is_empty():
		_finish()
		return

	REGISTRY.reset_for_test()
	_check_single_lifecycle()
	_check_blocking_takeover()
	_check_release_on_failure()
	_check_call_sites()
	_finish()


func _check_single_lifecycle() -> void:
	print("\n== One lifecycle per path ==")
	REGISTRY.reset_for_test()
	check(REGISTRY.in_flight_count() == 0, "the registry starts empty")

	check(bool(REGISTRY.request(_path)), "the first request for a path is granted")
	check(REGISTRY.in_flight_count() == 1, "the path is in flight")
	check(bool(REGISTRY.is_in_flight(_path)), "is_in_flight() reports it")

	# THE INVARIANT. This is the call that used to reach `ResourceLoader.load_threaded_request()` a
	# second time over one path — two lifecycles, one internal task, a freed block touched twice.
	check(not bool(REGISTRY.request(_path)),
		"a SECOND request for a live path is refused — the corruption F-591 is about")
	check(REGISTRY.collision_count() == 1, "the refusal is counted rather than hidden")
	check(REGISTRY.in_flight_count() == 1, "the refused request did not add a second lifecycle")

	var resource: Resource = REGISTRY.retrieve(_path)
	check(resource != null, "retrieving returns the resource")
	check(REGISTRY.in_flight_count() == 0, "retrieving releases the path")
	check(bool(REGISTRY.request(_path)), "the path can be requested again once released")
	REGISTRY.retrieve(_path)

	# NEGATIVE CONTROL: with the registry bypassed, the engine accepts the double request that the
	# guard above refuses. This is what the code did before F-591, and it must still be possible —
	# otherwise the assertion above is passing because the loader refuses it anyway, not because the
	# registry does, and the whole fix would be decoration.
	var first: int = ResourceLoader.load_threaded_request(_path)
	var second: int = ResourceLoader.load_threaded_request(_path)
	check(first == OK and second == OK,
		"NEGATIVE CONTROL: raw ResourceLoader accepts two requests over one path (%d, %d) — so the guard above is what prevents it, not the engine" % [first, second])
	ResourceLoader.load_threaded_get(_path)


func _check_blocking_takeover() -> void:
	print("\n== A blocking load never races a live request ==")
	REGISTRY.reset_for_test()
	check(bool(REGISTRY.request(_path)), "a threaded request is in flight")

	# The exact shape of the crash: a chunk build reaching `_load_mesh_parts()` for an asset the warm
	# pump still has in flight. It must take the request OVER, not start a second load.
	var resource: Resource = REGISTRY.blocking_load(_path)
	check(resource != null, "the blocking load returns the resource")
	check(REGISTRY.blocking_takeover_count() == 1,
		"it took the live request over rather than starting a competing load")
	check(REGISTRY.in_flight_count() == 0, "the path is released afterwards, not leaked")

	# And with nothing in flight it is an ordinary load, with no takeover recorded.
	REGISTRY.reset_for_test()
	check(REGISTRY.blocking_load(_path) != null, "a blocking load with nothing in flight still works")
	check(REGISTRY.blocking_takeover_count() == 0, "an uncontended load takes nothing over")


func _check_release_on_failure() -> void:
	print("\n== A failed load releases its claim ==")
	REGISTRY.reset_for_test()
	var missing := "res://assets/definitely_not_a_kit/exports/definitely_not_an_asset.glb"
	# Measured, not assumed: Godot GRANTS `load_threaded_request()` for a path that does not exist and
	# reports the failure later, through the status. (This check originally asserted the opposite and
	# went red, which is the assertion doing its job on its author.) So a claim IS taken, and what
	# matters is that the failure path still releases it — a leaked claim would block that path for
	# the rest of the process, and the pump would spin on a request it can never re-issue.
	var granted: bool = REGISTRY.request(missing)
	check(granted, "the engine grants the request and defers the error to the status")
	if granted:
		check(REGISTRY.status(missing) != ResourceLoader.THREAD_LOAD_LOADED,
			"the status reports the failure rather than a resource")
		# Exactly what both warm pumps do on a non-LOADED status.
		REGISTRY.retrieve(missing)
	check(REGISTRY.in_flight_count() == 0,
		"a failed load releases its claim, so the path is not blocked forever")


## The fix is only real if nothing bypasses it. Asserted against the source, because the alternative
## is reproducing a race — which is the thing this whole check exists to avoid.
func _check_call_sites() -> void:
	print("\n== Nothing bypasses the registry ==")
	for path: String in ["res://autoload/material_warmer.gd", "res://world/gen/resource_scatter_field.gd"]:
		var source: String = FileAccess.get_file_as_string(path)
		var offenders: Array[String] = []
		for line: String in source.split("\n"):
			var code: String = line.strip_edges()
			if code.begins_with("#") or code.begins_with("##"):
				continue
			if code.contains("ResourceLoader.load_threaded_request("):
				offenders.append(code)
			# A bare `load(` on an asset path, outside the registry, is the other half of the defect.
			if code.contains("= load(") and code.contains("res://assets"):
				offenders.append(code)
		check(offenders.is_empty(),
			"%s routes every threaded load through the registry (%s)" % [
				path.get_file(), "clean" if offenders.is_empty() else offenders])


func _any_asset() -> String:
	var root := DirAccess.open("res://assets")
	if root == null:
		return ""
	var kits: PackedStringArray = root.get_directories()
	# Sorted so a failure names the same asset every time rather than whichever the filesystem
	# happened to hand back first.
	var names: Array[String] = []
	for kit: String in kits:
		names.append(kit)
	names.sort()
	for kit: String in names:
		var exports_path := "res://assets/%s/exports" % kit
		var exports := DirAccess.open(exports_path)
		if exports == null:
			continue
		var files: Array[String] = []
		for file: String in exports.get_files():
			if file.ends_with(".glb"):
				files.append(file)
		files.sort()
		if not files.is_empty():
			return "%s/%s" % [exports_path, files[0]]
	return ""


func _finish() -> void:
	print("\nTHREADED_LOAD_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)
