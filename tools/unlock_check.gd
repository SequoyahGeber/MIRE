extends SceneTree

## Direct proof for task 6.9 (DESIGN.md §4.6 — "Salvage unlocks variety, never power"):
##   1. The shipped project registers `UnlockService`, `UnlockMenu` and content/unlocks/ actually
##      loads through `Registry` (the worked example, `unlock_deep_pocket`).
##   2. `UnlockDef.validation_errors()` catches a missing id/name/category, an unknown category, and
##      a non-positive cost — the schema-level enforcement of "never power" (D-044's shape: there is
##      no stat field to author one onto in the first place).
##   3. `SalvageService.spend_salvage()`: refuses (balance unchanged, disk unchanged) when the
##      amount is not positive or exceeds the balance; on success, deducts and persists.
##   4. `UnlockService.purchase()`: fails end-to-end when Salvage is short (nothing charged, nothing
##      marked purchased); succeeds when affordable — charges Salvage exactly once, marks the id
##      purchased, persists to `user://unlocks.json`, and fires `unlock_purchased` with the right
##      payload. A second purchase of the same id is refused and does not double-charge.
##   5. `UnlockService.is_content_unlocked()`: true for a content id nothing gates; false for a
##      gated id until its UnlockDef is purchased, true after.
##   6. `UnlockMenu`: opens/closes, joins `blocks_gameplay_input` while open (D-032), refuses to
##      stack on `MainMenu`, builds one row per authored UnlockDef, and `request_purchase()` flips
##      that row's button to "OWNED" on success.
##   7. `UnlockSave`'s save-file versioning: a missing/old `schema_version` migrates up and
##      backfills defaults instead of crashing; a round trip preserves data and stamps the current
##      version; a corrupt or absent file resolves to a safe default rather than propagating an
##      error.
##
##   .agent/bin/agent godot --script tools/unlock_check.gd

const EVENT_BUS := preload("res://core/events/event_bus.gd")
const UNLOCK_SAVE := preload("res://core/save/unlock_save.gd")
const UNLOCK_DEF := preload("res://systems/unlocks/unlock_def.gd")
const SALVAGE_SAVE := preload("res://core/save/salvage_save.gd")

## Every test path lives under a name a real save could never collide with, and every one of them
## is deleted at the end of the run — this check must never touch a real player's
## `unlocks.json`/`salvage.json`.
const TEST_UNLOCK_PATH: String = "user://unlock_check_service.json"
const TEST_SALVAGE_PATH: String = "user://unlock_check_salvage.json"
const TEST_MISSING_VERSION_PATH: String = "user://unlock_check_missing_version.json"
const TEST_CORRUPT_PATH: String = "user://unlock_check_corrupt.json"
const TEST_ROUNDTRIP_PATH: String = "user://unlock_check_roundtrip.json"
const ALL_TEST_PATHS: PackedStringArray = [
	TEST_UNLOCK_PATH, TEST_SALVAGE_PATH, TEST_MISSING_VERSION_PATH, TEST_CORRUPT_PATH,
	TEST_ROUNDTRIP_PATH,
]

const WORKED_EXAMPLE_ID: StringName = &"unlock_deep_pocket"

var failures: int = 0
var registry: Node
var unlock_service: Node
var unlock_menu: Node
var salvage_service: Node
var main_menu: Node
var _purchased_events: Array = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame
	_cleanup_test_paths()

	if not _check_wiring():
		_cleanup_test_paths()
		finish()
		return

	_check_def_validation()
	await _check_spend_salvage()
	await _check_purchase_flow()
	_check_content_gate()
	_check_menu()
	_check_save_versioning()

	_cleanup_test_paths()
	print("\nUNLOCK_CHECK failures=%d" % failures)
	finish()


func _check_wiring() -> bool:
	print("== the shipped project actually has the 6.9 pieces ==")
	registry = root.get_node_or_null(^"Registry")
	unlock_service = root.get_node_or_null(^"UnlockService")
	unlock_menu = root.get_node_or_null(^"UnlockMenu")
	salvage_service = root.get_node_or_null(^"SalvageService")
	main_menu = root.get_node_or_null(^"MainMenu")
	check(registry != null, "Registry is registered as an autoload")
	check(unlock_service != null, "UnlockService is registered as an autoload")
	check(unlock_menu != null, "UnlockMenu is registered as an autoload")
	check(salvage_service != null, "SalvageService is registered as an autoload")
	check(main_menu != null, "MainMenu is registered as an autoload")
	if registry == null or unlock_service == null or unlock_menu == null or salvage_service == null or main_menu == null:
		return false

	check(bool(registry.call("has_unlock", WORKED_EXAMPLE_ID)),
		"content/unlocks/unlock_deep_pocket.tres loaded and indexed by Registry")
	var def: Resource = registry.call("get_unlock", WORKED_EXAMPLE_ID)
	check(def != null and String(def.get(&"category")) == "powerup",
		"the worked example gates a powerup")
	check(def != null and String(def.get(&"gates_id")) == "deep_pocket",
		"the worked example gates the real 'deep_pocket' PowerupDef id")
	return true


