extends SceneTree

## Verifies the fauna art batch — FAUNA.md phase 2, D-218, F-596.
##
##   .agent/bin/agent godot --script tools/fauna_art_check.gd
##
## Holds the six ordinary species to the three things a batch like this actually
## gets wrong, none of which is visible by looking at one animal on its own:
##
##  1. **Scale against the player.** Not against each other. The chest batch is
##     being resized right now because a set of assets can agree perfectly among
##     themselves and still be collectively wrong next to the person looking at
##     them. `player_controller.gd` builds a 1.8 m capsule; every species declares
##     a height and this asserts the EXPORTED bounds against it, so the number in
##     the catalog cannot drift away from the geometry.
##  2. **The clip vocabulary.** D-218 fixes `idle-loop`/`walk-loop`/`flee`/`death`
##     identically across all six so an `AnimalDef` never needs per-species clip
##     names. One species quietly exporting `run` instead of `flee` fails as
##     silence at runtime — the def asks for a clip that is not there and the
##     animal simply never animates.
##  3. **The animals are distinguishable.** A batch built from one parameterised
##     quadruped is the failure mode that produced the rebuilt willow and apple
##     tree: generic shapes wearing species names. Asserted as a real spread of
##     proportion, because a deer and a hare that differ only in scale are the
##     same asset twice.
##
## Skips species that have not been built yet rather than failing on them, and
## says which — the six land one at a time, and a check that goes red for work
## that is merely not done yet trains people to ignore it.

const PLAYER_HEIGHT_M: float = 1.8

## Every species, its authored height in metres, and how far the export may sit
## from it. The tolerance is +-12%: tight enough that a doubled or halved animal
## fails immediately, loose enough that a tail carried at its real angle, or a
## raised head, does not.
const SPECIES: Dictionary = {
	&"songbird": 0.14,
	&"hare": 0.40,
	&"chicken": 0.42,
	&"boar": 0.90,
	&"deer": 1.78,
	&"cow": 1.45,
}
const HEIGHT_TOLERANCE: float = 0.12

## The names as GODOT SEES THEM, which is not what the exporter wrote. Blender
## exports the actions as `idle-loop`/`walk-loop`, and Godot's glTF importer treats
## the `-loop` suffix as an instruction rather than as part of the name: it strips
## it and sets the clip's loop mode. So the runtime vocabulary really is the four
## bare names D-218 promised `AnimalDef` — but only because the importer does that,
## and this asserts both halves so neither can change without the other noticing.
## How far apart two species must sit in (length/height, width/height) space to count as different
## shapes. 0.15 separates every pair the batch has built while still failing the boar/cow pair the
## single-ratio version passed by accident.
const SHAPE_GAP_MIN: float = 0.15
## Two animals this different in absolute height are different animals whatever their proportions —
## a hare and a cow owe the check no shape argument.
const SIZE_RATIO_DISTINCT: float = 1.4

const EXPECTED_CLIPS: Array[StringName] = [&"idle", &"walk", &"flee", &"death"]
## The two that must come back with loop mode actually set, not merely named.
const LOOPING_CLIPS: Array[StringName] = [&"idle", &"walk"]

var failures: int = 0
var built: Array[StringName] = []
var _profiles: Dictionary = {}


func _initialize() -> void:
	_run()


func _run() -> void:
	_check_catalog()
	_check_exports()
	_check_distinct_silhouettes()

	var missing: Array[String] = []
	for species: StringName in SPECIES:
		if not built.has(species):
			missing.append(String(species))
	if not missing.is_empty():
		print("\n  not built yet, skipped rather than failed: %s" % ", ".join(missing))

	print("\nFAUNA_ART_CHECK built=%d failures=%d" % [built.size(), failures])
	quit(0 if failures == 0 else 1)


