extends Control

## SalvageBenchScreen — MENU-8: spending Salvage, reframed as a workbench (docs/MENU.md §7.2).
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2): none — client-local UI over THIS peer's own
## `SalvageService` / `UnlockService` state, the same "Unlocks" row those two already claim. Nothing
## here is replicated: an unlock changes what enters future runs' content pools for this account.
##
## ## Shelves, not a list
##
## `ui/menu/unlock_menu.gd` renders every authored `UnlockDef` as one flat column of rows. That works
## at the seven unlocks authored today and stops working somewhere around twenty, which is where this
## table is heading — DESIGN.md §4.6 makes the unlock table the whole meta-progression system, and
## explicitly the cheap-to-extend part of it. Grouping by the category each def already declares
## costs nothing now and is the difference between browsing and scrolling later.
##
## ## The rule this screen exists to make visible
##
## **Salvage unlocks variety, never power** (DESIGN.md §4.6, D-009). Every card says what it adds to
## the pool rather than what it makes you stronger at, and the header says the rule out loud — a
## player who believes the bench sells power will read every price as a paywall.

const MireTheme := preload("res://ui/theme/mire_theme.gd")

## Display order and headings for the categories `UnlockDef.KNOWN_CATEGORIES` allows. Ordered by how
## much a player is likely to care, not alphabetically.
const SHELVES: Array[Dictionary] = [
	{"id": &"powerup", "title": "POWERUPS", "blurb": "new cards in the chest pool"},
	{"id": &"cycle_modifier", "title": "CYCLE MODIFIERS", "blurb": "new ways a run can go wrong"},
	{"id": &"enemy", "title": "ENEMIES", "blurb": "new things on the island"},
	{"id": &"poi", "title": "LANDMARKS", "blurb": "new places to find"},
	{"id": &"island_modifier", "title": "ISLANDS", "blurb": "new shapes of island"},
	{"id": &"attunement", "title": "ATTUNEMENTS", "blurb": "new roles to pick at the first Wellspring"},
	{"id": &"loadout", "title": "LOADOUTS", "blurb": "new ways to start — sidegrades, never upgrades"},
	{"id": &"cosmetic", "title": "COSMETICS", "blurb": "hats are canon"},
]

var _balance_label: Label
var _status_label: Label
var _shelf_host: VBoxContainer
var _back_button: Button
var _first_card: Button

## unlock_id -> {"def": Resource, "button": Button, "card": PanelContainer, "state": Label}
var _rows: Dictionary = {}


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	refresh()


func menu_default_focus() -> Control:
	return _first_card if _first_card != null else _back_button


func menu_shown() -> void:
	refresh()


# ── Public API (the check drives these) ───────────────────────────────────────────────────────────


func balance() -> int:
	var salvage: Node = get_node_or_null(^"/root/SalvageService")
	if salvage != null and salvage.has_method("total_salvage"):
		return int(salvage.call("total_salvage"))
	return 0


func row_count() -> int:
	return _rows.size()


func status_text() -> String:
	return _status_label.text


func is_owned(unlock_id: StringName) -> bool:
	var unlocks: Node = get_node_or_null(^"/root/UnlockService")
	if unlocks != null and unlocks.has_method("is_purchased"):
		return bool(unlocks.call("is_purchased", unlock_id))
	return false


func can_afford(unlock_id: StringName) -> bool:
	var row: Variant = _rows.get(unlock_id, null)
	if row == null:
		return false
	return balance() >= int((row as Dictionary)["def"].get("cost"))


