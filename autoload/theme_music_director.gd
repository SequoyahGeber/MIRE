extends Node

## ThemeMusicDirector — task 7.2's authored themes, and the only thing that plays them.
##
## `AmbientMusicDirector` owns the *bed* (day/night, always on, tempo-free); `BossMusicDirector`
## owns the 7-second boss hit. Neither is a home for a two-minute composed piece with a tune, and
## F-373's lesson is the one that matters here: an .ogg that nothing references is a silent game
## with no error anywhere. So each of the three themes gets a cue with a trigger, and this file is
## the reference.
##
## | Cue | Asset | Plays when | Ends when |
## |---|---|---|---|
## | `menu` | `menu_theme.ogg` ("Hollowmere Hymn") | the front end is on screen | it leaves |
## | `landfall` | `theme_landfall.ogg` ("Wake the Deep") | a run starts | one pass, then fades |
## | `cycle` | `theme_cycle.ogg` ("Mire Rites") | `cycle_advanced` past Cycle 1 | one pass, then fades |
## | `dawn` | `theme_dawn.ogg` ("First Light") | night->day, after a night survived | one pass, then fades |
##
## WHY THOSE THREE PAIRINGS. The hymn is the calm one, and a title screen is the one place in this
## game a track can be left running for twenty minutes — fatigue is the deciding constraint there,
## not impact. "Wake the Deep" is the only candidate with a real A-B-A tune and the full
## horns/strings/choir arrangement, which is what landfall wants and is exactly wrong as something
## you loop forever behind a menu. "Mire Rites" builds across four stages and ends on a hard stop:
## that is the shape of an escalation cue, and it is why it fires on the cycle turning rather than
## on a timer. "First Light" is the odd one out and deliberately so: it is the only cue that is not
## about the mire at all. Two of every three mornings (`CycleService.DAYS_PER_CYCLE` is 3) nothing
## has escalated and the players have simply lived through a night, and a 6/8 jig is the one thing in
## the palette that reads as *people* rather than as place — which is why it gets the whistle and the
## bodhran and the Cycle cue keeps the frame drums and the chant. On the third morning the escalation
## wins the slot; see `_poll_dawn()`. Swapping any of them is one line in `CUE_PATHS` plus a
## re-`--ship`.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, "VFX, audio, camera, UI"): **none.** Client-local
## presentation, the same row the other two directors sit in. Every peer runs its own copy against
## its own local `EventBus`; `cycle_advanced` is already dispatched identically on host and client
## (`systems/cycle/cycle_service.gd` re-emits it from the replicated setter for exactly this), so
## nothing here needs an RPC and there must never be an audio RPC (docs/AUDIO.md "Network authority").
##
## WHY THE FRONT END IS POLLED AND THE RUN START IS AN EDGE OF THAT POLL. There is no "front end
## closed" signal to subscribe to, and `EventBus.run_restarted` fires on a *restart*, not on the
## first entry into a run from the title screen — wiring landfall to `run_restarted` alone would
## therefore play the theme on every retry and never on the first run of a session, which is
## backwards. `ui/frontend/frontend.gd` puts itself in the `mire_frontend` group and
## `ui/menu/pause_menu.gd` already treats the ABSENCE of that group as the definition of being in a
## run; this file reads the same group and treats the falling edge — front end was up, now is not —
## as landfall. That covers pressing PLAY, and `_ready()` covers the case the shipped build does not
## take yet: `project.godot`'s `run/main_scene` still boots straight into the world while task 4.19's
## cutover is in flight, so a process that starts with no front end anywhere has already made
## landfall and the cue fires immediately.
##
## WHY EVERY CUE LOOPS EVEN THOUGH TWO OF THEM PLAY ONCE. All three tracks are rendered circularly
## (`tools/audio/render_theme.py`'s `finish()` folds the reverb and instrument decay back onto the
## head, same as the ambient beds), which means the first seconds of the file legitimately contain
## the last seconds' tail. Played as a non-looping one-shot the track would still sound right, but
## it would stop dead at the fold instead of arriving anywhere. So the bounded cues loop like the
## rest and are ended by a timed fade over their final `FADE_OUT_SEC` — the fold is then never heard
## as an edge, only as the wash it was written to be.

const EVENT_BUS := preload("res://core/events/event_bus.gd")

