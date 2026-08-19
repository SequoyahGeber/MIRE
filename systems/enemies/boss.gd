class_name Boss
extends Enemy

## Task 5.5's boss framework: phases, an arena leash, per-phase telegraphed moves, a replicated
## health-bar seam and music-stinger `EventBus` hooks — all layered on `Enemy`'s existing
## IDLE -> CHASE -> TELL -> ATTACK -> RECOVER machine through ordinary GDScript overriding. Every
## override below either falls through to `super()` when a `BossDef` authors nothing extra (so a
## `BossDef` with empty `phases` behaves exactly like a plain `Enemy` with a health bar and a
## stinger), or replaces the one decision a boss makes differently.
##
## **Touches zero lines of `enemy.gd`.** `systems/enemies/enemy.gd` was claimed by another lane
## (7.7, mid-brief) for this task's whole session — every hook this file needs already exists as an
## ordinary overridable method or an inherited member var, so nothing here required editing it. See
## the per-method comments below for exactly which base behaviour each override extends.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, "Enemies (spawn, AI, damage)"): unchanged, still
## **HOST** — no new row. A boss is spawned, simulated and killed by the exact same rules an ordinary
## `Enemy` is; `phase` and `move_index` are two more `REPLICATION_MODE_ALWAYS` properties on the same
## `MultiplayerSynchronizer` `Enemy._build_synchronizer()` already builds (D-116 records why no new
## row was needed). The one thing worth calling out twice: `EventBus.emit_boss_engaged()` /
## `emit_boss_phase_changed()` fire from `phase`'s own setter, and `emit_boss_defeated()` fires from
## `_play_state_animation()` (itself called from `Enemy.state`'s replicated setter) — never from a
## host-only `if _owns_simulation()` guard, which is the exact bug `docs/FINDINGS.md` F-168 still has
## open against `Wellspring.capped`. Firing from a replicated property's setter means every peer's own
## `EventBus` static reaches this emit on its own, from its own local set, the moment the host's value
## (or its replicated echo) lands — no second RPC required for cosmetic consumers like
## `BossMusicDirector`/`BossHealthHud`.

const BOSS_DEF := preload("res://systems/enemies/boss_def.gd")
const BOSS_MOVE_DEF := preload("res://systems/enemies/boss_move_def.gd")
## `EVENT_BUS` is NOT redeclared here — `Enemy` already has it (`const EVENT_BUS := preload(...)`),
## and GDScript refuses to shadow an inherited const/member with a same-named one in a subclass
## ("The member already exists in parent class"). It is used below via plain inheritance.

const BOSS_GROUP: StringName = &"bosses"
## `phase` starts here — "engaged" (task 5.5's `boss_engaged` event) is the transition OUT of this
## value, never a value in its own right. `BossDef.phase_for_health_fraction()` never returns it.
const DORMANT_PHASE: int = -1
## Deterministic, matching `WaveSpawner._rng`'s own convention (systems/waves/wave_spawner.gd) — a
## fixed seed for a host-only decision nobody else needs to agree with, so `tools/boss_check.gd` can
## assert an exact weighted-roll distribution instead of tolerating a flake-prone range.
const MOVE_RNG_SEED: int = 0x424f5353  # "BOSS"

## Replicated (see `_build_synchronizer()` below). -1 until the boss takes its first target; from
## then on, an index into `BossDef.phases`. The setter is the single place every phase-change
## consequence (the two `EventBus` emits, nothing else — presentation reads `phase` directly) lives,
## so every peer reaches it identically whether it just computed the value itself (the host) or
## received it over the wire (a client, through the property's own replicated set).
var phase: int = DORMANT_PHASE:
	set(value):
		if phase == value:
			return
		var previous: int = phase
		phase = value
		# Guarded on is_inside_tree() so a member initializer's own assignment (which GDScript may
		# route through this same setter, at construction time, before _ready() and before
		# `definition` is guaranteed set) can never fire a premature EventBus emit — every real
		# transition happens during _physics_process or a spawn snapshot, both always in-tree.
		if is_inside_tree():
			_react_to_phase(previous, value)

## Replicated. -1 when no move is in flight; otherwise an index into the ACTIVE phase's own
## `moves` array (`_moves_for_phase()`), read by both the host's own attack timing
## (`_tick_attack()`/`_resolve_attack()`) and every peer's presentation (`_play_state_animation()`) —
## one source of truth instead of a host-only cache that could drift from what clients render.
var move_index: int = -1

