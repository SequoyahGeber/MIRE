extends SceneTree

## The coverage check docs/COMMANDS.md §7 asks task 3.16 for, in its own words: "asserts every table
## row exists in `commands --json` and that every HOST-scope command refuses a non-op — coverage and
## permission tested mechanically, so a new service that forgets its verbs fails a check instead of
## a code review."
##
##   .agent/bin/agent godot --script tools/command_catalog_check.gd
##
## Two things this deliberately does NOT do. It does not execute the mutating verbs — the per-system
## checks own their behaviour, and a catalog check that spawned, built and killed things would be a
## slow, flaky duplicate of nine of them. And it does not accept a verb registered through
## `DebugConsole.register()`'s deprecation shim as coverage: the shim wraps a callable in an
## untyped LOCAL spec, so a HOST-scope mutation hiding behind one would pass a naive name check
## while being unprotected. Scope is asserted, not just existence.
const CommandServiceScript = preload("res://autoload/command_service.gd")

const HOST_PEER: int = 1
const NON_OP_PEER: int = 4242

## COMMANDS.md §7's table, transcribed. `scope` is what the row's authority implies, and is the half
## that actually catches mistakes — a `give` that drifted to LOCAL would still "exist".
const CATALOG: Array[Dictionary] = [
	{"name": &"give", "scope": "host", "system": "Inventory"},
	# §7's Inventory row says `clear [target]`; the Meta row says `clear` (console). The console kept
	# the bare name and the inventory wipe became `inv clear` — see D-093.
	{"name": &"inv", "scope": "host", "system": "Inventory"},
	{"name": &"clear", "scope": "local", "system": "Meta (console)"},
	{"name": &"spawn", "scope": "host", "system": "Enemies"},
	{"name": &"kill", "scope": "host", "system": "Enemies"},
	{"name": &"killall", "scope": "host", "system": "Enemies"},
	{"name": &"enemies", "scope": "local", "system": "Enemies"},
	{"name": &"damage", "scope": "host", "system": "Health"},
	{"name": &"heal", "scope": "host", "system": "Health"},
	{"name": &"down", "scope": "host", "system": "Health"},
	{"name": &"revive", "scope": "host", "system": "Health"},
	{"name": &"starve", "scope": "host", "system": "Health"},
	# `time` and `rule` are dynamic-scope (D-086) and report their MAX, host — see _declared_scope.
	{"name": &"time", "scope": "host", "system": "Time", "host_args": "set 0.5"},
	{"name": &"wave", "scope": "host", "system": "Waves"},
	{"name": &"powerup", "scope": "host", "system": "Powerups"},
	{"name": &"stat", "scope": "host", "system": "Powerups"},
	{"name": &"craft", "scope": "host", "system": "Crafting"},
	{"name": &"recipes", "scope": "local", "system": "Crafting"},
	{"name": &"build", "scope": "host", "system": "Building"},
	{"name": &"demolish", "scope": "host", "system": "Building"},
	{"name": &"harvest", "scope": "host", "system": "Harvest"},
	{"name": &"loot", "scope": "host", "system": "Loot"},
	{"name": &"rule", "scope": "host", "system": "Rules", "host_args": "day_length_seconds 120"},
	{"name": &"rules", "scope": "local", "system": "Rules"},
	{"name": &"entities", "scope": "local", "system": "Entities"},
	{"name": &"tag", "scope": "host", "system": "Entities"},
	{"name": &"tp", "scope": "host", "system": "Entities"},
	{"name": &"lobby", "scope": "local", "system": "Session"},
	{"name": &"help", "scope": "local", "system": "Meta"},
	{"name": &"commands", "scope": "local", "system": "Meta"},
	{"name": &"op", "scope": "host", "system": "Meta"},
	{"name": &"deop", "scope": "host", "system": "Meta"},
	{"name": &"quit", "scope": "local", "system": "Meta"},
	{"name": &"fps_cap", "scope": "local", "system": "Meta"},
	{"name": &"vsync", "scope": "local", "system": "Meta"},
]

## The one §7 row this task does not deliver, stated rather than quietly omitted: `function <name>`
## is task 3.17's, along with the whole functions/hooks/autoexec surface. Asserted ABSENT so that
## when 3.17 ships it fails here and its author moves the row up into CATALOG.
const DEFERRED_TO_3_17: Array[StringName] = [&"function"]

var failures: int = 0
var command_service: CommandServiceScript


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var node: Node = root.get_node_or_null(^"CommandService")
	check(node != null, "CommandService autoload exists")
	if node == null:
		finish()
		return
	command_service = node as CommandServiceScript

	var dump: Dictionary = await _json_dump()
	if dump.is_empty():
		finish()
		return

	_check_coverage(dump)
	_check_no_shim_registrations(dump)
	await _check_host_commands_refuse_non_op(dump)
	_check_deferred()

	print("\nCOMMAND_CATALOG_CHECK failures=%d" % failures)
	finish()


