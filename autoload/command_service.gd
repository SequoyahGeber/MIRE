extends Node

## CommandService — autoload. The one front door for every runtime command: parsing, typed-arg
## validation, LOCAL/HOST scope routing, op permissions, and execution. docs/COMMANDS.md is the design
## spec this implements; this header states the §2.2 authority row this task adds.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, "Command execution" row): **Host** for mutating
## (HOST-scope) commands; client submits over `net_submit_command`, the host RE-PARSES the raw line
## from scratch (never trusts anything the client parsed — same trust stance as BuildService re-
## snapping the ghost's transform, D-034) and returns the result via `net_command_result`. LOCAL-scope
## commands (reads/presentation) run wherever they were typed, against that machine's own replicated
## view.
##
## Autoload order: registered right after DebugConsole (`agent autoload`, D-021/F-051) so every later
## autoload can call `register_spec()` from its own `_ready()`. DebugConsole itself loads BEFORE this
## service exists, so its own builtin specs register via `call_deferred` — see debug_console.gd.
##
## CROSS-AUTOLOAD BOUNDARY: every command spec, arg, ctx and result crossing into or out of this file
## is a plain Dictionary/StringName/Callable — never a custom class instance — because every caller
## reaches this service through `get_node_or_null(^"/root/CommandService")` + `.call()` (the
## established convention in this codebase, not the bare-autoload-name carve-out AGENTS.md allows,
## because a `--script` harness that hand-instantiates one service under /root without the rest of
## project.godot's autoload list is exactly the shape several existing checks already use). Awaiting a
## coroutine THROUGH that dynamic `.call()` dispatch is not something any existing code here relies on,
## so this file does not either: `execute()` is a real coroutine for a typed/direct caller (checks that
## hold a preloaded/typed reference, or this script's own internals); everyone else uses `submit()` +
## the `command_result` signal, the same request/confirmed shape AttunementService already uses for its
## client -> host round trip.

## CommandCtx shape (plain Dictionary, built by `build_local_ctx()`/`_build_ctx()`):
##   peer_id: int          — who issued it
##   source: StringName    — &"console" | &"runner" | &"function" | &"hook" | &"rpc"
##   position: Vector3     — issuer's replicated position, for `~` relative coords (3.15)
##   facing: Vector3       — issuer's replicated forward vector (-basis.z); Vector3.FORWARD if there
##                            is no body to read (offline harness, or a peer with none spawned yet)
##   _fn_depth: int         — INTERNAL, task 3.17 only. How many `function` calls deep the CURRENT
##                            line is nested. Threaded through ctx rather than a member counter
##                            because a member would be shared across concurrent invocations (two
##                            peers' commands can interleave across `await` points) — see
##                            `_cmd_function()`. Absent (defaults to 0) for every caller outside the
##                            function machinery; nobody else needs to read or set it.
##
## CommandResult shape (built by `_result()`): {ok: bool, message: String, data: Dictionary}

const NOT_OP_MESSAGE: String = "not op — ask the host to `op <peer>` you first"
const HOST_COMMAND_TIMEOUT_SEC: float = 5.0
const _TRUE_WORDS: PackedStringArray = ["on", "true", "1", "yes"]
const _FALSE_WORDS: PackedStringArray = ["off", "false", "0", "no"]

## F-016: FunctionRunner is a script new this session. Preloaded rather than referenced bare, one-
## directional only — FunctionRunner itself never preloads this file back, so there is no cycle.
const FUNCTION_RUNNER := preload("res://systems/commands/function_runner.gd")

## docs/COMMANDS.md §5.1/§5.3. content/functions/autoexec.mcmd, if present, is scanned in like any
## other function and also auto-run at boot (host/offline only) — see `_run_autoexec()`.
const FUNCTIONS_DIR: String = "res://content/functions"

## docs/COMMANDS.md §5.2's event vocabulary "starts with what exists" — every entry here names a
## REAL signal a prior task already shipped. `run_started`/`player_downed` are named in the design
## doc's own illustrative list but have no shipped signal to bind to yet (filed F-154); a HookDef
## naming either fails loudly at wire time (MireLog error) below instead of silently never firing.
## `handler` is one of this file's own methods, shaped to match the named signal's exact arity —
## Callable.bind() appends the hook's (function, host_only) pair AFTER whatever the signal itself
## supplies, so the handler's own parameter list has to match the signal, not guess at it.
const _HOOK_EVENTS: Dictionary[StringName, Dictionary] = {
	&"night_started": {
		"path": ^"/root/DayNight", "signal": &"night_started", "handler": &"_on_hook_signal_0"},
	&"day_started": {
		"path": ^"/root/DayNight", "signal": &"day_started", "handler": &"_on_hook_signal_0"},
	&"enemy_died": {
		"path": ^"/root/EnemyWorld", "signal": &"enemy_died", "handler": &"_on_hook_signal_enemy_died"},
}

## Fires once per `submit()` handle, with that call's CommandResult. The dynamic-dispatch-safe way to
## get a result back — connect once, filter by the handle `submit()` returned.
signal command_result(handle: int, result: Dictionary)