## Where the arena is centred — the boss's own spawn point, fixed for the fight's whole life. A
## boss that is meant to guard a specific POI (5.6's Wellspring) should spawn there; nothing here
## reads the POI system directly, since that coupling belongs to the task that actually places one.
var arena_center: Vector3 = Vector3.ZERO

var _defeat_emitted: bool = false
var _move_rng := RandomNumberGenerator.new()


func _ready() -> void:
	super._ready()
	add_to_group(BOSS_GROUP)
	arena_center = global_position
	_move_rng.seed = MOVE_RNG_SEED


# ── Health / phases ───────────────────────────────────────────────────────────────────────────────


## Extends the damage seam (2.8/5.1): same acceptance rules as `Enemy`, plus recomputing which phase
## the new health fraction belongs to. Runs after `super()` so `health` already reflects the hit.
func host_apply_damage(amount: int, instigator_peer_id: int) -> bool:
	var accepted: bool = super.host_apply_damage(amount, instigator_peer_id)
	if accepted and state != State.DEAD:
		_update_phase()
	return accepted


## Extends `Enemy._acquire_target()` — the ONE place (alongside a fresh scan) a target is newly taken
## — to also mark the fight as engaged the first time it happens. Reusing that exact call site is what
## keeps this consistent with 5.1's own alerting rule: an alerted packmate re-affirming an existing
## hold is not a new acquisition, and neither is it an engagement.
func _acquire_target(peer_id: int, node: Node3D) -> void:
	var was_dormant: bool = phase == DORMANT_PHASE
	super._acquire_target(peer_id, node)
	if was_dormant and peer_id > 0:
		_update_phase()


## Host-only (only ever reached through `host_apply_damage()`/`_acquire_target()`, both already
## host-gated by their own callers). Phases only ever advance — there is no heal mechanic yet, but a
## monotonic `phase` means one never has to reason about a boss stepping BACKWARD into an earlier
## moveset if one is ever added.
func _update_phase() -> void:
	var boss_def := definition as BOSS_DEF
	if boss_def == null or definition.max_health <= 0:
		return
	var fraction: float = float(health) / float(definition.max_health)
	var target_index: int = boss_def.phase_for_health_fraction(fraction)
	if phase == DORMANT_PHASE or target_index > phase:
		phase = target_index


## The one place `boss_engaged`/`boss_phase_changed` are emitted — see the class doc comment on why
## hanging this off `phase`'s own setter (not a host-only guard) is load-bearing, not stylistic.
func _react_to_phase(previous: int, new_phase: int) -> void:
	var boss_id: StringName = definition.id if definition != null else &""
	if previous == DORMANT_PHASE:
		EVENT_BUS.emit_boss_engaged(boss_id, global_position)
	else:
		EVENT_BUS.emit_boss_phase_changed(boss_id, previous, new_phase, global_position)


# ── Movement (per-phase speed) ────────────────────────────────────────────────────────────────────


## Extends `Enemy._tick_pursuit()` — arena leash first (below), then the base pursuit/attack-entry
## logic unchanged, then the active phase's speed multiplier applied to whatever CHASE velocity the
## base just computed. Multiplying after the fact rather than mutating `definition.move_speed` matters:
## `definition` is a shared `Resource` (every boss of the same kind points at the same `.tres`), so
## writing through it would leak one boss's phase into every other live instance of the same kind.
func _tick_pursuit(delta: float) -> void:
	_enforce_arena_leash()
	super._tick_pursuit(delta)
	if state == State.CHASE:
		var multiplier: float = _move_speed_multiplier()
		velocity.x *= multiplier
		velocity.z *= multiplier


func _move_speed_multiplier() -> float:
	var phase_def: BossPhaseDef = _active_phase()
	return phase_def.move_speed_multiplier if phase_def != null else 1.0


# ── Arena leash (task 5.5's "arena flags") ───────────────────────────────────────────────────────
#
# The framework's half of "arena": a DATA-driven decision about whether this fight can be walked
# away from right now. The physical wall/pylons a player actually sees are boss-specific content
# (docs/ASSET_TRACKER.md A-027) built by whichever task authors the real fight (5.6/5.7/5.8) — see
# `BossPhaseDef.seals_arena`'s own header for the full split.


