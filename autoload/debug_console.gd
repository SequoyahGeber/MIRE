extends CanvasLayer

## Drop-down developer console. `~` (backtick) toggles it.
##
## Network authority: CLIENT-LOCAL presentation over CommandService's own authority row
## (docs/ARCHITECTURE.md §2.2, "Command execution"). This file is a thin client since task 3.13:
## it builds a CommandCtx, forwards the typed line to CommandService, and prints whatever
## CommandResult comes back. It no longer decides what may mutate host state or how — that is
## CommandService's job, uniformly, for every source (console, headless runner, functions, hooks).
##
## Autoload — builds its own UI in code, so there is no scene to wire. `register()` below is a
## **deprecated compatibility shim** kept so nothing that already calls it breaks; new commands
## should call `CommandService.register_spec()` directly (docs/COMMANDS.md §2.1/§2.4).
##
## LOAD ORDER: CommandService registers right after this autoload (project.godot), so it does not
## exist yet during THIS file's own `_ready()`. `_register_builtins()` is deferred one idle frame
## for exactly that reason — see its comment. Every autoload after CommandService in the list can
## register into it synchronously in their own `_ready()`, same as before.

const MAX_OUTPUT_LINES: int = 300
const HISTORY_LIMIT: int = 50

## Pausing while the console is open stops WASD from driving the player while you type, without the
## console needing to know anything about the player. Turn it off to debug things that need to keep
## running — a Mire tick, a wave timer.
@export var pause_while_open: bool = true

var is_open: bool = false

var _history: Array[String] = []
var _history_index: int = -1
var _root: Control
var _output: RichTextLabel
var _entry: LineEdit
var _restore_mouse_captured: bool = false
## Handles this console itself submitted, so `_on_command_result` only prints results for lines
## someone actually typed here — nothing else listens to CommandService's `command_result` today, but
## the guard costs nothing and stops that being an assumption.
var _pending_handles: Dictionary[int, bool] = {}
var _command_service_connected: bool = false
## Handles this console unpaused the tree FOR — see the comment in `_run()`. Re-paused once this set
## drains back to empty and the console is still open.
var _unpaused_for_handles: Dictionary[int, bool] = {}


func _ready() -> void:
	layer = 101
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	# CommandService loads right after this autoload (project.godot order), so it does not exist yet
	# during this _ready(). call_deferred runs at the end of THIS frame, after every autoload's own
	# _ready() (including CommandService's) has already completed, so by the time it fires the
	# service is there. Nothing else in this file depends on the builtins being registered
	# synchronously — a command typed before the deferred call runs would just see "unknown command"
	# for a single frame, which cannot happen: input is not processed until the tree is idle either.
	_register_builtins.call_deferred()

	MireLog.add_sink(_on_log_line)
	for line: String in MireLog.history():
		_print_line(line)


func _build_ui() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_root.anchor_bottom = 0.45
	_root.visible = false
	add_child(_root)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(panel)

	var box := VBoxContainer.new()
	panel.add_child(box)

	_output = RichTextLabel.new()
	_output.bbcode_enabled = true
	_output.scroll_following = true
	_output.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(_output)

	_entry = LineEdit.new()
	_entry.placeholder_text = "command — try `help`"
	_entry.caret_blink = true
	_entry.text_submitted.connect(_on_submitted)
	box.add_child(_entry)


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.is_pressed() and not event.is_echo():
		var key: InputEventKey = event
		# QUOTELEFT is the `~`/backtick key. Read raw rather than through an input action so the
		# console works before the input map exists, and stays out of the player's keybinds.
		if key.keycode == KEY_QUOTELEFT:
			toggle()
			get_viewport().set_input_as_handled()
			return
		if is_open and key.keycode == KEY_ESCAPE:
			toggle()
			get_viewport().set_input_as_handled()
			return
		if is_open and (key.keycode == KEY_UP or key.keycode == KEY_DOWN):
			_recall_history(-1 if key.keycode == KEY_UP else 1)
			get_viewport().set_input_as_handled()


