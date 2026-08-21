extends SceneTree

## Verifies task 4.3 — world/chunk/chunk_streamer.gd + the real world/chunk/chunk_mesher.gd.
##
##   .agent/bin/agent godot --windowed --script tools/chunk_stream_check.gd
##
## MUST run windowed, not headless (F-005/D-074): collision cooking is the gating cost this whole
## system is budgeted around, and the headless dummy renderer/physics stub under-reports it,
## which is exactly the mistake that made spike R2 (D-015) an incomplete GREEN the first time.
##
## Phase 1 asserts ring/LOD/hysteresis/collision-laziness BEHAVIOR. Phase 2 is the spec's actual
## acceptance test: "walk 500 m in a straight line at sprint speed with zero hitches over 16 ms."
##
## The seam section is F-128/D-084's guard. It does not eyeball a render — it measures the thing a
## crack IS (how far a fine chunk's edge surface departs from the coarse chord its neighbour draws
## across the same span) and asserts the skirt is deeper than that everywhere on the island. That
## makes the fix falsifiable from a terminal, and makes retuning `IslandHeightmap.HEIGHT_SCALE` or
## the noise fail loudly here instead of silently reopening the crack in-game.
##
## The union-of-interest section closes `docs/FINDINGS.md` F-132: a real `ChunkStreamer` fed TWO
## independent, far-apart anchors (standing in for "the host's own local player" and "a remote
## connected peer's last-known position") must build a resident, collision-bearing LOD0 chunk around
## EACH one, not just the nearest — and a real `ResourceScatterField` attached to that same streamer
## must turn both into live, `HarvestWorld`-wired `Harvestable` proxies. That is the exact property a
## remote client's `Harvestable.request_hit()` `rpc_id(HOST_PEER_ID)` call depends on: a node at the
## same NodePath actually existing on the host, even when the host's own player is elsewhere.

const ChunkStreamer := preload("res://world/chunk/chunk_streamer.gd")
const ChunkMesher := preload("res://world/chunk/chunk_mesher.gd")
const ResourceScatterFieldScript := preload("res://world/gen/resource_scatter_field.gd")
const ResourceScatterLib := preload("res://world/gen/resource_scatter.gd")
const HarvestLib := preload("res://systems/harvesting/harvest_library.gd")
const BiomeMapScript := preload("res://world/gen/biome_map.gd")
const BiomeDefsLib := preload("res://tools/biome_defs_lib.gd")

## The shipped biome table (F-274). Every mesh built here and every reference surface sampled here
## goes through it: the skirt is sized against the SHIPPED terrain's LOD divergence, and the
## biome-blind 1.0/1.0 surface is a smoother one, so measuring the skirt against it would certify a
## margin the game never actually gets.
var biome_defs: Array = []

const BENCH_SEED: int = 20260818
## The worst LOD-boundary divergence found when F-128 was fixed, and where it was found — swept
## over the whole island across four seeds. Kept as an explicit spot-check so the recorded number
## stays honest rather than drifting into folklore.
##
## Re-measured by F-251 (2026-08-19): the terrain retuning that dropped `HEIGHT_SCALE` 60->26 and
## added the domain-warped ridged layer + carved river (D-142/4.13-4.14) moved the worst case far
## from F-128's original spot. A 12-seed island-wide sweep found the new worst at seed 4242, chunk
## (3,-4), edge 0 (south), LOD1/LOD2 boundary — 12.805 m, against a spread of 7.5-12.8 m across all
## 12 seeds sampled. `SKIRT_DEPTH_FRACTION` in `chunk_mesher.gd` was retuned alongside this.
##
## Re-measured again by F-274 (2026-08-20), which put every vertex on its own biome's terrain
## amplitudes: the same spot then diverged 12.4405 m rather than 12.805 m, because the crest there
## sits in biomes whose authored `ridge_amplitude` is below 1.0.
##
## Re-measured again for D-184's flat-plateau restructure (2026-08-20, 4.18): 3.0999 m at this
## spot, 3.1256 m island-wide — the divergence spread collapsed with the amplitudes.
##
## Re-measured once more for the sea-level rebase later the same day (HEIGHT_SCALE 6, gentler
## hills, stream-depth river, ocean floor): 1.2134 m here, 2.5775 m island-wide worst on the bench
## seed.
##
## Re-measured again for the gradual-coast pass (smoothstep falloff, minimum beach band, cubed
## sea-floor shelf, slower coast jitter): **0.2196 m** here, 1.7604 m island-wide. The recorded
## spot is a COAST chunk, and gentling the coast is precisely what this pass did, so the collapse
## is the intended effect rather than drift. `SKIRT_DEPTH` (10.2 m) now clears the island-wide
## worst by ~6x. That assertion — skirt deeper than the worst anywhere — is what carries the
## guarantee; this recorded spot only exists to catch silent drift.
##
## Re-measured for F-447 (island radius 295 -> 590 m, elliptical lobes, asymmetric hills):
## **4.4004 m** here, 2.3049 m island-wide worst on the bench seed. The recorded spot moved a long
## way UP, and for a structural reason rather than a worrying one — chunk (3, -4) on seed 4242 was
## a coast chunk on a 295 m island and is interior ground on a 590 m one, so the number now
## describes different terrain entirely. It is also no longer the island-wide worst, which is the
## sign that this constant has become what its own last paragraph says it is: a drift tripwire on
## one named spot, not a bound. `SKIRT_DEPTH` (18.7 m) clears the island-wide worst by ~8x and this
## spot by ~4x, and both of those assertions are the ones that carry the guarantee.
##
## Asymmetric hills are the reason to keep watching it. A scarp is the sharpest feature this
## generator makes, and a sharp feature is exactly what a halved LOD sampling rate misses; if a
## later pass makes cliffs commoner or steeper, expect this to climb again and check it against
## `SKIRT_DEPTH` rather than against its own history.
const WORST_KNOWN_SEED: int = 4242
const WORST_KNOWN_CHUNK := Vector2i(3, -4)
##
## Re-swept again for F-450 (uplands: hill lift 13 -> 40 m, flat tops, scarped rims): **13.5104 m**
## here, 5.8681 m island-wide worst on the bench seed. Tripling the terrain's relief tripled this,
## which is what a drift tripwire is for — and this time it also cost the skirt its margin, because
## `ChunkMesher.SKIRT_DEPTH` was a fraction of `HEIGHT_SCALE` and the uplands are not in
## `HEIGHT_SCALE`. That constant is a fraction of `MAX_HEIGHT` now (33.2 m), so the margin is back
## to 2.5x and it tracks the hills automatically.
const WORST_KNOWN_DIVERGENCE_M: float = 13.5104
## Chunk radius the seam/harvestable sweeps scan. `IslandHeightmap.ISLAND_RADIUS` is 118 m
## (CHUNK_SIZE 32 m -> ~4 chunks), so 10 chunks (320 m) is a wide margin past the falloff shoulder
## into open water — cheap because water contributes ~0 divergence and no harvestable placements,
## it just costs empty iterations. Was 17 (F-128's era, sized against a 512 m island that no longer
## exists); shrunk by F-251 for speed, not correctness — either radius finds the same worst case.
const ISLAND_CHUNK_RADIUS: int = 10
## D-018: the tuned player controller default. The spec's own acceptance line names this speed.
const SPRINT_SPEED_MPS: float = 6.0
const TARGET_DISTANCE_M: float = 500.0
const HITCH_THRESHOLD_MS: float = 16.667
## Convergence timeout for phase 1's "wait until the ring settles" polls — protects against a
## silent hang reading as a slow pass instead of a failure.
const MAX_SETTLE_FRAMES: int = 600
## Sentinel: no chunk with a harvestable placement was found within the searched radius.
const NOT_FOUND_CHUNK := Vector2i(999999, 999999)

