extends CanvasLayer

## F-543 — the Forager's fourth promise: DESIGN.md §4.5 says a Forager "sees resources through
## terrain", and until this file nothing in the game did.
##
## The other three Forager lines (gather yield, gather speed, food) are `PowerupService` stat
## modifiers, so they ship as data over the F-543 wiring. This one is not a number — it is a sense,
## and a sense needs a presentation system. That is what this is: a screen-space marker over every
## nearby `&"harvestable"`, drawn with no occlusion test at all, so a bogsilver node behind a ridge
## reads as a diamond on the ridge rather than as nothing.
##
## ## NETWORK AUTHORITY: none (docs/ARCHITECTURE.md §2.2, "VFX, audio, camera, UI" row)
##
## Client-local presentation, end to end. Every input is something this peer already holds:
## `AttunementService.local_selection()` (broadcast to everyone by design — §4.5's whole point is
## that the party can see who plays what), the `&"harvestable"` group in this peer's own scene tree,
## and its own camera. Nothing is sent, nothing is mutated, no protocol bump.
##
## ## Why a marker and not an X-ray silhouette
##
## The obvious reading of "sees through terrain" is a depth-test-off outline shader on the prop
## itself. Rejected for two reasons, neither of them effort:
##
##   1. **It would have to be per-material.** The harvestable catalogue is dozens of exported `.glb`
##      models sharing no single surface material, so a see-through pass means either a second
##      material on every mesh instance at runtime (a per-prop cost on the exact node count
##      `docs/PERFORMANCE.md` is most careful about) or authoring a variant of every model.
##   2. **A silhouette through a hill reads as a bug.** A tree drawn solid through solid rock looks
##      like broken depth sorting. A marker floating where the tree is reads as *knowledge* — which
##      is what the Attunement grants. Muck's ore pings and Valheim's wishbone both make the same
##      call.
##
## ## Cost (F-099, and docs/PERFORMANCE.md's low-end target)
##
## Nothing here runs at all unless the local player is a Forager: `_process` is disabled outright
## otherwise, off `AttunementService.selection_changed`, so on five of every six runs this autoload
## is an idle node. When it IS active, the group scan and the range filter run at `REFRESH_SEC`
## (5 Hz — a harvestable does not move), and only `unproject_position` per surviving marker runs per
## frame. There is no occlusion ray anywhere in this file, which makes it strictly cheaper than
## `ui/hud/target_health_hud.gd`, the file it is otherwise shaped after.

const MIRE_THEME := preload("res://ui/theme/mire_theme.gd")

const HARVESTABLE_GROUP: StringName = &"harvestable"
const BLOCKING_UI_GROUP: StringName = &"blocks_gameplay_input"
const FORAGER_ID: StringName = &"forager"

## How far the sense reaches. Deliberately further than `TargetHealthHud.MAX_RANGE_M` (38 m): this is
## a navigation aid — "there is bogsilver over that hill" — not a combat readout, and a radius that
## only covered what you can already see would grant nothing.
const RANGE_M: float = 60.0
## Past this a marker fades toward `ALPHA_FAR`, so the near ones stay readable in a dense wood.
const FADE_START_M: float = 28.0
const ALPHA_FAR: float = 0.34
## Nearest-first cap. A birch grove can hold a hundred props and a screen of a hundred diamonds is
## not a sense, it is fog.
const MAX_MARKERS: int = 24

const REFRESH_SEC: float = 0.2

## Marker geometry in screen pixels, before `MireTheme.ui_scale()`. Shrinks with distance for the
## same reason the enemy bars do — it has to read as belonging to a thing out there.
const SIZE_NEAR_PX: float = 13.0
const SIZE_FAR_PX: float = 6.0
const OUTLINE_PX: float = 1.5

## `MireTheme.MOSS`, the palette's growing-things green — the Forager's own colour, and deliberately
## not `AMBER` (the interaction prompt) or `MIRE` (corruption), so a marker is never mistaken for
## either. Depleted props are drawn `MUTED` instead: still worth knowing about, since they respawn.
const COLOUR_READY := MIRE_THEME.MOSS
const COLOUR_SPENT := MIRE_THEME.MUTED
const COLOUR_OUTLINE := Color(0.02, 0.03, 0.02, 0.85)

