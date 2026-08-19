extends Node

## PlayerHealth — autoload. Host-keyed hp/downed/bleed-out/respawn per peer, plus the confirmed
## local snapshot and the broadcast downed flag task 2.5's inventory pattern already proved out.
## Task 3.8 extended this file rather than adding a new service for hunger or stamina — see each
## section's own authority note below.
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2): player health and hunger are HOST — hunger drains
## on the host tick and empty hunger drains hp through the exact same state machine a melee hit does.
## Downed/revive is HOST-VALIDATED — a client's hold duration is presentation only, the same split
## D-034 uses for melee (the swing wind-up runs client-local, the hit is host-resolved). Death/downed
## PRESENTATION (crawl, blocked input) is client-local, driven off the replicated flags.
##
## Stamina is a THIRD row, deliberately different from hp/hunger: it lives under "own player
## movement" (§2.2 row 1, CLIENT) because it gates sprint/jump/dodge, and gating a client's own
## movement from the host would reintroduce the input lag every other client-authoritative system
## here exists to avoid. The owning client is the only thing that drains or regenerates its own
## stamina, every physics tick, via local_tick_stamina() — see that method's own note. The host keeps
## a best-effort copy per peer, refreshed by a periodic unreliable report, so a later host-validated
## consumer (3.8b's dodge i-frames) or a future teammate HUD has something recent to read; the host
## never drives stamina gating itself, and this reconciliation is advisory, not authoritative.
##
## Food is a consumable ItemDef (category CONSUMABLE, task 3.8's hunger_restore/hp_restore fields)
## used through request_consume_item() — a host request that removes exactly one item via
## InventoryService.host_transaction() (reuse the crafting seam, do not reinvent it) and only then
## applies the restore, so a rejected transaction never pays out an effect.
##
## Damage comes IN two ways, both host-only:
##   · The shared melee seam (2.8) — entities/player/player_controller.gd joins &"damageable" and
##     forwards its host_apply_damage() call here, keyed by its own multiplayer authority.
##   · EventBus.enemy_attack_landed — 2.10's enemies emit it on a landed hit; this file is the
##     subscriber that seam was built for (see systems/enemies/enemy.gd's own note on the event).
##     enemy_attack_landed_subscriber_count() proves that wiring exists rather than trusting it.
##     Task 3.8b's dodge i-frames gate exactly this path — _on_enemy_attack_landed() checks the
##     dodging peer's replicated flag (_is_dodging()) before ever reaching host_apply_damage(), so a
##     dodge answers enemy melee only, never starvation or a future hazard routed through the shared
##     host_apply_damage() entry point directly.
##
## Replication mirrors autoload/inventory_service.gd (D-035-safe): an owner-only reliable snapshot
## carries the full hp/state/hunger, and a broadcast bool carries just "is this peer downed" to
## everyone — teammates have to see who needs help, but nobody else needs a stranger's exact hp.
## Hunger piggybacks the same snapshot RPC as hp rather than a second channel: published immediately
## on a discrete event (damage, revive, consume) and otherwise throttled to
## HUNGER_SNAPSHOT_INTERVAL_SEC so a continuous per-tick drain does not turn into a 60 Hz reliable
## RPC (day_night.gd's REPLICATE_INTERVAL_SEC is the same shape of fix for the same reason).

const DOWNED_STATE := preload("res://systems/health/downed_state.gd")
const EVENT_BUS := preload("res://core/events/event_bus.gd")
## F-055 resolved: mire_log.gd gained a dedicated channel this task, so damage/downed/revive/
## hunger/consume lines no longer share `combat`'s firehose.
const LOG_CHANNEL: StringName = &"health"
## Task 4.11: Blight — standing in Mire corruption drains hp through the SAME
## DownedState.apply_damage() transition path starvation already uses, so it can down a player like
## anything else, not a separate death rule. Below this MireGrid.corruption_at() reading, a player is
## just standing on tainted but non-lethal ground.
const BLIGHT_CORRUPTION_THRESHOLD: float = 0.15
## Scales linearly with corruption (0..1) above the threshold — full corruption drains this many
## hp/sec, matching starvation_hp_drain_per_sec's own placeholder-tuned status.
const BLIGHT_HP_DRAIN_PER_SEC_AT_FULL_CORRUPTION: float = 4.0
## Host tick throttle for hunger-only snapshot pushes — see the class doc above.
const HUNGER_SNAPSHOT_INTERVAL_SEC: float = 1.0

@export_group("Tuning")
## Full health at spawn and at respawn. Not a run-scoped stat yet (DESIGN.md §4.6: Salvage never
## unlocks +health) — this is the M2 flat value every player starts and returns to.
@export_range(1, 500, 1) var max_hp: int = 100
## DESIGN.md §4.5 "Downed, not dead" — how long a downed player can be revived before dying.
## Gamerule `bleed_out_seconds` (task 3.14) — export stays as the COMMANDS.md §4.3 fallback,
## adopted by `_bind_rules()`. Read at the moment a player goes down, so a change mid-bleed does not
## retroactively lengthen or shorten a timer already counting.
@export_range(1.0, 120.0, 1.0) var bleed_out_seconds: float = 30.0
## How long a teammate must hold interact next to a downed player to revive them.
## Gamerule `revive_seconds` (task 3.14) — same export-fallback shape. Adopting into the property
## rather than reading the service at the call site matters here specifically: the reviving player's
## own controller reads it off this autoload by name (`health.get(&"revive_seconds")`,
## entities/player/player_controller.gd), and that read happens on the CLIENT. Replication is what
## makes the client's local hold timer agree with the host's range check instead of drifting the
## moment somebody retunes the rule.
@export_range(0.5, 15.0, 0.5) var revive_seconds: float = 3.0
## How close a reviver must stay, re-checked by the host at the moment the request lands.
@export_range(0.5, 10.0, 0.1) var revive_radius_m: float = 3.0
## Fraction of max_hp restored by a successful revive.
@export_range(0.05, 1.0, 0.05) var revive_hp_fraction: float = 0.5
## How long a dead player waits before respawning at full hp. M2 rule: a solo death just respawns —
## there is no run-fail state yet (task 6.7 owns the lose condition).
@export_range(0.5, 30.0, 0.5) var respawn_seconds: float = 5.0

@export_group("Hunger")
## Full hunger at spawn/respawn. HOST-authoritative (§2.2) — never regenerates on its own, only
## eating restores it.
@export_range(1.0, 500.0, 1.0) var max_hunger: float = 100.0
## Drain rate. The default empties a full bar over 20 minutes (100 / 1200 s) with nothing eaten.
## Gamerule `hunger_drain_per_sec` (task 3.14) — same export-fallback shape. This one is read every
## physics tick, which is the reason the whole first wave adopts into exports instead of calling the
## service per use: a cross-autoload `.call()` in the hunger tick would be a per-frame cost on the
## low-end machines this project targets, for a value that changes a handful of times a session.
@export_range(0.0, 10.0, 0.01) var hunger_drain_per_sec: float = 0.0833
## Hp lost per second once hunger is at zero, accumulated as a float and applied in whole points
## through DownedState.apply_damage() — the same path a melee hit uses, so starving can down a
## player exactly like anything else, not a separate death rule.
@export_range(0.0, 20.0, 0.1) var starvation_hp_drain_per_sec: float = 1.0

