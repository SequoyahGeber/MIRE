extends Node

## CycleModifierService — autoload. Task 6.2 (docs/DESIGN.md §5.1 item 2): the deck/draw/stacking
## framework `CycleService` (task 6.1) deferred — see that file's header and D-100. Draws exactly one
## `CycleModifierDef` the instant `EventBus.emit_cycle_advanced()` fires, respecting Cycle-weighted
## eligibility and incompatibility tags, and stacks it permanently for the rest of the run
## (DESIGN.md §5.1: "modifiers stack across a run").
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, "Day/night, wave director, Cycle state, active
## modifiers" row): HOST. Only the host draws; every peer reads the resulting stack back through
## `WorldDeltaLog` — the identical no-new-RPC reuse D-100 established for `CycleService` itself, for
## the identical reason: a real RPC pair needs a `PROTOCOL_VERSION` bump in `core/net/net_version.gd`
## + `tools/handshake_check.gd`, and both were held all session by lane slate17's task 3.7 claim.
##
## Content loads through `autoload/registry.gd` first — D-006's usual boot loader for every content
## family, and `CycleModifierDef` is now one `_load_dir()` line there alongside every sibling Def
## (RuleDef, HookDef, ...). `_load_defs()` below falls back to its own direct disk scan only when
## Registry is unavailable — the identical "seatbelt, not a second front door" split
## `RuleService._load_defs()`/`_load_defs_from_disk()` already establishes, for a hand-instantiated
## harness that never registered Registry under `/root`.
##
## Every def is stored and passed around as `Resource`, never as the bare `CycleModifierDef`
## identifier, and read back via `.get(&"field")` / `.call("method")` rather than dot access — F-016:
## a brand-new `class_name` (this task's own) is not bare-resolvable in a fresh headless clone.
## `RuleService`/`RuleDef` is the established worked example of this same split.
##
## The draw seeds from `(GameState.run_seed, cycle)` rather than boot-time entropy — F-220, the same
## bug D-041/F-210 fixed in `Chest` and F-219/D-136 fixed in `RewardService`: two runs sharing a seed
## must draw the same modifier(s) in the same order. `cycle` is already the stable per-draw id
## `host_draw_modifier()` receives as a parameter — no counter needed the way `RewardService` had to
## mint one (D-136), since a Cycle only ever advances forward and each cycle draws at most once. The
## roll still happens exactly once, host-only, and no other peer ever recomputes it — this is about
## run-to-run reproducibility, not cross-peer agreement, same distinction `Chest`'s own header draws.
##
## F-254: `_announce()` below only ever runs host-side (it is reachable only through
## `host_draw_modifier()`, which returns early on `_owns_modifiers()`), so a real connected client's
## own `EventBus.subscribe_cycle_modifier_drawn()` listeners never fired at all — the exact shape
## F-250 fixed for `CycleService`. `_on_world_delta_applied()` re-derives the identical emit on a
## client from the same `WorldDeltaLog` records the host's `_announce()` writes, so every peer's bus
## sees a real, live `cycle_modifier_drawn` without a new RPC (D-099/D-100's no-new-RPC reuse).
## Unlike `CycleService`'s single-scalar record, a draw here is TWO records — the slot's `def_id` and
## (new, F-254) the Cycle it was drawn on, since `emit_cycle_modifier_drawn(def_id, cycle)` needs
## both and nothing stored `cycle` before. Those cross the wire as separate `net_delta_applied` RPCs,
## so the handler assumes NOTHING about arrival order: any landing re-scans the whole slot range and
## emits for whatever changed. See `_on_world_delta_applied()`.

const EVENT_BUS := preload("res://core/events/event_bus.gd")
const CYCLE_MODIFIER_DEF := preload("res://systems/cycle/cycle_modifier_def.gd")

const CYCLE_MODIFIERS_PATH: String = "res://content/cycle_modifiers"

