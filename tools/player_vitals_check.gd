extends SceneTree

## Focused offline proof for task 3.8: hunger drains on the host tick and starves a player down,
## food is eaten through a host request that removes exactly one item and applies its restore, and
## stamina is client-local — drains/regens every tick and gates sprint/jump on the owning body.
##
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/player_vitals_check.gd
##
## Timings are driven by stepping PlayerHealth's own _physics_process directly, same trick
## tools/player_health_check.gd uses — deterministic in delta, not real time.
##
## No food ItemDef is authored as real content (AGENTS.md: items are hand-authored, task 3.2's job).
## This check injects a synthetic one straight into Registry.items, the same way a hand-authored
## content/items/*.tres will look once 3.2 adds one — nothing here is content, just the framework's own
## proof that a CONSUMABLE ItemDef with hunger_restore/hp_restore works end to end.

const PLAYER_SCENE: PackedScene = preload("res://entities/player/player.tscn")
const ITEM_DEF := preload("res://systems/inventory/item_def.gd")

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame

	var health: Node = root.get_node_or_null(^"PlayerHealth")
	var inventory: Node = root.get_node_or_null(^"InventoryService")
	var registry: Node = root.get_node_or_null(^"Registry")
	check(health != null, "PlayerHealth autoload exists")
	check(inventory != null, "InventoryService autoload exists")
	check(registry != null, "Registry autoload exists")
	if health == null or inventory == null or registry == null:
		finish()
		return

	# PlayerHealth ticks its own _physics_process every real engine frame regardless of what this
	# script does — harmless for hp (nothing changes it except an explicit call) but NOT harmless for
	# hunger, which drains continuously. Left enabled, real wall-clock frames elapsing during this
	# script's own `await`s would add stray drain on top of every deliberate `.call(&"_physics_process",
	# <big delta>)` fast-forward below, making exact/approx assertions flaky under machine load. Drive
	# every tick by hand instead — same reasoning tools/day_night_check.gd's host_advance() seam exists
	# for, applied without a dedicated seam since PlayerHealth's own _physics_process already takes delta.
	health.set_physics_process(false)

	# Stamina and the controller integration run FIRST and use peer id 1 (offline's own unique id —
	# see _run_controller_integration's note). _physics_process(delta) below advances HUNGER FOR EVERY
	# TRACKED PEER AT ONCE, peer 1's own auto-created host state included — the hunger/starvation
	# sections use deltas large enough to deliberately starve their own peers down, and peer 1 would
	# starve down right along with them if it went first, taking its local ALIVE state down with it
	# and breaking the downed/dead gates _try_jump()/_apply_horizontal_movement() read. Order matters.
	_run_stamina(health)
	await _run_controller_integration(health)
	# _run_consume_flow ALSO needs peer 1 alive AND runs through InventoryService.host_add(), which
	# refuses any peer id but NetConfig.HOST_PEER_ID while offline (single-peer assumption, see its
	# own _valid_host_peer()) — so unlike hunger/starvation below, this section cannot use an
	# arbitrary synthetic peer id at all, and has to run before anything starves peer 1 down.
	_run_consume_flow(health, inventory, registry)
	_run_hunger_drain(health)
	_run_starvation(health)

	print("\n%d failure(s)\n" % failures)
	finish()


# ── Hunger drains on the host tick ────────────────────────────────────────────────────────────────


func _run_hunger_drain(health: Node) -> void:
	health.call(&"_ensure_host_state", 101)
	var max_hunger: float = float(health.get("max_hunger"))
	var drain_per_sec: float = float(health.get("hunger_drain_per_sec"))
	check(float(health.call(&"host_hunger", 101)) == max_hunger, "peer starts at full hunger")

	health.call(&"_physics_process", 10.0)
	var expected: float = maxf(max_hunger - drain_per_sec * 10.0, 0.0)
	check(is_equal_approx(float(health.call(&"host_hunger", 101)), expected),
		"10 s of host tick drains hunger by hunger_drain_per_sec (%.3f -> %.3f)" % [
			max_hunger, float(health.call(&"host_hunger", 101))
		])