@export_group("Stamina")
## Full stamina. CLIENT-LOCAL (§2.2 row 1) — see the class doc's Stamina paragraph.
@export_range(1.0, 500.0, 1.0) var max_stamina: float = 100.0
@export_range(0.0, 200.0, 1.0) var stamina_drain_per_sec: float = 25.0
@export_range(0.0, 200.0, 1.0) var stamina_regen_per_sec: float = 18.0
## Discrete cost of one jump. Sprint's cost is continuous (stamina_drain_per_sec while moving).
@export_range(0.0, 200.0, 1.0) var jump_stamina_cost: float = 12.0
## How often the owning client reports its own stamina to the host for reconciliation — advisory
## only, see the class doc.
@export_range(0.1, 10.0, 0.1) var stamina_reconcile_interval_sec: float = 2.0
## Once stamina hits zero, sprint stays locked out until it regenerates back above this fraction of
## max — see local_tick_stamina()'s note on why a bare "> 0" gate flickers at the boundary.
@export_range(0.0, 1.0, 0.01) var sprint_resume_fraction: float = 0.15

## Owner-only presentation snapshot. downed/dead are DOWNED_STATE.State ints.
signal local_health_changed(hp: int, max_hp: int, state: int, bleed_out_remaining: float)
## Owner-only presentation snapshot for hunger, published on the same cadence as local_health_changed
## (see HUNGER_SNAPSHOT_INTERVAL_SEC).
signal local_hunger_changed(hunger: float, max_hunger: float)
## Owner-only, updated every physics tick by the owning client itself — see local_tick_stamina().
signal local_stamina_changed(stamina: float, max_stamina: float)
## Host-side observer hook, mirrors InventoryService.host_inventory_changed — checks and any future
## host-only HUD read this instead of reaching into the private state dictionary.
signal host_health_changed(peer_id: int, hp: int, max_hp: int, state: int, revision: int)
## Host-side observer hook for the periodic, advisory stamina report — see the class doc.
signal host_stamina_reported(peer_id: int, stamina: float)
## Broadcast to every peer, including the downed peer itself: teammates must see who needs help.
signal downed_flag_changed(peer_id: int, downed: bool)
## Feedback for a revive request, owner-only. Mirrors InventoryService.operation_confirmed.
signal revive_confirmed(request_id: int, accepted: bool, detail: String)
## Feedback for a consume-item request, owner-only. Same shape as revive_confirmed.
signal consume_confirmed(request_id: int, accepted: bool, detail: String)

## Host-owned. peer_id -> DownedState.
var _states: Dictionary[int, RefCounted] = {}
var _revisions: Dictionary[int, int] = {}
## Host-owned hunger per peer, ticked alongside _states in _physics_process.
var _hunger: Dictionary[int, float] = {}
## Fractional starvation damage carried between ticks so a slow drain still lands whole-point hits.
var _starvation_accum: Dictionary[int, float] = {}
## Fractional Blight damage carried between ticks — same shape as _starvation_accum, see
## _tick_blight()'s own note.
var _blight_accum: Dictionary[int, float] = {}
## Cached MireGrid ref (F-099 — _tick_blight runs every physics tick per tracked peer). Path-resolved
## since MireGrid registers after this autoload (F-011).
var _mire_grid_node: Node
## Host-owned, advisory only: the last stamina value each peer reported. Never used to gate anything
## — see the class doc's Stamina paragraph.
var _host_stamina_reports: Dictionary[int, float] = {}
## Every peer's last-known downed flag, from the broadcast — read by any peer, including the host
## (kept in step with _states so callers do not need to branch on who they are).
var _downed_flags: Dictionary[int, bool] = {}
## The transform PlayerNet spawned each peer at, captured off PlayerNet.player_spawned. Respawn
## returns a player here rather than to wherever they happened to die.
var _spawn_transforms: Dictionary[int, Dictionary] = {}
## F-063: player_spawned only ever fires inside a session, so offline this dictionary would stay
## empty forever. Latched the first tick a local body exists so the offline capture below can never
## run twice and record a walked-to position as if it were the spawn.
var _local_spawn_captured: bool = false

var _local_hp: int = 0
var _local_max_hp: int = 0
var _local_state: int = DOWNED_STATE.State.ALIVE
var _local_bleed_out_remaining: float = 0.0
var _local_hunger: float = 0.0
var _local_max_hunger: float = 0.0
var _local_stamina: float = 0.0
## True from the instant local_tick_stamina() drains stamina to exactly zero until it regenerates
## back above sprint_resume_fraction of max — see local_can_sprint()'s note.
var _sprint_locked_out: bool = false
var _local_revision: int = -1
var _next_request_id: int = 1
var _session_open: bool = false
## Cached transport ref (F-099) — _owns_mutation() runs every physics tick. Path-resolved (F-011).
var _transport_node: Node
var _hunger_snapshot_elapsed: float = 0.0
var _stamina_reconcile_elapsed: float = 0.0


func _ready() -> void:
	_reset_local_cache()
	EVENT_BUS.subscribe_enemy_attack_landed(_on_enemy_attack_landed)
	_connect_player_net()

	var transport: Node = _transport()
	transport.get("server_started").connect(_on_session_opened)
	transport.get("connected_to_host").connect(_on_session_opened)
	transport.get("disconnected").connect(_on_disconnected)
	transport.get("peer_joined").connect(_on_peer_joined)
	transport.get("peer_left").connect(_on_peer_left)
	# F-032/D-035: NetSession owns run-player identity, so it decides when a departure is final.
	# Connected by path rather than by identifier because this autoload is reached from --script
	# harnesses (F-011), and guarded because a harness may drive PlayerHealth with no session layer.
	var session: Node = get_node_or_null(^"/root/NetSession")
	if session != null and session.has_signal(&"run_player_rebound"):
		session.connect(&"run_player_rebound", _on_run_player_rebound)
		session.connect(&"run_player_expired", _on_run_player_expired)

	_bind_rules()

	set_physics_process(true)
	if bool(transport.call("is_active")):
		_on_session_opened.call_deferred()
	else:
		_ensure_host_state(NetConfig.HOST_PEER_ID)
		_publish_snapshot(NetConfig.HOST_PEER_ID)
	_register_commands()



func _exit_tree() -> void:
	EVENT_BUS.unsubscribe_enemy_attack_landed(_on_enemy_attack_landed)


# ── Physics tick (host-owned bleed-out / respawn timers) ─────────────────────────────────────────


func _physics_process(delta: float) -> void:
	if not _owns_mutation() or _states.is_empty():
		return
	_capture_local_spawn_transform()
	_hunger_snapshot_elapsed += delta
	var publish_hunger: bool = _hunger_snapshot_elapsed >= HUNGER_SNAPSHOT_INTERVAL_SEC
	if publish_hunger:
		_hunger_snapshot_elapsed = 0.0
	# Iterated directly — nothing in the loop erases from _states, and .keys() allocates a fresh
	# Array every physics tick (F-099).
	for peer_id: int in _states:
		var downed_state: DOWNED_STATE = _states[peer_id]
		var starved: bool = _tick_hunger(peer_id, downed_state, delta)
		var blighted: bool = _tick_blight(peer_id, downed_state, delta)
		var transition: int = downed_state.tick(delta, respawn_seconds)
		match transition:
			DOWNED_STATE.Transition.DIED:
				MireLog.info(LOG_CHANNEL, "PlayerHealth: peer %d bled out" % peer_id)
				_commit(peer_id)
				continue
			DOWNED_STATE.Transition.RESPAWNED:
				MireLog.info(LOG_CHANNEL, "PlayerHealth: peer %d respawning" % peer_id)
				# A fresh respawn should not start starving — or Blighted — immediately.
				_hunger[peer_id] = max_hunger
				_starvation_accum[peer_id] = 0.0
				_blight_accum[peer_id] = 0.0
				_commit(peer_id)
				_teleport_to_spawn(peer_id)
				continue
		if starved or blighted or publish_hunger:
			_commit(peer_id)


