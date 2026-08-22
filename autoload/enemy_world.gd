extends Node

## Host-owned enemy spawning, the navigation map they path on, and the registry task 2.12's wave
## spawner drives.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, "Enemies (spawn, AI, damage)"): **HOST**. Only the
## host calls `host_spawn()`; clients receive bodies through a code-built `MultiplayerSpawner`
## (D-023) and simulate none of them. There is no client spawn RPC and there must not be one — an
## enemy a client can conjure is an enemy a client can duplicate.
##
## Navigation is built here rather than per-enemy because a navmesh is a property of the level, not
## of the thing walking on it. The region is baked once from the level's static collision at session
## start; enemies then just have a map to query.

const EVENT_BUS := preload("res://core/events/event_bus.gd")
const ENEMY_SCRIPT := preload("res://systems/enemies/enemy.gd")
const ENEMY_DEF := preload("res://systems/enemies/enemy_def.gd")
## Task 5.5. `BossDef extends EnemyDef`, so `_load_defs()`'s `res is ENEMY_DEF` check already accepts
## one with no change; only the spawn-time script choice below needs to know the difference, so a
## `BossDef` actually gets `Boss`'s phase/arena/telegraph machinery instead of plain `Enemy`.
const BOSS_DEF := preload("res://systems/enemies/boss_def.gd")
const BOSS_SCRIPT := preload("res://systems/enemies/boss.gd")

const DEFS_PATH: String = "res://content/enemies"
const CONTAINER_NODE: StringName = &"Enemies"
const SPAWNER_NODE: StringName = &"EnemySpawner"
const ENEMY_GROUP: StringName = &"enemies"
## The group `entities/player/player_controller.gd` joins. Read by F-392's spawn-distance guard, by
## name rather than by preloading that script — this autoload must not take a hard dependency on the
## player scene it only ever meets at runtime, and most `tools/` harnesses stand in a bare Node3D.
const PLAYER_GROUP: StringName = &"players"
## Group a `NavBaker` joins when it owns a level's navigation (F-351). Kept in sync with that file's
## own `NAV_OWNER_GROUP` by name rather than by preloading it: this autoload must not take a hard
## dependency on a world-building script it only ever meets at runtime, and most of the harnesses in
## `tools/` have no baker at all.
const NAV_OWNER_GROUP: StringName = &"navigation_map_owner"

## Matches A-006's crawler: 0.45 m radius, and it climbs the playtest ramps but not walls.
const NAV_AGENT_RADIUS_M: float = 0.5
const NAV_AGENT_HEIGHT_M: float = 0.7
const NAV_MAX_CLIMB_M: float = 0.6
const NAV_MAX_SLOPE_DEG: float = 46.0
const NAV_CELL_SIZE_M: float = 0.25
## F-494: `cell_height` was left at the engine default 0.25, which quantised `agent_height` up to
## 0.75 and `agent_max_climb` down to 0.5 and made the engine warn on every bake. 0.1 divides both
## exactly, so the baked mesh is built for the agent we actually asked for.
const NAV_CELL_HEIGHT_M: float = 0.1
## Grace before the first bake/spawn, so the level has entered the tree. Short enough that crawlers
## are there by the time you have finished looking around.
const BOOTSTRAP_DELAY_SEC: float = 0.75

## Ambient spawning: enough crawlers to make the world not empty, and nothing more. This is NOT task
## 2.12's wave director — there is no day/night gate, no scaling with Cycle, no despawn at dawn. It
## exists because the map had a nest marker and no enemies, and 2.12 is expected to turn it off and
## take over.
@export var ambient_enabled: bool = true
## Gamerule `ambient_enemy_population` (task 3.14). The export is the fallback COMMANDS.md §4.3
## describes; `_bind_rules()` adopts the rule's value into it when one is authored, so every reader
## below — the loop, the `enemies` status line — keeps reading one field and pays nothing per tick.
## F-599 review (wick1c650c): the export is the FALLBACK — any path where the rule is not authored,
## or `RuleService` is not up yet, reads this number and not the rule. Left at 4 it silently handed
## back the empty island the finding exists to fix, on exactly the paths nobody tests. The range also
## has to track the rule's ceiling (raised to 64) or the inspector and the gamerule disagree about
## what is legal.
@export_range(0, 64, 1) var ambient_population: int = 18
@export_range(1.0, 60.0, 0.5) var ambient_respawn_seconds: float = 12.0
## Spread around the marker, so four crawlers do not stack in one spot.
@export_range(0.0, 20.0, 0.5) var ambient_scatter_m: float = 4.0
@export var ambient_enemy: StringName = &"crawler"
## F-538. The rest of the daytime field. `docs/ENEMIES.md` §intro says the task-5.2 stat variants
## "stay as the ambient daytime field" — they did not: `ambient_enemy` was a single id, so `strider`,
## `tusker` and `broodcaller` were authored, tuned and tested (`tools/enemy_content_check.gd`) and
## then reachable from no spawn path in the game. `WaveSpawner` never rolls them either; its
## `roster_order` is the night LADDER, which is a different set on purpose.
##
## These are variants of the crawler and belong here rather than in the night roster: they wear
## `enemy_crawler.glb` under a `visual_tint` and a scale, so they read as "that one is faster / that
## one is bigger", not as a new tier. An id absent from `defs` is skipped rather than fatal, so
## deleting a variant's `.tres` does not brick the daytime loop.
@export var ambient_variants: Array[StringName] = [&"bog_crawler", &"strider", &"tusker", &"broodcaller"]
## F-538. Relative weight of `ambient_enemy` against ONE variant when `_roll_ambient_kind()` rolls.
## 6 against four variants at weight 1 each puts the plain crawler at 60% of the field, so a
## population of 4 is usually two or three crawlers and one oddity. Deliberately not an even split:
## variety means a spread that still contains the ordinary case — a day where every crawler is a
## different tinted special is not more varied, it just moves the sameness somewhere else.
@export_range(1.0, 20.0, 0.5) var ambient_base_weight: float = 6.0
## F-392. No ambient crawler may materialise closer than this to a live player. Reported from play:
## "a crawler randomly spawned in the middle of the map right after i respawned during the day" —
## the loop picked a nest marker with no regard for who was standing on it, so respawning next to a
## nest (which `content/poi/enemy_nest.tres`'s placement makes possible) put one in your face.
##
## 28 m is picked off a distance the game already defines rather than as a round number: the crawler
## inherits `EnemyDef`'s 18 m `aggro_radius_m` and 26 m `deaggro_radius_m` (it overrides neither), so
## a spawn beyond 28 m cannot be aggroed on the frame it appears — it has to notice you and walk,
## which is the difference between "something moved over there" and "something appeared here".
## Not larger: the island is 118 m across (F-368) and its nests cluster, so a much wider guard would
## leave a top-up with nowhere legal to go on most frames and permanently ride the fallback below.
@export_range(0.0, 60.0, 1.0) var ambient_min_player_distance_m: float = 28.0
## F-392. How long after a player comes back up — a bleed-out respawn or a teammate's revive — the
## ambient loop refuses to add anything at all. Distance alone does not cover the reported case: a
## respawn TELEPORTS the body (`PlayerHealth._teleport_to_spawn()`), so a top-up that ran on the same
## frame could clear the guard against where the player used to be and still land next to where they
## now are. Six seconds is long enough to cover the teleport, the fade and the first look around, and
## short enough that it never eats a whole `ambient_respawn_seconds` cycle.
const AMBIENT_RESPAWN_GRACE_SEC: float = 6.0
## F-392. How many (marker, scatter) rolls to try before falling back. The scatter can push an
## otherwise-legal marker back inside the guard radius, and re-rolling is far cheaper than solving
## for a legal offset; eight rolls is well past the point where a legal marker fails to produce a
## legal position.
const AMBIENT_PLACEMENT_ATTEMPTS: int = 8

