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

## F-547: asset ids already reported as publishing no `placements`, so the warning is raised once
## per asset rather than once per batch node. Never read for behaviour — purely to keep a
## per-generator fault from being reported eighteen hundred times in one walk.
var _placements_warned: Dictionary[String, bool] = {}

## How often the nearest-first emitter assignment is recomputed. Sites number in the hundreds and
## the player walks at 4.4 m/s, so four times a second is far below anything visible.
const BUDGET_INTERVAL: float = 0.25
## Sites closer together than this are treated as one — a defence against an asset that emits more
## than one MultiMesh part, which would otherwise register the same campfire twice.
const SITE_MERGE_DISTANCE: float = 0.35
## Emitter counts are scaled by the graphics preset. Low-end machines pay for lights first.
const BUDGET_BY_PRESET: PackedFloat32Array = [0.4, 0.7, 1.0]

## F-376: how strongly a slot resists being outranked off the site it already holds. `_assign_slots`
## ranks sites nearest-first; a site a slot is standing on is ranked as if it were 18% closer than it
## really is, so the live set changes only when a new site is meaningfully nearer, not every time two
## roughly equidistant props swap order in the sort.
const SLOT_HOLD_BIAS: float = 0.82

## How many leaves ONE crown has in the air at a time (F-376). Was 12, which times the old budget of
## twelve live crowns put up to 144 leaves around the player and was reported from play as "way too
## many spawn". Five over a seven-second lifetime is a leaf letting go of a given tree about every
## 1.4 seconds — weather rather than confetti.
const LEAF_FALL_AMOUNT: int = 5
## Where a leaf lets go, as a fraction of the host prop's measured height, and how deep that band is.
## A canopy occupies roughly the top third of a tree, so emitting from 0.80 of its height with a
## band of ±0.13 keeps every leaf inside the foliage it is supposed to be falling out of.
const LEAF_FALL_CROWN_HEIGHT: float = 0.80
const LEAF_FALL_CROWN_BAND: float = 0.13
## How much of the crown's measured half-width leaves actually come from. Under 1.0 on purpose: the
## prop's bounds include the widest branch, and a leaf appearing at that exact radius is a leaf
## appearing beside the tree rather than out of it.
const LEAF_FALL_CROWN_INSET: float = 0.72
## Used only when a holder cannot answer for ONE prop's bounds — see `_crown_metrics`. A stated
## fallback, not the fixed 4.8 m F-376 is about: every prop that CAN be measured is measured.
const LEAF_FALL_DEFAULT_CROWN: Vector2 = Vector2(4.2, 2.4)
## Bounds the per-prop mesh walk `_crown_metrics` does once per emitter site. A GLB tree arrives as
## around forty MeshInstance3D nodes; this caps what a malformed holder can cost, it does not
## describe any prop this project ships.
const CROWN_MESH_PART_CAP: int = 64

## How many one-shot impact bursts of ONE material may be in flight at once (F-391). Beyond this the
## oldest is reused, which for a burst that lives under one and a half seconds is inaudible — and it
## is what keeps a six-player crew all swinging at once from allocating without bound.
const IMPACT_POOL_SIZE: int = 6
## Past this the burst is skipped entirely. A burst nobody can see is not worth a restart, and this
## is also the guard that stops a client being told LATE about a prop harvested minutes ago — see
## `play_impact` and `systems/harvesting/harvestable.gd`'s own arm delay.
const IMPACT_MAX_DISTANCE_M: float = 40.0

## Successful per-node sway dressing visits in the current scene, including mesh-cache hits.
## Cumulative by design across an in-place procedural rebuild; reset only when the scene changes.
## This is work performed, not a census — `sway_asset_count` is the live unique-mesh census.
var foliage_dressing_count: int = 0
var fire_source_count: int = 0
## F-391: how many one-shot destruction bursts this process has played, and what the last one was.
## Published for the same reason the emitter censuses are — a one-shot leaves nothing behind to
## inspect a frame later, so a check has no other way to prove it fired.
var impact_burst_count: int = 0
var last_impact: Dictionary = {}
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
## F-376: `AssetVfx.Emitter` -> `PackedVector2Array` of each site's own crown, index for index with
## `_sites[emitter]` and written/pruned by exactly the same two functions that keep `_site_sources`
## in step. `x` is how far above the site the prop tops out, `y` is its horizontal half-width, both
## in world metres. Recorded only for the classes that use it (`_needs_crown`), because a campfire
## emits from a point and does not care how big the stone ring around it is.
var _site_crowns: Dictionary = {}
var _pools: Dictionary = {}
## F-391: `AssetVfx.Impact` -> `Array` of one-shot burst nodes, and where the round-robin is up to in
## each. Separate from `_pools` on purpose: those are ambient sites the budget assigns, these are
## fired by a gameplay event and belong to no site at all.
var _impact_pools: Dictionary = {}
var _impact_cursors: Dictionary = {}
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
	# F-311: unlike run_restarted, this lands after ProceduralWorld has synchronously published the
	# replacement island, including direct rebuild_for_seed() callers. Rediscovery is therefore
	# immediate; the periodic prune remains the invariant for streamed-out and harvested props.
	EVENT_BUS.subscribe_world_rebuilt(_rediscover_world)
	call_deferred("refresh_scene")


