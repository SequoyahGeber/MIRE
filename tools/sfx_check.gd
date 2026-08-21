extends SceneTree

## Offline proof that MIRE's sound effects PLAY — the check the 227 rendered
## files did not have, and the one that would have caught F-373's shape before
## a human had to report silence from play.
##
##   · SfxDirector is a REGISTERED autoload (an unregistered one plays nothing)
##   · every cue in the generated catalogue has files that load in-engine
##   · the catalogue and `assets/audio/sfx/` agree exactly — no orphan file,
##     no cue naming a file that is not there
##   · every cue named by a mapping table exists in the catalogue. This is the
##     assertion that matters most: a typo in `HARVEST_HIT_CUE` is a sound that
##     silently never plays, and nothing else in the project would notice
##   · playing a cue starts a voice, on the SFX bus
##   · variants round-robin, and repeats are pitch-scattered
##   · the dedupe window collapses a double-fired event into one sound
##   · a harvest event, a melee hit and a build placement each reach a voice
##     through the real handler, not through a test-only path
##
##   .agent/bin/agent godot --script tools/sfx_check.gd

const DIRECTOR_SCRIPT := preload("res://autoload/sfx_director.gd")
const CATALOGUE := preload("res://autoload/sfx_catalogue.gd")
const EVENT_BUS := preload("res://core/events/event_bus.gd")

const SFX_DIR := "res://assets/audio/sfx"

var failures: int = 0
var director: Node


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	if not _check_wiring():
		print("\nSFX_CHECK failures=%d" % failures)
		finish()
		return

	_check_binding_signatures()
	_check_cue_coverage()
	_check_catalogue_loads()
	_check_catalogue_matches_disk()
	_check_mapping_tables()
	_check_playback()
	_check_round_robin()
	_check_dedupe()
	await _check_events_reach_voices()
	await _check_ui_hooks()
	_check_ambient_scatter()

	print("\nSFX_CHECK failures=%d" % failures)
	finish()


func check(cond: bool, msg: String) -> void:
	if cond:
		print("PASS: %s" % msg)
	else:
		failures += 1
		print("FAIL: %s" % msg)


func _check_wiring() -> bool:
	print("\n== wiring ==")
	director = root.get_node_or_null(^"SfxDirector")
	check(director != null, "SfxDirector is a registered autoload")
	if director == null:
		return false
	check(CATALOGUE.CUES.size() >= 100,
		"catalogue has %d cues" % CATALOGUE.CUES.size())
	return true


## Every handler's arity must match its signal's. This is the check that pays
## for itself: a mismatch is silent until the signal fires in a real run, and
## two of them shipped in the first draft of `SfxDirector` — `landed` carries an
## impact speed, and `piece_destroyed` is `(def_id, owner, name, position)`
## rather than the `(piece, def_id, position, peer)` it looks like it should be.
## An hour into a session is a bad time to find out.
func _check_binding_signatures() -> void:
	print("\n== handler signatures match their signals ==")
	var methods: Dictionary[String, int] = {}
	for entry: Dictionary in director.get_method_list():
		methods[String(entry["name"])] = (entry["args"] as Array).size()

	var bad: PackedStringArray = PackedStringArray()
	var checked: int = 0
	var unreachable: int = 0
	for row: Array in DIRECTOR_SCRIPT.BINDINGS:
		var node: Node = root.get_node_or_null(NodePath(String(row[0]).trim_prefix("/root/")))
		if node == null:
			unreachable += 1
			continue
		var signal_args: int = _signal_arg_count(node, row[1])
		if signal_args < 0:
			bad.append("%s has no signal %s" % [row[0], row[1]])
			continue
		if not methods.has(String(row[2])):
			bad.append("SfxDirector has no method %s" % row[2])
			continue
		checked += 1
		if methods[String(row[2])] != signal_args:
			bad.append("%s(%d args) != %s(%d)"
				% [row[1], signal_args, row[2], methods[String(row[2])]])

	# Instance handlers take the signal's arguments PLUS the node they are bound to.
	for row: Array in DIRECTOR_SCRIPT.INSTANCE_BINDINGS:
		var sample: Node = _first_in_group(row[0])
		if sample == null:
			unreachable += 1
			continue
		var signal_args: int = _signal_arg_count(sample, row[1])
		if signal_args < 0 or not methods.has(String(row[2])):
			bad.append("%s / %s unresolvable" % [row[0], row[1]])
			continue
		checked += 1
		if methods[String(row[2])] != signal_args + 1:
			bad.append("%s(%d args + node) != %s(%d)"
				% [row[1], signal_args, row[2], methods[String(row[2])]])

	check(bad.is_empty(), "%d bindings have matching arity (%d bad: %s)"
		% [checked, bad.size(), ", ".join(bad.slice(0, 4))])
	# Not a failure — a harness legitimately registers only some autoloads, and
	# no harvestable exists in an empty scene — but it must be visible, because
	# an unreachable binding is one this check did NOT verify.
	print("NOTE: %d binding(s) had no live emitter in this process to check against"
		% unreachable)


