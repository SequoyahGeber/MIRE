extends SceneTree

## Offline proof for task 3.15 — the selector grammar, the directory, and the four verbs, against
## REAL entities spawned through EnemyWorld's own host seam rather than stand-ins.
##
##   .agent/bin/agent godot --script tools/entity_check.gd
##
## `tools/entity_net_check.gd` is the other half: a client's selector resolving on the HOST's
## directory, and `tp` on a player going the long way round through the owning client.
##
## Preloaded for the F-016 reason every check here states — entity_selector.gd and
## entity_directory.gd are new this session, so a fresh headless clone has not scanned them into the
## global class cache yet.
const CommandServiceScript = preload("res://autoload/command_service.gd")
const SelectorScript = preload("res://core/commands/entity_selector.gd")
const EnemyScript = preload("res://systems/enemies/enemy.gd")
const HarvestableScript = preload("res://systems/harvesting/harvestable.gd")
const ChestScript = preload("res://systems/loot/chest.gd")
const HaulableScript = preload("res://systems/hauling/haulable.gd")

const HOST_PEER: int = 1

var failures: int = 0
var command_service: CommandServiceScript
var directory: Node
var enemy_world: Node


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame

	directory = root.get_node_or_null(^"EntityDirectory")
	enemy_world = root.get_node_or_null(^"EnemyWorld")
	command_service = root.get_node_or_null(^"CommandService") as CommandServiceScript
	check(directory != null, "EntityDirectory autoload exists")
	check(command_service != null, "CommandService autoload exists")
	if directory == null or command_service == null:
		finish()
		return

	_check_grammar()
	_check_group_constants()
	await _check_directory_and_ids()
	await _check_filters()
	await _check_tags()
	await _check_vec3_and_tp()
	await _check_kill()

	print("\nENTITY_CHECK failures=%d" % failures)
	finish()


func _ctx(peer_id: int = HOST_PEER, position: Vector3 = Vector3.ZERO) -> Dictionary:
	return {"peer_id": peer_id, "source": &"console", "position": position, "facing": Vector3.FORWARD}


# ── the grammar, with no tree involved at all ───────────────────────────────────────────────────────


func _check_grammar() -> void:
	print("\n== selector grammar (pure — no entity needs to exist) ==")
	for pair: Array in [["@s", SelectorScript.KIND_SELF], ["@p", SelectorScript.KIND_NEAREST],
			["@a", SelectorScript.KIND_ALL], ["@r", SelectorScript.KIND_RANDOM],
			["@e", SelectorScript.KIND_ENTITIES]]:
		var parsed: Dictionary = SelectorScript.parse(pair[0])
		check(bool(parsed.get("ok", false)) and parsed["selector"]["kind"] == pair[1],
			"%s parses as %s" % [pair[0], pair[1]])

	var full: Dictionary = SelectorScript.parse("@e[type=enemy,tag=wave,r=30,limit=5,sort=nearest]")
	check(bool(full.get("ok", false)), "§3.2's own worked example parses")
	var filters: Dictionary = full.get("selector", {}).get("filters", {})
	check(filters.get("type") == &"enemy" and filters.get("tag") == &"wave", "type and tag land")
	check(is_equal_approx(float(filters.get("radius", 0.0)), 30.0), "r= lands as a radius")
	check(int(filters.get("limit", 0)) == 5 and filters.get("sort") == &"nearest", "limit and sort land")

	var coords: Dictionary = SelectorScript.parse("@e[x=1,y=2,z=3,r=5]")
	check(bool(coords.get("ok", false))
		and (coords["selector"]["filters"]["origin"] as Vector3).is_equal_approx(Vector3(1, 2, 3)),
		"x=,y=,z= become an explicit origin")

	for bad: Array in [
		["notaselector", "a bare word is not a selector"],
		["@x", "an unknown head is refused"],
		["@e[type=enemy", "an unclosed bracket is refused"],
		["@e[type]", "a filter with no = is refused"],
		["@e[r=banana]", "a non-numeric radius is refused"],
		["@e[limit=0]", "limit=0 is refused"],
		["@e[sort=sideways]", "an unknown sort is refused"],
		["@e[nonsuch=1]", "an unknown filter key is refused"],
		["@e[x=1,y=2]", "a partial origin is refused rather than silently zeroed"],
	]:
		var parsed: Dictionary = SelectorScript.parse(bad[0])
		check(not bool(parsed.get("ok", true)), "%s (%s)" % [bad[1], parsed.get("error", "")])

	check(SelectorScript.describe(SelectorScript.parse("@e[type=enemy,limit=2]")["selector"])
		== "@e[type=enemy,limit=2]", "describe() round-trips a selector for the affected-N line")