## Asks before spending. The confirmation carries the flavour line rather than a bare "are you
## sure?" — the bench is meant to feel like buying something, and the joke is the product.
func request_purchase(unlock_id: StringName) -> void:
	var row: Variant = _rows.get(unlock_id, null)
	if row == null:
		return
	var def: Resource = (row as Dictionary)["def"]
	if is_owned(unlock_id):
		_note("Already on the bench.", false)
		return
	if not can_afford(unlock_id):
		_note("%d short for %s." % [int(def.get("cost")) - balance(), String(def.get("display_name"))], true)
		refresh()
		return

	var stack: Node = get_node_or_null(^"/root/MenuStack")
	if stack == null:
		_purchase_now(unlock_id)
		return
	stack.call(
		"confirm",
		String(def.get("display_name")),
		"%s\n\n%d Salvage, and it joins the pool for every run after this one."
			% [String(def.get("description")), int(def.get("cost"))],
		"SPEND %d" % int(def.get("cost")),
		"NOT YET",
		func() -> void: _purchase_now(unlock_id),
		false,
	)


## Re-derives every card's state from the two services. Idempotent, never rebuilds the shelves —
## content is boot-time static (D-073), only affordability and ownership move.
func refresh() -> void:
	_balance_label.text = "%d SALVAGE" % balance()
	for unlock_id: StringName in _rows:
		var row: Dictionary = _rows[unlock_id]
		var def: Resource = row["def"]
		var button: Button = row["button"]
		var state: Label = row["state"]
		var owned: bool = is_owned(unlock_id)
		var affordable: bool = can_afford(unlock_id)

		# State is never colour alone (docs/MENU.md §9): each state has a word as well as a hue.
		if owned:
			state.text = "ON THE BENCH"
			state.add_theme_color_override("font_color", MireTheme.MOSS)
			button.text = "OWNED"
			button.disabled = true
		elif affordable:
			state.text = "%d salvage" % int(def.get("cost"))
			state.add_theme_color_override("font_color", MireTheme.AMBER)
			button.text = "SPEND %d" % int(def.get("cost"))
			button.disabled = false
		else:
			state.text = "%d salvage · %d short" % [int(def.get("cost")), int(def.get("cost")) - balance()]
			state.add_theme_color_override("font_color", MireTheme.MUTED)
			button.text = "SPEND %d" % int(def.get("cost"))
			button.disabled = true


func _purchase_now(unlock_id: StringName) -> void:
	var unlocks: Node = get_node_or_null(^"/root/UnlockService")
	if unlocks == null or not unlocks.has_method("purchase"):
		return
	var row: Dictionary = _rows[unlock_id]
	var def: Resource = row["def"]
	if bool(unlocks.call("purchase", unlock_id)):
		_note("%s is on the bench. It'll turn up." % String(def.get("display_name")), false)
	else:
		# UnlockService refused — it re-checks the balance and ownership itself, and it is the
		# authority. Say so rather than showing a success message for a purchase that did not happen.
		_note("Couldn't buy that one.", true)
	refresh()


# ── Build ─────────────────────────────────────────────────────────────────────────────────────────


func _build() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", MireTheme.GRID * 9)
	margin.add_theme_constant_override("margin_right", MireTheme.GRID * 9)
	margin.add_theme_constant_override("margin_top", MireTheme.GRID * 5)
	margin.add_theme_constant_override("margin_bottom", MireTheme.GRID * 5)
	add_child(margin)

	var centre: HBoxContainer = MireTheme.row(0)
	margin.add_child(centre)
	centre.add_child(_spacer())

	var page: VBoxContainer = MireTheme.column(MireTheme.GRID * 2)
	page.custom_minimum_size = Vector2(920.0, 0.0)
	page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	centre.add_child(page)
	centre.add_child(_spacer())

	var header: HBoxContainer = MireTheme.row()
	page.add_child(header)
	_back_button = MireTheme.link("◀  back", _go_back)
	header.add_child(_back_button)
	var title: Label = MireTheme.label("THE SALVAGE BENCH", MireTheme.HEADLINE, MireTheme.TEXT)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.add_child(title)
	_balance_label = MireTheme.label("0 SALVAGE", MireTheme.TITLE, MireTheme.MOSS)
	header.add_child(_balance_label)

	# The rule, said out loud. A player who thinks the bench sells power reads every price as a
	# paywall; saying it here is cheaper than letting them find out over ten runs.
	page.add_child(MireTheme.paragraph(
		"Salvage buys VARIETY, never power. Nothing here makes you stronger — it makes the next run "
		+ "less like the last one.", MireTheme.CAPTION, MireTheme.MUTED
	))
	page.add_child(MireTheme.separator())

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	page.add_child(scroll)

	_shelf_host = MireTheme.column(MireTheme.GRID * 2)
	_shelf_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_shelf_host)

	_build_shelves()

	_status_label = MireTheme.paragraph("", MireTheme.CAPTION, MireTheme.MUTED)
	page.add_child(_status_label)