var _specs: Dictionary[StringName, Dictionary] = {}
## Host-side only. Peer-id keyed, not literally the D-035 run-player token: NetSession's token lookup
## is private (`_identity`, no public accessor) and core/net/net_session.gd is outside this task's
## claim set. Every other host service in this codebase (Attunement, Powerup, Inventory) already keys
## its per-player state by peer id and follows `run_player_rebound`/`run_player_expired` to survive a
## reconnect's grace window — that is the actual mechanism "survives the grace window" describes, and
## it is what this dictionary does too. Filed as a decision, not a gap: see docs/DECISIONS.md.
var _ops: Dictionary[int, bool] = {}
var _next_id: int = 1
## request_id -> true once its result has arrived, so a late timeout after a real reply can't emit a
## second, stale result for the same request.
var _resolved_requests: Dictionary[int, bool] = {}
var _type_parsers: Dictionary[StringName, Callable] = {}
var _transport_node: Node
## content/functions/*.mcmd, scanned at boot (docs/COMMANDS.md §5.1). Also grown at runtime by
## `register_function()` — content reload and test setup both want that, same reasoning
## `register_spec()`'s own docstring gives.
var _functions: Dictionary[StringName, PackedStringArray] = {}
## Hook ids this process has actually connected a signal for — `has_wired_hook()` is what
## tools/function_check.gd asserts against rather than reaching into a private Dictionary.
var _wired_hooks: Dictionary[StringName, bool] = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_register_type_parsers()
	_register_meta_commands()
	_functions = FUNCTION_RUNNER.scan_directory(FUNCTIONS_DIR)
	_register_function_command()

	var session: Node = get_node_or_null(^"/root/NetSession")
	if session != null and session.has_signal(&"run_player_rebound"):
		session.connect(&"run_player_rebound", _on_run_player_rebound)
		session.connect(&"run_player_expired", _on_run_player_expired)

	# Deferred (same trick debug_console.gd's own _register_builtins() uses): Registry (this task's
	# own HookDef family) and every event source (DayNight, EnemyWorld) register LATER than this
	# autoload in project.godot, so neither exists yet during this _ready(). call_deferred runs at
	# the end of THIS frame, after every autoload's own _ready() has already completed.
	_wire_hooks.call_deferred()
	_run_autoexec.call_deferred()


# ── Registration ─────────────────────────────────────────────────────────────────────────────────


## spec: {scope: &"local"|&"host"|Callable, args: Array[Dictionary], handler: Callable(ctx, args) ->
## Dictionary, help: String}. A Callable `scope` decides per invocation — see `_invocation_scope`. `args` entries: {name: String, type: StringName, optional: bool, default: Variant,
## min/max: Variant, values: Array} — see `_register_type_parsers()` for the type table (COMMANDS.md
## §2.2). A spec with no `args` key takes none. Re-registering a name replaces it silently — content
## reload and test setup both want that, not a duplicate-registration error.
func register_spec(name: StringName, spec: Dictionary) -> void:
	if not (spec.get("handler") is Callable) or not (spec["handler"] as Callable).is_valid():
		MireLog.error(&"dev", "CommandService: '%s' registered with no valid handler — ignored" % name)
		return
	_specs[name] = spec


func has_spec(name: StringName) -> bool:
	return _specs.has(name)


func spec_names() -> Array[StringName]:
	var names: Array[StringName] = []
	names.assign(_specs.keys())
	# StringName's `<` compares interned identity, not string content — F-175.
	names.sort_custom(func(a, b): return String(a) < String(b))
	return names


## For a caller (DebugConsole's `help`) that wants to list commands without going through
## execute()/submit() — those return CommandResults, not raw spec data, and a LOCAL handler must stay
## synchronous (see the file header), so it cannot itself await a `commands` round trip.
func help_text(name: StringName) -> String:
	return String(_specs.get(name, {}).get("help", String(name)))


## The scope to SHOW for a command — help text, the `commands` listing, the §2.5 JSON dump. A
## dynamic-scope command reports &"host", its maximum: that is the honest thing to tell someone
## reading the list ("this one can mutate"), and it matches COMMANDS.md §5.1's own rule that a
## function's effective scope is the max of its lines' scopes.
func scope_of(name: StringName) -> StringName:
	return _declared_scope(_specs.get(name, {}))


func _declared_scope(spec: Dictionary) -> StringName:
	var scope: Variant = spec.get("scope", &"local")
	return &"host" if scope is Callable else StringName(scope)


## The scope of ONE invocation (D-086). A spec may declare `scope` as a Callable(PackedStringArray)
## -> StringName when the same verb reads on the machine that typed it but mutates on the host —
## `rule <id>` versus `rule <id> <value>` (COMMANDS.md §4.2), and 3.15's entity verbs after it. The
## callable sees the RAW argument tokens, before typed parsing, because routing has to be decided
## before the host is the one parsing them; it must therefore not assume the tokens are valid, only
## count and shape them. Evaluated identically on the client (to decide whether to forward) and on
## the host (to decide whether to demand op), from the same raw line — the host re-derives it from
## its own re-parse and never trusts the client's routing decision, same stance as everything else
## crossing `net_submit_command`.
func _invocation_scope(spec: Dictionary, raw_args: PackedStringArray) -> StringName:
	var scope: Variant = spec.get("scope", &"local")
	if scope is Callable:
		var resolver: Callable = scope
		if not resolver.is_valid():
			return &"host"
		return StringName(resolver.call(raw_args))
	return StringName(scope)


