extends Node

## EntityDirectory — autoload. Addressing for every live gameplay entity, and the four verbs that
## use it: `entities`, `tag`, `tp`, `kill`. docs/COMMANDS.md §3 is the spec.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2): **host-side registry, not replicated in v1.** A
## selector resolves wherever the command executes — a HOST command against the host's complete view,
## a LOCAL read against that machine's own (possibly partial) replicated one. That is exactly right
## for what LOCAL commands are allowed to do (§3.1), and it means this file adds no RPC of its own.
##
## COMMANDS EVER ONLY WRAP EXISTING HOST SEAMS (§3.3 — the safety argument for this whole track).
## Nothing here writes a transform or a hit point directly:
##   · `kill` on an enemy  -> Enemy.host_apply_damage()
##   · `kill` on a player  -> PlayerHealth.host_apply_damage()
##   · `tp` on an enemy    -> the body, which the host owns outright
##   · `tp` on a player    -> PlayerHealth.host_place_player(), which tells that peer's OWN client to
##     place itself. A player's movement is client-authoritative (§2.2 row 1); the host writing a
##     player transform would be overwritten by the next synchronizer tick and look like a bug in
##     teleporting rather than what it is, a violation of the authority table.
##
## DISCOVERY IS BY GROUP, and that is a deliberate simplification of §3.1's table (see D-088). Every
## spawn path the spec lists — PlayerNet's spawn, EnemyWorld's, BuildService's placement, a Chest's
## and a Harvestable's `_ready()` — already ends in `add_to_group()`. Subscribing to five different
## spawn signals plus five despawn paths would restate that fact five times and could drift out of
## sync with it; scanning the groups asks the tree what is actually alive right now, and cannot.
##
## Identity survives the scan: `<kind>:<serial>` is minted the first time an entity is seen and kept
## in `_entries`, keyed by instance id, so an id stays stable for the object's whole life and so do
## the tags hung on it.

const LOG_CHANNEL: StringName = &"entity"

## kind -> the group its members already join in their own _ready(). Adding a kind is one line here.
## The strings are duplicated from the owning scripts rather than preloaded from them on purpose:
## this autoload boots in every headless run, and preloading five gameplay scripts to read one
## constant each would drag their whole dependency trees into every check (the F-016 family of pain).
## `tools/entity_check.gd` asserts each one still matches its owner, so the duplication cannot rot.
const KIND_GROUPS: Dictionary = {
	&"player": &"players",
	&"enemy": &"enemies",
	&"harvestable": &"harvestable",
	&"buildable": &"buildable_piece",
	&"chest": &"chest",
	&"haulable": &"haulable",
}

## instance id -> {id: String, kind: StringName, tags: Array[StringName], peer_id: int}
var _entries: Dictionary[int, Dictionary] = {}
## kind -> next serial. Monotonic per boot, never reused, so an id in a log always means one entity.
var _serials: Dictionary[StringName, int] = {}
## §3.2: "Randomness uses a dedicated RandomNumberGenerator, and never touches world-gen RNG."
var _rng := RandomNumberGenerator.new()
var _transport_node: Node


func _ready() -> void:
	_rng.randomize()
	_register_commands()


# ── The directory ────────────────────────────────────────────────────────────────────────────────


## Every live entity, as {node, id, kind, tags, peer_id}. Rebuilt from the groups on each call and
## reconciled against `_entries` so ids and tags persist. Called once per selector resolution, not
## per frame — a command is a human pressing enter, so clarity beats caching here.
func snapshot() -> Array[Dictionary]:
	var live: Array[Dictionary] = []
	var seen: Dictionary[int, bool] = {}
	var tree: SceneTree = get_tree()
	if tree == null:
		return live

	for kind: StringName in KIND_GROUPS:
		for node: Node in tree.get_nodes_in_group(KIND_GROUPS[kind]):
			if not is_instance_valid(node) or node.is_queued_for_deletion():
				continue
			var instance_id: int = node.get_instance_id()
			seen[instance_id] = true
			var entry: Dictionary = _entries.get(instance_id, {})
			if entry.is_empty():
				entry = _mint(node, kind)
				_entries[instance_id] = entry
			live.append({
				"node": node,
				"id": String(entry["id"]),
				"kind": kind,
				"tags": (entry["tags"] as Array).duplicate(),
				"peer_id": int(entry.get("peer_id", 0)),
			})

	# Prune what died. Without this, tags accumulate against instance ids the engine is free to
	# reuse, and `entities` would slowly start counting corpses.
	for instance_id: int in _entries.keys():
		if not seen.has(instance_id):
			_entries.erase(instance_id)
	return live


