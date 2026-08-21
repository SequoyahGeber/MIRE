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
