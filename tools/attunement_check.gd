extends SceneTree

## Offline proof for task 3.9: the four DESIGN.md §4.5 roles load, a pick grants its backing
## PowerupDef through the real PowerupService seam, a second pick is refused, and D-035's rebind/
## expire discipline moves and drops state exactly like PowerupService's own does.
##
##   .agent/bin/agent godot --script tools/attunement_check.gd
##
## Drives the REGISTERED /root/AttunementService, /root/PowerupService and /root/Registry, not private
## instances (F-068/F-069 precedent) — a harness that builds its own copy proves the script works and
## says nothing about whether the shipped project loads it. Offline, `_owns_mutation()` is true, so
## this process is host-of-one and every host path below is the real one.

const HOST_PEER: int = 1
const CLIENT_PEER: int = 27

var failures: int = 0
var service: Node
var powerups: Node
var registry: Node
var _events: Array[Dictionary] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	if not _check_wiring():
		finish()
		return

	_check_all_four_roles_load()
	_check_selection_grants_and_locks()
	_check_unknown_role_refused()
	_check_broadcast_signal()
	_check_run_player_identity()

	print("\nATTUNEMENT_CHECK failures=%d" % failures)
	finish()


func _check_wiring() -> bool:
	print("== the shipped project actually has an attunement service ==")
	service = root.get_node_or_null(^"AttunementService")
	powerups = root.get_node_or_null(^"PowerupService")
	registry = root.get_node_or_null(^"Registry")
	check(service != null,
		"AttunementService is registered as an autoload — without this no role can ever be picked")
	check(powerups != null, "PowerupService is registered as an autoload")
	check(registry != null, "Registry is registered as an autoload")
	return service != null and powerups != null and registry != null


## D-070: exactly four, the fixed DESIGN §4.5 roster, each pointing at a real backing PowerupDef.
func _check_all_four_roles_load() -> void:
	print("\n== all four DESIGN §4.5 roles load through the real registry ==")
	var expected: Array[StringName] = [&"warden", &"forager", &"tinker", &"reaver"]
	check(int(registry.get(&"attunements").size()) == 4,
		"exactly four attunements are registered (%d)" % int(registry.get(&"attunements").size()))
	for role_id: StringName in expected:
		var definition: Resource = registry.call(&"get_attunement", role_id)
		check(definition != null, "content/attunements/%s.tres is indexed by its id" % role_id)
		if definition == null:
			continue
		var powerup_id: StringName = StringName(definition.get(&"granted_powerup_id"))
		check(powerup_id != &"", "%s names a backing powerup id" % role_id)
		var backing: Resource = registry.call(&"get_powerup", powerup_id)
		check(backing != null, "%s's backing powerup '%s' is itself registered" % [role_id, powerup_id])
		if backing != null:
			check(int(backing.get(&"max_stacks")) == 1,
				"%s's backing powerup is a one-time pick (max_stacks=1)" % role_id)
			check((backing.get(&"tags") as Array).is_empty(),
				"%s's backing powerup carries no §4.4 Resonance tag" % role_id)
			check(not (backing.get(&"modifiers") as Dictionary).is_empty(),
				"%s's backing powerup actually modifies a stat" % role_id)
		check((definition.call(&"validation_errors") as PackedStringArray).is_empty(),
			"%s validates clean" % role_id)


func _check_selection_grants_and_locks() -> void:
	print("\n== picking a role grants its powerup through the real PowerupService seam ==")
	powerups.call(&"host_clear", HOST_PEER)
	check(String(service.call(&"selection_of", HOST_PEER)) == "", "starts unset")

	service.call(&"request_select", &"reaver")
	check(String(service.call(&"selection_of", HOST_PEER)) == "reaver",
		"the pick is recorded (%s)" % service.call(&"selection_of", HOST_PEER))
	check(int(powerups.call(&"stacks_of", HOST_PEER, &"attunement_reaver")) == 1,
		"and its backing powerup was granted through PowerupService.host_grant")
	var expected_dmg: float = 10.0 * 1.15
	check(is_equal_approx(float(powerups.call(&"stat", HOST_PEER, &"melee_damage", 10.0)), expected_dmg),
		"the modifier resolves through PowerupService.stat() same as any other powerup: %.4f" %
			expected_dmg)

	print("\n== a second selection is refused — locked after the first pick ==")
	var before: StringName = service.call(&"selection_of", HOST_PEER)
	service.call(&"_process_selection", HOST_PEER, &"warden")
	check(String(service.call(&"selection_of", HOST_PEER)) == String(before),
		"the second pick did not overwrite the first (%s)" % service.call(&"selection_of", HOST_PEER))
	check(int(powerups.call(&"stacks_of", HOST_PEER, &"attunement_warden")) == 0,
		"and warden's powerup was never granted")


func _check_unknown_role_refused() -> void:
	print("\n== an unknown role id is refused, not invented ==")
	powerups.call(&"host_clear", CLIENT_PEER)
	service.call(&"_process_selection", CLIENT_PEER, &"no_such_role")
	check(String(service.call(&"selection_of", CLIENT_PEER)) == "",
		"nothing is recorded for an id with no AttunementDef")


func _check_broadcast_signal() -> void:
	print("\n== selection_changed fires with the peer id and the role, for roster UIs ==")
	powerups.call(&"host_clear", CLIENT_PEER + 1)
	_events.clear()
	service.connect(&"selection_changed", _on_selection_changed)
	service.call(&"_process_selection", CLIENT_PEER + 1, &"tinker")
	check(_events.size() == 1, "fires exactly once for one pick (%d)" % _events.size())
	if not _events.is_empty():
		check(int(_events[0]["peer"]) == CLIENT_PEER + 1, "with the right peer id")
		check(String(_events[0]["attunement"]) == "tinker", "and the right role")
	service.disconnect(&"selection_changed", _on_selection_changed)


## D-035's consumer contract: a reconnect must not cost a run's chosen role, and an expiry is what
## actually retires it — same shape PowerupService and InventoryService already prove for their own
## state.
func _check_run_player_identity() -> void:
	print("\n== D-035: a reconnect keeps your role, an expiry ends it ==")
	powerups.call(&"host_clear", CLIENT_PEER)
	service.call(&"_process_selection", CLIENT_PEER, &"forager")
	check(String(service.call(&"selection_of", CLIENT_PEER)) == "forager", "picked before the rebind")

	var rebound_peer: int = CLIENT_PEER + 200
	service.call(&"_on_run_player_rebound", CLIENT_PEER, rebound_peer)
	check(String(service.call(&"selection_of", rebound_peer)) == "forager",
		"run_player_rebound moves the selection onto the new peer id")
	check(String(service.call(&"selection_of", CLIENT_PEER)) == "",
		"and leaves nothing behind on the old one")

	service.call(&"_on_run_player_expired", rebound_peer)
	check(String(service.call(&"selection_of", rebound_peer)) == "",
		"run_player_expired is what actually drops a run-player's selection")


func _on_selection_changed(peer_id: int, attunement_id: StringName) -> void:
	_events.append({"peer": peer_id, "attunement": attunement_id})


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