## Host-only, called once per peer per tick from _physics_process. Drains hunger unconditionally and,
## once it is empty, accumulates starvation damage in fractional seconds and applies it in whole
## points through the SAME transition path a melee hit uses (DownedState.apply_damage), so starving
## can down a player like anything else. Returns true only when a starvation hit actually landed —
## _physics_process uses that to force an immediate snapshot instead of waiting for the throttled one.
##
## Prorates against the PREVIOUS hunger value, not the whole delta: a tick spanning both "still had
## some hunger left" and "ran out partway through" (an oversized single step — a real engine hitch, or
## a check fast-forwarding many seconds at once, per tools/player_vitals_check.gd) must only charge
## starvation for the fraction of the tick actually spent at zero, or a big-enough delta could apply
## years of accumulated starvation damage in a single frame.
func _tick_hunger(peer_id: int, downed_state: DOWNED_STATE, delta: float) -> bool:
	var previous_hunger: float = float(_hunger.get(peer_id, max_hunger))
	var next_hunger: float = maxf(previous_hunger - hunger_drain_per_sec * delta, 0.0)
	_hunger[peer_id] = next_hunger
	if next_hunger > 0.0 or not downed_state.is_alive():
		_starvation_accum[peer_id] = 0.0
		return false
	var empty_seconds: float = delta
	if previous_hunger > 0.0 and hunger_drain_per_sec > 0.0:
		empty_seconds = maxf(delta - previous_hunger / hunger_drain_per_sec, 0.0)
	var accum: float = float(_starvation_accum.get(peer_id, 0.0)) + starvation_hp_drain_per_sec * empty_seconds
	var whole: int = int(accum)
	if whole <= 0:
		_starvation_accum[peer_id] = accum
		return false
	_starvation_accum[peer_id] = accum - float(whole)
	var transition: int = downed_state.apply_damage(whole, bleed_out_seconds)
	if transition == DOWNED_STATE.Transition.WENT_DOWN:
		MireLog.info(LOG_CHANNEL, "PlayerHealth: peer %d starved down" % peer_id)
	return true


# ── The damage seam (shared with 2.8's &"damageable" group, and 2.10's enemy hits) ───────────────


## Host-only. entities/player/player_controller.gd forwards its own host_apply_damage() call here.
## Returns false while downed or dead (no corpse-kicking in M2) or for an unknown peer — CombatService
## treats false as a miss, not a phantom hit.
func host_apply_damage(peer_id: int, amount: int, instigator_peer_id: int) -> bool:
	if not _owns_mutation() or amount <= 0 or not _states.has(peer_id):
		return false
	var downed_state: DOWNED_STATE = _states[peer_id]
	if not downed_state.is_alive():
		return false
	var transition: int = downed_state.apply_damage(amount, bleed_out_seconds)
	_commit(peer_id)
	if transition == DOWNED_STATE.Transition.WENT_DOWN:
		MireLog.info(LOG_CHANNEL, "PlayerHealth: peer %d downed (instigator %d)" % [
			peer_id, instigator_peer_id
		])
	return true


func _on_enemy_attack_landed(
	_enemy_id: StringName, peer_id: int, damage: int, _world_position: Vector3
) -> void:
	if not _owns_mutation() or peer_id <= 0:
		return
	# Task 3.8b's i-frames: enemy melee ONLY (this event), never a check inside host_apply_damage
	# itself — that seam is shared with starvation, future hazards, and anything else that might land
	# on a player, and DESIGN.md/SPECS.md's dodge only ever promised to answer an enemy's hit.
	if _is_dodging(peer_id):
		MireLog.info(LOG_CHANNEL, "PlayerHealth: peer %d dodged an enemy hit" % peer_id)
		return
	# instigator 0: no player threw this hit. host_apply_damage's instigator arg is only ever used
	# for logging today; 0 is never a valid peer id so it reads unambiguously as "an enemy."
	host_apply_damage(peer_id, damage, 0)


## The i-frame DECISION (host-side, per task 3.8b's spec) reading the i-frame STATE (client-side,
## replicated). `dodging` lives on entities/player/player_controller.gd, replicated ALWAYS on the same
## synchronizer as position — see that file's own note on why ALWAYS and not ON_CHANGE. Trusted the
## same way position already is (§2.2 row 1: own movement is client authority); D-039's "cheating is
## irrelevant among friends" already covers a player lying about their own dodge state exactly the way
## it covers speed-hacking their own position.
func _is_dodging(peer_id: int) -> bool:
	var body: Node3D = _player_body(peer_id)
	return body != null and bool(body.get(&"dodging"))


# ── Consume item — food, task 3.8 ─────────────────────────────────────────────────────────────────


## Client request to eat/use a consumable item id. Mirrors request_revive()'s shape exactly: returns
## a local request id immediately, completion always arrives through consume_confirmed. Nothing is
## predicted — the item does not disappear from the UI until the host's inventory snapshot says so.
func request_consume_item(item_id: StringName) -> int:
	var request_id: int = _take_request_id()
	if _owns_mutation():
		_process_consume_request(_local_peer_id(), item_id, request_id)
	elif bool(_transport().call("is_active")):
		net_request_consume_item.rpc_id(NetConfig.HOST_PEER_ID, item_id, request_id)
	else:
		consume_confirmed.emit(request_id, false, "no authoritative session")
	return request_id


@rpc("any_peer", "call_remote", "reliable")
func net_request_consume_item(item_id: StringName, request_id: int) -> void:
	if not bool(_transport().call("is_host")):
		return
	_process_consume_request(multiplayer.get_remote_sender_id(), item_id, request_id)


@rpc("authority", "call_remote", "reliable")
func net_consume_confirmed(request_id: int, accepted: bool, detail: String) -> void:
	consume_confirmed.emit(request_id, accepted, detail)


func _process_consume_request(peer_id: int, item_id: StringName, request_id: int) -> void:
	var detail: String = _validate_and_apply_consume(peer_id, item_id)
	var accepted: bool = detail.is_empty()
	_confirm_consume(
		peer_id, request_id, accepted, ("ate %s" % item_id) if accepted else detail
	)


## Host-only. Removes exactly one item through InventoryService.host_transaction() — the same
## all-or-nothing seam CraftingService commits recipes through, so a rejected removal never pays out
## an effect — then applies ItemDef.hp_restore/hunger_restore straight onto this file's own state.
## Never trusts a client-supplied amount or effect; both come from the registered ItemDef.
func _validate_and_apply_consume(peer_id: int, item_id: StringName) -> String:
	if not _owns_mutation() or peer_id <= 0 or not _states.has(peer_id):
		return "consume rejected: invalid peer"
	var downed_state: DOWNED_STATE = _states[peer_id]
	if not downed_state.is_alive():
		return "consume rejected: not able-bodied"
	var registry: Node = _registry()
	if registry == null or not bool(registry.call("has_item", item_id)):
		return "consume rejected: unknown item"
	var item: ItemDef = registry.call("get_item", item_id) as ItemDef
	if item == null or int(item.category) != ItemDef.Category.CONSUMABLE:
		return "consume rejected: not a consumable"
	var inventory: Node = _inventory()
	if inventory == null:
		return "consume rejected: no inventory service"
	var removals: Dictionary = {}
	removals[item_id] = 1
	if not bool(inventory.call("host_transaction", peer_id, removals, {})):
		return "consume rejected: item not held"
	if item.hp_restore > 0:
		downed_state.heal(item.hp_restore)
	if item.hunger_restore > 0.0:
		_hunger[peer_id] = clampf(
			float(_hunger.get(peer_id, max_hunger)) + item.hunger_restore, 0.0, max_hunger
		)
	_commit(peer_id)
	MireLog.info(LOG_CHANNEL, "PlayerHealth: peer %d ate %s" % [peer_id, item_id])
	return ""


