extends Node

## EnvironmentVfx — client-local environmental presentation, bound to **assets**, never to levels.
##
## ## AUTHORITY: none
##
## `docs/ARCHITECTURE.md` §2.2, "VFX, audio, camera, UI" row. Every peer runs this independently
## off the same asset ids; nothing here crosses the wire and no gameplay state reads it. Two peers
## on different graphics presets see a different number of campfire lights and simulate identically.
##
## ## What it does
##
## Two effects, both keyed by asset id through `AssetVfxLibrary`:
##
## 1. **Sway** — foliage materials are swapped for `foliage_wind.gdshader`, tuned per asset. This is
##    done once per unique mesh resource, so it costs one pass per *asset*, not per instance, and
##    13,026 instanced plants cost the same as one.
## 2. **Emitters** — fires, crystals and spore clouds. Sites are collected as bare transforms and
##    served by a **fixed pool** of effect nodes, nearest-first. A world with four campfires and a
##    world with four hundred cost the same to draw.
##
## ## Why asset-bound (F-097)
##
## The first version walked the level for `MeshInstance3D` nodes with "grass" in their name. On
## Hollowmere that matched **nothing**: both generators emit `MultiMeshInstance3D` batches, so all
## 1,740 of them and every copy inside them were invisible, and the map shipped with no wind and no
## firelight at all. It looked green only because its check booted the deprecated Playtest Hollow.
##
## Release worlds are procedurally generated, so a level is not something to bind behaviour to. A
## generator stamps `ASSET_META` on what it emits; this system reads that and nothing else about
## the scene. A new generator inherits every effect here by stamping the same meta.
##
## Discovery falls back to node names when the meta is absent, which is what keeps hand-authored
## scenes (Playtest Hollow, a test fixture someone builds in the editor) working. The fallback is
## nearly free because `AssetVfxLibrary` matches asset-name *prefixes*: `grass_tuft_a_17` still
## resolves to `grass_`.

## The generator contract. `world/gen/authored_world.gd` already stamped this on its harvestable
## holders before F-097; both generators now stamp it on every emitted node, so there is one
## convention for "which asset is this" rather than a private one for presentation.
const ASSET_META: StringName = &"asset"
## Where every copy of an asset stands, in the coordinate space of the node that carries it. A
## generator publishes this for any asset whose presentation is per-copy; without it an instanced
## batch has no per-copy position that can be read anywhere but the GPU.
const PLACEMENTS_META: StringName = &"placements"
## F-203: declares a merged multi-asset holder's emitter class directly, bypassing the asset-id
## lookup entirely. `world/gen/authored_world.gd` stamps this on a `MeshInstance3D` that bakes
## several DIFFERENT emitter-bearing assets sharing ONE class into one static mesh per chunk —
## `AssetVfxLibrary.emitter_for` can't resolve a class from asset identity once that identity no
## longer survives the merge, so the generator declares the class it already grouped by instead.
## Holds an `AssetVfxLibrary.Emitter` int. `PLACEMENTS_META` still carries the per-instance
## positions exactly as it does for a per-asset holder; only the class lookup changes.
const EMITTER_META: StringName = &"vfx_emitter"
## F-208: declares a merged multi-asset holder's sway profile directly, the same reason
## `EMITTER_META` exists — `world/gen/authored_world.gd` stamps this on a `MeshInstance3D` that
## bakes several DIFFERENT sway-bearing assets sharing ONE `AssetVfxLibrary.Sway` into one static
## mesh per chunk. A merged holder's mesh already carries a per-vertex baked height mask (see
## `core/render/mesh_merge.gd`'s `bake_height_mask`), so dressing it needs the profile only, never
## a per-mesh AABB — `_apply_baked_sway` reads this instead of walking the asset-id path.
## Holds an `AssetVfxLibrary.Sway` int.
const SWAY_META: StringName = &"vfx_sway"
const VFX_META: StringName = &"mire_environment_vfx_applied"
## Preloaded rather than referenced by its `class_name`. A brand-new `class_name` only enters
## `.godot/global_script_class_cache.cfg` when the editor scans the project, and `agent godot` is
## always a headless `--script` run that never does (the same family of trap as F-093). Referencing
## it by name parses fine in the editor and fails everywhere an agent can actually verify, so the
## path is spelled out here instead.
const AssetVfx := preload("res://world/environment/asset_vfx_library.gd")
## Same spelled-out-path reasoning as `AssetVfx` above, and the idiom every other
## `run_restarted` subscriber in this project uses (`autoload/build_service.gd:32`).
const EVENT_BUS := preload("res://core/events/event_bus.gd")
const FOLIAGE_SHADER := preload("res://world/environment/foliage_wind.gdshader")
const PARTICLE_SHADER := preload("res://world/environment/particle_billboard.gdshader")
## Marks the prop an emitter site was already taken from, so its other forty mesh parts do not each
## register one of their own. See `_emitter_host`.
const EMITTER_HOST_META: StringName = &"mire_vfx_emitter_host"

## How often the nearest-first emitter assignment is recomputed. Sites number in the hundreds and
## the player walks at 4.4 m/s, so four times a second is far below anything visible.
const BUDGET_INTERVAL: float = 0.25
## Sites closer together than this are treated as one — a defence against an asset that emits more
## than one MultiMesh part, which would otherwise register the same campfire twice.
const SITE_MERGE_DISTANCE: float = 0.35
## Emitter counts are scaled by the graphics preset. Low-end machines pay for lights first.
const BUDGET_BY_PRESET: PackedFloat32Array = [0.4, 0.7, 1.0]

## Kept from the first version because the existing checks read them.
var foliage_mesh_count: int = 0
var fire_source_count: int = 0
## Asset-level counters — the honest measure now that one material serves thousands of copies.
var sway_asset_count: int = 0
var emitter_site_count: int = 0

