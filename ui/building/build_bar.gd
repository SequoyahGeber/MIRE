extends CanvasLayer

## Client-local build-mode presentation (F-086 — 3.6 shipped BuildService/BuildGhost/PlacementValidator
## with no way for a player to reach any of it). Built directly by
## entities/player/player_controller.gd for the local player only, the same way it builds its
## Viewmodel and debug avatar — NOT an autoload like ui/crafting/crafting_ui.gd or
## ui/inventory/inventory_ui.gd. Nobody needs to see another player's piece picker (client-local
## presentation, §2.2 last row, same as the ghost it sits beside), so this is built per-player.
## Piece rotate/destroy (task 7.6: real InputMap actions "build_rotate"/"build_destroy", each
## keyboard/mouse plus gamepad) are handled in player_controller.gd itself, not here — this bar is
## selection and status display only. Toggling
## build mode (the existing "build" InputMap action) is also read in player_controller.gd, so this
## bar and the player's build-mode state can never disagree about whether the mode is on; the player
## pushes state into this bar (`set_active`, `set_selected_piece`, `set_ghost_status`) rather than
## this bar polling for it.
##
## NETWORK AUTHORITY: none (§2.2 last row). A slot click only emits `piece_selected` — the player
## decides whether/how to act on it, and BuildService remains the only thing that ever actually
## places or destroys anything.
##
## F-217 was the first attempt at "a bare controller can change the piece": slots took focus, chained
## to their row neighbours, and selected on `ui_accept`. F-483 removed all of it — see below. The
## finding it was answering was real; the mechanism was the wrong one, because focus and `ui_accept`
## are not available to a mode that has the cursor captured and `ui_accept` bound to `jump`.
##
## ## F-483: one row, tabs, and no cursor
##
## Two faults with one symptom, from the 2026-08-21 playtest: *"the cursor stays captive even when
## opening the build menu so there is no way to select building pieces or view the placement of
## them."*
##
## The first is that every selection path this bar had needed something build mode does not give
## you. A click needs a free cursor, and build mode keeps the cursor CAPTURED on purpose — the ghost
## follows the camera and LMB confirms the placement, so a picker that took the cursor would break
## the aiming it exists to serve. `ui_accept` is `jump`. That left F-217's focus chain, i.e. the
## arrow keys, which nothing on screen mentions. In practice the player was stuck with whatever
## `toggle_build_mode()` auto-picked.
##
## So selection is now bound, not pointed at: `build_piece_prev`/`build_piece_next` (wheel up/down,
## and the shoulder buttons on a pad) step through the open tab, and
## `build_category_prev`/`build_category_next` (Z/C, right-stick-click and BACK) step the tab. The
## shoulder buttons are deliberately the SAME ones `hotbar_prev`/`hotbar_next` use: this bar is
## built by the player, which sits deeper in the tree than the `InventoryUI` autoload, `_input`
## propagates in reverse tree order, and `InventoryUI._input` opens with an `is_input_handled()`
## guard — so consuming them here while build mode is on cleanly takes them over for the duration
## and hands them straight back when it is off. The click path is left intact underneath; it simply
## has no cursor to be reached by today.
##
## The second is that the bar covered what it was previewing. F-477 took the set from 15 pieces to
## 22, and the wrapped `HFlowContainer` this file used to hold them was four rows and ~340 px tall,
## parked exactly where a first-person builder looks — the ghost sits on the ground a few metres
## ahead, low in frame. Tabs fix that structurally rather than by tuning a number: the row holds one
## CATEGORY (eight pieces at the widest, ~700 px), so it stays a single row no matter how far the
## buildable set grows. `BuildableDef.category` is the authored key and `CATEGORY_ORDER` fixes the
## tab order, so adding a buildable — or a whole new tab — never needs a number changed here.

