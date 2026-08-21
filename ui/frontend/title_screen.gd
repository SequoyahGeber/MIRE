extends Control

## TitleScreen — MENU-3: the first thing anyone sees (docs/MENU.md §4).
##
## A `MenuStack` screen, pushed by `frontend.gd` and never popped: it sits at the bottom of the
## stack for the whole life of the front end, so every other screen returns here by Esc without
## anything having to remember the way back.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2): none — client-local UI. Every number on this
## screen is read from THIS peer's own persistence (Salvage, the last run's record) or from the
## Steam client's own idea of who is signed in. It routes by signal and decides nothing itself;
## `frontend.gd` owns what each choice actually does, which is what keeps this file a layout.
##
## ## Layout, and why it is a corner and not a column
##
## The backdrop is the pitch (see `backdrop.gd`), so the menu deliberately does not sit in the
## middle of the screen where a centred panel would cover the island. It runs down the lower-left
## with the wordmark above it, leaving the sun, the horizon and the creeping Mire in clear view —
## the same reason the last-expedition card is a small block in the opposite corner rather than a
## panel competing for the centre.
##
## Everything reads over a live 3D scene, so text that must stay legible against a bright sky sits
## on the scrim below rather than trusting the backdrop to stay dark.

const MireTheme := preload("res://ui/theme/mire_theme.gd")
const SalvageSave := preload("res://core/save/salvage_save.gd")
const RunRecordSave := preload("res://core/save/run_record_save.gd")

## Width of the lower-left choice column. Wide enough for "SETTINGS" at Title size with the button's
## own padding, narrow enough to leave the island uncovered.
const MENU_WIDTH: float = 300.0

signal play_requested()
signal unlocks_requested()
signal settings_requested()
## F-458: the benchmark gets its own entry rather than living only inside Settings > DISPLAY. It is
## the thing a player reaches for BEFORE they know what their settings should be, and a control you
## have to already be configuring graphics to find is one nobody discovers on a first launch.
signal benchmark_requested()
signal credits_requested()
signal quit_requested()

var _play_button: Button
var _unlocks_button: Button
var _settings_button: Button
var _benchmark_button: Button
var _quit_button: Button
var _salvage_label: Label
var _persona_label: Label
var _expedition_card: PanelContainer
var _expedition_body: VBoxContainer


func _ready() -> void:
	# See MenuStack.push() for why this is the offsets variant: `set_anchors_preset` alone would
	# pin this screen's zero opening rect into its offsets and it would never draw.
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# The backdrop has to stay visible and the island has to stay clickable-through; only the
	# buttons themselves take the mouse.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()
	refresh()


## MenuStack contract: where a controller lands when this screen is shown.
func menu_default_focus() -> Control:
	return _play_button


## MenuStack contract: Esc at the title has nowhere to go back to. Returning false here is what
## makes the title the floor of the stack rather than something the player can accidentally pop
## into an empty front end (docs/MENU.md §2). QUIT is the deliberate way out, and it confirms.
func menu_allows_cancel() -> bool:
	return false


## MenuStack contract: no full-screen shade. The backdrop IS this screen's art; the stack's shade
## would dim the island the title exists to show. Legibility comes from the scrim gradient below
## instead, which darkens only the band the text actually sits in.
func menu_dims_background() -> bool:
	return false


func menu_shown() -> void:
	refresh()


## Re-derives every live number on the screen. Cheap and idempotent, so it is safe to call on every
## show and after any purchase — the same shape `main_menu.gd._refresh()` uses, and the same reason
## (`GameState.seed_ready` can fire twice for one run boundary — D-177).
func refresh() -> void:
	_salvage_label.text = "SALVAGE  %d" % _total_salvage()
	_persona_label.text = _persona_name()
	_rebuild_expedition_card()


# ── Data ──────────────────────────────────────────────────────────────────────────────────────────


