# WORLDGEN — the procedural island plan

> Written 2026-08-19 (yarrow21) on Sequoyah's directive: *"Start figuring out procedural world
> generation"* + *"analyze [the procedural-terrain education corpus] and figure out the best method
> for us."* This is the method decision (D-142), the composition architecture (D-143), and the task
> breakdown. `docs/GAMELOOP.md` is its sibling: what a run *plays* like on these islands.

---

## 0 · What we already have, verified

The pipeline is ~80% built and every piece is pure, tested, and **derived from the shared seed —
never replicated** (`ARCHITECTURE.md` §4, proven cross-platform by D-017/D-028):

| Piece | File | State |
|---|---|---|
| Heightmap (fBm + island falloff) | `world/gen/island_heightmap.gd` (4.1) | ✅ pure, thread-safe (D-075) |
| Biomes (height × moisture) | `world/gen/biome_map.gd` + 3 defs (4.2) | ✅ D-079 resolution rule |
| Chunk streaming + 3-tier LOD | `world/chunk/chunk_streamer.gd` (4.3) | ✅ measured, D-080 |
| Resource scatter (jittered grid, proxies) | `world/gen/resource_scatter*.gd` (4.4) | ✅ D-083 |
| Runtime nav baking per chunk | `world/chunk/nav_baker.gd` (4.5) | ✅ `bind(streamer, seed)` |
| Seed replication + mutation delta log | `core/game_state.gd`, `autoload/world_delta_log.gd` (4.6) | ✅ two-process proven |
| POI placement (Poisson-disc, priority) | `world/gen/poi_map.gd` + `PoiDef` (4.7) | ✅ 38 assertions |
| Mire grid simulation | `world/mire/mire_grid.gd` (4.9) | ✅ host-only, delta-broadcast |

**The composer shipped (4.15) and is the default map (4.19):** `world/gen/procedural_world.gd` on
the root of `levels/procedural_island.tscn`, which `project.godot` boots as `run/main_scene`.
Hollowmere stays in the repo as the authored fixture/reference. §3 was the composer's design and
now describes what runs.

---

## 1 · The method survey — the YouTube/education canon, judged against OUR constraints

The constraints that judge every technique (none are negotiable):

- **C1 — Cross-platform determinism.** Same seed ⇒ bit-identical island on macOS/Windows/Linux
  (§4). The safe set is FastNoiseLite + `+ − × ÷` + comparisons; raw transcendentals are banned
  (D-017, measured again on real Windows hardware in D-028).
