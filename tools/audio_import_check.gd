extends SceneTree

## Offline proof for tasks 7.1/7.2 (audio v1): every committed audio asset
## imports and loads in-engine — music OGGs decode as AudioStreamOggVorbis
## with loop enabled and the full 3:44 length, SFX WAVs decode as mono
## AudioStreamWAV of sane length. Run through the shared import lock:
##
##   .agent/bin/agent godot --script tools/audio_import_check.gd
##
## (A fresh clone needs one `.agent/bin/agent godot --import` first so the
## .import cache exists; CI-style usage is import-then-check.)

const MUSIC_DIR := "res://assets/audio/music"
const SFX_DIR := "res://assets/audio/sfx"
const MUSIC_LEN_S := 224.0

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	print("\n== music: ogg streams, looped, full length ==")
	var music_names: PackedStringArray = _list(MUSIC_DIR, ".ogg")
	check(music_names.size() == 2, "found 2 music oggs (%d)" % music_names.size())
	for name in music_names:
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

	print("\n== sfx: mono wav streams ==")
	var sfx_names: PackedStringArray = _list(SFX_DIR, ".wav")
	check(sfx_names.size() >= 19, "found >= 19 sfx wavs (%d)" % sfx_names.size())
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
			check(length > 0.02 and length < 3.5,
				"%s length %.2fs in (0.02, 3.5)" % [name, length])

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
