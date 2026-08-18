extends SceneTree

## F-128 / D-084 — renders a LOD0↔LOD1 chunk seam twice, once with the skirt and once with it
## stripped, so the fix can be judged by eye and not only by the divergence numbers in
## `tools/chunk_stream_check.gd`.
##
##   .agent/bin/agent godot --windowed --script tools/chunk_seam_shot.gd
##
## Must run windowed — a headless renderer produces nothing to look at. Writes to
## `user://chunk_seam/`; the run prints the absolute paths.
##
## The "no skirt" mesh is the real pre-fix geometry, not an approximation: it is the same built
## mesh with its index buffer truncated back to the terrain triangles, which is exactly what
## `build_mesh` produced before this finding was fixed.

const Mesher := preload("res://world/chunk/chunk_mesher.gd")

const OUT_DIR: String = "user://chunk_seam"
const WIDTH: int = 1280
const HEIGHT: int = 720
const BENCH_SEED: int = 20260818

## Where to look for a seam worth photographing. The roughest seam on the island by pure
## divergence sits 13 m under water in a pit, which says nothing about how the fix reads in play —
## so the search below wants the roughest seam that is also ON LAND and out in the open, and finds
## it rather than hardcoding a coordinate that a retune of the heightmap would silently invalidate.
const SEARCH_CHUNK_RADIUS: int = 14
## Minimum terrain height along the seam for it to count as land worth showing.
const MIN_SEAM_GROUND_M: float = 8.0
## Chunks either side of the seam to build, on each axis.
const SPAN: int = 3


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("chunk_seam_shot needs a real renderer — run with --windowed")
		quit(1)
		return

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	var scene := Node3D.new()
	root.add_child(scene)

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = Sky.new()
	env.sky.sky_material = ProceduralSkyMaterial.new()
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.45
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	scene.add_child(world_env)

	var sun := DirectionalLight3D.new()
	# Angled across the seam rather than straight down it, so the surfaces either side shade
	# differently and a discontinuity between them has something to show up against. Not a raking
	# low sun: that leaves half the terrain unlit, which hides the seam just as well as flat light.
	sun.rotation_degrees = Vector3(-48.0, 35.0, 0.0)
	sun.light_energy = 1.3
	scene.add_child(sun)

	var seam_chunk: Vector2i = _pick_seam_chunk()

	# The seam runs north-south along the west edge of seam_chunk. Everything west of it is coarse
	# (LOD1), everything east is full detail (LOD0) — the arrangement the streamer's rings produce
	# where the mid ring meets the near one.
	var seam_world_x: float = float(seam_chunk.x * Mesher.CHUNK_SIZE)
	var skirted := Node3D.new()
	var bare := Node3D.new()
	scene.add_child(skirted)
	scene.add_child(bare)

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.35, 0.45, 0.3)

	for dz: int in range(-SPAN, SPAN + 1):
		for dx: int in range(-SPAN, SPAN + 1):
			var coord := Vector2i(seam_chunk.x + dx, seam_chunk.y + dz)
			var lod: int = 1 if dx < 0 else 0
			var mesh: ArrayMesh = Mesher.build_mesh(coord.x, coord.y, BENCH_SEED, lod)
			var origin := Vector3(
				float(coord.x * Mesher.CHUNK_SIZE), 0.0, float(coord.y * Mesher.CHUNK_SIZE))
			_add_instance(skirted, mesh, origin, material)
			_add_instance(bare, _strip_skirt(mesh, lod), origin, material)

	# Both cameras are placed relative to the terrain actually under them, sampled from the same
	# heightmap the mesh was built from — a fixed world y drops the camera inside a hill, and a
	# clearance over the single point underfoot is not enough either when that point sits in a
	# hollow. The peak over the whole neighbourhood is what guarantees a clear line to the seam.
	var seam_z: float = float(seam_chunk.y * Mesher.CHUNK_SIZE) + 16.0
	var seam_ground: float = IslandHeightmap.height(seam_world_x, seam_z, BENCH_SEED)
	var peak: float = _neighbourhood_peak(seam_world_x, seam_z)
	print("seam ground %.1f m | neighbourhood peak %.1f m" % [seam_ground, peak])
	var shots: Array[Dictionary] = [
		# Grazing look down onto the seam from the fine side. Shallow angles are where a T-junction
		# crack is widest on screen and where a skirt has the least depth to hide behind, so this is
		# the angle that decides whether the fix works.
		{
			"name": "grazing",
			"eye": Vector3(seam_world_x + 26.0, maxf(seam_ground, peak) + 9.0, seam_z - 30.0),
			"target": Vector3(seam_world_x, seam_ground, seam_z + 4.0),
			"fov": 60.0,
		},
		# Further out and higher, so a whole run of the seam is in frame at once rather than one
		# stretch of it — a crack that only shows in close-up is a different claim from one that
		# survives at the distance the mid ring is actually viewed from.
		{
			"name": "overview",
			"eye": Vector3(seam_world_x + 62.0, maxf(seam_ground, peak) + 38.0, seam_z - 72.0),
			"target": Vector3(seam_world_x, seam_ground, seam_z + 8.0),
			"fov": 55.0,
		},
	]

	var viewport := SubViewport.new()
	viewport.size = Vector2i(WIDTH, HEIGHT)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.own_world_3d = false
	viewport.world_3d = scene.get_viewport().world_3d
	root.add_child(viewport)

	var camera := Camera3D.new()
	camera.far = 2000.0
	viewport.add_child(camera)
	camera.make_current()

	print("=== F-128 seam shots — LOD0/LOD1 boundary at world x=%.0f, chunk %s, seed %d ===" % [
		seam_world_x, seam_chunk, BENCH_SEED])
	print("skirt depth %.2f m" % Mesher.SKIRT_DEPTH)

	for shot: Dictionary in shots:
		camera.fov = shot["fov"]
		camera.global_position = shot["eye"]
		camera.look_at(shot["target"], Vector3.UP)
		print("-- %s: camera %.1f,%.1f,%.1f" % [
			shot["name"], camera.global_position.x, camera.global_position.y,
			camera.global_position.z])
		var bare_img: Image = await _shoot(
			viewport, skirted, bare, "seam_%s_without_skirt.png" % shot["name"], false)
		var skirted_img: Image = await _shoot(
			viewport, skirted, bare, "seam_%s_with_skirt.png" % shot["name"], true)
		_diff(bare_img, skirted_img, "seam_%s_diff.png" % shot["name"])
	quit(0)


