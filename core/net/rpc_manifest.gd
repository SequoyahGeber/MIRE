class_name RpcManifest
extends RefCounted

## The project's entire RPC wire surface, scanned from source and reduced to one signature — so that
## adding, removing or reshaping an RPC without bumping `NetVersion.PROTOCOL_VERSION` becomes a
## failing check instead of a silent desync.
##
## WHY THIS EXISTS. `net_version.gd`'s own docstring states the rule plainly: bump the version
## whenever a change would desync two builds without either side noticing. It is a good rule and it
## was missed **four times** — F-161 (5.3's three ranged-combat RPCs), F-165 (6.5's two extraction
## RPCs), F-169 (6.7's `net_run_defeated`), F-178 (F-157's three display-name RPCs). Four different
## agents, four different tasks, same omission. At that point it is not a discipline problem; the
## rule needed a mechanism, because the failure it guards against is invisible at the moment you
## cause it and expensive much later (two builds connect fine at the transport layer, then read
## wrong values off the wire or silently drop each other's packets).
##
## Network authority: none. This is a source scanner and a constant.
##
## HOW TO USE IT. `tools/rpc_manifest_check.gd` fails when the scanned surface no longer matches
## `RECORDED_SIGNATURE`. If you changed the wire on purpose: bump `NetVersion.PROTOCOL_VERSION`, then
## re-record by pasting the two constants the check prints. Both steps, or the check stays red — which
## is the point, because re-recording without bumping is the exact mistake it exists to catch.

const RPC_ANNOTATION: String = "@rpc"
const SCAN_ROOT: String = "res://"
## Skipped so a scan stays fast and, more importantly, so the manifest tracks the GAME's wire and
## nothing else. `tools/` is excluded deliberately: `handshake_check.gd` declares three `@rpc`
## functions of its own to drive a fake two-peer handshake, and counting harness scaffolding would
## mean adding a net check demanded a protocol bump — a false alarm, and false alarms are how a check
## like this gets ignored and then deleted.
const SKIP_DIRS: PackedStringArray = [
	".godot", ".git", "assets", "docs", ".agent", "addons", "tools",
]


## The `PROTOCOL_VERSION` in force when `RECORDED_SIGNATURE` below was taken. The check asserts these
## two move together: a signature re-recorded against an unchanged version is the omission itself.
const RECORDED_PROTOCOL_VERSION: int = 23
## FNV-1a over the canonical manifest (see `signature()`). Regenerate with the check tool; never by
## hand, and never without also bumping the version above.
const RECORDED_SIGNATURE: String = "3053c34e247b6fc5"
## Carried alongside the hash purely so a failure can say "42 -> 45" before it says "the hash moved".
## A hash tells you something changed; a count tells you roughly what happened.
const RECORDED_ENTRY_COUNT: int = 56


## One canonical line per RPC, sorted. The line is deliberately the parts that affect the WIRE and
## nothing else:
##
##     <script path>::<func name>(<arg types>)|<rpc config>
##
## Argument NAMES are excluded — renaming a parameter changes no bytes. Argument TYPES and ORDER are
## included, because both do. The `@rpc` config is included because `any_peer` vs `authority` and
## `reliable` vs `unreliable` are wire-behaviour changes that `net_version.gd` explicitly lists.
static func scan() -> PackedStringArray:
	var entries: PackedStringArray = []
	for path: String in _gd_files(SCAN_ROOT):
		_scan_file(path, entries)
	entries.sort()
	return entries


static func _scan_file(path: String, entries: PackedStringArray) -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return
	var pending_config: String = ""
	while not file.eof_reached():
		var line: String = file.get_line().strip_edges()
		if line.begins_with(RPC_ANNOTATION):
			pending_config = _normalize_config(line)
			continue
		if pending_config.is_empty():
			continue
		if line.begins_with("func "):
			entries.append("%s::%s|%s" % [path, _signature_of(line), pending_config])
			pending_config = ""
		elif not line.is_empty() and not line.begins_with("#"):
			# An @rpc followed by something that is not a func is malformed source, not a wire
			# change. Drop the pending config rather than attributing it to the next func along.
			pending_config = ""
	file.close()


## `@rpc("any_peer", "call_remote", "reliable")` -> `any_peer,call_remote,reliable`. Whitespace and
## quoting vary by author; the wire behaviour does not.
static func _normalize_config(annotation: String) -> String:
	var open_paren: int = annotation.find("(")
	if open_paren < 0:
		return "default"
	var close_paren: int = annotation.rfind(")")
	if close_paren <= open_paren:
		return "default"
	var inner: String = annotation.substr(open_paren + 1, close_paren - open_paren - 1)
	var parts: PackedStringArray = []
	for raw: String in inner.split(",", false):
		parts.append(raw.strip_edges().trim_prefix("\"").trim_suffix("\""))
	parts.sort()
	return ",".join(parts)


