extends SceneTree

## F-376 and F-391 — the two halves of "what happens when you look at, or hit, a prop".
##
## Both findings came from the same play session and both are pure presentation, so they are proved
## in one harness rather than two: they share a scene, an `EnvironmentVfx` autoload and a camera, and
## splitting them would mean booting the whole content stack twice to assert eight things.
##
## **F-376 — leaf fall.** Three defects, one per section below:
##
##   1. the emitter height was a hardcoded 4.8 m for every species, so a crown topping out below
##      that shed leaves out of open sky ABOVE itself;
##   2. nothing consulted `DayNight`, so leaves fell in full darkness lit by nothing;
##   3. the pool bound slot `i` to `ranked[i]` every budget tick, so walking past a stand of trees
##      re-pointed live emitters on ORDER churn and dragged every in-flight leaf across the world.
##
## **F-391 — harvest impact.** A harvested node produced no feedback at all: no chips, no dust, no
## debris on the final hit. The burst is asset-bound (`AssetVfxLibrary.impact_for`) and client-local,
## and this proves both that it fires on a real hit and that it stays quiet on the two health drops
## that are NOT a hit.
##
## Reads the registered autoloads. A check that builds its own `EnvironmentVfx` cannot see the
## shipped one and would read zeros — the autoload marks every node it has already handled.

const AssetVfx := preload("res://world/environment/asset_vfx_library.gd")
const HARVEST_LIB := preload("res://systems/harvesting/harvest_library.gd")
const HARVESTABLE_SCRIPT := preload("res://systems/harvesting/harvestable.gd")
const HARVESTABLE_DEF_SCRIPT := preload("res://systems/harvesting/harvestable_def.gd")
const ITEM_DEF_SCRIPT := preload("res://systems/inventory/item_def.gd")

const TEST_ITEM_ID: StringName = &"check_timber"
## The height the old code emitted every species' leaves from. Asserted AGAINST, not for: no tree
## this check builds is 4.8 m tall, so any slot still sitting at 4.8 * 0.80 is the bug.
const OLD_FIXED_HEIGHT: float = 4.8
## Comfortably past `Harvestable.IMPACT_ARM_DELAY_MSEC` (1500 ms). Real wall-clock time, because the
## arm delay is measured in real wall-clock time — that is the whole point of it.
const ARM_WAIT_SEC: float = 1.7

var failures: int = 0
var _scene: Node3D
var _camera: Camera3D
var _vfx: Node


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_vfx = root.get_node_or_null(^"EnvironmentVfx")
	check(_vfx != null, "EnvironmentVfx is registered as an autoload")
	if _vfx == null:
		finish()
		return

	_scene = Node3D.new()
	_scene.name = "HarvestVfxCheckScene"
	root.add_child(_scene)
	current_scene = _scene
	_camera = Camera3D.new()
	_camera.name = "CheckCamera"
	_scene.add_child(_camera)
	_camera.current = true
	await process_frame

	_check_library()
	await _check_crown_height()
	_check_day_gate()
	await _check_slot_stability()
	await _check_impacts()

	print("HARVEST_VFX_CHECK failures=%d" % failures)
	finish()


# ── F-391 · classification ───────────────────────────────────────────────────────────────────────


## The asset is the durable identity, so the classification has to answer from the asset id alone —
## the same contract the ambient emitters have had since F-097. The tool fallback is what covers a
## species no rule names yet, which on a procedurally generated island is the normal case.
func _check_library() -> void:
	check(AssetVfx.impact_for("tree_pine_c") == AssetVfx.Impact.WOOD,
		"a tree is made of wood, decided from the asset id")
	check(AssetVfx.impact_for("harvest_tree_intact") == AssetVfx.Impact.WOOD,
		"the authored harvest tree resolves before the bare `tree_` rule")
	check(AssetVfx.impact_for("boulder_mossy_a") == AssetVfx.Impact.STONE,
		"a boulder is made of stone")
	check(AssetVfx.impact_for("iron_node_intact") == AssetVfx.Impact.STONE,
		"an ore node is made of stone")
	check(AssetVfx.impact_for("bush_round_c") == AssetVfx.Impact.FOLIAGE,
		"a bush tears rather than chips")
	check(AssetVfx.impact_for("station_campfire") == AssetVfx.Impact.NONE,
		"scenery nobody harvests has no destruction material")

	check(AssetVfx.impact_for_tool(HARVEST_LIB.Tool.CHOP) == AssetVfx.Impact.WOOD,
		"the CHOP fallback is wood — F-391 names it explicitly")
	check(AssetVfx.impact_for_tool(HARVEST_LIB.Tool.MINE) == AssetVfx.Impact.STONE,
		"the MINE fallback is stone — F-391 names it explicitly")
	check(AssetVfx.impact_for_tool(HARVEST_LIB.Tool.NONE) == AssetVfx.Impact.FOLIAGE,
		"a bare-hands prop is soft growth")

	for impact: AssetVfx.Impact in [
		AssetVfx.Impact.WOOD, AssetVfx.Impact.STONE, AssetVfx.Impact.FOLIAGE
	]:
		check(not AssetVfx.impact_profile(impact).is_empty(),
			"impact class %d has a profile to build a burst from" % int(impact))