func _exit_tree() -> void:
	EVENT_BUS.unsubscribe_run_restarted(_on_run_restarted)
	EVENT_BUS.unsubscribe_world_rebuilt(_rediscover_world)


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
	_site_crowns.clear()
	_pools.clear()
	# The burst nodes were children of the effect root that just went with the old scene.
	_impact_pools.clear()
	_impact_cursors.clear()
	_dressed_meshes.clear()
	fire_source_count = 0
	emitter_site_count = 0
	foliage_dressing_count = 0
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
		var crowns: PackedVector2Array = _site_crowns.get(emitter, PackedVector2Array())
		var kept: Array = []
		var kept_sources: PackedInt64Array = PackedInt64Array()
		var kept_crowns: PackedVector2Array = PackedVector2Array()
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
			# F-376: the crown array is the third parallel array and is rebuilt by the same walk,
			# for the same reason the sources are — a site's index is its only key, and an array
			# that skips a drop the others took would silently hand one tree another's crown.
			if index < crowns.size():
				kept_crowns.append(crowns[index])
		_sites[emitter] = kept
		_site_sources[emitter] = kept_sources
		_site_crowns[emitter] = kept_crowns
		live_sites += kept.size()
		if _is_fire(emitter):
			live_fires += kept.size()
	if dropped == 0:
		return
	# F-376: every surviving site's INDEX just moved, and a pool slot records the index it is bound
	# to rather than the position. Releasing every binding is the honest response — the next
	# `_assign_slots()` re-derives them from the compacted arrays, which costs one budget tick of
	# reassignment on the rare tick that actually dropped a site.
	_unbind_all_slots()
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
	if not (node is GeometryInstance3D):
		return
	# F-547: reject what cannot possibly want dressing BEFORE paying for a deferred call.
	#
	# A 45-second traversal of the shipped world adds 44,049 nodes, and every one of them used to
	# buy a `call_deferred` — on the exact per-chunk path F-454 measures as the source of the
	# hitches (99 nodes added on a hitch frame against 5 on a quiet one). These two tests are
	# synchronous, allocate nothing, and are the same two `_apply_node` opens with, so anything they
	# reject was going to be discarded a frame later anyway. The scatter generators now stamp
	# `VFX_META` on the mesh parts they have already dressed through part 0 (see
	# `world/gen/undergrowth.gd`), which is most of a chunk's MultiMeshInstance3D nodes.
	#
	# Deliberately NOT moved here: `_asset_id_for()`'s ancestor walk. It is the other half of the
	# per-node cost, but it reads meta off ancestors and is the part most likely to behave
	# differently one frame earlier. Measuring that is its own task.
	if node is GPUParticles3D or node.has_meta(VFX_META):
		return
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
		foliage_dressing_count += 1
		return
	# Mesh resources outlive the level that used them — ResourceLoader hands the same ArrayMesh
	# back after a scene reload, and the authored-prop mesh cache is shared across chunks. Dressing
	# one twice would read the wind material as if it were the asset's original and collapse the
	# asset to the default green, so the shader itself is the durable "already done" mark.
	var existing := mesh.surface_get_material(0)
	if existing is ShaderMaterial and (existing as ShaderMaterial).shader == FOLIAGE_SHADER:
		_dressed_meshes[mesh_key] = false
		foliage_dressing_count += 1
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
	foliage_dressing_count += 1
	sway_asset_count += 1
	_dressed_meshes[mesh_key] = true


