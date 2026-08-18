extends SceneTree

## Headless offline proof for task 3.10 — docs/SPECS.md 3.10, DESIGN.md §4.5/§5.
##
##   .agent/bin/agent godot --script tools/haul_check.gd
##
## Two halves. First, HaulMath as pure functions — no node, no session, no Registry — which is where
## "solo and duo math" is actually proved: DESIGN.md §5's slow-drag rule lives entirely in
## systems/hauling/haul_math.gd, and a pure function is the cheapest possible proof of it. Second, a
## real (host-of-one) Haulable spawned through HaulService: request_pickup/request_drop host
## validation, the 2-carrier cap, the "already carrying something else" rule, and the D-035
## rebind/expire contract — reaching into the "private" _accept_pickup() the same way
## tools/build_net_check.gd reaches into BuildService._process_place() to simulate a second peer
## without a second real connection (the real connection, and the teleport-proofing that needs one,
## is tools/haul_net_check.gd).
##
## Content/haulables/ ships with no worked-example .tres yet (D-031: the editor was open for the
## whole of this task — see docs/DECISIONS.md and docs/FINDINGS.md). This check injects a synthetic
## HaulableDef into the real Registry instead, exactly the way tools/chest_check.gd proves
## LootTableDef/ItemDef before any content existed for them.

const HAULABLE_DEF_SCRIPT := preload("res://systems/hauling/haulable_def.gd")
const HAUL_MATH := preload("res://systems/hauling/haul_math.gd")
## docs/SPECS.md's own preamble ordering (task 2.11's day_night_check.gd is the worked example):
## write the check, prove it, THEN `agent autoload` — so this check cannot assume /root/HaulService
## exists yet. Instantiated under that exact name (not a "...UnderTest" alias like DayNight's check
## uses) because Haulable._peer_hauling_elsewhere() path-looks-up "/root/HaulService" internally;
## this check needs that lookup to resolve for real.
const HAUL_SERVICE_SCRIPT := preload("res://autoload/haul_service.gd")

const TEST_DEF_ID: StringName = &"check_crate"
const UNKNOWN_DEF_ID: StringName = &"check_crate_missing"

var failures: int = 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_check_math_pure()

	var registry: Node = root.get_node_or_null(^"Registry")
	check(registry != null, "Registry autoload exists")
	if registry == null:
		finish()
		return

	var haul_service: Node = root.get_node_or_null(^"HaulService")
	if haul_service == null:
		# Not registered yet — see the const's own comment. Named exactly "HaulService" so every
		# internal /root/HaulService lookup this task's scripts make resolves for real.
		haul_service = HAUL_SERVICE_SCRIPT.new()
		haul_service.name = "HaulService"
		root.add_child(haul_service)
		await process_frame

	_check_def_validation()
	_inject_test_def(registry)
	check(registry.call("has_haulable", TEST_DEF_ID), "test def reachable through Registry.get_haulable")

	await _check_spawn_and_pickup(haul_service)

	_remove_test_def(registry)
	# host_spawn() on an unknown def id logs at ERROR (HaulService mirrors EnemyWorld.host_spawn's
	# own convention there) and this check deliberately provokes that path once, on purpose, to
	# prove the rejection. Standing rule 4 (docs/SPECS.md): declare it by pattern rather than
	# "fixing" it by silencing the production log call.
	print("HAUL_CHECK failures=%d · EXPECTED_ERROR_PATTERNS=\"unknown haulable id\"" % failures)
	finish()


# ── HaulMath, pure ──────────────────────────────────────────────────────────────────────────────