func _confirm_consume(peer_id: int, request_id: int, accepted: bool, detail: String) -> void:
	if peer_id == _local_peer_id():
		consume_confirmed.emit(request_id, accepted, detail)
	elif bool(_transport().call("is_active")) and _peer_connected(peer_id):
		net_consume_confirmed.rpc_id(peer_id, request_id, accepted, detail)


# ── Revive — client hold is presentation, the host re-validates everything ───────────────────────


## Called by the reviving player's own controller once its local hold timer reaches revive_seconds.
## Returns a local request id immediately; completion always arrives through revive_confirmed.
func request_revive(target_peer: int) -> int:
	var request_id: int = _take_request_id()
	if _owns_mutation():
		_process_revive_request(_local_peer_id(), target_peer, request_id)
	elif bool(_transport().call("is_active")):
		net_request_revive.rpc_id(NetConfig.HOST_PEER_ID, target_peer, request_id)
	else:
		revive_confirmed.emit(request_id, false, "no authoritative session")
	return request_id


@rpc("any_peer", "call_remote", "reliable")
func net_request_revive(target_peer: int, request_id: int) -> void:
	if not bool(_transport().call("is_host")):
		return
	_process_revive_request(multiplayer.get_remote_sender_id(), target_peer, request_id)


@rpc("authority", "call_remote", "reliable")
func net_revive_confirmed(request_id: int, accepted: bool, detail: String) -> void:
	revive_confirmed.emit(request_id, accepted, detail)


func _process_revive_request(reviver_peer: int, target_peer: int, request_id: int) -> void:
	var detail: String = _validate_revive(reviver_peer, target_peer)
	var accepted: bool = detail.is_empty()
	if accepted:
		(_states[target_peer] as DOWNED_STATE).revive(revive_hp_fraction)
		_commit(target_peer)
		MireLog.info(LOG_CHANNEL, "PlayerHealth: peer %d revived peer %d" % [reviver_peer, target_peer])
	_confirm_peer(reviver_peer, request_id, accepted, "revived" if accepted else detail)


## A client cannot heal itself (reviver == target is rejected outright, before anything else is
## checked) and cannot revive at all unless it is itself able-bodied and within range NOW — the
## host's own copy of both positions, never a client-supplied distance.
func _validate_revive(reviver_peer: int, target_peer: int) -> String:
	if reviver_peer <= 0 or target_peer <= 0:
		return "revive rejected: invalid peer"
	if reviver_peer == target_peer:
		return "revive rejected: cannot revive yourself"
	if not _states.has(reviver_peer) or not (_states[reviver_peer] as DOWNED_STATE).is_alive():
		return "revive rejected: reviver is not able-bodied"
	if not _states.has(target_peer) or not (_states[target_peer] as DOWNED_STATE).is_downed():
		return "revive rejected: target is not downed"
	var reviver_body: Node3D = _player_body(reviver_peer)
	var target_body: Node3D = _player_body(target_peer)
	if reviver_body == null or target_body == null:
		return "revive rejected: player not spawned"
	if reviver_body.global_position.distance_to(target_body.global_position) > revive_radius_m:
		return "revive rejected: out of range"
	return ""


func _confirm_peer(peer_id: int, request_id: int, accepted: bool, detail: String) -> void:
	if peer_id == _local_peer_id():
		revive_confirmed.emit(request_id, accepted, detail)
	elif bool(_transport().call("is_active")) and _peer_connected(peer_id):
		net_revive_confirmed.rpc_id(peer_id, request_id, accepted, detail)


# ── Stamina — CLIENT-LOCAL (§2.2 row 1), never host-gated ─────────────────────────────────────────
# See the class doc's Stamina paragraph for why this whole section is a different authority row from
# everything else in the file. Nothing here reads or writes _states/_hunger.


func local_stamina() -> float:
	return _local_stamina


func local_max_stamina() -> float:
	return max_stamina


func local_jump_stamina_cost() -> float:
	return jump_stamina_cost


## True while there is stamina to spend AND sprint is not locked out — entities/player/
## player_controller.gd gates sprint with this before it ever asks for speed. Bare "stamina > 0"
## is deliberately not enough: see local_tick_stamina()'s note on why that flickers at zero.
func local_can_sprint() -> bool:
	return _local_stamina > 0.0 and not _sprint_locked_out


## Called every physics tick by the LOCAL player's own controller ONLY — own movement is CLIENT
## authority, so this must never run for a remote copy of another peer's body, and never for the
## host acting on someone else's behalf. Drains at stamina_drain_per_sec while [param draining] is
## true (sprinting), regenerates at stamina_regen_per_sec otherwise, and periodically reports the
## result to the host purely for reconciliation — see _report_local_stamina().
##
## Hysteresis, not a bare "> 0" gate: a player who drains to exactly zero while still holding sprint
## regenerates a little on the very next tick (this same function, called with draining=false because
## local_can_sprint() already read false that frame) — without a lockout, THAT tiny regen would read
## as "> 0" and re-enable sprint immediately, which drains it straight back to zero, forever
## alternating sprint on and off every single frame. Locking out at zero and only clearing the lock
## once stamina is back above sprint_resume_fraction of max breaks the cycle.
func local_tick_stamina(delta: float, draining: bool) -> void:
	var rate: float = -stamina_drain_per_sec if draining else stamina_regen_per_sec
	var next_stamina: float = clampf(_local_stamina + rate * delta, 0.0, max_stamina)
	if next_stamina != _local_stamina:
		_local_stamina = next_stamina
		local_stamina_changed.emit(_local_stamina, max_stamina)
	if _local_stamina <= 0.0:
		_sprint_locked_out = true
	elif _local_stamina >= max_stamina * sprint_resume_fraction:
		_sprint_locked_out = false
	_stamina_reconcile_elapsed += delta
	if _stamina_reconcile_elapsed < stamina_reconcile_interval_sec:
		return
	_stamina_reconcile_elapsed = 0.0
	_report_local_stamina()


## Discrete stamina cost — a jump, later a dodge (3.8b). Returns false and changes nothing if there
## is not enough; the caller (player_controller.gd) reads that as "the action does not happen."
func local_try_spend_stamina(amount: float) -> bool:
	if amount <= 0.0:
		return true
	if _local_stamina < amount:
		return false
	_local_stamina = clampf(_local_stamina - amount, 0.0, max_stamina)
	local_stamina_changed.emit(_local_stamina, max_stamina)
	return true


## Advisory only (see the class doc): tells the host roughly what this peer's stamina is, so a later
## host-validated consumer or a teammate HUD has something recent. The host never derives gating from
## this, so an unreliable channel and an occasional dropped report are both fine.
func _report_local_stamina() -> void:
	if _owns_mutation():
		_host_stamina_reports[_local_peer_id()] = _local_stamina
		host_stamina_reported.emit(_local_peer_id(), _local_stamina)
	elif bool(_transport().call("is_active")):
		net_report_local_stamina.rpc_id(NetConfig.HOST_PEER_ID, _local_stamina)


