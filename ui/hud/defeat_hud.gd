extends CanvasLayer

## Client-local presentation for task 6.7's lose condition (DESIGN.md §5.3: "Losing = all players
## down simultaneously with no revive available, or the Mire consumes the island"), extended by
## task 6.8 into the run summary ROADMAP.md names: "headline Cycle number, stats, modifiers drawn,
## Salvage earned". Reacts to `EventBus.subscribe_run_wiped` — the same signal `SalvageService`
## (task 6.6) already consumes to bank a death's Salvage fraction — and to
## `EventBus.subscribe_salvage_banked` for the number that banking produces. This file decides
## nothing about whether the run ended; `DefeatService` does that, and fires `run_wiped` identically
## on every peer (see its own class doc).
##
## ARCHITECTURE.md §2.2 "VFX, audio, camera, UI" row: client-local only, same shape as
## `ui/hud/extraction_hud.gd`. Registered directly in `project.godot`, after `SalvageService` — not
## required for correctness (`extracted == false` alone tells this file the bank was a death, not an
## extraction, regardless of dispatch order), but it means the very first paint already has a real
## banked number instead of a blank line for one frame.
##
## Terminal, like `ExtractionShip.departed`: once shown, this overlay never hides itself again this
## session. Joins `blocks_gameplay_input` (D-032) the moment it shows, same group
## `ui/inventory/inventory_ui.gd`/`ui/lobby/lobby_menu.gd` already use, so `player_controller.gd`'s
## `gameplay_input_allowed()` stops movement/interact for the local player without pausing the tree
## (pausing a multiplayer client would stall networking — see that function's own note).
##
## 6.8 scope decision (no spec block existed for it — see docs/SPECS.md §6.8, written by this task):
## the roadmap line reads as one headline (the Cycle number) plus a stats block with two rows,
## modifiers drawn and Salvage earned — not four separate elements. No new tracking system was
## built: modifiers drawn is read straight off `CycleModifierService.active_modifier_ids()` (task
## 6.2's own framework, already stacked for the run's whole life, nothing to subscribe to), the same
## `get_node_or_null(^"/root/X")` + `.call()`/`.get()` pattern `extraction_hud.gd._format_cost()`
## already uses for a content `Resource` (F-016: never a bare `CycleModifierDef` reference here).

const EVENT_BUS := preload("res://core/events/event_bus.gd")
const BLOCKING_UI_GROUP: StringName = &"blocks_gameplay_input"
const CYCLE_MODIFIER_SERVICE_PATH := ^"/root/CycleModifierService"

## Indexed by `DefeatService.cause` — a cause this file has never heard of (a future third lose
## condition) still gets a real line via `.get()`'s default below, not a blank one.
const CAUSE_HEADLINES: Dictionary = {
	&"team_wipe": "THE CREW HAS FALLEN",
	&"island_consumed": "THE MIRE HAS TAKEN THE ISLAND",
}
const DEFAULT_HEADLINE: String = "THE RUN HAS ENDED"

const COLOUR_BG := Color(0.02, 0.015, 0.03, 0.88)
const COLOUR_HEADLINE := Color(0.86, 0.24, 0.24, 1.0)
const COLOUR_DETAIL := Color(0.85, 0.85, 0.82, 1.0)

var _overlay: ColorRect
var _headline: Label
var _cause_label: Label
var _modifiers_label: Label
var _detail: Label
var _shown: bool = false
## F-235: `SalvageService` (autoload order before `DefeatHud` in `project.godot`) subscribes to
## `run_wiped` first, so its own `salvage_banked` emit — triggered synchronously from inside
## `EventBus.emit_run_wiped()`, before this file's OWN `_on_run_wiped` has run — always used to land
## while `_shown` was still false and get silently dropped by the old `not _shown` guard; nothing
## ever re-fired it, so the real number never appeared. Tracked independently of `_shown` instead, so
## whichever of the two arrives first wins and the second one never clobbers it.
var _salvage_known: bool = false