func toggle() -> void:
	set_open(not is_open)


func set_open(open: bool) -> void:
	if open == is_open:
		return
	is_open = open
	_root.visible = open

	if open:
		_restore_mouse_captured = Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_entry.clear()
		_entry.grab_focus()
	else:
		_entry.release_focus()
		if _restore_mouse_captured:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	if pause_while_open:
		get_tree().paused = open


## The pre-3.13 `register()`/`unregister()` deprecation shim lived here until F-130 closed: its
## last caller (`gfx`) migrated to `CommandService.register_spec()`, and
## `tools/command_shim_check.gd` fails the build if a new reflection caller ever appears — so the
## compat path is deleted rather than kept as dead weight. If you are reading this because you
## wanted `register()`: register a typed spec instead, docs/COMMANDS.md §2.1.


func _on_submitted(text: String) -> void:
	_entry.clear()

	var line: String = text.strip_edges()
	if line.is_empty():
		return

	_history.append(line)
	if _history.size() > HISTORY_LIMIT:
		_history.remove_at(0)
	_history_index = -1

	_print_line("[color=#8cf]> %s[/color]" % line)
	_run(line)


## Submits through CommandService and prints whatever CommandResult eventually comes back —
## synchronously for a LOCAL command or a HOST command typed on the host, after a real RPC round trip
## for a HOST command typed on a client. `submit()` + `command_result` rather than `await execute()`
## directly: this file only ever holds CommandService through `get_node_or_null().call()`, and
## awaiting a coroutine through that dynamic dispatch is not a pattern anything else in this codebase
## relies on, so this does not either (see command_service.gd's file header).
func _run(line: String) -> void:
	var command_service: Node = get_node_or_null(^"/root/CommandService")
	if command_service == null:
		_print_line("[color=#f77]CommandService unavailable[/color]")
		return
	if not _command_service_connected:
		command_service.connect(&"command_result", _on_command_result)
		_command_service_connected = true

	var ctx: Dictionary = command_service.call("build_local_ctx", &"console")
	var handle: int = int(command_service.call("submit", line, ctx))
	_pending_handles[handle] = true

	# COMMANDS.md §10's wrinkle, MEASURED rather than assumed: tools/command_net_check.gd proved a
	# client's HOST-scope submission never gets its `net_command_result` reply while this tree stays
	# paused — the request reaches the host fine, the host executes it and sends the reply, but the
	# reply never resumes this process's own awaiting coroutine until something unpauses it. So:
	# unpause for exactly as long as a request from THIS console is in flight, and re-pause once
	# every such request has resolved (see `_on_command_result`). A LOCAL command never leaves this
	# process, so it resolves inside `submit()` above before this line even runs — nothing to unpause
	# for. Filed as D-076 (docs/DECISIONS.md).
	if pause_while_open and get_tree().paused:
		get_tree().paused = false
		_unpaused_for_handles[handle] = true


func _on_command_result(handle: int, result: Dictionary) -> void:
	if _unpaused_for_handles.erase(handle) and _unpaused_for_handles.is_empty() \
			and is_open and pause_while_open:
		get_tree().paused = true

	if not _pending_handles.has(handle):
		return
	_pending_handles.erase(handle)
	var message: String = String(result.get("message", ""))
	if message.is_empty():
		return
	if bool(result.get("ok", true)):
		_print_line(message)
	else:
		_print_line("[color=#f77]%s[/color]" % message)


func _recall_history(direction: int) -> void:
	if _history.is_empty():
		return

	if _history_index == -1:
		_history_index = _history.size()
	_history_index = clampi(_history_index + direction, 0, _history.size())

	if _history_index >= _history.size():
		_entry.clear()
	else:
		_entry.text = _history[_history_index]
	_entry.caret_column = _entry.text.length()