# ── Execution ────────────────────────────────────────────────────────────────────────────────────


## The dynamic-dispatch-safe entry point: kicks off execution and returns a handle immediately;
## `command_result(handle, result)` fires once, whenever the answer is ready — synchronously, still
## inside this call, for everything that does not need the network; asynchronously, after a real RPC
## round trip, for a client's HOST-scope command.
func submit(line: String, ctx: Dictionary) -> int:
	var handle: int = _take_id()
	_run_submission(handle, line, ctx)
	return handle


func _run_submission(handle: int, line: String, ctx: Dictionary) -> void:
	var result: Dictionary = await execute(line, ctx)
	command_result.emit(handle, result)


## Direct coroutine form — for a caller that holds a typed/preloaded CommandService reference (this
## script's own internals, or a check that instantiates one). See the file header: nobody else should
## `await` this across a `get_node_or_null().call()` boundary.
func execute(line: String, ctx: Dictionary) -> Dictionary:
	var trimmed: String = line.strip_edges()
	if trimmed.is_empty():
		return _result(true, "", {})

	var parts: PackedStringArray = trimmed.split(" ", false)
	var name := StringName(parts[0])
	var spec: Dictionary = _specs.get(name, {})
	if spec.is_empty():
		return _result(false, "unknown command: %s — try `help`" % name, {})

	var raw_args: PackedStringArray = parts.slice(1)
	var scope: StringName = _invocation_scope(spec, raw_args)
	var source: StringName = ctx.get("source", &"console")
	if scope == &"host" and source != &"rpc" and not _owns_execution():
		return await _submit_to_host(trimmed)

	return _execute_locally(spec, name, ctx, raw_args)


func _execute_locally(
	spec: Dictionary, name: StringName, ctx: Dictionary, raw_args: PackedStringArray
) -> Dictionary:
	var scope: StringName = _invocation_scope(spec, raw_args)
	var peer_id: int = int(ctx.get("peer_id", NetConfig.HOST_PEER_ID))
	if scope == &"host" and not _is_op(peer_id):
		return _result(false, NOT_OP_MESSAGE, {})

	var parsed: Dictionary = _parse_args(spec, raw_args, ctx)
	if not bool(parsed.get("ok", false)):
		# A MISSING required arg gets the generic usage line — nothing to say about it beyond "here
		# is the shape". An INVALID one (wrong type, unknown item/enemy/peer id, out of an enum's
		# set) surfaces the type parser's own message instead, because that message is the whole
		# point of a typed parser (COMMANDS.md §2.2: "no such item '%s' — try `items`", not a bare
		# usage line that throws that information away).
		if String(parsed.get("kind", "")) == "missing":
			return _result(false, "usage: %s" % String(spec.get("help", String(name))), {})
		return _result(false, String(parsed.get("error", "bad arguments")), {})

	var handler: Callable = spec.get("handler")
	var outcome: Variant = handler.call(ctx, parsed.get("args", {}) as Dictionary)
	return _normalize_result(outcome)


func _normalize_result(outcome: Variant) -> Dictionary:
	if outcome is Dictionary and (outcome as Dictionary).has("ok"):
		var d: Dictionary = outcome
		return _result(bool(d.get("ok", true)), String(d.get("message", "")),
			d.get("data", {}) as Dictionary)
	# Every registered handler returns the {ok, message, data} shape since F-130 removed the
	# DebugConsole.register() shim (whose wrapped callables returned bare Strings). Anything else
	# reaching here is a handler bug — say so instead of laundering it into a silent success, which
	# is what the old String coercion would do to, say, a handler that forgot its return entirely
	# (null -> "ok, empty message").
	return _result(false,
		"handler returned %s instead of {ok, message, data} — fix the spec's handler" %
		type_string(typeof(outcome)), {})


func _result(ok: bool, message: String, data: Dictionary) -> Dictionary:
	return {"ok": ok, "message": message, "data": data}


func build_local_ctx(source: StringName = &"console") -> Dictionary:
	return _build_ctx(_local_peer_id(), source)


func _build_ctx(peer_id: int, source: StringName) -> Dictionary:
	var body: Node3D = _body_for(peer_id)
	return {
		"peer_id": peer_id,
		"source": source,
		"position": body.global_position if body != null else Vector3.ZERO,
		"facing": -body.global_transform.basis.z if body != null else Vector3.FORWARD,
	}


# ── Client -> host RPC (protocol version bumped for this pair, see net_version.gd) ─────────────────


@rpc("any_peer", "call_remote", "reliable")
func net_submit_command(request_id: int, line: String) -> void:
	if not _owns_execution():
		return
	var sender_id: int = multiplayer.get_remote_sender_id()
	var ctx: Dictionary = _build_ctx(sender_id, &"rpc")
	var result: Dictionary = await execute(line, ctx)
	# F-059's shape: the `await` above is exactly the window for a hostile disconnect — the sender
	# can drop mid-execution, and an unguarded rpc_id() back to it would log "unknown peer ID".
	if _peer_connected(sender_id):
		net_command_result.rpc_id(sender_id, request_id, result)


@rpc("authority", "call_remote", "reliable")
func net_command_result(request_id: int, result: Dictionary) -> void:
	_resolved_requests[request_id] = true
	_rpc_result_received.emit(request_id, result)


signal _rpc_result_received(request_id: int, result: Dictionary)