signal enemy_spawned(enemy: Node3D)
signal enemy_died(enemy_id: StringName, instigator_peer_id: int, position: Vector3)

var defs: Dictionary[StringName, Resource] = {}

var _container: Node3D
var _spawner: MultiplayerSpawner
var _region: NavigationRegion3D
var _next_index: int = 1
var _nav_polygon_count: int = 0
var _ambient_accumulator: float = 0.0
## Seeded, never randi(): every peer boots the same registry, and a spawn scatter that differs per
## machine is the kind of thing that looks fine until it does not (AGENTS.md).
var _ambient_rng := RandomNumberGenerator.new()
var _bootstrapped: bool = false
var _bootstrap_elapsed: float = 0.0
## Cached transport ref (F-099) — _owns_spawning() runs every physics tick on every peer, and was
## re-resolving /root/NetTransport by path each time. Path-based on purpose (F-011 — harnesses
## install their transport at /root), cached once found.
var _transport_node: Node
## F-392. Seconds of ambient silence still owed after somebody came back up. Counted down in
## `_physics_process`, and checked by `top_up_ambient()` itself rather than by the timer branch, so
## the rule-change path (`_on_rule_changed` -> `top_up_ambient`) is covered by the same guard — that
## path is the one that can fire at any instant, including the frame a player finishes respawning.
var _ambient_grace_remaining: float = 0.0


func _ready() -> void:
	_ambient_rng.seed = 0x4352414d  # "CRAM"
	_load_defs()
	_build_replication_nodes()
	var transport: Node = _transport()
	if transport != null:
		transport.get("server_started").connect(_on_session_opened)
		transport.get("connected_to_host").connect(_on_session_opened)
		transport.get("disconnected").connect(_on_disconnected)
	EVENT_BUS.subscribe_run_restarted(_on_run_restarted)
	_register_commands()
	_bind_rules()
	# F-392: PlayerHealth is registered AFTER EnemyWorld in project.godot's [autoload] block, so
	# `/root/PlayerHealth` does not exist yet inside this `_ready()`. Binding straight from here would
	# find nothing and the respawn grace would never arm — a wiring failure that presents as silence,
	# exactly F-068's class of bug. Deferred, every autoload is in the tree by the time it runs.
	_bind_player_health.call_deferred()
	MireLog.info(&"content", "loaded %d enemy definition(s)" % defs.size())


## F-392's respawn half. `PlayerHealth.downed_flag_changed(peer_id, false)` is the one signal that
## fires exactly once per "a player is upright again" — a bleed-out respawn and a teammate's revive
## both land there, and `_broadcast_downed_flag()` only emits on an actual change, so this costs
## nothing on the 1 Hz hunger publishes that share the same `_publish_snapshot()` path.
##
## Optional by design, same shape as `_bind_rules()` above: most `tools/` harnesses install no
## PlayerHealth at all, and an ambient loop that refused to run without one would take the whole
## enemy population down with it.
func _bind_player_health() -> void:
	var health: Node = get_node_or_null(^"/root/PlayerHealth")
	if health == null or not health.has_signal(&"downed_flag_changed"):
		return
	if health.is_connected(&"downed_flag_changed", _on_downed_flag_changed):
		return
	health.connect(&"downed_flag_changed", _on_downed_flag_changed)


## Arms the grace only on the false edge — the transition INTO being upright. Going down is not the
## dangerous moment; standing back up is, because `PlayerHealth._teleport_to_spawn()` has just put
## the body somewhere the last top-up never evaluated.
func _on_downed_flag_changed(_peer_id: int, downed: bool) -> void:
	if downed:
		return
	_ambient_grace_remaining = AMBIENT_RESPAWN_GRACE_SEC


func _exit_tree() -> void:
	EVENT_BUS.unsubscribe_run_restarted(_on_run_restarted)


## F-243: a fresh run starts with a clear field — `host_despawn_all()` already exists (task 2.12's
## dawn-clear), self-guarded on `_owns_spawning()`, so every peer's own copy can call this
## unconditionally off `run_restarted` and only the host's actually frees anything.
func _on_run_restarted() -> void:
	host_despawn_all()


## COMMANDS.md §4.3's export-fallback seam, in the direction the framework requires: this file ASKS
## RuleService once and then listens; the service never reaches in here. Adopting into the export
## rather than reading the service at each use keeps the hot `while live_count() < …` loop free of a
## cross-autoload call, and leaves the inspector showing the value actually in force. No RuleDef, no
## RuleService, or a harness without either — nothing happens and the export stands, which is the
## documented fallback.
func _bind_rules() -> void:
	var rules: Node = get_node_or_null(^"/root/RuleService")
	if rules == null:
		return
	rules.connect(&"rule_changed", _on_rule_changed)
	if bool(rules.call("has_rule", &"ambient_enemy_population")):
		ambient_population = int(rules.call("value_int", &"ambient_enemy_population", ambient_population))