var _sway_materials: Dictionary = {}
var _dressed_meshes: Dictionary = {}
var _sites: Dictionary = {}
## `AssetVfx.Emitter` -> `PackedInt64Array` of the instance id of the node each site in
## `_sites[emitter]` was registered from, index for index. The two arrays are written and
## pruned only by `_register_emitter()`/`_prune_dead_sites()`, which is what keeps them in step.
## This is the whole node-removed path (F-287): a site is scene-derived state, and nothing
## else in this file records which piece of scene it was derived FROM.
var _site_sources: Dictionary = {}
var _pools: Dictionary = {}
var _effect_root: Node3D = null
var _time: float = 0.0
var _budget_timer: float = 0.0
var _scene_id: int = 0


func _ready() -> void:
	# Imported GLBs and generated worlds both enter the tree after autoloads, so cover the current
	# scene and everything added later.
	get_tree().node_added.connect(_on_node_added)
	# F-287: the procedural generation boundary. `ProceduralWorld.rebuild_for_seed()` re-derives the
	# island INSIDE the existing current scene, so the scene-id test in `_process` — the only
	# invalidation this file had — deliberately does not fire, and every site of the ended island
	# would otherwise stay in the pools alongside the new one's.
	EVENT_BUS.subscribe_run_restarted(_on_run_restarted)
	call_deferred("refresh_scene")


func _exit_tree() -> void:
	EVENT_BUS.unsubscribe_run_restarted(_on_run_restarted)


func _process(delta: float) -> void:
	_time += delta
	var scene: Node = get_tree().current_scene
	var scene_id: int = 0 if scene == null else scene.get_instance_id()
	if scene_id != _scene_id:
		# A new level — the old sites belong to a freed tree and nothing may outlive it.
		_reset()
		refresh_scene()
		return

	# F-105: a world with no fire/crystal/spore sites at all (or before refresh_scene() has found
	# any) has nothing for the budget timer or the light-flicker pass to do — skip both rather than
	# pay the dictionary-empty checks inside them every frame regardless. `_sites`/`_pools` are the
	# whole state either loop reads, so both empty is the exact condition under which neither can do
	# anything; `_time` simply resumes counting once something registers, which nothing but the
	# flicker phase (itself just a sine offset, not a clock anyone reads) depends on.
	if _sites.is_empty() and _pools.is_empty():
		return

	_budget_timer += delta
	if _budget_timer >= BUDGET_INTERVAL:
		_budget_timer = 0.0
		# Pruned on the same tick that ranks, because "which sites exist" and "which sites are
		# nearest" are the same question asked of the same array — and because this is the one
		# path that covers a teardown NO signal announces: a streamed-out scatter chunk, a
		# harvested prop, or `rebuild_for_seed()` driven straight from a console verb rather than
		# through `run_restarted`. Strictly cheaper than the sort `_assign_slots()` already pays.
		_prune_dead_sites()
		# On the tick and NOT on the generation boundary, unlike the site prune, because a Mesh
		# cannot be asked the question a Node can. `remove_child()` is synchronous, so a site's
		# source node reads as out-of-tree the instant the island is torn down; a Mesh is a
		# RefCounted that does not die until the last MeshInstance3D referencing it is actually
		# deleted, and which frame that lands on is an engine detail. Measured rather than assumed:
		# pruning inside `_rediscover_world()` dropped nothing at all, and re-armed one frame later
		# it STILL found both of the ended island's meshes alive (probed: 4 entries, 2 valid, and
		# `sway_asset_count` stuck at 4). Waiting for the next tick needs no such guess.
		_prune_dressed_meshes()
		_assign_slots()
	_animate_lights()


## Walk the whole current scene. Safe to call again; every mesh and site is idempotent.
func refresh_scene() -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	_scene_id = scene.get_instance_id()
	_apply_recursive(scene)
	_assign_slots()


func _reset() -> void:
	if is_instance_valid(_effect_root):
		_effect_root.queue_free()
	_effect_root = null
	_sites.clear()
	_site_sources.clear()
	_pools.clear()
	_dressed_meshes.clear()
	fire_source_count = 0
	emitter_site_count = 0
	foliage_mesh_count = 0
	sway_asset_count = 0
	_scene_id = 0


# ---------------------------------------------------------------------------------------------
# The generation boundary (F-287)
# ---------------------------------------------------------------------------------------------

## A new run re-derives the island in place. AUTHORITY: none, and this subscription does not change
## that — `run_restarted` reaches every peer (the host emits it, a client re-derives it from the
## WorldDeltaLog seed record), and every peer independently re-reads its own scene. Nothing here is
## sent, requested or trusted across the wire.
##
## Deferred rather than immediate, and correct in either subscription order. Autoloads subscribe
## from `_ready()`, so this file's handler runs BEFORE `ProceduralWorld`'s and the old island is
## still standing when the signal lands — pruning synchronously here would find every source node
## alive and drop nothing. By the time a deferred call runs, `rebuild_for_seed()` has finished
## (it is synchronous inside the emit) and the ended island's nodes have been `remove_child`-ed,
## which is what `_prune_dead_sites()` reads. If some future ordering put this handler last, the
## deferred call is still after the rebuild, so it stays correct rather than merely lucky.
func _on_run_restarted() -> void:
	call_deferred("_rediscover_world")


## Prune, then re-walk. Both halves are needed and neither is enough alone: the prune retires the
## ended island's sites (nothing else would, since the current scene id is unchanged by design), and
## the re-walk registers the new island's immediately instead of waiting on `node_added`'s own
## deferred pass — which for the nodes added before this call is already queued behind it, and would
## otherwise leave a frame of the new world lit by the old world's fires.
func _rediscover_world() -> void:
	_prune_dead_sites()
	refresh_scene()


