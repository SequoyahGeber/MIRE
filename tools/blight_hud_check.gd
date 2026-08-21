extends SceneTree

## F-349: standing in Blight must be legible before it kills you.
##
## `PlayerHealth._tick_blight()` drains hp wherever `MireGrid.corruption_at()` is at or above
## `BLIGHT_CORRUPTION_THRESHOLD`, and until this shipped nothing on screen said so — the health bar
## simply fell. It was reported as a bug twice, by the same player, because from the inside that is
## exactly what it looks like.
##
## What this proves is the LINK, not just the presence of an overlay: the thresholds the readout
## draws are the ones PlayerHealth actually damages on, read off PlayerHealth rather than copied, so
## a retune of the mechanic cannot silently desync the warning from the damage.
##
## Run with: .agent/bin/agent godot --script tools/blight_hud_check.gd

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame

	var hud: Node = root.get_node_or_null(^"VitalsHud")
	var health: Node = root.get_node_or_null(^"PlayerHealth")
	check(hud != null, "VitalsHud autoload exists")
	check(health != null, "PlayerHealth autoload exists")
	if hud == null or health == null:
		finish()
		return

	var threshold: float = float(health.get(&"BLIGHT_CORRUPTION_THRESHOLD"))
	var rate: float = float(health.get(&"BLIGHT_HP_DRAIN_PER_SEC_AT_FULL_CORRUPTION"))
	check(threshold > 0.0, "PlayerHealth still exposes the corruption threshold (%.2f)" % threshold)
	check(rate > 0.0, "PlayerHealth still exposes the drain rate (%.1f hp/s at full)" % rate)

	# Clean ground: nothing at all. A permanent tint would be worse than none — it stops meaning
	# anything the moment it is always there.
	hud.call(&"force_blight_sample", 0.0)
	check(is_zero_approx(float(hud.call(&"blight_vignette_intensity"))),
		"clean ground draws no vignette")
	check(String(hud.call(&"blight_status_text")).is_empty(), "clean ground shows no status row")

	# Tainted but below the damage threshold: warn, and say so in words that do NOT claim damage.
	var warn_at: float = threshold * 0.5
	hud.call(&"force_blight_sample", warn_at)
	var warn_intensity: float = float(hud.call(&"blight_vignette_intensity"))
	var warn_text: String = String(hud.call(&"blight_status_text"))
	check(warn_intensity > 0.0, "tainted ground below the threshold still warns (%.2f)" % warn_intensity)
	check(not warn_text.is_empty(), "and names itself: '%s'" % warn_text)
	check(not warn_text.to_lower().contains("hp/s"),
		"a warning that is not yet costing hp does not claim a drain rate")

	# At the threshold: this is where PlayerHealth starts taking hp, so this is where the readout
	# has to become unmistakable rather than merely present.
	hud.call(&"force_blight_sample", threshold)
	var at_intensity: float = float(hud.call(&"blight_vignette_intensity"))
	var at_text: String = String(hud.call(&"blight_status_text"))
	check(at_intensity > warn_intensity * 1.5,
		"crossing the damage threshold steps the vignette up hard (%.2f -> %.2f)"
			% [warn_intensity, at_intensity])
	check(at_text.to_lower().contains("blight"), "and the status row names Blight: '%s'" % at_text)
	check(at_text.contains("hp/s"), "and states the rate, so the drain has a visible cause")

	# Full corruption: stronger again, and the quoted rate matches what PlayerHealth would actually
	# take. This is the assertion that keeps the warning honest across a retune.
	hud.call(&"force_blight_sample", 1.0)
	var full_intensity: float = float(hud.call(&"blight_vignette_intensity"))
	var full_text: String = String(hud.call(&"blight_status_text"))
	check(full_intensity > at_intensity,
		"full corruption reads stronger than the threshold (%.2f -> %.2f)"
			% [at_intensity, full_intensity])
	check(full_intensity <= 1.0, "and never exceeds the shader's own range")
	check(full_text.contains("%.1f" % rate),
		"the quoted rate is PlayerHealth's own number at full corruption (%.1f): '%s'"
			% [rate, full_text])

	# Leaving Blight must visibly stop it — otherwise the effect teaches nothing about where to go.
	hud.call(&"force_blight_sample", 0.0)
	check(is_zero_approx(float(hud.call(&"blight_vignette_intensity"))),
		"stepping back onto clean ground clears the vignette")
	check(String(hud.call(&"blight_status_text")).is_empty(),
		"and clears the status row, so the readout is about NOW")

	print("BLIGHT_HUD_CHECK failures=%d" % failures)
	finish()


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
