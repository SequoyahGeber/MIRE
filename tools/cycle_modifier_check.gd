extends SceneTree

## Direct proof for task 6.2: CycleModifierDef's Cycle-weighted eligibility math, the deck/draw/
## stacking loop wired to the REAL CycleService->EventBus->CycleModifierService chain (not a fake
## harness-built substitute — the F-068 lesson wave_spawner_check.gd already records), and the
## symmetric incompatibility-tag + explicit-id exclusion rules. Single-process, offline
## (host-of-one), same convention cycle_check.gd uses.
##
##   .agent/bin/agent godot --script tools/cycle_modifier_check.gd

const CYCLE_MODIFIER_DEF := preload("res://systems/cycle/cycle_modifier_def.gd")

var failures: int = 0
var cycle_service: Node
var cycle_modifier_service: Node
var world_delta_log: Node


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	if not _check_wiring():
		finish()
		return

	_check_weight_at_math()
	_check_real_draw_via_cycle_advance()
	_check_deck_depletes_no_duplicate()
	_check_incompatibility_tags()
	_check_explicit_incompatible_with()

	print("\nCYCLE_MODIFIER_CHECK failures=%d" % failures)
	finish()


## F-068-shaped regression anchor, same reasoning cycle_check.gd's own header records: proves the
## SHIPPED project wires CycleModifierService to the real CycleService, not that this script's own
## logic is correct in isolation.
func _check_wiring() -> bool:
	print("== the shipped project actually has a Cycle Modifier deck ==")
	cycle_service = root.get_node_or_null(^"CycleService")
	cycle_modifier_service = root.get_node_or_null(^"CycleModifierService")
	world_delta_log = root.get_node_or_null(^"WorldDeltaLog")
	check(cycle_service != null, "CycleService is registered as an autoload")
	check(cycle_modifier_service != null, "CycleModifierService is registered as an autoload")
	check(world_delta_log != null, "WorldDeltaLog is registered as an autoload")
	if cycle_service == null or cycle_modifier_service == null or world_delta_log == null:
		return false
	var loaded: Dictionary = cycle_modifier_service.get(&"_defs")
	check(loaded.has(&"long_night"), "content/cycle_modifiers/long_night.tres loaded ('%s' present)"
		% ", ".join(loaded.keys()))
	return loaded.has(&"long_night")


## Pure logic, no autoload involved — instantiated straight from the preloaded script (F-016: a
## brand-new class_name is not bare-resolvable in a fresh headless clone, so this never writes
## `CycleModifierDef` as a bare type, matching every content Def check in this project).
func _check_weight_at_math() -> void:
	print("\n== CycleModifierDef.weight_at() — Cycle-weighted eligibility ==")
	var def: Resource = CYCLE_MODIFIER_DEF.new()
	def.set(&"min_cycle", 5)
	def.set(&"base_weight", 2.0)
	def.set(&"weight_growth_per_cycle", 0.5)

	check(is_equal_approx(float(def.call("weight_at", 1)), 0.0),
		"below min_cycle, weight is 0 (not eligible)")
	check(is_equal_approx(float(def.call("weight_at", 5)), 2.0),
		"at min_cycle, weight is exactly base_weight (2.0)")
	check(is_equal_approx(float(def.call("weight_at", 7)), 3.0),
		"two Cycles past min_cycle, weight grows by 2 * 0.5 (2.0 -> 3.0)")

	var decaying: Resource = CYCLE_MODIFIER_DEF.new()
	decaying.set(&"min_cycle", 1)
	decaying.set(&"base_weight", 1.0)
	decaying.set(&"weight_growth_per_cycle", -1.0)
	check(is_equal_approx(float(decaying.call("weight_at", 3)), 0.0),
		"negative growth floors at 0, never goes negative (would corrupt a weighted-pick roll)")

	var empty_id_errors: PackedStringArray = CYCLE_MODIFIER_DEF.new().call("validation_errors")
	check(not empty_id_errors.is_empty(), "validation_errors() catches an unauthored (empty-id) def")


