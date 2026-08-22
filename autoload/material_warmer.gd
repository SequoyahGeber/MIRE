extends Node

## MaterialWarmer — draws every shipped material once, off-screen, while the player is still in the
## menu, so the one-time shader/pipeline compilation cost is not paid as hitches during their first
## minutes of play. Register as autoload `MaterialWarmer` → res://autoload/material_warmer.gd.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, "VFX, audio, camera, UI"): **none**. This is purely
## client-local presentation warm-up. It creates no game state, replicates nothing, and every peer
## runs its own copy independently — there is nothing here two machines could disagree about.
##
## ## What this is for (F-516)
##
## `tools/revisit_probe.gd` measured two arrivals at ground the player had never been, with unrelated
## locations visited in between. Neither leg had cached geometry and F-407 had already warmed the
## GLB loads, so loading was not the difference:
##
##     run 1   A cold  17035 nodes, 1% low 149.64 ms, 34 hitches
##             B warm  31247 nodes, 1% low  56.12 ms,  9 hitches
##
## Leg B creates roughly twice the nodes for three to four times less cost. What is left is a
## one-time cost per distinct material, paid the first time something is drawn.
##
## It matters more than the numbers suggest: it is paid on every machine, during a player's FIRST
## minutes, and **no graphics preset touches it** — D-194 already excludes travelling scenes from
## choosing a preset for this exact reason. It is worst on the low-end target this project ships to
## (F-174), where compilation is slowest. It is the one performance problem a player cannot mitigate
## and we cannot tune. It can only be pre-paid, and the menu is where paying it is free.
##
## `rendering/shader_compiler/shader_cache/enabled` is already on, but that caches compiled shaders
## across RUNS — it does nothing for the first run on a given machine, and nothing for pipeline state
## objects created on first draw.
##
## ## Why it draws real meshes rather than material swatches
##
## A pipeline state object is keyed by more than the material: the mesh's vertex format is part of
## it. Warming a material on a stand-in quad would compile the shader but leave the real pipeline to
## be created on first draw anyway, which is half the cost and the harder half to notice missing.
## So this instantiates each shipped GLB and renders it as-is. That also means nothing has to be kept
## in sync — a new asset is warmed the day it lands in `exports/`, with no registration step to
## forget (the failure mode F-051 exists to name).
##
## ## Why a directory scan and not the scatter tables
##
## `ResourceScatterField._pump_asset_warm()` enumerates what the scatter tables can place, which is
## most of the prop set but not the enemies, the tools, the buildables or the ships. Walking
## `res://assets/*/exports/*.glb` is a superset of every per-domain list and cannot drift out of date
## as the domains change. The cost of warming an asset the run never places is one off-screen draw of
## a 32x32 target; the cost of missing one is a hitch in front of the player.
##
## ## What this deliberately does NOT cover
##
## `world/environment/ground_fog.gdshader` is `shader_type fog`, which can only be warmed through a
## `FogVolume` inside an `Environment` with volumetric fog enabled — a materially different setup
## from the spatial pass below, and the fog is one shader against ~483 assets. It stays on the list
## as a known gap rather than being quietly implied to be covered.

## Off-screen target size. Deliberately tiny: the pipeline is compiled by the DRAW happening at all,
## not by how many pixels it covers, so anything larger is pure fill-rate spent for nothing.
const WARM_VIEWPORT_SIZE := Vector2i(32, 32)
## Where `exports/` directories live. Every art domain in this project follows
## `assets/<kit>/exports/<asset>.glb` (see `assets/enemies/README.md` and its siblings).
const ASSETS_ROOT: String = "res://assets"
const EXPORTS_DIR: String = "exports"
## How many threaded load requests may be outstanding. Same reasoning and same order of magnitude as
## `ResourceScatterField.WARM_REQUESTS_IN_FLIGHT` — enough to keep the loader busy, few enough that
## the menu's own frame does not go long behind a burst of completions.
const REQUESTS_IN_FLIGHT: int = 8
## How many warmed instances may be drawn per frame. This is the knob that keeps the MENU smooth
## while it works: the whole point is to move the cost off the player's first minutes of play, and
## moving it onto a stuttering title screen would just relocate the problem somewhere else visible.
##
## At 4 per frame the ~483 shipped assets take about 120 frames — two seconds of title screen at 60
## fps, and still only a few seconds on the low-end target this exists for (F-174). That is well
## inside the time a player spends reading the menu, so there is no need to trade frame smoothness
## for a faster pass.
const DRAWS_PER_FRAME: int = 4
## Frames an instance stays in the viewport before it is freed. One full frame must actually be
## rendered with it present or nothing is compiled; two is one frame of slack for a renderer that
## defers the draw, and costs one extra frame of its memory.
const FRAMES_ON_SCREEN: int = 2
## Grace before the first request, so the menu is up and interactive before this starts competing
## with it for frame time. The player is reading the title screen; nothing is urgent.
const START_DELAY_SEC: float = 1.0

