extends SceneTree

## F-516 proof, headless: every shipped GLB is enumerated and drawn once through `MaterialWarmer`'s
## off-screen viewport, and the rig tears itself down afterwards.
##
##   .agent/bin/agent godot --script tools/material_warm_check.gd
##
## ## What this check can and cannot prove
##
## It proves **coverage and lifecycle** — that the warm pass finds every asset the project ships,
## instantiates and draws each one, warms the runtime-built spatial shaders, and leaves nothing
## resident. Those are the properties that break silently: an art domain moves, the enumeration
## quietly returns fewer files, and nothing anywhere fails — the game just starts hitching again.
##
## It CANNOT prove the performance win. Headless Godot uses the dummy rendering driver, where no
## shader is compiled and no pipeline state object is created, so a hitch-count comparison measured
## here would be measuring nothing. F-516's acceptance test is `tools/revisit_probe.gd`'s cold/warm
## A-B on a real GPU: with pre-warming in place, leg A should cost what leg B costs, because there
## is nothing left for the intervening visits to warm. That run needs a window and a real display
## (docs/PERFORMANCE.md's method), which is one of the few things an agent genuinely cannot do
## itself.
##
## So: this check is the regression net, not the acceptance test, and it says so rather than
## implying a green run means the hitches are gone.
##
## ## Why the warmer is idle until this check starts it
##
## `MaterialWarmer` disables its own `_process` under the headless display server, because every
## harness in `tools/` runs headless and silently attaching a few hundred threaded GLB loads to all
## of them would slow the suite and perturb the timing-sensitive two-process net checks. This check
## therefore drives the pass explicitly through `force_complete_now()` — which is also why section 3
## can assert teardown at all.

## Below any plausible shipped inventory (483 GLBs at the time of writing) and above zero by enough
## that a broken enumeration — one kit found, or the `exports/` convention changed — fails here
## instead of silently halving the coverage. Deliberately not asserted as an exact number: a check
## that has to be edited every time an artist adds a tree is a check that gets edited without being
## read.
const MINIMUM_EXPECTED_ASSETS: int = 300

var failures: int = 0
var warmer: Node


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame

	warmer = root.get_node_or_null(^"MaterialWarmer")
	check(warmer != null, "the MaterialWarmer autoload is registered and in the tree")
	if warmer == null:
		_report()
		return

	await _check_enumeration()
	await _check_draws_every_asset()
	_check_teardown()
	_report()


func _report() -> void:
	print("\nMATERIAL_WARM_CHECK failures=%d" % failures)
	print("NOTE: coverage and lifecycle only — the hitch reduction itself needs tools/revisit_probe.gd")
	print("      on a real GPU with a window, which headless cannot measure (dummy rendering driver).")
	quit(0 if failures == 0 else 1)


# ── 1. coverage ───────────────────────────────────────────────────────────────────────────────────


## The property that fails silently. `_enumerate_assets()` walks `res://assets/*/exports/*.glb`
## rather than reading a manifest, which is what makes it self-maintaining — and also what makes a
## convention change (a domain that stops using `exports/`) invisible without this assertion.
func _check_enumeration() -> void:
	print("\n== F-516: every shipped GLB is enumerated for warming ==")
	var found: int = int(warmer.call("pending_asset_count"))
	print("   enumerated %d asset(s)" % found)
	check(found >= MINIMUM_EXPECTED_ASSETS,
		"the warm pass found at least %d shipped assets (%d)" % [MINIMUM_EXPECTED_ASSETS, found])

	# Cross-checked against the filesystem directly, not against the same walk the subject just did —
	# an enumeration bug that skipped a whole kit would agree with itself.
	var on_disk: int = _count_glbs_on_disk()
	print("   %d .glb file(s) on disk under assets/*/exports/" % on_disk)
	check(found == on_disk,
		"the warm pass enumerated exactly the GLBs on disk (%d found, %d on disk)" % [found, on_disk])


func _count_glbs_on_disk() -> int:
	var total: int = 0
	var root_dir := DirAccess.open("res://assets")
	if root_dir == null:
		return 0
	for kit: String in root_dir.get_directories():
		var exports := DirAccess.open("res://assets/%s/exports" % kit)
		if exports == null:
			continue
		for file: String in exports.get_files():
			if file.ends_with(".glb"):
				total += 1
	return total


# ── 2. the draw loop actually runs ────────────────────────────────────────────────────────────────


## Driven through `force_complete_now()` rather than by waiting out the real pacing, so the check
## measures the work rather than the frame budget the work is deliberately spread across.
func _check_draws_every_asset() -> void:
	print("\n== F-516: every enumerated asset is instantiated and drawn once ==")
	var expected: int = int(warmer.call("pending_asset_count"))
	await warmer.call("force_complete_now")
	var warmed: int = int(warmer.call("warmed_asset_count"))
	print("   warmed %d of %d" % [warmed, expected])
	# Not `==`: a GLB that instantiates to something other than a Node3D is skipped deliberately
	# (see `_draw_completed`), and an asset failing to load is a fault in that asset, not here. The
	# assertion is that essentially all of them go through, so a systematic failure — a wrong path
	# shape, a load that never completes — cannot pass as a handful of odd files.
	check(warmed >= int(float(expected) * 0.95),
		"at least 95%% of enumerated assets were instantiated and drawn (%d of %d)" % [warmed, expected])
	check(warmed > 0, "the warm pass drew anything at all")


# ── 3. nothing stays resident ─────────────────────────────────────────────────────────────────────


## A one-shot cost that leaves a SubViewport on UPDATE_ALWAYS behind is a permanent per-frame cost
## added by a performance fix, which is worse than the problem it solves.
func _check_teardown() -> void:
	print("\n== F-516: the warm rig frees itself when it is done ==")
	check(bool(warmer.call("is_finished")), "the warm pass reports itself finished")
	var live_viewports: int = 0
	for node: Node in warmer.get_children():
		if node is SubViewport and is_instance_valid(node) and not node.is_queued_for_deletion():
			live_viewports += 1
	check(live_viewports == 0,
		"no SubViewport is left rendering after the pass (%d still live)" % live_viewports)
	check(not warmer.is_processing(),
		"the warmer stops processing once finished, so it costs nothing for the rest of the session")


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)
