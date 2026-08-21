extends Node3D

## Frontend — MENU-3: the root of the front end, and the scene MIRE boots into (docs/MENU.md §4).
##
## Owns three things and no more: the live backdrop, the title screen pushed onto `MenuStack`, and
## the routing table that says what each choice does. Screens themselves stay layouts that emit
## signals (see `title_screen.gd`), so "what PLAY means" is decided in exactly one place and can
## change — as it will when the expedition dock lands — without touching a screen's layout code.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2): none — client-local UI and scene routing. This
## file opens no session and replicates nothing; starting a run hands off to the world scene, which
## brings up the session through the paths that already own it.
##
## ## The launch bypass, and why it is a hard requirement rather than a convenience
##
## Every headless check, every `-- host` / `-- client` two-process test and every render probe in
## `tools/` boots this project expecting to act immediately. If the front end became the main scene
## and always showed a title screen, all of that would stop at a menu and hang. So before it builds
## anything, `_ready()` asks `_launch_bypasses_frontend()` whether this process was started with a
## flag that means business — the same flags `core/dev/dev_launch.gd` parses, read the same way —
## and if so it goes straight to the world scene and never shows a menu at all.
##
## That bypass is MENU-3's acceptance gate: the front end may not cost the project a single check.
##
## ## What is deliberately NOT done here yet
##
## `project.godot`'s `run/main_scene` still points at the world, not at this scene. Task 4.19 is
## mid-cutover on exactly that setting (Hollowmere → procedural), and two agents editing the boot
## scene at once is how you get a project that boots into nothing. The flip is one line, and it is
## the only thing standing between this file and being the front door — see docs/MENU.md §11 and
## this task's hand-off note for the exact change and the checks to re-run after it.

const MireTheme := preload("res://ui/theme/mire_theme.gd")
const TitleScreen := preload("res://ui/frontend/title_screen.gd")
const TitleBackdrop := preload("res://ui/frontend/backdrop.gd")

## Where PLAY goes. Points at the procedural island because that is where 4.19's cutover lands the
## shipped world; `_world_scene_path()` falls back if it is not there, so this file cannot be the
## reason a boot fails.
const WORLD_SCENE_PATH: String = "res://levels/procedural_island.tscn"
const WORLD_SCENE_FALLBACK: String = "res://levels/hollowmere.tscn"

## Marks "the front end is on screen". `ui/menu/pause_menu.gd` treats the ABSENCE of this group as
## the definition of being in a run — true from the first frame of landfall, which a Cycle-count or
## session test would get wrong for the first several minutes of every solo run.
const FRONTEND_GROUP: StringName = &"mire_frontend"

## Screens that land in later tasks. Bound by path at press time rather than preloaded, so this
## routing table is already correct for screens that do not exist yet: the moment the file appears,
## the button works, with no edit here. A missing screen says so out loud rather than doing nothing,
## which is the failure D-032's "silently refuse to open" produced and this front end exists to fix.
const SETTINGS_SCREEN_PATH: String = "res://ui/frontend/settings_screen.gd"
const UNLOCKS_SCREEN_PATH: String = "res://ui/frontend/salvage_bench_screen.gd"
const EXPEDITION_SCREEN_PATH: String = "res://ui/frontend/expedition_screen.gd"

var _backdrop: Node3D
var _title: Control
var _bypassed: bool = false


func _ready() -> void:
	if _launch_bypasses_frontend():
		_bypassed = true
		_begin_run()
		return

	# The marker the pause menu reads to know a run is NOT on screen (see `ui/menu/pause_menu.gd`).
	# Membership of this group is the definition of "the front end is up", so it is joined before
	# anything else is built and released implicitly when this scene is freed on the way to a run.
	add_to_group(FRONTEND_GROUP)

	suspend_gameplay_overlays()
	_backdrop = TitleBackdrop.new()
	_backdrop.name = "Backdrop"
	add_child(_backdrop)

	_title = TitleScreen.new()
	_title.name = "TitleScreen"
	_title.play_requested.connect(request_play)
	_title.unlocks_requested.connect(request_unlocks)
	_title.settings_requested.connect(request_settings)
	_title.credits_requested.connect(request_credits)
	_title.quit_requested.connect(request_quit)

	var stack: Node = _stack()
	if stack != null:
		# free_on_pop = false: the title is the floor of the stack for the life of the front end.
		stack.call("push", _title, false)


