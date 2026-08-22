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
##   · a hard boundary is a SNAP on both sides — the theme is audible before a frame has run, and
##     the bed comes up already ducked underneath it rather than blaring first (F-430)
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
	_check_dawn_cue()
	_check_ambient_duck()
	_check_run_restart()
	_check_hard_boundary_is_a_snap()

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


## This process has no front end, so the director must treat that as "landfall already happened"
## rather than sitting silent waiting for a title screen that will never appear.
##
## F-564 corrected the reason, which had aged out: `run/main_scene` no longer boots straight into
## the world — MENU-3's cutover pointed it at `res://levels/frontend.tscn`. The conclusion survives
## intact, by a different route: `Frontend._launch_bypasses_frontend()` returns true for any
## `--script` launch, so the front end skips itself and no title screen is ever built here.
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


## The morning jig. Four things have to hold, and three of them are about the cue NOT firing:
##
##   · a run that has not been through a night yet gets no jig — there is nothing to celebrate, and
##     "the clock says day" is true from the first frame of every run that starts in daylight
##   · it waits `DAWN_DELAY_SEC` after the crossing, which is also the window a `cycle_advanced` has
##     to claim the morning for the escalation cue instead
##   · a `cycle_advanced` inside that window cancels it outright rather than being interrupted by it
##   · and its fade-out is the 3 s override, not the shared 8 s — at five seconds from the end the
##     jig is still at full gain, which is the whole point of `CUE_FADE_OUT`
##
## The trigger is a poll of `DayNight.time_of_day`, so the harness drives the clock directly. That is
## also the only way to test it: `DayNight.day_started` is HOST-only and never fires on a client, and
## a cue wired to it would pass a single-process check and be silent for four players out of five.
func _check_dawn_cue() -> void:
	print("\n== dawn cue ==")
	var clock: Node = root.get_node_or_null(^"DayNight")
	check(clock != null, "DayNight is a registered autoload")
	if clock == null:
		return
	var player: AudioStreamPlayer = _player(THEME_SCRIPT.CUE_DAWN)
	check(player != null, "dawn has a player")
	if player == null:
		return

	# A fresh run that opens in daylight: no night behind it, so no jig no matter how long it runs.
	clock.set(&"time_of_day", 0.40)
	EVENT_BUS.emit_run_restarted()
	for i: int in 10:
		director.advance(1.0 / 60.0)
	check(director.active_cue() == THEME_SCRIPT.CUE_LANDFALL,
		"a run that has not seen a night gets no jig (got %s)" % director.active_cue())

	# Now survive one.
	clock.set(&"time_of_day", 0.85)
	director.advance(1.0 / 60.0)
	clock.set(&"time_of_day", 0.30)
	director.advance(1.0 / 60.0)
	check(director.active_cue() != THEME_SCRIPT.CUE_DAWN,
		"the jig waits out DAWN_DELAY_SEC rather than firing on the crossing frame")
	director.advance(THEME_SCRIPT.DAWN_DELAY_SEC)
	check(director.active_cue() == THEME_SCRIPT.CUE_DAWN,
		"morning starts the jig (got %s)" % director.active_cue())
	director.advance(THEME_SCRIPT.FADE_IN_SEC)
	check(player.playing, "dawn player is playing")

	# The 3 s override: five seconds out it is still full, and it does fade before the end.
	var length: float = player.stream.get_length()
	director.advance(maxf(length - 5.0 - director._elapsed, 0.0))
	check(player.volume_db > -1.0,
		"5 s from the end the jig is still at full gain (%.1f dB) — the 8 s fade would have it at -4"
			% player.volume_db)
	director.advance(3.5)
	check(player.volume_db < -3.0, "and it does fade out over its last seconds (%.1f dB)"
		% player.volume_db)
	director.advance(THEME_SCRIPT.FADE_OUT_SEC)
	check(director.active_cue() == &"", "jig retires (got %s)" % director.active_cue())

	# The third morning belongs to the escalation. A `cycle_advanced` inside the delay window must
	# cancel the jig, not be cut into by it two seconds later.
	clock.set(&"time_of_day", 0.85)
	director.advance(1.0 / 60.0)
	clock.set(&"time_of_day", 0.30)
	director.advance(1.0 / 60.0)
	EVENT_BUS.emit_cycle_advanced(3)
	check(director.active_cue() == THEME_SCRIPT.CUE_CYCLE, "cycle cue takes the morning")
	director.advance(THEME_SCRIPT.DAWN_DELAY_SEC + 1.0)
	check(director.active_cue() == THEME_SCRIPT.CUE_CYCLE,
		"and the jig does not interrupt it (got %s)" % director.active_cue())
	check(not player.playing, "the dawn player never started")

	# Leave the clock and the director where the rest of the checks expect them.
	clock.set(&"time_of_day", 0.348)
	EVENT_BUS.emit_run_restarted()
	director.advance(1.0 / 60.0)


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


## F-430, as a regression test. The bug was a boot that opened on `ambient_day.ogg` at full volume
## for the length of the world-gen stall and then CUT to the theme, and both halves of it were the
## same mistake: a hard boundary was being treated as something to fade across.
##
## A restart is the one hard boundary this harness can replay — it runs the identical code (the theme
## snaps its cue in `_on_run_restarted()`, the bed re-arms `_boot_pending`), and unlike the real boot
## it happens while the harness owns the clock, so "before a single frame has run" is observable
## rather than already gone by the time `_run()` starts.
##
## The two assertions that would have failed before the fix: the theme is at FULL gain with no frame
## elapsed (it was at 0.0, which `_apply_channel()` renders as a STOPPED player — silence, not a
## quiet fade-in), and one frame is enough to put the bed at exactly `THEME_DUCK_GAIN` (it used to
## start at full and ramp down over `DUCK_ATTACK_SEC`, and on the real boot that ramp was crossed in
## one enormous `delta` — the audible cut).
func _check_hard_boundary_is_a_snap() -> void:
	print("\n== a hard boundary is a snap, not a fade (F-430) ==")
	for cue: StringName in THEME_SCRIPT.CUE_PATHS:
		var player: AudioStreamPlayer = _player(cue)
		if player != null:
			player.stop()
	for i: int in 60:
		ambient.advance(0.1)

	EVENT_BUS.emit_run_restarted()

	# Not one `advance()` on either director yet — this is the state a real boot spends its whole
	# world-gen stall in.
	var landfall: AudioStreamPlayer = _player(THEME_SCRIPT.CUE_LANDFALL)
	check(landfall != null and landfall.playing,
		"the theme is already sounding before a frame has run")
	check(landfall != null and absf(landfall.volume_db) < 0.01,
		"and at full gain, not the head of a %.1fs fade-in (%.2f dB)"
			% [THEME_SCRIPT.FADE_IN_SEC, landfall.volume_db if landfall != null else -99.0])
	var day: AudioStreamPlayer = ambient.call("day_player")
	check(day != null and not day.playing,
		"the bed is not the thing scoring the boundary")

	# One frame — the first `_process` of the new run — and the bed is where it belongs, in one step.
	ambient.advance(1.0 / 60.0)
	check(is_equal_approx(float(ambient._duck), AMBIENT_SCRIPT.THEME_DUCK_GAIN),
		"one frame puts the bed at THEME_DUCK_GAIN, no ramp (%.3f)" % float(ambient._duck))
	check(day != null and day.playing, "the bed is audible under the theme, not stopped")


func finish() -> void:
	quit(0 if failures == 0 else 1)