## Drop every site whose source node is gone, and recount from what is left.
##
## "Gone" is `not is_instance_valid() or not is_inside_tree()`, and the second half is the one that
## does the work here: `ProceduralWorld._teardown_derived()` calls `remove_child()` — synchronous —
## and only then `queue_free()`, which does not run until the end of the frame. A validity-only test
## would call every node of the ended island alive and prune nothing at exactly the moment this
## exists for. It is also the right test for a scatter chunk streaming out, which frees its holder
## the same way (`world/gen/resource_scatter_field.gd:_teardown_chunk`); those come back as NEW
## nodes with no `VFX_META`, so re-entry is `node_added`'s ordinary path and needs nothing here.
##
## An emitter class that loses ALL of its sites keeps its (now empty) key on purpose: `_assign_slots`
## iterates `_sites`, and an emitter missing from it is one whose pooled effect nodes are never
## reached and so stay switched on, burning at coordinates the ended island had. Empty array in,
## `live` of 0 out, every slot hidden.
func _prune_dead_sites() -> void:
	if _sites.is_empty():
		return
	var live_sites: int = 0
	var live_fires: int = 0
	var dropped: int = 0
	for emitter: AssetVfx.Emitter in _sites:
		var sites: Array = _sites[emitter] as Array
		var sources: PackedInt64Array = _site_sources.get(emitter, PackedInt64Array())
		var kept: Array = []
		var kept_sources: PackedInt64Array = PackedInt64Array()
		for index: int in sites.size():
			# A site with no recorded source cannot be proven dead, so it is kept — losing a real
			# emitter is worse than holding a ghost, and the two writers are in step by
			# construction anyway.
			if index < sources.size() and not _source_alive(sources[index]):
				dropped += 1
				continue
			kept.append(sites[index])
			if index < sources.size():
				kept_sources.append(sources[index])
		_sites[emitter] = kept
		_site_sources[emitter] = kept_sources
		live_sites += kept.size()
		if _is_fire(emitter):
			live_fires += kept.size()
	if dropped == 0:
		return
	# Recounted rather than decremented: these are published counters (`tools/
	# environment_vfx_check.gd` and the Hollowmere check both read them), and a census that can
	# only ever be re-derived from the arrays should be, not tracked by arithmetic on both sides.
	emitter_site_count = live_sites
	fire_source_count = live_fires


## Forget dressed meshes that no longer exist.
##
## NOT a correctness fix, and the difference is worth stating because the obvious reading of it is
## wrong: `_dressed_meshes` is keyed by `Mesh.get_instance_id()`, and a freed mesh's id handed to a
## new mesh would silently mark the new one "already dressed" and ship a patch of foliage with no
## wind in it. Godot does not do that — an `ObjectID` packs a validator that changes when the slot
## is reused. Measured before relying on it: 500 freed meshes against 5,000 fresh allocations, zero
## id collisions.
##
## What it is instead is the same census argument as `_prune_dead_sites`, applied to the other
## scene-derived cache in this file. A rebuild frees a whole island's chunk and batch meshes, and
## every one of their entries stays in this dictionary for the life of the process, unread, with
## `sway_asset_count` counting them — so the published number climbs by an island on every restart
## and describes a world that no longer exists. Surviving entries are untouched, so nothing already
## dressed is redressed and no shared mesh resource is walked twice, and the `false` values are the
## entries that never counted toward `sway_asset_count` in the first place (already wind-dressed
## when found, or a degenerate AABB) — decrementing by what was actually counted rather than by
## how many keys went away is what keeps the number exact instead of merely smaller.
func _prune_dressed_meshes() -> void:
	var live: Dictionary = {}
	var counted_dropped: int = 0
	for mesh_key: int in _dressed_meshes:
		if is_instance_id_valid(mesh_key):
			live[mesh_key] = _dressed_meshes[mesh_key]
		elif bool(_dressed_meshes[mesh_key]):
			counted_dropped += 1
	if live.size() == _dressed_meshes.size():
		return
	sway_asset_count = maxi(0, sway_asset_count - counted_dropped)
	_dressed_meshes = live


func _source_alive(instance_id: int) -> bool:
	if not is_instance_id_valid(instance_id):
		return false
	var node := instance_from_id(instance_id) as Node
	return node != null and node.is_inside_tree()


## The classes that burn — a flickering light and a fire-source count, as opposed to the ambient
## ones. Spelled once because three separate copies of the same three-way `or` is three chances for
## a fourth fire class to be added to two of them.
func _is_fire(emitter: AssetVfx.Emitter) -> bool:
	return emitter == AssetVfx.Emitter.CAMPFIRE \
		or emitter == AssetVfx.Emitter.FORGE \
		or emitter == AssetVfx.Emitter.EMBER


func _on_node_added(node: Node) -> void:
	if node is GeometryInstance3D:
		# Through the untyped shim, not `_apply_node` itself (F-194): a node freed between this
		# signal and the deferred call arrives as a freed Object, and a `GeometryInstance3D`-typed
		# parameter rejects it AT MARSHALLING — one engine error per freed node, 136 in a single
		# netted check run — before `_apply_node`'s own is_instance_valid guard can ever run.
		call_deferred("_apply_node_deferred", node)


## Deferred landing pad. The parameter is a bare Variant on purpose, and it cannot be tightened:
## deferred marshalling rejects a freed instance against ANY object-typed parameter — including
## plain `Object`, measured directly (the first version of this fix used `Object` and produced the
## same 136 errors as the bug). Only an untyped parameter lets the freed value arrive, which is what
## makes the validity check below reachable at last.
func _apply_node_deferred(node: Variant) -> void:
	if not is_instance_valid(node):
		return
	var geometry := node as GeometryInstance3D
	if geometry != null:
		_apply_node(geometry)


func _apply_recursive(node: Node) -> void:
	if node is GeometryInstance3D:
		_apply_node(node as GeometryInstance3D)
	for child: Node in node.get_children():
		_apply_recursive(child)


func _apply_node(node: GeometryInstance3D) -> void:
	if not is_instance_valid(node) or node.has_meta(VFX_META):
		return
	if node is GPUParticles3D:
		return

	# F-203: a merged multi-asset holder declares its class directly (EMITTER_META) because no
	# single asset id survives the bake to look one up from. Checked before the asset-id walk so
	# a merged node never falls through to it and resolves nothing. Sway never applies to one of
	# these — the generator's merge-eligibility rule keeps a sway-and-emitter asset (mire_tendril)
	# out of every merge bucket entirely (F-208), so an EMITTER_META holder is never also a
	# SWAY_META one.
	var merged_emitter := _merged_emitter_for(node)
	if merged_emitter != AssetVfx.Emitter.NONE:
		node.set_meta(VFX_META, true)
		_register_emitter(node, merged_emitter, "")
		return

	# F-208: same shape as the emitter case above — a merged multi-asset holder declares its sway
	# profile directly (SWAY_META) because no single asset id survives the bake to look one up
	# from, and its mesh already carries the per-vertex baked height mask `_apply_baked_sway`
	# needs instead of a per-mesh AABB.
	var merged_sway := _merged_sway_for(node)
	if merged_sway != AssetVfx.Sway.NONE:
		node.set_meta(VFX_META, true)
		_apply_baked_sway(node, merged_sway)
		return

	var asset_id := _asset_id_for(node)
	if asset_id.is_empty():
		return
	node.set_meta(VFX_META, true)

	var sway := AssetVfx.sway_for(asset_id)
	if sway != AssetVfx.Sway.NONE:
		_apply_sway(node, sway)

	var emitter := AssetVfx.emitter_for(asset_id)
	if emitter != AssetVfx.Emitter.NONE:
		_register_emitter(node, emitter, asset_id)


