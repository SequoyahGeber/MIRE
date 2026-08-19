extends Node

## RuleService — autoload. The live value of every gamerule, and the only thing allowed to change
## one. docs/COMMANDS.md §4.2 is the spec; systems/rules/rule_def.gd is the authored half.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, "Day/night, wave director, Cycle state, active
## modifiers" row): **HOST**. Only the host sets a rule. Clients read a replicated copy and never
## write one, because a rule is a knob on the simulation and the simulation has one brain. Two RPCs
## carry that (protocol 17):
##
##   · `net_rule_snapshot` — rpc_id to ONE peer, the full id -> value map. Sent on join.
##   · `net_rule_changed`  — broadcast, one id and its new value.
##
## Both reliable: a dropped rule change leaves two machines simulating different games, which is the
## exact failure mode a gamerule is most likely to hide (nobody notices day length disagreeing until
## night falls on one screen and not the other).
##
## THE ONE SEAM: systems ASK this service, it never reaches into systems — the same direction
## PowerupService set in 3.3. An owner keeps its `@export` and reads:
##
##     day_length_seconds = RuleService.value(&"day_length_seconds", day_length_seconds)
##
## `value()` hands back the fallback unchanged when the rule does not exist, so boot order, a deleted
## .tres, or a harness that never loaded content can never brick a system (COMMANDS.md §4.3). That is
## also why the export stays: inspector tuning keeps working until a knob formally moves, and a knob
## that has moved still shows its live value in the inspector's units.
##
## PERSISTENCE: none, on purpose. A run is one sitting (D-010), so rules reset to their authored
## defaults every boot. A `content/functions/autoexec.mcmd` (COMMANDS.md §5.3, task 3.17) is how a
## dev keeps preferred rules across boots — that is a content file, not a save system.
##
## CROSS-AUTOLOAD BOUNDARY: same discipline as CommandService — everything crossing in or out is a
## plain float/StringName/Dictionary, and every caller reaches this service through
## `get_node_or_null(^"/root/RuleService")` + `.call()`, so a `--script` harness can hand-instantiate
## it under /root without the rest of project.godot's autoload list.

const LOG_CHANNEL: StringName = &"rules"

## Fallback content path, used only when Registry has no rule family to hand over — a harness that
## instantiated this service alone, or a boot where registry.gd loaded before content/rules/ existed.
## The Registry is still the front door for content (ARCHITECTURE.md §3.1); this is the seatbelt that
## keeps a missing front door from meaning "no rules at all, silently".
const RULES_PATH: String = "res://content/rules"
const RULE_DEF := preload("res://systems/rules/rule_def.gd")

## The magic value word that returns a rule to its authored default: `rule <id> reset`. Spelled out
## here rather than inline so the `rule` help text and the parser can never drift apart.
const RESET_WORD: String = "reset"

## rule id -> RuleDef. Boot-time only; content never changes mid-run.
var _defs: Dictionary[StringName, Resource] = {}
## rule id -> live value, host-authoritative. Every entry is already coerced by its own RuleDef, so
## a reader never has to clamp or round what it gets back.
var _values: Dictionary[StringName, float] = {}
var _transport_node: Node

## Fires wherever the change is known — on the host when it sets one, on every client when the
## broadcast lands. A system that caches a rule instead of reading it per frame listens to this.
signal rule_changed(id: StringName, value: float)


func _ready() -> void:
	_load_defs()
	_seed_defaults()

	var transport: Node = _transport()
	if transport != null and transport.has_signal(&"peer_joined"):
		transport.connect(&"peer_joined", _on_peer_joined)

	_register_commands()
	MireLog.info(LOG_CHANNEL, "%d rule(s) at defaults" % _values.size())


# ── Read seam ────────────────────────────────────────────────────────────────────────────────────


func has_rule(id: StringName) -> bool:
	return _values.has(id)


## The one read every system uses. `fallback` is the owner's own `@export`, returned untouched when
## no RuleDef with this id exists — see the export-fallback note in the header.
func value(id: StringName, fallback: float = 0.0) -> float:
	return _values.get(id, fallback)


func value_int(id: StringName, fallback: int = 0) -> int:
	return roundi(_values.get(id, float(fallback)))


