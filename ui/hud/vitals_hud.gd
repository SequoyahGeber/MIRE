extends CanvasLayer

## Always-on vitals readout — hp, hunger, stamina — task 3.8. Client-local presentation only
## (ARCHITECTURE.md §2.2, "VFX, audio, camera, UI" row): every number it shows already arrived
## authoritative (hp/hunger via PlayerHealth's owner-only snapshot) or is the owning client's own
## prediction (stamina, per PlayerHealth's own Stamina note) — nothing here mutates state except
## sending a consume request when the player presses the eat key, and even that is a request, not a
## write; PlayerHealth decides what actually happens.
##
## Built in code, no .tscn (same reasoning as ui/inventory/inventory_ui.gd and
## ui/crafting/crafting_ui.gd): an always-on HUD has nowhere safe to live in a hand-authored scene
## file without an exact claim on that scene, and this autoload needs none.
##
## Eating is bound to a raw keycode rather than a new InputMap action (see EAT_KEY below) — the same
## choice ui/inventory/inventory_ui.gd already made for hotbar slots 1-8, and for the same reason:
## project.godot was held by another lane's task when this shipped, and a raw key avoids needing it.

const EAT_KEY: Key = KEY_G
const BLOCKING_UI_GROUP: StringName = &"blocks_gameplay_input"

const BAR_SIZE := Vector2(220.0, 14.0)
const MARGIN := Vector2(24.0, 24.0)
const ROW_GAP: float = 6.0

const COLOUR_HP := Color(0.82, 0.24, 0.22, 1.0)
const COLOUR_HUNGER := Color(0.86, 0.62, 0.20, 1.0)
const COLOUR_STAMINA := Color(0.30, 0.70, 0.86, 1.0)
const COLOUR_TRACK := Color(0.06, 0.08, 0.07, 0.85)
const COLOUR_BORDER := Color(0.345, 0.475, 0.390, 0.9)
const COLOUR_TEXT := Color(0.91, 0.94, 0.89, 1.0)
const COLOUR_HINT := Color(0.80, 0.86, 0.80, 0.92)

var _column: VBoxContainer
var _hp_fill: ColorRect
var _hunger_fill: ColorRect
var _stamina_fill: ColorRect
var _hp_label: Label
var _hint_label: Label

var _max_hp: int = 1
var _max_hunger: float = 1.0
var _max_stamina: float = 1.0


func _ready() -> void:
	layer = 40
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()

	PlayerHealth.local_health_changed.connect(_on_health_changed)
	PlayerHealth.local_hunger_changed.connect(_on_hunger_changed)
	PlayerHealth.local_stamina_changed.connect(_on_stamina_changed)
	InventoryService.local_inventory_changed.connect(_on_inventory_changed)
	get_viewport().size_changed.connect(_apply_layout)

	_on_health_changed(PlayerHealth.local_hp(), PlayerHealth.local_max_hp(), 0, 0.0)
	_on_hunger_changed(PlayerHealth.local_hunger(), PlayerHealth.local_max_hunger())
	_on_stamina_changed(PlayerHealth.local_stamina(), PlayerHealth.local_max_stamina())
	_refresh_hint()
	_apply_layout()


func _exit_tree() -> void:
	if PlayerHealth.local_health_changed.is_connected(_on_health_changed):
		PlayerHealth.local_health_changed.disconnect(_on_health_changed)
	if PlayerHealth.local_hunger_changed.is_connected(_on_hunger_changed):
		PlayerHealth.local_hunger_changed.disconnect(_on_hunger_changed)
	if PlayerHealth.local_stamina_changed.is_connected(_on_stamina_changed):
		PlayerHealth.local_stamina_changed.disconnect(_on_stamina_changed)
	if InventoryService.local_inventory_changed.is_connected(_on_inventory_changed):
		InventoryService.local_inventory_changed.disconnect(_on_inventory_changed)


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key: InputEventKey = event
	if not key.pressed or key.echo or key.keycode != EAT_KEY:
		return
	if get_viewport().is_input_handled():
		return
	if get_tree().get_first_node_in_group(BLOCKING_UI_GROUP) != null:
		return
	if PlayerHealth.local_is_downed() or PlayerHealth.local_is_dead():
		return
	var item_id: StringName = _selected_consumable_id()
	if item_id == &"":
		return
	PlayerHealth.request_consume_item(item_id)
	get_viewport().set_input_as_handled()


## Polled rather than signalled: InventoryUI has no "selection changed" signal (its own hotbar
## select is a raw-key handler too), and this is cheap enough to run every frame. Re-applies layout
## too, since the hint label toggling visible changes the column's height.
func _process(_delta: float) -> void:
	_refresh_hint()
	_apply_layout()


# ── Build ──────────────────────────────────────────────────────────────────────────────────────────