# ── Public API (the check drives these; the title screen's signals call the same paths) ───────────


func was_bypassed() -> bool:
	return _bypassed


func title_screen() -> Control:
	return _title


func backdrop() -> Node3D:
	return _backdrop


## Until the expedition dock exists this starts a run directly, which is exactly what the shipped
## front end does today. Once `expedition_screen.gd` lands, the dock is pushed instead and IT calls
## `enter_world()` when the host sets sail — no change needed here beyond the file appearing.
func request_play() -> void:
	if ResourceLoader.exists(EXPEDITION_SCREEN_PATH):
		_push_screen(EXPEDITION_SCREEN_PATH, "the dock")
		return
	_begin_run()


func request_unlocks() -> void:
	_push_screen(UNLOCKS_SCREEN_PATH, "the salvage bench")


func request_settings() -> void:
	_push_screen(SETTINGS_SCREEN_PATH, "settings")


func request_credits() -> void:
	var stack: Node = _stack()
	if stack != null:
		stack.call("push", CreditsScreen.new(), true)


func request_quit() -> void:
	var stack: Node = _stack()
	if stack == null:
		get_tree().quit()
		return
	stack.call(
		"confirm",
		"Quit?",
		"The bog will keep.",
		"QUIT",
		"STAY",
		func() -> void: get_tree().quit(),
		true,
	)


## Leaves the front end and loads the world. Pops the whole menu stack first: `MenuStack` is an
## autoload, so its screens outlive a scene change and would otherwise still be sitting over the
## island — holding the cursor and the gameplay-input gate — once the run started.
func enter_world() -> void:
	_begin_run()


# ── Internals ─────────────────────────────────────────────────────────────────────────────────────


## Every gameplay HUD in this project is an autoload `CanvasLayer` that builds and shows itself in
## `_ready()`, because until now there was no "before the run" for them to be absent from — the game
## booted straight into the world. With a front end as the boot scene they all draw over the title:
## a health bar reading 100/100, an empty hotbar and the debug overlay, on top of the menu.
##
## Hiding them for the life of the front end is the contained fix — this file owns it, no HUD needs
## an exact claim, and `restore_gameplay_overlays()` puts back exactly what was hidden rather than
## forcing everything visible (a HUD that was legitimately hidden must stay hidden). The principled
## fix is for each HUD to key its own visibility off "is a run in progress", which is a change across
## six files this task does not hold; it is filed as a finding.
static func suspend_gameplay_overlays() -> void:
	_suspended.clear()
	var loop: MainLoop = Engine.get_main_loop()
	if not (loop is SceneTree):
		return
	var tree: SceneTree = loop
	for child: Node in tree.root.get_children():
		if child is CanvasLayer and child.name != &"MenuStack":
			var layer: CanvasLayer = child
			if layer.visible:
				_suspended.append(layer)
				layer.visible = false


static func restore_gameplay_overlays() -> void:
	for layer: CanvasLayer in _suspended:
		if is_instance_valid(layer):
			layer.visible = true
	_suspended.clear()


## The overlays this front end switched off, so exactly those get switched back on.
static var _suspended: Array[CanvasLayer] = []


## NEVER call this `_enter_world()`. `Node3D` has an engine virtual of exactly that name, fired on
## NOTIFICATION_ENTER_WORLD — before `_enter_tree()` and long before `_ready()` — so a method named
## that is not private at all: Godot calls it the instant this node enters the 3D world. This file
## used to be named that way, and the result was F-421: QUIT TO TITLE reaches
## `SceneTree::_flush_scene_change()`, the incoming Frontend enters the world, the engine calls
## `_enter_world()`, and this body requests ANOTHER scene change from inside the one in progress.
## The process died with SIGSEGV every single time, before `_ready()` ever ran — which is also why
## nobody had ever seen the title screen. `tools/virtual_shadow_check.gd` now fails the build on any
## recurrence.
func _begin_run() -> void:
	restore_gameplay_overlays()
	var stack: Node = _stack()
	if stack != null:
		stack.call("pop_all")
	# The title is freed with the scene, but it was pushed with free_on_pop = false and reparented
	# under MenuStack, so it is no longer this scene's child to free. Drop it explicitly.
	if _title != null and is_instance_valid(_title):
		_title.queue_free()
		_title = null
	get_tree().change_scene_to_file(_world_scene_path())


