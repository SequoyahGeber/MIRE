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
const BIOME_TINT: Dictionary = {
	&"shore": Color(0.86, 0.80, 0.58),
	&"grassland": Color(0.42, 0.62, 0.34),
	&"forest": Color(0.20, 0.42, 0.26),
}


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var seed_value: int = _arg_int(args, "--seed", 20260819)
	var size: int = _arg_int(args, "--size", 600)
	var span: float = float(_arg_int(args, "--span", 340))
	var out: String = _arg_str(args, "--out", "res://assets/audit/terrain/island_%d.png" % seed_value)

	var defs: Array = []
	var registry: Node = root.get_node_or_null(^"Registry")
	if registry != null and registry.has_method("biome_list"):
		defs = registry.call("biome_list")
	elif registry != null:
		var table: Dictionary = registry.get(&"biomes")
		if table != null:
			for key: Variant in table.keys():
				defs.append(table[key])

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
				var tint := Color(0.45, 0.52, 0.38)
				if not defs.is_empty():
					tint = BIOME_TINT.get(id, tint)
				# Height shading on top of the biome tint: dark in the valleys,
				# pale on the crests, so ridges are visible as ridges.
				var lift: float = clampf(h / 30.0, 0.0, 1.0)
				colour = tint.lerp(Color(0.94, 0.94, 0.90), lift * 0.75)
				if h < 1.6:
					colour = colour.lerp(Color(0.88, 0.83, 0.62), 0.65)   # the beach line
			image.set_pixel(px, py, colour)

	var absolute := ProjectSettings.globalize_path(out)
	DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
	var error := image.save_png(absolute)
	print("TERRAIN_MAP seed=%d size=%d span=%.0f land=%.1f%% low=%.1f high=%.1f -> %s (%s)" % [
		seed_value, size, span, 100.0 * float(land) / float(size * size), lowest, highest,
		out, "ok" if error == OK else str(error)
	])
	quit(0 if error == OK else 1)


func _arg_int(args: PackedStringArray, key: String, fallback: int) -> int:
	var index := args.find(key)
	return int(args[index + 1]) if index >= 0 and index + 1 < args.size() else fallback


func _arg_str(args: PackedStringArray, key: String, fallback: String) -> String:
	var index := args.find(key)
	return args[index + 1] if index >= 0 and index + 1 < args.size() else fallback
