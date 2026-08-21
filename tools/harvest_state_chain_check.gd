extends SceneTree

## F-425 — does every authored damage state actually get shown?
##
## `HarvestableDef.active_state_scenes` divides a prop's health evenly across however many states it
## is given, so adding a state does NOT guarantee anyone ever sees it: with the wrong ratio of health
## to states, `Harvestable._state_for_health()` can skip an index entirely and the art is dead
## weight. That is the failure this exists to catch, and it is invisible in play — a state you never
## reach looks exactly like a state that does not exist.
##
## So this walks each definition's health from full down to 1 and asserts that
##
##   * every index in `active_state_scenes` is visited at least once,
##   * the sequence never goes backwards (a prop must not visibly heal as it is hit), and
##   * every scene the definition names actually loads.
##
## Authority: none (docs/ARCHITECTURE.md §2.2). Read-only measurement.
##
##   .agent/bin/agent godot --script tools/harvest_state_chain_check.gd

const HARVESTABLE := preload("res://systems/harvesting/harvestable.gd")

var _failures: int = 0


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: %s" % label)
	else:
		_failures += 1
		print("FAIL: %s" % label)


func _initialize() -> void:
	print("F-425 — harvest damage state chains\n")
	var dir := DirAccess.open("res://content/harvestables")
	var names: PackedStringArray = dir.get_files()
	names.sort()
	for file_name: String in names:
		if not file_name.ends_with(".tres"):
			continue
		var definition: Resource = load("res://content/harvestables/%s" % file_name)
		if definition == null:
			_check(false, "%s loads" % file_name)
			continue
		var states: Array = definition.get("active_state_scenes")
		if states.is_empty():
			# F-114's supported case: the prop is its own intact visual.
			print("SKIP: %s draws the world's own mesh" % file_name)
			continue

		var prop: Node = HARVESTABLE.new()
		prop.set("definition", definition)
		var seen: Dictionary = {}
		var previous: int = -1
		var monotonic := true
		for health: int in range(int(definition.get("max_health")), 0, -1):
			var state: int = prop.call("_state_for_health", health)
			seen[state] = true
			if state < previous:
				monotonic = false
			previous = state
		prop.free()

		var id: String = String(definition.get("id"))
		var missing: PackedStringArray = PackedStringArray()
		for index: int in states.size():
			if not seen.has(index):
				missing.append(str(index))
		_check(missing.is_empty(), "%s: every one of its %d damage states is reachable%s" % [
			id, states.size(), "" if missing.is_empty() else " (never shown: %s)" % ", ".join(missing),
		])
		_check(monotonic, "%s: damage never visibly reverses" % id)
		var loaded := true
		for index: int in states.size():
			if states[index] == null or states[index].instantiate() == null:
				loaded = false
		_check(loaded, "%s: every state scene loads" % id)
		if definition.get("depleted_scene") != null:
			_check(prop_state_is_depleted(definition), "%s: zero health selects the depleted scene" % id)

	print("\nHARVEST_STATE_CHAIN_CHECK failures=%d" % _failures)
	quit(1 if _failures > 0 else 0)


func prop_state_is_depleted(definition: Resource) -> bool:
	var prop: Node = HARVESTABLE.new()
	prop.set("definition", definition)
	var state: int = prop.call("_state_for_health", 0)
	prop.free()
	return state == (definition.get("active_state_scenes") as Array).size()
