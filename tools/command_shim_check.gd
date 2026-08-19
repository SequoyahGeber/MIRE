extends SceneTree

## F-130's proposed regression guard, built. `f9cb6f7` ("CommandService front door: ... migrate
## every console command") missed three commands because they never referenced the autoload
## directly — they resolved `/root/DebugConsole` at runtime and invoked it by name:
##
##   var console: Node = get_node_or_null(^"/root/DebugConsole")
##   console.call("register", &"gfx", _cmd_gfx, "gfx [low|medium|high] | ...")
##
## so the command name never sits next to the method name in the source text, and
## `grep -rn 'DebugConsole.register('` cannot see it. `fps_cap`/`vsync` (task 3.16) and `gfx`
## (still open at the time this check was written — blocked on autoload/graphics_quality.gd being
## claimed by F-144) were the last three; the next one that gets written this way would slip past
## a name grep exactly the same way. This is a SOURCE-TEXT check for that reason — the whole point
## is to catch a call site a grep for the method name misses, so it matches on the reflection
## shape itself (`.call("register"` / `.call(&"register"`) rather than on `register` as an
## identifier.
##
##   .agent/bin/agent godot --script tools/command_shim_check.gd
##
## `autoload/debug_console.gd` is exempt — it is the shim's own implementation (`func register()`,
## docs/COMMANDS.md §2.1/§2.4) and is expected to exist there for as long as anything still calls
## it. Every other `.gd` file failing this check names a command still hanging off the
## deprecated path.

const SELF_PATH: String = "res://tools/command_shim_check.gd"
const SHIM_HOME: String = "res://autoload/debug_console.gd"
const SKIP_DIRS: Array[String] = ["res://addons", "res://.godot"]

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var scripts: Array[String] = []
	_walk("res://", scripts)
	scripts.sort()

	var re := RegEx.new()
	# `.call("register", ...)` or `.call(&"register", ...)` — the exact reflection shape the shim
	# invocation uses. The trailing comma (rather than just the closing quote) keeps this from
	# matching `.call("register_spec", ...)`, which is the migrated path and must not be flagged.
	re.compile("\\.call\\(\\s*&?\"register\"\\s*,")

	var hits: int = 0
	for path: String in scripts:
		if path == SHIM_HOME:
			continue
		var lines: PackedStringArray = FileAccess.get_file_as_string(path).split("\n")
		for i: int in lines.size():
			if re.search(lines[i]) == null:
				continue
			hits += 1
			fail(("%s:%d calls DebugConsole's register() shim by reflection — migrate to "
				+ "CommandService.register_spec() (docs/COMMANDS.md §2.1), the shape F-130 "
				+ "describes and this check exists to catch") % [path, i + 1])
	check(hits == 0, "no .gd file outside %s calls the register() shim by reflection (%d files scanned)"
		% [SHIM_HOME, scripts.size()])

	print("\nCOMMAND_SHIM_CHECK scripts=%d hits=%d failures=%d" % [scripts.size(), hits, failures])
	quit(0 if failures == 0 else 1)


func _walk(dir_path: String, found: Array[String]) -> void:
	for skip: String in SKIP_DIRS:
		if dir_path.begins_with(skip):
			return
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if entry.begins_with("."):
			entry = dir.get_next()
			continue
		var full: String = dir_path.path_join(entry)
		if dir.current_is_dir():
			_walk(full, found)
		elif entry.ends_with(".gd") and full != SELF_PATH:
			found.append(full)
		entry = dir.get_next()
	dir.list_dir_end()


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	fail(description)


func fail(description: String) -> void:
	failures += 1
	push_error("FAIL: %s" % description)