## The name the art pipeline gave a material — `"MIRE_" + CamelCase(palette_token)` — or "" when
## there is no material to ask. Kept in one place because two cache keys and two materials depend on
## it saying exactly the same thing (F-442).
func _material_name(original: Material) -> String:
	return original.resource_name if original != null else ""


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
	# F-442: the ORIGINAL's name is part of the key, and is carried onto the material below. A
	# material's `resource_name` is the only thing in this game that says which surface is foliage —
	# `world/gen/prop_collider.gd::_is_foliage()` reads it to keep a tree's collider on its trunk —
	# and dressing a mesh for sway used to drop it, so every surface on a dressed tree looked
	# unnamed and its whole canopy read as solid. Keying on it as well means two differently-named
	# materials that happen to agree on colour and roughness cannot collapse onto one name.
	var key := "%s:%s:%.2f:%d:%.3f:%.3f:%.3f:%.2f:%.2f:%.3f:%.3f" % [
		_material_name(original), color.to_html(), material_roughness, int(vertex_color),
		float(profile.get("strength", 0.1)), float(profile.get("speed", 1.3)),
		float(profile.get("bob", 0.0)), float(profile.get("mask_power", 1.0)),
		float(profile.get("vertex_phase", 1.0)), bounds.size.y, bounds.position.y]
	if _sway_materials.has(key):
		return _sway_materials[key] as ShaderMaterial

	var material := ShaderMaterial.new()
	material.resource_name = _material_name(original)
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
		foliage_dressing_count += 1
		return
	var existing := mesh.surface_get_material(0)
	if existing is ShaderMaterial and (existing as ShaderMaterial).shader == FOLIAGE_SHADER:
		_dressed_meshes[mesh_key] = false
		foliage_dressing_count += 1
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
	foliage_dressing_count += 1
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

	# F-442: see `_sway_material` — the original's name is part of the key and is carried onto the
	# material, because it is what tells leaves from bark everywhere downstream.
	var key := "baked:%s:%s:%.2f:%d:%.3f:%.3f:%.3f:%.2f:%.2f" % [
		_material_name(original), color.to_html(), material_roughness, int(vertex_color),
		float(profile.get("strength", 0.1)), float(profile.get("speed", 1.3)),
		float(profile.get("bob", 0.0)), float(profile.get("mask_power", 1.0)),
		float(profile.get("vertex_phase", 1.0))]
	if _sway_materials.has(key):
		return _sway_materials[key] as ShaderMaterial

	var material := ShaderMaterial.new()
	material.resource_name = _material_name(original)
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
		# F-547: ONCE per asset, not once per node. `push_warning` captures and formats a GDScript
		# backtrace on every call, and this fired 1,821 times in a single 45-second walk — during
		# traversal, which is the path that already collapses the 1% low from 81 fps to 13.
		#
		# The condition it reports is per-GENERATOR, not per-node: either a generator publishes
		# `placements` for an asset's batches or it does not, so the thousandth warning carries no
		# information the first did not. Keyed by asset id where there is one, because that is what
		# a reader has to act on; node names here are per-cell (`tree_birch_d_0_3_-4`) and would
		# defeat the dedupe entirely.
		var warn_key: String = asset_id if not asset_id.is_empty() else node.name
		if not _placements_warned.has(warn_key):
			_placements_warned[warn_key] = true
			push_warning(
				"EnvironmentVfx: %s has an emitter but no `placements` meta; skipping "
				% warn_key
				+ "(reported once per asset — see F-547)"
			)
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
	var crowns: PackedVector2Array = _site_crowns.get_or_add(emitter, PackedVector2Array())
	# F-376: measured ONCE per prop here rather than per budget tick in `_assign_slots`, because it
	# is a property of the asset standing there and does not change while it stands. Vector2.ZERO
	# from a holder that cannot answer for one prop; `_apply_site_shape` reads that as "use the
	# stated fallback".
	var crown := _crown_metrics(node, source, not published.is_empty()) \
		if _needs_crown(emitter) else Vector2.ZERO
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
		crowns.append(crown)
		emitter_site_count += 1
		if _is_fire(emitter):
			fire_source_count += 1
	_sites[emitter] = sites
	# Written back because a PackedInt64Array is a value type — what `get_or_add` handed back is a
	# copy, and appending to it stores nothing (the same trap `_check_placement_space` documents in
	# `tools/environment_vfx_hollowmere_check.gd`).
	_site_sources[emitter] = sources
	_site_crowns[emitter] = crowns


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
##
## ## Why assignment is STABLE (F-376)
##
## The first version bound pool slot `i` to `ranked[i]` on every budget tick. That is correct about
## *which* sites are live and wrong about *which slot serves which*: walking at 4.4 m/s past a stand
## of trees reorders roughly-equidistant sites several times a second, and every reorder moved a live
## `GPUParticles3D` — with every leaf currently mid-fall inside it — to a different tree in one
## frame. Reported from play as leaves that "bug out when you start walking/running", and it got
## worse the faster you moved, because faster movement reorders the sort more often.
##
## A slot now keeps the site it already holds for as long as that site stays in the live set, and
## only a slot whose site genuinely dropped out is re-pointed. `SLOT_HOLD_BIAS` adds hysteresis so a
## site sitting on the boundary does not flip in and out on sub-metre movement. `_restart()` — which
## clears the in-flight particles rather than dragging them — is then reserved for the rare real
## reassignment it was always the right answer to.
func _assign_slots() -> void:
	if _sites.is_empty():
		return
	if not _ensure_effect_root():
		return

	var scale := _budget_scale()
	var viewpoint := _viewpoint()
	# F-376: read once per pass rather than per slot — it is a property of the world clock, not of
	# any one tree.
	var leaves_allowed := _leaf_fall_allowed()
	for emitter: AssetVfx.Emitter in _sites:
		var sites: Array = _sites[emitter] as Array
		var profile := AssetVfx.emitter_profile(emitter)
		var live: int = mini(
			maxi(1, int(round(float(profile.get("max_live", 4)) * scale))), sites.size())
		var shadows: int = int(round(float(profile.get("shadow_live", 0)) * scale))

		var pool: Array = _pools.get_or_add(emitter, [] as Array) as Array
		while pool.size() < live:
			pool.append(_make_effect(emitter))

		# Which site each slot is standing on right now. Read BEFORE the ranking, because holding a
		# site is what earns it the hysteresis bonus in that ranking.
		var held: Dictionary = {}
		for slot_index: int in pool.size():
			var slot: Dictionary = pool[slot_index]
			if not bool(slot.get("bound", false)):
				continue
			var site_index: int = int(slot.get("site", -1))
			if site_index >= 0 and site_index < sites.size():
				held[site_index] = slot_index

		var ranked: Array[int] = []
		for site_index: int in sites.size():
			ranked.append(site_index)
		var hold_bias_sq := SLOT_HOLD_BIAS * SLOT_HOLD_BIAS
		ranked.sort_custom(func(a: int, b: int) -> bool:
			var distance_a: float = (sites[a] as Vector3).distance_squared_to(viewpoint)
			var distance_b: float = (sites[b] as Vector3).distance_squared_to(viewpoint)
			if held.has(a):
				distance_a *= hold_bias_sq
			if held.has(b):
				distance_b *= hold_bias_sq
			return distance_a < distance_b)

		# The live set, and each member's rank inside it. The rank used to fall out of the slot
		# index — it cannot any more, now that a slot keeps its site — and shadows are assigned from
		# it, so it is carried explicitly.
		var target_rank: Dictionary = {}
		for rank: int in mini(live, ranked.size()):
			target_rank[ranked[rank]] = rank

		# Pass 1: every slot already holding a live site keeps it, and nothing about it moves.
		var free_slots: PackedInt32Array = PackedInt32Array()
		var claimed: Dictionary = {}
		for slot_index: int in pool.size():
			var slot: Dictionary = pool[slot_index]
			var site_index: int = int(slot.get("site", -1))
			if bool(slot.get("bound", false)) and target_rank.has(site_index) \
					and not claimed.has(site_index):
				claimed[site_index] = true
				continue
			free_slots.append(slot_index)

		# Pass 2: the live sites nobody is standing on go to the slots that were released. Iterating
		# `target_rank` walks the live set in rank order, so the nearest unserved site is served
		# first when there are fewer free slots than the budget would like.
		var pending: PackedInt32Array = PackedInt32Array()
		for site_index: int in target_rank:
			if not claimed.has(site_index):
				pending.append(site_index)
		for offset: int in free_slots.size():
			var slot: Dictionary = pool[free_slots[offset]]
			var node := slot["node"] as Node3D
			if not is_instance_valid(node):
				continue
			if offset >= pending.size():
				slot["bound"] = false
				slot["site"] = -1
				continue
			var site_index: int = pending[offset]
			slot["bound"] = true
			slot["site"] = site_index
			node.global_position = sites[site_index] as Vector3
			_apply_site_shape(emitter, node, site_index)
			# The particles in the air belonged to the site this slot just left. Restarting is what
			# stops them being dragged across the world to the new one (F-376).
			_restart(node)

		# Pass 3: presentation for every slot, bound or not.
		for slot_index: int in pool.size():
			var slot: Dictionary = pool[slot_index]
			var node := slot["node"] as Node3D
			if not is_instance_valid(node):
				continue
			var bound := bool(slot.get("bound", false))
			node.visible = bound
			# F-376: `emitting`, not `visible`. Stopping emission lets the leaves already mid-fall
			# at dusk finish falling; hiding the node would snap them out of the air.
			_set_emitting(
				node, bound and (emitter != AssetVfx.Emitter.LEAF_FALL or leaves_allowed))
			var light := slot["light"] as OmniLight3D
			if light != null and is_instance_valid(light):
				var rank: int = int(target_rank.get(int(slot.get("site", -1)), shadows))
				light.shadow_enabled = bound and rank < shadows
		_pools[emitter] = pool


