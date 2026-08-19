extends SceneTree

## Direct proof for task 6.6:
##   1. The shipped project actually registers `SalvageService` as an autoload.
##   2. The reward curve is superlinear in Cycle (Cycle 9 worth much more than 3x Cycle 3).
##   3. Wellsprings capped this run add a milestone bonus on top of the Cycle curve, and the tally
##      resets once a run ends (banked or not).
##   4. `run_extracted` banks the FULL reward; `run_wiped` banks only `DEATH_BANK_FRACTION` of it —
##      DESIGN.md §5.2's "extracting banks it all; dying banks a fraction."
##   5. Every bank writes through to `user://` — the balance a fresh `SalvageSave.load_data()` call
##      sees on disk matches what `SalvageService.total_salvage()` reports in memory.
##   6. `EventBus.emit_salvage_banked` fires once per bank with the right `earned`/`total`/`cycle`/
##      `extracted` payload — the seam task 6.8's run summary builds from.
##   7. `SalvageSave`'s save-file versioning: a missing/old `schema_version` migrates up and backfills
##      defaults instead of crashing; a round trip preserves data and stamps the current version; a
##      corrupt or absent file resolves to a safe default rather than propagating an error.
##
##   .agent/bin/agent godot --script tools/salvage_check.gd

const EVENT_BUS := preload("res://core/events/event_bus.gd")
const SALVAGE_SAVE := preload("res://core/save/salvage_save.gd")

## Every test path lives under a name a real save could never collide with, and every one of them is
## deleted at the end of the run — this check must never touch a real player's `salvage.json`.
const TEST_SAVE_PATH: String = "user://salvage_check_service.json"
const TEST_MISSING_VERSION_PATH: String = "user://salvage_check_missing_version.json"
const TEST_CORRUPT_PATH: String = "user://salvage_check_corrupt.json"
const TEST_ROUNDTRIP_PATH: String = "user://salvage_check_roundtrip.json"
const ALL_TEST_PATHS: PackedStringArray = [
	TEST_SAVE_PATH, TEST_MISSING_VERSION_PATH, TEST_CORRUPT_PATH, TEST_ROUNDTRIP_PATH,
]

var failures: int = 0
var salvage_service: Node
var _banked_events: Array = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	_cleanup_test_paths()

	if not _check_wiring():
		_cleanup_test_paths()
		finish()
		return

	_check_reward_curve()
	_check_milestone_bonus()
	await _check_banking()
	_check_save_versioning()

	_cleanup_test_paths()
	# Standing rule 4 (docs/SPECS.md): declare provoked errors by pattern rather than silencing
	# them — same two lines unlock_check declares for the same corrupt-save fixture (F-182/F-193).
	print("\nSALVAGE_CHECK failures=%d · EXPECTED_ERROR_PATTERNS=\"Parse JSON failed|did not contain a JSON object\"" % failures)
	finish()


func _check_wiring() -> bool:
	print("== the shipped project actually has SalvageService ==")
	salvage_service = root.get_node_or_null(^"SalvageService")
	check(salvage_service != null, "SalvageService is registered as an autoload")
	return salvage_service != null


func _check_reward_curve() -> void:
	print("\n== superlinear reward curve ==")
	# Fresh process, no wellspring_capped events fired yet -> milestone bonus is 0 for both reads,
	# so this isolates the Cycle curve itself.
	check(int(salvage_service.call(&"wellsprings_capped_this_run")) == 0,
		"sanity: no milestones banked yet this run")
	var cycle_3: int = int(salvage_service.call(&"reward_for_cycle", 3))
	var cycle_9: int = int(salvage_service.call(&"reward_for_cycle", 9))
	check(cycle_9 > cycle_3 * 3,
		"Cycle 9's reward (%d) is worth more than 3x Cycle 3's (%d, 3x=%d) — DESIGN.md §5.2" %
			[cycle_9, cycle_3, cycle_3 * 3])
	var cycle_1: int = int(salvage_service.call(&"reward_for_cycle", 1))
	var cycle_2: int = int(salvage_service.call(&"reward_for_cycle", 2))
	check(cycle_2 - cycle_1 < cycle_9 - int(salvage_service.call(&"reward_for_cycle", 8)),
		"the Cycle-to-Cycle step grows as Cycle rises (curve is convex, not linear)")
	check(int(salvage_service.call(&"reward_for_cycle", 0)) == int(salvage_service.call(&"reward_for_cycle", 1)),
		"Cycle 0 (pre-run) clamps to the same floor as Cycle 1, never a negative or zero reward")


func _check_milestone_bonus() -> void:
	print("\n== milestone bonus (Wellsprings capped this run) ==")
	var before: int = int(salvage_service.call(&"reward_for_cycle", 5))
	EVENT_BUS.emit_wellspring_capped(&"CheckWellspring", Vector3.ZERO)
	check(int(salvage_service.call(&"wellsprings_capped_this_run")) == 1,
		"one wellspring_capped event -> milestone tally is 1")
	var after_one: int = int(salvage_service.call(&"reward_for_cycle", 5))
	check(after_one > before, "capping a Wellspring raises the reward for the same Cycle")
	EVENT_BUS.emit_wellspring_capped(&"CheckWellspring2", Vector3.ZERO)
	check(int(salvage_service.call(&"wellsprings_capped_this_run")) == 2,
		"a second wellspring_capped event -> milestone tally is 2")
	var after_two: int = int(salvage_service.call(&"reward_for_cycle", 5))
	check(after_two - after_one == after_one - before,
		"each capped Wellspring adds the same flat bonus (WELLSPRING_CAP_BONUS)")


