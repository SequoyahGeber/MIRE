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
## Eating is bound to the "eat" InputMap action (G / gamepad D-pad down) — task 7.6 promoted it from
## the raw keycode read this file used while project.godot was held by another lane's task. Hotbar
## slots 1-8 in ui/inventory/inventory_ui.gd stay raw keys on purpose (no sane single gamepad button
## per slot); that task instead gained a gamepad "hotbar_prev"/"hotbar_next" cycle of its own.

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
const COLOUR_DOWNED := Color(0.90, 0.32, 0.28, 1.0)
const COLOUR_DEAD := Color(0.72, 0.72, 0.74, 1.0)
const COLOUR_TEAMMATE := Color(0.96, 0.78, 0.30, 1.0)

## Where the state banner sits, as a fraction of viewport height. Above centre on purpose: dead
## centre is where the crosshair and whatever is trying to kill you both are.
const BANNER_HEIGHT_FRACTION: float = 0.32

## ── Blight readout (F-349) ────────────────────────────────────────────────────────────────────────
##
## Reported from play twice, in the same words both times: "the player health just starts dropping
## after a bit and then i die", and then "health starts randomly draining right after starting the
## game". It is not a bug — `PlayerHealth._tick_blight()` drains hp wherever
## `MireGrid.corruption_at()` is at or above `BLIGHT_CORRUPTION_THRESHOLD` — but NOTHING on screen
## said so, and from the inside an unexplained drain is indistinguishable from a defect.
##
## This is the missing half. It is pure presentation and needs no new event or RPC:
## `MireGrid.corruption_at()` documents itself as working on any peer (the host reads its live
## simulation, a client reads WorldDeltaLog's replicated deltas), so every peer can sample the
## ground under its own player and draw the answer. ARCHITECTURE.md §2.2, "VFX, audio, camera, UI":
## client-local, never networked.
##
## The thresholds are READ OFF PlayerHealth rather than copied, so a retune of the mechanic cannot
## silently desync the warning from the damage.
const BLIGHT_VIGNETTE_SHADER := preload("res://ui/hud/blight_vignette.gdshader")

## Ground this corrupted is tainted but not yet draining. Showing it is the point: a player who only
## ever sees the warning at the moment damage starts learns nothing about where it is safe to stand.
## Below PlayerHealth.BLIGHT_CORRUPTION_THRESHOLD by design.
const BLIGHT_WARN_CORRUPTION: float = 0.05

## F-099 warns that anything sampling MireGrid per tick per peer is a cost. 8 Hz is far more often
## than a spreading grid changes and far cheaper than every frame; the tint lerps between samples so
## the eye never sees the step.
const BLIGHT_SAMPLE_INTERVAL_SEC: float = 0.125
## How fast the tint chases a new sample. Slow enough to read as fog rolling over you, fast enough
## that stepping out of Blight is visibly the thing that stopped it.
const BLIGHT_TINT_LERP_PER_SEC: float = 3.5

const COLOUR_BLIGHT := Color(0.62, 0.80, 0.28, 1.0)
const COLOUR_BLIGHT_WARN := Color(0.74, 0.78, 0.52, 1.0)

var _column: VBoxContainer
var _hp_fill: ColorRect
var _hunger_fill: ColorRect
var _stamina_fill: ColorRect
var _hp_label: Label
var _hint_label: Label

var _banner: VBoxContainer
var _banner_title: Label
var _banner_detail: Label

var _max_hp: int = 1
var _max_hunger: float = 1.0
var _max_stamina: float = 1.0

## F-064. Presentation-only mirrors of the state the owner-only snapshot carries. The snapshot lands
## about once a second (PlayerHealth.HUNGER_SNAPSHOT_INTERVAL_SEC throttles it), which is the right
## rate for a reliable RPC and the wrong rate for a countdown a player is watching — so the banner
## re-seeds from every snapshot and counts down locally in between. Nothing here decides anything:
## the host owns when you actually die, this only owns whether you can SEE it coming.
var _state: int = DownedState.State.ALIVE
var _bleed_out_remaining: float = 0.0
## The dead state has no wire field to mirror — respawn_remaining never leaves the host — so this is
## seeded from PlayerHealth's own exported respawn_seconds the moment the state turns DEAD.
var _respawn_remaining: float = 0.0
var _teammates_down: int = 0
## Downed peers other than this one, from the broadcast flag. A set, not a count, because the flag
## arrives per peer and can repeat.
var _downed_peers: Dictionary[int, bool] = {}
## The hotbar index the hint was last built for, and the whole second the banner last showed —
## change detectors so _process rebuilds strings only when what they show moves (F-099).
var _hint_slot: int = -1
var _banner_seconds_shown: int = -1

