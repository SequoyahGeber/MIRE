extends SceneTree

## F-291's project-wide sweep. A `--script` check that fires a real `EventBus` event purely as a
## state-setup shortcut can be silently broken later by an unrelated feature that subscribes to that
## same event and *latches* — joins `blocks_gameplay_input` and stays there until a reset event.
##
##   .agent/bin/agent godot --script tools/blocking_ui_event_check.gd
##
## The worked case: `tools/unlock_check.gd` emitted `run_extracted` twice just to top up
## `SalvageService`'s balance. That was correct when 6.9/F-173 wrote it — nothing subscribed. F-238
## then gave `ui/hud/extraction_hud.gd` a `run_extracted` handler that shows a terminal overlay and
## joins `blocks_gameplay_input` "until the run itself resets", so from that emit onward D-032's
## interlock turned every `set_open(true)` into a no-op and three unrelated menu assertions failed.
## Nothing about unlocks had regressed; the check was broken by a feature it had never heard of.
##
## SOURCE-TEXT check, like `tools/findings_numbering_check.gd` and `tools/net_check_pattern_check.gd`
## — it reads scripts rather than booting a world. That is deliberate and is what makes it a *sweep*
## rather than a reproduction: a running game can only ever demonstrate one such pairing at a time,
## and the point is to catch the pairing before someone runs the check that would fail.
##
## ## What it derives, and why nothing here is hard-coded
##
## Hard-coding the latching events is exactly the failure mode being guarded against — F-238 added a
## latching subscriber to an event that had none, and a hand-maintained list would not have grown to
## include it. So both halves are re-derived on every run:
##
##   1. Shipped scripts under `SHIPPED_DIRS` that reference `BLOCKING_UI_GROUP`. For each, map every
##      `EVENT_BUS.subscribe_<event>(<handler>)` onto that handler's body, and classify the event as
##      LATCHING if the body calls `add_to_group(BLOCKING_UI_GROUP)` or RELEASING if it calls
##      `remove_from_group(BLOCKING_UI_GROUP)`. An event whose handler does neither is neutral and is
##      not tracked — `salvage_banked`, subscribed by both terminal HUDs, is one of these.
##   2. Every `tools/*_check.gd`, walked in **call order** rather than text order (see below). An
##      `emit_<latching>` opens a window, an `emit_<releasing>` closes it, and touching latch-
##      sensitive state (`BLOCKING_UI_GROUP`, `set_open(`, `gameplay_input_allowed`, …) inside an
##      open window must be acknowledged.
##
## ## Call order, not text order
##
## This is not a cosmetic detail — it is the difference between passing and failing the one check
## F-291 already fixed. `unlock_check.gd` emits its reset at line 103 inside `_run()`, and the two
## shortcut emits it is resetting live at lines 227 and 274, inside helpers `_run()` calls *before*
## that line. Read top to bottom the file looks broken; executed, it is correct. So the walk starts
## at the entry function and expands calls to local `_helpers()` in place, depth-first. Any function
## the walk never reaches is then walked as its own entry with a fresh window, because in these
## checks an unreached function is normally a second-process probe body dispatched by argv
## (`terminal_focus_check.gd`'s `_run_client`/`_run_orphan_client`) rather than dead code.
##
## ## What is NOT flagged, deliberately
##
## Emitting a latching event is not itself a defect and must never be treated as one: F-310 wants
## MORE checks driving real producers, and thirty-odd checks emit these events because the fan-out IS
## their subject. The defect is only ever the *pairing* — a latch left standing under later work that
## a latch changes the meaning of.
##
## Nor can source text tell an assertion that *depends* on the latch being absent from one that
## *proves* the latch is doing its job: `terminal_focus_check.gd` deliberately calls `set_open(true)`
## under a live overlay to assert D-032 refuses it, which is the correct thing to check and looks
## identical to `unlock_check.gd`'s bug. Guessing between them would either miss the bug or fail a
## correct check forever, so this does neither and asks instead: a latch-sensitive line under an open
## window needs a `latch-ok:` marker with a reason, on that line or the one above it. That is the
## convention half of F-291's "worth a lint/convention" — the author who wrote the emit records that
## they knew what it does, and the next author to add a shortcut emit is made to think once.
##
## The fix a failure asks for, in preference order: call the service directly
## (`SalvageService.host_add`-style) rather than emitting a bus event with cross-system fan-out; or
## emit the real reset path afterwards, never a test-only workaround and never `remove_from_group` by
## hand on someone else's node; or, if the latch is the point, mark the line and say why.
##
## Comment handling is blunt: everything from the first `#` is dropped before matching (after the
## marker is looked for), so this file's own prose does not trip it. A `#` inside a string literal
## would truncate that line early; no shipped check has one, and a missed line is a false negative in
## a tripwire, not a false failure in a gate.

