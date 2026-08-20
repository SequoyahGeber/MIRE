extends Node

## PauseMenu — MENU-5: the in-run menu (docs/MENU.md §6.1).
## Register as autoload `PauseMenu` → res://ui/menu/pause_menu.gd, AFTER `MenuStack` (it subscribes
## to that autoload's `cancel_at_root` signal in `_ready()`).
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2): none — client-local UI. Abandoning a run routes
## into `DefeatService`, which already owns that decision and its replication; this file only asks.
##
## ## It is an overlay, and the simulation never stops
##
## "PAUSED — the Mire isn't." Pausing the tree in a listen-server co-op game would stall networking
## for everyone (`player_controller.gd`'s `gameplay_input_allowed()` comment already says exactly
## this, which is why the shipped panels block INPUT rather than calling `get_tree().paused`). So
## this is one rule for solo and co-op both, with no divergent path: the world keeps running, you
## can be eaten while reading the menu, and you deserve it.
##
## Solo pause was considered and deliberately not built (docs/MENU.md §12). If solo playtests ask
## for it, the fix is host-side `Engine.time_scale` gated behind this screen — about a session's
## work — and it stays out until someone actually wants it.
##
## ## How Esc reaches it
##
## `MenuStack` owns `ui_cancel` project-wide. With an empty stack it emits `cancel_at_root`, and
## this file answers by pushing itself IF a run is in progress. The stack consumes the press only
## because a listener responded — which is how the pause menu claims Esc in-run without `MenuStack`
## knowing anything about runs, and without touching the player controller's input handling.
##
## "In a run" is decided by the absence of the front end (group `mire_frontend`), not by asking a
## gameplay service. A run is exactly "the front end is not on screen": that is true on the first
## frame of landfall, before any Cycle has advanced or any session exists, which a
## `CycleService.current_cycle() > 0` test would get wrong for the first several minutes of every
## solo run.

const MireTheme := preload("res://ui/theme/mire_theme.gd")

const FRONTEND_GROUP: StringName = &"mire_frontend"

var _screen: Control


func _ready() -> void:
	var stack: Node = _stack()
	if stack != null and stack.has_signal("cancel_at_root"):
		stack.connect("cancel_at_root", _on_cancel_at_root)


# ── Public API (the check drives these; Esc calls the same paths) ─────────────────────────────────


## True when a run is on screen — i.e. the front end is not.
func run_in_progress() -> bool:
	var tree: SceneTree = get_tree()
	if tree == null:
		return false
	return tree.get_nodes_in_group(FRONTEND_GROUP).is_empty()


func is_open() -> bool:
	return _screen != null and is_instance_valid(_screen)


func open() -> void:
	if is_open():
		return
	var stack: Node = _stack()
	if stack == null:
		return
	_screen = PauseScreen.new()
	_screen.setup(self)
	_screen.tree_exited.connect(_on_screen_closed)
	stack.call("push", _screen, true)


func close() -> void:
	if not is_open():
		return
	var stack: Node = _stack()
	if stack != null and bool(stack.call("has_screen", _screen)):
		stack.call("pop")
	_screen = null


func request_invite() -> void:
	var lobby: Node = get_node_or_null(^"/root/SteamLobby")
	if lobby != null and lobby.has_method("open_invite_overlay") and bool(lobby.call("open_invite_overlay")):
		return
	var stack: Node = _stack()
	if stack != null:
		stack.call("toast", "No lobby to invite anyone to — you're playing solo.", true)


func request_settings() -> void:
	var stack: Node = _stack()
	if stack == null:
		return
	const SETTINGS_PATH: String = "res://ui/frontend/settings_screen.gd"
	if not ResourceLoader.exists(SETTINGS_PATH):
		stack.call("toast", "Settings isn't built yet.", true)
		return
	# Pushed ON TOP of the pause screen rather than replacing it, so backing out of settings lands
	# where the player was — the whole reason the front end is a stack.
	var script: GDScript = load(SETTINGS_PATH)
	stack.call("push", script.new(), true)


## The numbers this dialog quotes are the real ones: what a death banks right now, at this Cycle,
## with this run's milestones counted. A confirmation that says "are you sure?" without saying what
## it costs is a confirmation the player learns to click through.
func abandon_summary() -> Dictionary:
	var salvage: Node = get_node_or_null(^"/root/SalvageService")
	var cycle: int = _current_cycle()
	if salvage == null or not salvage.has_method("reward_for_cycle"):
		return {"cycle": cycle, "full": 0, "banked": 0}
	var full: int = int(salvage.call("reward_for_cycle", cycle))
	var fraction: float = float(salvage.get("DEATH_BANK_FRACTION")) if salvage.get("DEATH_BANK_FRACTION") != null else 0.5
	return {"cycle": cycle, "full": full, "banked": int(round(float(full) * fraction))}


## Abandoning is a wipe you chose: it banks the death fraction and ends the run, which is exactly
## what `DefeatService` already does. Routing through it rather than inventing a second ending path
## means the summary screen, the Salvage bank and the Steam stats all see one kind of event.
func request_abandon() -> void:
	var stack: Node = _stack()
	var summary: Dictionary = abandon_summary()
	if stack == null:
		return
	stack.call(
		"confirm",
		"Swim home?",
		"You'll bank %d of the %d Salvage you're carrying. The others sail on without you."
			% [int(summary["banked"]), int(summary["full"])],
		"SWIM HOME",
		"KEEP FIGHTING",
		_abandon_now,
		true,
	)


