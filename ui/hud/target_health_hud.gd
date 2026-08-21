extends CanvasLayer

## Overhead health bars for ordinary enemies (F-433).
##
## ## Why this exists
##
## Reported by Sequoyah, 2026-08-21: "healthbars for enemies ... enemy healthbars should hover above
## their head". Before this, a swing on an enemy produced a hit flash, a sound and a chip of
## knockback, and *nothing* that said how close the thing was to dying. `Boss` has had a top-centre
## bar since task 5.5 (`ui/hud/boss_health_hud.gd`), but a boss is one enemy per island; the crawler
## chewing on your leg had no readout at all.
##
## The harvestable half of that same report — a progress bar next to the crosshair while you chop —
## is NOT here: F-431's `ui/hud/focus_prompt.gd` already draws exactly that bar in the prompt panel
## under the crosshair, off `Harvestable.health`, and hides it at full health so an untouched prop is
## not noise. Two panels drawing the same number at two screen offsets is the precise defect F-431
## was filed about, so this file stays off the crosshair entirely and owns only the world-anchored
## enemy bars. `ui/hud/damage_numbers.gd` owns the floating "-5" indicators for both kinds of target.
##
## ## NETWORK AUTHORITY: none (docs/ARCHITECTURE.md §2.2, "VFX, audio, camera, UI" row)
##
## Client-local presentation. Every number drawn is a value the peer already holds — `Enemy.health`
## and `Enemy.state` are replicated on-change through the enemy's own synchronizer, `max_health`
## comes off the shared `EnemyDef` resource — and nothing here mutates or sends anything. Same
## reasoning `boss_health_hud.gd` records, and for the same reason it needs no protocol bump.
##
## ## What gets a bar, and why not everything
##
## A generated island can hold a lot of enemies, and a screen of bars over every distant idle husk is
## noise that makes the one that matters harder to find. Three rules, any of which is enough:
##
## 1. it has been damaged (`health < max_health`) — you want to know how much further to go;
## 2. it is not IDLE — anything that has noticed you is a fight in progress;
## 3. it is inside `ALWAYS_RANGE_M` — close enough that you are about to swing at it.
##
## On top of that: living, in front of the camera, inside `MAX_RANGE_M`, not occluded by world
## geometry, and at most `MAX_BARS` of them, nearest first.
##
## ## Cost (F-099)
##
## The group scan, the range/rule filter and the occlusion rays run at `REFRESH_SEC` (10 Hz) and are
## capped at `MAX_BARS` rays. Only the projection — `unproject_position` per surviving bar — runs per
## frame, because a bar that lags the enemy under it by up to 100 ms reads as broken.

const MIRE_THEME := preload("res://ui/theme/mire_theme.gd")
## Preloaded by path, not referenced by `class_name`: a global class is invisible to a headless
## `--script` run until the editor rescans the project (standing rule, F-016).
const PLACEMENT_VALIDATOR := preload("res://systems/building/placement_validator.gd")

const ENEMY_GROUP: StringName = &"enemies"
const BOSS_GROUP: StringName = &"bosses"
const PLAYER_GROUP: StringName = &"players"
const BLOCKING_UI_GROUP: StringName = &"blocks_gameplay_input"

## `Enemy.State.IDLE`. Compared as an int rather than through the enum, because this file must not
## preload `enemy.gd` just to name one value — every enemy it reads is duck-typed through `get()`.
const STATE_IDLE: int = 0
const STATE_DEAD: int = 5

## Beyond this a bar is a smear of two pixels; inside this it always shows if the rules above pass.
const MAX_RANGE_M: float = 38.0
const ALWAYS_RANGE_M: float = 12.0
## Nearest-first cap. Also bounds the occlusion rays, which is the only per-refresh physics cost.
const MAX_BARS: int = 12
## How far above the top of the enemy's own geometry the bar floats. See `_head_height()`.
const HEAD_CLEARANCE_M: float = 0.34
## Bounds the one-time mesh walk that measures a model's height.
const MODEL_PART_CAP: int = 48

const REFRESH_SEC: float = 0.1