var _failures: int = 0


func _check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		print("  ok    %s" % label)
	else:
		_failures += 1
		print("  FAIL  %s%s" % [label, ("  — " + detail) if detail != "" else ""])


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("chunk_stream_check needs a real renderer — run with --windowed (F-005/D-074)")
		quit(1)
		return

	biome_defs = BiomeDefsLib.load_defs(self)
	_check("the shipped biome table loaded (%d def(s))" % biome_defs.size(),
		not biome_defs.is_empty())

	print("=== MIRE Task 4.3 — chunk streaming + LOD ===")
	print("Godot %s | %s | renderer=%s" % [
		Engine.get_version_info()["string"], OS.get_name(), RenderingServer.get_video_adapter_name(),
	])

	var root_node := Node3D.new()
	root.add_child(root_node)
	var camera := Camera3D.new()
	camera.far = 4000.0
	root_node.add_child(camera)
	camera.global_position = Vector3(0.0, 400.0, 400.0)
	camera.look_at(Vector3.ZERO, Vector3.UP)
	camera.make_current()
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45.0, -30.0, 0.0)
	root_node.add_child(sun)

	print("\n-- mesh geometry (LOD0/1/2) --")
	_check("LOD0 matches R2's own 33x33/2048-tri chunk", ChunkMesher.vert_count(0) == 1089
		and ChunkMesher.tri_count(0) == 2048)
	_check("LOD1 is half detail (17x17/512 tri)", ChunkMesher.vert_count(1) == 289
		and ChunkMesher.tri_count(1) == 512)
	_check("LOD2 is quarter detail (9x9/128 tri)", ChunkMesher.vert_count(2) == 81
		and ChunkMesher.tri_count(2) == 128)

	print("\n-- mesh determinism (thread-safety precondition — D-075's guarantee extended to lod) --")
	# Chunk (0, 0) — the island's own centre, guaranteed land regardless of seed. F-251
	# (2026-08-19): this was chunk (5, -3), which centres ~186 m from origin — outside
	# `IslandHeightmap.ISLAND_RADIUS` (118 m, shrunk from 512 m since this check was written) and
	# therefore flat open water at every seed, so "a different seed changes the mesh" failed for a
	# reason that had nothing to do with determinism.
	var m1: ArrayMesh = ChunkMesher.build_mesh(0, 0, BENCH_SEED, biome_defs, 1)
	var m2: ArrayMesh = ChunkMesher.build_mesh(0, 0, BENCH_SEED, biome_defs, 1)
	var m3: ArrayMesh = ChunkMesher.build_mesh(0, 0, BENCH_SEED + 1, biome_defs, 1)
	var v1: PackedVector3Array = m1.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var v2: PackedVector3Array = m2.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var v3: PackedVector3Array = m3.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	_check("same (chunk, seed, lod) is byte-identical", v1 == v2)
	_check("a different seed changes the mesh", v1 != v3)

	print("\n-- LOD-boundary seams: skirt geometry + coverage (F-128 / D-084) --")
	_check_skirt_geometry()
	_check_seam_coverage()

	print("\n-- ring / LOD / lazy-collision behavior (phase 1) --")
	await _check_ring_behavior(root_node)

	print("\n-- 500 m sprint walk, hitch budget %.3f ms (phase 2 — the spec's acceptance test) --" % HITCH_THRESHOLD_MS)
	await _check_sprint_walk(root_node)

	print("\n-- host union-of-interest: two independent anchors each get a reachable proxy (F-132) --")
	await _check_union_of_interest()

	print("\n%d functional failure(s)\n" % _failures)
	quit(1 if _failures > 0 else 0)


