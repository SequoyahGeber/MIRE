extends CanvasLayer

## Everything the player sees when they GET something. One HUD, three surfaces, one input signal:
##
##   · bottom-left — a running feed of short "+3 Mushroom" lines, one per received item or powerup,
##     from any source (ground drop, chest, anything that ever calls `PickupFeedService`).
##   · top-left    — the row of powerup icons this run has given you, with stack counts. The run's
##     build, always on screen, so the Resonance economy (3+ of a family) can be played on purpose.
##   · centre      — the powerup ceremony: a family-tinted screen flash and a named card, because a
##     powerup is the one pickup that changes the run rather than filling a slot.
##
## Built in code for the same reason `vitals_hud.gd` and `guide_hud.gd` are: an always-on HUD has
## nowhere safe to live in a hand-authored scene without an exact claim on it (D-031), and an
## autoload needs none.
##
## ARCHITECTURE.md §2.2, "VFX, audio, camera, UI" row: client-local only. This node reads
## `PickupFeedService.pickup_received` (which only ever fires on the peer that earned the pickup) and
## `PowerupService.local_powerups_changed`, and draws them. It never sends anything, never takes
## input, never takes the cursor and is never in `blocks_gameplay_input` — receiving loot must not be
## able to interrupt a fight.

const MIRE_THEME := preload("res://ui/theme/mire_theme.gd")
const POWERUP_DEF := preload("res://systems/powerups/powerup_def.gd")

## Above `GuideHud` (5) so a pickup line is never buried by the objective card, far below `ChestUI`
## (52) and the menus.
const LAYER: int = 6

## Bottom-left, stacked upward, clear of `GuideHud`'s objective line at -132 and of the hotbar.
const FEED_MARGIN := Vector2(24.0, -186.0)
const FEED_WIDTH_PX: float = 320.0
const FEED_MAX_LINES: int = 6
const FEED_HOLD_SEC: float = 4.5
const FEED_FADE_SEC: float = 0.45
## A second helping of the same thing inside this window bumps the existing line instead of adding
## another — chopping a tree pays out in several drops and six identical "+1 Log" rows is noise.
const FEED_MERGE_SEC: float = 2.5

## Top-left. The row is the run's build; it never fades.
const ROW_MARGIN := Vector2(24.0, 24.0)
const ROW_ICON_PX: float = 38.0
const ROW_GAP: int = 6
## Wraps rather than running off the screen — a long run can hold a lot of powerups.
const ROW_MAX_PER_LINE: int = 12

## The powerup ceremony.
const FLASH_PEAK_ALPHA: float = 0.26
const FLASH_SEC: float = 0.55
const CARD_HOLD_SEC: float = 2.6
const CARD_FADE_SEC: float = 0.45
const CARD_TOP_FRACTION: float = 0.26
const CARD_POP_SEC: float = 0.28

## DESIGN.md §4.4's six families, given a voice. These are the same identities the resonance cues in
## `sfx_director.gd` sort by, and the reel in `ui/loot/chest_reel.gd` reads this table too — one
## palette for the whole powerup layer, so a Fire pickup flashes, glows and reads the same colour
## everywhere it appears. An unlisted family (a seventh one is a design event, per `PowerupDef`)
## falls back to the theme's amber rather than going colourless.
const FAMILY_COLOURS: Dictionary[StringName, Color] = {
	&"Fire": Color(1.0, 0.47, 0.18),
	&"Blood": Color(0.86, 0.20, 0.28),
	&"Kinetic": Color(0.98, 0.82, 0.30),
	&"Fungal": Color(0.55, 0.83, 0.42),
	&"Cold": Color(0.44, 0.78, 0.98),
	&"Void": Color(0.66, 0.42, 0.95),
}

const ITEM_COLOUR := Color(0.72, 0.82, 0.72)
const COIN_ITEM_ID: StringName = &"coins"
const COIN_COLOUR := Color(0.95, 0.78, 0.32)