## The one real cost of discovering by group (D-088): this file states each group name, and the
## owning script states it too. If they ever disagree, that kind silently stops being addressable —
## so assert it here rather than discover it as "why does `entities` never list chests".
func _check_group_constants() -> void:
	print("\n== the group names EntityDirectory scans still match their owners ==")
	var expected: Dictionary = {
		&"enemy": EnemyScript.ENEMY_GROUP,
		&"harvestable": HarvestableScript.HARVESTABLE_GROUP,
		&"chest": ChestScript.CHEST_GROUP,
		&"haulable": HaulableScript.HAULABLE_GROUP,
		&"buildable": (root.get_node_or_null(^"BuildService") as Node).get(&"PIECE_GROUP")
			if root.get_node_or_null(^"BuildService") != null else &"buildable_piece",
	}
	var groups: Dictionary = directory.get(&"KIND_GROUPS")
	for kind: StringName in expected:
		check(groups.get(kind) == expected[kind],
			"'%s' scans group '%s' (owner says '%s')" % [kind, groups.get(kind), expected[kind]])
	check(groups.get(&"player") == &"players",
		"'player' scans group 'players' (player_controller.gd's own add_to_group)")


# ── the directory ───────────────────────────────────────────────────────────────────────────────────


func _check_directory_and_ids() -> void:
	print("\n== the directory sees what is alive, with stable ids ==")
	var before: int = (directory.call("snapshot") as Array).size()
	var spawned: Array[Node3D] = []
	for i: int in 3:
		var enemy: Node3D = enemy_world.call("host_spawn", &"crawler", Vector3(float(i) * 10.0, 0.0, 0.0))
		if enemy != null:
			spawned.append(enemy)
	await process_frame
	check(spawned.size() == 3, "spawned 3 crawlers through EnemyWorld's own host seam")

	var snapshot: Array = directory.call("snapshot")
	check(snapshot.size() == before + 3, "the directory picked them up with no registration call")

	var first_ids: Array = []
	for entry: Dictionary in snapshot:
		if entry["kind"] == &"enemy":
			first_ids.append(entry["id"])
	check(not first_ids.is_empty() and String(first_ids[0]).begins_with("enemy:"),
		"ids are <kind>:<serial> (%s)" % first_ids[0])

	var again: Array = directory.call("snapshot")
	var second_ids: Array = []
	for entry: Dictionary in again:
		if entry["kind"] == &"enemy":
			second_ids.append(entry["id"])
	check(first_ids == second_ids, "a second scan mints nothing new — ids are stable across scans")

	# Pruning: kill one outside the directory's knowledge and confirm it stops being listed.
	spawned[0].queue_free()
	await process_frame
	await process_frame
	var pruned: Array = directory.call("snapshot")
	check(pruned.size() == before + 2, "a freed entity drops out of the directory on the next scan")


func _check_filters() -> void:
	print("\n== filters: type, radius, limit, sort ==")
	var origin_ctx: Dictionary = _ctx(HOST_PEER, Vector3.ZERO)

	var all_enemies: Array = directory.call("resolve",
		SelectorScript.parse("@e[type=enemy]")["selector"], origin_ctx)
	check(all_enemies.size() == 2, "type=enemy matches the 2 survivors (%d)" % all_enemies.size())

	var by_def: Array = directory.call("resolve",
		SelectorScript.parse("@e[type=crawler]")["selector"], origin_ctx)
	check(by_def.size() == 2, "type= also accepts an enemy DEF id, not just the kind")

	# Survivors sit at x=10 and x=20 (x=0 was freed above).
	var near: Array = directory.call("resolve",
		SelectorScript.parse("@e[type=enemy,r=15]")["selector"], origin_ctx)
	check(near.size() == 1, "r=15 from the origin reaches only the nearer one (%d)" % near.size())

	var far_origin: Array = directory.call("resolve",
		SelectorScript.parse("@e[type=enemy,r=5,x=20,y=0,z=0]")["selector"], origin_ctx)
	check(far_origin.size() == 1, "an explicit x=,y=,z= origin measures from there, not from the issuer")

	var limited: Array = directory.call("resolve",
		SelectorScript.parse("@e[type=enemy,limit=1]")["selector"], origin_ctx)
	check(limited.size() == 1, "limit= caps the result")
	check(is_equal_approx((limited[0]["node"] as Node3D).global_position.x, 10.0),
		"a limit with no sort takes the NEAREST, not whatever the scan happened to return first")

	var empty: Array = directory.call("resolve",
		SelectorScript.parse("@e[type=enemy,tag=nosuchtag]")["selector"], origin_ctx)
	check(empty.is_empty(), "an unmatched tag resolves to an empty list, not an error")


