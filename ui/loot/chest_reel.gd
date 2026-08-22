extends Node3D

## The chest reveal. A slot machine, in the world, directly above the chest you just opened: icons
## whip past behind a coloured window, slow down, and land on what you actually got — then the
## window flashes its family colour and throws a burst of motes.
##
## Sequoyah's call, and the reason it is in the WORLD rather than in a panel: opening a chest used to
## freeze the player behind a modal list of ids (F-581), which is the least ceremonious possible
## reading of the loop's headline reward. Everyone standing around the chest sees this one; the
## opener also gets the HUD half (`ui/hud/pickup_hud.gd`).
##
## ARCHITECTURE.md §2.2, "VFX, audio, camera, UI" row: **client-local, presentation only.** This node
## is built by `ui/loot/chest_ui.gd` on the opener's machine from the `granted` dictionary the host
## already decided. It rolls nothing, grants nothing, replicates nothing, and frees itself when the
## show is over. Nothing gameplay-facing may ever read it.

const MIRE_THEME := preload("res://ui/theme/mire_theme.gd")
const PICKUP_HUD := preload("res://ui/hud/pickup_hud.gd")

## How high above the chest's own origin the window floats. Chest-height plus a head, so it reads
## against the sky rather than against the lid.
const HEIGHT_M: float = 1.55
const WINDOW_SIZE_M: float = 0.62
const ICON_SIZE_M: float = 0.46

## The spin, in seconds, before the reel commits. Long enough to build an expectation, short enough
## that a player opening a row of caches is not waiting on an animation — the whole point of putting
## this in the world instead of a modal is that it never takes the game away from you.
const SPIN_SEC: float = 1.5
## First and last gaps between icon changes. Easing between them IS the slot machine: the ramp from
## a blur to a heartbeat is what makes the last frame feel like a decision.
const TICK_FAST_SEC: float = 0.045
const TICK_SLOW_SEC: float = 0.26
## How long the winning face sits there before it fades.
const HOLD_SEC: float = 1.6
const FADE_SEC: float = 0.5

## Scale of the "landed" punch on the window.
const POP_SCALE: float = 1.5
const POP_SEC: float = 0.35

const LIGHT_RANGE_M: float = 5.0
const LIGHT_ENERGY_SPIN: float = 1.6
const LIGHT_ENERGY_POP: float = 7.0

const PARTICLE_COUNT: int = 44
const PARTICLE_LIFETIME_SEC: float = 1.1


var _window: MeshInstance3D
var _window_material: StandardMaterial3D
var _icon: Sprite3D
var _light: OmniLight3D
var _burst: GPUParticles3D

## Every icon the reel may show while it spins, the winner included so it flickers past before it
## lands — a machine that never shows the prize until the end reads as a reveal, not a roll.
var _faces: Array[Texture2D] = []
var _face_tints: Array[Color] = []
var _final_icon: Texture2D
var _final_tint: Color = Color(0.894, 0.704, 0.286)

var _elapsed: float = 0.0
var _next_tick: float = 0.0
var _face_index: int = 0
var _settled: bool = false
var _settled_at: float = 0.0
## Local presentation randomness only. Never the loot roll — that happened on the host, in the
## chest's own seeded stream (F-210), long before this node existed.
var _rng := RandomNumberGenerator.new()

signal finished


## `granted` is the chest's own `{ id -> amount }`. Everything else is derived here: which entry is
## the headline, what it looks like, and what colour the whole show is.
func configure(granted: Dictionary) -> void:
	var headline: StringName = _headline_of(granted)
	var feed: Node = get_node_or_null(^"/root/PickupFeedService")
	var kind: StringName = &"item"
	if feed != null and headline != &"":
		kind = StringName(feed.call(&"kind_of", headline))
		_final_icon = feed.call(&"icon_of", kind, headline) as Texture2D
	_final_tint = _tint_for(kind, headline)
	_build_faces(headline)
	# `configure()` is called AFTER `add_child()` — it needs the tree to reach Registry and
	# PickupFeedService — so the nodes `_ready()` already built are still wearing the default tint at
	# this point. Re-dress them rather than requiring callers to configure a detached node.
	if is_node_ready():
		_show_face(0)
		_apply_tint(_final_tint)


func _ready() -> void:
	_rng.randomize()
	if _faces.is_empty():
		_build_faces(&"")
	_build_window()
	_build_icon()
	_build_light()
	_build_burst()
	_show_face(0)
	set_process(true)


func _process(delta: float) -> void:
	_elapsed += delta
	if not _settled:
		_spin(delta)
		return
	_after_settle()


