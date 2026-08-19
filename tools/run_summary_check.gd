extends SceneTree

## Direct proof for task 6.8: `ui/hud/defeat_hud.gd`'s run summary — headline Cycle number,
## modifiers drawn, Salvage earned — driven through the REAL chain, not a mock (the same
## `cycle_modifier_check.gd`/F-068 convention docs/SPECS.md's own preamble points at):
## `DefeatService.net_run_defeated()` -> `EventBus.run_wiped` -> `SalvageService` banks ->
## `EventBus.salvage_banked` -> `DefeatHud`. Single-process, offline (host-of-one), same shape
## `cycle_modifier_check.gd`/`defeat_check.gd` already use.
##
## Also the regression proof for F-235: `_on_salvage_banked`'s old `not _shown` guard silently
## dropped the real banked number, because `SalvageService` subscribes to `run_wiped` before
## `DefeatHud` does (autoload order) and its `salvage_banked` emit fires synchronously INSIDE
## `EventBus.emit_run_wiped()`, before `DefeatHud._on_run_wiped` has set `_shown`. This check fails
## on the old guard (`_detail.text` would still read the "Tallying Salvage…" placeholder) and passes
## on the `_salvage_known` fix.
##
## F-238 extended this file with the mirror-image chain for the SUCCESS path:
## `EventBus.emit_run_extracted()` (the same direct shortcut `salvage_check.gd` already takes,
## since a real `ExtractionShip` departure needs a scene this bare harness doesn't have) ->
## `SalvageService` banks -> `EventBus.salvage_banked` -> `ui/hud/extraction_hud.gd`'s own summary
## overlay, which task 6.8 explicitly did not build (see this file's original header, and
## docs/FINDINGS.md F-238).
##
##   .agent/bin/agent godot --script tools/run_summary_check.gd
##
## `SalvageService._persistence_enabled()` (D-107) is false by default in a bare `--script`
## harness (no scene ever loaded, default `save_path`) — exactly the guard that stops an unrelated
## check's own real `run_wiped` traffic from banking into a developer's actual save. Proving the
## real chain here needs a real bank, so this check overrides `save_path` to a throwaway file the
## same way `salvage_check.gd` already does, and deletes it on the way out.

const EVENT_BUS := preload("res://core/events/event_bus.gd")
const TEST_SAVE_PATH: String = "user://run_summary_check_salvage.json"

var failures: int = 0
var defeat_hud: Node
var defeat_service: Node
var cycle_modifier_service: Node
var salvage_service: Node
var extraction_hud: Node


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame

	if not _check_wiring():
		_cleanup()
		finish()
		return

	_check_no_draw_yet()
	_check_one_modifier_drawn()
	_check_full_defeat_chain()
	_check_second_defeat_is_a_no_op()
	_check_salvage_banked_guards()
	_check_full_extraction_chain()
	_check_second_extraction_is_a_no_op()
	_check_extraction_salvage_banked_guards()

	_cleanup()
	print("\nRUN_SUMMARY_CHECK failures=%d" % failures)
	finish()


func _check_wiring() -> bool:
	print("== the shipped project actually wires DefeatHud/DefeatService/CycleModifierService ==")
	defeat_hud = root.get_node_or_null(^"DefeatHud")
	defeat_service = root.get_node_or_null(^"DefeatService")
	cycle_modifier_service = root.get_node_or_null(^"CycleModifierService")
	salvage_service = root.get_node_or_null(^"SalvageService")
	extraction_hud = root.get_node_or_null(^"ExtractionHud")
	check(defeat_hud != null, "DefeatHud is registered as an autoload")
	check(defeat_service != null, "DefeatService is registered as an autoload")
	check(cycle_modifier_service != null, "CycleModifierService is registered as an autoload")
	check(salvage_service != null, "SalvageService is registered as an autoload")
	check(extraction_hud != null, "ExtractionHud is registered as an autoload")
	if salvage_service != null:
		salvage_service.set(&"save_path", TEST_SAVE_PATH)
	return defeat_hud != null and defeat_service != null and cycle_modifier_service != null \
		and salvage_service != null and extraction_hud != null


func _cleanup() -> void:
	var abs_path: String = ProjectSettings.globalize_path(TEST_SAVE_PATH)
	if FileAccess.file_exists(abs_path):
		DirAccess.remove_absolute(abs_path)


