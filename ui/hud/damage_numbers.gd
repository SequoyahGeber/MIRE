extends CanvasLayer

## Floating damage indicators — the "-5" that peels off whatever you just hit (F-433).
##
## ## Why this exists
##
## Reported by Sequoyah, 2026-08-21: "damage indicators ex -5hp, -3hp". Combat already told you a
## swing connected (hit flash, impact sound, hitstop) but never how *much* it was worth, so a
## weapon upgrade, a powerup's damage bonus and a wrong-tool bounce were all indistinguishable from
## the outside. This draws the number the host actually applied, at the thing it was applied to.
##
## The one case worth as much as any of the others is **zero**: `Harvestable.host_apply_tool_damage()`
## deliberately reports a pickaxe bouncing off a pine as a hit that landed for 0, because the thunk
## is the feedback that tells you to switch tools. That comes through here as a muted "0" rather than
## being swallowed, which is the whole point of showing it.
##
## ## Where the numbers come from
##
## `CombatService.attack_landed` and `RangedCombatService.shot_landed`, both of which already carry
## `(peer_id, position, damage, target_name)` to **every** peer — the host resolves the hit and
## broadcasts the resolution, and each peer emits the signal locally from `_apply_resolution()` /
## `_apply_resolved()`. So this file needs no new RPC, no new event, and no protocol bump.
##
## Only the LOCAL peer's own hits are drawn. In a six-player fight on one enemy, six players' numbers
## over one husk is confetti, and the number you care about is the one that says whether *your*
## weapon is doing anything.
##
## ## NETWORK AUTHORITY: none (docs/ARCHITECTURE.md §2.2, "VFX, audio, camera, UI" row)
##
## Client-local presentation, reading a signal it does not emit and mutating nothing.

const MIRE_THEME := preload("res://ui/theme/mire_theme.gd")
## Preloaded by path rather than named as a global class, for the usual reason: a `class_name` is
## invisible to a headless `--script` run until the editor rescans the project (F-016).
const NET_CONFIG := preload("res://core/net/net_config.gd")

## Layer 3, with `ui/hud/target_health_hud.gd`: over the 3D viewport, under `focus_prompt.gd` (4) and
## every panel above it.
const CANVAS_LAYER: int = 3

const LIFETIME_SEC: float = 0.95
## How far the number climbs in WORLD space over its life. World space, not screen space, so a number
## stays pinned over the thing that took the hit while you strafe around it.
const RISE_M: float = 0.85
## Lifted off the target's origin, which sits at the feet of an enemy and the base of a prop.
const SPAWN_LIFT_M: float = 1.15
## Screen-space spread so three fast hits on one target do not stack into an unreadable smear.
## Cycled through a fixed table rather than randomised, so a check sees the same layout twice — and
## the table STARTS at zero, because the overwhelmingly common case is one number at a time and a
## lone "-5" sitting half a hand to the left of what you hit reads as a bug.
const SPREAD_PX: float = 26.0
const SPREAD_STEPS: Array[float] = [0.0, 0.6, -0.6, 1.15, -1.15]
## Oldest are dropped past this. A swing can only land once per weapon cooldown, so reaching it takes
## a deliberate crowd of arrows.
const MAX_ACTIVE: int = 24

## Fraction of the lifetime spent fully opaque before the fade starts.
const HOLD_FRACTION: float = 0.55
## The number pops slightly oversized and settles, which is what makes it read as an impact rather
## than as HUD text that faded in.
const POP_SCALE: float = 1.3
const POP_FRACTION: float = 0.16

const COLOUR_DAMAGE := Color(0.98, 0.90, 0.74, 1.0)
## A hit that did nothing: same event, deliberately quieter.
const COLOUR_BLOCKED := Color(0.62, 0.66, 0.62, 1.0)
const COLOUR_SHADOW := Color(0.02, 0.03, 0.02, 0.85)
const SHADOW_OFFSET_PX := Vector2(1.0, 1.0)

const FONT_SIZE_PX: int = 20

## Retry cadence for binding the combat autoloads. They are registered before this one, so the first
## attempt in `_ready()` normally takes; the retry covers a headless `--script` scenario that adds
## this HUD to a bare tree before the services exist.
const BIND_RETRY_SEC: float = 0.5


## One in-flight number. Fields only — an inner class does not share the outer script's scope.
class Indicator:
	extends RefCounted

	var origin: Vector3
	var text: String = ""
	var colour := Color.WHITE
	var spread: float = 0.0
	var elapsed: float = 0.0
	var screen_position := Vector2.ZERO
	var alpha: float = 1.0
	var scale: float = 1.0
	var on_screen: bool = false


## Draws the whole set in one pass; the drawing itself lives on the HUD so the palette stays in one
## scope. Same shape as `ui/hud/target_health_hud.gd`.
class NumberCanvas:
	extends Control

	var hud: Node

	func _draw() -> void:
		if hud != null and is_instance_valid(hud):
			hud.call(&"_draw_numbers", self)


var _canvas: NumberCanvas
var _active: Array[Indicator] = []
var _spread_index: int = 0
var _bind_elapsed: float = 0.0
var _bound: bool = false


func _ready() -> void:
	layer = CANVAS_LAYER
	_canvas = NumberCanvas.new()
	_canvas.hud = self
	_canvas.name = "DamageNumbers"
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_canvas)
	_bind_sources()
	set_process(true)


