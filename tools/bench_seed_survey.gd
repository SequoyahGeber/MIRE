extends SceneTree

## Chooses the island the benchmark measures (F-458).
##
##   .agent/bin/agent godot --script tools/bench_seed_survey.gd
##   .agent/bin/agent godot --script tools/bench_seed_survey.gd -- --count 400 --top 10
##
## `BenchmarkRunner.BENCH_SEED` has to be a fixed number — two runs of a benchmark must measure the
## same island or nothing can be compared (docs/PERFORMANCE.md §1, rule 5). It does NOT have to be
## an arbitrary one, and it was: `20260821`, a date, picked because a constant was needed and
## nothing had looked at what it generates.
##
## That matters more than it sounds. The suite visits a marsh, a forest, a highland vista, ruins and
## the Mire. Every one of those destinations falls back to somewhere else when the island does not
## contain it, so an island short on highland quietly measures the shore twice and reports it as
## coverage. The benchmark is supposed to be representative; the seed is where that starts.
##
## So this surveys candidates and scores each on what the suite actually needs — every biome present
## and none of them vestigial, enough POIs and enough different kinds of them, a sensible amount of
## land, and real elevation — then prints the ranking. The winner is pinned by hand into
## `BenchmarkRunner.BENCH_SEED` with the survey's output quoted next to it, so the choice is
## reviewable and can be re-made when worldgen moves (it has moved twice this month: F-447 doubled
## the island, F-450 tripled its height).
##
## Authority: none — an offline survey tool. It generates no world and instantiates no scene; it
## samples the generator's static functions directly, which is why it can score hundreds of seeds
## in the time one world takes to build.

const IslandHeightmap := preload("res://world/gen/island_heightmap.gd")
const BiomeMap := preload("res://world/gen/biome_map.gd")
const PoiMap := preload("res://world/gen/poi_map.gd")

## Candidates surveyed by default. Enough to make the top of the ranking a real choice rather than
## the best of a handful, and small enough to finish in about a minute.
const DEFAULT_COUNT: int = 250
const DEFAULT_TOP: int = 8

## Where candidates come from. Sequential from a fixed base rather than random, so this tool's own
## output is reproducible — re-running it must rank the same seeds the same way, or the pinned
## choice cannot be audited later.
const SEED_BASE: int = 20260000

## The sampling grid, in metres. This has to be WIDER than the island or the land fraction measures
## nothing: at +-240 m every candidate reported 83-97% land, because the window sat entirely inside
## the coastline. F-447 doubled the island and F-450 raised it; +-700 m clears the current one with
## sea to spare, and a 20 m step is 71x71 = 5,041 samples per seed.
const SAMPLE_HALF_EXTENT_M: float = 700.0
const SAMPLE_STEP_M: float = 20.0

## Above this height a sample is land. Matches `BenchmarkRunner.MIN_STANDING_HEIGHT_M` — a scene
## cannot be measured from anywhere lower, so ground below it is not coverage.
const LAND_HEIGHT_M: float = 0.6

## A biome occupying less of the land than this is present in name only: the destination search
## will find one point of it, on the far side of the island, wedged between two others. Counted as
## missing.
const VESTIGIAL_SHARE: float = 0.02

