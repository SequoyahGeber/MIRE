class_name RangedWeaponDef
extends Resource

## Static definition of one ranged weapon (a bow), authored by hand as a .tres in
## content/ranged_weapons/ and keyed by the `ItemDef.id` it belongs to — same convention as
## `WeaponDef` (systems/combat/weapon_def.gd), but a SEPARATE content family rather than new fields
## on that class: a ranged weapon fires an ammo item instead of colliding a static arc, and its hit
## is decided at the end of a variable-length flight, not at a fixed instant inside a swing. An item
## may have at most one of WeaponDef/RangedWeaponDef; `CombatService.request_attack()` checks
## `Registry.has_ranged_weapon()` first and hands the whole action to `RangedCombatService` when it
## does, so the two content families and their host state machines never run for the same hotbar slot
## at once (task 5.3).
##
## Network authority: none directly, same as WeaponDef. This is the description of a shot, not an
## attempt at one — see autoload/ranged_combat_service.gd for the host-authoritative attempt.

## The BOW's own item id (e.g. &"short_bow"). Not a separate id, same convention as WeaponDef.item_id.
@export var item_id: StringName = &""
@export var display_name: String = ""

## The item consumed from the shooter's own HOST inventory, one per shot (e.g. &"arrow"). The host
## re-checks and re-removes this itself at the moment the arrow is loosed, never trusted from a
## client, and never reserved during the draw — a draw that never resolves (the peer drops mid-draw)
## burns no ammo.
@export var ammo_item_id: StringName = &""

@export_group("Timing")
## Committed draw before the arrow releases. Same DESIGN.md §6 "you cannot cancel a swing" logic as
## WeaponDef.wind_up_seconds — a real cost, not an animation offset.
@export_range(0.05, 3.0, 0.01) var draw_seconds: float = 0.55
## Locked-out tail AFTER the arrow has already left the bow. draw + flight time + this is the whole
## action; the host will not accept another shot from this peer until it has elapsed. Flight time
## itself is not authored here — it is however long the arrow actually takes to connect or run out
## of range, which is not knowable up front.
@export_range(0.02, 2.0, 0.01) var recovery_seconds: float = 0.35

@export_group("Flight")
@export_range(1.0, 120.0, 0.5) var projectile_speed_m_s: float = 34.0
## Drop applied to the arrow's own vertical velocity, as a fraction of real gravity. 0 is a dead-
## straight, hitscan-feeling shot; DESIGN.md's "chunky, readable" combat is why v1 favours a near-flat
## default rather than an arc a player has to learn to lead.
@export_range(0.0, 1.0, 0.01) var gravity_scale: float = 0.0
## Distance the arrow travels before it despawns as a miss, absent any collision.
@export_range(5.0, 200.0, 1.0) var max_range_m: float = 60.0
@export_range(1, 999, 1) var damage: int = 4

@export_group("Feel — client-local, never networked")
## Same D-033 reasoning as WeaponDef: this stalls only the shooter's own local draw/recovery clock,
## never Engine.time_scale (which would also stall the network pump every transport is polled from).
@export_range(0.0, 0.4, 0.005) var hitstop_seconds: float = 0.05
@export_range(0.0, 1.0, 0.005) var shake_magnitude: float = 0.08
@export_range(0.0, 1.0, 0.01) var shake_duration: float = 0.16
## Null means RangedCombatService plays CombatService's own code-built placeholder thud instead — the
## SAME shared placeholder melee falls back to (`CombatService.placeholder_impact_sound()`), not a
## second copy of the procedural synthesis.
@export var impact_sound: AudioStream
@export_range(0.0, 60.0, 0.5) var impact_audible_range_m: float = 28.0


func validation_errors() -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	if item_id == &"":
		errors.append("item_id is empty")
	if ammo_item_id == &"":
		errors.append("ammo_item_id is empty")
	if draw_seconds <= 0.0 or recovery_seconds <= 0.0:
		errors.append("draw_seconds and recovery_seconds must be positive")
	if projectile_speed_m_s <= 0.0:
		errors.append("projectile_speed_m_s must be positive")
	if max_range_m <= 0.0:
		errors.append("max_range_m must be positive")
	if damage <= 0:
		errors.append("damage must be positive")
	return errors
