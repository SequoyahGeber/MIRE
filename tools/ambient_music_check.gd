extends SceneTree

## Offline proof for F-373 — the ambient soundtrack actually plays. Before this, `ambient_day.ogg`
## and `ambient_night.ogg` were rendered, imported and documented and referenced by nothing at all,
## so the shipped game was silent except for a seven-second boss stinger. This check asserts the
## things that would have caught that, and the things that would catch it coming back:
##
##   · both beds load in-engine as looping streams and are attached to real players
##   · the DAY bed is the audible one by day and the NIGHT bed by night
##   · a crossfade genuinely moves volume — both beds audible mid-fade, at equal power
##   · the phase is re-derived from `time_of_day` with NO signal, which is the client case
##     (`DayNight._advance_client()` never calls `_check_thresholds()`, so a client receives
##     `night_started`/`day_started` exactly never — see the autoload's header)
##   · a boss stinger ducks the bed and the bed comes back afterwards
##   · a real run restart leaves exactly one player per channel and does not go silent
##
##   .agent/bin/agent godot --script tools/ambient_music_check.gd
##
## This harness drives the REGISTERED autoloads, for F-068/F-069's reason: a private copy would pass
## with `AmbientMusicDirector` unregistered, and "nothing plays the soundtrack" is EXACTLY the failure
## F-373 is about, so `_check_wiring()` fails on line one instead of testing a node the game never
## loads. The script is preloaded only to read its constants — never instantiated.

const DIRECTOR_SCRIPT := preload("res://autoload/ambient_music_director.gd")

## Both beds are 3:44 seamless loops (`docs/AUDIO.md`'s music table, `tools/audio_import_check.gd`'s
## MUSIC_LEN_S). Kept loose here — length is that check's job; this one only needs "a real bed, not a
## truncated import".
const MIN_BED_LEN_S: float = 200.0

## `AudioStreamPlayer.volume_db` when a channel is at full gain and unducked: `linear_to_db(1.0)`.
const FULL_DB: float = 0.0
const DB_EPSILON: float = 0.01

var failures: int = 0
var director: Node
var day_night: Node
var boss_director: Node
var cycle_service: Node
var defeat_service: Node


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	if not _check_wiring():
		print("\nAMBIENT_MUSIC_CHECK failures=%d" % failures)
		finish()
		return

	# The harness owns both clocks from here. DayNight advances `time_of_day` on its own physics tick
	# and the director fades on its own frame; either running underneath an assertion would make the
	# volume readings below a race rather than a measurement. Same shape as
	# `tools/wave_spawner_check.gd`'s `day_night.set_physics_process(false)`.
	day_night.set_physics_process(false)
	director.set_process(false)

	_check_streams()
	_check_day_bed()
	_check_night_bed()
	_check_crossfade_moves_volume()
	_check_poll_drives_the_fade()
	_check_boss_duck()
	await _check_restart()

	director.set_process(true)
	day_night.set_physics_process(true)
	print("\nAMBIENT_MUSIC_CHECK failures=%d" % failures)
	finish()


## F-373 in one assertion: if `AmbientMusicDirector` is not a registered autoload, the game has no
## soundtrack, and every other assertion in this file would be testing a private instance that the
## shipped build never creates.
func _check_wiring() -> bool:
	print("\n== wiring ==")
	director = root.get_node_or_null(^"AmbientMusicDirector")
	day_night = root.get_node_or_null(^"DayNight")
	boss_director = root.get_node_or_null(^"BossMusicDirector")
	cycle_service = root.get_node_or_null(^"CycleService")
	defeat_service = root.get_node_or_null(^"DefeatService")

	check(director != null,
		"AmbientMusicDirector is registered as an autoload — without this the game is silent (F-373)")
	check(day_night != null, "DayNight is registered as an autoload")
	check(boss_director != null, "BossMusicDirector is registered as an autoload")
	check(cycle_service != null and defeat_service != null,
		"CycleService and DefeatService are registered — the real restart path")
	return director != null and day_night != null


func _check_streams() -> void:
	print("\n== both beds load, one player per channel ==")
	var day: AudioStreamPlayer = director.call("day_player")
	var night: AudioStreamPlayer = director.call("night_player")
	check(day != null and night != null, "the director built a day player and a night player")
	if day == null or night == null:
		return

	_check_bed(day, "ambient_day.ogg")
	_check_bed(night, "ambient_night.ogg")
	check(_player_count() == 2,
		"exactly two AudioStreamPlayers, one per channel (%d)" % _player_count())


func _check_bed(player: AudioStreamPlayer, expected_file: String) -> void:
	var stream: AudioStream = player.stream
	check(stream != null, "%s: a stream is attached" % player.name)
	if stream == null:
		return
	check(String(stream.resource_path).ends_with(expected_file),
		"%s plays %s (got %s)" % [player.name, expected_file, stream.resource_path])
	var ogg := stream as AudioStreamOggVorbis
	check(ogg != null, "%s decoded as AudioStreamOggVorbis" % player.name)
	if ogg == null:
		return
	# A bed that does not loop is a game that goes quiet 3:44 in with nothing logged, which is
	# indistinguishable from F-373 itself from the player's chair.
	check(ogg.loop, "%s loops — a non-looping bed goes silent 3:44 in" % player.name)
	check(stream.get_length() > MIN_BED_LEN_S,
		"%s is a full-length bed (%.1fs)" % [player.name, stream.get_length()])


