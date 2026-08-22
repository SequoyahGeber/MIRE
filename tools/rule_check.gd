extends SceneTree

## Offline proof for task 3.14's gamerules — everything that does not need a second real peer:
## RuleDef coercion, the content family loading, the `rule`/`rules` commands, the dynamic LOCAL-read
## / HOST-set scope split, the clamp being visible rather than silent, and — the load-bearing one —
## that every first-wave knob's authored default is byte-for-byte the number its owner shipped with
## (docs/COMMANDS.md §4.3: "defaults unchanged").
##
##   .agent/bin/agent godot --script tools/rule_check.gd
##
## Boots the real project offline (host-of-one), so the rules come from the REAL content directory
## through the REAL Registry and the commands run through the REAL CommandService registration.
## `tools/rule_net_check.gd` is the other half: snapshot-on-join, host broadcast, and an opped
## client's set arriving over the wire.
##
## Preloaded rather than referenced bare for the F-016 reason every check in this project states:
## rule_def.gd and rule_service.gd are new this session, so a fresh headless clone has not scanned
## them into the global class cache yet.
const CommandServiceScript = preload("res://autoload/command_service.gd")
const RuleDefScript = preload("res://systems/rules/rule_def.gd")

const NON_OP_PEER: int = 999
const HOST_PEER: int = 1  # NetConfig.HOST_PEER_ID

## The numbers the owning systems shipped with, before 3.14 existed. Hard-coded on purpose: this is
## the whole content of the "first-wave migration, defaults unchanged" promise, and reading them back
## off the same exports the rules now write into would assert nothing at all.
## F-599: `ambient_enemy_population` was deliberately retuned from 4.0 to 18.0, so its migration-era
## number is recorded here instead of in `SHIPPED_DEFAULTS`. The §4.3 promise is about the 3.14
## MIGRATION not silently moving a number — it was never a promise that balance can never change
## again. Keeping the old value in the pinned map would have made every future balance change look
## like a migration regression, which is how a check stops meaning what its name says.
##
## Entries here are still asserted: each must have actually MOVED off its migration value, so a
## retune that gets reverted by accident still fails.
const DELIBERATELY_RETUNED: Dictionary = {
	&"ambient_enemy_population": 4.0,   # F-599 -> 18.0; 4 bodies over 1.09 km2 read as an empty world
}

const SHIPPED_DEFAULTS: Dictionary = {
	&"day_length_seconds": 900.0,
	&"wave_base_count": 4.0,
	&"wave_per_player": 2.0,
	&"revive_seconds": 3.0,
	&"bleed_out_seconds": 30.0,
	&"hunger_drain_per_sec": 0.0833,
	&"dev_loadout_enabled": 1.0,
}

var failures: int = 0
var command_service: CommandServiceScript
var rules: Node


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame

	rules = root.get_node_or_null(^"RuleService")
	check(rules != null, "RuleService autoload exists")
	var command_node: Node = root.get_node_or_null(^"CommandService")
	check(command_node != null, "CommandService autoload exists")
	if rules == null or command_node == null:
		finish()
		return
	command_service = command_node as CommandServiceScript

	_check_defs_loaded()
	_check_defaults_unchanged()
	_check_coercion()
	await _check_read_and_list()
	await _check_set_and_clamp()
	await _check_reset_and_is_overridden()
	await _check_bad_input()
	await _check_dynamic_scope()
	await _check_owner_adoption()

	print("\nRULE_CHECK failures=%d" % failures)
	finish()


func _ctx(peer_id: int, source: StringName = &"console") -> Dictionary:
	return {"peer_id": peer_id, "source": source, "position": Vector3.ZERO, "facing": Vector3.FORWARD}


# ── the content family ──────────────────────────────────────────────────────────────────────────────