## Raising the population mid-session should populate the world now, not at the next respawn tick —
## the point of a runtime knob is seeing the change. Lowering it does NOT cull: an enemy already in
## the world is a live thing a player may be fighting, and the field drains to the new number as
## those die. `top_up_ambient` is host-guarded on its own.
func _on_rule_changed(id: StringName, new_value: float) -> void:
	if id != &"ambient_enemy_population":
		return
	var previous: int = ambient_population
	ambient_population = roundi(new_value)
	if ambient_enabled and ambient_population > previous:
		top_up_ambient()


## docs/COMMANDS.md §2.1 — migrated off DebugConsole.register() in task 3.13. `spawn`/`killall` are
## HOST-scope (CommandService's op check replaces the old hand-rolled `_owns_spawning()` string), so
## the host-only refusal these used to print by hand is gone; a non-op gets CommandService's uniform
## refusal (COMMANDS.md §1.3) instead.
func _register_commands() -> void:
	var command_service: Node = get_node_or_null(^"/root/CommandService")
	if command_service == null:
		return
	command_service.call("register_spec", &"spawn", {
		"scope": &"host",
		"args": [
			{"name": "enemy", "type": &"enemy_id", "optional": true, "default": &""},
			{"name": "count", "type": &"int", "optional": true, "default": 1, "min": 1},
			# Optional and LAST, so `spawn crawler 3` keeps working exactly as it did — the vec3
			# branch in _parse_args only fires when all three coordinate tokens are present.
			{"name": "at", "type": &"vec3", "optional": true, "default": null},
		],
		"handler": _cmd_spawn,
		"help": "spawn [enemy_id] [count] [x y z] — spawn near you, or at a point",
	})
	command_service.call("register_spec", &"killall", {
		"scope": &"host", "args": [], "handler": _cmd_killall,
		"help": "killall — despawn every enemy",
	})
	command_service.call("register_spec", &"enemies", {
		"scope": &"local", "args": [], "handler": _cmd_enemies,
		"help": "enemies — how many are alive, and where",
	})


func _cmd_spawn(ctx: Dictionary, args: Dictionary) -> Dictionary:
	var id: StringName = args.get("enemy", &"")
	if id == &"":
		id = ambient_enemy
	if not has_def(id):
		return {"ok": false,
			"message": "no such enemy '%s' — have: %s" % [id, ", ".join(defs.keys())], "data": {}}
	var count: int = maxi(int(args.get("count", 1)), 1)
	# ctx.position/facing are the ISSUER's own replicated body — host typing locally, or an opped
	# client's body read off the host's own copy for an RPC-submitted spawn. That generalizes what the
	# old is_multiplayer_authority() search could only ever do for the host's own local body (it would
	# silently fall back to the origin for anyone else, which an RPC-submitted spawn now is).
	# An explicit destination wins; otherwise 5 m in front of the issuer, which is what this command
	# meant before task 3.16 gave it coordinates and is still the right default at a console.
	var explicit: Variant = args.get("at")
	var origin: Vector3 = explicit if explicit is Vector3 else \
		(ctx.get("position", Vector3.ZERO) as Vector3) \
		+ (ctx.get("facing", Vector3.FORWARD) as Vector3) * 5.0
	var made: int = 0
	for i: int in count:
		if host_spawn(id, origin + Vector3(float(i) * 1.5, 0.0, 0.0)) != null:
			made += 1
	return {"ok": true, "message": "spawned %d %s" % [made, id],
		"data": {"count": made, "enemy": String(id)}}


func _cmd_killall(_ctx: Dictionary, _args: Dictionary) -> Dictionary:
	var count: int = live_count()
	host_despawn_all()
	return {"ok": true, "message": "despawned %d" % count, "data": {"count": count}}


func _cmd_enemies(_ctx: Dictionary, _args: Dictionary) -> Dictionary:
	var points: Array[Vector3] = ambient_spawn_points()
	return {"ok": true, "message":
		"%d alive, ambient %s (population %d), %d spawn point(s), navmesh %d polygons" % [
			live_count(), "on" if ambient_enabled else "off", ambient_population,
			points.size(), _nav_polygon_count
		], "data": {}}


## Host-only, and the whole ambient loop. Deliberately coarse: it tops the population back up on a
## timer rather than tracking individual deaths, so a crawler killed at any moment is replaced within
## `ambient_respawn_seconds` and nothing has to be unsubscribed.
func _physics_process(delta: float) -> void:
	# F-392: the respawn grace burns down ahead of every early-out below, night included. It is a
	# real-time "nothing appears near someone who just stood up" window, not a share of the ambient
	# timer, so it must not freeze while `WaveSpawner` has `ambient_enabled` off for the night and
	# then still be owing at dawn. One float subtract, and only while one is actually owed.
	if _ambient_grace_remaining > 0.0:
		_ambient_grace_remaining = maxf(_ambient_grace_remaining - delta, 0.0)

	# Cheap constant checks first; the authority check dispatches into the transport (F-099).
	if not ambient_enabled or defs.is_empty() or not _owns_spawning():
		return

	# Pressing Play opens no session, so nothing calls _on_session_opened and neither the bake nor
	# the first spawn would ever happen — which is exactly how the game shipped with a nest marker
	# and no crawlers. The short delay is for the level: an autoload's _ready runs before
	# get_tree().current_scene exists, so there is nothing to bake from yet.
	if not _bootstrapped:
		_bootstrap_elapsed += delta
		if _bootstrap_elapsed < BOOTSTRAP_DELAY_SEC:
			return
		_bootstrapped = true
		if _nav_polygon_count == 0:
			bake_navigation()
		top_up_ambient()
		return

	_ambient_accumulator += delta
	if _ambient_accumulator < ambient_respawn_seconds:
		return
	_ambient_accumulator = 0.0
	top_up_ambient()


