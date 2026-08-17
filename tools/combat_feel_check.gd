extends SceneTree

## Task 2.9's instrument. It does **not** decide whether combat feels great — that is a playtest, and
## `ROADMAP.md` is explicit that the gate is not passed until a human says so.
##
## What it does is measure the properties that make "feels great" *possible*, so a tuning pass is a
## conversation about numbers rather than about adjectives, and so a later change that quietly breaks
## one of them is caught. Every assertion below is a relationship between authored values, not a
## judgement about them: it fails when the numbers stop being coherent with each other, not when they
## stop being fun.
##
##   Godot --headless --path . --script tools/combat_feel_check.gd

const PLAYER_CONTROLLER := preload("res://entities/player/player_controller.gd")

var failures: int = 0
var notes: PackedStringArray = PackedStringArray()


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame
	var registry: Node = root.get_node_or_null(^"Registry")
	var world: Node = root.get_node_or_null(^"EnemyWorld")
	if registry == null or world == null:
		push_error("FAIL: Registry and EnemyWorld autoloads must exist")
		quit(1)
		return

	var axe: WeaponDef = registry.call("get_weapon", &"stone_axe") as WeaponDef
	var crawler: Resource = world.call("get_def", &"crawler")
	if axe == null or crawler == null:
		push_error("FAIL: the vertical-slice weapon and enemy must both be authored")
		quit(1)
		return

	var player: Node = PLAYER_CONTROLLER.new()
	var walk_speed: float = float(player.get("walk_speed"))
	var sprint_speed: float = float(player.get("sprint_speed"))
	player.free()

	print("\n-- the one weapon --")
	var swing: float = axe.swing_seconds()
	note("swing        %.2f s  (wind-up %.2f + commit %.2f + recovery %.2f)"
		% [swing, axe.wind_up_seconds, axe.commit_seconds, axe.recovery_seconds])
	note("reach        %.2f m over a %.0f° arc" % [axe.range_m, axe.arc_degrees])
	note("hitstop      %.3f s   shake %.3f m for %.2f s"
		% [axe.hitstop_seconds, axe.shake_magnitude, axe.shake_duration])

	print("\n-- the one enemy --")
	var tell: float = float(crawler.get("attack_tell_seconds"))
	var enemy_speed: float = float(crawler.get("move_speed"))
	var enemy_reach: float = float(crawler.get("attack_range_m"))
	note("crawler      %d HP, %.1f dmg, %.2f m/s, reach %.2f m"
		% [int(crawler.get("max_health")), int(crawler.get("attack_damage")), enemy_speed, enemy_reach])
	note("telegraph    %.2f s tell -> %.2f s swing -> %.2f s recovery"
		% [tell, float(crawler.get("attack_seconds")), float(crawler.get("attack_recovery_seconds"))])

	print("\n-- what those numbers add up to --")
	var swings_to_kill: int = ceili(float(crawler.get("max_health")) / float(axe.damage))
	var time_to_kill: float = float(swings_to_kill) * swing
	note("time-to-kill %d swings, %.2f s of swinging" % [swings_to_kill, time_to_kill])
	check(swings_to_kill >= 2, "a kill takes more than one swing, so a fight is a fight")
	check(swings_to_kill <= 8, "a kill does not take so many swings that one enemy is a chore")

	# The telegraph only means something if a player who reads it can act on it. The realistic gap is
	# not the enemy's whole reach — the crawler stops closing at `stop_distance_m`, and it holds
	# still for the whole tell (velocity is zeroed in TELL), so the player only has to cover the
	# difference, at full walk speed, unopposed.
	var escape_m: float = maxf(enemy_reach - float(crawler.get("stop_distance_m")), 0.0)
	var escape_time: float = escape_m / maxf(walk_speed, 0.001)
	var reaction_budget: float = tell - escape_time
	note("player       %.1f m/s walk, %.1f m/s sprint" % [walk_speed, sprint_speed])
	note("reaction     %.2f s of the %.2f s tell is thinking time; %.2f m of retreat costs %.2f s"
		% [reaction_budget, tell, escape_m, escape_time])
	note("worst case   standing at contact needs %.2f s to clear %.2f m — sprint or trade, do not walk"
		% [enemy_reach / walk_speed, enemy_reach])
	check(reaction_budget > 0.15,
		"the telegraph leaves a readable window, not a reflex test (%.2f s)" % reaction_budget)

	# DESIGN.md §6 names Muck's backpedal spam as the thing to fix. An enemy slower than a walk can
	# be retreated from indefinitely, which removes every decision the telegraph was there to create.
	check(enemy_speed > walk_speed,
		"the enemy outruns a walk, so backing away forever is not a strategy (%.2f > %.2f)"
			% [enemy_speed, walk_speed])
	check(enemy_speed < sprint_speed,
		"but a sprint still disengages, so a fight is a choice (%.2f < %.2f)"
			% [enemy_speed, sprint_speed])
	note("retreat      walking loses %.2f m/s; sprinting gains %.2f m/s"
		% [enemy_speed - walk_speed, sprint_speed - enemy_speed])

	# Trading blows: the player's whole swing has to fit inside the enemy's recovery, or standing in
	# melee is never the right answer and the fight is only ever kiting.
	var enemy_recovery: float = float(crawler.get("attack_recovery_seconds"))
	check(swing <= enemy_recovery + float(crawler.get("attack_seconds")),
		"a player swing fits inside the enemy's commit+recovery, so trading is possible (%.2f <= %.2f)"
			% [swing, enemy_recovery + float(crawler.get("attack_seconds"))])

	check(axe.range_m > enemy_reach,
		"the axe outreaches the crawler, so spacing is a real option (%.2f > %.2f)"
			% [axe.range_m, enemy_reach])
	check(axe.hitstop_seconds > 0.0 and axe.shake_magnitude > 0.0,
		"a connect produces hitstop and shake — DESIGN.md §6's 'loud, satisfying impact'")
	check(axe.hitstop_seconds < axe.recovery_seconds,
		"hitstop is shorter than the recovery it interrupts, so it reads as impact not as a hitch")

	print("")
	for line: String in notes:
		print("  %s" % line)
	print("\nCOMBAT_FEEL_CHECK failures=%d" % failures)
	print("""
  These are relationships, not verdicts. The gate is ROADMAP.md 2.9's own wording — one enemy, one
  weapon, and a human who says it feels great. Tune in the inspector:
    · content/weapons/stone_axe.tres   swing timings, reach, hitstop, shake
    · content/enemies/crawler.tres     health, speed, reach, telegraph
    · entities/player/player_camera.gd shake frequency and roll
  Do not re-run tools/setup_combat_content.gd or tools/setup_enemy_content.gd afterwards — they
  overwrite those files with these starting values.""")
	quit(0 if failures == 0 else 1)


func note(line: String) -> void:
	notes.append(line)


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)
