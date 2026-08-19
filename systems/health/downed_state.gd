class_name DownedState
extends RefCounted

## Pure per-player health/downed/bleed-out/respawn state machine — no node, no peer id, no network.
## PlayerHealth (autoload) owns one instance per host-keyed peer id and is the only thing that
## mutates it. Same split as systems/inventory/inventory_store.gd is to InventoryService: the
## autoload owns authority, replication and RPCs, this class only owns the arithmetic, so it is
## testable without a session.
##
## Flow (DESIGN.md §4.5, "Downed, not dead" / DESIGN §5.2): ALIVE -[hp hits 0]-> DOWNED
## -[bleed_out_remaining expires]-> DEAD -[respawn_remaining expires]-> ALIVE at full hp. A
## teammate's successful revive short-circuits DOWNED back to ALIVE at revive_hp_fraction instead of
## waiting out the bleed-out. This class knows nothing of the run's outcome — task 6.7's
## `DefeatService` decides that at the PlayerHealth level, by simply no longer calling tick() on any
## instance here once every present player is simultaneously DOWNED or DEAD (see PlayerHealth's own
## `_run_over` flag).

enum State { ALIVE, DOWNED, DEAD }

## What changed on the last tick()/apply_damage() call, so PlayerHealth reacts only to the instant
## something actually happened instead of polling state every physics step.
enum Transition { NONE, WENT_DOWN, DIED, RESPAWNED }

var max_hp: int
var hp: int
var state: int = State.ALIVE
var bleed_out_remaining: float = 0.0
var respawn_remaining: float = 0.0


func _init(starting_max_hp: int) -> void:
	max_hp = maxi(starting_max_hp, 1)
	hp = max_hp


func is_alive() -> bool:
	return state == State.ALIVE


func is_downed() -> bool:
	return state == State.DOWNED


func is_dead() -> bool:
	return state == State.DEAD


## Only an ALIVE player can be damaged — a downed or dead player has already paid for this hit, and
## M2 has no corpse-kicking. Returns Transition.WENT_DOWN the instant hp reaches 0.
func apply_damage(amount: int, bleed_out_seconds: float) -> int:
	if state != State.ALIVE or amount <= 0:
		return Transition.NONE
	hp = maxi(hp - amount, 0)
	if hp > 0:
		return Transition.NONE
	state = State.DOWNED
	bleed_out_remaining = maxf(bleed_out_seconds, 0.0)
	return Transition.WENT_DOWN


## A consumable or other host-trusted source restores hp (task 3.8). Only an ALIVE player can be
## healed — a downed player needs a revive, not a snack, and a dead player has nothing to heal yet.
## Clamps to max_hp; never raises Transition, since nothing downstream needs to react to a heal the
## way it reacts to damage or a state change.
func heal(amount: int) -> bool:
	if state != State.ALIVE or amount <= 0:
		return false
	hp = clampi(hp + amount, 0, max_hp)
	return true


## A teammate finished the revive hold. False (no-op) unless still DOWNED — the window between a
## revive starting and finishing is exactly when the bleed-out timer could beat it there.
func revive(hp_fraction: float) -> bool:
	if state != State.DOWNED:
		return false
	hp = clampi(int(round(float(max_hp) * hp_fraction)), 1, max_hp)
	state = State.ALIVE
	bleed_out_remaining = 0.0
	return true


## Advances whichever timer applies to the current state and applies the transition in the same
## call. respawn_seconds is passed in rather than stored, same reasoning as apply_damage's
## bleed_out_seconds: PlayerHealth owns the tuning, this class only owns the arithmetic.
func tick(delta: float, respawn_seconds: float) -> int:
	match state:
		State.DOWNED:
			bleed_out_remaining = maxf(bleed_out_remaining - delta, 0.0)
			if bleed_out_remaining > 0.0:
				return Transition.NONE
			state = State.DEAD
			respawn_remaining = maxf(respawn_seconds, 0.0)
			return Transition.DIED
		State.DEAD:
			respawn_remaining = maxf(respawn_remaining - delta, 0.0)
			if respawn_remaining > 0.0:
				return Transition.NONE
			hp = max_hp
			state = State.ALIVE
			respawn_remaining = 0.0
			return Transition.RESPAWNED
		_:
			return Transition.NONE
