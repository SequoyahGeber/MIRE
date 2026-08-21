# Performance

The standing goal: **MIRE runs at 60 fps on the worst computer we target**, and that goal never
closes (`docs/DECISIONS.md`, F-174). This file is what we know about where the frame goes, which
optimization techniques are worth applying to *this* game, and which are worth nothing here despite
being the first advice every guide gives.

Three findings referenced this file before it existed (F-352, F-363, F-426). It exists now.

---

## 1. How to measure — and what each instrument is actually good for

Three instruments, three different questions. Using the wrong one has cost this project real work
twice (F-342, F-452), so read this before quoting a number.

| Instrument | Question it answers | How to run |
|---|---|---|
| `tools/perf_probe.gd` | **How fast is it?** Milliseconds, fullscreen, real display, one suspect toggled per row | `.agent/bin/agent godot --display-driver macos --script tools/perf_probe.gd` |
| `tools/frame_cost_check.gd` | **What does the renderer do per frame?** Draw calls, primitives, VRAM, from the renderer's own counters | `.agent/bin/agent godot --windowed --script tools/frame_cost_check.gd` |
| `tools/render_census.gd` | **What is the scene made of?** Surfaces, meshes, LOD levels, attribution by asset | `.agent/bin/agent godot --script tools/render_census.gd` |

**Run the millisecond probe fullscreen, on a quiet machine.** An offscreen, unfocused, downsized
window is throttled and scaled differently from the real game; its draw-call and primitive counters
survive that, its frame times do not.

Five rules the instruments learned the hard way. All of them are about not fooling yourself, and
every one was written after a table that looked like evidence turned out not to be:

1. **The 1% low is the headline, not the median.** A median describes the smooth stretches; what a
   player *feels* as the game being bad is the worst one frame in a hundred — a chunk arriving, the
   Mire tick, a wave spawning. `perf_probe` reports the 1% low as the **mean of the slowest 1% of
   frames** (a single 99th-percentile sample swung 20 ms between identical runs) over a 5 s window,
   which is ~700 frames, so the tail has something to average. An optimization that moves the median
   and leaves the 1% low alone has not improved anything anyone feels.
2. **Pair every measurement.** Each row is sampled, undone, and the untouched build sampled again
   *immediately after*; the row's delta is against that adjacent reference. A serial table quoting
   row 19 against a baseline taken twenty rows earlier cannot resolve anything smaller than the
   run's own drift — measured here at **+1.90 ms**, enough to swallow every lever except the
   resolution ones, and enough to make four rows that removed hundreds of draw calls report the
   frame getting *slower*. The probe prints its drift at the end so the claim stays checkable.
3. **Discard the transient.** Applying a config re-renders shadow atlases, walks draw-policy state,
   compiles shaders. That belongs to the toggle, not the configuration, and it lands squarely in the
   1% tail. `DISCARD_FRAMES` drops the first 15 frames of every sample; rows that mutate geometry
   ask for a longer settle on top.
4. **Kill the frame limiter.** The probe printed 120 fps for all fourteen rows on a 120 Hz panel —
   vsync-off rows included, because `Engine.max_fps` survived the vsync toggle. Every delta was
   noise and it read as "shadows and fog cost nothing." `Engine.max_fps = 0`, and a loud warning if
   the rows still cluster on the refresh rate.
5. **Pin the seed, and settle the streamer.** The world is generated from `GameState.run_seed`, and
   an unpinned launch draws real entropy — so every run measured a *different island*. Three
   consecutive `frame_cost_check` runs reported 4,908 / 3,325 / 2,990 draw calls and none was wrong.
   `ProbeScene.pin_seed()` stages `BENCH_SEED` unless `--seed=` says otherwise; two runs now agree
   to 0.07%. Then `ProbeScene.settle()` waits for the streamer, because a fixed warmup measures a
   third-built world.

**Nobody has ever run these on low-end hardware** (F-174). Every number below is from the fastest
machine in the project. Treat them as *ratios* — which lever is worth what, relative to the others —
never as absolute headroom.

---

## 2. The measured baseline

M5 Pro, macOS, Metal, Forward+, fullscreen 3024x1898 (5.7 Mpx), procedural island on `BENCH_SEED`
(20260821), settled. `tools/perf_probe.gd`, 2026-08-21.

### The headline: standing still versus walking

```
                              fps    1% low             median
  as shipped, stationary      120    81 (12.34 ms)      7.99 ms
  TRAVERSAL (streaming)       101    13 (74.45 ms)      9.00 ms
  traversal @ preset low      146    10 (102.55 ms)     4.23 ms
  traversal + menu open       102    15 (65.92 ms)      8.93 ms
```

