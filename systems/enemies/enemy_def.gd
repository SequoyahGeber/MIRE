class_name EnemyDef
extends Resource

## Static definition of one enemy kind, authored by hand as a .tres in content/enemies/ — see
## ARCHITECTURE.md §3.1 ("content is data, not code", D-006). `EnemyWorld` loads every .tres in that
## folder at boot and indexes it by `id`.
##
## Network authority: none directly. This is the *description* of an enemy; the enemy itself is
## host-owned in every respect (ARCHITECTURE.md §2.2, "Enemies (spawn, AI, damage)"), including
## spawn, target choice, pathing, attack timing, damage and death.

@export var id: StringName = &""
@export var display_name: String = ""
## The visual. Carries no collision, health, AI or authority — `Enemy` builds all of that in code
## (D-023). A-006's crawler is the vertical-slice model.
@export var model: PackedScene

@export_group("Body")
@export_range(0.1, 4.0, 0.05) var radius_m: float = 0.45
@export_range(0.2, 6.0, 0.05) var height_m: float = 0.6

@export_group("Health")
@export_range(1, 9999, 1) var max_health: int = 12
## How long the corpse stays after `death` finishes playing, before the host despawns it.
@export_range(0.0, 30.0, 0.1) var corpse_seconds: float = 2.5

@export_group("Movement")
@export_range(0.1, 20.0, 0.1) var move_speed: float = 3.4
## How close the enemy tries to get before it stops closing. Kept under `attack_range_m` so it does
## not oscillate on the edge of its own reach.
@export_range(0.2, 8.0, 0.05) var stop_distance_m: float = 1.5
@export_range(0.5, 30.0, 0.5) var turn_speed_rad: float = 6.0

@export_group("Aggro")
## Picks up a target inside this radius…
@export_range(1.0, 80.0, 0.5) var aggro_radius_m: float = 18.0
## …and gives up outside this one. Deliberately larger: one radius makes an enemy on the boundary
## flicker between chasing and idling every tick.
@export_range(1.0, 120.0, 0.5) var deaggro_radius_m: float = 26.0

@export_group("Attack")
@export_range(0.5, 10.0, 0.05) var attack_range_m: float = 2.0
@export_range(1, 999, 1) var attack_damage: int = 6
## DESIGN.md §6 wants a readable telegraph, and A-006's `attack_tell` clip is authored at 0.4 s to
## match. Changing this without re-authoring the clip desynchronises the animation from the hit.
@export_range(0.05, 3.0, 0.05) var attack_tell_seconds: float = 0.4
## The committed swing after the tell. A-006's `attack` clip is 0.4 s and its first frame is the
## tell's last, so the two play back to back without a pop.
@export_range(0.05, 3.0, 0.05) var attack_seconds: float = 0.4
@export_range(0.0, 5.0, 0.05) var attack_recovery_seconds: float = 0.5


func validation_errors() -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	if id == &"":
		errors.append("id is empty")
	if max_health <= 0:
		errors.append("max_health must be positive")
	if attack_damage <= 0:
		errors.append("attack_damage must be positive")
	if deaggro_radius_m < aggro_radius_m:
		errors.append("deaggro_radius_m must be >= aggro_radius_m or aggro flickers on the boundary")
	if stop_distance_m > attack_range_m:
		errors.append("stop_distance_m must be <= attack_range_m or the enemy stops out of reach")
	return errors