## The skirt's shape: appended after the terrain (so `collision_faces()` can slice it off), one
## surface (a second would be a second draw call on every resident chunk), facing outward on all
## four sides, and absent from collision.
func _check_skirt_geometry() -> void:
	var centre := Vector3(float(ChunkMesher.CHUNK_SIZE) * 0.5, 0.0, float(ChunkMesher.CHUNK_SIZE) * 0.5)
	var all_counts_ok: bool = true
	var all_layout_ok: bool = true
	var all_collision_ok: bool = true
	var inward_total: int = 0
	var downward_total: int = 0
	var detail: String = ""

	for lod: int in ChunkMesher.LOD_COUNT:
		var mesh: ArrayMesh = ChunkMesher.build_mesh(2, -3, BENCH_SEED, biome_defs, lod)
		var arrays: Array = mesh.surface_get_arrays(0)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var terrain_verts: int = ChunkMesher.vert_count(lod)
		var terrain_tris: int = ChunkMesher.tri_count(lod)
		var skirt_verts: int = ChunkMesher.skirt_vert_count(lod)
		var skirt_tris: int = ChunkMesher.skirt_tri_count(lod)

		if mesh.get_surface_count() != 1 \
			or verts.size() != terrain_verts + skirt_verts \
			or indices.size() != (terrain_tris + skirt_tris) * 3:
			all_counts_ok = false
			detail += "LOD%d counts; " % lod

		# The terrain block must still be the first `vert_count(lod)` vertices in row-major order —
		# the invariant `collision_faces()` slices on, and what keeps the determinism test above
		# comparing terrain rather than skirt. Since 4.18/D-184 an interior vertex sits within
		# VERTEX_JITTER_FRACTION of a step of its grid point rather than exactly on it, so the
		# assertion is a bound, not an equality — still tight enough that any skirt vertex (a full
		# SKIRT_DEPTH below, on the perimeter) or reordered row lands far outside it. Border
		# vertices stay EXACT: that is the tiling contract the seam measurement below rests on.
		var side: int = ChunkMesher.verts_per_side(lod)
		var step: int = ChunkMesher.LOD_STEPS[lod]
		# Border vertices jitter at the FIXED LOD0 amplitude (so both neighbours agree — see
		# VERTEX_JITTER_FRACTION), interior at their own tier's; both bounds far under the
		# SKIRT_DEPTH a leaked skirt vertex would show up at.
		var jitter_bound: float = ChunkMesher.VERTEX_JITTER_FRACTION * float(step) + 0.001
		var border_bound: float = ChunkMesher.VERTEX_JITTER_FRACTION + 0.001
		for z: int in side:
			for x: int in side:
				var p: Vector3 = verts[z * side + x]
				var on_border: bool = x == 0 or x == side - 1 or z == 0 or z == side - 1
				var bound: float = border_bound if on_border else jitter_bound
				if absf(p.x - float(x * step)) > bound or absf(p.z - float(z * step)) > bound:
					all_layout_ok = false

		# Collision must be terrain only: same triangle count, its lowest point matches the
		# TERRAIN block's own lowest vertex exactly (proving no skirt vertex leaked in), and the
		# skirt sits well clear beneath it.
		#
		# F-251 (2026-08-19): this used to compare `collision_min_y` against the whole mesh's
		# `mesh_min_y` and require the difference equal `SKIRT_DEPTH` exactly — which silently
		# assumed the chunk's globally lowest TERRAIN point always sits on the border (so the
		# border vertex the skirt hangs from doubles as the terrain minimum). That held on the
		# smoother pre-D-142 terrain; the domain-warped ridged layer + carved river now routinely
		# put the lowest point of a chunk in its INTERIOR instead, which desyncs that coincidence
		# by up to a metre or so without anything actually being wrong — collision was terrain-only
		# the whole time, this assertion was just measuring the wrong thing.
		var faces: PackedVector3Array = ChunkMesher.collision_faces(mesh, lod)
		var collision_min_y: float = 1.0e30
		for f: Vector3 in faces:
			collision_min_y = minf(collision_min_y, f.y)
		var terrain_min_y: float = 1.0e30
		for i: int in terrain_verts:
			terrain_min_y = minf(terrain_min_y, verts[i].y)
		var skirt_min_y: float = 1.0e30
		for i: int in range(terrain_verts, verts.size()):
			skirt_min_y = minf(skirt_min_y, verts[i].y)
		if faces.size() != terrain_tris * 3 \
			or not is_equal_approx(collision_min_y, terrain_min_y) \
			or skirt_min_y > terrain_min_y - ChunkMesher.SKIRT_DEPTH * 0.5:
			all_collision_ok = false
			detail += "LOD%d collision; " % lod

		# Which way each surface FACES, asked of the engine rather than derived by hand — see
		# `_winding_facing()`. F-133 is precisely what assuming this answer costs.
		var terrain_facing: Array = _winding_facing(verts, indices.slice(0, terrain_tris * 3))
		for n: Vector3 in terrain_facing[1] as PackedVector3Array:
			if n.dot(Vector3.UP) <= 0.0:
				downward_total += 1

		# Every skirt triangle must face away from the chunk centre, or it is backface-culled
		# exactly when it is needed and the crack shows through anyway.
		var skirt_facing: Array = _winding_facing(verts, indices.slice(terrain_tris * 3))
		var skirt_pos: PackedVector3Array = skirt_facing[0]
		var skirt_n: PackedVector3Array = skirt_facing[1]
		for i: int in skirt_n.size():
			var facing := Vector2(skirt_n[i].x, skirt_n[i].z)
			var outward := Vector2(skirt_pos[i].x - centre.x, skirt_pos[i].z - centre.z)
			if facing.length() > 0.0001 and outward.length() > 0.0001 \
				and facing.normalized().dot(outward.normalized()) <= 0.0:
				inward_total += 1

	_check("skirt vertex/triangle counts match skirt_vert_count/skirt_tri_count at every LOD, in one surface",
		all_counts_ok, detail)
	_check("terrain stays the first vert_count(lod) vertices in grid order (collision_faces slices on this)",
		all_layout_ok)
	_check("collision_faces() is terrain only — skirt is never handed to the physics server (D-084)",
		all_collision_ok, detail)
	_check("the terrain surface faces UP at every LOD (F-133 — it shipped inside-out)",
		downward_total == 0, "%d vertices facing down" % downward_total)
	_check("every skirt triangle faces outward at every LOD", inward_total == 0,
		"%d inward-facing" % inward_total)