func _submit_to_host(line: String) -> Dictionary:
	var request_id: int = _take_id()
	net_submit_command.rpc_id(NetConfig.HOST_PEER_ID, request_id, line)

	var timer: SceneTreeTimer = get_tree().create_timer(HOST_COMMAND_TIMEOUT_SEC)
	timer.timeout.connect(_on_submit_timeout.bind(request_id), CONNECT_ONE_SHOT)

	while true:
		var received: Array = await _rpc_result_received
		if int(received[0]) == request_id:
			return received[1] as Dictionary
	return _result(false, "unreachable", {})


func _on_submit_timeout(request_id: int) -> void:
	if _resolved_requests.has(request_id):
		return
	_resolved_requests[request_id] = true
	_rpc_result_received.emit(request_id,
		_result(false, "command timed out — no response from host", {}))


func _take_id() -> int:
	var id: int = _next_id
	_next_id += 1
	return id


# ── Op permissions (COMMANDS.md §1.3) ───────────────────────────────────────────────────────────────


func _is_op(peer_id: int) -> bool:
	return peer_id == NetConfig.HOST_PEER_ID or _ops.get(peer_id, false)


func _on_run_player_rebound(old_peer_id: int, new_peer_id: int) -> void:
	if _ops.has(old_peer_id):
		_ops.erase(old_peer_id)
		_ops[new_peer_id] = true


func _on_run_player_expired(peer_id: int) -> void:
	_ops.erase(peer_id)


# ── Meta commands (help lives on DebugConsole; this is the rest of COMMANDS.md §7's Meta row) ──────


func _register_meta_commands() -> void:
	register_spec(&"commands", {
		"scope": &"local",
		"args": [{"name": "format", "type": &"string", "optional": true, "default": ""}],
		"handler": _cmd_commands,
		"help": "commands [--json] — list every registered command, scope and help text",
	})
	register_spec(&"op", {
		"scope": &"host",
		"args": [{"name": "peer", "type": &"peer"}],
		"handler": _cmd_op,
		"help": "op <peer_id> — grant command permissions to a connected peer (host only)",
	})
	register_spec(&"deop", {
		"scope": &"host",
		"args": [{"name": "peer", "type": &"peer"}],
		"handler": _cmd_deop,
		"help": "deop <peer_id> — revoke command permissions from a peer (host only)",
	})


func _cmd_commands(_ctx: Dictionary, args: Dictionary) -> Dictionary:
	var names: Array[StringName] = spec_names()
	var as_json: bool = String(args.get("format", "")) == "--json"

	var dump: Array[Dictionary] = []
	for command_name: StringName in names:
		var spec: Dictionary = _specs[command_name]
		dump.append({
			"name": String(command_name),
			"scope": String(_declared_scope(spec)),
			"help": String(spec.get("help", "")),
			"arg_count": (spec.get("args", []) as Array).size(),
		})

	if as_json:
		return _result(true, JSON.stringify(dump), {"commands": dump})

	var lines: Array[String] = []
	for entry: Dictionary in dump:
		lines.append("  [%s] %s" % [String(entry["scope"]).to_upper(), entry["help"]])
	return _result(true, "\n".join(lines), {"commands": dump})


## Restricted to the host peer itself, additionally to the HOST-scope op check `_execute_locally`
## already ran — an op cannot mint another op (COMMANDS.md §1.3).
func _cmd_op(ctx: Dictionary, args: Dictionary) -> Dictionary:
	if int(ctx.get("peer_id", 0)) != NetConfig.HOST_PEER_ID:
		return _result(false, "only the host itself may op/deop", {})
	var target: int = int(args.get("peer", 0))
	_ops[target] = true
	return _result(true, "opped peer %d" % target, {"peer": target})


func _cmd_deop(ctx: Dictionary, args: Dictionary) -> Dictionary:
	if int(ctx.get("peer_id", 0)) != NetConfig.HOST_PEER_ID:
		return _result(false, "only the host itself may op/deop", {})
	var target: int = int(args.get("peer", 0))
	_ops.erase(target)
	return _result(true, "deopped peer %d" % target, {"peer": target})


# ── Functions (COMMANDS.md §5.1) ────────────────────────────────────────────────────────────────────


func _register_function_command() -> void:
	register_spec(&"function", {
		# Dynamic scope (D-086): a function's own lines decide whether running it mutates host
		# state. `_function_scope` inspects the NAMED function's content, not the invocation's
		# tokens (contrast `rule`/`time`, which only look at how many tokens were typed) — see
		# FunctionRunner.effective_scope().
		"scope": _function_scope,
		"args": [{"name": "name", "type": &"function_id"}],
		"handler": _cmd_function,
		"help": "function <name> — run a content/functions/<name>.mcmd file (COMMANDS.md §5.1)",
	})


func _function_scope(raw_args: PackedStringArray) -> StringName:
	if raw_args.is_empty():
		return &"local"  # missing arg -> a usage error, not a mutation attempt
	return FUNCTION_RUNNER.effective_scope(StringName(raw_args[0]), _functions, scope_of)


