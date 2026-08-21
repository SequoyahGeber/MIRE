extends RefCounted

## The scenes a benchmark run walks, and what each one is for.
##
## This is a table, not a script: every entry is plain data, and `core/bench/benchmark_runner.gd`
## is the only thing that knows how to stage one. Keeping them apart is what lets
## `tools/benchmark_check.gd` assert the shape and the ordering of the suite without a renderer,
## and what lets a scene be added by editing one array.
##
## ## Why these nine
##
## A benchmark that samples one view of one place measures that place. MIRE is a procedurally
## generated island whose cost is wildly uneven across it — a shore at dusk and a forest at night
## with a wave in it are not the same game — so a recommendation drawn from one view is a
## recommendation for one view. The suite covers the axes that actually move the frame, each
## isolated enough to name what convicted it:
##
##   * geometry density        shore (almost none) vs forest (the most the scatter ever places)
##   * streaming               standing still vs sprinting into unbuilt chunks (F-452's finding
##                             that traversal is the ONLY condition the hitch appears in)
##   * authored scene content  a POI's instanced buildings, which are the densest draw-call
##                             cluster in the world
##   * shader and VFX cost     the Mire's corruption field, which samples a texture over the whole
##                             ground and drives particles
##   * lighting                day (one sun, four cascades) vs night (moon, stars, ground fog,
##                             every point light in range re-rendering its shadow)
##   * skinned meshes and AI   a live wave, which is main-thread nav and animation, not fill
##   * draw distance           a high vista where nothing is culled by terrain
##
## The order is deliberate and load-bearing. Cheap-and-static first, so a machine that cannot hold
## the target even on the shore learns that in the first ten seconds; the two scenes that MUTATE
## the world irreversibly (night crosses 18:00 and fires `night_started`; the wave spawns enemies
## that stay) go last, so nothing after them is measured in a world they changed. This is the same
## reason `perf_probe`'s night row is its second-to-last.
##
## AUTHORITY: none (docs/ARCHITECTURE.md §2.2, "VFX, audio, camera, UI" row) — the benchmark runs
## in its own single-player world and replicates nothing.

## Seconds of frame sampling per scene. At 60 fps that is ~360 frames, so the worst 1% is the
## three-frame floor `FrameSampler.MIN_TAIL_FRAMES` sets; at 140 fps it is ~840 and the tail has
## eight frames to average. Shorter than `perf_probe`'s 5 s per row is tempting because there are
## eight of these, but the 1% low is the number the whole recommendation turns on and a short
## sample makes it noise.
const SAMPLE_SECONDS: float = 6.0

## Seconds between arriving somewhere and starting to sample, on top of `FrameSampler`'s discarded
## frames. Teleporting re-anchors the chunk streamer, and the world it has to build around the new
## position is not a cost of *standing* there.
const SETTLE_SECONDS: float = 2.0

## Metres per second the traversal scene moves. Roughly sprint speed — fast enough that the
## streamer is continuously building, which is the condition Sequoyah described on 2026-08-21:
## "it really only shows the lag and performance hit when you move and force the game to load new
## terrain".
const TRAVEL_SPEED: float = 7.0

## How many enemies the combat scene puts around the player. Six is a mid-run night wave rather
## than a worst case — the point is to price skinned meshes and nav against everything else in the
## table, and a number so large it never occurs in play would price a situation that never happens.
const COMBAT_ENEMIES: int = 6

## Time of day the night scenes run at. 02:00 is the middle of the dark half — far enough from
## either threshold that the sample is not measuring a sunrise transition.
const NIGHT_TIME_OF_DAY: float = 2.0 / 24.0
## Mid-morning: the run's own start time, so the day scenes measure what a player opens on.
const DAY_TIME_OF_DAY: float = 8.35 / 24.0


## Every scene, in run order. Keys:
##
##   `id`        stable identifier — the ledger key and the resume key. NEVER renamed: a renamed
##               id silently re-runs a scene an interrupted run had already finished.
##   `label`     what the player sees while it runs
##   `stresses`  one line naming what this scene is pricing, shown next to its row in the results
##   `where`     destination, resolved by the runner: `spawn`, `biome:<id>`, `poi`, `mire`, `vista`
##   `travel`    true to sprint through the world while sampling instead of standing still
##   `night`     true to run at `NIGHT_TIME_OF_DAY`
##   `enemies`   how many enemies to spawn around the player before sampling
##   `mutates`   true if this scene leaves the world changed. Documentation for the reader and an
##               assertion for `tools/benchmark_check.gd`, which fails if a mutating scene is
##               ordered before a non-mutating one.
static func scenes() -> Array[Dictionary]:
	return [
		{
			"id": &"shore",
			"label": "Shoreline",
			"stresses": "open water and near-empty ground — the cheapest view in the game",
			"where": "spawn", "travel": false, "night": false, "enemies": 0, "mutates": false,
		},
		{
			"id": &"forest",
			"label": "Deep forest",
			"stresses": "the densest foliage the scatter places: canopy, undergrowth, alpha",
			"where": "biome:forest", "travel": false, "night": false, "enemies": 0,
			"mutates": false,
		},
		{
			"id": &"marsh",
			"label": "Marshland",
			"stresses": "water surfaces, ground fog and wet-ground materials over open sightlines",
			"where": "biome:marsh", "travel": false, "night": false, "enemies": 0, "mutates": false,
		},
		{
			"id": &"vista",
			"label": "Highland vista",
			"stresses": "long sightlines — nothing culled by terrain, every draw-distance ring live",
			"where": "vista", "travel": false, "night": false, "enemies": 0, "mutates": false,
		},
		{
			"id": &"poi",
			"label": "Ruins",
			"stresses": "an instanced point-of-interest: the densest draw-call cluster in the world",
			"where": "poi", "travel": false, "night": false, "enemies": 0, "mutates": false,
		},
		{
			"id": &"mire",
			"label": "The Mire",
			"stresses": "the corruption field: a whole-ground shader sample plus its particles",
			"where": "mire", "travel": false, "night": false, "enemies": 0, "mutates": false,
		},
		{
			"id": &"traverse",
			"label": "Running inland",
			"stresses": "chunk streaming, meshing and nav baking while you move — where hitches live",
			"where": "spawn", "travel": true, "night": false, "enemies": 0, "mutates": false,
		},
		# ── from here the world is changed and stays changed ──────────────────────────────────
		{
			"id": &"night",
			"label": "Night",
			"stresses": "moonlight, stars, ground fog and every point light refreshing its shadow",
			"where": "biome:forest", "travel": false, "night": true, "enemies": 0, "mutates": true,
		},
		{
			"id": &"combat",
			"label": "Night wave",
			"stresses": "skinned meshes, animation and navigation — main-thread work a GPU cannot help",
			"where": "biome:forest", "travel": false, "night": true, "enemies": COMBAT_ENEMIES,
			"mutates": true,
		},
	]


## Wall-clock estimate for a full run, in seconds, excluding world generation. Shown to the player
## before they commit to it — "this takes about two minutes" is the difference between a benchmark
## people run and one they alt-F4 out of.
static func estimated_seconds() -> float:
	return float(scenes().size()) * (SAMPLE_SECONDS + SETTLE_SECONDS)


static func scene_by_id(id: StringName) -> Dictionary:
	for scene: Dictionary in scenes():
		if scene["id"] == id:
			return scene
	return {}