func _check_math_pure() -> void:
	print("\n-- HaulMath, pure --")

	var current := Vector3(0.0, 0.0, 0.0)
	check(
		HAUL_MATH.target_position([], current) == current,
		"no carriers: target is wherever the object already is"
	)
	var solo_carrier := Vector3(10.0, 0.0, 0.0)
	check(
		HAUL_MATH.target_position([solo_carrier], current) == solo_carrier,
		"one carrier: target is that carrier's own position"
	)
	var duo_a := Vector3(10.0, 0.0, 0.0)
	var duo_b := Vector3(20.0, 0.0, 0.0)
	check(
		HAUL_MATH.target_position([duo_a, duo_b], current) == Vector3(15.0, 0.0, 0.0),
		"two carriers: target is their midpoint"
	)

	var def: Resource = HAULABLE_DEF_SCRIPT.new()
	def.set("carry_track_speed_mps", 4.0)
	def.set("solo_drag_multiplier", 0.4)

	check(
		HAUL_MATH.step(current, solo_carrier, 0, def, 1.0) == current,
		"zero carriers: the object never moves, even with a target"
	)

	# Far target — well under the tick budget in every case below, so no move_toward clamp masks
	# the speed relationship.
	var far_target := Vector3(100.0, 0.0, 0.0)
	var solo_step: Vector3 = HAUL_MATH.step(current, far_target, 1, def, 1.0)
	var duo_step: Vector3 = HAUL_MATH.step(current, far_target, 2, def, 1.0)
	check(is_equal_approx(solo_step.x, 1.6), "solo: one second at 4.0 * 0.4 covers 1.6 m (%s)" % solo_step.x)
	check(is_equal_approx(duo_step.x, 4.0), "duo: one second at the full 4.0 m/s covers 4.0 m (%s)" % duo_step.x)
	check(duo_step.x > solo_step.x, "DESIGN.md §5: duo tracks strictly faster than solo's slow drag")

	# Near target — the object must land exactly on it, never overshoot past a lying carrier's claim.
	var near_target := Vector3(0.5, 0.0, 0.0)
	var landed: Vector3 = HAUL_MATH.step(current, near_target, 2, def, 1.0)
	check(landed == near_target, "step never overshoots the target, even at full speed (%s)" % landed)

	var solo_multiplier_zero: Resource = HAULABLE_DEF_SCRIPT.new()
	solo_multiplier_zero.set("carry_track_speed_mps", 4.0)
	solo_multiplier_zero.set("solo_drag_multiplier", 1.0)
	check(
		is_equal_approx(HAUL_MATH.step(current, far_target, 1, solo_multiplier_zero, 1.0).x, 4.0),
		"solo_drag_multiplier is the only thing that separates solo from duo speed"
	)


# ── HaulableDef.validation_errors() ────────────────────────────────────────────────────────────────


func _check_def_validation() -> void:
	print("\n-- HaulableDef.validation_errors() --")
	var valid: Resource = HAULABLE_DEF_SCRIPT.new()
	valid.set("id", TEST_DEF_ID)
	valid.set("display_name", "Check Crate")
	check((valid.call("validation_errors") as PackedStringArray).is_empty(), "a fully-authored def is valid")

	var no_id: Resource = HAULABLE_DEF_SCRIPT.new()
	no_id.set("display_name", "No Id")
	check(not (no_id.call("validation_errors") as PackedStringArray).is_empty(), "empty id is rejected")

	var bad_multiplier: Resource = HAULABLE_DEF_SCRIPT.new()
	bad_multiplier.set("id", &"bad")
	bad_multiplier.set("display_name", "Bad")
	bad_multiplier.set("solo_drag_multiplier", 1.5)
	check(
		not (bad_multiplier.call("validation_errors") as PackedStringArray).is_empty(),
		"solo_drag_multiplier above 1.0 is rejected"
	)


func _inject_test_def(registry: Node) -> void:
	var def: Resource = HAULABLE_DEF_SCRIPT.new()
	def.set("id", TEST_DEF_ID)
	def.set("display_name", "Check Crate")
	def.set("size", Vector3(1.0, 1.0, 1.5))
	def.set("pickup_range_m", 2.5)
	def.set("carry_track_speed_mps", 4.0)
	def.set("solo_drag_multiplier", 0.4)
	# F-060: Object.get() on a strictly-typed Dictionary property can hand back a value that does
	# not alias the original — always .set() it back after mutating.
	var haulables: Dictionary = registry.get("haulables")
	haulables[TEST_DEF_ID] = def
	registry.set("haulables", haulables)


func _remove_test_def(registry: Node) -> void:
	var haulables: Dictionary = registry.get("haulables")
	haulables.erase(TEST_DEF_ID)
	registry.set("haulables", haulables)


# ── Haulable, offline (host-of-one) ────────────────────────────────────────────────────────────────


