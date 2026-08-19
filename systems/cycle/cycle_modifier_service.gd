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

## id -> CycleModifierDef, stored as Resource (F-016, see header).
var _defs: Dictionary = {}
## Host's own authoritative draw order. A client never writes this — it reads the stack back through
## `active_modifier_ids()` -> `_replicated_active_ids()` instead.
var _active_ids: Array[StringName] = []
var _rng := RandomNumberGenerator.new()
var _transport_node: Node


func _ready() -> void:
	_load_defs()
	EVENT_BUS.subscribe_cycle_advanced(_on_cycle_advanced)
	_register_commands()


func _on_cycle_advanced(cycle: int) -> void:
	host_draw_modifier(cycle)


## The stacked modifiers drawn so far this run, in draw order, readable on any peer — host's own
## array, or a client's `WorldDeltaLog`-replicated reconstruction (same split `CycleService.
## current_cycle()` uses).
func active_modifier_ids() -> Array[StringName]:
	if _owns_modifiers():
		return _active_ids.duplicate()
	return _replicated_active_ids()


func has_modifier(id: StringName) -> bool:
	return active_modifier_ids().has(id)


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
		world_delta_log.call("host_record", GLOBAL_CHUNK, KIND, str(slot), String(def_id))
		world_delta_log.call("host_record", GLOBAL_CHUNK, KIND, COUNT_KEY, _active_ids.size())
	EVENT_BUS.emit_cycle_modifier_drawn(def_id, cycle)
	MireLog.info(&"world", "Cycle %d Modifier drawn: %s — %s" % [
		cycle, String(def.get(&"display_name")), String(def.get(&"description"))
	])


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