## Meta first — that is the generator contract. Node names are the fallback that keeps
## hand-authored scenes alive; the search walks a few ancestors because a GLB's mesh nodes are
## usually named for their material while the holder above them carries the asset name.
func _asset_id_for(node: Node) -> String:
	var cursor: Node = node
	for _depth: int in 4:
		if cursor == null:
			break
		if cursor.has_meta(ASSET_META):
			return String(cursor.get_meta(ASSET_META))
		cursor = cursor.get_parent()
	cursor = node
	for _depth: int in 4:
		if cursor == null:
			break
		var name := String(cursor.name).to_lower()
		if AssetVfx.is_animated(name):
			return name
		cursor = cursor.get_parent()
	return ""


## F-203: same ancestor walk as `_asset_id_for`, for a holder that declares `EMITTER_META`
## instead of `ASSET_META` — the merged-mesh case where no single asset id applies.
func _merged_emitter_for(node: Node) -> AssetVfx.Emitter:
	var cursor: Node = node
	for _depth: int in 4:
		if cursor == null:
			break
		if cursor.has_meta(EMITTER_META):
			return int(cursor.get_meta(EMITTER_META)) as AssetVfx.Emitter
		cursor = cursor.get_parent()
	return AssetVfx.Emitter.NONE


## F-208: same ancestor walk again, for a holder that declares `SWAY_META` instead of
## `ASSET_META` — the merged-mesh case for sway-bearing props.
func _merged_sway_for(node: Node) -> AssetVfx.Sway:
	var cursor: Node = node
	for _depth: int in 4:
		if cursor == null:
			break
		if cursor.has_meta(SWAY_META):
			return int(cursor.get_meta(SWAY_META)) as AssetVfx.Sway
		cursor = cursor.get_parent()
	return AssetVfx.Sway.NONE


# ---------------------------------------------------------------------------------------------
# Sway
# ---------------------------------------------------------------------------------------------

## The mesh, not the node, is what gets dressed. Every copy of an asset shares one mesh resource,
## so one pass here reaches every instance of that asset in the world at once — which is the whole
## reason this is affordable on a map holding 13,026 instanced plants.
func _apply_sway(node: GeometryInstance3D, sway: AssetVfx.Sway) -> void:
	var mesh: Mesh = null
	if node is MultiMeshInstance3D:
		var multimesh := (node as MultiMeshInstance3D).multimesh
		if multimesh != null:
			mesh = multimesh.mesh
	elif node is MeshInstance3D:
		mesh = (node as MeshInstance3D).mesh
	if mesh == null or mesh.get_surface_count() == 0:
		return

	var mesh_key := mesh.get_instance_id()
	if _dressed_meshes.has(mesh_key):
		foliage_mesh_count += 1
		return
	# Mesh resources outlive the level that used them — ResourceLoader hands the same ArrayMesh
	# back after a scene reload, and the authored-prop mesh cache is shared across chunks. Dressing
	# one twice would read the wind material as if it were the asset's original and collapse the
	# asset to the default green, so the shader itself is the durable "already done" mark.
	var existing := mesh.surface_get_material(0)
	if existing is ShaderMaterial and (existing as ShaderMaterial).shader == FOLIAGE_SHADER:
		_dressed_meshes[mesh_key] = false
		foliage_mesh_count += 1
		return
	# `false` = "in the cache, but not counted toward `sway_asset_count`". Flipped to `true` below
	# only on the path that actually increments it, so `_prune_dressed_meshes()` can decrement by
	# exactly what it drops instead of approximating (this path can still return early on a
	# degenerate AABB, and the branch above never counted at all).
	_dressed_meshes[mesh_key] = false

	var bounds := mesh.get_aabb()
	if bounds.size.y <= 0.001:
		return
	var profile := AssetVfx.sway_profile(sway)
	for surface_index: int in mesh.get_surface_count():
		var original := mesh.surface_get_material(surface_index)
		mesh.surface_set_material(
			surface_index, _sway_material(original, profile, bounds))
	foliage_mesh_count += 1
	sway_asset_count += 1
	_dressed_meshes[mesh_key] = true


