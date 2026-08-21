extends RefCounted

## One benchmark scene's worth of frame timings, and the statistics the report quotes from them.
##
## Split out of the runner so the maths is testable without a renderer: `tools/benchmark_check.gd`
## feeds it synthetic frame times and asserts the 1% low, and nothing about that test needs a
## window, a world, or thirty seconds. Everything here is pure accumulation — the sampler never
## reads the clock itself, the caller passes the delta it observed.
##
## The metric definitions are deliberately the SAME ones `tools/perf_probe.gd` reports, because two
## instruments in one project that both say "1% low" and mean different things is how a number
## stops being comparable (docs/PERFORMANCE.md §1). If you change a definition here, change it
## there, and say so in that file.
##
## AUTHORITY: none (docs/ARCHITECTURE.md §2.2, "VFX, audio, camera, UI" row). Measuring this
## machine's frame rate is local presentation data; it is never sent anywhere.

## Frames dropped at the start of every scene before anything is recorded. Arriving in a scene
## re-renders the shadow atlas, walks draw-policy state and compiles whatever shaders that view
## needed for the first time; that transient belongs to the *transition*, not to the scene, and it
## lands squarely in the 1% tail if it is measured. Same reasoning and same count as
## `perf_probe.DISCARD_FRAMES`.
const DISCARD_FRAMES: int = 15

## The smallest tail the 1% low is ever averaged over. At 60 fps a 6 s scene is ~360 frames, so the
## worst 1% is three frames; below that the number is one unlucky hitch rather than a measurement.
const MIN_TAIL_FRAMES: int = 3

## Frame times above this are not frames, they are the game being suspended — an OS sleep, a window
## drag, the player alt-tabbing away. Recording them would let one interruption decide the whole
## recommendation, and the recommendation is the point of this system. They are counted and
## reported instead, so a run that lost frames this way can say so rather than quietly lying.
const STALL_MS: float = 500.0

var _deltas: PackedFloat64Array = PackedFloat64Array()
var _gpu_ms_total: float = 0.0
var _cpu_ms_total: float = 0.0
var _draws_total: float = 0.0
var _primitives_total: float = 0.0
var _discarded: int = 0
var _stalls: int = 0
## The engine reports viewport render times in a unit that has changed across versions; the scale
## is anchored on the first read that is implausibly large. See `_normalise_render_time()`.
var _render_time_scale: float = 1.0


## Records one frame. `delta_ms` is wall-clock time since the previous recorded frame; the renderer
## counters are this frame's, read by the caller from `RenderingServer`/`Performance`.
func record(delta_ms: float, gpu_ms: float, cpu_ms: float, draws: float, primitives: float) -> void:
	if _discarded < DISCARD_FRAMES:
		_discarded += 1
		return
	if delta_ms >= STALL_MS:
		_stalls += 1
		return
	_deltas.append(delta_ms)
	_gpu_ms_total += _normalise_render_time(gpu_ms)
	_cpu_ms_total += _normalise_render_time(cpu_ms)
	_draws_total += draws
	_primitives_total += primitives


func frame_count() -> int:
	return _deltas.size()


## The scene's numbers. Safe to call on an empty sampler — a scene that was cut short before it
## recorded anything returns zeros and `frames: 0`, which the report shows as "not measured"
## rather than as a machine that renders at zero fps.
func stats() -> Dictionary:
	var count: int = _deltas.size()
	if count == 0:
		return {
			"frames": 0, "stalls": _stalls, "fps": 0.0, "median_ms": 0.0, "p95_ms": 0.0,
			"low1_ms": 0.0, "low1_fps": 0.0, "gpu_ms": 0.0, "cpu_ms": 0.0,
			"draws": 0.0, "mprims": 0.0,
		}
	var sorted: PackedFloat64Array = _deltas.duplicate()
	sorted.sort()
	var low1_ms: float = _worst_percent_mean(sorted)
	var total_ms: float = 0.0
	for value: float in sorted:
		total_ms += value
	return {
		"frames": count,
		"stalls": _stalls,
		# Frames divided by the time those frames actually took, so a scene that lost time to a
		# stall reports the rate it rendered at rather than one diluted by the suspension.
		"fps": 1000.0 * float(count) / maxf(total_ms, 0.001),
		"median_ms": sorted[count / 2],
		"p95_ms": sorted[mini(count - 1, int(float(count) * 0.95))],
		# THE HEADLINE. The mean of the worst 1% of frames, not the median and not a single 99th
		# percentile sample: a median describes the smooth stretches, and what a player feels as
		# the game being bad is the worst one frame in a hundred — a chunk arriving, the Mire
		# tick, a wave spawning. A single percentile sample swung 20 ms between identical runs,
		# which is why this is a mean of the tail (docs/PERFORMANCE.md §1, rule 1).
		"low1_ms": low1_ms,
		"low1_fps": 1000.0 / maxf(low1_ms, 0.001),
		"gpu_ms": _gpu_ms_total / float(count),
		"cpu_ms": _cpu_ms_total / float(count),
		"draws": _draws_total / float(count),
		"mprims": _primitives_total / float(count) / 1e6,
	}


func _worst_percent_mean(sorted_deltas: PackedFloat64Array) -> float:
	var count: int = sorted_deltas.size()
	if count == 0:
		return 0.0
	var tail: int = mini(count, maxi(MIN_TAIL_FRAMES, int(float(count) * 0.01)))
	var total: float = 0.0
	for i: int in range(count - tail, count):
		total += sorted_deltas[i]
	return total / float(tail)


## Anchors the viewport render-time unit on the first implausible read. A fullscreen frame
## plausibly costs 0.05..200 ms, so anything larger is microseconds or nanoseconds and is scaled
## down until it lands in range. Mirrors `perf_probe._render_time_ms()`.
func _normalise_render_time(raw: float) -> float:
	if raw <= 0.0:
		return 0.0
	if _render_time_scale == 1.0 and raw > 200.0:
		_render_time_scale = 0.001 if raw < 200000.0 else 0.000001
	return raw * _render_time_scale