## F-349 state. `_blight_shown` is the smoothed value actually on screen; `_blight_corruption` is the
## last raw sample. Kept apart so the lerp has somewhere to go.
var _blight_vignette: ColorRect
var _blight_material: ShaderMaterial
var _blight_label: Label
var _blight_corruption: float = 0.0
var _blight_shown: float = 0.0
var _blight_sample_timer: float = 0.0
var _mire_grid_node: Node


func _ready() -> void:
	layer = 40
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()

	PlayerHealth.local_health_changed.connect(_on_health_changed)
	PlayerHealth.local_hunger_changed.connect(_on_hunger_changed)
	PlayerHealth.local_stamina_changed.connect(_on_stamina_changed)
	PlayerHealth.downed_flag_changed.connect(_on_downed_flag_changed)
	InventoryService.local_inventory_changed.connect(_on_inventory_changed)
	get_viewport().size_changed.connect(_apply_layout)

	_on_health_changed(
		PlayerHealth.local_hp(), PlayerHealth.local_max_hp(),
		DownedState.State.ALIVE, 0.0
	)
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
	if PlayerHealth.downed_flag_changed.is_connected(_on_downed_flag_changed):
		PlayerHealth.downed_flag_changed.disconnect(_on_downed_flag_changed)
	if InventoryService.local_inventory_changed.is_connected(_on_inventory_changed):
		InventoryService.local_inventory_changed.disconnect(_on_inventory_changed)


func _input(event: InputEvent) -> void:
	if not event.is_action_pressed(&"eat"):
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
## select is a raw-key handler too). Only the selected index is read every frame — the hint rebuild
## (slot read, Registry lookup, string format) runs when it moves, or when the inventory signals.
## Layout is applied on resize and on hint visibility flips, the two things that change it (F-099).
func _process(delta: float) -> void:
	var selected: int = InventoryUI.selected_hotbar_slot()
	if selected != _hint_slot:
		_hint_slot = selected
		_refresh_hint()
	_tick_banner_countdown(delta)
	_tick_blight(delta)


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

	# F-349: the persistent half of the Blight readout. A tint alone does not survive looking away
	# from it, and "why is my health going down" is exactly the question a player asks while looking
	# somewhere else. This row names the cause in words, right under the bar that is falling.
	_blight_label = Label.new()
	_blight_label.name = "BlightStatus"
	_blight_label.add_theme_color_override("font_color", COLOUR_BLIGHT)
	_blight_label.add_theme_font_size_override("font_size", 13)
	_blight_label.visible = false
	_column.add_child(_blight_label)

	_build_blight_vignette(root)
	_build_banner(root)


## F-349's screen-edge tint. Behind the column and the banner in draw order (added before them), and
## mouse-transparent, so it can never take a click or hide a number.
func _build_blight_vignette(root: Control) -> void:
	_blight_material = ShaderMaterial.new()
	_blight_material.shader = BLIGHT_VIGNETTE_SHADER
	_blight_material.set_shader_parameter(&"intensity", 0.0)

	_blight_vignette = ColorRect.new()
	_blight_vignette.name = "BlightVignette"
	_blight_vignette.color = Color(1.0, 1.0, 1.0, 1.0)
	_blight_vignette.material = _blight_material
	_blight_vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	_blight_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_blight_vignette.visible = false
	root.add_child(_blight_vignette)
	root.move_child(_blight_vignette, 0)