const SHIPPED_DIRS: PackedStringArray = ["res://ui", "res://autoload", "res://systems", "res://entities", "res://world"]
const TOOLS_DIR: String = "res://tools"
const GROUP_TOKEN: String = "BLOCKING_UI_GROUP"
const MARKER: String = "latch-ok:"
const MAX_DEPTH: int = 12

## Entry points tried in order. These checks are `SceneTree` scripts, so `_initialize()` is the real
## one, but almost all of them defer immediately into `_run()`/`_start()` and the deferred call is
## not a syntactic call this walk can follow.
const ENTRY_NAMES: PackedStringArray = ["_run", "_start", "_initialize"]

## Lines whose meaning a standing latch changes. `set_open` covers every shipped menu's open path,
## since D-032's interlock lives inside it; the rest are the group itself and the predicate that
## reads it. Matched bare rather than as `set_open(` on purpose — these checks reach menus through
## `menu.call(&"set_open", true)` far more often than through a direct call, and the paren form
## missed every one of those.
const LATCH_SENSITIVE: PackedStringArray = [
	GROUP_TOKEN,
	"blocks_gameplay_input",
	"set_open",
	"gameplay_input_allowed",
	"_other_blocking_ui_open",
]

var failures: int = 0

## event name -> Array[String] of "file.gd:_handler" that latch on / release it.
var latching: Dictionary = {}
var releasing: Dictionary = {}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	for dir in SHIPPED_DIRS:
		for path in _gd_files(dir):
			_scan_shipped(path)

	if latching.is_empty():
		fail("derived no latching events at all — the `EVENT_BUS.subscribe_*` or "
			+ "`add_to_group(%s)` spelling this parses must have changed, and a sweep " % GROUP_TOKEN
			+ "that derives nothing passes everything. Fix the parser, do not delete the check")
		_finish(0, 0, 0)
		return

	print("latching events (an emit opens a window):")
	for event in _sorted_keys(latching):
		print("  %-24s %s" % [event, ", ".join(latching[event])])
	print("releasing events (an emit closes it):")
	for event in _sorted_keys(releasing):
		print("  %-24s %s" % [event, ", ".join(releasing[event])])
	print("")

	var scanned: int = 0
	var acknowledged: int = 0
	for path in _gd_files(TOOLS_DIR):
		if not path.ends_with("_check.gd"):
			continue
		if path.ends_with("blocking_ui_event_check.gd"):
			continue
		scanned += 1
		acknowledged += _scan_check(path)
	_finish(scanned, acknowledged, failures)


# --- deriving the latching set from shipped code ----------------------------------------------


func _scan_shipped(path: String) -> void:
	var text: String = FileAccess.get_file_as_string(path)
	if not text.contains(GROUP_TOKEN):
		return
	var lines: PackedStringArray = text.split("\n")

	# Pass 1: what each top-level func does to the group.
	var joins: Dictionary = {}
	var leaves: Dictionary = {}
	var current: String = ""
	for raw in lines:
		var line: String = _strip_comment(raw)
		if line.begins_with("func "):
			current = line.substr(5).split("(")[0].strip_edges()
			continue
		if current.is_empty():
			continue
		if line.contains("add_to_group(%s)" % GROUP_TOKEN):
			joins[current] = true
		elif line.contains("remove_from_group(%s)" % GROUP_TOKEN):
			leaves[current] = true

	# Pass 2: which event reaches which of those handlers.
	var file_name: String = path.get_file()
	for raw in lines:
		var line: String = _strip_comment(raw).strip_edges()
		var marker: String = "EVENT_BUS.subscribe_"
		var at: int = line.find(marker)
		if at < 0:
			continue
		var rest: String = line.substr(at + marker.length())
		var paren: int = rest.find("(")
		if paren < 0:
			continue
		var event: String = rest.substr(0, paren)
		# `subscribe_x(_on_x)` and `subscribe_x(Callable(self, "_on_x"))` both reduce to the name.
		var handler: String = rest.substr(paren + 1).split(")")[0].strip_edges()
		handler = handler.split(",")[-1].strip_edges().trim_prefix("\"").trim_suffix("\"")
		var label: String = "%s:%s" % [file_name, handler]
		if joins.has(handler):
			_append(latching, event, label)
		if leaves.has(handler):
			_append(releasing, event, label)