func _check_catalog() -> void:
	print("== the kit catalog describes what is actually on disk ==")
	var path := "res://assets/fauna/catalog.json"
	if not FileAccess.file_exists(path):
		print("     no catalog yet — nothing built")
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	check(parsed is Dictionary, "assets/fauna/catalog.json is valid JSON")
	if not (parsed is Dictionary):
		return
	for row: Variant in (parsed as Dictionary).get("assets", []):
		var entry := row as Dictionary
		var species := StringName(entry.get("id", ""))
		check(SPECIES.has(species),
			"catalog id '%s' is one of the six the batch is for" % species)
		if not SPECIES.has(species):
			continue
		# The catalog's own height must match its own bounds — a row can be
		# rewritten by hand and this is what stops it lying about the geometry.
		var stated: float = float(entry.get("height_m", 0.0))
		var size: Array = entry.get("size_m", []) as Array
		if size.size() == 3:
			check(absf(stated - float(size[2])) < 0.001,
				"%s's stated height matches its own bounds (%.3f)" % [species, stated])
		var fraction: float = float(entry.get("player_fraction", 0.0))
		check(absf(fraction - stated / PLAYER_HEIGHT_M) < 0.01,
			"%s's player fraction is consistent with its height (%.3f)" % [species, fraction])
		_profiles[species] = entry


func _check_exports() -> void:
	print("\n== every built species: real scale against the player, and the four clips ==")
	for species: StringName in SPECIES:
		var path := "res://assets/fauna/exports/%s.glb" % species
		if not ResourceLoader.exists(path):
			continue
		built.append(species)
		var packed: PackedScene = load(path) as PackedScene
		check(packed != null, "%s.glb loads as a PackedScene" % species)
		if packed == null:
			continue
		var instance: Node = packed.instantiate()

		# Scale, measured off the GEOMETRY rather than read from the catalog —
		# the catalog is a claim, the mesh is the fact.
		var aabb: AABB = _visual_bounds(instance)
		var expected: float = float(SPECIES[species])
		var tolerance: float = expected * HEIGHT_TOLERANCE
		# The catalog is a CLAIM and the mesh is the fact, so they are compared
		# against each other rather than each against itself. The first version of
		# this check asserted the catalog's height against the catalog's own
		# bounds — which is trivially true however wrong both are, and it passed
		# happily while the row said 0.499 m for a 0.41 m bird.
		if _profiles.has(species):
			var claimed: float = float((_profiles[species] as Dictionary).get("height_m", 0.0))
			check(absf(claimed - aabb.size.y) <= 0.02,
				"%s's catalog row matches the exported geometry (%.3f claimed, %.3f measured)"
					% [species, claimed, aabb.size.y])
		check(absf(aabb.size.y - expected) <= tolerance,
			"%s stands %.2f m against the player's %.1f m — %.0f%% of them (%.2f m authored, +-%.0f%% allowed)"
				% [species, aabb.size.y, PLAYER_HEIGHT_M, aabb.size.y / PLAYER_HEIGHT_M * 100.0,
					expected, HEIGHT_TOLERANCE * 100.0])

		# Clips. A missing clip fails as silence at runtime, which is why this is
		# asserted by name rather than by count.
		var player: AnimationPlayer = _find_animation_player(instance)
		check(player != null, "%s carries an AnimationPlayer" % species)
		if player != null:
			var names: PackedStringArray = player.get_animation_list()
			for clip: StringName in EXPECTED_CLIPS:
				check(names.has(String(clip)),
					"%s has a '%s' clip (%s)" % [species, clip, names])
			for clip: StringName in EXPECTED_CLIPS:
				if not names.has(String(clip)):
					continue
				var animation: Animation = player.get_animation(String(clip))
				check(animation.length > 0.05,
					"%s's '%s' is a real clip, not an empty one (%.3f s)"
						% [species, clip, animation.length])
				if LOOPING_CLIPS.has(clip):
					# Proves the `-loop` suffix did its job. A clip that arrives
					# without loop mode plays once and freezes — an idle animal
					# that stops idling after two seconds and never moves again.
					check(animation.loop_mode != Animation.LOOP_NONE,
						"%s's '%s' came back with loop mode set, so the -loop suffix was honoured"
							% [species, clip])
					# And a cycle whose ends disagree drifts every loop, which
					# reads as a limp.
					check(_ends_match(animation),
						"%s's '%s' closes on the pose it opened with" % [species, clip])
				else:
					check(animation.loop_mode == Animation.LOOP_NONE,
						"%s's '%s' does NOT loop — a death that repeats is a resurrection"
							% [species, clip])
		instance.free()


