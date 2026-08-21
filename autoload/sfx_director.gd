extends Node

## SfxDirector — the one thing that plays MIRE's sound effects, and the consumer
## the 227 rendered files did not have.
##
## Before this, `assets/audio/sfx/` was referenced by exactly nothing outside
## `tools/audio_import_check.gd`: rendered, imported, loudness-checked,
## documented, and silent. That is F-373's failure repeated at a larger scale,
## and it is invisible — a game with no sound reports no error.
##
## ## Why the wiring lives HERE and not at each play site
##
## Almost every event worth a sound is already a signal on an autoload service
## (`CombatService.attack_landed`, `BuildService.piece_placed`,
## `PlayerHealth.player_downed`, `EventBus.cycle_advanced`, …), and most of them
## already carry a world position. So this file subscribes to them and needs to
## edit **no gameplay code at all**. That is not just convenience:
##
## 1. `docs/ARCHITECTURE.md` §2.2 puts audio in the "client-local presentation"
##    row. Keeping every play call in one client-local autoload makes that
##    structurally true rather than a convention each system has to remember.
## 2. Those signals are already replicated-event-driven, so every peer hears the
##    same sounds off its own local bus with no audio RPC — and there must never
##    be an audio RPC (docs/AUDIO.md "Network authority").
## 3. It does not fight other agents' file claims. Combat, building and the
##    player controller are all actively claimed most of the time; a design that
##    needed a line in each of them would be permanently blocked.
##
## ## Footsteps are driven, not signalled
##
## There is no footstep signal, and `entities/player/player_controller.gd` is
## claimed almost continuously (F-404/F-405 today). So steps are generated here
## from the local player's own motion: distance travelled while grounded, a step
## every `STEP_STRIDE_M`, with the surface chosen by a downward raycast. Games
## do it this way routinely, and it keeps audio out of the controller entirely —
## the controller has no idea this exists.
##
## ## Material mapping
##
## Which impact you hear is chosen from the def **id** of what was hit
## (`HARVEST_TOOL_CUE`, `TARGET_MATERIAL_CUE`), not from a scene or a map — MIRE's
## shipped worlds are procedurally generated, so anything keyed to a level is
## keyed to nothing. Sound fields on the defs themselves are the eventual right
## home; this table is the seam until `weapon_def`/`harvestable_def` grow them,
## and it is one file to move when they do.

const CATALOGUE := preload("res://autoload/sfx_catalogue.gd")
const EVENT_BUS := preload("res://core/events/event_bus.gd")
const BIOME_MAP := preload("res://world/gen/biome_map.gd")

const SFX_DIR := "res://assets/audio/sfx/"
## The bus `SettingsService._ensure_audio_buses()` creates at runtime and the SFX
## slider drives. Its own comment notes it had "nothing routed to it yet" — this
## is what routes to it.
const SFX_BUS: StringName = &"SFX"

## Positional voices for anything with a place in the world, flat voices for UI
## and for the player's own body. Both pools round-robin: a pool that big never
## needs to steal a voice in practice, and stealing is what makes a busy fight
## sound like it is dropping sounds.
const POOL_3D: int = 24
const POOL_FLAT: int = 10

## Every repeated cue is scattered in pitch. Without it, three round-robin
## variants still read as a loop after about ten hits.
const PITCH_SCATTER: float = 0.04

const DEFAULT_MAX_DISTANCE_M: float = 45.0
## Steps, UI and other constant-fire cues do not need to carry across a valley,
## and letting them would make a four-player camp unlistenable.
const CLOSE_MAX_DISTANCE_M: float = 22.0
const CLOSE_CUES: Array[StringName] = [
	&"footstep_mud", &"footstep_water", &"footstep_grass", &"footstep_stone",
	&"footstep_wood", &"jump", &"swim_stroke", &"inventory_move", &"item_pickup",
	&"leaf_rustle", &"insect_chirp", &"water_lap", &"creature_step",
	&"creature_step_heavy",
]

## Footstep driving.
const STEP_STRIDE_M: float = 2.1
const STEP_STRIDE_MIN_SPEED: float = 0.6
const SURFACE_RAY_M: float = 1.6

## A cue asked for twice inside this window plays once. Several services emit a
## confirmation AND a state-change signal for the same action, and a few fire per
## affected slot; without this, one pickup can play four times.
const DEDUPE_WINDOW_S: float = 0.045

var _streams: Dictionary[StringName, Array] = {}     # cue -> Array[AudioStream]
var _next_variant: Dictionary[StringName, int] = {}
var _last_played: Dictionary[StringName, float] = {}
var _players_3d: Array[AudioStreamPlayer3D] = []
var _players_flat: Array[AudioStreamPlayer] = []
var _next_3d: int = 0
var _next_flat: int = 0
var _clock: float = 0.0
## Per-cue play tally since boot. Costs one dictionary increment per sound and
## it is what turns "the wiring compiles" into "the wiring fires" — the runtime
## probe reads it, and it is the first thing to look at when a sound is missing
## in play.
var play_counts: Dictionary[StringName, int] = {}

var _step_accum: float = 0.0
var _last_player_pos: Vector3 = Vector3.ZERO
var _have_last_pos: bool = false


func _ready() -> void:
	# SFX must survive the pause menu no more than the world does, but the UI
	# cues fire WHILE paused — a menu that goes silent when opened is the bug
	# this avoids. Same call the two music directors make.
	process_mode = Node.PROCESS_MODE_ALWAYS
	for i: int in POOL_3D:
		var p3 := AudioStreamPlayer3D.new()
		p3.name = "Voice3D%d" % i
		p3.max_distance = DEFAULT_MAX_DISTANCE_M
		p3.unit_size = 6.0
		add_child(p3)
		_players_3d.append(p3)
	for i: int in POOL_FLAT:
		var pf := AudioStreamPlayer.new()
		pf.name = "VoiceFlat%d" % i
		add_child(pf)
		_players_flat.append(pf)
	_connect_events()
	set_process(true)


func _process(delta: float) -> void:
	_clock += delta
	_drive_footsteps(delta, _player_body(multiplayer.get_unique_id()))
	_tick_ambient()
	_tick_enemies()


# ── Playback ─────────────────────────────────────────────────────────────────


## Play a cue with no position — UI, and anything happening to the local player
## themselves, which should not attenuate with distance from their own body.
func play(cue: StringName) -> void:
	var stream: AudioStream = _take(cue)
	if stream == null:
		return
	var player: AudioStreamPlayer = _players_flat[_next_flat]
	_next_flat = (_next_flat + 1) % _players_flat.size()
	player.bus = _bus()
	player.stream = stream
	player.pitch_scale = _scatter()
	player.play()


## Play a cue at a world position.
func play_at(cue: StringName, position: Vector3) -> void:
	var stream: AudioStream = _take(cue)
	if stream == null:
		return
	var player: AudioStreamPlayer3D = _players_3d[_next_3d]
	_next_3d = (_next_3d + 1) % _players_3d.size()
	player.bus = _bus()
	player.stream = stream
	player.pitch_scale = _scatter()
	player.max_distance = CLOSE_MAX_DISTANCE_M if CLOSE_CUES.has(cue) else DEFAULT_MAX_DISTANCE_M
	player.global_position = position
	player.play()


## True while any voice is sounding. Used by checks, and available to anything
## that wants to duck against the effects bus later.
func is_playing() -> bool:
	for p3: AudioStreamPlayer3D in _players_3d:
		if p3.playing:
			return true
	for pf: AudioStreamPlayer in _players_flat:
		if pf.playing:
			return true
	return false


