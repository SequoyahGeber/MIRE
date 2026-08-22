extends SceneTree

## F-543 — offline proof that an Attunement's stat modifiers CHANGE THE GAME, not just the roster.
##
##   .agent/bin/agent godot --script tools/attunement_effects_check.gd
##
## `tools/attunement_check.gd` already proves selection: the pick is recorded, its backing PowerupDef
## is granted, a second pick is refused, D-035 identity is honoured. It proves the modifier resolves
## through `PowerupService.stat()` — and that is exactly where its coverage stopped, because until
## F-543 nothing downstream READ that stat. SPECS §3.9's acceptance line has three clauses
## ("selection replicates, modifiers apply, second selection refused") and this file is the middle
## one.
##
## Two halves, deliberately:
##
##   1. **The catalogue half.** Every stat named by any of the four Attunement PowerupDefs is
##      actually consumed by shipped code. This is the regression guard that matters most — the
##      failure F-543 records is silent, so a future content edit that authors a stat nothing reads
##      must fail here rather than ship as a role that does nothing.
##   2. **The behaviour half.** Each consumer is driven for real, with a peer that holds the
##      Attunement and a peer that does not, and the two answers are required to differ in the
##      direction DESIGN §4.5 promises.
##
## Drives the REGISTERED autoloads (F-068/F-069), offline, so `_owns_mutation()` is true everywhere
## and every host path below is the shipped one.

const HOST_PEER: int = 1
const BARE_PEER: int = 44

## Every stat any Attunement PowerupDef names -> the file that must contain its read, and the
## `PowerupService` seam that read goes through. Kept as data so the assertion message can name the
## exact file to open when it fails.
const CONSUMER_SITES: Dictionary = {
	&"move_speed": ["res://entities/player/player_controller.gd", "local_stat"],
	&"max_hp": ["res://systems/health/player_health.gd", "stat"],
	&"food_value": ["res://systems/health/player_health.gd", "stat"],
	&"blight_rate": ["res://systems/health/player_health.gd", "stat"],
	&"harvest_yield": ["res://systems/harvesting/harvestable.gd", "stat"],
	&"harvest_damage": ["res://systems/harvesting/harvestable.gd", "stat"],
	&"melee_damage": ["res://autoload/combat_service.gd", "stat"],
	&"bow_damage": ["res://autoload/ranged_combat_service.gd", "stat"],
	&"craft_seconds": ["res://autoload/crafting_service.gd", "stat"],
	&"coin_gain": ["res://autoload/reward_service.gd", "stat"],
	&"ward_radius_m": ["res://autoload/build_service.gd", "stat"],
	&"structure_hp": ["res://autoload/build_service.gd", "stat"],
}

var failures: int = 0
var registry: Node
var powerups: Node
var attunements: Node


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	if not _check_wiring():
		finish()
		return

	_check_every_attunement_stat_has_a_consumer()
	_check_design_promises_are_authored()
	await _check_health_pool()
	_check_food_value()
	_check_blight_rate()
	_check_harvest()
	_check_craft_seconds()
	_check_coins()
	_check_ward_radius()
	_check_host_change_signal()
	_check_role_gated_building()

	print("\nATTUNEMENT_EFFECTS_CHECK failures=%d" % failures)
	finish()


func _check_wiring() -> bool:
	print("== the shipped project has the services these effects run through ==")
	registry = root.get_node_or_null(^"Registry")
	powerups = root.get_node_or_null(^"PowerupService")
	attunements = root.get_node_or_null(^"AttunementService")
	check(registry != null, "Registry is registered as an autoload")
	check(powerups != null, "PowerupService is registered as an autoload")
	check(attunements != null, "AttunementService is registered as an autoload")
	return registry != null and powerups != null and attunements != null