## Bar geometry in screen pixels, before `MireTheme.ui_scale()`. Width shrinks with distance so a bar
## reads as belonging to the thing under it rather than floating in the HUD plane.
const BAR_WIDTH_NEAR_PX: float = 68.0
const BAR_WIDTH_FAR_PX: float = 34.0
const BAR_HEIGHT_PX: float = 6.0
const BORDER_PX: float = 1.0
## Distance past which a bar is drawn at `ALPHA_FAR` rather than full strength.
const FADE_START_M: float = 22.0
const ALPHA_FAR: float = 0.45

const COLOUR_TRACK := Color(0.06, 0.08, 0.07, 0.85)
const COLOUR_BORDER := Color(0.02, 0.03, 0.02, 0.9)
const COLOUR_HEALTHY := Color(0.82, 0.24, 0.22, 1.0)
## What the fill turns into as the bar empties — the "nearly dead" tell, read at a glance in a fight.
const COLOUR_CRITICAL := Color(0.96, 0.72, 0.26, 1.0)

## Layer 3: under `focus_prompt.gd` (4) and every panel, over the 3D viewport. These bars are the
## least important thing on screen and must never sit on top of a prompt or a menu.
const CANVAS_LAYER: int = 3

## World-only ray mask, the same one `ranged_combat_service.gd` and `enemy.gd` use: layer 1 is the
## shared solid layer, TERRAIN_LAYER is the ground's own since F-075.
const WORLD_COLLISION_MASK: int = 1 | PLACEMENT_VALIDATOR.TERRAIN_LAYER


## One drawn bar. Rebuilt at `REFRESH_SEC`, re-projected every frame. Fields only — an inner class
## does not share the outer script's constant scope, so every value it needs is handed to it.
class Bar:
	extends RefCounted

	var node: Node3D
	var head: Vector3
	var fraction: float = 1.0
	var distance: float = 0.0
	var screen_position := Vector2.ZERO
	var width: float = 0.0
	var alpha: float = 1.0
	var on_screen: bool = false


## Draws the whole set in one pass. A Control per enemy would churn nodes every time a wave spawns;
## one `_draw()` over a small array does not. The drawing itself lives on the HUD (`_draw_bars()`),
## called back through here, so the palette and geometry constants stay in one scope.
class BarCanvas:
	extends Control

	var hud: Node

	func _draw() -> void:
		if hud != null and is_instance_valid(hud):
			hud.call(&"_draw_bars", self)


var _canvas: BarCanvas
var _bars: Array[Bar] = []
## Measured model height per `EnemyDef` instance id — see `_head_height()`.
var _model_height: Dictionary[int, float] = {}
var _refresh_elapsed: float = 0.0


func _ready() -> void:
	layer = CANVAS_LAYER
	_canvas = BarCanvas.new()
	_canvas.hud = self
	_canvas.name = "TargetHealthBars"
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_canvas)
	set_process(true)


func _process(delta: float) -> void:
	_refresh_elapsed += delta
	if _refresh_elapsed >= REFRESH_SEC:
		_refresh_elapsed = 0.0
		_rebuild_bars()
	_project_bars()
	_canvas.queue_redraw()


## What is currently drawn. The check reads this rather than the pixels.
func tracked_bars() -> Array[Bar]:
	return _bars


## Force one full rebuild + projection now, for a check that must not wait out `REFRESH_SEC`.
func refresh_now() -> void:
	_refresh_elapsed = 0.0
	_rebuild_bars()
	_project_bars()
	if _canvas != null:
		_canvas.queue_redraw()


# ── Drawing ──────────────────────────────────────────────────────────────────────────────────────


## Called from `BarCanvas._draw()`, so every `draw_*` here lands on that Control's canvas item.
func _draw_bars(canvas: Control) -> void:
	var height: float = _bar_height()
	for bar: Bar in _bars:
		if not bar.on_screen:
			continue
		var origin := Vector2(
			bar.screen_position.x - bar.width * 0.5, bar.screen_position.y - height * 0.5
		)
		canvas.draw_rect(
			Rect2(
				origin - Vector2(BORDER_PX, BORDER_PX),
				Vector2(bar.width + BORDER_PX * 2.0, height + BORDER_PX * 2.0)
			),
			Color(COLOUR_BORDER, COLOUR_BORDER.a * bar.alpha),
			true
		)
		canvas.draw_rect(
			Rect2(origin, Vector2(bar.width, height)),
			Color(COLOUR_TRACK, COLOUR_TRACK.a * bar.alpha),
			true
		)
		if bar.fraction <= 0.0:
			continue
		# Red while healthy, amber as it empties — the "one more swing" tell, readable without
		# reading a number.
		var fill: Color = COLOUR_CRITICAL.lerp(COLOUR_HEALTHY, clampf(bar.fraction, 0.0, 1.0))
		canvas.draw_rect(
			Rect2(origin, Vector2(bar.width * clampf(bar.fraction, 0.0, 1.0), height)),
			Color(fill, fill.a * bar.alpha),
			true
		)