@rpc("any_peer", "call_remote", "unreliable")
func net_report_local_stamina(value: float) -> void:
	if not bool(_transport().call("is_host")):
		return
	var peer_id: int = multiplayer.get_remote_sender_id()
	if peer_id <= 0:
		return
	var clamped: float = clampf(value, 0.0, max_stamina)
	_host_stamina_reports[peer_id] = clamped
	host_stamina_reported.emit(peer_id, clamped)


## The host's best-effort, advisory copy of a peer's stamina — see the class doc. Defaults to full
## for a peer that has never reported, which is the safe assumption for anything reading this today
## (nothing does yet; 3.8b is the intended first consumer).
func host_stamina(peer_id: int) -> float:
	return float(_host_stamina_reports.get(peer_id, max_stamina))


# ── Respawn teleport ───────────────────────────────────────────────────────────────────────────────


## Own player movement is CLIENT authority (§2.2 row 1) — the host cannot just write another peer's
## position, so it tells that peer's own client to place itself, the same way it is the only thing
## allowed to move its own body at all.
func _teleport_to_spawn(peer_id: int) -> void:
	# F-063: this used to fall back to Vector3.ZERO, which is not a spawn point — it is wherever the
	# level author happened to put the world origin. In playtest_hollow that is 7.4 m from the real
	# spawn and 0.2 m underground. Standing a respawned player up where they fell is also wrong, but
	# it is recoverable, and it is loud in the log instead of silent.
	if not _spawn_transforms.has(peer_id):
		MireLog.warn(
			LOG_CHANNEL,
			"PlayerHealth: peer %d has no spawn transform — respawning in place" % peer_id
		)
		return
	var spawn: Dictionary = _spawn_transforms[peer_id]
	var position: Vector3 = spawn.get("position", Vector3.ZERO)
	var yaw: float = float(spawn.get("yaw", 0.0))
	if peer_id == _local_peer_id():
		_apply_respawn_transform(position, yaw)
	elif bool(_transport().call("is_active")) and _peer_connected(peer_id):
		net_force_respawn.rpc_id(peer_id, position, yaw)


## The public seam task 3.15's `tp` needs, and the reason it lives HERE rather than in
## EntityDirectory: a player's own movement is client-authoritative (ARCHITECTURE.md §2.2 row 1), so
## the host must never write a player transform — the next synchronizer tick would overwrite it and
## the teleport would look like a flaky command instead of what it is, a violation of the authority
## table. This service already had to solve that for respawn; `tp` reuses the identical mechanism
## rather than growing a second one (COMMANDS.md §3.3: commands wrap existing host seams).
##
## Returns whether the request was actually dispatched — false for an unknown/absent peer, so a
## caller can report "could not be moved" instead of claiming a move that never happened.
func host_place_player(peer_id: int, position: Vector3, yaw: float = NAN) -> bool:
	if not _owns_mutation() or peer_id <= 0:
		return false
	# NAN means "keep their current facing" — a teleport should not spin the player to face north.
	# Reading the body's own yaw where one is visible from here; the remote path passes NAN through
	# to `_apply_respawn_transform`, which leaves rotation alone for it.
	var resolved_yaw: float = yaw
	if peer_id == _local_peer_id():
		_apply_respawn_transform(position, resolved_yaw)
		return true
	if not bool(_transport().call("is_active")) or not _peer_connected(peer_id):
		return false
	net_force_respawn.rpc_id(peer_id, position, resolved_yaw)
	return true


@rpc("authority", "call_remote", "reliable")
func net_force_respawn(position: Vector3, yaw: float) -> void:
	_apply_respawn_transform(position, yaw)


func _apply_respawn_transform(position: Vector3, yaw: float) -> void:
	var body := _local_player_body() as CharacterBody3D
	if body == null:
		return
	body.position = position
	# NAN is host_place_player()'s "keep their current facing". Respawn always passes a real yaw, so
	# its behaviour is unchanged; a `tp` should move a player without also spinning them.
	if not is_nan(yaw):
		body.rotation.y = yaw
	body.velocity = Vector3.ZERO


## F-063. PlayerNet only spawns bodies inside a session — offline it leaves the level's hand-placed
## Player exactly where it is (see its own _claim_spawn_point note), so player_spawned never fires
## and nothing else ever writes _spawn_transforms. That is the configuration task 2.9's gate is
## played in, and it is why the check for this file never caught it: the check calls
## _on_player_spawned by hand, simulating a signal the real offline game does not emit.
##
## Capture it here instead, on the first physics tick a local body exists. That tick is the frame the
## level's own Player was ready on, before the player has walked anywhere, so it is the same
## transform PlayerNet would have read off that node had a session been open. Latched, so a body that
## appears later (a respawn teleport, a level reload) can never overwrite a real spawn with a
## walked-to position. In a session this is a no-op: player_spawned has already filled the entry.
func _capture_local_spawn_transform() -> void:
	if _local_spawn_captured:
		return
	var body: Node3D = _local_player_body()
	if body == null:
		return
	_local_spawn_captured = true
	var peer_id: int = _local_peer_id()
	if _spawn_transforms.has(peer_id):
		return
	_spawn_transforms[peer_id] = {"position": body.position, "yaw": body.rotation.y}


func _connect_player_net() -> void:
	var player_net: Node = get_node_or_null(^"/root/PlayerNet")
	if player_net != null and player_net.has_signal(&"player_spawned"):
		player_net.connect(&"player_spawned", _on_player_spawned)


## PlayerNet sets position/rotation on the body before add_child (see its own _net_spawn_player), so
## this signal — fired during that same add_child — already carries the real spawn transform.
func _on_player_spawned(peer_id: int, body: Node3D) -> void:
	_spawn_transforms[peer_id] = {"position": body.position, "yaw": body.rotation.y}


# ── Read API ───────────────────────────────────────────────────────────────────────────────────────


func local_hp() -> int:
	return _local_hp


func local_max_hp() -> int:
	return _local_max_hp


func local_is_downed() -> bool:
	return _local_state == DOWNED_STATE.State.DOWNED


func local_is_dead() -> bool:
	return _local_state == DOWNED_STATE.State.DEAD


func local_is_alive() -> bool:
	return _local_state == DOWNED_STATE.State.ALIVE


func local_bleed_out_remaining() -> float:
	return _local_bleed_out_remaining


func local_revision() -> int:
	return _local_revision


func local_hunger() -> float:
	return _local_hunger


func local_max_hunger() -> float:
	return _local_max_hunger


## What the broadcast flag last said about [param peer_id] — the host's own truth included, so
## callers never have to special-case "am I the host". Unknown peers read as not-downed.
func is_downed_known(peer_id: int) -> bool:
	return bool(_downed_flags.get(peer_id, false))


func host_hp(peer_id: int) -> int:
	if not _owns_mutation() or not _states.has(peer_id):
		return 0
	return int((_states[peer_id] as DOWNED_STATE).hp)


func host_is_downed(peer_id: int) -> bool:
	if not _owns_mutation() or not _states.has(peer_id):
		return false
	return bool((_states[peer_id] as DOWNED_STATE).is_downed())


func host_is_dead(peer_id: int) -> bool:
	if not _owns_mutation() or not _states.has(peer_id):
		return false
	return bool((_states[peer_id] as DOWNED_STATE).is_dead())


func host_is_alive(peer_id: int) -> bool:
	if not _owns_mutation() or not _states.has(peer_id):
		return false
	return bool((_states[peer_id] as DOWNED_STATE).is_alive())