func value_bool(id: StringName, fallback: bool = false) -> bool:
	return _values.get(id, 1.0 if fallback else 0.0) != 0.0


func def(id: StringName) -> Resource:
	return _defs.get(id)


## True when this rule holds something other than its authored default — i.e. somebody actually
## expressed an opinion. Stateless on purpose (it is derived from the value, not a separate flag), so
## a client computes the same answer from its replicated value and its own RuleDef, and `rule <id>
## reset` makes it false again without any bookkeeping.
##
## This exists for the one knob that already had a second, level-authored source of truth before it
## became a rule: DayNight's day_length_seconds is overwritten from the level's Atmosphere node. A
## rule sitting at its default must not silently outrank a level that authored 600s, but a rule
## someone deliberately set must outrank it — that is the whole point of typing the command. See
## D-085; every other first-wave knob has no competing source and just reads `value()`.
func is_overridden(id: StringName) -> bool:
	var rule: Resource = _defs.get(id)
	if rule == null:
		return false
	return not is_equal_approx(_values.get(id, 0.0), float(rule.get(&"default_value")))


## Sorted, so `rules` and the check tool both get a stable order without either of them sorting.
func rule_ids() -> Array[StringName]:
	var ids: Array[StringName] = []
	ids.assign(_values.keys())
	# StringName's `<` compares interned identity, not string content — F-175.
	ids.sort_custom(func(a, b): return String(a) < String(b))
	return ids


## Rendered through the rule's own type — see RuleDef.format_value().
func value_text(id: StringName) -> String:
	var rule: Resource = _defs.get(id)
	if rule == null:
		return "—"
	return String(rule.call("format_value", _values.get(id, 0.0)))


# ── Host mutation ────────────────────────────────────────────────────────────────────────────────


## Sets a rule and replicates it. Returns the value actually stored, which is the requested one
## coerced by the RuleDef (clamped, then rounded for INT / flattened for BOOL) — callers that report
## back to a player should print THIS, not what was asked for, so a clamp is visible rather than
## silent. Returns the current value unchanged when the caller is not the authority or the id is
## unknown; check `has_rule()` first if you need to tell those apart.
func host_set(id: StringName, raw_value: float) -> float:
	if not _owns_rules() or not _defs.has(id):
		return _values.get(id, raw_value)
	var rule: Resource = _defs[id]
	var coerced: float = float(rule.call("coerce", raw_value))
	if is_equal_approx(coerced, _values.get(id, NAN)):
		return coerced
	_values[id] = coerced
	MireLog.info(LOG_CHANNEL, "%s = %s" % [id, rule.call("format_value", coerced)])
	rule_changed.emit(id, coerced)
	if bool(_transport().call("is_active")):
		net_rule_changed.rpc(id, coerced)
	return coerced


## Back to the authored default. Same return contract as host_set().
func host_reset(id: StringName) -> float:
	if not _defs.has(id):
		return _values.get(id, 0.0)
	return host_set(id, float(_defs[id].get(&"default_value")))


# ── Replication (host -> clients, reliable) ──────────────────────────────────────────────────────


## A joiner that never got this would run the host's session on its own authored defaults, and
## nothing would look wrong until the first rule someone had already changed mattered. Same lesson
## PowerupService's `_on_peer_joined` records: publishing on mutation alone is only correct if every
## peer was present for every mutation, which is exactly what a mid-run join is not.
func _on_peer_joined(peer_id: int) -> void:
	if not _owns_rules() or not bool(_transport().call("has_peer", peer_id)):
		return
	# Dictionary[StringName, float] does not cross the wire as itself; send a plain copy.
	var snapshot: Dictionary = {}
	for id: StringName in _values:
		snapshot[id] = _values[id]
	net_rule_snapshot.rpc_id(peer_id, snapshot)


@rpc("authority", "call_remote", "reliable")
func net_rule_snapshot(values: Dictionary) -> void:
	if _owns_rules():
		return
	for key: Variant in values:
		var id := StringName(key)
		# A rule the client does not know is a content mismatch, not a value to invent an entry for:
		# storing it would make has_rule() true for something with no RuleDef, and every typed read
		# (value_int, value_text, the `rule` command's parser) assumes a def exists for a live id.
		if not _defs.has(id):
			MireLog.warn(LOG_CHANNEL, "host sent unknown rule '%s' — content mismatch, ignored" % id)
			continue
		_apply_replicated(id, float(values[key]))