## `func net_give(peer: int, item: StringName = &"") -> void:` -> `net_give(int,StringName)`.
## Defaults are stripped: a default value changes what a CALLER sends, never what the wire format is.
static func _signature_of(func_line: String) -> String:
	var name_start: int = 5  # past "func "
	var open_paren: int = func_line.find("(", name_start)
	if open_paren < 0:
		return func_line.substr(name_start).strip_edges()
	var func_name: String = func_line.substr(name_start, open_paren - name_start).strip_edges()
	var close_paren: int = _matching_paren(func_line, open_paren)
	if close_paren < 0:
		return func_name
	var args: String = func_line.substr(open_paren + 1, close_paren - open_paren - 1)
	var types: PackedStringArray = []
	for raw: String in _split_top_level(args):
		var argument: String = raw.strip_edges()
		if argument.is_empty():
			continue
		# Strip a default first, then take whatever follows the colon. An untyped argument records as
		# `Variant`, which is honest — and is itself worth noticing in a wire signature.
		var equals: int = argument.find("=")
		if equals >= 0:
			argument = argument.substr(0, equals).strip_edges()
		var colon: int = argument.find(":")
		types.append(argument.substr(colon + 1).strip_edges() if colon >= 0 else "Variant")
	return "%s(%s)" % [func_name, ",".join(types)]


static func _matching_paren(text: String, open_index: int) -> int:
	var depth: int = 0
	for i: int in range(open_index, text.length()):
		var character: String = text[i]
		if character == "(":
			depth += 1
		elif character == ")":
			depth -= 1
			if depth == 0:
				return i
	return -1


## Splits on commas that are not inside brackets — `Dictionary[StringName, int]` is ONE argument, and
## a naive `split(",")` would record it as two and make the manifest wrong in a way nobody would
## think to check.
static func _split_top_level(text: String) -> PackedStringArray:
	var parts: PackedStringArray = []
	var depth: int = 0
	var current: String = ""
	for i: int in text.length():
		var character: String = text[i]
		if character == "[" or character == "(":
			depth += 1
		elif character == "]" or character == ")":
			depth -= 1
		if character == "," and depth == 0:
			parts.append(current)
			current = ""
			continue
		current += character
	if not current.strip_edges().is_empty():
		parts.append(current)
	return parts


## FNV-1a, 64-bit, integer-only — the same discipline world/gen uses for seeds and for the same
## reason: `hash()`'s implementation is not a contract, and a signature that changed between engine
## versions would cry wolf on every build.
static func signature(entries: PackedStringArray) -> String:
	# FNV-1a's offset basis is 0xCBF29CE484222325 (14695981039346656037 unsigned), which overflows
	# GDScript's signed int64 literal parser (max 0x7FFFFFFFFFFFFFFF) and fails the script to load.
	# -3750763034362895579 is its two's-complement signed reading of the identical 64 bits; FNV-1a's
	# xor/multiply steps are mod-2^64 either way, so the arithmetic is unchanged.
	var h: int = -3750763034362895579
	for entry: String in entries:
		for byte: int in entry.to_utf8_buffer():
			h = (h ^ byte) * 0x100000001B3
		h = (h ^ 0x0A) * 0x100000001B3
	# GDScript's `int` is SIGNED 64-bit, so the top bit makes `%016x` render a leading minus and the
	# recorded constant reads like a typo. Mask it off — 63 bits is ample for a change detector, and
	# a signature you can paste without second-guessing is worth more than the bit.
	return "%016x" % (h & 0x7FFFFFFFFFFFFFFF)


static func _gd_files(root: String) -> PackedStringArray:
	var found: PackedStringArray = []
	var pending: PackedStringArray = [root]
	while not pending.is_empty():
		var current: String = pending[pending.size() - 1]
		pending.remove_at(pending.size() - 1)
		var dir: DirAccess = DirAccess.open(current)
		if dir == null:
			continue
		dir.list_dir_begin()
		var entry: String = dir.get_next()
		while entry != "":
			if entry.begins_with("."):
				entry = dir.get_next()
				continue
			var path: String = current.path_join(entry)
			if dir.current_is_dir():
				if not SKIP_DIRS.has(entry):
					pending.append(path)
			elif entry.ends_with(".gd"):
				found.append(path)
			entry = dir.get_next()
		dir.list_dir_end()
	return found