## The container every pooled effect and every impact burst hangs under. Split out of
## `_assign_slots` because F-391's one-shot bursts need it too, and a world can hold destructible
## props without holding a single ambient emitter site.
func _ensure_effect_root() -> bool:
	if is_instance_valid(_effect_root):
		return true
	var scene: Node = get_tree().current_scene
	if scene == null:
		return false
	_effect_root = Node3D.new()
	_effect_root.name = "EnvironmentVfxEffects"
	scene.add_child(_effect_root)
	return true


## Release every slot's site binding. Called when the site arrays are re-indexed under the pools
## (`_prune_dead_sites`), which is the one event that makes a recorded index mean a different site.
func _unbind_all_slots() -> void:
	for emitter: AssetVfx.Emitter in _pools:
		for slot: Dictionary in _pools[emitter] as Array:
			slot["bound"] = false
			slot["site"] = -1


## Which emitter classes measure the prop they stand on. Only LEAF_FALL does: every other class
## emits from a point, and how big the asset around that point is changes nothing about it.
func _needs_crown(emitter: AssetVfx.Emitter) -> bool:
	return emitter == AssetVfx.Emitter.LEAF_FALL


## Do leaves fall right now? (F-376.)
##
## Nothing used to ask. Leaves kept coming down in full darkness lit by nothing, which is what made
## them read as a bug rather than as weather — reported from play as "also visible at night when they
## shouldnt be". `DayNight` owns the clock and its thresholds are exported, so this reads them rather
## than hardcoding dawn and dusk a second time; a harness with no DayNight autoload, or one whose
## stand-in does not carry the properties, keeps the old always-on behaviour rather than silently
## going dark.
func _leaf_fall_allowed() -> bool:
	var day_night: Node = get_node_or_null(^"/root/DayNight")
	if day_night == null:
		return true
	var raw_time: Variant = day_night.get(&"time_of_day")
	var raw_dawn: Variant = day_night.get(&"day_started_at")
	var raw_dusk: Variant = day_night.get(&"night_started_at")
	if not (raw_time is float and raw_dawn is float and raw_dusk is float):
		return true
	var dawn: float = raw_dawn
	var dusk: float = raw_dusk
	if dusk <= dawn:
		return true
	var fraction: float = raw_time
	return fraction >= dawn and fraction < dusk


