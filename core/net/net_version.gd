class_name NetVersion
extends RefCounted

## Protocol/build version handshake — docs/ARCHITECTURE.md §2.2, task 1.11.
##
## The problem this exists to prevent: two builds that disagree about the wire format (a replicated
## property added/removed/reordered, an RPC signature change, a SceneReplicationConfig change) do not
## fail loudly. They connect fine at the ENet/Steam layer — that handshake only agrees on transport,
## never on payload shape — and then desync silently: wrong values read off the wire, or a client that
## quietly drops every packet from the mismatched peer. That failure mode is expensive to diagnose,
## because everything upstream of it (host(), join(), connected_to_host) reports success.
##
## Constants only, deliberately — same reasoning as NetConfig: this has to be byte-identical in the
## host process and every client process, so nothing here should be able to branch or drift.
##
## Network authority (§2.2): none of its own — this is infrastructure, not simulated state. The one
## authority fact worth stating: the HOST is the arbiter. A client never rejects the host for running a
## different version; it only ever reports itself and accepts whatever the host decides, because the
## host is what the rest of §2.2's table already trusts to be right.


## Bump this whenever a change would desync two builds without either side noticing on its own:
##   · a replicated property added, removed, reordered, or its REPLICATION_MODE changed
##   · an RPC's name, argument order, or @rpc config (any_peer/authority, reliable/unreliable) changed
##   · SceneReplicationConfig itself changed for any synced node
## Bump it even when nothing else about the release changed — a stale peer must never connect to a
## maintained one and desync instead of being told to update. There is no compatibility window: this
## project ships from source control, not distributed binaries with staggered rollout, so "N and N+1
## interoperate" is a guarantee nobody needs and nobody should spend effort keeping true.
##
## 7 (task 2.13): systems/health/player_health.gd added three RPCs — net_request_revive,
## net_health_snapshot, net_downed_flag — and net_force_respawn.
## 8 (task 2.11): systems/environment/day_night.gd added net_push_time, the host -> client
## time-of-day broadcast.
## 9 (task 3.8): systems/health/player_health.gd's net_health_snapshot gained two arguments
## (hunger, hunger_max), and it added two new RPCs — net_request_consume_item/net_consume_confirmed
## (food) and net_report_local_stamina (advisory client -> host stamina reconciliation).
## 10 (task 3.5): systems/loot/chest.gd added net_request_open and net_open_result, the chest-opening
## request/grant pair.
## 11 (task 3.3): autoload/powerup_service.gd added net_powerup_snapshot (host -> the owning peer,
## its own full powerup id -> stacks map) and net_powerup_counts (host -> everyone, per-peer
## per-family counts only). Both reliable: a dropped grant is a powerup the player paid for and
## does not have.
## 12 (task 3.6): autoload/build_service.gd added net_request_place and net_request_destroy
## (client -> host build requests) and net_build_result (host -> the one requester). All reliable:
## a dropped build request is a player pressing the button and nothing happening.
## 13 (task 3.10): systems/hauling/haulable.gd added net_request_pickup/net_pickup_result and
## net_request_drop/net_drop_result (client -> host carry requests, host -> requester grants), plus
## its own SceneReplicationConfig (position ALWAYS, carriers ON_CHANGE) — the first wire shape a
## carryable object ever put on the network.
## 14 (task 3.9): autoload/attunement_service.gd added net_request_attunement (client -> host),
## net_attunement_confirmed (host -> the requester only), and net_attunement_selected (host -> a
## full broadcast of one peer's pick, or &"" to retire it). All reliable: a dropped message must
## never leave a role pick unmade or a stale role visible after a reconnect/expiry.
## 15 (task 3.8b): entities/player/player_controller.gd added a fourth REPLICATION_MODE_ALWAYS
## property, `dodging`, to the player's existing position/rotation SceneReplicationConfig — the
## host's dodge i-frame decision (systems/health/player_health.gd's _on_enemy_attack_landed()) reads
## it off that synchronizer, not a new RPC.
## 16 (task 3.13): autoload/command_service.gd added net_submit_command (client -> host, a raw
## console line + a request id) and net_command_result (host -> the one requester, its CommandResult).
## The command framework's whole trust model is the host re-parsing that raw line from scratch, so
## the wire shape is deliberately just one String — no client-parsed structure ever crosses the RPC.
## 17 (task 3.14): autoload/rule_service.gd added net_rule_snapshot (host -> one joining peer, the
## full gamerule id -> value map) and net_rule_changed (host -> everyone, one id and its new value).
## Both reliable: a dropped rule change leaves two machines simulating different games, and it is the
## kind of disagreement nobody notices until the consequence lands (a night that falls on one screen
## and not the other).
## 18 (task 4.6): autoload/world_delta_log.gd added net_world_snapshot (host -> one newly admitted
## peer, the run seed plus the whole accumulated chunk-keyed mutation log, compressed) and
## net_delta_applied (host -> everyone, one live mutation: chunk, kind, key, value). Both reliable —
## a dropped snapshot is a late joiner starting from a world that silently disagrees with everyone
## else's, and a dropped live delta is the exact same disagreement arriving more slowly, the next
## time that peer's chunk happens to reload.
## 19 (task 4.8): systems/wellspring/wellspring.gd added net_request_toggle_channel (client -> host,
## start/cancel the capture ritual) and its own SceneReplicationConfig (capped/channeling/
## progress_sec/duration_sec/required_players, all ON_CHANGE). Reliable: a dropped toggle either
## strands a channel nobody can see running, or cancels one and leaves a client's HUD showing the
## progress bar of a channel the host already dropped.
## 20 (task 3.7): systems/building/buildable_door.gd added net_request_toggle (client -> host, open
## or shut a placed door or gate) and its own SceneReplicationConfig — `open`, ON_CHANGE, the entire
## schema a door has. Reliable: a dropped toggle leaves a door that is shut on the host and open on
## a client, which is a wall you can see through and walk into.
## 21 (F-161/F-165/F-169/F-178, one bump for four omissions): four tasks shipped new RPCs without
## bumping this constant, and each was filed separately before the pattern was visible. They are
## folded into one bump because the versions in between never existed as a build anyone ran — there
## is no compatibility window to preserve (see the note above), so four retroactive numbers would be
## fiction. What actually shipped unversioned:
##   · task 5.3, autoload/ranged_combat_service.gd — net_request_shot (client -> host), net_shot_fired
##     (host -> everyone, the tracer), net_shot_resolved (host -> the shooter, the hit result).
##   · task 6.5, the extraction pair — net_request_repair and net_request_toggle_departure.
##   · task 6.7 — net_run_defeated, the host's team-wipe broadcast.
##   · F-157, autoload/net_transport.gd — net_request_display_name (client -> host),
##     net_display_name_changed (host -> everyone) and net_display_name_snapshot (host -> a joiner).
##
## `tools/rpc_manifest_check.gd` now scans every @rpc in the project and fails when the wire surface
## moves without this constant moving with it, so a fifth omission is a red check rather than a
## silent desync somebody diagnoses weeks later. Bumping this without re-recording the manifest
## (core/net/rpc_manifest.gd) leaves that check red on purpose.
## 22 (F-411): autoload/god_mode_service.gd added net_set_local_enabled (host -> the approved
## owning peer). Reliable: losing the enable leaves host-side immunity on while the owner cannot
## fly; losing the disable leaves flight on while host-side immunity is already gone.
const PROTOCOL_VERSION: int = 22

## Wire-format tag for the client→host hello RPC, kept separate from the reason string format so a
## mismatch renders identically everywhere it's read (a log line, a UI error, a check-tool assertion).
const _MISMATCH_FMT: String = "protocol mismatch: host is v%d, you are v%d — update your build"


## Pure — no node, no network, so it is testable without a session and reusable by whichever side ends
## up owning the RPC (see the drop-in note in docs/DELEGATION.md for where that lands). Returns "" when
## the versions agree, or a reason string ready to hand to a rejected client otherwise.
static func mismatch_reason(local_version: int, remote_version: int) -> String:
	if local_version == remote_version:
		return ""
	return _MISMATCH_FMT % [local_version, remote_version]