func host_bleed_out_remaining(peer_id: int) -> float:
	if not _owns_mutation() or not _states.has(peer_id):
		return 0.0
	return float((_states[peer_id] as DOWNED_STATE).bleed_out_remaining)


func host_hunger(peer_id: int) -> float:
	if not _owns_mutation() or not _hunger.has(peer_id):
		return 0.0
	return float(_hunger[peer_id])


# ── Session lifecycle (mirrors autoload/inventory_service.gd) ────────────────────────────────────


func _on_session_opened() -> void:
	if _session_open:
		return
	_session_open = true
	# F-063: a session replaces every body in the level, so the offline capture has to be re-armed —
	# PlayerNet.player_spawned will normally beat it to the punch now, which is exactly the intent.
	_local_spawn_captured = false
	_states.clear()
	_revisions.clear()
	_clear_downed_flags()
	_hunger.clear()
	_starvation_accum.clear()
	_blight_accum.clear()
	_host_stamina_reports.clear()
	_reset_local_cache()
	if not bool(_transport().call("is_host")):
		return
	for peer_id: int in _transport().call("peer_ids"):
		_ensure_host_state(peer_id)
		_publish_snapshot(peer_id)


func _on_peer_joined(peer_id: int) -> void:
	if not bool(_transport().call("is_host")):
		return
	_ensure_host_state(peer_id)
	_publish_snapshot(peer_id)
	# Flags only travel when they CHANGE now (see _broadcast_downed_flag), so the joiner is told who
	# is already down once, here, instead of waiting on the next change (F-099).
	if bool(_transport().call("is_active")) and _peer_connected(peer_id):
		for known_peer: int in _downed_flags:
			if known_peer != peer_id and _downed_flags[known_peer]:
				net_downed_flag.rpc_id(peer_id, known_peer, true)


## Deliberately a no-op (D-035, F-032). Between a drop and a rejoin the player is still a player;
## NetSession decides which of run_player_rebound/run_player_expired actually applies. Same shape as
## InventoryService._on_peer_left — see its comment for the fuller story.
func _on_peer_left(_peer_id: int) -> void:
	pass


func _on_run_player_rebound(old_peer_id: int, new_peer_id: int) -> void:
	if not _owns_mutation() or not _states.has(old_peer_id):
		return
	_states[new_peer_id] = _states[old_peer_id]
	_revisions[new_peer_id] = int(_revisions.get(old_peer_id, 0))
	_states.erase(old_peer_id)
	_revisions.erase(old_peer_id)
	_hunger[new_peer_id] = float(_hunger.get(old_peer_id, max_hunger))
	_hunger.erase(old_peer_id)
	_starvation_accum[new_peer_id] = float(_starvation_accum.get(old_peer_id, 0.0))
	_starvation_accum.erase(old_peer_id)
	_blight_accum[new_peer_id] = float(_blight_accum.get(old_peer_id, 0.0))
	_blight_accum.erase(old_peer_id)
	if _host_stamina_reports.has(old_peer_id):
		_host_stamina_reports[new_peer_id] = _host_stamina_reports[old_peer_id]
		_host_stamina_reports.erase(old_peer_id)
	if _spawn_transforms.has(old_peer_id):
		_spawn_transforms[new_peer_id] = _spawn_transforms[old_peer_id]
		_spawn_transforms.erase(old_peer_id)
	_publish_snapshot(new_peer_id)


func _on_run_player_expired(peer_id: int) -> void:
	if not _owns_mutation():
		return
	_states.erase(peer_id)
	_revisions.erase(peer_id)
	# An expired peer that left while downed would otherwise stay "TEAMMATE DOWN" on every client
	# forever — nothing republished its flag after the state was erased. Announce the clear.
	if bool(_downed_flags.get(peer_id, false)):
		_broadcast_downed_flag(peer_id, false)
	_downed_flags.erase(peer_id)
	_spawn_transforms.erase(peer_id)
	_hunger.erase(peer_id)
	_starvation_accum.erase(peer_id)
	_blight_accum.erase(peer_id)
	_host_stamina_reports.erase(peer_id)


func _on_disconnected() -> void:
	_session_open = false
	_local_spawn_captured = false
	_states.clear()
	_revisions.clear()
	_clear_downed_flags()
	_hunger.clear()
	_starvation_accum.clear()
	_blight_accum.clear()
	_host_stamina_reports.clear()
	_reset_local_cache()
	_ensure_host_state(NetConfig.HOST_PEER_ID)
	_publish_snapshot(NetConfig.HOST_PEER_ID)


# ── Replication ────────────────────────────────────────────────────────────────────────────────────


## Protocol version 9 (task 3.8): gained hunger/hunger_max alongside hp — see net_version.gd.
@rpc("authority", "call_remote", "reliable")
func net_health_snapshot(
	revision: int, hp: int, hp_max: int, state: int, bleed_out_remaining: float,
	hunger: float, hunger_max: float
) -> void:
	if revision < _local_revision:
		return
	_accept_local_snapshot(hp, hp_max, state, bleed_out_remaining, hunger, hunger_max, revision)


@rpc("authority", "call_remote", "reliable")
func net_downed_flag(peer_id: int, downed: bool) -> void:
	_apply_downed_flag(peer_id, downed)


func _commit(peer_id: int) -> void:
	_revisions[peer_id] = int(_revisions.get(peer_id, 0)) + 1
	_publish_snapshot(peer_id)


func _publish_snapshot(peer_id: int) -> void:
	if not _states.has(peer_id):
		return
	var downed_state: DOWNED_STATE = _states[peer_id]
	var revision: int = int(_revisions.get(peer_id, 0))
	var hunger: float = float(_hunger.get(peer_id, max_hunger))
	host_health_changed.emit(peer_id, downed_state.hp, downed_state.max_hp, downed_state.state, revision)
	if peer_id == _local_peer_id():
		_accept_local_snapshot(
			downed_state.hp, downed_state.max_hp, downed_state.state,
			downed_state.bleed_out_remaining, hunger, max_hunger, revision
		)
	elif bool(_transport().call("is_active")) and _peer_connected(peer_id):
		net_health_snapshot.rpc_id(
			peer_id, revision, downed_state.hp, downed_state.max_hp,
			downed_state.state, downed_state.bleed_out_remaining, hunger, max_hunger
		)
	_broadcast_downed_flag(peer_id, not downed_state.is_alive())


## Only a CHANGED flag is broadcast (F-099): every _publish_snapshot lands here, so the 1 Hz hunger
## publish used to re-send an unchanged flag as a reliable rpc to every peer, every second, per peer.
## A late joiner still learns the current flags — _on_peer_joined sends them once, explicitly.
func _broadcast_downed_flag(peer_id: int, downed: bool) -> void:
	if bool(_downed_flags.get(peer_id, false)) == downed:
		return
	_apply_downed_flag(peer_id, downed)
	if bool(_transport().call("is_active")):
		net_downed_flag.rpc(peer_id, downed)


func _apply_downed_flag(peer_id: int, downed: bool) -> void:
	if bool(_downed_flags.get(peer_id, false)) == downed:
		return
	_downed_flags[peer_id] = downed
	downed_flag_changed.emit(peer_id, downed)


## Flags travel only on change now (see _broadcast_downed_flag), so a silent .clear() would leave
## every subscriber showing peers that are no longer down. Announce each clear locally; the wire
## side needs nothing — each peer clears its own flags on its own session transition.
func _clear_downed_flags() -> void:
	for peer_id: int in _downed_flags.keys():
		if _downed_flags[peer_id]:
			_downed_flags[peer_id] = false
			downed_flag_changed.emit(peer_id, false)
	_downed_flags.clear()


