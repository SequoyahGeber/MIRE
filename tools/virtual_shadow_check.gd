extends SceneTree

## Does any script in this project define a method the ENGINE will call behind its back?
##
## F-421. `ui/frontend/frontend.gd` had a private helper called `_enter_world()` meaning "go into
## the game world". `Node3D` has an engine virtual of exactly that name, fired on
## NOTIFICATION_ENTER_WORLD — before `_enter_tree()`, long before `_ready()`. So the method was not
## private at all: Godot called it the moment the node entered the 3D world. It happened inside
## `SceneTree::_flush_scene_change()` during QUIT TO TITLE, the body asked for ANOTHER scene change
## from inside the one already running, and the process died with SIGSEGV every single time. Nobody
## had ever seen the title screen, and the crash carried no GDScript frames at all, so it read as an
## engine bug for as long as anyone looked at it.
##
## Nothing warns you about this. `ClassDB.class_has_method("Node3D", "_enter_world")` is FALSE and
## the method is absent from `class_get_method_list` — the virtual is invisible to reflection, so
## neither the editor's autocomplete nor a ClassDB-based lint can see the collision. The only way to
## find out is to ask the engine: define the name on the base class, put it in a tree, and see
## whether it fires on its own.
##
## That is what this does. For every `extends <EngineClass>` script in the project it collects the
## zero-argument `func _name()` definitions, builds a throwaway script that declares the same name on
## the same base, adds it to the tree, and checks whether the engine called it uninvited. Names
## ClassDB already knows (`_ready`, `_process`, `_input`, …) are expected to fire and are ignored —
## an INVISIBLE virtual firing is the defect.
##
## Authority: none (docs/ARCHITECTURE.md §2.2). Static/dynamic analysis only.
##
##   .agent/bin/agent godot --script tools/virtual_shadow_check.gd
##
## LIMITATION, stated rather than hidden: only zero-argument methods are probed, because a virtual is
## only called when the arity matches and guessing argument lists would produce false negatives
## dressed as passes. That covers the whole lifecycle family this trap lives in.

const SKIP_DIRS: PackedStringArray = ["res://addons", "res://.godot"]

## Probed on every run whether or not the project uses it. If the engine STOPS calling this, the
## check has quietly become a no-op that passes for the wrong reason, and it says so instead.
const CONTROL_BASE: String = "Node3D"
const CONTROL_METHOD: String = "_enter_world"

var _failures: Array[String] = []


func _initialize() -> void:
	_run()


func _run() -> void:
	print("Engine-virtual shadowing check (F-421)\n")

	if not await _fires(CONTROL_BASE, CONTROL_METHOD):
		print("✗ SELF-TEST FAILED: the engine no longer calls %s.%s(), so this check can no longer"
			% [CONTROL_BASE, CONTROL_METHOD])
		print("  detect anything. Fix the check before trusting a pass from it.")
		quit(1)
		return
	print("· self-test ok — %s.%s() still fires uninvited, so the probe works\n"
		% [CONTROL_BASE, CONTROL_METHOD])

	var candidates: Dictionary = _collect()
	var probed: int = 0
	for base: String in candidates:
		for method: String in candidates[base]:
			probed += 1
			if await _fires(base, method):
				for path: String in (candidates[base][method] as PackedStringArray):
					_failures.append("%s defines %s(), which %s calls on its own"
						% [path, method, base])

	print("probed %d name(s) across %d engine base class(es)\n" % [probed, candidates.size()])
	if _failures.is_empty():
		print("✓ no script shadows an engine virtual")
		quit(0)
		return
	for failure: String in _failures:
		print("✗ %s" % failure)
	print("\nRename the method. A leading underscore does NOT make it private — the engine owns")
	print("that name, and it will be called at a moment you did not choose.")
	quit(1)


## base -> method -> the scripts that define it.
func _collect() -> Dictionary:
	var found: Dictionary = {}
	var known: Dictionary = {}
	for path: String in _scripts("res://"):
		var text: String = FileAccess.get_file_as_string(path)
		if text.is_empty():
			continue
		var base: String = _engine_base(text)
		if base.is_empty():
			continue
		if not known.has(base):
			known[base] = _classdb_methods(base)
		for method: String in _zero_arg_underscore_methods(text):
			if (known[base] as PackedStringArray).has(method):
				continue                      # a real, documented virtual — overriding it is the point
			if not found.has(base):
				found[base] = {}
			if not found[base].has(method):
				found[base][method] = PackedStringArray()
			var users: PackedStringArray = found[base][method]
			users.append(path)
			found[base][method] = users
	return found


## Declares `method` on `base`, puts it in the tree, and reports whether the engine called it.
func _fires(base: String, method: String) -> bool:
	if not ClassDB.class_exists(base) or not ClassDB.can_instantiate(base):
		return false
	var script := GDScript.new()
	script.source_code = ("extends %s\n\nvar fired: bool = false\n\n\nfunc %s() -> void:\n\tfired = true\n"
		% [base, method])
	if script.reload() != OK:
		return false
	var probe: Object = ClassDB.instantiate(base)
	if probe == null:
		return false
	if not (probe is Node):
		# A RefCounted drops on its own; a bare Object has to be freed by hand.
		if not (probe is RefCounted):
			probe.free()
		return false
	var node: Node = probe
	node.set_script(script)
	root.add_child(node)
	await process_frame
	await process_frame
	var fired: bool = bool(node.get(&"fired"))
	# `free()` rather than `queue_free()`: this runs hundreds of times, and a Viewport- or
	# Window-derived probe holds real server RIDs until it is actually gone. Deferring them all to
	# one delete queue leaked 515 viewports and scenarios on the first run of this check.
	root.remove_child(node)
	node.free()
	return fired


## The `extends <Name>` of a script, when Name is an engine class. Scripts that extend another
## script (`extends "res://…"`) or a `class_name` are skipped: their base's virtuals are whatever
## THAT file's engine base already contributes, and it is checked on its own.
func _engine_base(text: String) -> String:
	for line: String in text.split("\n"):
		var trimmed: String = line.strip_edges()
		if trimmed.is_empty() or trimmed.begins_with("#"):
			continue
		if not trimmed.begins_with("extends "):
			return ""
		var name: String = trimmed.substr(8).strip_edges()
		return name if ClassDB.class_exists(name) else ""
	return ""


func _zero_arg_underscore_methods(text: String) -> PackedStringArray:
	var names := PackedStringArray()
	var re := RegEx.create_from_string("(?m)^func[ \\t]+(_[A-Za-z0-9_]*)\\(\\)")
	for m: RegExMatch in re.search_all(text):
		var name: String = m.get_string(1)
		if not names.has(name):
			names.append(name)
	return names


func _classdb_methods(base: String) -> PackedStringArray:
	var names := PackedStringArray()
	for m: Dictionary in ClassDB.class_get_method_list(base, false):
		names.append(String(m["name"]))
	return names


func _scripts(dir_path: String) -> PackedStringArray:
	var out := PackedStringArray()
	for skip: String in SKIP_DIRS:
		if dir_path.begins_with(skip):
			return out
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if not entry.begins_with("."):
			var full: String = dir_path.path_join(entry)
			if dir.current_is_dir():
				out.append_array(_scripts(full))
			elif entry.ends_with(".gd"):
				out.append(full)
		entry = dir.get_next()
	dir.list_dir_end()
	return out
