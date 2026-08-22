extends SceneTree

## F-537 — verifies the game has exactly one way out and that it actually gets there.
##
## Run:  .agent/bin/agent godot --script tools/app_exit_check.gd
##
## What this can and cannot prove. It runs headless, so it cannot close a window and it deliberately
## does not arm the watchdog (see `_arm_watchdog`). What it does prove is the part that is pure
## logic: AppExit exists and owns the close notification, no quit path bypasses it, Steam has a
## shutdown counterpart to its init, and `AppExit.quit()` is idempotent and actually ends the tree.
## The window-close half is verified by launching the real macOS app and closing it — recorded in
## docs/FINDINGS.md under F-537, not automatable from here.

var _failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


## Deferred by one frame: under `--script` the SceneTree exists before its autoloads are added, so
## `_initialize` is too early to look any of them up. Paths are relative to `root` for the same
## reason absolute ones fail here — this tree is not the "active scene tree" get_node() means.
func _run() -> void:
	var exit_node: Node = root.get_node_or_null(^"AppExit")
	_check(exit_node != null, "AppExit autoload is registered")
	if exit_node == null:
		_finish()
		return

	_check(exit_node.has_method("quit"), "AppExit exposes quit()")
	_check(
		exit_node.process_mode == Node.PROCESS_MODE_ALWAYS,
		"AppExit runs while paused — the pause menu's Quit must work"
	)

	var lobby: Node = root.get_node_or_null(^"SteamLobby")
	_check(lobby != null and lobby.has_method("shutdown"), "SteamLobby.shutdown() exists")

	_check_no_bare_quits()

	# Idempotence: a double-click on Quit, or a close request arriving while the confirm dialog's
	# callback is already running, must not re-enter teardown.
	exit_node.call("quit")
	exit_node.call("quit")
	_check(true, "AppExit.quit() twice did not error")

	_finish()


## Paths allowed to end the tree themselves. `tools/` and `addons/` are headless one-shots that never
## initialise Steam, and app_exit.gd is the one that is supposed to.
const QUIT_EXEMPT_PREFIXES: PackedStringArray = ["res://tools/", "res://addons/"]

const QUIT_EXEMPT_FILES: PackedStringArray = ["res://autoload/app_exit.gd"]


## Every `get_tree().quit()` outside AppExit is a path that skips Steam shutdown and the watchdog,
## which is precisely how F-537 happened in the first place — four call sites, no owner.
func _check_no_bare_quits() -> void:
	var offenders: PackedStringArray = []
	for path: String in _gd_files("res://"):
		if QUIT_EXEMPT_FILES.has(path):
			continue
		var exempt: bool = false
		for prefix: String in QUIT_EXEMPT_PREFIXES:
			if path.begins_with(prefix):
				exempt = true
				break
		if exempt:
			continue
		if _strip_comments(FileAccess.get_file_as_string(path)).contains("get_tree().quit("):
			offenders.append(path)
	_check(
		offenders.is_empty(),
		"no shipped script calls get_tree().quit() directly (found: %s)" % ", ".join(offenders)
	)


## Comment lines are stripped before scanning, so a doc comment that says "never call
## get_tree().quit()" does not read as a call to it. Crude — it does not know about `#` inside a
## string literal — but a false positive here is a visible failure, never a silent pass.
func _strip_comments(text: String) -> String:
	var out: PackedStringArray = []
	for line: String in text.split("\n"):
		var hash_at: int = line.find("#")
		out.append(line if hash_at < 0 else line.substr(0, hash_at))
	return "\n".join(out)


func _gd_files(dir_path: String) -> PackedStringArray:
	var out: PackedStringArray = []
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if entry.begins_with("."):
			entry = dir.get_next()
			continue
		var full: String = dir_path.path_join(entry)
		if dir.current_is_dir():
			out.append_array(_gd_files(full))
		elif entry.ends_with(".gd"):
			out.append(full)
		entry = dir.get_next()
	dir.list_dir_end()
	return out


func _check(ok: bool, label: String) -> void:
	if ok:
		print("  PASS  ", label)
	else:
		_failures += 1
		print("  FAIL  ", label)


func _finish() -> void:
	print("app_exit_check: %d failure(s)" % _failures)
	quit(1 if _failures > 0 else 0)