func has_cue(cue: StringName) -> bool:
	return CATALOGUE.CUES.has(cue)


## Round-robin one variant of a cue, loading it on first use.
##
## Lazily, not at boot: 227 files is ~49 MB of PCM, and loading all of it up
## front would cost every headless check and every launch several seconds for
## sounds most runs never trigger. Each cue is loaded once and then cached, so
## the cost is paid at most once per cue per process.
func _take(cue: StringName) -> AudioStream:
	if not CATALOGUE.CUES.has(cue):
		push_warning("[SfxDirector] unknown cue %s" % cue)
		return null
	var now: float = _clock
	var last: float = float(_last_played.get(cue, -999.0))
	if now - last < DEDUPE_WINDOW_S:
		return null
	_last_played[cue] = now
	play_counts[cue] = int(play_counts.get(cue, 0)) + 1

	if not _streams.has(cue):
		_streams[cue] = _load_variants(cue)
	var variants: Array = _streams[cue]
	if variants.is_empty():
		return null
	var index: int = int(_next_variant.get(cue, 0)) % variants.size()
	_next_variant[cue] = index + 1
	return variants[index] as AudioStream


func _load_variants(cue: StringName) -> Array:
	var count: int = int(CATALOGUE.CUES[cue][0])
	var out: Array = []
	if count <= 1:
		var single: AudioStream = load(SFX_DIR + String(cue) + ".wav") as AudioStream
		if single != null:
			out.append(single)
	else:
		for v: int in range(1, count + 1):
			var stream: AudioStream = load(SFX_DIR + "%s_%02d.wav" % [cue, v]) as AudioStream
			if stream != null:
				out.append(stream)
	if out.is_empty():
		push_warning("[SfxDirector] cue %s has no loadable files" % cue)
	return out


func _scatter() -> float:
	return 1.0 + randf_range(-PITCH_SCATTER, PITCH_SCATTER)


## Re-resolved per call rather than cached, exactly as the music directors do it:
## "SFX" is created at RUNTIME by SettingsService with no committed bus layout,
## so this autoload's boot order relative to it is not guaranteed. Falls back to
## Master rather than refusing to play, so a harness still makes noise.
func _bus() -> StringName:
	if AudioServer.get_bus_index(SFX_BUS) >= 0:
		return SFX_BUS
	return &"Master"


# ── Material mapping ─────────────────────────────────────────────────────────
#
# Keyed by def **id**, never by scene or level — MIRE's shipped worlds are
# procedurally generated, so anything bound to a level is bound to nothing.
# Unknown ids fall through to the defaults rather than going silent: a new
# harvestable is a missing polish pass, not a mute.

const HARVEST_HIT_CUE: Dictionary[StringName, StringName] = {
	&"tree": &"axe_hit_wood",
	&"wild_tree": &"axe_hit_wood",
	&"sapling": &"axe_hit_wood",
	&"bush": &"harvest_plant",
	&"nettle": &"harvest_plant",
	&"stump": &"axe_hit_wood_dead",
	&"fallen_log": &"axe_hit_wood_dead",
	&"boulder": &"pick_hit_stone",
	&"rock_cluster": &"pick_hit_stone",
	&"stone_node": &"pick_hit_stone",
	&"iron_node": &"pick_hit_ore",
	&"mire_crystal": &"pick_hit_crystal",
}
const HARVEST_BREAK_CUE: Dictionary[StringName, StringName] = {
	&"tree": &"tree_fall",
	&"wild_tree": &"tree_fall",
	&"sapling": &"sapling_break",
	&"bush": &"harvest_plant",
	&"nettle": &"harvest_plant",
	&"stump": &"log_break",
	&"fallen_log": &"log_break",
	&"boulder": &"stone_break",
	&"rock_cluster": &"stone_break",
	&"stone_node": &"stone_break",
	&"iron_node": &"ore_break",
	&"mire_crystal": &"stone_break",
}
const DEFAULT_HARVEST_HIT: StringName = &"axe_hit_wood"
const DEFAULT_HARVEST_BREAK: StringName = &"log_break"

## `attack_landed`/`shot_landed` carry the target's node name, which is the only
## material information available at the seam. Matched by substring so a
## generated instance name like "Enemy_crawler_7" still resolves.
const TARGET_MATERIAL_CUE: Array[Array] = [
	["crawler", &"hit_carapace"],
	["brood", &"hit_carapace"],
	["strider", &"hit_carapace"],
	["boss", &"hit_bone"],
	["tusker", &"hit_bone"],
	["player", &"hit_flesh"],
	["tree", &"hit_wood"],
	["log", &"hit_wood"],
	["stump", &"hit_wood"],
	["sapling", &"hit_wood"],
	["boulder", &"hit_stone"],
	["rock", &"hit_stone"],
	["stone", &"hit_stone"],
	["iron", &"hit_metal"],
	["ore", &"hit_metal"],
	# A built panel is not a plank: it is large, mounted at its edges, and the
	# whole structure moves. `structure_hit` models that and carries far more
	# low end, which is also what makes it audible from inside a base.
	["wall", &"structure_hit"],
	["palisade", &"structure_hit"],
	["gate", &"structure_hit"],
	["door", &"structure_hit"],
	["barricade", &"structure_hit"],
	["ramp", &"structure_hit"],
	["bridge", &"structure_hit"],
	["dock", &"structure_hit"],
	["ladder", &"structure_hit"],
	["ward", &"structure_hit"],
]
const DEFAULT_HIT_CUE: StringName = &"hit_flesh"

## Swing weight by weapon id. A skewer and a two-handed axe must not share an
## arc; this is the cheapest way to make nine weapons feel like nine weapons.
const WEAPON_SWING_CUE: Dictionary[StringName, StringName] = {
	&"skewer": &"swing_light",
	&"cleaver": &"swing_blade",
	&"iron_sword": &"swing_blade",
	&"stone_axe": &"swing_heavy",
	&"wooden_axe": &"swing_heavy",
	&"iron_pickaxe": &"swing_heavy",
	&"stone_pickaxe": &"swing_heavy",
	&"wooden_pickaxe": &"swing_heavy",
	&"repair_hammer": &"swing_heavy",
}
const DEFAULT_SWING_CUE: StringName = &"swing_blade"

const RANGED_DRAW_CUE: Dictionary[StringName, StringName] = {
	&"short_bow": &"bow_draw",
	&"longbow": &"bow_draw",
	&"crossbow": &"crossbow_load",
	&"sling": &"sling_whirl",
}
const RANGED_RELEASE_CUE: Dictionary[StringName, StringName] = {
	&"short_bow": &"bow_release",
	&"longbow": &"bow_release",
	&"crossbow": &"crossbow_release",
	&"sling": &"bow_release",
}

## Buildables made of stone get the stone placement; everything else is timber.
const STONE_BUILDABLES: Array[StringName] = [&"wall", &"ramp", &"dock", &"ward", &"ward_post"]

const ENEMY_GROUP: StringName = &"enemies"


func _cue_for_target(target_name: StringName) -> StringName:
	var lowered: String = String(target_name).to_lower()
	for row: Array in TARGET_MATERIAL_CUE:
		if lowered.contains(String(row[0])):
			return row[1]
	return DEFAULT_HIT_CUE


# ── Event wiring ─────────────────────────────────────────────────────────────


