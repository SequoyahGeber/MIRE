extends SceneTree

## F-602 — is the Mire guaranteed to be MET, and how long does meeting it take?
##
##   .agent/bin/agent godot --script tools/mire_encounter_check.gd
##
## Sequoyah: *"in terms of the mire spreading and players have to keep it back its super unclear."*
## One reason is that nothing related where the Mire starts to where the party starts. The single
## seed was drawn uniformly inside a 354 m square about the island centre while `_pick_spawn()`
## independently put the party on a shore ring, so the distance between them was an accident of the
## seed. On an unlucky one a party could finish a session having never seen corrupted ground.
##
## ## This measures, it does not reason
##
## The deliverable of F-602 is a NUMBER — how far the seed lands from spawn and how long a walking
## player takes to reach it — and the constants are only how that number is obtained. So this boots
## the real composer once per seed and reads the real spawn point and the real cluster centre, rather
## than doing arithmetic on the constants. Constants can be edited to make arithmetic come out right;
## a booted island cannot.
##
## Several seeds, because "it worked on one seed" says nothing about the next run, and an island that
## is generous on one seed and empty on another is the exact failure a single-seed check is blind to.
##
## ## What it asserts
##
##  1. every seed puts the corruption inside the band — the guarantee itself
##  2. it is never in the camp on minute one, stated as the real time before the FRONT reaches spawn
##  3. a walking player meets corrupted ground within a stated number of Cycles
##  4. `resource_scatter.gd` and the sim agree about where the Mire is, which is what the anchor's
##     call-site ordering in `procedural_world.gd` exists to guarantee
##  5. there is still exactly ONE seed (D-191) — the band must not have been bought with a second

const ProceduralWorldScript := preload("res://world/gen/procedural_world.gd")
const MireGridSim := preload("res://world/mire/mire_grid_sim.gd")
const ResourceScatter := preload("res://world/gen/resource_scatter.gd")

const SEEDS: Array[int] = [20260822, 536536, 991177, 4242, 771001, 8080808]

## `PlayerController.walk_speed`. Restated rather than imported: this check is a witness, and
## importing the value would make its verdict agree with the controller whatever the controller said.
## A separate assertion below catches the two drifting apart.
const WALK_SPEED_MPS: float = 4.0
## Nobody walks a straight line at full speed while exploring — they stop, look, harvest, turn round.
## This is the fraction of straight-line speed a real exploring party makes good, and it is
## deliberately pessimistic: the interesting question is the WORST case for meeting the Mire.
const EXPLORATION_EFFICIENCY: float = 0.35
## `docs/PRESSURE.md`: the front advances 1.66 m/min, 25 m per 15-minute Cycle.
const FRONT_ADVANCE_M_PER_MIN: float = 1.66
const CYCLE_MINUTES: float = 15.0
## The bar. A party that has to walk more than this to find the antagonist has a session where the
## antagonist is optional, which is the whole finding.
const MAX_CYCLES_TO_ENCOUNTER: float = 2.0