const CUE_MENU: StringName = &"menu"
const CUE_LANDFALL: StringName = &"landfall"
const CUE_CYCLE: StringName = &"cycle"
## The morning tune — "First Light", a 6/8 double jig. One pass on the night->day crossing, on every
## morning the Cycle theme does not already own. Sequoyah asked for it in exactly those words: a
## happy jig to celebrate surviving another night.
const CUE_DAWN: StringName = &"dawn"

const CUE_PATHS: Dictionary[StringName, String] = {
	CUE_MENU: "res://assets/audio/music/menu_theme.ogg",
	CUE_LANDFALL: "res://assets/audio/music/theme_landfall.ogg",
	CUE_CYCLE: "res://assets/audio/music/theme_cycle.ogg",
	CUE_DAWN: "res://assets/audio/music/theme_dawn.ogg",
}

## Cues that hold for as long as their condition does. Anything not listed here plays exactly one
## pass and then hands the mix back to the ambient bed.
const HOLDING_CUES: Array[StringName] = [CUE_MENU]

## `ui/frontend/frontend.gd`'s own group constant, read rather than imported: `pause_menu.gd` already
## keeps a second copy of this literal for the same reason, and a preload of the front-end script
## from an autoload would pull the whole title-screen tree into every headless check.
const FRONTEND_GROUP: StringName = &"mire_frontend"

## The bus `SettingsService._ensure_audio_buses()` creates at runtime — shared with both other
## directors so ONE music slider governs bed, stinger and theme together.
const MUSIC_BUS: StringName = &"Music"

const FADE_IN_SEC: float = 1.5
## Long, because it is a musical ending rather than a mute: eight seconds is roughly the last
## phrase of either bounded cue, and it is the same figure `AmbientMusicDirector.CROSSFADE_SEC`
## uses for the dusk crossing.
const FADE_OUT_SEC: float = 8.0

## Per-cue override of the fade-out above. `dawn` is the one cue that ENDS — the jig plays its own
## button and lets the room ring, and an 8 s fade would start pulling the volume down four bars
## before the end — over the band's last entry, which is the loudest and most deliberate part of the
## whole set (see the arrangement map in `render_theme.py`'s `first_light_jig()`). 3 s
## rides the composed ring-out instead of cutting into the music, and is still long enough that a
## `cycle` cue landing on top of it (see `_poll_dawn()`) is a crossfade rather than a cut.
const CUE_FADE_OUT: Dictionary[StringName, float] = {
	CUE_DAWN: 3.0,
}

## How long after the day threshold the jig starts. Two things want this delay. Musically the sun
## should crest before the tune does, and mechanically it is the window in which a `cycle_advanced`
## can still arrive and claim the morning: `CycleService` reacts to the HOST's `day_started` signal
## and a client only learns the new Cycle when the WorldDeltaLog record replicates, both of which
## land after this file's own poll has already seen the crossing.
const DAWN_DELAY_SEC: float = 2.0

## The same fallbacks `AmbientMusicDirector` carries, for a harness with no `DayNight` autoload.
const FALLBACK_NIGHT_AT: float = 0.75
const FALLBACK_DAY_AT: float = 0.25

## Cycle 1 is the start of the run, which landfall already covers — an escalation cue on the cycle
## the player has been in since the first frame would fire on top of it and mean nothing.
const FIRST_CUE_CYCLE: int = 2

const SILENT_DB: float = -60.0
## Below this a channel is stopped outright rather than merely quiet, so an idle director holds zero
## decoding ogg streams instead of three. Same threshold and same reasoning as the ambient bed's.
const AUDIBLE_EPSILON: float = 0.0005

var _players: Dictionary[StringName, AudioStreamPlayer] = {}
## Where each cue's fade is now, 0..1 linear.
var _gain: Dictionary[StringName, float] = {}
## The cue that WANTS to be audible; empty means "ambient bed owns the mix".
var _active: StringName = &""
## Seconds into the active cue's single pass. Meaningless for a holding cue.
var _elapsed: float = 0.0
var _frontend_up: bool = false