## F-064: the downed/dead state used to be readable only as "the hp bar is empty and the controls
## feel wrong". This is the part of the 2.13 state machine the player is actually allowed to see.
func _build_banner(root: Control) -> void:
	_banner = VBoxContainer.new()
	_banner.name = "StateBanner"
	_banner.alignment = BoxContainer.ALIGNMENT_CENTER
	_banner.add_theme_constant_override("separation", int(ROW_GAP))
	_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_banner.visible = false
	root.add_child(_banner)

	_banner_title = Label.new()
	_banner_title.name = "Title"
	_banner_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner_title.add_theme_font_size_override("font_size", 34)
	_banner_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_banner.add_child(_banner_title)

	_banner_detail = Label.new()
	_banner_detail.name = "Detail"
	_banner_detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner_detail.add_theme_color_override("font_color", COLOUR_TEXT)
	_banner_detail.add_theme_font_size_override("font_size", 16)
	_banner_detail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_banner.add_child(_banner_detail)


## Bottom-left anchored by explicit position, not an anchor preset — a preset's anchor point is the
## control's own top-left corner, so a bottom-anchored Control would grow DOWN off-screen instead of
## up from the edge. Recomputed on resize, same pattern as inventory_ui.gd's own responsive layout.
func _apply_layout() -> void:
	if _column == null:
		return
	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	var column_height: float = _column.get_combined_minimum_size().y
	_column.position = Vector2(MARGIN.x, viewport_size.y - MARGIN.y - column_height)

	# The banner spans the full width and centres its own labels, so horizontal centring costs no
	# measurement — only the vertical placement is computed.
	if _banner != null:
		_banner.size.x = viewport_size.x
		_banner.position = Vector2(0.0, viewport_size.y * BANNER_HEIGHT_FRACTION)


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


func _on_health_changed(hp: int, max_hp: int, state: int, bleed_out_remaining: float) -> void:
	_max_hp = maxi(max_hp, 1)
	_apply_fill(_hp_fill, float(hp) / float(_max_hp))
	if _hp_label != null:
		_hp_label.text = "%d / %d" % [hp, _max_hp]

	var previous_state: int = _state
	_state = state
	if state == DownedState.State.DOWNED:
		# Re-seed rather than accumulate: the host's number is the truth every time it arrives, and
		# _process only fills the gap between arrivals.
		_bleed_out_remaining = bleed_out_remaining
	elif state == DownedState.State.DEAD and previous_state != DownedState.State.DEAD:
		_respawn_remaining = PlayerHealth.respawn_seconds
	_refresh_banner()


## Every peer's downed flag is broadcast to everyone (PlayerHealth's own note: teammates have to see
## who needs help). Counting them is enough for the prompt — the controller already finds the nearest
## one by itself when the hold starts.
func _on_downed_flag_changed(peer_id: int, downed: bool) -> void:
	if peer_id == _local_peer_id():
		return
	var was_down: bool = _downed_peers.has(peer_id)
	if downed:
		_downed_peers[peer_id] = true
	else:
		_downed_peers.erase(peer_id)
	if was_down != downed:
		_teammates_down = _downed_peers.size()
		_refresh_banner()


func _local_peer_id() -> int:
	var peer_id: int = NetTransport.local_peer_id()
	return peer_id if peer_id > 0 else NetConfig.HOST_PEER_ID


# ── State banner (F-064) ───────────────────────────────────────────────────────────────────────────


## Counts the two timers down between snapshots so the numbers move every frame instead of jumping
## once a second. Never crosses a threshold on its own — clamped at zero, and the host's next
## snapshot is what actually changes _state.
func _tick_banner_countdown(delta: float) -> void:
	if _banner == null or not _banner.visible:
		return
	var remaining: float
	match _state:
		DownedState.State.DOWNED:
			_bleed_out_remaining = maxf(_bleed_out_remaining - delta, 0.0)
			remaining = _bleed_out_remaining
		DownedState.State.DEAD:
			_respawn_remaining = maxf(_respawn_remaining - delta, 0.0)
			remaining = _respawn_remaining
		_:
			return
	# The detail line shows whole seconds, so its strings need rebuilding once per second, not once
	# per frame (F-099). State/teammate changes bypass this via _refresh_banner.
	if int(ceil(remaining)) != _banner_seconds_shown:
		_refresh_banner_text()


func _refresh_banner() -> void:
	if _banner == null:
		return
	var showing: bool = _state != DownedState.State.ALIVE or _teammates_down > 0
	_banner.visible = showing
	if not showing:
		return
	_refresh_banner_text()