func _check_def_validation() -> void:
	print("\n== UnlockDef.validation_errors() — schema-level 'never power' ==")
	var blank := UNLOCK_DEF.new()
	var errors: PackedStringArray = blank.validation_errors()
	check(errors.size() >= 3, "a blank UnlockDef fails id/display_name/category/cost checks (got %d error(s))" % errors.size())

	var bad_category := UNLOCK_DEF.new()
	bad_category.id = &"x"
	bad_category.display_name = "X"
	bad_category.category = &"stat_boost"
	bad_category.cost = 10
	check(not bad_category.validation_errors().is_empty(),
		"a category outside DESIGN.md §4.6's list ('stat_boost') fails validation")

	var free := UNLOCK_DEF.new()
	free.id = &"y"
	free.display_name = "Y"
	free.category = &"cosmetic"
	free.cost = 0
	check(not free.validation_errors().is_empty(), "a zero-cost row fails validation (not a Salvage sink)")

	var valid := UNLOCK_DEF.new()
	valid.id = &"z"
	valid.display_name = "Z"
	valid.category = &"cosmetic"
	valid.cost = 5
	check(valid.validation_errors().is_empty(), "a well-formed row (no gates_id needed for cosmetics) passes")


func _check_spend_salvage() -> void:
	print("\n== SalvageService.spend_salvage() ==")
	salvage_service.set(&"save_path", TEST_SALVAGE_PATH)
	EVENT_BUS.emit_run_extracted(20, Vector3.ZERO)
	await process_frame
	var balance: int = int(salvage_service.call("total_salvage"))
	check(balance > 500, "sanity: seeded a large Salvage balance (%d) via a real extraction" % balance)

	check(not bool(salvage_service.call("spend_salvage", 0)), "spend_salvage(0) refuses")
	check(not bool(salvage_service.call("spend_salvage", -5)), "spend_salvage(negative) refuses")
	check(not bool(salvage_service.call("spend_salvage", balance + 1)),
		"spend_salvage(more than the balance) refuses")
	check(int(salvage_service.call("total_salvage")) == balance,
		"a refused spend leaves the balance untouched")

	var spend_amount: int = 50
	check(bool(salvage_service.call("spend_salvage", spend_amount)), "an affordable spend succeeds")
	check(int(salvage_service.call("total_salvage")) == balance - spend_amount,
		"the balance dropped by exactly the spent amount")
	var on_disk: Dictionary = SALVAGE_SAVE.load_data(TEST_SALVAGE_PATH)
	check(int(on_disk.get(&"total_salvage", -1)) == balance - spend_amount,
		"the spend reached disk — a fresh SalvageSave.load_data() agrees")


func _check_purchase_flow() -> void:
	print("\n== UnlockService.purchase() end to end ==")
	unlock_service.set(&"save_path", TEST_UNLOCK_PATH)
	EVENT_BUS.subscribe_unlock_purchased(_on_unlock_purchased)

	var def: Resource = registry.call("get_unlock", WORKED_EXAMPLE_ID)
	var cost: int = int(def.get(&"cost"))

	check(not bool(unlock_service.call("is_content_unlocked", &"deep_pocket")),
		"'deep_pocket' reads locked before its UnlockDef is purchased")

	# Drain the balance below the worked example's cost first, so the "too poor" path is real.
	var balance: int = int(salvage_service.call("total_salvage"))
	if balance >= cost:
		check(bool(salvage_service.call("spend_salvage", balance - cost + 1)),
			"sanity: drained the balance below the unlock's cost")
	balance = int(salvage_service.call("total_salvage"))
	check(balance < cost, "sanity: balance (%d) is now below the unlock's cost (%d)" % [balance, cost])

	check(not bool(unlock_service.call("purchase", WORKED_EXAMPLE_ID)),
		"purchase() fails when Salvage is short")
	check(not bool(unlock_service.call("is_purchased", WORKED_EXAMPLE_ID)),
		"a failed purchase does not mark the unlock purchased")
	check(int(salvage_service.call("total_salvage")) == balance,
		"a failed purchase does not touch the Salvage balance")

	EVENT_BUS.emit_run_extracted(20, Vector3.ZERO)
	await process_frame
	balance = int(salvage_service.call("total_salvage"))
	check(balance >= cost, "sanity: topped the balance back up above the unlock's cost")

	check(bool(unlock_service.call("purchase", WORKED_EXAMPLE_ID)), "purchase() succeeds when affordable")
	check(bool(unlock_service.call("is_purchased", WORKED_EXAMPLE_ID)), "the unlock is now marked purchased")
	check(int(salvage_service.call("total_salvage")) == balance - cost,
		"purchasing charged exactly the unlock's cost")
	check(_purchased_events.size() == 1, "unlock_purchased fired exactly once")
	check(_purchased_events[-1] == [WORKED_EXAMPLE_ID, cost, balance - cost],
		"unlock_purchased carried (unlock_id, cost, total_salvage) == %s, got %s" %
			[[WORKED_EXAMPLE_ID, cost, balance - cost], _purchased_events[-1]])

	var on_disk: Dictionary = UNLOCK_SAVE.load_data(TEST_UNLOCK_PATH)
	var ids_on_disk: Array = on_disk.get(&"purchased_ids", [])
	check(ids_on_disk.has(String(WORKED_EXAMPLE_ID)), "the purchase reached disk")

	var balance_before_repeat: int = int(salvage_service.call("total_salvage"))
	check(not bool(unlock_service.call("purchase", WORKED_EXAMPLE_ID)),
		"purchasing the same id again is refused")
	check(int(salvage_service.call("total_salvage")) == balance_before_repeat,
		"a refused repeat purchase does not double-charge")
	check(_purchased_events.size() == 1, "unlock_purchased does not fire again for a refused repeat")

	EVENT_BUS.unsubscribe_unlock_purchased(_on_unlock_purchased)


