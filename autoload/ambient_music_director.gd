extends Node

## AmbientMusicDirector — F-373. `assets/audio/music/ambient_day.ogg` and `ambient_night.ogg` were
## rendered, imported, loudness-checked and written up in `docs/AUDIO.md`'s music table, and then
## referenced by NOTHING: a recursive search across `content/`, `systems/`, `autoload/`, `world/`,
## `ui/` and `core/` returned zero hits for either filename. The only music player in the repo was
## `autoload/boss_music_director.gd`, whose `CUE_PATHS` holds exactly one entry (`boss_stinger`), so
## the shipped game was silent from boot until a boss engaged and silent again seven seconds later.
## Sequoyah reported it from play as "the music/soundtrack does not play". Everything else this
## needed already existed — `SettingsService` (7.5) creates the "Music" bus and owns the slider that
## governs it — so this file is the missing consumer and nothing else, exactly the fix F-373 asks
## for and the one `docs/AUDIO.md`'s own "Not done yet" list has been naming since 7.2.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, "VFX, audio, camera, UI" row): **none.** This is
## client-local presentation, the same row `BossMusicDirector` sits in. Every peer runs its own copy
## against its OWN local clock reading; nothing here sends an RPC, and nothing here reads or writes a
## replicated property except `DayNight.time_of_day`, which the host already replicates for the sky.
## There must never be an audio RPC (docs/AUDIO.md "Network authority").
##
## THE TRAP THIS FILE EXISTS TO AVOID — why the phase is POLLED and not just taken off the signals.
## `DayNight.night_started`/`day_started` are documented HOST ONLY, and the code means it:
## `_check_thresholds()` is called from `_advance_host()` and `host_set_time()`, and `_advance_client()`
## calls neither. A connected client therefore never receives either signal for the whole run. Wiring
## the crossfade to the signals alone — which is what `docs/AUDIO.md`'s sketch of this autoload
## suggests, and what `systems/waves/wave_spawner.gd` legitimately does because IT is a host-side
## system — would give the host a day/night soundtrack and leave every joining player on whichever
## bed happened to be up when they booted. So `_clock_is_night()` re-derives the phase every frame
## from `time_of_day` (which IS replicated, ~1 Hz, and interpolated on the client) against DayNight's
## OWN `night_started_at`/`day_started_at` exports — the identical comparison `DayNight._is_night()`
## makes, read off the exports rather than copied, so retuning the threshold retunes the music with
## the sky. The two signals are still connected on top of that: they are the same-frame edge for a
## `time set dusk` console jump on the host, and they cost nothing because both handlers set the same
## target the poll would have set a frame later.
##
## Two players, crossfaded, rather than one player whose stream is swapped: a hard cut between two
## 3:44 beds at dusk is the single most noticeable thing an ambient soundtrack can do wrong, and the
## eight-second fade `docs/AUDIO.md` specifies needs both streams audible at once to happen at all.
## The fade is EQUAL POWER (`cos`/`sin` of the same ramp, so day² + night² == 1) rather than a linear
## gain ramp — the two beds are different keys over different pedals (D Dorian / A Aeolian) and so are
## essentially uncorrelated, which is precisely the case where a linear crossfade audibly dips ~3 dB
## through the middle.

const EVENT_BUS := preload("res://core/events/event_bus.gd")

const DAY_STREAM_PATH := "res://assets/audio/music/ambient_day.ogg"
const NIGHT_STREAM_PATH := "res://assets/audio/music/ambient_night.ogg"

## The bus `SettingsService._ensure_audio_buses()` creates at runtime and `set_music_volume()` drives,
## and the same one `BossMusicDirector` plays into — that shared routing is what makes ONE music
## slider govern the bed and the stinger together, which is the whole reason neither director applies
## a player-facing volume of its own.
const MUSIC_BUS: StringName = &"Music"

## Seconds for a full day <-> night crossfade. `docs/AUDIO.md`'s ambient-director entry asks for "~8 s";
## the crossing itself is a threshold, not a ramp, so this is the only place the transition has any
## length at all.
const CROSSFADE_SEC: float = 8.0

## While a boss stinger is audible, the bed drops to this fraction of its gain (~-11 dB) rather than
## stopping: the stinger is a ~7 s hit whose back half is reverb tail, and cutting the bed out from
## under it would leave a hole in the mix every time a boss changes phase. Attack is fast enough that
## the duck is already down under the stinger's own transient; release is slow so the bed swells back
## under the tail instead of popping in behind it.
const DUCK_GAIN: float = 0.28
const DUCK_ATTACK_SEC: float = 0.35
const DUCK_RELEASE_SEC: float = 2.5