const COLOUR_PANEL := Color(0.055, 0.086, 0.070, 0.97)
const COLOUR_ROW := Color(0.085, 0.125, 0.102, 0.98)
const COLOUR_BORDER := Color(0.345, 0.475, 0.390, 1.0)
const COLOUR_READY := Color(0.894, 0.704, 0.286, 1.0)
const COLOUR_TEXT := Color(0.91, 0.94, 0.89, 1.0)
const COLOUR_MUTED := Color(0.60, 0.69, 0.62, 1.0)
const COLOUR_ERROR := Color(0.96, 0.47, 0.39, 1.0)
## Snapping ON. Deliberately the same amber as COLOUR_READY: snapping on is the normal, expected
## state of build mode, so it reads as "armed" rather than as a warning.
const COLOUR_SNAP_ON := COLOUR_READY
## Snapping OFF — muted, because free placement is the quieter mode, not an error.
const COLOUR_SNAP_OFF := Color(0.60, 0.69, 0.62, 1.0)
## Width the widest tab needs: eight slots plus their separations. 104 px rather than F-086's 88:
## the first render of the tabbed row trimmed "Wooden Floor" and "Wooden Wall" to "Wooden Fl..." and
## "Wooden W...", which on a picker whose whole job is telling you what you are about to place is
## the wrong thing to save 128 px on. Eight of them is 860 px, still inside a 1280-wide window. A floor on the panel, not a
## wrap width (F-483 replaced the wrapping flow with one row per tab) — it keeps the bar the same
## shape whichever tab is open, so stepping from an eight-piece tab to a six-piece one does not make
## the panel visibly breathe in and out under the crosshair. Still narrow enough for a 1280-wide
## window with the margins the panel adds.
const SLOT_WIDTH_PX: float = 104.0
const ROW_WIDTH_PX: float = 8.0 * SLOT_WIDTH_PX + 7.0 * 4.0

## Height of the bar's slot band. One row of 56 px slots; fixed rather than measured so the panel
## does not resize when a tab with a taller cost line opens.
const ROW_HEIGHT_PX: float = 56.0


## One registered buildable. Selecting never places anything — it only tells the player which piece
## the ghost should preview.
class PieceSlot extends PanelContainer:
	var piece_id: StringName = &""
	var select_requested: Callable
	## Cost and description, rendered once at setup and read back by the bar for the lines under the
	## row. Held here rather than re-derived from the Registry so the bar never has to look a
	## definition up again after boot.
	var cost_text: String = ""
	var description_text: String = ""

	var _label: Label
	var _icon: TextureRect
	var _base_style: StyleBoxFlat
	var _selected_style: StyleBoxFlat
	var _selected: bool = false


	func setup(def: Resource, select_callback: Callable) -> void:
		piece_id = StringName(String(def.get(&"id")))
		select_requested = select_callback
		name = "BuildSlot_%s" % String(piece_id)
		custom_minimum_size = Vector2(SLOT_WIDTH_PX, 56.0)
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		# F-483: FOCUS_NONE, where F-217 had FOCUS_ALL. Focus was that finding's answer to "a bare
		# controller cannot change the piece" — the arrow keys walked the chain. `build_piece_prev`/
		# `_next` answer it properly now, and leaving focus on for it costs two things. The focus
		# ring outranks the selected ring in `_update_style()`, so the first render of this change
		# showed the armed piece in cyan "focused" blue instead of amber "this is what you are
		# placing" — on a picker whose entire job is saying what you are about to place. And a
		# focused Control during first-person play means `ui_accept` and the arrow keys are doing
		# UI things while the player is aiming a ghost. The click path stays — it costs nothing and
		# a future cursor-owning context would want it — but focus does not.
		focus_mode = Control.FOCUS_NONE
		_build_contents(def)
		_build_styles()


	func display_name() -> String:
		return _label.text if _label != null else String(piece_id)


	func present(selected: bool) -> void:
		_selected = selected
		_update_style()


	## One ring, one meaning (F-483): amber marks the piece build mode is actually placing, and
	## nothing else marks anything. F-217's focus ring used to sit on top of this and win, which is
	## how the tabbed row's first render showed the armed piece in "focused" blue.
	func _update_style() -> void:
		var style: StyleBoxFlat = _base_style
		if _selected:
			style = _selected_style
		add_theme_stylebox_override("panel", style)


	func _build_contents(def: Resource) -> void:
		var margin := MarginContainer.new()
		margin.add_theme_constant_override("margin_left", 6)
		margin.add_theme_constant_override("margin_top", 4)
		margin.add_theme_constant_override("margin_right", 6)
		margin.add_theme_constant_override("margin_bottom", 4)
		add_child(margin)

		var stack := VBoxContainer.new()
		stack.add_theme_constant_override("separation", 2)
		margin.add_child(stack)

		_icon = TextureRect.new()
		_icon.custom_minimum_size = Vector2(0.0, 22.0)
		_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_icon.texture = def.get(&"icon")
		_icon.visible = _icon.texture != null
		stack.add_child(_icon)

		var display_name: String = String(def.get(&"display_name"))
		if display_name.is_empty():
			display_name = String(piece_id)

		_label = Label.new()
		_label.text = display_name
		_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		# The slot's width is SLOT_WIDTH_PX and nothing inside it gets to argue: a long display name
		# ellipsizes rather than widening its slot, so the row is the same shape on every tab.
		_label.custom_minimum_size = Vector2(SLOT_WIDTH_PX - 12.0, 0.0)
		_label.clip_text = true
		_label.add_theme_font_size_override("font_size", 12)
		_label.add_theme_color_override("font_color", COLOUR_TEXT)
		stack.add_child(_label)

		# F-483: the cost is NOT in the slot. Eight slots each sized to their own cost string
		# ("6 iron_ingot · 4 log · 1 wellglass_shard") pushed the row to 1 268 px of a 1 280 px
		# window — edge to edge, for seven costs the player is not spending. It moved to a line
		# under the row, where it belongs to the one piece that is actually armed.
		cost_text = _cost_text(def.get(&"cost"))

		var description: String = String(def.get(&"description"))
		description_text = description
		tooltip_text = "%s\n%s" % [display_name, description] if not description.is_empty() \
			else display_name
		accessibility_name = "%s build slot" % display_name


	func _cost_text(cost: Dictionary) -> String:
		if cost.is_empty():
			return "free"
		var parts: PackedStringArray = PackedStringArray()
		for item_id: StringName in cost:
			parts.append("%d %s" % [int(cost[item_id]), String(item_id)])
		return "  ·  ".join(parts)


	func _build_styles() -> void:
		_base_style = _slot_style(COLOUR_BORDER, 1)
		_selected_style = _slot_style(COLOUR_READY, 3)
		add_theme_stylebox_override("panel", _base_style)


	func _slot_style(border: Color, border_width: int) -> StyleBoxFlat:
		var style := StyleBoxFlat.new()
		style.bg_color = COLOUR_ROW
		style.border_color = border
		style.set_border_width_all(border_width)
		style.set_corner_radius_all(6)
		return style


	func _gui_input(event: InputEvent) -> void:
		if (
			event is InputEventMouseButton
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT
			and (event as InputEventMouseButton).pressed
		):
			select_requested.call(piece_id)
			return
		# F-217's `ui_accept` branch is gone with the focus that fed it: a FOCUS_NONE control never
		# receives one, and `ui_accept` is `jump`, so keeping it would have meant a slot claiming
		# the jump key on the frame a cursor happened to be over it.