## `MireTheme.ui_scale()` follows the accessibility setting, so these are functions, not constants.
func _bar_height() -> float:
	return BAR_HEIGHT_PX * MIRE_THEME.ui_scale()


func _bar_width(distance: float) -> float:
	return lerpf(
		BAR_WIDTH_NEAR_PX, BAR_WIDTH_FAR_PX, clampf(distance / MAX_RANGE_M, 0.0, 1.0)
	) * MIRE_THEME.ui_scale()


# ── Selection ────────────────────────────────────────────────────────────────────────────────────


func _rebuild_bars() -> void:
	_bars.clear()
	if _blocking_ui_open():
		return
	var camera: Camera3D = _camera()
	if camera == null:
		return

	var origin: Vector3 = camera.global_position
	var candidates: Array[Bar] = []
	var exclude: Array[RID] = _occlusion_exclusions()

	for node: Node in get_tree().get_nodes_in_group(ENEMY_GROUP):
		var enemy := node as Node3D
		if enemy == null or not is_instance_valid(enemy) or not enemy.is_inside_tree():
			continue
		# Bosses already have the top-centre bar task 5.5 built them; a second readout over the head
		# of the one enemy that already has one is the duplication this file exists to avoid.
		if enemy.is_in_group(BOSS_GROUP):
			continue
		var definition: Resource = enemy.get(&"definition") as Resource
		if definition == null:
			continue
		if int(enemy.get(&"state")) == STATE_DEAD:
			continue

		var max_health: int = maxi(int(definition.get(&"max_health")), 1)
		var health: int = clampi(int(enemy.get(&"health")), 0, max_health)
		var head: Vector3 = enemy.global_position + Vector3.UP * _head_height(enemy, definition)
		var distance: float = origin.distance_to(head)
		if distance > MAX_RANGE_M:
			continue
		if not _worth_showing(enemy, health, max_health, distance):
			continue

		var bar := Bar.new()
		bar.node = enemy
		bar.head = head
		bar.fraction = float(health) / float(max_health)
		bar.distance = distance
		candidates.append(bar)

	candidates.sort_custom(func(a: Bar, b: Bar) -> bool: return a.distance < b.distance)
	var space: PhysicsDirectSpaceState3D = _space_state(camera)
	for bar: Bar in candidates:
		if _bars.size() >= MAX_BARS:
			break
		if _occluded(space, origin, bar.head, exclude):
			continue
		_bars.append(bar)


## Rules 1-3 in the file header. `state` is the replicated int, so a client applies the same rule the
## host would without asking it anything.
func _worth_showing(enemy: Node3D, health: int, max_health: int, distance: float) -> bool:
	if health < max_health:
		return true
	if int(enemy.get(&"state")) != STATE_IDLE:
		return true
	return distance <= ALWAYS_RANGE_M


## How far above an enemy's origin its bar floats.
##
## Measured off the MODEL, not off `EnemyDef.height_m`. The capsule `Enemy._build_body()` builds is a
## movement volume and is routinely taller than the thing you can see — the crawler's is 0.9 m
## against a model barely half that — so trusting it parks the bar in empty sky a foot above the
## enemy's back, which reads as belonging to nothing. Cached per definition, because every crawler on
## the island is the same model and the walk is otherwise repeated per enemy per refresh (F-099).
func _head_height(enemy: Node3D, definition: Resource) -> float:
	var key: int = definition.get_instance_id()
	if _model_height.has(key):
		return _model_height[key] + HEAD_CLEARANCE_M

	var measured: float = _measure_model_height(enemy)
	if measured <= 0.0:
		# No mesh yet (a model still streaming, or a definition with none at all): fall back to the
		# capsule and do NOT cache it, so the real measurement still lands on a later refresh.
		var radius: float = maxf(float(definition.get(&"radius_m")), 0.05)
		return maxf(float(definition.get(&"height_m")), radius * 2.0) + HEAD_CLEARANCE_M
	_model_height[key] = measured
	return measured + HEAD_CLEARANCE_M


