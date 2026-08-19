extends CanvasLayer

## Client-local presentation for task 6.7's lose condition (DESIGN.md §5.3: "Losing = all players
## down simultaneously with no revive available, or the Mire consumes the island"). Reacts to
## `EventBus.subscribe_run_wiped` — the same signal `SalvageService` (task 6.6) already consumes to
## bank a death's Salvage fraction — and to `EventBus.subscribe_salvage_banked` for the number that
## banking produces. This file decides nothing about whether the run ended; `DefeatService` does
## that, and fires `run_wiped` identically on every peer (see its own class doc).
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

const EVENT_BUS := preload("res://core/events/event_bus.gd")
const BLOCKING_UI_GROUP: StringName = &"blocks_gameplay_input"

## Indexed by `DefeatService.cause` — a cause this file has never heard of (a future third lose
## condition) still gets a real headline via `.get()`'s default below, not a blank screen.
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
var _detail: Label
var _shown: bool = false


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
	_headline.text = String(CAUSE_HEADLINES.get(cause, DEFAULT_HEADLINE))
	_detail.text = "Cycle %d reached" % cycle
	_overlay.visible = true
	add_to_group(BLOCKING_UI_GROUP)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


## Only the death-banking half of this signal is ours — `extracted == true` is 6.5/6.6's success
## path, a screen this task does not own (nothing shows one yet; see docs/FINDINGS.md).
func _on_salvage_banked(earned: int, total_salvage: int, cycle: int, extracted: bool) -> void:
	if extracted or not _shown:
		return
	_detail.text = "Cycle %d reached — banked %d Salvage (%d total)" % [cycle, earned, total_salvage]


func _defeat_cause() -> StringName:
	var defeat_service: Node = get_node_or_null(^"/root/DefeatService")
	return StringName(defeat_service.get(&"cause")) if defeat_service != null else &""


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
	_headline.add_theme_color_override("font_color", COLOUR_HEADLINE)
	_headline.add_theme_font_size_override("font_size", 40)
	_headline.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_headline)

	_detail = Label.new()
	_detail.add_theme_color_override("font_color", COLOUR_DETAIL)
	_detail.add_theme_font_size_override("font_size", 18)
	_detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_detail)