## Materials are cached across assets that agree on colour, roughness and sway numbers, so the
## eighty-odd flora assets collapse to a handful of shaders rather than one each.
func _sway_material(original: Material, profile: Dictionary, bounds: AABB) -> ShaderMaterial:
	var color := Color(0.24, 0.42, 0.16)
	var material_roughness: float = 0.9
	var vertex_color: bool = false
	if original is StandardMaterial3D:
		var standard := original as StandardMaterial3D
		color = standard.albedo_color
		material_roughness = standard.roughness
		vertex_color = standard.vertex_color_use_as_albedo

	# F-341: the key carries BOTH ends of the bounds, not just the height. The material bakes
	# `bounds.position.y` into `wind_root_y` and `1.0 / bounds.size.y` into `wind_inv_height`, so two
	# meshes that agree on appearance and height but sit at different vertical origins — a plant
	# modelled with its base at y=0 and one modelled centred, say — used to share the first one's
	# root and bend around a pivot somewhere off its own geometry.
	#
	# Keyed at the same 1 mm precision as the height, and it cannot fragment the cache per instance:
	# `bounds` comes from `mesh.get_aabb()`, which is mesh-LOCAL, so this is a per-asset constant.
	# The worst case is one material per distinct asset origin, which is what the cache existed to
	# improve on and still does.
	var key := "%s:%.2f:%d:%.3f:%.3f:%.3f:%.2f:%.2f:%.3f:%.3f" % [
		color.to_html(), material_roughness, int(vertex_color),
		float(profile.get("strength", 0.1)), float(profile.get("speed", 1.3)),
		float(profile.get("bob", 0.0)), float(profile.get("mask_power", 1.0)),
		float(profile.get("vertex_phase", 1.0)), bounds.size.y, bounds.position.y]
	if _sway_materials.has(key):
		return _sway_materials[key] as ShaderMaterial

	var material := ShaderMaterial.new()
	material.shader = FOLIAGE_SHADER
	material.set_shader_parameter(&"albedo_color", color)
	material.set_shader_parameter(&"roughness", material_roughness)
	material.set_shader_parameter(&"use_vertex_color", vertex_color)
	material.set_shader_parameter(&"sway_strength", float(profile.get("strength", 0.1)))
	material.set_shader_parameter(&"sway_speed", float(profile.get("speed", 1.3)))
	material.set_shader_parameter(&"bob_strength", float(profile.get("bob", 0.0)))
	material.set_shader_parameter(&"mask_power", float(profile.get("mask_power", 1.0)))
	material.set_shader_parameter(&"vertex_phase", float(profile.get("vertex_phase", 1.0)))
	material.set_shader_parameter(&"wind_root_y", bounds.position.y)
	material.set_shader_parameter(&"wind_inv_height", 1.0 / bounds.size.y)
	_sway_materials[key] = material
	return material


## F-208: the SWAY_META counterpart to `_apply_sway`, for a merged multi-asset chunk holder whose
## mesh's own AABB spans the whole merge (terrain relief plus every source asset's height) rather
## than one plant's local frame — `wind_root_y`/`wind_inv_height` computed from it would be
## meaningless. `core/render/mesh_merge.gd`'s `merge_instances(..., bake_height_mask=true)` already
## baked the correct per-vertex mask into UV2.x from each source asset's OWN local AABB before the
## merge, so this only needs the sway PROFILE (strength/speed/bob/mask_power/vertex_phase) —
## dressing itself just points the material at the baked channel instead of the two AABB uniforms.
func _apply_baked_sway(node: GeometryInstance3D, sway: AssetVfx.Sway) -> void:
	var mesh: Mesh = null
	if node is MeshInstance3D:
		mesh = (node as MeshInstance3D).mesh
	elif node is MultiMeshInstance3D:
		var multimesh := (node as MultiMeshInstance3D).multimesh
		if multimesh != null:
			mesh = multimesh.mesh
	if mesh == null or mesh.get_surface_count() == 0:
		return

	var mesh_key := mesh.get_instance_id()
	if _dressed_meshes.has(mesh_key):
		foliage_mesh_count += 1
		return
	var existing := mesh.surface_get_material(0)
	if existing is ShaderMaterial and (existing as ShaderMaterial).shader == FOLIAGE_SHADER:
		_dressed_meshes[mesh_key] = false
		foliage_mesh_count += 1
		return
	# `false` = "in the cache, but not counted toward `sway_asset_count`". Flipped to `true` below
	# only on the path that actually increments it, so `_prune_dressed_meshes()` can decrement by
	# exactly what it drops instead of approximating (this path can still return early on a
	# degenerate AABB, and the branch above never counted at all).
	_dressed_meshes[mesh_key] = false

	var profile := AssetVfx.sway_profile(sway)
	for surface_index: int in mesh.get_surface_count():
		var original := mesh.surface_get_material(surface_index)
		mesh.surface_set_material(surface_index, _baked_sway_material(original, profile))
	foliage_mesh_count += 1
	sway_asset_count += 1
	_dressed_meshes[mesh_key] = true


## Same appearance-collapsing cache `_sway_material` keeps, kept separate from it: a baked-mask
## material carries no `wind_root_y`/`wind_inv_height` (meaningless once several placements share
## one mesh), so its cache key has no `bounds` term and must not collide with a per-asset one
## sharing the same colour/profile numbers — two materials that read UV2 differently can never be
## the same ShaderMaterial instance.
func _baked_sway_material(original: Material, profile: Dictionary) -> ShaderMaterial:
	var color := Color(0.24, 0.42, 0.16)
	var material_roughness: float = 0.9
	var vertex_color: bool = false
	if original is StandardMaterial3D:
		var standard := original as StandardMaterial3D
		color = standard.albedo_color
		material_roughness = standard.roughness
		vertex_color = standard.vertex_color_use_as_albedo

	var key := "baked:%s:%.2f:%d:%.3f:%.3f:%.3f:%.2f:%.2f" % [
		color.to_html(), material_roughness, int(vertex_color),
		float(profile.get("strength", 0.1)), float(profile.get("speed", 1.3)),
		float(profile.get("bob", 0.0)), float(profile.get("mask_power", 1.0)),
		float(profile.get("vertex_phase", 1.0))]
	if _sway_materials.has(key):
		return _sway_materials[key] as ShaderMaterial

	var material := ShaderMaterial.new()
	material.shader = FOLIAGE_SHADER
	material.set_shader_parameter(&"albedo_color", color)
	material.set_shader_parameter(&"roughness", material_roughness)
	material.set_shader_parameter(&"use_vertex_color", vertex_color)
	material.set_shader_parameter(&"sway_strength", float(profile.get("strength", 0.1)))
	material.set_shader_parameter(&"sway_speed", float(profile.get("speed", 1.3)))
	material.set_shader_parameter(&"bob_strength", float(profile.get("bob", 0.0)))
	material.set_shader_parameter(&"mask_power", float(profile.get("mask_power", 1.0)))
	material.set_shader_parameter(&"vertex_phase", float(profile.get("vertex_phase", 1.0)))
	material.set_shader_parameter(&"use_baked_mask", true)
	_sway_materials[key] = material
	return material


# ---------------------------------------------------------------------------------------------
# Emitters
# ---------------------------------------------------------------------------------------------