## `WorldDeltaLog` addressing for the drawn-modifier stack. Same fixed pseudo-chunk `CycleService`
## uses — Cycle Modifiers have no position either — under a distinct `kind` so the two logs never
## collide. One key per draw (`"0"`, `"1"`, ...) holding that slot's modifier id, plus a `COUNT_KEY`
## so a late joiner (or a client re-deriving the stack) knows how many slots to read.
const GLOBAL_CHUNK: Vector2i = Vector2i.ZERO
const KIND: StringName = &"cycle_modifier"
const COUNT_KEY: String = "count"
## F-254: the Cycle a slot was drawn on, recorded under its OWN key (`"0:cycle"`, `"1:cycle"`, ...)
## beside that slot's existing `def_id` key. Deliberately additive rather than widening the `str(slot)`
## value to `"%s:%d" % [def_id, cycle]`: that would change the parsing contract of every existing
## reader of `_replicated_active_ids()`, whereas a new key is invisible to a loop that only ever asks
## for `str(index)` and `COUNT_KEY`. This is option (a) of the two the finding named; see D-158.
const CYCLE_KEY_SUFFIX: String = ":cycle"

## id -> CycleModifierDef, stored as Resource (F-016, see header).
var _defs: Dictionary = {}
## Host's own authoritative draw order. A client never writes this — it reads the stack back through
## `active_modifier_ids()` -> `_replicated_active_ids()` instead.
var _active_ids: Array[StringName] = []
## F-245: `drought`'s own text is the one modifier here whose effect is not simply "as long as it's
## drawn" — content/cycle_modifiers/drought.tres reads "yield half until the NEXT Wellspring cap".
## `has_modifier()` still reflects the permanent draw stack (DESIGN.md §5.1: a modifier never leaves
## it), so this is tracked separately: reset to false the instant `drought` is drawn
## (`host_draw_modifier()`), flipped true by the next `wellspring_capped` this file sees regardless of
## which Wellspring capped. `drought_active()` below is the one place that combines the two.
var _drought_cleared: bool = false
## F-254, client-side only: slot -> the `"def_id|cycle"` stamp last emitted for that slot, so the two
## `delta_applied` landings a single draw produces (`str(slot)` and its `CYCLE_KEY_SUFFIX` sibling)
## emit exactly once between them regardless of arrival order. Cleared on `run_restarted` because a
## restart re-uses slot 0 and legitimately redraws on the same Cycle 1, which the stamp alone could
## not tell from a duplicate landing. F-254 justified that clear with "the run seed being unchanged",
## citing D-149's scope cut; F-258/D-161 lifted the cut and a restart now draws a FRESH seed, so a
## redraw is only *likely* to repeat rather than guaranteed to. The clear is still required either
## way — slot 0 is reused whatever it holds — and `tools/cycle_modifier_net_check.gd`'s phase 2
## still passes, so only the reason recorded here needed correcting.
var _announced_draws: Dictionary = {}
var _rng := RandomNumberGenerator.new()
var _transport_node: Node


func _ready() -> void:
	_load_defs()
	# F-254: a client's own EventBus never gets `_announce()`'s emit directly (host-only, see that
	# method's header) — this re-derives it locally from the log records the host's `_announce()` also
	# writes, the moment they actually land. Same seam `CycleService._ready()` uses for `cycle_advanced`.
	var world_delta_log: Node = get_node_or_null(^"/root/WorldDeltaLog")
	if world_delta_log != null and world_delta_log.has_signal(&"delta_applied"):
		world_delta_log.connect(&"delta_applied", _on_world_delta_applied)
	EVENT_BUS.subscribe_cycle_advanced(_on_cycle_advanced)
	EVENT_BUS.subscribe_run_restarted(_on_run_restarted)
	EVENT_BUS.subscribe_wellspring_capped(_on_wellspring_capped)
	_register_commands()


func _exit_tree() -> void:
	EVENT_BUS.unsubscribe_cycle_advanced(_on_cycle_advanced)
	EVENT_BUS.unsubscribe_run_restarted(_on_run_restarted)
	EVENT_BUS.unsubscribe_wellspring_capped(_on_wellspring_capped)


func _on_wellspring_capped(_wellspring_name: StringName, _world_position: Vector3) -> void:
	_drought_cleared = true


func _on_cycle_advanced(cycle: int) -> void:
	host_draw_modifier(cycle)


