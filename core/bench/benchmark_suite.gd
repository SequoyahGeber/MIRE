extends RefCounted

## The scenes a benchmark run walks, and what each one is for.
##
## This is a table, not a script: every entry is plain data, and `core/bench/benchmark_runner.gd`
## is the only thing that knows how to stage one. Keeping them apart is what lets
## `tools/benchmark_check.gd` assert the shape and the ordering of the suite without a renderer,
## and what lets a scene be added by editing one array.
##
## ## Why these, and why each of them twice
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
## **Every situation is measured twice — once by day and once by night** (F-458). Night is not a
## minor variant of this game: it is when the waves come, when every point light refreshes its
## shadow, when the ground fog and the stars are up, and when the frame is most likely to miss the
## target. The first version of this suite ran seven day scenes against two night ones, which
## weighted the whole recommendation toward the easy half of the game. Pairing them makes the split
## equal by construction rather than by somebody counting rows, and it doubles as the honest
## before/after for every lighting cost in the build.
##
## The order is deliberate and load-bearing. Cheap-and-static first, so a machine that cannot hold
## the target even on the shore learns that in the first twenty seconds. Then the whole DAY block,
## then the whole NIGHT block — crossing into darkness is a one-way step that fires `night_started`,
## so it happens exactly once, half way through, rather than being toggled back and forth. Within
## each block the wave goes last, because it is the only scene that leaves anything behind, and
## what it leaves is despawned before the next scene starts.
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

## How many enemies each wave scene puts around the player. Six is a mid-run night wave rather
## than a worst case — the point is to price skinned meshes and nav against everything else in the
## table, and a number so large it never occurs in play would price a situation that never happens.
const COMBAT_ENEMIES: int = 6

## Time of day the night scenes run at. 02:00 is the middle of the dark half — far enough from
## either threshold that the sample is not measuring a sunrise transition.
const NIGHT_TIME_OF_DAY: float = 2.0 / 24.0
## Mid-morning: the run's own start time, so the day scenes measure what a player opens on.
const DAY_TIME_OF_DAY: float = 8.35 / 24.0

## How the camera moves in a scene. `still` stands where it was put; `walk` sprints through the
## world at ground level; `fly` crosses the island from above. Anything other than `still` means the
## streamer is building around a moving anchor, which is why `SettingsAdvisor.preset_basis()`
## excludes them all from choosing a preset (D-194) — that cost is not a cost a preset can change.
const MOTION_STILL: StringName = &"still"
const MOTION_WALK: StringName = &"walk"
const MOTION_FLY: StringName = &"fly"

## The flyover (F-458). Altitude clears the tallest ground the seed survey found (46 m) with room to
## spare, so the camera never clips a hill; the pitch is a map-reading angle rather than straight
## down, which would show texture and no silhouette. The speed is chosen so a single sample crosses
## a few hundred metres of island — fast enough that the streamer is continuously building a large
## neighbourhood, which together with the full draw distance is what this scene is pricing.
const FLY_ALTITUDE_M: float = 90.0
const FLY_SPEED: float = 40.0
const FLY_PITCH_DEGREES: float = -32.0


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
	var out: Array[Dictionary] = []
	for night: bool in [false, true]:
		for situation: Dictionary in situations():
			var scene: Dictionary = situation.duplicate()
			scene["id"] = StringName("%s_%s" % [situation["id"], "night" if night else "day"])
			scene["label"] = "%s — %s" % [situation["label"], "night" if night else "day"]
			scene["night"] = night
			scene["travel"] = StringName(situation.get("motion", MOTION_STILL)) != MOTION_STILL
			out.append(scene)
	return out


## The situations, independent of time of day. Keys:
##
##   `id`        stable identifier. The scene id is this plus `_day` / `_night`, and it is the
##               ledger's resume key — NEVER renamed, or an interrupted run re-measures scenes it
##               had already finished.
##   `label`     what the player sees while it runs
##   `stresses`  one line naming what this situation is pricing, shown next to its row
##   `where`     destination, resolved by the runner: `spawn`, `biome:<id>`, `poi`, `mire`, `vista`,
##               `flyover`
##   `motion`    `MOTION_STILL`, `MOTION_WALK` or `MOTION_FLY`
##   `enemies`   how many enemies to spawn around the player before sampling
static func situations() -> Array[Dictionary]:
	return [
		{
			"id": &"shore",
			"label": "Shoreline",
			"stresses": "open water and near-empty ground — the cheapest view in the game",
			"where": "spawn", "motion": MOTION_STILL, "enemies": 0,
		},
		{
			"id": &"forest",
			"label": "Deep forest",
			"stresses": "the densest foliage the scatter places: canopy, undergrowth, alpha",
			"where": "biome:forest", "motion": MOTION_STILL, "enemies": 0,
		},
		{
			"id": &"marsh",
			"label": "Marshland",
			"stresses": "water surfaces, ground fog and wet-ground materials over open sightlines",
			"where": "biome:marsh", "motion": MOTION_STILL, "enemies": 0,
		},
		{
			"id": &"vista",
			"label": "Highland vista",
			"stresses": "long sightlines — nothing culled by terrain, every draw-distance ring live",
			"where": "vista", "motion": MOTION_STILL, "enemies": 0,
		},
		{
			"id": &"poi",
			"label": "Ruins",
			"stresses": "an instanced point-of-interest: the densest draw-call cluster in the world",
			"where": "poi", "motion": MOTION_STILL, "enemies": 0,
		},
		{
			"id": &"mire",
			"label": "The Mire",
			"stresses": "the corruption field: a whole-ground shader sample plus its particles",
			"where": "mire", "motion": MOTION_STILL, "enemies": 0,
		},
		{
			"id": &"flyover",
			"label": "Flyover",
			"stresses": "the island from above: full draw distance, and the streamer building a "
				+ "large neighbourhood around a fast anchor",
			"where": "flyover", "motion": MOTION_FLY, "enemies": 0,
		},
		{
			"id": &"traverse",
			"label": "Running inland",
			"stresses": "chunk streaming, meshing and nav baking while you move — where hitches live",
			"where": "spawn", "motion": MOTION_WALK, "enemies": 0,
		},
		# LAST in each block: the only situation that leaves anything behind. The runner despawns
		# what it spawned before the next scene starts, so this ordering is belt to that braces.
		{
			"id": &"wave",
			"label": "Under attack",
			"stresses": "skinned meshes, animation and navigation — main-thread work a GPU cannot help",
			"where": "biome:forest", "motion": MOTION_STILL, "enemies": COMBAT_ENEMIES,
		},
	]


## Wall-clock estimate for a full run, in seconds, excluding world generation. Shown to the player
## before they commit to it — "this takes about two minutes" is the difference between a benchmark
## people run and one they alt-F4 out of.
static func estimated_seconds() -> float:
	return float(scenes().size()) * (SAMPLE_SECONDS + SETTLE_SECONDS)


## How many scenes run by day and how many by night. Equal by construction — `tools/benchmark_check.gd`
## asserts it rather than trusting this comment.
static func day_night_counts() -> Vector2i:
	var day: int = 0
	var night: int = 0
	for scene: Dictionary in scenes():
		if bool(scene.get("night", false)):
			night += 1
		else:
			day += 1
	return Vector2i(day, night)


static func scene_by_id(id: StringName) -> Dictionary:
	for scene: Dictionary in scenes():
		if scene["id"] == id:
			return scene
	return {}
