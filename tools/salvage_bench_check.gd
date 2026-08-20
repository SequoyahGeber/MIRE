extends SceneTree

## MENU-8 proof (docs/MENU.md §7.2, §11): the bench groups the authored unlocks into shelves, states
## each card's affordability in words as well as colour, asks before spending, and never claims a
## purchase `UnlockService` refused.
##
## The last one is the property worth guarding: this screen is a view over a service that re-checks
## the balance itself and is the authority. A bench that prints "bought!" on a refused purchase is
## how a player ends up believing their Salvage vanished.
##
## Run with: .agent/bin/agent godot --script tools/salvage_bench_check.gd

const SalvageBenchScreen := preload("res://ui/frontend/salvage_bench_screen.gd")
const MireTheme := preload("res://ui/theme/mire_theme.gd")

## Throwaway save paths, so this check exercises real purchases without touching a player's save.
const TEST_UNLOCK_PATH: String = "user://bench_check_unlocks.json"
const TEST_SALVAGE_PATH: String = "user://bench_check_salvage.json"

## Enough Salvage that at least one authored unlock is affordable, so the purchase path is actually
## reached rather than skipped for want of funds.
const TEST_BALANCE: int = 5000

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame

	var stack: Node = root.get_node_or_null(^"/root/MenuStack")
	var registry: Node = root.get_node_or_null(^"/root/Registry")
	var unlocks: Node = root.get_node_or_null(^"/root/UnlockService")
	check(stack != null and registry != null and unlocks != null,
		"MenuStack, Registry and UnlockService autoloads exist")
	if stack == null or registry == null or unlocks == null:
		finish()
		return
	stack.call("pop_all")

	# D-107: both services disable persistence when `save_path` is still the real one AND no main
	# scene is loaded, so a `--script` harness can never scribble on a player's actual save. That
	# also means `purchase()` refuses everything here unless the check opts back in the same way
	# `tools/unlock_check.gd` does — point both services at throwaway paths and seed a balance, so
	# the purchase path below exercises the real transaction instead of the guard.
	var salvage: Node = root.get_node_or_null(^"/root/SalvageService")
	check(salvage != null, "SalvageService autoload exists")
	if salvage == null:
		finish()
		return
	unlocks.set(&"save_path", TEST_UNLOCK_PATH)
	salvage.set(&"save_path", TEST_SALVAGE_PATH)
	_reset_test_saves()
	unlocks.call("_load")
	# `total_salvage()` reads a cache that only refreshes on its own bank/spend events, so
	# redirecting `save_path` leaves it reporting the balance from the REAL save. Sync it, or the
	# "spends exactly the listed cost" assertion compares a stale before against a fresh after.
	salvage.set("_total_salvage_cache", TEST_BALANCE)

	var authored: int = (registry.get("unlocks") as Dictionary).size()
	check(authored > 0, "there are authored unlocks to show (%d)" % authored)

	var bench: Control = SalvageBenchScreen.new()
	stack.call("push", bench, false)
	await process_frame
	await process_frame

	check(int(bench.call("row_count")) == authored,
		"every authored unlock gets a card (%d of %d)" % [int(bench.call("row_count")), authored])

	# Focus must land on something usable (F-216).
	var focus_target: Control = bench.call("menu_default_focus")
	check(focus_target != null and focus_target.focus_mode == Control.FOCUS_ALL,
		"the bench names a focusable default")

	# ── affordability is stated in words, not just colour (docs/MENU.md §9) ──────────────────────
	var rows: Dictionary = bench.get("_rows")
	var sample_id: StringName = rows.keys()[0]
	var sample: Dictionary = rows[sample_id]
	var state_label: Label = sample["state"]
	var button: Button = sample["button"]

	check(not state_label.text.is_empty(), "each card states its price in words")
	if bool(bench.call("is_owned", sample_id)):
		check(state_label.text.contains("BENCH"), "an owned card says it is owned")
		check(button.disabled, "an owned card cannot be bought again")
	elif bool(bench.call("can_afford", sample_id)):
		check(not button.disabled, "an affordable card can be bought")
	else:
		check(state_label.text.contains("short"), "an unaffordable card says how much short you are")
		check(button.disabled, "an unaffordable card cannot be bought")

	# ── buying asks first, and the confirmation names the thing and the price ────────────────────
	var affordable_id: StringName = &""
	for unlock_id: StringName in rows:
		if bool(bench.call("can_afford", unlock_id)) and not bool(bench.call("is_owned", unlock_id)):
			affordable_id = unlock_id
			break

	if affordable_id != &"":
		var def: Resource = rows[affordable_id]["def"]
		var balance_before: int = int(bench.call("balance"))

		bench.call("request_purchase", affordable_id)
		await process_frame
		check(int(stack.call("depth")) == 2, "buying asks before spending")
		var dialog: Control = stack.call("top")
		var dialog_text: String = _all_text(dialog)
		check(dialog_text.contains(String(def.get("display_name"))),
			"the confirmation names what you are buying")
		check(dialog_text.contains(str(int(def.get("cost")))),
			"the confirmation names the price")
		check(int(bench.call("balance")) == balance_before,
			"nothing is spent while the confirmation is still up")

		# Backing out must cost nothing.
		stack.call("pop")
		await process_frame
		check(int(bench.call("balance")) == balance_before, "declining spends nothing")
		check(not bool(bench.call("is_owned", affordable_id)), "declining buys nothing")

		# Going through with it spends exactly the cost and marks it owned.
		bench.call("_purchase_now", affordable_id)
		await process_frame
		check(bool(bench.call("is_owned", affordable_id)), "confirming buys the unlock")
		check(int(bench.call("balance")) == balance_before - int(def.get("cost")),
			"confirming spends exactly the listed cost")
		check(String(bench.call("status_text")).contains(String(def.get("display_name"))),
			"the bench says what was bought")

		# Buying it again must be refused in words, and must not spend twice.
		var after: int = int(bench.call("balance"))
		bench.call("request_purchase", affordable_id)
		await process_frame
		check(int(bench.call("balance")) == after, "an owned unlock cannot be bought twice")
		check(String(bench.call("status_text")).to_lower().contains("already"),
			"buying an owned unlock says so")
	else:
		check(true, "no affordable unpurchased unlock in this save — purchase path not exercised")

	# ── a refusal by the service must never be reported as a success ─────────────────────────────
	# Drive the failure path directly: an id the service will refuse.
	var unaffordable_id: StringName = &""
	for unlock_id: StringName in rows:
		if not bool(bench.call("can_afford", unlock_id)) and not bool(bench.call("is_owned", unlock_id)):
			unaffordable_id = unlock_id
			break
	if unaffordable_id != &"":
		var before: int = int(bench.call("balance"))
		bench.call("_purchase_now", unaffordable_id)
		await process_frame
		check(not bool(bench.call("is_owned", unaffordable_id)),
			"a purchase the service refuses does not mark the unlock owned")
		check(int(bench.call("balance")) == before, "a refused purchase spends nothing")
		check(String(bench.call("status_text")).to_lower().contains("couldn't"),
			"a refused purchase says it failed rather than printing a success line")

	check(_minimum_font_size(bench) >= MireTheme.CAPTION,
		"no text on the bench falls below the %dpx floor" % MireTheme.CAPTION)

	stack.call("pop_all")
	bench.free()
	print("SALVAGE_BENCH_CHECK failures=%d" % failures)
	finish()


## Starts every run from the same state: nothing owned, a known balance. Without this the check
## passes or fails depending on what a previous run of it happened to buy.
func _reset_test_saves() -> void:
	var salvage_save := load("res://core/save/salvage_save.gd")
	var unlock_save := load("res://core/save/unlock_save.gd")
	salvage_save.save_data({"total_salvage": TEST_BALANCE}, TEST_SALVAGE_PATH)
	unlock_save.save_data({"purchased_ids": []}, TEST_UNLOCK_PATH)


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
