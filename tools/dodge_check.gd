extends SceneTree

## Focused offline proof for task 3.8b: a stamina-costed dash impulse, cooldown, i-frames that answer
## enemy melee only, and the replicated `dodging` flag itself.
##
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/dodge_check.gd
##
## Same driving technique as tools/player_vitals_check.gd: PlayerHealth's own _physics_process is
## stepped by hand (disabled from the engine's real per-frame call) so timings are exact in delta, not
## wall time, and a real entities/player/player.tscn instance proves the wiring end to end rather than
## asserting PlayerController's own private state in isolation.

const PLAYER_SCENE: PackedScene = preload("res://entities/player/player.tscn")
const EVENT_BUS := preload("res://core/events/event_bus.gd")
## Offline's own peer id — the same "1" _spawn_player() names the body for.
const HOST_PEER: int = 1

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame

	var health: Node = root.get_node_or_null(^"PlayerHealth")
	check(health != null, "PlayerHealth autoload exists")
	if health == null:
		finish()
		return

	# See tools/player_vitals_check.gd's own note on why this is disabled: PlayerHealth's
	# _physics_process ticks hunger on every REAL engine frame regardless of what this script does,
	# and stray real-time drain during this script's own `await`s would make the stamina-cost
	# assertions below flaky under machine load.
	health.set_physics_process(false)

	await _run_dash_and_cost(health)
	await _run_cooldown(health)
	await _run_iframes(health)
	await _run_iframe_powerup(health)

	print("\n%d failure(s)\n" % failures)
	finish()


## Named "1" — offline's own unique id, same reasoning tools/player_vitals_check.gd gives: only a
## node named for peer 1 adopts multiplayer authority offline, and only the local-authority body runs
## _unhandled_input/_physics_process at all.
func _spawn_player() -> CharacterBody3D:
	var player: CharacterBody3D = PLAYER_SCENE.instantiate() as CharacterBody3D
	player.name = "1"
	root.add_child(player)
	return player


# ── Dash impulse, stamina cost, direction ────────────────────────────────────────────────────────


func _run_dash_and_cost(health: Node) -> void:
	var player: CharacterBody3D = _spawn_player()
	await process_frame
	await process_frame
	_refill_stamina(health)

	var cost: float = float(player.get("dodge_stamina_cost"))
	var impulse: float = float(player.get("dodge_impulse"))
	var max_stamina: float = float(health.get("max_stamina"))
	check(not bool(player.get("dodging")), "dodging starts false")
	check(float(health.call(&"local_stamina")) == max_stamina, "stamina starts full")

	var accepted: bool = bool(player.call(&"_execute_dodge"))
	check(accepted, "a dodge with a full stamina bar is accepted")
	check(bool(player.get("dodging")), "dodging flips true the instant it is accepted")
	check(is_equal_approx(float(health.call(&"local_stamina")), max_stamina - cost),
		"exactly dodge_stamina_cost was spent, not the whole bar")

	# _execute_dodge() itself only sets _dodge_velocity and the flag — velocity.x/z is written by
	# _apply_horizontal_movement()'s dodging branch, the same physics tick a real _physics_process()
	# would run it on. One direct call here mirrors that tick without waiting a real frame.
	player.call(&"_apply_horizontal_movement", 1.0 / 60.0, true, false, false)

	# No movement input held: _execute_dodge()'s own fallback dashes in the facing direction
	# (-transform.basis.z) rather than refusing, so the impulse should point straight along -Z at
	# spawn's default (unrotated) yaw.
	var horizontal_speed: float = Vector2(player.velocity.x, player.velocity.z).length()
	check(is_equal_approx(horizontal_speed, impulse),
		"velocity reaches exactly dodge_impulse with no movement input held (facing fallback) (%.2f vs %.2f)" % [
			horizontal_speed, impulse
		])
	check(player.velocity.z < 0.0, "and the fallback direction is the player's forward (-Z)")

	# Tick past dodge_duration_sec: dodging clears, and normal locomotion (no input held, so
	# ground_friction) takes horizontal velocity back toward zero.
	var duration: float = float(player.get("dodge_duration_sec"))
	for _i: int in range(int(duration / (1.0 / 60.0)) + 5):
		player.call(&"_tick_dodge", 1.0 / 60.0)
		player.call(&"_apply_horizontal_movement", 1.0 / 60.0, true, false, false)
	check(not bool(player.get("dodging")), "dodging clears once dodge_duration_sec elapses")

	player.queue_free()
	await process_frame