# ── Empty hunger drains hp through the exact same path a melee hit uses ─────────────────────────────


func _run_starvation(health: Node) -> void:
	health.call(&"_ensure_host_state", 102)
	var max_hunger: float = float(health.get("max_hunger"))
	var drain_per_sec: float = float(health.get("hunger_drain_per_sec"))
	var starvation_per_sec: float = float(health.get("starvation_hp_drain_per_sec"))
	var max_hp: int = int(health.get("max_hp"))

	# One big step past empty hunger, same trick enemy_check/player_health_check use: the accumulator
	# is exact in delta, not in wall time. Safe as a single big step because nothing downstream has a
	# smaller timer of its own to overshoot yet — no damage has landed, so there is nothing to cascade.
	var seconds_to_empty: float = max_hunger / drain_per_sec
	health.call(&"_physics_process", seconds_to_empty + 1.0)
	check(float(health.call(&"host_hunger", 102)) == 0.0, "hunger reaches exactly zero, not negative")
	check(int(health.call(&"host_hp", 102)) < max_hp, "and starvation has already cost hp")

	# From here, step in increments smaller than bleed_out_seconds — a single _physics_process call
	# runs BOTH _tick_hunger's damage AND DownedState.tick()'s bleed-out countdown against the same
	# delta, so one step that overshoots bleed_out_seconds would cascade straight through DOWNED into
	# DEAD before this check ever observes DOWNED. Same reasoning tools/player_health_check.gd applies
	# damage as a discrete instant hit before separately fast-forwarding bleed-out in its own call.
	var step: float = 1.0
	var max_steps: int = int(float(max_hp) / starvation_per_sec / step) + 5
	for _i: int in range(max_steps):
		if bool(health.call(&"host_is_downed", 102)):
			break
		health.call(&"_physics_process", step)
	check(bool(health.call(&"host_is_downed", 102)), "sustained starvation downs a player like any other damage")


# ── Consume item — food, task 3.8 ────────────────────────────────────────────────────────────────