## Record where an asset's emitters stand. Transforms only — no nodes are built here, because a
## generated world may hold any number of these and the pool below is what bounds the cost.
func _register_emitter(
	node: GeometryInstance3D, emitter: AssetVfx.Emitter, asset_id: String
) -> void:
	var placements: Array[Vector3] = []
	var published := _published_placements(node)
	if not published.is_empty():
		var base := node.global_transform
		for origin: Vector3 in published:
			placements.append(base * origin)
	elif node is MultiMeshInstance3D:
		# A batch with no published placements is a generator that has not honoured the contract.
		# Reading the transforms back out of the MultiMesh is NOT an option: instance transforms
		# live in the RenderingServer, and under `--headless` — which is every way an agent can
		# verify anything (F-077) — the buffer is empty and every read returns identity. Silently
		# collapsing a hundred crystals onto the world origin is exactly what that looked like.
		push_warning("EnvironmentVfx: %s has an emitter but no `placements` meta; skipping"
			% node.name)
		return
	else:
		# ONE site per prop, not one per mesh part. A GLB tree arrives as around forty separate
		# MeshInstance3D nodes, each of which resolves the same asset id from the holder above it
		# and each of which sits far enough from its siblings to survive the merge test below — so
		# 44 harvestable trees registered 1,925 leaf sites, and the O(n²) merge loop then compared
		# 1.8 million pairs at load. The prop is whichever ancestor carries the asset id.
		var host := _emitter_host(node)
		if host.has_meta(EMITTER_HOST_META):
			return
		host.set_meta(EMITTER_HOST_META, true)
		var host_3d := host as Node3D
		placements.append(host_3d.global_position if host_3d != null else node.global_position)
		# A named placeholder flame in a hand-authored scene is replaced, not decorated — but that
		# is true of exactly two assets, and asking the library rather than assuming is what stops
		# this from hiding real geometry. F-118 gave canopies an emitter, and every tree that is a
		# node of its own rather than a MultiMesh slot — which, since F-114, is every harvestable
		# tree on the map — vanished the moment it was registered.
		if AssetVfx.replaces_host_mesh(asset_id):
			node.visible = false

	if emitter == AssetVfx.Emitter.GLOW:
		return

	# The node the sites BELONG to, which is not always the node that resolved them (F-287). For a
	# published-placements batch or a MultiMesh it is this node; for a loose prop it is the host
	# ancestor `_emitter_host()` picked and stamped, because that is the node whose lifetime the
	# prop's existence actually tracks — a GLB's forty mesh parts can come and go under a holder
	# that stays put.
	var source: Node = _emitter_host(node)
	var sites: Array = _sites.get_or_add(emitter, [] as Array) as Array
	var sources: PackedInt64Array = _site_sources.get_or_add(emitter, PackedInt64Array())
	for position: Vector3 in placements:
		var duplicate: bool = false
		for existing: Vector3 in sites:
			if existing.distance_squared_to(position) < SITE_MERGE_DISTANCE * SITE_MERGE_DISTANCE:
				duplicate = true
				break
		if duplicate:
			continue
		sites.append(position)
		sources.append(source.get_instance_id())
		emitter_site_count += 1
		if _is_fire(emitter):
			fire_source_count += 1
	_sites[emitter] = sites
	# Written back because a PackedInt64Array is a value type — what `get_or_add` handed back is a
	# copy, and appending to it stores nothing (the same trap `_check_placement_space` documents in
	# `tools/environment_vfx_hollowmere_check.gd`).
	_site_sources[emitter] = sources


## The node that IS this prop: the nearest ancestor carrying the asset id, or the node itself when
## nothing above it does — which is the hand-authored case, where a placeholder mesh is its own prop.
func _emitter_host(node: Node) -> Node:
	var cursor: Node = node
	for _depth: int in 4:
		if cursor == null:
			break
		if cursor.has_meta(ASSET_META):
			return cursor
		cursor = cursor.get_parent()
	return node


## Where each copy of this asset stands, as published by the generator. World generation owns
## these positions; the renderer is not a place to read them back from.
func _published_placements(node: Node) -> PackedVector3Array:
	var cursor: Node = node
	for _depth: int in 4:
		if cursor == null:
			break
		if cursor.has_meta(PLACEMENTS_META):
			return cursor.get_meta(PLACEMENTS_META) as PackedVector3Array
		cursor = cursor.get_parent()
	return PackedVector3Array()


func _budget_scale() -> float:
	var quality: Node = get_node_or_null(^"/root/GraphicsQuality")
	if quality == null:
		return 1.0
	var preset: int = int(quality.get("preset"))
	if preset < 0 or preset >= BUDGET_BY_PRESET.size():
		return 1.0
	return BUDGET_BY_PRESET[preset]


## Point the fixed pool at the nearest sites. This is the whole scalability story: the pool is
## sized from the budget, never from the world, so a hundred mire crystals cost what eight do.
func _assign_slots() -> void:
	if _sites.is_empty():
		return
	var scene: Node = get_tree().current_scene
	if scene == null:
		return
	if not is_instance_valid(_effect_root):
		_effect_root = Node3D.new()
		_effect_root.name = "EnvironmentVfxEffects"
		scene.add_child(_effect_root)

	var scale := _budget_scale()
	var viewpoint := _viewpoint()
	for emitter: AssetVfx.Emitter in _sites:
		var sites: Array = _sites[emitter] as Array
		var profile := AssetVfx.emitter_profile(emitter)
		var live: int = mini(
			maxi(1, int(round(float(profile.get("max_live", 4)) * scale))), sites.size())
		var shadows: int = int(round(float(profile.get("shadow_live", 0)) * scale))

		var ranked := sites.duplicate() as Array
		ranked.sort_custom(func(a: Vector3, b: Vector3) -> bool:
			return a.distance_squared_to(viewpoint) < b.distance_squared_to(viewpoint))

		var pool: Array = _pools.get_or_add(emitter, [] as Array) as Array
		while pool.size() < live:
			pool.append(_make_effect(emitter))
		for index: int in pool.size():
			var slot: Dictionary = pool[index]
			var node := slot["node"] as Node3D
			if not is_instance_valid(node):
				continue
			if index >= live:
				node.visible = false
				continue
			var target: Vector3 = ranked[index]
			node.visible = true
			if node.global_position.distance_squared_to(target) > 0.01:
				node.global_position = target
				_restart(node)
			var light := slot["light"] as OmniLight3D
			if light != null and is_instance_valid(light):
				light.shadow_enabled = index < shadows
		_pools[emitter] = pool


