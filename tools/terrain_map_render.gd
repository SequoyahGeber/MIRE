extends SceneTree

## Render the generated island top-down to a PNG, so "terrain look" can be judged
## without a window (F-077: `agent godot` is always headless).
##
## Run with:
##   .agent/bin/agent godot --script tools/terrain_map_render.gd
##   .agent/bin/agent godot --script tools/terrain_map_render.gd -- --seed 12345 --size 700
##
## Shades by height with a sea level, marks the coastline, and tints by the biome
## each point resolves to — which also makes it a visual check of D-144: if biome
## bands follow the ridged crests rather than the continent, the circularity is
## back. It writes pixels, so it is evidence rather than an impression.
##
## Every pixel is sampled through `BiomeMap.surface_from_set()`, the same function the chunk mesher
## calls, so what this renders is what the game builds (F-274). That was NOT true until F-274: this
## tool applied each biome's authored amplitudes and nothing else in the repo did.

const IslandHeightmap := preload("res://world/gen/island_heightmap.gd")
const BiomeMap := preload("res://world/gen/biome_map.gd")

const SEA_LEVEL: float = 0.0

## F-401: the land tint is each biome's OWN `ground_albedo`, read off the def, lifted toward white so
## it survives being seen at map scale. It used to be a hard-coded three-entry Dictionary, which had
## two problems the moment the table grew past three rows: a new biome rendered as the fallback grey
## (so the one thing this tool exists to show — where the regions are — was invisible for exactly
## the biomes you added it to look at), and the tints were nobody's authored colour, so a palette
## pass like F-397 could not be judged from the picture it produced. Sourcing the def means adding a
## `.tres` is enough, the same rule `Registry` already follows.
##
## `--mode biomes` drops the height shading entirely and paints flat regions, which is the view that
## answers "is this a region or a stipple" without relief confusing the eye.
const TINT_LIFT: float = 0.34


const BiomeDefsLib := preload("res://tools/biome_defs_lib.gd")


