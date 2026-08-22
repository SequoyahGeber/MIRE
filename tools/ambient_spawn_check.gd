extends SceneTree

## F-392's proof, headless. Reported from play (2026-08-20, Sequoyah): "a crawler randomly spawned in
## the middle of the map right after i respawned during the day".
##
## `EnemyWorld`'s ambient loop picked a nest marker at random, scattered it by up to 4 m, and spawned
## — with no reference at all to where anybody was standing. This check holds it to the three rules
## F-392 asks for, and it drives the REAL producers for each: no direct calls into
## `EnemyWorld._on_downed_flag_changed()`, because a check that pokes the consumer's handler proves
## the handler and not the wiring (F-310), and the wiring is exactly what fails silently here — this
## autoload is registered BEFORE PlayerHealth in project.godot, so an eager connect finds nothing.
##
##   1. Wiring: `PlayerHealth.downed_flag_changed` really is connected to EnemyWorld by the time the
##      first frame ends, despite that autoload-order hazard.
##   2. The guard: with a legal nest available, nothing lands inside `ambient_min_player_distance_m`
##      of a live player, even when a player is standing on top of another nest.
##   3. The fallback: when EVERY nest is inside the guard, the loop still fills the field (an empty
##      daytime world is the worse bug) and picks the FURTHEST nest, pushed one scatter length
##      further away — it never silently spawns nothing, and it never takes the near one.
##   4. The respawn grace: a real bleed-out -> death -> respawn cycle, ticked through PlayerHealth's
##      own `_physics_process`, stops ambient spawning entirely for `AMBIENT_RESPAWN_GRACE_SEC`, and
##      that clock burns down even while `ambient_enabled` is false (WaveSpawner owns the field at
##      night, and a grace owed at dusk must not still be owed at dawn).
##
##   5. F-538, the composition: the daytime field is a SPREAD of the crawler variants, not one
##      hardcoded id. `strider`, `tusker` and `broodcaller` were authored and tuned by task 5.2 and
##      then spawned by nothing — `ambient_enemy` named only `crawler`, and `WaveSpawner` rolls the
##      night ladder, which is a different set. This asserts every variant is actually reachable and
##      that the plain crawler is still the common case.
##
##   .agent/bin/agent godot --script tools/ambient_spawn_check.gd

## Constants are not properties, so `world.get("AMBIENT_RESPAWN_GRACE_SEC")` would hand back null —
## read them off the script the autoload is running, the same way tools/wellspring_check.gd reads
## `SOLO_DURATION_SEC`.
const ENEMY_WORLD_SCRIPT := preload("res://autoload/enemy_world.gd")

const NEST_GROUP: StringName = &"authored_world_marker"
const NEST_KIND: String = "enemy_nest"

var failures: int = 0
var world: Node
var health: Node


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	# Two frames, not one: EnemyWorld's PlayerHealth bind is a `call_deferred()` out of its `_ready()`
	# (project.godot registers it above PlayerHealth), and section 1 asserts that it landed.
	await process_frame
	await process_frame

	world = root.get_node_or_null(^"EnemyWorld")
	health = root.get_node_or_null(^"PlayerHealth")
	check(world != null, "EnemyWorld autoload exists")
	check(health != null, "PlayerHealth autoload exists")
	if world == null or health == null:
		_report()
		return

	# Every timer in this check is driven by hand. Left running, EnemyWorld's own ambient tick would
	# top the field up between assertions, PlayerHealth's would drain hunger and advance the very
	# bleed-out clock section 4 steps deliberately, and DefeatService would call a team wipe the
	# moment it saw a synthetic player body whose peer has no health state — which sets
	# `PlayerHealth._run_over` and freezes the respawn this check needs. Same reasoning
	# `tools/player_vitals_check.gd` gives for disabling PlayerHealth's `_physics_process`.
	world.set_physics_process(false)
	health.set_physics_process(false)
	var defeat: Node = root.get_node_or_null(^"DefeatService")
	if defeat != null:
		defeat.set_physics_process(false)

	_check_respawn_wiring()
	await _check_distance_guard()
	await _check_furthest_fallback()
	await _check_respawn_grace()
	await _check_ambient_composition()
	_report()