## By day the day bed is audible at full gain and the night bed is not merely quiet but STOPPED —
## a steady phase must not hold two ogg streams decoding for the whole run.
func _check_day_bed() -> void:
	print("\n== the day bed is the audible one by day ==")
	_settle_at(0.5)  # noon
	check(is_equal_approx(float(director.call("night_mix")), 0.0),
		"noon settles the mix fully to day (%.4f)" % float(director.call("night_mix")))
	_check_audible(director.call("day_player"), "AmbientDay")
	_check_silent(director.call("night_player"), "AmbientNight")


func _check_night_bed() -> void:
	print("\n== the night bed is the audible one by night ==")
	_settle_at(0.8)  # past DayNight's 0.75 dusk threshold
	check(is_equal_approx(float(director.call("night_mix")), 1.0),
		"night settles the mix fully to night (%.4f)" % float(director.call("night_mix")))
	_check_audible(director.call("night_player"), "AmbientNight")
	_check_silent(director.call("day_player"), "AmbientDay")


## The claim that separates a crossfade from a hard cut: halfway through, BOTH beds are playing, both
## are audible but neither is at full, and the pair sums to equal power (day² + night² == 1) so the
## mix does not dip through the middle.
func _check_crossfade_moves_volume() -> void:
	print("\n== a crossfade actually moves volume ==")
	_settle_at(0.5)
	var day: AudioStreamPlayer = director.call("day_player")
	var night: AudioStreamPlayer = director.call("night_player")
	var day_before: float = day.volume_db
	var night_before: float = night.volume_db

	day_night.call("host_set_time", 0.8)
	# Half of CROSSFADE_SEC, in one-second steps through the same `advance()` the real frame calls.
	for i: int in 4:
		director.call("advance", 1.0)

	var mix: float = float(director.call("night_mix"))
	check(mix > 0.1 and mix < 0.9, "mid-fade the mix sits between the two beds (%.4f)" % mix)
	check(day.playing and night.playing, "mid-fade BOTH beds are playing — this is a fade, not a cut")
	check(day.volume_db < day_before - 1.0,
		"the outgoing day bed dropped (%.2f dB -> %.2f dB)" % [day_before, day.volume_db])
	check(night.volume_db > night_before + 1.0,
		"the incoming night bed rose (%.2f dB -> %.2f dB)" % [night_before, night.volume_db])

	var day_linear: float = db_to_linear(day.volume_db)
	var night_linear: float = db_to_linear(night.volume_db)
	var power: float = day_linear * day_linear + night_linear * night_linear
	check(absf(power - 1.0) < 0.02,
		"the fade is equal power, so the mix does not dip through the middle (%.4f)" % power)

	director.call("advance", CROSSFADE_SEC_HEADROOM)
	check(is_equal_approx(float(director.call("night_mix")), 1.0), "the fade completes on night")
	_check_audible(night, "AmbientNight")
	_check_silent(day, "AmbientDay")


## The client case, and the reason this director polls instead of only listening. `host_set_time()`
## fires `night_started`/`day_started` on its way past a threshold; writing `time_of_day` directly
## fires neither, which is exactly what a client sees — `DayNight._advance_client()` interpolates the
## replicated value and never calls `_check_thresholds()`. If this assertion ever fails, the host has
## a soundtrack and every joining player is stuck on whichever bed they booted into.
func _check_poll_drives_the_fade() -> void:
	print("\n== the poll drives the fade with no signal — the client case ==")
	_settle_at(0.5)
	check(is_equal_approx(float(director.call("night_mix")), 0.0), "starts settled on day")

	# No host_set_time, no signal: just the replicated number moving, the way it arrives on a client.
	day_night.set(&"time_of_day", 0.8)
	director.call("advance", CROSSFADE_SEC_HEADROOM)
	check(is_equal_approx(float(director.call("night_mix")), 1.0),
		"a bare time_of_day change crossfades to night with no signal (%.4f)"
			% float(director.call("night_mix")))
	_check_audible(director.call("night_player"), "AmbientNight")

	day_night.set(&"time_of_day", 0.5)
	director.call("advance", CROSSFADE_SEC_HEADROOM)
	check(is_equal_approx(float(director.call("night_mix")), 0.0),
		"and back to day the same way (%.4f)" % float(director.call("night_mix")))
	_check_audible(director.call("day_player"), "AmbientDay")