func _connect_events() -> void:
	EVENT_BUS.subscribe_harvest_yielded(_on_harvest_yielded)
	EVENT_BUS.subscribe_enemy_attack_landed(_on_enemy_attack_landed)
	EVENT_BUS.subscribe_cycle_advanced(_on_cycle_advanced)
	EVENT_BUS.subscribe_wellspring_capped(_on_wellspring_capped)
	EVENT_BUS.subscribe_wellspring_recorrupted(_on_wellspring_recorrupted)
	EVENT_BUS.subscribe_boss_engaged(_on_boss_engaged)
	EVENT_BUS.subscribe_salvage_banked(_on_salvage_banked)
	EVENT_BUS.subscribe_unlock_purchased(_on_unlock_purchased)
	EVENT_BUS.subscribe_ship_repaired(_on_ship_repaired)
	EVENT_BUS.subscribe_run_extracted(_on_run_extracted)
	EVENT_BUS.subscribe_run_restarted(_on_run_restarted)

	for row: Array in BINDINGS:
		_bind(NodePath(row[0]), row[1], Callable(self, row[2]))

	# Per-instance signals: harvestables, chests, doors and enemies are spawned
	# and freed constantly, so they are picked up as they enter the tree rather
	# than resolved once. Same shape `HarvestWorld._on_node_added` uses.
	var tree: SceneTree = get_tree()
	# The whole UI, wired without touching a single UI file: focus movement is
	# the hover, and every BaseButton in the project reports its own press. A
	# design that needed a line per screen would be out of date by the next
	# screen anyone adds.
	var viewport: Viewport = get_viewport()
	if viewport != null and not viewport.gui_focus_changed.is_connected(_on_gui_focus_changed):
		viewport.gui_focus_changed.connect(_on_gui_focus_changed)

	if tree != null and not tree.node_added.is_connected(_on_node_added):
		tree.node_added.connect(_on_node_added)
		for row: Array in INSTANCE_BINDINGS:
			for node: Node in tree.get_nodes_in_group(row[0]):
				_on_node_added(node)


## Every autoload signal this director listens to, as data: [autoload path,
## signal, handler method].
##
## A table rather than a run of `_bind()` calls so `tools/sfx_check.gd` can walk
## it and assert each handler's argument count matches the signal's. That check
## exists because the mistake is silent and I made it twice: `landed` carries an
## impact speed and `piece_destroyed` is `(def_id, owner, name, position)` — not
## the `(piece, def_id, position, peer)` shape it looks like it should be — and a
## handler with the wrong arity does not fail until the signal fires in a real
## run, which for `piece_destroyed` might be an hour in.
const BINDINGS: Array[Array] = [
	["/root/CombatService", &"swing_started", "_on_swing_started"],
	["/root/CombatService", &"attack_landed", "_on_attack_landed"],
	["/root/RangedCombatService", &"shot_started", "_on_shot_started"],
	["/root/RangedCombatService", &"shot_landed", "_on_shot_landed"],
	["/root/RangedCombatService", &"shot_missed", "_on_shot_missed"],
	["/root/BuildService", &"piece_placed", "_on_piece_placed"],
	["/root/BuildService", &"build_confirmed", "_on_build_confirmed"],
	["/root/BuildService", &"piece_destroyed", "_on_piece_destroyed"],
	["/root/CraftingService", &"craft_confirmed", "_on_craft_confirmed"],
	["/root/PlayerHealth", &"player_downed", "_on_player_downed"],
	["/root/PlayerHealth", &"revive_confirmed", "_on_revive_confirmed"],
	["/root/PlayerHealth", &"consume_confirmed", "_on_consume_confirmed"],
	["/root/PlayerHealth", &"local_health_changed", "_on_local_health_changed"],
	["/root/PlayerHealth", &"local_stamina_changed", "_on_local_stamina_changed"],
	["/root/EnemyWorld", &"enemy_spawned", "_on_enemy_spawned"],
	["/root/EnemyWorld", &"enemy_died", "_on_enemy_died"],
	["/root/PowerupService", &"resonance_changed", "_on_resonance_changed"],
	["/root/AttunementService", &"selection_confirmed", "_on_attunement_confirmed"],
	["/root/InventoryService", &"operation_confirmed", "_on_inventory_operation"],
	["/root/PlayerNet", &"player_spawned", "_on_player_spawned"],
	["/root/NetTransport", &"peer_joined", "_on_peer_joined"],
	["/root/NetTransport", &"peer_left", "_on_peer_left"],
	["/root/MenuStack", &"screen_pushed", "_on_screen_pushed"],
	["/root/MenuStack", &"screen_popped", "_on_screen_popped"],
]

## Per-instance signals, connected as nodes enter the tree: [group, signal, handler].
## The handler is called with the signal's own arguments plus the node, via `bind()`.
const INSTANCE_BINDINGS: Array[Array] = [
	[&"harvestable", &"depleted", "_on_harvestable_depleted"],
	[&"chest", &"open_confirmed", "_on_chest_opened"],
	[&"door", &"toggled", "_on_door_toggled"],
	[&"haulable", &"carriers_changed", "_on_carriers_changed"],
]


## Connect one signal on an autoload that may not exist in this process (a
## headless harness registers only what it needs). Guarded on both existence and
## `is_connected` so a re-entry cannot stack a second connection.
func _bind(path: NodePath, signal_name: StringName, handler: Callable) -> void:
	var node: Node = get_node_or_null(path)
	if node == null or not node.has_signal(signal_name):
		return
	if not node.is_connected(signal_name, handler):
		node.connect(signal_name, handler)


func _on_node_added(node: Node) -> void:
	var button := node as BaseButton
	if button != null:
		var handler: Callable = _on_button_pressed.bind(button)
		if not button.pressed.is_connected(handler):
			button.pressed.connect(handler)
		return
	_try_attach_station_loop(node)
	for row: Array in INSTANCE_BINDINGS:
		if not node.is_in_group(row[0]) or not node.has_signal(row[1]):
			continue
		# Bound to the node so the handler knows WHICH one fired — none of these
		# signals carries a reference to its own emitter.
		var handler: Callable = Callable(self, row[2]).bind(node)
		if not node.is_connected(row[1], handler):
			node.connect(row[1], handler)


func _world_position_of(node: Node) -> Vector3:
	var spatial := node as Node3D
	return spatial.global_position if spatial != null and spatial.is_inside_tree() else Vector3.ZERO


func _def_id(node: Node) -> StringName:
	var definition: Variant = node.get(&"definition")
	if definition == null:
		return &""
	var id: Variant = (definition as Resource).get(&"id")
	return id if id is StringName else &""


# ── Handlers ─────────────────────────────────────────────────────────────────
#
# Every one of these is unconditional on network authority. That is correct and
# not an oversight: each signal it listens to is already dispatched identically
# on host and client (the replicated setters and EventBus re-emits do that work),
# so a peer plays its own sounds off its own local bus. Adding an authority
# guard here would make clients silent.


func _on_harvest_yielded(harvestable_id: StringName, _peer_id: int, _item_id: StringName,
		_amount: int, world_position: Vector3) -> void:
	var cue: StringName = HARVEST_HIT_CUE.get(harvestable_id, DEFAULT_HARVEST_HIT)
	play_at(cue, world_position)


func _on_harvestable_depleted(_peer_id: int, _item_id: StringName, _amount: int,
		node: Node) -> void:
	var cue: StringName = HARVEST_BREAK_CUE.get(_def_id(node), DEFAULT_HARVEST_BREAK)
	play_at(cue, _world_position_of(node))


