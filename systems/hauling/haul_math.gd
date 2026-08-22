class_name HaulMath
extends RefCounted

## Pure math behind a carried object's per-tick position — docs/SPECS.md 3.10, DESIGN.md §4.5/§5.
## No node, no network, no Registry lookup: testable standalone by tools/haul_check.gd, and it is the
## whole authority story for how the OBJECT moves, not just an implementation detail of it.
##
## The object always creeps toward the carriers' midpoint at a HOST-bounded speed — never snaps to
## it. That bound is what makes "a client cannot teleport the object" provable at all (see
## tools/haul_net_check.gd): a rogue client can misreport its OWN body's replicated position (own
## movement is client-authoritative, §2.2 row 1), but the object can only ever approach that lie at
## the rate [member HaulableDef.carry_track_speed_mps] allows, per tick, forever — it can never jump.


## Carrier positions -> where the object is trying to go this tick. Empty carriers means nobody is
## holding it, so there is no target to move toward — callers are expected to skip stepping entirely
## in that case rather than call this (see [method step]'s own carrier_count <= 0 guard, which makes
## that safe even if a caller doesn't).
static func target_position(carrier_positions: Array, current: Vector3) -> Vector3:
	if carrier_positions.is_empty():
		return current
	var sum := Vector3.ZERO
	for position: Vector3 in carrier_positions:
		sum += position
	return sum / carrier_positions.size()


## Advances [param current] toward [param target] by at most one tick's worth of bounded motion.
## DESIGN.md §5's solo rule: exactly one carrier drags the object at `solo_drag_multiplier` of the
## full track speed; two (or more, though HaulService caps it at two) track at full speed. Either
## way this is `move_toward` at a capped rate, never an assignment — that cap is the whole
## teleport-proofing, not a stylistic choice.
## [param speed_scale] is the carriers' `haul_speed` powerup stat, folded in by the caller — F-580's
## last unread stat. It arrives as a plain multiplier rather than as a PowerupService lookup because
## this file is pure math by design (see the class docstring): a static function that reached for an
## autoload could not be tested standalone, and `tools/haul_check.gd` proves the teleport bound by
## calling it with nothing else in the tree. Clamped at zero so a hostile modifier can slow a haul to
## a standstill but can never reverse it — a negative track speed would drive the object AWAY from
## its carriers, which is not a balance decision anyone would be making on purpose.
static func step(
	current: Vector3, target: Vector3, carrier_count: int, def: Resource, delta: float,
	speed_scale: float = 1.0
) -> Vector3:
	if carrier_count <= 0 or def == null:
		return current
	var speed: float = float(def.get(&"carry_track_speed_mps"))
	if carrier_count == 1:
		speed *= float(def.get(&"solo_drag_multiplier"))
	speed *= maxf(speed_scale, 0.0)
	return current.move_toward(target, speed * delta)
