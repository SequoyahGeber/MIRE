extends CanvasLayer

## F-594 — how many arrows are left.
##
## Sequoyah, from play (2026-08-22): the bow *"shows no arrows remaining count"*. He was right that
## there was none: `ui/hud/` held thirteen scripts and not one of them read an ammo count, so the
## only way to know how many arrows you had was to open the inventory — mid-fight, having just fired
## the one that might have been your last.
##
## It matters more than it would in most games because of F-580's `arrow_save_chance`: a shot does
## not reliably consume an arrow any more, so a player who was counting their own shots is now
## counting wrong. The number has to come from the pack.
##
## ## NETWORK AUTHORITY: none (docs/ARCHITECTURE.md §2.2, "VFX, audio, camera, UI" row)
##
## Client-local presentation end to end, from three things this peer already holds: its own hotbar
## selection, the ranged weapon that slot resolves to, and its own inventory count. Nothing is sent,
## nothing is mutated, no protocol bump.
##
## ## Why it reads the WEAPON's ammo id rather than assuming arrows
##
## `RangedWeaponDef.ammo_item_id` is per weapon — the crossbow fires `bolt`, the sling fires
## `pinecone`, the bows fire `arrow`. A HUD hard-coded to `arrow` would confidently show the wrong
## number for two of the four ranged weapons in the game, which is worse than showing nothing.

const MireTheme := preload("res://ui/theme/mire_theme.gd")

## Only visible while a ranged weapon is actually selected. A permanent ammo readout over a player
## holding an axe is clutter, and MIRE's HUD is deliberately sparse (DESIGN.md §4.1 — you read the
## run's state off the world, not off an overlay).
const MARGIN_PX: int = 24

## Below this the count turns amber, and at zero it turns hostile — the two thresholds a player
## actually acts on. Ten is roughly two engagements' worth at the roster's current arrow costs.
const LOW_AMMO: int = 10

const COLOUR_LOW := Color(0.95, 0.72, 0.28, 1.0)
const COLOUR_EMPTY := Color(0.90, 0.35, 0.30, 1.0)

var _root: HBoxContainer
var _icon: TextureRect
var _count: Label
var _ranged: Node
var _inventory_ui: Node
var _last_key: String = ""


func _ready() -> void:
	layer = 2
	process_mode = Node.PROCESS_MODE_PAUSABLE
	_ranged = get_node_or_null(^"/root/RangedCombatService")
	_inventory_ui = get_node_or_null(^"/root/InventoryUI")

	_root = HBoxContainer.new()
	_root.name = "AmmoReadout"
	_root.add_theme_constant_override(&"separation", MireTheme.GRID)
	_root.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_root.offset_left = -220.0
	_root.offset_top = -64.0
	_root.offset_right = -float(MARGIN_PX)
	_root.offset_bottom = -float(MARGIN_PX)
	_root.alignment = BoxContainer.ALIGNMENT_END
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_icon = TextureRect.new()
	_icon.custom_minimum_size = Vector2(28, 28)
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_icon)

	_count = MireTheme.label("", MireTheme.TITLE, MireTheme.TEXT)
	_count.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_count)

	_root.visible = false


func _process(_delta: float) -> void:
	refresh()


## Split out from `_process` so a check can drive it without waiting on frames — the same seam
## `ChestPlacementService.refresh_current_scene()` exposes for the same reason.
func refresh() -> void:
	if _root == null:
		return
	var weapon: Resource = _selected_ranged_weapon()
	if weapon == null:
		_root.visible = false
		return

	var ammo_id := StringName(String(weapon.get("ammo_item_id")))
	if ammo_id == &"":
		_root.visible = false
		return

	var count: int = InventoryService.local_count(ammo_id)
	_root.visible = true
	# Rebuilding the label and re-fetching the icon every frame would be wasteful and would fight
	# the theme's own font cache, so both are keyed on (ammo, count) and only touched on a change.
	var key := "%s|%d" % [ammo_id, count]
	if key == _last_key:
		return
	_last_key = key

	var item: ItemDef = Registry.get_item(ammo_id)
	_icon.texture = item.icon if item != null else null
	_count.text = str(count)
	if count <= 0:
		_count.add_theme_color_override(&"font_color", COLOUR_EMPTY)
	elif count <= LOW_AMMO:
		_count.add_theme_color_override(&"font_color", COLOUR_LOW)
	else:
		_count.add_theme_color_override(&"font_color", MireTheme.TEXT)


## The ranged weapon in the selected hotbar slot, or null when the player is holding anything else.
func _selected_ranged_weapon() -> Resource:
	if _ranged == null or _inventory_ui == null:
		return null
	var slot: int = int(_inventory_ui.call(&"selected_hotbar_slot"))
	if slot < 0:
		return null
	return _ranged.call(&"ranged_weapon_for_hotbar_index", slot) as Resource