## One tab in the strip above the row (F-483). Display only — the tab a player is on is changed by
## `build_category_prev`/`build_category_next`, never by pointing at this, because build mode has no
## cursor to point with. It is a `PanelContainer` rather than a `Button` for exactly that reason:
## nothing here is pressable, so nothing here should look pressable or take focus off a piece slot.
class CategoryTab extends PanelContainer:
	var category: StringName = &""

	var _label: Label
	var _open_style: StyleBoxFlat
	var _shut_style: StyleBoxFlat


	func setup(name_key: StringName, text: String, count: int) -> void:
		category = name_key
		name = "BuildTab_%s" % String(name_key)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		focus_mode = Control.FOCUS_NONE

		var margin := MarginContainer.new()
		margin.add_theme_constant_override("margin_left", 10)
		margin.add_theme_constant_override("margin_top", 3)
		margin.add_theme_constant_override("margin_right", 10)
		margin.add_theme_constant_override("margin_bottom", 3)
		add_child(margin)

		_label = Label.new()
		# The count is on the tab because the row only ever shows one tab's worth: without it there
		# is nothing on screen to say how much is behind the tabs you are not looking at.
		_label.text = "%s (%d)" % [text, count]
		_label.add_theme_font_size_override("font_size", 11)
		margin.add_child(_label)

		_open_style = _tab_style(COLOUR_READY, COLOUR_ROW, 2)
		_shut_style = _tab_style(COLOUR_BORDER, COLOUR_PANEL, 1)
		present(false)


	func present(open: bool) -> void:
		add_theme_stylebox_override("panel", _open_style if open else _shut_style)
		_label.add_theme_color_override("font_color", COLOUR_READY if open else COLOUR_MUTED)


	func _tab_style(border: Color, fill: Color, border_width: int) -> StyleBoxFlat:
		var style := StyleBoxFlat.new()
		style.bg_color = fill
		style.border_color = border
		style.set_border_width_all(border_width)
		# Square along the bottom: the open tab reads as continuous with the row beneath it.
		style.corner_radius_top_left = 5
		style.corner_radius_top_right = 5
		return style