# ── Cooldown ──────────────────────────────────────────────────────────────────────────────────────


func _run_cooldown(health: Node) -> void:
	var player: CharacterBody3D = _spawn_player()
	await process_frame
	await process_frame
	_refill_stamina(health)

	check(bool(player.call(&"_execute_dodge")), "first dodge of a fresh cooldown is accepted")
	# Let the dash itself finish so the SECOND attempt is testing the cooldown, not "already dodging".
	var duration: float = float(player.get("dodge_duration_sec"))
	for _i: int in range(int(duration / (1.0 / 60.0)) + 5):
		player.call(&"_tick_dodge", 1.0 / 60.0)
	check(not bool(player.get("dodging")), "sanity: the first dash has ended")

	check(not bool(player.call(&"_execute_dodge")),
		"a second dodge before dodge_cooldown_sec is rejected outright")
	check(not bool(player.get("dodging")), "and nothing about state changed on rejection")

	var cooldown: float = float(player.get("dodge_cooldown_sec"))
	for _i: int in range(int(cooldown / (1.0 / 60.0)) + 5):
		player.call(&"_tick_dodge", 1.0 / 60.0)
	check(bool(player.call(&"_execute_dodge")), "a third dodge is accepted once the cooldown clears")

	player.queue_free()
	await process_frame


# ── I-frames: enemy melee only, decided host-side off the replicated flag ──────────────────────────


func _run_iframes(health: Node) -> void:
	var player: CharacterBody3D = _spawn_player()
	player.name = "1"
	await process_frame
	await process_frame

	health.call(&"_on_player_spawned", 1, player)
	_refill_stamina(health)
	var max_hp: int = int(health.get("max_hp"))
	check(int(health.call(&"local_hp")) == max_hp, "sanity: full hp before any hit lands")

	check(bool(player.call(&"_execute_dodge")), "dodge accepted going into the i-frame window")
	check(bool(player.get("dodging")), "sanity: dodging is true for this hit")

	EVENT_BUS.emit_enemy_attack_landed(&"crawler", 1, 30, Vector3.ZERO)
	check(int(health.call(&"local_hp")) == max_hp,
		"an enemy hit during the dash window is dodged — no damage lands")

	var duration: float = float(player.get("dodge_duration_sec"))
	for _i: int in range(int(duration / (1.0 / 60.0)) + 5):
		player.call(&"_tick_dodge", 1.0 / 60.0)
	check(not bool(player.get("dodging")), "sanity: the i-frame window has closed")

	EVENT_BUS.emit_enemy_attack_landed(&"crawler", 1, 30, Vector3.ZERO)
	check(int(health.call(&"local_hp")) == max_hp - 30,
		"the SAME hit lands normally once dodging is false again")

	# Task 3.8b's spec: i-frames answer enemy melee only, never the shared host_apply_damage() seam
	# other damage sources (starvation, a future hazard) call directly — dodging must not block those.
	for _i: int in range(int(float(player.get("dodge_cooldown_sec")) / (1.0 / 60.0)) + 5):
		player.call(&"_tick_dodge", 1.0 / 60.0)
	check(bool(player.call(&"_execute_dodge")), "sanity: cooldown cleared, a second dodge is accepted")
	check(bool(player.get("dodging")), "sanity: dodging true going into the direct-damage check")
	var hp_before_direct: int = int(health.call(&"local_hp"))
	check(bool(health.call(&"host_apply_damage", 1, 15, 0)),
		"host_apply_damage() called directly (not through the enemy event) still lands while dodging")
	check(int(health.call(&"local_hp")) == hp_before_direct - 15,
		"i-frames never touched the shared damage seam itself — only the enemy_attack_landed path")

	player.queue_free()
	await process_frame


## Stamina is a single client-local value on the PlayerHealth autoload, shared across every test
## function in this script (only a real session open/close resets it — see player_health.gd's
## _on_session_opened/_on_disconnected) — same trap tools/player_vitals_check.gd's own
## _run_controller_integration note describes. Force a known-full baseline before each section rather
## than let it carry whatever the previous section's dodges (and their brief regen windows) left
## behind.
func _refill_stamina(health: Node) -> void:
	health.call(&"local_tick_stamina", 999.0, false)


