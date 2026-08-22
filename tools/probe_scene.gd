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


## The front end, which `run/main_scene` points at since MENU-3's cutover. A path rather than a
## `preload`, because a `--script` harness compiles before the autoloads exist and this file names
## an autoload (F-558).
const FRONTEND_SCRIPT_PATH: String = "res://ui/frontend/frontend.gd"


## What `run/main_scene` literally says.
static func main_scene_path() -> String:
	return str(ProjectSettings.get_setting("application/run/main_scene", ""))


## The scene an instrument should measure: `-- --scene res://...` if given, else the shipped map.
static func resolve() -> String:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	for i: int in args.size():
		if args[i] == "--scene" and i + 1 < args.size():
			return args[i + 1]
	return shipped_map_path()


## The MAP the project boots into — which is not `run/main_scene` any more (F-561).
##
## MENU-3's cutover pointed `run/main_scene` at `res://levels/frontend.tscn`. The front end is not a
## world: measuring it produced `draw_calls_median=2206 primitives_median=538344 vram_mb=470.9
## frame_ms_median=35.71` published under the banner "the shipped main scene". 35.71 ms is 28 fps,
## and it described a menu.
##
## That is the SAME failure F-342 exists for, arriving from the other direction. F-342's fix was
## "read `main_scene` at runtime instead of copying it," and that fix is what broke here, because
## `main_scene` stopped naming a map. So the question an instrument has to ask is not "what does the
## project boot?" but "what world does a player end up in?" — and only the front end can answer it.
##
## It is also not merely mislabelled. `_begin_run()` uses `change_scene_to_file()`, which is
## DEFERRED, so an instrument that instantiates `frontend.tscn` and starts sampling is racing the
## bypass: it may measure the front end, the world, or both in the tree at once. F-549 caught that
## third case for real — every group count in `world_contract_check` doubled.
static func shipped_map_path() -> String:
	var main_scene: String = main_scene_path()
	if main_scene.is_empty():
		push_warning("probe_scene: application/run/main_scene is unset, falling back to %s"
			% FALLBACK_SCENE)
		return FALLBACK_SCENE
	var behind: String = _map_behind_front_end(main_scene)
	return behind if not behind.is_empty() else main_scene


## The world `scene_path` bypasses into, or "" when it is not the front end.
##
## Instantiating to ask is safe, and deliberately chosen over parsing the scene: `_ready()` runs when
## a node ENTERS THE TREE, not when it is instantiated, so the bypass this whole finding is about
## cannot fire here. The instance is freed immediately and never added to anything.
##
## The answer comes from `Frontend._world_scene_path()` — static for exactly this reason (F-549) —
## rather than from a path spelled out here, so this file cannot silently disagree with the game the
## first time `WORLD_SCENE_FALLBACK` matters.
static func _map_behind_front_end(scene_path: String) -> String:
	var packed: PackedScene = load(scene_path) as PackedScene
	if packed == null:
		return ""
	var frontend_script: Variant = load(FRONTEND_SCRIPT_PATH)
	if frontend_script == null:
		return ""
	var probe: Node = packed.instantiate()
	var is_front_end: bool = probe.get_script() == frontend_script
	probe.free()
	if not is_front_end:
		return ""
	return String(frontend_script._world_scene_path())


## True when the resolved scene is the world the project actually boots into. Instruments print this,
## because "measured the shipped world" and "measured a fixture" are different claims and a reader of
## the log should never have to work out which one they are holding.
static func is_shipped_default(scene_path: String) -> bool:
	return scene_path == shipped_map_path()


## A one-line provenance banner for an instrument's header.
##
## When the front end was followed through, the banner says so rather than calling the map "the
## shipped main scene" — that phrase is now false about any map, and a provenance line that is
## subtly wrong is worse than a vague one.
static func describe(scene_path: String) -> String:
	if not is_shipped_default(scene_path):
		return "%s (EXPLICIT FIXTURE — not what the project boots)" % scene_path
	var main_scene: String = main_scene_path()
	if scene_path == main_scene:
		return "%s (the shipped main scene)" % scene_path
	return "%s (the world the shipped front end %s boots into)" % [scene_path, main_scene]


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