## What the skirt actually changed on screen, pixel for pixel. The two renders are identical
## geometry apart from the skirt, from an identical camera, so every differing pixel is somewhere
## the skirt is visible — and if the fix is working those pixels are the crack and nothing else.
## A skirt that showed up as a flange along the seam instead would light this up as a solid band,
## which is the failure mode F-128 warned skirts can have.
func _diff(bare_img: Image, skirted_img: Image, filename: String) -> void:
	var w: int = bare_img.get_width()
	var h: int = bare_img.get_height()
	var out := Image.create_empty(w, h, false, Image.FORMAT_RGB8)
	var changed: int = 0
	for y: int in h:
		for x: int in w:
			var a: Color = bare_img.get_pixel(x, y)
			var b: Color = skirted_img.get_pixel(x, y)
			var delta: float = maxf(maxf(absf(a.r - b.r), absf(a.g - b.g)), absf(a.b - b.b))
			if delta > 0.02:
				changed += 1
				out.set_pixel(x, y, Color(1.0, 0.0, 0.8))
			else:
				# Dim greyscale backdrop, so the changed pixels are readable in context.
				var grey: float = a.get_luminance() * 0.35
				out.set_pixel(x, y, Color(grey, grey, grey))
	var path: String = OUT_DIR.path_join(filename)
	if out.save_png(path) != OK:
		push_error("could not write %s" % path)
		return
	print("  diff: %d of %d pixels changed (%.3f%%) -> %s" % [
		changed, w * h, 100.0 * float(changed) / float(w * h),
		ProjectSettings.globalize_path(path)])