## Spatial shaders built at runtime rather than embedded in a GLB, so no asset draw covers them.
## Warmed on a plain quad — for these the mesh format genuinely does not matter, because the real
## meshes they run on (terrain chunks, water planes, foliage cards, particle billboards) are all
## generated at runtime and there is no shipped asset to instantiate instead.
const RUNTIME_SPATIAL_SHADERS: Array[String] = [
	"res://world/chunk/terrain_flat.gdshader",
	"res://world/environment/water_low_poly.gdshader",
	"res://world/environment/foliage_wind.gdshader",
	"res://world/environment/particle_billboard.gdshader",
]

var _viewport: SubViewport
var _camera: Camera3D
var _pending: PackedStringArray = PackedStringArray()
var _active: Array = []
## [instance, frames_remaining] for everything currently in the viewport.
var _showing: Array = []
var _elapsed: float = 0.0
var _started: bool = false
var _finished: bool = false
var _warmed_count: int = 0


func _ready() -> void:
	# Never in the editor: the editor already draws these materials in its own viewports, and a
	# hidden SubViewport spinning up on project load is exactly the kind of thing that makes the
	# editor feel broken for no benefit.
	if Engine.is_editor_hint():
		set_process(false)
		_finished = true
		return
	_pending = _enumerate_assets()
	# Headless has nothing to warm — the dummy rendering driver compiles no shaders and creates no
	# pipeline state objects, so the entire pass is 483 pointless GLB loads. That is not merely
	# wasted: every `tools/*_check.gd` harness in this project runs headless, and quietly attaching a
	# few hundred threaded loads to all of them would slow the whole suite and perturb the
	# timing-sensitive ones (the two-process net checks especially). A real player is never headless.
	#
	# `tools/material_warm_check.gd` drives the pass through `force_complete_now()`, which starts it
	# explicitly rather than through this gate — so the check still exercises everything here.
	if DisplayServer.get_name() == "headless":
		set_process(false)


func _process(delta: float) -> void:
	if _finished:
		return
	if not _started:
		_elapsed += delta
		if _elapsed < START_DELAY_SEC:
			return
		_started = true
		_build_viewport()
		_warm_runtime_shaders()

	_age_showing()
	_pump_requests()
	_draw_completed()

	if _pending.is_empty() and _active.is_empty() and _showing.is_empty():
		_teardown()


## Every shipped GLB, as `res://assets/<kit>/exports/<asset>.glb`.
##
## Walks the directory rather than reading a manifest on purpose — see the header. `DirAccess` sees
## exported PCK contents at runtime the same way it sees the project directory in development, so
## this returns the same list in a shipped build as it does here.
func _enumerate_assets() -> PackedStringArray:
	var found := PackedStringArray()
	var root := DirAccess.open(ASSETS_ROOT)
	if root == null:
		MireLog.warn(&"perf", "MaterialWarmer: cannot open %s — nothing pre-warmed" % ASSETS_ROOT)
		return found
	for kit: String in root.get_directories():
		var exports_path := "%s/%s/%s" % [ASSETS_ROOT, kit, EXPORTS_DIR]
		var exports := DirAccess.open(exports_path)
		if exports == null:
			continue
		for file: String in exports.get_files():
			# `.import` siblings and (in an exported build) `.remap` suffixes both show up here; only
			# the GLB itself is loadable, and load()ing anything else logs an error per file.
			if file.ends_with(".glb"):
				found.append("%s/%s" % [exports_path, file])
	return found


## A world of its own, so nothing warmed here is ever visible in, or lit by, the real scene.
func _build_viewport() -> void:
	_viewport = SubViewport.new()
	_viewport.size = WARM_VIEWPORT_SIZE
	_viewport.own_world_3d = true
	_viewport.transparent_bg = true
	# UPDATE_ALWAYS, not UPDATE_ONCE: this viewport must render on every frame it holds something new,
	# and UPDATE_ONCE would have to be re-armed per batch — one more thing to get wrong for no gain
	# over a 32x32 target.
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_viewport)

	_camera = Camera3D.new()
	_camera.position = Vector3(0.0, 0.0, 6.0)
	_camera.current = true
	_viewport.add_child(_camera)

	# A light, because an unlit draw can take a different pipeline path than the lit one the game
	# actually uses — warming the wrong variant would look like success and change nothing.
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45.0, -30.0, 0.0)
	_viewport.add_child(light)


## The four runtime-built spatial shaders, on a quad. All at once rather than batched: four draws is
## not a frame, and these are the ones the very first chunk of terrain needs.
func _warm_runtime_shaders() -> void:
	for path: String in RUNTIME_SPATIAL_SHADERS:
		var shader: Shader = load(path) as Shader
		if shader == null:
			MireLog.warn(&"perf", "MaterialWarmer: %s did not load as a Shader" % path)
			continue
		var material := ShaderMaterial.new()
		material.shader = shader
		var quad := MeshInstance3D.new()
		quad.mesh = QuadMesh.new()
		quad.material_override = material
		_show(quad)