## Which way the triangles in [param indices] face as the ENGINE reads them: derived from winding
## by `SurfaceTool.generate_normals()`, deliberately not from the authored ARRAY_NORMAL and not
## from a hand-rolled cross product whose sign convention is the very thing in question. A mesh can
## carry perfectly correct authored normals and still be wound inside-out — that is exactly how
## F-133 shipped, with the shading data saying "up" while the triangles said "down". Only the
## triangles decide what renders and what a trimesh collider presents to Jolt.
##
## Returns `[positions, facing_normals]`, both compacted to the vertices actually referenced and
## aligned to each other — SurfaceTool drops the rest, so these do NOT index like [param verts].
func _winding_facing(verts: PackedVector3Array, indices: PackedInt32Array) -> Array:
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var st := SurfaceTool.new()
	st.create_from(mesh, 0)
	st.generate_normals()
	var out: Array = st.commit().surface_get_arrays(0)
	return [out[Mesh.ARRAY_VERTEX], out[Mesh.ARRAY_NORMAL]]


## The seam measurement itself. Along a shared edge the coarse chunk draws a straight chord between
## samples 2*step apart while the fine chunk follows the terrain at every step — the gap between
## them IS the crack, and the skirt must be deeper than the worst of it anywhere on the island.
func _check_seam_coverage() -> void:
	var worst: float = 0.0
	var worst_at := Vector2i.ZERO
	for cz: int in range(-ISLAND_CHUNK_RADIUS, ISLAND_CHUNK_RADIUS + 1):
		for cx: int in range(-ISLAND_CHUNK_RADIUS, ISLAND_CHUNK_RADIUS + 1):
			# Every shared edge in the grid is some chunk's south or west edge, so two edges per
			# chunk covers all of them exactly once.
			for edge: int in 2:
				# Fine step 1 against coarse 2 is the LOD0/LOD1 boundary; 2 against 4 is LOD1/LOD2.
				# The ring design never puts LOD0 next to LOD2 (asserted separately, in phase 1).
				for fine_step: int in [1, 2]:
					var d: float = _max_edge_divergence(cx, cz, edge, fine_step, BENCH_SEED)
					if d > worst:
						worst = d
						worst_at = Vector2i(cx, cz)

	var known: float = maxf(
		_max_edge_divergence(WORST_KNOWN_CHUNK.x, WORST_KNOWN_CHUNK.y, 0, 2, WORST_KNOWN_SEED),
		_max_edge_divergence(WORST_KNOWN_CHUNK.x, WORST_KNOWN_CHUNK.y, 1, 2, WORST_KNOWN_SEED))

	print("  info  worst seam divergence: %.4f m on seed %d at chunk (%d,%d); %.4f m at F-128's recorded worst case (seed %d, chunk %s). Skirt depth %.3f m." % [
		worst, BENCH_SEED, worst_at.x, worst_at.y, known, WORST_KNOWN_SEED, WORST_KNOWN_CHUNK,
		ChunkMesher.SKIRT_DEPTH,
	])
	_check("skirt is deeper than the worst LOD-boundary divergence across the whole island",
		ChunkMesher.SKIRT_DEPTH > worst, "skirt %.3f m vs divergence %.4f m" % [ChunkMesher.SKIRT_DEPTH, worst])
	_check("skirt still clears F-128's recorded worst case with >= 2x margin",
		ChunkMesher.SKIRT_DEPTH >= known * 2.0,
		"skirt %.3f m vs %.4f m" % [ChunkMesher.SKIRT_DEPTH, known])
	_check("the recorded worst-case divergence (%.4f m) has not drifted" % WORST_KNOWN_DIVERGENCE_M,
		absf(known - WORST_KNOWN_DIVERGENCE_M) < 0.01,
		"now %.4f m — terrain changed; re-sweep and update the constant" % known)