## F-243: empties the stacked deck for a new run and overwrites `WorldDeltaLog`'s `COUNT_KEY` to 0 so
## a client re-reading `active_modifier_ids()` before the next draw sees an empty stack rather than
## last run's. Host-only (`_owns_modifiers()`), run BEFORE `CycleService.host_restart_run()`'s own
## `_announce()` re-fires `cycle_advanced(1)` — `EVENT_BUS.emit_run_restarted()` reaches every
## in-process subscriber synchronously, so this always clears before that later `cycle_advanced(1)`
## triggers `_on_cycle_advanced()`'s own draw check against the now-empty deck.
func _on_run_restarted() -> void:
	# F-254: above the host gate on purpose — a client reaches this through `CycleService.
	# _on_world_delta_applied()`'s re-derived `run_restarted`, and its slot stamps must reset there too
	# or the next run's slot-0 draw is silently swallowed as a duplicate. See `_announced_draws`.
	_announced_draws.clear()
	if not _owns_modifiers():
		return
	_active_ids.clear()
	_drought_cleared = false
	var world_delta_log: Node = get_node_or_null(^"/root/WorldDeltaLog")
	if world_delta_log != null:
		world_delta_log.call("host_record", GLOBAL_CHUNK, KIND, COUNT_KEY, 0)


## The stacked modifiers drawn so far this run, in draw order, readable on any peer — host's own
## array, or a client's `WorldDeltaLog`-replicated reconstruction (same split `CycleService.
## current_cycle()` uses).
func active_modifier_ids() -> Array[StringName]:
	if _owns_modifiers():
		return _active_ids.duplicate()
	return _replicated_active_ids()


func has_modifier(id: StringName) -> bool:
	return active_modifier_ids().has(id)


## F-245: `drought`'s own effect window — see `_drought_cleared`'s header note. `Harvestable` reads
## this instead of `has_modifier(&"drought")` directly.
func drought_active() -> bool:
	return has_modifier(&"drought") and not _drought_cleared


func def_for(id: StringName) -> Resource:
	return _defs.get(id)


## Draws and stacks exactly one eligible modifier for `cycle`, or does nothing (no crash, no
## duplicate) when the deck has nothing left to offer — same "legitimate empty state" convention
## `WaveSpawner.host_unlock_next_enemy()` already uses for the identical reason. Public and
## host-guarded, mirroring `CycleService.host_advance_cycle()`, so both the real `cycle_advanced`
## path and a console command can drive the identical code. Returns the drawn id, or `&""` if
## nothing was drawn.
func host_draw_modifier(cycle: int) -> StringName:
	if not _owns_modifiers():
		return &""
	var eligible: Array[Resource] = _eligible_defs(cycle)
	if eligible.is_empty():
		MireLog.info(&"world", "Cycle %d: no eligible Cycle Modifier to draw" % cycle)
		return &""
	_rng.seed = _seed_for_run(_run_seed(), str(cycle))
	var chosen: Resource = _weighted_pick(eligible, cycle)
	var chosen_id: StringName = StringName(chosen.get(&"id"))
	_active_ids.append(chosen_id)
	if chosen_id == &"drought":
		_drought_cleared = false
	_announce(chosen, cycle)
	return chosen_id


## Every def not already drawn (a modifier draws at most once per run — the "deck" depletes), whose
## `weight_at(cycle)` is positive, and that the incompatibility tags (+ explicit id exclusions) allow
## alongside whatever is already stacked.
func _eligible_defs(cycle: int) -> Array[Resource]:
	var result: Array[Resource] = []
	var active_tags: Dictionary = _tag_union(_active_ids, false)
	var blocked_tags: Dictionary = _tag_union(_active_ids, true)
	for def: Resource in _defs.values():
		var def_id: StringName = StringName(def.get(&"id"))
		if _active_ids.has(def_id):
			continue
		if float(def.call("weight_at", cycle)) <= 0.0:
			continue
		if _has_any(def.get(&"incompatible_with") as Array, _active_ids):
			continue
		if _dict_has_any(active_tags, def.get(&"incompatible_tags") as Array):
			continue
		if _dict_has_any(blocked_tags, def.get(&"tags") as Array):
			continue
		result.append(def)
	return result