## Layer 3, alongside the enemy bars and under `focus_prompt.gd` (4) — a world-anchored hint must
## never sit over a panel or the crosshair prompt.
const CANVAS_LAYER: int = 3


## One drawn marker. Rebuilt at `REFRESH_SEC`, re-projected every frame. Fields only, same reason
## `TargetHealthHud.Bar` is: an inner class does not share the outer script's constant scope.
class Marker:
	extends RefCounted

	var node: Node3D
	var anchor: Vector3
	var distance: float = 0.0
	var ready: bool = true
	var screen_position := Vector2.ZERO
	var size: float = 0.0
	var alpha: float = 1.0
	var on_screen: bool = false


class MarkerCanvas:
	extends Control

	var hud: Node

	func _draw() -> void:
		if hud != null and is_instance_valid(hud):
			hud.call(&"_draw_markers", self)


var _canvas: MarkerCanvas
var _markers: Array[Marker] = []
var _refresh_elapsed: float = 0.0
var _attunement_node: Node


func _ready() -> void:
	layer = CANVAS_LAYER
	_canvas = MarkerCanvas.new()
	_canvas.hud = self
	_canvas.name = "ForagerSenseMarkers"
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_canvas)

	# F-277's lesson, applied ahead of time: a selection is RUN-scoped, so this has to follow the
	# signal rather than read the answer once. `selection_changed` fires for every peer, including on
	# the clear a run restart broadcasts, and `_refresh_active()` re-asks about the LOCAL one.
	var attunements: Node = _attunements()
	if attunements != null and attunements.has_signal(&"selection_changed"):
		attunements.connect(&"selection_changed", _on_selection_changed)
	_refresh_active()


func _process(delta: float) -> void:
	_refresh_elapsed += delta
	if _refresh_elapsed >= REFRESH_SEC:
		_refresh_elapsed = 0.0
		_rebuild_markers()
	_project_markers()
	_canvas.queue_redraw()


## Whether the sense is live for this peer. Public so the check reads the state rather than the
## pixels, and so a future "sense" powerup could ask the same question.
func sense_active() -> bool:
	var attunements: Node = _attunements()
	if attunements == null:
		return false
	return StringName(attunements.call(&"local_selection")) == FORAGER_ID


## What is currently drawn. The check reads this.
func tracked_markers() -> Array[Marker]:
	return _markers


## Force one full rebuild + projection now, for a check that must not wait out `REFRESH_SEC`.
func refresh_now() -> void:
	_refresh_elapsed = 0.0
	_rebuild_markers()
	_project_markers()
	if _canvas != null:
		_canvas.queue_redraw()


func _on_selection_changed(_peer_id: int, _attunement_id: StringName) -> void:
	_refresh_active()


## The whole cost gate. A non-Forager peer processes nothing and draws nothing.
func _refresh_active() -> void:
	var active: bool = sense_active()
	set_process(active)
	if not active:
		_markers.clear()
		if _canvas != null:
			_canvas.queue_redraw()
		return
	refresh_now()


# ── Drawing ──────────────────────────────────────────────────────────────────────────────────────


## A diamond, not a circle or a box: at 8 px a rotated square is the most distinguishable shape
## against foliage, and it is not the shape anything else in this HUD uses.
func _draw_markers(canvas: Control) -> void:
	for marker: Marker in _markers:
		if not marker.on_screen:
			continue
		var half: float = marker.size * 0.5
		var points := PackedVector2Array([
			marker.screen_position + Vector2(0.0, -half),
			marker.screen_position + Vector2(half, 0.0),
			marker.screen_position + Vector2(0.0, half),
			marker.screen_position + Vector2(-half, 0.0),
		])
		var fill: Color = COLOUR_READY if marker.ready else COLOUR_SPENT
		fill.a *= marker.alpha
		var outline: Color = COLOUR_OUTLINE
		outline.a *= marker.alpha
		canvas.draw_colored_polygon(points, fill)
		canvas.draw_polyline(
			points + PackedVector2Array([points[0]]),
			outline,
			OUTLINE_PX * MIRE_THEME.ui_scale()
		)