func request_quit_to_title() -> void:
	var stack: Node = _stack()
	if stack == null:
		return
	var host: bool = _is_host()
	stack.call(
		"confirm",
		"Quit to the title?",
		"This ends the run for everyone." if host else "You'll leave; the others sail on.",
		"QUIT TO TITLE",
		"STAY",
		_quit_to_title_now,
		true,
	)


# ── Internals ─────────────────────────────────────────────────────────────────────────────────────


func _on_cancel_at_root() -> void:
	if run_in_progress():
		open()


func _on_screen_closed() -> void:
	_screen = null


func _abandon_now() -> void:
	var defeat: Node = get_node_or_null(^"/root/DefeatService")
	if defeat != null and defeat.has_method("request_abandon"):
		defeat.call("request_abandon")
		return
	# No abandon path on DefeatService yet: leave the session, which ends the run for this peer
	# without inventing a second, divergent ending. Says so rather than appearing to do nothing.
	_leave_session()
	var stack: Node = _stack()
	if stack != null:
		stack.call("toast", "Left the run.", false)


func _quit_to_title_now() -> void:
	_leave_session()
	var stack: Node = _stack()
	if stack != null:
		stack.call("pop_all")
	var frontend_scene: String = "res://levels/frontend.tscn"
	if ResourceLoader.exists(frontend_scene):
		get_tree().change_scene_to_file(frontend_scene)


func _leave_session() -> void:
	var lobby: Node = get_node_or_null(^"/root/SteamLobby")
	if lobby != null and lobby.has_method("in_lobby") and bool(lobby.call("in_lobby")):
		lobby.call("leave")
		return
	var transport: Node = get_node_or_null(^"/root/NetTransport")
	if transport != null and transport.has_method("is_active") and bool(transport.call("is_active")):
		transport.call("leave")


func _is_host() -> bool:
	var transport: Node = get_node_or_null(^"/root/NetTransport")
	if transport == null or not transport.has_method("is_active") or not bool(transport.call("is_active")):
		return true
	var lobby: Node = get_node_or_null(^"/root/SteamLobby")
	if lobby == null or not lobby.has_method("lobby_owner_id"):
		return true
	return int(lobby.call("lobby_owner_id")) == int(lobby.call("local_steam_id"))


func _current_cycle() -> int:
	var cycle: Node = get_node_or_null(^"/root/CycleService")
	if cycle != null and cycle.has_method("current_cycle"):
		return int(cycle.call("current_cycle"))
	return 1


func _stack() -> Node:
	var loop: MainLoop = Engine.get_main_loop()
	if not (loop is SceneTree):
		return null
	var tree: SceneTree = loop
	return tree.root.get_node_or_null(^"MenuStack") if tree.root != null else null


## The panel itself. An inner class for the same reason the confirm dialog is one: nothing else ever
## builds it, and it has no life apart from the autoload that owns it.
class PauseScreen extends Control:
	const Kit := preload("res://ui/theme/mire_theme.gd")

	var _menu: Node
	var _resume_button: Button

	func setup(menu: Node) -> void:
		_menu = menu
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

		var centre := CenterContainer.new()
		centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		add_child(centre)

		var panel: PanelContainer = Kit.panel()
		panel.custom_minimum_size = Vector2(420.0, 0.0)
		centre.add_child(panel)

		var column: VBoxContainer = Kit.column(Kit.GRID)
		panel.add_child(column)

		var heading: Label = Kit.label("PAUSED", Kit.HEADLINE, Kit.TEXT)
		heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		column.add_child(heading)
		# The joke IS the rule: this menu does not stop the world, and saying so is cheaper than a
		# player discovering it by dying with the menu open.
		column.add_child(Kit.paragraph("the Mire isn't.", Kit.CAPTION, Kit.MUTED))
		column.add_child(Kit.separator())

		_resume_button = Kit.button("RESUME", _resume, Kit.Variant.PRIMARY)
		column.add_child(_resume_button)

		var invite: Button = Kit.button("INVITE FRIENDS", func() -> void: _menu.call("request_invite"))
		column.add_child(invite)

		var settings: Button = Kit.button("SETTINGS", func() -> void: _menu.call("request_settings"))
		column.add_child(settings)

		column.add_child(Kit.separator())

		var abandon: Button = Kit.button(
			"ABANDON RUN", func() -> void: _menu.call("request_abandon"), Kit.Variant.DESTRUCTIVE
		)
		column.add_child(abandon)

		var quit: Button = Kit.button(
			"QUIT TO TITLE", func() -> void: _menu.call("request_quit_to_title"), Kit.Variant.DESTRUCTIVE
		)
		column.add_child(quit)

		Kit.wire_chain([_resume_button, invite, settings, abandon, quit])

	func menu_default_focus() -> Control:
		return _resume_button

	func _resume() -> void:
		_menu.call("close")
