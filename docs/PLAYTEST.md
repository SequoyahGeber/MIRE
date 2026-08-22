# PLAYTEST READINESS — co-op session with a friend

**Written 2026-08-22 by wick410d34 (director), against Sequoyah's bar:**

> *"keep going until ur confident that the game is at a good point for me to do a gameplay test with
> my friend, i dont want to get hard locked in progression during the play test and have to do fixes
> then compile a new app and install, i want to just be able to play the game with my friend."*

Everything below was **measured on a real generated island**, not derived from reading code. Four
things were wrong today that reading had said were right, so nothing here is asserted from a file.

---

## 1. The short answer

**Yes for a session, with three things to know before you sit down** (§4). The four ways a co-op run
could have stranded are now measured rather than assumed, and none of them strands.

---

## 2. What was verified, and how

| Question | Answer | Instrument |
|---|---|---|
| Can progression hard lock? | **No.** Every station buildable, every recipe craftable, 45/46 items obtainable — **identically on all five seeds** | `progression_reachability_check` |
| …even if loot placement breaks? | **No.** With loot disabled entirely, the tree still bootstraps: all 3 tool classes, all 8 stations, 40/46 items. **Progression does not depend on loot** | same, negative control |
| Is the opening near where you land? | **Yes.** Everything for a workbench and the first axe is **19–74 m from spawn** on three seeds | `first_minutes_check` |
| Does the game loop run end to end? | **Yes**, both endings — default arc and defeat | `loop_audit_check` |
| Does host/client parity hold? | **Yes**, on every verb: harvest, inventory, chest, crafting, build, health, **extraction**, **pickup** | 28 `*_net_check` harnesses + 2 new |
| Does a client's progress persist? | **Yes.** Salvage banks to that peer's own file and survives a reload; unlocks persist; double-buy refused with balance intact | `salvage_unlock_net_check` |
| Can a run be ended? | **Yes.** Client can initiate the hold, it requires both players, the ship departs, the client banks | `extraction_check`, `extraction_net_check` |
| Does HEAD still export? | **Yes**, macOS export runs to DONE including code signing | `--export-debug` at HEAD |
| Does anything grow unboundedly over a long session? | **No.** Drops capped at 256/128, damage numbers 24, corpses timed, hazard fields self-free, the delta log is latest-value-wins bounded by cell count | static audit |

---

## 3. What changed today because it was wrong

- **Arrows flew broadside on every shot** — the flying visual reuses the pickup mesh, whose shaft
  runs along +Y while `look_at()` aims -Z. Also never re-oriented, so it flew level into ground it
  was descending toward. Fixed; the bow now draws, and there is an ammo counter.
- **Hitting things did nothing to them.** `host_apply_knockback()` existed and was called from
  exactly one place — a powerup shockwave. An ordinary swing moved nothing. Now 3.0 m/s plus a
  stronger hit flash.
- **Four ambient enemies on the whole island**, and they spawn only at 5 nest markers. Now 18 at 12
  nests, growing to ~1.6× as the island corrupts, weighted toward corrupted ground.
- **The Mire was invisible.** 26 minutes in, the island was 8% corrupted and spawn corruption was
  still exactly 0.000. The seed could also land 500 m away. Now bounded to 296–383 m from spawn, and
  `mire_spread_multiplier` defaults to 2.0.
- **Rocks, stumps and logs had no colliders at all** — you walked through every one.
- **A harvest burst deleted the island's entire authored loot**: 0 of 71 caches left standing.
- **30 of 72 powerups did nothing.** 24 stat names had no reader anywhere.
- **Two top-tier chests per island were permanently unopenable**, gated behind a key that did not exist.
- **The Reinforced Workbench crafted nothing** — buying the upgrade left you strictly worse off.
- **Heap corruption** in the threaded asset loader: one owner running two load lifecycles over one
  path. Fixed by construction. This is the one that could have crashed a real session.

---

## 4. Three things to know before you sit down

1. **Steam invites will not work.** `STEAM_APP_ID` is 480 (Spacewar), so an invite invites your
   friend to Spacewar and Steam will not launch MIRE for them. **Host and read out the join code**,
   and tell them up front so nobody waits on an invite that never comes. Fixing it needs a real
   Steamworks App ID — your account, your paperwork.
2. **Rebuild before you play.** The build in `export/macos` is from **Aug 18** and hundreds of
   commits stale. The export path is verified working at HEAD.
3. **The Mire's pace is a console knob now.** `gamerule mire_spread_multiplier <n>` — 2.0 is the new
   default and reaches the island origin around 34 min; 1.0 is the original three-hour curve. Change
   it mid-session if it feels wrong in either direction.

---

## 5. Known and deliberately not fixed

- **`raw_meat` has no source** — there are no huntable animals yet. Cooking recipes exist but the
  meat does not. Fauna is specced (`docs/FAUNA.md`) and parked at 2 of 6 art assets.
- **The sling** is fully modelled, documented and obtainable by nobody (F-601). Nothing depends on it.
- **~30 pickup meshes can never render**, because the icon branch always wins (F-589). Art direction.
- **The first unlock is roughly eight cycle-1 runs away** (10 Salvage banked against a 75 cost). If
  you play two or three short runs, expect nothing purchasable.
- **`workbench_upgraded` grants parity, not an upgrade** — no recipe requires it (F-587).

---

## 6. The one real unknown: performance on an M1 Air

**This is the thing that has not been measured and cannot be from here.** Your friend's machine is
fanless with an integrated GPU and unified memory, and today's work made the world busier — more
enemies, more nests, 307 new collision shapes, hazard fields, status effects.

Structural counters are being measured headlessly. **Frame times are a genuine hand-off to you**: a
windowed run is worthless because it gets backgrounded and throttled, and on a fanless laptop a
40-second probe measures the best minute the machine will ever have. **If you want a real number,
it needs a long run, on a display, foreground, with you not using the machine.**

Cheapest mitigation if it does run badly: the `GraphicsQuality` presets. "Run it on Medium" may be
the whole answer.