# ── dodge_iframe_seconds actually does something (F-125) ─────────────────────────────────────────

## The powerup's contract, in its own words: "untouchable for the whole of the trip rather than most
## of it". So the assertion that matters is a PAIR — the i-frame flag must outlive `dodge_duration_sec`
## AND the dash movement must not. Testing only the first would pass just as well against the wrong
## fix (feeding the stat into `dodge_duration_sec`), which F-125 explicitly warned is a different
## powerup: at 3 stacks it would add 0.12 s of travel and change where the player ends up.
func _run_iframe_powerup(health: Node) -> void:
	var service: Node = root.get_node_or_null(^"/root/PowerupService")
	check(service != null, "PowerupService autoload exists")
	if service == null:
		return

	var player: CharacterBody3D = _spawn_player()
	await process_frame
	await process_frame
	_refill_stamina(health)

	var duration: float = float(player.get("dodge_duration_sec"))
	var impulse: float = float(player.get("dodge_impulse"))
	var step: float = 1.0 / 60.0

	# Three stacks of the real authored content, not a fixture: content/powerups/thin_step.tres is
	# +0.04 s a stack, so this is the biggest window the shipped game can produce.
	var stacks: int = int(service.call(&"host_grant", HOST_PEER, &"thin_step", 3))
	check(stacks == 3, "three stacks of thin_step granted (got %d)" % stacks)
	var bonus: float = float(service.call(&"local_stat", &"dodge_iframe_seconds", 0.0))
	check(bonus > 0.0,
		"PowerupService reports a dodge_iframe_seconds bonus of %.3fs — if this is 0 the rest of "
		% bonus + "this section proves nothing")

	check(bool(player.call(&"_execute_dodge")), "a dodge is accepted while holding thin_step")

	# Step to just PAST the dash window but short of the extended i-frame window. Both facts are
	# read at the same instant, which is the whole point.
	var to_dash_end: int = int(duration / step) + 2
	for _i: int in range(to_dash_end):
		player.call(&"_tick_dodge", step)
		player.call(&"_apply_horizontal_movement", step, true, false, false)

	check(bool(player.get("dodging")),
		"i-frames outlive the dash: `dodging` is still true %.3fs in, past dodge_duration_sec (%.3fs)"
			% [float(to_dash_end) * step, duration])
	# Two readings of the same fact, because the velocity one alone is a thin margin: ground friction
	# has had only a frame or two to bite, so a still-running dash reads 10.00 and a just-ended one
	# reads ~9.5. The private timer is the unambiguous one — it is what _apply_horizontal_movement()
	# actually branches on — and the velocity check is what proves the branch is really wired to it.
	check(float(player.get("_dodge_time_remaining")) == 0.0,
		"...the dash window itself is closed (_dodge_time_remaining == 0) while `dodging` is still "
		+ "true — the two windows are genuinely separate timers, which is the whole of F-125")
	var speed: float = Vector2(player.velocity.x, player.velocity.z).length()
	check(speed < impulse - 0.01,
		"...and the dash MOVEMENT has ended — horizontal speed %.2f m/s is below dodge_impulse "
		% speed + "(%.2f). If this fails the stat is lengthening the dash, not the i-frames (F-125)"
			% impulse)

	# And it does end. Run out the rest of the extended window plus a margin.
	for _i: int in range(int(bonus / step) + 6):
		player.call(&"_tick_dodge", step)
		player.call(&"_apply_horizontal_movement", step, true, false, false)
	check(not bool(player.get("dodging")),
		"the extended window closes too — `dodging` is false after dodge_duration_sec + %.3fs"
			% bonus)

	# Leave the service as this section found it: every other check in the repo that reads powerups
	# for peer 1 runs against a shared autoload.
	service.call(&"host_clear", HOST_PEER)
	check(float(service.call(&"local_stat", &"dodge_iframe_seconds", 0.0)) == 0.0,
		"powerups cleared again, so no later check inherits a dodge bonus from this one")

	player.queue_free()
	await process_frame


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