func _world_scene_path() -> String:
	if ResourceLoader.exists(WORLD_SCENE_PATH):
		return WORLD_SCENE_PATH
	return WORLD_SCENE_FALLBACK


func _push_screen(path: String, label: String) -> void:
	var stack: Node = _stack()
	if stack == null:
		return
	if not ResourceLoader.exists(path):
		stack.call("toast", "%s isn't built yet — it's next on the bench." % label.capitalize(), true)
		return
	var script: GDScript = load(path)
	var screen: Control = script.new()
	stack.call("push", screen, true)


## Resolved through the SceneTree root rather than `get_node_or_null("/root/MenuStack")` on self,
## because an absolute node path only resolves once THIS node is inside the tree — and the routing
## calls above are worth being able to drive on a bare instance, which is exactly how `title_check`
## exercises them without booting a scene that would immediately bypass into the world.
func _stack() -> Node:
	var loop: MainLoop = Engine.get_main_loop()
	if not (loop is SceneTree):
		return null
	var tree: SceneTree = loop
	if tree.root == null:
		return null
	return tree.root.get_node_or_null(^"MenuStack")


## True when this process was launched to do something other than show a menu. Mirrors the flags
## `core/dev/dev_launch.gd` accepts, and reads them the same way (user args first, then the full
## command line) so the two can never disagree about what a launch meant.
static func _launch_bypasses_frontend() -> bool:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.is_empty():
		args = OS.get_cmdline_args()

	for arg: String in args:
		if arg in ["host", "--host", "client", "--client", "--steam-host", "--lan-host", "--procedural"]:
			return true
		if arg.begins_with("--steam-join") or arg.begins_with("--lan-join"):
			return true
		# A `--script` run drives the engine itself and never wants a scene of ours in the way.
		if arg == "--script" or arg == "-s":
			return true
	return false


## The credits card. An inner class for the same reason `MenuStack.ConfirmScreen` is one: it has no
## existence apart from the call that builds it, and nothing else ever instantiates it.
class CreditsScreen extends Control:
	const Kit := preload("res://ui/theme/mire_theme.gd")

	func _init() -> void:
		set_anchors_preset(Control.PRESET_FULL_RECT)

		var centre := CenterContainer.new()
		centre.set_anchors_preset(Control.PRESET_FULL_RECT)
		add_child(centre)

		var panel: PanelContainer = Kit.panel()
		panel.custom_minimum_size = Vector2(560.0, 0.0)
		centre.add_child(panel)

		var column: VBoxContainer = Kit.column(Kit.GRID)
		panel.add_child(column)

		var heading: Label = Kit.label("CREDITS", Kit.HEADLINE, Kit.TEXT)
		heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		column.add_child(heading)
		column.add_child(Kit.separator())

		for entry: Array in [
			["MIRE", "by Sequoyah"],
			["built with", "Godot Engine"],
			["physics", "Jolt"],
			["art & audio", "CC0 packs, credited in full in the repository"],
		]:
			var row: HBoxContainer = Kit.row(Kit.GRID * 2)
			column.add_child(row)
			var role: Label = Kit.label(String(entry[0]), Kit.CAPTION, Kit.MUTED)
			role.custom_minimum_size = Vector2(140.0, 0.0)
			row.add_child(role)
			row.add_child(Kit.label(String(entry[1]), Kit.BODY, Kit.TEXT))

		column.add_child(Kit.separator())
		column.add_child(Kit.paragraph(
			"No animals were harmed. The island was already like that.", Kit.CAPTION, Kit.MUTED
		))
