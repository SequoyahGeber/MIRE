extends CanvasLayer

## F-599 — the one line that says what you are supposed to be doing.
##
## Sequoyah, after playing: *"in terms of the mire spreading and players have to keep it back its
## super unclear, id like the base objective to be pretty simple and make sure the whole thing
## actually does something."*
##
## The objective already IS simple — cap Wellsprings, hold the Mire back, leave or push on
## (`DESIGN.md` §4.1/§4.2). It is just never stated anywhere. There are 19 guide steps including
## `cap_wellspring`, but the guide is a tutorial that finishes; after it does, nothing on screen says
## what the run is for. This is the persistent version: two lines, always there, never explaining
## itself twice.
##
## ## Why a marker and a number rather than a map
##
## §4.1's promise is "the run's state is visible on the horizon; you never read a UI to know how you
## are doing" — and `docs/PRESSURE.md` measures why that fails today: the Mire front advances
## 1.66 m/min, so on an 1180 m island a two-hour session can pass without the horizon ever carrying
## the information. Until the corruption is fast enough to see, something has to say it. A **bearing
## and a distance** is the smallest thing that does, and it is the same shape a compass gives — it
## points you at the world rather than replacing it with a map, so the moment the horizon does start
## carrying the news, this stops being the thing you read.
##
## ## NETWORK AUTHORITY: none (docs/ARCHITECTURE.md §2.2, "VFX, audio, camera, UI" row)
##
## Client-local presentation from three things this peer already holds: the `wellspring` group in its
## own tree, `MireGrid.corruption_at()` on its own replicated grid, and its own camera. Nothing sent,
## nothing mutated.

const MireTheme := preload("res://ui/theme/mire_theme.gd")
## The island's own half-extent, from the same constant the terrain and the corruption grid derive
## from. Preloaded rather than read off `MireGrid`: `ISLAND_HALF_M` is a `const` on `MireGridSim`,
## and a `const` is not reachable through `Node.get()` — a mistake that would have silently fallen
## back to a hard-coded 590 and quietly mis-scaled the readout the day the island resizes.
const MireSim := preload("res://world/mire/mire_grid_sim.gd")
const WELLSPRING_GROUP: StringName = &"wellspring"

## Refresh cadence. The objective changes on the scale of minutes, so sampling it every frame would
## be pure waste — and `_sample_corruption()` walks a grid of points, which is the expensive half.
const REFRESH_SEC: float = 1.0

## How many points across the island the corruption readout samples. 24x24 = 576 `corruption_at()`
## calls once a second, against a 256x256 grid — enough for a percentage that moves smoothly and
## cheap enough to not care about.
const SAMPLE_STEPS: int = 24

## Above this the readout turns hostile. Not a threshold in any system — purely the point at which
## "how the run is going" stops being good news.
const CORRUPTION_ALARM: float = 0.35

const COLOUR_ALARM := Color(0.90, 0.35, 0.30, 1.0)

var _root: VBoxContainer
var _task: Label
var _bearing: Label
var _state: Label
var _mire: Node
var _elapsed: float = 0.0


func _ready() -> void:
	layer = 2
	process_mode = Node.PROCESS_MODE_PAUSABLE
	_mire = get_node_or_null(^"/root/MireGrid")

	_root = VBoxContainer.new()
	_root.name = "Objective"
	_root.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_root.offset_left = float(MireTheme.GRID * 3)
	_root.offset_top = float(MireTheme.GRID * 3)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_task = MireTheme.label("Cap the Wellsprings", MireTheme.BODY, MireTheme.TEXT)
	_bearing = MireTheme.label("", MireTheme.CAPTION, MireTheme.MUTED)
	_state = MireTheme.label("", MireTheme.CAPTION, MireTheme.MUTED)
	for row: Label in [_task, _bearing, _state]:
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_root.add_child(row)
	_root.visible = false


func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed < REFRESH_SEC:
		return
	_elapsed = 0.0
	refresh()