## Spawns up to `ambient_population` living enemies at the level's enemy_spawn markers. Returns how
## many it added. Public so a console command and task 2.12 can both drive it.
##
## F-392: HOST-ONLY placement, and it has to stay that way. This is ARCHITECTURE.md §2.2's "wave
## director" row — the distance guard below decides WHERE a body comes into the world, so it belongs
## on the one machine that runs `host_spawn()`. A client filtering what it renders would only hide
## the crawler that already exists next to it, which is not the same thing at all.
func top_up_ambient() -> int:
	if not _owns_spawning():
		return 0
	# F-392: checked here rather than in `_physics_process` so that EVERY way in is covered by one
	# guard — the 12 s timer, the bootstrap top-up, and `_on_rule_changed()`'s immediate refill, which
	# is the path that can land on the exact frame a player finishes respawning. Returning 0 leaves
	# the field a body or two short for a few seconds; the next tick fills it.
	if _ambient_grace_remaining > 0.0:
		return 0
	var points: Array[Vector3] = ambient_spawn_points()
	if points.is_empty():
		return 0
	var players: Array[Vector3] = _live_player_positions()
	var added: int = 0
	# live_count() alone, NOT live_count() + added: a spawned enemy joins the `enemies` group inside
	# its own _ready, so it is already counted by the next iteration. Adding both stopped the loop at
	# half the population.
	var attempts: int = 0
	# F-599 review: the target grows with corruption, so the bias adds pressure instead of moving it.
	var target: int = _corruption_scaled_population(points)
	while live_count() < target and attempts < target:
		attempts += 1
		if host_spawn(_roll_ambient_kind(), _pick_ambient_position(points, players)) == null:
			break
		added += 1
	return added


## F-538. Which kind the next ambient body is: `ambient_enemy` at `ambient_base_weight`, or one of
## `ambient_variants` at weight 1 each. Rolled per BODY rather than once per top-up, so a field that
## refills a single corpse still varies instead of locking to whatever the first roll picked.
##
## Uses `_ambient_rng` — the same seeded stream the placement scatter draws from, never `randi()`.
## Ambient spawning is host-only (F-392), so this does not have to agree across peers the way a
## replicated roll would; it draws from the seeded stream anyway because a run that replays the same
## way from the same seed is worth more than the two lines it costs, and mixing an unseeded call into
## a seeded stream is how the placement scatter would quietly stop being reproducible too.
func _roll_ambient_kind() -> StringName:
	var pool: Array[StringName] = []
	for id: StringName in ambient_variants:
		# Skip silently: a variant whose .tres was deleted or renamed should thin the spread, not
		# fail the top-up and leave the day empty.
		if id != ambient_enemy and has_def(id):
			pool.append(id)
	if pool.is_empty():
		return ambient_enemy
	var total: float = ambient_base_weight + float(pool.size())
	var roll: float = _ambient_rng.randf() * total
	if roll < ambient_base_weight:
		return ambient_enemy
	var index: int = mini(int(roll - ambient_base_weight), pool.size() - 1)
	return pool[index]


## F-392. Where one ambient crawler actually lands: a nest marker plus scatter, re-rolled until the
## result clears `ambient_min_player_distance_m` from every live player.
##
## Re-rolling the whole (marker, scatter) pair rather than only the marker is deliberate — the
## scatter is up to 4 m and can push an otherwise-legal marker back inside the guard, which is how a
## "safe" nest still produced a crawler at arm's length.
##
## When every roll fails the fallback is `_furthest_ambient_point()`, NOT "spawn nothing": an empty
## field is a worse bug than a distant crawler, and on a map whose nests all sit near the players
## (small island, everyone regrouped at the Wellspring) silently spawning nothing would drain the
## daytime population to zero and stay there. `top_up_ambient()` is the daytime population by design
## — `systems/waves/wave_spawner.gd` disables it for the night and owns the field then — so it must
## always produce a body, just never an ambush.
## The ambient target for the island as it stands right now.
func _corruption_scaled_population(points: Array[Vector3]) -> int:
	var mean: float = _mean_nest_corruption(_corruption_weights(points))
	return maxi(int(roundf(float(ambient_population) * (1.0 + mean * POPULATION_CORRUPTION_GAIN))), 0)


func _pick_ambient_position(points: Array[Vector3], players: Array[Vector3]) -> Vector3:
	var minimum_sq: float = ambient_min_player_distance_m * ambient_min_player_distance_m
	var weights: PackedFloat32Array = _corruption_weights(points)
	for _attempt: int in AMBIENT_PLACEMENT_ATTEMPTS:
		var candidate: Vector3 = points[_weighted_nest_index(points, weights)] \
			+ _ambient_scatter_offset()
		if _nearest_player_distance_sq(candidate, players) >= minimum_sq:
			return candidate
	return _furthest_ambient_point(points, players)


## F-599: how much more likely a nest is to be used, per unit of corruption standing on it.
##
## Sequoyah, after playing: *"there doesnt seem to be any pressure and in terms of the mire spreading
## and players have to keep it back its super unclear."* This constant is half the answer to both
## halves of that sentence at once, which is why it is worth the code rather than being another
## number somewhere.
##
## The Mire is currently only legible by walking onto it: the front advances 1.66 m/min across an
## 1180 m island (docs/PRESSURE.md), so in a two-hour session a player may never see it. But enemies
## are legible from a long way off. Biasing the ambient field toward corrupted nests means the
## corruption announces itself through the thing the player already reads — "this side of the island
## is getting dangerous" — before it is visible as ground. It also gives the ambient field a reason to
## exist beyond ambience, and it makes capping a Wellspring feel like it did something, because the
## pressure near it drops with the corruption.
##
## 2.0 means a fully corrupted nest is 3x as likely as clean ground. **Lowered from 4.0 on review
## (birch1db63e), and the reasoning is worth keeping because it is not obvious.** Bodies land within
## `ambient_scatter_m` (4 m) of their nest, so weight does not spread population over the island — it
## decides how big a CLUMP is at one point. At bias 4 the worst case is one corrupted nest among four
## clean ones, which puts 5/9 — 56% — of the entire ambient field inside a single 8 m box. Against a
## broodcaller's 28 m alert radius and `_alert_nearby()` handing a target to every untargeted
## packmate in one hop, that is not pressure, it is an unsurvivable ambush at Cycle 1.
##
## Note also that the skew exists only while corruption is UNEVEN: an all-clean island and a fully
## saturated one both give uniform weights. This is a mid-run signal by construction, which is
## correct — it is at its strongest exactly when part of the island has turned and part has not, and
## that is the moment the information is worth having.
const CORRUPTION_SPAWN_BIAS: float = 2.0