func _check_defs_loaded() -> void:
	print("\n== content/rules/ loads as a content family ==")
	var ids: Array = rules.call("rule_ids")
	# `>=` for the same reason as the Registry count below: rules are content and the family grows.
	# Every first-wave id must still be there, which is the part that would actually be a regression.
	check(ids.size() >= SHIPPED_DEFAULTS.size(),
		"all %d first-wave rules loaded (got %d: %s)" % [
			SHIPPED_DEFAULTS.size(), ids.size(), ", ".join(ids)])
	for id: StringName in SHIPPED_DEFAULTS:
		check(bool(rules.call("has_rule", id)), "rule '%s' exists" % id)

	# The Registry is the front door for content (ARCHITECTURE.md §3.1). RuleService has a disk
	# fallback so a hand-instantiated harness is not left with zero rules, but in a REAL boot the
	# rules must arrive through the Registry like every other family — otherwise the fallback is
	# quietly carrying the feature and nobody would notice the front door was never wired.
	var registry: Node = root.get_node_or_null(^"Registry")
	check(registry != null and registry.has_method(&"rule_defs"),
		"Registry exposes the rules family (rule_defs)")
	if registry != null and registry.has_method(&"rule_defs"):
		# `>=`, not `==`: `content/rules/` is a content family and grows. Pinning the COUNT made
		# every new rule fail an assertion about the loader, which says nothing about the loader.
		# What this is actually for is "Registry indexed them, the disk fallback did not" — so
		# assert every known rule is present and let the total float (F-599).
		var indexed: Dictionary = registry.call("rule_defs")
		check(indexed.size() >= SHIPPED_DEFAULTS.size(),
			"Registry itself indexed every rule, so the disk fallback is not what loaded them (%d)"
				% indexed.size())
		for id: StringName in SHIPPED_DEFAULTS:
			check(indexed.has(id), "Registry indexed '%s'" % id)


func _check_defaults_unchanged() -> void:
	print("\n== COMMANDS.md §4.3: first-wave migration changes no default ==")
	for id: StringName in DELIBERATELY_RETUNED:
		var retuned: Resource = rules.call("def", id)
		if retuned == null:
			check(false, "retuned rule '%s' still has a def" % id)
			continue
		check(not is_equal_approx(float(retuned.get(&"default_value")),
				float(DELIBERATELY_RETUNED[id])),
			"'%s' is still deliberately retuned away from its migration value %s (now %s)"
				% [id, DELIBERATELY_RETUNED[id], retuned.get(&"default_value")])

	for id: StringName in SHIPPED_DEFAULTS:
		var rule: Resource = rules.call("def", id)
		if rule == null:
			check(false, "rule '%s' has a def to read a default from" % id)
			continue
		var authored: float = float(rule.get(&"default_value"))
		var shipped: float = float(SHIPPED_DEFAULTS[id])
		check(is_equal_approx(authored, shipped),
			"'%s' default is still %s (authored %s)" % [id, shipped, authored])
		check(float(rules.call("value", id, -1.0)) == authored,
			"'%s' boots holding its authored default" % id)
		var errors: PackedStringArray = rule.call("validation_errors")
		check(errors.is_empty(), "'%s' is a valid RuleDef (%s)" % [id, "; ".join(errors)])


func _check_coercion() -> void:
	print("\n== RuleDef.coerce is the single gate every write passes ==")
	var boolean: Resource = RuleDefScript.new()
	boolean.type = RuleDefScript.Type.BOOL
	boolean.min_value = 0.0
	boolean.max_value = 1.0
	check(boolean.coerce(0.4) == 1.0, "BOOL flattens any non-zero to 1")
	check(boolean.coerce(0.0) == 0.0, "BOOL keeps zero as 0")
	check(boolean.format_value(1.0) == "true", "BOOL renders as true/false")

	var whole: Resource = RuleDefScript.new()
	whole.type = RuleDefScript.Type.INT
	whole.min_value = 0.0
	whole.max_value = 10.0
	check(whole.coerce(3.7) == 4.0, "INT rounds")
	check(whole.coerce(99.0) == 10.0, "INT clamps to max before rounding")
	check(whole.coerce(-5.0) == 0.0, "INT clamps to min")
	check(whole.format_value(4.0) == "4", "INT renders without a decimal tail")

	var number: Resource = RuleDefScript.new()
	number.type = RuleDefScript.Type.FLOAT
	check(number.coerce(1234.5) == 1234.5, "min == max means unclamped, per the spec's convention")
	check(not number.is_clamped(), "is_clamped() is false for a degenerate range")
	check(number.format_value(0.0833) == "0.0833", "a small rate keeps its precision")
	check(number.format_value(900.0) == "900", "a round number does not print a decimal tail")

	var bad: Resource = RuleDefScript.new()
	bad.id = &"broken"
	bad.display_name = "Broken"
	bad.min_value = 10.0
	bad.max_value = 1.0
	check(not (bad.validation_errors() as PackedStringArray).is_empty(),
		"an inverted range is a validation error, so registry.gd skips it")


# ── the commands ────────────────────────────────────────────────────────────────────────────────────