## Split out so a check can drive it without waiting a second of real time — the same seam
## `ChestPlacementService.refresh_current_scene()` and `AmmoHud.refresh()` expose.
func refresh() -> void:
	if _root == null:
		return
	var player: Node3D = _local_player()
	var wellsprings: Array[Node] = get_tree().get_nodes_in_group(WELLSPRING_GROUP)
	# Nothing to say in the front end, or on a map with no Wellsprings at all — better silent than
	# an objective the map cannot offer.
	if player == null or wellsprings.is_empty():
		_root.visible = false
		return
	_root.visible = true

	var target: Node3D = _nearest_uncapped(player, wellsprings)
	var capped: int = 0
	for node: Node in wellsprings:
		if bool((node as Node3D).get(&"capped")):
			capped += 1

	if target == null:
		# Every Wellspring on the island is capped. That is the win condition of the pushing-back
		# half of the loop, and it deserves to be said rather than leaving a stale bearing up.
		_task.text = "All Wellsprings capped"
		_bearing.text = "The Mire is losing ground — hold it, or leave"
	else:
		_task.text = "Cap the Wellsprings   %d / %d" % [capped, wellsprings.size()]
		var offset: Vector3 = target.global_position - player.global_position
		_bearing.text = "Nearest: %s  %d m" % [_compass(offset), int(roundf(offset.length()))]

	var corruption: float = _sample_corruption()
	_state.text = "Island corrupted: %d%%" % int(roundf(corruption * 100.0))
	_state.add_theme_color_override(&"font_color",
		COLOUR_ALARM if corruption >= CORRUPTION_ALARM else MireTheme.MUTED)


## The closest Wellspring that still needs capping, or null when they all have been.
func _nearest_uncapped(player: Node3D, wellsprings: Array[Node]) -> Node3D:
	var best: Node3D = null
	var best_distance_sq: float = INF
	for node: Node in wellsprings:
		var spring := node as Node3D
		if spring == null or bool(spring.get(&"capped")):
			continue
		var distance_sq: float = player.global_position.distance_squared_to(spring.global_position)
		if distance_sq < best_distance_sq:
			best_distance_sq = distance_sq
			best = spring
	return best


## Eight-point compass bearing. Deliberately not degrees: "NE" is a direction a person turns towards,
## and a heading in degrees is a number they would have to do arithmetic on.
static func _compass(offset: Vector3) -> String:
	# -Z is north, matching the convention the rest of the project uses for forward.
	var angle: float = atan2(offset.x, -offset.z)
	var index: int = posmod(roundi(angle / (PI / 4.0)), 8)
	return ["N", "NE", "E", "SE", "S", "SW", "W", "NW"][index]


## What fraction of the island is corrupted, sampled on a coarse grid.
##
## Deliberately measured rather than asked of `MireGrid` for a total: the grid is the host's, and a
## client holds a replicated copy quantised by `EMIT_QUANTUM`. Sampling `corruption_at()` gives every
## peer the same answer from whatever it actually holds, which is the honest number to show.
func _sample_corruption() -> float:
	if _mire == null:
		return 0.0
	var half: float = MireSim.ISLAND_HALF_M
	var inside: int = 0
	var corrupted: float = 0.0
	for ix: int in SAMPLE_STEPS:
		for iz: int in SAMPLE_STEPS:
			var x: float = lerpf(-half, half, float(ix) / float(SAMPLE_STEPS - 1))
			var z: float = lerpf(-half, half, float(iz) / float(SAMPLE_STEPS - 1))
			# Only count the disc, not the square around it — the corners are ocean and would
			# permanently drag the percentage down by the same fixed amount.
			if x * x + z * z > half * half:
				continue
			inside += 1
			corrupted += clampf(float(_mire.call(&"corruption_at", Vector3(x, 0.0, z))), 0.0, 1.0)
	return corrupted / float(maxi(inside, 1))


func _local_player() -> Node3D:
	for node: Node in get_tree().get_nodes_in_group(&"players"):
		var player := node as Node3D
		if player != null and player.is_multiplayer_authority():
			return player
	return null