## A theme (`ThemeMusicDirector`, 7.2) ducks the bed much harder than a stinger does, because it is a
## different kind of thing: a stinger is a 7 s event the bed should be heard UNDER, while a theme is
## two minutes of full arrangement that owns the mix outright. -20 dB leaves the bed as air rather
## than as a second piece of music in a second key — which is what 0.28 would give, and the two beds
## are in D Dorian and A Aeolian while the themes are in their own keys.
##
## Deliberately still above `AUDIBLE_EPSILON`: taking the bed to actual zero would STOP its channel
## (see `_apply_channel`), and a stopped `AudioStreamPlayer` resumes from the head of a 3:44 loop —
## so a cycle cue ending mid-run would silently rewind the bed. Ducking to a whisper keeps its
## playhead where the run left it.
const THEME_DUCK_GAIN: float = 0.10

## `AudioStreamPlayer.volume_db` bottoms out at -80; -60 is 0.001 linear and already inaudible under
## any master setting, and a channel that reaches it is stopped outright anyway (see `_apply_channel`).
const SILENT_DB: float = -60.0
## Below this linear gain a channel is treated as off — stopped, not merely quiet, so a steady day or
## night holds exactly ONE decoding ogg stream instead of two. `cos(PI/2)` is 6e-17 rather than a
## clean zero, so this cannot be an `== 0.0` test.
const AUDIBLE_EPSILON: float = 0.0005

## Used only when no `/root/DayNight` is reachable at all AND its exports cannot be read — a harness
## tree, a `--script` check that never registered it. Mirrors DayNight's own authored defaults.
const FALLBACK_NIGHT_AT: float = 0.75
const FALLBACK_DAY_AT: float = 0.25

var _day_player: AudioStreamPlayer
var _night_player: AudioStreamPlayer

## 0.0 = full day bed, 1.0 = full night bed. `_night_mix` is where the fade is now, `_target_mix`
## where the clock says it should be; the only thing that ever moves between them is `_step_mix()`.
var _night_mix: float = 0.0
var _target_mix: float = 0.0
## Multiplies BOTH channels. 1.0 = no duck, `DUCK_GAIN` = a boss stinger is sounding.
var _duck: float = 1.0

var _day_night_node: Node
var _boss_director_node: Node
var _theme_director_node: Node


func _ready() -> void:
	# The bed must survive the pause menu. Autoloads inherit from the root, which resolves to
	# PROCESS_MODE_PAUSABLE, and a pausable AudioStreamPlayer stops dead the moment `SceneTree.paused`
	# goes true — so opening the pause menu (or `DebugConsole`'s `pause_while_open`, which does set it,
	# autoload/debug_console.gd:129) would kill the soundtrack and resume it on close. Music is not
	# simulation. Same call `MenuStack`, `CommandService` and `NetTransport` already make for the same
	# reason; the players below inherit it from this node.
	process_mode = Node.PROCESS_MODE_ALWAYS

	_day_player = _make_player(&"AmbientDay", DAY_STREAM_PATH)
	_night_player = _make_player(&"AmbientNight", NIGHT_STREAM_PATH)

	# Snap, do not fade, at boot: nothing was playing to fade FROM, and a player who loads straight
	# into a night run should hear the night bed immediately rather than eight seconds of the day one.
	_target_mix = 1.0 if _clock_is_night() else 0.0
	_night_mix = _target_mix

	EVENT_BUS.subscribe_run_restarted(_on_run_restarted)
	set_process(true)
	_apply_mix()


func _exit_tree() -> void:
	EVENT_BUS.unsubscribe_run_restarted(_on_run_restarted)


func _process(delta: float) -> void:
	advance(delta)


## The whole per-frame update, exposed the same way `DayNight.host_advance()` is and for the same
## reason: a headless check (`tools/ambient_music_check.gd`) can drive a full eight-second crossfade
## in three calls instead of waiting on the wall clock, through the exact code path the real frame
## uses rather than a parallel test-only one. Production has exactly one caller, `_process` above.
func advance(delta: float) -> void:
	# The poll is the source of truth for the phase — see the header's "THE TRAP" note. It runs
	# unconditionally, so a client (which never gets the two signals) and a host that jumped its clock
	# with `time set` both converge on the same target within a frame.
	_target_mix = 1.0 if _clock_is_night() else 0.0
	_step_mix(delta)
	_step_duck(delta)
	_apply_mix()


# ── Fade state ───────────────────────────────────────────────────────────────────────────────────


func _step_mix(delta: float) -> void:
	if is_equal_approx(_night_mix, _target_mix):
		_night_mix = _target_mix
		return
	_night_mix = move_toward(_night_mix, _target_mix, delta / maxf(CROSSFADE_SEC, 0.001))