## F-599 review (wick1c650c): how much the ambient population GROWS with mean corruption.
##
## The bias above decides which nests are hot; on its own it redistributes a fixed pool, and they
## measured what that costs: at half the nests corrupted the clean half keeps 17% of the field —
## about 3 bodies over half an island, back to roughly the density this finding exists to fix, and at
## its worst in the middle of a run where players spend most of their time. Biasing *placement*
## without growing the *pool* moves pressure rather than adding it.
##
## So the pool grows with how much of the island has turned: 0.6 means a fully corrupted island
## carries 1.6x the ambient population of a clean one. The clean half then keeps roughly its original
## absolute density while the corrupted half genuinely intensifies, which is the behaviour the bias
## was supposed to produce on its own.
##
## Deliberately modest. The population is also what the night waves stack on top of, and
## birch1db63e's clump analysis is the standing warning here: a broodcaller's 28 m alert radius plus
## `_alert_nearby()` means bodies that land together fight together.
const POPULATION_CORRUPTION_GAIN: float = 0.6


## Mean corruption across the nests, 0..1 — the cheap stand-in for "how much of the island has
## turned". Sampled at the nests rather than over the island because the nests are where it changes
## what happens; a corrupted lake nobody spawns at should not inflate the population.
func _mean_nest_corruption(weights: PackedFloat32Array) -> float:
	if weights.is_empty():
		return 0.0
	var total: float = 0.0
	for weight: float in weights:
		# Invert `1 + corruption * BIAS` rather than re-sampling the grid — same numbers, no second
		# pass over `corruption_at()`.
		total += (weight - 1.0) / maxf(CORRUPTION_SPAWN_BIAS, 0.001)
	return clampf(total / float(weights.size()), 0.0, 1.0)


## Per-nest selection weight, `1 + corruption * CORRUPTION_SPAWN_BIAS`.
##
## Computed once per top-up rather than per attempt: `AMBIENT_PLACEMENT_ATTEMPTS` re-rolls against
## the same nests and the corruption cannot change between two rolls in the same frame.
func _corruption_weights(points: Array[Vector3]) -> PackedFloat32Array:
	var weights := PackedFloat32Array()
	weights.resize(points.size())
	var mire_grid: Node = get_node_or_null(^"/root/MireGrid")
	for index: int in points.size():
		var corruption: float = 0.0
		if mire_grid != null:
			corruption = clampf(float(mire_grid.call(&"corruption_at", points[index])), 0.0, 1.0)
		weights[index] = 1.0 + corruption * CORRUPTION_SPAWN_BIAS
	return weights


## Weighted pick over the nests, from the same seeded stream the uniform pick used.
##
## Falls back to a uniform index if the weights are degenerate (no MireGrid, or every nest clean),
## which is both the common early-run case and the case where weighting would be meaningless anyway.
func _weighted_nest_index(points: Array[Vector3], weights: PackedFloat32Array) -> int:
	var total: float = 0.0
	for weight: float in weights:
		total += weight
	if total <= 0.0 or weights.size() != points.size():
		return _ambient_rng.randi_range(0, points.size() - 1)
	var roll: float = _ambient_rng.randf() * total
	for index: int in weights.size():
		roll -= weights[index]
		if roll <= 0.0:
			return index
	return weights.size() - 1


## F-392's fallback. Sweeps every nest deterministically (not another random roll — this branch only
## runs when the random ones have already failed, and "the best of eight more guesses" is not the
## furthest point) and then walks the winner one full scatter length directly AWAY from the player
## nearest it, so the least-bad option is still made as un-ambush-like as the map allows.
func _furthest_ambient_point(points: Array[Vector3], players: Array[Vector3]) -> Vector3:
	var best: Vector3 = points[0]
	var best_clearance_sq: float = -1.0
	for point: Vector3 in points:
		var clearance_sq: float = _nearest_player_distance_sq(point, players)
		if clearance_sq > best_clearance_sq:
			best_clearance_sq = clearance_sq
			best = point
	var nearest: Vector3 = _nearest_player_position(best, players)
	var away := Vector3(best.x - nearest.x, 0.0, best.z - nearest.z)
	if away.length_squared() < 0.0001:
		# Standing exactly on the marker. Any direction is equally away; take a seeded one rather
		# than dropping the body on the player's head.
		away = Vector3(_ambient_rng.randf_range(-1.0, 1.0), 0.0, _ambient_rng.randf_range(-1.0, 1.0))
		if away.length_squared() < 0.0001:
			away = Vector3.FORWARD
	return best + away.normalized() * ambient_scatter_m


## The seeded spread that keeps four crawlers from stacking on one marker. Split out of
## `top_up_ambient()` by F-392 only so the re-roll above can ask for a fresh one.
func _ambient_scatter_offset() -> Vector3:
	return Vector3(
		_ambient_rng.randf_range(-ambient_scatter_m, ambient_scatter_m),
		0.0,
		_ambient_rng.randf_range(-ambient_scatter_m, ambient_scatter_m)
	)


## F-392. Every live player body, host-side — the same `&"players"` group `Wellspring._present_count()`
## reads, which holds on the host for remote bodies and offline for the local one. A downed or dead
## body still counts: it is about to stand back up, in place or at its spawn, and neither is somewhere
## a crawler should be waiting.
func _live_player_positions() -> Array[Vector3]:
	var positions: Array[Vector3] = []
	var tree: SceneTree = get_tree()
	if tree == null:
		return positions
	for node: Node in tree.get_nodes_in_group(PLAYER_GROUP):
		var body := node as Node3D
		if body != null and body.is_inside_tree():
			positions.append(body.global_position)
	return positions


## Horizontal distance only, and squared — the question is "how far away across the ground", and a
## nest marker authored at y=0 under terrain that is 3 m up must not read as further away than it is.
## INF when nobody is present, so an empty session (every `tools/` harness that installs no player)
## takes the first roll and behaves exactly as it did before F-392.
func _nearest_player_distance_sq(point: Vector3, players: Array[Vector3]) -> float:
	var nearest_sq: float = INF
	for player_position: Vector3 in players:
		var dx: float = point.x - player_position.x
		var dz: float = point.z - player_position.z
		nearest_sq = minf(nearest_sq, dx * dx + dz * dz)
	return nearest_sq


func _nearest_player_position(point: Vector3, players: Array[Vector3]) -> Vector3:
	var nearest: Vector3 = point
	var nearest_sq: float = INF
	for player_position: Vector3 in players:
		var dx: float = point.x - player_position.x
		var dz: float = point.z - player_position.z
		var distance_sq: float = dx * dx + dz * dz
		if distance_sq < nearest_sq:
			nearest_sq = distance_sq
			nearest = player_position
	return nearest


