extends SceneTree

## F-526: unlike player_health_net_check, this drives PlayerController's actual hold path rather
## than calling PlayerHealth.request_revive() directly.

const PLAYER_SCENE: PackedScene = preload("res://entities/player/player.tscn")

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var health: Node = root.get_node_or_null(^"PlayerHealth")
	check(health != null, "PlayerHealth autoload exists")
	if health == null:
		finish()
		return

	var reviver := PLAYER_SCENE.instantiate() as Node3D
	reviver.name = "1"
	reviver.set_multiplayer_authority(1)
	root.add_child(reviver)
	var target := PLAYER_SCENE.instantiate() as Node3D
	target.name = "2"
	target.set_multiplayer_authority(2)
	root.add_child(target)
	await process_frame
	reviver.global_position = Vector3.ZERO
	target.global_position = Vector3(1.0, 0.0, 0.0)
	health.call(&"_ensure_host_state", 1)
	health.call(&"_ensure_host_state", 2)
	health.call(&"_on_player_spawned", 1, reviver)
	health.call(&"_on_player_spawned", 2, target)
	check(bool(health.call(&"host_apply_damage", 2, int(health.get(&"max_hp")), 0)),
		"the teammate enters downed state")
	check(bool(health.call(&"is_downed_known", 2)),
		"the reviver's replicated downed lookup knows the target")

	Input.action_press(&"interact")
	var held: float = float(health.get(&"revive_seconds")) + 0.1
	reviver.call(&"_tick_revive_hold", held, true, false, false)
	Input.action_release(&"interact")
	check(bool(health.call(&"host_is_alive", 2)),
		"holding the bound interact action through PlayerController revives the teammate")

	reviver.queue_free()
	target.queue_free()
	print("REVIVE_INTERACTION_CHECK failures=%d" % failures)
	finish()


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
