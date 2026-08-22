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

## Rotates the VISUAL only, never the body or its facing logic. Exists because an exported model's
## forward is a property of whoever authored it: A-006's crawler faces +Z while its own generator and
## catalog say -Z (F-039), and rotating the mesh here is cheaper and safer than re-exporting an asset
## other things are already placed against. 0 means the model faces -Z, which is Godot's forward.
@export_range(-180.0, 180.0, 1.0) var model_yaw_offset_degrees: float = 0.0

## Multiplied into every mesh's albedo at spawn (`Enemy._build_visual()`). `Color(1,1,1,1)` — the
## default — is a no-op, so every existing EnemyDef renders exactly as before. Exists so a stat-only
## variant (F-158: `bog_crawler` reuses `enemy_crawler.glb` unmodified, D-073 forbids new art for a
## mechanics task) can still read as visually distinct without authoring a new model. Cosmetic only —
## every peer loads the same `.tres` and computes the same tint, so this needs no replication
## (ARCHITECTURE.md §2.2, "VFX, audio, camera, UI" row).
@export var visual_tint: Color = Color(1.0, 1.0, 1.0, 1.0)

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
## Closes ground toward the target during the enemy's own TELL instead of standing fully still
## (2.10/5.1's default for every existing kind). 0.0 — the default — preserves that stationary
## behaviour bit-for-bit, so no shipped `EnemyDef` is affected. F-240: no field could make retreating
## through a tell fail, because the enemy never moved during one — a bigger `attack_range_m` only
## changes where the tell can trigger from, not whether it can be walked away from. A kind that sets
## this above the target's own retreat speed closes the gap a straight-backward "just take one step
## back" opens, without touching WHEN the hit resolves — `Enemy._resolve_attack()` still checks live
## distance at the end of the tell, exactly as before. Capped at `stop_distance_m`, the same arrival
## distance pursuit itself stops at, so a lunge cannot carry the enemy through its own target.
@export_range(0.0, 20.0, 0.1) var lunge_speed_m_s: float = 0.0
## docs/ENEMIES.md §4.2 — the tier-2 Fen Stalker's ambush. Multiplies the damage of the FIRST attack
## this enemy commits to after it has been sitting with no target at all; every attack after that is
## the plain `attack_damage`. 1.0 — the default — is a no-op, so no kind authored before the ladder
## moves a byte.
##
## It exists so that a kind whose idle is genuine stillness (a bittern freeze) has that stillness
## MEAN something. A creature that stands motionless and then hits you for its ordinary damage is
## just an enemy with a quiet idle; a creature whose stillness is how it earns its opening shot
## changes how a player crosses open ground. It is deliberately spent on the first COMMITTED attack
## rather than on the first one that lands — dodging the opening strike burns it, which is what makes
## spotting the thing first worth doing.
##
## Front-loaded on purpose: after the opener the enemy is an ordinary fast melee, so the pressure
## sits on the moment of being surprised instead of turning the whole fight into a damage check.
@export_range(1.0, 4.0, 0.05) var ambush_damage_multiplier: float = 1.0

@export_group("Armour")
## docs/ENEMIES.md §5.2 — the tier-3 Bog Bulwark's directional armour. Damage arriving from inside
## this arc, centred on the enemy's own facing, is multiplied by `armor_damage_multiplier`; damage
## from anywhere else is unreduced. 0.0 — the default — means no armour at all, so no kind authored
## before the ladder changes by a byte.
##
## Expressed as an ARC rather than as a flat resistance because the point is not that the creature is
## tough, it is that the fight is about **where you are standing**. A flat 70% reduction is a health
## bar with more numbers in it; a 160-degree frontal arc is a co-op problem — somebody holds its
## attention while somebody else gets behind it (`DESIGN.md` §P3, roles without classes).
##
## The direction is taken from the INSTIGATOR'S OWN POSITION at the moment the damage lands, so it
## works for melee and will work unchanged for a projectile whose instigator is the shooter. Damage
## with no locatable instigator — a peer id of 0, a player that has left — is never reduced: failing
## OPEN matters, because failing closed would let an unattributable damage source be silently
## nullified by armour it was never meant to be standing in front of.
@export_range(0.0, 360.0, 5.0) var armor_arc_degrees: float = 0.0
## What a hit inside the arc is multiplied by. Never zero in practice: a hit that does literally
## nothing reads as a bug rather than as armour, and it also makes a solo player's fight unwinnable
## rather than merely wrong.
@export_range(0.05, 1.0, 0.05) var armor_damage_multiplier: float = 1.0

