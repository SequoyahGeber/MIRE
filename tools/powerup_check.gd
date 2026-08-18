extends SceneTree

## Offline proof for task 3.3: powerups stack, stats resolve through one seam, families cross
## Resonance thresholds, and a reconnect does not cost you your run.
##
##   .agent/bin/agent godot --script tools/powerup_check.gd
##
## Drives the REGISTERED /root/PowerupService, not a private instance (F-068/F-069): a harness that
## builds its own copy proves the script works and says nothing about whether the shipped project
## loads it. Offline, `_owns_mutation()` is true, so this process is host-of-one and every host path
## below is the real one.
##
## Two of the definitions here are built in memory rather than authored as .tres. That is deliberate:
## task 3.4 authors the 40-60 real powerups in the inspector and is explicitly never agent-generated,
## so this check ships exactly ONE worked example (`content/powerups/swift_stride.tres`) and
## synthesises the rest. It also buys the assertion that matters most for §4.4 — a family is counted
## ACROSS different powerups, so three different Fire powerups resonate at one stack each.

const POWERUP_DEF := preload("res://systems/powerups/powerup_def.gd")

const HOST_PEER: int = 1
const CLIENT_PEER: int = 27

var failures: int = 0
var service: Node
var registry: Node
var _resonance_events: Array[Dictionary] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	if not _check_wiring():
		finish()
		return
	_install_test_definitions()

	_check_authored_example()
	_check_stacking_and_caps()
	_check_stat_seam()
	_check_resonance_thresholds()
	_check_resonance_signal_fires_on_crossings_only()
	_check_revoke_and_clear()
	_check_run_player_identity()

	print("\nPOWERUP_CHECK failures=%d" % failures)
	finish()


## F-068's lesson, applied on the way in rather than after the fact.
func _check_wiring() -> bool:
	print("== the shipped project actually has a powerup service ==")
	service = root.get_node_or_null(^"PowerupService")
	registry = root.get_node_or_null(^"Registry")
	check(service != null,
		"PowerupService is registered as an autoload — without this no powerup can ever be granted")
	check(registry != null, "Registry is registered as an autoload")
	if service == null or registry == null:
		return false
	check(int(service.get(&"RESONANCE_THRESHOLD")) == 3,
		"Resonance threshold is DESIGN §4.4's 3+ (%d)" % int(service.get(&"RESONANCE_THRESHOLD")))
	check(int(service.get(&"GREATER_RESONANCE_THRESHOLD")) == 6,
		"Greater Resonance threshold is §4.4's 6+ (%d)" %
			int(service.get(&"GREATER_RESONANCE_THRESHOLD")))
	return true


## The one authored .tres has to survive the real loader, or 3.4 is authoring against a shape that
## does not load.
func _check_authored_example() -> void:
	print("\n== the worked example loads through the real registry ==")
	var definition: Resource = registry.call(&"get_powerup", &"swift_stride")
	check(definition != null, "content/powerups/swift_stride.tres is indexed by its id")
	if definition == null:
		return
	check((definition.get(&"tags") as Array).has(&"Kinetic"), "it carries its §4.4 tag")
	check((definition.get(&"modifiers") as Dictionary).has(&"move_speed"),
		"it names the stat it modifies")
	check((definition.call(&"validation_errors") as PackedStringArray).is_empty(),
		"it validates clean")

	var broken: Resource = POWERUP_DEF.new()
	var errors: PackedStringArray = broken.call(&"validation_errors")
	check(not errors.is_empty(),
		"an empty PowerupDef is rejected rather than silently indexed (%s)" % ", ".join(errors))


func _check_stacking_and_caps() -> void:
	print("\n== stacks accumulate and stop at max_stacks ==")
	service.call(&"host_clear", HOST_PEER)
	var first: int = int(service.call(&"host_grant", HOST_PEER, &"swift_stride", 1))
	check(first == 1, "granting one returns one (%d)" % first)
	check(int(service.call(&"stacks_of", HOST_PEER, &"swift_stride")) == 1, "and is held")

	var bulk: int = int(service.call(&"host_grant", HOST_PEER, &"swift_stride", 99))
	check(bulk == 4, "a 99-stack grant is clamped to the remaining 4 (%d)" % bulk)
	check(int(service.call(&"stacks_of", HOST_PEER, &"swift_stride")) == 5, "capped at max_stacks")

	var overflow: int = int(service.call(&"host_grant", HOST_PEER, &"swift_stride", 1))
	check(overflow == 0,
		"granting past the cap returns 0 so a caller charging a cost can refund (%d)" % overflow)

	var unknown: int = int(service.call(&"host_grant", HOST_PEER, &"no_such_powerup", 1))
	check(unknown == 0, "an unregistered id is refused, not invented")