## The real chain: CycleService.host_advance_cycle() -> EventBus.emit_cycle_advanced() ->
## CycleModifierService._on_cycle_advanced() -> a real draw, stacked and announced through
## WorldDeltaLog. long_night.tres has min_cycle=2, so the FIRST advance (Cycle 1 -> 2) must draw it.
func _check_real_draw_via_cycle_advance() -> void:
	print("\n== a real Cycle advance draws and stacks the deck's one modifier ==")
	var cycle_before: int = int(cycle_service.call("current_cycle"))
	check(cycle_before == 1, "starts at Cycle 1, before long_night's min_cycle (sanity check)")

	var new_cycle: int = int(cycle_service.call("host_advance_cycle"))
	check(new_cycle == 2, "advanced to Cycle 2 (%d)" % new_cycle)

	var active: Array = cycle_modifier_service.call("active_modifier_ids")
	check(active.size() == 1 and active[0] == &"long_night",
		"long_night was drawn and stacked the instant the Cycle advanced past its min_cycle (%s)"
		% str(active))
	check(bool(cycle_modifier_service.call("has_modifier", &"long_night")),
		"has_modifier() reflects the same stack")

	var logged_count: int = int(world_delta_log.call(
		"latest", Vector2i.ZERO, &"cycle_modifier", "count", -1))
	check(logged_count == 1, "WorldDeltaLog carries the same stack size a late joiner would read (%d)"
		% logged_count)
	var logged_slot0: String = String(world_delta_log.call(
		"latest", Vector2i.ZERO, &"cycle_modifier", "0", ""))
	check(logged_slot0 == "long_night", "WorldDeltaLog's slot 0 is the drawn id ('%s')" % logged_slot0)


## Task 6.3 grew the deck past the single long_night worked example — 7 real content modifiers
## now (long_night min_cycle=2; drought/tithe/static min_cycle=3; rooted min_cycle=4; bloom
## min_cycle=5; the_hunt min_cycle=6). Never hardcode WHICH id a given Cycle draws — the weighted
## pick is real RNG (seeded per F-220, but the seed is derived from a live run_seed this check
## never fixes) and two authors are free to add an 8th modifier at min_cycle=3 tomorrow, which
## would silently break a test that assumed exactly 3 candidates go eligible there. Instead this
## proves the invariants that hold regardless of WHICH candidate wins each weighted pick: a draw
## never repeats an id, the stack size only ever grows by the number of still-eligible advances,
## and the deck is fully exhausted (every content id drawn exactly once) by the Cycle every
## authored id has become eligible — after which further advances are a no-op, not a crash.
func _check_deck_depletes_no_duplicate() -> void:
	print("\n== the grown deck draws every modifier exactly once, then goes quiet ==")
	var total: int = int(cycle_modifier_service.get(&"_defs").size())

	var seen_ids: Dictionary = {}
	for active_id: StringName in cycle_modifier_service.call("active_modifier_ids"):
		seen_ids[active_id] = true

	# host_draw_modifier() appends at most one id per Cycle advance, so full deck coverage takes
	# at most `total` further advances past whatever has already landed above (long_night, from
	# the caller). `total + 5` is a safety cap on the loop itself, not a tuned expectation — it
	# exists only so a future author adding an 8th modifier can never turn this into an infinite
	# loop, not to assert how many Cycles the draw should take.
	var advances: int = 0
	while seen_ids.size() < total and advances < total + 5:
		var before_size: int = seen_ids.size()
		cycle_service.call("host_advance_cycle")
		var active: Array = cycle_modifier_service.call("active_modifier_ids")
		check(active.size() <= before_size + 1,
			"a single Cycle advance never stacks more than one new modifier (%d -> %d)"
			% [before_size, active.size()])
		for active_id: StringName in active:
			seen_ids[active_id] = true
		advances += 1

	check(seen_ids.size() == total,
		"every authored modifier is drawn exactly once across the run (%d/%d)"
		% [seen_ids.size(), total])

	var before: Array = cycle_modifier_service.call("active_modifier_ids")
	cycle_service.call("host_advance_cycle")
	var after: Array = cycle_modifier_service.call("active_modifier_ids")
	check(after.size() == before.size(),
		"advancing past a fully-drawn deck draws nothing new (%d)" % after.size())

	var drawn_id: StringName = cycle_modifier_service.call("host_draw_modifier", 999)
	check(drawn_id == &"", "host_draw_modifier() on an exhausted deck returns '', not a crash")


