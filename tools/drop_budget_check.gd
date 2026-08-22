extends SceneTree

## Verifies F-590 — a harvesting player must not delete the island's authored loot behind them.
##
##   .agent/bin/agent godot --script tools/drop_budget_check.gd
##
## `ItemDropService._enforce_budget()` caps live drops at `MAX_LIVE_DROPS` and used to evict
## `_container.get_child(0)` — the oldest — without ever looking at `persistent`. The reasoning
## written above the constant was "oldest first, because the drop a player is standing over is the
## newest one", which is right for harvest yields and exactly wrong for placed loot: `LooseLootService`
## spawns its piles at WORLD BUILD, so they are the oldest children in the container by a wide margin
## and therefore first in the queue to be deleted. Since F-535 every harvest yield competes for the
## same slots, so ordinary play was the trigger.
##
## ## This boots a real island rather than reading the code
##
## The population that matters is the one the shipped composer actually produces, and the documented
## figure has already been wrong once by 3x — `LooseLootService`'s own comment claimed "20-30
## collectible piles" while the real number is 71-86 (F-536 measured it). So the first thing this
## check does is boot the procedural world and COUNT, and every threshold below is stated against
## that measured number rather than against a comment.
##
## ## What it proves
##
##   1. a real island's authored loot survives a harvest burst big enough to overrun the cap
##   2. the burst still works — transient drops are evicted, so the budget is doing its job
##   3. the cap cannot be starved: the transient half stays reachable no matter what is placed
##   4. a refused drop is not a lost item, because `InventoryService` credits the pack directly
##      when `host_spawn_drop()` returns null
##
## Assertion 1 is the regression guard. It fails on the pre-F-590 file.

const ProceduralWorldScript := preload("res://world/gen/procedural_world.gd")
const DropService := preload("res://autoload/item_drop_service.gd")

const WORLD_SEED: int = 20260822
## Comfortably past `MAX_LIVE_DROPS` from whatever the island already placed, so eviction must run.
const HARVEST_BURST: int = 400
## Spread wider than `MERGE_RADIUS_M` so each yield is its own body — a burst that all merged into
## one pile would never reach the cap and the check would pass without testing anything.
const BURST_SPACING_M: float = 6.0