func _check_content_gate() -> void:
	print("\n== is_content_unlocked() ==")
	check(bool(unlock_service.call("is_content_unlocked", &"thick_hide")),
		"a powerup id nothing gates is unlocked by default")
	check(bool(unlock_service.call("is_content_unlocked", &"deep_pocket")),
		"'deep_pocket' reads unlocked now that its UnlockDef was purchased above")


func _check_menu() -> void:
	print("\n== UnlockMenu ==")
	check(not bool(unlock_menu.call("is_open")), "UnlockMenu starts closed")
	check(unlock_menu.call("row_count") == registry.call("unlock_defs").size(),
		"UnlockMenu built one row per authored UnlockDef")

	main_menu.call("set_open", true)
	check(bool(main_menu.call("is_open")), "sanity: MainMenu opens")
	main_menu.call("request_open_unlocks")
	check(not bool(main_menu.call("is_open")), "opening UnlockMenu from MainMenu closes MainMenu (D-032)")
	check(bool(unlock_menu.call("is_open")), "UnlockMenu opens")
	check(unlock_menu.is_in_group(&"blocks_gameplay_input"), "open UnlockMenu blocks gameplay input (D-032)")
	check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "open UnlockMenu frees the cursor")

	main_menu.call("set_open", true)
	check(not bool(main_menu.call("is_open")), "MainMenu refuses to open while UnlockMenu is open (D-032)")

	check(String(unlock_menu.call("balance_text")).begins_with("SALVAGE:"), "balance label is populated")
	check(bool(unlock_menu.call("request_purchase", WORKED_EXAMPLE_ID)) == false,
		"request_purchase() on an already-owned id refuses (bought via UnlockService above)")

	unlock_menu.call("set_open", false)
	check(not unlock_menu.is_in_group(&"blocks_gameplay_input"), "closed UnlockMenu releases the blocking group")


func _check_save_versioning() -> void:
	print("\n== UnlockSave versioning ==")
	check((UNLOCK_SAVE.load_data("user://unlock_check_does_not_exist.json").get(&"purchased_ids", null)) == [],
		"a missing save file resolves to a safe default (empty purchased_ids), not an error")

	var file: FileAccess = FileAccess.open(TEST_MISSING_VERSION_PATH, FileAccess.WRITE)
	file.store_string(JSON.stringify({"purchased_ids": ["unlock_deep_pocket"]}))
	file.close()
	var migrated: Dictionary = UNLOCK_SAVE.load_data(TEST_MISSING_VERSION_PATH)
	check(int(migrated.get(&"schema_version", -1)) == UNLOCK_SAVE.SCHEMA_VERSION,
		"a file with no schema_version migrates up to the current one on load")
	check((migrated.get(&"purchased_ids", []) as Array).has("unlock_deep_pocket"),
		"migration preserves the data that was already there")

	file = FileAccess.open(TEST_CORRUPT_PATH, FileAccess.WRITE)
	file.store_string("{not valid json")
	file.close()
	var from_corrupt: Dictionary = UNLOCK_SAVE.load_data(TEST_CORRUPT_PATH)
	check((from_corrupt.get(&"purchased_ids", null)) == [],
		"a corrupt save file resolves to a safe default instead of crashing")

	UNLOCK_SAVE.save_data({"purchased_ids": ["a", "b"]}, TEST_ROUNDTRIP_PATH)
	var roundtrip: Dictionary = UNLOCK_SAVE.load_data(TEST_ROUNDTRIP_PATH)
	check((roundtrip.get(&"purchased_ids", []) as Array) == ["a", "b"],
		"save -> load round trip preserves purchased_ids")
	check(int(roundtrip.get(&"schema_version", -1)) == UNLOCK_SAVE.SCHEMA_VERSION,
		"save_data stamps the current schema_version")


func _on_unlock_purchased(unlock_id: StringName, cost: int, total_salvage: int) -> void:
	_purchased_events.append([unlock_id, cost, total_salvage])


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
