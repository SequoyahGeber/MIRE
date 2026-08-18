extends SceneTree

## Focused offline proof for task 2.13: damage -> downed -> bleed-out -> death -> respawn, revive
## validation, and the EventBus wiring the whole thing depends on.
##
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/player_health_check.gd
##
## Timings are driven by stepping PlayerHealth's own _physics_process directly rather than by
## sleeping in real time — same reasoning as tools/enemy_check.gd: the state machine is deterministic
## in delta, and a check that sleeps out a 30 s bleed-out is a check nobody runs.
##
## Two peer shapes are used on purpose. A real entities/player/player.tscn instance proves the
## &"damageable" wiring end to end (EventBus -> PlayerHealth -> the body's own host_apply_damage and
## its _is_downed()/_is_dead() gating helpers). The revive scenarios use bare host-state peers with no
## body at all where the rule under test is decided before PlayerHealth ever looks for one (self-revive,
## reviver-alive, target-downed), and add a real Node3D body only where range genuinely has to be
## measured — see F-052/dev_loadout's lesson: assert the wiring, not just the arithmetic.

const PLAYER_SCENE: PackedScene = preload("res://entities/player/player.tscn")
const EVENT_BUS := preload("res://core/events/event_bus.gd")

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

	var max_hp: int = int(health.get("max_hp"))
	var revive_hp_fraction: float = float(health.get("revive_hp_fraction"))
	var bleed_out_seconds: float = float(health.get("bleed_out_seconds"))
	var respawn_seconds: float = float(health.get("respawn_seconds"))
	var revive_radius_m: float = float(health.get("revive_radius_m"))

	check(int(EVENT_BUS.enemy_attack_landed_subscriber_count()) >= 1,
		"PlayerHealth subscribes to EventBus.enemy_attack_landed (the dev_loadout lesson: prove the "
		+ "wiring, not just the logic)")

	# Every one of these contains an `await` internally, so each MUST be awaited here — an
	# un-awaited call to a coroutine only runs synchronously up to its first await point and then
	# the rest silently never resumes once _run() itself calls finish()/quit().
	await _run_offline_solo_flow(health, max_hp, bleed_out_seconds, respawn_seconds)
	await _run_offline_spawn_capture(health, max_hp, bleed_out_seconds, respawn_seconds)
	_run_revive_state_checks(health, max_hp)
	await _run_revive_range_and_success(health, max_hp, revive_hp_fraction, revive_radius_m)
	await _run_public_request_revive(health, max_hp, revive_hp_fraction)

	print("\n%d failure(s)\n" % failures)
	finish()


# ── A real player, damaged through EventBus AND the melee seam, all the way to respawn ────────────


func _run_offline_solo_flow(
	health: Node, max_hp: int, bleed_out_seconds: float, respawn_seconds: float
) -> void:
	var player: Node3D = PLAYER_SCENE.instantiate() as Node3D
	player.name = "1"
	root.add_child(player)
	await process_frame
	await process_frame

	check(player.is_in_group(&"damageable"), "the player body joins 2.8's damageable group")
	check(player.has_method(&"host_apply_damage"), "and implements the shared seam")
	check(int(health.call("local_hp")) == max_hp, "offline solo starts at full health")
	check(not bool(health.call("local_is_downed")), "and not downed")

	# Seed the spawn transform the same way PlayerNet.player_spawned would (F-018): captured off the
	# body BEFORE it moves, so the eventual respawn has somewhere real to send it back to.
	var spawn_position: Vector3 = player.position
	health.call("_on_player_spawned", 1, player)

	# Damage IN via the event 2.10's enemies actually emit — the seam this whole check exists for.
	EVENT_BUS.emit_enemy_attack_landed(&"crawler", 1, 30, Vector3.ZERO)
	check(int(health.call("local_hp")) == max_hp - 30, "an enemy hit lands through EventBus")

	# Damage IN via the shared melee seam (2.8): CombatService calls this exact method on anything in
	# &"damageable"; skip CombatService itself and call it the way CombatService would.
	check(bool(player.call(&"host_apply_damage", 5, 0)), "the melee seam also reaches player health")
	check(int(health.call("local_hp")) == max_hp - 35, "and the two paths share one hp pool")

	# Move it away from spawn before the lethal hit, so a later "did it come back" check means something.
	player.position = Vector3(40.0, 0.0, -40.0)

	check(bool(player.call(&"host_apply_damage", 1000, 0)), "a lethal hit is still accepted")
	check(bool(health.call("local_is_downed")), "hp at 0 enters DOWNED, not dead outright (DESIGN §4.5)")
	check(bool(player.call(&"_is_downed")), "the controller's own gate agrees (input gating reads PlayerHealth)")
	check(not bool(player.call(&"host_apply_damage", 10, 0)),
		"no corpse-kicking: damage is rejected while downed")

	EVENT_BUS.emit_enemy_attack_landed(&"crawler", 1, 999, Vector3.ZERO)
	check(bool(health.call("local_is_downed")), "and the event path is rejected the same way")

	# Bleed-out: one big step past the threshold, same trick as enemy_check's _step — the accumulator
	# is exact in delta, not in wall time.
	health.call(&"_physics_process", bleed_out_seconds + 0.1)
	check(bool(health.call("local_is_dead")), "bleed-out expiring moves DOWNED -> DEAD")
	check(bool(player.call(&"_is_dead")), "the controller's own gate agrees")

	health.call(&"_physics_process", respawn_seconds + 0.1)
	check(bool(health.call("local_is_alive")), "respawn_seconds later the player is ALIVE again")
	check(int(health.call("local_hp")) == max_hp, "and back at full health")
	check(player.position.distance_to(spawn_position) < 0.01,
		"and physically back at the spawn point PlayerNet.player_spawned recorded (%v -> %v)" % [
			Vector3(40.0, 0.0, -40.0), player.position
		])

	# Left in the tree, alive, at the spawn point — _run_public_request_revive reuses it as peer 1's
	# real body, since request_revive() offline always resolves the caller as the local peer.