## The regression guard. Reads the consumer source and requires a `PowerupService` read of that exact
## stat name in it — a grep, deliberately, because the alternative (driving every consumer) cannot
## cover a stat whose consumer needs a physics body, and a stat with NO consumer is the whole bug.
func _check_every_attunement_stat_has_a_consumer() -> void:
	print("\n== every stat the four Attunements name is read by shipped code ==")
	var named: Dictionary[StringName, StringName] = {}
	for role_id: StringName in [&"warden", &"forager", &"tinker", &"reaver"]:
		var definition: Resource = registry.call(&"get_attunement", role_id)
		if definition == null:
			check(false, "content/attunements/%s.tres loads" % role_id)
			continue
		var backing: Resource = registry.call(
			&"get_powerup", StringName(definition.get(&"granted_powerup_id"))
		)
		if backing == null:
			check(false, "%s's backing powerup loads" % role_id)
			continue
		for stat_name: StringName in (backing.get(&"modifiers") as Dictionary):
			named[stat_name] = role_id

	check(not named.is_empty(), "the four roles name at least one stat between them")
	for stat_name: StringName in named:
		if not CONSUMER_SITES.has(stat_name):
			check(false, ("'%s' (from %s) has no consumer recorded in this check — either wire it " +
				"and add it to CONSUMER_SITES, or the Attunement is authoring a dead stat") % [
					stat_name, named[stat_name]
				])
			continue
		var site: Array = CONSUMER_SITES[stat_name]
		var source: String = _read_source(String(site[0]))
		check(source != "", "%s is readable" % site[0])
		check(source.contains("&\"%s\"" % stat_name) and source.contains("&\"%s\"" % site[1]),
			"'%s' is read through PowerupService.%s() in %s" % [stat_name, site[1], site[0]])


## DESIGN §4.5's table is the spec; a role that promises something the data never names is the same
## dead-effect bug one layer up. Each entry is a phrase from that table and the stat that carries it.
func _check_design_promises_are_authored() -> void:
	print("\n== DESIGN §4.5's better/worse promises each have a stat behind them ==")
	var promises: Dictionary = {
		&"warden": [&"ward_radius_m", &"structure_hp", &"move_speed", &"harvest_yield", &"harvest_damage"],
		&"forager": [&"harvest_yield", &"harvest_damage", &"food_value", &"melee_damage"],
		&"tinker": [&"craft_seconds", &"max_hp"],
		&"reaver": [&"melee_damage", &"bow_damage", &"coin_gain", &"blight_rate"],
	}
	for role_id: StringName in promises:
		var definition: Resource = registry.call(&"get_attunement", role_id)
		if definition == null:
			continue
		var backing: Resource = registry.call(
			&"get_powerup", StringName(definition.get(&"granted_powerup_id"))
		)
		if backing == null:
			continue
		var modifiers: Dictionary = backing.get(&"modifiers")
		for stat_name: StringName in promises[role_id]:
			check(modifiers.has(stat_name),
				"%s's PowerupDef carries '%s'" % [role_id, stat_name])


## Tinker: -15% max_hp. Proves the DownedState ceiling actually moves for a peer who already had a
## state before the pick — the exact order a real run uses (spawn, then pick at run start, D-071).
func _check_health_pool() -> void:
	print("\n== Tinker's -15% health pool reaches PlayerHealth's DownedState ==")
	var health: Node = root.get_node_or_null(^"PlayerHealth")
	if health == null:
		check(false, "PlayerHealth is registered as an autoload")
		return
	powerups.call(&"host_clear", HOST_PEER)
	health.call(&"_ensure_host_state", HOST_PEER)
	var base_max: int = int(health.call(&"host_max_hp", HOST_PEER)) if health.has_method(&"host_max_hp") \
		else int((health.get(&"_states") as Dictionary)[HOST_PEER].max_hp)
	check(base_max > 0, "an unattuned peer has the authored ceiling (%d)" % base_max)

	powerups.call(&"host_grant", HOST_PEER, &"attunement_tinker", 1)
	await process_frame
	var tinker_max: int = int((health.get(&"_states") as Dictionary)[HOST_PEER].max_hp)
	check(tinker_max < base_max,
		"a Tinker granted AFTER the state existed has a smaller pool (%d < %d)" % [tinker_max, base_max])
	var state: Object = (health.get(&"_states") as Dictionary)[HOST_PEER]
	check(int(state.hp) <= tinker_max and int(state.hp) >= 1,
		"and the shrink clamped current hp inside it without downing anyone (%d)" % int(state.hp))

	powerups.call(&"host_clear", HOST_PEER)
	await process_frame
	check(int((health.get(&"_states") as Dictionary)[HOST_PEER].max_hp) == base_max,
		"clearing the pick restores the authored ceiling — the effect is run-scoped, like the pick")


