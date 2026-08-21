extends SceneTree

## Focused offline proof for F-411: the typed/op-gated command, recovery on enable, every local
## damage entry point available without a world fixture, flight controls, and ordinary behaviour
## returning on disable.
##
##   .agent/bin/agent godot --script tools/god_mode_check.gd

const PLAYER_SCENE: PackedScene = preload("res://entities/player/player.tscn")
const EVENT_BUS := preload("res://core/events/event_bus.gd")

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame

	var service: Node = root.get_node_or_null(^"GodModeService")
	var health: Node = root.get_node_or_null(^"PlayerHealth")
	var commands: Node = root.get_node_or_null(^"CommandService")
	check(service != null, "GodModeService autoload exists")
	check(health != null, "PlayerHealth autoload exists")
	check(commands != null, "CommandService autoload exists")
	if service == null or health == null or commands == null:
		finish()
		return

	check(bool(commands.call(&"has_spec", &"god")), "the typed `god` command is registered")

	var player: CharacterBody3D = PLAYER_SCENE.instantiate() as CharacterBody3D
	player.name = "1"
	root.add_child(player)
	await process_frame
	await process_frame
	player.set_physics_process(false)
	health.call(&"_on_player_spawned", NetConfig.HOST_PEER_ID, player)
	var max_hp: int = int(health.get("max_hp"))

	# The host re-parses an RPC submission and CommandService rejects a peer that has not been opped
	# before GodModeService's handler can mutate anything.
	var untrusted_ctx: Dictionary = {
		"peer_id": 2, "source": &"rpc", "position": Vector3.ZERO, "facing": Vector3.FORWARD,
	}
	var refused: Dictionary = await commands.call(&"execute", "god on", untrusted_ctx)
	check(not bool(refused.get("ok", true)), "a non-op remote peer cannot enable God mode")
	check(String(refused.get("message", "")).begins_with("not op"),
		"the refusal comes from CommandService's uniform op gate")

	# Ordinary damage works before the toggle, so immunity below cannot pass because the health
	# fixture was inert.
	check(bool(health.call(&"host_apply_damage", 1, 10, 0)), "baseline damage lands with God mode off")
	check(int(health.call(&"host_hp", 1)) == max_hp - 10, "baseline damage costs exactly 10 hp")
	check(bool(health.call(&"host_apply_damage", 1, max_hp, 0)), "a lethal baseline hit is accepted")
	check(bool(health.call(&"host_is_downed", 1)), "the baseline lethal hit downs the tester")

	var host_ctx: Dictionary = commands.call(&"build_local_ctx", &"console")
	var enabled_result: Dictionary = await commands.call(&"execute", "god on", host_ctx)
	check(bool(enabled_result.get("ok", false)), "host/operator enables God mode through the real command")
	check(bool(service.call(&"is_enabled", 1)), "the host canonical peer set records God mode")
	check(bool(service.call(&"is_local_enabled")), "the owning controller sees the approved state")
	check(bool(health.call(&"host_is_alive", 1)), "enabling while downed revives the tester")
	check(int(health.call(&"host_hp", 1)) == max_hp, "enabling also restores full health")

	var before: int = int(health.call(&"host_hp", 1))
	check(not bool(health.call(&"host_apply_damage", 1, 25, 0)),
		"direct/shared damage is rejected while God mode is on")
	EVENT_BUS.emit_enemy_attack_landed(&"god_mode_probe", 1, 25, Vector3.ZERO)
	check(int(health.call(&"host_hp", 1)) == before, "enemy EventBus damage also costs no hp")
	health.call(&"host_set_hunger", 1, 0.0)
	health.call(&"_physics_process", 20.0)
	check(int(health.call(&"host_hp", 1)) == before, "starvation damage costs no hp")

	# Flight is the owning controller's normal CharacterBody velocity, not a host transform write.
	player.velocity = Vector3.ZERO
	Input.action_press(&"jump")
	player.call(&"_apply_god_flight", 0.25, true)
	Input.action_release(&"jump")
	check(player.velocity.y > 0.0, "jump drives God-mode flight upward")

	player.velocity = Vector3.ZERO
	Input.action_press(&"dodge")
	player.call(&"_apply_god_flight", 0.25, true)
	Input.action_release(&"dodge")
	check(player.velocity.y < 0.0, "dodge drives God-mode flight downward")

	var status_result: Dictionary = await commands.call(&"execute", "god status", host_ctx)
	check(bool(status_result.get("data", {}).get("enabled", false)), "`god status` reports the live state")
	var disabled_result: Dictionary = await commands.call(&"execute", "god off", host_ctx)
	check(bool(disabled_result.get("ok", false)), "the command disables God mode")
	check(not bool(service.call(&"is_local_enabled")), "the local approved state clears")
	check(bool(health.call(&"host_apply_damage", 1, 5, 0)), "ordinary damage resumes after disable")
	player.velocity = Vector3.ZERO
	player.call(&"_apply_gravity", 0.1)
	check(player.velocity.y < 0.0, "ordinary gravity resumes after disable")

	var settings_menu: Node = root.get_node_or_null(^"SettingsMenu")
	var toggle: CheckBox = settings_menu.find_child("GodModeToggle", true, false) as CheckBox \
		if settings_menu != null else null
	check(toggle != null, "Settings contains the God Mode toggle")
	if toggle != null:
		toggle.button_pressed = true
		await process_frame
		check(bool(service.call(&"is_local_enabled")), "the Settings toggle enables God mode")
		toggle.button_pressed = false
		await process_frame
		check(not bool(service.call(&"is_local_enabled")), "the Settings toggle disables God mode")

	print("GOD_MODE_CHECK failures=%d" % failures)
	finish()


func check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: %s" % label)
		return
	failures += 1
	push_error("FAIL: %s" % label)


func finish() -> void:
	quit(1 if failures > 0 else 0)