## Land area and peak height are scored against the MEDIAN of the candidates rather than against
## constants. The benchmark wants a TYPICAL island — one whose numbers a player's own run will
## resemble — and "typical" is a property of the distribution, not something to guess at. It also
## means this tool does not need re-tuning every time worldgen changes the island's size, which it
## has done twice this month; the two constants it used to hold were already wrong when written.


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var count: int = _int_arg("--count", DEFAULT_COUNT)
	var top: int = _int_arg("--top", DEFAULT_TOP)
	var registry: Node = root.get_node_or_null(^"/root/Registry")
	if registry == null:
		push_error("bench_seed_survey needs the Registry autoload for biome and POI definitions")
		quit(1)
		return
	var biome_defs: Array = (registry.get(&"biomes") as Dictionary).values()
	var poi_defs: Array = (registry.get(&"poi") as Dictionary).values()
	var biome_ids: PackedStringArray = []
	for definition: Resource in biome_defs:
		biome_ids.append(String(definition.get(&"id")))
	biome_ids.sort()

	print("\n=== benchmark seed survey (F-458) ===")
	print("%d candidate(s) from %d | %d biome(s): %s | %d POI kind(s)" % [
		count, SEED_BASE, biome_ids.size(), ", ".join(biome_ids), poi_defs.size()])
	print("scoring: every biome present and none under %.0f%% of land, evenly spread; POI count "
		% (VESTIGIAL_SHARE * 100.0) + "and variety; an island of typical size with typical or "
		+ "better high ground")

	# Pass one: measure every candidate. Pass two: score them against the distribution they form.
	var scored: Array[Dictionary] = []
	for index: int in count:
		var candidate: int = SEED_BASE + index
		scored.append(_survey(candidate, biome_defs, poi_defs, biome_ids))
		if index % 25 == 24:
			print("  ... %d/%d" % [index + 1, count])

	var median_land: float = _median(scored, "land_fraction")
	var median_peak: float = _median(scored, "peak")
	print("typical island across these candidates: %.0f%% land, %.1f m peak"
		% [median_land * 100.0, median_peak])
	for entry: Dictionary in scored:
		_score(entry, biome_ids, median_land, median_peak)

	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["score"]) > float(b["score"]))

	print("\n  %-10s %6s  %5s %5s %5s  %-7s  %s" % [
		"seed", "score", "land", "peak", "pois", "kinds", "biome shares (% of land)"])
	for rank: int in mini(top, scored.size()):
		_print_row(scored[rank], biome_ids)

	var winner: Dictionary = scored[0]
	print("\nBest: %d — score %.3f" % [int(winner["seed"]), float(winner["score"])])
	for note: String in winner["notes"]:
		print("  %s" % note)
	print("\nPin it as `BenchmarkRunner.BENCH_SEED`, and paste the row above beside it.")
	quit(0)


## One candidate's coverage, and what it scores.
func _survey(candidate: int, biome_defs: Array, poi_defs: Array,
		biome_ids: PackedStringArray) -> Dictionary:
	var island_set: IslandHeightmap.NoiseSet = IslandHeightmap.make_noise_set(candidate)
	var biome_set: BiomeMap.NoiseSet = BiomeMap.make_noise_set(candidate, island_set)

	var counts: Dictionary = {}
	for id: String in biome_ids:
		counts[id] = 0
	var land: int = 0
	var total: int = 0
	var peak: float = 0.0

	var extent: float = SAMPLE_HALF_EXTENT_M
	var step: float = SAMPLE_STEP_M
	var x: float = -extent
	while x <= extent:
		var z: float = -extent
		while z <= extent:
			total += 1
			var height: float = IslandHeightmap.height_from_set(x, z, island_set, candidate)
			if height >= LAND_HEIGHT_M:
				land += 1
				peak = maxf(peak, height)
				var id: String = String(BiomeMap.biome_at_from_set(
					x, z, biome_set, candidate, biome_defs))
				if counts.has(id):
					counts[id] = int(counts[id]) + 1
			z += step
		x += step

	var sites: Array[Dictionary] = PoiMap.sites_for_island(candidate, poi_defs, biome_defs)
	var kinds: Dictionary = {}
	for site: Dictionary in sites:
		kinds[String(site.get("def_id", ""))] = true

	var shares: Dictionary = {}
	for id: String in biome_ids:
		shares[id] = (float(counts[id]) / float(maxi(land, 1)))

	return {
		"seed": candidate,
		"land_fraction": float(land) / float(maxi(total, 1)),
		"peak": peak,
		"pois": sites.size(),
		"poi_kinds": kinds.size(),
		"poi_kinds_available": poi_defs.size(),
		"shares": shares,
	}