## Per-SITE geometry for a slot that has just taken a new site. Only LEAF_FALL has any.
func _apply_site_shape(
	emitter: AssetVfx.Emitter, node: Node3D, site_index: int
) -> void:
	if emitter != AssetVfx.Emitter.LEAF_FALL:
		return
	var crowns: PackedVector2Array = _site_crowns.get(emitter, PackedVector2Array())
	var crown := LEAF_FALL_DEFAULT_CROWN
	if site_index >= 0 and site_index < crowns.size() and crowns[site_index].x > 0.01:
		crown = crowns[site_index]
	_shape_leaf_fall(node.get_node_or_null(^"Leaves") as GPUParticles3D, crown)


## Put the leaf emitter INSIDE the crown of the tree it is standing on (F-376).
##
## The first version passed one hardcoded height of 4.8 m for every species — `_leaf_fall(12, 7.0,
## 4.8)` — and its own header called that "a compromise, and a forgiving one, because a leaf that
## starts a metre inside the foliage simply appears from behind it". That reasoning holds only while
## the number UNDER-estimates the crown. Against the shipped trees it over-estimates: play reported
## leaves that "spawn above the trees", because a canopy topping out below 4.8 m was shedding from
## open sky. The height is now measured from the host prop's own mesh bounds, so it is right for a
## sapling, right for a mature oak, and right again the moment F-370 makes the trees taller —
## derived here rather than waiting on that finding to land.
func _shape_leaf_fall(leaves: GPUParticles3D, crown: Vector2) -> void:
	if leaves == null or not is_instance_valid(leaves):
		return
	var height: float = maxf(crown.x, 0.5)
	var radius: float = maxf(crown.y, 0.35)
	var emit_y: float = height * LEAF_FALL_CROWN_HEIGHT
	var band: float = maxf(height * LEAF_FALL_CROWN_BAND, 0.15)
	leaves.position.y = emit_y
	var process := leaves.process_material as ParticleProcessMaterial
	if process != null:
		process.emission_box_extents = Vector3(
			radius * LEAF_FALL_CROWN_INSET, band, radius * LEAF_FALL_CROWN_INSET)
	# Set explicitly and generously: particles that travel outside their own AABB are culled as a
	# group the moment the emitter's box leaves the frustum, which for something falling `emit_y`
	# metres and drifting sideways means leaves winking out while you are looking straight at them.
	var span: float = radius + 3.0
	leaves.visibility_aabb = AABB(
		Vector3(-span, -emit_y - 1.5, -span), Vector3(span * 2.0, emit_y + 3.0, span * 2.0))