# --- walking one check in call order -----------------------------------------------------------


## Returns how many latch-sensitive lines carried an acknowledgement marker.
func _scan_check(path: String) -> int:
	var text: String = FileAccess.get_file_as_string(path)
	var raw_lines: PackedStringArray = text.split("\n")
	var bodies: Dictionary = _func_bodies(raw_lines)

	var entry: String = ""
	for candidate in ENTRY_NAMES:
		if bodies.has(candidate):
			entry = candidate
			break

	var reached: Dictionary = {}
	var acknowledged: int = 0
	if not entry.is_empty():
		acknowledged += _walk(path, bodies, entry, reached, raw_lines)
	# Anything the entry never reaches is normally a probe body dispatched by argv in the second
	# process, so it gets its own window rather than being assumed dead.
	for name in _sorted_keys(bodies):
		if reached.has(name):
			continue
		acknowledged += _walk(path, bodies, name, reached, raw_lines)
	return acknowledged


func _walk(path: String, bodies: Dictionary, entry: String, reached: Dictionary,
		raw_lines: PackedStringArray) -> int:
	var state: Dictionary = {"event": "", "line": 0, "acknowledged": 0}
	_walk_body(path, bodies, entry, reached, raw_lines, state, [], 0)
	return int(state["acknowledged"])


func _walk_body(path: String, bodies: Dictionary, name: String, reached: Dictionary,
		raw_lines: PackedStringArray, state: Dictionary, stack: Array, depth: int) -> void:
	if depth > MAX_DEPTH or stack.has(name):
		return
	reached[name] = true
	stack.append(name)
	# Sibling branches of one `if`/`elif`/`else` are alternatives, not a sequence. Without this,
	# `terminal_focus_check.gd`'s argv dispatch (`_run_client` / `_run_orphan_client` / `_run_driver`
	# under one if-chain) let the first probe's latch leak into the next probe's assertions and
	# reported a failure in a branch that can never run in the same process.
	var branches: Array = []
	for entry in bodies[name]:
		var index: int = int(entry[0])
		var line: String = _strip_comment(entry[1])
		if line.strip_edges().is_empty():
			continue

		var indent: int = entry[1].length() - entry[1].lstrip("\t").length()
		var head: String = line.strip_edges()
		while not branches.is_empty() and int(branches[-1]["indent"]) > indent:
			branches.pop_back()
		if head.begins_with("elif ") or head.begins_with("else:"):
			if not branches.is_empty() and int(branches[-1]["indent"]) == indent:
				state["event"] = branches[-1]["event"]
				state["line"] = branches[-1]["line"]
		elif head.begins_with("if "):
			if not branches.is_empty() and int(branches[-1]["indent"]) == indent:
				branches.pop_back()
			branches.append({"indent": indent, "event": state["event"], "line": state["line"]})

		var emitted: String = _emitted_event(line)
		if not emitted.is_empty():
			if releasing.has(emitted):
				state["event"] = ""
			elif latching.has(emitted):
				state["event"] = emitted
				state["line"] = index + 1
			continue

		var called: String = _called_local(line, bodies)
		if not called.is_empty():
			_walk_body(path, bodies, called, reached, raw_lines, state, stack, depth + 1)
			continue

		if String(state["event"]).is_empty():
			continue
		for probe in LATCH_SENSITIVE:
			if not line.contains(probe):
				continue
			if _acknowledged(raw_lines, index):
				state["acknowledged"] = int(state["acknowledged"]) + 1
			else:
				_report(path, index, probe, state)
			break
	stack.pop_back()


func _report(path: String, index: int, probe: String, state: Dictionary) -> void:
	var event: String = String(state["event"])
	fail("%s:%d touches `%s` while the `%s` latch opened at line %d is still standing.\n"
			% [path.trim_prefix("res://"), index + 1, probe, event, int(state["line"])]
		+ "        %s joins `blocks_gameplay_input` on that event and does not leave until %s, "
			% [", ".join(latching[event]), _release_hint(event)]
		+ "so D-032's interlock silently changes what this line means (F-291).\n"
		+ "        Fix it by calling the service directly instead of emitting; or by emitting the "
		+ "real reset first, as tools/unlock_check.gd does; or, if the latch is the point of the "
		+ "assertion, add `# %s <why>` on this line or the one above it" % MARKER)