## The duck ramps at a rate expressed in "full duck depth per attack/release span", so retuning
## `DUCK_GAIN` alone changes how DEEP the duck is without also changing how long it takes to get
## there — which is what a plain `move_toward(_duck, target, delta / span)` would have coupled.
func _step_duck(delta: float) -> void:
	var target: float = _duck_target()
	var span: float = DUCK_ATTACK_SEC if target < _duck else DUCK_RELEASE_SEC
	_duck = move_toward(_duck, target, delta * (1.0 - THEME_DUCK_GAIN) / maxf(span, 0.001))


## The deepest duck any audible director asks for. Both are checked every frame rather than one
## winning by priority: a boss engaged during a cycle cue is a real combination, and the bed should
## sit under whichever is asking for more room, not under whichever was noticed first.
func _duck_target() -> float:
	var target: float = 1.0
	if _music_playing(_boss_director()):
		target = minf(target, DUCK_GAIN)
	if _music_playing(_theme_director()):
		target = minf(target, THEME_DUCK_GAIN)
	return target


func _apply_mix() -> void:
	var bus: StringName = _resolve_bus()
	var angle: float = clampf(_night_mix, 0.0, 1.0) * PI * 0.5
	_apply_channel(_day_player, cos(angle), bus)
	_apply_channel(_night_player, sin(angle), bus)


## Also the "never goes silent" guard, which is the half of F-373 that a pure fade would not cover:
## any channel that should be audible and is NOT playing gets started here, every frame. That covers
## the run-restart snap below, a `stop()` from anywhere, and the one genuinely nasty failure mode —
## an ambient ogg whose `.import` loses `loop=true` would play once and leave the game permanently
## silent with no error anywhere. (`_make_player()` forces the flag on for the same reason.)
func _apply_channel(player: AudioStreamPlayer, gain: float, bus: StringName) -> void:
	if player == null or player.stream == null:
		return
	# Re-resolved rather than cached, exactly as `BossMusicDirector._resolve_bus()` explains: the
	# "Music" bus is created at RUNTIME by SettingsService with no committed bus layout, so this
	# autoload's boot order relative to it is not guaranteed and an answer cached at `_ready()` would
	# freeze on whichever came first. Assigning only on a change keeps it a string compare per frame.
	if player.bus != bus:
		player.bus = bus

	var linear: float = clampf(gain, 0.0, 1.0) * _duck
	if linear <= AUDIBLE_EPSILON:
		player.volume_db = SILENT_DB
		if player.playing:
			player.stop()
		return
	player.volume_db = linear_to_db(linear)
	if not player.playing:
		player.play()


# ── The clock ────────────────────────────────────────────────────────────────────────────────────


## True when the replicated clock sits in the night half. Identical comparison to `DayNight._is_night()`,
## but reading the two thresholds off the node's exports instead of copying the numbers, so retuning
## dusk retunes the sky and the soundtrack together. With no clock reachable at all the current target
## is returned unchanged — a main menu or a harness holds whatever bed it started on rather than
## flapping to day.
func _clock_is_night() -> bool:
	var clock: Node = _day_night()
	if clock == null:
		return _target_mix >= 0.5
	var fraction: float = _clock_float(clock, &"time_of_day", 0.348)
	var night_at: float = _clock_float(clock, &"night_started_at", FALLBACK_NIGHT_AT)
	var day_at: float = _clock_float(clock, &"day_started_at", FALLBACK_DAY_AT)
	return fraction >= night_at or fraction < day_at


func _clock_float(clock: Node, property: StringName, fallback: float) -> float:
	var raw: Variant = clock.get(property)
	if typeof(raw) == TYPE_FLOAT or typeof(raw) == TYPE_INT:
		return float(raw)
	return fallback


## Path-resolved and cached (F-011/F-099 — harnesses install DayNight at /root themselves, and this
## runs every frame), re-resolved if the node is ever freed. The two signal connections are made here
## rather than in `_ready()` so a DayNight that arrives LATER than this autoload still gets hooked;
## `has_signal` guards are the same shape `systems/waves/wave_spawner.gd` uses, and the
## `is_connected` guards keep a re-resolve from stacking a second connection.
func _day_night() -> Node:
	if _day_night_node != null and is_instance_valid(_day_night_node):
		return _day_night_node
	_day_night_node = get_node_or_null(^"/root/DayNight")
	if _day_night_node == null:
		return null
	if _day_night_node.has_signal(&"night_started") \
			and not _day_night_node.is_connected(&"night_started", _on_night_started):
		_day_night_node.connect(&"night_started", _on_night_started)
	if _day_night_node.has_signal(&"day_started") \
			and not _day_night_node.is_connected(&"day_started", _on_day_started):
		_day_night_node.connect(&"day_started", _on_day_started)
	return _day_night_node