func _mint(node: Node, kind: StringName) -> Dictionary:
	var serial: int = int(_serials.get(kind, 0)) + 1
	_serials[kind] = serial
	var tags: Array[StringName] = []
	return {
		"id": "%s:%d" % [kind, serial],
		"kind": kind,
		"tags": tags,
		# Players are additionally addressable by peer id (§3.1). The body's multiplayer authority IS
		# the owning peer — that is what makes their movement client-authoritative in the first place.
		"peer_id": node.get_multiplayer_authority() if kind == &"player" else 0,
	}


## Resolves a parsed selector against the live directory. `ctx` is a CommandCtx — the issuer's peer
## id and position, which is what @s/@p and a radius without an explicit origin measure from.
func resolve(selector: Dictionary, ctx: Dictionary) -> Array[Dictionary]:
	var kind: StringName = selector.get("kind", EntitySelector.KIND_ENTITIES)
	var filters: Dictionary = selector.get("filters", {})
	var issuer_peer: int = int(ctx.get("peer_id", 0))
	var origin: Vector3 = filters.get("origin", ctx.get("position", Vector3.ZERO))

	var pool: Array[Dictionary] = snapshot()
	if EntitySelector.is_player_only(selector) or kind == EntitySelector.KIND_SELF:
		pool = pool.filter(func(e: Dictionary) -> bool: return e["kind"] == &"player")

	if kind == EntitySelector.KIND_SELF:
		return pool.filter(func(e: Dictionary) -> bool: return int(e["peer_id"]) == issuer_peer)

	pool = _apply_filters(pool, filters, origin)

	match kind:
		EntitySelector.KIND_NEAREST:
			_sort_by_distance(pool, origin)
			return pool.slice(0, 1)
		EntitySelector.KIND_RANDOM:
			if pool.is_empty():
				return pool
			return [pool[_rng.randi_range(0, pool.size() - 1)]]
		_:
			pass

	var sort: StringName = filters.get("sort", &"")
	if sort == EntitySelector.SORT_NEAREST:
		_sort_by_distance(pool, origin)
	elif sort == EntitySelector.SORT_RANDOM:
		_shuffle(pool)
	if filters.has("limit"):
		# A limit with no sort would silently take whichever entities the group scan happened to
		# return first, which is stable but arbitrary. Nearest is the useful default and the one a
		# player means by "the closest 5"; sort= is still there to ask for random explicitly.
		if sort == &"":
			_sort_by_distance(pool, origin)
		pool = pool.slice(0, int(filters["limit"]))
	return pool


func _apply_filters(pool: Array[Dictionary], filters: Dictionary, origin: Vector3) -> Array[Dictionary]:
	var result: Array[Dictionary] = pool
	if filters.has("type"):
		var wanted: StringName = filters["type"]
		result = result.filter(func(e: Dictionary) -> bool: return _matches_type(e, wanted))
	if filters.has("tag"):
		var tag: StringName = filters["tag"]
		result = result.filter(func(e: Dictionary) -> bool: return (e["tags"] as Array).has(tag))
	if filters.has("radius"):
		var radius: float = float(filters["radius"])
		result = result.filter(func(e: Dictionary) -> bool:
			return _position_of(e["node"]).distance_to(origin) <= radius)
	return result


## `type=` accepts a KIND (player, enemy, chest…) or, for an enemy, its def id — §3.2's example is
## `type=enemy`, and `type=crawler` is the obvious next thing anyone types.
func _matches_type(entry: Dictionary, wanted: StringName) -> bool:
	if entry["kind"] == wanted:
		return true
	var node: Node = entry["node"]
	# The content id, wherever this kind keeps it. Enemies hold an EnemyDef on `definition` and the id
	# is on the RESOURCE, not the node — `type=crawler` reads it there. `tier` is the Chest's
	# equivalent. Probed by name rather than by `is` for the F-016 reason this whole codebase probes
	# by name: a bare class reference here would break every check on a stale class cache.
	for property: StringName in [&"def_id", &"enemy_id", &"tier", &"id"]:
		var value: Variant = node.get(property)
		if value != null and StringName(String(value)) == wanted:
			return true
	for holder: StringName in [&"definition", &"def"]:
		var resource: Variant = node.get(holder)
		if resource is Resource:
			var id: Variant = (resource as Resource).get(&"id")
			if id != null and StringName(String(id)) == wanted:
				return true
	return false