## Top of the enemy's own geometry, in metres above its origin. Bounded walk: a model with hundreds
## of parts is measured from the first `MODEL_PART_CAP` of them, same shape as
## `Harvestable._measure_anchor_offset()`.
func _measure_model_height(enemy: Node3D) -> float:
	var top: float = 0.0
	var seen: int = 0
	var to_local: Transform3D = enemy.global_transform.affine_inverse()
	for node: Node in enemy.find_children("*", "MeshInstance3D", true, false):
		if seen >= MODEL_PART_CAP:
			break
		var mesh_instance := node as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null or not mesh_instance.is_inside_tree():
			continue
		seen += 1
		var bounds: AABB = to_local * mesh_instance.global_transform * mesh_instance.mesh.get_aabb()
		top = maxf(top, bounds.position.y + bounds.size.y)
	return top


func _occlusion_exclusions() -> Array[RID]:
	var rids: Array[RID] = []
	for group: StringName in [ENEMY_GROUP, PLAYER_GROUP]:
		for node: Node in get_tree().get_nodes_in_group(group):
			var body := node as CollisionObject3D
			if body != null and body.is_inside_tree():
				rids.append(body.get_rid())
	return rids


## Null in a `--script` run whose scenario never built a physics world; the caller then draws every
## bar, which is the right failure for a check that is testing selection, not walls.
func _space_state(camera: Camera3D) -> PhysicsDirectSpaceState3D:
	var world: World3D = camera.get_world_3d()
	return world.direct_space_state if world != null else null


func _occluded(
	space: PhysicsDirectSpaceState3D, origin: Vector3, head: Vector3, exclude: Array[RID]
) -> bool:
	if space == null:
		return false
	var query := PhysicsRayQueryParameters3D.create(origin, head, WORLD_COLLISION_MASK)
	query.exclude = exclude
	return not space.intersect_ray(query).is_empty()


# ── Projection ───────────────────────────────────────────────────────────────────────────────────


func _project_bars() -> void:
	var camera: Camera3D = _camera()
	if camera == null:
		for bar: Bar in _bars:
			bar.on_screen = false
		return
	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	for bar: Bar in _bars:
		if not is_instance_valid(bar.node) or not bar.node.is_inside_tree():
			bar.on_screen = false
			continue
		# Re-read the position every frame: at 10 Hz refresh the head moves a metre between
		# rebuilds, and a bar that trails its enemy is worse than no bar.
		var definition: Resource = bar.node.get(&"definition") as Resource
		if definition != null:
			bar.head = bar.node.global_position + Vector3.UP * _head_height(bar.node, definition)
		if camera.is_position_behind(bar.head):
			bar.on_screen = false
			continue
		bar.screen_position = camera.unproject_position(bar.head)
		bar.width = _bar_width(bar.distance)
		bar.alpha = 1.0 if bar.distance <= FADE_START_M else lerpf(
			1.0, ALPHA_FAR, clampf(
				(bar.distance - FADE_START_M) / maxf(MAX_RANGE_M - FADE_START_M, 0.001), 0.0, 1.0
			)
		)
		var margin: float = bar.width
		bar.on_screen = (
			bar.screen_position.x > -margin
			and bar.screen_position.y > -margin
			and bar.screen_position.x < viewport_size.x + margin
			and bar.screen_position.y < viewport_size.y + margin
		)


func _camera() -> Camera3D:
	var viewport: Viewport = get_viewport()
	return viewport.get_camera_3d() if viewport != null else null


## D-032's interlock in spirit: while a cursor-owning panel is open the player is not fighting, and
## `focus_prompt.gd` hides its crosshair for the same reason.
func _blocking_ui_open() -> bool:
	return not get_tree().get_nodes_in_group(BLOCKING_UI_GROUP).is_empty()