## Where "nearest" is measured from. The camera in a running game; the origin when there is no
## camera at all, which is every headless check — so the check still exercises a deterministic
## set of live emitters rather than none.
func _viewpoint() -> Vector3:
	var viewport := get_viewport()
	if viewport != null:
		var camera := viewport.get_camera_3d()
		if camera != null:
			return camera.global_position
	return Vector3.ZERO


func _restart(node: Node3D) -> void:
	for child: Node in node.get_children():
		if child is GPUParticles3D:
			(child as GPUParticles3D).restart()


func _animate_lights() -> void:
	for emitter: AssetVfx.Emitter in _pools:
		var flickers: bool = _is_fire(emitter)
		var pool: Array = _pools[emitter] as Array
		for index: int in pool.size():
			var slot: Dictionary = pool[index]
			var light := slot["light"] as OmniLight3D
			if light == null or not is_instance_valid(light) or not light.visible:
				continue
			var base := float(slot["energy"])
			if flickers:
				# Two detuned sines: a fast flutter for the flame and a slow pulse for the bed of
				# coals under it. Detuned per slot so neighbouring fires never beat in unison.
				var flutter := sin(_time * 10.7 + float(index) * 1.91) * 0.13
				var pulse := sin(_time * 4.1 + float(index) * 0.73) * 0.1
				light.light_energy = base + flutter + pulse
			else:
				light.light_energy = base + sin(_time * 1.3 + float(index) * 2.2) * 0.18


# ---------------------------------------------------------------------------------------------
# Effect construction
# ---------------------------------------------------------------------------------------------

## Build one pooled effect for an emitter class. Called at most `max_live` times per class for the
## whole run, however large the world is — the pool is reassigned to new sites as the player moves
## rather than grown.
func _make_effect(emitter: AssetVfx.Emitter) -> Dictionary:
	var profile := AssetVfx.emitter_profile(emitter)
	var node := Node3D.new()
	node.name = "Vfx%d" % int(emitter)
	node.set_meta(VFX_META, true)
	_effect_root.add_child(node)

	var light: OmniLight3D = null
	var energy: float = 0.0
	match emitter:
		AssetVfx.Emitter.CAMPFIRE:
			node.add_child(_flame(30, 0.72, Vector2(0.18, 0.38), 0.55, 1.15, 1.15))
			node.add_child(_sparks(13, 1.15, 0.16))
			node.add_child(_smoke(9, 2.4, Vector2(0.26, 0.26), 0.28))
			energy = 2.25
			light = _light(Color(1.0, 0.42, 0.12), energy, float(profile.get("radius", 5.5)), 0.42)
		AssetVfx.Emitter.FORGE:
			# Contained in stone: a shorter, tighter flame and a heavier smoke column.
			node.add_child(_flame(18, 0.6, Vector2(0.15, 0.3), 0.35, 0.75, 0.85))
			node.add_child(_smoke(12, 2.8, Vector2(0.3, 0.3), 0.55))
			energy = 1.9
			light = _light(Color(1.0, 0.48, 0.16), energy, float(profile.get("radius", 4.5)), 0.5)
		AssetVfx.Emitter.EMBER:
			node.add_child(_flame(12, 0.55, Vector2(0.13, 0.24), 0.3, 0.6, 0.7))
			node.add_child(_sparks(6, 0.9, 0.1))
			energy = 1.4
			light = _light(Color(1.0, 0.52, 0.2), energy, float(profile.get("radius", 3.4)), 0.3)
		AssetVfx.Emitter.CRYSTAL:
			node.add_child(_motes(10, 3.0, Color(0.55, 0.85, 1.0, 0.75), 0.34, 0.16))
			energy = 1.2
			light = _light(Color(0.42, 0.72, 1.0), energy, float(profile.get("radius", 4.0)), 0.6)
		AssetVfx.Emitter.SPORE:
			# Mire growth: no light at all, just something adrift that should not be there.
			node.add_child(_motes(8, 4.0, Color(0.62, 0.78, 0.45, 0.5), 0.16, 0.5))
		AssetVfx.Emitter.LEAF_FALL:
			# The one effect whose job is to be barely noticed: a handful of leaves letting go of a
			# crown and taking six seconds to reach the ground. No light, no shadow, no smoke.
			node.add_child(_leaf_fall(12, 7.0, 4.8))
	if light != null:
		node.add_child(light)
	return {"node": node, "light": light, "energy": energy}


func _flame(amount: int, lifetime: float, size: Vector2, speed_min: float, speed_max: float,
		scale_max: float) -> GPUParticles3D:
	var particles := _make_particles(amount, lifetime, size,
		Color(1.0, 0.72, 0.08, 0.88), Color(1.0, 0.08, 0.01, 0.0), 0)
	var process := particles.process_material as ParticleProcessMaterial
	process.direction = Vector3.UP
	process.spread = 18.0
	process.initial_velocity_min = speed_min
	process.initial_velocity_max = speed_max
	process.gravity = Vector3(0.0, 0.45, 0.0)
	process.scale_min = 0.45
	process.scale_max = scale_max
	return particles


func _sparks(amount: int, lifetime: float, radius: float) -> GPUParticles3D:
	var particles := _make_particles(amount, lifetime, Vector2(0.025, 0.025),
		Color(1.0, 0.78, 0.16, 1.0), Color(1.0, 0.12, 0.01, 0.0), 1)
	var process := particles.process_material as ParticleProcessMaterial
	process.direction = Vector3.UP
	process.spread = 28.0
	process.initial_velocity_min = 0.85
	process.initial_velocity_max = 1.8
	# Negative gravity is what makes a spark arc over and die rather than rise forever.
	process.gravity = Vector3(0.0, -0.35, 0.0)
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = radius
	return particles