## Deferred one frame before it reads anything (F-401). `_initialize()` runs BEFORE the autoload
## tree exists, so `get_node_or_null(^"Registry")` returned null here and `defs` was ALWAYS empty:
## every render this tool has produced took the `defs.is_empty()` branch, which is
## `IslandHeightmap.height_from_set()` — the biome-BLIND 1.0/1.0 surface — and painted it with the
## hard-coded fallback tint. That is F-274's bug wearing this tool's clothes: the header promised
## "what this renders is what the game builds" and the picture was of a surface the mesher never
## makes. `BiomeDefsLib.load_defs()` is the same accessor every other terrain tool uses, and it
## falls back to a direct `content/biomes/` scan when no Registry is present at all.
func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	var seed_value: int = _arg_int(args, "--seed", 20260819)
	var size: int = _arg_int(args, "--size", 600)
	var span: float = float(_arg_int(args, "--span", 340))
	var out: String = _arg_str(args, "--out", "res://assets/audit/terrain/island_%d.png" % seed_value)
	var mode: String = _arg_str(args, "--mode", "relief")

	var defs: Array = BiomeDefsLib.load_defs(self)
	# F-401: id -> the def's own authored ground colour, lifted so it reads at map scale.
	var tints: Dictionary = {}
	var area: Dictionary = {}
	for def_value: Variant in defs:
		var def: Resource = def_value as Resource
		if def == null:
			continue
		var id_value: StringName = StringName(String(def.get(&"id")))
		tints[id_value] = (def.get(&"ground_albedo") as Color).lerp(Color.WHITE, TINT_LIFT)
		area[id_value] = 0

	var image := Image.create(size, size, false, Image.FORMAT_RGB8)
	var lowest: float = INF
	var highest: float = -INF
	var land: int = 0
	# F-261: one set of noise fields for the whole render. This loop is the worst per-sample rebuild
	# in the repo — every pixel resolved its biome twice and sampled the surface twice, and each of
	# those four calls rebuilt every field from scratch: 22 constructions per pixel, so roughly
	# 7.9 million for a default 600 px image and 23 million at `--size 1024`.
	var noise_set: BiomeMap.NoiseSet = BiomeMap.make_noise_set(seed_value)
	# F-274: the flattened table and one reusable Shape, so a 600x600 render pays neither a
	# per-pixel `Resource.get()` sweep nor a per-pixel allocation.
	var table: BiomeMap.TerrainTable = BiomeMap.make_terrain_table(defs)
	var shape := IslandHeightmap.Shape.new()
	for py in size:
		for px in size:
			var x: float = (float(px) / float(size) - 0.5) * span
			var z: float = (float(py) / float(size) - 0.5) * span
			# The tint's biome id and the pixel's surface, from the SAME two functions the game
			# calls (F-274). This tool used to be the only thing in the repo applying a biome's
			# authored amplitudes — it rendered a surface the chunk mesher would never produce, so
			# terrain tuned from these PNGs was tuned from the wrong image. It now goes through
			# `BiomeMap.surface_from_set()`, the mesher's own sampler, and the amplitude crossfade
			# comes with it.
			var id: StringName = &""
			var h: float
			if defs.is_empty():
				h = IslandHeightmap.height_from_set(x, z, noise_set.island, seed_value)
			else:
				id = BiomeMap.biome_at_from_set(x, z, noise_set, seed_value, defs)
				h = BiomeMap.surface_from_set(x, z, noise_set, seed_value, table, shape)
			lowest = minf(lowest, h)
			highest = maxf(highest, h)
			var colour: Color
			if h <= SEA_LEVEL:
				# Water, deepening with distance below the surface.
				var depth: float = clampf(-h / 12.0, 0.0, 1.0)
				colour = Color(0.09, 0.16, 0.24).lerp(Color(0.03, 0.06, 0.11), depth)
			else:
				land += 1
				if area.has(id):
					area[id] = int(area[id]) + 1
				var tint: Color = tints.get(id, Color(0.45, 0.52, 0.38))
				if mode == "biomes":
					# Flat regions, no relief: the view that answers "region or stipple".
					colour = tint
				else:
					# Height shading on top of the biome tint: dark in the valleys,
					# pale on the crests, so ridges are visible as ridges. Scaled to the
					# island's own relief rather than to a fixed number of metres.
					#
					# The scale is `IslandHeightmap.MAX_HEIGHT` now, not a literal 8.0 (F-450). A
					# hard-coded ceiling is a hidden assumption about how tall the terrain is, and
					# when the uplands went to ~44 m every square metre above 8 m clipped to the
					# same white — the picture said "the island is uniformly high" about terrain
					# with 40 m of relief in it, which is the opposite of what this tool is for.
					var lift: float = clampf(h / IslandHeightmap.MAX_HEIGHT, 0.0, 1.0)
					colour = tint.lerp(Color(0.96, 0.96, 0.92), lift * 0.55)
			image.set_pixel(px, py, colour)

	var absolute := ProjectSettings.globalize_path(out)
	DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
	var error := image.save_png(absolute)
	print("TERRAIN_MAP seed=%d size=%d span=%.0f mode=%s land=%.1f%% low=%.1f high=%.1f -> %s (%s)" % [
		seed_value, size, span, mode, 100.0 * float(land) / float(size * size), lowest, highest,
		out, "ok" if error == OK else str(error)
	])
	# F-401: the per-biome share of LAND, printed with every render, so "are the regions real and is
	# any of them rare enough that a run never sees it" is a number under the picture rather than an
	# impression of it. Sorted by share so the rare tail is the last thing on the line.
	var ordered: Array = area.keys()
	ordered.sort_custom(func(a: StringName, b: StringName) -> bool: return int(area[a]) > int(area[b]))
	var shares: PackedStringArray = []
	for id_value: StringName in ordered:
		shares.append("%s=%.1f%%" % [id_value, 100.0 * float(area[id_value]) / maxf(float(land), 1.0)])
	print("TERRAIN_MAP_BIOMES seed=%d %s" % [seed_value, " ".join(shares)])
	quit(0 if error == OK else 1)


func _arg_int(args: PackedStringArray, key: String, fallback: int) -> int:
	var index := args.find(key)
	return int(args[index + 1]) if index >= 0 and index + 1 < args.size() else fallback


func _arg_str(args: PackedStringArray, key: String, fallback: String) -> String:
	var index := args.find(key)
	return args[index + 1] if index >= 0 and index + 1 < args.size() else fallback