var failures: int = 0
var drops: Node
var inventory: Node


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	drops = root.get_node_or_null(^"ItemDropService")
	inventory = root.get_node_or_null(^"InventoryService")
	var game_state: Node = root.get_node_or_null(^"GameState")
	check(drops != null, "ItemDropService is registered as an autoload")
	check(inventory != null, "InventoryService is registered as an autoload")
	if drops == null or inventory == null or game_state == null:
		quit(1)
		return

	check(DropService.MAX_PERSISTENT_DROPS < DropService.MAX_LIVE_DROPS,
		"the persistent cap leaves transient slots at all (%d of %d, %d left over)" % [
			DropService.MAX_PERSISTENT_DROPS, DropService.MAX_LIVE_DROPS,
			DropService.MAX_LIVE_DROPS - DropService.MAX_PERSISTENT_DROPS])

	await _check_real_island(game_state)
	_check_persistent_cap_cannot_starve()

	print("\nDROP_BUDGET_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)


func _check_real_island(game_state: Node) -> void:
	print("\n== a real procedural island, harvested until the budget overruns ==")
	drops.call(&"host_clear_all")
	# Seeded before the composer runs: loose loot is derived from the run seed and each marker's own
	# NodePath, so seeding afterwards would describe a different island than the markers came from.
	game_state.call(&"set_replicated_seed", WORLD_SEED)

	var world: Node3D = ProceduralWorldScript.new()
	world.name = "ProceduralWorld"
	world.set(&"build_player", false)
	root.add_child(world)
	current_scene = world
	for _frame: int in 16:
		await process_frame
		await physics_frame

	# MEASURED, not read off a comment — every number below is stated against this.
	var placed: int = int(drops.call(&"persistent_count"))
	var live_before: int = int(drops.call(&"live_count"))
	print("     island placed %d persistent drop(s), %d live in total" % [placed, live_before])
	check(placed > 0, "the shipped island actually places authored loot to protect (%d)" % placed)
	check(placed == live_before,
		"and all of it is persistent before any harvesting (%d of %d)" % [placed, live_before])
	check(placed <= DropService.MAX_PERSISTENT_DROPS,
		"the real placed population fits under the %d persistent cap (%d) — if this fails the cap is too low for the shipped island, not the other way round"
			% [DropService.MAX_PERSISTENT_DROPS, placed])

	# Now play: harvest yields, spread far enough apart that none of them merge.
	var origin: Vector3 = Vector3(2000.0, 0.0, 2000.0)
	for index: int in HARVEST_BURST:
		var offset := Vector3(float(index % 20) * BURST_SPACING_M, 0.0,
			float(index / 20) * BURST_SPACING_M)
		drops.call(&"host_spawn_drop", &"stone", 1, origin + offset)

	var live_after: int = int(drops.call(&"live_count"))
	var persistent_after: int = int(drops.call(&"persistent_count"))
	print("     after %d harvest yields: %d live, %d persistent" % [
		HARVEST_BURST, live_after, persistent_after])

	check(live_after > DropService.MAX_LIVE_DROPS / 2,
		"the burst was big enough to exercise the cap (%d live against a %d cap)"
			% [live_after, DropService.MAX_LIVE_DROPS])
	check(live_after <= DropService.MAX_LIVE_DROPS,
		"the budget still holds — the cap is enforced (%d <= %d)"
			% [live_after, DropService.MAX_LIVE_DROPS])
	# THE REGRESSION GUARD. On the pre-F-590 file this is the assertion that fails: the island's
	# loot is the oldest thing in the container, so oldest-first eviction takes all of it.
	check(persistent_after == placed,
		"every piece of authored loot survived the harvest (%d of %d still standing)"
			% [persistent_after, placed])

	world.queue_free()
	await process_frame
	await process_frame


func _check_persistent_cap_cannot_starve() -> void:
	print("\n== authored loot cannot starve the budget, and a refusal is not a lost item ==")
	drops.call(&"host_clear_all")

	# Fill the persistent half past its own cap. The cap must bite at PLACEMENT: refusing the 129th
	# pile is visible and recoverable, while evicting to make room silently deletes loot a player
	# may already have walked towards.
	var accepted: int = 0
	for index: int in DropService.MAX_PERSISTENT_DROPS + 40:
		var placed_drop: Node3D = drops.call(&"host_spawn_placed_drop", &"stone", 1,
			Vector3(float(index) * BURST_SPACING_M, 0.0, 0.0)) as Node3D
		if placed_drop != null:
			accepted += 1
	check(accepted == DropService.MAX_PERSISTENT_DROPS,
		"placement stops at the persistent cap instead of evicting (%d accepted of %d attempted)"
			% [accepted, DropService.MAX_PERSISTENT_DROPS + 40])
	check(int(drops.call(&"persistent_count")) == DropService.MAX_PERSISTENT_DROPS,
		"and nothing already placed was despawned to make room")

	# With the persistent half full to its cap, a harvest yield must still find a home — that is
	# the whole reason the two budgets are separate rather than the exemption being unconditional.
	var yield_drop: Node3D = drops.call(&"host_spawn_drop", &"stone", 1,
		Vector3(0.0, 0.0, 500.0)) as Node3D
	check(yield_drop != null,
		"a harvest yield still spawns with the persistent half full (%d transient slots reserved)"
			% (DropService.MAX_LIVE_DROPS - DropService.MAX_PERSISTENT_DROPS))

	# And the failure mode when the budget genuinely cannot take another: the yield is not lost, it
	# goes straight to the pack. `InventoryService._on_harvest_yielded()` treats a null from
	# `host_spawn_drop()` as "no drop service" and credits directly — the pre-F-535 behaviour.
	# Asserted here so a later change cannot make refusal destructive without this going red.
	#
	# Asserted as a DISJUNCTION on both destinations, not as "the pack did not shrink". The weaker
	# form passes when nothing happens at all, which is precisely the failure it is meant to catch:
	# a yield that is silently dropped on the floor leaves the pack unchanged too.
	var pack_before: int = int(inventory.call("host_count", NetConfig.HOST_PEER_ID, &"stone"))
	var ground_before: int = int(drops.call(&"live_count"))
	inventory.call("_on_harvest_yielded", &"probe", NetConfig.HOST_PEER_ID, &"stone", 3,
		Vector3(0.0, 0.0, 900.0))
	var pack_after: int = int(inventory.call("host_count", NetConfig.HOST_PEER_ID, &"stone"))
	var ground_after: int = int(drops.call(&"live_count"))
	check(pack_after > pack_before or ground_after > ground_before,
		"a yield always lands somewhere — pack %d -> %d, ground %d -> %d (one of them must move)"
			% [pack_before, pack_after, ground_before, ground_after])

	drops.call(&"host_clear_all")


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)
