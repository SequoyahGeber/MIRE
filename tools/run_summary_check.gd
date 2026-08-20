extends SceneTree

## MENU-7 proof (docs/MENU.md §6.2, §11): a run's outcome is recorded once, survives to disk, and
## the summary presents it for all three endings — with the host-only restart F-243 established.
##
## The ordering property is the one worth guarding: a run ending fires TWO events (what happened,
## and what it was worth) whose order depends on autoload order, and the record must come out the
## same either way. Both orders are driven below.
##
## Run with: .agent/bin/agent godot --script tools/run_summary_check.gd

const RunSummaryScreen := preload("res://ui/frontend/run_summary_screen.gd")
const RunRecordSave := preload("res://core/save/run_record_save.gd")
const EVENT_BUS := preload("res://core/events/event_bus.gd")
const MireTheme := preload("res://ui/theme/mire_theme.gd")

## A throwaway path, so this check never overwrites a player's real last-run record.
const TEST_PATH: String = "user://run_summary_check.json"

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame

	var stack: Node = root.get_node_or_null(^"/root/MenuStack")
	var record_service: Node = root.get_node_or_null(^"/root/RunRecord")
	check(stack != null, "MenuStack autoload exists")
	check(record_service != null, "RunRecord autoload exists")
	if stack == null or record_service == null:
		finish()
		return
	stack.call("pop_all")
	record_service.set(&"save_path", TEST_PATH)

	# ── a fresh install reports no run ───────────────────────────────────────────────────────────
	RunRecordSave.save_data(RunRecordSave._default_data(), TEST_PATH)
	check(not bool(record_service.call("has_last_run")),
		"a fresh install has no last run — the title card stays hidden rather than showing Cycle 0")

	# ── recording, and the round trip through disk ───────────────────────────────────────────────
	var written: Dictionary = record_service.call("record", &"extracted", 7, 118)
	check(bool(record_service.call("has_last_run")), "recording a run marks one as having happened")
	var read_back: Dictionary = record_service.call("last_run")
	check(int(read_back.get("cycle", 0)) == 7, "the cycle survives the round trip")
	check(int(read_back.get("salvage_banked", 0)) == 118, "the banked figure survives the round trip")
	check(String(read_back.get("ending", "")) == "extracted", "the ending survives the round trip")
	check(not String(read_back.get("cause_line", "")).is_empty(), "a cause line is recorded")
	check(String(read_back.get("cause_line", "")) == String(written.get("cause_line", "")),
		"the stored cause line is the one that was written, not a re-roll")

	# The same run must always read the same way — a player looking twice must not see their
	# expedition described differently the second time.
	check(RunSummaryScreen != null, "the summary screen script loads")
	var line_a: String = record_service.call("cause_line_for", &"wiped", 4)
	var line_b: String = record_service.call("cause_line_for", &"wiped", 4)
	check(line_a == line_b, "a cause line is deterministic for a given ending and cycle")
	check(record_service.call("cause_line_for", &"extracted", 4) != line_a,
		"different endings read differently")

	# ── the two-event ordering, both ways round ──────────────────────────────────────────────────
	for order: String in ["outcome-first", "bank-first"]:
		RunRecordSave.save_data(RunRecordSave._default_data(), TEST_PATH)
		record_service.set("_pending", {})
		if order == "outcome-first":
			EVENT_BUS.emit_run_wiped(5, Vector3.ZERO)
			check(not bool(record_service.call("has_last_run")),
				"%s: nothing is written until both halves have arrived" % order)
			EVENT_BUS.emit_salvage_banked(29, 500, 5, false)
		else:
			EVENT_BUS.emit_salvage_banked(29, 500, 5, false)
			EVENT_BUS.emit_run_wiped(5, Vector3.ZERO)
		await process_frame

		var result: Dictionary = record_service.call("last_run")
		check(bool(result.get("has_run", false)), "%s: the run is recorded" % order)
		check(int(result.get("cycle", 0)) == 5, "%s: the cycle is right" % order)
		check(int(result.get("salvage_banked", 0)) == 29, "%s: the banked figure is right" % order)
		check(String(result.get("ending", "")) == "wiped", "%s: the ending is right" % order)

	# Recording twice for one boundary must re-derive, never accumulate (D-174/D-177).
	var before: Dictionary = record_service.call("last_run")
	EVENT_BUS.emit_run_wiped(5, Vector3.ZERO)
	EVENT_BUS.emit_salvage_banked(29, 500, 5, false)
	await process_frame
	var after: Dictionary = record_service.call("last_run")
	check(int(after.get("salvage_banked", 0)) == int(before.get("salvage_banked", 0)),
		"a repeated run boundary rewrites the same values rather than accumulating")

	# ── the screen ───────────────────────────────────────────────────────────────────────────────
	for ending: String in ["extracted", "wiped", "consumed"]:
		var screen: Control = RunSummaryScreen.new()
		screen.call("present", {
			"has_run": true, "cycle": 9, "ending": ending,
			"cause_line": record_service.call("cause_line_for", StringName(ending), 9),
			"salvage_banked": 84, "modifiers": ["long_night", "bloom"], "seed": 7,
		})
		stack.call("push", screen, false)
		await process_frame
		await process_frame

		check(String(screen.call("cycle_text")).contains("CYCLE"),
			"%s: the headline is the Cycle number" % ending)
		var text: String = _all_text(screen)
		check(text.contains("84"), "%s: the banked figure is shown" % ending)
		check(text.contains("Long Night"), "%s: the modifiers drawn are shown" % ending)
		check(text.contains("ONE MORE RUN") and text.contains("BACK TO TITLE"),
			"%s: both ways out are offered" % ending)

		# Terminal for the run it describes: Esc must not dismiss it back into a world that ended.
		check(not bool(screen.call("menu_allows_cancel")),
			"%s: Esc does not dismiss the summary" % ending)
		# ...but it is NOT the F-275 trap, because both buttons are real exits and one is focused.
		var focus_target: Control = screen.call("menu_default_focus")
		check(focus_target != null and focus_target.focus_mode == Control.FOCUS_ALL and not focus_target.disabled,
			"%s: focus lands on an enabled way out (not F-275's trap)" % ending)

		# Solo/host: restart is offered.
		check(bool(screen.call("restart_enabled")),
			"%s: a host is offered ONE MORE RUN" % ending)

		check(_minimum_font_size(screen) >= MireTheme.CAPTION,
			"%s: no text falls below the %dpx floor" % [ending, MireTheme.CAPTION])

		stack.call("pop_all")
		screen.free()
		await process_frame

	# The count-up must land on the real number even when skipped immediately.
	var skipped: Control = RunSummaryScreen.new()
	skipped.call("present", {"has_run": true, "cycle": 12, "ending": "wiped", "salvage_banked": 3})
	stack.call("push", skipped, false)
	await process_frame
	skipped.call("_finish_count_up")
	check(String(skipped.call("cycle_text")) == "CYCLE 12",
		"skipping the count-up lands on the real number (got %s)" % String(skipped.call("cycle_text")))
	stack.call("pop_all")
	skipped.free()

	print("RUN_SUMMARY_CHECK failures=%d" % failures)
	finish()


func _all_text(node: Node) -> String:
	var text: String = ""
	if node is Label:
		text += (node as Label).text + " "
	elif node is Button:
		text += (node as Button).text + " "
	for child: Node in node.get_children():
		text += _all_text(child)
	return text


func _minimum_font_size(node: Node) -> int:
	var smallest: int = 9999
	if node is Label:
		var label: Label = node
		if label.has_theme_font_size_override("font_size"):
			smallest = mini(smallest, label.get_theme_font_size(&"font_size"))
	for child: Node in node.get_children():
		smallest = mini(smallest, _minimum_font_size(child))
	return smallest


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
