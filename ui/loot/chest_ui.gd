extends CanvasLayer

## Client-local chest-opening flow. Chest remains the only authority: this UI finds the nearest
## chest, turns [E] into exactly one `request_open()`, and presents whatever `open_confirmed`
## reports — it never predicts a roll or a grant.
##
## ## What this used to be, and why it changed (F-581)
##
## It used to open a full-screen modal listing the granted ids as text rows, taking the cursor and
## joining the D-032 blocking-input interlock. Sequoyah's call: the chest is the loop's headline
## reward moment and deserves a *ceremony*, not a receipt — and a ceremony that stops the game is
## worse than no ceremony at all in a six-player co-op fight. So the reveal moved into the world as
## a slot machine above the chest (`ui/loot/chest_reel.gd`), the itemised "what did I get" moved to
## the shared pickup feed every ground drop already uses (`ui/hud/pickup_hud.gd` through
## `PickupFeedService`), and this file kept only the input and the refusals.
##
## Consequently **nothing here blocks, and nothing here takes the cursor.** It still refuses to open
## a chest while another panel owns the screen, because [E] belongs to that panel then.

const CHEST_GROUP: StringName = &"chest"
const BLOCKING_UI_GROUP: StringName = &"blocks_gameplay_input"
const CHEST_REEL := preload("res://ui/loot/chest_reel.gd")
const MIRE_THEME := preload("res://ui/theme/mire_theme.gd")

const RANGE_POLL_SEC: float = 0.15
## How long a refusal ("you need 12 coins", "locked — you need a Rusted Key") sits on screen. Long
## enough to read while walking away; short enough that it is gone before you get back with the key.
const STATUS_HOLD_SEC: float = 3.0
const STATUS_FADE_SEC: float = 0.4
## Just under the crosshair, where the focus prompt already puts its own line — a refusal is an
## answer to the button you pressed, so it belongs where you were looking when you pressed it.
const STATUS_TOP_FRACTION: float = 0.58


var _root: Control
var _status_panel: PanelContainer
var _status_label: Label
var _status_remaining: float = 0.0
var _poll_accumulator: float = 0.0
var _nearest_chest: Node3D
var _pending_chest: Node3D
var _pending_request_id: int = -1
var _request_in_flight: bool = false
var _reel: Node3D


func _ready() -> void:
	layer = 52
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	_refresh_nearest()


func _process(delta: float) -> void:
	_tick_status(delta)
	_poll_accumulator += delta
	if _poll_accumulator < RANGE_POLL_SEC:
		return
	_poll_accumulator = 0.0
	# The chest scan is pointless while another blocking UI owns the screen (F-099).
	if _other_blocking_ui():
		return
	_refresh_nearest()


func _input(event: InputEvent) -> void:
	if get_viewport().is_input_handled():
		return
	if not event.is_action_pressed(&"interact"):
		return
	var focus_owner: Control = get_viewport().gui_get_focus_owner()
	if focus_owner is LineEdit or focus_owner is TextEdit:
		return
	if try_open_nearest():
		get_viewport().set_input_as_handled()


## The interact path. Returns whether a request was actually sent, so the caller knows whether the
## input was consumed.
func try_open_nearest() -> bool:
	_refresh_nearest()
	if _nearest_chest == null or _other_blocking_ui():
		return false
	if bool(_nearest_chest.get("opened")):
		return false

	_pending_chest = _nearest_chest
	if not _pending_chest.is_connected(&"open_confirmed", _on_open_confirmed):
		_pending_chest.connect(&"open_confirmed", _on_open_confirmed)
	_request_in_flight = true
	_pending_request_id = int(_pending_chest.call("request_open"))
	return true


## Kept as the compatibility seam other panels and checks use to force this UI closed (it is on the
## same "dismiss every overlay" list as InventoryUI and CraftingUI). There is no longer a panel to
## close, so this only clears a pending refusal message.
func set_open(open: bool) -> void:
	if open:
		return
	_status_remaining = 0.0
	_status_panel.visible = false


func is_open() -> bool:
	return _status_panel != null and _status_panel.visible


func nearest_chest() -> Node3D:
	return _nearest_chest


## Whether a reveal is playing right now. The reel is world presentation, not UI state — this exists
## so a check can assert the ceremony happened without reaching into the scene tree.
func is_revealing() -> bool:
	return _reel != null and is_instance_valid(_reel)


## Delegates to FocusPrompt, which draws the prompt now. Still answers the question callers were
## actually asking — "is the player being told this chest can be opened?"
func is_prompt_visible() -> bool:
	var focus: Node = get_node_or_null(^"/root/FocusPrompt")
	if focus == null:
		return false
	return bool(focus.call(&"is_prompt_visible")) and focus.call(&"focus_node") == _nearest_chest