func _run_consume_flow(health: Node, inventory: Node, registry: Node) -> void:
	# NetConfig.HOST_PEER_ID (1), not a synthetic id: InventoryService.host_add()/host_transaction()
	# refuse any other peer id while offline (see this function's own call site note), and
	# request_consume_item() resolves the acting peer as "whoever is asking" (_local_peer_id(), which
	# is always 1 offline) — both structurally require this to be the same peer 1
	# _run_controller_integration just used, not an arbitrary id like the hunger/starvation tests use.
	var peer_id: int = NetConfig.HOST_PEER_ID
	health.call(&"_ensure_host_state", peer_id)
	var max_hp: int = int(health.get("max_hp"))
	var max_hunger: float = float(health.get("max_hunger"))

	var food := ITEM_DEF.new()
	food.id = &"test_ration"
	food.display_name = "Test Ration"
	food.category = ITEM_DEF.Category.CONSUMABLE
	food.hunger_restore = 40.0
	food.hp_restore = 15
	# .set() back explicitly, not just mutating what .get() returned — Registry's `items` is a
	# strictly-typed Dictionary, and reading it through the generic Object property API can hand back
	# a converted copy rather than the live reference, silently dropping the mutation.
	var items: Dictionary = registry.get("items")
	items[food.id] = food
	registry.set("items", items)

	# Damage and starve the peer partway so the restore is visible, then verify a rejected consume
	# BEFORE the item is even granted — "not held" has to fail cleanly, not silently succeed.
	check(bool(health.call(&"host_apply_damage", peer_id, 30, 0)), "peer takes 30 damage before eating")
	health.call(&"_physics_process", 20.0) # drains some hunger, not enough to starve

	var confirmations: Dictionary[int, Dictionary] = {}
	var on_confirmed := func(request_id: int, accepted: bool, detail: String) -> void:
		confirmations[request_id] = {"accepted": accepted, "detail": detail}
	health.connect(&"consume_confirmed", on_confirmed)

	var detail_not_held: String = String(health.call(&"_validate_and_apply_consume", peer_id, &"test_ration"))
	check(not detail_not_held.is_empty(), "eating an item not in the inventory is rejected: %s" % detail_not_held)

	var unknown_detail: String = String(health.call(&"_validate_and_apply_consume", peer_id, &"not_a_real_item"))
	check(not unknown_detail.is_empty(), "eating an unknown item id is rejected: %s" % unknown_detail)

	var non_consumable_detail: String = String(health.call(&"_validate_and_apply_consume", peer_id, &"log"))
	check(not non_consumable_detail.is_empty()
		or not bool(registry.call("has_item", &"log")),
		"eating a non-CONSUMABLE item (log) is rejected: %s" % non_consumable_detail)

	check(bool(inventory.call("host_add", peer_id, &"test_ration", 1)), "peer is granted one ration")
	var hp_before: int = int(health.call(&"host_hp", peer_id))
	var hunger_before: float = float(health.call(&"host_hunger", peer_id))
	check(hp_before < max_hp and hunger_before < max_hunger,
		"sanity: peer is genuinely damaged and hungry before eating")

	var request_id: int = int(health.call(&"request_consume_item", &"test_ration"))
	check(confirmations.has(request_id) and bool(confirmations[request_id].get("accepted", false)),
		"request_consume_item() resolves synchronously offline and is accepted: %s" % confirmations.get(request_id, {}))
	check(int(inventory.call("host_count", peer_id, &"test_ration")) == 0,
		"the ration is gone — host_transaction actually removed it")
	check(int(health.call(&"host_hp", peer_id)) == mini(hp_before + food.hp_restore, max_hp),
		"hp_restore applied and clamped to max_hp")
	check(is_equal_approx(
		float(health.call(&"host_hunger", peer_id)),
		minf(hunger_before + food.hunger_restore, max_hunger)
	), "hunger_restore applied and clamped to max_hunger")

	var second_request: int = int(health.call(&"request_consume_item", &"test_ration"))
	check(confirmations.has(second_request) and not bool(confirmations[second_request].get("accepted", true)),
		"eating again with none left is rejected")

	health.disconnect(&"consume_confirmed", on_confirmed)
	items.erase(food.id)


# ── Stamina — client-local, task 3.8 ─────────────────────────────────────────────────────────────


func _run_stamina(health: Node) -> void:
	var max_stamina: float = float(health.get("max_stamina"))
	var drain_per_sec: float = float(health.get("stamina_drain_per_sec"))
	var regen_per_sec: float = float(health.get("stamina_regen_per_sec"))
	var jump_cost: float = float(health.call(&"local_jump_stamina_cost"))

	check(float(health.call(&"local_stamina")) == max_stamina, "stamina starts full")
	check(bool(health.call(&"local_can_sprint")), "and sprinting is allowed")

	health.call(&"local_tick_stamina", max_stamina / drain_per_sec + 1.0, true)
	check(float(health.call(&"local_stamina")) == 0.0, "draining past empty clamps at zero, not negative")
	check(not bool(health.call(&"local_can_sprint")), "and sprinting is no longer allowed")
	check(not bool(health.call(&"local_try_spend_stamina", jump_cost)),
		"a discrete cost (jump) is rejected with nothing left to spend")

	health.call(&"local_tick_stamina", max_stamina / regen_per_sec + 1.0, false)
	check(float(health.call(&"local_stamina")) == max_stamina, "regen with draining=false clamps back at max")
	check(bool(health.call(&"local_try_spend_stamina", jump_cost)), "a jump is affordable again")
	check(is_equal_approx(float(health.call(&"local_stamina")), max_stamina - jump_cost),
		"and exactly jump_stamina_cost was spent, not the whole bar")