## One line in the bottom-left feed. Owns its own clock so the HUD's `_process` stays a loop over
## children rather than a parallel array of timers.
class FeedLine extends PanelContainer:
	const MireThemeRef := preload("res://ui/theme/mire_theme.gd")

	var pickup_id: StringName = &""
	var amount: int = 0
	var age: float = 0.0
	var accent: Color = Color.WHITE

	var _icon: TextureRect
	var _label: Label

	func setup(icon: Texture2D, display_name: String, count: int, tint: Color) -> void:
		pickup_id = &""
		amount = count
		accent = tint

		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.03, 0.055, 0.045, 0.80)
		style.border_color = tint
		# Accent on the leading edge only: a full border around six stacked rows turns the corner of
		# the screen into a grid, which is exactly the busy-ness a transient feed must not add.
		style.border_width_left = 3
		style.set_corner_radius_all(5)
		style.content_margin_left = 8.0
		style.content_margin_right = 10.0
		style.content_margin_top = 5.0
		style.content_margin_bottom = 5.0
		add_theme_stylebox_override("panel", style)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(row)

		_icon = TextureRect.new()
		_icon.texture = icon
		_icon.custom_minimum_size = Vector2(22.0, 22.0)
		_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_icon.visible = icon != null
		_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(_icon)

		_label = Label.new()
		_label.add_theme_font_size_override("font_size", 14)
		_label.add_theme_color_override("font_color", MireThemeRef.TEXT)
		_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(_label)

		_refresh(display_name)

	## Same pickup again inside the merge window: bump the count and restart the clock rather than
	## adding a row.
	func bump(display_name: String, count: int) -> void:
		amount += count
		age = 0.0
		modulate.a = 1.0
		_refresh(display_name)

	func text() -> String:
		return _label.text if _label != null else ""

	func _refresh(display_name: String) -> void:
		_label.text = "+%d  %s" % [amount, display_name]


var _root: Control
var _feed_box: VBoxContainer
var _row_wrap: HFlowContainer
var _flash: ColorRect
var _card: PanelContainer
var _card_icon: TextureRect
var _card_title: Label
var _card_family: Label
var _card_body: Label

var _flash_remaining: float = 0.0
var _flash_colour: Color = Color.WHITE
var _card_remaining: float = 0.0
var _card_pop: float = 0.0
## Powerup id -> the icon box drawn for it in the top-left row, so a second stack updates the badge
## instead of adding a tile.
var _row_tiles: Dictionary[StringName, Control] = {}


func _ready() -> void:
	layer = LAYER
	# The feed keeps running while a menu is up: a teammate's chest can pay you out while you are in
	# your pack, and the line explaining that must not be frozen behind the pause state.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()

	var feed: Node = get_node_or_null(^"/root/PickupFeedService")
	if feed != null:
		feed.connect(&"pickup_received", _on_pickup_received)
	var powerups: Node = get_node_or_null(^"/root/PowerupService")
	if powerups != null:
		powerups.connect(&"local_powerups_changed", _on_local_powerups_changed)
		_on_local_powerups_changed(powerups.call(&"local_stacks"))
	get_viewport().size_changed.connect(_apply_layout)
	set_process(true)


func _exit_tree() -> void:
	var feed: Node = get_node_or_null(^"/root/PickupFeedService")
	if feed != null and feed.is_connected(&"pickup_received", _on_pickup_received):
		feed.disconnect(&"pickup_received", _on_pickup_received)


func _process(delta: float) -> void:
	_tick_feed(delta)
	_tick_flash(delta)
	_tick_card(delta)


# ── The one input ────────────────────────────────────────────────────────────────────────────────


func _on_pickup_received(kind: StringName, id: StringName, amount: int, _source: StringName) -> void:
	if amount <= 0:
		return
	var feed: Node = get_node_or_null(^"/root/PickupFeedService")
	var display_name: String = String(id).replace("_", " ").capitalize()
	var icon: Texture2D = null
	if feed != null:
		display_name = String(feed.call(&"display_name_of", kind, id))
		icon = feed.call(&"icon_of", kind, id) as Texture2D

	var powerup: bool = kind == &"powerup"
	_push_feed_line(id, display_name, icon, amount, _accent_for(kind, id))
	_play_cue(&"powerup_pickup" if powerup else &"item_pickup")
	if powerup:
		_show_powerup_card(id, display_name, icon)


## Client-local audio, on the peer that received the pickup. The cue has existed in `SfxCatalogue`
## since the audio pass and nothing ever played it on an actual pickup (F-581).
func _play_cue(cue: StringName) -> void:
	var sfx: Node = get_node_or_null(^"/root/SfxDirector")
	if sfx != null:
		sfx.call(&"play", cue)


# ── Bottom-left feed ─────────────────────────────────────────────────────────────────────────────