## Emitted on a slot click. The player decides what to do with it (player_controller.gd's
## set_selected_build_piece()) — this file never touches BuildGhost or BuildService directly.
signal piece_selected(piece_id: StringName)
## Emitted when the open tab changes, for checks and for anything that later wants to react to it.
signal category_changed(category: StringName)

var _root: Control
var _bar_center: CenterContainer
var _panel: PanelContainer
var _tab_row: HBoxContainer
var _row: HBoxContainer
var _hint_label: Label
var _selection_label: Label
var _status_label: Label
## Every slot, in tab order then registry order within a tab. The flat list the focus chain, the
## check API (`slot_piece_id`) and `set_selected_piece` all walk; only the open tab's slots are ever
## visible.
var _slots: Array[PieceSlot] = []
## Tab keys in `BuildableDef.CATEGORY_ORDER` order, then anything unlisted alphabetically. Derived
## from what the registry actually holds, so a tab with no authored pieces never appears.
var _categories: Array[StringName] = []
## category -> its slots, in the order they were registered.
var _slots_by_category: Dictionary[StringName, Array] = {}
## category -> its tab button in `_tab_row`.
var _tabs: Dictionary[StringName, PanelContainer] = {}
var _open_category: StringName = &""
## Mirrors BuildGhost's own `_snapping`, pushed in through set_snapping(). Same default, because the
## bar is built before the player ever presses the toggle and must not open showing the wrong mode.
var _snapping: bool = true
var _snap_label: Label
var _selected_piece_id: StringName = &""


func _ready() -> void:
	layer = 41
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	_present_snapping()
	_populate_slots()
	var service: Node = get_node_or_null(^"/root/BuildService")
	if service != null:
		service.connect(&"build_confirmed", _on_build_confirmed)


func _exit_tree() -> void:
	var service: Node = get_node_or_null(^"/root/BuildService")
	if service != null and service.is_connected(&"build_confirmed", _on_build_confirmed):
		service.disconnect(&"build_confirmed", _on_build_confirmed)


## F-483: the whole reason a piece can be picked at all. Build mode owns the cursor, so every path
## in here is a bound action — the picker is driven from the keys the hand is already on, never from
## a pointer it does not have.
##
## `_input` rather than `_unhandled_input`, because a Control focus chain must not get first refusal
## on a press the bar is claiming; and consuming, so nothing downstream acts on it twice.
##
## The bindings deliberately collide with nothing. The first cut shared the shoulder buttons with
## `hotbar_prev`/`hotbar_next` on the theory that this node — built by the player, deeper in the
## tree than the `InventoryUI` autoload — would win `_input`'s reverse-tree-order propagation and
## consume them for the duration of build mode. It does not: `InventoryUI` sees them first, steps
## the hotbar, and returns WITHOUT consuming, so the press then also reached here. One button, two
## effects; `tools/build_picker_check.gd` caught it swapping the held item out from under a player
## who was only changing walls. So piece stepping is the wheel plus R3/BACK, the only pad buttons
## still genuinely free, and `step_piece` wraps across tabs so those two reach the whole set. The
## tab keys are keyboard-only for the same reason — there was nothing left to bind them to.
func _input(event: InputEvent) -> void:
	if not is_active() or get_viewport().is_input_handled():
		return
	if event.is_action_pressed(&"build_piece_next"):
		step_piece(1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"build_piece_prev"):
		step_piece(-1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"build_category_next"):
		step_category(1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"build_category_prev"):
		step_category(-1)
		get_viewport().set_input_as_handled()


## The player calls this on entering/leaving build mode. Never decided here.
func set_active(active: bool) -> void:
	_bar_center.visible = active
	if active:
		# The picker's own bindings lead, because F-483 was a discoverability failure as much as an
		# input one: nothing on screen had ever said how to change the piece.
		_show_status(
			"wheel piece  ·  Z / C tab  ·  R rotate  ·  V snapping  ·  click place  ·  "
			+ "right-click destroy",
			false,
		)


