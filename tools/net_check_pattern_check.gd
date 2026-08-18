extends SceneTree

## F-060's tripwire: two traps in how `tools/*_net_check.gd` (and offline `tools/*_check.gd`) authors
## build test scaffolding, found the hard way while writing tools/player_vitals_net_check.gd for
## task 3.8, then re-found already fixed once in tools/chest_net_check.gd (task 3.5) before this
## check existed to catch it automatically.
##
##   .agent/bin/agent godot --script tools/net_check_pattern_check.gd
##
## It is a SOURCE-TEXT check, like tools/interp_coverage_check.gd — the trap is in code that never
## runs (a false readiness gate resolves true and the loop it guards silently runs zero iterations;
## a discarded mutation just means the injected test fixture quietly isn't there), so a runtime check
## has nothing to fail against. Reading the source is how you catch the thing nobody noticed.
##
## Trap 1 — a client "ready" gate built only from `local_peer_id() > HOST_PEER_ID` (optionally
## `and local_revision >= 0`) can resolve TRUE before the connection is actually established. ENet
## hands a client its own unique id locally the instant create_client() succeeds
## (autoload/net_transport.gd's join()), before the host<->client handshake completes — so the gate
## must also check `is_active()`, which is the one thing that is actually false until CONNECTED.
##
## Trap 2 — reading a strictly-typed `Dictionary[K, V]` script property through the generic
## `Object.get()` reflection API and mutating what it returns does not reliably mutate the original;
## something about that boundary converts rather than aliases. Assigning into it
## (`registry.get("items")[id] = x`) or calling a mutator on it (`registry.get("items").erase(id)`)
## directly off the `.get()` call silently discards the mutation. Always capture it to a `Dictionary`
## local and `.set()` it back explicitly afterward — the shape every fixed file in SET_BACK_OK uses.

## This file's own path is excluded from the walk — its comments and string literals above and below
## necessarily mention the trap shapes, which would otherwise self-trigger the very patterns it looks
## for.
const SELF_PATH: String = "res://tools/net_check_pattern_check.gd"

const SKIP_DIRS: Array[String] = ["res://addons", "res://.godot"]

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var scripts: Array[String] = []
	_walk("res://", scripts)
	scripts.sort()

	print("== trap 1: ready-gates that read local_peer_id() without gating on is_active() ==")
	var gate_hits: int = 0
	for path: String in scripts:
		var lines: PackedStringArray = FileAccess.get_file_as_string(path).split("\n")
		for i: int in lines.size():
			if not _is_bare_ready_read(lines[i]):
				continue
			gate_hits += 1
			var window_start: int = maxi(0, i - 8)
			var guarded: bool = false
			for j: int in range(window_start, i + 1):
				if lines[j].contains("is_active"):
					guarded = true
					break
			check(guarded,
				("%s:%d gates readiness on local_peer_id() > HOST_PEER_ID with no is_active() check "
				+ "within 8 lines above it — this can read true while the connection is still "
				+ "CONNECTING, not CONNECTED (F-060)") % [path, i + 1])
	if gate_hits == 0:
		fail("found zero local_peer_id() ready-gate reads — the scan itself is broken, not the codebase")

	print("\n== trap 2: mutating what a typed-Dictionary .get() call returns, without .set()-ing it back ==")
	var mutate_hits: int = 0
	var re := RegEx.new()
	# A bare property-reflection read — .get() called with exactly one string/StringName literal
	# argument, the shape Object.get(property_name) uses — chained straight into an index-assignment
	# or .erase(), discarding whatever it returned instead of capturing and reassigning it.
	re.compile("\\.get\\((\"[^\"]*\"|&\"[^\"]*\")\\)\\s*(\\[[^\\]]*\\]\\s*=|\\.erase\\()")
	for path: String in scripts:
		var lines: PackedStringArray = FileAccess.get_file_as_string(path).split("\n")
		for i: int in lines.size():
			if re.search(lines[i]) == null:
				continue
			mutate_hits += 1
			fail(("%s:%d mutates a .get() call's return value directly — capture it to a Dictionary "
				+ "local and .set() it back explicitly, the property may not alias the original "
				+ "(F-060)") % [path, i + 1])
	check(mutate_hits == 0, "no direct-chain mutation of a .get() reflection read (%d file lines scanned)"
		% _total_lines(scripts))

	print("\nNET_CHECK_PATTERN_CHECK scripts=%d gate_reads=%d mutate_hits=%d failures=%d" % [
		scripts.size(), gate_hits, mutate_hits, failures
	])
	quit(0 if failures == 0 else 1)


## True for a line that reads local_peer_id() and compares it against HOST_PEER_ID via the
## reflection `.call("local_peer_id")` idiom — the shape every two-process tools/*_net_check.gd
## driver uses, as opposed to `check(new_peer_id > ..., ...)`-style assertions on an id already read
## and stored earlier, which are not readiness gates and must not be flagged.
func _is_bare_ready_read(line: String) -> bool:
	return line.contains("local_peer_id\")) > NetConfig.HOST_PEER_ID")


func _total_lines(scripts: Array[String]) -> int:
	var total: int = 0
	for path: String in scripts:
		total += FileAccess.get_file_as_string(path).split("\n").size()
	return total


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
