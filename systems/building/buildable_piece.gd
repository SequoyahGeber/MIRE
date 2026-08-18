extends Node3D

## F-085: the `&"damageable"` group's whole contract, attached to a placed buildable root.
##
## `autoload/build_service.gd`'s `_net_spawn_piece()` adds every piece to `&"damageable"` on every
## peer, but a bare `StaticBody3D` (the generated fallback) or an art-only authored scene root
## (task 3.7) carries no script and so no `host_apply_damage()` — `CombatService._best_target()`
## then silently skips it (`autoload/combat_service.gd:251`), and nothing can ever hit it. This
## script IS the piece's implementation of that contract; `BuildService` attaches it at spawn time
## to whichever root doesn't already bring its own (see `_net_spawn_piece`'s comment for why).
##
## Mirrors `Harvestable._owns_world_mutation()` / `Enemy._owns_simulation()`'s shape exactly: the
## damage method re-checks authority itself rather than trusting a caller CombatService already
## gates, because "someone else already checked" is how a check gets silently removed later.
##
## `hp` is host-only and deliberately unreplicated — a piece's remaining HP has no visual yet (task
## 3.7 owns damaged-state art), and the only state a client needs is whether the piece still EXISTS,
## which already replicates through `BuildService`'s code-built `MultiplayerSpawner` the moment the
## host `queue_free()`s it (D-023).

var hp: int = 1


## Host-only. Returning false is a no-op, not a phantom hit — same contract as
## `Harvestable.host_apply_damage()` and `Enemy.host_apply_damage()`, and for the same reason:
## `CombatService` only broadcasts a landed hit when this returns true.
func host_apply_damage(amount: int, instigator_peer_id: int) -> bool:
	if not _owns_world_mutation() or amount <= 0 or hp <= 0:
		return false

	hp = maxi(hp - amount, 0)
	if hp == 0:
		var build_service: Node = get_node_or_null(^"/root/BuildService")
		if build_service != null and build_service.has_method(&"host_piece_destroyed_by_damage"):
			build_service.call(&"host_piece_destroyed_by_damage", StringName(name), instigator_peer_id)
	return true


func _owns_world_mutation() -> bool:
	var transport: Node = get_node_or_null(^"/root/NetTransport")
	if transport == null:
		return true
	if bool(transport.call("is_host")):
		return true
	return not bool(transport.call("is_active")) and not bool(transport.call("is_connecting"))