## `attack_landed` carries no weapon, so the last thing to swing is remembered
## here. That is what lets an axe into a trunk sound like a chop rather than a
## generic knock, and the repair hammer sound like work rather than like combat.
var _last_swing_weapon: StringName = &""


func _on_swing_started(weapon_id: StringName) -> void:
	_last_swing_weapon = weapon_id
	play(WEAPON_SWING_CUE.get(weapon_id, DEFAULT_SWING_CUE))


func _on_attack_landed(_peer_id: int, position: Vector3, damage: int,
		target_name: StringName) -> void:
	var cue: StringName = _cue_for_target(target_name)
	# The repair hammer is not a weapon and must not sound like one, whatever it
	# lands on.
	if _last_swing_weapon == &"repair_hammer":
		play_at(&"repair_hit", position)
		return
	# An axe or a pick meeting wood or stone is a harvest stroke, not a combat
	# impact — same tool, same material, so it should be the same sound.
	if cue == &"hit_wood" and String(_last_swing_weapon).contains("axe"):
		cue = &"axe_hit_wood"
	elif cue == &"hit_stone" and String(_last_swing_weapon).contains("pick"):
		cue = &"pick_hit_stone"
	play_at(cue, position)
	# Anything alive answers the blow. Without this the world is full of
	# impacts that nothing reacts to, which is the single loudest tell that a
	# combat mix is synthetic.
	if cue == &"hit_carapace" or cue == &"hit_flesh":
		play_at(&"creature_hurt", position)
	# A hit well above the baseline reads as a crit. Threshold rather than a
	# flag because `attack_landed` carries no crit bit; when combat grows one,
	# this is the line that changes.
	if damage >= 12:
		play_at(&"hit_crit", position)


func _on_shot_started(weapon_id: StringName) -> void:
	play(RANGED_DRAW_CUE.get(weapon_id, &"bow_draw"))
	play(RANGED_RELEASE_CUE.get(weapon_id, &"bow_release"))


func _on_shot_landed(_peer_id: int, position: Vector3, _damage: int,
		target_name: StringName) -> void:
	var material_cue: StringName = _cue_for_target(target_name)
	var cue: StringName = &"arrow_hit_flesh"
	if material_cue == &"hit_wood":
		cue = &"arrow_hit_wood"
	elif material_cue == &"hit_stone" or material_cue == &"hit_metal":
		cue = &"arrow_hit_stone"
	play_at(&"arrow_whizz", position)
	play_at(cue, position)


func _on_shot_missed(_peer_id: int, position: Vector3) -> void:
	play_at(&"arrow_whizz", position)


func _on_piece_placed(piece: Node3D, def_id: StringName, _owner_peer_id: int) -> void:
	var cue: StringName = &"build_place_stone" if STONE_BUILDABLES.has(def_id) \
		else &"build_place_wood"
	play_at(cue, _world_position_of(piece))
	if WARD_BUILDABLES.has(def_id):
		play_at(&"ward_activate", _world_position_of(piece))


const WARD_BUILDABLES: Array[StringName] = [&"ward", &"ward_post"]


var _last_build_confirm: float = -999.0
## Set on run restart: `BuildService` frees every placed piece on teardown and
## emits `piece_destroyed` for each, which without this is a barrage of collapse
## sounds over the first second of a fresh run.
var _suppress_destroy_until: float = 0.0


func _on_build_confirmed(_request_id: int, accepted: bool, _reason: String) -> void:
	if not accepted:
		play(&"build_denied")
		return
	_last_build_confirm = _clock


## Crafting resolves instantly here, so the work and the result are one event.
## Playing both — the tool strokes, then the chime a beat later — is what makes
## it read as something being MADE rather than as a number changing.
func _on_craft_confirmed(_request_id: int, accepted: bool, _detail: String) -> void:
	if not accepted:
		play(&"craft_denied")
		return
	play(&"craft_work")
	_after(0.55, func() -> void: play(&"craft_complete"))


## Fire a callable after a delay, on this director's own always-processing tree.
## Used where one event is genuinely two sounds separated in time.
func _after(delay_s: float, action: Callable) -> void:
	var timer: SceneTreeTimer = get_tree().create_timer(delay_s, true, false, true)
	timer.timeout.connect(action, CONNECT_ONE_SHOT)


func _on_chest_opened(_request_id: int, accepted: bool, granted: Dictionary,
		_detail: String, node: Node) -> void:
	if not accepted:
		return
	var position: Vector3 = _world_position_of(node)
	play_at(&"chest_open", position)
	# A haul worth stopping for. `loot_rare` is the only overtly magical sound
	# in the set and it is spent here, matching the design call that a chest
	# should sometimes change a run outright.
	var total: int = 0
	for key: Variant in granted:
		total += int(granted[key])
	if total >= 12 or granted.size() >= 4:
		play_at(&"loot_rare", position)


## A haulable changing hands. Empty means it was set down, non-empty means it was
## picked up — the same signal covers both, which is why this reads the array
## rather than trusting a separate lift/drop pair that does not exist.
func _on_carriers_changed(carrier_ids: PackedInt32Array, node: Node) -> void:
	play_at(&"haul_lift" if carrier_ids.size() > 0 else &"haul_drop",
		_world_position_of(node))


## A gate is not a door — twice the mass and a bar rather than a latch — and a
## player should be able to tell which one a teammate just opened from across a
## camp. `BuildableDoor` carries no def reference, so the piece's own node name
## is the discriminator; `BuildService` names pieces after their def.
func _on_door_toggled(open: bool, _by_peer_id: int, node: Node) -> void:
	var is_gate: bool = node.name.to_lower().contains("gate")
	var cue: StringName
	if is_gate:
		cue = &"gate_open" if open else &"gate_close"
	else:
		cue = &"door_open" if open else &"door_close"
	play_at(cue, _world_position_of(node))


func _on_enemy_spawned(enemy: Node3D) -> void:
	play_at(&"enemy_spawn", _world_position_of(enemy))
	if enemy != null and enemy.has_signal(&"died") \
			and not enemy.is_connected(&"died", _on_enemy_instance_died):
		enemy.died.connect(_on_enemy_instance_died.bind(enemy))


func _on_enemy_instance_died(_instigator_peer_id: int, enemy: Node) -> void:
	var id: StringName = _def_id(enemy)
	var cue: StringName = &"tusker_snort" if id == &"tusker" else &"creature_death"
	play_at(cue, _world_position_of(enemy))


func _on_enemy_died(_enemy_id: StringName, _instigator_peer_id: int,
		position: Vector3) -> void:
	play_at(&"creature_death", position)


## An enemy connecting. The lunge is the creature's, the grunt is the player's,
## and they are two layers of one moment rather than one sound — which is why
## the impact goes to the world position and the grunt does not.
func _on_enemy_attack_landed(_enemy_id: StringName, peer_id: int, _damage: int,
		world_position: Vector3) -> void:
	play_at(&"creature_attack", world_position)
	if peer_id == multiplayer.get_unique_id():
		play(&"hit_flesh")


func _on_boss_engaged(_boss_id: StringName, world_position: Vector3) -> void:
	play_at(&"boss_roar", world_position)


func _on_cycle_advanced(cycle: int) -> void:
	if cycle > 1:
		play(&"cycle_advance")


func _on_wellspring_capped(_name: StringName, world_position: Vector3) -> void:
	play_at(&"wellspring_capture", world_position)