## Worst gap between the fine surface and the coarse chord along one chunk edge, in metres.
## [param edge] 0 = south (z fixed), 1 = west (x fixed). Coarse step is always twice [param fine_step]
## because adjacent chunks are never more than one LOD tier apart.
func _max_edge_divergence(cx: int, cz: int, edge: int, fine_step: int, world_seed: int) -> float:
	var coarse_step: int = fine_step * 2
	var ox: float = float(cx * ChunkMesher.CHUNK_SIZE)
	var oz: float = float(cz * ChunkMesher.CHUNK_SIZE)
	# The SHIPPED surface (F-274), sampled through one set for the whole edge. Bare
	# `IslandHeightmap.height()` is the biome-blind surface the mesher stopped building.
	var set: BiomeMapScript.NoiseSet = BiomeMapScript.make_noise_set(world_seed)
	var table: BiomeMapScript.TerrainTable = BiomeMapScript.make_terrain_table(biome_defs)
	var worst: float = 0.0
	var t: int = fine_step
	while t < ChunkMesher.CHUNK_SIZE:
		if t % coarse_step != 0:
			# t falls midway between two coarse samples, so the chord there is their mean.
			var lo: int = t - fine_step
			var hi: int = t + fine_step
			var h_t: float
			var h_lo: float
			var h_hi: float
			if edge == 0:
				h_t = BiomeMapScript.surface_from_set(ox + float(t), oz, set, world_seed, table)
				h_lo = BiomeMapScript.surface_from_set(ox + float(lo), oz, set, world_seed, table)
				h_hi = BiomeMapScript.surface_from_set(ox + float(hi), oz, set, world_seed, table)
			else:
				h_t = BiomeMapScript.surface_from_set(ox, oz + float(t), set, world_seed, table)
				h_lo = BiomeMapScript.surface_from_set(ox, oz + float(lo), set, world_seed, table)
				h_hi = BiomeMapScript.surface_from_set(ox, oz + float(hi), set, world_seed, table)
			worst = maxf(worst, absf(h_t - (h_lo + h_hi) * 0.5))
		t += fine_step
	return worst


## Largest LOD-tier difference between any two neighbouring resident chunks. The skirt is sized for
## a one-tier gap, and the whole seam argument above assumes the coarse step is exactly twice the
## fine one — so this being <= 1 is a precondition of the fix, not a nicety. Enumerated by scanning
## the box around [param anchor] rather than through a new streamer API.
func _max_neighbour_tier_gap(streamer: ChunkStreamer, anchor: Vector3) -> int:
	var ac := Vector2i(
		int(floor(anchor.x / float(ChunkMesher.CHUNK_SIZE))),
		int(floor(anchor.z / float(ChunkMesher.CHUNK_SIZE))),
	)
	var r: int = ChunkStreamer.LOAD_RADIUS_CHUNKS + ChunkStreamer.HYSTERESIS_CHUNKS + 1
	var gap: int = 0
	for dz: int in range(-r, r + 1):
		for dx: int in range(-r, r + 1):
			var coord := Vector2i(ac.x + dx, ac.y + dz)
			if not streamer.is_chunk_loaded(coord):
				continue
			var lod: int = streamer.chunk_lod(coord)
			for nz: int in range(-1, 2):
				for nx: int in range(-1, 2):
					if nx == 0 and nz == 0:
						continue
					var n := Vector2i(coord.x + nx, coord.y + nz)
					if streamer.is_chunk_loaded(n):
						gap = maxi(gap, absi(lod - streamer.chunk_lod(n)))
	return gap


func _wait_real_seconds(seconds: float) -> void:
	var deadline_msec: int = Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline_msec:
		await process_frame


## Waits (bounded) for every in-flight WorkerThreadPool job to drain, so assertions below observe
## a settled state rather than a race with async mesh generation.
##
## `pending_job_count() == 0` is only trustworthy AFTER at least one ring-evaluation pass has run —
## that pass is gated by a REAL RING_EVAL_INTERVAL_SEC accumulator (chunk_streamer.gd), which is
## real wall-clock time, not a frame count, so a plain `await process_frame` loop can read "zero
## jobs" before the first evaluation has ever happened and return instantly with nothing queued.
## Two real-time waits bracket the drain: one to guarantee an evaluation pass has fired at all, one
## after in case that pass queued jobs on its very last checked frame.
func _settle(streamer: ChunkStreamer) -> void:
	await _wait_real_seconds(ChunkStreamer.RING_EVAL_INTERVAL_SEC * 1.5)
	var frames: int = 0
	while streamer.pending_job_count() > 0 and frames < MAX_SETTLE_FRAMES:
		await process_frame
		frames += 1
	await _wait_real_seconds(ChunkStreamer.RING_EVAL_INTERVAL_SEC * 1.5)
	frames = 0
	while streamer.pending_job_count() > 0 and frames < MAX_SETTLE_FRAMES:
		await process_frame
		frames += 1