func _total_salvage() -> int:
	var service: Node = get_node_or_null(^"/root/SalvageService")
	if service != null and service.has_method("total_salvage"):
		return int(service.call("total_salvage"))
	# No service (a check that boots no autoloads): read the same file it would have read, so the
	# screen still shows a real number rather than a zero that looks like a wiped save.
	var data: Dictionary = SalvageSave.load_data()
	return int(data.get("total_salvage", 0))


func _persona_name() -> String:
	var lobby: Node = get_node_or_null(^"/root/SteamLobby")
	if lobby != null and lobby.has_method("local_persona_name"):
		var name_text: String = String(lobby.call("local_persona_name")).strip_edges()
		if not name_text.is_empty():
			return name_text
	return "offline"


## The last run's record, written by `autoload/run_record.gd` (MENU-7). Empty on a first-ever boot,
## in which case the card is hidden entirely rather than shown empty — a "Cycle 0 / nothing banked"
## card would tell a new player they had already failed.
func _last_expedition() -> Dictionary:
	var service: Node = get_node_or_null(^"/root/RunRecord")
	var record: Dictionary = service.call("last_run") if service != null else RunRecordSave.load_data()
	return record if bool(record.get("has_run", false)) else {}


# ── Layout ────────────────────────────────────────────────────────────────────────────────────────


func _build() -> void:
	_build_scrim()
	_build_wordmark()
	_build_menu()
	_build_expedition_card()
	_build_footer()


## A soft dark gradient up from the bottom edge. Without it, menu text sits directly on whatever the
## camera happens to be pointing at, and the drift means that changes over time — the one thing a
## backdrop must never do is take the words with it.
func _build_scrim() -> void:
	var gradient := Gradient.new()
	gradient.set_color(0, Color(0.0, 0.0, 0.0, 0.0))
	gradient.set_color(1, Color(0.01, 0.03, 0.02, 0.86))

	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.fill_from = Vector2(0.0, 0.0)
	texture.fill_to = Vector2(0.0, 1.0)

	var scrim := TextureRect.new()
	scrim.name = "Scrim"
	scrim.texture = texture
	scrim.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	scrim.anchor_top = 0.42
	scrim.anchor_bottom = 1.0
	scrim.stretch_mode = TextureRect.STRETCH_SCALE
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(scrim)


## The wordmark: wide-tracked capitals with a bog-coloured wash rising over their lower third, so
## the letters read as standing IN the water rather than on top of a picture of it. A drawn logotype
## replaces this (an ASSET_TRACKER entry); until then the typeset form is deliberately plain — a
## placeholder that tries to look like a logo is harder to replace than one that clearly is not.
func _build_wordmark() -> void:
	var anchor := Control.new()
	anchor.name = "Wordmark"
	anchor.set_anchors_preset(Control.PRESET_TOP_LEFT)
	anchor.offset_left = float(MireTheme.GRID * 9)
	anchor.offset_top = float(MireTheme.GRID * 12)
	anchor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(anchor)

	var letters: HBoxContainer = MireTheme.row(MireTheme.GRID * 3)
	letters.name = "Letters"
	anchor.add_child(letters)
	for letter: String in ["M", "I", "R", "E"]:
		var glyph: Label = MireTheme.label(letter, MireTheme.DISPLAY, MireTheme.TEXT)
		glyph.add_theme_font_size_override("font_size", MireTheme.font_size(MireTheme.DISPLAY) + 16)
		letters.add_child(glyph)

	var sink := ColorRect.new()
	sink.name = "Sink"
	sink.color = Color(0.055, 0.10, 0.085, 0.55)
	sink.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	sink.anchor_top = 0.62
	sink.mouse_filter = Control.MOUSE_FILTER_IGNORE
	letters.add_child(sink)
	sink.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	sink.anchor_top = 0.62