func _build_shelves() -> void:
	var by_category: Dictionary = {}
	for def: Resource in _definitions():
		var category: StringName = StringName(def.get("category"))
		if not by_category.has(category):
			by_category[category] = []
		by_category[category].append(def)

	var focus_chain: Array = []
	var any: bool = false

	for shelf: Dictionary in SHELVES:
		var category: StringName = shelf["id"]
		if not by_category.has(category):
			# An empty shelf is not drawn. A row of "nothing here yet" headings would make the bench
			# read as mostly-empty when it is simply not authored in that direction.
			continue
		any = true
		var heading: HBoxContainer = MireTheme.row()
		_shelf_host.add_child(heading)
		heading.add_child(MireTheme.label(String(shelf["title"]), MireTheme.TITLE, MireTheme.TEXT))
		heading.add_child(MireTheme.label(String(shelf["blurb"]), MireTheme.CAPTION, MireTheme.MUTED))

		var shelf_column: VBoxContainer = MireTheme.column(MireTheme.GRID / 2)
		_shelf_host.add_child(shelf_column)
		for def: Resource in by_category[category]:
			var card: Control = _card(def)
			shelf_column.add_child(card)
			focus_chain.append(_rows[StringName(def.get("id"))]["button"])

	if not any:
		_shelf_host.add_child(MireTheme.paragraph(
			"Nothing on the bench yet. Finish a run and come back.", MireTheme.BODY, MireTheme.MUTED
		))

	focus_chain.append(_back_button)
	MireTheme.wire_chain(focus_chain)
	if focus_chain.size() > 1:
		_first_card = focus_chain[0]


func _card(def: Resource) -> Control:
	var unlock_id: StringName = StringName(def.get("id"))
	var card: PanelContainer = MireTheme.card()

	var row: HBoxContainer = MireTheme.row()
	card.add_child(row)

	var text_column: VBoxContainer = MireTheme.column(2)
	text_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(text_column)

	text_column.add_child(MireTheme.label(String(def.get("display_name")), MireTheme.BODY, MireTheme.TEXT))
	var description: Label = MireTheme.label(String(def.get("description")), MireTheme.CAPTION, MireTheme.MUTED)
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	description.custom_minimum_size = Vector2(460.0, 0.0)
	text_column.add_child(description)

	var state: Label = MireTheme.label("", MireTheme.CAPTION, MireTheme.MUTED)
	row.add_child(state)

	var button: Button = MireTheme.button("SPEND", func() -> void: request_purchase(unlock_id))
	row.add_child(button)

	_rows[unlock_id] = {"def": def, "button": button, "card": card, "state": state}
	return card


## Every authored `UnlockDef`, sorted by cost within its shelf so the cheapest thing a player can
## actually afford is the first one they see.
func _definitions() -> Array:
	var registry: Node = get_node_or_null(^"/root/Registry")
	if registry == null:
		return []
	var table: Variant = registry.get("unlocks")
	if not (table is Dictionary):
		return []
	var defs: Array = (table as Dictionary).values()
	defs.sort_custom(func(a: Resource, b: Resource) -> bool:
		return int(a.get("cost")) < int(b.get("cost")))
	return defs


func _note(message: String, is_error: bool) -> void:
	_status_label.text = message
	_status_label.add_theme_color_override("font_color", MireTheme.ERROR if is_error else MireTheme.MOSS)


func _spacer() -> Control:
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return spacer


func _go_back() -> void:
	var stack: Node = get_node_or_null(^"/root/MenuStack")
	if stack != null:
		stack.call("pop")
