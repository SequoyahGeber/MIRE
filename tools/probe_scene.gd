extends RefCounted

## Which world a renderer instrument measures (F-342).
##
## `tools/frame_cost_check.gd`, `tools/perf_probe.gd` and `tools/render_census.gd` each hard-coded
## `res://levels/hollowmere.tscn`. That was correct when Hollowmere was the game. It stopped being
## correct when `project.godot` switched `application/run/main_scene` to the procedural island, and
## nothing pointed the instruments at the new default — so the numbers those tools reported (4,864
## draw calls, 1.17M primitives, 278 MB VRAM, 9.35 ms) described a retired authored fixture while
## being quoted as the shipped game's performance. A performance claim about a world nobody boots is
## worse than no claim, because it reads as evidence.
##
## The default is now whatever `project.godot` actually boots, read at runtime rather than copied, so
## the next main-scene cutover cannot silently orphan the instruments again. An explicit fixture is
## still reachable — comparing against Hollowmere is a legitimate thing to want — but it has to be
## asked for:
##
##   .agent/bin/agent godot --windowed --script tools/frame_cost_check.gd -- --scene res://levels/hollowmere.tscn
##
## Authority: none (docs/ARCHITECTURE.md §2.2). Argument parsing for instruments.

## Only used if `application/run/main_scene` is somehow unset — a project with no main scene is
## already broken, but an instrument should say which world it measured rather than crash on it.
const FALLBACK_SCENE: String = "res://levels/procedural_island.tscn"


## The seed every renderer instrument generates its world from unless told otherwise. Arbitrary,
## and that is the point — what matters is that two runs get the SAME island.
const BENCH_SEED: int = 20260821


## Pins the world seed so two runs of an instrument measure the same island (F-452).
##
## `GameState.host_generate_seed()` draws real entropy when nothing has staged a seed, so an
## unpinned instrument generates a DIFFERENT world every launch — different hills, different
## biome mix, different prop count. Two runs of `tools/frame_cost_check.gd` an hour apart reported
## 4,908 and 3,325 draw calls on "the same" scene, and neither number was wrong: they were two
## islands. A before/after taken across a reseed is not a before/after at all, which makes it
## impossible to prove any optimization did anything.
##
## An explicit `--seed=` on the command line still wins, so measuring a specific island stays
## possible; this only supplies the default that entropy was supplying before. Call it BEFORE
## instantiating the level — the world reads its seed as it builds.
static func pin_seed(loop: SceneTree) -> int:
	var game_state: Node = loop.root.get_node_or_null(^"/root/GameState")
	if game_state == null:
		return 0
	# An explicit `--seed=` is the operator measuring a specific island; never override it.
	if _has_seed_arg():
		return int(game_state.get(&"run_seed"))
	# Solo/offline play draws its seed during autoload `_ready()` (F-172), so by the time an
	# instrument runs, `is_seed_ready` is ALREADY true and a staged pending seed would never be
	# consulted. Re-derive over it: nothing has built a world from the entropy seed yet, because
	# the instrument has not instantiated the level.
	game_state.call(&"set_pending_seed", BENCH_SEED)
	game_state.call(&"host_generate_seed")
	return int(game_state.get(&"run_seed"))


static func _has_seed_arg() -> bool:
	for source: PackedStringArray in [OS.get_cmdline_user_args(), OS.get_cmdline_args()]:
		for arg: String in source:
			if arg.begins_with("--seed="):
				return true
	return false


## The scene an instrument should measure: `-- --scene res://...` if given, else the project's
## shipped main scene.
static func resolve() -> String:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	for i: int in args.size():
		if args[i] == "--scene" and i + 1 < args.size():
			return args[i + 1]
	var main_scene: String = str(ProjectSettings.get_setting("application/run/main_scene", ""))
	if main_scene.is_empty():
		push_warning("probe_scene: application/run/main_scene is unset, falling back to %s"
			% FALLBACK_SCENE)
		return FALLBACK_SCENE
	return main_scene


## True when the resolved scene is the one the project boots. Instruments print this, because
## "measured the shipped world" and "measured a fixture" are different claims and a reader of the
## log should never have to work out which one they are holding.
static func is_shipped_default(scene_path: String) -> bool:
	return scene_path == str(ProjectSettings.get_setting("application/run/main_scene", ""))


## A one-line provenance banner for an instrument's header.
static func describe(scene_path: String) -> String:
	if is_shipped_default(scene_path):
		return "%s (the shipped main scene)" % scene_path
	return "%s (EXPLICIT FIXTURE — not what the project boots)" % scene_path


## Frames to wait, at most, for a streaming world to finish arriving. At 8 chunks of load radius the
## neighbourhood is 17x17 and the streamer holds itself to a 4 ms frame budget, so settling takes
## real time; a cap that is too tight silently reports a half-built world as a cheap one.
const SETTLE_MAX_FRAMES: int = 900

## Consecutive quiet frames before a world counts as settled. More than one because the streamer
## evaluates its rings on a 0.2 s interval, so a single frame with no pending job proves nothing.
const SETTLE_QUIET_FRAMES: int = 30


## Waits until `scene_root`'s chunk streamer has nothing left in flight, and reports what it saw.
##
## The instruments used to warm up for a fixed frame count, which was right for an authored level
## that arrived whole. The procedural default streams in over hundreds of frames, so the same fixed
## warmup measures a partly-built world — 388 surfaces where the settled world has far more — and
## reports it as the shipped game's cost. That is the same class of mistake as F-342 itself: a number
## that describes something other than what it claims to.
##
## Duck-typed on `pending_job_count`/`loaded_chunk_count` rather than a class check, so an authored
## fixture with no streamer settles instantly and a future streamer needs no change here.
static func settle(scene_root: Node) -> Dictionary:
	var streamer: Node = _find_streamer(scene_root)
	if streamer == null:
		return {"streaming": false, "frames": 0, "chunks": 0}

	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	var quiet: int = 0
	var frames: int = 0
	while frames < SETTLE_MAX_FRAMES:
		await tree.process_frame
		frames += 1
		if int(streamer.call(&"pending_job_count")) == 0:
			quiet += 1
			if quiet >= SETTLE_QUIET_FRAMES:
				break
		else:
			quiet = 0

	var chunks: int = int(streamer.call(&"loaded_chunk_count"))
	var settled: bool = frames < SETTLE_MAX_FRAMES
	if not settled:
		push_warning("probe_scene: world still streaming after %d frames (%d chunk(s) loaded) — "
			% [SETTLE_MAX_FRAMES, chunks]
			+ "the numbers below are a partly-built world, not steady state")
	return {"streaming": true, "frames": frames, "chunks": chunks, "settled": settled}


## The node that owns chunk streaming, found by capability. Returns null for a scene that has none.
static func _find_streamer(node: Node) -> Node:
	if node.has_method(&"pending_job_count") and node.has_method(&"loaded_chunk_count"):
		return node
	for child: Node in node.get_children():
		var found: Node = _find_streamer(child)
		if found != null:
			return found
	return null
