extends Node

## Task 5.5's "music stinger" — client-local presentation, the same row `docs/AUDIO.md`'s own
## "Not done yet" list already named this task for ("More music: ... boss (5.5)").
##
## ARCHITECTURE.md §2.2 "VFX, audio, camera, UI": client-local only, never networked. Every peer
## reaches this from its OWN local `EventBus` — `Boss.phase`'s replicated setter and
## `Boss._play_state_animation()` (itself hung off `Enemy.state`'s replicated setter) are what
## guarantee that fires identically on host and client alike; see `core/events/event_bus.gd`'s
## `boss_engaged`/`boss_phase_changed`/`boss_defeated` doc comments for the full reasoning. Nothing
## here sends an RPC or reads/writes any replicated property.
##
## One shared cue for all three moments rather than three separate assets: `boss_stinger.ogg`
## (`tools/audio/render_music.py`'s `BOSS_STINGER`) is a ~7 s non-looping hit (impact in the first
## ~1.1 s, the rest its own reverb tail ringing out) built from the same palette NIGHT's ambience
## uses (D-066), and a `BossDef`/`BossPhaseDef` may override which id plays
## at engage/phase-change time via `engage_music_cue`/`music_cue` — anything not found in `CUE_PATHS`
## falls back to the shared cue rather than playing nothing, so an unauthored id is a missing polish
## pass, not a silent fight.

const EVENT_BUS := preload("res://core/events/event_bus.gd")

const CUE_PATHS: Dictionary[StringName, String] = {
	&"boss_stinger": "res://assets/audio/music/boss_stinger.ogg",
}
const DEFAULT_ENGAGE_CUE: StringName = &"boss_stinger"
const DEFAULT_PHASE_CUE: StringName = &"boss_stinger"
const DEFAULT_DEFEAT_CUE: StringName = &"boss_stinger"

const MUSIC_BUS: StringName = &"Music"

## Two players so a phase-change stinger arriving mid-engage-stinger does not cut the first one off —
## a boss dying to a hit that ALSO crosses a phase threshold in the same tick is exactly this case
## (`Boss._update_phase()` only ever advances one step, so this is rare but not impossible with a
## steep hit). Round-robin, same shape 7.1/7.2's SFX guidance already gives repeated one-shots.
const PLAYER_COUNT: int = 2

var _players: Array[AudioStreamPlayer] = []
var _next_player: int = 0
var _streams: Dictionary[StringName, AudioStream] = {}


func _ready() -> void:
	for i: int in PLAYER_COUNT:
		var player := AudioStreamPlayer.new()
		player.name = "Stinger%d" % i
		add_child(player)
		_players.append(player)

	EVENT_BUS.subscribe_boss_engaged(_on_boss_engaged)
	EVENT_BUS.subscribe_boss_phase_changed(_on_boss_phase_changed)
	EVENT_BUS.subscribe_boss_defeated(_on_boss_defeated)


func _exit_tree() -> void:
	EVENT_BUS.unsubscribe_boss_engaged(_on_boss_engaged)
	EVENT_BUS.unsubscribe_boss_phase_changed(_on_boss_phase_changed)
	EVENT_BUS.unsubscribe_boss_defeated(_on_boss_defeated)


func _on_boss_engaged(_boss_id: StringName, _world_position: Vector3) -> void:
	play_cue(DEFAULT_ENGAGE_CUE)


func _on_boss_phase_changed(
	_boss_id: StringName, _previous_phase: int, _new_phase: int, _world_position: Vector3
) -> void:
	play_cue(DEFAULT_PHASE_CUE)


func _on_boss_defeated(_boss_id: StringName, _world_position: Vector3) -> void:
	play_cue(DEFAULT_DEFEAT_CUE)


## Public so a future per-boss/per-phase cue id (`BossDef.engage_music_cue`, `BossPhaseDef.music_cue`)
## can be routed here directly once a real boss authors one — the three EventBus handlers above are
## deliberately the only callers today, each hard-coding the shared default, because nothing has
## authored a second cue yet (AGENTS.md: framework, not content). An id `CUE_PATHS` does not know
## falls back to `DEFAULT_ENGAGE_CUE` rather than staying silent.
func play_cue(cue_id: StringName) -> void:
	var stream: AudioStream = _stream_for(cue_id)
	if stream == null:
		return
	var player: AudioStreamPlayer = _players[_next_player]
	_next_player = (_next_player + 1) % _players.size()
	player.bus = _resolve_bus()
	player.stream = stream
	player.play()


func _stream_for(cue_id: StringName) -> AudioStream:
	var resolved_id: StringName = cue_id if CUE_PATHS.has(cue_id) else DEFAULT_ENGAGE_CUE
	if _streams.has(resolved_id):
		return _streams[resolved_id]
	var path: String = CUE_PATHS.get(resolved_id, "")
	if path.is_empty():
		return null
	var stream: AudioStream = load(path) as AudioStream
	_streams[resolved_id] = stream
	return stream


## Resolved fresh on every `play_cue()` call, never cached — `SettingsService` (task 7.5) creates the
## "Music" bus at runtime with no committed layout resource (its own doc comment explains why), so
## this autoload's own boot order relative to it is not guaranteed, and caching the answer at
## `_ready()` would freeze in whichever came first. Falling back to "Master" rather than failing to
## play at all keeps a stinger audible even in a harness or an old save that never ran 7.5's bus setup.
func _resolve_bus() -> StringName:
	return MUSIC_BUS if AudioServer.get_bus_index(MUSIC_BUS) >= 0 else &"Master"