func _accept_local_snapshot(
	hp: int, hp_max: int, state: int, bleed_out_remaining: float,
	hunger: float, hunger_max: float, revision: int
) -> void:
	_local_hp = hp
	_local_max_hp = hp_max
	_local_state = state
	_local_bleed_out_remaining = bleed_out_remaining
	_local_hunger = hunger
	_local_max_hunger = hunger_max
	_local_revision = revision
	local_health_changed.emit(hp, hp_max, state, bleed_out_remaining)
	local_hunger_changed.emit(hunger, hunger_max)


func _reset_local_cache() -> void:
	_local_hp = max_hp
	_local_max_hp = max_hp
	_local_state = DOWNED_STATE.State.ALIVE
	_local_bleed_out_remaining = 0.0
	_local_hunger = max_hunger
	_local_max_hunger = max_hunger
	_local_stamina = max_stamina
	_sprint_locked_out = false
	_local_revision = -1


# ── Shared lookups ────────────────────────────────────────────────────────────────────────────────


func _ensure_host_state(peer_id: int) -> void:
	if _states.has(peer_id):
		return
	_states[peer_id] = DOWNED_STATE.new(max_hp)
	_revisions[peer_id] = 0
	_hunger[peer_id] = max_hunger
	_starvation_accum[peer_id] = 0.0
	_blight_accum[peer_id] = 0.0


## Host-only, mirrors _tick_hunger()'s shape: fractional damage accumulated across ticks so a slow
## drain still lands whole-point hits, applied through the SAME DownedState.apply_damage() transition
## path a melee hit and starvation both already use. Reads MireGrid.corruption_at() at the player's
## OWN body position — own movement is client authority (§2.2 row 1), but the host already trusts
## that position exactly as much as every other system here does (D-039: cheating is irrelevant
## among friends). Returns true only when a Blight hit actually landed, same reason _tick_hunger
## does: _physics_process uses that to force an immediate snapshot instead of waiting on the
## throttled hunger publish.
func _tick_blight(peer_id: int, downed_state: DOWNED_STATE, delta: float) -> bool:
	if not downed_state.is_alive():
		_blight_accum[peer_id] = 0.0
		return false
	var body: Node3D = _player_body(peer_id)
	var mire_grid: Node = _mire_grid()
	if body == null or mire_grid == null:
		return false
	var corruption: float = float(mire_grid.call(&"corruption_at", body.global_position))
	if corruption < BLIGHT_CORRUPTION_THRESHOLD:
		_blight_accum[peer_id] = 0.0
		return false
	var accum: float = float(_blight_accum.get(peer_id, 0.0)) \
		+ BLIGHT_HP_DRAIN_PER_SEC_AT_FULL_CORRUPTION * corruption * delta
	var whole: int = int(accum)
	if whole <= 0:
		_blight_accum[peer_id] = accum
		return false
	_blight_accum[peer_id] = accum - float(whole)
	var transition: int = downed_state.apply_damage(whole, bleed_out_seconds)
	if transition == DOWNED_STATE.Transition.WENT_DOWN:
		MireLog.info(LOG_CHANNEL, "PlayerHealth: peer %d downed by Blight" % peer_id)
	return true


func _mire_grid() -> Node:
	if _mire_grid_node == null or not is_instance_valid(_mire_grid_node):
		_mire_grid_node = get_node_or_null(^"/root/MireGrid")
	return _mire_grid_node


func _registry() -> Node:
	return get_node_or_null(^"/root/Registry")


func _inventory() -> Node:
	return get_node_or_null(^"/root/InventoryService")


## PlayerNet.player_for() first (it knows every peer it spawned); the &"players" group second, so a
## harness that builds PlayerController nodes directly — without going through PlayerNet — still
## resolves a body. Same fallback order as systems/enemies/enemy.gd's own _player_for().
func _player_body(peer_id: int) -> Node3D:
	var player_net: Node = get_node_or_null(^"/root/PlayerNet")
	if player_net != null and player_net.has_method(&"player_for"):
		var body: Node3D = player_net.call("player_for", peer_id) as Node3D
		if body != null:
			return body
	for node: Node in get_tree().get_nodes_in_group(&"players"):
		var player := node as Node3D
		if player != null and int(player.get_multiplayer_authority()) == peer_id:
			return player
	return null


func _local_player_body() -> Node3D:
	for node: Node in get_tree().get_nodes_in_group(&"players"):
		var player := node as Node3D
		if player != null and player.is_multiplayer_authority():
			return player
	return null


func _owns_mutation() -> bool:
	var transport: Node = _transport()
	if bool(transport.call("is_host")):
		return true
	return not bool(transport.call("is_active")) and not bool(transport.call("is_connecting"))


## Guards every rpc_id(peer_id, ...) send in this file. D-035 keeps a departed peer's state alive
## through a grace window (rebind or expire, decided by NetSession) rather than releasing it on
## peer_left — which means a peer id can sit in _states/_hunger with no live transport connection
## behind it at all. Hunger's own periodic publish (HUNGER_SNAPSHOT_INTERVAL_SEC) makes this the
## likely trigger: unlike the rest of this file's RPCs, which only fire on a discrete gameplay event,
## it fires on an ambient timer for every tracked peer, so it will eventually land inside that grace
## window in any session that runs long enough. Sending rpc_id() to a peer id the transport no longer
## recognises is a Godot-level error ("Attempt to call RPC with unknown peer ID"), not a silent no-op.
func _peer_connected(peer_id: int) -> bool:
	# has_peer checks membership without the whole-array copy peer_ids() makes — this guard runs on
	# the 1 Hz hunger publish for every tracked peer (F-099).
	return bool(_transport().call("has_peer", peer_id))


func _take_request_id() -> int:
	var result: int = _next_request_id
	_next_request_id += 1
	if _next_request_id <= 0:
		_next_request_id = 1
	return result


func _local_peer_id() -> int:
	var peer_id: int = int(_transport().call("local_peer_id"))
	return peer_id if peer_id > 0 else NetConfig.HOST_PEER_ID


## COMMANDS.md §4.3's export-fallback seam — this file asks RuleService once, then listens; the
## service never reaches in here. No RuleDef or no service means the exports stand unchanged, which
## is the documented fallback rather than a failure: a harness driving PlayerHealth with no content
## loaded gets exactly today's numbers.
func _bind_rules() -> void:
	var rules: Node = get_node_or_null(^"/root/RuleService")
	if rules == null:
		return
	rules.connect(&"rule_changed", _on_rule_changed)
	if bool(rules.call("has_rule", &"bleed_out_seconds")):
		bleed_out_seconds = float(rules.call("value", &"bleed_out_seconds", bleed_out_seconds))
	if bool(rules.call("has_rule", &"revive_seconds")):
		revive_seconds = float(rules.call("value", &"revive_seconds", revive_seconds))
	if bool(rules.call("has_rule", &"hunger_drain_per_sec")):
		hunger_drain_per_sec = float(rules.call("value", &"hunger_drain_per_sec", hunger_drain_per_sec))


func _on_rule_changed(id: StringName, new_value: float) -> void:
	match id:
		&"bleed_out_seconds":
			bleed_out_seconds = new_value
		&"revive_seconds":
			revive_seconds = new_value
		&"hunger_drain_per_sec":
			hunger_drain_per_sec = new_value


func _transport() -> Node:
	if _transport_node == null or not is_instance_valid(_transport_node):
		_transport_node = get_node(^"/root/NetTransport")
	return _transport_node