func _push_feed_line(id: StringName, display_name: String, icon: Texture2D, amount: int,
		tint: Color) -> void:
	for child: Node in _feed_box.get_children():
		var existing := child as FeedLine
		if existing != null and existing.pickup_id == id and existing.age <= FEED_MERGE_SEC:
			existing.bump(display_name, amount)
			return

	var line := FeedLine.new()
	line.setup(icon, display_name, amount, tint)
	line.pickup_id = id
	_feed_box.add_child(line)
	# Newest at the bottom, nearest the corner the eye is already using for vitals.
	while _feed_box.get_child_count() > FEED_MAX_LINES:
		var oldest: Node = _feed_box.get_child(0)
		_feed_box.remove_child(oldest)
		oldest.queue_free()


func _tick_feed(delta: float) -> void:
	for child: Node in _feed_box.get_children():
		var line := child as FeedLine
		if line == null:
			continue
		line.age += delta
		var over: float = line.age - FEED_HOLD_SEC
		if over <= 0.0:
			continue
		if over >= FEED_FADE_SEC:
			_feed_box.remove_child(line)
			line.queue_free()
			continue
		line.modulate.a = 1.0 - over / FEED_FADE_SEC


## Test/inspection seam, and the honest answer to "what does the feed say right now".
func feed_lines() -> PackedStringArray:
	var out := PackedStringArray()
	for child: Node in _feed_box.get_children():
		var line := child as FeedLine
		if line != null:
			out.append(line.text())
	return out


# ── Top-left held-powerup row ────────────────────────────────────────────────────────────────────


func _on_local_powerups_changed(stacks: Dictionary) -> void:
	var seen: Dictionary[StringName, bool] = {}
	var ids: Array[StringName] = []
	for id: StringName in stacks:
		ids.append(id)
	# StringName's `<` compares interned identity, not string content — F-175. A stable order means
	# the row does not reshuffle itself every time a stack is added.
	ids.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))

	for id: StringName in ids:
		var count: int = int(stacks[id])
		if count <= 0:
			continue
		seen[id] = true
		var tile: Control = _row_tiles.get(id)
		if tile == null:
			tile = _build_row_tile(id)
			_row_tiles[id] = tile
			_row_wrap.add_child(tile)
		var badge := tile.get_node_or_null(^"Count") as Label
		if badge != null:
			badge.text = "×%d" % count
			badge.visible = count > 1
		# A newly-gained stack pops, so the row answers "which one was that" without being read.
		tile.pivot_offset = tile.size * 0.5
		tile.scale = Vector2.ONE * 1.35
		_settle_tile(tile)

	for id: StringName in _row_tiles.keys():
		if seen.has(id):
			continue
		var stale: Control = _row_tiles[id]
		_row_tiles.erase(id)
		if is_instance_valid(stale):
			stale.get_parent().remove_child(stale)
			stale.queue_free()

	_reorder_row(ids)


## Keeps the drawn order equal to the sorted id order, so a powerup gained late lands in its place
## rather than at the end.
func _reorder_row(ids: Array[StringName]) -> void:
	var index: int = 0
	for id: StringName in ids:
		var tile: Control = _row_tiles.get(id)
		if tile != null and tile.get_parent() == _row_wrap:
			_row_wrap.move_child(tile, index)
			index += 1


func _settle_tile(tile: Control) -> void:
	var tween: Tween = create_tween()
	tween.tween_property(tile, ^"scale", Vector2.ONE,
		MIRE_THEME.DURATION_SCREEN * MIRE_THEME.motion_scale()) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _build_row_tile(id: StringName) -> Control:
	var feed: Node = get_node_or_null(^"/root/PickupFeedService")
	var icon: Texture2D = feed.call(&"icon_of", &"powerup", id) as Texture2D if feed != null else null
	var tint: Color = _accent_for(&"powerup", id)

	var tile := PanelContainer.new()
	tile.name = String(id)
	tile.custom_minimum_size = Vector2(ROW_ICON_PX, ROW_ICON_PX)
	tile.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# The tooltip is free — a Control that ignores the mouse never shows one — but the name is what
	# makes the row inspectable from a screenshot or a check.
	tile.tooltip_text = _display_name(&"powerup", id)

	var style := StyleBoxFlat.new()
	style.bg_color = Color(tint.r, tint.g, tint.b, 0.16)
	style.border_color = tint
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	tile.add_theme_stylebox_override("panel", style)

	var texture := TextureRect.new()
	texture.name = "Icon"
	texture.texture = icon
	texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	texture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	texture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tile.add_child(texture)

	var badge := Label.new()
	badge.name = "Count"
	badge.text = "×1"
	badge.visible = false
	badge.add_theme_font_size_override("font_size", 11)
	badge.add_theme_color_override("font_color", MIRE_THEME.TEXT)
	badge.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.85))
	badge.add_theme_constant_override("outline_size", 4)
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	badge.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	badge.set_anchors_preset(Control.PRESET_FULL_RECT)
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tile.add_child(badge)
	return tile