func _sort_by_distance(pool: Array[Dictionary], origin: Vector3) -> void:
	pool.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return _position_of(a["node"]).distance_squared_to(origin) \
			< _position_of(b["node"]).distance_squared_to(origin))


## Fisher-Yates off this service's own RNG — `Array.shuffle()` uses the global RNG, which is exactly
## the world-gen-adjacent shared state §3.2 says selectors must not touch.
func _shuffle(pool: Array[Dictionary]) -> void:
	for i: int in range(pool.size() - 1, 0, -1):
		var j: int = _rng.randi_range(0, i)
		var swap: Dictionary = pool[i]
		pool[i] = pool[j]
		pool[j] = swap


func _position_of(node: Node) -> Vector3:
	var body := node as Node3D
	return body.global_position if body != null else Vector3.ZERO


# ── Tags (addressing only — node groups stay the behavioural mechanism, §3.1) ────────────────────


func add_tag(node: Node, tag: StringName) -> bool:
	var entry: Dictionary = _entry_for(node)
	if entry.is_empty():
		return false
	var tags: Array = entry["tags"]
	if tags.has(tag):
		return false
	tags.append(tag)
	return true


func remove_tag(node: Node, tag: StringName) -> bool:
	var entry: Dictionary = _entry_for(node)
	if entry.is_empty():
		return false
	var tags: Array = entry["tags"]
	# Array.erase() returns void in Godot 4, so "did it actually remove one" has to be asked first —
	# and the caller genuinely needs the answer, because `tag ... remove` reports how many changed.
	if not tags.has(tag):
		return false
	tags.erase(tag)
	return true


func tags_of(node: Node) -> Array:
	var entry: Dictionary = _entry_for(node)
	return (entry["tags"] as Array).duplicate() if not entry.is_empty() else []


## Goes through `snapshot()` rather than reading `_entries` directly so an entity that has never been
## seen is minted here too — otherwise the first thing you could do to a fresh entity would depend on
## whether someone had run `entities` first.
func _entry_for(node: Node) -> Dictionary:
	if not is_instance_valid(node):
		return {}
	if not _entries.has(node.get_instance_id()):
		snapshot()
	return _entries.get(node.get_instance_id(), {})


# ── Commands (COMMANDS.md §3, §7) ────────────────────────────────────────────────────────────────


func _register_commands() -> void:
	var command_service: Node = get_node_or_null(^"/root/CommandService")
	if command_service == null:
		return
	command_service.call("register_spec", &"entities", {
		"scope": &"local",
		"args": [{"name": "target", "type": &"selector", "optional": true, "default": "@e"}],
		"handler": _cmd_entities,
		"help": "entities [selector] — list what the selector matches",
	})
	command_service.call("register_spec", &"tag", {
		"scope": &"host",
		"args": [
			{"name": "target", "type": &"selector"},
			{"name": "op", "type": &"enum", "values": ["add", "remove", "list"]},
			{"name": "tag", "type": &"string", "optional": true, "default": ""},
		],
		"handler": _cmd_tag,
		"help": "tag <selector> add|remove|list [tag] — addressing tags",
	})
	command_service.call("register_spec", &"tp", {
		"scope": &"host",
		"args": [
			{"name": "target", "type": &"selector"},
			{"name": "destination", "type": &"vec3"},
		],
		"handler": _cmd_tp,
		"help": "tp <selector> <x y z> — move entities (~ is relative to you)",
	})
	command_service.call("register_spec", &"kill", {
		"scope": &"host",
		"args": [{"name": "target", "type": &"selector"}],
		"handler": _cmd_kill,
		"help": "kill <selector> — kill everything the selector matches",
	})


func _cmd_entities(ctx: Dictionary, args: Dictionary) -> Dictionary:
	var matched: Array[Dictionary] = resolve(args.get("target", {}), ctx)
	if matched.is_empty():
		return _affected(0, "nothing matched %s" % EntitySelector.describe(args.get("target", {})), [])
	var lines: PackedStringArray = ["%d entit%s:" % [matched.size(), "y" if matched.size() == 1 else "ies"]]
	for entry: Dictionary in matched:
		var position: Vector3 = _position_of(entry["node"])
		var tags: Array = entry["tags"]
		lines.append("  %s  (%.1f, %.1f, %.1f)%s" % [
			entry["id"], position.x, position.y, position.z,
			"  tags: %s" % ", ".join(tags) if not tags.is_empty() else "",
		])
	return _affected(matched.size(), "\n".join(lines), _ids(matched))


