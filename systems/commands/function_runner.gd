class_name FunctionRunner
extends RefCounted

## Pure helpers for docs/COMMANDS.md §5.1's `.mcmd` command-file format: turning raw file text into
## real command lines (comments/blanks stripped), scanning a directory of them, and computing a
## function's EFFECTIVE scope (the max of its lines' scopes, recursing into any `function <name>`
## line up to the same recursion cap real execution enforces). Node-free and stateless on purpose,
## same discipline as core/commands/entity_selector.gd — the fiddly bugs in a text format live in
## parsing, and parsing should be testable without a SceneTree or a live CommandService.
##
## Actually RUNNING a function's lines needs `await` on CommandService.execute() for each one in
## order, which is why that half stays inside autoload/command_service.gd itself rather than here: a
## coroutine reached only through an untyped Node + Object.call() cannot be reliably awaited (see
## that file's own header), and this class is deliberately never handed a typed CommandService
## reference — command_service.gd is the one doing the preloading, not the other way round, so this
## file stays free to be preloaded FROM it without a cycle. This class only ever hands back data.
##
## Network authority: none. Text parsing and scope arithmetic, nothing more.

const RECURSION_CAP: int = 4

## Whole-line comments only (a line beginning with `#` once trimmed) — no inline trailing comments,
## because a command argument could legitimately contain a literal `#`.
const COMMENT_PREFIX: String = "#"


## Real command lines only, in file order — comments and blank lines dropped, everything else
## edge-trimmed. Raw text in, ready-to-execute lines out.
static func parse_lines(text: String) -> PackedStringArray:
	var lines: PackedStringArray = []
	for raw_line: String in text.split("\n"):
		var line: String = raw_line.strip_edges()
		if line.is_empty() or line.begins_with(COMMENT_PREFIX):
			continue
		lines.append(line)
	return lines


## Scans a directory for `*.mcmd` files and returns {StringName(file basename): parsed lines}. Reads
## via FileAccess rather than `load()` — these are plain text, not a Resource — so the exported-build
## remap question registry.gd's `_tres_files_in` worries about (F-121) does not apply here.
static func scan_directory(dir_path: String) -> Dictionary[StringName, PackedStringArray]:
	var functions: Dictionary[StringName, PackedStringArray] = {}
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return functions
	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.ends_with(".mcmd"):
			var full_path: String = dir_path.path_join(file_name)
			var text: String = FileAccess.get_file_as_string(full_path)
			var name := StringName(file_name.trim_suffix(".mcmd"))
			functions[name] = parse_lines(text)
		file_name = dir.get_next()
	dir.list_dir_end()
	return functions


## The max of `name`'s own lines' scopes (COMMANDS.md §5.1: "effective scope is the max of its
## lines"), recursing into any nested `function <other>` line up to RECURSION_CAP so a self-
## referential or deeply-nested function cannot hang this computation either — the same cap real
## execution enforces, just checked here for ROUTING (a client must know a function is HOST-scope
## before typing it, not after the RPC comes back). An unknown function, or one nested past the cap,
## resolves to &"host" — deny by default: safer to demand op for a name whose contents are unknown
## or unresolvable than to let it slip through as a LOCAL read. `scope_of_command` is
## CommandService's own `scope_of(name) -> StringName`, passed in rather than referenced directly so
## this stays node-free and testable with a synthetic functions dict and a fake Callable.
static func effective_scope(
	name: StringName, functions: Dictionary[StringName, PackedStringArray], scope_of_command: Callable,
	depth: int = 0
) -> StringName:
	if depth >= RECURSION_CAP or not functions.has(name):
		return &"host"
	for line: String in functions[name]:
		var parts: PackedStringArray = line.split(" ", false)
		if parts.is_empty():
			continue
		var head := StringName(parts[0])
		var line_scope: StringName
		if head == &"function" and parts.size() >= 2:
			line_scope = effective_scope(StringName(parts[1]), functions, scope_of_command, depth + 1)
		else:
			line_scope = StringName(scope_of_command.call(head))
		if line_scope == &"host":
			return &"host"
	return &"local"