func set_selected_piece(piece_id: StringName) -> void:
	_selected_piece_id = piece_id
	# F-483: open the tab the selection lives in. Without this, `toggle_build_mode()`'s auto-pick —
	# or any future code path that selects a piece directly — could arm a piece the bar is not
	# showing, and the row would sit there marking nothing while the ghost previewed something else.
	var owning: StringName = _category_of(piece_id)
	if owning != &"" and owning != _open_category:
		_open_category = owning
		_present_category()
		category_changed.emit(_open_category)
	for slot: PieceSlot in _slots:
		var armed: bool = slot.piece_id == piece_id
		slot.present(armed)
		if armed:
			_present_selection(slot)


## The line under the row: what is armed, and what it will cost to place. Its own line rather than
## eight of them in the slots — see `_build_contents`'s note on the row running edge to edge.
func _present_selection(slot: PieceSlot) -> void:
	if _selection_label == null:
		return
	var parts: PackedStringArray = [slot.display_name()]
	if not slot.cost_text.is_empty():
		parts.append(slot.cost_text)
	_selection_label.text = "   ·   ".join(parts)


## Moves the selection `direction` steps, wrapping. Walks `_slots` — the WHOLE set in tab order —
## rather than only the open tab, so stepping off the end of a tab carries you into the next one and
## `set_selected_piece` brings that tab open behind you.
##
## That is deliberate, and it is what makes the picker complete on a gamepad. The bindings for this
## are two buttons (R3 and BACK — see the note in `_input`, the shoulders were not available), and
## `build_category_prev`/`build_category_next` are keyboard-only. If stepping stopped at a tab
## boundary, a pad could only ever reach the tab it started on. Wrapping across tabs makes the two
## buttons reach all 22 pieces; Z/C stay a keyboard shortcut for jumping a whole tab at once rather
## than the only way to change one.
##
## Emits `piece_selected` like a click would rather than marking a slot itself — the player is still
## the only thing that decides what the ghost previews (see this file's NETWORK AUTHORITY note), so
## there is exactly one path from "the player chose a piece" to "the ghost changed", whichever input
## started it.
func step_piece(direction: int) -> void:
	if _slots.is_empty():
		return
	var current: int = -1
	for i: int in _slots.size():
		if _slots[i].piece_id == _selected_piece_id:
			current = i
			break
	# -1 (nothing selected yet) steps to the first piece going forward and the last going back,
	# which is what a player pressing the key expects either way.
	var next: int = wrapi(current + direction, 0, _slots.size()) if current >= 0 \
		else (0 if direction > 0 else _slots.size() - 1)
	piece_selected.emit(_slots[next].piece_id)


## Moves to the next/previous tab, wrapping, and selects that tab's first piece — a tab you switched
## to but are not building from would be a mode with no effect until you also pressed the piece key.
func step_category(direction: int) -> void:
	if _categories.size() < 2:
		return
	var current: int = _categories.find(_open_category)
	_open_category = _categories[wrapi(maxi(current, 0) + direction, 0, _categories.size())]
	_present_category()
	category_changed.emit(_open_category)
	var bucket: Array = _open_slots()
	if not bucket.is_empty():
		piece_selected.emit((bucket[0] as PieceSlot).piece_id)


func open_category() -> StringName:
	return _open_category


func category_count() -> int:
	return _categories.size()


func category_at(index: int) -> StringName:
	return _categories[index] if index >= 0 and index < _categories.size() else &""


## How many pieces the open tab shows — i.e. how many slots are on screen at once, which is the
## number F-483 exists to keep small.
func visible_slot_count() -> int:
	return _open_slots().size()


func _open_slots() -> Array:
	return _slots_by_category.get(_open_category, [])


func _category_of(piece_id: StringName) -> StringName:
	for category: StringName in _categories:
		for slot: PieceSlot in (_slots_by_category[category] as Array):
			if slot.piece_id == piece_id:
				return category
	return &""


## Pushed by player_controller.gd when the player presses the snap toggle, and never decided here —
## `BuildGhost` owns that state and this only shows it, the same one-way contract `set_active()` and
## `set_selected_piece()` already follow. Called with the ghost's answer, not with a guess, so the
## bar cannot drift out of step with what the ghost is actually doing.
func set_snapping(enabled: bool) -> void:
	_snapping = enabled
	_present_snapping()


func is_snapping() -> bool:
	return _snapping


