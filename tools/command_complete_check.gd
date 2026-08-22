extends SceneTree

## F-534's guard: TAB completion in the dev console. Proves both halves — `CommandService.complete()`
## picking the right candidate set for the token under the caret, and `DebugConsole._complete()`
## rewriting the entry line the way readline would.
##
##   .agent/bin/agent godot --script tools/command_complete_check.gd
##
## Drives the real console UI through reflection (`_entry`, `_complete`, `_output`) for the same
## reason `tools/command_console_check.gd` does, and keeps `console` a plain `Node` for the same
## compile-chain reason its header explains.

var failures: int = 0
var console: Node
var command_service: Node


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame  # DebugConsole's builtins register one idle frame deferred — see its _ready().

	console = root.get_node_or_null(^"DebugConsole")
	command_service = root.get_node_or_null(^"CommandService")
	check(console != null, "DebugConsole autoload exists")
	check(command_service != null, "CommandService autoload exists")
	if console == null or command_service == null:
		finish()
		return

	_check_command_names()
	_check_argument_types()
	_check_peer_completion()
	_check_vec3_does_not_shift_the_argument_count()
	_check_entry_rewrite()

	print("\nCOMMAND_COMPLETE_CHECK failures=%d" % failures)
	finish()


func _candidates(line: String) -> PackedStringArray:
	var result: Dictionary = command_service.call("complete", line, line.length())
	return result.get("candidates", PackedStringArray())


func _start(line: String) -> int:
	var result: Dictionary = command_service.call("complete", line, line.length())
	return int(result.get("start", -1))


func _check_command_names() -> void:
	print("\n== the first token completes against registered command names ==")
	var all_names: PackedStringArray = _candidates("")
	check(all_names.has("help") and all_names.has("give"),
		"an empty line offers every command: %d candidate(s)" % all_names.size())

	var prefixed: PackedStringArray = _candidates("he")
	check(prefixed.has("help"), "`he` reaches `help`: %s" % ", ".join(prefixed))
	check(not prefixed.has("give"), "`he` does NOT offer unrelated commands: %s" % ", ".join(prefixed))
	check(_start("he") == 0, "the token to replace starts at column 0")

	check(_candidates("zzz").is_empty(), "an unmatched prefix offers nothing rather than everything")


func _check_argument_types() -> void:
	print("\n== later tokens complete against the TYPE of the argument they land on ==")
	var items: PackedStringArray = _candidates("give bra")
	check(items.has("branch"), "`give bra` reaches the item id `branch`: %s" % ", ".join(items))
	check(_start("give bra") == 5, "the token to replace starts after `give `, at column 5")

	var rules: PackedStringArray = _candidates("rule ")
	check(not rules.is_empty(), "`rule ` offers rule ids: %d candidate(s)" % rules.size())

	var bools: PackedStringArray = _candidates("log dev ")
	check(bools.has("on") and bools.has("off"),
		"a bool argument offers on/off: %s" % ", ".join(bools))

	check(_candidates("help ").is_empty(), "a command that takes no arguments offers nothing")


func _check_peer_completion() -> void:
	print("\n== `op <TAB>` — the case F-534 was filed for ==")
	var transport: Node = root.get_node_or_null(^"NetTransport")
	check(transport != null, "NetTransport autoload exists")
	if transport == null:
		return

	# Offline there is nobody connected, so plant the registry entries the completion reads. This is
	# the same dictionary `_parse_peer` resolves names against (F-157), so what it offers here is
	# exactly what it would offer in a live session.
	var names: Dictionary = {7: "Bob", 12: "Ada Lovelace"}
	transport.set("_display_names", names)

	var peers: PackedStringArray = _candidates("op ")
	check(peers.has("Bob") and peers.has("7"),
		"both the display name and the peer id are offered: %s" % ", ".join(peers))
	check(peers.has("12") and not peers.has("Ada Lovelace"),
		("a name with a space cannot survive the console's token split, so only that peer's id is "
			+ "offered: %s") % ", ".join(peers))

	var cased: PackedStringArray = _candidates("op bo")
	check(cased.has("Bob"),
		("completion is case-insensitive, matching what `_parse_peer` itself accepts: %s")
			% ", ".join(cased))

	transport.set("_display_names", {})


func _check_vec3_does_not_shift_the_argument_count() -> void:
	print("\n== a vec3 argument eats three tokens without skewing which argument the caret is on ==")
	command_service.call("register_spec", &"_complete_probe", {
		"scope": &"local",
		"args": [
			{"name": "where", "type": &"vec3"},
			{"name": "what", "type": &"item_id"},
		],
		"handler": func(_ctx: Dictionary, _args: Dictionary) -> Dictionary:
			return {"ok": true, "message": "", "data": {}},
		"help": "_complete_probe — completion test fixture",
	})

	check(_candidates("_complete_probe 1 2 3 bra").has("branch"),
		"the token after all three coordinates completes as the item id it is")
	check(_candidates("_complete_probe 1 bra").is_empty(),
		"a token still inside the vec3 does not complete as the item id that follows it")


func _check_entry_rewrite() -> void:
	print("\n== the console rewrites its entry line the way readline would ==")
	var entry: LineEdit = console.get("_entry")

	entry.text = "hel"
	entry.caret_column = 3
	console.call("_complete")
	check(entry.text == "help ", "one candidate completes and adds the separating space: '%s'" % entry.text)
	check(entry.caret_column == 5, "the caret lands after the inserted space (%d)" % entry.caret_column)

	entry.text = "zzz"
	entry.caret_column = 3
	console.call("_complete")
	check(entry.text == "zzz", "no candidates leaves the line untouched: '%s'" % entry.text)

	# `kil` matches both `kill` and `killall`, so TAB advances to their shared prefix and stops.
	entry.text = "kil"
	entry.caret_column = 3
	console.call("_complete")
	check(entry.text == "kill",
		"several candidates advance to the common prefix without committing to one: '%s'" % entry.text)

	var output: RichTextLabel = console.get("_output")
	check(output.get_parsed_text().contains("killall"),
		"the ambiguous set is printed so you can see what you are choosing between")

	# Completing mid-line leaves the tail alone — the caret is what decides the token, not the end.
	entry.text = "give bra 5"
	entry.caret_column = 8
	console.call("_complete")
	check(entry.text == "give branch 5",
		("a completion in the middle of a line keeps the text after the caret, and does not double "
			+ "the space that is already there: '%s'") % entry.text)

	entry.clear()


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
