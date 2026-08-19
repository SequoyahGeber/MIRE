extends SceneTree

## Regression check for F-187/F-203/F-208: AuthoredWorld._build_props merges rigid, non-batch,
## never-shadow-casting props across assets into one static mesh per chunk instead of one
## MultiMesh per (chunk, asset) — and, since F-203, does the same for emitter-bearing props too,
## split into their own per-(chunk, emitter class) merge bucket rather than folded into the
## chunk's plain one (GLOW excepted — it needs no per-instance bookkeeping and merges with the
## plain bucket like any other inert prop). Since F-208, sway-bearing props (that carry no
## emitter) get the same treatment, split into a per-(chunk, sway type) bucket instead — a
## sway-AND-emitter combo asset (mire_tendril) stays excluded from every bucket, unchanged from
## F-187/F-203.
##
## Two things could silently break this and neither would show up as an engine error:
##
## 1. The eligibility rule (harvestable, emitter, sway, shadow-height) could drift out of sync
##    between the classification loop and this check, quietly merging (or failing to merge) props
##    it shouldn't. This check recomputes eligibility independently, straight from the layout file
##    and the same three libraries `_build_props` reads, and asserts the number of merge buckets
##    (chunks, or chunk+emitter-class or chunk+sway-type pairs) that recomputation predicts
##    matches the number of "merged_*" holder nodes the scene actually built — a mismatch means
##    the two classifications have drifted apart.
## 2. The shadow-cascade regression F-203 exists because of (measured with `frame_cost_check.gd`
##    against `agent baseline`: shadow-pass primitives rose 16% before the height filter was
##    added). Every merged node's own `cast_shadow` must read OFF, because the height filter is
##    supposed to guarantee every prop going into a merge is too short to cast one regardless of
##    grouping — if that ever reads ON, the cascade-crossing regression is back.
##
## Run with:  .agent/bin/agent godot --script tools/prop_chunk_merge_check.gd

const SCENE_PATH: String = "res://levels/hollowmere.tscn"
const LAYOUT_PATH: String = "res://world/gen/layouts/hollowmere.json"
const AssetVfx := preload("res://world/environment/asset_vfx_library.gd")
const HarvestLib := preload("res://systems/harvesting/harvest_library.gd")
const DrawPolicy := preload("res://world/environment/draw_policy.gd")
const MeshMerge := preload("res://core/render/mesh_merge.gd")

var failures: Array[String] = []


func _init() -> void:
	var packed: PackedScene = load(SCENE_PATH) as PackedScene
	if packed == null:
		failures.append("could not load %s" % SCENE_PATH)
		_finish()
		return
	var level := packed.instantiate()
	root.add_child(level)
	current_scene = level
	for frame in 4:
		await process_frame

	var world := level.get_node_or_null("World")
	if world == null:
		failures.append("scene has no World node")
		_finish()
		return

	var merged_count: int = int(world.get("merged_prop_mesh_count"))
	print("PROP_CHUNK_MERGE merged_meshes=%d multimeshes=%d" % [
		merged_count, int(world.get("multimesh_count"))])
	if merged_count <= 0:
		failures.append("no merged_prop_mesh_count built at all")

	_check_holders(world, merged_count)
	_check_eligibility_parity(merged_count)

	level.queue_free()
	_finish()


## Every "merged_*" holder under PropVisuals must carry exactly one MeshInstance3D named
## "MergedProps", with real geometry, a draw distance, and — the F-203 invariant — no shadow.
func _check_holders(world: Node, expected_count: int) -> void:
	var visuals := (world as Node).get_node_or_null("PropVisuals")
	if visuals == null:
		failures.append("World has no PropVisuals node")
		return
	var found := 0
	for holder: Node in visuals.get_children():
		if not String(holder.name).begins_with("merged_"):
			continue
		found += 1
		var mesh_instances: Array[MeshInstance3D] = []
		for child: Node in holder.get_children():
			if child is MeshInstance3D:
				mesh_instances.append(child as MeshInstance3D)
		if mesh_instances.size() != 1:
			failures.append("%s has %d MeshInstance3D children, expected 1"
				% [holder.name, mesh_instances.size()])
			continue
		var instance := mesh_instances[0]
		if instance.mesh == null or instance.mesh.get_surface_count() == 0:
			failures.append("%s's MergedProps has no built geometry" % holder.name)
		if instance.visibility_range_end <= 0.0:
			failures.append("%s's MergedProps has no draw distance" % holder.name)
		if instance.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
			failures.append(
				"%s's MergedProps casts a shadow — the F-203 cascade regression is back"
				% holder.name)
	if found != expected_count:
		failures.append("%d merged_* holders in the scene, world reported merged_prop_mesh_count=%d"
			% [found, expected_count])