## Dawn-trigger state. `_was_night` is the previous poll's answer, so the trigger is the EDGE and not
## the phase; `_seen_night` gates the very first morning of a run — a run that starts in daylight has
## not survived anything yet, and the jig would be celebrating nothing. `_dawn_pending` counts down
## `DAWN_DELAY_SEC` and is negative when nothing is armed.
var _day_night_node: Node
var _was_night: bool = false
var _seen_night: bool = false
var _dawn_pending: float = -1.0


func _ready() -> void:
	# Music is not simulation: it must survive the pause menu and `DebugConsole`'s
	# `pause_while_open`. Identical reasoning, and identical call, to AmbientMusicDirector's.
	process_mode = Node.PROCESS_MODE_ALWAYS

	for cue: StringName in CUE_PATHS:
		_players[cue] = _make_player(cue, CUE_PATHS[cue])
		_gain[cue] = 0.0

	_frontend_up = _frontend_visible()
	# Seed the edge detector with the phase we booted into, so loading straight into a night run does
	# not read as a night->day crossing on the first frame of the first poll.
	_was_night = _clock_is_night()
	_seen_night = _was_night
	if _frontend_up:
		_active = CUE_MENU
	else:
		# No front end anywhere at boot — either the 4.19 cutover has not landed and the process went
		# straight to the world, or this is a headless check. Landfall has already happened.
		_start_bounded(CUE_LANDFALL)
	_snap_active_gain()

	EVENT_BUS.subscribe_cycle_advanced(_on_cycle_advanced)
	EVENT_BUS.subscribe_run_restarted(_on_run_restarted)
	set_process(true)
	_apply()


func _exit_tree() -> void:
	EVENT_BUS.unsubscribe_cycle_advanced(_on_cycle_advanced)
	EVENT_BUS.unsubscribe_run_restarted(_on_run_restarted)


func _process(delta: float) -> void:
	advance(delta)


## The whole per-frame update, exposed the way `AmbientMusicDirector.advance()` and
## `DayNight.host_advance()` are: `tools/theme_music_check.gd` drives a full two-minute cue in a
## handful of calls through this exact path rather than a test-only parallel one. Production has
## exactly one caller, `_process` above.
func advance(delta: float) -> void:
	_poll_frontend()
	_poll_dawn(delta)
	_step_active(delta)
	_step_gains(delta)
	_apply()


## True while any theme is audible. `AmbientMusicDirector` reads this director's child players
## directly (its `_music_playing()` scans children of any director it can reach), so this exists for
## checks and for anything later that wants the answer without walking the tree.
func is_playing() -> bool:
	for cue: StringName in _players:
		var player: AudioStreamPlayer = _players[cue]
		if player != null and player.playing:
			return true
	return false


## Which cue currently owns the mix, or &"" for none. Checks assert on this rather than on gains.
func active_cue() -> StringName:
	return _active


## Takes the active cue straight to its full gain instead of leaving it at zero for `FADE_IN_SEC` to
## ramp up. Used at the two moments there is nothing to fade FROM — boot, and a run restart — which
## is the identical argument `AmbientMusicDirector._ready()` makes for snapping its own mix ("nothing
## was playing to fade from").
##
## F-430 is what the ramp cost. A cue at gain 0 is not merely quiet: `_apply_channel()` STOPS a
## channel below `AUDIBLE_EPSILON`, so a fading-in theme makes no sound whatsoever until the first
## `_process` frame moves its gain off zero. The first frame of a real boot is the one that
## instantiates `run/main_scene` and compiles its shaders — seconds, during which the ambient bed
## (started from ITS `_ready()`, at full, because no theme was playing yet to duck it) was the entire
## soundtrack. Then that frame's `delta` — the whole stall — arrived at once, which is large enough
## for `move_toward` to finish the fade in a single step, so the intended 1.5 s crossfade was heard
## as a cut. Snapping here means the theme is the first thing the process plays, and the bed comes up
## underneath it already ducked (see `AmbientMusicDirector.advance()`'s boot branch).
func _snap_active_gain() -> void:
	if _active == &"":
		return
	_gain[_active] = _active_target()


# ── State ────────────────────────────────────────────────────────────────────────────────────────


## The front end appearing or disappearing is the only state transition this director cannot be told
## about, so it is the only one polled. The falling edge IS landfall — see the header.
func _poll_frontend() -> void:
	var up: bool = _frontend_visible()
	if up == _frontend_up:
		return
	_frontend_up = up
	if up:
		# Back at the title after a run: the menu theme resumes and any bounded cue is abandoned
		# rather than allowed to keep running under it.
		_active = CUE_MENU
		_elapsed = 0.0
	elif _active == CUE_MENU:
		_start_bounded(CUE_LANDFALL)