@export_group("Death")
## docs/ENEMIES.md §3.5 — how much corruption this kind pours into the Mire grid where it dies, and
## how wide. 0.0 — the default — means it leaves nothing, so every `EnemyDef` authored before the
## ladder behaves bit-for-bit as it did.
##
## This is the tier-1 Peatling's whole identity, and it is deliberately expressed as data on the
## `EnemyDef` rather than as a Peatling-shaped special case in `Enemy`: "dies into corrupted ground"
## is a property a later kind may well want too, and D-006 ("content is data, not code") is what
## keeps that from becoming a second special case.
##
## Host-only in effect: `Enemy._enter_death()` is only ever reached through `host_apply_damage()`'s
## own authority gate, and `MireGrid.host_add_corruption()` refuses a client a second time. Nothing
## is replicated from here — the resulting corruption replicates itself, through `WorldDeltaLog`.
@export_range(0.0, 1.0, 0.01) var death_corruption_amount: float = 0.0
## Falls off linearly to nothing at this radius, so the stain has a soft edge.
@export_range(0.0, 24.0, 0.5) var death_corruption_radius_m: float = 0.0

@export_group("Perception")
## The full arc, centred on the enemy's own facing, it can ACQUIRE a new target within. 360 means
## omnidirectional — Enemy v1's original behaviour, and still the default: a value below 360 gives
## an enemy a genuine blind side. Gates acquisition only. An already-held target is kept on distance
## alone (the Aggro group's hysteresis, below); it is never re-checked against the cone, so ducking
## behind an enemy that has already spotted you does not un-aggro it.
@export_range(1.0, 360.0, 1.0) var vision_angle_deg: float = 360.0
## Acquisition additionally requires an unobstructed ray to the candidate — world geometry blocks it,
## nothing else does. Like the cone above, this is checked only at acquisition, never at retention.
@export var requires_line_of_sight: bool = true

@export_group("Group")
## On a NEW acquisition (not a refreshed hold of the same target), every enemy within this radius
## that currently has no target of its own is handed the same one directly — no cone or line-of-sight
## check, because an alert is "a packmate shouted", not "a packmate saw". Alerting is one hop: an
## enemy woken this way does not itself alert further, so a spotted player draws the pack without
## chaining across the whole map (see `Enemy._alert_nearby()`). 0 disables alerting for this kind.
@export_range(0.0, 60.0, 0.5) var alert_radius_m: float = 8.0
## How many of this enemy's kind may be committed to TELL/ATTACK against the same target at once. One
## that reaches attack range while the cap is already full holds its position instead of telegraphing
## — the pack surrounds and takes turns rather than alpha-striking together.
@export_range(1, 12, 1) var max_concurrent_attackers: int = 2


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
	# Either both death-corruption fields are set or neither is. One alone is always an authoring
	# slip — an amount with no radius stains nothing and a radius with no amount stains nothing, and
	# both fail SILENTLY, which is the worst way for a kind's entire identity to go missing.
	if (death_corruption_amount > 0.0) != (death_corruption_radius_m > 0.0):
		errors.append("death_corruption_amount and death_corruption_radius_m must both be set or both be zero")
	# Same shape of authoring slip as the pair above: an arc with no reduction and a reduction with no
	# arc both mean "no armour", and both do it silently.
	if (armor_arc_degrees > 0.0) != (armor_damage_multiplier < 1.0):
		errors.append("armor_arc_degrees and armor_damage_multiplier must both be set or neither")
	return errors
