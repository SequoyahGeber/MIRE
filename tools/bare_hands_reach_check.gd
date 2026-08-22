extends SceneTree

## F-519 regression: bare hands must reach everything the look-at prompt offers them.
##
## `ui/hud/focus_prompt.gd` offers a harvestable at its definition's `request_range_m` (3.0 m for
## every bare-hands plant), while `CombatService._best_target()` reaches
## `weapon.range_m + HOST_RANGE_TOLERANCE_M`. When the unarmed WeaponDef was shorter than the
## prompt's promise, the HUD said "Gather Bush with Bare Hands" and the swing silently missed —
## the entry tier of the whole tool tree, since the starter axe wants `branch` + `fibre_bundle`.
##
## Runs against the real procedural world rather than a fixture, because the geometry that broke it
## is real: a scattered plant's origin sits at the player's feet, well below the eye the reach is
## measured from.

const SCENE_PATH: String = "res://levels/procedural_island.tscn"
## The distance the prompt can promise, minus a hand's width — a plant at exactly `request_range_m`
## is the edge case the mismatch lived on.
const PROMPT_RANGE_M: float = 3.0
const SAMPLE_DISTANCES: Array[float] = [0.6, 1.2, 1.8, 2.4]

var failures: int = 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed := load(SCENE_PATH) as PackedScene
	check(packed != null, "the procedural island loads")
	if packed == null:
		_finish()
		return
	var scene := packed.instantiate() as Node3D
	root.add_child(scene)
	current_scene = scene
	for _frame: int in 40:
		await process_frame
	await physics_frame

	var harvest_world: Node = root.get_node_or_null(^"HarvestWorld")
	var combat: Node = root.get_node_or_null(^"CombatService")
	check(harvest_world != null, "HarvestWorld autoload exists")
	check(combat != null, "CombatService autoload exists")
	if harvest_world == null or combat == null:
		_finish()
		return

	var unarmed: Resource = combat.get("unarmed") as Resource
	check(unarmed != null, "the unarmed fallback exists")
	if unarmed == null:
		_finish()
		return
	var reach: float = float(unarmed.get(&"range_m")) + float(combat.get_script().get("HOST_RANGE_TOLERANCE_M"))
	check(reach >= PROMPT_RANGE_M,
		"bare hands reach %.2f m, at least the %.1f m the prompt offers" % [reach, PROMPT_RANGE_M])

	var player: Node3D = _authoritative_player()
	check(player != null, "the level spawned a player to swing")
	if player == null:
		_finish()
		return

	# One live example per definition, so this covers whatever the seed happened to scatter.
	var by_definition: Dictionary[String, Node3D] = {}
	for value: Variant in harvest_world.call("wired_harvestables"):
		var node := value as Node3D
		if node == null or not is_instance_valid(node):
			continue
		var definition: Resource = node.get("definition") as Resource
		if definition == null:
			continue
		var id := String(definition.get(&"id"))
		if not by_definition.has(id):
			by_definition[id] = node

	var bare_hands_props: int = 0
	for id: String in by_definition:
		var target: Node3D = by_definition[id]
		var definition: Resource = target.get("definition") as Resource
		if int(definition.get(&"required_tool")) != 0:
			continue  # Needs a tool by design (F-113); the prompt says so and the swing agrees.
		bare_hands_props += 1
		var origin: Vector3 = target.global_position
		for distance: float in SAMPLE_DISTANCES:
			player.global_position = origin + Vector3(0.0, 0.0, distance)
			player.rotation.y = 0.0
			await process_frame
			check(combat.call("_best_target", player, unarmed) == target,
				"bare hands reach '%s' from %.1f m" % [id, distance])

		# And the whole loop, through the real request path, not just target selection.
		player.global_position = origin + Vector3(0.0, 0.0, 1.2)
		await process_frame
		var max_health: int = maxi(int(definition.get(&"max_health")), 1)
		var swings: int = 0
		while swings < max_health + 4 and bool(target.get("active")):
			if int(combat.call("request_attack")) > 0:
				swings += 1
			await process_frame
		check(not bool(target.get("active")),
			"bare hands actually harvest '%s' (%d swing(s) for %d health)"
				% [id, swings, max_health])

	check(bare_hands_props > 0, "the world scattered something bare hands are meant to gather")
	_finish()


func _authoritative_player() -> Node3D:
	for node: Node in root.get_tree().get_nodes_in_group(&"players"):
		var candidate := node as Node3D
		if candidate != null and candidate.is_multiplayer_authority():
			return candidate
	return null


func check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: %s" % label)
		return
	failures += 1
	printerr("FAIL: %s" % label)


func _finish() -> void:
	print("BARE_HANDS_REACH failures=%d" % failures)
	quit(1 if failures > 0 else 0)
