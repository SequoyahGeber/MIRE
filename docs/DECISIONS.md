# Decision log

One entry per decision that would be expensive to reverse. **Append, never rewrite.** When you change
your mind, add a new entry that supersedes the old one — the reasoning you rejected is as valuable as
the reasoning you kept, and future-you (or an agent) will otherwise re-litigate it for free.

Format: `D-NNN · date · decision · why · what would change my mind`

---

### D-001 · 2026-08-15 · Engine: Godot 4.7, pinned
Staying in Godot rather than moving to Unity (which Muck used). You already know it; the project is
already configured with Forward+ and Jolt; the high-level multiplayer API fits host-authoritative co-op
well; no revenue share; text-based project files work well with AI agents and git.
**Pinned version matters** — GodotSteam breaking on a point release produces long, confusing, expensive
debug sessions. Do not upgrade mid-milestone.
**Would change my mind:** spike R2 or R3 (`ARCHITECTURE.md` §6) failing catastrophically with no viable
fallback.

### D-002 · 2026-08-15 · Networking: host-authoritative listen server
No dedicated servers, no host migration, no rollback. Host runs the sim; clients predict their own
movement only. This is what Muck does and it's correct for 3–6 friends.
**Would change my mind:** wanting public matchmaking with strangers (would need dedicated servers and
actual anti-cheat).

### D-003 · 2026-08-15 · Multiplayer built first, before gameplay (M1)
Retrofitting multiplayer is the single most common way co-op hobby projects die — it means rewriting
every system that touches state, which is most of them. Given that quota is the binding constraint, a
rewrite of that size is not survivable.
**Would change my mind:** nothing. This one is load-bearing.

### D-004 · 2026-08-15 · First-person, viewmodel arms only
No full-body character animation pipeline, no locomotion blend trees, no IK, no third-person camera
collision. Saves an estimated 4–6 months of a skill you don't currently have. Muck proves FP melee works.
**Would change my mind:** playtesters consistently reporting they can't read melee range in FP. Mitigate
first with better hit feedback before considering third-person.

### D-005 · 2026-08-15 · Art: CC0 low-poly packs (Quaternius / Kenney), hero assets swapped later
$0, no attribution burden, and stylistically close to Muck already. Removes art as a blocker entirely
and defers all art cost until the project has proven it will survive.
**Would change my mind:** the game succeeding and the generic look becoming the main criticism. That's a
good problem, and the fix is commissioning hero assets, not restarting.

### D-006 · 2026-08-15 · Content is data (`.tres` Resources), not code
Items, powerups, recipes, enemy stats, Cycle Modifiers all live in Godot `Resource` files loaded at boot.
Framework built once with premium quota; content authored by hand in the inspector for free.
**This is a direct quota optimization** — it makes the 60th powerup cost the same as the 2nd, and zero
tokens either way.
**Would change my mind:** nothing. This gets more correct the longer the project runs.

### D-007 · 2026-08-15 · Agents write scripts; the human wires scenes
Godot `.tscn`/`.tres` files do not merge — they carry internal sub-resource and node-path IDs that
conflict badly and can silently corrupt. Restricting agents to `.gd` files makes parallel agent work
safe, and happens to match what each party is actually good at.
See `AI-WORKFLOW.md` §3.
**Would change my mind:** nothing, until Godot scene files become mergeable.

### D-008 · 2026-08-15 · Develop against Steam App ID 480 until M8
Valve's public test app. Full lobby + P2P + overlay with no Steamworks account and no $100. Defers all
cost and paperwork until the project has proven it will ship.
**Would change my mind:** needing achievements or Steam Cloud earlier than expected (both require a real
App ID).

### D-009 · 2026-08-15 · No win condition — endless Cycles with voluntary extraction
*Supersedes the original three-act, boss-at-the-end structure.*
Runs escalate forever via stacking Cycle Modifiers until the island is consumed or the team wipes. The
shipwreck is reframed from win condition to voluntary cash-out.
Three reasons this is better: (1) replayability comes from stacking modifiers rather than authored
content, which scales far better for a solo dev; (2) it removes a final boss — a large, risky, gating
chunk of work; (3) the ending is emergent (the island runs out) rather than something you have to
design, balance, and justify.
The "one evening" identity is preserved by the extraction decision and by tuning the wall to ~2–2.5h,
not by a timer.
**Would change my mind:** playtests showing nobody ever extracts (Q6) *and* the reward curve can't be
tuned to fix it — at which point reconsider a soft cap.

### D-010 · 2026-08-15 · A run is one sitting; no save/resume
Serializing world mutations, entity state, inventories, powerups, and the Mire grid is a large,
bug-prone body of work, and it's the kind of bug that only shows up in front of friends.
**Would change my mind:** 2h+ runs proving to be a real scheduling problem for your group in practice.
This is the #1 post-launch feature candidate.

---

## Template

```
### D-0NN · YYYY-MM-DD · <one-line decision>
<why, in 2–4 sentences>
**Would change my mind:** <the specific evidence that should make you revisit this>
```
