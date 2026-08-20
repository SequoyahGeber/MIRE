extends Node

## SalvageService — autoload. Task 6.6 (DESIGN.md §4.6, §5.2): the superlinear reward curve,
## extract-vs-die split, and local persistence for **Salvage**, MIRE's meta-progression currency.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, "Salvage" row): NONE. Salvage is per-player account
## state, not simulation state — there is no "two clients disagree" case for the rule of thumb in
## §2.2 to apply to, because no peer ever reads another peer's balance. Every peer runs this exact
## same autoload and reacts only to events it received on ITS OWN local `EventBus` (a per-process
## static), banking only into ITS OWN `user://salvage.json`. `ExtractionShip.departed`'s setter was
## reworked this task specifically so `run_extracted` reaches every peer's local bus, not just the
## host's — see that file's own comment.
##
## `EventBus.subscribe_run_wiped()` has no real emitter yet — task 6.7 ("Lose condition") owns
## deciding when a run has actually ended in defeat. This service is ready for that signal the moment
## it exists; `tools/salvage_check.gd` proves the banking math by emitting it synthetically, the same
## "unreachable but correct" shape F-139/F-166 already established for this kind of gap.

const EVENT_BUS := preload("res://core/events/event_bus.gd")
const SALVAGE_SAVE := preload("res://core/save/salvage_save.gd")

## DESIGN.md §5.2: "the reward curve for pushing deeper must be superlinear (Cycle 9 worth much more
## than 3x Cycle 3), or nobody ever gambles." `CYCLE_EXPONENT > 1` is what makes it superlinear;
## `CYCLE_BASE` just scales the whole curve to a number that feels worth banking. Cycle 3 -> 58,
## Cycle 9 -> 336 (~5.8x for 3x the Cycle, comfortably clearing the "much more than 3x" bar).
## Placeholder-tuned, same status as every other Cycle-facing constant in this codebase
## (`CycleService.SPREAD_ESCALATION_PER_CYCLE`, `ExtractionShip.REPAIR_COSTS`) — nothing here has
## been through a real playtest (Q6: "does anyone ever actually extract").
const CYCLE_BASE: int = 10
const CYCLE_EXPONENT: float = 1.6

## DESIGN.md §5.2: "dying instead banks a fraction of what you'd earned." Applied to the WHOLE
## payout (Cycle curve + milestone bonus), matching that sentence literally rather than only the
## Cycle half — a milestone earned this run (a Wellspring capped, say) is real progress made before
## the wipe, not something death should zero out differently than the Cycle number is. Placeholder,
## same unplaytested status as the curve above.
const DEATH_BANK_FRACTION: float = 0.5

## DESIGN.md §4.6's secondary scaling factor lists "Wellsprings capped, bosses killed, tiers
## reached." Only the first is trackable today: `EventBus.wellspring_capped` already exists and
## fires once per cap. No boss enemy concept exists anywhere in the codebase yet, and no event marks
## a crafting tier as "reached" this run (`StationDef.tier` exists but nothing announces reaching
## one) — both are out of scope for a T2/est-3 task that would otherwise be building content-family
## detection work two other systems haven't shipped. `MILESTONE_WEIGHTS`-shaped growth (one more
## `EventBus` subscription and one more counter, same pattern as `_wellsprings_capped_this_run`) is
## how a future task adds either without touching the reward formula itself.
const WELLSPRING_CAP_BONUS: int = 20

var _total_salvage_cache: int = 0
var _wellsprings_capped_this_run: int = 0
## Override for `tools/salvage_check.gd` only — production code never sets this, so it always reads
## `SalvageSave.SAVE_PATH` and a check run never touches a real player's save file.
var save_path: String = SALVAGE_SAVE.SAVE_PATH


func _ready() -> void:
	_total_salvage_cache = int(SALVAGE_SAVE.load_data(save_path).get(&"total_salvage", 0))
	EVENT_BUS.subscribe_run_extracted(_on_run_extracted)
	EVENT_BUS.subscribe_run_wiped(_on_run_wiped)
	EVENT_BUS.subscribe_wellspring_capped(_on_wellspring_capped)
	var game_state: Node = get_node_or_null(^"/root/GameState")
	if game_state != null:
		game_state.connect(&"seed_ready", _on_seed_ready)


func _exit_tree() -> void:
	EVENT_BUS.unsubscribe_run_extracted(_on_run_extracted)
	EVENT_BUS.unsubscribe_run_wiped(_on_run_wiped)
	EVENT_BUS.unsubscribe_wellspring_capped(_on_wellspring_capped)