## The roughest west-edge seam that is also above MIN_SEAM_GROUND_M along its whole length — the
## worst case a player can actually stand next to and look at, which is the case this tool exists
## to judge. Divergence is measured the same way `chunk_stream_check.gd` measures it: how far the
## fine surface departs from the chord the coarse neighbour draws across the same span.
func _pick_seam_chunk() -> Vector2i:
	var best := Vector2i.ZERO
	var best_divergence: float = -1.0
	for cz: int in range(-SEARCH_CHUNK_RADIUS, SEARCH_CHUNK_RADIUS + 1):
		for cx: int in range(-SEARCH_CHUNK_RADIUS, SEARCH_CHUNK_RADIUS + 1):
			var ox: float = float(cx * Mesher.CHUNK_SIZE)
			var oz: float = float(cz * Mesher.CHUNK_SIZE)
			var worst: float = 0.0
			var lowest: float = 1.0e30
			for t: int in range(0, Mesher.CHUNK_SIZE + 1):
				var h: float = IslandHeightmap.height(ox, oz + float(t), BENCH_SEED)
				lowest = minf(lowest, h)
				if t > 0 and t < Mesher.CHUNK_SIZE and t % 2 != 0:
					var lo: float = IslandHeightmap.height(ox, oz + float(t - 1), BENCH_SEED)
					var hi: float = IslandHeightmap.height(ox, oz + float(t + 1), BENCH_SEED)
					worst = maxf(worst, absf(h - (lo + hi) * 0.5))
			if lowest < MIN_SEAM_GROUND_M:
				continue
			if worst > best_divergence:
				best_divergence = worst
				best = Vector2i(cx, cz)
	print("seam chosen: chunk %s, west edge, worst divergence %.3f m (land only, >= %.0f m)" % [
		best, best_divergence, MIN_SEAM_GROUND_M])
	return best


## Highest terrain within the built grid, so a camera clears every ridge between it and the seam.
func _neighbourhood_peak(cx: float, cz: float) -> float:
	var reach: float = float((SPAN + 1) * Mesher.CHUNK_SIZE)
	var peak: float = -1.0e30
	var z: float = cz - reach
	while z <= cz + reach:
		var x: float = cx - reach
		while x <= cx + reach:
			peak = maxf(peak, IslandHeightmap.height(x, z, BENCH_SEED))
			x += 4.0
		z += 4.0
	return peak


func _add_instance(parent: Node3D, mesh: ArrayMesh, origin: Vector3, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = origin
	parent.add_child(mi)


## The pre-fix mesh: identical vertices, index buffer cut back to the terrain triangles.
func _strip_skirt(mesh: ArrayMesh, lod: int) -> ArrayMesh:
	var arrays: Array = mesh.surface_get_arrays(0)
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	arrays[Mesh.ARRAY_INDEX] = indices.slice(0, Mesher.tri_count(lod) * 3)
	var stripped := ArrayMesh.new()
	stripped.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return stripped


func _shoot(
	viewport: SubViewport, skirted: Node3D, bare: Node3D, filename: String, with_skirt: bool
) -> Image:
	skirted.visible = with_skirt
	bare.visible = not with_skirt
	# Two frames: one for the visibility change to take, one to be certain the swap is what the
	# render target actually holds.
	for _i: int in 3:
		await process_frame
		await RenderingServer.frame_post_draw
	var image: Image = viewport.get_texture().get_image()
	var path: String = OUT_DIR.path_join(filename)
	var error: int = image.save_png(path)
	if error != OK:
		push_error("could not write %s (error %d)" % [path, error])
		return image
	print("wrote %s" % ProjectSettings.globalize_path(path))
	return image