## The prop's own crown, as (height above the site, horizontal half-width), both in world metres.
## `Vector2.ZERO` when this holder cannot answer for ONE prop — the caller then falls back to
## `LEAF_FALL_DEFAULT_CROWN`, which is a stated guess rather than a silent one.
##
## Three cases, because the three ways a generator can emit a prop answer differently:
##
## * A **MultiMesh batch** draws every copy from one mesh, so that mesh's LOCAL AABB is exactly one
##   prop's bounds. Per-instance transforms are not readable here — under `--headless`, which is
##   every way an agent can verify anything (F-077), the RenderingServer buffer is empty and every
##   read returns identity — so the batch node's own basis is the only scale available, and it is
##   identity for every generator in this project.
## * A **loose prop** (every harvestable tree, and everything `world/gen/resource_scatter_field.gd`
##   promotes to its own node) is a holder with mesh parts under it. Merging their world-space
##   bounds and subtracting the site origin gives the true height including the 0.85-1.2 placement
##   scale the scatter def applies.
## * A **merged multi-asset bake** (F-203's `EMITTER_META` holder) has a mesh whose AABB spans the
##   whole chunk bucket — several different assets and the terrain relief under them. There is no
##   per-prop answer to extract from that, so it declines rather than reporting a 40 m crown.
func _crown_metrics(node: GeometryInstance3D, host: Node, from_published: bool) -> Vector2:
	if from_published:
		var batch := node as MultiMeshInstance3D
		if batch == null or batch.multimesh == null or batch.multimesh.mesh == null:
			return Vector2.ZERO
		var local_bounds: AABB = Transform3D(node.global_transform.basis, Vector3.ZERO) \
			* batch.multimesh.mesh.get_aabb()
		return _crown_from_bounds(local_bounds, 0.0)

	var host_3d := host as Node3D
	if host_3d == null or not host_3d.is_inside_tree():
		return Vector2.ZERO
	var bounds := AABB()
	var found: bool = false
	for part: MeshInstance3D in _mesh_parts(host_3d):
		var mesh: Mesh = part.mesh
		if mesh == null:
			continue
		var part_bounds: AABB = part.global_transform * mesh.get_aabb()
		bounds = part_bounds if not found else bounds.merge(part_bounds)
		found = true
	if not found:
		return Vector2.ZERO
	return _crown_from_bounds(bounds, host_3d.global_position.y)


func _crown_from_bounds(bounds: AABB, origin_y: float) -> Vector2:
	var top: float = bounds.position.y + bounds.size.y - origin_y
	if top <= 0.25:
		return Vector2.ZERO
	return Vector2(top, maxf(bounds.size.x, bounds.size.z) * 0.5)


## Every MeshInstance3D under a prop's holder, capped at `CROWN_MESH_PART_CAP`. Runs once per
## emitter site at load, never per frame.
func _mesh_parts(host: Node3D) -> Array[MeshInstance3D]:
	var parts: Array[MeshInstance3D] = []
	var queue: Array[Node] = [host]
	while not queue.is_empty() and parts.size() < CROWN_MESH_PART_CAP:
		var cursor: Node = queue.pop_back()
		var mesh_instance := cursor as MeshInstance3D
		if mesh_instance != null and mesh_instance.is_inside_tree():
			parts.append(mesh_instance)
		for child: Node in cursor.get_children():
			queue.append(child)
	return parts


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


## Switch a pooled effect's particle systems on or off WITHOUT touching its visibility. A stopped
## emitter keeps whatever is already in the air until it dies of its own lifetime, which is the
## difference between a fade and a pop — see the day gate in `_assign_slots` (F-376).
func _set_emitting(node: Node3D, on: bool) -> void:
	for child: Node in node.get_children():
		if child is GPUParticles3D:
			(child as GPUParticles3D).emitting = on


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
## rather than grown. `site`/`bound` are how F-376 makes that reassignment stable: a slot records
## WHICH site it is serving, so `_assign_slots` can leave it there instead of re-deriving a binding
## from the slot's position in the distance sort every quarter second.
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
			# The emitter's HEIGHT is not decided here any more — `_apply_site_shape` measures it
			# from whatever prop the slot is standing on (F-376).
			node.add_child(_leaf_fall(LEAF_FALL_AMOUNT, 7.0))
	if light != null:
		node.add_child(light)
	return {"node": node, "light": light, "energy": energy, "site": -1, "bound": false}


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
## reads as a rock.
##
## Where the slab SITS is no longer decided here. F-376 replaced the single hardcoded height with a
## per-site measurement (`_shape_leaf_fall`, called from `_apply_site_shape` every time a slot takes
## a new tree); this only builds the system, seeded with the stated fallback so a slot is never
## degenerate between construction and its first binding.
func _leaf_fall(amount: int, lifetime: float) -> GPUParticles3D:
	var particles := _make_particles(amount, lifetime, Vector2(0.15, 0.21),
		Color(0.78, 0.63, 0.22, 0.95), Color(0.45, 0.37, 0.15, 0.0), 3)
	# Named so `_apply_site_shape` can find it again — every other emitter's particle children are
	# write-once, this one is re-shaped per site.
	particles.name = "Leaves"
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
	_shape_leaf_fall(particles, LEAF_FALL_DEFAULT_CROWN)
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
# Impacts (F-391)
# ---------------------------------------------------------------------------------------------