# ── F-376 · defect 1, the hardcoded 4.8 m ────────────────────────────────────────────────────────


## Two trees of very different heights standing side by side. If the emitter height is derived from
## the prop, they disagree; if it is one number for every species, they agree — and that is exactly
## the failure ("leaves spawn above the trees") on the short one.
func _check_crown_height() -> void:
	var tall := _tree("tree_check_tall", Vector3(0.0, 0.0, 0.0), 8.4, 3.4)
	var short := _tree("tree_check_short", Vector3(6.0, 0.0, 0.0), 2.6, 1.8)
	_camera.global_position = Vector3(0.0, 1.6, -3.0)
	await process_frame
	_vfx.call(&"refresh_scene")

	var crowns: PackedVector2Array = _vfx.call(&"site_crowns", AssetVfx.Emitter.LEAF_FALL)
	var positions: PackedVector3Array = (
		_vfx.call(&"site_positions") as Dictionary
	).get(AssetVfx.Emitter.LEAF_FALL, PackedVector3Array())
	check(positions.size() == 2 and crowns.size() == 2,
		"both check trees registered a leaf-fall site with a crown (%d/%d)"
		% [positions.size(), crowns.size()])
	if positions.size() != 2 or crowns.size() != 2:
		return

	var tall_crown := _crown_at(positions, crowns, tall.global_position)
	var short_crown := _crown_at(positions, crowns, short.global_position)
	check(absf(tall_crown.x - 8.4) < 0.6,
		"the 8.4 m tree was measured at its own height (%.2f)" % tall_crown.x)
	check(absf(short_crown.x - 2.6) < 0.4,
		"the 2.6 m tree was measured at its own height (%.2f)" % short_crown.x)
	check(absf(tall_crown.y - 1.7) < 0.4 and absf(short_crown.y - 0.9) < 0.3,
		"each crown's half-width came from its own bounds (%.2f / %.2f)"
		% [tall_crown.y, short_crown.y])

	# The emitter node itself, which is what the player actually sees leaves come out of.
	var bound: Dictionary = _bound_sites(positions)
	var tall_y: float = _leaf_height(bound, tall.global_position)
	var short_y: float = _leaf_height(bound, short.global_position)
	check(tall_y > 0.0 and short_y > 0.0,
		"both trees have a live leaf emitter to inspect (%.2f / %.2f)" % [tall_y, short_y])
	if tall_y <= 0.0 or short_y <= 0.0:
		return
	check(tall_y > short_y + 2.0,
		"the tall tree sheds from higher up than the short one (%.2f vs %.2f)" % [tall_y, short_y])
	check(tall_y < 8.4 and short_y < 2.6,
		"neither emitter sits ABOVE its own canopy — F-376's actual complaint (%.2f/%.2f)"
		% [tall_y, short_y])
	check(tall_y > 8.4 * 0.5 and short_y > 2.6 * 0.5,
		"...and neither sits down in the trunk either (%.2f/%.2f)" % [tall_y, short_y])
	check(absf(short_y - OLD_FIXED_HEIGHT) > 1.0,
		"the short tree is not still emitting from the old fixed 4.8 m (%.2f)" % short_y)


# ── F-376 · defect 2, no night gate ──────────────────────────────────────────────────────────────


