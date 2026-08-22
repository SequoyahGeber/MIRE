extends SceneTree

## F-287 — EnvironmentVfx across a procedural reseed.
##
## `ProceduralWorld.rebuild_for_seed()` re-derives the island INSIDE the existing current scene
## (F-258). Every other invalidation in `autoload/environment_vfx.gd` keys on the current scene's
## instance id, which that rebuild deliberately does not change, so the ended island's emitter sites
## used to survive it and the fixed pools ranked the new world's fires against the old world's
## ghosts. This proves the site set is REPLACED rather than appended to.
##
## A count cannot tell those two apart, which is why every assertion here is about positions.
##
## Four phases:
##   1. Boot a real procedural island on `BOOT_SEED` and record every emitter site on it.
##   2. Plant two known props: a GHOST under `PoiSites` (which the rebuild tears down) and a
##      SURVIVOR under the scene root (which it does not). The survivor is the regression guard for
##      the obvious wrong fix — clearing `_sites` outright on `run_restarted` would take the
##      authored map's emitters with it, because Hollowmere fires the same signal and rebuilds no
##      geometry, and its surviving nodes all carry `VFX_META` so a re-walk skips them forever.
##   3. The shipped trigger: `EventBus.run_restarted` with a new seed in `GameState`. Assert the
##      ghost is gone, the survivor is not, the old island's sites are all gone, and
##      `emitter_site_count` still equals the number of sites that actually exist.
##   4. The path NO signal announces: `rebuild_for_seed()` called directly, as a console reroll or
##      `tools/run_reseed_check.gd` phase 5 calls it. Nothing subscribes on that route, so the
##      periodic prune in `_process` is what has to catch it.
##
## Solo/offline, one process. `EnvironmentVfx` declares no network authority (`ARCHITECTURE.md`
## §2.2, "VFX, audio, camera, UI"): every peer runs this independently off its own scene, nothing
## here crosses the wire, and `run_restarted` reaches every peer already.
##
##   .agent/bin/agent godot --script tools/environment_vfx_reseed_check.gd

const ProceduralWorldScript := preload("res://world/gen/procedural_world.gd")
const AssetVfx := preload("res://world/environment/asset_vfx_library.gd")
const EVENT_BUS := preload("res://core/events/event_bus.gd")

const BOOT_SEED: int = 20260287
const RESTART_SEED: int = 424242
const REROLL_SEED: int = 990211

## The asset id the planted props claim. `station_campfire` is `Emitter.CAMPFIRE`, a fire class, so
## these props move `fire_source_count` as well as `emitter_site_count` and both counters are under
## test. Read through the library rather than assumed — a retune that moved this asset to another
## class would otherwise silently stop exercising the fire path.
const PROP_ASSET: String = "station_campfire"
## Far enough out that no generated site can land on one by accident, and far enough apart that
## `EnvironmentVfx.SITE_MERGE_DISTANCE` never folds the two together.
const GHOST_POSITION: Vector3 = Vector3(9000.0, 40.0, -9000.0)
const REROLL_GHOST_POSITION: Vector3 = Vector3(-9000.0, 40.0, 9000.0)
const SURVIVOR_POSITION: Vector3 = Vector3(9000.0, 40.0, 9000.0)
## Two sites are "the same site" within this, matching the merge distance the autoload registers by.
const SAME_SITE: float = 0.35
## How long the periodic prune may take to notice a teardown nothing announced. `BUDGET_INTERVAL` is
## 0.25 s of frame time and a headless frame is very short, so this is a generous ceiling, not a
## measurement — the check reports how many frames it actually took.
const PRUNE_FRAME_BUDGET: int = 4000
## How long to let the terrain stream in before calling an island empty. Chunk meshing, collision
## and scatter are each a frame or more apart by design (`ResourceScatterField` waits on
## `chunk_has_collision`), so this is several hundred frames of headroom over what it measures.
const STREAM_FRAME_BUDGET: int = 1200