func status_text() -> String:
	return _status_label.text if _status_panel.visible else ""


# ── The reveal ───────────────────────────────────────────────────────────────────────────────────


func _on_open_confirmed(request_id: int, accepted: bool, granted: Dictionary, detail: String) -> void:
	if not _request_in_flight and request_id != _pending_request_id:
		return
	_request_in_flight = false
	if not accepted:
		_show_status(detail)
		return
	if granted.is_empty():
		_show_status("The chest was empty.")
		return
	_spawn_reel(granted)


## One reel at a time: opening a second chest while the first is still spinning replaces the show
## rather than stacking two of them in the same square metre of air.
func _spawn_reel(granted: Dictionary) -> void:
	if _reel != null and is_instance_valid(_reel):
		_reel.queue_free()
	var chest: Node3D = _pending_chest
	if chest == null or not is_instance_valid(chest):
		return
	var reel := Node3D.new()
	reel.set_script(CHEST_REEL)
	reel.name = "ChestReel"
	# Parented to the chest, so the show travels with it and dies with it — a reel outliving the
	# node it belongs to is the shape that leaves orphaned VFX in the world after a run restart.
	chest.add_child(reel)
	reel.global_position = chest.global_position
	reel.call(&"configure", granted)
	_reel = reel


# ── Scan ─────────────────────────────────────────────────────────────────────────────────────────


## Nearest unopened chest within ITS OWN request_range_m, read straight off the node so the prompt
## never disagrees with what request_open() will actually accept.
func _refresh_nearest() -> void:
	var player: Node3D = _local_player()
	var closest: Node3D = null
	var closest_distance_sq: float = INF
	if player != null:
		for node: Node in get_tree().get_nodes_in_group(CHEST_GROUP):
			var chest := node as Node3D
			if chest == null or not is_instance_valid(chest):
				continue
			# Skip opened chests HERE, not just on the winner: an opened chest that is closer than
			# an unopened one otherwise wins the scan, the prompt hides, and [E] refuses even though
			# a perfectly valid chest is also in range (review F-099).
			if bool(chest.get("opened")):
				continue
			var range_m: float = float(chest.get("request_range_m"))
			var distance_sq: float = player.global_position.distance_squared_to(chest.global_position)
			if distance_sq <= range_m * range_m and distance_sq < closest_distance_sq:
				closest = chest
				closest_distance_sq = distance_sq
	_nearest_chest = closest


func _other_blocking_ui() -> bool:
	for node: Node in get_tree().get_nodes_in_group(BLOCKING_UI_GROUP):
		if node != self:
			return true
	return false


func _local_player() -> Node3D:
	for node: Node in get_tree().get_nodes_in_group(&"players"):
		var player := node as Node3D
		if player != null and player.is_multiplayer_authority():
			return player
	return null


# ── Refusal toast ────────────────────────────────────────────────────────────────────────────────


func _show_status(message: String) -> void:
	if message.strip_edges().is_empty():
		return
	_status_label.text = message
	_status_panel.modulate.a = 1.0
	_status_panel.visible = true
	_status_remaining = STATUS_HOLD_SEC + STATUS_FADE_SEC
	_apply_layout()


func _tick_status(delta: float) -> void:
	if _status_remaining <= 0.0:
		return
	_status_remaining -= delta
	if _status_remaining <= 0.0:
		_status_panel.visible = false
		return
	if _status_remaining < STATUS_FADE_SEC:
		_status_panel.modulate.a = _status_remaining / STATUS_FADE_SEC


func _build_ui() -> void:
	_root = Control.new()
	_root.name = "ChestUIRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_status_panel = PanelContainer.new()
	_status_panel.name = "ChestStatus"
	_status_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status_panel.visible = false
	_status_panel.add_theme_stylebox_override("panel",
		MIRE_THEME.panel_style(Color(0.03, 0.055, 0.045, 0.90), MIRE_THEME.ERROR))
	_root.add_child(_status_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_bottom", 8)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status_panel.add_child(margin)

	_status_label = Label.new()
	_status_label.name = "Status"
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 14)
	_status_label.add_theme_color_override("font_color", MIRE_THEME.TEXT)
	_status_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(_status_label)

	get_viewport().size_changed.connect(_apply_layout)
	_apply_layout()


func _apply_layout() -> void:
	if _status_panel == null:
		return
	var screen: Vector2 = get_viewport().get_visible_rect().size
	var size: Vector2 = _status_panel.get_combined_minimum_size()
	_status_panel.size = size
	_status_panel.position = Vector2(
		(screen.x - size.x) * 0.5, screen.y * STATUS_TOP_FRACTION
	)