func _check_tags() -> void:
	print("\n== tags are addressing, and they survive a rescan ==")
	var tagged: Dictionary = await command_service.execute("tag @e[type=enemy] add wave", _ctx())
	check(bool(tagged.get("ok", false)), "tag ... add succeeds: %s" % tagged.get("message"))
	check(int((tagged.get("data", {}) as Dictionary).get("count", 0)) == 2, "it tagged both enemies")

	var by_tag: Array = directory.call("resolve",
		SelectorScript.parse("@e[tag=wave]")["selector"], _ctx())
	check(by_tag.size() == 2, "tag= now addresses them")

	directory.call("snapshot")
	var still: Array = directory.call("resolve", SelectorScript.parse("@e[tag=wave]")["selector"], _ctx())
	check(still.size() == 2, "and the tags survived a rescan — they hang on the entry, not the scan")

	var listed: Dictionary = await command_service.execute("tag @e[tag=wave] list", _ctx())
	check(String(listed.get("message", "")).contains("wave"), "tag ... list shows them")

	var untagged: Dictionary = await command_service.execute("tag @e[tag=wave] remove wave", _ctx())
	check(int((untagged.get("data", {}) as Dictionary).get("count", 0)) == 2, "tag ... remove clears them")
	check((directory.call("resolve", SelectorScript.parse("@e[tag=wave]")["selector"], _ctx()) as Array).is_empty(),
		"and nothing answers tag=wave afterwards")

	var no_tag: Dictionary = await command_service.execute("tag @a add", _ctx())
	check(not bool(no_tag.get("ok", true)), "tag ... add with no tag word is refused, not a silent no-op")


func _check_vec3_and_tp() -> void:
	print("\n== vec3, including ~ relative coords, and tp on an entity the host owns ==")
	var listed: Dictionary = await command_service.execute("entities @e[type=enemy]", _ctx())
	check(bool(listed.get("ok", false)) and int((listed.get("data", {}) as Dictionary).get("count", 0)) == 2,
		"`entities` lists them: %s" % String(listed.get("message", "")).split("\n")[0])

	var moved: Dictionary = await command_service.execute("tp @e[type=enemy] 5 1 5", _ctx())
	check(bool(moved.get("ok", false)), "tp with absolute coords succeeds: %s" % moved.get("message"))
	for entry: Dictionary in directory.call("resolve", SelectorScript.parse("@e[type=enemy]")["selector"], _ctx()):
		check((entry["node"] as Node3D).global_position.is_equal_approx(Vector3(5, 1, 5)),
			"enemy %s actually moved" % entry["id"])

	# `~` is relative to the ISSUER's position, which is what the ctx carries.
	var relative: Dictionary = await command_service.execute(
		"tp @e[type=enemy] ~ ~2 ~", _ctx(HOST_PEER, Vector3(100.0, 0.0, 100.0)))
	check(bool(relative.get("ok", false)), "tp with ~ relative coords succeeds")
	for entry: Dictionary in directory.call("resolve", SelectorScript.parse("@e[type=enemy]")["selector"], _ctx()):
		check((entry["node"] as Node3D).global_position.is_equal_approx(Vector3(100, 2, 100)),
			"~ resolved against the ISSUER's position, not the world origin")

	var short: Dictionary = await command_service.execute("tp @e[type=enemy] 1 2", _ctx())
	check(not bool(short.get("ok", true)) and String(short.get("message", "")).contains("usage"),
		"two coordinates is a usage error, not a silent Vector3 with a zero in it")

	check(root.get_node_or_null(^"PlayerHealth").has_method(&"host_place_player"),
		"PlayerHealth grew the public seam tp needs for PLAYERS (§3.3) rather than tp writing a "
			+ "player transform itself")


func _check_kill() -> void:
	print("\n== kill goes through each owner's existing damage seam ==")
	var alive_before: int = int(enemy_world.call("live_count"))
	var killed: Dictionary = await command_service.execute("kill @e[type=enemy]", _ctx())
	check(bool(killed.get("ok", false)), "kill succeeds: %s" % killed.get("message"))
	check(int((killed.get("data", {}) as Dictionary).get("count", 0)) == alive_before,
		"it reports killing every match, Minecraft-style")
	await process_frame
	await process_frame
	check(int(enemy_world.call("live_count")) == 0,
		"EnemyWorld agrees they are gone — the damage went through host_apply_damage, not queue_free")

	var nothing: Dictionary = await command_service.execute("kill @e[type=enemy]", _ctx())
	check(bool(nothing.get("ok", false))
		and int((nothing.get("data", {}) as Dictionary).get("count", 0)) == 0,
		"killing an empty selection is a successful zero, not an error")

	var bad_selector: Dictionary = await command_service.execute("kill notaselector", _ctx())
	check(not bool(bad_selector.get("ok", true)), "a malformed selector is refused by the arg parser")
	check(String(bad_selector.get("message", "")).contains("selector"),
		"with the grammar's own message: %s" % bad_selector.get("message"))


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