var failures: int = 0
var vfx: Node = null
var world: Node3D = null
var scene: Node3D = null


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame
	var game_state: Node = root.get_node_or_null(^"GameState")
	vfx = root.get_node_or_null(^"EnvironmentVfx")
	check(game_state != null, "GameState autoload exists")
	check(vfx != null, "EnvironmentVfx is registered as an autoload")
	if game_state == null or vfx == null:
		await _finish()
		return

	await _phase_boot(game_state)
	if world == null:
		await _finish()
		return
	await _phase_restart(game_state)
	await _phase_reroll()
	await _finish()


# ── 1 · the island the run started on ────────────────────────────────────────────────────────────


func _phase_boot(game_state: Node) -> void:
	print("\n== VFX RESEED 1 · a procedural island on seed %d ==" % BOOT_SEED)
	scene = Node3D.new()
	scene.name = "VfxReseedCheckScene"
	root.add_child(scene)
	current_scene = scene

	game_state.call("set_replicated_seed", BOOT_SEED)
	world = ProceduralWorldScript.new()
	world.set(&"build_player", false)
	scene.add_child(world)
	await process_frame

	check(int(world.get(&"world_seed")) == BOOT_SEED,
		"the world booted on the seed under test (%d)" % int(world.get(&"world_seed")))
	check(AssetVfx.emitter_for(PROP_ASSET) == AssetVfx.Emitter.CAMPFIRE,
		"%s is still a fire class, so the planted props exercise fire_source_count too"
			% PROP_ASSET)

	var frames: int = await _stream_around_spawn()
	check(_total_sites() > 0,
		"the generated island itself registered emitter sites (%d, after %d frames) — without "
		% [_total_sites(), frames]
		+ "these the reseed assertions below would only ever see the planted props")
	print("BOOT sites=%d fires=%d foliage=%d sway_assets=%d frames=%d" % [
		_total_sites(), int(vfx.get("fire_source_count")),
		int(vfx.get("foliage_mesh_count")), int(vfx.get("sway_asset_count")), frames])


# ── 2/3 · the shipped trigger ────────────────────────────────────────────────────────────────────