func _check_distinct_silhouettes() -> void:
	print("\n== the six are different animals, not one shape at six scales ==")
	if _profiles.size() < 2:
		print("     fewer than two built — nothing to compare yet")
		return
	# Compared on a PROPORTION VECTOR — (length/height, width/height) — rather than on a single
	# length:height ratio, and with an absolute-size escape.
	#
	# The first version used length:height alone and it could not tell a boar from a cow: 1.61
	# against 1.59, while the two are plainly different animals — 0.90 m against 1.36 m, half the
	# mass, a front-heavy wedge against a rectangle. Width was what separated them (0.45 against
	# 1.01, the cow's horns being wider than its body), so one number was throwing away the axis
	# that carried the difference. A check that reports two distinct animals as the same asset is
	# a check that will eventually be silenced rather than believed.
	#
	# The size escape exists because proportion is the wrong question for some pairs. A hare and a
	# cow do not need different ratios to be different animals; one is knee-high and one is chest
	# height, and demanding a shape argument on top of that would be the check inventing work.
	var shapes: Dictionary = {}
	for species: StringName in _profiles:
		var size: Array = (_profiles[species] as Dictionary).get("size_m", []) as Array
		if size.size() != 3 or float(size[2]) <= 0.0:
			continue
		var height: float = float(size[2])
		shapes[species] = {
			"vector": Vector2(float(size[1]) / height, float(size[0]) / height),
			"height": height,
		}
	var names: Array = shapes.keys()
	for first: int in names.size():
		for second: int in range(first + 1, names.size()):
			var a: StringName = names[first]
			var b: StringName = names[second]
			var shape_a: Dictionary = shapes[a]
			var shape_b: Dictionary = shapes[b]
			var shape_gap: float = (shape_a["vector"] as Vector2).distance_to(shape_b["vector"] as Vector2)
			var tall: float = maxf(shape_a["height"], shape_b["height"])
			var short: float = minf(shape_a["height"], shape_b["height"])
			var size_ratio: float = tall / short
			check(shape_gap > SHAPE_GAP_MIN or size_ratio >= SIZE_RATIO_DISTINCT,
				"%s and %s are visibly different animals (shape gap %.2f, size ratio %.2fx — needs %.2f or %.2fx)"
					% [a, b, shape_gap, size_ratio, SHAPE_GAP_MIN, SIZE_RATIO_DISTINCT])


## Bounds of the visible mesh only. An armature's own bones are not geometry and
## a rest-position bone reaching past the mesh would inflate the measurement.
##
## Composed against the SCENE ROOT rather than read off each MeshInstance3D's own
## local transform. The first draft used the local one and undermeasured the
## chicken by 18% — the mesh sits under a Skeleton3D that carries a transform of
## its own, so the local box was in skeleton space and the check happily passed a
## number that disagreed with the catalog. A scale check that measures the wrong
## space is worse than no scale check, because it reports confidence.
func _visual_bounds(node: Node) -> AABB:
	var bounds := AABB()
	var started := false
	for child: Node in _walk(node):
		var mesh_instance := child as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null:
			continue
		var box: AABB = mesh_instance.mesh.get_aabb()
		box = _transform_to_root(mesh_instance, node) * box
		if not started:
			bounds = box
			started = true
		else:
			bounds = bounds.merge(box)
	return bounds


## A node's transform relative to `scene_root`, walked up the parent chain — the
## imported scene is not in the tree, so `global_transform` is not available.
func _transform_to_root(node: Node3D, scene_root: Node) -> Transform3D:
	var result := Transform3D.IDENTITY
	var current: Node = node
	while current != null and current != scene_root:
		if current is Node3D:
			result = (current as Node3D).transform * result
		current = current.get_parent()
	return result


func _find_animation_player(node: Node) -> AnimationPlayer:
	for child: Node in _walk(node):
		if child is AnimationPlayer:
			return child as AnimationPlayer
	return null


func _walk(node: Node) -> Array[Node]:
	var out: Array[Node] = [node]
	for child: Node in node.get_children():
		out.append_array(_walk(child))
	return out


## Whether a looping clip's first and last keyed values agree on every track.
## A cycle that does not close drifts a little every loop, which reads as a limp.
func _ends_match(animation: Animation) -> bool:
	for track: int in animation.get_track_count():
		var count: int = animation.track_get_key_count(track)
		if count < 2:
			continue
		var first: Variant = animation.track_get_key_value(track, 0)
		var last: Variant = animation.track_get_key_value(track, count - 1)
		if first is Quaternion and last is Quaternion:
			if absf((first as Quaternion).dot(last as Quaternion)) < 0.999:
				return false
		elif first is Vector3 and last is Vector3:
			if ((first as Vector3) - (last as Vector3)).length() > 0.002:
				return false
	return true


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)