func _check_banking() -> void:
	print("\n== extract-vs-die split + persistence ==")
	salvage_service.set(&"save_path", TEST_SAVE_PATH)
	EVENT_BUS.subscribe_salvage_banked(_on_salvage_banked)

	print("-- extraction banks the full reward --")
	# 2 Wellsprings already capped from the milestone check above -> part of THIS run's payout.
	var expected_full: int = int(salvage_service.call(&"reward_for_cycle", 6))
	EVENT_BUS.emit_run_extracted(6, Vector3(10.0, 0.0, 10.0))
	await process_frame
	check(int(salvage_service.call(&"total_salvage")) == expected_full,
		"total_salvage after extraction == the full Cycle-6 reward (%d)" % expected_full)
	check(int(salvage_service.call(&"wellsprings_capped_this_run")) == 0,
		"the milestone tally resets once a run ends")
	check(_banked_events.size() == 1, "salvage_banked fired exactly once")
	check(_banked_events[-1] == [expected_full, expected_full, 6, true],
		"salvage_banked carried (earned, total, cycle, extracted=true) == %s, got %s" %
			[[expected_full, expected_full, 6, true], _banked_events[-1]])

	var on_disk: Dictionary = SALVAGE_SAVE.load_data(TEST_SAVE_PATH)
	check(int(on_disk.get(&"total_salvage", -1)) == expected_full,
		"the write actually reached disk — a fresh SalvageSave.load_data() agrees")

	print("-- dying banks only DEATH_BANK_FRACTION of the reward --")
	EVENT_BUS.emit_wellspring_capped(&"CheckWellspring3", Vector3.ZERO)
	var expected_death_full: int = int(salvage_service.call(&"reward_for_cycle", 4))
	var expected_death_banked: int = int(round(expected_death_full * 0.5))
	var total_before_death: int = int(salvage_service.call(&"total_salvage"))
	EVENT_BUS.emit_run_wiped(4, Vector3(-5.0, 0.0, -5.0))
	await process_frame
	var expected_total_after_death: int = total_before_death + expected_death_banked
	check(int(salvage_service.call(&"total_salvage")) == expected_total_after_death,
		"total_salvage after a wipe == prior total + half the Cycle-4 reward (banked %d of %d)" %
			[expected_death_banked, expected_death_full])
	check(expected_death_banked < expected_death_full,
		"sanity: dying banks strictly less than extracting would have at the same Cycle")
	check(_banked_events.size() == 2, "salvage_banked fired again for the death")
	check(_banked_events[-1][3] == false, "salvage_banked's extracted flag is false for a wipe")

	on_disk = SALVAGE_SAVE.load_data(TEST_SAVE_PATH)
	check(int(on_disk.get(&"total_salvage", -1)) == expected_total_after_death,
		"the death payout also reached disk")

	EVENT_BUS.unsubscribe_salvage_banked(_on_salvage_banked)


func _check_save_versioning() -> void:
	print("\n== save-file versioning ==")
	check(int(SALVAGE_SAVE.load_data("user://salvage_check_does_not_exist.json").get(&"total_salvage", -1)) == 0,
		"a missing save file resolves to a safe default (total_salvage 0), not an error")

	var file: FileAccess = FileAccess.open(TEST_MISSING_VERSION_PATH, FileAccess.WRITE)
	file.store_string(JSON.stringify({&"total_salvage": 42}))
	file.close()
	var migrated: Dictionary = SALVAGE_SAVE.load_data(TEST_MISSING_VERSION_PATH)
	check(int(migrated.get(&"schema_version", -1)) == SALVAGE_SAVE.SCHEMA_VERSION,
		"a file with no schema_version migrates up to the current one on load")
	check(int(migrated.get(&"total_salvage", -1)) == 42,
		"migration preserves the data that was already there")

	file = FileAccess.open(TEST_CORRUPT_PATH, FileAccess.WRITE)
	file.store_string("{not valid json")
	file.close()
	var from_corrupt: Dictionary = SALVAGE_SAVE.load_data(TEST_CORRUPT_PATH)
	check(int(from_corrupt.get(&"total_salvage", -1)) == 0,
		"a corrupt save file resolves to a safe default instead of crashing")

	SALVAGE_SAVE.save_data({&"total_salvage": 7}, TEST_ROUNDTRIP_PATH)
	var roundtrip: Dictionary = SALVAGE_SAVE.load_data(TEST_ROUNDTRIP_PATH)
	check(int(roundtrip.get(&"total_salvage", -1)) == 7, "save -> load round trip preserves total_salvage")
	check(int(roundtrip.get(&"schema_version", -1)) == SALVAGE_SAVE.SCHEMA_VERSION,
		"save_data stamps the current schema_version")


func _on_salvage_banked(earned: int, total_salvage: int, cycle: int, extracted: bool) -> void:
	_banked_events.append([earned, total_salvage, cycle, extracted])


func _cleanup_test_paths() -> void:
	for path: String in ALL_TEST_PATHS:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