func _phase_restart(game_state: Node) -> void:
	print("\n== VFX RESEED 2 · a known ghost and a known survivor ==")
	var poi_root: Node = world.get_node_or_null(^"PoiSites")
	check(poi_root != null, "the booted island has a PoiSites node to plant the ghost under")
	if poi_root == null:
		return
	_plant_prop(poi_root, "GhostCampfire", GHOST_POSITION)
	_plant_prop(scene, "SurvivorCampfire", SURVIVOR_POSITION)
	await process_frame
	await process_frame

	var before: PackedVector3Array = _all_sites()
	check(_holds_site(before, GHOST_POSITION),
		"the ghost prop registered a site before the restart")
	check(_holds_site(before, SURVIVOR_POSITION),
		"the survivor prop registered a site before the restart")
	var sway_before: int = int(vfx.get("sway_asset_count"))
	check(before.size() > 2,
		"the island itself contributed emitter sites too, so this is not a two-prop toy "
		+ "(%d sites)" % before.size())

	print("\n== VFX RESEED 3 · EventBus.run_restarted with a new seed ==")
	game_state.call("set_replicated_seed", RESTART_SEED)
	EVENT_BUS.emit_run_restarted()
	# Two frames: the handler's own deferred `_rediscover_world`, then `node_added`'s deferred pass
	# over everything the rebuild added behind it.
	for _frame: int in 10:
		await process_frame

	check(int(world.get(&"world_seed")) == RESTART_SEED,
		"run_restarted really did re-derive the island (seed %d)" % int(world.get(&"world_seed")))

	# The rebuild replaced the streamer with a new node, so the new island needs anchoring the same
	# way the boot did before any of its own scatter exists to register.
	var restream: int = await _stream_around_spawn()
	print("RESTREAM frames=%d" % restream)

	var after: PackedVector3Array = _all_sites()
	check(not _holds_site(after, GHOST_POSITION),
		"the torn-down island's emitter site is GONE — this is F-287 itself")
	check(_holds_site(after, SURVIVOR_POSITION),
		"a prop the rebuild did NOT free kept its site — the authored map, which fires the same "
		+ "signal and rebuilds nothing, must not go dark")

	# Every emitter-bearing node of the previous island lived under the derived subtree the rebuild
	# frees, so nothing but the survivor may appear in both sets. Positions, not counts: an appended
	# set and a replaced set of the same size are indistinguishable by count, which is the exact
	# blind spot that let this ship.
	var shared: int = 0
	for site: Vector3 in before:
		if site.distance_to(SURVIVOR_POSITION) <= SAME_SITE:
			continue
		if _holds_site(after, site):
			shared += 1
	check(shared == 0,
		"not one of the ended island's %d sites survived into the new one (%d did)"
			% [before.size() - 1, shared])
	check(after.size() > 1,
		"...and the new island was actually discovered, not merely cleared (%d sites)"
			% after.size())

	# The counters are published (`tools/environment_vfx_check.gd` and the Hollowmere check both
	# read them) and the finding names their growth directly: `emitter_site_count` climbed by a
	# whole island on every restart.
	check(int(vfx.get("emitter_site_count")) == after.size(),
		"emitter_site_count is a census of what exists (%d) not a running total (%d)"
			% [after.size(), int(vfx.get("emitter_site_count"))])
	# Recomputed from the classes rather than compared against the previous run's number: a new
	# seed may honestly have more fires than the old one, so only "matches what is registered
	# right now" separates a correct census from an accumulated one.
	check(int(vfx.get("fire_source_count")) == _fire_sites(),
		"fire_source_count is a census of the fire classes too (%d vs %d)"
			% [int(vfx.get("fire_source_count")), _fire_sites()])
	# `sway_asset_count` counts unique dressed MESHES, and the ended island's are freed with it, so
	# it is a census too and must not have climbed by an island. It reads one frame late by
	# construction (a Mesh has no `is_inside_tree()` and does not die until the frame's deletion
	# queue runs), which the ten frames above cover.
	check(int(vfx.get("sway_asset_count")) <= sway_before,
		"sway_asset_count did not carry the ended island's dressed meshes (%d -> %d)"
			% [sway_before, int(vfx.get("sway_asset_count"))])

	# Printed, not asserted: `foliage_mesh_count` is a per-NODE dressing tally with no per-node
	# record behind it, so unlike the four counters above it cannot be re-derived and pruned. It
	# still climbs by a whole island here — filed as its own finding rather than left silent.
	print("RESTART before=%d after=%d shared=%d foliage=%d sway_assets=%d" % [
		before.size(), after.size(), shared,
		int(vfx.get("foliage_mesh_count")), int(vfx.get("sway_asset_count"))])


# ── 4 · direct rebuild announces its completed generation boundary ───────────────────────────────


func _phase_reroll() -> void:
	print("\n== VFX RESEED 4 · rebuild_for_seed() called directly emits world_rebuilt ==")
	var poi_root: Node = world.get_node_or_null(^"PoiSites")
	check(poi_root != null, "the rebuilt island has a PoiSites node")
	if poi_root == null:
		return
	_plant_prop(poi_root, "RerollGhostCampfire", REROLL_GHOST_POSITION)
	await process_frame
	await process_frame
	check(_holds_site(_all_sites(), REROLL_GHOST_POSITION),
		"the second ghost registered before the reroll")

	world.call("rebuild_for_seed", REROLL_SEED)
	var frames: int = 0
	while frames < PRUNE_FRAME_BUDGET and _holds_site(_all_sites(), REROLL_GHOST_POSITION):
		frames += 1
		await process_frame

	check(not _holds_site(_all_sites(), REROLL_GHOST_POSITION),
		"world_rebuilt retired a site whose prop was freed with no run_restarted to hear "
		+ "(%d frames)" % frames)
	check(frames <= 1, "the direct reroll ghost survives at most one rendered frame (%d)" % frames)
	check(_holds_site(_all_sites(), SURVIVOR_POSITION),
		"...and still did not touch the prop that is still standing")
	check(int(vfx.get("emitter_site_count")) == _total_sites(),
		"...and the census still matches the arrays (%d vs %d)"
			% [int(vfx.get("emitter_site_count")), _total_sites()])
	print("REROLL prune_frames=%d sites=%d" % [frames, _total_sites()])


# ── helpers ──────────────────────────────────────────────────────────────────────────────────────