func _check_stat_seam() -> void:
	print("\n== stat() is the one seam, and the maths is (base + add*N) * (1 + mult*N) ==")
	service.call(&"host_clear", HOST_PEER)
	check(is_equal_approx(float(service.call(&"stat", HOST_PEER, &"move_speed", 4.4)), 4.4),
		"no stacks returns base untouched")
	check(is_equal_approx(float(service.call(&"stat", HOST_PEER, &"nonexistent_stat", 7.0)), 7.0),
		"a stat nothing modifies returns base")

	service.call(&"host_grant", HOST_PEER, &"swift_stride", 3)
	var expected: float = 4.4 * (1.0 + 0.08 * 3.0)
	var got: float = float(service.call(&"stat", HOST_PEER, &"move_speed", 4.4))
	check(is_equal_approx(got, expected),
		"3 stacks of +8%% multiplicative on 4.4 gives %.4f (got %.4f)" % [expected, got])

	# Additive and multiplicative together, and summed across two different powerups.
	service.call(&"host_grant", HOST_PEER, &"test_flat_speed", 2)
	expected = (4.4 + 0.5 * 2.0) * (1.0 + 0.08 * 3.0)
	got = float(service.call(&"stat", HOST_PEER, &"move_speed", 4.4))
	check(is_equal_approx(got, expected),
		"additive applies before multiplicative, across powerups: %.4f (got %.4f)" %
			[expected, got])
	service.call(&"host_clear", HOST_PEER)


func _check_resonance_thresholds() -> void:
	print("\n== a family counts across different powerups, and crosses at 3 and 6 ==")
	service.call(&"host_clear", HOST_PEER)
	check(int(service.call(&"resonance_tier", HOST_PEER, &"Fire")) == 0, "no stacks, no Resonance")

	# Three DIFFERENT Fire powerups at one stack each — §4.4 counts the tag, not the powerup.
	for powerup_id: StringName in [&"test_fire_a", &"test_fire_b", &"test_fire_c"]:
		service.call(&"host_grant", HOST_PEER, powerup_id, 1)
	check(int(service.call(&"family_count", HOST_PEER, &"Fire")) == 3,
		"three different Fire powerups count 3 toward the family")
	check(bool(service.call(&"resonance_active", HOST_PEER, &"Fire")),
		"3 of a tag triggers Resonance")
	check(not bool(service.call(&"greater_resonance_active", HOST_PEER, &"Fire")),
		"3 is not yet a Greater Resonance")

	service.call(&"host_grant", HOST_PEER, &"test_fire_a", 3)
	check(int(service.call(&"family_count", HOST_PEER, &"Fire")) == 6, "stacking the same one adds")
	check(bool(service.call(&"greater_resonance_active", HOST_PEER, &"Fire")),
		"6 of a tag triggers Greater Resonance")

	# A two-tag powerup feeds both families (§4.4: "each powerup has 1-2 tags").
	service.call(&"host_grant", HOST_PEER, &"test_dual", 1)
	check(int(service.call(&"family_count", HOST_PEER, &"Blood")) == 1,
		"a dual-tag powerup counts toward its second family")
	check(int(service.call(&"family_count", HOST_PEER, &"Fire")) == 7,
		"and toward its first at the same time")
	service.call(&"host_clear", HOST_PEER)


func _check_resonance_signal_fires_on_crossings_only() -> void:
	print("\n== resonance_changed fires on crossings, not on every grant ==")
	service.call(&"host_clear", HOST_PEER)
	_resonance_events.clear()
	service.connect(&"resonance_changed", _on_resonance_changed)

	service.call(&"host_grant", HOST_PEER, &"test_fire_a", 2)
	check(_resonance_events.is_empty(), "two stacks is below the threshold and says nothing")
	service.call(&"host_grant", HOST_PEER, &"test_fire_a", 1)
	check(_resonance_events.size() == 1, "the third stack fires exactly once (%d)" %
		_resonance_events.size())
	if not _resonance_events.is_empty():
		check(int(_resonance_events[0]["tier"]) == 1, "and reports the ACTIVE tier")
	service.call(&"host_grant", HOST_PEER, &"test_fire_a", 1)
	check(_resonance_events.size() == 1, "a fourth stack is still ACTIVE and does not re-fire")

	# Falling back below the threshold is a crossing too — a Resonance that never switches off is
	# how a revoked powerup leaves a permanent effect behind.
	service.call(&"host_revoke", HOST_PEER, &"test_fire_a", 2)
	check(_resonance_events.size() == 2, "dropping under 3 fires again (%d)" %
		_resonance_events.size())
	if _resonance_events.size() >= 2:
		check(int(_resonance_events[1]["tier"]) == 0, "and reports NONE")

	service.disconnect(&"resonance_changed", _on_resonance_changed)
	service.call(&"host_clear", HOST_PEER)