## Every nest marker the level published, from either map's marker group.
##
## `playtest_hollow.gd` publishes `playtest_hollow_marker` with kind `enemy_spawn`;
## `authored_world.gd` publishes `authored_world_marker` with kind `enemy_nest` — the same idea
## under two names, because the two maps were built a milestone apart. Reading only the first is
## how Hollowmere shipped as the main scene with four crawler nests modelled into its Blight and
## **zero crawlers in the game**: nothing was broken, nothing logged, the group simply never
## matched. An empty result still means the level has no nest, and ambient spawning quietly does
## nothing rather than dropping crawlers at the origin.
const NEST_SOURCES: Array[Array] = [
	[&"playtest_hollow_marker", "enemy_spawn"],
	[&"authored_world_marker", "enemy_nest"],
]


func ambient_spawn_points() -> Array[Vector3]:
	var points: Array[Vector3] = []
	for source: Array in NEST_SOURCES:
		for node: Node in get_tree().get_nodes_in_group(source[0] as StringName):
			var marker := node as Node3D
			if marker == null:
				continue
			if String(marker.get_meta(&"kind", "")) != String(source[1]):
				continue
			points.append(marker.global_position)
	return points


## F-076: the one marker `kind` a NEW map's generator should publish for its enemy nests. Every
## map built from here on should use this and only this; `NEST_SOURCES` above keeps reading
## Playtest Hollow's legacy `enemy_spawn` for backward compatibility, but nothing new should add
## a third spelling. Read the group-name convergence note in `docs/DELEGATION.md` before adding one.
const CANONICAL_NEST_KIND: StringName = &"enemy_nest"


## Ground truth for "does this map's layout actually have nests" — read straight from the raw
## layout JSON's `markers` array, never through a Godot group. `ambient_spawn_points()` above is
## the other half of the comparison a check wants: what THIS FILE actually found. Keeping the two
## independent is the whole point — Hollowmere shipped with four nests in its layout and zero
## found by `ambient_spawn_points()`, and a check built by counting the same groups this file
## reads would have been just as blind as this file was. `tools/world_contract_check.gd` is that
## check, and it runs against whatever map is `project.godot`'s main scene, not just this one.
func expected_nest_count(layout: Dictionary) -> int:
	var count: int = 0
	for marker_value: Variant in (layout.get("markers", []) as Array):
		var marker := marker_value as Dictionary
		if marker != null and String(marker.get("kind", "")) == String(CANONICAL_NEST_KIND):
			count += 1
	return count


func get_def(id: StringName) -> Resource:
	return defs.get(id)


func has_def(id: StringName) -> bool:
	return defs.has(id)


## Host-only. Returns the spawned body, or null. `position` is where it lands; the caller is
## responsible for that being somewhere sensible — task 2.12 owns spawn-point choice.
func host_spawn(def_id: StringName, position: Vector3) -> Node3D:
	if not _owns_spawning():
		return null
	var def: Resource = defs.get(def_id)
	if def == null:
		MireLog.error(&"content", "EnemyWorld: unknown enemy '%s'" % def_id)
		return null

	var spawned: Node = _spawner.spawn({
		"def": String(def_id),
		"index": _take_index(),
		"origin": position,
	})
	var enemy := spawned as Node3D
	if enemy == null:
		MireLog.error(&"content", "EnemyWorld: spawn failed for '%s'" % def_id)
		return null
	enemy.connect(&"died", _on_enemy_died.bind(def_id, enemy))
	enemy_spawned.emit(enemy)
	return enemy


func live_enemies() -> Array[Node]:
	return get_tree().get_nodes_in_group(ENEMY_GROUP)


func live_count() -> int:
	var total: int = 0
	for node: Node in live_enemies():
		if is_instance_valid(node) and bool(node.call("is_alive")):
			total += 1
	return total


## Host-only. Task 2.12 clears the field at dawn through this rather than freeing nodes itself.
func host_despawn_all() -> void:
	if not _owns_spawning():
		return
	for node: Node in live_enemies():
		node.queue_free()
	# `queue_free()` runs `_exit_tree()` at the end of the frame, which clears each row on its own.
	# Dropping them now as well means a run restart never carries a single engagement across the
	# boundary, even if a body was somehow removed from the tree before this ran (F-331).
	_clear_engagements()


## How many polygons the level's navmesh baked to. Zero means enemies fall back to straight-line
## steering — see `Enemy._steer_toward()`.
func nav_polygon_count() -> int:
	return _nav_polygon_count


## The navigation map anything that walks in this level must query — the one seam for "where is the
## navmesh", so no caller has to know how the level was assembled (F-351).
##
## A streamed world does not bake into the default map. `world/chunk/nav_baker.gd` mints its own,
## configured to match `ChunkMesher`'s cell grid and D-016's edge-connection margin, and registers a
## region per chunk on it as the ring moves. A `NavigationAgent3D` left alone queries the viewport's
## DEFAULT map instead, so before this every enemy on the procedural island navigated a map holding
## exactly one region — `bake_navigation()`'s, baked once at session start from the handful of
## primed spawn chunks — while all 25 streamed chunk navmeshes sat somewhere no walker could see. An
## enemy handed a target off that stale patch paths to the nearest point ON it, which is why a
## crawler spawned at the well walked away from the player standing next to it.
##
## Returns the default map when no baker owns the level, which is every authored map and every test
## harness — those bake into the default map through `bake_navigation()` and are unchanged.
func navigation_map_rid() -> RID:
	var navigation_owner: Node = _navigation_owner()
	if navigation_owner != null:
		return navigation_owner.call(&"map_rid") as RID
	var tree: SceneTree = get_tree()
	if tree == null or tree.root == null or tree.root.world_3d == null:
		return RID()
	return tree.root.world_3d.navigation_map


## The `NavBaker` (or anything else adopting its contract) that owns this level's navigation, or null
## when nothing does. Duck-typed on `map_rid()` rather than on a class: an owner that joined the
## group without the method is a wiring bug that must not silently hand back a null RID as if the
## level simply had no baker.
func _navigation_owner() -> Node:
	var tree: SceneTree = get_tree()
	if tree == null:
		return null
	for node: Node in tree.get_nodes_in_group(NAV_OWNER_GROUP):
		if node.has_method(&"map_rid"):
			return node
	return null