# ── Commands (docs/COMMANDS.md §7 — task 3.16) ───────────────────────────────────────────────────


func _register_commands() -> void:
	var command_service: Node = get_node_or_null(^"/root/CommandService")
	if command_service == null:
		return
	command_service.call("register_spec", &"damage", {
		"scope": &"host",
		"args": [
			{"name": "target", "type": &"selector"},
			{"name": "amount", "type": &"int", "min": 1},
		],
		"handler": _cmd_damage,
		"help": "damage <selector> <n> — apply damage through the normal damage path",
	})
	command_service.call("register_spec", &"heal", {
		"scope": &"host",
		"args": [
			{"name": "target", "type": &"peer", "optional": true, "default": 0},
			{"name": "amount", "type": &"int", "optional": true, "default": 0, "min": 0},
		],
		"handler": _cmd_heal,
		"help": "heal [peer] [n] — heal a player; no amount means full",
	})
	command_service.call("register_spec", &"down", {
		"scope": &"host",
		"args": [{"name": "target", "type": &"peer", "optional": true, "default": 0}],
		"handler": _cmd_down,
		"help": "down [peer] — put a player into the downed state",
	})
	command_service.call("register_spec", &"revive", {
		"scope": &"host",
		"args": [{"name": "target", "type": &"peer", "optional": true, "default": 0}],
		"handler": _cmd_revive,
		"help": "revive [peer] — stand a downed player back up, no hold required",
	})
	command_service.call("register_spec", &"starve", {
		"scope": &"host",
		"args": [
			{"name": "target", "type": &"peer", "optional": true, "default": 0},
			{"name": "hunger", "type": &"float", "optional": true, "default": 0.0, "min": 0.0},
		],
		"handler": _cmd_starve,
		"help": "starve [peer] [hunger] — set a player's hunger; 0 means empty",
	})


## Selector-driven so it hits enemies too — `damage @e[type=enemy,r=10] 5` is the shape you actually
## want when tuning a weapon. Each entity takes it through its OWN damage seam (§3.3), which is what
## EntityDirectory's kill already established; this is the non-lethal sibling.
func _cmd_damage(ctx: Dictionary, args: Dictionary) -> Dictionary:
	var directory: Node = get_node_or_null(^"/root/EntityDirectory")
	if directory == null:
		return {"ok": false, "message": "EntityDirectory is not loaded", "data": {}}
	var amount: int = int(args.get("amount", 1))
	var issuer: int = int(ctx.get("peer_id", NetConfig.HOST_PEER_ID))
	var hit: int = 0
	for entry: Dictionary in directory.call("resolve", args.get("target", {}), ctx):
		if String(entry["kind"]) == "player":
			if host_apply_damage(int(entry["peer_id"]), amount, issuer):
				hit += 1
			continue
		var node: Node = entry["node"]
		if node.has_method(&"host_apply_damage") and bool(node.call("host_apply_damage", amount, issuer)):
			hit += 1
	return {"ok": true, "message": "damaged %d entit%s for %d" % [hit, "y" if hit == 1 else "ies", amount],
		"data": {"count": hit, "amount": amount}}


func _cmd_heal(ctx: Dictionary, args: Dictionary) -> Dictionary:
	var peer_id: int = _command_peer(ctx, args)
	var amount: int = int(args.get("amount", 0))
	var healed: int = host_heal(peer_id, amount)
	if healed < 0:
		return {"ok": false, "message": "peer %d has no health state here" % peer_id, "data": {}}
	return {"ok": true, "message": "peer %d healed %d, now %d/%d" % [
		peer_id, healed, host_hp(peer_id), max_hp
	], "data": {"peer": peer_id, "healed": healed, "hp": host_hp(peer_id)}}


## Damage rather than a "set downed" flag: going down is a CONSEQUENCE in this system, and forcing
## the flag would skip the bleed-out clock, the replication and the signals that hang off it.
func _cmd_down(ctx: Dictionary, args: Dictionary) -> Dictionary:
	var peer_id: int = _command_peer(ctx, args)
	if host_is_downed(peer_id):
		return {"ok": true, "message": "peer %d is already down" % peer_id, "data": {"peer": peer_id}}
	host_apply_damage(peer_id, maxi(host_hp(peer_id), 1), int(ctx.get("peer_id", NetConfig.HOST_PEER_ID)))
	return {"ok": host_is_downed(peer_id) or host_is_dead(peer_id),
		"message": "peer %d is down" % peer_id, "data": {"peer": peer_id}}


func _cmd_revive(ctx: Dictionary, args: Dictionary) -> Dictionary:
	var peer_id: int = _command_peer(ctx, args)
	if not host_revive(peer_id):
		return {"ok": false, "message": "peer %d is not downed" % peer_id, "data": {"peer": peer_id}}
	return {"ok": true, "message": "peer %d revived at %d hp" % [peer_id, host_hp(peer_id)],
		"data": {"peer": peer_id, "hp": host_hp(peer_id)}}


func _cmd_starve(ctx: Dictionary, args: Dictionary) -> Dictionary:
	var peer_id: int = _command_peer(ctx, args)
	var target: float = float(args.get("hunger", 0.0))
	if not host_set_hunger(peer_id, target):
		return {"ok": false, "message": "peer %d has no health state here" % peer_id, "data": {}}
	return {"ok": true, "message": "peer %d hunger %.1f/%.1f" % [peer_id, host_hunger(peer_id), max_hunger],
		"data": {"peer": peer_id, "hunger": host_hunger(peer_id)}}


func _command_peer(ctx: Dictionary, args: Dictionary) -> int:
	var requested: int = int(args.get("target", 0))
	return requested if requested > 0 else int(ctx.get("peer_id", NetConfig.HOST_PEER_ID))


# ── Small host seams the catalog needed (COMMANDS.md §7 marks these as expected) ─────────────────


## Returns how many hit points were actually restored, or -1 when this peer has no state here — so a
## caller can tell "already at full" (0) from "no such player" (-1). `amount <= 0` means full heal.
## Goes through DownedState.heal() and _commit(), the same pair every other host mutation here uses,
## so the replication and the signals are not something this seam has to remember.
func host_heal(peer_id: int, amount: int = 0) -> int:
	if not _owns_mutation() or not _states.has(peer_id):
		return -1
	var downed_state: DOWNED_STATE = _states[peer_id]
	var current: int = int(downed_state.hp)
	var restored: int = (max_hp - current) if amount <= 0 else mini(amount, max_hp - current)
	if restored <= 0:
		return 0
	if not downed_state.heal(restored):
		return 0
	_commit(peer_id)
	return restored


## The admin revive `revive <peer>` needs: no reviver, no range check, no hold. Deliberately a
## separate entry point from `_process_revive_request`, which is the GAMEPLAY path and must keep
## every one of those validations — this is not a shortcut into it, it is a different caller with
## different rights. Both end at the same `DownedState.revive()` + `_commit()`.
func host_revive(peer_id: int) -> bool:
	if not _owns_mutation() or not _states.has(peer_id):
		return false
	var downed_state: DOWNED_STATE = _states[peer_id]
	if not downed_state.is_downed():
		return false
	if not downed_state.revive(revive_hp_fraction):
		return false
	_commit(peer_id)
	MireLog.info(LOG_CHANNEL, "PlayerHealth: peer %d revived by command" % peer_id)
	return true


func host_set_hunger(peer_id: int, value: float) -> bool:
	if not _owns_mutation() or not _hunger.has(peer_id):
		return false
	_hunger[peer_id] = clampf(value, 0.0, max_hunger)
	_commit(peer_id)
	return true