## Runs every line of `name` through THIS SAME execute() (never a second execution path), in order,
## stopping at the first line that fails. Depth is threaded through `ctx["_fn_depth"]` rather than a
## member counter — see the CommandCtx docstring at the top of this file for why a shared counter
## would be unsafe across concurrent invocations.
func _cmd_function(ctx: Dictionary, args: Dictionary) -> Dictionary:
	var name: StringName = args.get("name", &"")
	var depth: int = int(ctx.get("_fn_depth", 0))
	if depth >= FUNCTION_RUNNER.RECURSION_CAP:
		return _result(false,
			"function recursion cap (%d) exceeded calling '%s'" % [FUNCTION_RUNNER.RECURSION_CAP, name], {})
	if not _functions.has(name):
		# Reachable directly (e.g. a hook's HookDef.function typo) even though `_parse_function_id`
		# already guards the console/RPC path — belt and suspenders, cheap either way.
		return _result(false, "no such function '%s' — check content/functions/" % name, {})

	var child_ctx: Dictionary = ctx.duplicate()
	child_ctx["_fn_depth"] = depth + 1
	var executed: int = 0
	for line: String in (_functions[name] as PackedStringArray):
		var result: Dictionary = await execute(line, child_ctx)
		executed += 1
		if not bool(result.get("ok", false)):
			return _result(false, "function '%s' line %d ('%s') failed: %s" % [
				name, executed, line, result.get("message", "")], {})
	return _result(true, "function '%s' ran %d command(s)" % [name, executed], {"executed": executed})


func has_function(name: StringName) -> bool:
	return _functions.has(name)


func function_names() -> Array[StringName]:
	var names: Array[StringName] = []
	names.assign(_functions.keys())
	# StringName's `<` compares interned identity, not string content — F-175.
	names.sort_custom(func(a, b): return String(a) < String(b))
	return names


## Registers (or replaces) a function's lines directly, bypassing content/functions/ entirely — the
## runtime-authoring counterpart to `register_spec()`'s "content reload and test setup both want
## that" (same file, same reasoning). tools/function_check.gd is the worked caller: proving the
## recursion cap or D-086 routing needs a throwaway function that never has to become a permanent
## content/functions/*.mcmd fixture.
func register_function(name: StringName, lines: PackedStringArray) -> void:
	_functions[name] = lines


## Read-only mirror of `_is_op()` for a caller outside this file (tools/function_check.gd's hook
## test asserts on it rather than driving observable game state that another system — WaveSpawner,
## on night_started — would ALSO touch and make ambiguous).
func is_op(peer_id: int) -> bool:
	return _is_op(peer_id)


## docs/COMMANDS.md §5.3. content/functions/autoexec.mcmd runs through the exact same `function`
## handler as `function autoexec` typed by hand (it was already scanned into `_functions` above like
## any other file in the directory) — one code path, not two. user://autoexec.mcmd is the per-
## install, gitignored dev file and is never content, so it is read directly instead. Host/offline
## only, and only once every autoload has settled (see the call_deferred in `_ready()`).
func _run_autoexec() -> void:
	if not _owns_execution():
		return
	var ctx: Dictionary = _build_ctx(NetConfig.HOST_PEER_ID, &"function")

	if _functions.has(&"autoexec"):
		var project_result: Dictionary = await _cmd_function(ctx, {"name": &"autoexec"})
		if not bool(project_result.get("ok", false)):
			MireLog.error(&"dev", "content/functions/autoexec.mcmd: %s" % project_result.get("message", ""))

	if FileAccess.file_exists("user://autoexec.mcmd"):
		var lines: PackedStringArray = FUNCTION_RUNNER.parse_lines(
			FileAccess.get_file_as_string("user://autoexec.mcmd"))
		for line: String in lines:
			var result: Dictionary = await execute(line, ctx)
			if not bool(result.get("ok", false)):
				MireLog.error(&"dev", "user://autoexec.mcmd: '%s' failed: %s" % [line, result.get("message", "")])


# ── Hooks (COMMANDS.md §5.2) ─────────────────────────────────────────────────────────────────────────


## Every ENABLED HookDef Registry loaded gets wired to its real signal. Disabled ones (the shipped
## default, per §5.2) are skipped entirely — not connected, not even looked up, so an author has to
## deliberately flip `enabled` to find out whether the event binding even exists.
func _wire_hooks() -> void:
	var registry: Node = get_node_or_null(^"/root/Registry")
	if registry == null:
		return
	var defs: Dictionary = registry.call("hook_defs")
	for hook_id: StringName in defs.keys():
		var hook: Resource = defs[hook_id]
		if not bool(hook.get("enabled")):
			continue
		wire_hook(hook)


## Public so a check can wire a synthetic HookDef straight in — no content/hooks/*.tres, no Registry
## round trip needed (tools/function_check.gd's worked proof). Real hooks only ever arrive here
## through `_wire_hooks()` above.
func wire_hook(hook: Resource) -> void:
	var hook_id: StringName = hook.get("id")
	var event: StringName = hook.get("event")
	var binding: Dictionary = _HOOK_EVENTS.get(event, {})
	if binding.is_empty():
		MireLog.error(&"dev", "hook '%s': unknown event '%s' has no signal binding" % [hook_id, event])
		return
	var target: Node = get_node_or_null(binding["path"])
	if target == null or not target.has_signal(binding["signal"]):
		MireLog.error(&"dev", "hook '%s': %s has no signal '%s'" % [hook_id, binding["path"], binding["signal"]])
		return
	var callback := Callable(self, binding["handler"] as StringName)
	target.connect(binding["signal"], callback.bind(hook.get("function"), bool(hook.get("host_only"))))
	_wired_hooks[hook_id] = true