## Union of `tags` (when `incompatible` is false) or `incompatible_tags` (when true) across every
## already-active modifier. Building both sets once per draw, rather than re-scanning `_active_ids`
## per candidate, keeps the eligibility check symmetric without being quadratic in deck size.
func _tag_union(ids: Array[StringName], incompatible: bool) -> Dictionary:
	var union: Dictionary = {}
	for id: StringName in ids:
		var def: Resource = _defs.get(id)
		if def == null:
			continue
		var field: StringName = &"incompatible_tags" if incompatible else &"tags"
		for tag: StringName in (def.get(field) as Array):
			union[tag] = true
	return union


func _dict_has_any(haystack: Dictionary, needles: Array) -> bool:
	for needle: Variant in needles:
		if haystack.has(needle):
			return true
	return false


func _has_any(needles: Array, haystack: Array[StringName]) -> bool:
	for needle: Variant in needles:
		if haystack.has(needle):
			return true
	return false


## Weighted random pick over `candidates`, each weighted by `weight_at(cycle)`. `_rng` is seeded by
## the caller (`host_draw_modifier()`) from `(run_seed, cycle)` immediately before this runs — see
## the header note.
func _weighted_pick(candidates: Array[Resource], cycle: int) -> Resource:
	var total_weight: float = 0.0
	for def: Resource in candidates:
		total_weight += float(def.call("weight_at", cycle))
	var roll: float = _rng.randf() * total_weight
	var cursor: float = 0.0
	for def: Resource in candidates:
		cursor += float(def.call("weight_at", cycle))
		if roll < cursor:
			return def
	return candidates[candidates.size() - 1]


## Host-only. Appends this draw's slot to `WorldDeltaLog` (broadcasts to every connected peer, folds
## into a late joiner's snapshot) and fires `EventBus.emit_cycle_modifier_drawn()` for in-process
## listeners — same two-channel announce `CycleService._announce()` uses.
func _announce(def: Resource, cycle: int) -> void:
	var def_id: StringName = StringName(def.get(&"id"))
	var world_delta_log: Node = get_node_or_null(^"/root/WorldDeltaLog")
	if world_delta_log != null:
		var slot: int = _active_ids.size() - 1
		# F-254: both halves of the draw BEFORE `COUNT_KEY`, and this order is load-bearing on the
		# client, not cosmetic. `_on_world_delta_applied()` only announces slots below the recorded
		# count, so bumping the count last is what publishes a draw — writing it first would expose a
		# slot whose `def_id`/`cycle` are still the previous run's (see that method's own note).
		world_delta_log.call("host_record", GLOBAL_CHUNK, KIND, _cycle_key(slot), cycle)
		world_delta_log.call("host_record", GLOBAL_CHUNK, KIND, str(slot), String(def_id))
		world_delta_log.call("host_record", GLOBAL_CHUNK, KIND, COUNT_KEY, _active_ids.size())
	EVENT_BUS.emit_cycle_modifier_drawn(def_id, cycle)
	MireLog.info(&"world", "Cycle %d Modifier drawn: %s — %s" % [
		cycle, String(def.get(&"display_name")), String(def.get(&"description"))
	])