func _on_wellspring_recorrupted(_name: StringName, world_position: Vector3) -> void:
	play_at(&"wellspring_corrupt", world_position)


func _on_ship_repaired(_name: StringName, world_position: Vector3) -> void:
	play_at(&"extraction_arrive", world_position)


func _on_run_extracted(_cycle: int, world_position: Vector3) -> void:
	play_at(&"extraction_launch", world_position)


func _on_salvage_banked(_earned: int, _total: int, _cycle: int, _extracted: bool) -> void:
	play(&"salvage_bank")


func _on_unlock_purchased(_unlock_id: StringName, _cost: int, _total: int) -> void:
	play(&"unlock_purchase")


func _on_resonance_changed(peer_id: int, _family: StringName, tier: int) -> void:
	if peer_id != multiplayer.get_unique_id():
		return
	# Tiers only ever climb during a run, so a drop means a cost was paid —
	# `powerup_curse` is the same crystal figure inverted, which is how a player
	# learns the difference without being told.
	play(&"powerup_pickup" if tier > 0 else &"powerup_curse")


func _on_attunement_confirmed(accepted: bool, _attunement_id: StringName,
		_detail: String) -> void:
	play(&"attune_select" if accepted else &"ui_deny")


func _on_inventory_operation(_request_id: int, accepted: bool, detail: String) -> void:
	if not accepted:
		play(&"ui_deny")
		return
	var lowered: String = detail.to_lower()
	if lowered.contains("drop"):
		play(&"item_drop")
	elif lowered.contains("move") or lowered.contains("swap") or lowered.contains("split"):
		play(&"inventory_move")
	else:
		play(&"item_pickup")


func _on_consume_confirmed(_request_id: int, accepted: bool, detail: String) -> void:
	if not accepted:
		play(&"ui_deny")
		return
	play(&"player_drink" if detail.to_lower().contains("drink") else &"player_eat")
	play(&"player_heal")


func _on_player_downed(peer_id: int) -> void:
	if peer_id == multiplayer.get_unique_id():
		play(&"player_downed")
	else:
		var body: Node3D = _player_body(peer_id)
		play_at(&"player_downed", _world_position_of(body) if body != null else Vector3.ZERO)


func _on_revive_confirmed(_request_id: int, accepted: bool, _detail: String) -> void:
	if accepted:
		play(&"player_revive")


var _last_hp: int = -1
var _low_breath_at: float = -999.0
const LOW_BREATH_INTERVAL_S: float = 6.0


func _on_local_health_changed(hp: int, max_hp: int, state: int,
		_bleed_out_remaining: float) -> void:
	if _last_hp >= 0 and hp < _last_hp:
		play(&"player_hurt" if hp > 0 else &"player_death")
	_last_hp = hp
	# The ragged breath is a heartbeat, not an event: it repeats on a timer
	# while the player is under a quarter health rather than firing once, which
	# is what makes it read as a condition rather than as a hit.
	if state == 0 and max_hp > 0 and hp > 0 and float(hp) / float(max_hp) <= 0.25 \
			and _clock - _low_breath_at > LOW_BREATH_INTERVAL_S:
		_low_breath_at = _clock
		play(&"player_breath_low")


var _stamina_was_empty: bool = false


func _on_local_stamina_changed(stamina: float, max_stamina: float) -> void:
	var empty: bool = max_stamina > 0.0 and stamina <= max_stamina * 0.02
	if empty and not _stamina_was_empty:
		play(&"stamina_empty")
	_stamina_was_empty = empty


func _on_player_spawned(peer_id: int, body: Node3D) -> void:
	if peer_id != multiplayer.get_unique_id() or body == null:
		return
	_have_last_pos = false
	_step_accum = 0.0
	if body.has_signal(&"jumped") and not body.is_connected(&"jumped", _on_jumped):
		body.jumped.connect(_on_jumped)
	if body.has_signal(&"landed") and not body.is_connected(&"landed", _on_landed):
		body.landed.connect(_on_landed)
	if body.has_signal(&"dodged") and not body.is_connected(&"dodged", _on_dodged):
		body.dodged.connect(_on_dodged)


func _on_dodged() -> void:
	play(&"dodge_roll")


func _on_jumped() -> void:
	play(&"jump")


## `landed` carries the downward speed at impact, and it is the whole reason
## there is one landing sound rather than two: a gentle arrival is a footstep,
## and only a real drop earns the heavy landing. A threshold on data the signal
## already provides beats authoring a `land_soft` nobody would tune.
func _on_landed(impact_speed: float) -> void:
	if impact_speed < HARD_LANDING_SPEED:
		play(&"footstep_mud")
		return
	play(&"land_hard")


const HARD_LANDING_SPEED: float = 6.0


func _on_peer_joined(_peer_id: int) -> void:
	play(&"peer_joined")


func _on_peer_left(_peer_id: int) -> void:
	play(&"peer_left")


var _last_screen_change: float = -999.0


func _on_screen_pushed(_screen: Control) -> void:
	_last_screen_change = _clock
	play(&"ui_open")


func _on_screen_popped(_screen: Control) -> void:
	_last_screen_change = _clock
	play(&"ui_close")


## A player tearing a piece down and an enemy breaking it are the same signal.
## They are told apart by whether a build request was just answered: only
## `BuildService._process_destroy()` routes through `_answer()`, so a
## `build_confirmed` in the last few frames means a person did this on purpose.
func _on_piece_destroyed(_def_id: StringName, _owner_peer_id: int,
		_piece_name: StringName, position: Vector3) -> void:
	if _clock < _suppress_destroy_until:
		return
	if _clock - _last_build_confirm < 0.15:
		play_at(&"build_remove", position)
		return
	play_at(&"structure_destroy", position)


## Focus moving IS the hover, for keyboard, gamepad and mouse alike — which is
## why this is hooked to focus rather than to mouse-enter. Suppressed on the
## first focus after a screen appears: a panel that opens onto a focused button
## would otherwise play its open sound and a hover in the same frame.
func _on_gui_focus_changed(control: Control) -> void:
	if control == null:
		return
	if _clock - _last_screen_change < 0.2:
		return
	play(&"ui_hover")


## Buttons that mean accept, cancel or change-page get their own sound, read off
## the button's own text and node name. A heuristic, but the alternative is a
## line of audio code in every screen — and the words themselves are the most
## stable thing about a button.
const UI_CONFIRM_WORDS: Array[String] = ["confirm", "accept", "ok", "yes", "start",
	"play", "apply", "buy", "purchase", "craft", "sail", "launch"]
const UI_BACK_WORDS: Array[String] = ["back", "cancel", "close", "no", "return", "quit"]
const UI_TAB_WORDS: Array[String] = ["tab", "next", "prev", "page"]


func _on_button_pressed(button: BaseButton) -> void:
	var words: String = button.name.to_lower()
	var labelled := button as Button
	if labelled != null:
		words += " " + labelled.text.to_lower()
	for word: String in UI_BACK_WORDS:
		if words.contains(word):
			play(&"ui_back")
			return
	for word: String in UI_CONFIRM_WORDS:
		if words.contains(word):
			play(&"ui_confirm")
			return
	for word: String in UI_TAB_WORDS:
		if words.contains(word):
			play(&"ui_tab")
			return
	play(&"ui_click")


