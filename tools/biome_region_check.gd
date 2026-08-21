extends SceneTree

## MEASUREMENT PASS — parameter sweep for the F-401 region field. Rewritten as the real check after.
const IslandHeightmap := preload("res://world/gen/island_heightmap.gd")
const BiomeMap := preload("res://world/gen/biome_map.gd")

const SEEDS: Array[int] = [20260819, 4242, 7]
const SALT: int = 0x0C0FFEE1


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	# freq, octaves, gain, warp_amp, warp_freq, contrast
	var candidates: Array = [
		[0.0100, 3, 0.50, 0.0, 0.0, 1.0],
		[0.0035, 3, 0.42, 55.0, 0.006, 2.0],
		[0.0035, 3, 0.42, 55.0, 0.006, 2.6],
		[0.0026, 2, 0.40, 70.0, 0.005, 2.4],
		[0.0026, 3, 0.35, 70.0, 0.005, 2.8],
		[0.0018, 3, 0.40, 90.0, 0.004, 2.4],
		[0.0018, 2, 0.45, 90.0, 0.004, 3.0],
	]
	for c: Array in candidates:
		_measure(c)
	quit(0)


func _make(world_seed: int, c: Array) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = world_seed ^ SALT
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.frequency = float(c[0])
	n.fractal_type = FastNoiseLite.FRACTAL_FBM
	n.fractal_octaves = int(c[1])
	n.fractal_lacunarity = 2.0
	n.fractal_gain = float(c[2])
	if float(c[3]) > 0.0:
		n.domain_warp_enabled = true
		n.domain_warp_type = FastNoiseLite.DOMAIN_WARP_SIMPLEX
		n.domain_warp_amplitude = float(c[3])
		n.domain_warp_frequency = float(c[4])
		n.domain_warp_fractal_type = FastNoiseLite.DOMAIN_WARP_FRACTAL_PROGRESSIVE
		n.domain_warp_fractal_octaves = 2
	return n


func _value(n: FastNoiseLite, x: float, z: float, contrast: float) -> float:
	var v: float = (n.get_noise_2d(x, z) + 1.0) * 0.5
	return clampf((v - 0.5) * contrast + 0.5, 0.0, 1.0)


func _measure(c: Array) -> void:
	var all := PackedFloat64Array()
	var crossings_total: float = 0.0
	var flat_share_total: float = 0.0
	for world_seed: int in SEEDS:
		var n: FastNoiseLite = _make(world_seed, c)
		var set: BiomeMap.NoiseSet = BiomeMap.make_noise_set(world_seed)
		var shape := IslandHeightmap.Shape.new()
		var span: float = IslandHeightmap.ISLAND_RADIUS
		var x: float = -span
		while x <= span:
			var z: float = -span
			while z <= span:
				IslandHeightmap.shape_into(x, z, set.island, world_seed, shape)
				if IslandHeightmap.continent_from_shape(shape) > 0.0:
					all.append(_value(n, x, z, float(c[5])))
				z += 4.0
			x += 4.0
		# Band changes along transects: how many distinct regions you cross walking the island.
		var edges: PackedFloat64Array = PackedFloat64Array([0.0, 0.2, 0.42, 0.62, 0.8, 1.01])
		var crossings: int = 0
		var lines: int = 0
		for line: int in 8:
			var offset: float = (float(line) - 3.5) * 55.0
			var previous: int = -1
			var t: float = -span
			while t <= span:
				var wx: float = t if line < 4 else offset
				var wz: float = offset if line < 4 else t
				IslandHeightmap.shape_into(wx, wz, set.island, world_seed, shape)
				if IslandHeightmap.continent_from_shape(shape) > 0.0:
					var v: float = _value(n, wx, wz, float(c[5]))
					var band: int = 0
					for i: int in edges.size() - 1:
						if v >= edges[i] and v < edges[i + 1]:
							band = i
					if previous >= 0 and band != previous:
						crossings += 1
					previous = band
				t += 2.0
			lines += 1
		crossings_total += float(crossings) / float(lines)
		# How much of the land sits on a plateau (gradient below a tenth of the mean)
		var flat: int = 0
		var count: int = 0
		var xx: float = -span
		while xx <= span:
			var zz: float = -span
			while zz <= span:
				IslandHeightmap.shape_into(xx, zz, set.island, world_seed, shape)
				if IslandHeightmap.continent_from_shape(shape) > 0.0:
					count += 1
					var g: float = maxf(
						absf(_value(n, xx + 3.0, zz, float(c[5])) - _value(n, xx - 3.0, zz, float(c[5]))),
						absf(_value(n, xx, zz + 3.0, float(c[5])) - _value(n, xx, zz - 3.0, float(c[5])))) / 6.0
					if g < 0.002:
						flat += 1
				zz += 7.0
			xx += 7.0
		flat_share_total += 100.0 * float(flat) / maxf(float(count), 1.0)
	all.sort()
	print("freq=%.4f oct=%d gain=%.2f warp=%.0f/%.4f contrast=%.1f" % c)
	print("   %s" % _q(all))
	print("   band changes per island transect: %.1f    plateau share: %.0f%%"
		% [crossings_total / float(SEEDS.size()), flat_share_total / float(SEEDS.size())])


func _q(values: PackedFloat64Array) -> String:
	if values.is_empty():
		return "(none)"
	var out: PackedStringArray = []
	for p: float in [0.02, 0.1, 0.25, 0.5, 0.75, 0.9, 0.98]:
		var i: int = clampi(int(p * float(values.size() - 1)), 0, values.size() - 1)
		out.append("p%02d=%.2f" % [int(p * 100.0), values[i]])
	return " ".join(out)
