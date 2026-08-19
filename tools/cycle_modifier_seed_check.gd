extends SceneTree

## F-220 proof: `CycleModifierService.host_draw_modifier()` now derives its RNG seed from
## `(GameState.run_seed, cycle)` instead of boot-time `randomize()` — see
## `systems/cycle/cycle_modifier_service.gd`'s `_seed_for_run()`/`_run_seed()`. Same shape
## `tools/chest_seed_check.gd`/`tools/reward_service_seed_check.gd` already prove for their own
## files; `cycle` is the stable per-draw id here, the same role `Chest`'s node `name` and
## `RewardService`'s event counter play in those two.
##
## Real content ships only one Cycle Modifier so far (`long_night.tres`), so a weighted pick over a
## single candidate can never show variation regardless of seed — this check injects two additional
## synthetic, equally-weighted candidates directly into `CycleModifierService._defs`, the identical
## "GDScript has no real access control" seam `tools/cycle_modifier_check.gd`'s own incompatibility
## tests already use, wide enough (3-way pick, repeated draws) that a coincidental match is not a
## realistic false pass.
##
##   .agent/bin/agent godot --script tools/cycle_modifier_seed_check.gd

const CYCLE_MODIFIER_DEF := preload("res://systems/cycle/cycle_modifier_def.gd")

var failures: int = 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	print("\n== F-220 CycleModifierService seed determinism check ==")
	var game_state: Node = root.get_node_or_null(^"GameState")
	var cycle_modifier_service: Node = root.get_node_or_null(^"CycleModifierService")
	check(game_state != null, "GameState autoload exists")
	check(cycle_modifier_service != null, "CycleModifierService autoload exists")
	if game_state == null or cycle_modifier_service == null:
		finish()
		return

	var saved_defs: Dictionary = (cycle_modifier_service.get(&"_defs") as Dictionary).duplicate()
	var saved_active: Array[StringName] = (
		cycle_modifier_service.get(&"_active_ids") as Array[StringName]
	).duplicate()

	var defs: Dictionary = {}
	for id: StringName in [&"seed_check_a", &"seed_check_b", &"seed_check_c"]:
		defs[id] = _synthetic(id)
	cycle_modifier_service.set(&"_defs", defs)

	# ── Case 1: same run_seed, same cycle -> identical draw. ───────────────────────────────────
	game_state.call("set_replicated_seed", 20260819)
	var draw_a: StringName = _fresh_draw(cycle_modifier_service, 7)
	var draw_b: StringName = _fresh_draw(cycle_modifier_service, 7)
	check(draw_a != &"" and draw_a == draw_b,
		"same run_seed + same cycle draws identically ('%s' vs '%s')" % [draw_a, draw_b])

	# ── Case 2: same run_seed, different cycle -> not guaranteed to differ by itself, but
	# combined with case 3 below proves the seed is actually cycle-dependent, not a fixed
	# per-process stream that happens to repeat. ───────────────────────────────────────────────
	var draw_c: StringName = _fresh_draw(cycle_modifier_service, 8)
	check(draw_c != &"", "same run_seed, different cycle still draws something ('%s')" % draw_c)

	# ── Case 3: different run_seed, same cycle -> the draw sequence across several cycles must
	# not match case 1/2's sequence exactly (single-cycle draws can coincidentally match across
	# only 3 candidates; a run of several draws makes that astronomically unlikely). ────────────
	game_state.call("set_replicated_seed", 20260819)
	var sequence_1: Array[StringName] = _draw_sequence(cycle_modifier_service, [7, 8, 9, 10, 11])
	check(sequence_1[0] == draw_a and sequence_1[1] == draw_c,
		"replaying the same run_seed reproduces the same per-cycle draws (%s vs earlier '%s'/'%s')"
		% [sequence_1, draw_a, draw_c])
	game_state.call("set_replicated_seed", 424242)
	var sequence_2: Array[StringName] = _draw_sequence(cycle_modifier_service, [7, 8, 9, 10, 11])
	check(sequence_1 != sequence_2,
		"a different run_seed at the same cycles draws a different sequence (%s vs %s)"
		% [sequence_1, sequence_2])

	cycle_modifier_service.set(&"_defs", saved_defs)
	cycle_modifier_service.set(&"_active_ids", saved_active)

	print("CYCLE_MODIFIER_SEED_CHECK failures=%d" % failures)
	finish()


## Resets the deck to all three synthetic candidates (undrawn) and draws once at `cycle`, returning
## the id drawn. Deck reset is needed because `host_draw_modifier()` never redraws an id already in
## `_active_ids` — without this, a second call at any cycle would draw from a shrinking deck instead
## of replaying the same three-way choice.
func _fresh_draw(cycle_modifier_service: Node, cycle: int) -> StringName:
	cycle_modifier_service.set(&"_active_ids", Array([], TYPE_STRING_NAME, &"", null))
	return cycle_modifier_service.call("host_draw_modifier", cycle)


## Same reset-then-draw as `_fresh_draw()`, repeated across several cycles into one comparable id
## sequence — a longer fingerprint than a single draw, so a coincidental match across only 3
## candidates is not a realistic false pass.
func _draw_sequence(cycle_modifier_service: Node, cycles: Array) -> Array[StringName]:
	var result: Array[StringName] = []
	for cycle: int in cycles:
		result.append(_fresh_draw(cycle_modifier_service, cycle))
	return result


func _synthetic(id: StringName) -> Resource:
	var def: Resource = CYCLE_MODIFIER_DEF.new()
	def.set(&"id", id)
	def.set(&"display_name", String(id))
	def.set(&"min_cycle", 1)
	def.set(&"base_weight", 1.0)
	def.set(&"tags", Array([], TYPE_STRING_NAME, &"", null))
	def.set(&"incompatible_tags", Array([], TYPE_STRING_NAME, &"", null))
	def.set(&"incompatible_with", Array([], TYPE_STRING_NAME, &"", null))
	return def


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