func _smoke(amount: int, lifetime: float, size: Vector2, height: float) -> GPUParticles3D:
	var particles := _make_particles(amount, lifetime, size,
		Color(0.19, 0.17, 0.2, 0.2), Color(0.08, 0.07, 0.1, 0.0), 2)
	var process := particles.process_material as ParticleProcessMaterial
	process.direction = Vector3.UP
	process.spread = 14.0
	process.initial_velocity_min = 0.35
	process.initial_velocity_max = 0.62
	# A slight lateral drift so the column leans instead of standing like a pillar.
	process.gravity = Vector3(0.08, 0.04, 0.03)
	process.scale_min = 0.55
	process.scale_max = 1.4
	particles.position.y = height
	return particles


func _motes(amount: int, lifetime: float, tint: Color, rise: float, radius: float) -> GPUParticles3D:
	var faded := Color(tint.r, tint.g, tint.b, 0.0)
	var particles := _make_particles(amount, lifetime, Vector2(0.045, 0.045), tint, faded, 1)
	var process := particles.process_material as ParticleProcessMaterial
	process.direction = Vector3.UP
	process.spread = 42.0
	process.initial_velocity_min = rise * 0.5
	process.initial_velocity_max = rise
	process.gravity = Vector3(0.02, rise * 0.2, 0.01)
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = maxf(radius, 0.05)
	return particles


## Leaves letting go of a canopy (F-118). Emitted from a slab the width of a crown and dropped
## slowly, with sideways gravity so they slip rather than plummet — a leaf that falls straight down
## reads as a rock. `height` is where the crown starts; one number for every species is a
## compromise, and a forgiving one, because a leaf that starts a metre inside the foliage simply
## appears from behind it.
##
## The visibility AABB is set explicitly and generously: the default in `_make_particles` is 5 m
## tall, and particles that travel outside their own AABB are culled as a group the moment the
## emitter's box leaves the frustum — which for something falling 6 m and drifting 4 m sideways
## means leaves winking out while you are looking straight at them.
func _leaf_fall(amount: int, lifetime: float, height: float) -> GPUParticles3D:
	var particles := _make_particles(amount, lifetime, Vector2(0.15, 0.21),
		Color(0.78, 0.63, 0.22, 0.95), Color(0.45, 0.37, 0.15, 0.0), 3)
	var process := particles.process_material as ParticleProcessMaterial
	process.direction = Vector3.DOWN
	process.spread = 30.0
	process.initial_velocity_min = 0.08
	process.initial_velocity_max = 0.3
	# Barely more than a tenth of real gravity, plus a lateral component: this is the difference
	# between drifting and dropping.
	process.gravity = Vector3(0.22, -0.85, 0.13)
	# A slow tumble. Leaves are the only thing here that reads wrong without one.
	process.angular_velocity_min = -55.0
	process.angular_velocity_max = 55.0
	process.angle_min = -180.0
	process.angle_max = 180.0
	process.scale_min = 0.7
	process.scale_max = 1.25
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	process.emission_box_extents = Vector3(2.6, 0.7, 2.6)
	particles.position.y = height
	particles.visibility_aabb = AABB(
		Vector3(-5.0, -height - 2.0, -5.0), Vector3(10.0, height + 4.0, 10.0)
	)
	return particles


func _light(tint: Color, energy: float, radius: float, height: float) -> OmniLight3D:
	var light := OmniLight3D.new()
	light.name = "VfxLight"
	light.light_color = tint
	light.light_energy = energy
	light.omni_range = radius
	# Shadows are switched on per slot by _assign_slots, for the nearest few only.
	light.shadow_enabled = false
	light.position.y = height
	return light


func _make_particles(amount: int, lifetime: float, size: Vector2, start_color: Color,
		end_color: Color, particle_shape: int) -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.amount = amount
	particles.lifetime = lifetime
	particles.randomness = 0.42
	particles.visibility_aabb = AABB(Vector3(-2.0, -0.5, -2.0), Vector3(4.0, 5.0, 4.0))
	var process := ParticleProcessMaterial.new()
	var gradient := Gradient.new()
	gradient.colors = PackedColorArray([start_color, end_color])
	var ramp := GradientTexture1D.new()
	ramp.gradient = gradient
	process.color_ramp = ramp
	particles.process_material = process

	var quad := QuadMesh.new()
	quad.size = size
	quad.orientation = PlaneMesh.FACE_Z
	var draw_material := ShaderMaterial.new()
	draw_material.shader = PARTICLE_SHADER
	draw_material.set_shader_parameter(&"particle_shape", particle_shape)
	quad.material = draw_material
	particles.draw_pass_1 = quad
	return particles


# ---------------------------------------------------------------------------------------------
# Introspection
# ---------------------------------------------------------------------------------------------

## How many emitter sites the world holds, per class. This is a property of the world.
func site_counts() -> Dictionary:
	var counts: Dictionary = {}
	for emitter: AssetVfx.Emitter in _sites:
		counts[emitter] = (_sites[emitter] as Array).size()
	return counts


## WHERE the emitter sites are, per class — the positions behind `site_counts()`.
##
## Exists for `tools/environment_vfx_reseed_check.gd` (F-287): a count cannot tell a replaced site
## set from an appended one, which is the entire failure this system had. Returns copies, so a
## caller cannot edit the live arrays out from under `_assign_slots`.
func site_positions() -> Dictionary:
	var out: Dictionary = {}
	for emitter: AssetVfx.Emitter in _sites:
		var positions: PackedVector3Array = PackedVector3Array()
		for site: Vector3 in _sites[emitter] as Array:
			positions.append(site)
		out[emitter] = positions
	return out


## How many effect nodes actually exist, per class. This is a property of the BUDGET, and the two
## numbers diverging is the whole point — 99 crystal sites must not mean 99 crystal effects.
func pool_counts() -> Dictionary:
	var counts: Dictionary = {}
	for emitter: AssetVfx.Emitter in _pools:
		counts[emitter] = (_pools[emitter] as Array).size()
	return counts


## How many effect nodes are switched on right now.
func live_count() -> int:
	var live: int = 0
	for emitter: AssetVfx.Emitter in _pools:
		for slot: Dictionary in _pools[emitter] as Array:
			var node := slot["node"] as Node3D
			if is_instance_valid(node) and node.visible:
				live += 1
	return live