# ── player_controller.gd integration: stamina actually gates sprint and jump ────────────────────────


func _run_controller_integration(health: Node) -> void:
	# Named "1", not an arbitrary peer id: offline (no session) the unique id is always 1, and
	# is_multiplayer_authority() — which player_controller.gd's is_local_authority gates its own
	# input processing on — only reads true when the node's adopted authority matches that (see
	# player_controller.gd's _adopt_spawn_authority() and its own comment on the offline case).
	var player: CharacterBody3D = PLAYER_SCENE.instantiate() as CharacterBody3D
	player.name = "1"
	root.add_child(player)
	await process_frame
	await process_frame

	var jump_cost: float = float(health.call(&"local_jump_stamina_cost"))
	var max_stamina: float = float(health.get("max_stamina"))
	var regen_per_sec: float = float(health.get("stamina_regen_per_sec"))
	var drain_per_sec: float = float(health.get("stamina_drain_per_sec"))

	# Force a known baseline first — _run_stamina left some amount behind, and this section's whole
	# point is testing specific thresholds relative to jump_cost, not whatever's left over.
	health.call(&"local_tick_stamina", max_stamina / drain_per_sec + 1.0, true)
	check(float(health.call(&"local_stamina")) == 0.0, "known baseline: stamina is empty")

	# Regenerate to just under one jump's cost, directly through the API player_controller.gd itself
	# calls — this proves the WIRING (the controller actually asks PlayerHealth), not just the arithmetic.
	health.call(&"local_tick_stamina", (jump_cost * 0.5) / regen_per_sec, false)
	player.set(&"_time_since_jump_pressed", 0.0)
	player.set(&"_time_since_grounded", 0.0)
	var velocity_before: Vector3 = player.velocity
	player.call(&"_try_jump")
	check(player.velocity.y == velocity_before.y,
		"jump is blocked outright when stamina is under jump_stamina_cost")

	health.call(&"local_tick_stamina", max_stamina / regen_per_sec + 1.0, false)
	check(float(health.call(&"local_stamina")) == max_stamina, "stamina refilled through the real regen path")

	player.set(&"_time_since_jump_pressed", 0.0)
	player.set(&"_time_since_grounded", 0.0)
	player.call(&"_try_jump")
	check(player.velocity.y > 0.0, "and with a full bar, the exact same jump now succeeds")
	check(is_equal_approx(float(health.call(&"local_stamina")), max_stamina - jump_cost),
		"jump spent exactly jump_stamina_cost")

	# Sprint: drain to zero, hold sprint + forward, and confirm the resulting horizontal speed never
	# reaches sprint_speed — _apply_horizontal_movement is called directly with a generous delta so
	# move_toward has time to reach whatever target speed it picked.
	health.call(&"local_tick_stamina", max_stamina / drain_per_sec + 1.0, true)
	check(not bool(health.call(&"local_can_sprint")), "stamina is empty going into the sprint check")
	Input.action_press(&"sprint")
	Input.action_press(&"move_forward")
	for _i: int in range(30):
		player.call(&"_apply_horizontal_movement", 1.0 / 60.0)
	var walk_speed: float = float(player.get("walk_speed"))
	var sprint_speed: float = float(player.get("sprint_speed"))
	var horizontal_speed: float = Vector2(player.velocity.x, player.velocity.z).length()
	check(horizontal_speed <= walk_speed + 0.05 and horizontal_speed < sprint_speed - 0.5,
		"out of stamina, holding sprint still only reaches walk speed (%.2f, walk=%.2f, sprint=%.2f)" % [
			horizontal_speed, walk_speed, sprint_speed
		])
	Input.action_release(&"sprint")
	Input.action_release(&"move_forward")

	player.queue_free()


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