func _check_spawn_and_pickup(haul_service: Node) -> void:
	print("\n-- Haulable, offline (host-of-one) --")

	var unknown: Node3D = haul_service.call("host_spawn", UNKNOWN_DEF_ID, Vector3.ZERO)
	check(unknown == null, "host_spawn refuses an unknown def id")

	var crate: Node3D = haul_service.call("host_spawn", TEST_DEF_ID, Vector3(5.0, 0.0, 5.0))
	check(crate != null, "host_spawn returns a real node for a known def")
	if crate == null:
		return
	await process_frame
	check(crate.is_in_group(&"haulable"), "spawned object joins the haulable group")
	check(int(haul_service.call("live_count")) == 1, "HaulService tracks exactly one live haulable")
	_check_replication(crate)

	var pickups: Array = []
	crate.connect(&"pickup_confirmed", func(rid, accepted, reason):
		pickups.append({"id": rid, "accepted": accepted, "reason": reason})
	)

	var local_peer: int = NetConfig.HOST_PEER_ID
	crate.call("request_pickup")
	check(pickups.size() == 1 and bool(pickups[0]["accepted"]), "offline pickup answers synchronously and is accepted")
	check((crate.get("carriers") as PackedInt32Array).has(local_peer), "carriers now includes the local peer")

	crate.call("request_pickup")
	check(
		pickups.size() == 2 and not bool(pickups[1]["accepted"]) and pickups[1]["reason"] == "already carrying this",
		"the same peer requesting pickup twice is refused"
	)

	# Simulate a second and third peer the same way tools/build_net_check.gd's "forge" phase reaches
	# into BuildService's own decision function — there is no second real connection offline.
	crate.call("_accept_pickup", 2, 900)
	check((crate.get("carriers") as PackedInt32Array).size() == 2, "a second peer is accepted (duo cap)")
	crate.call("_accept_pickup", 3, 901)
	check((crate.get("carriers") as PackedInt32Array).size() == 2, "a third peer is refused — 2 is the cap")

	# DESIGN.md §4.5: one pair of hands, not one slot per object. Asserted on the host-side EFFECT
	# (carriers stays empty), not on pickup_confirmed — that signal only fires for the local peer or
	# a connected remote one (see _answer_pickup), and peer 2 here is neither: it is simulated the
	# same reach-in way tools/build_net_check.gd's "forge" phase checks placed_count() directly
	# rather than listening for a confirmation nobody would route to it either.
	var second_crate: Node3D = haul_service.call("host_spawn", TEST_DEF_ID, Vector3(-5.0, 0.0, -5.0))
	await process_frame
	check(bool(haul_service.call("is_peer_hauling", 2, second_crate)), "HaulService.is_peer_hauling sees the first crate")
	second_crate.call("_accept_pickup", 2, 902)
	check(
		not (second_crate.get("carriers") as PackedInt32Array).has(2),
		"a peer already carrying one object cannot pick up a second"
	)

	var drops: Array = []
	crate.connect(&"drop_confirmed", func(rid, accepted, reason):
		drops.append({"accepted": accepted, "reason": reason})
	)
	crate.call("request_drop")
	check(drops.size() == 1 and bool(drops[0]["accepted"]), "the local peer can drop what it carries")
	check(not (crate.get("carriers") as PackedInt32Array).has(local_peer), "carriers no longer includes it")
	crate.call("request_drop")
	check(
		drops.size() == 2 and not bool(drops[1]["accepted"]) and drops[1]["reason"] == "not carrying this",
		"dropping something you don't carry is refused"
	)

	# D-035: NetSession's grace window, not peer_left, decides a carry's fate. HaulService's
	# subscription fans these out to every live haulable — simulated directly here, the same way
	# tools/inventory_net_check.gd-adjacent offline checks exercise InventoryService's own rebound
	# handler without a live NetSession.
	crate.call("_accept_pickup", 2, 903)
	haul_service.call("_on_run_player_rebound", 2, 20)
	check(
		(crate.get("carriers") as PackedInt32Array).has(20)
		and not (crate.get("carriers") as PackedInt32Array).has(2),
		"a reconnect's new peer id inherits the old one's carry (D-035 rebind)"
	)
	haul_service.call("_on_run_player_expired", 20)
	check(not (crate.get("carriers") as PackedInt32Array).has(20), "an expired grace window releases the carry")

	crate.queue_free()
	second_crate.queue_free()


func _check_replication(crate: Node3D) -> void:
	var sync := crate.get_node_or_null(NodePath(String(NetConfig.PLAYER_SYNC_NODE))) as MultiplayerSynchronizer
	check(sync != null, "code-built synchronizer exists, named like a player's (F-004)")
	if sync == null:
		return
	check(sync.get_multiplayer_authority() == NetConfig.HOST_PEER_ID, "synchronizer is host-authoritative")
	check(sync.root_path == NodePath(".."), "synchronizer replicates its parent")
	check(sync.is_in_group(NetConfig.SYNCED_GROUP), "counted by the net debug panel (D-024)")
	var properties: Array[NodePath] = sync.replication_config.get_properties()
	check(
		properties == [NodePath(".:position"), NodePath(".:carriers")],
		"position and carriers are the entire replicated schema (%s)" % [properties]
	)
	check(
		sync.replication_config.property_get_replication_mode(NodePath(".:position"))
			== SceneReplicationConfig.REPLICATION_MODE_ALWAYS,
		"position replicates ALWAYS — it is a continuous transform (D-043)"
	)
	check(
		sync.replication_config.property_get_replication_mode(NodePath(".:carriers"))
			== SceneReplicationConfig.REPLICATION_MODE_ON_CHANGE,
		"carriers replicates ON_CHANGE — it is discrete state that should snap (D-043)"
	)


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
