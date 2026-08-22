#!/usr/bin/env bash
# Queue rebuilt against the board of 2026-08-22 ~01:40 Vancouver.
# Replaces the 2026-08-20 14:05 queue, which predated ~180 findings.
#
#   Run from the repo root:  bash .agent/rebuild-queue.sh
#
# Nothing here dispatches. It only writes orders.
#
# Only LP and LC2 are dispatchable. LC1 and LM are manual:true — reserved for Sequoyah's own
# sessions, budgeted by hand, never dispatched.
#
# DISPATCH SCHEDULE:
#
#   after 15:00 Vancouver   .agent/bin/agent saturate LP  --watch   # 96% of seven-day, resets 15:00
#   after 00:00 on the 23rd .agent/bin/agent saturate LC2 --watch   # LC2's natural reset
#
# FREE CODEX RESETS — one on each account, decided independently:
#
#   LC1   apply NOW. It is at 0% quota with only paid credits left and does not reset naturally
#         until the 26th, so there is no window to drain first and every day held is a day lost.
#   LC2   HOLD. It resets naturally at 00:00 on the 23rd — drain that window fully, then apply the
#         credit for a second one. A granted reset does not decay, so holding it costs nothing,
#         while applying it early restarts the cycle and pushes the next natural reset out a week.
#
# Note LC1's credit restores Sequoyah's own Codex lane, not the queue's — LC1 is manual. If the
# queue should use it today instead, that takes `agent lane-release LC1`, which is his call.
set -euo pipefail
cd "$(dirname "$0")/.."
A=.agent/bin/agent

$A director --take

# Dropped from the old queue: F-236 only. It is already running on LP, and cmd_order's retirement
# condition ("an order whose task is done is skipped") retires it on its own once LP closes it —
# no cancel needed. Every id below already has an order file; re-issuing overwrites it in place,
# so this script is safe to re-run.

# ─────────────────────────────────────────────────────────────────────────────
# LC2 — Codex #2 (ui/ tools/ world/). The fresh reset. Red-at-HEAD checks first.
# ─────────────────────────────────────────────────────────────────────────────
$A order F-293 --lane LC2 --priority 1   # nothing enumerates/runs the tools/ suite — the meta-fix
$A order F-467 --lane LC2 --priority 1   # an h2 inside a finding body hides every finding after it
$A order F-427 --lane LC2 --priority 1   # assets/ silently duplicated with a ' 2' suffix
$A order F-428 --lane LC2 --priority 2   # 78 icon_* 2.png dupes — item_icons_check red at HEAD
$A order F-438 --lane LC2 --priority 2   # run_scope_audit_check red at HEAD: 3 audio autoloads
$A order F-285 --lane LC2 --priority 2   # nav_bake_check 4 failures at clean HEAD
$A order F-448 --lane LC2 --priority 3   # chunk_stream_check union-of-interest fails at HEAD
$A order F-304 --lane LC2 --priority 3   # 27 probe transports truncate-write a polled file
$A order F-305 --lane LC2 --priority 4   # wave_spawner_check: undeclared ERRORs, reports green
$A order F-312 --lane LC2 --priority 4   # environment_vfx_reseed_check: 15 undeclared ERRORs
$A order F-310 --lane LC2 --priority 4   # 10 checks drive the consumer, never the producer
$A order F-446 --lane LC2 --priority 5   # Deep Forest is 3.5% of dry land — richest tables unseen
$A order F-444 --lane LC2 --priority 5   # ground mist pools at the waterline, not in the valleys
$A order F-294 --lane LC2 --priority 6   # per-sample Array allocs in island_heightmap.gd
$A order F-289 --lane LC2 --priority 6   # ship structurally cannot commit docs/FINDINGS.md
$A order F-420 --lane LC2 --priority 7   # settings screen: two contradictory row layouts

# ─────────────────────────────────────────────────────────────────────────────
# NOT DISPATCHED — LC1 is manual:true, reserved for Sequoyah's own sessions. The block below was
# originally routed there in error. These are systems/ core/ entities/ findings; LP owns systems/
# too, so they drain there behind the LP block once LP's seven-day window resets at 15:00.
# ─────────────────────────────────────────────────────────────────────────────
$A order F-479 --lane LP   --priority 5   # 5 buildable stations, no recipes — panel opens empty
$A order F-481 --lane LP   --priority 5   # apple swings like an axe — viewmodel_check red at HEAD
$A order F-436 --lane LP   --priority 6   # inventory_check asserts 1 subscriber, SfxDirector is 2nd
$A order F-474 --lane LP   --priority 6   # bogsilver is a plain item — tier 4 lost two-player carry
$A order F-440 --lane LP   --priority 7   # 5 pickups 16-24% under their declared true size
$A order F-429 --lane LP   --priority 7   # headless boot never streams collision — player falls
$A order F-264 --lane LP   --priority 8   # Boss._tick_move_lunge duplicates Enemy._tick_lunge
$A order F-354 --lane LP   --priority 8   # enemy_check's 'starts idle' races the physics tick
$A order F-300 --lane LP   --priority 9   # autoexec loadout is boot-only, F-243 wipes it
$A order F-412 --lane LP   --priority 9   # command system below the Minecraft-like capability bar

# ─────────────────────────────────────────────────────────────────────────────
# LP — Claude Pro. 96% of its seven-day window, resets 15:00. Short queue only.
# ─────────────────────────────────────────────────────────────────────────────
$A order F-321 --lane LP --priority 1    # AttunementUI soft-lock: orphaned client can never leave
$A order F-320 --lane LP --priority 1    # every gameplay HUD autoload draws over the front end
$A order F-322 --lane LP --priority 2    # end_session has no caller — 19s rejoin ladder on host quit
$A order F-437 --lane LP --priority 3    # 3 centre-screen HUD elements never seen together
$A order F-303 --lane LP --priority 4    # foliage_mesh_count climbs an island per reseed
$A order F-306 --lane LP --priority 5    # docs/NEXT.md goes stale within hours

$A report