## Is there a navmesh in this level that something can actually path on? The question
## `nav_polygon_count() > 0` used to answer, asked in a way that survives F-351.
##
## `nav_polygon_count()` still means exactly what its name says — polygons THIS node baked — and on a
## streamed island that is legitimately zero, because `bake_navigation()` declines in favour of the
## `NavBaker` that owns the ground. Counting polygons is the wrong unit there anyway: a streamed
## world's coverage is a region per resident chunk, added and retired as the ring moves. So callers
## that want "can enemies path here" should ask this, and callers that want "what did EnemyWorld
## bake" should keep asking `nav_polygon_count()`.
func navigation_ready() -> bool:
	var map: RID = navigation_map_rid()
	if not map.is_valid():
		return false
	return not NavigationServer3D.map_get_regions(map).is_empty()


func nav_region() -> NavigationRegion3D:
	return _region


# ── Construction ──────────────────────────────────────────────────────────────────────────────────


## Built unconditionally on every peer, exactly like PlayerNet's: both sides must build the same
## tree, and only the spawn CALLS are host-only. A spawner that exists on one side only fails as
## silence.
func _build_replication_nodes() -> void:
	_container = Node3D.new()
	_container.name = CONTAINER_NODE
	add_child(_container)

	_spawner = MultiplayerSpawner.new()
	_spawner.name = SPAWNER_NODE
	_spawner.spawn_limit = 0
	_spawner.spawn_function = _net_spawn_enemy
	add_child(_spawner)
	_spawner.spawn_path = _spawner.get_path_to(_container)


## Runs on every peer, with the same data, so host and client build identical bodies. The name is
## derived from the spawn index and is in place before the node enters the tree, matching how
## PlayerNet names players for their peer.
func _net_spawn_enemy(data: Variant) -> Node:
	var payload: Dictionary = data as Dictionary
	if payload == null:
		return null
	var def: Resource = defs.get(StringName(String(payload.get("def", ""))))
	if def == null:
		return null

	# Same script choice on every peer, from the same replicated payload (D-023's usual rule) — a
	# BossDef spawns Boss, anything else spawns the plain Enemy it always has (task 5.5).
	var enemy: CharacterBody3D = BOSS_SCRIPT.new() if def is BOSS_DEF else ENEMY_SCRIPT.new()
	enemy.name = "Enemy%d" % int(payload.get("index", 0))
	enemy.set("definition", def)
	enemy.position = payload.get("origin", Vector3.ZERO)
	return enemy


func _load_defs() -> void:
	var dir: DirAccess = DirAccess.open(DEFS_PATH)
	if dir == null:
		return
	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	while file_name != "":
		# Exported builds pack "<name>.tres" as "<name>.tres.remap", so a raw .tres filter matches
		# nothing there and the game ships with no enemies at all (F-121). load() wants the original
		# .tres path and resolves the remap itself.
		var res_name: String = file_name.trim_suffix(".remap")
		if res_name.ends_with(".tres"):
			var res: Resource = load("%s/%s" % [DEFS_PATH, res_name])
			if res is ENEMY_DEF and StringName(res.get("id")) != &"":
				var errors: PackedStringArray = res.call("validation_errors")
				if errors.is_empty():
					defs[StringName(res.get("id"))] = res
				else:
					MireLog.error(&"content", "%s is invalid (%s), skipped"
						% [file_name, "; ".join(errors)])
		file_name = dir.get_next()
	dir.list_dir_end()


# ── Navigation ────────────────────────────────────────────────────────────────────────────────────


func _on_session_opened() -> void:
	# Re-bake for the session's level rather than trusting whatever the offline bootstrap found.
	_bootstrapped = false
	_bootstrap_elapsed = 0.0
	_nav_polygon_count = 0


func _on_disconnected() -> void:
	host_despawn_all()
	_bootstrapped = false
	_bootstrap_elapsed = 0.0


## Bakes one region from whatever static collision the current scene has. Synchronous on purpose:
## it runs once at session start, before anything is spawned, and an enemy that spawns into a
## half-baked map paths into walls. R3 measured this shape of bake as viable (D-016).
func bake_navigation() -> Node:
	# F-351: when a `NavBaker` owns this level, baking here is worse than redundant. It would parse
	# the whole scene to produce a SECOND description of the same ground on a DIFFERENT map, and the
	# one that matters is already being maintained per chunk as the ring moves. Whatever this baked
	# could then only be a stale rival — which is exactly the region enemies were pathing on.
	# Deliberately still reachable for the authored maps and for every harness with no baker.
	var navigation_owner: Node = _navigation_owner()
	if navigation_owner != null:
		_nav_polygon_count = 0
		var regions: int = -1
		if navigation_owner.has_method(&"region_count"):
			regions = int(navigation_owner.call(&"region_count"))
		MireLog.info(&"content",
			"EnemyWorld: %s owns this level's navigation (%s region(s)) — not baking a rival"
				% [navigation_owner.name, "?" if regions < 0 else str(regions)])
		return null

	var scene_root: Node = get_tree().current_scene
	if scene_root == null:
		_nav_polygon_count = 0
		return null

	var nav_mesh := NavigationMesh.new()
	nav_mesh.agent_radius = NAV_AGENT_RADIUS_M
	nav_mesh.agent_height = NAV_AGENT_HEIGHT_M
	nav_mesh.agent_max_climb = NAV_MAX_CLIMB_M
	nav_mesh.agent_max_slope = NAV_MAX_SLOPE_DEG
	nav_mesh.cell_size = NAV_CELL_SIZE_M
	nav_mesh.cell_height = NAV_CELL_HEIGHT_M
	nav_mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS

	var geometry := NavigationMeshSourceGeometryData3D.new()
	NavigationServer3D.parse_source_geometry_data(nav_mesh, geometry, scene_root)

	# F-177: a placed buildable's StaticBody3D lives under `BuildService`'s own container
	# (`/root/BuildService/Buildings`, D-023 — an autoload keeps its spawned content as its own
	# child so it survives a scene reload) — a SIBLING of the level under `/root`, never a
	# descendant of `scene_root`. The walk above therefore never reaches it, which is F-159's exact
	# gap: a placed wall or Ward is a real physics collider the bake never saw. NavBaker (task 4.5)
	# already fixed this for itself by folding piece boxes into the same source data before its one
	# bake call (D-118) — same "one combined pass" requirement applies here, because Recast carves a
	# hole around solid geometry by seeing it alongside whatever it's carving, so two independently
	# baked regions cannot composite into that result. Parsed into its own data and merged rather
	# than reusing `geometry` directly: `parse_source_geometry_data` is a walk rooted at ONE node,
	# so two roots need two calls regardless, and merging keeps each call's data intact if a future
	# root fails to parse instead of one call silently clobbering the other's data.
	var buildables: Node = get_node_or_null(^"/root/BuildService/Buildings")
	if buildables != null and buildables.get_child_count() > 0:
		var piece_geometry := NavigationMeshSourceGeometryData3D.new()
		NavigationServer3D.parse_source_geometry_data(nav_mesh, piece_geometry, buildables)
		geometry.merge(piece_geometry)

	if geometry.has_data():
		NavigationServer3D.bake_from_source_geometry_data(nav_mesh, geometry)
	_nav_polygon_count = nav_mesh.get_polygon_count()

	if _region == null:
		_region = NavigationRegion3D.new()
		_region.name = "EnemyNavRegion"
		add_child(_region)
	_region.navigation_mesh = nav_mesh

	if _nav_polygon_count == 0:
		# Not an error: an empty test scene has nothing to bake, and Enemy falls back to straight-line
		# steering. Worth a line so a level that SHOULD have baked and did not is visible.
		MireLog.warn(&"content", "EnemyWorld: navmesh baked 0 polygons — enemies will steer directly")
	else:
		MireLog.info(&"content", "EnemyWorld: navmesh baked %d polygons" % _nav_polygon_count)
	return _region