## Acquisition-time gate (task 5.1's `_can_perceive()` seam, already virtual): on top of whatever
## `super()` already requires (facing cone, optional line-of-sight), a boss never acquires someone
## outside its own arena in the first place. `_arena_radius()` returns INF for a plain `EnemyDef`
## (no `BossDef.arena_radius_m` to read), so this is a no-op for that fallback path.
func _can_perceive(player: Node3D) -> bool:
	if not super._can_perceive(player):
		return false
	var radius: float = _arena_radius()
	if radius == INF:
		return true
	return arena_center.distance_to(player.global_position) <= radius


## Retention-time gate, run once per physics tick BEFORE `Enemy._tick_pursuit()`'s own
## `_resolve_target()` call. `_target_peer`/`_target_node` are `Enemy`'s own inherited fields — reset
## to "no target" here has the same effect `_resolve_target()`'s own deaggro-radius check already
## produces, just anchored to `arena_center` instead of the boss's live position, and skipped entirely
## while the active phase's `seals_arena` is true (task 5.5's arena flag: sealed means no leash, on
## the assumption a later task's real wall already stops anyone leaving).
func _enforce_arena_leash() -> void:
	if _target_peer <= 0 or _target_node == null or not is_instance_valid(_target_node):
		return
	if _arena_sealed():
		return
	var radius: float = _arena_radius()
	if radius == INF:
		return
	if arena_center.distance_to(_target_node.global_position) > radius:
		_target_peer = 0
		_target_node = null


func _arena_radius() -> float:
	var boss_def := definition as BOSS_DEF
	return boss_def.arena_radius_m if boss_def != null else INF


func _arena_sealed() -> bool:
	var phase_def: BossPhaseDef = _active_phase()
	return phase_def != null and phase_def.seals_arena


# ── Telegraphs: per-phase moves instead of one fixed attack ─────────────────────────────────────


## Extends `Enemy._enter_tell()`: with no move available for the active phase (an empty `phases`
## array, or a phase authored with no `moves`), falls straight through to the base's single fixed
## attack — the framework's minimal-boss fallback described in the class doc comment. Otherwise picks
## one move (weighted, `_pick_move_index()`) and tells with ITS `tell_seconds`.
func _enter_tell() -> void:
	var moves: Array[BossMoveDef] = _moves_for_phase()
	if moves.is_empty():
		move_index = -1
		super._enter_tell()
		return
	move_index = _pick_move_index(moves)
	state = State.TELL
	_phase_remaining = moves[move_index].tell_seconds


## Extends `Enemy._tick_attack()`'s TELL/ATTACK/RECOVER clock with the chosen move's own three
## durations in place of `EnemyDef`'s fixed ones. Falls through to `super()` when `_current_move()` is
## null — either the fallback path above, or (defensively) a move index that stopped resolving because
## the boss changed phase mid-swing, which should not happen (a committed attack finishes before the
## next tick can re-enter `_tick_pursuit()`) but is cheap to guard rather than assume.
func _tick_attack(delta: float) -> void:
	var move: BossMoveDef = _current_move()
	if move == null:
		super._tick_attack(delta)
		return
	velocity.x = 0.0
	velocity.z = 0.0
	_phase_remaining -= delta
	if _phase_remaining > 0.0:
		return
	match state:
		State.TELL:
			_resolve_attack()
			state = State.ATTACK
			_phase_remaining = move.attack_seconds
		State.ATTACK:
			state = State.RECOVER
			_phase_remaining = move.recovery_seconds
		_:
			state = State.CHASE
			_phase_remaining = 0.0
			move_index = -1


## Extends `Enemy._resolve_attack()`: same "hit resolves at the end of the tell, against where the
## target is NOW" rule (5.1's own comment on this), using the chosen move's damage/range instead of
## `EnemyDef`'s fixed ones. Falls through to `super()` under the same null-move conditions as
## `_tick_attack()`.
func _resolve_attack() -> void:
	var move: BossMoveDef = _current_move()
	if move == null:
		super._resolve_attack()
		return
	var target: Node3D = _resolve_target()
	if target == null:
		return
	var to_target: Vector3 = target.global_position - global_position
	if Vector3(to_target.x, 0.0, to_target.z).length() > move.range_m:
		return
	EVENT_BUS.emit_enemy_attack_landed(definition.id, _target_peer, move.damage, target.global_position)