## Which catalogue cues are actually reachable from the director. A rendered
## sound that no code path names is the F-373 failure one asset at a time, and
## the only way to keep it visible is to count it every run.
func _check_cue_coverage() -> void:
	print("\n== cue coverage ==")
	var file := FileAccess.open("res://autoload/sfx_director.gd", FileAccess.READ)
	if file == null:
		check(false, "sfx_director.gd is readable")
		return
	var source: String = file.get_as_text()
	file.close()
	var unwired: PackedStringArray = PackedStringArray()
	for cue: StringName in CATALOGUE.CUES:
		if not source.contains("&\"%s\"" % cue):
			unwired.append(String(cue))
	var wired: int = CATALOGUE.CUES.size() - unwired.size()
	print("  %d of %d cues are named by SfxDirector" % [wired, CATALOGUE.CUES.size()])
	if not unwired.is_empty():
		print("  not yet triggered: %s" % ", ".join(unwired))
	# A floor rather than "all of them": several cues are rendered ahead of the
	# systems that will fire them (there is no equip signal, no crafting-progress
	# signal, no furnace ignition event). The floor stops that list growing
	# quietly, which is the actual risk.
	check(wired >= CATALOGUE.CUES.size() - 12,
		"at most 12 cues unwired (%d unwired)" % unwired.size())


func _signal_arg_count(node: Node, signal_name: StringName) -> int:
	for entry: Dictionary in node.get_signal_list():
		if StringName(entry["name"]) == signal_name:
			return (entry["args"] as Array).size()
	return -1


func _first_in_group(group: StringName) -> Node:
	var nodes: Array[Node] = root.get_tree().get_nodes_in_group(group)
	return nodes[0] if not nodes.is_empty() else null


func _check_catalogue_loads() -> void:
	print("\n== every cue loads ==")
	var missing: PackedStringArray = PackedStringArray()
	var files: int = 0
	for cue: StringName in CATALOGUE.CUES:
		var count: int = int(CATALOGUE.CUES[cue][0])
		for path: String in _paths_for(cue, count):
			files += 1
			if not ResourceLoader.exists(path):
				missing.append(path)
				continue
			var stream: AudioStream = load(path) as AudioStream
			if stream == null or stream.get_length() <= 0.0:
				missing.append(path + " (empty)")
	check(missing.is_empty(),
		"all %d cue files load (%d missing: %s)"
		% [files, missing.size(), ", ".join(missing.slice(0, 5))])