func _on_night_started() -> void:
	_target_mix = 1.0


func _on_day_started() -> void:
	_target_mix = 0.0


# ── The duck ─────────────────────────────────────────────────────────────────────────────────────


## Read off a director's CHILDREN rather than its private `_players`: the array is private, and "does
## this director have an audible AudioStreamPlayer right now" is true of any music director this
## project grows. That generality is what let 7.2's `ThemeMusicDirector` be ducked by adding one line
## to `_duck_target()` rather than by teaching this file anything about cues.
func _music_playing(director: Node) -> bool:
	if director == null:
		return false
	for child: Node in director.get_children():
		var player := child as AudioStreamPlayer
		if player != null and player.playing:
			return true
	return false


func _boss_director() -> Node:
	if _boss_director_node == null or not is_instance_valid(_boss_director_node):
		_boss_director_node = get_node_or_null(^"/root/BossMusicDirector")
	return _boss_director_node


func _theme_director() -> Node:
	if _theme_director_node == null or not is_instance_valid(_theme_director_node):
		_theme_director_node = get_node_or_null(^"/root/ThemeMusicDirector")
	return _theme_director_node


# ── Run lifecycle ────────────────────────────────────────────────────────────────────────────────


## A new run is a hard boundary, not a transition: snap the mix, clear any duck the ended run left
## behind, and restart the bed from the top of the track so the run opens on the head of the loop
## rather than 2:40 into whatever was playing when the last one died.
##
## Ordering is what makes the snap read the RIGHT phase, and it is not luck. `DayNight._on_run_restarted()`
## resets `time_of_day` to the run-start morning, and EventBus dispatches `run_restarted` in
## subscription order, which for autoloads is `project.godot` registration order (D-021, append-only) —
## DayNight sits far above this entry, so its clock is already back at 0.348 by the time `_clock_is_night()`
## runs below. This handler is unconditional on authority like every other `run_restarted` subscriber:
## a client resets its own bed off its own replicated clock, and needs no guard to do it (see
## `core/events/event_bus.gd`'s `subscribe_run_restarted` note).
func _on_run_restarted() -> void:
	_target_mix = 1.0 if _clock_is_night() else 0.0
	_night_mix = _target_mix
	_duck = 1.0
	# Stop both, then let `_apply_mix()` start whichever channel the new run needs. The players
	# themselves are created once, in `_ready()`, and never replaced — a restart or a reseed must not
	# leave two AmbientDay nodes stacked and phasing against each other.
	if _day_player != null:
		_day_player.stop()
	if _night_player != null:
		_night_player.stop()
	_apply_mix()


# ── Construction / plumbing ──────────────────────────────────────────────────────────────────────


func _make_player(node_name: StringName, path: String) -> AudioStreamPlayer:
	var player := AudioStreamPlayer.new()
	player.name = node_name
	player.bus = _resolve_bus()
	player.volume_db = SILENT_DB
	var stream: AudioStream = load(path) as AudioStream
	var ogg := stream as AudioStreamOggVorbis
	if ogg != null and not ogg.loop:
		# Belt and braces over `assets/audio/music/*.ogg.import`'s own `loop=true`. Both beds are
		# 3:44 seamless loops (`tools/audio/render_music.py` folds the reverb tail back onto the head);
		# a bed that does not loop is a game that goes quiet 3:44 in and never comes back, with nothing
		# logged. `tools/audio_import_check.gd` asserts the import flag — this makes the runtime not
		# depend on it.
		ogg.loop = true
	player.stream = stream
	add_child(player)
	return player


## Falls back to "Master" rather than refusing to play, same as `BossMusicDirector._resolve_bus()`:
## a harness or a boot that never ran SettingsService's bus setup still gets a soundtrack.
func _resolve_bus() -> StringName:
	return MUSIC_BUS if AudioServer.get_bus_index(MUSIC_BUS) >= 0 else &"Master"


# ── Read-only accessors (tools/ambient_music_check.gd) ───────────────────────────────────────────


func day_player() -> AudioStreamPlayer:
	return _day_player


func night_player() -> AudioStreamPlayer:
	return _night_player


## 0.0 = full day bed, 1.0 = full night bed; anything between is mid-crossfade.
func night_mix() -> float:
	return _night_mix


## 1.0 = unducked, `DUCK_GAIN` = fully ducked under a boss stinger.
func duck_gain() -> float:
	return _duck