## Through `commands --json` rather than the private `_specs`, because that dump is what COMMANDS.md
## §2.5 promises as the machine-readable surface — checking it here is also what keeps the promise
## honest for any future UI or agent that reads it.
func _json_dump() -> Dictionary:
	var result: Dictionary = await command_service.execute(
		"commands --json", _ctx(HOST_PEER))
	check(bool(result.get("ok", false)), "`commands --json` succeeds")
	var raw: String = String((result.get("data", {}) as Dictionary).get("json", ""))
	var parsed: Variant = JSON.parse_string(raw) if not raw.is_empty() else null
	var entries: Array = []
	if parsed is Array:
		entries = parsed
	elif parsed is Dictionary:
		entries = (parsed as Dictionary).get("commands", [])
	else:
		entries = (result.get("data", {}) as Dictionary).get("commands", [])
	check(not entries.is_empty(), "the dump contains commands (%d)" % entries.size())
	var by_name: Dictionary = {}
	for entry: Variant in entries:
		if entry is Dictionary:
			by_name[StringName(String((entry as Dictionary).get("name", "")))] = entry
	return by_name


func _check_coverage(dump: Dictionary) -> void:
	print("\n== every COMMANDS.md §7 row is registered, at the scope its authority implies ==")
	var missing: PackedStringArray = []
	for row: Dictionary in CATALOG:
		var name: StringName = row["name"]
		if not dump.has(name):
			missing.append("%s (%s)" % [name, row["system"]])
			continue
		var scope: String = String((dump[name] as Dictionary).get("scope", ""))
		check(scope == String(row["scope"]),
			"%s · %s is %s scope" % [row["system"], name, row["scope"]]
				+ ("" if scope == String(row["scope"]) else " — but the registry says '%s'" % scope))
	check(missing.is_empty(),
		"no §7 verb is missing" if missing.is_empty()
			else "MISSING §7 verbs: %s" % ", ".join(missing))


## A verb registered through `DebugConsole.register()` still shows up in the dump, so name-only
## coverage would happily pass while the command was an untyped LOCAL wrapper. The shim's own
## signature is the tell: it produces exactly one `rest`-typed argument and no others.
func _check_no_shim_registrations(dump: Dictionary) -> void:
	print("\n== no catalog verb is still riding the deprecated DebugConsole.register() shim ==")
	var shimmed: PackedStringArray = []
	for row: Dictionary in CATALOG:
		var entry: Dictionary = dump.get(row["name"], {})
		if entry.is_empty():
			continue
		var args: Array = entry.get("args", [])
		if args.size() == 1 and String((args[0] as Dictionary).get("type", "")) == "rest":
			shimmed.append(String(row["name"]))
	check(shimmed.is_empty(),
		"every §7 verb has a real typed spec" if shimmed.is_empty()
			else "still on the shim: %s" % ", ".join(shimmed))


## The permission half of §7's sentence. Every HOST-scope verb must refuse a peer that is not op, in
## CommandService's one uniform voice — a verb that forgot to declare HOST scope, or one that grew a
## handler doing its own permission thinking, fails right here.
func _check_host_commands_refuse_non_op(dump: Dictionary) -> void:
	print("\n== every HOST-scope verb refuses a non-op, in the same words ==")
	var leaked: PackedStringArray = []
	for row: Dictionary in CATALOG:
		if String(row["scope"]) != "host" or not dump.has(row["name"]):
			continue
		# Bare name by default, on purpose: a HOST command must be refused BEFORE its arguments are
		# parsed, so a missing-argument usage line coming back instead of the refusal would mean the
		# permission gate sits downstream of parsing and leaks the shape of commands a non-op may not
		# run.
		#
		# `host_args` is the exception a dynamic-scope verb needs (D-086). `time` and `rule` are LOCAL
		# reads in their bare form — that is the whole feature — so probing them with no arguments
		# would assert the opposite of what they promise. They are probed with the arguments that
		# actually make them mutate. The first version of this check did not, and reported the
		# feature working correctly as a permission leak.
		var line: String = String(row["name"])
		if row.has("host_args"):
			line += " " + String(row["host_args"])
		var result: Dictionary = await command_service.execute(line, _ctx(NON_OP_PEER))
		var message: String = String(result.get("message", ""))
		if bool(result.get("ok", false)) or not message.begins_with("not op"):
			leaked.append("%s -> %s" % [row["name"], "ok" if bool(result.get("ok", false)) else message])
	check(leaked.is_empty(),
		"all HOST verbs gate on op" if leaked.is_empty()
			else "NOT gated: %s" % ", ".join(leaked))


func _check_deferred() -> void:
	print("\n== the §7 rows this task does not deliver are named, not silently missing ==")
	for name: StringName in DEFERRED_TO_3_17:
		check(not command_service.has_spec(name),
			"`%s` is still task 3.17's — when it lands, move its row into CATALOG" % name)


func _ctx(peer_id: int) -> Dictionary:
	return {"peer_id": peer_id, "source": &"console", "position": Vector3.ZERO, "facing": Vector3.FORWARD}


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