## Drift in either direction is a bug. A cue naming a file that is not there is
## a silent sound; a file no cue names is dead weight in the export and usually
## means a rename landed in one place and not the other.
func _check_catalogue_matches_disk() -> void:
	print("\n== catalogue matches disk ==")
	var on_disk: Dictionary[String, bool] = {}
	var dir := DirAccess.open(SFX_DIR)
	if dir == null:
		check(false, "%s is readable" % SFX_DIR)
		return
	for name in dir.get_files():
		if name.ends_with(".wav"):
			on_disk[name] = true
	var claimed: Dictionary[String, bool] = {}
	for cue: StringName in CATALOGUE.CUES:
		for path: String in _paths_for(cue, int(CATALOGUE.CUES[cue][0])):
			claimed[path.get_file()] = true
	var orphans: PackedStringArray = PackedStringArray()
	for name: String in on_disk:
		if not claimed.has(name):
			orphans.append(name)
	check(orphans.is_empty(),
		"no orphan wavs (%d: %s)" % [orphans.size(), ", ".join(orphans.slice(0, 6))])
	check(on_disk.size() == claimed.size(),
		"%d files on disk == %d claimed by the catalogue" % [on_disk.size(), claimed.size()])


## The highest-value assertion in this file. Every mapping table in SfxDirector
## is a dictionary of cue NAMES, and a typo in one is a sound that never plays,
## with no error, forever — exactly the failure mode this whole check exists for.
func _check_mapping_tables() -> void:
	print("\n== mapping tables name real cues ==")
	# Walked off the script's own constant map rather than a hand-listed set of
	# table names, so a mapping table added later is covered without anyone
	# remembering to add it here — which is exactly the kind of remembering that
	# does not happen.
	# Reached through the live autoload's own script object: calling
	# `get_script_constant_map()` on a preloaded class directly is a parse error
	# ("make an instance instead"), and going through the instance also proves
	# the constants being validated are the ones the RUNNING director uses.
	var consts: Dictionary = director.get_script().get_script_constant_map()
	var bad: PackedStringArray = PackedStringArray()
	var checked: int = 0
	var tables: int = 0
	for const_name: String in consts:
		var value: Variant = consts[const_name]
		if const_name.ends_with("_CUE") and value is StringName:
			checked += 1
			if not CATALOGUE.CUES.has(value):
				bad.append("%s -> %s" % [const_name, value])
		elif const_name.ends_with("_CUE") and value is Dictionary:
			tables += 1
			for key: Variant in (value as Dictionary):
				checked += 1
				var cue: Variant = (value as Dictionary)[key]
				if cue is StringName and not CATALOGUE.CUES.has(cue):
					bad.append("%s[%s] -> %s" % [const_name, key, cue])
		elif const_name.ends_with("_CUES") and value is Dictionary:
			tables += 1
			for key: Variant in (value as Dictionary):
				checked += 1
				var mapped: Variant = (value as Dictionary)[key]
				if mapped is StringName and not CATALOGUE.CUES.has(mapped):
					bad.append("%s[%s] -> %s" % [const_name, key, mapped])
		elif const_name.ends_with("_CUES") and value is Array:
			tables += 1
			for entry: Variant in (value as Array):
				checked += 1
				if entry is StringName and not CATALOGUE.CUES.has(entry):
					bad.append("%s -> %s" % [const_name, entry])
				elif entry is Array and (entry as Array).size() >= 2:
					if not CATALOGUE.CUES.has((entry as Array)[1]):
						bad.append("%s -> %s" % [const_name, (entry as Array)[1]])
	# TARGET_MATERIAL_CUE is an Array of [substring, cue] rows, so it does not
	# match either shape above.
	tables += 1
	for row: Array in DIRECTOR_SCRIPT.TARGET_MATERIAL_CUE:
		checked += 1
		if not CATALOGUE.CUES.has(row[1]):
			bad.append("TARGET_MATERIAL_CUE[%s] -> %s" % [row[0], row[1]])
	check(tables >= 6, "found %d cue tables to validate" % tables)
	check(bad.is_empty(), "%d mapped cue names all exist (%d bad: %s)"
		% [checked, bad.size(), ", ".join(bad.slice(0, 5))])


