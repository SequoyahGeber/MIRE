class_name BossDef
extends EnemyDef

## Static definition of one boss (task 5.5) — everything `EnemyDef` already gives an ordinary enemy
## (body, health, movement, aggro, perception, group behaviour) plus phases, an arena radius and the
## music cue ids `BossMusicDirector` reads by name. Authored by hand as a .tres in `content/enemies/`
## exactly like `EnemyDef` — `EnemyWorld._load_defs()` needs no change to find one: `res is ENEMY_DEF`
## is already true for a `BossDef`, since this class extends it.
##
## Network authority: none directly, same as `EnemyDef`. `Boss` (`systems/enemies/boss.gd`) is the
## host-owned thing that reads this data; see its header comment for the full authority story.
##
## **No worked-example content ships with this task.** 5.6/5.7/5.8 own the three actual bosses
## (Wellspring guardian, Hunt-spawned roaming elite, deep-Cycle threat) — this is the framework those
## tasks build their own `.tres` against, proven end-to-end by `tools/boss_check.gd` with synthetic
## defs rather than a placeholder boss with no model (AGENTS.md's "never bulk-generate content data"
## cuts the other way too: a fake boss authored only to exercise the framework is still content, and
## D-073 says that is 5.6+'s job, not this one's).

## Phases in descending `hp_threshold_fraction` order — see `BossPhaseDef`'s own header. Empty is
## valid: `Boss` then behaves like a plain `Enemy` (one fixed attack from the fields above) with a
## health bar and an engage/defeat stinger, which is a legitimate minimal boss and the framework's own
## fallback path.
@export var phases: Array[BossPhaseDef] = []

@export_group("Arena")
## How far from the boss's own spawn point the arena leash reaches. Only enforced while the active
## phase's `seals_arena` is false (see `BossPhaseDef.seals_arena`) — a sealed phase holds its target
## regardless of distance, on the assumption a later task's real wall already stops anyone leaving.
@export_range(1.0, 200.0, 1.0) var arena_radius_m: float = 30.0

@export_group("Music")
## Read by `BossMusicDirector` off `EventBus.boss_engaged` — the id of the stinger to play the moment
## this boss takes its first target. Empty plays `BossMusicDirector.DEFAULT_ENGAGE_CUE`.
@export var engage_music_cue: StringName = &""
## Read off `EventBus.boss_defeated`. Empty plays `BossMusicDirector.DEFAULT_DEFEAT_CUE`.
@export var defeat_music_cue: StringName = &""


## The phase index active at `fraction` (0..1 of max health), scanning `phases` in array order and
## keeping the LAST index whose threshold the fraction still satisfies. Authored in descending
## threshold order this is monotonic — once a threshold stops being satisfied, every later (lower)
## one does too — so the loop needs no early-exit special case to be correct even against a
## mis-ordered array; `validation_errors()` below is what actually enforces the ordering at author
## time. Returns 0 (not -1) for an empty `phases` array — callers that only care "is this dormant or
## not" gate on `Boss.phase == Boss.DORMANT_PHASE` separately, never on this method's return alone.
func phase_for_health_fraction(fraction: float) -> int:
	var index: int = 0
	for i: int in phases.size():
		if fraction <= phases[i].hp_threshold_fraction:
			index = i
	return index


func validation_errors() -> PackedStringArray:
	var errors: PackedStringArray = super.validation_errors()
	if arena_radius_m <= 0.0:
		errors.append("arena_radius_m must be positive")
	var previous_threshold: float = 1.0000001  # phases[0] must be able to equal 1.0
	for i: int in phases.size():
		var phase: BossPhaseDef = phases[i]
		if phase == null:
			errors.append("phases[%d] is null" % i)
			continue
		if phase.hp_threshold_fraction > previous_threshold:
			errors.append(
				"phases must be authored in descending hp_threshold_fraction order (phase %d breaks it)"
				% i
			)
		previous_threshold = phase.hp_threshold_fraction
		for phase_error: String in phase.validation_errors():
			errors.append("phases[%d]: %s" % [i, phase_error])
	if not phases.is_empty() and phases[0].hp_threshold_fraction < 1.0:
		errors.append("phases[0].hp_threshold_fraction should be 1.0 — nothing covers full health otherwise")
	return errors