func _present_snapping() -> void:
	if _snap_label == null:
		return
	_snap_label.text = "SNAP ON — pieces mate to their neighbours" if _snapping \
		else "SNAP OFF — free placement"
	_snap_label.add_theme_color_override(
		"font_color", COLOUR_SNAP_ON if _snapping else COLOUR_SNAP_OFF)


## Fed every physics tick the player is in build mode, straight from BuildGhost's own
## is_valid()/last_reason_text() — this file never re-derives a verdict of its own.
func set_ghost_status(valid: bool, reason_text: String) -> void:
	if reason_text.is_empty():
		return
	_hint_label.text = reason_text
	_hint_label.add_theme_color_override("font_color", COLOUR_MUTED if valid else COLOUR_ERROR)


func is_active() -> bool:
	return _bar_center.visible


func slot_count() -> int:
	return _slots.size()


func slot_piece_id(index: int) -> StringName:
	return _slots[index].piece_id if index >= 0 and index < _slots.size() else &""


## Presses the slot exactly as a click would, so a check exercises the real seam.
func select_slot(index: int) -> void:
	if index < 0 or index >= _slots.size():
		return
	piece_selected.emit(_slots[index].piece_id)


func _build_ui() -> void:
	_root = Control.new()
	_root.name = "BuildBarRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_bar_center = CenterContainer.new()
	_bar_center.name = "BuildBarCenter"
	_bar_center.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	# The band the bar occupies is pinned to its BOTTOM edge, clear of the hotbar (which ends at
	# -92), and sized to the panel rather than to a fixed row height — see `_fit_bar_height()`, and
	# F-477's four-wrapped-rows bug in its doc comment for what happens when the band is too short.
	# F-483's tab strip made it one slot row again, but a taller stack around that row.
	_bar_center.offset_top = -172.0
	_bar_center.offset_bottom = -96.0
	_bar_center.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_bar_center.mouse_filter = Control.MOUSE_FILTER_STOP
	_bar_center.visible = false
	_root.add_child(_bar_center)

	_panel = PanelContainer.new()
	_panel.name = "BuildBarPanel"
	_panel.add_theme_stylebox_override("panel", _panel_style())
	_bar_center.add_child(_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_bottom", 8)
	_panel.add_child(margin)

	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 4)
	margin.add_child(stack)

	# F-483. F-477 made every crafting station buildable, taking the set from 15 pieces to 22, and
	# the HFlowContainer that held them wrapped to four rows ~340 px tall — right over the ghost.
	# Tabs solve that at the source rather than by tuning a width: the row shows ONE category, so
	# it stays one row however large the set gets. The strip is centred above the row it belongs to.
	_tab_row = HBoxContainer.new()
	_tab_row.name = "BuildTabs"
	_tab_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_tab_row.add_theme_constant_override("separation", 3)
	stack.add_child(_tab_row)

	_row = HBoxContainer.new()
	_row.name = "BuildSlots"
	_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_row.add_theme_constant_override("separation", 4)
	# Width is a FLOOR on the widest tab, not a wrap point — see ROW_WIDTH_PX. Pinning the height
	# too means switching tabs never nudges the bar up or down under the crosshair.
	_row.custom_minimum_size = Vector2(ROW_WIDTH_PX, ROW_HEIGHT_PX)
	stack.add_child(_row)

	# F-483: the armed piece's own line. What the slot's cost label used to say, for the ONE piece
	# it is true of, with room to say it in full — and the name too, since the slot ellipsizes.
	_selection_label = Label.new()
	_selection_label.name = "SelectedPiece"
	_selection_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_selection_label.add_theme_font_size_override("font_size", 13)
	_selection_label.add_theme_color_override("font_color", COLOUR_TEXT)
	stack.add_child(_selection_label)

	_hint_label = Label.new()
	_hint_label.name = "GhostHint"
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_label.add_theme_font_size_override("font_size", 12)
	_hint_label.add_theme_color_override("font_color", COLOUR_MUTED)
	stack.add_child(_hint_label)

	# Its OWN label rather than a phrase inside the hint: set_ghost_status() rewrites the hint every
	# physics tick from the ghost's verdict, so a mode indicator living there would be erased within a
	# frame of being set. A player toggling snapping has to be able to see the state they toggled to.
	_snap_label = Label.new()
	_snap_label.name = "SnapState"
	_snap_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_snap_label.add_theme_font_size_override("font_size", 11)
	stack.add_child(_snap_label)

	_status_label = Label.new()
	_status_label.name = "Status"
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 10)
	_status_label.add_theme_color_override("font_color", COLOUR_MUTED)
	stack.add_child(_status_label)


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = COLOUR_PANEL
	style.border_color = COLOUR_BORDER
	style.set_border_width_all(1)
	style.set_corner_radius_all(9)
	return style