func _on_log_line(line: String, level: MireLog.Level) -> void:
	var colour: String = "ccc"
	if level == MireLog.Level.ERROR:
		colour = "f77"
	elif level == MireLog.Level.WARN:
		colour = "fd7"
	_print_line("[color=#%s]%s[/color]" % [colour, line])


func _print_line(line: String) -> void:
	_output.append_text(line + "\n")
	if _output.get_paragraph_count() > MAX_OUTPUT_LINES:
		_output.remove_paragraph(0)


## Real CommandSpecs, registered directly against CommandService — these are the "console builtins"
## docs/COMMANDS.md §2.4 names as part of 3.13's migration. `commands`/`op`/`deop` live on
## CommandService itself (COMMANDS.md §7's Meta row is split: the ones that need no console-specific
## state are meta commands there; `help`/`clear`/`overlay`/`quit`/`log`/`channels` stay here because
## they reach into this console's own UI or MireLog directly).
func _register_builtins() -> void:
	var command_service: Node = get_node_or_null(^"/root/CommandService")
	if command_service == null:
		MireLog.error(&"dev", "DebugConsole: CommandService never appeared — builtins not registered")
		return

	command_service.call("register_spec", &"help", {
		"scope": &"local", "args": [], "handler": _cmd_help, "help": "help — list commands",
	})
	command_service.call("register_spec", &"clear", {
		"scope": &"local", "args": [], "handler": _cmd_clear,
		"help": "clear — wipe the console output",
	})
	command_service.call("register_spec", &"channels", {
		"scope": &"local", "args": [], "handler": _cmd_channels,
		"help": "channels — show log channel states",
	})
	command_service.call("register_spec", &"log", {
		"scope": &"local",
		"args": [
			{"name": "channel", "type": &"string"},
			{"name": "state", "type": &"bool"},
		],
		"handler": _cmd_log,
		"help": "log <channel> <on|off> — toggle a log channel",
	})
	command_service.call("register_spec", &"overlay", {
		"scope": &"local", "args": [], "handler": _cmd_overlay,
		"help": "overlay — cycle the debug overlay",
	})
	command_service.call("register_spec", &"quit", {
		"scope": &"local", "args": [], "handler": _cmd_quit, "help": "quit — close the game",
	})


func _cmd_help(_ctx: Dictionary, _args: Dictionary) -> Dictionary:
	var command_service: Node = get_node_or_null(^"/root/CommandService")
	if command_service == null:
		return {"ok": true, "message": "", "data": {}}
	var names: Array = command_service.call("spec_names")
	var lines: Array[String] = []
	for command_name: Variant in names:
		lines.append("  " + String(command_service.call("help_text", command_name)))
	return {"ok": true, "message": "\n".join(lines), "data": {}}


func _cmd_clear(_ctx: Dictionary, _args: Dictionary) -> Dictionary:
	_output.clear()
	return {"ok": true, "message": "", "data": {}}


func _cmd_channels(_ctx: Dictionary, _args: Dictionary) -> Dictionary:
	var lines: Array[String] = []
	var states: Dictionary[StringName, bool] = MireLog.channel_states()
	for channel: StringName in states:
		lines.append("  %-3s  %s" % ["on" if states[channel] else "off", channel])
	return {"ok": true, "message": "\n".join(lines), "data": {}}


func _cmd_log(_ctx: Dictionary, args: Dictionary) -> Dictionary:
	var channel: String = String(args.get("channel", ""))
	var enabled: bool = bool(args.get("state", false))
	if not MireLog.set_enabled(StringName(channel), enabled):
		return {"ok": false, "message": "no such channel: %s" % channel, "data": {}}
	return {"ok": true, "message": "%s -> %s" % [channel, "on" if enabled else "off"], "data": {}}


func _cmd_overlay(_ctx: Dictionary, _args: Dictionary) -> Dictionary:
	DebugOverlay.cycle_mode()
	return {"ok": true, "message": "", "data": {}}


func _cmd_quit(_ctx: Dictionary, _args: Dictionary) -> Dictionary:
	get_tree().quit()
	return {"ok": true, "message": "", "data": {}}