func _check_revoke_and_clear() -> void:
	print("\n== revoke and clear ==")
	service.call(&"host_clear", HOST_PEER)
	service.call(&"host_grant", HOST_PEER, &"swift_stride", 3)
	var removed: int = int(service.call(&"host_revoke", HOST_PEER, &"swift_stride", 1))
	check(removed == 1 and int(service.call(&"stacks_of", HOST_PEER, &"swift_stride")) == 2,
		"revoking one leaves two")
	removed = int(service.call(&"host_revoke", HOST_PEER, &"swift_stride", 99))
	check(removed == 2, "revoking more than held removes what is there and reports it (%d)" % removed)
	check(int(service.call(&"stacks_of", HOST_PEER, &"swift_stride")) == 0, "and reaches zero")
	check((service.call(&"families_of", HOST_PEER) as Dictionary).get(&"Kinetic", 0) == 0,
		"the family count follows it down rather than stranding a 0-stack entry")

	service.call(&"host_grant", HOST_PEER, &"swift_stride", 2)
	service.call(&"host_clear", HOST_PEER)
	check(int(service.call(&"stacks_of", HOST_PEER, &"swift_stride")) == 0, "clear empties the peer")


## D-035's consumer contract, which is the whole reason this state is not keyed by raw peer id in
## spirit: a reconnect must not cost a run's powerups, and unlike an inventory they cannot be
## re-gathered.
func _check_run_player_identity() -> void:
	print("\n== D-035: a reconnect keeps your run, an expiry ends it ==")
	service.call(&"host_clear", CLIENT_PEER)
	service.call(&"host_grant", CLIENT_PEER, &"swift_stride", 4)

	service.call(&"_on_peer_left", CLIENT_PEER)
	check(int(service.call(&"stacks_of", CLIENT_PEER, &"swift_stride")) == 4,
		"peer_left alone does NOT drop powerups — it cannot tell a reconnect from a departure")

	var rebound_peer: int = CLIENT_PEER + 100
	service.call(&"_on_run_player_rebound", CLIENT_PEER, rebound_peer)
	check(int(service.call(&"stacks_of", rebound_peer, &"swift_stride")) == 4,
		"run_player_rebound moves the stacks onto the new peer id")
	check(int(service.call(&"stacks_of", CLIENT_PEER, &"swift_stride")) == 0,
		"and leaves nothing behind on the old one")
	check(int(service.call(&"family_count", rebound_peer, &"Kinetic")) == 4,
		"the derived family counts move with it")

	service.call(&"_on_run_player_expired", rebound_peer)
	check(int(service.call(&"stacks_of", rebound_peer, &"swift_stride")) == 0,
		"run_player_expired is what actually drops a run-player's powerups")


func _on_resonance_changed(peer_id: int, family: StringName, tier: int) -> void:
	_resonance_events.append({"peer": peer_id, "family": family, "tier": tier})


## Built in memory and injected into the live registry. 3.4 authors the real content by hand; this
## is the minimum needed to prove family aggregation across DIFFERENT powerups and the 6+ tier,
## which one .tres capped at 5 stacks cannot reach on its own.
func _install_test_definitions() -> void:
	_define(&"test_flat_speed", [&"Kinetic"], 5, {&"move_speed": Vector2(0.5, 0.0)})
	_define(&"test_fire_a", [&"Fire"], 9, {})
	_define(&"test_fire_b", [&"Fire"], 9, {})
	_define(&"test_fire_c", [&"Fire"], 9, {})
	_define(&"test_dual", [&"Fire", &"Blood"], 9, {})


func _define(id: StringName, tags: Array, max_stacks: int, modifiers: Dictionary) -> void:
	var definition: Resource = POWERUP_DEF.new()
	definition.set(&"id", id)
	definition.set(&"display_name", String(id))
	definition.set(&"max_stacks", max_stacks)
	var typed_tags: Array[StringName] = []
	for tag: Variant in tags:
		typed_tags.append(tag as StringName)
	definition.set(&"tags", typed_tags)
	var typed_modifiers: Dictionary[StringName, Vector2] = {}
	for stat_name: Variant in modifiers:
		typed_modifiers[stat_name as StringName] = modifiers[stat_name] as Vector2
	definition.set(&"modifiers", typed_modifiers)
	(registry.get(&"powerups") as Dictionary)[id] = definition


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