func _process(delta: float) -> void:
	if not _bound:
		_bind_elapsed += delta
		if _bind_elapsed >= BIND_RETRY_SEC:
			_bind_elapsed = 0.0
			_bind_sources()
	if _active.is_empty():
		return
	_advance(delta)
	_canvas.queue_redraw()


## What is currently in flight. The check reads this rather than the pixels.
func active_indicators() -> Array[Indicator]:
	return _active


## Spawn one directly. Public because both combat services route through it and because a check needs
## a way in that does not require a resolved swing.
func show_damage(world_position: Vector3, damage: int) -> void:
	var indicator := Indicator.new()
	indicator.origin = world_position + Vector3.UP * SPAWN_LIFT_M
	# `damage` is what the host APPLIED, so a wrong-tool bounce arrives as 0 and says so.
	indicator.text = "0" if damage <= 0 else "-%d" % damage
	indicator.colour = COLOUR_BLOCKED if damage <= 0 else COLOUR_DAMAGE
	indicator.spread = SPREAD_STEPS[_spread_index % SPREAD_STEPS.size()] * SPREAD_PX
	_spread_index += 1
	_active.append(indicator)
	while _active.size() > MAX_ACTIVE:
		_active.remove_at(0)
	_advance(0.0)
	if _canvas != null:
		_canvas.queue_redraw()


# ── Sources ──────────────────────────────────────────────────────────────────────────────────────


## Bound by path and by feature test, never as a bare autoload identifier: a `--script` run compiles
## this file outside the project's autoload list (standing rule 1, D-185's own note).
func _bind_sources() -> void:
	var melee: Node = get_node_or_null(^"/root/CombatService")
	var ranged: Node = get_node_or_null(^"/root/RangedCombatService")
	if melee == null or ranged == null:
		return
	if not melee.is_connected(&"attack_landed", _on_attack_landed):
		melee.connect(&"attack_landed", _on_attack_landed)
	if not ranged.is_connected(&"shot_landed", _on_attack_landed):
		ranged.connect(&"shot_landed", _on_attack_landed)
	_bound = true


## Both signals carry the identical `(peer_id, position, damage, target_name)` shape, so melee and
## ranged share one handler. `target_name` is unused: the number is drawn where the hit happened, and
## naming the target is `focus_prompt.gd`'s job.
func _on_attack_landed(
	peer_id: int, position: Vector3, damage: int, _target_name: StringName
) -> void:
	if peer_id != _local_peer_id():
		return
	show_damage(position, damage)


func _local_peer_id() -> int:
	var transport: Node = get_node_or_null(^"/root/NetTransport")
	if transport == null or not bool(transport.call(&"is_active")):
		return NET_CONFIG.HOST_PEER_ID
	return int(transport.call(&"local_peer_id"))


# ── Motion ───────────────────────────────────────────────────────────────────────────────────────


func _advance(delta: float) -> void:
	var camera: Camera3D = _camera()
	var viewport_size := Vector2.ZERO
	var viewport: Viewport = get_viewport()
	if viewport != null:
		viewport_size = viewport.get_visible_rect().size

	var index: int = _active.size() - 1
	while index >= 0:
		var indicator: Indicator = _active[index]
		indicator.elapsed += delta
		if indicator.elapsed >= LIFETIME_SEC:
			_active.remove_at(index)
			index -= 1
			continue

		var t: float = clampf(indicator.elapsed / LIFETIME_SEC, 0.0, 1.0)
		# Eased rise: most of the climb happens early, so the number reads as thrown off the impact.
		var world: Vector3 = indicator.origin + Vector3.UP * (RISE_M * sqrt(t))
		indicator.alpha = 1.0 if t <= HOLD_FRACTION else 1.0 - (t - HOLD_FRACTION) / (
			1.0 - HOLD_FRACTION
		)
		indicator.scale = lerpf(POP_SCALE, 1.0, clampf(t / POP_FRACTION, 0.0, 1.0))

		if camera == null or camera.is_position_behind(world):
			indicator.on_screen = false
		else:
			indicator.screen_position = camera.unproject_position(world) + Vector2(
				indicator.spread, 0.0
			)
			indicator.on_screen = (
				viewport_size == Vector2.ZERO
				or Rect2(Vector2.ZERO, viewport_size).grow(96.0).has_point(
					indicator.screen_position
				)
			)
		index -= 1


func _draw_numbers(canvas: Control) -> void:
	var font: Font = ThemeDB.fallback_font
	if font == null:
		return
	for indicator: Indicator in _active:
		if not indicator.on_screen:
			continue
		var size: int = maxi(
			int(round(float(FONT_SIZE_PX) * indicator.scale * MIRE_THEME.ui_scale())), 1
		)
		var width: float = font.get_string_size(
			indicator.text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, size
		).x
		var at := indicator.screen_position - Vector2(width * 0.5, 0.0)
		canvas.draw_string(
			font,
			at + SHADOW_OFFSET_PX,
			indicator.text,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1.0,
			size,
			Color(COLOUR_SHADOW, COLOUR_SHADOW.a * indicator.alpha)
		)
		canvas.draw_string(
			font,
			at,
			indicator.text,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1.0,
			size,
			Color(indicator.colour, indicator.colour.a * indicator.alpha)
		)


func _camera() -> Camera3D:
	var viewport: Viewport = get_viewport()
	return viewport.get_camera_3d() if viewport != null else null
