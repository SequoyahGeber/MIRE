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
	var span: float = float(_arg_int(args, "--span", 1100))
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
	for py in size:
		for px in size:
			var x: float = (float(px) / float(size) - 0.5) * span
			var z: float = (float(py) / float(size) - 0.5) * span
			var h: float = IslandHeightmap.height(x, z, seed_value)
			if not defs.is_empty():
				var amplitudes: Vector2 = BiomeMap.terrain_amplitudes(x, z, seed_value, defs)
				h = IslandHeightmap.height(x, z, seed_value, amplitudes.x, amplitudes.y)
			lowest = minf(lowest, h)
			highest = maxf(highest, h)
			var colour: Color
			if h <= SEA_LEVEL:
				# Water, deepening with distance below the surface.
				var depth: float = clampf(-h / 24.0, 0.0, 1.0)
				colour = Color(0.09, 0.16, 0.24).lerp(Color(0.03, 0.06, 0.11), depth)
			else:
				land += 1
				var tint := Color(0.45, 0.52, 0.38)
				if not defs.is_empty():
					var id: StringName = BiomeMap.biome_at(x, z, seed_value, defs)
					tint = BIOME_TINT.get(id, tint)
				# Height shading on top of the biome tint: dark in the valleys,
				# pale on the crests, so ridges are visible as ridges.
				var lift: float = clampf(h / 70.0, 0.0, 1.0)
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