func _check_ring_behavior(root_node: Node3D) -> void:
	var streamer := ChunkStreamer.new()
	streamer.world_seed = BENCH_SEED
	streamer.biome_defs = biome_defs
	root_node.add_child(streamer)
	streamer.set_anchors([Vector3.ZERO])
	await _settle(streamer)

	_check("center chunk loaded at LOD0", streamer.chunk_lod(Vector2i(0, 0)) == 0)
	_check("center chunk has a collider (nearest ring cooks eagerly, not lazily forever)",
		streamer.chunk_has_collision(Vector2i(0, 0)))

	var mid_ring_coord := Vector2i(ChunkStreamer.LOD1_RADIUS_CHUNKS, 0)
	_check("mid-ring chunk loaded at LOD1", streamer.chunk_lod(mid_ring_coord) == 1)
	_check("mid-ring chunk has no collider", not streamer.chunk_has_collision(mid_ring_coord))

	var far_ring_coord := Vector2i(ChunkStreamer.LOAD_RADIUS_CHUNKS, 0)
	_check("outer-ring chunk loaded at LOD2", streamer.chunk_lod(far_ring_coord) == 2)
	_check("outer-ring chunk has no collider", not streamer.chunk_has_collision(far_ring_coord))

	var beyond_coord := Vector2i(
		ChunkStreamer.LOAD_RADIUS_CHUNKS + ChunkStreamer.HYSTERESIS_CHUNKS + 1, 0
	)
	_check("chunk beyond load+hysteresis radius never loads", not streamer.is_chunk_loaded(beyond_coord))

	# F-133's other half. `ConcavePolygonShape3D` faces are one-sided — `backface_collision` is off
	# by default — so an inside-out terrain is not merely invisible from above, it is a floor that
	# players fall through. Rendering and collision read the same winding, so this is the assertion
	# that makes the bug a gameplay failure rather than a cosmetic one; a ray straight down onto the
	# centre chunk is the cheapest honest test of it.
	var space: PhysicsDirectSpaceState3D = root_node.get_world_3d().direct_space_state
	var ray_from := Vector3(16.0, 400.0, 16.0)
	var query := PhysicsRayQueryParameters3D.create(ray_from, ray_from + Vector3.DOWN * 800.0)
	var hit: Dictionary = space.intersect_ray(query)
	_check("a ray straight down hits the centre chunk's collider — terrain is a floor from above, not only from below (F-133)",
		not hit.is_empty())

	# F-128/D-084's precondition: the skirt is sized for a one-tier seam, so the ring design must
	# never actually put LOD0 against LOD2. Chebyshev ring distance changes by at most 1 per grid
	# step and tightening is immediate, so this should hold by construction — measured rather than
	# assumed, because the seam sizing above depends on it.
	var settled_gap: int = _max_neighbour_tier_gap(streamer, Vector3.ZERO)
	_check("neighbouring chunks never differ by more than one LOD tier (settled ring)",
		settled_gap <= 1, "largest gap %d tiers" % settled_gap)

	# Hysteresis: nudge the anchor one chunk further out. far_ring_coord's ring grows from
	# LOAD_RADIUS to LOAD_RADIUS + 1, which is still <= LOAD_RADIUS + HYSTERESIS — D-025's lesson
	# says it must stay loaded rather than reload every step along the boundary.
	var nudge: float = float(ChunkMesher.CHUNK_SIZE)
	streamer.set_anchors([Vector3(-nudge, 0.0, 0.0)])
	await _settle(streamer)
	_check("a chunk just past its ring boundary stays loaded (hysteresis, D-025's lesson)",
		streamer.is_chunk_loaded(far_ring_coord))

	# Push it well past the leave boundary — now it must actually unload.
	streamer.set_anchors([Vector3(-nudge * 4.0, 0.0, 0.0)])
	await _settle(streamer)
	_check("a chunk well past leave radius eventually unloads",
		not streamer.is_chunk_loaded(far_ring_coord))

	streamer.queue_free()
	await process_frame


func _check_sprint_walk(root_node: Node3D) -> void:
	var streamer := ChunkStreamer.new()
	streamer.world_seed = BENCH_SEED
	streamer.biome_defs = biome_defs
	root_node.add_child(streamer)

	var pos := Vector3.ZERO
	streamer.set_anchors([pos])
	# Cold start is out of scope for this measurement: loading the very first neighbourhood (up to
	# a full (2*(LOAD_RADIUS+HYSTERESIS)+1)^2 chunk box, all requested in one evaluation pass
	# because nothing was loaded yet) is a one-time cost the same way any game's initial level load
	# is not part of its in-session frame-time budget. The spec's acceptance test is about
	# STREAMING while already moving, so settle the spawn-in neighbourhood before starting the
	# timed walk below — exactly what a loading screen would cover in the shipped game.
	await _settle(streamer)

	var traveled: float = 0.0
	var frame_ms_samples := PackedFloat32Array()
	var own_cost_ms_samples := PackedFloat32Array()
	var hitches: int = 0
	var own_cost_hitches: int = 0
	var worst_ms: float = 0.0
	var worst_own_cost_ms: float = 0.0
	var t_prev: int = Time.get_ticks_usec()

	while traveled < TARGET_DISTANCE_M:
		await process_frame
		var t_now: int = Time.get_ticks_usec()
		var frame_ms: float = float(t_now - t_prev) / 1000.0
		t_prev = t_now
		frame_ms_samples.append(frame_ms)
		worst_ms = maxf(worst_ms, frame_ms)
		if frame_ms > HITCH_THRESHOLD_MS:
			hitches += 1

		# The streamer's OWN issuing cost for that same frame — ring eval plus budgeted upload/
		# collision work, nothing else. This machine runs several concurrent agent lanes at once
		# (D-074's own caveat), so total real frame time above is not a clean signal of whether
		# THIS system's design holds its budget: an unrelated OS scheduling stall reads identically
		# to a real overrun in `frame_ms` alone. `last_process_cost_ms()` is not subject to that —
		# it is a wall-clock measurement taken entirely inside this node's own call.
		var own_cost_ms: float = streamer.last_process_cost_ms()
		own_cost_ms_samples.append(own_cost_ms)
		worst_own_cost_ms = maxf(worst_own_cost_ms, own_cost_ms)
		if own_cost_ms > HITCH_THRESHOLD_MS:
			own_cost_hitches += 1

		# Movement derived from REAL elapsed wall time, same accumulator the engine's own physics
		# catch-up uses (§5a) — a slow frame still advances the anchor by roughly what a real
		# player's physics ticks would have covered in that time. Clamped so one anomalously slow
		# iteration (process/GC hiccup unrelated to steady-state streaming) cannot fling the anchor
		# far enough to demand a whole new ring at once and cascade into a fake hitch storm.
		var step: float = minf(SPRINT_SPEED_MPS * (frame_ms / 1000.0), SPRINT_SPEED_MPS * 0.1)
		traveled += step
		pos.x += step
		streamer.set_anchors([pos])

	var mean_ms: float = _mean(frame_ms_samples)
	var mean_own_cost_ms: float = _mean(own_cost_ms_samples)
	print("TOTAL FRAME TIME  frames=%d | distance=%.1f m | mean %.3f ms | worst %.3f ms | hitches(>%.3f ms)=%d | chunks loaded=%d" % [
		frame_ms_samples.size(), traveled, mean_ms, worst_ms, HITCH_THRESHOLD_MS, hitches,
		streamer.loaded_chunk_count(),
	])
	print("STREAMER'S OWN COST (excludes rendering/physics/other processes on this shared machine)")
	print("                  mean %.4f ms | worst %.4f ms | hitches(>%.3f ms)=%d" % [
		mean_own_cost_ms, worst_own_cost_ms, HITCH_THRESHOLD_MS, own_cost_hitches,
	])
	print("CHUNK_STREAM_CHECK_DONE hitches=%d worst_ms=%.4f mean_ms=%.4f own_cost_hitches=%d own_cost_worst_ms=%.4f own_cost_mean_ms=%.4f frames=%d distance_m=%.1f" % [
		hitches, worst_ms, mean_ms, own_cost_hitches, worst_own_cost_ms, mean_own_cost_ms,
		frame_ms_samples.size(), traveled,
	])
	_check("streamer's own per-frame cost never exceeds %.3f ms across a %.0f m sprint walk (the spec's acceptance test, measured as this system's own issuing cost — see header)" % [
		HITCH_THRESHOLD_MS, TARGET_DISTANCE_M,
	], own_cost_hitches == 0, "%d hitch(es), worst %.4f ms" % [own_cost_hitches, worst_own_cost_ms])
	if hitches > own_cost_hitches:
		print("  note  %d total-frame-time hitch(es) did not come from this node's own cost — shared-machine noise (D-074), not a finding against this task" % [
			hitches - own_cost_hitches,
		])

	var walked_gap: int = _max_neighbour_tier_gap(streamer, pos)
	_check("neighbouring chunks still never differ by more than one LOD tier after a %.0f m walk (hysteresis exercised)" % TARGET_DISTANCE_M,
		walked_gap <= 1, "largest gap %d tiers" % walked_gap)

	streamer.queue_free()
	await process_frame