func _on_run_restarted() -> void:
	_suppress_destroy_until = _clock + 1.5
	_enemy_states.clear()
	_enemy_positions.clear()
	_enemy_step_accum.clear()
	_last_hp = -1
	_stamina_was_empty = false
	_have_last_pos = false
	_step_accum = 0.0
	_last_played.clear()


# ── Footsteps ────────────────────────────────────────────────────────────────
#
# Driven from the local player's motion rather than from a signal the controller
# does not have, and deliberately so — see the header. Distance-based rather
# than time-based: a stride is a distance, so this stays correct when movement
# speed changes (sprinting, the `loping_gait`/`thin_step` powerups, deep mire
# slowing the player) without any of those systems knowing audio exists.


func _player_body(peer_id: int) -> Node3D:
	var net: Node = get_node_or_null(^"/root/PlayerNet")
	if net == null or not net.has_method(&"player_for"):
		return null
	return net.player_for(peer_id) as Node3D


## The body is a parameter rather than looked up inside, so a check can drive
## this with a synthetic node. That matters more than it looks: a headless boot
## never streams terrain collision (the runtime probe measured the player falling
## to y = -64 with `is_on_floor()` false forever), so an end-to-end run cannot
## prove the stride logic, and without this seam nothing could.
func _drive_footsteps(delta: float, body: Node3D) -> void:
	if body == null or not body.is_inside_tree():
		_have_last_pos = false
		return
	var pos: Vector3 = body.global_position
	if not _have_last_pos:
		_last_player_pos = pos
		_have_last_pos = true
		return

	var moved: Vector3 = pos - _last_player_pos
	_last_player_pos = pos
	# Horizontal only: falling is not walking, and a lift or a ramp would
	# otherwise generate steps from vertical travel alone.
	var flat: float = Vector2(moved.x, moved.z).length()
	if delta <= 0.0 or flat / delta < STEP_STRIDE_MIN_SPEED:
		return
	var grounded: Variant = body.get(&"is_on_floor_cached")
	if grounded is bool and not bool(grounded):
		_step_accum = 0.0
		return
	if body.has_method(&"is_on_floor") and not body.call(&"is_on_floor"):
		_step_accum = 0.0
		return

	_step_accum += flat
	if _step_accum < STEP_STRIDE_M:
		return
	_step_accum = 0.0
	# Below the water line the player is swimming, not walking. Checked on the
	# BODY's own height rather than on the surface under it, because in open
	# water the surface may be several metres down or absent entirely.
	if pos.y <= WATER_LEVEL_M - 0.25:
		play_at(&"swim_stroke", pos)
		return
	_check_water_entry(pos)
	play_at(_surface_cue(body), pos)


## Which ground the player is standing on, by raycast. Read from the collider's
## groups and node name rather than from a surface-material system, because
## there is not one yet — when there is, this is the single function that
## changes, and nothing that calls it needs to know.
func _surface_cue(body: Node3D) -> StringName:
	var world: World3D = body.get_world_3d()
	if world == null:
		return &"footstep_mud"
	var from: Vector3 = body.global_position + Vector3.UP * 0.2
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * SURFACE_RAY_M)
	query.exclude = [body.get_rid()] if body is CollisionObject3D else []
	var hit: Dictionary = world.direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return &"footstep_mud"

	var collider: Node = hit.get("collider") as Node
	if collider != null:
		var name_lower: String = collider.name.to_lower()
		if collider.is_in_group(&"buildable") or name_lower.contains("dock") \
				or name_lower.contains("bridge") or name_lower.contains("plank") \
				or name_lower.contains("wall") or name_lower.contains("ramp"):
			return &"footstep_wood"
		if name_lower.contains("rock") or name_lower.contains("stone") \
				or name_lower.contains("boulder"):
			return &"footstep_stone"

	# No surface system, so the water table decides: MireGrid owns where the
	# standing water is, and below it a step is a splash. Height is the honest
	# proxy for "is this shore, bog, or dry heath" on an island whose terrain is
	# generated from one heightmap.
	var height: float = float(hit.get("position", Vector3.ZERO).y)
	if height <= WATER_LEVEL_M:
		return &"footstep_water"
	if height <= MIRE_LEVEL_M:
		return &"footstep_mud"
	return &"footstep_grass"


var _was_in_water: bool = false


## The moment the player breaks the surface, once — not every frame they are wet.
## Checked in the step driver rather than on its own timer because it needs the
## same position sample and the same "is there a local body" guard.
func _check_water_entry(pos: Vector3) -> void:
	var wet: bool = pos.y <= WATER_LEVEL_M
	if wet and not _was_in_water:
		play_at(&"water_enter", pos)
	_was_in_water = wet


## Rough bands rather than a lookup into world gen: this file must not depend on
## the generator's internals, and being one metre out picks a neighbouring
## surface rather than producing a wrong one.
const WATER_LEVEL_M: float = 0.35
const MIRE_LEVEL_M: float = 2.6


# ── Ambient life ─────────────────────────────────────────────────────────────
#
# The world making noise on its own, scattered around the player at random
# intervals. This is what stops a forest sounding like a wind machine: the
# looping beds (`render_music.py`'s ambient tracks) give the room tone, and
# these give it inhabitants.
#
# Day and night draw from different pools, off the same replicated clock the
# ambient music director reads — birds and insects by day, frogs and something
# further off after dark. Positions are random around the player rather than
# tied to spawn points, because MIRE's worlds are generated and there is nothing
# authored to tie them to.

## The default pools, used wherever the biome is unknown and as the base every
## biome adds to. Duplicated entries are weights: `bird_call` twice is twice as
## likely as `marsh_gas`, which is a weighting scheme that needs no extra code.
const AMBIENT_DAY_CUES: Array[StringName] = [
	&"bird_call", &"bird_call", &"insect_chirp", &"leaf_rustle",
	&"branch_creak", &"wind_gust", &"water_lap", &"marsh_gas",
]
const AMBIENT_NIGHT_CUES: Array[StringName] = [
	&"night_bird", &"frog_croak", &"frog_croak", &"insect_chirp",
	&"marsh_gas", &"distant_call", &"branch_creak", &"wind_gust", &"water_lap",
]

