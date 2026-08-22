extends SceneTree

## F-536 — does a REAL procedural run actually produce collectible loose loot?
##
##   .agent/bin/agent godot --script tools/loose_loot_world_check.gd
##
## `tools/loose_loot_check.gd` (F-570) proves the SERVICE works: it builds 40 synthetic markers in a
## bare tree and asserts drops appear, replicate and can be taken. That is the right test for the
## service and it is not a test of the game — a fixture cannot tell you whether the shipped world
## puts any `loot` markers in front of a player, which is the half F-536 is actually about.
##
## This boots the composer exactly as `--procedural` does (the `world_contract_check.gd` arm), lets
## `LooseLootService` see the real markers, and counts what a player would actually find. Three
## seeds, because a single seed proving "some loot exists" says nothing about whether the NEXT run
## does — and an island that is generous on one seed and empty on another is the failure mode a
## fixture check is structurally blind to.
##
## Asserts a FLOOR and a CEILING, both loose. The floor is the real bug guard: a run with almost no
## loose loot means the pickup layer exists and the player never meets it. The ceiling exists
## because `LooseLootService`'s own comment claims "20-30 collectible piles", and a number wildly
## above that would mean the island is carpeted in items, which is its own bug and would also be a
## sign the comment has silently stopped describing the code.

const ProceduralWorldScript := preload("res://world/gen/procedural_world.gd")

const SEEDS: Array[int] = [536536, 991177, 20260822]

## Below this, the loose-loot layer is effectively invisible in a real run.
const MIN_DROPS_PER_RUN: int = 8
## Far above LooseLootService's own stated 20-30, so this only trips on a genuine runaway.
const MAX_DROPS_PER_RUN: int = 200

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var loose: Node = root.get_node_or_null(^"LooseLootService")
	var drops: Node = root.get_node_or_null(^"ItemDropService")
	var game_state: Node = root.get_node_or_null(^"GameState")
	check(loose != null, "LooseLootService is registered as an autoload")
	check(drops != null, "ItemDropService is registered as an autoload")
	check(game_state != null, "GameState is registered as an autoload")
	if loose == null or drops == null or game_state == null:
		_finish()
		return

	for world_seed: int in SEEDS:
		await _measure_seed(loose, drops, game_state, world_seed)

	print("\nLOOSE_LOOT_WORLD_CHECK failures=%d" % failures)
	_finish()


func _measure_seed(loose: Node, drops: Node, game_state: Node, world_seed: int) -> void:
	print("\n== seed %d ==" % world_seed)
	drops.call(&"host_clear_all")
	# Seed BEFORE the composer runs: LooseLootService derives every placement from the run seed and
	# the marker's own NodePath, so a seed set afterwards would describe a different island than the
	# one the markers came from.
	game_state.call(&"set_replicated_seed", world_seed)

	var world: Node3D = ProceduralWorldScript.new()
	world.name = "ProceduralWorld"
	# No player: this measures what the WORLD produces. Loose loot placement is seed-derived and does
	# not consult the player, and building one would only add a body for the drops to collide with.
	world.set(&"build_player", false)
	root.add_child(world)
	current_scene = world
	# The service discovers markers on `node_added` and defers its refresh, so the count is only
	# settled after the composer has finished AND the deferred pass has run.
	for _frame: int in 16:
		await process_frame
		await physics_frame

	var markers: int = 0
	# This script IS the SceneTree, so the group query is a plain method call on self.
	for node: Node in get_nodes_in_group(&"authored_world_marker"):
		if String(node.get_meta(&"kind", "")) == "loot":
			markers += 1
	var live: int = int(drops.call(&"live_count"))

	check(markers > 0, "seed %d places loot markers at all (%d)" % [world_seed, markers])
	check(live >= MIN_DROPS_PER_RUN,
		"seed %d leaves at least %d collectible drops in the world (%d from %d marker(s))" % [
			world_seed, MIN_DROPS_PER_RUN, live, markers
		])
	check(live <= MAX_DROPS_PER_RUN,
		"seed %d does not carpet the island (%d <= %d)" % [world_seed, live, MAX_DROPS_PER_RUN])

	world.queue_free()
	await process_frame
	await process_frame


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func _finish() -> void:
	quit(0 if failures == 0 else 1)
