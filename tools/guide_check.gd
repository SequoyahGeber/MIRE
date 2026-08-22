extends SceneTree

## Task 3.19: does the guidance layer say the right thing, once, and can it be turned off?
##
## The three failure modes this exists to catch, in the order they would actually bite:
##   1. an authored step whose condition can never resolve, so the line silently skips it;
##   2. two objectives on screen at once, or an objective that reappears after being satisfied;
##   3. a tip that fires every run forever, which is how a tutorial becomes an irritant.
##
## Every assertion drives `GuideService.evaluate()` directly rather than waiting out `POLL_SEC` — the
## service exposes it public for exactly that reason, and a check that sleeps is a check nobody runs.
##
## Run with: .agent/bin/agent godot --script tools/guide_check.gd

const GUIDE_STEP := preload("res://systems/guide/guide_step_def.gd")

## The opening of the objective ladder, in the order a new player must see it
## (`docs/PROGRESSION.md` §5.1). Asserted as an ORDER, not as a set: which line comes first is the
## entire design, and a re-authored `order` field that shuffles them is a regression even though
## every individual step still validates.
## F-522 reordered the first four: the workbench is now the FIRST thing built, because its cost is
## the only one bare hands can pay and every tool recipe names it as its station.
const EXPECTED_OPENING: Array[String] = [
	"gather_fibre", "place_workbench", "craft_first_axe", "chop_a_tree"
]

var failures: int = 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var registry: Node = root.get_node_or_null(^"Registry")
	var guide: Node = root.get_node_or_null(^"GuideService")
	var settings: Node = root.get_node_or_null(^"SettingsService")
	check(registry != null, "Registry autoload exists")
	check(guide != null, "GuideService autoload exists")
	check(settings != null, "SettingsService autoload exists")
	if registry == null or guide == null or settings == null:
		_finish()
		return

	_check_authored_steps(registry)
	_check_ordering(registry)
	_check_tip_once(guide, settings)
	_check_off_switch(guide, settings)

	print("GUIDE failures=%d" % failures)
	_finish()


## Every shipped step validates, and — the part `validation_errors()` cannot see — every step that
## names a piece of content names one that exists. A tip keyed to `wodden_axe` is a tip that never
## fires, and nothing else in the build would ever complain about it.
func _check_authored_steps(registry: Node) -> void:
	var steps: Dictionary = registry.call("guide_step_defs") as Dictionary
	check(not steps.is_empty(), "at least one guidance step is authored")
	var objectives: int = 0
	var tips: int = 0
	for step_id: StringName in steps:
		var step: Resource = steps[step_id] as Resource
		if step == null:
			continue
		var errors: PackedStringArray = step.call("validation_errors")
		check(errors.is_empty(), "step '%s' validates (%s)" % [step_id, "; ".join(errors)])
		if int(step.get(&"kind")) == GUIDE_STEP.Kind.TIP:
			tips += 1
		else:
			objectives += 1
		for slot: StringName in [&"require", &"satisfied_by"]:
			var condition: int = int(step.get(slot))
			var arg_field: StringName = &"require_arg" if slot == &"require" else &"satisfied_arg"
			var arg := StringName(String(step.get(arg_field)))
			if condition == GUIDE_STEP.Condition.HAS_ITEM:
				check(bool(registry.call("has_item", arg)),
					"step '%s' %s names a real item '%s'" % [step_id, slot, arg])
			elif condition == GUIDE_STEP.Condition.STATION_BUILT:
				check(bool(registry.call("has_station", arg)),
					"step '%s' %s names a real station '%s'" % [step_id, slot, arg])
	check(objectives > 0, "objectives are authored (%d)" % objectives)
	check(tips > 0, "tips are authored (%d)" % tips)


