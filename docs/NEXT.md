# NEXT — what am I doing right now?

> **This is the file you open first, every single time.** It exists so that coming back after a week or
> a month costs you ten minutes instead of a weekend. Update it before you stop working. Always.

---

## Status

**Milestone:** M0 · Foundations & spikes
**Last session:** 2026-08-15 — planning. Design, architecture, roadmap, and workflow docs written.
**Nothing is built yet.** The Godot project is empty scaffolding.

---

## Next task

### → 0.1 · `git init` and first commit — `[T0]` · ~30 min

The project isn't under version control yet. Do this before anything else — with agents editing files,
`git` is your undo button and your safety net.

```bash
cd /Users/sequoyahgeber/Desktop/muck-but-better && git init && git add -A && git commit -m "Initial project scaffolding and design docs"
```

Then confirm `.gitignore` covers `.godot/` (it does), and add `export/` and `.DS_Store`.

---

## Then, in order

| # | Task | Tier | Est |
|---|---|---|---|
| 0.2 | Create the folder structure from `ARCHITECTURE.md` §3 | T0 | 30 min |
| 0.3 | Input map: move, look, jump, sprint, attack, interact, inventory, build | T0 | 30 min |
| 0.4 | First-person `CharacterBody3D` controller | T1 | 2h |
| 0.5 | Grey-box test level; **tune until movement feels good** | T0 | 2h |
| 0.6 | Debug overlay + console autoload | T1 | 2h |
| 0.7 | **Spike R2** — 100 chunked terrain meshes, measure frame times | T2 | 1.5h |
| 0.8 | **Spike R3** — runtime NavMesh bake on a generated chunk, measure hitch | T2 | 1.5h |
| 0.9 | Write spike results into `DECISIONS.md`; if R3 failed, pick the fallback now | T0 | 30 min |

Full plan: `ROADMAP.md`.

---

## Open questions waiting on playtests

None yet — nothing is playable. First real answers arrive at **M2 task 2.14**.
Tracked in `DESIGN.md` §8.

---

## Cold-start ritual

1. Read this file
2. `git log --oneline -10` — what did past-you actually finish?
3. Launch in `LOCAL` two-window mode, confirm nothing is broken *before* changing anything
4. Do the work
5. **Update this file and commit before you stop**

---

## Parking lot

Ideas that are not in scope yet. Write them here instead of building them.

- Seed sharing / daily seed with a friends leaderboard by Cycle depth
- Spectator mode for dead players (better than staring at a respawn timer)
- A "Cycle 1 speedrun" mode
- Cosmetic hats. There must be hats.