- **C2 — The worst computers must run it** (Sequoyah's standing directive). Generation must fit
  the streaming budget D-080 measured; no per-frame global passes.
- **C3 — Bounded island, first-person scale.** ~200 m across (D-045's lesson: 356 m was too big
  for the player count), walkable slopes, readable landmarks. Not infinite, not voxel.
- **C4 — The Mire must eat it.** The island is consumed cell-by-cell (§5); terrain must stay
  compatible with a 2D corruption grid and with extraction/wellspring pacing.
- **C5 — Co-op pacing is authored by the layout.** Wellsprings, nests, the wreck — their *spacing*
  is the difficulty curve. Whatever shapes terrain must leave POI placement in control.

The techniques, sourced from the canonical material ([Sebastian Lague's Procedural Landmass series
and its noise/octaves/falloff structure](https://github.com/SebLague/Procedural-Landmass-Generation/blob/master/Proc%20Gen%20E03/Assets/Scripts/Noise.cs),
[his hydraulic-erosion work](https://agerdev.itch.io/hydraulic-erosion-simulation),
[Henrik Kniberg's Minecraft terrain-generation-in-a-nutshell material](https://x.com/henrikkniberg/status/1490449049002123265)
and [the Minecraft noise/density docs that formalize it](https://minecraft.wiki/w/Noise_generator),
[Amit Patel's polygonal map generation](http://www-cs-students.stanford.edu/~amitp/game-programming/polygon-map-generation/),
[terrain-erosion-3-ways](https://github.com/dandrino/terrain-erosion-3-ways),
[the academic survey of the field](https://link.springer.com/chapter/10.1007/978-3-030-21077-9_6),
and [how Valheim derives everything from one hashed seed](https://cybrancee.com/blog/how-does-valheim-world-generation-work/)):

| Technique | Canonical source | Verdict for MIRE |
|---|---|---|
| **fBm heightmap + island falloff** | Lague eps 1–11; what 4.1 already is | **KEEP — the base.** Already built, measured, deterministic. |
| **Domain warping** (offset the sample position by another noise field) | Inigo Quilez; Kniberg uses it for Minecraft's "shift" noise | **ADOPT (4.13).** The single biggest visual upgrade per unit cost: kills fBm's telltale isotropic blobbiness, makes coastlines and ridgelines read as *geology*. Godot's `FastNoiseLite` has it built in (`domain_warp_*` properties) — same library we already trust, integer-seeded, C1-compatible pending one determinism-probe extension. Cost: ~2 extra noise evaluations per sample, amortized off-thread by 4.3's existing WorkerThreadPool path (C2 ✓). |
| **Ridged multifractal layer** (abs-folded noise for ridgelines) | Lague; standard fBm variant | **ADOPT (4.13), one octave, masked to highlands — RETUNED DOWN (4.18, D-184).** Sequoyah's island-feel verdict: mostly flat, gentle rolling hills, no mountains (Muck reference). The layer survives as rolling texture (RIDGE_WEIGHT 2.0, HEIGHT_SCALE 11), not a skyline. Pure arithmetic on FastNoiseLite output (C1 ✓). |
| **Hydraulic erosion** (droplet simulation) | Lague's erosion episode; [terrain-erosion-3-ways](https://github.com/dandrino/terrain-erosion-3-ways) | **SPIKE, don't adopt yet (4.17).** It produces the best-looking valleys in the corpus, and a *bounded* island makes it affordable as a one-time pass at run start (a ~100×100 grid, tens of thousands of seeded droplets, integer-indexed — nothing per-frame, C2 ✓). The risk is C1: iterative float accumulation is exactly where platforms drift. The spike's deliverable is a *measured answer*: extend `tools/check_determinism.gd` with the erosion pass and compare hashes on the D-028 Windows machine. Hash-equal ⇒ adopt; not ⇒ reject permanently and say why in the decision. Do not let the pretty valleys negotiate with C1. |
| **River carving via graph/spline** (downhill tracing, carve along path) | Patel's polygonal maps put rivers first; Valheim carves lanes with per-biome banks | **ADOPT, simplified (4.14).** Hollowmere's identity IS "a river out of the northern rim through a gorge into the mere" — authored. Procedurally: pick a high point and the mere from the POI pass, trace steepest-descent on the heightfield, carve a widening channel along the path (pure arithmetic, C1 ✓). One river per island, always navigable on foot at the banks. This is *landmark stamping*: guaranteeing the readable terrain feature noise alone can't promise. |
| **Voronoi/polygonal skeleton** (Patel's whole-island graph) | [Red Blob's polygon map generation](http://www-cs-students.stanford.edu/~amitp/game-programming/polygon-map-generation/) | **REJECT as the base, STEAL the lesson.** A full Voronoi re-architecture would discard 4.1–4.5's built, measured stack for a different one with the same output class at our scale. The lesson worth stealing — *place the things that matter first, then make terrain serve them* — is already how 4.7 works (Wellspring places at priority 0 and wins the good ground) and is how the river (4.14) and POI flattening work. |
| **3D density noise / caves / overhangs** (Minecraft Caves & Cliffs) | Kniberg's talk; marching-cubes episodes | **REJECT.** Wrong game: C4's Mire grid is 2D, collision cooking and nav for volumetric terrain would blow C2, and DESIGN.md's cut list already excludes cave content. Overhangs come from props and stamped POI structures, not from the field. |
| **Wave-function collapse for structures** | the WFC corpus | **REJECT for now.** Our POIs are authored prefabs placed by 4.7; WFC solves a variety problem we do not have at 3–7 POIs per island. Revisit only if ruins-variety ever becomes a playtest complaint. |
| **Per-biome parameter tables over one noise stack** (not separate generators) | Kniberg's spline/table approach; Valheim's biome-by-distance | **ADOPT (4.13).** Biomes already resolve from height×moisture (4.2); 4.13 lets a `BiomeDef` scale amplitude/roughness so shores stay gentle and highlands crag — tables, not code forks, exactly the Minecraft shape. |

**The recipe (D-142):** keep the 4.1 base; add domain warp + one masked ridged layer + per-biome
amplitude tables (4.13); carve one guaranteed river and flatten POI ground (4.14); spike erosion
behind the determinism gate (4.17) and adopt only on hash-equal evidence. Everything else stays
rejected with reasons above. Every new operation must be added to `tools/check_determinism.gd`'s
probe **in the same task that adds it to the generator**.

---

## 2 · Why this wins (over the alternatives we could have picked)

- **It is the smallest diff from a measured, shipped stack** — three of five adopted items are
  parameter-level changes to files that already exist and already have checks.
- **It preserves what made Hollowmere good.** 2.1k taught us what a readable MIRE island is: a
  river, a plateau, a wet lowland for the Blight, landmarks you can navigate by. The adopted set
  (warp for geology, ridged for silhouette, carved river, POI-first ground) reproduces those
  *guarantees* instead of hoping noise provides them.
- **Determinism is enforced at the technique boundary.** The one genuinely risky adoption
  (erosion) enters through a spike whose only deliverable is the cross-platform hash — the same
  discipline that already banned transcendentals (D-017) and measured MSVC (D-028).

---

## 3 · The composer — how a procedural island becomes a *playable level* (D-143)

The audit's key discovery: **the map contract is the marker-group protocol.** Every world service
already discovers its sites by scanning group `authored_world_marker` for a `kind` meta —
`objective` (WellspringService), `shipwreck` (ExtractionService), chest kinds
(ChestPlacementService), `station` (CraftingService), `enemy_nest` (EnemyWorld, F-076's canonical
kind). Plus `authored_world_terrain` / `authored_world_harvestable` for ground and holders.

So the cutover needs **no service rewrites**. It needs one node:

```
world/gen/procedural_world.gd  (class_name ProceduralWorld, a Node3D)
  _ready():
    seed        = GameState.ensure_seed()                 # 4.6 — host draws, clients regenerate
    streamer    = ChunkStreamer  (world_seed = seed)      # 4.3 — terrain, LOD, collision ring
    scatter     = ResourceScatterField (streamer, seed)   # 4.4 — flora + harvestable proxies
    nav         = NavBaker.bind(streamer, seed)           # 4.5 — walkable = navigable
    sites       = PoiMap.sites_for_island(seed, …)        # 4.7 — Wellspring first, then landmarks
    for site in sites:
        instance site.scene_path (if any) at site.position/rotation_y
        publish Marker3D in "authored_world_marker" with kind = def's marker kind
    spawn       = pick_spawn(seed, sites)                 # new: §3.1
    publish self in "authored_world_terrain"; height_at(x,z) -> IslandHeightmap.height(…)
```

Services light up unchanged the moment the markers exist. `WorldDeltaLog` (4.6) already carries
mutations; `MireGrid` binds to the island bound the same way it does today.

### 3.1 The two genuinely new rules (small, but design, so recorded)

- **Spawn selection:** the shore point nearest the Wellspring-densest arc — shore biome, slope
  under the walkable limit, `clearance_m` from every POI, nav-reachable to the nearest Wellspring
  once LOD0 collision exists. Deterministic from seed (every peer computes the same point; the
  host's placement RPC already handles the rest). *Shore start is a pacing choice:* the first
  minutes walk inland, which is the forage-and-first-tools beat GAMELOOP.md §1 wants.
- **POI marker kinds live on `PoiDef`.** A def gains `marker_kind: StringName` (`objective`,
  `shipwreck`, `enemy_nest`, chest kinds, `station`, or empty for scenery) so the composer stays a
  dumb loop and content stays in charge — same philosophy as every other Def family.

### 3.1a Scatter has a second gate: Mire corruption (F-445, D-191)

A `ScatterDef` gates on one `biome_id`, and the Mire is not a biome — it is `MireGrid`'s corruption
field, seeded from the world seed and spreading over the run. So the Mire's own art
(`mushroom_cluster_*`, `mire_crystal_*`, `mire_tendril_*`, the `mire_growth` category) had nowhere
to live and was scattered as ordinary woodland decor, which put purple corruption in clean birch
forest.

`ScatterDef` therefore carries `min_corruption`/`max_corruption` alongside its height band, and
`biome_id = "*"` (`ScatterDef.ANY_BIOME`) for a table that opts out of the biome gate entirely.
Two rules go with it:

- **A `"*"` table MUST set a corruption band.** `validation_errors()` rejects one that does not —
  a table with neither gate would carpet the whole island. Only the Mire uses `"*"` today and it
  should stay that way; anything else wanting it needs a gate at least as narrow as a biome.
- **The gate reads the INITIAL corruption field, never the live one.**
  `MireGridSim.initial_corruption_at()` is a pure function of the world seed. Scatter placements are
  generated once per chunk, cached, and identical on every peer forever; a field that moves every
  two seconds cannot be an input to that. The spreading half of the Mire is shown by F-435's ground
  shader — this half is the permanent growth at the origin it spread from. Since D-191 there is
  exactly one such origin per run.

Two tables ship on it: `mire_growth` (mushroom-dominant, from corruption 0.12 outward) and
`mire_heart` (crystals and tendrils, corruption 0.55 and up), so the patch reads as a dense core
inside a thinning rim rather than a uniform disc. `tools/mire_scatter_check.gd` guards both
directions — no `mire_growth` asset in an ungated biome table, and no `mire_growth` export left
referenced by nothing.

### 3.2 Cutover strategy — flag first, parity second, default last

1. **4.15** ships the composer behind `DevLaunch --procedural` (beside the existing `--seed=`,
   F-172). Hollowmere stays the default main scene. Nothing a player runs changes.
2. **4.16** makes the *contract checks* pass on the procedural world: `world_contract_check`
   already asserts nests/harvestables map-agnostically (F-076); extend its boot matrix to run both
   maps, fold in F-112's Undergrowth gap (procedural flora is ResourceScatterField's job, so the
   check retires on that map). Parity = every service check green with `--procedural`.
3. **4.18** is Sequoyah walking three seeds against Hollowmere and judging *island feel* — the one
   thing no check asserts. Per D-125 this gates nothing; it schedules tuning.
4. **4.19** swaps the default main scene — **done 2026-08-20**: `levels/procedural_island.tscn`
   (composer root under Hollowmere's environment shell) is `run/main_scene`; Hollowmere stays in
   the repo as the test fixture and the reference island (same retirement Playtest Hollow already
   went through), pinned into `world_contract_check`'s authored arm and the authored-content
   checks (`chest_placement`, `harvest_batch`, `environment_vfx_hollowmere`).

---

## 4 · Task breakdown (now in ROADMAP.md, claimable)

| # | Task | Tier | Depends on |
|---|---|---|---|
| 4.13 | Terrain look: domain warp + masked ridged layer + per-biome amplitude tables; extend `check_determinism` + re-run `bench_chunks` | T2 | — |
| 4.14 | One guaranteed river: steepest-descent trace + carve; POI ground flattening; `terrain_check` additions | T2 | 4.13 |
| 4.15 | `ProceduralWorld` composer behind `--procedural`; `PoiDef.marker_kind`; spawn rule; its check | T2 | — (started 2026-08-19) |
| 4.16 | Map-contract parity: both-map check matrix, F-112 fold-in, MireGrid binding | T1 | 4.15 |
| 4.17 | **Spike:** one-time seeded erosion pass; cross-platform hash on the D-028 machine; adopt/reject with numbers | T2 | 4.13 |
| 4.18 | Three-seed island-feel walk vs Hollowmere (tuning input, not a gate — D-125) | T0 | 4.15 |
| 4.19 | Default cutover; Hollowmere becomes fixture/reference | T1 | 4.16 |

Estimated premium spend is concentrated in 4.13/4.15; both build directly on measured seams.

---

## 5 · What this deliberately does not do

- No infinite world, no voxels, no caves — C2/C4 and the cut list.
- No biome *count* growth here — 4.2's three biomes suffice for the cutover; authoring more is
  content work gated by art batches, not by this plan.
- No replacement of the delta-log/replication story — 4.6 already answered it and proved it over
  real ENet; the composer is a consumer.