## Symmetric incompatibility-tag rule: a candidate is blocked if ITS OWN incompatible_tags names a
## tag an active modifier carries, OR if an ALREADY-ACTIVE modifier's incompatible_tags names a tag
## the candidate carries — so either author can declare the exclusion once. Injects synthetic defs
## directly (GDScript has no real access control; every other check in this project reads/writes an
## autoload's private state the identical way, e.g. cycle_check.gd's mire_grid._cycle_spread_multiplier
## probe) rather than authoring throwaway .tres content just to exercise this path.
func _check_incompatibility_tags() -> void:
	print("\n== incompatibility tags block a draw in both directions ==")
	var defs: Dictionary = cycle_modifier_service.get(&"_defs")
	var saved_defs: Dictionary = defs.duplicate()
	var saved_active: Array[StringName] = (cycle_modifier_service.get(&"_active_ids") as Array[StringName]).duplicate()

	var carries_weather: Resource = _synthetic(&"synth_carries_weather", [&"weather"], [], [])
	var refuses_weather: Resource = _synthetic(&"synth_refuses_weather", [], [&"weather"], [])
	defs[carries_weather.get(&"id")] = carries_weather
	defs[refuses_weather.get(&"id")] = refuses_weather

	# Direction 1: the CANDIDATE's own incompatible_tags names an already-active tag.
	cycle_modifier_service.set(&"_active_ids", _one(carries_weather.get(&"id")))
	var eligible_1: Array = cycle_modifier_service.call("_eligible_defs", 1)
	check(not _ids_of(eligible_1).has(refuses_weather.get(&"id")),
		"a candidate whose own incompatible_tags names an already-active tag is excluded")

	# Direction 2: an ALREADY-ACTIVE modifier's incompatible_tags names the candidate's own tag.
	cycle_modifier_service.set(&"_active_ids", _one(refuses_weather.get(&"id")))
	var eligible_2: Array = cycle_modifier_service.call("_eligible_defs", 1)
	check(not _ids_of(eligible_2).has(carries_weather.get(&"id")),
		"a candidate carrying a tag an active modifier refuses is excluded (symmetric)")

	cycle_modifier_service.set(&"_defs", saved_defs)
	cycle_modifier_service.set(&"_active_ids", saved_active)


## Explicit id-level exclusion, independent of tags — the escape hatch for a pair that should never
## stack together but shares no natural tag worth inventing.
func _check_explicit_incompatible_with() -> void:
	print("\n== explicit incompatible_with excludes by id, with no shared tag ==")
	var defs: Dictionary = cycle_modifier_service.get(&"_defs")
	var saved_defs: Dictionary = defs.duplicate()
	var saved_active: Array[StringName] = (cycle_modifier_service.get(&"_active_ids") as Array[StringName]).duplicate()

	var nemesis_a: Resource = _synthetic(&"synth_nemesis_a", [], [], [&"synth_nemesis_b"])
	var nemesis_b: Resource = _synthetic(&"synth_nemesis_b", [], [], [])
	defs[nemesis_a.get(&"id")] = nemesis_a
	defs[nemesis_b.get(&"id")] = nemesis_b

	cycle_modifier_service.set(&"_active_ids", _one(nemesis_b.get(&"id")))
	var eligible: Array = cycle_modifier_service.call("_eligible_defs", 1)
	check(not _ids_of(eligible).has(nemesis_a.get(&"id")),
		"synth_nemesis_a names synth_nemesis_b in incompatible_with and is excluded once it is active")

	cycle_modifier_service.set(&"_defs", saved_defs)
	cycle_modifier_service.set(&"_active_ids", saved_active)


## `Array[StringName](...)` is the real element-wise conversion — `expr as Array[StringName]` does
## NOT convert an untyped Array's element type (it silently leaves it untyped, and a subsequent
## `.set()` on a strictly-typed Array export property then no-ops). This bit this check during
## authoring: see the constructor-call convention `content/powerups/*.tres` already uses for typed
## array/dictionary literals — the same syntax GDScript code needs at runtime, not just in a .tres.
func _synthetic(
	id: StringName, tags: Array, incompatible_tags: Array, incompatible_with: Array
) -> Resource:
	var typed_tags: Array[StringName] = Array(tags, TYPE_STRING_NAME, &"", null)
	var typed_incompatible_tags: Array[StringName] = Array(incompatible_tags, TYPE_STRING_NAME, &"", null)
	var typed_incompatible_with: Array[StringName] = Array(incompatible_with, TYPE_STRING_NAME, &"", null)
	var def: Resource = CYCLE_MODIFIER_DEF.new()
	def.set(&"id", id)
	def.set(&"display_name", String(id))
	def.set(&"min_cycle", 1)
	def.set(&"base_weight", 1.0)
	def.set(&"tags", typed_tags)
	def.set(&"incompatible_tags", typed_incompatible_tags)
	def.set(&"incompatible_with", typed_incompatible_with)
	return def


func _one(id: StringName) -> Array[StringName]:
	var result: Array[StringName] = [id]
	return result


func _ids_of(defs: Array) -> Array:
	var ids: Array = []
	for def: Resource in defs:
		ids.append(def.get(&"id"))
	return ids


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
