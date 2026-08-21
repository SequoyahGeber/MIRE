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
	&"leaf_rustle", &"insect_chirp", &"water_lap",
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
	_drive_footsteps(delta)
	_tick_ambient()


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
	["tusker", &"hit_flesh"],
	["boss", &"hit_flesh"],
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
	["wall", &"hit_wood"],
	["palisade", &"hit_wood"],
	["gate", &"hit_wood"],
	["door", &"hit_wood"],
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

const HARVESTABLE_GROUP: StringName = &"harvestable"
const CHEST_GROUP: StringName = &"chest"
const DOOR_GROUP: StringName = &"door"
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

	_bind(^"/root/CombatService", &"swing_started", _on_swing_started)
	_bind(^"/root/CombatService", &"attack_landed", _on_attack_landed)
	_bind(^"/root/RangedCombatService", &"shot_started", _on_shot_started)
	_bind(^"/root/RangedCombatService", &"shot_landed", _on_shot_landed)
	_bind(^"/root/RangedCombatService", &"shot_missed", _on_shot_missed)
	_bind(^"/root/BuildService", &"piece_placed", _on_piece_placed)
	_bind(^"/root/BuildService", &"build_confirmed", _on_build_confirmed)
	_bind(^"/root/BuildService", &"piece_destroyed", _on_piece_destroyed)
	_bind(^"/root/CraftingService", &"craft_confirmed", _on_craft_confirmed)
	_bind(^"/root/PlayerHealth", &"player_downed", _on_player_downed)
	_bind(^"/root/PlayerHealth", &"revive_confirmed", _on_revive_confirmed)
	_bind(^"/root/PlayerHealth", &"consume_confirmed", _on_consume_confirmed)
	_bind(^"/root/PlayerHealth", &"local_health_changed", _on_local_health_changed)
	_bind(^"/root/PlayerHealth", &"local_stamina_changed", _on_local_stamina_changed)
	_bind(^"/root/EnemyWorld", &"enemy_spawned", _on_enemy_spawned)
	_bind(^"/root/EnemyWorld", &"enemy_died", _on_enemy_died)
	_bind(^"/root/PowerupService", &"resonance_changed", _on_resonance_changed)
	_bind(^"/root/AttunementService", &"selection_confirmed", _on_attunement_confirmed)
	_bind(^"/root/InventoryService", &"operation_confirmed", _on_inventory_operation)
	_bind(^"/root/PlayerNet", &"player_spawned", _on_player_spawned)
	_bind(^"/root/NetSession", &"peer_joined", _on_peer_joined)
	_bind(^"/root/NetSession", &"peer_left", _on_peer_left)
	_bind(^"/root/MenuStack", &"screen_pushed", _on_screen_pushed)
	_bind(^"/root/MenuStack", &"screen_popped", _on_screen_popped)

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
		for node: Node in tree.get_nodes_in_group(HARVESTABLE_GROUP):
			_on_node_added(node)
		for node: Node in tree.get_nodes_in_group(CHEST_GROUP):
			_on_node_added(node)
		for node: Node in tree.get_nodes_in_group(DOOR_GROUP):
			_on_node_added(node)


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
		if not button.pressed.is_connected(_on_button_pressed):
			button.pressed.connect(_on_button_pressed)
		return
	_try_attach_station_loop(node)
	if node.is_in_group(HARVESTABLE_GROUP):
		if node.has_signal(&"depleted") and not node.is_connected(&"depleted", _on_harvestable_depleted.bind(node)):
			node.depleted.connect(_on_harvestable_depleted.bind(node))
	elif node.is_in_group(CHEST_GROUP):
		if node.has_signal(&"open_confirmed"):
			node.open_confirmed.connect(_on_chest_opened.bind(node))
	elif node.is_in_group(DOOR_GROUP):
		if node.has_signal(&"toggled"):
			node.toggled.connect(_on_door_toggled.bind(node))


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


func _on_swing_started(weapon_id: StringName) -> void:
	play(WEAPON_SWING_CUE.get(weapon_id, DEFAULT_SWING_CUE))


func _on_attack_landed(_peer_id: int, position: Vector3, damage: int,
		target_name: StringName) -> void:
	var cue: StringName = _cue_for_target(target_name)
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


func _on_build_confirmed(_request_id: int, accepted: bool, _reason: String) -> void:
	if not accepted:
		play(&"build_denied")


func _on_craft_confirmed(_request_id: int, accepted: bool, _detail: String) -> void:
	play(&"craft_complete" if accepted else &"craft_denied")


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


func _on_door_toggled(open: bool, _by_peer_id: int, node: Node) -> void:
	play_at(&"door_open" if open else &"door_close", _world_position_of(node))


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


func _on_landed() -> void:
	play(&"land_hard")


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


func _on_piece_destroyed(_piece: Variant, _def_id: StringName, position: Vector3,
		_by_peer_id: int) -> void:
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


func _on_button_pressed() -> void:
	play(&"ui_click")


func _on_run_restarted() -> void:
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


func _drive_footsteps(delta: float) -> void:
	var body: Node3D = _player_body(multiplayer.get_unique_id())
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

const AMBIENT_DAY_CUES: Array[StringName] = [
	&"bird_call", &"bird_call", &"insect_chirp", &"leaf_rustle",
	&"branch_creak", &"wind_gust", &"water_lap", &"marsh_gas",
]
const AMBIENT_NIGHT_CUES: Array[StringName] = [
	&"night_bird", &"frog_croak", &"frog_croak", &"insect_chirp",
	&"marsh_gas", &"distant_call", &"branch_creak", &"wind_gust", &"water_lap",
]
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
	var pool: Array[StringName] = AMBIENT_NIGHT_CUES if _clock_is_night() else AMBIENT_DAY_CUES
	var cue: StringName = pool[randi() % pool.size()]
	var angle: float = randf() * TAU
	var distance: float = randf_range(AMBIENT_NEAR_M, AMBIENT_FAR_M)
	var offset := Vector3(cos(angle) * distance, randf_range(-1.0, 4.0), sin(angle) * distance)
	play_at(cue, body.global_position + offset)


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


## A lit furnace is the only continuous sound source in the game, and it is
## attached to the station node itself rather than played as a one-shot — a
## crackle that restarts every few seconds is unmistakably a loop, and a player
## standing at a workbench for a minute will hear it restart twenty times.
##
## Keyed on the asset's own name, not on a scene or a level, because release
## worlds are generated (the same rule the animation/VFX binding follows). The
## furnace has no lit/unlit state yet; when it grows one, this is where it
## hooks, and until then a furnace in a camp is a working furnace.
const STATION_LOOP_CUES: Dictionary[String, StringName] = {
	"furnace": &"furnace_loop",
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
		return