func _check_playback() -> void:
	print("\n== playback ==")
	_silence()
	director.play(&"ui_click")
	check(director.is_playing(), "play() starts a voice")
	var flat: AudioStreamPlayer = _first_flat_playing()
	check(flat != null, "a flat voice is sounding")
	if flat != null:
		var expected: StringName = DIRECTOR_SCRIPT.SFX_BUS \
			if AudioServer.get_bus_index(DIRECTOR_SCRIPT.SFX_BUS) >= 0 else &"Master"
		check(flat.bus == expected, "routed to %s (got %s)" % [expected, flat.bus])

	_silence()
	director.play_at(&"tree_fall", Vector3(12.0, 3.0, -4.0))
	var spatial: AudioStreamPlayer3D = _first_3d_playing()
	check(spatial != null, "play_at() starts a positional voice")
	if spatial != null:
		check(spatial.global_position.is_equal_approx(Vector3(12.0, 3.0, -4.0)),
			"positioned at the event (%v)" % spatial.global_position)
		check(is_equal_approx(spatial.max_distance, DIRECTOR_SCRIPT.DEFAULT_MAX_DISTANCE_M),
			"a world event carries the full distance")

	_silence()
	director.play_at(&"footstep_mud", Vector3.ZERO)
	var step: AudioStreamPlayer3D = _first_3d_playing()
	check(step != null and is_equal_approx(step.max_distance,
			DIRECTOR_SCRIPT.CLOSE_MAX_DISTANCE_M),
		"a footstep is range-limited so a four-player camp stays listenable")

	check(not director.has_cue(&"definitely_not_a_cue"), "unknown cue is rejected")


func _check_round_robin() -> void:
	print("\n== variants round-robin ==")
	var seen: Dictionary[String, bool] = {}
	var pitches: Array[float] = []
	for i: int in 8:
		_silence()
		director.play_at(&"footstep_mud", Vector3.ZERO)
		var voice: AudioStreamPlayer3D = _first_3d_playing()
		if voice != null and voice.stream != null:
			seen[voice.stream.resource_path] = true
			pitches.append(voice.pitch_scale)
	var expected_variants: int = int(CATALOGUE.CUES[&"footstep_mud"][0])
	check(seen.size() == expected_variants,
		"8 plays cycled all %d variants (saw %d)" % [expected_variants, seen.size()])
	var unique_pitches: Dictionary[float, bool] = {}
	for p: float in pitches:
		unique_pitches[p] = true
	check(unique_pitches.size() > 1, "repeats are pitch-scattered (%d distinct)"
		% unique_pitches.size())


func _check_dedupe() -> void:
	print("\n== dedupe ==")
	_silence()
	# Several services emit a confirmation AND a state change for one action;
	# without the window, one pickup plays four times.
	director.play(&"item_pickup")
	var first: int = _flat_playing_count()
	director.play(&"item_pickup")
	director.play(&"item_pickup")
	check(_flat_playing_count() == first,
		"three immediate plays of one cue sound once (%d voices)" % _flat_playing_count())


## The point of this one: drive the REAL signals and confirm a voice results, so
## the handler signatures are proven against the emitters rather than assumed.
func _check_events_reach_voices() -> void:
	print("\n== real events reach voices ==")
	_silence()
	EVENT_BUS.emit_harvest_yielded(&"tree", 1, &"wood", 1, Vector3(4.0, 1.0, 2.0))
	await process_frame
	check(_first_3d_playing() != null, "harvest_yielded plays a chop at the event")

	_silence()
	EVENT_BUS.emit_cycle_advanced(3)
	await process_frame
	check(_first_flat_playing() != null, "cycle_advanced plays its stinger")

	_silence()
	EVENT_BUS.emit_wellspring_capped(&"spring", Vector3(9.0, 0.0, 9.0))
	await process_frame
	check(_first_3d_playing() != null, "wellspring_capped plays at the spring")

	var combat: Node = root.get_node_or_null(^"CombatService")
	if combat != null and combat.has_signal(&"attack_landed"):
		_silence()
		combat.attack_landed.emit(1, Vector3(1.0, 1.0, 1.0), 4, &"Enemy_crawler_3")
		await process_frame
		var voice: AudioStreamPlayer3D = _first_3d_playing()
		check(voice != null, "attack_landed plays an impact")
		if voice != null and voice.stream != null:
			check(voice.stream.resource_path.contains("carapace"),
				"a crawler reads as carapace, not flesh (%s)"
				% voice.stream.resource_path.get_file())
	else:
		check(false, "CombatService exposes attack_landed")

	var build: Node = root.get_node_or_null(^"BuildService")
	if build != null and build.has_signal(&"build_confirmed"):
		_silence()
		build.build_confirmed.emit(1, false, "no room")
		await process_frame
		check(_first_flat_playing() != null, "a refused placement plays the denial")
	else:
		check(false, "BuildService exposes build_confirmed")