## F-132: proves the fix is a calling contract, not a code change. One real `ChunkStreamer` fed two
## independent anchors — standing in for "the host's own local player" and "a remote connected
## peer's last-known position" — must resolve BOTH chunks to a resident, collision-bearing LOD0
## entry, and a real `ResourceScatterField` attached to it must build a live, `HarvestWorld`-wired
## `Harvestable` at each. `min_separation` is chosen so anchor A's own LOD0 ring
## (`LOD0_RADIUS_CHUNKS + HYSTERESIS_CHUNKS`, see F-251/D-150) can't reach anchor B's chunk — a
## streamer that (bugged) only ever unioned its NEAREST anchor would still pass a test where the two
## targets happen to sit inside each other's LOD0 ring, so this rules that out by construction
## rather than by luck.
func _check_union_of_interest() -> void:
	var registry: Node = root.get_node_or_null(^"Registry")
	_check("Registry is registered as an autoload", registry != null)
	if registry == null:
		return
	var scatter_defs: Array = (registry.get(&"scatter_tables") as Dictionary).values()
	var biome_defs: Array = (registry.get(&"biomes") as Dictionary).values()

	var chunk_a: Vector2i = _find_harvestable_chunk(scatter_defs, biome_defs, Vector2i.ZERO, 0)
	_check("found a chunk with a harvestable placement for the 'host local player' anchor (%s)" % chunk_a,
		chunk_a != NOT_FOUND_CHUNK)
	if chunk_a == NOT_FOUND_CHUNK:
		return

	# F-251 (2026-08-19): was LOAD_RADIUS_CHUNKS-based (10 chunks / 320 m) — a separation big enough
	# that NEITHER anchor's full outer ring could reach the other. That doesn't fit this island any
	# more: `IslandHeightmap.ISLAND_RADIUS` shrank 512->118 m (D-143 era) and harvestable placements
	# never occur past Chebyshev radius 6 from origin (open water beyond the island has none), so no
	# two harvestable-bearing chunks are ever 10 apart and this always returned NOT_FOUND. The
	# assertions below only need chunk_b outside chunk_a's LOD0 ring (proving b's own COLLIDER came
	# from b's own anchor, not from a's radius) — see D-150.
	var min_separation: int = ChunkStreamer.LOD0_RADIUS_CHUNKS + ChunkStreamer.HYSTERESIS_CHUNKS + 1
	var chunk_b: Vector2i = _find_harvestable_chunk(scatter_defs, biome_defs, chunk_a, min_separation)
	_check("found a second chunk with a harvestable placement, >= %d chunks from the first, for the 'remote peer' anchor (%s)" % [min_separation, chunk_b],
		chunk_b != NOT_FOUND_CHUNK)
	if chunk_b == NOT_FOUND_CHUNK:
		return

	var pos_a: Vector3 = _chunk_center(chunk_a)
	var pos_b: Vector3 = _chunk_center(chunk_b)

	# `current_scene` must be a DIRECT child of `root` (SceneTree enforces this) — unlike the other
	# phases above, which nest under the shared `root_node`, this scene stands alone so
	# `HarvestWorld.refresh_current_scene()`'s own scene-ancestry check (autoload/harvest_world.gd)
	# actually wires the holders this phase builds.
	var scene := Node3D.new()
	scene.name = "UnionOfInterestCheckScene"
	root.add_child(scene)
	current_scene = scene

	var streamer := ChunkStreamer.new()
	streamer.world_seed = BENCH_SEED
	streamer.biome_defs = biome_defs
	scene.add_child(streamer)

	# `attach_to_streamer()` only reacts to FUTURE `chunk_mesh_ready`/`chunk_unloaded` signals — it
	# does not retroactively scan chunks already resident at attach time — so, matching the real
	# caller order both DELEGATION.md snippets show (streamer built and added first, then the field
	# attached, THEN anchors set and re-set every frame), the field is wired before the streamer is
	# ever given anchors to stream around.
	var field := ResourceScatterFieldScript.new()
	field.world_seed = BENCH_SEED
	field.scatter_defs = scatter_defs
	field.biome_defs = biome_defs
	scene.add_child(field)
	field.attach_to_streamer(streamer)

	# The host's own local player position PLUS a remote connected peer's last-known position — the
	# union-of-interest contract F-132 records. A host anchored ONLY to its own local player never
	# builds a proxy for a point a remote client can locally reach.
	streamer.set_anchors([pos_a, pos_b])
	await _settle(streamer)

	_check("the 'host local' anchor's chunk loaded at LOD0 with a collider",
		streamer.chunk_lod(chunk_a) == 0 and streamer.chunk_has_collision(chunk_a))
	_check("the 'remote peer' anchor's chunk ALSO loaded at LOD0 with a collider — not just the nearest anchor's",
		streamer.chunk_lod(chunk_b) == 0 and streamer.chunk_has_collision(chunk_b))

	# Every chunk in EITHER anchor's LOD0 ring gets scatter, not just the two exact target chunks —
	# `chunk_count()` alone can't tell them apart, so the holders below are checked by name.
	await _wait_real_seconds(ResourceScatterFieldScript.COLLISION_POLL_INTERVAL_SEC * 4.0)
	_check("both far-apart chunks are among the ones that materialized scatter (%d chunks total)" % field.chunk_count(),
		field.get_node_or_null(NodePath("Chunk_%d_%d" % [chunk_a.x, chunk_a.y])) != null
			and field.get_node_or_null(NodePath("Chunk_%d_%d" % [chunk_b.x, chunk_b.y])) != null)

	var harvest: Node = root.get_node_or_null(^"HarvestWorld")
	_check("HarvestWorld autoload exists", harvest != null)
	if harvest != null:
		harvest.call("refresh_current_scene")
	for _frame: int in 8:
		await process_frame

	_check("a live, host-authoritative Harvestable exists at the 'host local' anchor's point",
		_chunk_has_wired_harvestable(field, chunk_a))
	_check("a live, host-authoritative Harvestable ALSO exists at the 'remote peer' anchor's point — the exact node an rpc_id(HOST_PEER_ID) call from that peer would need to reach (F-132)",
		_chunk_has_wired_harvestable(field, chunk_b))

	current_scene = null
	scene.queue_free()
	await process_frame