## The scoring function, stated in one place so the choice can be argued with.
##
## Biome coverage dominates deliberately, because it is the one thing that silently degrades the
## suite: a missing biome does not fail, it substitutes, and the report still prints nine scenes.
## Everything else is a smaller adjustment on top.
func _score(entry: Dictionary, biome_ids: PackedStringArray, median_land: float,
		median_peak: float) -> void:
	var shares: Dictionary = entry["shares"]
	var notes: PackedStringArray = []

	# 1. Every biome present, and none of them vestigial. The floor share is what stops a seed
	#    scoring well on a marsh that is four samples wide.
	var present: int = 0
	var weakest: float = 1.0
	var weakest_id: String = ""
	for id: String in biome_ids:
		var share: float = float(shares[id])
		if share >= VESTIGIAL_SHARE:
			present += 1
		if share < weakest:
			weakest = share
			weakest_id = id
	var coverage: float = float(present) / float(maxi(biome_ids.size(), 1))

	# 2. Evenness. A seed where one biome is 70% of the land technically has them all, and the
	#    forest scene and the marsh scene would then measure adjacent parts of the same wood.
	#    Normalised Shannon entropy over the biome shares: 1.0 is a perfectly even spread.
	var entropy: float = 0.0
	for id: String in biome_ids:
		var share: float = float(shares[id])
		if share > 0.0:
			entropy -= share * log(share)
	var evenness: float = entropy / log(float(maxi(biome_ids.size(), 2)))

	# 3. POIs — the ruins scene needs one with a scene to instance, and variety keeps the island
	#    from being six copies of the same site.
	var poi_score: float = clampf(float(entry["pois"]) / 24.0, 0.0, 1.0)
	var kind_score: float = float(entry["poi_kinds"]) \
		/ float(maxi(int(entry["poi_kinds_available"]), 1))

	# 4. An island of typical size, and a peak at least as tall as typical — the highland vista
	#    scene is only a vista if there is high ground to stand on, and an island much smaller or
	#    much larger than usual is not the world a player's own run will look like.
	var land_score: float = 1.0 - clampf(
		absf(float(entry["land_fraction"]) - median_land) / maxf(median_land, 0.001), 0.0, 1.0)
	var peak_score: float = clampf(float(entry["peak"]) / maxf(median_peak, 0.001), 0.0, 1.0)

	entry["score"] = coverage * 0.40 + evenness * 0.20 + poi_score * 0.10 \
		+ kind_score * 0.10 + land_score * 0.10 + peak_score * 0.10
	entry["coverage"] = coverage
	entry["evenness"] = evenness

	notes.append("%d/%d biomes above %.0f%% of land (weakest: %s at %.1f%%)" % [
		present, biome_ids.size(), VESTIGIAL_SHARE * 100.0, weakest_id, weakest * 100.0])
	notes.append("evenness %.2f | land %.0f%% | peak %.1f m" % [
		evenness, float(entry["land_fraction"]) * 100.0, float(entry["peak"])])
	notes.append("%d POI site(s) across %d of %d kind(s)" % [
		int(entry["pois"]), int(entry["poi_kinds"]), int(entry["poi_kinds_available"])])
	entry["notes"] = notes


## Median rather than mean: one freak candidate — an island that barely formed, or one that filled
## the whole window — must not move the definition of typical that every other seed is judged by.
func _median(entries: Array[Dictionary], key: String) -> float:
	var values: PackedFloat64Array = []
	for entry: Dictionary in entries:
		values.append(float(entry[key]))
	if values.is_empty():
		return 0.0
	values.sort()
	return values[values.size() / 2]


func _print_row(entry: Dictionary, biome_ids: PackedStringArray) -> void:
	var shares: Dictionary = entry["shares"]
	var parts: PackedStringArray = []
	for id: String in biome_ids:
		parts.append("%s %.0f" % [id.substr(0, 4), float(shares[id]) * 100.0])
	print("  %-10d %6.3f  %4.0f%% %4.0fm %5d  %d/%-5d  %s" % [
		int(entry["seed"]), float(entry["score"]), float(entry["land_fraction"]) * 100.0,
		float(entry["peak"]), int(entry["pois"]), int(entry["poi_kinds"]),
		int(entry["poi_kinds_available"]), " ".join(parts)])


func _int_arg(name: String, fallback: int) -> int:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	for i: int in args.size():
		if args[i] == name and i + 1 < args.size() and args[i + 1].is_valid_int():
			return int(args[i + 1])
	return fallback