**Standing still the game holds an 81 fps 1% low. Walking into unstreamed terrain it is 13 fps.**
The median barely moves; the tail collapses by a factor of six — 74 ms frames, on the fastest
machine in the project. That is the whole felt performance problem, and it is F-454.

**No graphics setting touches it.** Traversal at preset LOW improves the median by 53% (9.00 ms to
4.23 ms — exactly what the preset is built to buy) and makes the 1% low *worse*. Every renderer
lever below moves the 1% low by between -3.4 ms and +1.6 ms while stationary; the traversal hitch is
**+60.8 ms**. Different problem, different fix, and the fix is not in the renderer.

**Not the menu.** An open Attunement/class picker costs nothing measurable (15 fps against 13 —
inside the run's variance). That question is settled.

### The renderer levers, measured stationary

Each against the reference sampled right after it, ranked by 1% low. These are honest numbers for
what a setting costs; they are not the answer to why the game hitches.

| Lever | 1% low | median | Draws saved |
|---|---:|---:|---:|
| dynamic resolution @240 | **-6.72 ms** | -3.23 ms | 0 |
| FSR upscale @0.59 | **-6.03 ms** | -3.77 ms | 222 |
| bilinear @0.59 (FSR control) | **-5.15 ms** | -4.73 ms | 195 |
| gfx preset low | **-4.50 ms** | -7.21 ms | 1,511 |
| gfx preset medium | -3.57 ms | -3.41 ms | 599 |
| anti-aliasing off (MSAA 2x + FXAA) | **-3.44 ms** | -1.33 ms | 346 |
| 3D render scale 50% | -2.57 ms | -2.03 ms | 324 |
| sun shadows off | -2.26 ms | -0.76 ms | 756 |
| SSAO off | -1.75 ms | -0.72 ms | 345 |
| glow off | -1.06 ms | -0.15 ms | 302 |
| mesh LOD threshold 4.0 | -0.69 ms | -0.37 ms | 282 |
| sky/time frozen | 0.00 ms | +0.02 ms | 70 |
| undergrowth hidden | +0.08 ms | +0.01 ms | 99 |
| volumetric fog off | +1.08 ms | -0.07 ms | 253 |

(Rows 11–13 — shadow cascades, shadow distance, draw distance — swung between -10.8 and +7.5 ms of
1% low across runs. They are real draw-call reductions with no measurable millisecond effect on this
GPU; treat their 1%-low column as unresolved rather than as a result.)

Read it like this:

- **Everything that helps is a resolution lever.** The top four entries are the dynamic-resolution
  controller, the two ways of lowering the render scale directly, and the preset that does it along
  with five other things. The frame is fill-bound.
- **FSR costs nothing over bilinear** at the same 0.59 scale — same price, sharper image.
  `scaling_3d_mode` is still bilinear on every preset. That is free quality, currently unclaimed.
- **Anti-aliasing is the biggest unmanaged cost in the build.** MSAA 2x + FXAA is 3.44 ms of 1% low,
  and **no graphics preset touches it** — it ships at `anti_aliasing: 2` to every machine, reachable
  only through the settings menu.
- **The draw-call knobs buy draw calls, not milliseconds.** Draw distance sheds 1,103 submissions
  for nothing measurable here. Keep them: submission is CPU cost, and the low-end target pays it.

Structure, for comparison (`frame_cost_check`, same seed, two runs): **3,010 / 3,012 draw calls,
526,889 / 526,909 primitives, 727.8 MB VRAM.** VRAM is the number to worry about — 727 MB is most of
a low-end card's budget before the OS takes its share, and no preset moves it below 380 MB.

And from `render_census` on the settled world: **1,826 `MeshInstance3D` and 10,087
`MultiMeshInstance3D` holding 22,047 instances — 2.2 instances per MultiMesh.** See §3.6.

---

## 3. Techniques, ranked by what they are worth *here*

### Worth the most

**3.1 Resolution scale, static and dynamic.** The biggest lever by a wide margin, four ways over.
Already built: `GraphicsQuality` presets set `scaling_3d_scale` (LOW 0.59, MEDIUM 0.77), and F-098's
dynamic resolution steers it to hold a target frame rate (-3.09 ms of 1% low). The trade that makes
this survivable is that MEDIUM and HIGH keep the full-quality shadow map while the resolution drops.

*Not yet done:* `scaling_3d_mode` is bilinear everywhere. FSR 1.0 measured at the same cost for a
sharper image; LOW and MEDIUM should be using it.

**3.2 Anti-aliasing.** 3.10 ms of 1% low, unmanaged by any preset. LOW should not be running MSAA
2x. This is the cheapest large win left in the settings layer, and it needs a look on a moving
camera before it ships — dropping to FXAA-only is a taste call, not just a cost one.

**3.3 The shadow pass.** 2.39 ms of 1% low and 753 draw calls for the whole thing; the individual
knobs inside it (cascade count, distance) measured at zero, which simply means the pass is not where
this GPU's time goes. Keep the knobs — they are draw-call reductions, and draw calls are CPU cost
that the low-end target pays and this machine does not. Read the F-377 block at the top of
`autoload/graphics_quality.gd` before touching any of them: shadow *stability* is a property of the
whole preset, not of one knob, and lowering four independently is how LOW got its flicker.

**3.4 Draw distance and mesh LOD.** Same story, more extreme: draw distance at 0.55 removes 1,103
draw calls — 38% of the frame's submissions — for 0.03 ms here. `world/environment/draw_policy.gd`
owns the ranges and `GraphicsQuality` scales them (LOW 0.55). It is the only knob that removes work
from the opaque pass *and* all four shadow cascades at once (F-144), which is exactly the shape of
saving a weak CPU needs. Godot's own guidance backs the mechanism — automatic mesh LOD from import
plus `visibility_range_begin`/`end` (HLOD) on any `GeometryInstance3D` — and the census now confirms
MIRE has 187 meshes with LOD levels and 11,063 instances carrying a LOD distance, so the ladder
exists and is being spent. The terrain LODs a different and legitimate way, by ring distance in
`ChunkStreamer` (F-352).

**3.5 Post-process passes.** Glow, volumetric fog and SSAO each measured inside the noise band on
this island — which is a statement about a fast GPU at 5.7 Mpx, not a licence to leave them on for
the low-end target. Their cost is a share of the pixels, so they dominate exactly when the geometry
does not; on a sparser seed measured earlier the same two rows came out at 20% and 14% of a cheaper
frame. All three are already off on LOW (SSAO since F-398). Volumetric fog is still worth bounding
to `FogVolume` shapes rather than the whole scene — the Godot docs recommend it because it limits
the region the froxel pass integrates over, and it happens to be exactly the *look* the art
direction asks for: localized drifting ground fog, not full-screen haze.

### Worth little here — measure before believing the guides

**3.6 Draw-call batching and MultiMesh.** Every general Godot guide leads with this, and for good
reason in general: one MultiMesh with 10,000 instances is one draw call where 10,000
`MeshInstance3D` nodes are 10,000. MIRE has taken half that win — `core/render/mesh_merge.gd`
collapses a 56-object pine into one mesh with one surface per material, and the scatter fields draw
through MultiMesh.

**The other half is inverted, and the census now says by how much.** The settled world holds
**10,087 `MultiMeshInstance3D` nodes carrying 22,047 instances — 2.2 instances each.** A MultiMesh
with 2.2 instances in it is *worse* than a plain `MeshInstance3D`: it pays the node overhead, the
buffer, and the submission, and batches essentially nothing. Seven fern variants alone account for
~4,100 of those nodes for ~8,300 placed copies. This is F-426's finding — one MultiMesh per colour,
because `_load_mesh_parts()` splits by material — measured at full scale for the first time.

Two things follow, and they point in opposite directions:

- On *this* GPU it is worth nothing in milliseconds. Hiding the entire undergrowth layer is inside
  the noise band, and draw distance can shed 1,103 draw calls for 0.03 ms.
- On the low-end target it is the most CPU-shaped cost in the build. Draw submission is host work,
  10,087 nodes is 10,087 of them, and the machines this project ships to are the ones without the
  CPU to hide it. F-363's Mire tick and this share a bottleneck that no graphics preset can reach.

So: **schedule F-426's palette atlas, but rank it by the low-end measurement it does not yet have,
not by a millisecond figure taken here.** That is a hypothesis with a number attached, which is more
than it had before, and less than a result.

Note also that Forward+ does automatic instancing for identical mesh+material pairs, but **only for
opaque or alpha-tested materials** — an alpha-*blended* foliage material silently opts out of it.
For a world this fern-heavy, that is worth auditing.

**3.7 Occlusion culling.** Costs CPU every frame to rasterize occluders, and pays off in dense
interiors and cities. MIRE is an open island of gentle rolling hills with the sightlines that
implies. The docs are explicit that a wide-open scene with nothing large to hide behind can lose
more than it gains. Don't bake occluders here without a before/after.

**3.8 Baked lighting.** The closest thing to free lighting, and unavailable to us: MIRE's worlds are
procedurally generated per run and it has a full day/night cycle. There is nothing static to bake.
This is a permanent exclusion, not a backlog item.

### The CPU side

The frame is GPU-bound at the player's eye, but the *host* also runs simulation that no graphics
preset touches:

- **`MireGridSim.tick()` — ~16 ms at saturation, synchronously on the host main thread, every two
  seconds** (F-363). A whole frame, and 12–14 ms during ordinary deep-Cycle play. The two ways out
  are time-slicing it across the interval (cheap to reason about) or moving it to
  `WorkerThreadPool` (an authority and ordering change needing an ARCHITECTURE.md §2.2 decision).
  On the low-end target this is several times worse than the number above.
- **Chunk streaming** holds itself to a 4 ms frame budget, which is why settling takes real time.
- **Transparency** is sorted back-to-front per object; keep transparent surfaces few and separate
  small transparent sections onto their own materials rather than making a whole mesh blended.

---

## 4. Shipping defaults — fixed 2026-08-21 (F-452)

The largest single performance defect in the project was not in a renderer. `SettingsService`
shipped `graphics_preset: 2` (HIGH) and `dynamic_resolution: false` as factory defaults, so **every
machine — including the worst computer we target — booted into the full authored look with the
safety net switched off**, and stayed there until its owner found the settings menu. All the levers
in §3 existed; nothing was choosing them.

`core/render/hardware_tier.gd` now classifies the machine on first boot only, from what the driver
reports (adapter name, `RenderingDevice` device type, thread count, physical memory) — no benchmark,
no black screen, ties resolved downward. Software rasterizers and named entry-level integrated parts
go to LOW; other integrated GPUs and virtualised ones to MEDIUM; Apple Silicon and discrete cards to
HIGH. Low thread count and low memory each drop a tier and they stack. Anything below HIGH also gets
dynamic resolution on.

Once `user://settings.json` exists, the player's own choice wins forever, including a choice worse
than the one detection would make. `tools/hardware_tier_check.gd` proves both halves against
synthetic machines, so the check does not report the classification of whatever hardware runs it.

---

## 5. What to do next, in order

1. **Fix the traversal hitch** (F-454). Everything else on this list is a rounding error next to it:
   13 fps 1% low under motion against 81 standing still, on the fastest machine in the project, and
   no graphics preset reaches it. The work to audit is what happens per newly-resident chunk on the
   main thread — `ChunkStreamer`'s 4 ms budget and whether motion actually respects it, the mesher's
   `add_surface_from_arrays` pass, `ResourceScatterField`'s per-chunk placement, the nav bake, and
   the repeated `Harvestable` re-wiring the probe log shows firing throughout traversal. A 74 ms
   frame is a stall, not a budget overrun.
2. **Time-slice the Mire tick** (F-363). The other known main-thread stall: ~16 ms synchronously,
   every two seconds, and several times that on the low-end target. Time-slicing needs no
   architecture decision; moving it to `WorkerThreadPool` does (ARCHITECTURE.md §2.2).
3. **Get a low-end machine into the loop** (F-174). Every ratio here is from an M5 Pro, and the two
   most promising structural wins (§3.4, §3.6) are exactly the ones that measure as zero on fast
   hardware and matter on slow. This does not block the work; it blocks confidence.
4. **Put anti-aliasing in the preset table** (§3.2). 3.44 ms of 1% low, unmanaged, shipped at MSAA
   2x to every machine including the worst one. LOW should not be running it.
5. **Give LOW and MEDIUM FSR instead of bilinear** (§3.1). Same measured cost, sharper image. One
   line in the preset table plus a look on a moving camera.
6. **Bound the volumetric fog to `FogVolume` shapes** (§3.5). Cheap on this GPU, not on a weak one,
   and it moves the look toward the localized ground fog the art direction asks for.
7. **F-426's palette atlas** (§3.6) — 10,087 MultiMesh nodes at 2.2 instances each. Rank it once a
   low-end machine has measured it, not before.
8. **Fix `render_census`'s LOD gap report** (F-352) so it attributes ring-based chunk LOD separately
   and stops flagging a lever the terrain manages a different way as missing.

Anything added to this list needs a measurement next to it. This project has three times acted on a
performance number that described a different world than the one it claimed to.

---

## Sources

Godot's own documentation is the primary reference for §3; the measurements are ours.

- [Optimizing 3D performance — godot-docs](https://github.com/godotengine/godot-docs/blob/master/tutorials/performance/optimizing_3d_performance.rst)
- [Visibility ranges (HLOD) — Godot Engine documentation](https://docs.godotengine.org/en/stable/tutorials/3d/visibility_ranges.html)
- [Occlusion culling — Godot Engine documentation](https://trinovantes.github.io/godot-docs/tutorials/3d/occlusion_culling.html)
- [Volumetric fog and fog volumes — Godot Engine documentation](https://docs.godotengine.org/en/stable/tutorials/3d/volumetric_fog.html)
- [Godot 3D Optimization Guide (2026) — StraySpark](https://www.strayspark.studio/blog/godot-3d-optimization-guide-2026)
- [MeshInstance3D vs. MultiMesh in Godot 4](https://bitsoulhosting.com/marketplace/blog/meshinstance3d-vs-multimesh-godot-4-rendering-guide)