## Boot state: nothing has drawn yet (CycleService starts at Cycle 1, no `cycle_advanced` has fired
## in this bare harness), so the "modifiers drawn" line reads the real empty-deck case, not a blank
## string or a crash.
func _check_no_draw_yet() -> void:
	print("\n== no Cycle Modifier drawn yet ==")
	var ids: Array = cycle_modifier_service.call(&"active_modifier_ids")
	check(ids.is_empty(), "fresh boot has drawn no modifiers")
	var summary: String = String(defeat_hud.call(&"_modifiers_drawn_summary"))
	check(summary == "Modifiers drawn: none", "the summary line reads 'none': '%s'" % summary)


## `content/cycle_modifiers/long_night.tres` is the one worked example (task 6.2/6.3), `min_cycle =
## 2`, so drawing at Cycle 2 is guaranteed to succeed and to pick it (it is the only eligible def).
func _check_one_modifier_drawn() -> void:
	print("\n== drawing the worked-example modifier ==")
	var drawn_id: StringName = StringName(cycle_modifier_service.call(&"host_draw_modifier", 2))
	check(drawn_id == &"long_night", "the deck's one eligible def draws: got '%s'" % drawn_id)
	var summary: String = String(defeat_hud.call(&"_modifiers_drawn_summary"))
	check(summary.begins_with("Modifiers drawn: "), "the summary line still has its own label: '%s'" % summary)
	check(summary.contains("Long Night"), "and names the def by display_name, not the raw id: '%s'" % summary)


## The real chain: `net_run_defeated` is the code path an actual client takes (not the host's own
## `_trigger_defeat`), the same shortcut `defeat_check.gd` already takes to prove D-108's requirement
## without standing up a second process. This is also the F-235 regression proof — see this file's
## own header.
func _check_full_defeat_chain() -> void:
	print("\n== the real run_wiped -> salvage_banked -> DefeatHud chain ==")
	defeat_service.call(&"net_run_defeated", "team_wipe", 5, Vector3.ZERO)

	check(bool(defeat_service.call(&"is_defeated")), "DefeatService latches defeated")
	check(String(defeat_service.get(&"cause")) == "team_wipe", "and records the cause")

	var headline: Label = defeat_hud.get(&"_headline") as Label
	var cause_label: Label = defeat_hud.get(&"_cause_label") as Label
	var modifiers_label: Label = defeat_hud.get(&"_modifiers_label") as Label
	var detail: Label = defeat_hud.get(&"_detail") as Label
	var overlay: ColorRect = defeat_hud.get(&"_overlay") as ColorRect
	check(headline != null and cause_label != null and modifiers_label != null and detail != null
		and overlay != null, "DefeatHud built every label the summary needs")
	if headline == null or cause_label == null or modifiers_label == null or detail == null or overlay == null:
		return

	check(headline.text == "CYCLE 5", "the headline names the Cycle reached: '%s'" % headline.text)
	check(cause_label.text == "THE CREW HAS FALLEN", "the cause line reads the team-wipe headline: '%s'" % cause_label.text)
	check(modifiers_label.text.contains("Long Night"), "the stats block still names the drawn modifier: '%s'" % modifiers_label.text)
	check(overlay.visible, "the overlay shows")
	check(defeat_hud.is_in_group(&"blocks_gameplay_input"), "and blocks gameplay input (D-032)")

	# F-235: the old `not _shown` guard silently dropped this — SalvageService's `salvage_banked`
	# emit fires synchronously inside `emit_run_wiped()`, before `_on_run_wiped` sets `_shown`.
	check(detail.text.begins_with("Salvage earned: "), "F-235 fixed: the real banked number reached the screen, not the placeholder: '%s'" % detail.text)
	check(not detail.text.contains("Tallying"), "the placeholder never survives to the final paint: '%s'" % detail.text)


## `_apply_defeat()` is terminal — a second `net_run_defeated` call must change nothing, and must not
## re-fire `run_wiped` (which would double-bank Salvage). Mirrors `defeat_check.gd`'s own "a second
## tick fires no more" assertion, one layer up at the HUD.
func _check_second_defeat_is_a_no_op() -> void:
	print("\n== a second defeat verdict is a no-op (terminal, D-109) ==")
	var headline: Label = defeat_hud.get(&"_headline") as Label
	var before: String = headline.text
	defeat_service.call(&"net_run_defeated", "island_consumed", 99, Vector3.ONE)
	check(String(defeat_service.get(&"cause")) == "team_wipe", "cause does not change after the verdict latches")
	check(headline.text == before, "and the summary screen does not repaint: '%s'" % headline.text)