func _ready() -> void:
	layer = 20
	_build_ui()
	EVENT_BUS.subscribe_run_wiped(_on_run_wiped)
	EVENT_BUS.subscribe_salvage_banked(_on_salvage_banked)


func _exit_tree() -> void:
	EVENT_BUS.unsubscribe_run_wiped(_on_run_wiped)
	EVENT_BUS.unsubscribe_salvage_banked(_on_salvage_banked)


func _on_run_wiped(cycle: int, _world_position: Vector3) -> void:
	if _shown:
		return
	_shown = true
	var cause: StringName = _defeat_cause()
	_headline.text = "CYCLE %d" % cycle
	_cause_label.text = String(CAUSE_HEADLINES.get(cause, DEFAULT_HEADLINE))
	_modifiers_label.text = _modifiers_drawn_summary()
	if not _salvage_known:
		_detail.text = "Tallying Salvage…"
	_overlay.visible = true
	add_to_group(BLOCKING_UI_GROUP)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


## Only the death-banking half of this signal is ours — `extracted == true` is 6.5/6.6's success
## path, a screen `ui/hud/extraction_hud.gd` owns instead (F-238, resolved). Gated on
## `_salvage_known`, not `_shown` (F-235, see that field's own comment) — this can legitimately fire
## before `_on_run_wiped` does.
func _on_salvage_banked(earned: int, total_salvage: int, _cycle: int, extracted: bool) -> void:
	if extracted or _salvage_known:
		return
	_salvage_known = true
	_detail.text = "Salvage earned: %d (%d total)" % [earned, total_salvage]


func _defeat_cause() -> StringName:
	var defeat_service: Node = get_node_or_null(^"/root/DefeatService")
	return StringName(defeat_service.get(&"cause")) if defeat_service != null else &""


## "Modifiers drawn" stat: the run's whole stacked deck (task 6.2's `CycleModifierService`), in draw
## order, by display name — never a bare `CycleModifierDef` reference (F-016). Falls back to the raw
## id if a def somehow failed to load, and to a plain "none" line if the deck never drew (Cycle 1
## defeats, or an exhausted/ineligible deck — `host_draw_modifier()`'s own documented empty case).
func _modifiers_drawn_summary() -> String:
	var service: Node = get_node_or_null(CYCLE_MODIFIER_SERVICE_PATH)
	if service == null:
		return "Modifiers drawn: none"
	var ids: Array = service.call(&"active_modifier_ids")
	if ids.is_empty():
		return "Modifiers drawn: none"
	var names: PackedStringArray = []
	for id: Variant in ids:
		var def: Resource = service.call(&"def_for", id) as Resource
		var display_name: String = String(def.get(&"display_name")) if def != null else ""
		names.append(display_name if not display_name.is_empty() else String(id))
	return "Modifiers drawn: %s" % ", ".join(names)


func _build_ui() -> void:
	_overlay = ColorRect.new()
	_overlay.color = COLOUR_BG
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_overlay.visible = false
	add_child(_overlay)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	column.set_anchors_and_offsets_preset(Control.PRESET_CENTER, Control.PRESET_MODE_KEEP_SIZE)
	_overlay.add_child(column)

	_headline = Label.new()
	_headline.add_theme_color_override("font_color", COLOUR_DETAIL)
	_headline.add_theme_font_size_override("font_size", 48)
	_headline.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_headline)

	_cause_label = Label.new()
	_cause_label.add_theme_color_override("font_color", COLOUR_HEADLINE)
	_cause_label.add_theme_font_size_override("font_size", 26)
	_cause_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_cause_label)

	_modifiers_label = Label.new()
	_modifiers_label.add_theme_color_override("font_color", COLOUR_DETAIL)
	_modifiers_label.add_theme_font_size_override("font_size", 18)
	_modifiers_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_modifiers_label)

	_detail = Label.new()
	_detail.add_theme_color_override("font_color", COLOUR_DETAIL)
	_detail.add_theme_font_size_override("font_size", 18)
	_detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_detail)