## `emitting`, not `visible`: a leaf already mid-fall at dusk has to finish falling, and hiding the
## node would snap it out of the air. So the assertion is on the emitter's switch.
func _check_day_gate() -> void:
	var day_night: Node = root.get_node_or_null(^"DayNight")
	check(day_night != null, "DayNight is registered as an autoload")
	if day_night == null:
		return
	var restore: float = float(day_night.get(&"time_of_day"))
	var dawn: float = float(day_night.get(&"day_started_at"))
	var dusk: float = float(day_night.get(&"night_started_at"))

	day_night.set(&"time_of_day", (dawn + dusk) * 0.5)
	_vfx.call(&"refresh_scene")
	check(_leaves_emitting(), "leaves fall at midday")

	day_night.set(&"time_of_day", fposmod(dusk + 0.05, 1.0))
	_vfx.call(&"refresh_scene")
	check(not _leaves_emitting(),
		"leaves stop after dusk — nothing consulted DayNight before F-376")

	day_night.set(&"time_of_day", maxf(dawn - 0.05, 0.0))
	_vfx.call(&"refresh_scene")
	check(not _leaves_emitting(), "...and are still stopped before dawn")

	day_night.set(&"time_of_day", (dawn + dusk) * 0.5)
	_vfx.call(&"refresh_scene")
	check(_leaves_emitting(), "and start again once it is light")
	day_night.set(&"time_of_day", restore)


# ── F-376 · defect 3, the pool teleport ──────────────────────────────────────────────────────────


## The invariant that separates a stable assignment from an index-based one: **a slot changes site
## only to take a site that has just entered the live set.** Under the old `pool[i] = ranked[i]`
## scheme, two roughly-equidistant trees swapping order in the sort re-pointed BOTH slots while the
## live set was unchanged — the reassignment count would exceed the entry count, and every one of
## those reassignments dragged a live particle system (and every leaf in it) across the world.
##
## Walking the camera is what makes this real rather than theoretical: the finding says the artifact
## "gets worse the faster you move", and moving is the only thing that reorders the sort. Replaying
## this exact walk against the OLD `pool[i] = ranked[i]` rule gives **60 reassignments for 4
## entries** — sixty teleported particle systems over eighteen metres of walking — against 3 for 3
## now, which is the size of the artifact this assertion is guarding.
func _check_slot_stability() -> void:
	for index: int in 10:
		_tree("tree_check_row_%d" % index, Vector3(4.0 + float(index) * 3.0, 0.0, 4.0), 6.0, 2.6)
	_camera.global_position = Vector3(0.0, 1.6, 4.0)
	await process_frame
	_vfx.call(&"refresh_scene")

	var previous: PackedInt32Array = _vfx.call(&"slot_sites", AssetVfx.Emitter.LEAF_FALL)
	check(previous.size() > 0, "the leaf-fall pool has slots to observe (%d)" % previous.size())
	if previous.is_empty():
		return

	# Stationary first: the same viewpoint twice must not move a single slot.
	_vfx.call(&"refresh_scene")
	var stationary: PackedInt32Array = _vfx.call(&"slot_sites", AssetVfx.Emitter.LEAF_FALL)
	check(stationary == previous, "a second pass from the same viewpoint rebinds nothing")

	var rebinds: int = 0
	var entries: int = 0
	for step: int in 24:
		_camera.global_position = Vector3(float(step + 1) * 0.75, 1.6, 4.0)
		_vfx.call(&"refresh_scene")
		var current: PackedInt32Array = _vfx.call(&"slot_sites", AssetVfx.Emitter.LEAF_FALL)
		var was: Dictionary = {}
		for site: int in previous:
			if site >= 0:
				was[site] = true
		for slot: int in mini(current.size(), previous.size()):
			if current[slot] >= 0 and current[slot] != previous[slot]:
				rebinds += 1
		for site: int in current:
			if site >= 0 and not was.has(site):
				entries += 1
		previous = current

	check(entries > 0,
		"the walk actually moved the live set, so the invariant below is being tested (%d)" % entries)
	check(rebinds == entries,
		("a slot moved ONLY to take a site that just entered the live set — %d rebind(s) for "
			+ "%d entry(ies); order churn alone must never move one") % [rebinds, entries])


# ── F-391 · the burst itself ─────────────────────────────────────────────────────────────────────