## The UI is wired without a line in any UI file — focus movement is the hover
## and every BaseButton reports its own press — so these assertions are the only
## thing standing between that and a silent menu after someone adds a screen.
func _check_ui_hooks() -> void:
	print("\n== ui, wired without touching a ui file ==")
	var layer := CanvasLayer.new()
	root.add_child(layer)
	var button := Button.new()
	button.text = "probe"
	layer.add_child(button)
	await process_frame

	_silence()
	button.pressed.emit()
	check(_first_flat_playing() != null, "a BaseButton press plays a click")

	_silence()
	# `_last_screen_change` suppresses the hover right after a screen opens, so
	# push it back before testing focus.
	director._last_screen_change = -999.0
	button.grab_focus()
	await process_frame
	check(_first_flat_playing() != null, "moving focus plays a hover")

	_silence()
	layer.queue_free()


func _check_ambient_scatter() -> void:
	print("\n== ambient life ==")
	var day: Array = DIRECTOR_SCRIPT.AMBIENT_DAY_CUES
	var night: Array = DIRECTOR_SCRIPT.AMBIENT_NIGHT_CUES
	check(day.size() >= 5 and night.size() >= 5,
		"day pool %d cues, night pool %d cues" % [day.size(), night.size()])
	# The pools must actually differ, or day and night sound identical and the
	# whole day/night derivation below them is wasted.
	var shared: int = 0
	for cue: StringName in day:
		if night.has(cue):
			shared += 1
	check(shared < day.size(), "day and night pools differ (%d of %d shared)"
		% [shared, day.size()])
	check(night.has(&"frog_croak") and not day.has(&"frog_croak"),
		"frogs are a night sound")
	check(day.has(&"bird_call") and not night.has(&"bird_call"),
		"songbirds are a day sound")
	# With no player there is nothing to place a sound relative to, and the
	# scatterer must stay silent rather than fire at the origin.
	_silence()
	director._next_ambient_at = -1.0
	director._tick_ambient()
	check(not director.is_playing(),
		"no ambient event without a local player to place it around")


# ── helpers ──────────────────────────────────────────────────────────────────


func _paths_for(cue: StringName, count: int) -> PackedStringArray:
	var out := PackedStringArray()
	if count <= 1:
		out.append("%s/%s.wav" % [SFX_DIR, cue])
	else:
		for v: int in range(1, count + 1):
			out.append("%s/%s_%02d.wav" % [SFX_DIR, cue, v])
	return out


func _silence() -> void:
	for child: Node in director.get_children():
		if child is AudioStreamPlayer3D:
			(child as AudioStreamPlayer3D).stop()
		elif child is AudioStreamPlayer:
			(child as AudioStreamPlayer).stop()
	# The dedupe window is real time; clear the ledger so back-to-back
	# assertions on the same cue are not swallowed by it.
	director._last_played.clear()


func _first_3d_playing() -> AudioStreamPlayer3D:
	for child: Node in director.get_children():
		var p := child as AudioStreamPlayer3D
		if p != null and p.playing:
			return p
	return null


func _first_flat_playing() -> AudioStreamPlayer:
	for child: Node in director.get_children():
		if child is AudioStreamPlayer3D:
			continue
		var p := child as AudioStreamPlayer
		if p != null and p.playing:
			return p
	return null


func _flat_playing_count() -> int:
	var n: int = 0
	for child: Node in director.get_children():
		if child is AudioStreamPlayer3D:
			continue
		var p := child as AudioStreamPlayer
		if p != null and p.playing:
			n += 1
	return n


func finish() -> void:
	quit(0 if failures == 0 else 1)