func _build_ui() -> void:
	var root := Control.new()
	root.name = "VitalsHudRoot"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	_column = VBoxContainer.new()
	_column.name = "Column"
	_column.add_theme_constant_override("separation", int(ROW_GAP))
	_column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_column)

	var hp_row := _new_bar_row("HpBar")
	_hp_fill = _add_fill(hp_row, COLOUR_HP)
	_column.add_child(hp_row)
	_hp_label = Label.new()
	_hp_label.add_theme_color_override("font_color", COLOUR_TEXT)
	_hp_label.add_theme_font_size_override("font_size", 13)
	_hp_label.position = Vector2(6.0, -2.0)
	hp_row.add_child(_hp_label)

	var hunger_row := _new_bar_row("HungerBar")
	_hunger_fill = _add_fill(hunger_row, COLOUR_HUNGER)
	_column.add_child(hunger_row)

	var stamina_row := _new_bar_row("StaminaBar")
	_stamina_fill = _add_fill(stamina_row, COLOUR_STAMINA)
	_column.add_child(stamina_row)

	_hint_label = Label.new()
	_hint_label.name = "EatHint"
	_hint_label.add_theme_color_override("font_color", COLOUR_HINT)
	_hint_label.add_theme_font_size_override("font_size", 13)
	_hint_label.visible = false
	_column.add_child(_hint_label)


## Bottom-left anchored by explicit position, not an anchor preset — a preset's anchor point is the
## control's own top-left corner, so a bottom-anchored Control would grow DOWN off-screen instead of
## up from the edge. Recomputed on resize, same pattern as inventory_ui.gd's own responsive layout.
func _apply_layout() -> void:
	if _column == null:
		return
	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	var column_height: float = _column.get_combined_minimum_size().y
	_column.position = Vector2(MARGIN.x, viewport_size.y - MARGIN.y - column_height)


## The track half of one bar row — an empty panel sized BAR_SIZE with the shared border style.
func _new_bar_row(row_name: String) -> PanelContainer:
	var row := PanelContainer.new()
	row.name = row_name
	row.custom_minimum_size = BAR_SIZE
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var track_style := StyleBoxFlat.new()
	track_style.bg_color = COLOUR_TRACK
	track_style.border_color = COLOUR_BORDER
	track_style.set_border_width_all(1)
	track_style.set_corner_radius_all(3)
	row.add_theme_stylebox_override("panel", track_style)

	return row


## The fill half of one bar row, added as a child of [param row]. Returned so the caller can resize
## its width as a fraction of BAR_SIZE.x to show fill level.
func _add_fill(row: PanelContainer, fill_colour: Color) -> ColorRect:
	var fill := ColorRect.new()
	fill.name = "Fill"
	fill.color = fill_colour
	fill.size = BAR_SIZE
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(fill)
	return fill


func _apply_fill(fill: ColorRect, fraction: float) -> void:
	if fill == null:
		return
	fill.size.x = BAR_SIZE.x * clampf(fraction, 0.0, 1.0)


# ── Signal handlers ────────────────────────────────────────────────────────────────────────────────


func _on_health_changed(hp: int, max_hp: int, _state: int, _bleed_out_remaining: float) -> void:
	_max_hp = maxi(max_hp, 1)
	_apply_fill(_hp_fill, float(hp) / float(_max_hp))
	if _hp_label != null:
		_hp_label.text = "%d / %d" % [hp, _max_hp]


func _on_hunger_changed(hunger: float, max_hunger: float) -> void:
	_max_hunger = maxf(max_hunger, 1.0)
	_apply_fill(_hunger_fill, hunger / _max_hunger)


func _on_stamina_changed(stamina: float, max_stamina: float) -> void:
	_max_stamina = maxf(max_stamina, 1.0)
	_apply_fill(_stamina_fill, stamina / _max_stamina)


func _on_inventory_changed(_slots: Array[Dictionary], _revision: int) -> void:
	_refresh_hint()


# ── Eat hint / selection ───────────────────────────────────────────────────────────────────────────


func _refresh_hint() -> void:
	if _hint_label == null:
		return
	var item: ItemDef = _selected_consumable_item()
	_hint_label.visible = item != null
	if item != null:
		_hint_label.text = "[G] Eat %s" % (item.display_name if not item.display_name.is_empty() else String(item.id))


func _selected_consumable_id() -> StringName:
	var item: ItemDef = _selected_consumable_item()
	return item.id if item != null else &""


func _selected_consumable_item() -> ItemDef:
	var slot_index: int = InventoryService.hotbar_start_index() + InventoryUI.selected_hotbar_slot()
	var slots: Array[Dictionary] = InventoryService.local_slots()
	if slot_index < 0 or slot_index >= slots.size():
		return null
	var slot: Dictionary = slots[slot_index]
	var item_id := StringName(String(slot.get("item_id", "")))
	if item_id == &"" or int(slot.get("amount", 0)) <= 0:
		return null
	var item: ItemDef = Registry.get_item(item_id)
	if item == null or item.category != ItemDef.Category.CONSUMABLE:
		return null
	return item