func has_wired_hook(hook_id: StringName) -> bool:
	return _wired_hooks.get(hook_id, false)


func _on_hook_signal_0(function_name: StringName, host_only: bool) -> void:
	_fire_hook(function_name, host_only)


func _on_hook_signal_enemy_died(
	_enemy_id: StringName, _peer_id: int, _position: Vector3, function_name: StringName, host_only: bool
) -> void:
	_fire_hook(function_name, host_only)


## Runs the bound function through the exact same `function` front door `function <name>` uses
## (COMMANDS.md's own repeated principle: never a second mutation path). `host_only` re-checked here
## rather than only at connect time because a signal's OWNING autoload deciding when to emit is a
## separate question from whether THIS hook should react on this particular peer.
func _fire_hook(function_name: StringName, host_only: bool) -> void:
	if host_only and not _owns_execution():
		return
	var ctx: Dictionary = _build_ctx(NetConfig.HOST_PEER_ID, &"hook")
	var result: Dictionary = await execute("function %s" % function_name, ctx)
	if not bool(result.get("ok", false)):
		MireLog.error(&"dev", "hook -> function '%s' failed: %s" % [function_name, result.get("message", "")])


# ── Argument parsing (COMMANDS.md §2.2) ─────────────────────────────────────────────────────────────


func _register_type_parsers() -> void:
	_type_parsers[&"string"] = _parse_string
	_type_parsers[&"int"] = _parse_int
	_type_parsers[&"float"] = _parse_float
	_type_parsers[&"bool"] = _parse_bool
	_type_parsers[&"enum"] = _parse_enum
	_type_parsers[&"item_id"] = _parse_item_id
	_type_parsers[&"enemy_id"] = _parse_enemy_id
	_type_parsers[&"peer"] = _parse_peer
	_type_parsers[&"rule_id"] = _parse_rule_id
	_type_parsers[&"selector"] = _parse_selector
	_type_parsers[&"vec3"] = _parse_vec3
	_type_parsers[&"function_id"] = _parse_function_id
	# The remaining COMMANDS.md §2.2 content types, all four the same shape: a Registry lookup with
	# the family's own "try `<listing verb>`" hint. Registered through one helper rather than four
	# near-identical functions (F-099's lesson from registry.gd's own loader).
	_type_parsers[&"recipe_id"] = _registry_parser.bind(&"has_recipe", "recipe", "recipes")
	_type_parsers[&"powerup_id"] = _registry_parser.bind(&"has_powerup", "powerup", "powerups")
	_type_parsers[&"buildable_id"] = _registry_parser.bind(&"has_buildable", "buildable", "build")
	_type_parsers[&"station_id"] = _registry_parser.bind(&"has_station", "station", "recipes")
	_type_parsers[&"loot_table_id"] = _registry_parser.bind(&"has_loot_table", "loot table", "loot")


## Returns {ok: bool, args: Dictionary} on success, {ok: false, error: String} on the first bad token.
## A parse failure never reaches a handler — `_execute_locally` turns it into the spec's `help` text as
## the usage message, so handlers never write their own "usage:" strings (COMMANDS.md §2.2).
func _parse_args(spec: Dictionary, raw_args: PackedStringArray, ctx: Dictionary = {}) -> Dictionary:
	var arg_specs: Array = spec.get("args", [])
	var parsed: Dictionary = {}
	var i: int = 0

	for arg_spec_v: Variant in arg_specs:
		var arg_spec: Dictionary = arg_spec_v
		var arg_name: String = String(arg_spec.get("name", ""))
		var type_name: StringName = arg_spec.get("type", &"string")

		if type_name == &"rest":
			parsed[arg_name] = raw_args.slice(i)
			i = raw_args.size()
			continue

		# vec3 is the one type that spans three tokens, and the only one whose meaning depends on the
		# issuer (`~` means "my x"). Both facts live here rather than in the type table because the
		# table hands a parser exactly one token and no context.
		if type_name == &"vec3":
			if i + 3 > raw_args.size():
				if bool(arg_spec.get("optional", false)):
					parsed[arg_name] = arg_spec.get("default", Vector3.ZERO)
					continue
				return {"ok": false, "kind": "missing", "error": "missing <%s> (x y z)" % arg_name}
			var origin: Vector3 = ctx.get("position", Vector3.ZERO)
			var components: Array[float] = []
			for axis: int in 3:
				var component: Dictionary = _parse_vec3_component(raw_args[i + axis], origin[axis])
				if not bool(component.get("ok", false)):
					return {"ok": false, "kind": "value",
						"error": String(component.get("error", "bad <%s>" % arg_name))}
				components.append(float(component.get("value", 0.0)))
			parsed[arg_name] = Vector3(components[0], components[1], components[2])
			i += 3
			continue

		if i >= raw_args.size():
			if bool(arg_spec.get("optional", false)):
				parsed[arg_name] = arg_spec.get("default")
				continue
			return {"ok": false, "kind": "missing", "error": "missing <%s>" % arg_name}

		var parser: Callable = _type_parsers.get(type_name, _parse_string)
		var outcome: Dictionary = parser.call(raw_args[i], arg_spec)
		i += 1
		if not bool(outcome.get("ok", false)):
			return {"ok": false, "kind": "value",
				"error": String(outcome.get("error", "bad <%s>" % arg_name))}
		parsed[arg_name] = outcome.get("value")

	return {"ok": true, "args": parsed}