## Registry.buildables loads once at boot and never changes at runtime (task 3.7 authors more .tres
## files, it does not hot-reload them), so slots are built once here rather than rebuilt on a poll —
## unlike CraftingUI's rows, which change with whichever station is nearby.
func _populate_slots() -> void:
	var registry: Node = get_node_or_null(^"/root/Registry")
	if registry == null:
		return
	var buildables: Dictionary = registry.get(&"buildables")

	# Pass one: bucket by authored category. A def from before F-483 (or one whose category failed
	# validation) still has the export's own default, so there is no unbucketed case to handle.
	for id: StringName in buildables:
		var def: Resource = buildables[id]
		var category: StringName = StringName(String(def.get(&"category")))
		if not _slots_by_category.has(category):
			_slots_by_category[category] = []
			_categories.append(category)
		var slot := PieceSlot.new()
		slot.setup(def, _on_slot_pressed)
		(_slots_by_category[category] as Array).append(slot)

	_categories.sort_custom(_compare_categories)

	# Pass two: add them to the row in tab order, so `_slots` — which the focus chain and the check
	# API both walk — is one linear order that matches what the tabs show.
	for category: StringName in _categories:
		var tab := CategoryTab.new()
		var bucket: Array = _slots_by_category[category]
		tab.setup(category, BuildableDef.category_label(category), bucket.size())
		_tabs[category] = tab
		_tab_row.add_child(tab)
		for slot: PieceSlot in bucket:
			_slots.append(slot)
			_row.add_child(slot)

	_panel.minimum_size_changed.connect(_fit_bar_height)
	_fit_bar_height()
	if not _categories.is_empty():
		_open_category = _categories[0]
	_present_category()


## Keep the bar's bottom edge where it has always been (96 px above the screen bottom, clear of the
## hotbar) and grow the band upward by however tall the panel actually needs to be. Driven by the
## panel's own combined minimum size rather than a slot count, so neither authoring a buildable nor
## adding a tab needs a matching number changed here. Still load-bearing after F-483 pinned the slot
## row to one line: the tab strip, hint, snap state and status line above and below it are five
## stacked children, and a CenterContainer given less height than its content centres the OVERFLOW —
## half of it below the screen edge, which is how F-477's four wrapped rows first rendered.
func _fit_bar_height() -> void:
	if _panel == null or _bar_center == null:
		return
	var needed: float = _panel.get_combined_minimum_size().y
	_bar_center.offset_top = _bar_center.offset_bottom - maxf(needed, 76.0)


## `CATEGORY_ORDER` first, in its order; anything a .tres authored that the constant does not name
## sorts after those, alphabetically — visible immediately rather than silently dropped, so a new
## tab is one .tres field away.
func _compare_categories(a: StringName, b: StringName) -> bool:
	var rank_a: int = BuildableDef.category_rank(a)
	var rank_b: int = BuildableDef.category_rank(b)
	if rank_a != rank_b:
		return rank_a < rank_b
	return String(a) < String(b)


## Shows exactly the open tab's slots and marks its tab. Visibility rather than reparenting: the
## focus chain is wired once across the whole flat list and a hidden Control simply skips its turn.
func _present_category() -> void:
	for category: StringName in _categories:
		var open: bool = category == _open_category
		(_tabs[category] as CategoryTab).present(open)
		for slot: PieceSlot in (_slots_by_category[category] as Array):
			slot.visible = open


func _on_slot_pressed(piece_id: StringName) -> void:
	piece_selected.emit(piece_id)


## Fires for both a place and a destroy request (BuildService.build_confirmed carries no "kind"), so
## the accepted message stays generic rather than claiming "placed" for what might be a destroy.
func _on_build_confirmed(_request_id: int, accepted: bool, reason: String) -> void:
	if accepted:
		_show_status("done" if reason.is_empty() else reason, false)
	else:
		_show_status(reason if not reason.is_empty() else "refused", true)


func _show_status(message: String, error: bool) -> void:
	_status_label.text = message
	_status_label.add_theme_color_override("font_color", COLOUR_ERROR if error else COLOUR_MUTED)