func _pump_requests() -> void:
	while _active.size() < REQUESTS_IN_FLIGHT and not _pending.is_empty():
		var path: String = _pending[0]
		_pending.remove_at(0)
		if ResourceLoader.load_threaded_request(path) == OK:
			_active.append(path)


func _draw_completed() -> void:
	var drawn: int = 0
	for index: int in range(_active.size() - 1, -1, -1):
		if drawn >= DRAWS_PER_FRAME:
			break
		var path: String = _active[index]
		var status: int = ResourceLoader.load_threaded_get_status(path)
		if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			continue
		_active.remove_at(index)
		if status != ResourceLoader.THREAD_LOAD_LOADED:
			continue
		var scene: PackedScene = ResourceLoader.load_threaded_get(path) as PackedScene
		if scene == null:
			continue
		var instance: Node = scene.instantiate()
		var body := instance as Node3D
		if body == null:
			instance.free()
			continue
		_show(body)
		_warmed_count += 1
		drawn += 1


## Puts one node in front of the warm camera for [constant FRAMES_ON_SCREEN] frames.
##
## Scaled to a fixed size rather than placed at its authored scale: a 20 m tree and a 20 cm mushroom
## both have to be ON screen for their draw to happen at all, and the pipeline does not care how big
## the triangle ends up.
func _show(body: Node3D) -> void:
	_viewport.add_child(body)
	var extent: float = _radius_of(body)
	if extent > 0.0:
		body.scale = Vector3.ONE * (1.5 / extent)
	body.position = Vector3.ZERO
	_showing.append([body, FRAMES_ON_SCREEN])


## Longest axis of the node's combined AABB, or 0 when it has no visual instance at all (a GLB that
## is only an armature or an empty, which is warmed as a no-op rather than skipped — asking is
## cheaper than maintaining a list of which assets have meshes).
func _radius_of(body: Node3D) -> float:
	var aabb := AABB()
	var seeded: bool = false
	for node: Node in _all_descendants(body):
		var visual := node as VisualInstance3D
		if visual == null:
			continue
		var box: AABB = visual.get_aabb()
		if not seeded:
			aabb = box
			seeded = true
		else:
			aabb = aabb.merge(box)
	if not seeded:
		return 0.0
	return maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z))


func _all_descendants(root: Node) -> Array[Node]:
	var out: Array[Node] = [root]
	for child: Node in root.get_children():
		out.append_array(_all_descendants(child))
	return out


func _age_showing() -> void:
	for index: int in range(_showing.size() - 1, -1, -1):
		var entry: Array = _showing[index]
		entry[1] = int(entry[1]) - 1
		if int(entry[1]) > 0:
			continue
		_showing.remove_at(index)
		var body: Node = entry[0]
		if is_instance_valid(body):
			body.queue_free()


## Frees the whole warm rig. Nothing about it is worth keeping resident — it is a one-shot cost, and
## a SubViewport left on UPDATE_ALWAYS would go on rendering an empty 32x32 target forever.
func _teardown() -> void:
	_finished = true
	set_process(false)
	if is_instance_valid(_viewport):
		_viewport.queue_free()
	_viewport = null
	_camera = null
	MireLog.info(&"perf", "MaterialWarmer: pre-warmed %d asset(s) and %d runtime shader(s)"
		% [_warmed_count, RUNTIME_SPATIAL_SHADERS.size()])


# ── test seams ────────────────────────────────────────────────────────────────────────────────────


## How many assets the enumeration found, without waiting for any of them to be drawn. Lets a check
## assert coverage — the property that actually breaks silently when an art domain moves — separately
## from the draw loop.
func pending_asset_count() -> int:
	return _pending.size() + _active.size()


func warmed_asset_count() -> int:
	return _warmed_count


func is_finished() -> bool:
	return _finished


## Runs the warm pass to completion, one loop iteration per real frame, instead of waiting for
## `_process` to drive it. For checks only.
##
## This deliberately runs the SAME body `_process` does rather than a faster straight-line version.
## The first attempt skipped `_age_showing()` on the theory that freeing could wait until the end —
## with `_process` disabled under the headless gate nothing else was aging them, all 483 instances
## stayed live in the viewport at once, and the process died on the memory. Sharing the body is what
## keeps that class of divergence from coming back: if the loop below is ever wrong, it is wrong in
## the same way the real path is.
##
## Awaiting a real frame each iteration is not padding either — an instance has to be present for a
## frame that actually renders, or nothing is compiled and the pass warms nothing.
func force_complete_now() -> void:
	if _finished:
		return
	_started = true
	if _viewport == null:
		_build_viewport()
		_warm_runtime_shaders()
	while not _finished:
		_age_showing()
		_pump_requests()
		_draw_completed()
		if _pending.is_empty() and _active.is_empty() and _showing.is_empty():
			_teardown()
			return
		await get_tree().process_frame