## Per-biome pools — task 7.1's "ambience per biome", at the resolution that
## actually matters. Seven places should not sound alike, and the cheapest way to
## make them differ is not a different bed but a different *cast*: gulls and
## lapping water on the shore, frogs and gas in the marsh, a woodpecker in deep
## forest, crows and thin wind on the heath, scree on the highland.
##
## Keyed on biome id, which `BiomeMap.biome_at()` returns for any world position,
## so this works on a generated island with nothing authored.
const BIOME_DAY_CUES: Dictionary[StringName, Array] = {
	&"shore": [&"gull_call", &"gull_call", &"water_lap", &"water_lap", &"wind_gust",
		&"dry_grass"],
	&"marsh": [&"frog_croak", &"marsh_gas", &"marsh_gas", &"reed_rustle",
		&"reed_rustle", &"insect_chirp", &"water_lap", &"bird_call"],
	&"forest": [&"bird_call", &"bird_call", &"woodpecker", &"leaf_rustle",
		&"leaf_rustle", &"branch_creak", &"insect_chirp"],
	&"birchwood": [&"bird_call", &"woodpecker", &"woodpecker", &"leaf_rustle",
		&"branch_creak", &"wind_gust"],
	&"grassland": [&"dry_grass", &"dry_grass", &"insect_chirp", &"insect_chirp",
		&"bird_call", &"wind_gust"],
	&"heath": [&"crow_call", &"dry_grass", &"dry_grass", &"wind_high",
		&"insect_chirp", &"stone_settle"],
	&"highland": [&"wind_high", &"wind_high", &"crow_call", &"stone_settle",
		&"stone_settle", &"distant_call"],
}
const BIOME_NIGHT_CUES: Dictionary[StringName, Array] = {
	&"shore": [&"water_lap", &"water_lap", &"wind_gust", &"night_bird", &"distant_call"],
	&"marsh": [&"frog_croak", &"frog_croak", &"frog_croak", &"marsh_gas", &"marsh_gas",
		&"reed_rustle", &"insect_chirp", &"distant_call"],
	&"forest": [&"night_bird", &"night_bird", &"branch_creak", &"leaf_rustle",
		&"insect_chirp", &"distant_call"],
	&"birchwood": [&"night_bird", &"branch_creak", &"leaf_rustle", &"wind_gust",
		&"distant_call"],
	&"grassland": [&"insect_chirp", &"insect_chirp", &"dry_grass", &"night_bird",
		&"wind_gust"],
	&"heath": [&"wind_high", &"dry_grass", &"distant_call", &"crow_call", &"night_bird"],
	&"highland": [&"wind_high", &"wind_high", &"stone_settle", &"distant_call",
		&"distant_call"],
}
## Gaps, in seconds. Long enough that the world is mostly quiet — an ambient
## event every two seconds reads as a soundboard, not as a place.
const AMBIENT_GAP_MIN_S: float = 5.0
const AMBIENT_GAP_MAX_S: float = 16.0
## Placed beyond arm's reach and inside earshot: close enough to feel like it is
## happening near you, far enough that it never reads as coming from your own body.
const AMBIENT_NEAR_M: float = 7.0
const AMBIENT_FAR_M: float = 26.0

## Matches `AmbientMusicDirector`'s fallbacks, and for the same reason: read off
## DayNight's own exports when it is reachable so retuning dusk retunes the sky,
## the soundtrack and the wildlife together.
const FALLBACK_NIGHT_AT: float = 0.75
const FALLBACK_DAY_AT: float = 0.25

var _next_ambient_at: float = 4.0
var _day_night_node: Node


func _tick_ambient() -> void:
	if _clock < _next_ambient_at:
		return
	_next_ambient_at = _clock + randf_range(AMBIENT_GAP_MIN_S, AMBIENT_GAP_MAX_S)
	# Nothing in the world to place a sound relative to — a front end, or a
	# harness with no player. Silence is correct here, not a fallback position.
	var body: Node3D = _player_body(multiplayer.get_unique_id())
	if body == null or not body.is_inside_tree():
		return
	var pool: Array = _ambient_pool(body.global_position)
	var cue: StringName = pool[randi() % pool.size()]
	var angle: float = randf() * TAU
	var distance: float = randf_range(AMBIENT_NEAR_M, AMBIENT_FAR_M)
	var offset := Vector3(cos(angle) * distance, randf_range(-1.0, 4.0), sin(angle) * distance)
	play_at(cue, body.global_position + offset)


## Which cast of sounds this place has, by biome and time of day.
##
## The biome is resolved at most every `BIOME_REFRESH_S` rather than per event:
## `BiomeMap.biome_at()` samples noise, and the answer cannot change meaningfully
## in the time it takes to walk a few metres. Falls back to the generic pools
## whenever the generator is not reachable — a harness, the front end, or a level
## that was authored rather than generated — because being wrong about the biome
## is worse than being generic about it.
const BIOME_REFRESH_S: float = 4.0

var _biome: StringName = &""
var _biome_checked_at: float = -999.0


func _ambient_pool(position: Vector3) -> Array:
	var night: bool = _clock_is_night()
	var biome: StringName = _biome_at(position)
	var table: Dictionary = BIOME_NIGHT_CUES if night else BIOME_DAY_CUES
	if biome != &"" and table.has(biome):
		return table[biome]
	return AMBIENT_NIGHT_CUES if night else AMBIENT_DAY_CUES


func _biome_at(position: Vector3) -> StringName:
	if _clock - _biome_checked_at < BIOME_REFRESH_S:
		return _biome
	_biome_checked_at = _clock
	_biome = &""
	var state: Node = get_node_or_null(^"/root/GameState")
	var registry: Node = get_node_or_null(^"/root/Registry")
	if state == null or registry == null:
		return _biome
	var seed_value: Variant = state.get(&"run_seed")
	var biomes: Variant = registry.get(&"biomes")
	if typeof(seed_value) != TYPE_INT or not (biomes is Dictionary) \
			or (biomes as Dictionary).is_empty():
		return _biome
	var defs: Array = (biomes as Dictionary).values()
	_biome = BIOME_MAP.biome_at(position.x, position.z, int(seed_value), defs)
	return _biome


## Re-derived from `time_of_day` every call rather than taken off DayNight's
## signals: those are HOST ONLY (`_advance_client()` never calls
## `_check_thresholds()`), so a connected client would never hear a night pool.
## Same trap, and the same solution, as `AmbientMusicDirector._clock_is_night()`.
func _clock_is_night() -> bool:
	if _day_night_node == null or not is_instance_valid(_day_night_node):
		_day_night_node = get_node_or_null(^"/root/DayNight")
	if _day_night_node == null:
		return false
	var fraction: float = _clock_float(&"time_of_day", 0.348)
	var night_at: float = _clock_float(&"night_started_at", FALLBACK_NIGHT_AT)
	var day_at: float = _clock_float(&"day_started_at", FALLBACK_DAY_AT)
	return fraction >= night_at or fraction < day_at


func _clock_float(property: StringName, fallback: float) -> float:
	var raw: Variant = _day_night_node.get(property)
	if typeof(raw) == TYPE_FLOAT or typeof(raw) == TYPE_INT:
		return float(raw)
	return fallback


# ── Station loops ────────────────────────────────────────────────────────────


## The two continuous sound sources in the world. Attached to the node itself
## rather than played as one-shots — a
## crackle that restarts every few seconds is unmistakably a loop, and a player
## standing at a workbench for a minute will hear it restart twenty times.
##
## Keyed on the asset's own name, not on a scene or a level, because release
## worlds are generated (the same rule the animation/VFX binding follows). The
## furnace has no lit/unlit state yet; when it grows one, this is where it
## hooks, and until then a furnace in a camp is a working furnace.
const STATION_LOOP_CUES: Dictionary[String, StringName] = {
	"furnace": &"furnace_loop",
	"wellspring": &"wellspring_loop",
}
const STATION_LOOP_DISTANCE_M: float = 16.0

var _station_loops: Dictionary[int, AudioStreamPlayer3D] = {}


func _try_attach_station_loop(node: Node) -> void:
	var spatial := node as Node3D
	if spatial == null or _station_loops.has(spatial.get_instance_id()):
		return
	var lowered: String = spatial.name.to_lower()
	for key: String in STATION_LOOP_CUES:
		if not lowered.contains(key):
			continue
		var stream: AudioStream = load(SFX_DIR + String(STATION_LOOP_CUES[key]) + ".wav")
		var wav := stream as AudioStreamWAV
		if wav == null:
			return
		# Looped in code rather than through the `.import` sidecar: sidecars are
		# gitignored, so a fresh clone would re-import this one-shot and the
		# furnace would tick once and go quiet with nothing logged.
		wav = wav.duplicate() as AudioStreamWAV
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = wav.data.size() / 2   # 16-bit mono: two bytes per frame
		var player := AudioStreamPlayer3D.new()
		player.name = "StationLoop"
		player.stream = wav
		player.bus = _bus()
		player.max_distance = STATION_LOOP_DISTANCE_M
		player.unit_size = 3.0
		spatial.add_child(player)
		player.play()
		_station_loops[spatial.get_instance_id()] = player
		# A furnace has no lit/unlit state yet, so the moment it enters the world
		# IS its ignition. A wellspring simply runs and needs no such moment.
		if key == "furnace":
			play_at(&"furnace_light", spatial.global_position if spatial.is_inside_tree()
				else Vector3.ZERO)
		return


