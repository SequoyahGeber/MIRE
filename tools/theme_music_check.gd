extends SceneTree

## Offline proof for task 7.2's three authored themes — that they PLAY, and that each one plays at
## its own moment. This is the check F-373 would have needed: three .ogg files can be rendered,
## imported, loudness-checked and written up in `docs/AUDIO.md` and still be referenced by nothing,
## and a silent game reports no error anywhere. So the first assertion here is that
## `ThemeMusicDirector` is a REGISTERED autoload, and every later one drives that registered
## instance rather than a private copy (F-068/F-069).
##
##   · all three cue streams load in-engine as looping streams on real players
##   · booting with no front end IS landfall — the landfall cue is active on frame one
##   · a bounded cue fades out across its last seconds and then hands the mix back
##   · `cycle_advanced` past Cycle 1 starts the cycle cue; Cycle 1 itself does not
##   · a theme ducks the ambient bed harder than a boss stinger does, and the bed comes back
##   · the duck never reaches zero — a stopped bed would rewind a 3:44 loop to its head
##   · a run restart drops whatever was playing and returns to landfall
##
##   .agent/bin/agent godot --script tools/theme_music_check.gd

const THEME_SCRIPT := preload("res://autoload/theme_music_director.gd")
const AMBIENT_SCRIPT := preload("res://autoload/ambient_music_director.gd")
const EVENT_BUS := preload("res://core/events/event_bus.gd")

## Each theme is a composed piece, not a sting: anything under a minute means a truncated import.
const MIN_THEME_LEN_S: float = 60.0

var failures: int = 0
var director: Node
var ambient: Node


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	if not _check_wiring():
		print("\nTHEME_MUSIC_CHECK failures=%d" % failures)
		finish()
		return

	# The harness owns the clock from here: both directors fade on their own frame, and either one
	# running underneath an assertion would make every volume reading a race. Same shape as
	# `tools/ambient_music_check.gd`.
	director.set_process(false)
	ambient.set_process(false)

	_check_streams()
	_check_landfall_at_boot()
	_check_bounded_cue_hands_back()
	_check_cycle_cue()
	_check_ambient_duck()
	_check_run_restart()

	director.set_process(true)
	ambient.set_process(true)
	print("\nTHEME_MUSIC_CHECK failures=%d" % failures)
	finish()


func check(cond: bool, msg: String) -> void:
	if cond:
		print("PASS: %s" % msg)
	else:
		failures += 1
		print("FAIL: %s" % msg)


## The one assertion that would have caught F-373's shape: an unregistered director means three
## themes that never play, and every other assertion below would be testing a node the shipped build
## never creates.
func _check_wiring() -> bool:
	print("\n== wiring ==")
	director = root.get_node_or_null(^"ThemeMusicDirector")
	check(director != null, "ThemeMusicDirector is a registered autoload")
	ambient = root.get_node_or_null(^"AmbientMusicDirector")
	check(ambient != null, "AmbientMusicDirector is a registered autoload")
	return director != null and ambient != null


func _player(cue: StringName) -> AudioStreamPlayer:
	for child: Node in director.get_children():
		var player := child as AudioStreamPlayer
		if player != null and player.name == String(cue).capitalize():
			return player
	return null


func _check_streams() -> void:
	print("\n== streams ==")
	for cue: StringName in THEME_SCRIPT.CUE_PATHS:
		var path: String = THEME_SCRIPT.CUE_PATHS[cue]
		check(ResourceLoader.exists(path), "%s: %s exists" % [cue, path])
		var player: AudioStreamPlayer = _player(cue)
		check(player != null, "%s: has a player" % cue)
		if player == null or player.stream == null:
			check(false, "%s: player has a stream" % cue)
			continue
		var ogg := player.stream as AudioStreamOggVorbis
		check(ogg != null and ogg.loop, "%s: stream loops" % cue)
		check(player.stream.get_length() >= MIN_THEME_LEN_S,
			"%s: %.1fs >= %.0fs" % [cue, player.stream.get_length(), MIN_THEME_LEN_S])


## `project.godot`'s `run/main_scene` still boots straight into the world (4.19's cutover is in
## flight), so this process has no front end and the director must treat that as "landfall already
## happened" rather than sitting silent waiting for a title screen that will never appear.
func _check_landfall_at_boot() -> void:
	print("\n== landfall at boot ==")
	check(root.get_tree().get_nodes_in_group(THEME_SCRIPT.FRONTEND_GROUP).is_empty(),
		"no front end in this process")
	check(director.active_cue() == THEME_SCRIPT.CUE_LANDFALL,
		"active cue is landfall (got %s)" % director.active_cue())
	director.advance(THEME_SCRIPT.FADE_IN_SEC)
	var player: AudioStreamPlayer = _player(THEME_SCRIPT.CUE_LANDFALL)
	check(player != null and player.playing, "landfall player is playing")
	check(director.is_playing(), "director reports a theme playing")