## Regression proof for the `_salvage_known` fix's own idempotency: `extracted == true` is still
## ignored (6.5's success path, not this screen's), and a second non-extracted bank does not
## clobber the first real number with a different one.
func _check_salvage_banked_guards() -> void:
	print("\n== _on_salvage_banked's guards hold after the fix ==")
	var detail: Label = defeat_hud.get(&"_detail") as Label
	var before: String = detail.text
	defeat_hud.call(&"_on_salvage_banked", 999, 9999, 5, true)
	check(detail.text == before, "an extracted bank (6.5's own path) never overwrites the death screen: '%s'" % detail.text)
	defeat_hud.call(&"_on_salvage_banked", 111, 222, 5, false)
	check(detail.text == before, "a second non-extracted bank does not clobber the first real number: '%s'" % detail.text)


## F-238: the mirror-image real chain for a successful extraction — `emit_run_extracted` is the
## same direct shortcut `salvage_check.gd` already takes to prove SalvageService's own extraction
## path, since standing up a real `ExtractionShip`/departure hold needs a live scene this bare
## harness doesn't have. Cycle 7 (distinct from the defeat chain's Cycle 5 above) so a mixed-up
## assertion between the two screens would fail loudly rather than coincidentally match.
func _check_full_extraction_chain() -> void:
	print("\n== the real run_extracted -> salvage_banked -> ExtractionHud chain ==")
	EVENT_BUS.emit_run_extracted(7, Vector3(10.0, 0.0, 10.0))

	var headline: Label = extraction_hud.get(&"_summary_headline") as Label
	var subtitle: Label = extraction_hud.get(&"_summary_subtitle") as Label
	var modifiers_label: Label = extraction_hud.get(&"_summary_modifiers_label") as Label
	var detail: Label = extraction_hud.get(&"_summary_detail") as Label
	var overlay: ColorRect = extraction_hud.get(&"_summary_overlay") as ColorRect
	check(headline != null and subtitle != null and modifiers_label != null and detail != null
		and overlay != null, "ExtractionHud built every label the summary needs")
	if headline == null or subtitle == null or modifiers_label == null or detail == null or overlay == null:
		return

	check(headline.text == "CYCLE 7", "the headline names the Cycle reached: '%s'" % headline.text)
	check(subtitle.text == "EXTRACTED SAFELY", "the subtitle reads success, not a death cause: '%s'" % subtitle.text)
	check(modifiers_label.text.contains("Long Night"), "the stats block still names the drawn modifier: '%s'" % modifiers_label.text)
	check(overlay.visible, "the overlay shows")
	check(extraction_hud.is_in_group(&"blocks_gameplay_input"), "and blocks gameplay input (D-032)")

	# Mirrors the F-235 regression proof one layer up: the real banked number must reach the
	# screen, not the "Tallying Salvage…" placeholder, regardless of which of the two signals
	# (`run_extracted`, `salvage_banked`) this file's own subscriber order makes land first.
	check(detail.text.begins_with("Salvage earned: "), "the real banked number reached the screen, not the placeholder: '%s'" % detail.text)
	check(not detail.text.contains("Tallying"), "the placeholder never survives to the final paint: '%s'" % detail.text)


## Terminal, like the death screen (D-109) — proves `ExtractionHud._summary_shown` itself, not
## `ExtractionShip.departed`'s own once-only setter (that guard already stops a real second
## `run_extracted` at the source; this check fires the bus event directly, the same
## `salvage_check.gd` shortcut this whole file uses, specifically to exercise the HUD's own guard
## in isolation).
func _check_second_extraction_is_a_no_op() -> void:
	print("\n== a second extraction verdict is a no-op (terminal, D-109) ==")
	var headline: Label = extraction_hud.get(&"_summary_headline") as Label
	var before: String = headline.text
	EVENT_BUS.emit_run_extracted(99, Vector3.ONE)
	check(headline.text == before, "the summary screen does not repaint: '%s'" % headline.text)


## Regression proof for `ExtractionHud`'s own `_salvage_known` idempotency, mirroring
## `_check_salvage_banked_guards()` above: `extracted == false` is `DefeatHud`'s own path and must
## never reach this screen, and a second `extracted == true` bank does not clobber the first number.
func _check_extraction_salvage_banked_guards() -> void:
	print("\n== ExtractionHud's own _on_salvage_banked guards hold ==")
	var detail: Label = extraction_hud.get(&"_summary_detail") as Label
	var before: String = detail.text
	extraction_hud.call(&"_on_salvage_banked", 999, 9999, 7, false)
	check(detail.text == before, "a death bank (DefeatHud's own path) never overwrites the extraction screen: '%s'" % detail.text)
	extraction_hud.call(&"_on_salvage_banked", 111, 222, 7, true)
	check(detail.text == before, "a second extracted bank does not clobber the first real number: '%s'" % detail.text)


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
