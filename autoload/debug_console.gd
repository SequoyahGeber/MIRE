extends CanvasLayer

## Drop-down developer console. `~` (backtick) toggles it.
##
## Network authority: CLIENT-LOCAL. Commands run on the machine that typed them. A command that
## needs to change authoritative state must go through the same RPC path as gameplay — never add a
## command here that mutates host state directly, or the console becomes a desync generator.
##
## Autoload — builds its own UI in code, so there is no scene to wire. Register commands from
## anywhere, ideally in the owning system's _ready():
##
##     DebugConsole.register(&"give", _cmd_give, "give <item_id> [count]")

const MAX_OUTPUT_LINES: int = 300
const HISTORY_LIMIT: int = 50

## Pausing while the console is open stops WASD from driving the player while you type, without the
## console needing to know anything about the player. Turn it off to debug things that need to keep
## running — a Mire tick, a wave timer.
@export var pause_while_open: bool = true

var is_open: bool = false

var _commands: Dictionary[StringName, Callable] = {}
var _help: Dictionary[StringName, String] = {}
var _history: Array[String] = []
var _history_index: int = -1
var _root: Control
var _output: RichTextLabel
var _entry: LineEdit
var _restore_mouse_captured: bool = false


func _ready() -> void:
	layer = 101
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	_register_builtins()

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


## Register a console command. The callable receives one argument: PackedStringArray of arguments,
## already split, excluding the command name itself. Return a String to have it echoed.
func register(command: StringName, callable: Callable, usage: String = "") -> void:
	_commands[command] = callable
	_help[command] = usage


func unregister(command: StringName) -> void:
	_commands.erase(command)
	_help.erase(command)


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


func _run(line: String) -> void:
	var parts: PackedStringArray = line.split(" ", false)
	var command := StringName(parts[0])
	if not _commands.has(command):
		_print_line("[color=#f77]unknown command: %s[/color]" % command)
		return

	var args: PackedStringArray = parts.slice(1)
	var result: Variant = _commands[command].call(args)
	if result != null and str(result) != "":
		_print_line(str(result))


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


func _register_builtins() -> void:
	register(&"help", _cmd_help, "help — list commands")
	register(&"clear", _cmd_clear, "clear — wipe the console output")
	register(&"channels", _cmd_channels, "channels — show log channel states")
	register(&"log", _cmd_log, "log <channel> <on|off> — toggle a log channel")
	register(&"overlay", _cmd_overlay, "overlay — cycle the debug overlay")
	register(&"quit", _cmd_quit, "quit — close the game")


func _cmd_help(_args: PackedStringArray) -> String:
	var commands: Array[StringName] = []
	commands.assign(_help.keys())
	commands.sort()

	var lines: Array[String] = []
	for command: StringName in commands:
		lines.append("  " + (_help[command] if _help[command] != "" else String(command)))
	return "\n".join(lines)


func _cmd_clear(_args: PackedStringArray) -> String:
	_output.clear()
	return ""


func _cmd_channels(_args: PackedStringArray) -> String:
	var lines: Array[String] = []
	var states: Dictionary[StringName, bool] = MireLog.channel_states()
	for channel: StringName in states:
		lines.append("  %-3s  %s" % ["on" if states[channel] else "off", channel])
	return "\n".join(lines)


func _cmd_log(args: PackedStringArray) -> String:
	if args.size() < 2:
		return "usage: log <channel> <on|off>"
	var enabled: bool = args[1].to_lower() in ["on", "true", "1"]
	if not MireLog.set_enabled(StringName(args[0]), enabled):
		return "no such channel: %s" % args[0]
	return "%s -> %s" % [args[0], "on" if enabled else "off"]


func _cmd_overlay(_args: PackedStringArray) -> String:
	DebugOverlay.cycle_mode()
	return ""


func _cmd_quit(_args: PackedStringArray) -> String:
	get_tree().quit()
	return ""