@rpc("authority", "call_remote", "reliable")
func net_rule_changed(id: StringName, new_value: float) -> void:
	if _owns_rules():
		return
	if not _defs.has(id):
		MireLog.warn(LOG_CHANNEL, "host changed unknown rule '%s' — content mismatch, ignored" % id)
		return
	_apply_replicated(id, new_value)


func _apply_replicated(id: StringName, new_value: float) -> void:
	if is_equal_approx(new_value, _values.get(id, NAN)):
		return
	_values[id] = new_value
	rule_changed.emit(id, new_value)


# ── Commands (COMMANDS.md §4.2) ──────────────────────────────────────────────────────────────────


func _register_commands() -> void:
	var command_service: Node = get_node_or_null(^"/root/CommandService")
	if command_service == null:
		return
	command_service.call("register_spec", &"rule", {
		# Dynamic scope: reading a rule answers off this machine's own replicated copy, setting one
		# is a host mutation. COMMANDS.md §4.2 asks for exactly that split under one verb, and a
		# fixed scope cannot express it — see CommandService's `_invocation_scope`.
		"scope": _rule_scope,
		"args": [
			{"name": "rule", "type": &"rule_id"},
			# Typed as a raw string on purpose: what counts as a legal value depends on the RULE
			# named by the previous argument (on/off for a BOOL, a whole number for an INT), and the
			# central type table parses each argument independently. The handler coerces it through
			# the RuleDef, which is the only thing that knows.
			{"name": "value", "type": &"string", "optional": true, "default": ""},
		],
		"handler": _cmd_rule,
		"help": "rule <rule_id> [value|reset] — read or set a gamerule",
	})
	command_service.call("register_spec", &"rules", {
		"scope": &"local", "args": [], "handler": _cmd_rules,
		"help": "rules — list every gamerule with its value and description",
	})


func _rule_scope(raw_args: PackedStringArray) -> StringName:
	return &"host" if raw_args.size() >= 2 else &"local"


func _cmd_rule(_ctx: Dictionary, args: Dictionary) -> Dictionary:
	var id: StringName = args.get("rule", &"")
	var rule: Resource = _defs.get(id)
	if rule == null:
		return {"ok": false, "message": "no such rule '%s' — try `rules`" % id, "data": {}}

	var raw: String = String(args.get("value", "")).strip_edges()
	if raw.is_empty():
		return {"ok": true, "message": "%s = %s" % [id, value_text(id)],
			"data": {"rule": String(id), "value": _values.get(id, 0.0), "changed": false}}

	var requested: float
	if raw.to_lower() == RESET_WORD:
		requested = float(rule.get(&"default_value"))
	else:
		var parsed: Dictionary = _parse_typed(rule, raw)
		if not bool(parsed.get("ok", false)):
			return {"ok": false, "message": String(parsed.get("error", "")), "data": {}}
		requested = float(parsed.get("value", 0.0))

	var before: float = _values.get(id, 0.0)
	var after: float = host_set(id, requested)
	var message: String = "%s = %s" % [id, rule.call("format_value", after)]
	# Say so when the clamp moved the number. Silently storing 3600 for a requested 99999 is how a
	# tuning session ends with someone convinced the rule does not work.
	if not is_equal_approx(after, requested):
		message += " (clamped from %s, range %s)" % [
			rule.call("format_value", requested), rule.call("range_text")
		]
	return {"ok": true, "message": message,
		"data": {"rule": String(id), "value": after, "previous": before,
			"changed": not is_equal_approx(after, before)}}