## The opening ladder is in the order the design says, by `order` alone — the same sort
## `GuideService` applies, so this is the sequence a player will actually be walked through.
func _check_ordering(registry: Node) -> void:
	var steps: Dictionary = registry.call("guide_step_defs") as Dictionary
	var ordered: Array[Resource] = []
	for step_id: StringName in steps:
		var step: Resource = steps[step_id] as Resource
		if step != null and int(step.get(&"kind")) == GUIDE_STEP.Kind.OBJECTIVE:
			ordered.append(step)
	ordered.sort_custom(func(a: Resource, b: Resource) -> bool:
		var order_a: int = int(a.get(&"order"))
		var order_b: int = int(b.get(&"order"))
		if order_a == order_b:
			return String(a.get(&"id")) < String(b.get(&"id"))
		return order_a < order_b
	)
	var actual: Array[String] = []
	for index: int in mini(ordered.size(), EXPECTED_OPENING.size()):
		actual.append(String(ordered[index].get(&"id")))
	check(actual == EXPECTED_OPENING, "the opening ladder reads %s (expected %s)" % [
		", ".join(actual), ", ".join(EXPECTED_OPENING)
	])

	# Two steps at the same order with the same id cannot happen (ids are the registry key), but two
	# at the same order CAN, and then which one a player sees depends on directory read order. That
	# is a real authoring mistake and cheap to name here.
	var seen_orders: Dictionary = {}
	for step: Resource in ordered:
		var order: int = int(step.get(&"order"))
		check(not seen_orders.has(order), "objective order %d is used once ('%s' collides with '%s')"
			% [order, step.get(&"id"), seen_orders.get(order, "")])
		seen_orders[order] = String(step.get(&"id"))


## A tip fires once per profile and then never again, which is the whole point of persisting the
## record. Driven through the real `SettingsService`, with its seen-record cleared first so the dev
## machine's own profile cannot make this pass or fail by accident.
func _check_tip_once(guide: Node, settings: Node) -> void:
	settings.call("reset_seen_tips")
	var shown: Array[StringName] = []
	var listener: Callable = func(step_id: StringName, _text: String, _seconds: float) -> void:
		shown.append(step_id)
	guide.connect(&"tip_shown", listener)

	# NIGHT is the one tip trigger a headless check can set without a world: DayNight's time_of_day
	# is a plain replicated float, and every other trigger needs a player, a prop or a boss.
	var day_night: Node = root.get_node_or_null(^"DayNight")
	if day_night == null:
		check(false, "DayNight autoload exists")
		guide.disconnect(&"tip_shown", listener)
		return
	day_night.set(&"time_of_day", 0.9)
	guide.call("evaluate")
	guide.call("evaluate")
	var first_pass: int = shown.size()
	check(first_pass > 0, "a night tip fires when night falls (%d shown)" % first_pass)

	# Same situation again, in a brand new run: the per-profile record must survive the reset.
	guide.call("reset_run")
	guide.call("evaluate")
	guide.call("evaluate")
	check(shown.size() == first_pass,
		"a tip already seen does not fire again in a later run (%d -> %d)" % [
			first_pass, shown.size()
		])

	settings.call("reset_seen_tips")
	guide.call("reset_run")
	guide.call("evaluate")
	guide.call("evaluate")
	check(shown.size() > first_pass, "clearing the seen record makes tips teachable again")

	guide.disconnect(&"tip_shown", listener)
	settings.call("reset_seen_tips")
	day_night.set(&"time_of_day", 0.5)


## OFF means off: no objective, no tip, no exceptions. This is the setting a player reaches for when
## the guidance is in their way, and a surface that ignores it is worse than no setting at all.
func _check_off_switch(guide: Node, settings: Node) -> void:
	var previous: int = int(settings.call("guidance_mode"))

	settings.call("set_guidance_mode", 0)
	guide.call("reset_run")
	guide.call("evaluate")
	check(String(guide.call("current_objective_id")) != "",
		"FULL shows an objective")

	var tips_while_objectives_only: int = 0
	var counter: Callable = func(_id: StringName, _text: String, _seconds: float) -> void:
		tips_while_objectives_only += 1
	guide.connect(&"tip_shown", counter)
	settings.call("set_guidance_mode", 1)
	settings.call("reset_seen_tips")
	var day_night: Node = root.get_node_or_null(^"DayNight")
	if day_night != null:
		day_night.set(&"time_of_day", 0.9)
	guide.call("reset_run")
	guide.call("evaluate")
	guide.call("evaluate")
	check(String(guide.call("current_objective_id")) != "", "OBJECTIVES_ONLY keeps the line")
	check(tips_while_objectives_only == 0, "OBJECTIVES_ONLY fires no tips")
	guide.disconnect(&"tip_shown", counter)

	settings.call("set_guidance_mode", 2)
	guide.call("reset_run")
	guide.call("evaluate")
	check(String(guide.call("current_objective_id")) == "", "OFF shows nothing")

	settings.call("set_guidance_mode", previous)
	settings.call("reset_seen_tips")
	if day_night != null:
		day_night.set(&"time_of_day", 0.5)


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func _finish() -> void:
	quit(1 if failures > 0 else 0)