func _cmd_tag(ctx: Dictionary, args: Dictionary) -> Dictionary:
	var matched: Array[Dictionary] = resolve(args.get("target", {}), ctx)
	var operation: String = String(args.get("op", "list"))
	var tag := StringName(String(args.get("tag", "")).strip_edges())
	if operation != "list" and tag == &"":
		return {"ok": false, "message": "usage: tag <selector> %s <tag>" % operation, "data": {}}

	if operation == "list":
		var lines: PackedStringArray = []
		for entry: Dictionary in matched:
			var tags: Array = entry["tags"]
			lines.append("  %s: %s" % [entry["id"], ", ".join(tags) if not tags.is_empty() else "—"])
		return _affected(matched.size(),
			"\n".join(lines) if not lines.is_empty() else "nothing matched", _ids(matched))

	var changed: int = 0
	for entry: Dictionary in matched:
		if operation == "add":
			if add_tag(entry["node"], tag):
				changed += 1
		elif remove_tag(entry["node"], tag):
			changed += 1
	return _affected(changed, "%s '%s' %s %d of %d matched" % [
		"tagged" if operation == "add" else "untagged", tag,
		"on" if operation == "add" else "off", changed, matched.size()
	], _ids(matched))


## §3.3's authority split, and the reason this verb is worth a whole task: an enemy is the host's to
## move, a player is not.
func _cmd_tp(ctx: Dictionary, args: Dictionary) -> Dictionary:
	var matched: Array[Dictionary] = resolve(args.get("target", {}), ctx)
	var destination: Vector3 = args.get("destination", Vector3.ZERO)
	var moved: int = 0
	var refused: int = 0
	for entry: Dictionary in matched:
		if String(entry["kind"]) == "player":
			if _move_player(int(entry["peer_id"]), destination):
				moved += 1
			else:
				refused += 1
			continue
		var body := entry["node"] as Node3D
		if body == null:
			refused += 1
			continue
		body.global_position = destination
		moved += 1
	var message: String = "teleported %d entit%s to (%.1f, %.1f, %.1f)" % [
		moved, "y" if moved == 1 else "ies", destination.x, destination.y, destination.z]
	if refused > 0:
		message += " — %d could not be moved" % refused
	return _affected(moved, message, _ids(matched))


## Never writes the player's transform. PlayerHealth owns the one seam that legitimately relocates a
## player (it already had to, for respawn) and it works by telling that peer's own client to do it.
func _move_player(peer_id: int, destination: Vector3) -> bool:
	var health: Node = get_node_or_null(^"/root/PlayerHealth")
	if health == null or peer_id <= 0 or not health.has_method(&"host_place_player"):
		return false
	return bool(health.call("host_place_player", peer_id, destination))


func _cmd_kill(ctx: Dictionary, args: Dictionary) -> Dictionary:
	var matched: Array[Dictionary] = resolve(args.get("target", {}), ctx)
	var killed: int = 0
	var issuer: int = int(ctx.get("peer_id", 0))
	for entry: Dictionary in matched:
		if _kill_one(entry, issuer):
			killed += 1
	return _affected(killed, "killed %d entit%s" % [killed, "y" if killed == 1 else "ies"],
		_ids(matched))


## Lethal damage through each owner's EXISTING host seam — never a second death path. The amount is
## deliberately absurd rather than "current hp": reading a hit-point total here would make this file
## know each entity's health model, which is the coupling §3.3 exists to prevent.
func _kill_one(entry: Dictionary, issuer_peer_id: int) -> bool:
	const LETHAL: int = 1_000_000
	var node: Node = entry["node"]
	if String(entry["kind"]) == "player":
		var health: Node = get_node_or_null(^"/root/PlayerHealth")
		if health == null:
			return false
		return bool(health.call("host_apply_damage", int(entry["peer_id"]), LETHAL, issuer_peer_id))
	if node.has_method(&"host_apply_damage"):
		return bool(node.call("host_apply_damage", LETHAL, issuer_peer_id))
	# Nothing with a damage seam — a chest, a haulable. Refusing beats queue_free()ing it behind the
	# owning service's back, which is exactly the second mutation path §3.3 forbids.
	return false


func _ids(matched: Array[Dictionary]) -> Array:
	var ids: Array = []
	for entry: Dictionary in matched:
		ids.append(entry["id"])
	return ids


func _affected(count: int, message: String, ids: Array) -> Dictionary:
	return {"ok": true, "message": message, "data": {"count": count, "ids": ids}}