## True if this line, or the one above it, carries `latch-ok:` followed by an actual reason.
func _acknowledged(raw_lines: PackedStringArray, index: int) -> bool:
	for probe_index in [index, index - 1]:
		if probe_index < 0:
			continue
		var at: int = raw_lines[probe_index].find(MARKER)
		if at < 0:
			continue
		if raw_lines[probe_index].substr(at + MARKER.length()).strip_edges().length() >= 8:
			return true
	return false


func _release_hint(event: String) -> String:
	var owners: Array = latching[event]
	for candidate in _sorted_keys(releasing):
		for label in releasing[candidate]:
			for owner in owners:
				if String(label).split(":")[0] == String(owner).split(":")[0]:
					return "`%s` fires" % candidate
	return "the run resets"


# --- small parsers -----------------------------------------------------------------------------


## name -> Array of [line_index, raw_text] for that function's body, in order.
func _func_bodies(lines: PackedStringArray) -> Dictionary:
	var bodies: Dictionary = {}
	var current: String = ""
	for index in lines.size():
		var line: String = lines[index]
		var stripped: String = _strip_comment(line)
		if stripped.begins_with("func "):
			current = stripped.substr(5).split("(")[0].strip_edges()
			bodies[current] = []
			continue
		if current.is_empty():
			continue
		# A non-indented, non-blank line has left the function body (a const, a var, a new block).
		if not stripped.strip_edges().is_empty() and not (line.begins_with("\t") or line.begins_with(" ")):
			current = ""
			continue
		bodies[current].append([index, line])
	return bodies


## The local function this line calls, if it calls exactly one we know about.
func _called_local(line: String, bodies: Dictionary) -> String:
	var text: String = line.strip_edges().trim_prefix("await ").strip_edges()
	if not text.begins_with("_"):
		return ""
	var paren: int = text.find("(")
	if paren <= 0:
		return ""
	var name: String = text.substr(0, paren)
	return name if bodies.has(name) else ""


## The event in an `EVENT_BUS.emit_x(` / `EventBus.emit_x(` call, or "".
func _emitted_event(line: String) -> String:
	for prefix in ["EVENT_BUS.emit_", "EventBus.emit_"]:
		var at: int = line.find(prefix)
		if at < 0:
			continue
		var rest: String = line.substr(at + prefix.length())
		var paren: int = rest.find("(")
		if paren < 0:
			continue
		return rest.substr(0, paren)
	return ""


func _strip_comment(line: String) -> String:
	var hash_at: int = line.find("#")
	return line if hash_at < 0 else line.substr(0, hash_at)


func _append(target: Dictionary, key: String, value: String) -> void:
	if not target.has(key):
		target[key] = []
	if not target[key].has(value):
		target[key].append(value)


func _sorted_keys(target: Dictionary) -> Array:
	var keys: Array = target.keys()
	keys.sort()
	return keys


func _gd_files(dir_path: String) -> PackedStringArray:
	var out: PackedStringArray = []
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var name: String = dir.get_next()
	while name != "":
		if name.begins_with("."):
			name = dir.get_next()
			continue
		var full: String = "%s/%s" % [dir_path, name]
		if dir.current_is_dir():
			out.append_array(_gd_files(full))
		elif name.ends_with(".gd"):
			out.append(full)
		name = dir.get_next()
	dir.list_dir_end()
	var sorted: Array = Array(out)
	sorted.sort()
	return PackedStringArray(sorted)


func _finish(scanned: int, acknowledged: int, failure_count: int) -> void:
	if failure_count == 0:
		print("PASS: %d tools/*_check.gd walked in call order; every latch-sensitive line under a "
			% scanned
			+ "standing latch is acknowledged (%d marker%s)"
				% [acknowledged, "" if acknowledged == 1 else "s"])
	print("\nBLOCKING_UI_EVENT_CHECK scanned=%d acknowledged=%d failures=%d"
		% [scanned, acknowledged, failure_count])
	quit(0 if failure_count == 0 else 1)


func fail(description: String) -> void:
	failures += 1
	push_error("FAIL: %s" % description)