func _marker_size(distance: float) -> float:
	return lerpf(
		SIZE_NEAR_PX, SIZE_FAR_PX, clampf(distance / RANGE_M, 0.0, 1.0)
	) * MIRE_THEME.ui_scale()


# ── Selection ────────────────────────────────────────────────────────────────────────────────────


func _rebuild_markers() -> void:
	_markers.clear()
	if _blocking_ui_open():
		return
	var camera: Camera3D = _camera()
	if camera == null:
		return
	var origin: Vector3 = camera.global_position

	var candidates: Array[Marker] = []
	for node: Node in get_tree().get_nodes_in_group(HARVESTABLE_GROUP):
		var prop := node as Node3D
		if prop == null or not is_instance_valid(prop) or not prop.is_inside_tree():
			continue
		var anchor: Vector3 = prop.global_position + Vector3.UP * _anchor_height(prop)
		var distance: float = origin.distance_to(anchor)
		if distance > RANGE_M:
			continue
		var marker := Marker.new()
		marker.node = prop
		marker.anchor = anchor
		marker.distance = distance
		# `active` is the replicated "not yet harvested" flag every peer already holds. A depleted
		# node still gets a marker, muted: it respawns, and knowing where the patch IS is most of
		# what the sense is for.
		# `get()` on a node without the property returns null, and `bool(null)` is a hard script
		# error that would abort the whole scan mid-loop — so an unknown prop is treated as ready
		# rather than trusted to be a real `Harvestable`.
		var active_flag: Variant = prop.get(&"active")
		marker.ready = active_flag == null or bool(active_flag)
		candidates.append(marker)

	candidates.sort_custom(func(a: Marker, b: Marker) -> bool: return a.distance < b.distance)
	for marker: Marker in candidates:
		if _markers.size() >= MAX_MARKERS:
			break
		_markers.append(marker)


## How far above the prop's origin the marker floats. `Harvestable` already measures its own model
## for the interaction anchor; reuse that rather than measuring the meshes again, and fall back to a
## fixed lift for anything that has not measured yet.
func _anchor_height(prop: Node3D) -> float:
	if prop.has_method(&"anchor_offset"):
		var measured: float = float(prop.call(&"anchor_offset"))
		if measured > 0.0:
			return measured
	return 1.2


# ── Projection ───────────────────────────────────────────────────────────────────────────────────


func _project_markers() -> void:
	var camera: Camera3D = _camera()
	if camera == null:
		for marker: Marker in _markers:
			marker.on_screen = false
		return
	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	for marker: Marker in _markers:
		if not is_instance_valid(marker.node) or not marker.node.is_inside_tree():
			marker.on_screen = false
			continue
		if camera.is_position_behind(marker.anchor):
			marker.on_screen = false
			continue
		marker.screen_position = camera.unproject_position(marker.anchor)
		marker.size = _marker_size(marker.distance)
		marker.alpha = 1.0 if marker.distance <= FADE_START_M else lerpf(
			1.0, ALPHA_FAR, clampf(
				(marker.distance - FADE_START_M) / maxf(RANGE_M - FADE_START_M, 0.001), 0.0, 1.0
			)
		)
		var margin: float = marker.size
		marker.on_screen = (
			marker.screen_position.x > -margin
			and marker.screen_position.y > -margin
			and marker.screen_position.x < viewport_size.x + margin
			and marker.screen_position.y < viewport_size.y + margin
		)


func _camera() -> Camera3D:
	var viewport: Viewport = get_viewport()
	return viewport.get_camera_3d() if viewport != null else null


## Path-resolved (F-011) and cached (F-099) — this is asked on every selection change and by
## `sense_active()`.
func _attunements() -> Node:
	if _attunement_node == null or not is_instance_valid(_attunement_node):
		_attunement_node = get_node_or_null(^"/root/AttunementService")
	return _attunement_node


## Same interlock every other world-anchored HUD here uses: while a cursor-owning panel is open the
## player is reading a menu, not the world.
func _blocking_ui_open() -> bool:
	return not get_tree().get_nodes_in_group(BLOCKING_UI_GROUP).is_empty()