func _check_read_and_list() -> void:
	print("\n== `rule <id>` reads, `rules` lists ==")
	var read: Dictionary = await command_service.execute("rule day_length_seconds", _ctx(HOST_PEER))
	check(bool(read.get("ok", false)), "reading a rule succeeds")
	check(String(read.get("message", "")).contains("900"),
		"read prints the value: %s" % read.get("message"))
	check(not bool((read.get("data", {}) as Dictionary).get("changed", true)),
		"a read reports changed=false, so a caller can tell it apart from a set")

	var listing: Dictionary = await command_service.execute("rules", _ctx(HOST_PEER))
	check(bool(listing.get("ok", false)), "`rules` succeeds")
	var listed: Array = (listing.get("data", {}) as Dictionary).get("rules", [])
	check(listed.size() >= SHIPPED_DEFAULTS.size() and listed.size() == (rules.call("rule_ids") as Array).size(),
		"`rules` lists every rule as structured data, not just text (%d)" % listed.size())
	var text: String = String(listing.get("message", ""))
	check(text.contains("hunger_drain_per_sec") and text.contains("Hunger points lost per second"),
		"the listing carries each rule's description, which is what it is for")


func _check_set_and_clamp() -> void:
	print("\n== `rule <id> <value>` sets, and a clamp is visible ==")
	var set_result: Dictionary = await command_service.execute(
		"rule bleed_out_seconds 45", _ctx(HOST_PEER))
	check(bool(set_result.get("ok", false)), "setting a rule succeeds")
	check(float(rules.call("value", &"bleed_out_seconds", 0.0)) == 45.0,
		"the service holds the new value")
	check(bool((set_result.get("data", {}) as Dictionary).get("changed", false)),
		"the result reports changed=true")

	var clamped: Dictionary = await command_service.execute(
		"rule bleed_out_seconds 99999", _ctx(HOST_PEER))
	check(bool(clamped.get("ok", false)), "an out-of-range set still succeeds, clamped")
	check(float(rules.call("value", &"bleed_out_seconds", 0.0)) == 120.0,
		"it lands on the RuleDef's max, not the requested number")
	check(String(clamped.get("message", "")).contains("clamped"),
		"and it SAYS it clamped: %s" % clamped.get("message"))

	var rounded: Dictionary = await command_service.execute(
		"rule wave_base_count 7", _ctx(HOST_PEER))
	check(bool(rounded.get("ok", false)) and rules.call("value_int", &"wave_base_count", 0) == 7,
		"an INT rule round-trips through value_int")

	var toggled: Dictionary = await command_service.execute(
		"rule dev_loadout_enabled off", _ctx(HOST_PEER))
	check(bool(toggled.get("ok", false)), "a BOOL rule accepts the word `off`")
	check(not bool(rules.call("value_bool", &"dev_loadout_enabled", true)),
		"and value_bool reports it as false")


func _check_reset_and_is_overridden() -> void:
	print("\n== `reset`, and is_overridden as D-085's precedence signal ==")
	check(bool(rules.call("is_overridden", &"bleed_out_seconds")),
		"a rule that was set reads as overridden")
	var reset_result: Dictionary = await command_service.execute(
		"rule bleed_out_seconds reset", _ctx(HOST_PEER))
	check(bool(reset_result.get("ok", false)), "`rule <id> reset` succeeds")
	check(float(rules.call("value", &"bleed_out_seconds", 0.0)) == 30.0,
		"it returns the authored default")
	check(not bool(rules.call("is_overridden", &"bleed_out_seconds")),
		"and is_overridden goes false again with no bookkeeping")

	await command_service.execute("rule wave_base_count reset", _ctx(HOST_PEER))
	await command_service.execute("rule dev_loadout_enabled reset", _ctx(HOST_PEER))


func _check_bad_input() -> void:
	print("\n== bad input is a typed refusal, never a silent no-op ==")
	var unknown: Dictionary = await command_service.execute("rule nosuchrule 5", _ctx(HOST_PEER))
	check(not bool(unknown.get("ok", true)), "an unknown rule id is refused")
	check(String(unknown.get("message", "")).contains("no such rule"),
		"the rule_id parser owns that message: %s" % unknown.get("message"))

	var not_a_number: Dictionary = await command_service.execute(
		"rule day_length_seconds banana", _ctx(HOST_PEER))
	check(not bool(not_a_number.get("ok", true)), "a non-numeric value is refused")
	check(float(rules.call("value", &"day_length_seconds", 0.0)) == 900.0,
		"and nothing was written on the way to refusing")

	var bad_bool: Dictionary = await command_service.execute(
		"rule dev_loadout_enabled maybe", _ctx(HOST_PEER))
	check(not bool(bad_bool.get("ok", true)), "a BOOL rule refuses a word that is not on/off")

	var missing: Dictionary = await command_service.execute("rule", _ctx(HOST_PEER))
	check(not bool(missing.get("ok", true)) and String(missing.get("message", "")).contains("usage"),
		"a missing rule id gets the spec's usage line: %s" % missing.get("message"))