## F-254: the client half of the two-channel announce. `_announce()` above only ever runs host-side,
## so without this a client's own `EventBus.cycle_modifier_drawn` never fired — the identical bug
## F-250 fixed in `CycleService`, and the reason this file's `active_modifier_ids()` getter looking
## correct was never enough (a getter that reads right does not make a SIGNAL fire).
##
## Guarded on `_owns_modifiers()` so the host — whose own `host_record()` calls also run through
## `WorldDeltaLog._apply()` and fire this same local signal — never double-emits; it already emitted
## directly in `_announce()`.
##
## The ordering hazard the finding named, handled rather than assumed away. One draw writes THREE
## records (`slot:cycle`, `slot`, then `COUNT_KEY`), which reach a client as three separate
## `net_delta_applied` RPCs. Rather than trust an arrival order, ANY landing under this `kind`
## re-scans every slot `COUNT_KEY` currently covers and emits for each one whose `(def_id, cycle)`
## pair has changed since it was last announced here. That is idempotent, so the three landings of a
## single draw produce exactly one emit between them, in any order.
##
## Scanning against `COUNT_KEY` rather than reacting to the touched key is what makes a RESTART safe,
## and is the whole reason this is not the obvious per-key handler. `WorldDeltaLog` is
## latest-value-wins and never deletes: after `_on_run_restarted()` writes `COUNT_KEY = 0`, slot 0's
## `def_id` from the PREVIOUS run is still sitting in the log. A handler that emitted the moment the
## new run's `slot:cycle` record landed would pair the new Cycle with last run's stale modifier id.
## Gating on `slot < count` means nothing is announced until the new draw's own `COUNT_KEY` write —
## which the host issues last, after both halves — brings the slot back into range.
##
## A late joiner never reaches here for draws that predate its join — `net_world_snapshot` replaces
## `_state` wholesale without going through `_apply()`, so it fires no `delta_applied` at all. That is
## deliberate and matches `CycleService`: a joiner reads the caught-up stack straight out of
## `active_modifier_ids()` instead of replaying a burst of historical draw signals it missed.
func _on_world_delta_applied(chunk: Vector2i, kind: StringName, _key: String, _value: Variant) -> void:
	if _owns_modifiers() or chunk != GLOBAL_CHUNK or kind != KIND:
		return
	var world_delta_log: Node = get_node_or_null(^"/root/WorldDeltaLog")
	if world_delta_log == null:
		return
	var count: int = int(world_delta_log.call("latest", GLOBAL_CHUNK, KIND, COUNT_KEY, 0))
	for slot: int in range(count):
		var def_id := StringName(String(
			world_delta_log.call("latest", GLOBAL_CHUNK, KIND, str(slot), "")
		))
		var cycle_value: Variant = world_delta_log.call(
			"latest", GLOBAL_CHUNK, KIND, _cycle_key(slot), null
		)
		if def_id == &"" or cycle_value == null:
			continue
		var stamp: String = "%s|%d" % [def_id, int(cycle_value)]
		if String(_announced_draws.get(slot, "")) == stamp:
			continue
		_announced_draws[slot] = stamp
		EVENT_BUS.emit_cycle_modifier_drawn(def_id, int(cycle_value))


func _cycle_key(slot: int) -> String:
	return str(slot) + CYCLE_KEY_SUFFIX


func _replicated_active_ids() -> Array[StringName]:
	var world_delta_log: Node = get_node_or_null(^"/root/WorldDeltaLog")
	var result: Array[StringName] = []
	if world_delta_log == null:
		return result
	var count: int = int(world_delta_log.call("latest", GLOBAL_CHUNK, KIND, COUNT_KEY, 0))
	for index: int in range(count):
		var value: Variant = world_delta_log.call("latest", GLOBAL_CHUNK, KIND, str(index), "")
		var id := StringName(String(value))
		if id != &"":
			result.append(id)
	return result


func _owns_modifiers() -> bool:
	var transport: Node = _transport()
	if transport == null:
		return true
	if bool(transport.call("is_host")):
		return true
	return not bool(transport.call("is_active")) and not bool(transport.call("is_connecting"))


func _transport() -> Node:
	if _transport_node == null or not is_instance_valid(_transport_node):
		_transport_node = get_node_or_null(^"/root/NetTransport")
	return _transport_node


## Host-only caller (F-220, same contract as `Chest._run_seed()`/`RewardService._run_seed()`).
## GameState is a project-wide autoload, present in every scene including a headless SceneTree check,
## so this never needs the null guard the transport lookups above carry. `ensure_seed()` lazily draws
## one from real entropy if nothing has drawn it yet (offline/host-of-one boot order) and is a no-op
## once a seed exists.
func _run_seed() -> int:
	var game_state: Node = get_node_or_null(^"/root/GameState")
	if game_state == null:
		return 0
	return int(game_state.call("ensure_seed"))


## Salt distinguishes this file's seed derivation from every other file mixing the same run_seed
## (`systems/loot/chest.gd`'s `0xC4E57`, `autoload/reward_service.gd`'s `0x9E3779B9`, `world/gen/
## poi_map.gd`'s `0x9017A11`, `world/gen/resource_scatter.gd`'s `0x5CA77E5`) — same "own salt per
## file" convention those establish. Integer multiply/xor only, never Godot's `hash()`, for the
## identical cross-platform-stability reason `chest.gd` documents on its own copy of this constant.
const _SEED_SALT: int = 0xB16B00B5