## Forager: +20% food_value. Driven through DownedState-free arithmetic — the consume path needs an
## inventory, so this asserts on the stat seam the consumer calls with the consumer's own base.
func _check_food_value() -> void:
	print("\n== Forager's +20% food value ==")
	powerups.call(&"host_clear", HOST_PEER)
	var base: float = 25.0
	var plain: float = float(powerups.call(&"stat", HOST_PEER, &"food_value", base))
	powerups.call(&"host_grant", HOST_PEER, &"attunement_forager", 1)
	var attuned: float = float(powerups.call(&"stat", HOST_PEER, &"food_value", base))
	check(is_equal_approx(plain, base), "an unattuned peer restores the authored amount")
	check(attuned > plain, "a Forager restores more per eat (%.2f > %.2f)" % [attuned, plain])
	var source: String = _read_source("res://systems/health/player_health.gd")
	check(source.contains("item.hunger_restore") and source.contains("&\"food_value\""),
		"and the consume path is what reads it, not something adjacent")
	powerups.call(&"host_clear", HOST_PEER)


## Reaver: +20% blight_rate — the ONLY negative in the set that makes the world hurt you faster.
func _check_blight_rate() -> void:
	print("\n== Reaver's +20% Blight rate ==")
	powerups.call(&"host_clear", HOST_PEER)
	var base: float = 2.0
	var plain: float = float(powerups.call(&"stat", HOST_PEER, &"blight_rate", base))
	powerups.call(&"host_grant", HOST_PEER, &"attunement_reaver", 1)
	var attuned: float = float(powerups.call(&"stat", HOST_PEER, &"blight_rate", base))
	check(attuned > plain, "a Reaver takes Blight faster (%.3f > %.3f)" % [attuned, plain])
	var source: String = _read_source("res://systems/health/player_health.gd")
	check(source.contains("BLIGHT_HP_DRAIN_PER_SEC_AT_FULL_CORRUPTION") \
		and source.contains("&\"blight_rate\""),
		"_tick_blight's own drain is what the stat scales")
	powerups.call(&"host_clear", HOST_PEER)


## Forager +25% / Warden -15%, on a REAL Harvestable driven through its real host seam.
func _check_harvest() -> void:
	print("\n== Forager gathers more per node than a Warden, on a real Harvestable ==")
	var definition: Resource = _first_harvestable_def()
	if definition == null:
		check(false, "at least one HarvestableDef is registered to test against")
		return
	powerups.call(&"host_clear", HOST_PEER)
	powerups.call(&"host_clear", BARE_PEER)

	var prop: Node3D = _spawn_harvestable(definition)
	if prop == null:
		return
	var plain_yield: int = int(prop.call(&"_yield_amount", BARE_PEER))
	powerups.call(&"host_grant", HOST_PEER, &"attunement_forager", 1)
	var forager_yield: int = int(prop.call(&"_yield_amount", HOST_PEER))
	powerups.call(&"host_clear", HOST_PEER)
	powerups.call(&"host_grant", HOST_PEER, &"attunement_warden", 1)
	var warden_yield: int = int(prop.call(&"_yield_amount", HOST_PEER))

	check(forager_yield > plain_yield or int(definition.get(&"yield_amount")) <= 2,
		"a Forager pulls more from the same node (%d vs %d, authored %d)" % [
			forager_yield, plain_yield, int(definition.get(&"yield_amount"))
		])
	check(warden_yield <= plain_yield,
		"a Warden pulls no more than an unattuned player (%d <= %d)" % [warden_yield, plain_yield])
	check(warden_yield >= 1, "and never pulls nothing at all — a consumed node always pays")

	# The gather-SPEED half. `harvest_damage` is what makes a Forager fell a tree in fewer swings.
	var base_bite: int = 20
	powerups.call(&"host_clear", HOST_PEER)
	var plain_bite: int = int(prop.call(&"_harvest_damage_for_peer", base_bite, HOST_PEER))
	powerups.call(&"host_grant", HOST_PEER, &"attunement_forager", 1)
	var forager_bite: int = int(prop.call(&"_harvest_damage_for_peer", base_bite, HOST_PEER))
	check(plain_bite == base_bite, "an unattuned swing takes the authored bite (%d)" % plain_bite)
	check(forager_bite > plain_bite,
		"a Forager's swing takes a bigger one — DESIGN §4.5's gather SPEED (%d > %d)" % [
			forager_bite, plain_bite
		])
	check(int(prop.call(&"_harvest_damage_for_peer", 0, HOST_PEER)) == 0,
		"and a wrong-tool zero stays zero — a positive modifier never mints damage bare hands lack")

	powerups.call(&"host_clear", HOST_PEER)
	prop.queue_free()


