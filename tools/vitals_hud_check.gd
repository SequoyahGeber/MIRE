extends SceneTree

## F-064 proof: the 2.13 state machine is legible on screen, not just in the log.
##
## Sequoyah played the 2.9 gate, was downed, bled out and respawned twice, and reported that he had
## not died — because the only thing the HUD drew was an empty hp bar. Everything below asserts the
## thing he could not see: a banner that names the state, counts the bleed-out down, says outright
## that a teammate can pick you up, and tells a LIVING player when someone else needs them.
##
## Driven through the real PlayerHealth host path, not by emitting the HUD's signals by hand — a HUD
## test that fakes its own input proves the formatting and nothing about the wiring (the dev_loadout
## lesson again, F-052).

const DOWNED_STATE := preload("res://systems/health/downed_state.gd")
const PLAYER_SCENE: PackedScene = preload("res://entities/player/player.tscn")

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame

	# A real body, so the respawn at the end of this run has somewhere to go (F-063) and the check
	# does not sit on a warning it caused itself.
	var player: Node3D = PLAYER_SCENE.instantiate() as Node3D
	player.name = "1"
	root.add_child(player)
	await process_frame
	await process_frame

	var health: Node = root.get_node_or_null(^"PlayerHealth")
	var hud: Node = root.get_node_or_null(^"VitalsHud")
	check(health != null, "PlayerHealth autoload exists")
	check(hud != null, "VitalsHud autoload exists")
	if health == null or hud == null:
		finish()
		return

	var banner := hud.get("_banner") as Control
	var title := hud.get("_banner_title") as Label
	var detail := hud.get("_banner_detail") as Label
	check(banner != null and title != null and detail != null, "the HUD built a state banner")
	if banner == null or title == null or detail == null:
		finish()
		return

	check(not banner.visible, "an able-bodied player with nobody down sees no banner")

	# ── downed ────────────────────────────────────────────────────────────────────────────────────
	var bleed_out_seconds: float = float(health.get("bleed_out_seconds"))
	check(bool(health.call("host_apply_damage", 1, int(health.get("max_hp")), 0)),
		"a lethal hit lands on the local peer")
	check(int(health.call("local_hp")) == 0, "hp reads zero")
	check(banner.visible, "hp reaching zero puts a banner on screen (F-064)")
	check(title.text == "DOWNED", "which names the state instead of leaving it to be inferred")
	check(detail.text.contains("%ds" % int(ceil(bleed_out_seconds))),
		"and shows the bleed-out the host actually granted: '%s'" % detail.text)
	check(detail.text.to_lower().contains("revive"),
		"and says a teammate can pick you up — the one thing a downed player needs to know")

	# The countdown is client-local between snapshots; one frame of it must move.
	var before: float = float(hud.get("_bleed_out_remaining"))
	await process_frame
	await process_frame
	check(float(hud.get("_bleed_out_remaining")) < before,
		"the countdown ticks between the host's ~1 Hz snapshots instead of standing still")

	# ── dead ──────────────────────────────────────────────────────────────────────────────────────
	health.call(&"_physics_process", bleed_out_seconds + 0.1)
	check(bool(health.call("local_is_dead")), "the bleed-out expires")
	check(banner.visible and title.text == "YOU DIED",
		"death reads as death — the state Sequoyah reached twice without noticing")
	check(detail.text.to_lower().contains("respawning"), "and the respawn is announced: '%s'" % detail.text)

	# ── respawned ─────────────────────────────────────────────────────────────────────────────────
	health.call(&"_physics_process", float(health.get("respawn_seconds")) + 0.1)
	check(bool(health.call("local_is_alive")), "the player respawns")
	check(not banner.visible, "and the banner gets out of the way")

	# ── a teammate goes down ──────────────────────────────────────────────────────────────────────
	# Through the broadcast flag every peer already receives, which is how a living player learns
	# somebody needs them.
	health.call(&"_apply_downed_flag", 7, true)
	check(banner.visible, "a living player is told when a teammate goes down")
	check(title.text == "TEAMMATE DOWN", "named for the teammate, not for themselves")
	check(detail.text.to_lower().contains("revive"), "with the verb that fixes it: '%s'" % detail.text)

	health.call(&"_apply_downed_flag", 8, true)
	check(title.text == "2 TEAMMATES DOWN", "two down reads as two: '%s'" % title.text)

	health.call(&"_apply_downed_flag", 7, false)
	health.call(&"_apply_downed_flag", 8, false)
	check(not banner.visible, "and it clears when everyone is back up")

	# The local peer's own flag must never be counted as a teammate — it is broadcast to everyone,
	# including the peer it describes.
	health.call(&"_apply_downed_flag", 1, true)
	check(not banner.visible, "the local peer's own broadcast flag is not a 'teammate down'")

	print("\n%d failure(s)\n" % failures)
	finish()


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)


func finish() -> void:
	quit(0 if failures == 0 else 1)
