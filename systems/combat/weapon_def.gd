class_name WeaponDef
extends Resource

## Static definition of one melee swing, authored by hand as a .tres in content/weapons/ and keyed by
## the `ItemDef.id` it belongs to — see ARCHITECTURE.md §3.1 ("content is data, not code"). An item
## with no WeaponDef swings unarmed; `CombatService` owns that fallback in code so an empty hand is
## never a content authoring job.
##
## Network authority: none directly, same as ItemDef and RecipeDef. This is the *description* of a
## swing, not an attempt at one. The attempt is host-validated (ARCHITECTURE.md §2.2, world mutation
## and enemy rows) — see autoload/combat_service.gd.

## The item this weapon belongs to. Not a separate id: a weapon is how an item swings.
@export var item_id: StringName = &""
@export var display_name: String = ""

@export_group("Timing")
## Committed wind-up before the hit resolves. DESIGN.md §6: you cannot cancel a swing, so this is a
## real cost, not an animation offset.
@export_range(0.02, 2.0, 0.01) var wind_up_seconds: float = 0.22
## How long the swing stays committed after the hit resolves. v1 resolves exactly once, at the start
## of this window; a multi-hit sweep would widen it.
@export_range(0.02, 1.0, 0.01) var commit_seconds: float = 0.12
## Locked-out tail. wind-up + commit + recovery is the whole swing, and the host will not accept
## another attack from this peer until it has elapsed.
@export_range(0.02, 2.0, 0.01) var recovery_seconds: float = 0.30

@export_group("Hitbox")
## Reach from the attacker's eye, metres.
@export_range(0.5, 6.0, 0.05) var range_m: float = 2.6
## Full width of the swing arc in degrees; the host tests half of it either side of the aim. Measured
## horizontally, so a target's mesh origin sitting on the ground cannot fall out of the arc.
@export_range(10.0, 180.0, 1.0) var arc_degrees: float = 100.0
## Vertical tolerance either side of the eye, metres. Generous on purpose: chunky, readable melee.
@export_range(0.5, 8.0, 0.1) var vertical_reach_m: float = 2.4
@export_range(1, 999, 1) var damage: int = 3

@export_group("Feel — client-local, never networked")
## Freeze applied to the attacker's own swing clock and camera on a connect. This is NOT
## `Engine.time_scale` (D-033): slowing a client's frame rate slows its network pump.
@export_range(0.0, 0.4, 0.005) var hitstop_seconds: float = 0.07
## Peak camera displacement of the impact shake, metres.
@export_range(0.0, 1.0, 0.005) var shake_magnitude: float = 0.11
@export_range(0.0, 1.0, 0.01) var shake_duration: float = 0.22
## Authored impact sound. Null means CombatService plays its code-built placeholder thud instead, so
## 2.9 has something to tune against before any audio asset exists.
@export var impact_sound: AudioStream
@export_range(0.0, 60.0, 0.5) var impact_audible_range_m: float = 24.0


## Total locked-out duration of one swing.
func swing_seconds() -> float:
	return wind_up_seconds + commit_seconds + recovery_seconds


func validation_errors() -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	if item_id == &"":
		errors.append("item_id is empty")
	if wind_up_seconds <= 0.0 or commit_seconds <= 0.0 or recovery_seconds <= 0.0:
		errors.append("every swing phase must be a positive duration")
	if range_m <= 0.0:
		errors.append("range_m must be positive")
	if arc_degrees <= 0.0 or arc_degrees > 180.0:
		errors.append("arc_degrees must be within (0, 180]")
	if damage <= 0:
		errors.append("damage must be positive")
	return errors