func _check_impacts() -> void:
	var registry: Node = root.get_node_or_null(^"Registry")
	check(registry != null, "Registry autoload exists")
	if registry == null:
		return
	# F-060: read, mutate, write back explicitly — Registry.items is strictly typed and the generic
	# property API can hand back a converted copy.
	var item: Resource = ITEM_DEF_SCRIPT.new()
	item.set("id", TEST_ITEM_ID)
	var items: Dictionary = registry.get("items")
	items[TEST_ITEM_ID] = item
	registry.set("items", items)

	var prop := _harvestable("tree_check_hit", Vector3(2.0, 0.0, -6.0), HARVEST_LIB.Tool.CHOP)
	var stone := _harvestable("boulder_check_hit", Vector3(4.0, 0.0, -6.0), HARVEST_LIB.Tool.MINE)
	_camera.global_position = Vector3(3.0, 1.6, -4.0)
	await process_frame

	check(int(prop.call(&"impact_class")) == AssetVfx.Impact.WOOD,
		"the tree prop reports wood, from its own asset meta")
	check(int(stone.call(&"impact_class")) == AssetVfx.Impact.STONE,
		"the boulder prop reports stone, from its own asset meta")

	# The arm delay is the guard against a client's first replication delta — max health to zero for
	# a prop harvested an hour ago — reading as a fresh hit. Nothing may burst before it expires.
	var before_arm: int = int(_vfx.get(&"impact_burst_count"))
	check(bool(prop.call(&"host_apply_damage", 1, 1)), "the host accepts a hit inside the arm delay")
	check(int(_vfx.get(&"impact_burst_count")) == before_arm,
		"...and it does NOT burst — a newly built prop is still settling its replicated state")
	prop.call(&"host_respawn")

	var timer: SceneTreeTimer = create_timer(ARM_WAIT_SEC)
	await timer.timeout

	var baseline: int = int(_vfx.get(&"impact_burst_count"))
	check(bool(prop.call(&"host_apply_damage", 1, 1)), "the host accepts an ordinary chop")
	var after_hit: int = int(_vfx.get(&"impact_burst_count"))
	check(after_hit == baseline + 1,
		"one landed hit plays exactly one burst — before F-391 it played none (%d -> %d)"
		% [baseline, after_hit])
	var hit_record: Dictionary = _vfx.get(&"last_impact")
	check(int(hit_record.get("impact", -1)) == AssetVfx.Impact.WOOD,
		"the burst is wood, because the ASSET is a tree")
	var anchor: Vector3 = hit_record.get("position", Vector3.ZERO)
	check(anchor.y > prop.global_position.y + 0.2 and anchor.y < prop.global_position.y + 2.0,
		"the chips come off the prop at swing height, not out of the ground (%.2f)" % anchor.y)

	# The depleting hit is the one the finding singles out — "a larger burst on the depletion hit".
	var ordinary_ratio: float = float(hit_record.get("amount_ratio", 0.0))
	while bool(prop.get(&"active")):
		prop.call(&"host_apply_damage", 1, 1)
	var deplete_record: Dictionary = _vfx.get(&"last_impact")
	check(float(deplete_record.get("intensity", 0.0)) > 1.0,
		"the depleting hit is a bigger burst than an ordinary one (%.2f)"
		% float(deplete_record.get("intensity", 0.0)))
	check(float(deplete_record.get("amount_ratio", 0.0)) > ordinary_ratio,
		"...and it actually emits more of the system (%.2f vs %.2f)"
		% [float(deplete_record.get("amount_ratio", 0.0)), ordinary_ratio])

	# F-231's depletion memory re-establishes a state that already paid out. It is bookkeeping, not
	# a swing, and the presentation has to stay as quiet as the yield event does.
	prop.call(&"host_respawn")
	var before_restore: int = int(_vfx.get(&"impact_burst_count"))
	check(bool(prop.call(&"host_restore_depleted")), "host_restore_depleted() applies")
	check(int(_vfx.get(&"impact_burst_count")) == before_restore,
		"replaying a remembered depletion bursts nothing — it is not a hit")

	# The distance gate: the other half of the same guard, and the one that covers a client only
	# being told about a prop when interest management admits it at 120 m.
	var before_far: int = int(_vfx.get(&"impact_burst_count"))
	_vfx.call(&"play_impact", AssetVfx.Impact.STONE, Vector3(0.0, 0.0, 400.0), 1.0)
	check(int(_vfx.get(&"impact_burst_count")) == before_far,
		"a burst 400 m away is skipped rather than allocated")

	var before_stone: int = int(_vfx.get(&"impact_burst_count"))
	check(bool(stone.call(&"host_apply_damage", 1, 1)), "the host accepts a mining hit")
	check(int(_vfx.get(&"impact_burst_count")) == before_stone + 1, "the boulder bursts too")
	check(int((_vfx.get(&"last_impact") as Dictionary).get("impact", -1)) == AssetVfx.Impact.STONE,
		"...and it bursts stone, not wood")

	var cleanup: Dictionary = registry.get("items")
	cleanup.erase(TEST_ITEM_ID)
	registry.set("items", cleanup)