# ── F-063: the same flow with NOBODY faking PlayerNet.player_spawned ──────────────────────────────


## The scenario above seeds _spawn_transforms by calling _on_player_spawned by hand — which is what
## PlayerNet does, but ONLY inside a session. Offline (Play from the editor, every --script harness,
## the exact configuration task 2.9's gate is played in) PlayerNet leaves the level's hand-placed
## Player alone and never emits that signal, so nothing filled the dictionary and every respawn fell
## through to Vector3.ZERO — the world origin, which is not a spawn point, just wherever the level
## author put 0,0,0. Simulating the signal is what hid this for a whole task.
##
## So this scenario deliberately does NOT call _on_player_spawned. It resets the capture latch, puts
## a body down at a known "level spawn", and lets PlayerHealth notice it on its own.
func _run_offline_spawn_capture(
	health: Node, max_hp: int, bleed_out_seconds: float, respawn_seconds: float
) -> void:
	var level_spawn := Vector3(12.0, 1.0, -8.0)

	for node: Node in root.get_tree().get_nodes_in_group(&"players"):
		node.queue_free()
	await process_frame
	await process_frame

	var player: Node3D = PLAYER_SCENE.instantiate() as Node3D
	player.name = "1"
	player.position = level_spawn
	root.add_child(player)
	await process_frame
	await process_frame

	# Rewind to the state a freshly booted offline game is in — no spawn recorded, latch unarmed —
	# and then run the rest of this scenario with NO `await` in it. The engine ticks PlayerHealth
	# itself on every awaited frame (which is the real fix working, and did capture the body above),
	# so awaiting between the reset and the assertion would be racing our own subject.
	health.set("_local_spawn_captured", false)
	(health.get("_spawn_transforms") as Dictionary).erase(1)
	check(not (health.get("_spawn_transforms") as Dictionary).has(1),
		"nothing has faked player_spawned — the offline game's real starting condition")

	# One ordinary tick is all PlayerHealth gets to notice the body.
	health.call(&"_physics_process", 0.016)
	check((health.get("_spawn_transforms") as Dictionary).has(1),
		"PlayerHealth captures the spawn off the body itself when player_spawned never fires (F-063)")

	player.position = Vector3(40.0, 0.0, -40.0)
	check(bool(player.call(&"host_apply_damage", 1000, 0)), "a lethal hit lands away from spawn")
	health.call(&"_physics_process", bleed_out_seconds + 0.1)
	health.call(&"_physics_process", respawn_seconds + 0.1)
	check(bool(health.call("local_is_alive")), "the offline player respawns")
	check(int(health.call("local_hp")) == max_hp, "at full health")
	check(player.position.distance_to(level_spawn) < 0.01,
		"and at the level's spawn, NOT the world origin (%v -> %v)" % [level_spawn, player.position])
	check(player.position.length() > 0.01,
		"the old Vector3.ZERO fallback would have failed this check")

	player.queue_free()
	await process_frame
	await process_frame

	# Put _run_public_request_revive's expected body back: a live peer 1 at a known spot.
	var restored: Node3D = PLAYER_SCENE.instantiate() as Node3D
	restored.name = "1"
	root.add_child(restored)
	await process_frame