## Recompute, straight from the layout and the same three libraries `_build_props` classifies
## against, which (chunk, prop) pairs SHOULD have merged — then check that count of distinct
## merge BUCKETS matches the holder count found above. A rule change that silently widens or
## narrows eligibility moves this number without touching `merged_prop_mesh_count`'s own sanity
## check.
##
## F-203/F-208: a bucket is a chunk on its own for a plain rigid prop, a (chunk, emitter class)
## pair for an emitter-bearing one, or a (chunk, sway type) pair for a sway-bearing one —
## `_build_props` gives each emitter class or sway type its own merged mesh per chunk rather than
## folding it into the chunk's single asset-agnostic one (see `world/gen/authored_world.gd`'s
## classification comment for why the class/type has to be the merge key). GLOW is the one
## emitter that stays folded into the plain bucket: nothing at runtime ever reads a class or a
## position for it, so it needs none of the other classes' bookkeeping. An asset carrying BOTH
## sway and an emitter (mire_tendril) stays excluded from every bucket, per F-208's own scope.
func _check_eligibility_parity(actual_holders: int) -> void:
	var layout: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(LAYOUT_PATH)) as Dictionary
	if layout == null or layout.is_empty():
		failures.append("could not read %s" % LAYOUT_PATH)
		return
	var buckets_with_eligible: Dictionary = {}
	var eligible_props := 0
	for value: Variant in layout.get("props", []):
		var prop := value as Dictionary
		var asset_name := String(prop.get("asset", ""))
		var asset_id := StringName(asset_name)
		if bool(prop.get("harvestable", false)) or HarvestLib.is_harvestable(asset_id):
			if HarvestLib.representation_for(asset_id) == HarvestLib.Represent.NODE:
				continue
		if HarvestLib.is_harvestable(asset_id):
			continue
		var sway := AssetVfx.sway_for(asset_name)
		var emitter := AssetVfx.emitter_for(asset_name)
		if sway != AssetVfx.Sway.NONE and emitter != AssetVfx.Emitter.NONE:
			continue
		var mesh := MeshMerge.merged(
			"res://assets/%s/exports/%s.glb" % [String(prop.get("kit", "")), asset_name])
		if mesh == null:
			continue
		var height: float = mesh.get_aabb().size.y * float(prop.get("scale", 1.0))
		if height >= DrawPolicy.SHADOW_MIN_HEIGHT:
			continue
		var chunk: Array = prop.get("chunk", [0, 0]) as Array
		var bucket := "%d_%d" % [int(chunk[0]), int(chunk[1])]
		if sway != AssetVfx.Sway.NONE:
			bucket = "%s|s%d" % [bucket, int(sway)]
		elif emitter != AssetVfx.Emitter.NONE and emitter != AssetVfx.Emitter.GLOW:
			bucket = "%s|e%d" % [bucket, int(emitter)]
		buckets_with_eligible[bucket] = true
		eligible_props += 1
	print("PROP_CHUNK_MERGE eligible_props=%d eligible_chunks=%d" % [
		eligible_props, buckets_with_eligible.size()])
	if eligible_props == 0:
		failures.append("no prop in the layout independently recomputes as merge-eligible — "
			+ "the check's own rule may have drifted from _build_props'")
	if buckets_with_eligible.size() != actual_holders:
		failures.append(
			"independent recompute predicts %d merged buckets, the scene built %d — "
			% [buckets_with_eligible.size(), actual_holders]
			+ "_build_props' eligibility rule and this check's have drifted apart")


func _finish() -> void:
	if failures.is_empty():
		print("PROP_CHUNK_MERGE_CHECK PASS")
	else:
		print("PROP_CHUNK_MERGE_CHECK FAIL (%d)" % failures.size())
		for failure in failures:
			print("  ", failure)
	quit(0 if failures.is_empty() else 1)
