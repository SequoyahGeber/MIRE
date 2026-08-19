class_name BossMoveDef
extends Resource

## One telegraphed attack a boss can perform, authored by hand as part of a `BossPhaseDef.moves`
## array (task 5.5). `Enemy`/`EnemyDef` give every enemy exactly one attack, fixed for the whole
## fight; a boss needs several, so the TELL -> ATTACK -> RECOVER timings, damage, range and clip
## names that `EnemyDef` bakes as flat fields become an array element here instead, one per move a
## boss actually knows.
##
## Network authority: none directly — same as `EnemyDef`. `Boss` (host-owned, ARCHITECTURE.md §2.2
## "Enemies") is the only thing that ever reads these fields to make a decision; every peer holds the
## identical array (spawned from the same `BossDef`), so only the CHOSEN move's index needs to cross
## the wire (`Boss.move_index`), never the move's own data.

@export var id: StringName = &""

@export_group("Attack")
@export_range(1, 9999, 1) var damage: int = 10
@export_range(0.2, 12.0, 0.05) var range_m: float = 2.5

@export_group("Timing")
## DESIGN.md §6's readable-telegraph target applies here exactly as it does to `EnemyDef.attack_tell_
## seconds` — a boss move with a shorter tell than 0.4s is a design call worth a comment when it's
## made, not a default to reach for.
@export_range(0.05, 6.0, 0.05) var tell_seconds: float = 0.6
@export_range(0.05, 6.0, 0.05) var attack_seconds: float = 0.4
@export_range(0.0, 10.0, 0.05) var recovery_seconds: float = 0.8

@export_group("Selection")
## Relative odds this move is picked the next time the boss commits to an attack, among whatever
## other moves its current phase also allows — see `Boss._pick_move_index()`. Not a probability; only
## the ratio between moves in the same phase matters.
@export_range(0.01, 20.0, 0.01) var weight: float = 1.0

@export_group("Animation")
## Clip names on the same `AnimationPlayer` `EnemyDef.model` already carries (A-006's convention:
## `attack_tell`/`attack` are the two `Enemy` plays by default). A boss with several moves needs a
## distinct clip per move; a def whose model has no clip by this name falls back to `Enemy`'s own
## `ANIM_TELL`/`ANIM_ATTACK` silently, so an unauthored animation is a missing polish pass, not a
## broken fight — see `Boss._play_state_animation()`.
@export var tell_animation: StringName = &"attack_tell"
@export var attack_animation: StringName = &"attack"


func validation_errors() -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	if id == &"":
		errors.append("id is empty")
	if damage <= 0:
		errors.append("damage must be positive")
	if range_m <= 0.0:
		errors.append("range_m must be positive")
	return errors
