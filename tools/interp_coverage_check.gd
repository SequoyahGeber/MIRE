extends SceneTree

## F-004's tripwire: every entity that puts a TRANSFORM on the wire must be smoothed by NetInterp.
##
##   .agent/bin/agent godot --script tools/interp_coverage_check.gd
##
## F-004 asked whether props needed interpolation alongside players and enemies. They do not, and the
## reason is structural rather than a judgement call: a `Harvestable` replicates `health`,
## `visual_state` and `active`; a `Chest` replicates `opened`. Neither puts a position or a rotation
## on the wire at all, so there is nothing for an interpolator to interpolate — and a discrete
## ON_CHANGE state swap is a thing you would want to *snap*, not blend, since a half-swapped mesh is
## a worse artefact than the swap it smoothed. See D-043.
##
## That makes the real rule "does it replicate a transform", not "is it a prop" — and a rule nobody
## can trip over is a rule that gets forgotten the first time someone adds a moving barrel. So this
## check finds every `SceneReplicationConfig` in the project, sorts them by whether they replicate a
## transform, and fails if that set ever changes.
##
## It is deliberately a SOURCE-TEXT check, not a runtime one. The runtime proofs already exist and
## are better at their job — `tools/interp_check.gd` measures the actual smoothing (67% of frames
## motionless without it, 1.5% with, D-026) and `tools/enemy_net_check.gd` asserts a real client's
## enemy is smoothed over real ENet. What no runtime check can do is notice an entity that nobody
## wired up, because an unwired entity has no test to fail. Reading the source is how you catch the
## thing that was never added.

## Paths that mean "this entity moves under host authority and a client sees it move".
const TRANSFORM_MARKERS: Array[String] = [
	".:position", ".:transform", ".:rotation", ".:global_position", ".:global_transform",
	".:quaternion", ".:basis",
]

## The transform-replicating entities we know about, and how each one is smoothed. Adding to this
## list is part of shipping a new moving entity — not a formality: if it is not smoothed, every
## client watching it sees it judder at the replication rate.
const SMOOTHED: Dictionary = {
	"res://entities/player/player_controller.gd":
		"NetInterp attaches centrally, off PlayerNet.player_spawned (autoload/net_interp.gd)",
	"res://systems/enemies/enemy.gd":
		"attaches itself in _ready() when it does not own simulation (enemy.gd:112)",
	"res://systems/hauling/haulable.gd":
		"attaches itself in _ready() when it does not own simulation, same shape as enemy.gd "
		+ "(task 3.10)",
}

## Transform-replicating scripts that deliberately go unsmoothed, and why. An entry here is a claim
## that no player ever WATCHES this thing move — which is the only reason smoothing can be skipped.
const EXEMPT: Dictionary = {
	"res://core/net/dummy_replicant.gd":
		"spike fixture for R1 (task 1.9), consumed only by tools/bench_replication.gd and "
		+ "tools/synced_group_check.gd. Its own header says it is not the real entity base "
		+ "class. Nobody watches it, and smoothing it would move the very numbers it exists "
		+ "to produce.",
}

## Directories with no shipped entities in them. tools/ builds throwaway replicants inside harnesses,
## and addons/ is third-party.
const SKIP_DIRS: Array[String] = ["res://addons", "res://tools", "res://.godot"]

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var moving: Array[String] = []
	var still: Array[String] = []
	for path: String in _scripts_building_a_replication_config():
		var source: String = FileAccess.get_file_as_string(path)
		if _replicates_a_transform(source):
			moving.append(path)
		else:
			still.append(path)
	moving.sort()
	still.sort()

	print("== entities that replicate a transform ==")
	for path: String in moving:
		if EXEMPT.has(path):
			check(true, "%s is exempt — %s" % [path, String(EXEMPT[path])])
			continue
		var how: String = String(SMOOTHED.get(path, ""))
		check(not how.is_empty(), "%s is smoothed — %s" % [
			path, how if not how.is_empty() else
			"NOTHING SMOOTHS IT. A client will watch it judder at the replication rate. Attach "
			+ "NetInterp (D-043) and add it to SMOOTHED, or justify it in EXEMPT."
		])

	print("\n== entities that replicate no transform, and so need no interpolation ==")
	for path: String in still:
		check(not SMOOTHED.has(path),
			"%s replicates state only — an interpolator would have nothing to act on" % path)

	print("\n== the rule has not quietly changed ==")
	check(not moving.is_empty(), "at least one entity still replicates a transform (%d)" % moving.size())
	check(not still.is_empty(), "at least one entity still replicates state only (%d)" % still.size())
	for path: String in SMOOTHED:
		check(moving.has(path),
			"%s is listed as smoothed and still replicates a transform" % path)
	for path: String in EXEMPT:
		check(moving.has(path),
			"%s is listed as exempt and still replicates a transform" % path)

	print("\nINTERP_COVERAGE_CHECK moving=%d still=%d failures=%d" % [
		moving.size(), still.size(), failures])
	quit(0 if failures == 0 else 1)


func _replicates_a_transform(source: String) -> bool:
	for marker: String in TRANSFORM_MARKERS:
		if source.contains(marker):
			return true
	return false


## Every shipped .gd that builds its own SceneReplicationConfig. That call is the one thing an entity
## cannot skip and still be replicated, which is what makes it a reliable place to look.
func _scripts_building_a_replication_config() -> Array[String]:
	var found: Array[String] = []
	_walk("res://", found)
	found.sort()
	return found


func _walk(dir_path: String, found: Array[String]) -> void:
	for skip: String in SKIP_DIRS:
		if dir_path.begins_with(skip):
			return
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if entry.begins_with("."):
			entry = dir.get_next()
			continue
		var full: String = dir_path.path_join(entry)
		if dir.current_is_dir():
			_walk(full, found)
		elif entry.ends_with(".gd"):
			var source: String = FileAccess.get_file_as_string(full)
			if source.contains("SceneReplicationConfig.new()"):
				found.append(full)
		entry = dir.get_next()
	dir.list_dir_end()


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)