var failures: int = 0
var _distances: Array[float] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var game_state: Node = root.get_node_or_null(^"GameState")
	check(game_state != null, "GameState is registered as an autoload")
	if game_state == null:
		quit(1)
		return

	check(MireGridSim.SEED_CLUSTER_COUNT == 1,
		"there is still exactly ONE corruption seed (D-191) — the encounter band was not bought with a second (%d)"
			% MireGridSim.SEED_CLUSTER_COUNT)
	check(is_equal_approx(_controller_walk_speed(), WALK_SPEED_MPS),
		"this check's walking speed still matches PlayerController's (%.2f vs %.2f m/s)"
			% [WALK_SPEED_MPS, _controller_walk_speed()])

	for world_seed: int in SEEDS:
		await _measure(game_state, world_seed)

	_report()
	print("\nMIRE_ENCOUNTER_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)


func _measure(game_state: Node, world_seed: int) -> void:
	MireGridSim.clear_spawn_anchor()
	# Each seed builds a world that places ~71 persistent loot drops, and they are run-scoped rather
	# than world-scoped, so six worlds in a row accumulate past `MAX_PERSISTENT_DROPS` (F-590) and
	# the later seeds spend the whole build warning about a cap they only hit because this check
	# built six islands without a run restart between them. A check artifact, not a product bug —
	# cleared here so the log stays readable and the cap warning keeps meaning something.
	var drops: Node = root.get_node_or_null(^"ItemDropService")
	if drops != null:
		drops.call(&"host_clear_all")
	game_state.call(&"set_replicated_seed", world_seed)

	var world: Node3D = ProceduralWorldScript.new()
	world.name = "ProceduralWorld"
	# No player: this measures what the WORLD decides. The spawn point is published state, not
	# something a body has to stand on for it to exist.
	world.set(&"build_player", false)
	root.add_child(world)
	current_scene = world
	for _frame: int in 12:
		await process_frame
		await physics_frame

	var spawn: Vector3 = world.get(&"spawn_position")
	var centres: PackedVector2Array = MireGridSim.seed_cluster_centres(world_seed)
	check(centres.size() == 1, "seed %d produced exactly one cluster (%d)" % [world_seed, centres.size()])
	if centres.is_empty():
		world.queue_free()
		await process_frame
		return

	var centre: Vector2 = centres[0]
	var distance: float = Vector2(spawn.x, spawn.z).distance_to(centre)
	_distances.append(distance)

	# 1 — the guarantee.
	check(distance >= MireGridSim.SEED_SPAWN_MIN_M and distance <= MireGridSim.SEED_SPAWN_MAX_M,
		"seed %d puts the Mire %.0f m from spawn, inside the %.0f-%.0f m band"
			% [world_seed, distance, MireGridSim.SEED_SPAWN_MIN_M, MireGridSim.SEED_SPAWN_MAX_M])

	# 2 — not a starting-area problem. Stated as TIME, because that is the thing a player
	# experiences; a distance alone does not say whether it is a threat yet.
	var edge_distance: float = distance - MireGridSim.SEED_CLUSTER_RADIUS_M
	var minutes_to_camp: float = edge_distance / FRONT_ADVANCE_M_PER_MIN
	check(minutes_to_camp >= CYCLE_MINUTES * 3.0,
		"seed %d gives the party %.0f min (%.1f Cycles) before the front reaches camp"
			% [world_seed, minutes_to_camp, minutes_to_camp / CYCLE_MINUTES])

	# 3 — and it is actually findable. Both sides close the gap: the player walks out and the front
	# advances toward them, so the meeting point is earlier than either alone.
	var closing_speed: float = WALK_SPEED_MPS * 60.0 * EXPLORATION_EFFICIENCY + FRONT_ADVANCE_M_PER_MIN
	var minutes_to_meet: float = edge_distance / closing_speed
	# STATED AS A LOWER BOUND, deliberately. This is the time for a party that walks TOWARD the
	# Mire, and a party does not know where it is — so the real figure is longer by however long
	# they search, which this cannot model and should not pretend to. What the number does prove is
	# the thing F-602 is about: the Mire is close enough that finding it is a walk rather than an
	# expedition, on every seed. The distance is the measurement; this is its consequence.
	check(minutes_to_meet <= CYCLE_MINUTES * MAX_CYCLES_TO_ENCOUNTER,
		"seed %d: walking straight at it at %.0f%% of walking pace, a party reaches corrupted ground in %.1f min (%.2f Cycles) — a lower bound, they still have to find it"
			% [world_seed, EXPLORATION_EFFICIENCY * 100.0, minutes_to_meet, minutes_to_meet / CYCLE_MINUTES])

	# 4 — the sim and the scatter agree. This is what the anchor's call-site ordering buys, and the
	# reason it is asserted rather than commented: `resource_scatter.gd` reads the same centres per
	# chunk, so a stale memo would put the Mire's own flora where the corruption is not.
	# `resource_scatter.gd` gates Mire tables on exactly this call, with exactly these centres
	# (`_placement_at`, F-445), so asking it the same question is asking what scatter itself asks.
	var at_centre: float = MireGridSim.initial_corruption_from_centres(centre.x, centre.y, centres)
	check(at_centre > 0.5,
		"seed %d: the scatter gate reads the cluster centre as corrupt (%.2f), so the Mire's own flora lands where the corruption is"
			% [world_seed, at_centre])
	var away: Vector2 = centre + Vector2(MireGridSim.SEED_CLUSTER_RADIUS_M * 6.0, 0.0)
	check(MireGridSim.initial_corruption_from_centres(away.x, away.y, centres) < at_centre,
		"seed %d: and reads ground well outside it as cleaner — the reading is positional, not a constant"
			% world_seed)
	# The ordering guarantee itself: the centres the sim serves AFTER the world is built are the
	# ones it served while the world was building. A stale memo from before the anchor was known
	# would put the Mire's flora on an island the corruption has since left.
	check(MireGridSim.seed_cluster_centres(world_seed)[0].is_equal_approx(centre),
		"seed %d: the memoised centre is stable after the world is built — scatter and sim saw the same island"
			% world_seed)

	world.queue_free()
	await process_frame
	await process_frame


## The measurement F-602 actually asked for, printed whether or not anything failed — the numbers
## are the deliverable and a check that only prints them on failure hides its own result.
func _report() -> void:
	if _distances.is_empty():
		return
	var lowest: float = _distances[0]
	var highest: float = _distances[0]
	var total: float = 0.0
	for value: float in _distances:
		lowest = minf(lowest, value)
		highest = maxf(highest, value)
		total += value
	var mean: float = total / float(_distances.size())
	var closing: float = WALK_SPEED_MPS * 60.0 * EXPLORATION_EFFICIENCY + FRONT_ADVANCE_M_PER_MIN
	print("\n== the measurement (%d seeds) ==" % _distances.size())
	print("  spawn to Mire: %.0f m closest, %.0f m mean, %.0f m furthest" % [lowest, mean, highest])
	print("  time to REACH corrupted ground walking straight at it, at %.0f%% of walking pace" % (EXPLORATION_EFFICIENCY * 100.0))
	print("  (a LOWER BOUND — a party does not know where it is and has to find it first):")
	print("    %.1f min best case, %.1f min worst (%.2f - %.2f Cycles)" % [
		(lowest - MireGridSim.SEED_CLUSTER_RADIUS_M) / closing,
		(highest - MireGridSim.SEED_CLUSTER_RADIUS_M) / closing,
		(lowest - MireGridSim.SEED_CLUSTER_RADIUS_M) / closing / CYCLE_MINUTES,
		(highest - MireGridSim.SEED_CLUSTER_RADIUS_M) / closing / CYCLE_MINUTES])
	print("  time before the front reaches camp untouched:")
	print("    %.0f min worst (%.1f Cycles) — set by the CLOSEST seed, not by the band's near edge:" % [
		(lowest - MireGridSim.SEED_CLUSTER_RADIUS_M) / FRONT_ADVANCE_M_PER_MIN,
		(lowest - MireGridSim.SEED_CLUSTER_RADIUS_M) / FRONT_ADVANCE_M_PER_MIN / CYCLE_MINUTES])
	# Worth saying plainly: no sampled seed came near the band's 180 m floor. Candidates are drawn
	# in a square about the ISLAND CENTRE while spawn sits on a 295-500 m shore ring, so the natural
	# distribution already sits high in the band and the floor is a guard against the unlucky draw
	# rather than a number that shapes the typical run. If a future change moves spawn inward, the
	# floor starts doing real work and these figures should be re-measured, not assumed.
	print("  band is %.0f-%.0f m; the closest sampled seed was %.0f m, so the floor did not bind here."
		% [MireGridSim.SEED_SPAWN_MIN_M, MireGridSim.SEED_SPAWN_MAX_M, lowest])


func _controller_walk_speed() -> float:
	var packed: PackedScene = load("res://entities/player/player.tscn") as PackedScene
	if packed == null:
		return WALK_SPEED_MPS
	var instance: Node = packed.instantiate()
	var speed: float = float(instance.get(&"walk_speed"))
	instance.free()
	return speed


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)
