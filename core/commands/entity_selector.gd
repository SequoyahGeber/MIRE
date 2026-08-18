class_name EntitySelector
extends RefCounted

## The `@s @p @a @r @e[...]` grammar from docs/COMMANDS.md §3.2, parsed into a plain Dictionary.
##
## Pure and node-free on purpose — same discipline as NetVersion and IslandHeightmap. Parsing a
## selector must be testable without a SceneTree, a session, or a single spawned entity, because the
## grammar is where the fiddly bugs live (a stray bracket, `r=` on a selector with no origin) and
## those are exactly the cases a live-entity test is worst at reaching. Resolution — turning a parsed
## selector into actual nodes — is EntityDirectory's job, on whichever side is executing.
##
## Network authority: none. This is a string parser.
##
## Parsed shape:
##   {kind: StringName, filters: Dictionary}
##     kind    — &"self" | &"nearest" | &"all" | &"random" | &"entities"
##     filters — only for @e / any selector that carried [...]:
##                 type: StringName   entity kind (player/enemy/…) OR an enemy def id
##                 tag: StringName
##                 radius: float      metres from the origin
##                 origin: Vector3    explicit x=,y=,z= — absent means "from the issuer"
##                 limit: int
##                 sort: StringName   &"nearest" | &"random"

const KIND_SELF: StringName = &"self"
const KIND_NEAREST: StringName = &"nearest"
const KIND_ALL: StringName = &"all"
const KIND_RANDOM: StringName = &"random"
const KIND_ENTITIES: StringName = &"entities"

const SORT_NEAREST: StringName = &"nearest"
const SORT_RANDOM: StringName = &"random"

const _HEADS: Dictionary = {
	"@s": KIND_SELF,
	"@p": KIND_NEAREST,
	"@a": KIND_ALL,
	"@r": KIND_RANDOM,
	"@e": KIND_ENTITIES,
}


## Returns {ok: true, selector: {kind, filters}} or {ok: false, error: String}. The error text is
## what the player sees, so it names the offending token rather than describing the grammar.
static func parse(raw: String) -> Dictionary:
	var text: String = raw.strip_edges()
	if text.is_empty():
		return _bad("empty selector")
	if not text.begins_with("@"):
		return _bad("'%s' is not a selector — selectors start with @ (try `@a`, `@e[type=enemy]`)" % raw)

	var head: String = text.substr(0, 2)
	if not _HEADS.has(head):
		return _bad("unknown selector '%s' — use @s, @p, @a, @r or @e" % head)
	var kind: StringName = _HEADS[head]

	var rest: String = text.substr(2)
	if rest.is_empty():
		return {"ok": true, "selector": {"kind": kind, "filters": {}}}
	if not rest.begins_with("[") or not rest.ends_with("]"):
		# Catches the two real typos: `@e type=enemy` (space swallowed by the tokenizer, so this
		# arrives as a bare `@e` plus a stray argument) and `@e[type=enemy` (unclosed).
		return _bad("'%s' has a malformed filter — expected @e[key=value,...]" % raw)

	var body: String = rest.substr(1, rest.length() - 2).strip_edges()
	if body.is_empty():
		return {"ok": true, "selector": {"kind": kind, "filters": {}}}

	var filters: Dictionary = {}
	var coords: Dictionary = {}
	for clause: String in body.split(",", false):
		var pair: PackedStringArray = clause.split("=", true, 1)
		if pair.size() != 2:
			return _bad("'%s' is not key=value" % clause.strip_edges())
		var key: String = pair[0].strip_edges().to_lower()
		var value: String = pair[1].strip_edges()
		if value.is_empty():
			return _bad("'%s' has no value" % key)
		var outcome: Dictionary = _apply(key, value, filters, coords)
		if not bool(outcome.get("ok", false)):
			return outcome

	if not coords.is_empty():
		if coords.size() != 3:
			return _bad("an explicit origin needs all of x=, y= and z= (got %s)" % ", ".join(coords.keys()))
		filters["origin"] = Vector3(coords["x"], coords["y"], coords["z"])

	return {"ok": true, "selector": {"kind": kind, "filters": filters}}


static func _apply(key: String, value: String, filters: Dictionary, coords: Dictionary) -> Dictionary:
	match key:
		"type":
			filters["type"] = StringName(value)
		"tag":
			filters["tag"] = StringName(value)
		"r":
			if not _is_number(value):
				return _bad("r= wants a radius in metres, got '%s'" % value)
			var radius: float = value.to_float()
			if radius < 0.0:
				return _bad("r= cannot be negative")
			filters["radius"] = radius
		"limit":
			if not value.is_valid_int():
				return _bad("limit= wants a whole number, got '%s'" % value)
			var limit: int = value.to_int()
			if limit < 1:
				return _bad("limit= must be at least 1")
			filters["limit"] = limit
		"sort":
			var sort: StringName = StringName(value.to_lower())
			if sort != SORT_NEAREST and sort != SORT_RANDOM:
				return _bad("sort= is nearest or random, got '%s'" % value)
			filters["sort"] = sort
		"x", "y", "z":
			if not _is_number(value):
				return _bad("%s= wants a number, got '%s'" % [key, value])
			coords[key] = value.to_float()
		_:
			return _bad("unknown filter '%s' — have: type, tag, r, limit, sort, x, y, z" % key)
	return {"ok": true}


## A selector that can only ever name players, so a command can refuse a nonsense pairing early
## (`tag @p add boss` is fine; `op @e[type=enemy]` is not) and EntityDirectory can skip scanning
## groups it will discard anyway.
static func is_player_only(selector: Dictionary) -> bool:
	var kind: StringName = selector.get("kind", KIND_ENTITIES)
	return kind == KIND_NEAREST or kind == KIND_ALL or kind == KIND_RANDOM


## Renders a parsed selector back to something close to what was typed — for the "affected N" line
## and for error messages, so a player sees their own selector echoed rather than a Dictionary.
static func describe(selector: Dictionary) -> String:
	var kind: StringName = selector.get("kind", KIND_ENTITIES)
	var head: String = "@e"
	for symbol: String in _HEADS:
		if _HEADS[symbol] == kind:
			head = symbol
			break
	var filters: Dictionary = selector.get("filters", {})
	if filters.is_empty():
		return head
	var parts: PackedStringArray = []
	for key: String in ["type", "tag", "radius", "limit", "sort"]:
		if filters.has(key):
			parts.append("%s=%s" % ["r" if key == "radius" else key, filters[key]])
	if filters.has("origin"):
		var origin: Vector3 = filters["origin"]
		parts.append("x=%.1f,y=%.1f,z=%.1f" % [origin.x, origin.y, origin.z])
	return "%s[%s]" % [head, ",".join(parts)]


## `is_valid_float()` is false for "5" and `is_valid_int()` is false for "5.0", and every numeric
## filter here accepts both spellings — so both are asked, every time, in one place.
static func _is_number(value: String) -> bool:
	return value.is_valid_float() or value.is_valid_int()


static func _bad(message: String) -> Dictionary:
	return {"ok": false, "error": message}
