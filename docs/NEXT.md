# NEXT — what am I doing right now?

> **Open this first, every time.** It exists so that coming back after a week or a month costs you ten
> minutes instead of a weekend. Update it before you stop working. Always.

---

## Status

**Milestone:** M0 · Foundations & spikes — 1 of 9 tasks done
**Last session:** 2026-08-15 — planning docs written; git repo initialised; multi-agent coordination
system built and tested.

Nothing in the *game* is built yet. The Godot project is still empty scaffolding.

---

## Start here, every session

```bash
.agent/bin/agent start <your-name>
```

`claude` · `codex` · `sequoyah`. It prints the board, what's in flight, stale claims, and recent
commits. Protocol is in [AGENTS.md](../AGENTS.md); live board is `.agent/BOARD.md`.

---

## Next task

### → 0.2 · Folder structure — `[T0]` · ~30 min

Create the layout from `ARCHITECTURE.md` §3. Do it in Finder or the shell, whichever you prefer — it's
just empty directories, and getting them in place now is what keeps files small and single-purpose
later (which is a direct quota saving).

```
autoload/  core/{net,save,util}/  world/{gen,chunk,mire}/
entities/{player,enemies,props,structures}/
systems/{crafting,inventory,combat,powerups,waves,daynight}/
content/{items,powerups,enemies,recipes,biomes}/  ui/{hud,menus,lobby,inventory}/
```

---

## Then, in order

| # | Task | Tier | Est |
|---|---|---|---|
| 0.3 | Input map: move, look, jump, sprint, attack, interact, inventory, build | T0 | 30 min |
| 0.4 | First-person `CharacterBody3D` controller | T1 | 2h |
| 0.5 | Grey-box test level; **tune until movement feels good** | T0 | 2h |
| 0.6 | Debug overlay + console autoload | T1 | 2h |
| 0.7 | **Spike R2** — 100 chunked terrain meshes, measure frame times | T2 | 1.5h |
| 0.8 | **Spike R3** — runtime NavMesh bake on a generated chunk, measure hitch | T2 | 1.5h |
| 0.9 | Write spike results into `DECISIONS.md`; if R3 failed, pick the fallback now | T0 | 30 min |

Full plan: `ROADMAP.md`. Live status: `.agent/BOARD.md`.

**0.4 is a good first handoff to Codex** — self-contained, one file, no scene edits needed beyond
attaching the script. Good way to test the protocol on real work.

---

## Open questions waiting on playtests

None yet — nothing is playable. First real answers arrive at **M2 task 2.14**.
Tracked in `DESIGN.md` §8.

---

## Cold-start ritual

1. `.agent/bin/agent start <name>` — the board tells you what's in flight
2. Read this file
3. Skim the last entry or two in `.agent/JOURNAL.md` if someone handed off
4. `agent claim <id> <files...>` **before** editing
5. Do the work
6. `agent done <id> "..."` or `agent handoff <id> "..."`, update this file, **commit**

---

## Parking lot

Ideas that are not in scope yet. Write them here instead of building them.

- Seed sharing / daily seed with a friends leaderboard by Cycle depth
- Spectator mode for dead players (better than staring at a respawn timer)
- A "Cycle 1 speedrun" mode
- Cosmetic hats. There must be hats.
