extends SceneTree

## F-164 proof: a capped Wellspring's re-corruption clock now has an ON-SCREEN warning before it
## finishes, not just the in-world mesh swap. Two things this check exists to catch, both real:
##   1. `WellspringHud` was never added to `[autoload]` at all — the whole HUD (capping prompt
##      included) has been unreachable in the live game since task 4.8, an F-165/F-151-shaped gap
##      DELEGATION.md's task 6.5 entry already flagged in passing. Fixed here alongside F-164's own
##      warning, because a warning built into a HUD nothing loads is not shipped (AGENTS.md).
##   2. The warning is ambient, not proximity-gated: driven through a REAL `Wellspring` node (same
##      construction `wellspring_recorruption_check.gd` uses) placed far from the local camera, so a
##      pass here proves a player elsewhere on the map still gets the cue — not just one standing
##      next to the decaying mesh.
##
##   .agent/bin/agent godot --script tools/wellspring_hud_check.gd

const WELLSPRING_SCRIPT := preload("res://systems/wellspring/wellspring.gd")

var failures: int = 0
var hud: Node
var _far_wellspring: Node3D


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame

	hud = root.get_node_or_null(^"WellspringHud")
	check(hud != null, "WellspringHud autoload exists — F-164's fix is reachable in the live game")
	if hud == null:
		finish()
		return

	var warning_panel := hud.get("_warning_panel") as Control
	var warning_label := hud.get("_warning_label") as Label
	check(warning_panel != null and warning_label != null, "the HUD built the ambient warning panel")
	if warning_panel == null or warning_label == null:
		finish()
		return

	check(not warning_panel.visible, "no capped Wellspring anywhere yet -> no warning on boot")

	# Placed far from the (nonexistent, in this headless check) camera — `_local_camera_position()`
	# falls back to Vector3.ZERO when there is no Camera3D, so any position proves the point, but a
	# large offset makes the intent unambiguous: this is not a proximity read.
	_far_wellspring = WELLSPRING_SCRIPT.new() as Node3D
	_far_wellspring.name = "CheckWellspringFar"
	root.add_child(_far_wellspring)
	_far_wellspring.global_position = Vector3(5000.0, 0.0, 5000.0)
	await process_frame

	var duration: float = WELLSPRING_SCRIPT.RECORRUPTION_DURATION_SEC
	var threshold_fraction: float = WELLSPRING_SCRIPT.RECORRUPTING_VISUAL_FRACTION

	# Cap it directly (host-side field writes, same shortcut `wellspring_recorruption_check.gd`
	# takes for sections that don't need the ritual itself) and cross into recorruption.
	_far_wellspring.set("capped", true)
	check(bool(_far_wellspring.get("capped")), "the check wellspring is capped")

	_call_refresh()
	check(not warning_panel.visible, "capped but recorruption_sec is 0 -> below threshold, no warning yet")

	_far_wellspring.set("recorruption_sec", duration * threshold_fraction + 1.0)
	_call_refresh()
	check(warning_panel.visible, "crossing RECORRUPTING_VISUAL_FRACTION shows the ambient warning (F-164)")
	check(warning_label.text.to_lower().contains("wellspring"), "and it names what's happening: '%s'" % warning_label.text)
	check(warning_label.text.contains(":"), "with a countdown, not just a static line: '%s'" % warning_label.text)

	# A second capped-and-recorrupting Wellspring should read as a count, not silently collapse to
	# the singular line — the two-Wellspring line is a real path (Hollowmere ships one today, but a
	# future map's `PoiDef` count is not this HUD's business to assume).
	var second := WELLSPRING_SCRIPT.new() as Node3D
	second.name = "CheckWellspringFarSecond"
	root.add_child(second)
	second.global_position = Vector3(-5000.0, 0.0, -5000.0)
	await process_frame
	second.set("capped", true)
	second.set("recorruption_sec", duration * threshold_fraction + 1.0)
	_call_refresh()
	check(warning_label.text.contains("2"), "two recorrupting Wellsprings read as a count: '%s'" % warning_label.text)
	second.queue_free()
	await process_frame

	# Finishing the clock (capped -> false, recorruption_sec -> 0, same terminal state
	# `_finish_recorruption()` leaves) clears the warning again.
	_far_wellspring.set("capped", false)
	_far_wellspring.set("recorruption_sec", 0.0)
	_call_refresh()
	check(not warning_panel.visible, "a fully re-corrupted (no longer capped) Wellspring clears the warning")

	# Re-capping and crossing the threshold again re-arms it — this is not a one-shot latch.
	_far_wellspring.set("capped", true)
	_far_wellspring.set("recorruption_sec", duration * threshold_fraction + 1.0)
	_call_refresh()
	check(warning_panel.visible, "a fresh cap crossing the threshold again re-shows the warning")

	print("\nWELLSPRING_HUD_CHECK failures=%d" % failures)
	finish()


## `_refresh_recorruption_warning()` is private and polled on a 0.15s timer in the live game — called
## directly here so this check crosses many polls in one call instead of `await`ing real engine time
## the way `vitals_hud_check.gd`'s countdown assertion does, which this check has no need for.
func _call_refresh() -> void:
	hud.call(&"_refresh_recorruption_warning")


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	if _far_wellspring != null:
		_far_wellspring.queue_free()
	quit(0 if failures == 0 else 1)