## The whole slot-machine feel is this one curve: the gap between faces eases from a blur to a
## heartbeat, so the reel *decelerates* into its answer instead of stopping dead.
func _spin(_delta: float) -> void:
	if _elapsed >= SPIN_SEC:
		_settle()
		return
	if _elapsed < _next_tick:
		return
	var progress: float = clampf(_elapsed / SPIN_SEC, 0.0, 1.0)
	# Cubic ease-out on the INTERVAL, which is what a real reel's friction does to it.
	var gap: float = lerpf(TICK_FAST_SEC, TICK_SLOW_SEC, ease(progress, 0.35))
	_next_tick = _elapsed + gap
	_face_index = (_face_index + 1) % maxi(_faces.size(), 1)
	_show_face(_face_index)
	# One blip per face. The cheapest UI tick in the set — this fires a dozen times and must never
	# become the loudest thing in the clearing.
	_play_at(&"ui_hover")
	if _light != null:
		_light.light_energy = LIGHT_ENERGY_SPIN


func _settle() -> void:
	_settled = true
	_settled_at = _elapsed
	if _final_icon != null:
		_icon.texture = _final_icon
	_apply_tint(_final_tint)
	if _window != null:
		_window.scale = Vector3.ONE * POP_SCALE
	if _light != null:
		_light.light_energy = LIGHT_ENERGY_POP
	if _burst != null:
		_burst.restart()
		_burst.emitting = true
	# The pickup cue itself belongs to the HUD, on the peer that earned it. This is the machine's own
	# clunk — the reel committing, which everyone nearby should hear.
	_play_at(&"ui_confirm")


func _after_settle() -> void:
	var since: float = _elapsed - _settled_at
	var pop: float = clampf(since / (POP_SEC * MIRE_THEME.motion_scale()), 0.0, 1.0)
	if _window != null:
		_window.scale = Vector3.ONE * lerpf(POP_SCALE, 1.0, ease(pop, 0.3))
	if _light != null:
		_light.light_energy = lerpf(LIGHT_ENERGY_POP, LIGHT_ENERGY_SPIN, pop)
	if since < HOLD_SEC:
		return
	var fade: float = clampf((since - HOLD_SEC) / FADE_SEC, 0.0, 1.0)
	_apply_alpha(1.0 - fade)
	if _light != null:
		_light.light_energy = LIGHT_ENERGY_SPIN * (1.0 - fade)
	if fade >= 1.0:
		finished.emit()
		queue_free()


# ── What the reel shows ──────────────────────────────────────────────────────────────────────────


## The entry the reel lands on. A powerup always wins — it is the thing that changes the run, and
## §4.4 builds the whole chest economy around it. Otherwise the biggest pile, with coins deliberately
## last: "you got 40 coins" is a fine consolation, not a headline.
func _headline_of(granted: Dictionary) -> StringName:
	var feed: Node = get_node_or_null(^"/root/PickupFeedService")
	var best: StringName = &""
	var best_amount: int = -1
	var ids: Array[StringName] = []
	for id: StringName in granted:
		ids.append(id)
	# StringName's `<` compares interned identity, not string content — F-175. Sorting first makes
	# the tie-break deterministic, so the same haul always reveals the same face.
	ids.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))
	for id: StringName in ids:
		if feed != null and StringName(feed.call(&"kind_of", id)) == &"powerup":
			return id
		var amount: int = int(granted[id])
		if id == &"coins":
			amount = 0
		if amount > best_amount:
			best_amount = amount
			best = id
	return best


## Fills the spinning face list: a spread of real powerup icons from the registry, plus the winner.
## Powerups specifically, whatever the prize turns out to be — the reel is selling the possibility of
## a powerup, and a wheel of mushrooms and logs does not sell anything.
func _build_faces(headline: StringName) -> void:
	_faces.clear()
	_face_tints.clear()
	var registry: Node = get_node_or_null(^"/root/Registry")
	var pool: Array[StringName] = []
	if registry != null:
		var powerups: Variant = registry.get(&"powerups")
		if powerups is Dictionary:
			for id: StringName in powerups:
				if id != headline:
					pool.append(id)
	pool.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))

	var feed: Node = get_node_or_null(^"/root/PickupFeedService")
	# Nine faces is enough that the loop is not readable at speed, and few enough that the reel is
	# not holding a hundred textures resident for a second and a half.
	var wanted: int = 9
	while pool.size() > wanted:
		pool.remove_at(_rng.randi_range(0, pool.size() - 1))
	for id: StringName in pool:
		var icon: Texture2D = feed.call(&"icon_of", &"powerup", id) as Texture2D if feed != null else null
		if icon == null:
			continue
		_faces.append(icon)
		_face_tints.append(_tint_for(&"powerup", id))
	if _final_icon != null:
		_faces.append(_final_icon)
		_face_tints.append(_final_tint)
	# A registry with no powerup icons at all still has to spin something rather than crash: one
	# blank face, tinted, is a working (if dull) machine.
	if _faces.is_empty():
		_faces.append(null)
		_face_tints.append(_final_tint)