func _refresh_banner_text() -> void:
	match _state:
		DownedState.State.DOWNED:
			_banner_seconds_shown = int(ceil(_bleed_out_remaining))
			_banner_title.add_theme_color_override("font_color", COLOUR_DOWNED)
			_banner_title.text = "DOWNED"
			_banner_detail.text = "Bleeding out — %ds    ·    a teammate can revive you" % (
				_banner_seconds_shown
			)
		DownedState.State.DEAD:
			_banner_seconds_shown = int(ceil(_respawn_remaining))
			_banner_title.add_theme_color_override("font_color", COLOUR_DEAD)
			_banner_title.text = "YOU DIED"
			_banner_detail.text = "Respawning in %ds" % _banner_seconds_shown
		_:
			_banner_seconds_shown = -1
			_banner_title.add_theme_color_override("font_color", COLOUR_TEAMMATE)
			_banner_title.text = "TEAMMATE DOWN" if _teammates_down == 1 else (
				"%d TEAMMATES DOWN" % _teammates_down
			)
			_banner_detail.text = "Hold %s next to them to revive" % _interact_key_label()


## The bound key rather than a hard-coded letter — the prompt should not start lying the first time
## anyone rebinds interact.
## ── Blight (F-349) ────────────────────────────────────────────────────────────────────────────────


## Samples the ground under the local player and drives the tint and the status row from it.
##
## The two numbers that decide what the player sees are read off PlayerHealth, not copied here:
## `BLIGHT_CORRUPTION_THRESHOLD` is where the drain starts and
## `BLIGHT_HP_DRAIN_PER_SEC_AT_FULL_CORRUPTION` is what it costs at corruption 1.0. Retuning the
## mechanic therefore retunes the warning, which is the whole point — a warning that can drift out
## of step with the damage is worse than none, because it teaches the wrong ground.
func _tick_blight(delta: float) -> void:
	if _blight_material == null:
		return

	_blight_sample_timer -= delta
	if _blight_sample_timer <= 0.0:
		_blight_sample_timer = BLIGHT_SAMPLE_INTERVAL_SEC
		_blight_corruption = _sample_local_corruption()

	# Nothing to show while dead: the defeat overlay owns the screen, and a tint under it reads as a
	# rendering fault rather than as a cause of death.
	var target: float = _blight_corruption if _state == DownedState.State.ALIVE else 0.0
	_blight_shown = move_toward(
		_blight_shown, target, BLIGHT_TINT_LERP_PER_SEC * delta * maxf(1.0, absf(target - _blight_shown))
	)

	var threshold: float = float(PlayerHealth.BLIGHT_CORRUPTION_THRESHOLD)
	# Remap so the vignette is barely there on merely-tainted ground and unmistakable once the drain
	# has started. Two ranges rather than one, because the interesting boundary is the threshold and
	# a single linear ramp puts almost no visual distance either side of it.
	var display: float = 0.0
	if _blight_shown >= threshold:
		display = 0.42 + 0.58 * clampf(
			inverse_lerp(threshold, 1.0, _blight_shown), 0.0, 1.0)
	elif _blight_shown > BLIGHT_WARN_CORRUPTION:
		display = 0.34 * clampf(
			inverse_lerp(BLIGHT_WARN_CORRUPTION, threshold, _blight_shown), 0.0, 1.0)

	# Always write the parameter, not just while visible: a hidden rect holding the last intensity
	# flashes that stale value for one frame the moment it comes back, which is the exact failure
	# mode this readout must not have — a flicker on the edge of the screen reads as a rendering
	# fault, and the player has been told that pattern means "you are being damaged".
	_blight_material.set_shader_parameter(&"intensity", display)
	var showing: bool = display > 0.005
	if _blight_vignette.visible != showing:
		_blight_vignette.visible = showing

	_refresh_blight_label(threshold)


