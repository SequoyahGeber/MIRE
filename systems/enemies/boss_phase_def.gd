class_name BossPhaseDef
extends Resource

## One phase of a boss fight — an entry in `BossDef.phases`, authored in descending health-threshold
## order (task 5.5). `Boss` enters phase N the instant its health fraction drops to or below that
## phase's `hp_threshold_fraction`; see `BossDef.phase_for_health_fraction()` for the exact rule, and
## `Boss._update_phase()` for where it is applied. Phase 0's threshold should always be 1.0 — the
## phase the boss is in from the moment it engages, at full health.
##
## Network authority: none directly, same as `EnemyDef`/`BossMoveDef` — every peer holds the
## identical array from the same `BossDef`; only the active INDEX (`Boss.phase`) is replicated.

## The health fraction (0..1) at or below which this phase becomes active. Author phases in
## descending order — 1.0, then lower — so `BossDef.phase_for_health_fraction()`'s scan is
## meaningful; `validation_errors()` on the owning `BossDef` checks the ordering, not this file alone.
@export_range(0.0, 1.0, 0.01) var hp_threshold_fraction: float = 1.0

## The attacks available once this phase is active. Empty is valid — a boss with no phases defining
## any moves falls back to `EnemyDef`'s own single fixed attack (`Boss._enter_tell()`'s super() path),
## which is also what makes an entirely vanilla `BossDef` (no phases at all beyond the implicit one)
## behave exactly like a plain `Enemy` with a health bar and a stinger.
@export var moves: Array[BossMoveDef] = []

## Multiplies `EnemyDef.move_speed` while this phase is active — a later phase that visibly speeds up
## or staggers is a common boss beat, and this is the one knob for it. 1.0 = no change.
@export_range(0.1, 5.0, 0.05) var move_speed_multiplier: float = 1.0

## Arms the arena leash for this phase (task 5.5's "arena flags"): while true, `Boss` never drops an
## already-held target for straying beyond `BossDef.arena_radius_m` of the boss's own spawn point —
## see `Boss._within_arena_leash()`. The PHYSICAL wall/pylons a player actually sees are boss-specific
## content (docs/ASSET_TRACKER.md A-027's "arena pylons"), built by whichever task authors the real
## fight (5.6/5.7/5.8) — this flag is the framework's half: the DECISION that this phase is sealed,
## not the geometry that shows it.
@export var seals_arena: bool = false

## Optional per-phase music cue id, read by `BossMusicDirector` off `boss_phase_changed`. Empty plays
## nothing extra beyond the shared stinger every phase change already gets — see
## `BossMusicDirector.CUE_PATHS` for the id -> asset mapping and what an unknown id falls back to.
@export var music_cue: StringName = &""


func validation_errors() -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	if hp_threshold_fraction < 0.0 or hp_threshold_fraction > 1.0:
		errors.append("hp_threshold_fraction must be within 0..1")
	if move_speed_multiplier <= 0.0:
		errors.append("move_speed_multiplier must be positive")
	for move: BossMoveDef in moves:
		if move == null:
			errors.append("moves contains a null entry")
			continue
		for move_error: String in move.validation_errors():
			errors.append("move '%s': %s" % [move.id, move_error])
	return errors