## Tinker: -20% craft_seconds, through CraftingService's own helper.
func _check_craft_seconds() -> void:
	print("\n== Tinker's -20% craft time ==")
	var crafting: Node = root.get_node_or_null(^"CraftingService")
	if crafting == null:
		check(false, "CraftingService is registered as an autoload")
		return
	powerups.call(&"host_clear", HOST_PEER)
	var base: float = 10.0
	check(is_equal_approx(float(crafting.call(&"_modified_craft_seconds", HOST_PEER, base)), base),
		"an unattuned craft takes the authored time")
	powerups.call(&"host_grant", HOST_PEER, &"attunement_tinker", 1)
	var attuned: float = float(crafting.call(&"_modified_craft_seconds", HOST_PEER, base))
	check(attuned < base, "a Tinker crafts faster (%.2f < %.2f)" % [attuned, base])
	check(is_equal_approx(float(crafting.call(&"_modified_craft_seconds", HOST_PEER, 0.0)), 0.0),
		"and an instant recipe stays instant rather than gaining a wait")
	powerups.call(&"host_clear", HOST_PEER)


## Reaver: +15% coin_gain, through RewardService's own helper — both its call sites share it.
func _check_coins() -> void:
	print("\n== Reaver's +15% coin drops ==")
	var rewards: Node = root.get_node_or_null(^"RewardService")
	if rewards == null:
		check(false, "RewardService is registered as an autoload")
		return
	powerups.call(&"host_clear", HOST_PEER)
	var base: int = 100
	check(int(rewards.call(&"_modified_coins", HOST_PEER, base)) == base,
		"an unattuned kill pays the rolled amount")
	powerups.call(&"host_grant", HOST_PEER, &"attunement_reaver", 1)
	check(int(rewards.call(&"_modified_coins", HOST_PEER, base)) > base,
		"a Reaver is paid more for the same roll")
	check(int(rewards.call(&"_modified_coins", HOST_PEER, 0)) == 0,
		"and a zero roll still pays nothing — the modifier scales a bounty, it does not create one")
	powerups.call(&"host_clear", HOST_PEER)


## Warden: +2 m ward radius, and the builder-attribution answer — the radius belongs to whoever
## PLACED the piece, not to whoever asks.
func _check_ward_radius() -> void:
	print("\n== Warden's +2 m ward radius, attributed to the builder ==")
	var build: Node = root.get_node_or_null(^"BuildService")
	if build == null:
		check(false, "BuildService is registered as an autoload")
		return
	powerups.call(&"host_clear", HOST_PEER)
	powerups.call(&"host_clear", BARE_PEER)
	var base: float = 12.0
	check(is_equal_approx(float(build.call(&"_owner_ward_radius", base, BARE_PEER)), base),
		"a piece placed by an unattuned player keeps the authored radius")
	powerups.call(&"host_grant", HOST_PEER, &"attunement_warden", 1)
	check(float(build.call(&"_owner_ward_radius", base, HOST_PEER)) > base,
		"a piece placed by a Warden is wider")
	check(is_equal_approx(float(build.call(&"_owner_ward_radius", base, BARE_PEER)), base),
		"and the Warden's pick does NOT widen a piece somebody else placed")
	powerups.call(&"host_clear", HOST_PEER)