func _refresh_blight_label(threshold: float) -> void:
	if _blight_label == null:
		return
	if _state != DownedState.State.ALIVE or _blight_corruption <= BLIGHT_WARN_CORRUPTION:
		if _blight_label.visible:
			_blight_label.visible = false
		return

	if _blight_corruption < threshold:
		_blight_label.add_theme_color_override("font_color", COLOUR_BLIGHT_WARN)
		_blight_label.text = "Tainted ground"
	else:
		# The rate is the number that turns "random damage" into a mechanic you can reason about:
		# it tells you both that the ground is the cause and that moving to cleaner ground helps.
		var rate: float = float(
			PlayerHealth.BLIGHT_HP_DRAIN_PER_SEC_AT_FULL_CORRUPTION) * _blight_corruption
		_blight_label.add_theme_color_override("font_color", COLOUR_BLIGHT)
		_blight_label.text = "BLIGHT  −%.1f hp/s   ·   move to clean ground" % rate
	_blight_label.visible = true
	_apply_layout()


## Corruption under this peer's own player, or 0 when there is no player or no grid to ask. Works on
## host and client alike — see MireGrid.corruption_at()'s own header.
func _sample_local_corruption() -> float:
	var body: Node3D = _local_player_body()
	if body == null:
		return 0.0
	var grid: Node = _mire_grid()
	if grid == null:
		return 0.0
	return clampf(float(grid.call(&"corruption_at", body.global_position)), 0.0, 1.0)


func _local_player_body() -> Node3D:
	for node: Node in get_tree().get_nodes_in_group(&"players"):
		var player := node as Node3D
		if player != null and player.is_multiplayer_authority():
			return player
	return null


## Path-resolved and cached, not preloaded: MireGrid registers after this autoload (the same F-011
## ordering PlayerHealth's own `_mire_grid()` documents).
func _mire_grid() -> Node:
	if _mire_grid_node == null or not is_instance_valid(_mire_grid_node):
		_mire_grid_node = get_node_or_null(^"/root/MireGrid")
	return _mire_grid_node


## Test seam: drive the readout without a MireGrid or a player body. Used by tools/blight_hud_check.gd.
func force_blight_sample(corruption: float) -> void:
	_blight_corruption = clampf(corruption, 0.0, 1.0)
	_blight_shown = _blight_corruption
	_blight_sample_timer = BLIGHT_SAMPLE_INTERVAL_SEC
	_tick_blight(0.0)


func blight_vignette_intensity() -> float:
	if _blight_material == null:
		return 0.0
	return float(_blight_material.get_shader_parameter(&"intensity"))


func blight_status_text() -> String:
	if _blight_label == null or not _blight_label.visible:
		return ""
	return _blight_label.text


func _interact_key_label() -> String:
	for event: InputEvent in InputMap.action_get_events(&"interact"):
		var key := event as InputEventKey
		if key != null:
			return key.as_text_physical_keycode().to_upper()
	return "INTERACT"


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
	var showing: bool = item != null
	if showing:
		_hint_label.text = "[%s] Eat %s" % [
			_eat_key_label(),
			item.display_name if not item.display_name.is_empty() else String(item.id),
		]
	if _hint_label.visible != showing:
		_hint_label.visible = showing
		# The hint toggling is the one non-resize thing that changes the column's height.
		_apply_layout()


## Same "the prompt should not start lying the first time anyone rebinds the key" reasoning as
## _interact_key_label(). "eat" always carries at least one InputEventKey (its authored default),
## so the "EAT" fallback below only ever fires against a hand-rolled action with no keyboard event.
func _eat_key_label() -> String:
	for event: InputEvent in InputMap.action_get_events(&"eat"):
		var key := event as InputEventKey
		if key != null:
			return key.as_text_physical_keycode().to_upper()
	return "EAT"


func _selected_consumable_id() -> StringName:
	var item: ItemDef = _selected_consumable_item()
	return item.id if item != null else &""


func _selected_consumable_item() -> ItemDef:
	# One slot read, not a whole-array snapshot (F-099); &"" already covers empty/exhausted slots.
	var slot_index: int = InventoryService.hotbar_start_index() + InventoryUI.selected_hotbar_slot()
	var item_id: StringName = InventoryService.local_item_id(slot_index)
	if item_id == &"":
		return null
	var item: ItemDef = Registry.get_item(item_id)
	if item == null or item.category != ItemDef.Category.CONSUMABLE:
		return null
	return item