func _check_dynamic_scope() -> void:
	print("\n== COMMANDS.md §4.2's split: reads answer locally, sets need op ==")
	var non_op: Dictionary = _ctx(NON_OP_PEER)
	var read: Dictionary = await command_service.execute("rule revive_seconds", non_op)
	check(bool(read.get("ok", false)),
		"a non-op CAN read a rule — the read is LOCAL scope: %s" % read.get("message"))

	var write: Dictionary = await command_service.execute("rule revive_seconds 9", non_op)
	check(not bool(write.get("ok", true)), "the same non-op CANNOT set one — the set is HOST scope")
	check(String(write.get("message", "")).contains("not op"),
		"and gets CommandService's uniform refusal: %s" % write.get("message"))
	check(float(rules.call("value", &"revive_seconds", 0.0)) == 3.0, "the value did not move")

	check(String(command_service.scope_of(&"rule")) == "host",
		"introspection reports the MAX scope for a dynamic command, so `commands` reads honestly")
	check(String(command_service.scope_of(&"rules")) == "local", "`rules` is plainly local")


# ── the point of the whole task: a knob that actually turns ─────────────────────────────────────────


func _check_owner_adoption() -> void:
	print("\n== the owning systems adopt the value (COMMANDS.md §4.3) ==")
	var enemy_world: Node = root.get_node_or_null(^"EnemyWorld")
	check(enemy_world != null, "EnemyWorld autoload exists")
	if enemy_world != null:
		# Read the authored default off the RuleDef rather than restating it. The number is balance
		# and will move again; what this subtest is for is that the OWNER follows the rule, which is
		# true whatever the number happens to be (F-599).
		var ambient_def: Resource = rules.call("def", &"ambient_enemy_population")
		var ambient_default: int = roundi(float(ambient_def.get(&"default_value"))) \
			if ambient_def != null else 0
		check(int(enemy_world.get(&"ambient_population")) == ambient_default,
			"it boots on the authored default (%d)" % ambient_default)
		await command_service.execute("rule ambient_enemy_population 11", _ctx(HOST_PEER))
		check(int(enemy_world.get(&"ambient_population")) == 11,
			"and follows the rule the moment it changes")
		await command_service.execute("rule ambient_enemy_population reset", _ctx(HOST_PEER))
		check(int(enemy_world.get(&"ambient_population")) == ambient_default,
			"reset puts it back")

	var health: Node = root.get_node_or_null(^"PlayerHealth")
	check(health != null, "PlayerHealth autoload exists")
	if health != null:
		await command_service.execute("rule revive_seconds 8", _ctx(HOST_PEER))
		check(is_equal_approx(float(health.get(&"revive_seconds")), 8.0),
			"revive_seconds follows — this is the property player_controller.gd reads by name")
		await command_service.execute("rule revive_seconds reset", _ctx(HOST_PEER))

	var waves: Node = root.get_node_or_null(^"WaveSpawner")
	if waves != null:
		await command_service.execute("rule wave_per_player 5", _ctx(HOST_PEER))
		check(int(waves.get(&"per_player")) == 5, "WaveSpawner follows wave_per_player")
		await command_service.execute("rule wave_per_player reset", _ctx(HOST_PEER))

	# D-085: day_length_seconds is the one knob with a competing, level-authored source. A rule
	# sitting at its default must NOT outrank the level; a rule someone set must.
	var day_night: Node = root.get_node_or_null(^"DayNight")
	check(day_night != null, "DayNight autoload exists")
	if day_night != null:
		check(not bool(rules.call("is_overridden", &"day_length_seconds")),
			"day_length_seconds starts un-overridden, so the level's Atmosphere still wins (D-085)")
		day_night.set(&"day_length_seconds", 600.0)  # stand in for a level that authored 600s
		await command_service.execute("rule day_length_seconds 120", _ctx(HOST_PEER))
		check(bool(rules.call("is_overridden", &"day_length_seconds")),
			"once set, the rule is overridden")
		check(is_equal_approx(float(rules.call("value", &"day_length_seconds", 0.0)), 120.0),
			"and the service holds the value DayNight resolves against")
		await command_service.execute("rule day_length_seconds reset", _ctx(HOST_PEER))
		check(not bool(rules.call("is_overridden", &"day_length_seconds")),
			"reset hands precedence back to the level")


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