func _cmd_rules(_ctx: Dictionary, _args: Dictionary) -> Dictionary:
	var ids: Array[StringName] = rule_ids()
	if ids.is_empty():
		return {"ok": true, "message": "no rules loaded", "data": {"rules": []}}
	var lines: PackedStringArray = ["%d rule(s):" % ids.size()]
	var listing: Array[Dictionary] = []
	for id: StringName in ids:
		var rule: Resource = _defs[id]
		lines.append("  %s = %s  [%s %s]" % [
			id, value_text(id), rule.call("type_name"), rule.call("range_text")
		])
		var description: String = String(rule.get(&"description")).strip_edges()
		if not description.is_empty():
			lines.append("      %s" % description)
		listing.append({
			"rule": String(id),
			"value": _values.get(id, 0.0),
			"default": float(rule.get(&"default_value")),
			"type": String(rule.call("type_name")),
		})
	return {"ok": true, "message": "\n".join(lines), "data": {"rules": listing}}


## Turns one raw token into a value for THIS rule. BOOL accepts the same words the console's own bool
## arguments do, so `rule dev_loadout_enabled off` reads the way every other toggle in the project
## does rather than demanding a 0.
func _parse_typed(rule: Resource, raw: String) -> Dictionary:
	var kind: int = int(rule.get(&"type"))
	if kind == RULE_DEF.Type.BOOL:
		var lowered: String = raw.to_lower()
		if lowered in ["on", "true", "1", "yes"]:
			return {"ok": true, "value": 1.0}
		if lowered in ["off", "false", "0", "no"]:
			return {"ok": true, "value": 0.0}
		return {"ok": false, "error": "'%s' is not on/off for a bool rule" % raw}
	if kind == RULE_DEF.Type.INT:
		if not raw.is_valid_int():
			return {"ok": false, "error": "'%s' is not a whole number" % raw}
		return {"ok": true, "value": float(raw.to_int())}
	if not raw.is_valid_float() and not raw.is_valid_int():
		return {"ok": false, "error": "'%s' is not a number" % raw}
	return {"ok": true, "value": raw.to_float()}


# ── Boot ─────────────────────────────────────────────────────────────────────────────────────────


func _load_defs() -> void:
	var registry: Node = get_node_or_null(^"/root/Registry")
	if registry != null and registry.has_method(&"rule_defs"):
		var from_registry: Dictionary = registry.call("rule_defs")
		for key: Variant in from_registry:
			_defs[StringName(key)] = from_registry[key]
		return
	_load_defs_from_disk()


## The header's seatbelt path. Deliberately quieter than registry.gd's loader — it is not trying to
## be a second content front door, only to keep a hand-instantiated harness from seeing zero rules
## and concluding the feature is broken.
func _load_defs_from_disk() -> void:
	var dir: DirAccess = DirAccess.open(RULES_PATH)
	if dir == null:
		return
	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	while file_name != "":
		if not dir.current_is_dir():
			# F-121: exported builds pack "<name>.tres" as "<name>.tres.remap"; load() wants the
			# original path and resolves the remap itself.
			var res_name: String = file_name.trim_suffix(".remap")
			if res_name.ends_with(".tres"):
				var res: Resource = load(RULES_PATH.path_join(res_name))
				# Script equality, not `is RuleDef` — F-016: this autoload boots in every headless
				# run and a stale class cache would break every check in the project, not just this
				# task's own.
				if res != null and res.get_script() == RULE_DEF:
					var id := StringName(String(res.get(&"id")))
					if id != &"" and not _defs.has(id):
						_defs[id] = res
		file_name = dir.get_next()
	dir.list_dir_end()


## Every rule starts at its authored default on every peer, host and client alike, so a client is
## never blank before the snapshot lands — it is merely possibly-stale, which every replicated
## service in this project already is for one round trip.
func _seed_defaults() -> void:
	for id: StringName in _defs:
		var rule: Resource = _defs[id]
		_values[id] = float(rule.call("coerce", float(rule.get(&"default_value"))))


# ── Authority (same `_owns_*` shape as every other host service) ─────────────────────────────────


func _owns_rules() -> bool:
	var transport: Node = _transport()
	if transport == null:
		return true
	if bool(transport.call("is_host")):
		return true
	return not bool(transport.call("is_active")) and not bool(transport.call("is_connecting"))


## Path-resolved (F-011 — harnesses install the transport at /root), cached once found (F-099).
func _transport() -> Node:
	if _transport_node == null or not is_instance_valid(_transport_node):
		_transport_node = get_node_or_null(^"/root/NetTransport")
	return _transport_node