func _frontend_visible() -> bool:
	var tree: SceneTree = get_tree()
	if tree == null:
		return false
	return not tree.get_nodes_in_group(FRONTEND_GROUP).is_empty()


func _start_bounded(cue: StringName) -> void:
	if not CUE_PATHS.has(cue):
		return
	_active = cue
	_elapsed = 0.0


## A bounded cue retires itself once it has played one full pass. `_cue_length()` is read off the
## loaded stream rather than hard-coded, so re-rendering a theme at a different length retunes the
## hand-back without touching this file.
func _step_active(delta: float) -> void:
	if _active == &"" or HOLDING_CUES.has(_active):
		return
	_elapsed += delta
	if _elapsed >= _cue_length(_active):
		_active = &""
		_elapsed = 0.0


## 1.0 for a holding cue and for the body of a bounded one; ramps to 0 across the final
## `FADE_OUT_SEC` so a bounded cue ends on a decrescendo instead of a cut.
func _active_target() -> float:
	if _active == &"" or HOLDING_CUES.has(_active):
		return 1.0
	var fade: float = _fade_out_for(_active)
	var remaining: float = _cue_length(_active) - _elapsed
	if remaining >= fade:
		return 1.0
	return clampf(remaining / maxf(fade, 0.001), 0.0, 1.0)


func _fade_out_for(cue: StringName) -> float:
	return float(CUE_FADE_OUT.get(cue, FADE_OUT_SEC))


func _cue_length(cue: StringName) -> float:
	var player: AudioStreamPlayer = _players.get(cue) as AudioStreamPlayer
	if player == null or player.stream == null:
		return 0.0
	return maxf(player.stream.get_length(), 0.001)


## Rates are expressed as "full travel per span", so retuning either span changes how long a fade
## takes without also changing where it ends up — the same shape `AmbientMusicDirector._step_duck()`
## uses and for the same reason.
func _step_gains(delta: float) -> void:
	var wanted: float = _active_target()
	for cue: StringName in _players:
		var target: float = wanted if cue == _active else 0.0
		var current: float = float(_gain.get(cue, 0.0))
		var span: float = FADE_IN_SEC if target > current else _fade_out_for(cue)
		_gain[cue] = move_toward(current, target, delta / maxf(span, 0.001))


func _apply() -> void:
	var bus: StringName = _resolve_bus()
	for cue: StringName in _players:
		_apply_channel(_players[cue], float(_gain.get(cue, 0.0)), bus)


func _apply_channel(player: AudioStreamPlayer, gain: float, bus: StringName) -> void:
	if player == null or player.stream == null:
		return
	# Re-resolved rather than cached: the "Music" bus is created at RUNTIME by SettingsService with
	# no committed bus layout, so this autoload's boot order relative to it is not guaranteed and an
	# answer cached in `_ready()` would freeze on whichever came up first. Assigning only on a change
	# keeps it a string compare per frame.
	if player.bus != bus:
		player.bus = bus

	var linear: float = clampf(gain, 0.0, 1.0)
	if linear <= AUDIBLE_EPSILON:
		player.volume_db = SILENT_DB
		if player.playing:
			player.stop()
		return
	player.volume_db = linear_to_db(linear)
	if not player.playing:
		player.play()


# ── Events ───────────────────────────────────────────────────────────────────────────────────────


## Unconditional on authority, like every other `cycle_advanced` subscriber: a client fires its own
## copy off its own re-emitted signal and needs no guard to do it.
func _on_cycle_advanced(cycle: int) -> void:
	if cycle < FIRST_CUE_CYCLE:
		return
	if _frontend_up:
		return
	# This morning belongs to the escalation, not the celebration. Disarming rather than letting
	# `_start_bounded()` overwrite matters because the Cycle cue usually wins the race by a frame or
	# two and the jig would otherwise be armed to interrupt it two seconds in.
	_dawn_pending = -1.0
	_start_bounded(CUE_CYCLE)