## This peer's own lifetime Salvage balance.
func total_salvage() -> int:
	return _total_salvage_cache


## Task 6.9's spend seam — the inverse of `_bank()`, same shape: refuse the whole thing rather than
## partially apply it. Returns false, with NOTHING changed (memory or disk), if `amount` is not
## positive, persistence is disabled (D-107's guard — a `--script` check that forgot to override
## `save_path` must not spend into a real player's save), or the balance is short. `UnlockService`
## is the one caller today; any future Salvage sink reuses this rather than writing `total_salvage`
## itself, so there is exactly one place a negative balance could ever originate.
func spend_salvage(amount: int) -> bool:
	if amount <= 0:
		return false
	if not _persistence_enabled():
		return false
	var data: Dictionary = SALVAGE_SAVE.load_data(save_path)
	var current: int = int(data.get(&"total_salvage", 0))
	if amount > current:
		return false
	_total_salvage_cache = current - amount
	data[&"total_salvage"] = _total_salvage_cache
	SALVAGE_SAVE.save_data(data, save_path)
	return true


## How many Wellsprings THIS peer has seen capped since the current run began (`GameState.seed_ready`
## resets the count). Exposed for `tools/salvage_check.gd` and for a future HUD/summary read, not
## consumed internally beyond `_milestone_bonus()`.
func wellsprings_capped_this_run() -> int:
	return _wellsprings_capped_this_run


## The Salvage a run ending at `cycle` with the milestones banked so far would earn, before any
## death fraction is applied. Exposed so `tools/salvage_check.gd` can assert the curve directly
## rather than reverse-engineering it from a banked total.
func reward_for_cycle(cycle: int) -> int:
	return int(round(CYCLE_BASE * pow(float(maxi(cycle, 1)), CYCLE_EXPONENT))) + _milestone_bonus()


func _milestone_bonus() -> int:
	return _wellsprings_capped_this_run * WELLSPRING_CAP_BONUS


func _on_run_extracted(cycle: int, _world_position: Vector3) -> void:
	_bank(reward_for_cycle(cycle), cycle, true)


func _on_run_wiped(cycle: int, _world_position: Vector3) -> void:
	_bank(int(round(reward_for_cycle(cycle) * DEATH_BANK_FRACTION)), cycle, false)


func _on_wellspring_capped(_wellspring_name: StringName, _world_position: Vector3) -> void:
	_wellsprings_capped_this_run += 1


## F-273: `GameState.seed_ready` is a RUN boundary on every peer, host and client alike — it fires
## at session start, at every restart (F-258/D-161 made a restart draw a fresh seed), and when a
## client adopts the host's replicated seed. Read that signal's declaration in `core/game_state.gd`
## for the contract in full; the half that matters here is that it can fire MORE THAN ONCE for one
## boundary (a restart emits twice on the host), so this handler is a plain zeroing reset and must
## stay one. It is still the closest thing this codebase has to "a run has begun" reaching every
## peer, which is why this run's milestone tally resets on it.
func _on_seed_ready(_value: int) -> void:
	_wellsprings_capped_this_run = 0


func _bank(earned: int, cycle: int, extracted: bool) -> void:
	if not _persistence_enabled():
		return
	var data: Dictionary = SALVAGE_SAVE.load_data(save_path)
	_total_salvage_cache = int(data.get(&"total_salvage", 0)) + earned
	data[&"total_salvage"] = _total_salvage_cache
	SALVAGE_SAVE.save_data(data, save_path)
	_wellsprings_capped_this_run = 0
	EVENT_BUS.emit_salvage_banked(earned, _total_salvage_cache, cycle, extracted)


## Guards every disk write against being triggered by an unrelated check's own test traffic.
## `EventBus` is process-global, so ANY `--script` harness that fires a real `run_extracted` /
## `run_wiped` / `wellspring_capped` event for ITS OWN system's test reaches this autoload exactly
## like the shipped game would — confirmed the hard way while building this: running
## `tools/extraction_check.gd` once (its departure-hold tests legitimately complete two real
## extractions) banked 116 Salvage into this developer's REAL `user://salvage.json` before this
## guard existed. D-107 records the fix: a `--script` harness never loads `project.godot`'s
## `run/main_scene` (`current_scene` stays null for the whole run), which the real game always does
## — the one signal available to every future check for free, with no per-check opt-out to
## remember. `tools/salvage_check.gd` opts back in explicitly by overriding `save_path` away from
## the real one, which both routes its own writes to a throwaway file AND proves persistence works.
func _persistence_enabled() -> bool:
	return save_path != SALVAGE_SAVE.SAVE_PATH or get_tree().current_scene != null