func _on_enemy_died(instigator_peer_id: int, def_id: StringName, enemy: Node3D) -> void:
	enemy_died.emit(def_id, instigator_peer_id,
		enemy.global_position if is_instance_valid(enemy) else Vector3.ZERO)


func _take_index() -> int:
	var result: int = _next_index
	_next_index += 1
	return result


func _transport() -> Node:
	if _transport_node == null or not is_instance_valid(_transport_node):
		_transport_node = get_node_or_null(^"/root/NetTransport")
	return _transport_node


func _owns_spawning() -> bool:
	var transport: Node = _transport()
	if transport == null:
		return true
	if bool(transport.call("is_host")):
		return true
	return not bool(transport.call("is_active")) and not bool(transport.call("is_connecting"))


# ── Attack-slot engagement ledger (F-331) ─────────────────────────────────────────────────────────


## Which enemies are currently telegraphing or swinging at whom: `peer_id -> {instance_id -> kind}`.
##
## `Enemy._engaged_attackers()` used to answer "how many others are already committed to my target?"
## by walking `get_nodes_in_group(ENEMY_GROUP)` — from every in-range enemy, on every host physics
## tick. That is an O(N^2) group traversal at exactly the moment combat density is highest, and it
## also counted every kind against one shared budget, contradicting `Enemy`'s own documented cap "of
## one kind": crawlers, striders and bosses all spent the same slots on the same target.
##
## The original chose the scan for a real reason, recorded in its own comment: "counters drift when
## an enemy dies mid-swing; a live scan cannot." That is a fair objection to an increment/decrement
## pair, where one missed decrement is permanent. It is not an objection to this shape. What is
## stored here is the ENGAGEMENT ITSELF, not a tally: `Enemy` republishes its whole current
## engagement on every state and target change, anything that is not TELL/ATTACK publishes "none",
## and `engaged_attackers()` drops rows whose instance has gone away as it counts. So the structure
## is still a live scan — it has simply been narrowed from the entire roster to the handful of
## enemies engaged on one target, which is bounded by the cap itself.
var _engaged: Dictionary[int, Dictionary] = {}
## `instance_id -> peer_id`, so an engagement can be moved or cleared without its owner having to
## remember which target it was last published against.
var _engaged_peer: Dictionary[int, int] = {}


## Records that `enemy` is committed to `peer_id` as `kind_id`. Idempotent, and safe to call with a
## different target than last time — the previous row is removed first.
func set_engagement(enemy: Node, peer_id: int, kind_id: StringName) -> void:
	if enemy == null or peer_id <= 0:
		return
	var id: int = enemy.get_instance_id()
	var previous: int = int(_engaged_peer.get(id, 0))
	if previous == peer_id:
		var rows: Dictionary = _engaged.get(peer_id, {})
		if StringName(rows.get(id, &"")) == kind_id:
			return
	if previous != 0:
		_forget(id)
	if not _engaged.has(peer_id):
		_engaged[peer_id] = {}
	(_engaged[peer_id] as Dictionary)[id] = kind_id
	_engaged_peer[id] = peer_id


## Records that `enemy` is committed to nobody. The only way out of the ledger, and reached from
## `Enemy`'s state setter, its target setter and its `_exit_tree()` alike — so death, despawn,
## deaggro and a plain transition back to CHASE all clear through one path.
func clear_engagement(enemy: Node) -> void:
	if enemy == null:
		return
	_forget(enemy.get_instance_id())


## How many enemies of `kind_id` are engaged on `peer_id`, not counting `exclude`.
##
## `exclude` is the asking enemy: the shipped cap has always meant "how many OTHERS", and an enemy
## re-evaluating while already engaged must not count itself out of its own slot.
func engaged_attackers(peer_id: int, kind_id: StringName, exclude: Node = null) -> int:
	if peer_id <= 0:
		return 0
	var rows: Dictionary = _engaged.get(peer_id, {})
	if rows.is_empty():
		return 0
	var exclude_id: int = exclude.get_instance_id() if exclude != null else 0
	var count: int = 0
	var stale: Array[int] = []
	for id: int in rows:
		# Self-healing, and the reason this keeps the live scan's guarantee: an enemy freed without
		# passing through `_exit_tree()` leaves a row that is dropped the next time anyone counts,
		# rather than inflating the cap forever.
		if not is_instance_id_valid(id):
			stale.append(id)
			continue
		if id == exclude_id:
			continue
		if StringName(rows[id]) == kind_id:
			count += 1
	for id: int in stale:
		_forget(id)
	return count


## Rows currently held, for checks that assert the ledger does not leak.
func engagement_row_count() -> int:
	var total: int = 0
	for peer_id: int in _engaged:
		total += (_engaged[peer_id] as Dictionary).size()
	return total


func _forget(id: int) -> void:
	var peer_id: int = int(_engaged_peer.get(id, 0))
	_engaged_peer.erase(id)
	if peer_id == 0:
		return
	var rows: Dictionary = _engaged.get(peer_id, {})
	rows.erase(id)
	if rows.is_empty():
		_engaged.erase(peer_id)


func _clear_engagements() -> void:
	_engaged.clear()
	_engaged_peer.clear()
