extends Node

## RunRecord — MENU-7: watches a run end and writes down what happened (docs/MENU.md §6.2).
## Register as autoload `RunRecord` → res://autoload/run_record.gd, AFTER `SalvageService` (it reads
## the banked figure that service produces) and after `CycleModifierService`.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2): none of its own — this is per-player account state,
## the same row `SalvageSave` occupies. It writes down what THIS peer observed about the run that
## just ended. Every input it reads is already replicated by the service that owns it
## (`EventBus.run_extracted` / `run_wiped` fire identically on every peer — see `DefeatService` and
## `ExtractionService`), so two peers recording the same run agree without this file arbitrating
## anything.
##
## ## What it is for
##
## DESIGN.md §1: "The brag is a number: *we made it to Cycle 9*." Between runs that number has to
## live somewhere, or the game forgets what you did the moment you leave the summary screen. This is
## the somewhere: the title screen's last-expedition card and the run summary both read it.
##
## ## The ordering problem, and how it is avoided
##
## A run ending produces TWO events, not one: `run_extracted`/`run_wiped` (what happened) and
## `salvage_banked` (what it was worth). Which arrives first depends on autoload order, and
## `SalvageService` is itself a subscriber to the first pair. Rather than depend on that order, this
## file accumulates into `_pending` on whichever arrives first and writes on the second — the same
## "react to the SECOND event and be idempotent" shape D-174 already settled for this codebase.
## Writing twice for one run boundary is harmless anyway: the write is a whole-file overwrite of
## re-derived values, never an increment.

const RunRecordSave := preload("res://core/save/run_record_save.gd")
const EVENT_BUS := preload("res://core/events/event_bus.gd")

## Per-ending flavour. Warm, dumb, never lore (DESIGN.md §6 — "Tone: silly. Do not write lore.").
## One is picked per run from the seed so the same run always reads the same way, rather than
## re-rolling every time the title screen refreshes.
const CAUSE_LINES: Dictionary = {
	&"extracted": [
		"sailed home heavy",
		"left while the leaving was good",
		"the boat held. barely.",
	],
	&"wiped": [
		"the bog ate well tonight",
		"swallowed, with the good pickaxe",
		"nobody left standing to say what happened",
	],
	&"consumed": [
		"there was no more island",
		"the Mire finished what it started",
		"ran out of ground before you ran out of nerve",
	],
}

## Overridable so a check never writes a real player's record (the same `save_path` seam
## `SalvageService` and `UnlockService` use for D-107's guard).
var save_path: String = RunRecordSave.SAVE_PATH

var _pending: Dictionary = {}


func _ready() -> void:
	EVENT_BUS.subscribe_run_extracted(_on_run_extracted)
	EVENT_BUS.subscribe_run_wiped(_on_run_wiped)
	EVENT_BUS.subscribe_salvage_banked(_on_salvage_banked)


# ── Public API ────────────────────────────────────────────────────────────────────────────────────


## The last recorded run, or a default record with `has_run` false. Always valid.
func last_run() -> Dictionary:
	return RunRecordSave.load_data(save_path)


func has_last_run() -> bool:
	return bool(last_run().get("has_run", false))


## Exposed so the summary screen can show the ending it is presenting without waiting for the disk
## write, and so a check can drive the whole shape without firing four events.
func record(ending: StringName, cycle: int, salvage_banked: int) -> Dictionary:
	var data: Dictionary = {
		"has_run": true,
		"cycle": maxi(cycle, 0),
		"ending": String(ending),
		"cause_line": cause_line_for(ending, cycle),
		"salvage_banked": maxi(salvage_banked, 0),
		"modifiers": _modifiers_drawn(),
		"seed": _run_seed(),
	}
	RunRecordSave.save_data(data, save_path)
	return data


## Deterministic per (ending, cycle): the same run always reads the same way, so a player who looks
## at the title card twice does not see their expedition described differently the second time.
static func cause_line_for(ending: StringName, cycle: int) -> String:
	var pool: Variant = CAUSE_LINES.get(ending, null)
	if not (pool is Array) or (pool as Array).is_empty():
		return ""
	var lines: Array = pool
	return String(lines[absi(cycle) % lines.size()])


# ── Events ────────────────────────────────────────────────────────────────────────────────────────


func _on_run_extracted(cycle: int, _world_position: Vector3) -> void:
	_pending["ending"] = &"extracted"
	_pending["cycle"] = cycle
	_flush_if_ready()


## `DefeatService` distinguishes a team wipe from the island being consumed by its own cause enum,
## but `EventBus.run_wiped` does not carry it. Recorded as a wipe here; the consumed ending is worth
## telling apart on the summary and is filed as follow-up work rather than guessed at.
func _on_run_wiped(cycle: int, _world_position: Vector3) -> void:
	_pending["ending"] = &"wiped"
	_pending["cycle"] = cycle
	_flush_if_ready()


func _on_salvage_banked(earned: int, _total: int, cycle: int, extracted: bool) -> void:
	_pending["salvage_banked"] = earned
	if not _pending.has("ending"):
		# Banking can legitimately arrive first. `extracted` alone says which ending it was, so the
		# record is complete either way and neither event has to wait for the other.
		_pending["ending"] = &"extracted" if extracted else &"wiped"
		_pending["cycle"] = cycle
	_flush_if_ready()


## Writes once both halves are in. Idempotent: a second call for the same boundary re-derives and
## rewrites the same values rather than accumulating (D-174 / D-177's rule applied here).
func _flush_if_ready() -> void:
	if not (_pending.has("ending") and _pending.has("salvage_banked")):
		return
	record(
		StringName(_pending["ending"]),
		int(_pending.get("cycle", 0)),
		int(_pending["salvage_banked"]),
	)
	_pending.clear()


func _modifiers_drawn() -> Array:
	var service: Node = get_node_or_null(^"/root/CycleModifierService")
	if service == null or not service.has_method("active_modifier_ids"):
		return []
	var ids: Array = []
	for id: StringName in service.call("active_modifier_ids"):
		ids.append(String(id))
	return ids


func _run_seed() -> int:
	var state: Node = get_node_or_null(^"/root/GameState")
	if state != null and bool(state.call("is_seed_ready")):
		return int(state.get("run_seed"))
	return 0