## A new run is a hard boundary. Landfall restarts from the top rather than continuing whatever the
## dead run left running — including a cycle cue from Cycle 9 of the run that just ended, which is
## the one combination that would otherwise survive across the boundary and score the wrong moment.
func _on_run_restarted() -> void:
	_dawn_pending = -1.0
	_was_night = _clock_is_night()
	_seen_night = _was_night
	if _frontend_up:
		_active = CUE_MENU
		_elapsed = 0.0
		return
	for cue: StringName in _players:
		var player: AudioStreamPlayer = _players[cue]
		if player != null and player.playing:
			player.stop()
		_gain[cue] = 0.0
	_start_bounded(CUE_LANDFALL)
	# Snap, for the same reason boot does: this handler just stopped every player above, so there is
	# nothing left to cross-fade against, and a restart that loads a fresh world stalls exactly like a
	# boot does (F-430).
	_snap_active_gain()
	_apply()


# ── Dawn ─────────────────────────────────────────────────────────────────────────────────────────


## The morning trigger, and it is a POLL for the same reason `AmbientMusicDirector` polls: DayNight's
## `day_started`/`night_started` are documented HOST ONLY and the code means it — `_advance_client()`
## never calls `_check_thresholds()`, so a connected client would never hear the jig at all if this
## were wired to the signal. Every peer reads its own local copy of the replicated clock and arrives
## at the same crossing within a frame of the others.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, "VFX, audio, camera, UI"): none. Client-local
## presentation, no RPC, same row the rest of this file sits in.
func _poll_dawn(delta: float) -> void:
	var night: bool = _clock_is_night()
	if night:
		_seen_night = true
		# A clock that jumps backwards into night (`time set`, a restart) disarms anything pending
		# rather than firing the jig into the dark a moment later.
		_dawn_pending = -1.0
	elif _was_night and _seen_night:
		_dawn_pending = DAWN_DELAY_SEC
	_was_night = night

	if _dawn_pending < 0.0:
		return
	_dawn_pending -= delta
	if _dawn_pending > 0.0:
		return
	_dawn_pending = -1.0
	if _frontend_up:
		return
	if _active == CUE_CYCLE:
		return
	_start_bounded(CUE_DAWN)


func _clock_is_night() -> bool:
	var clock: Node = _day_night()
	if clock == null:
		return _was_night
	var fraction: float = _clock_float(clock, &"time_of_day", 0.348)
	var night_at: float = _clock_float(clock, &"night_started_at", FALLBACK_NIGHT_AT)
	var day_at: float = _clock_float(clock, &"day_started_at", FALLBACK_DAY_AT)
	return fraction >= night_at or fraction < day_at


func _clock_float(clock: Node, property: StringName, fallback: float) -> float:
	var raw: Variant = clock.get(property)
	if typeof(raw) == TYPE_FLOAT or typeof(raw) == TYPE_INT:
		return float(raw)
	return fallback


## Re-resolved on loss rather than cached once, exactly as `AmbientMusicDirector._day_night()` does:
## a harness scene can come up without the autoload and a check can free it mid-run.
func _day_night() -> Node:
	if _day_night_node != null and is_instance_valid(_day_night_node):
		return _day_night_node
	_day_night_node = get_node_or_null(^"/root/DayNight")
	return _day_night_node


# ── Construction / plumbing ──────────────────────────────────────────────────────────────────────


func _make_player(cue: StringName, path: String) -> AudioStreamPlayer:
	var player := AudioStreamPlayer.new()
	player.name = String(cue).capitalize()
	player.bus = _resolve_bus()
	player.volume_db = SILENT_DB
	var stream: AudioStream = load(path) as AudioStream
	var ogg := stream as AudioStreamOggVorbis
	if ogg != null and not ogg.loop:
		# Belt and braces over the committed `.ogg.import` sidecars, exactly as the ambient beds do
		# it: an import that silently loses `loop=true` would make every cue a one-shot that stops at
		# the circular fold, with nothing logged anywhere.
		ogg.loop = true
	player.stream = stream
	add_child(player)
	return player


## Falls back to "Master" rather than refusing to play, same as both other directors: a harness or a
## boot that never ran SettingsService's bus setup still gets a soundtrack.
func _resolve_bus() -> StringName:
	if AudioServer.get_bus_index(MUSIC_BUS) >= 0:
		return MUSIC_BUS
	return &"Master"