func _current_move() -> BossMoveDef:
	var moves: Array[BossMoveDef] = _moves_for_phase()
	if move_index < 0 or move_index >= moves.size():
		return null
	return moves[move_index]


func _moves_for_phase() -> Array[BossMoveDef]:
	var phase_def: BossPhaseDef = _active_phase()
	if phase_def != null:
		return phase_def.moves
	# A bare `[]` here is an untyped Array literal — returning it directly through this function's
	# `-> Array[BossMoveDef]` signature threw at runtime ("Trying to assign an array of type Array to
	# a variable of type Array[BossMoveDef]") the moment a caller assigned the result into its own
	# typed local, which a dormant boss's very first `_ready()` -> `_play_state_animation()` ->
	# `_current_move()` call hit on EVERY spawn. Assigning the literal into a properly-typed local
	# first, instead of returning it inline, is what actually gets the runtime conversion to stick.
	var empty: Array[BossMoveDef] = []
	return empty


func _active_phase() -> BossPhaseDef:
	var boss_def := definition as BOSS_DEF
	if boss_def == null or phase < 0 or phase >= boss_def.phases.size():
		return null
	return boss_def.phases[phase]


## Weighted random pick among `moves` — every weight is clamped away from zero first so a mis-authored
## 0-weight move stays pickable-but-rare instead of raising a division error.
func _pick_move_index(moves: Array[BossMoveDef]) -> int:
	var total_weight: float = 0.0
	for move: BossMoveDef in moves:
		total_weight += maxf(move.weight, 0.0001)
	var roll: float = _move_rng.randf() * total_weight
	var cursor: float = 0.0
	for i: int in moves.size():
		cursor += maxf(moves[i].weight, 0.0001)
		if roll <= cursor:
			return i
	return moves.size() - 1


# ── Presentation (client-local, every peer) — health bar + defeat stinger hook ──────────────────


## Extends `Enemy._play_state_animation()`, itself called from `Enemy.state`'s replicated setter —
## the one call site that already runs on every peer, host and client alike, with no RPC of its own
## (see the class doc comment). Two jobs: play the CHOSEN move's own clip while TELL/ATTACK-ing
## instead of `EnemyDef`'s fixed `attack_tell`/`attack` names, and fire `boss_defeated` the instant
## `state` first reaches DEAD — on every peer, for the reason explained at the top of this file.
func _play_state_animation() -> void:
	var move: BossMoveDef = _current_move()
	var played_move_clip: bool = false
	if move != null and _anim != null and (state == State.TELL or state == State.ATTACK):
		var clip: StringName = move.tell_animation if state == State.TELL else move.attack_animation
		if _anim.has_animation(String(clip)):
			_anim.play(String(clip))
			played_move_clip = true
	if not played_move_clip:
		super._play_state_animation()

	if state == State.DEAD and not _defeat_emitted:
		_defeat_emitted = true
		EVENT_BUS.emit_boss_defeated(definition.id if definition != null else &"", global_position)


## Extends `Enemy._build_synchronizer()`: same code-built `SceneReplicationConfig` (D-023), with
## `phase`/`move_index` added to the property list `super()` already built and spawned. `_sync` is
## `Enemy`'s own inherited node reference — populated by the `super()` call just above, so it is safe
## to read here.
func _build_synchronizer() -> void:
	super._build_synchronizer()
	var config: SceneReplicationConfig = _sync.replication_config
	for property: NodePath in [^".:phase", ^".:move_index"]:
		config.add_property(property)
		config.property_set_spawn(property, true)
		config.property_set_replication_mode(property, SceneReplicationConfig.REPLICATION_MODE_ALWAYS)


## Public: the health fraction a HUD should show, 0..1. Safe against a `null`/zero-health def.
func health_fraction() -> float:
	if definition == null or definition.max_health <= 0:
		return 0.0
	return clampf(float(health) / float(definition.max_health), 0.0, 1.0)


## Public: how many phases this boss's `BossDef` authors, for a HUD's phase-pip row. 1 for a plain
## `EnemyDef`/empty-`phases` `BossDef` — the single implicit phase the fallback path plays out in.
func phase_count() -> int:
	var boss_def := definition as BOSS_DEF
	return maxi(boss_def.phases.size(), 1) if boss_def != null else 1


## Public: true once this boss has taken its first target and is not yet dead — what a HUD gates
## visibility on.
func is_engaged() -> bool:
	return phase != DORMANT_PHASE and state != State.DEAD