## Copy of `Chest._seed_for_run()`/`RewardService._seed_for_run()` — see `chest.gd`'s header for why
## this is duplicated per file rather than shared. [param draw_id] is `str(cycle)`, the stable
## per-draw id `host_draw_modifier()` already receives as a parameter.
func _seed_for_run(run_seed: int, draw_id: String) -> int:
	const PRIME: int = 1000003
	var id_hash: int = 0x1000193
	for byte: int in draw_id.to_utf8_buffer():
		id_hash = (id_hash ^ byte) * 16777619
	var h: int = run_seed ^ _SEED_SALT
	h = h * PRIME + id_hash
	return h


## Registry first (the real content front door); the direct disk scan below only runs when Registry
## is not registered under `/root` — same split `RuleService._load_defs()` uses.
func _load_defs() -> void:
	var registry: Node = get_node_or_null(^"/root/Registry")
	if registry != null and registry.has_method(&"cycle_modifier_defs"):
		var from_registry: Dictionary = registry.call("cycle_modifier_defs")
		for key: Variant in from_registry:
			_defs[StringName(key)] = from_registry[key]
		return
	_load_defs_from_disk()


## The seatbelt path (`RuleService._load_defs_from_disk()`'s own naming) — deliberately quieter than
## `Registry._load_dir`'s loader; it is not trying to be a second content front door, only to keep a
## hand-instantiated harness from seeing zero modifiers and concluding the feature is broken. Same
## shape as `Registry._load_dir`: scan `.tres` files (including exported builds' `.tres.remap`,
## F-121), reject anything that is not a `CycleModifierDef`, reject a missing id, reject a duplicate
## id (keep first), reject anything `validation_errors()` flags.
func _load_defs_from_disk() -> void:
	var dir: DirAccess = DirAccess.open(CYCLE_MODIFIERS_PATH)
	if dir == null:
		MireLog.error(&"content", "cannot open %s (%s)" % [
			CYCLE_MODIFIERS_PATH, DirAccess.get_open_error()
		])
		return
	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	while file_name != "":
		if not dir.current_is_dir():
			var res_name: String = file_name.trim_suffix(".remap")
			if res_name.ends_with(".tres"):
				_load_one(CYCLE_MODIFIERS_PATH.path_join(res_name))
		file_name = dir.get_next()
	dir.list_dir_end()


func _load_one(path: String) -> void:
	var res: Resource = load(path)
	if res == null or res.get_script() != CYCLE_MODIFIER_DEF:
		MireLog.error(&"content", "%s does not contain a CycleModifierDef, skipped" % path)
		return
	var id: StringName = StringName(res.get(&"id"))
	if id == &"":
		MireLog.error(&"content", "%s has no id set, skipped" % path)
		return
	if _defs.has(id):
		MireLog.error(&"content", "duplicate cycle modifier id '%s' at %s, keeping first" % [id, path])
		return
	var errors: PackedStringArray = res.call("validation_errors")
	if not errors.is_empty():
		MireLog.error(&"content", "%s is invalid (%s), skipped" % [path, "; ".join(errors)])
		return
	_defs[id] = res


# ── Commands (docs/COMMANDS.md §7 — task 3.16's convention) ─────────────────────────────────────


func _register_commands() -> void:
	var command_service: Node = get_node_or_null(^"/root/CommandService")
	if command_service == null:
		return
	command_service.call("register_spec", &"modifiers", {
		"scope": &"local",
		"args": [],
		"handler": _cmd_modifiers,
		"help": "modifiers — list Cycle Modifiers stacked so far this run",
	})


func _cmd_modifiers(_ctx: Dictionary, _args: Dictionary) -> Dictionary:
	var ids: Array[StringName] = active_modifier_ids()
	if ids.is_empty():
		return {"ok": true, "message": "no Cycle Modifiers active yet", "data": {"active": []}}
	var lines: PackedStringArray = []
	for id: StringName in ids:
		var def: Resource = _defs.get(id)
		lines.append(String(def.get(&"display_name")) if def != null else String(id))
	return {"ok": true, "message": ", ".join(lines), "data": {"active": ids}}
