extends SceneTree

## Offline proof for tasks 7.1/7.2 (audio v1) and 5.5 (the boss stinger): every committed audio
## asset imports and loads in-engine — the two ambient beds decode as AudioStreamOggVorbis with
## loop enabled and the full 3:44 length, the three authored themes decode as looping streams of
## their own composed lengths, the boss stinger decodes as a short non-looping one-shot, and SFX
## WAVs decode as mono AudioStreamWAV of sane length. Run through the shared import lock:
##
##   .agent/bin/agent godot --script tools/audio_import_check.gd
##
## (A fresh clone needs one `.agent/bin/agent godot --import` first so the
## .import cache exists; CI-style usage is import-then-check.)

const MUSIC_DIR := "res://assets/audio/music"
const SFX_DIR := "res://assets/audio/sfx"
const MUSIC_LEN_S := 224.0
## Task 7.2's authored themes (`tools/audio/render_theme.py`). Unlike the two beds these are not one
## fixed length — each is as long as its own composition — so they are checked by name against their
## rendered length rather than against a shared constant. All four loop: they are rendered
## circularly like the beds (`finish()` folds the decay onto the head), and `ThemeMusicDirector` ends
## the two bounded cues with a timed fade rather than by letting the stream run out.
const THEME_LEN_S: Dictionary[String, float] = {
	"menu_theme.ogg": 101.3,
	"theme_landfall.ogg": 117.4,
	"theme_cycle.ogg": 71.3,
	"theme_dawn.ogg": 132.5,
}
## `tools/audio/render_music.py`'s `BOSS_STINGER` (task 5.5) — a one-shot cue, not a bed, so it is
## checked on its own rather than folded into the looped-ambience assertions below. The rendered
## length is `dur_s + tail_s` (3.2 + 4.0), not `dur_s` alone: unlike the looped tracks (whose
## `wrap_loop()` folds the reverb tail back onto the head), a one-shot has nothing to fold onto and
## is left to ring out — the "hit" lands in the first ~1.1s, the rest is decay.
const STINGER_NAME := "boss_stinger.ogg"
const STINGER_LEN_S := 7.2

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	print("\n== music: ogg streams, looped, full length ==")
	var music_names: PackedStringArray = _list(MUSIC_DIR, ".ogg")
	var stinger_index: int = music_names.find(STINGER_NAME)
	if stinger_index >= 0:
		music_names.remove_at(stinger_index)
	var bed_names: PackedStringArray = PackedStringArray()
	for name in music_names:
		if not THEME_LEN_S.has(name):
			bed_names.append(name)
	check(bed_names.size() == 2, "found 2 looped ambient beds (%d)" % bed_names.size())
	for name in bed_names:
		var stream: AudioStream = load(MUSIC_DIR + "/" + name)
		if stream == null:
			check(false, "%s loads" % name)
			continue
		check(stream is AudioStreamOggVorbis, "%s is AudioStreamOggVorbis" % name)
		var length: float = stream.get_length()
		check(absf(length - MUSIC_LEN_S) < 1.0,
			"%s length %.1fs ~= %.0fs" % [name, length, MUSIC_LEN_S])
		var looped: bool = bool(stream.get("loop"))
		check(looped, "%s has loop enabled" % name)

	print("\n== music: the four authored themes ==")
	check(THEME_LEN_S.size() == 4, "4 themes expected (%d)" % THEME_LEN_S.size())
	for name: String in THEME_LEN_S:
		var theme: AudioStream = load(MUSIC_DIR + "/" + name)
		if theme == null:
			check(false, "%s loads" % name)
			continue
		check(theme is AudioStreamOggVorbis, "%s is AudioStreamOggVorbis" % name)
		var theme_len: float = theme.get_length()
		check(absf(theme_len - THEME_LEN_S[name]) < 1.0,
			"%s length %.1fs ~= %.1fs" % [name, theme_len, THEME_LEN_S[name]])
		check(bool(theme.get("loop")), "%s has loop enabled" % name)

	print("\n== music: the boss stinger, a short non-looping one-shot ==")
	var stinger: AudioStream = load(MUSIC_DIR + "/" + STINGER_NAME)
	check(stinger != null, "%s loads" % STINGER_NAME)
	if stinger != null:
		check(stinger is AudioStreamOggVorbis, "%s is AudioStreamOggVorbis" % STINGER_NAME)
		var stinger_length: float = stinger.get_length()
		check(absf(stinger_length - STINGER_LEN_S) < 1.0,
			"%s length %.1fs ~= %.1fs" % [STINGER_NAME, stinger_length, STINGER_LEN_S])
		check(not bool(stinger.get("loop")), "%s does not loop — it is a one-shot cue" % STINGER_NAME)

	print("\n== sfx: mono wav streams ==")
	var sfx_names: PackedStringArray = _list(SFX_DIR, ".wav")
	check(sfx_names.size() >= 200, "found >= 200 sfx wavs (%d)" % sfx_names.size())
	for name in sfx_names:
		var stream: AudioStream = load(SFX_DIR + "/" + name)
		if stream == null:
			check(false, "%s loads" % name)
			continue
		check(stream is AudioStreamWAV, "%s is AudioStreamWAV" % name)
		var wav: AudioStreamWAV = stream as AudioStreamWAV
		if wav != null:
			check(not wav.stereo, "%s is mono" % name)
			var length: float = wav.get_length()
			# 8 s, not 3.5: `tree_fall` runs from the first fibre giving way to
			# the ground impact, `extraction_arrive`/`_launch` are whole hull
			# manoeuvres, and the two seamless beds (`furnace_loop` 4 s,
			# `wellspring_loop` 6 s) are as long as they need to be to not repeat
			# audibly. Truncating any of them to satisfy a rule would remove the
			# part they exist for.
			check(length > 0.02 and length <= 8.0,
				"%s length %.2fs in (0.02, 8.0]" % [name, length])

	print("\nAUDIO_IMPORT_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)


func _list(dir_path: String, extension: String) -> PackedStringArray:
	var names: PackedStringArray = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return names
	dir.list_dir_begin()
	var name: String = dir.get_next()
	while name != "":
		if not dir.current_is_dir() and name.ends_with(extension):
			names.append(name)
		name = dir.get_next()
	dir.list_dir_end()
	return names


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)
