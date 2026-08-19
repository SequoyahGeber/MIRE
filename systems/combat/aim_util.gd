class_name CombatAim
extends RefCounted

## Where a player's eye is, and which way it's looking — the one formula every host-resolved ranged
## attack needs (task 5.3's bow). Pure and node-free on purpose, same discipline as
## `EntitySelector`/`PlacementValidator`: an aim direction is a fact about a transform, not about a
## live combat system, so it should be testable without one.
##
## Reads the player's OWN already-replicated transform (position + body yaw) plus its CameraPivot's
## already-replicated pitch — never anything sent alongside an attack/shot request itself — so the
## host never has to trust an aim vector a client could lie about (ARCHITECTURE.md §2.2). This is the
## exact formula `autoload/combat_service.gd`'s melee path has used since task 2.8
## (`_aim_direction()`/`EYE_HEIGHT_M`, private to that file); it is not factored out of melee's own
## copy for this task, to avoid touching tested swing-resolution code that already ships. A future
## cleanup can point combat_service.gd at this too — until then, keeping both formulas identical is
## the contract, not a shared call site.

const EYE_HEIGHT_M: float = 1.5


static func eye_position(player: Node3D) -> Vector3:
	return player.global_position + Vector3.UP * EYE_HEIGHT_M


## Body yaw plus replicated camera pitch, exactly like combat_service.gd's `_aim_direction()`.
static func direction(player: Node3D) -> Vector3:
	var pitch: float = 0.0
	var pivot := player.get_node_or_null(^"CameraPivot") as Node3D
	if pivot != null:
		pitch = pivot.rotation.x
	return Vector3(0.0, 0.0, -1.0).rotated(Vector3.RIGHT, pitch).rotated(Vector3.UP, player.rotation.y)