# ── Fixtures ─────────────────────────────────────────────────────────────────────────────────────


## A prop shaped the way `world/gen/resource_scatter_field.gd` builds one: a holder carrying the
## asset meta, with the geometry under a `Visual` child. That shape is what `EnvironmentVfx`'s
## emitter-host walk and `Harvestable`'s anchor measurement both read, so a fixture that flattens it
## would be testing something the game does not build.
func _tree(asset_id: String, origin: Vector3, height: float, width: float) -> Node3D:
	var holder := Node3D.new()
	holder.name = "Holder_%s" % asset_id
	holder.set_meta(&"asset", StringName(asset_id))
	holder.position = origin
	var visual := Node3D.new()
	visual.name = "Visual"
	var mesh_instance := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(width, height, width)
	mesh_instance.mesh = box
	# Modelled with its base on the ground, exactly as the flora exports are.
	mesh_instance.position = Vector3(0.0, height * 0.5, 0.0)
	visual.add_child(mesh_instance)
	holder.add_child(visual)
	_scene.add_child(holder)
	return holder


func _harvestable(asset_id: String, origin: Vector3, required_tool: int) -> Node3D:
	var holder := _tree(asset_id, origin, 3.0, 1.4)
	var definition: Resource = HARVESTABLE_DEF_SCRIPT.new()
	definition.set("id", StringName("check_%s" % asset_id))
	definition.set("max_health", 3)
	definition.set("damage_per_hit", 1)
	definition.set("required_tool", required_tool)
	definition.set("yield_item_id", TEST_ITEM_ID)
	definition.set("yield_amount", 1)
	definition.set("respawn_seconds", 600.0)
	definition.set("request_cooldown_seconds", 0.0)

	var prop: Node3D = HARVESTABLE_SCRIPT.new() as Node3D
	prop.name = "Harvestable"
	prop.set("definition", definition)
	prop.set_meta(&"asset", StringName(asset_id))
	holder.add_child(prop)
	return prop


# ── Readers ──────────────────────────────────────────────────────────────────────────────────────


func _crown_at(
	positions: PackedVector3Array, crowns: PackedVector2Array, where: Vector3
) -> Vector2:
	for index: int in positions.size():
		if positions[index].distance_to(where) < 0.5 and index < crowns.size():
			return crowns[index]
	return Vector2.ZERO


## Site index -> the pooled effect node standing on it, for the classes this check inspects.
func _bound_sites(positions: PackedVector3Array) -> Dictionary:
	var bound: Dictionary = {}
	var sites: PackedInt32Array = _vfx.call(&"slot_sites", AssetVfx.Emitter.LEAF_FALL)
	var nodes: Array[Node3D] = _vfx.call(&"effect_nodes", AssetVfx.Emitter.LEAF_FALL)
	for slot: int in mini(sites.size(), nodes.size()):
		if sites[slot] >= 0 and sites[slot] < positions.size():
			bound[positions[sites[slot]]] = nodes[slot]
	return bound


## How far above the prop's base its leaves are emitted, or -1.0 when no slot is serving it.
func _leaf_height(bound: Dictionary, where: Vector3) -> float:
	for site: Vector3 in bound:
		if site.distance_to(where) >= 0.5:
			continue
		var leaves := (bound[site] as Node3D).get_node_or_null(^"Leaves") as GPUParticles3D
		if leaves == null:
			return -1.0
		return leaves.position.y
	return -1.0


func _leaves_emitting() -> bool:
	var sites: PackedInt32Array = _vfx.call(&"slot_sites", AssetVfx.Emitter.LEAF_FALL)
	var nodes: Array[Node3D] = _vfx.call(&"effect_nodes", AssetVfx.Emitter.LEAF_FALL)
	for slot: int in mini(sites.size(), nodes.size()):
		if sites[slot] < 0:
			continue
		var leaves := nodes[slot].get_node_or_null(^"Leaves") as GPUParticles3D
		if leaves != null and leaves.emitting:
			return true
	return false


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