## Test/inspection seam: the powerup row, in drawn order.
func powerup_row_ids() -> Array[StringName]:
	var out: Array[StringName] = []
	for child: Node in _row_wrap.get_children():
		out.append(StringName(child.name))
	return out


# ── The powerup ceremony ─────────────────────────────────────────────────────────────────────────


func _show_powerup_card(id: StringName, display_name: String, icon: Texture2D) -> void:
	var tint: Color = _accent_for(&"powerup", id)
	_flash_colour = tint
	_flash_remaining = FLASH_SEC * MIRE_THEME.motion_scale()
	_flash.color = Color(tint.r, tint.g, tint.b, 0.0)
	_flash.visible = true

	_card_icon.texture = icon
	_card_icon.visible = icon != null
	_card_title.text = display_name
	_card_title.add_theme_color_override("font_color", tint)
	_card_family.text = _families_text(id)
	_card_family.visible = not _card_family.text.is_empty()
	_card_body.text = _description(id)
	_card_body.visible = not _card_body.text.is_empty()

	var style: StyleBoxFlat = MIRE_THEME.panel_style(Color(0.03, 0.055, 0.045, 0.94), tint)
	style.set_border_width_all(2)
	_card.add_theme_stylebox_override("panel", style)

	_card.modulate.a = 1.0
	_card.visible = true
	_card_remaining = CARD_HOLD_SEC
	_card_pop = CARD_POP_SEC * MIRE_THEME.motion_scale()
	_apply_layout()


func _tick_flash(delta: float) -> void:
	if _flash_remaining <= 0.0:
		return
	_flash_remaining -= delta
	if _flash_remaining <= 0.0:
		_flash.visible = false
		_flash.color.a = 0.0
		return
	var total: float = maxf(FLASH_SEC * MIRE_THEME.motion_scale(), 0.001)
	var elapsed: float = total - _flash_remaining
	# Up fast, down slow: a grant should read as a strike, not as a fade-in.
	var curve: float = (
		elapsed / (total * 0.25) if elapsed < total * 0.25
		else 1.0 - (elapsed - total * 0.25) / (total * 0.75)
	)
	_flash.color.a = FLASH_PEAK_ALPHA * clampf(curve, 0.0, 1.0)


func _tick_card(delta: float) -> void:
	if _card_pop > 0.0:
		_card_pop -= delta
		var total: float = maxf(CARD_POP_SEC * MIRE_THEME.motion_scale(), 0.001)
		var t: float = clampf(1.0 - _card_pop / total, 0.0, 1.0)
		_card.pivot_offset = _card.size * 0.5
		_card.scale = Vector2.ONE * lerpf(1.18, 1.0, ease(t, 0.35))
	if _card_remaining <= 0.0:
		return
	_card_remaining -= delta
	if _card_remaining > 0.0:
		return
	var fade: Tween = create_tween()
	fade.tween_property(_card, ^"modulate:a", 0.0, CARD_FADE_SEC * MIRE_THEME.motion_scale())
	fade.tween_callback(func() -> void: _card.visible = false)


## Test/inspection seam.
func card_title() -> String:
	return _card_title.text if _card.visible else ""


func flash_alpha() -> float:
	return _flash.color.a if _flash.visible else 0.0


# ── Shared lookups ───────────────────────────────────────────────────────────────────────────────


## The colour that identifies this pickup everywhere it is drawn: a powerup takes its first family's
## colour, coins take the theme's amber, and every other item takes one neutral moss so the feed's
## colour means something rather than being decoration.
func _accent_for(kind: StringName, id: StringName) -> Color:
	if kind == &"powerup":
		for family: StringName in _families_of(id):
			if FAMILY_COLOURS.has(family):
				return FAMILY_COLOURS[family]
		return MIRE_THEME.AMBER
	if id == COIN_ITEM_ID:
		return COIN_COLOUR
	return ITEM_COLOUR


func _families_of(id: StringName) -> Array:
	var registry: Node = get_node_or_null(^"/root/Registry")
	if registry == null:
		return []
	var definition: Resource = registry.call(&"get_powerup", id) as Resource
	if definition == null:
		return []
	var tags: Variant = definition.get(&"tags")
	return tags if tags is Array else []


func _families_text(id: StringName) -> String:
	var names: Array[String] = []
	for family: StringName in _families_of(id):
		names.append(String(family))
	return "  ·  ".join(names).to_upper()