## A bounded cue must end on a decrescendo and then give the bed back. Driven by advancing the
## director's own clock rather than waiting two real minutes.
func _check_bounded_cue_hands_back() -> void:
	print("\n== bounded cue hands back ==")
	var player: AudioStreamPlayer = _player(THEME_SCRIPT.CUE_LANDFALL)
	var length: float = player.stream.get_length()
	# To four seconds before the end: half way through the fade-out, so audibly quieter but not gone.
	director.advance(length - THEME_SCRIPT.FADE_OUT_SEC)
	var full_db: float = player.volume_db
	director.advance(THEME_SCRIPT.FADE_OUT_SEC * 0.5)
	check(player.volume_db < full_db - 3.0,
		"fading out: %.1f dB -> %.1f dB" % [full_db, player.volume_db])
	check(director.active_cue() == THEME_SCRIPT.CUE_LANDFALL, "still the active cue mid-fade")
	# Past the end, plus enough frames for the gain to reach zero and the channel to stop.
	director.advance(THEME_SCRIPT.FADE_OUT_SEC)
	director.advance(THEME_SCRIPT.FADE_OUT_SEC)
	check(director.active_cue() == &"", "cue retired (got %s)" % director.active_cue())
	check(not player.playing, "landfall player stopped")
	check(not director.is_playing(), "director reports nothing playing")


func _check_cycle_cue() -> void:
	print("\n== cycle cue ==")
	# Cycle 1 is where every run already starts; landfall covers it, so it must not fire.
	EVENT_BUS.emit_cycle_advanced(1)
	check(director.active_cue() == &"", "Cycle 1 does not start a cue")
	EVENT_BUS.emit_cycle_advanced(2)
	check(director.active_cue() == THEME_SCRIPT.CUE_CYCLE,
		"Cycle 2 starts the cycle cue (got %s)" % director.active_cue())
	director.advance(THEME_SCRIPT.FADE_IN_SEC)
	var player: AudioStreamPlayer = _player(THEME_SCRIPT.CUE_CYCLE)
	check(player != null and player.playing, "cycle player is playing")


## The bed must get out of a theme's way harder than it does for a stinger — and must never be taken
## to actual silence, because `AmbientMusicDirector._apply_channel()` STOPS a silent channel and a
## stopped player resumes at the head of a 3:44 loop.
func _check_ambient_duck() -> void:
	print("\n== ambient duck ==")
	check(director.is_playing(), "a theme is audible for this measurement")
	for i: int in 40:
		ambient.advance(0.1)
	var ducked: float = ambient._duck
	check(is_equal_approx(ducked, AMBIENT_SCRIPT.THEME_DUCK_GAIN),
		"bed ducked to %.3f == THEME_DUCK_GAIN %.3f" % [ducked, AMBIENT_SCRIPT.THEME_DUCK_GAIN])
	check(AMBIENT_SCRIPT.THEME_DUCK_GAIN < AMBIENT_SCRIPT.DUCK_GAIN,
		"theme duck is deeper than the boss duck")
	check(AMBIENT_SCRIPT.THEME_DUCK_GAIN > AMBIENT_SCRIPT.AUDIBLE_EPSILON,
		"theme duck stays above the stop threshold, so the bed keeps its playhead")

	# And it comes back once the theme is gone.
	for cue: StringName in THEME_SCRIPT.CUE_PATHS:
		var player: AudioStreamPlayer = _player(cue)
		if player != null:
			player.stop()
	for i: int in 60:
		ambient.advance(0.1)
	check(is_equal_approx(ambient._duck, 1.0), "bed returns to full (%.3f)" % ambient._duck)


## A restart must not let the dying run's cue keep playing into the new one — a Cycle 9 escalation
## cue surviving into the first frame of a fresh run is the one combination that scores the wrong
## moment outright.
func _check_run_restart() -> void:
	print("\n== run restart ==")
	EVENT_BUS.emit_cycle_advanced(4)
	director.advance(THEME_SCRIPT.FADE_IN_SEC)
	check(director.active_cue() == THEME_SCRIPT.CUE_CYCLE, "a cycle cue is running")
	EVENT_BUS.emit_run_restarted()
	check(director.active_cue() == THEME_SCRIPT.CUE_LANDFALL,
		"restart returns to landfall (got %s)" % director.active_cue())
	var cycle_player: AudioStreamPlayer = _player(THEME_SCRIPT.CUE_CYCLE)
	check(cycle_player != null and not cycle_player.playing, "the old cycle cue was stopped")


func finish() -> void:
	quit(0 if failures == 0 else 1)
