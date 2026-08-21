extends SceneTree

## F-401: biomes must form REGIONS you cross an edge into, not a smear where everything is
## everywhere.
##
## The finding's complaint was structural, not cosmetic: three biomes split by a single moisture
## threshold gave "no sense of arriving anywhere, because there is nowhere distinct to arrive at".
## Seven biomes only fix that if they are CLUSTERED. Seven biomes assigned by high-frequency noise
## would be strictly worse than three — the same smear, with more colours in it.
##
## So the property under test is not "how many biomes exist" (a content check would catch that) but
## how many boundaries you cross walking in a straight line. A clustered island gives a handful of
## long stretches; a noisy one flickers between biomes every few metres. `tools/biome_region_probe.gd`
## is the parameter sweep this was derived from — it measured the shipped field at 3.5-4.7 band
## changes per transect while tuning.
##
## Also asserts every biome actually appears. A biome nothing ever selects is content that ships and
## is never seen, which is the failure mode F-401 called out for `highland` at 5.2%.
##
## Run with: .agent/bin/agent godot --script tools/biome_region_check.gd

const IslandHeightmap := preload("res://world/gen/island_heightmap.gd")
const BiomeMap := preload("res://world/gen/biome_map.gd")

const SEEDS: Array[int] = [20260819, 7, 4242, 991]
## Transects per seed, and the step along them. 4 m matches the probe's sampling.
const TRANSECTS: int = 8
const STEP_M: float = 4.0

## A clustered island crosses a handful of boundaries per traverse. The shipped field measured
## 3.5-4.7 while tuning; 12 is well clear of that and still far below what a noise-assigned island
## would produce, where every few samples can flip.
const MAX_CHANGES_PER_TRANSECT: float = 12.0
## ...and it must not collapse the other way either. Under 1.0 would mean a transect typically
## crosses NO boundary, i.e. one biome covering the island — F-401's original complaint restated.
const MIN_CHANGES_PER_TRANSECT: float = 1.0

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var registry: Node = root.get_node_or_null(^"Registry")
	var biome_defs: Array = (registry.get(&"biomes") as Dictionary).values() if registry else []
	check(not biome_defs.is_empty(), "biome defs are loaded (%d)" % biome_defs.size())
	if biome_defs.is_empty():
		quit(1)
		return

	var seen: Dictionary = {}
	var changes_total: float = 0.0
	var transects_total: int = 0

	for world_seed: int in SEEDS:
		var noise: BiomeMap.NoiseSet = BiomeMap.make_noise_set(world_seed)
		var span: float = IslandHeightmap.ISLAND_RADIUS
		for line: int in TRANSECTS:
			# Spread the transects across the island, alternating axis so a field that is clustered
			# on one axis and striped on the other cannot pass.
			var offset: float = (float(line) - float(TRANSECTS - 1) * 0.5) * (span * 2.0 / float(TRANSECTS))
			var previous: StringName = &""
			var changes: int = 0
			var samples: int = 0
			var t: float = -span
			while t <= span:
				var x: float = t if line % 2 == 0 else offset
				var z: float = offset if line % 2 == 0 else t
				t += STEP_M
				# Ocean has no biome to speak of; only judge ground.
				if IslandHeightmap.continent_from_set(x, z, noise.island, world_seed) <= 0.0:
					continue
				var id: StringName = BiomeMap.biome_at_from_set(x, z, noise, world_seed, biome_defs)
				seen[id] = true
				samples += 1
				if previous != &"" and id != previous:
					changes += 1
				previous = id
			if samples < 10:
				continue   # transect barely clipped the island — not a meaningful traverse
			changes_total += float(changes)
			transects_total += 1

	check(transects_total > 0, "transects crossed real ground (%d)" % transects_total)
	var mean: float = changes_total / float(maxi(transects_total, 1))

	check(mean <= MAX_CHANGES_PER_TRANSECT,
		"biomes are CLUSTERED, not noise — %.1f boundary crossings per transect (max %.1f)"
			% [mean, MAX_CHANGES_PER_TRANSECT],
		"a high count means you flicker between biomes as you walk, which is F-401's smear with "
		+ "more colours in it")
	check(mean >= MIN_CHANGES_PER_TRANSECT,
		"...and the island is not ONE biome — %.1f crossings per transect (min %.1f)"
			% [mean, MIN_CHANGES_PER_TRANSECT])

	for def: Resource in biome_defs:
		var id: StringName = def.get(&"id")
		check(seen.has(id),
			"biome '%s' actually appears somewhere across %d seeds" % [String(id), SEEDS.size()],
			"a biome nothing selects is content that ships and is never seen")

	print("BIOME_REGION_CHECK failures=%d mean_crossings=%.1f biomes_seen=%d/%d transects=%d"
		% [failures, mean, seen.size(), biome_defs.size(), transects_total])
	quit(0 if failures == 0 else 1)


func check(condition: bool, description: String, detail: String = "") -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s%s" % [description, "" if detail.is_empty() else " — " + detail])