## The seam that makes an already-spawned player hear about a pick at all.
func _check_host_change_signal() -> void:
	print("\n== PowerupService tells host consumers when a peer's stacks changed ==")
	check(powerups.has_signal(&"host_powerups_changed"),
		"host_powerups_changed exists — without it a max_hp or ward change is never re-derived")
	if not powerups.has_signal(&"host_powerups_changed"):
		return
	var seen: Array[int] = []
	var handler: Callable = func(peer_id: int) -> void: seen.append(peer_id)
	powerups.connect(&"host_powerups_changed", handler)
	powerups.call(&"host_grant", BARE_PEER, &"attunement_warden", 1)
	powerups.disconnect(&"host_powerups_changed", handler)
	check(seen.has(BARE_PEER), "and it fires with the peer whose stacks changed")
	powerups.call(&"host_clear", BARE_PEER)


## DESIGN §4.5's two non-stat build rules, as authored content (D-212). Read off the definitions
## rather than driven through a placement, because a real placement needs a physics world, a builder
## body and materials — none of which this rule depends on.
func _check_role_gated_building() -> void:
	print("\n== the Reaver's Ward ban is authored on the two Wards, not hard-coded ==")
	var build: Node = root.get_node_or_null(^"BuildService")
	check(build != null and build.has_method(&"_attunement_refusal"),
		"BuildService has the one host-side role gate")
	var wards_found: int = 0
	for buildable_id: StringName in (registry.get(&"buildables") as Dictionary):
		var def: Resource = registry.call(&"get_buildable", buildable_id)
		if def == null or not bool(def.call(&"is_ward")):
			continue
		wards_found += 1
		check((def.get(&"forbidden_attunement_ids") as Array).has(&"reaver"),
			"'%s' is a Ward and forbids the Reaver" % buildable_id)
	check(wards_found >= 1, "at least one Ward is registered to test (%d)" % wards_found)

	if build == null or not build.has_method(&"_attunement_refusal"):
		return
	var ward: Resource = registry.call(&"get_buildable", &"ward")
	var wall: Resource = registry.call(&"get_buildable", &"wall_wood")
	if ward == null or wall == null:
		check(false, "content/buildables/ward.tres and wall.tres (id wall_wood) both load")
		return
	attunements.call(&"host_clear_selection", HOST_PEER)
	powerups.call(&"host_clear", HOST_PEER)
	check(String(build.call(&"_attunement_refusal", ward, HOST_PEER)) == "",
		"an unattuned player may still raise a Ward — the ban is the ROLE's, not the picker's")
	attunements.call(&"request_select", &"reaver")
	check(String(build.call(&"_attunement_refusal", ward, HOST_PEER)) != "",
		"a Reaver is refused, with a reason: '%s'" % build.call(&"_attunement_refusal", ward, HOST_PEER))
	check(String(build.call(&"_attunement_refusal", wall, HOST_PEER)) == "",
		"and is refused ONLY the Ward — an ordinary wall is still theirs to build")
	attunements.call(&"host_clear_selection", HOST_PEER)
	powerups.call(&"host_clear", HOST_PEER)


# ── Helpers ──────────────────────────────────────────────────────────────────────────────────────


## HarvestableDefs are per-instance content (`harvest_library.gd`), not a Registry family — so this
## loads one by path rather than asking the Registry for a dictionary that does not exist. Boulder
## because its `yield_amount` is large enough that a ±25% modifier survives integer rounding.
func _first_harvestable_def() -> Resource:
	for path: String in [
		"res://content/harvestables/boulder.tres",
		"res://content/harvestables/bogsilver_node.tres",
		"res://content/harvestables/berry_bush.tres",
	]:
		var definition: Resource = load(path) as Resource
		if definition != null:
			return definition
	return null


func _spawn_harvestable(definition: Resource) -> Node3D:
	var script: Script = load("res://systems/harvesting/harvestable.gd")
	if script == null:
		check(false, "systems/harvesting/harvestable.gd loads")
		return null
	var prop: Node3D = Node3D.new()
	prop.set_script(script)
	prop.set(&"definition", definition)
	root.add_child(prop)
	return prop


func _read_source(path: String) -> String:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	return file.get_as_text()


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