## Play a one-shot destruction burst at [param world_position].
##
## ## AUTHORITY: none
##
## Exactly like everything else in this file. The host alone decides whether a harvestable actually
## broke; this only draws the consequence, and every peer draws it from its own copy of the
## already-replicated health value (see `systems/harvesting/harvestable.gd`). Nothing here is sent,
## requested or trusted across the wire — no new RPC, and therefore no `NetVersion.PROTOCOL_VERSION`
## bump.
##
## ## Bound to the ASSET
##
## The caller passes the material class `AssetVfxLibrary` resolved from the asset id, never a scene,
## a map or a node name — the same contract every ambient effect here already honours, and for the
## same reason: release worlds are procedurally generated, so a world containing a boulder gets stone
## chips off it with no map edit and no code change (F-391, F-097's rule applied to an event).
##
## [param intensity] is one swing at 1.0; the depleting hit passes more and gets the bigger burst.
func play_impact(impact: AssetVfx.Impact, world_position: Vector3, intensity: float = 1.0) -> void:
	if impact == AssetVfx.Impact.NONE or intensity <= 0.0:
		return
	# A burst nobody can see is not worth a restart. This is also the second half of the guard on a
	# client being told LATE about a prop harvested minutes ago: interest management admits a prop at
	# `NetConfig.INTEREST_ENTER_RADIUS_M` (120 m), so the catch-up delta that drops its health to
	# zero always lands far outside this radius and never bursts. `Harvestable`'s own arm delay
	# covers the other route in, a prop whose first sync arrives moments after it is built.
	if world_position.distance_squared_to(_viewpoint()) \
			> IMPACT_MAX_DISTANCE_M * IMPACT_MAX_DISTANCE_M:
		return
	if not _ensure_effect_root():
		return
	var burst := _impact_slot(impact)
	if burst == null:
		return
	burst.global_position = world_position
	burst.visible = true
	# `amount_ratio` rather than `amount`: changing the count reallocates the particle buffer, and a
	# burst that reallocates on every swing is a hitch on exactly the machines this game targets.
	# The system is built at the material's full count and a normal swing simply uses less of it.
	var ratio: float = clampf(intensity * 0.42, 0.2, 1.0)
	for child: Node in burst.get_children():
		var particles := child as GPUParticles3D
		if particles == null:
			continue
		particles.amount_ratio = ratio
		particles.restart()
	impact_burst_count += 1
	last_impact = {
		"impact": int(impact),
		"position": world_position,
		"intensity": intensity,
		"amount_ratio": ratio,
	}


## The next burst node for a material, building the pool up to `IMPACT_POOL_SIZE` and then reusing
## it round-robin. Oldest-first reuse is correct for something that lives under 1.5 s: by the time
## the cursor comes back around, the burst it is stealing has finished.
func _impact_slot(impact: AssetVfx.Impact) -> Node3D:
	var pool: Array = _impact_pools.get_or_add(impact, [] as Array) as Array
	if pool.size() < IMPACT_POOL_SIZE:
		var built := _make_impact(impact, pool.size())
		if built == null:
			return null
		pool.append(built)
		_impact_pools[impact] = pool
		return built
	var cursor: int = int(_impact_cursors.get(impact, 0)) % pool.size()
	_impact_cursors[impact] = (cursor + 1) % pool.size()
	var node := pool[cursor] as Node3D
	return node if is_instance_valid(node) else null


func _make_impact(impact: AssetVfx.Impact, index: int) -> Node3D:
	var profile := AssetVfx.impact_profile(impact)
	if profile.is_empty():
		return null
	var node := Node3D.new()
	node.name = "Impact%d_%d" % [int(impact), index]
	node.set_meta(VFX_META, true)
	node.visible = false
	_effect_root.add_child(node)
	node.add_child(_chips(profile))
	if int(profile.get("dust_amount", 0)) > 0:
		node.add_child(_dust(profile))
	return node


## The solid fragments — splinters, stone flakes, torn leaf.
##
## Drawn with the leaf shape (`particle_shape` 3) rather than the spark shape, and the reason is
## worth stating: shape 1 is a soft round blob that `particle_billboard.gdshader` self-illuminates at
## 1.4x, which is right for an ember flying off a fire and completely wrong for a wood chip. Shape 3
## is unlit and tapered at both ends, so at three centimetres across it reads as a sliver of the
## thing you just hit. No shader change was needed for this, which is why none was made.
func _chips(profile: Dictionary) -> GPUParticles3D:
	var tint: Color = profile.get("chip_color", Color(0.6, 0.45, 0.25, 1.0))
	var particles := _make_particles(
		int(profile.get("chip_amount", 14)), float(profile.get("chip_life", 0.9)),
		profile.get("chip_size", Vector2(0.07, 0.035)) as Vector2,
		tint, Color(tint.r * 0.7, tint.g * 0.7, tint.b * 0.7, 0.0), 3)
	particles.name = "Chips"
	# One burst, all at once, and then nothing until the next swing.
	particles.one_shot = true
	particles.explosiveness = 1.0
	particles.emitting = false
	var process := particles.process_material as ParticleProcessMaterial
	process.direction = Vector3.UP
	# Near-hemispherical: a struck surface throws fragments outward, not up a chimney.
	process.spread = 78.0
	process.initial_velocity_min = float(profile.get("chip_speed_min", 1.5))
	process.initial_velocity_max = float(profile.get("chip_speed_max", 4.0))
	# Real gravity, unlike every ambient emitter in this file. A chip is a solid fragment thrown off
	# a surface and it has to arc and drop to read as one; the drifting values that make smoke and
	# leaves work would make this look like ash.
	process.gravity = Vector3(0.0, -9.2, 0.0)
	process.angular_velocity_min = -520.0
	process.angular_velocity_max = 520.0
	process.angle_min = -180.0
	process.angle_max = 180.0
	process.scale_min = 0.6
	process.scale_max = 1.25
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = float(profile.get("origin_radius", 0.2))
	particles.visibility_aabb = AABB(Vector3(-2.5, -3.0, -2.5), Vector3(5.0, 6.0, 5.0))
	return particles