func _description(id: StringName) -> String:
	var registry: Node = get_node_or_null(^"/root/Registry")
	if registry == null:
		return ""
	var definition: Resource = registry.call(&"get_powerup", id) as Resource
	return String(definition.get(&"description")) if definition != null else ""


func _display_name(kind: StringName, id: StringName) -> String:
	var feed: Node = get_node_or_null(^"/root/PickupFeedService")
	if feed != null:
		return String(feed.call(&"display_name_of", kind, id))
	return String(id).replace("_", " ").capitalize()


# ── Build ────────────────────────────────────────────────────────────────────────────────────────


func _build_ui() -> void:
	_root = Control.new()
	_root.name = "PickupHudRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	# Behind everything else here, and mouse-transparent: a full-screen tint must never eat a click.
	_flash = ColorRect.new()
	_flash.name = "PowerupFlash"
	_flash.color = Color(1.0, 1.0, 1.0, 0.0)
	_flash.set_anchors_preset(Control.PRESET_FULL_RECT)
	_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flash.visible = false
	_root.add_child(_flash)

	_feed_box = VBoxContainer.new()
	_feed_box.name = "PickupFeed"
	_feed_box.alignment = BoxContainer.ALIGNMENT_END
	_feed_box.add_theme_constant_override("separation", 4)
	_feed_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Anchored to the bottom-left corner and grown UPWARD, so the newest line is always at the same
	# height and the column climbs the screen edge as it fills.
	_feed_box.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_feed_box.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_root.add_child(_feed_box)

	_row_wrap = HFlowContainer.new()
	_row_wrap.name = "PowerupRow"
	_row_wrap.add_theme_constant_override("h_separation", ROW_GAP)
	_row_wrap.add_theme_constant_override("v_separation", ROW_GAP)
	_row_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_row_wrap.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_root.add_child(_row_wrap)

	_build_card()
	_apply_layout()


func _build_card() -> void:
	_card = PanelContainer.new()
	_card.name = "PowerupCard"
	_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.visible = false
	_card.add_theme_stylebox_override("panel", MIRE_THEME.panel_style())
	_root.add_child(_card)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 18)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_right", 18)
	margin.add_theme_constant_override("margin_bottom", 14)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.add_child(margin)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(row)

	_card_icon = TextureRect.new()
	_card_icon.name = "CardIcon"
	_card_icon.custom_minimum_size = Vector2(56.0, 56.0)
	_card_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_card_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_card_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_card_icon)

	var text_column := VBoxContainer.new()
	text_column.add_theme_constant_override("separation", 2)
	text_column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(text_column)

	_card_family = Label.new()
	_card_family.name = "CardFamily"
	_card_family.add_theme_font_size_override("font_size", 11)
	_card_family.add_theme_color_override("font_color", MIRE_THEME.MUTED)
	text_column.add_child(_card_family)

	_card_title = Label.new()
	_card_title.name = "CardTitle"
	_card_title.add_theme_font_size_override("font_size", MIRE_THEME.TITLE)
	text_column.add_child(_card_title)

	_card_body = Label.new()
	_card_body.name = "CardBody"
	_card_body.add_theme_font_size_override("font_size", 13)
	_card_body.add_theme_color_override("font_color", MIRE_THEME.TEXT)
	_card_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_card_body.custom_minimum_size = Vector2(260.0, 0.0)
	text_column.add_child(_card_body)


func _apply_layout() -> void:
	if _root == null:
		return
	var screen: Vector2 = get_viewport().get_visible_rect().size
	var scale: float = MIRE_THEME.ui_scale()

	_feed_box.custom_minimum_size = Vector2(FEED_WIDTH_PX * scale, 0.0)
	_feed_box.offset_left = FEED_MARGIN.x * scale
	_feed_box.offset_right = _feed_box.offset_left + FEED_WIDTH_PX * scale
	_feed_box.offset_bottom = FEED_MARGIN.y * scale

	_row_wrap.offset_left = ROW_MARGIN.x * scale
	_row_wrap.offset_top = ROW_MARGIN.y * scale
	_row_wrap.custom_minimum_size = Vector2(
		minf((ROW_ICON_PX + float(ROW_GAP)) * float(ROW_MAX_PER_LINE), screen.x * 0.5) * scale, 0.0
	)
	_row_wrap.size = _row_wrap.get_combined_minimum_size()

	if _card != null:
		var card_size: Vector2 = _card.get_combined_minimum_size()
		_card.size = card_size
		_card.position = Vector2(
			(screen.x - card_size.x) * 0.5, screen.y * CARD_TOP_FRACTION
		)