# ── Revive: rules that are decided before PlayerHealth ever looks for a body ──────────────────────


func _run_revive_state_checks(health: Node, max_hp: int) -> void:
	health.call(&"_ensure_host_state", 5)
	health.call(&"_ensure_host_state", 6)
	health.call(&"_ensure_host_state", 7)

	check(bool(health.call(&"host_apply_damage", 5, max_hp, 0)), "peer 5 takes a lethal hit")
	check(bool(health.call(&"host_is_downed", 5)), "and is downed")

	health.call(&"_process_revive_request", 5, 5, 201)
	check(bool(health.call(&"host_is_downed", 5)), "a client cannot heal itself: self-revive is rejected")

	health.call(&"_process_revive_request", 6, 7, 202)
	check(bool(health.call(&"host_is_alive", 7)) and int(health.call(&"host_hp", 7)) == max_hp,
		"reviving a target that is not downed is rejected and changes nothing")

	check(bool(health.call(&"host_apply_damage", 6, max_hp, 0)), "peer 6 also goes down")
	health.call(&"_process_revive_request", 6, 5, 203)
	check(bool(health.call(&"host_is_downed", 5)),
		"a downed reviver cannot revive anyone — peer 5 is still waiting")


# ── Revive: range, which the host can only decide once real bodies exist ──────────────────────────


func _run_revive_range_and_success(
	health: Node, max_hp: int, revive_hp_fraction: float, revive_radius_m: float
) -> void:
	health.call(&"_ensure_host_state", 8)
	health.call(&"_ensure_host_state", 9)
	check(bool(health.call(&"host_apply_damage", 8, max_hp, 0)), "peer 8 (the target) goes down")

	var target := Node3D.new()
	target.name = "8"
	target.add_to_group(&"players")
	target.set_multiplayer_authority(8)
	root.add_child(target)

	var reviver := Node3D.new()
	reviver.name = "9"
	reviver.add_to_group(&"players")
	reviver.set_multiplayer_authority(9)
	# .position, not .global_position: both are direct children of `root` (identity transform) so
	# the two are equal here, and setting .global_position before add_child() reads the current
	# global transform to derive it, which errors on a node not yet inside the tree.
	reviver.position = target.position + Vector3(revive_radius_m * 3.0, 0.0, 0.0)
	root.add_child(reviver)
	await process_frame

	health.call(&"_process_revive_request", 9, 8, 301)
	check(bool(health.call(&"host_is_downed", 8)), "out of range: the host rejects the revive")

	reviver.position = target.position
	health.call(&"_process_revive_request", 9, 8, 302)
	check(bool(health.call(&"host_is_alive", 8)), "in range: the host accepts it")
	check(int(health.call(&"host_hp", 8)) == clampi(int(round(float(max_hp) * revive_hp_fraction)), 1, max_hp),
		"and restores revive_hp_fraction of max hp, not a full heal")

	target.queue_free()
	reviver.queue_free()


# ── The public entrypoint offline: request_revive() -> revive_confirmed, no RPC required ──────────


func _run_public_request_revive(health: Node, max_hp: int, revive_hp_fraction: float) -> void:
	var confirmations: Array[Dictionary] = []
	var callback := func(request_id: int, accepted: bool, detail: String) -> void:
		confirmations.append({"request_id": request_id, "accepted": accepted, "detail": detail})
	health.connect(&"revive_confirmed", callback)

	health.call(&"_ensure_host_state", 2)
	check(bool(health.call(&"host_apply_damage", 2, max_hp, 0)), "peer 2 (the target) goes down")

	var teammate := Node3D.new()
	teammate.name = "2"
	teammate.add_to_group(&"players")
	teammate.set_multiplayer_authority(2)
	teammate.position = Vector3.ZERO
	root.add_child(teammate)
	await process_frame

	# Offline solo, request_revive() resolves the caller as the local peer (1) — the same body the
	# earlier flow respawned back to the origin, so it is already in range with nothing to move.
	var request_id: int = int(health.call(&"request_revive", 2))
	var confirmed: Dictionary = {}
	for entry: Dictionary in confirmations:
		if int(entry.get("request_id", -1)) == request_id:
			confirmed = entry
			break
	check(bool(confirmed.get("accepted", false)),
		"request_revive() resolves synchronously offline and reports success: %s" % confirmed)
	check(bool(health.call(&"host_is_alive", 2)), "and the target is actually alive again")

	health.disconnect(&"revive_confirmed", callback)
	teammate.queue_free()


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