func _report() -> void:
	print("\nAMBIENT_SPAWN_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)


# ── 1. The wiring that fails as silence ───────────────────────────────────────────────────────────


## project.godot lists EnemyWorld above PlayerHealth, so `_ready()` cannot see it — the bind is
## deferred a frame. This asserts the deferred call actually landed, because the failure mode if it
## did not is not an error anywhere: ambient spawning simply keeps ignoring respawns forever.
func _check_respawn_wiring() -> void:
	print("== F-392: EnemyWorld is subscribed to PlayerHealth's downed flag ==")
	var bound: bool = false
	for connection: Dictionary in health.get_signal_connection_list(&"downed_flag_changed"):
		var callable: Callable = connection.get("callable", Callable())
		if callable.get_object() == world:
			bound = true
	check(bound,
		"PlayerHealth.downed_flag_changed reaches EnemyWorld despite the autoload order")


# ── 2. The distance guard ─────────────────────────────────────────────────────────────────────────


func _check_distance_guard() -> void:
	print("\n== F-392: nothing spawns inside the guard radius when a legal nest exists ==")
	var origin := Vector3(2000.0, 0.0, 2000.0)
	var minimum: float = float(world.get("ambient_min_player_distance_m"))
	check(minimum >= 25.0,
		"the guard radius is at least the 25 m F-392 asks for (%.1f m)" % minimum)

	# The player stands ON one nest — the reported case, and the one the old code spawned into.
	var occupied: Node3D = _nest(origin)
	var distant: Node3D = _nest(origin + Vector3(0.0, 0.0, 200.0))
	var player: Node3D = _player(origin, 1)
	check((world.call("ambient_spawn_points") as Array).size() == 2,
		"both nest markers are visible to EnemyWorld")

	var spawned: Array[Node3D] = await _fill(4)
	check(spawned.size() == 4, "the field still fills to the population (%d of 4)" % spawned.size())
	var closest: float = _closest_to(spawned, player)
	check(closest >= minimum,
		"the nearest ambient spawn is %.1f m away, past the %.1f m guard" % [closest, minimum])
	check(_all_nearer_to(spawned, distant, occupied),
		"every one of them came off the distant nest, not the one under the player")

	await _clear([occupied, distant, player])


# ── 3. The fallback — never "spawn nothing" ───────────────────────────────────────────────────────


## F-392: "fall back to the furthest available point when every nest is too close rather than
## spawning nothing". Both halves matter. An ambient loop that declines is not a safe ambient loop —
## it is a daytime world that empties out and stays empty, because this loop IS the daytime
## population (`systems/waves/wave_spawner.gd` suppresses it only at night).
func _check_furthest_fallback() -> void:
	print("\n== F-392: every nest too close -> the furthest one, pushed away, never nothing ==")
	var origin := Vector3(-3000.0, 0.0, -3000.0)
	var scatter: float = float(world.get("ambient_scatter_m"))
	var near: Node3D = _nest(origin + Vector3(6.0, 0.0, 0.0))
	var far: Node3D = _nest(origin + Vector3(15.0, 0.0, 0.0))
	var player: Node3D = _player(origin, 1)

	var spawned: Array[Node3D] = await _fill(3)
	check(spawned.size() == 3,
		"the field still fills with no legal nest anywhere (%d of 3)" % spawned.size())
	check(_all_nearer_to(spawned, far, near),
		"the furthest nest is the one that gets used, not the near one")
	# Deterministic, unlike the scattered path: the fallback walks the winner one full scatter length
	# directly away from the nearest player, so 15 m + 4 m is an exact number, not a range.
	var expected: float = 15.0 + scatter
	var closest: float = _closest_to(spawned, player)
	check(is_equal_approx(closest, expected),
		"and it is pushed a scatter length further out — %.2f m, expected %.2f m"
			% [closest, expected])

	await _clear([near, far, player])


# ── 4. The respawn grace, driven through PlayerHealth itself ──────────────────────────────────────


func _check_respawn_grace() -> void:
	print("\n== F-392: a real respawn buys a few seconds of silence ==")
	var origin := Vector3(5000.0, 0.0, 5000.0)
	var peer_id: int = 909
	# The nest is 100 m from the player, so the distance guard alone would happily spawn here — the
	# only thing that can stop this section is the grace itself.
	var nest: Node3D = _nest(origin)
	var player: Node3D = _player(origin + Vector3(0.0, 0.0, 100.0), peer_id)
	await _clear_enemies()

	var grace: float = ENEMY_WORLD_SCRIPT.AMBIENT_RESPAWN_GRACE_SEC
	check(grace > 0.0, "AMBIENT_RESPAWN_GRACE_SEC is a real window (%.1f s)" % grace)

	# The real producer path: damage down -> bleed out -> DEAD -> respawn, ticked through
	# PlayerHealth's own _physics_process exactly as the shipped game reaches it.
	health.call(&"_ensure_host_state", peer_id)
	var lethal: int = int(health.get("max_hp"))
	check(bool(health.call(&"host_apply_damage", peer_id, lethal, 0)), "the peer goes down")
	health.call(&"_physics_process", float(health.get("bleed_out_seconds")) + 1.0)
	check(not bool(health.call(&"host_is_alive", peer_id)), "and bleeds out")
	health.call(&"_physics_process", float(health.get("respawn_seconds")) + 1.0)
	check(bool(health.call(&"host_is_alive", peer_id)), "then respawns")

	check(float(world.get("_ambient_grace_remaining")) > 0.0,
		"the respawn armed EnemyWorld's ambient grace")
	check(int(world.call("top_up_ambient")) == 0,
		"nothing at all spawns while the grace is owed, however far away the nest is")
	check(int(world.call("live_count")) == 0, "and the field really is still empty")

	# The countdown has to survive a night: WaveSpawner turns `ambient_enabled` off and owns the
	# field until dawn, and a grace that froze there would still be owed hours later.
	world.set("ambient_enabled", false)
	world.call("_physics_process", grace + 1.0)
	check(is_equal_approx(float(world.get("_ambient_grace_remaining")), 0.0),
		"the grace burns down even while ambient spawning is disabled for the night")
	world.set("ambient_enabled", true)
	check(int(world.call("top_up_ambient")) > 0, "once it expires, the loop fills the field again")

	await _clear([nest, player])


# ── Harness ───────────────────────────────────────────────────────────────────────────────────────


## A nest marker in the shape `authored_world_marker`/`enemy_nest` that `ambient_spawn_points()`
## reads on the procedural map — the real source, not a stubbed spawn-point list.
func _nest(position: Vector3) -> Node3D:
	var marker := Marker3D.new()
	marker.name = "CheckNest%d" % randi()
	marker.add_to_group(NEST_GROUP)
	marker.set_meta(&"kind", NEST_KIND)
	root.add_child(marker)
	marker.global_position = position
	return marker


## A stand-in player body: `EnemyWorld` reads the `&"players"` group and nothing else about it, the
## same duck-typed contract `Wellspring._present_count()` uses.
func _player(position: Vector3, peer_id: int) -> Node3D:
	var body := Node3D.new()
	body.name = "CheckPlayer%d" % peer_id
	body.add_to_group(&"players")
	body.set_multiplayer_authority(peer_id)
	root.add_child(body)
	body.global_position = position
	return body


## Empties the field, then tops it up to `population` and returns exactly the bodies that top-up
## added. The await matters: `host_despawn_all()` uses `queue_free()`, so the old bodies are still
## instance-valid (and still counted by `live_count()`) until the frame ends.
func _fill(population: int) -> Array[Node3D]:
	await _clear_enemies()
	world.set("ambient_population", population)
	world.call("top_up_ambient")
	var spawned: Array[Node3D] = []
	for node: Node in (world.call("live_enemies") as Array):
		var body := node as Node3D
		if body != null:
			spawned.append(body)
	return spawned


func _clear_enemies() -> void:
	world.call("host_despawn_all")
	await process_frame


func _clear(nodes: Array) -> void:
	for node: Node in nodes:
		node.queue_free()
	await _clear_enemies()


# ── 5. F-538: the daytime field is a spread, not one id ───────────────────────────────────────────


## Two separate claims, because they fail in different directions and a single "did we see variety"
## assertion would pass on either bug alone.
##
##   · Reachability — every id in `ambient_variants` comes out of the roll. This is the F-538 bug
##     itself: three authored `EnemyDef`s that no spawn path in the shipped game could produce.
##   · Proportion — the plain `ambient_enemy` still dominates. A uniform swap would "fix" the first
##     claim and replace the reported symptom with its mirror image: a day where the ordinary crawler
##     is now the rare one and every body is a tinted special.
##
## The roll is sampled directly rather than through `top_up_ambient()`: the population is capped at
## 24, so a fill-based sample could never separate "a variant is unreachable" from "a variant did not
## come up in 24 draws". The integration half — that a real fill honours the roll — is the last
## assertion, which drives the actual producer.
func _check_ambient_composition() -> void:
	print("\n== F-538: the ambient field spreads across the crawler variants ==")
	var base: StringName = StringName(world.get("ambient_enemy"))
	var variants: Array = world.get("ambient_variants")
	check(variants.size() >= 3,
		"more than one crawler variant is authored into the daytime field (%d)" % variants.size())
	for id: StringName in variants:
		check(bool(world.call("has_def", id)),
			"the daytime field names a real EnemyDef: '%s'" % id)

	var samples: int = 4000
	var counts: Dictionary = {}
	for _i: int in samples:
		var id: StringName = StringName(world.call("_roll_ambient_kind"))
		counts[id] = int(counts.get(id, 0)) + 1
	print("   sampled %d rolls: %s" % [samples, counts])

	for id: StringName in variants:
		check(int(counts.get(id, 0)) > 0,
			"'%s' is reachable from the ambient roll at all — the F-538 bug" % id)
	var base_share: float = float(counts.get(base, 0)) / float(samples)
	# The authored weights are 6 against four variants at 1 each, so 0.60 exactly; the window is wide
	# enough that retuning `ambient_base_weight` within its intent does not fail the check, and tight
	# enough to catch both "one id again" (1.0) and "flat split" (0.20).
	check(base_share > 0.40 and base_share < 0.85,
		"the plain '%s' is still the common case but not the only one (%.2f of the field)"
			% [base, base_share])

	# The producer, end to end: a real top-up puts something other than the base kind on the ground.
	# Twelve fills of four rather than one fill, because at a 60% base share a single field of four is
	# all-crawler about one time in eight and this must not be a check that fails one run in eight.
	var nest: Node3D = _nest(Vector3(5000.0, 0.0, 5000.0))
	var seen: Dictionary = {}
	for _round: int in 12:
		for body: Node3D in await _fill(4):
			var definition: Resource = body.get("definition")
			if definition != null:
				seen[StringName(definition.get("id"))] = true
	check(seen.size() > 1,
		"a real top_up_ambient() field contains more than one kind: %s" % [seen.keys()])
	await _clear([nest])


## Horizontal distance, matching the guard's own measure — a marker authored at y=0 under a body
## standing 1.8 m up is not further away for it.
func _flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


func _closest_to(spawned: Array[Node3D], player: Node3D) -> float:
	var closest: float = INF
	for body: Node3D in spawned:
		closest = minf(closest, _flat_distance(body.global_position, player.global_position))
	return closest


func _all_nearer_to(spawned: Array[Node3D], wanted: Node3D, other: Node3D) -> bool:
	for body: Node3D in spawned:
		var to_wanted: float = _flat_distance(body.global_position, wanted.global_position)
		var to_other: float = _flat_distance(body.global_position, other.global_position)
		if to_wanted >= to_other:
			return false
	return true


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)