## Scans outward in Chebyshev rings from the origin for the first chunk producing at least one
## harvestable placement, skipping any coord within [param min_separation] chunks of [param avoid]
## (Chebyshev, matching `ChunkStreamer`'s own ring metric). [param min_separation] 0 disables that
## filter, for the first (unconstrained) search.
func _find_harvestable_chunk(
	scatter_defs: Array, biome_defs: Array, avoid: Vector2i, min_separation: int
) -> Vector2i:
	for radius: int in range(0, ISLAND_CHUNK_RADIUS + 1):
		for cx: int in range(-radius, radius + 1):
			for cz: int in range(-radius, radius + 1):
				if maxi(absi(cx), absi(cz)) != radius:
					continue
				var coord := Vector2i(cx, cz)
				if min_separation > 0 and maxi(absi(coord.x - avoid.x), absi(coord.y - avoid.y)) < min_separation:
					continue
				var placements: Array[Dictionary] = ResourceScatterLib.placements_for_chunk(
					cx, cz, BENCH_SEED, scatter_defs, biome_defs
				)
				for placement: Dictionary in placements:
					var asset_id: StringName = placement["asset"]
					if HarvestLib.is_harvestable(asset_id):
						return coord
	return NOT_FOUND_CHUNK


func _chunk_center(coord: Vector2i) -> Vector3:
	var size: float = float(ChunkMesher.CHUNK_SIZE)
	return Vector3((float(coord.x) + 0.5) * size, 0.0, (float(coord.y) + 0.5) * size)


## `field`'s own child-naming convention (`world/gen/resource_scatter_field.gd::_build_chunk()`):
## one holder named `Chunk_<x>_<z>` per resident chunk, however many `Harvestable` descendants
## `HarvestWorld` has wired into it.
func _chunk_has_wired_harvestable(field: Node, coord: Vector2i) -> bool:
	var holder: Node = field.get_node_or_null(NodePath("Chunk_%d_%d" % [coord.x, coord.y]))
	if holder == null:
		return false
	return not holder.find_children("Harvestable", "", true, false).is_empty()


func _mean(values: PackedFloat32Array) -> float:
	if values.is_empty():
		return 0.0
	var total: float = 0.0
	for v: float in values:
		total += v
	return total / float(values.size())