## The duck lowers the bed under a stinger and RESTORES it afterwards — a duck that never releases is
## a soundtrack that dies at the first boss, which is the same silence F-373 reported.
func _check_boss_duck() -> void:
	print("\n== the boss duck lowers the bed and restores it ==")
	_settle_at(0.8)
	var night: AudioStreamPlayer = director.call("night_player")
	var before_db: float = night.volume_db

	# BossMusicDirector's own public seam, not an EventBus emit — F-291: a check that fires the bus
	# event proves the subscriber, not the shipped path, and `play_cue()` IS the shipped path here
	# (its three EventBus handlers all call straight into it).
	boss_director.call("play_cue", &"boss_stinger")
	check(_boss_is_sounding(), "the boss stinger is sounding")

	director.call("advance", 1.0)
	var ducked: float = float(director.call("duck_gain"))
	check(is_equal_approx(ducked, DIRECTOR_SCRIPT.DUCK_GAIN),
		"the duck reaches full depth under the stinger (%.4f)" % ducked)
	check(night.volume_db < before_db - 6.0,
		"the bed drops under the stinger (%.2f dB -> %.2f dB)" % [before_db, night.volume_db])
	check(night.playing, "the bed is ducked, not stopped — the stinger's tail keeps its bed")

	_stop_boss_players()
	check(not _boss_is_sounding(), "the stinger has finished")
	director.call("advance", 4.0)
	check(is_equal_approx(float(director.call("duck_gain")), 1.0),
		"the duck releases (%.4f)" % float(director.call("duck_gain")))
	check(absf(night.volume_db - before_db) < DB_EPSILON,
		"the bed is restored to exactly where it was (%.2f dB -> %.2f dB)"
			% [before_db, night.volume_db])


## A restart reseeds the world and resets every run-scoped system. The director must come out the
## other side with the SAME two players (not four, phasing against each other) and audible — this is
## the "survives a restart and a reseed" half of F-373.
func _check_restart() -> void:
	print("\n== a restart leaves exactly one player per channel, still audible ==")
	_settle_at(0.8)
	var night_before: AudioStreamPlayer = director.call("night_player")
	check(night_before.playing, "the night bed is playing going into the restart")

	# The real ending -> restart path, not a bare EVENT_BUS.emit_run_restarted() shortcut (F-291),
	# the same way tools/harvest_restart_check.gd reaches it.
	defeat_service.set(&"defeated", true)
	await process_frame
	var cycle: int = int(cycle_service.call("host_restart_run"))
	check(cycle == 1, "the restart returns the run to Cycle 1")
	await process_frame

	check(_player_count() == 2,
		"still exactly two players after the restart — no stacking (%d)" % _player_count())
	var day_after: AudioStreamPlayer = director.call("day_player")
	var night_after: AudioStreamPlayer = director.call("night_player")
	check(night_after == night_before, "the players are the same instances, not rebuilt")

	# DayNight resets the clock to the run-start morning, so the new run opens on the DAY bed, snapped
	# rather than faded — and above all not silent.
	check(is_equal_approx(float(director.call("night_mix")), 0.0),
		"the new run snaps to the day bed (%.4f)" % float(director.call("night_mix")))
	_check_audible(day_after, "AmbientDay")
	_check_silent(night_after, "AmbientNight")

	# And a second restart in the same process must not stack either.
	defeat_service.set(&"defeated", true)
	await process_frame
	cycle_service.call("host_restart_run")
	await process_frame
	check(_player_count() == 2,
		"a second restart still leaves two players (%d)" % _player_count())
	_check_audible(director.call("day_player"), "AmbientDay")


# ── Helpers ──────────────────────────────────────────────────────────────────────────────────────

## More than one full crossfade, so a single `advance()` settles whatever it was doing.
const CROSSFADE_SEC_HEADROOM: float = 12.0


## Puts the clock at `fraction` through the host's own jump seam (which crosses thresholds on the
## way, so the signal path is exercised too) and runs the fade out to completion.
func _settle_at(fraction: float) -> void:
	day_night.call("host_set_time", fraction)
	director.call("advance", CROSSFADE_SEC_HEADROOM)


func _check_audible(player: AudioStreamPlayer, label: String) -> void:
	check(player.playing, "%s is playing" % label)
	check(absf(player.volume_db - FULL_DB) < DB_EPSILON,
		"%s is at full gain, %.2f dB (the Music bus slider is the only attenuation)"
			% [label, player.volume_db])


func _check_silent(player: AudioStreamPlayer, label: String) -> void:
	check(not player.playing,
		"%s is stopped, not merely quiet — one decoding stream in a steady phase" % label)
	check(player.volume_db <= DIRECTOR_SCRIPT.SILENT_DB + DB_EPSILON,
		"%s is at silence (%.2f dB)" % [label, player.volume_db])


func _player_count() -> int:
	var count: int = 0
	for child: Node in director.get_children():
		if child is AudioStreamPlayer:
			count += 1
	return count


func _boss_is_sounding() -> bool:
	for child: Node in boss_director.get_children():
		var player := child as AudioStreamPlayer
		if player != null and player.playing:
			return true
	return false


## The stinger is ~7.2s and this check is not going to wait for it. Stopping the players directly is
## the harness reaching in, deliberately: the assertion under test is "the duck releases when the
## stinger stops sounding", and how it stopped is not part of that claim.
func _stop_boss_players() -> void:
	for child: Node in boss_director.get_children():
		var player := child as AudioStreamPlayer
		if player != null:
			player.stop()


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