func _build_menu() -> void:
	var column: VBoxContainer = MireTheme.column(MireTheme.GRID / 2)
	column.name = "MainChoices"
	column.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	column.offset_left = float(MireTheme.GRID * 9)
	# PRESET_BOTTOM_LEFT pins both horizontal anchors to 0, so width is offset_right - offset_left
	# and leaving offset_right at 0 computes a NEGATIVE width — the column lays out at zero size and
	# never draws, with no error to notice. Set the right edge explicitly.
	column.offset_right = float(MireTheme.GRID * 9) + MENU_WIDTH
	column.offset_top = -float(MireTheme.GRID * 40)
	column.offset_bottom = -float(MireTheme.GRID * 9)
	add_child(column)

	_play_button = MireTheme.button("PLAY", func() -> void: play_requested.emit(), MireTheme.Variant.PRIMARY)
	_unlocks_button = MireTheme.button("UNLOCKS", func() -> void: unlocks_requested.emit())
	_settings_button = MireTheme.button("SETTINGS", func() -> void: settings_requested.emit())
	_benchmark_button = MireTheme.button("BENCHMARK", func() -> void: benchmark_requested.emit())
	_quit_button = MireTheme.button("QUIT", func() -> void: quit_requested.emit(), MireTheme.Variant.DESTRUCTIVE)

	for button: Button in [_play_button, _unlocks_button, _settings_button, _benchmark_button,
			_quit_button]:
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		column.add_child(button)

	MireTheme.wire_chain([_play_button, _unlocks_button, _settings_button, _benchmark_button,
		_quit_button])


func _build_expedition_card() -> void:
	_expedition_card = MireTheme.card()
	_expedition_card.name = "LastExpedition"
	_expedition_card.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_expedition_card.offset_left = -float(MireTheme.GRID * 42)
	_expedition_card.offset_right = -float(MireTheme.GRID * 9)
	_expedition_card.offset_top = -float(MireTheme.GRID * 22)
	_expedition_card.offset_bottom = -float(MireTheme.GRID * 9)
	_expedition_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_expedition_card.visible = false
	add_child(_expedition_card)

	_expedition_body = MireTheme.column(MireTheme.GRID / 2)
	_expedition_card.add_child(_expedition_body)


func _rebuild_expedition_card() -> void:
	for child: Node in _expedition_body.get_children():
		_expedition_body.remove_child(child)
		child.queue_free()

	var record: Dictionary = _last_expedition()
	if record.is_empty():
		_expedition_card.visible = false
		return
	_expedition_card.visible = true

	_expedition_body.add_child(MireTheme.label("LAST EXPEDITION", MireTheme.CAPTION, MireTheme.MUTED))

	var cycle: int = int(record.get("cycle", 0))
	_expedition_body.add_child(MireTheme.label("Cycle %d" % cycle, MireTheme.HEADLINE, MireTheme.AMBER))

	var cause: String = String(record.get("cause_line", ""))
	if not cause.is_empty():
		var cause_label: Label = MireTheme.label(cause, MireTheme.BODY, MireTheme.TEXT)
		cause_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_expedition_body.add_child(cause_label)

	var banked: int = int(record.get("salvage_banked", 0))
	_expedition_body.add_child(
		MireTheme.label("banked %d salvage" % banked, MireTheme.CAPTION, MireTheme.MOSS)
	)


func _build_footer() -> void:
	var footer: HBoxContainer = MireTheme.row(MireTheme.GRID * 2)
	footer.name = "Footer"
	footer.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	footer.offset_left = float(MireTheme.GRID * 9)
	footer.offset_right = -float(MireTheme.GRID * 9)
	footer.offset_top = -float(MireTheme.GRID * 5)
	footer.offset_bottom = -float(MireTheme.GRID * 2)
	add_child(footer)

	footer.add_child(MireTheme.label(_version_string(), MireTheme.CAPTION, MireTheme.MUTED))

	_persona_label = MireTheme.label("offline", MireTheme.CAPTION, MireTheme.MUTED)
	footer.add_child(_persona_label)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	footer.add_child(spacer)

	_salvage_label = MireTheme.label("SALVAGE  0", MireTheme.CAPTION, MireTheme.MOSS)
	footer.add_child(_salvage_label)

	footer.add_child(MireTheme.link("credits", func() -> void: credits_requested.emit()))


func _version_string() -> String:
	var configured: String = String(ProjectSettings.get_setting("application/config/version", "")).strip_edges()
	return "v%s" % configured if not configured.is_empty() else "in development"