func _parse_string(raw: String, _spec: Dictionary) -> Dictionary:
	return {"ok": true, "value": raw}


func _parse_int(raw: String, spec: Dictionary) -> Dictionary:
	if not raw.is_valid_int():
		return {"ok": false, "error": "'%s' is not a whole number" % raw}
	var value: int = raw.to_int()
	if spec.has("min"):
		value = maxi(value, int(spec["min"]))
	if spec.has("max"):
		value = mini(value, int(spec["max"]))
	return {"ok": true, "value": value}


func _parse_float(raw: String, spec: Dictionary) -> Dictionary:
	if not raw.is_valid_float() and not raw.is_valid_int():
		return {"ok": false, "error": "'%s' is not a number" % raw}
	var value: float = raw.to_float()
	if spec.has("min"):
		value = maxf(value, float(spec["min"]))
	if spec.has("max"):
		value = minf(value, float(spec["max"]))
	return {"ok": true, "value": value}


func _parse_bool(raw: String, _spec: Dictionary) -> Dictionary:
	var lowered: String = raw.to_lower()
	if _TRUE_WORDS.has(lowered):
		return {"ok": true, "value": true}
	if _FALSE_WORDS.has(lowered):
		return {"ok": true, "value": false}
	return {"ok": false, "error": "'%s' is not on/off" % raw}


## `values`: Array[String], the closed word set — `enum(a,b,c)` in COMMANDS.md §2.2's notation.
func _parse_enum(raw: String, spec: Dictionary) -> Dictionary:
	var values: Array = spec.get("values", [])
	if values.has(raw):
		return {"ok": true, "value": raw}
	return {"ok": false, "error": "'%s' must be one of %s" % [raw, ", ".join(values)]}


func _parse_item_id(raw: String, _spec: Dictionary) -> Dictionary:
	var registry: Node = get_node_or_null(^"/root/Registry")
	var id := StringName(raw)
	if registry == null or not bool(registry.call("has_item", id)):
		# Exact text `dev_loadout.gd`'s old hand-rolled `give` used — kept verbatim (COMMANDS.md's
		# 3.13 instruction: give's output strings are load-bearing for whatever reads them next).
		return {"ok": false, "error": "no such item '%s' — try 'items'" % raw}
	return {"ok": true, "value": id}


func _parse_enemy_id(raw: String, _spec: Dictionary) -> Dictionary:
	var enemy_world: Node = get_node_or_null(^"/root/EnemyWorld")
	var id := StringName(raw)
	if enemy_world == null or not bool(enemy_world.call("has_def", id)):
		return {"ok": false, "error": "no such enemy '%s' — try 'enemies'" % raw}
	return {"ok": true, "value": id}


## Validated against RuleService rather than Registry — the Registry knows which RuleDefs were
## AUTHORED, but a rule only exists as something you can read or set once the service has seeded a
## live value for it (COMMANDS.md §4.2). Asking the service is therefore the honest check, and it is
## also what makes a harness that hand-instantiates RuleService alone still able to parse `rule`.
## Parsed here, RESOLVED later (COMMANDS.md §2.2: "resolves to an entity list at execution time, on
## the executing side"). Keeping those apart is what lets the host re-parse a client's raw line and
## resolve it against its OWN complete directory — a selector resolved on the client and shipped as a
## node list would be both untrustworthy and stale by the time it landed. The grammar itself lives in
## core/commands/entity_selector.gd, pure and node-free, so it is testable without a spawned entity.
func _parse_selector(raw: String, _spec: Dictionary) -> Dictionary:
	var parsed: Dictionary = EntitySelector.parse(raw)
	if not bool(parsed.get("ok", false)):
		return {"ok": false, "error": String(parsed.get("error", "bad selector"))}
	return {"ok": true, "value": parsed.get("selector", {})}


## COMMANDS.md §2.2's `vec3`: three floats, each optionally `~` (this coordinate, unchanged) or
## `~<offset>` (relative to it). Consumes THREE tokens where every other type consumes one, so it is
## handled ahead of the normal per-token loop in `_parse_args` rather than here — this function only
## ever sees one component, and `_parse_args` calls it three times with the issuer's own coordinate.
func _parse_vec3_component(raw: String, origin_component: float) -> Dictionary:
	if raw == "~":
		return {"ok": true, "value": origin_component}
	if raw.begins_with("~"):
		var offset: String = raw.substr(1)
		if not offset.is_valid_float() and not offset.is_valid_int():
			return {"ok": false, "error": "'%s' is not a relative offset" % raw}
		return {"ok": true, "value": origin_component + offset.to_float()}
	if not raw.is_valid_float() and not raw.is_valid_int():
		return {"ok": false, "error": "'%s' is not a coordinate" % raw}
	return {"ok": true, "value": raw.to_float()}


## Never reached — `vec3` is intercepted in `_parse_args`, which is the only place that can see the
## three tokens and the ctx a `~` needs. Registered anyway so the type table stays a complete
## description of what `type:` accepts, and so a spec naming it cannot silently fall through to
## `_parse_string` if that interception is ever refactored away.
func _parse_vec3(raw: String, _spec: Dictionary) -> Dictionary:
	return {"ok": false, "error": "'%s': vec3 wants three coordinates (x y z)" % raw}