func _tint_for(kind: StringName, id: StringName) -> Color:
	if kind == &"powerup":
		var registry: Node = get_node_or_null(^"/root/Registry")
		var definition: Resource = registry.call(&"get_powerup", id) as Resource if registry != null else null
		var tags: Variant = definition.get(&"tags") if definition != null else null
		if tags is Array:
			for family: StringName in tags:
				# One palette for the whole powerup layer — the HUD flash, the icon row and this
				# reel all read the same table, so a Fire pickup is the same orange everywhere.
				if PICKUP_HUD.FAMILY_COLOURS.has(family):
					return PICKUP_HUD.FAMILY_COLOURS[family]
	if id == &"coins":
		return PICKUP_HUD.COIN_COLOUR
	return MIRE_THEME.AMBER


func _show_face(index: int) -> void:
	if _faces.is_empty():
		return
	var i: int = index % _faces.size()
	if _icon != null:
		_icon.texture = _faces[i]
	_apply_tint(_face_tints[i])


func _apply_tint(colour: Color) -> void:
	if _window_material != null:
		_window_material.albedo_color = Color(colour.r, colour.g, colour.b,
			_window_material.albedo_color.a)
		_window_material.emission = colour
	if _light != null:
		_light.light_color = colour
	if _burst != null:
		var material := _burst.process_material as ParticleProcessMaterial
		if material != null:
			material.color = colour


func _apply_alpha(alpha: float) -> void:
	if _window_material != null:
		_window_material.albedo_color.a = 0.55 * alpha
	if _icon != null:
		_icon.modulate.a = alpha


# ── Build ────────────────────────────────────────────────────────────────────────────────────────


## The coloured "window" the icon sits in: an unshaded, additive, billboarded quad. Unshaded because
## this is a UI affordance that happens to live in the world — a reveal that goes dim at night is a
## reveal nobody sees.
func _build_window() -> void:
	_window_material = StandardMaterial3D.new()
	_window_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_window_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_window_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_window_material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	# Additive glow must not write depth, or it punches a hole in whatever is drawn after it.
	_window_material.no_depth_test = false
	_window_material.disable_receive_shadows = true
	_window_material.albedo_color = Color(_final_tint.r, _final_tint.g, _final_tint.b, 0.55)
	_window_material.emission_enabled = true
	_window_material.emission = _final_tint
	_window_material.emission_energy_multiplier = 2.0

	var quad := QuadMesh.new()
	quad.size = Vector2(WINDOW_SIZE_M, WINDOW_SIZE_M)
	_window = MeshInstance3D.new()
	_window.name = "ReelWindow"
	_window.mesh = quad
	_window.material_override = _window_material
	_window.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_window.position.y = HEIGHT_M
	add_child(_window)


## The face itself. Same billboarded, unshaded, alpha-scissored sprite an `ItemDrop` uses, for the
## same reason: an icon is the one visual every item and powerup is guaranteed to author.
func _build_icon() -> void:
	_icon = Sprite3D.new()
	_icon.name = "ReelIcon"
	_icon.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_icon.shaded = false
	_icon.transparent = true
	_icon.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	_icon.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	# Drawn in front of the window quad, which sits at the same point in space.
	_icon.no_depth_test = true
	_icon.render_priority = 1
	_icon.position.y = HEIGHT_M
	add_child(_icon)


func _build_light() -> void:
	_light = OmniLight3D.new()
	_light.name = "ReelLight"
	_light.light_color = _final_tint
	_light.light_energy = LIGHT_ENERGY_SPIN
	_light.omni_range = LIGHT_RANGE_M
	# A reveal that costs a shadow map per chest is not worth it — this is a glow, not a lamp.
	_light.shadow_enabled = false
	_light.position.y = HEIGHT_M
	add_child(_light)


func _build_burst() -> void:
	var material := ParticleProcessMaterial.new()
	material.direction = Vector3(0.0, 1.0, 0.0)
	material.spread = 180.0
	material.initial_velocity_min = 1.2
	material.initial_velocity_max = 3.4
	material.gravity = Vector3(0.0, -2.2, 0.0)
	material.scale_min = 0.5
	material.scale_max = 1.4
	material.color = _final_tint

	var mesh := QuadMesh.new()
	mesh.size = Vector2(0.07, 0.07)
	var mote := StandardMaterial3D.new()
	mote.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mote.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mote.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mote.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mote.vertex_color_use_as_albedo = true
	mesh.material = mote

	_burst = GPUParticles3D.new()
	_burst.name = "ReelBurst"
	_burst.amount = PARTICLE_COUNT
	_burst.lifetime = PARTICLE_LIFETIME_SEC
	_burst.one_shot = true
	_burst.explosiveness = 1.0
	_burst.emitting = false
	_burst.process_material = material
	_burst.draw_pass_1 = mesh
	_burst.position.y = HEIGHT_M
	add_child(_burst)


func _play_at(cue: StringName) -> void:
	var sfx: Node = get_node_or_null(^"/root/SfxDirector")
	if sfx != null:
		sfx.call(&"play_at", cue, global_position + Vector3(0.0, HEIGHT_M, 0.0))