# ── Creature voices ──────────────────────────────────────────────────────────
#
# `Enemy.state` is a replicated property with a setter, not a signal, so there
# is nothing to subscribe to — and `systems/enemies/enemy.gd` is not this task's
# to edit. So the enemies group is polled a few times a second for transitions.
# That is cheap (a handful of nodes, one integer compare each) and it keeps the
# enemy script unaware that audio exists, which is the same trade the footstep
# driver makes and for the same reason.
#
# The two transitions worth hearing are the ones that change what the player
# should do: noticing them, and winding up to strike. Everything else is
# already covered by the impact and death sounds.

## Mirrors `Enemy.State`. Duplicated rather than preloaded because preloading the
## enemy script from an autoload pulls its whole dependency tree into every
## headless check; the values are an append-only enum and a drift would show up
## as a missing alert rather than as a wrong sound.
const ENEMY_STATE_IDLE: int = 0
const ENEMY_STATE_CHASE: int = 1
const ENEMY_STATE_TELL: int = 2

const ENEMY_POLL_INTERVAL_S: float = 0.2
## Idle vocals are rarer than ambient life — a creature that mutters every few
## seconds stops being a threat and becomes scenery.
const ENEMY_VOCAL_GAP_MIN_S: float = 9.0
const ENEMY_VOCAL_GAP_MAX_S: float = 24.0
const ENEMY_VOCAL_RANGE_M: float = 32.0

## Which voice a species uses when it is simply present.
const ENEMY_IDLE_CUES: Dictionary[StringName, StringName] = {
	&"tusker": &"tusker_snort",
	&"broodcaller": &"broodcaller_call",
}
const DEFAULT_IDLE_VOCAL: StringName = &"creature_chitter"

## Creature footsteps, driven exactly like the player's: distance travelled, not
## a timer, so something closing on you sounds like it is closing on you. This is
## arguably the most useful sound in a co-op survival game — hearing a thing
## arrive before seeing it is what makes a swamp dangerous rather than dark.
const CREATURE_STRIDE_M: float = 1.5
const CREATURE_STEP_RANGE_M: float = 26.0
## A single poll can never advance more than this. A spawn, a teleport or a
## replication snap would otherwise dump a dozen steps in one frame.
const CREATURE_STEP_MAX_JUMP_M: float = 3.0
## Species with real mass get the heavy pad instead of the skitter.
const HEAVY_STEP_SPECIES: Array[StringName] = [&"tusker", &"broodcaller"]

var _enemy_states: Dictionary[int, int] = {}
var _enemy_positions: Dictionary[int, Vector3] = {}
var _enemy_step_accum: Dictionary[int, float] = {}
var _next_enemy_poll: float = 0.0
var _next_enemy_vocal: float = 6.0


func _tick_enemies() -> void:
	if _clock < _next_enemy_poll:
		return
	_next_enemy_poll = _clock + ENEMY_POLL_INTERVAL_S
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	var enemies: Array[Node] = tree.get_nodes_in_group(ENEMY_GROUP)
	var idle_candidates: Array[Node3D] = []
	var seen: Dictionary[int, bool] = {}

	for node: Node in enemies:
		var spatial := node as Node3D
		if spatial == null or not spatial.is_inside_tree():
			continue
		var id: int = spatial.get_instance_id()
		seen[id] = true
		var raw: Variant = spatial.get(&"state")
		if typeof(raw) != TYPE_INT:
			continue
		var state: int = int(raw)
		if state == ENEMY_STATE_IDLE:
			idle_candidates.append(spatial)
		_drive_creature_step(spatial, id, state)
		var previous: int = int(_enemy_states.get(id, -1))
		_enemy_states[id] = state
		if previous < 0 or previous == state:
			continue
		if state == ENEMY_STATE_CHASE and previous == ENEMY_STATE_IDLE:
			play_at(&"creature_alert", spatial.global_position)
		elif state == ENEMY_STATE_TELL:
			# The wind-up, not the landing: this is the half-second of warning a
			# player can actually act on, and it is the reason to poll at all.
			play_at(&"creature_attack", spatial.global_position)

	# Freed enemies would otherwise accumulate ids forever across a long run.
	for id: int in _enemy_states.keys():
		if not seen.has(id):
			_enemy_states.erase(id)
			_enemy_positions.erase(id)
			_enemy_step_accum.erase(id)

	_tick_enemy_vocal(idle_candidates)


func _drive_creature_step(enemy: Node3D, id: int, state: int) -> void:
	var pos: Vector3 = enemy.global_position
	if not _enemy_positions.has(id):
		_enemy_positions[id] = pos
		return
	var moved: Vector3 = pos - _enemy_positions[id]
	_enemy_positions[id] = pos
	if state >= ENEMY_STATE_TELL:
		# Winding up, striking or dead: not walking. Reset so the first step
		# after it starts moving again is a full stride away.
		_enemy_step_accum[id] = 0.0
		return
	var flat: float = Vector2(moved.x, moved.z).length()
	if flat > CREATURE_STEP_MAX_JUMP_M:
		return
	var accum: float = float(_enemy_step_accum.get(id, 0.0)) + flat
	if accum < CREATURE_STRIDE_M:
		_enemy_step_accum[id] = accum
		return
	_enemy_step_accum[id] = 0.0
	# Out of earshot is silence, not a quiet sound: a dozen creatures stepping
	# across an island is a wash of noise that hides the one that matters.
	var body: Node3D = _player_body(multiplayer.get_unique_id())
	if body == null or not body.is_inside_tree():
		return
	if pos.distance_to(body.global_position) > CREATURE_STEP_RANGE_M:
		return
	var heavy: bool = HEAVY_STEP_SPECIES.has(_def_id(enemy))
	play_at(&"creature_step_heavy" if heavy else &"creature_step", pos)


func _tick_enemy_vocal(idle: Array[Node3D]) -> void:
	if _clock < _next_enemy_vocal or idle.is_empty():
		return
	_next_enemy_vocal = _clock + randf_range(ENEMY_VOCAL_GAP_MIN_S, ENEMY_VOCAL_GAP_MAX_S)
	var body: Node3D = _player_body(multiplayer.get_unique_id())
	if body == null or not body.is_inside_tree():
		return
	# Only something the player could plausibly hear. A creature muttering
	# across the island is noise, and worse, a false threat cue.
	var near: Array[Node3D] = []
	for enemy: Node3D in idle:
		if enemy.global_position.distance_to(body.global_position) <= ENEMY_VOCAL_RANGE_M:
			near.append(enemy)
	if near.is_empty():
		return
	var chosen: Node3D = near[randi() % near.size()]
	var cue: StringName = ENEMY_IDLE_CUES.get(_def_id(chosen), DEFAULT_IDLE_VOCAL)
	play_at(cue, chosen.global_position)