## The shared body behind recipe_id/powerup_id/buildable_id/station_id/loot_table_id. Bound (not
## captured) per type — `Callable.bind()` appends its arguments AFTER the parser's own two, which is
## why the bound parameters trail `raw`/`spec` in the signature. Bound values, not a lambda closing
## over loop variables: F-107 is the scar for what the other spelling does here.
func _registry_parser(
	raw: String, _spec: Dictionary, has_method_name: StringName, label: String, listing_verb: String
) -> Dictionary:
	var registry: Node = get_node_or_null(^"/root/Registry")
	var id := StringName(raw)
	if registry == null or not bool(registry.call(has_method_name, id)):
		return {"ok": false, "error": "no such %s '%s' — try '%s'" % [label, raw, listing_verb]}
	return {"ok": true, "value": id}


func _parse_rule_id(raw: String, _spec: Dictionary) -> Dictionary:
	var rule_service: Node = get_node_or_null(^"/root/RuleService")
	var id := StringName(raw)
	if rule_service == null or not bool(rule_service.call("has_rule", id)):
		return {"ok": false, "error": "no such rule '%s' — try 'rules'" % raw}
	return {"ok": true, "value": id}


func _parse_function_id(raw: String, _spec: Dictionary) -> Dictionary:
	var id := StringName(raw)
	if not _functions.has(id):
		return {"ok": false, "error": "no such function '%s' — check content/functions/" % raw}
	return {"ok": true, "value": id}


## COMMANDS.md §2.2's full "peer id int or player display name" (F-157 built the registry this
## consumes — `NetTransport.display_names()` — after F-126 found the name half had nothing to resolve
## against, and D-098 closed F-126 without building it here). Deliberately does NOT require an INT to
## be a currently connected peer: `op` is the main caller, and an op grant has to survive exactly the
## reconnect gap D-035 describes (`_on_run_player_rebound`/`_on_run_player_expired` above) — refusing
## to op someone mid-reconnect, or pre-authorizing a peer id the host expects to join, would fight
## that on purpose. A NAME, by contrast, only ever resolves against who is connected right now — there
## is nothing to pre-authorize by name for a peer that has not joined and so has never submitted one.
func _parse_peer(raw: String, _spec: Dictionary) -> Dictionary:
	if raw.is_valid_int():
		var id: int = raw.to_int()
		if id <= 0:
			return {"ok": false, "error": "'%s' is not a valid peer id" % raw}
		return {"ok": true, "value": id}
	return _resolve_peer_by_name(raw)


## The name half of _parse_peer. Exact match, case-insensitive — a display name is a player-chosen
## label, not an identifier, so `op bob` should hit "Bob". Two connected peers may share a name (the
## registry does not dedupe — F-157), so an ambiguous match refuses rather than guessing which one was
## meant, the same "never guess" stance @r's random-pick is the one deliberate exception to elsewhere
## in this file.
func _resolve_peer_by_name(raw: String) -> Dictionary:
	var transport: Node = _transport()
	if transport == null:
		return {"ok": false, "error": "no peer named '%s'" % raw}
	var names: Dictionary = transport.call("display_names")
	var matches: Array[int] = []
	for id_v: Variant in names:
		if String(names[id_v]).nocasecmp_to(raw) == 0:
			matches.append(int(id_v))
	if matches.is_empty():
		return {"ok": false, "error": "no peer named '%s'" % raw}
	if matches.size() > 1:
		matches.sort()
		var id_list: PackedStringArray = PackedStringArray()
		for id: int in matches:
			id_list.append(str(id))
		return {"ok": false, "error": "'%s' matches more than one peer (%s) — use their peer id" % [
			raw, ", ".join(id_list)
		]}
	return {"ok": true, "value": matches[0]}


# ── Shared authority/lookup helpers (same shape as every other host service — dev_loadout.gd,
# enemy_world.gd — `_owns_*`) ────────────────────────────────────────────────────────────────────────


func _owns_execution() -> bool:
	var transport: Node = _transport()
	if transport == null:
		return true
	if bool(transport.call("is_host")):
		return true
	return not bool(transport.call("is_active")) and not bool(transport.call("is_connecting"))


func _local_peer_id() -> int:
	var transport: Node = _transport()
	if transport == null:
		return NetConfig.HOST_PEER_ID
	var peer_id: int = int(transport.call("local_peer_id"))
	return peer_id if peer_id > 0 else NetConfig.HOST_PEER_ID


## F-059's guard, same shape as every other host service's rpc_id() send: a peer that has already
## gone is still a valid dictionary key during D-035's grace window, but not a valid rpc_id() target.
func _peer_connected(peer_id: int) -> bool:
	var transport: Node = _transport()
	return transport != null and bool(transport.call("has_peer", peer_id))


func _body_for(peer_id: int) -> Node3D:
	var player_net: Node = get_node_or_null(^"/root/PlayerNet")
	if player_net == null:
		return null
	return player_net.call("player_for", peer_id)


func _transport() -> Node:
	if _transport_node == null or not is_instance_valid(_transport_node):
		_transport_node = get_node_or_null(^"/root/NetTransport")
	return _transport_node