## Stream the island in around its own spawn, and wait for the scatter to register emitters.
##
## Nothing else does this here. `ChunkStreamer.set_anchors()` is normally called once a tick with
## the local player's position, and this harness boots with `build_player = false` (the same switch
## `tools/run_reseed_check.gd` uses) — so with no anchor the streamer meshes nothing, no chunk
## reaches LOD0 with collision, `ResourceScatterField` builds no holder, and the island registers
## exactly zero emitter sites however long it is left alone. Measured: this check's first run had
## `before=2`, both of them its own planted props.
##
## Returns the number of frames it took, so a future slowdown reads as a number rather than as a
## check that quietly waits longer.
func _stream_around_spawn() -> int:
	var streamer: Node = world.get(&"streamer") as Node
	if streamer == null:
		return 0
	var spawn: Vector3 = world.get(&"spawn_position")
	streamer.call("set_anchors", PackedVector3Array([spawn]))
	var frames: int = 0
	var before: int = _total_sites()
	while frames < STREAM_FRAME_BUDGET:
		frames += 1
		await process_frame
		# Anchors are a per-tick contract, not a setting — re-stated every frame, which is what the
		# player's own `_process` does.
		streamer.call("set_anchors", PackedVector3Array([spawn]))
		if _total_sites() > before:
			break
	# A few more frames so the whole first ring of chunks lands, not just the one that tripped the
	# loop — the assertions below compare SETS of island sites, so a half-streamed island would make
	# the "nothing survived" comparison weaker than it looks.
	for _extra: int in 30:
		await process_frame
		streamer.call("set_anchors", PackedVector3Array([spawn]))
	return frames


## A minimal emitter-bearing prop: the generator contract is a node with an `asset` meta, and
## `EnvironmentVfx` reads nothing else about it. No mesh is needed — `station_campfire` has no sway
## profile, so nothing here walks a surface.
func _plant_prop(parent: Node, node_name: String, position: Vector3) -> void:
	var prop := MeshInstance3D.new()
	prop.name = node_name
	prop.set_meta(&"asset", PROP_ASSET)
	parent.add_child(prop)
	prop.global_position = position


func _all_sites() -> PackedVector3Array:
	var out: PackedVector3Array = PackedVector3Array()
	var positions: Dictionary = vfx.call(&"site_positions")
	for emitter: int in positions:
		for site: Vector3 in positions[emitter] as PackedVector3Array:
			out.append(site)
	return out


## The registered sites belonging to the classes `EnvironmentVfx.fire_source_count` counts.
func _fire_sites() -> int:
	var fires: int = 0
	var positions: Dictionary = vfx.call(&"site_positions")
	for emitter: int in positions:
		if emitter == AssetVfx.Emitter.CAMPFIRE or emitter == AssetVfx.Emitter.FORGE \
				or emitter == AssetVfx.Emitter.EMBER:
			fires += (positions[emitter] as PackedVector3Array).size()
	return fires


func _total_sites() -> int:
	return _all_sites().size()


func _holds_site(sites: PackedVector3Array, position: Vector3) -> bool:
	for site: Vector3 in sites:
		if site.distance_to(position) <= SAME_SITE:
			return true
	return false


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func _finish() -> void:
	# Let every procedural node leave the tree and release renderer resources before SceneTree quits.
	# Quitting against the live world turns ordinary deferred destruction into a false leak verdict.
	if is_instance_valid(scene):
		current_scene = null
		scene.queue_free()
		await process_frame
		await process_frame
		world = null
		scene = null
	# Real imported meshes exercise Godot's dummy renderer in this headless check. These messages
	# are renderer limitations rather than gameplay failures; every other ERROR remains undeclared.
	print(("\nENVIRONMENT_VFX_RESEED_CHECK failures=%d" % failures)
		+ " · EXPECTED_ERROR_PATTERNS=\"Attempting to (initialize the wrong|use an uninitialized) RID"
		+ "|Parameter \\\"(mem|m)\\\" is null|unimplemented base type encountered in renderer scene cull"
		+ "|RID allocations? of type .*DummyMesh.* leaked at exit|resources still in use at exit\"")
	quit(1 if failures > 0 else 0)