## The soft cloud that hangs after the fragments have fallen — sawdust off an axe, rock powder off a
## pickaxe. `dust_amount` 0 means the material does not make one; foliage does not, and a puff of
## dust off a nettle would read as smoke.
func _dust(profile: Dictionary) -> GPUParticles3D:
	var tint: Color = profile.get("dust_color", Color(0.5, 0.45, 0.35, 0.3))
	var particles := _make_particles(
		int(profile.get("dust_amount", 6)), float(profile.get("dust_life", 1.0)),
		profile.get("dust_size", Vector2(0.32, 0.32)) as Vector2,
		tint, Color(tint.r, tint.g, tint.b, 0.0), 2)
	particles.name = "Dust"
	particles.one_shot = true
	particles.explosiveness = 0.85
	particles.emitting = false
	var rise: float = float(profile.get("dust_rise", 0.6))
	var process := particles.process_material as ParticleProcessMaterial
	process.direction = Vector3.UP
	process.spread = 60.0
	process.initial_velocity_min = rise * 0.4
	process.initial_velocity_max = rise
	# Barely any fall: dust hangs, and the slight lateral term keeps the cloud from being a sphere.
	process.gravity = Vector3(0.05, -0.35, 0.04)
	# Grows as it disperses, which is most of what separates dust from a puff of steam.
	process.scale_min = 0.5
	process.scale_max = 1.0
	process.scale_curve = _dust_growth_curve()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = float(profile.get("origin_radius", 0.2)) * 1.4
	particles.visibility_aabb = AABB(Vector3(-2.0, -1.0, -2.0), Vector3(4.0, 4.0, 4.0))
	return particles


## Built per dust system rather than cached on the script. It is immutable content and one shared
## copy would be tidier, but a `static var` on an autoload holds it for the life of the PROCESS, and
## a resource alive at exit is a line in the engine's shutdown report — noise that a reviewer then
## has to prove is harmless. At most `IMPACT_POOL_SIZE` burst nodes per material carry one, they are
## a handful of floats each, and they die with the scene like everything else under `_effect_root`.
func _dust_growth_curve() -> CurveTexture:
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 0.35))
	curve.add_point(Vector2(0.35, 1.0))
	curve.add_point(Vector2(1.0, 1.35))
	var texture := CurveTexture.new()
	texture.curve = curve
	return texture


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


## Which site index each slot of one emitter class is bound to, in slot order; -1 for an idle slot.
##
## Exists for `tools/harvest_vfx_check.gd` (F-376). Slot STABILITY is the fix for the leaves that
## "bug out when you start walking" and only the binding shows it: a count is identical whether a
## slot kept its tree or was re-pointed at a different one every quarter second.
func slot_sites(emitter: AssetVfx.Emitter) -> PackedInt32Array:
	var bound := PackedInt32Array()
	for slot: Dictionary in _pools.get(emitter, [] as Array) as Array:
		bound.append(int(slot.get("site", -1)) if bool(slot.get("bound", false)) else -1)
	return bound


## The pooled effect nodes for one emitter class, in slot order. Also for the checks (F-376): the
## day gate and the measured crown are both properties of the NODE, and no census exposes either.
func effect_nodes(emitter: AssetVfx.Emitter) -> Array[Node3D]:
	var nodes: Array[Node3D] = []
	for slot: Dictionary in _pools.get(emitter, [] as Array) as Array:
		var node := slot["node"] as Node3D
		if is_instance_valid(node):
			nodes.append(node)
	return nodes


## The crown each site of one emitter class was measured at, index for index with
## `site_positions()`. `Vector2.ZERO` marks a site that fell back to `LEAF_FALL_DEFAULT_CROWN`.
func site_crowns(emitter: AssetVfx.Emitter) -> PackedVector2Array:
	return (_site_crowns.get(emitter, PackedVector2Array()) as PackedVector2Array).duplicate()


## How many effect nodes are switched on right now.
func live_count() -> int:
	var live: int = 0
	for emitter: AssetVfx.Emitter in _pools:
		for slot: Dictionary in _pools[emitter] as Array:
			var node := slot["node"] as Node3D
			if is_instance_valid(node) and node.visible:
				live += 1
	return live
