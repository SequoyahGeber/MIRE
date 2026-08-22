extends RefCounted

## Which graphics preset a machine should get the FIRST time it launches MIRE, read off the
## hardware rather than assumed.
##
## Why this exists. `autoload/settings_service.gd` shipped `graphics_preset: 2` (HIGH) and
## `dynamic_resolution: false` as its factory defaults, which meant every machine — including the
## worst computer this project explicitly targets (F-174) — booted into the full authored look
## with the safety net switched off, and stayed there until its owner found the settings menu.
## `autoload/graphics_quality.gd` had already built every lever needed to survive on weak
## hardware; nothing was choosing them. The measured cost of that default, on the FASTEST machine
## in the project (M5 Pro, fullscreen 3024x1898, settled procedural island):
##
##     as shipped (HIGH)   7.18 ms   139 fps
##     preset medium       4.40 ms   226 fps
##     preset low          2.00 ms   485 fps
##
## A 3.6x spread between the ends of the preset table is the whole point of having one. Handing
## the bottom tier to a machine that needs the top one is the single largest performance defect
## the project can fix without touching a renderer.
##
## What this is NOT. It is not a benchmark and it does not run the game to find out — a first-boot
## benchmark costs the player a black screen and is wrong on any machine that is busy for the
## thirty seconds it samples. It is a cheap, boring classification from what the driver reports,
## deliberately biased toward the SAFE answer: an over-conservative first boot costs a player one
## trip to the settings menu to raise it, where an over-optimistic one costs them their first
## impression of the game at 20 fps. Ties go downward.
##
## It also only ever decides the FIRST boot. Once `user://settings.json` exists, the player's own
## choice is the answer forever, including a choice that is worse than what this would pick.
##
## AUTHORITY: none (docs/ARCHITECTURE.md §2.2, "VFX, audio, camera, UI" row). A preset is local
## presentation; peers on different tiers run the same simulation.

## Mirrors `GraphicsQuality.Preset`. Duplicated as plain ints rather than referenced, because this
## class is pure data classification and must be callable from a headless check with no autoloads.
const PRESET_LOW: int = 0
const PRESET_MEDIUM: int = 1
const PRESET_HIGH: int = 2

## Integrated parts whose names say "this is a laptop chip from the era we are targeting". Matched
## case-insensitively as substrings against the adapter name, so "Intel(R) UHD Graphics 620" and
## "Intel(R) HD Graphics 4000" both land. Apple Silicon is deliberately absent — it reports as an
## integrated GPU and is not one of these (see `_apple_silicon()`).
const WEAK_GPU_MARKERS: PackedStringArray = [
	"intel(r) hd graphics",
	"intel hd graphics",
	"intel(r) uhd graphics",
	"intel uhd graphics",
	"intel(r) iris",
	"intel iris",
	"llvmpipe",
	"softwarerasterizer",
	"microsoft basic render",
	"swiftshader",
]

## Suffixes that mark an Apple Silicon part as above the integrated class (F-609). Everything else
## on Apple Silicon — a bare "Apple M1", "Apple M3" — is a base chip and takes the integrated rule.
const APPLE_PRO_MARKERS: PackedStringArray = ["pro", "max", "ultra"]

## Below this, a machine is assumed to be doing something else with its cores too.
const WEAK_CPU_THREADS: int = 4
## Physical memory, in MiB, under which the machine gets dropped a tier. 8 GB is the floor a
## Forward+ scene with a 726 MB VRAM footprint is comfortable on; below it the OS is already
## paging against us.
const LOW_MEMORY_MIB: int = 7000


## The first-boot settings for this machine: `{preset: int, dynamic_resolution: bool,
## reason: String}`. `reason` is logged, not shown — a player who lands on LOW should be able to
## find out why from the console rather than assume the game is broken.
##
## `probe` lets `tools/hardware_tier_check.gd` feed synthetic machines through the same table the
## shipped game uses; production passes nothing and the real driver answers.
static func detect(probe: Dictionary = {}) -> Dictionary:
	var machine: Dictionary = probe if not probe.is_empty() else read_machine()
	var adapter: String = str(machine.get("adapter_name", "")).to_lower()
	var device_type: int = int(machine.get("device_type", RenderingDevice.DEVICE_TYPE_OTHER))
	var threads: int = int(machine.get("cpu_threads", 8))
	var memory_mib: int = int(machine.get("memory_mib", 16384))

	var preset: int = PRESET_HIGH
	var reasons: PackedStringArray = []

	# 1. The GPU class. A software rasterizer or a named weak part is not a "maybe" — it goes
	#    straight to the floor, because those machines cannot afford the authored look at any
	#    resolution scale.
	if _matches(adapter, WEAK_GPU_MARKERS) or device_type == RenderingDevice.DEVICE_TYPE_CPU:
		preset = PRESET_LOW
		reasons.append("GPU '%s' is a software or entry-level integrated part"
			% machine.get("adapter_name", "?"))
	elif device_type == RenderingDevice.DEVICE_TYPE_INTEGRATED_GPU and not _apple_silicon_pro(adapter):
		# Modern integrated (Radeon 780M, Arc, the Steam Deck) plays this fine at MEDIUM's 0.77
		# render scale and cannot hold HIGH's.
		#
		# F-609: this used to exclude ALL Apple Silicon, on the reasoning that it "reports
		# integrated and is not in that class". That is true of the Pro/Max/Ultra parts and false
		# of the base chips, and the rule was written on a Pro-class machine — the exact shape of
		# generalising from the development hardware. A base M1 has 7-8 GPU cores against an
		# M4 Max's 40, and in a MacBook Air it is **fanless**, so it holds its clocks for five to
		# ten minutes and then throttles for the rest of a session.
		#
		# Measured consequence, reported by Sequoyah from a real session on a friend's M1 Air:
		# 40-50 fps at 1080p, because the machine had been handed HIGH with dynamic resolution
		# off. Nothing else in the table caught it — 8 threads clears WEAK_CPU_THREADS and 8 GB
		# clears LOW_MEMORY_MIB — so the GPU rule was the only thing that could have.
		#
		# Pro/Max/Ultra keep HIGH: those are the parts the original exclusion was actually about.
		preset = PRESET_MEDIUM
		reasons.append("integrated GPU '%s'" % machine.get("adapter_name", "?"))
	elif device_type == RenderingDevice.DEVICE_TYPE_VIRTUAL_GPU:
		preset = PRESET_MEDIUM
		reasons.append("virtualised GPU")

	# 2. CPU and memory each drop one tier, and they stack: a dual-core with 4 GB is LOW even
	#    behind a discrete card, because the streamer and the Mire tick are main-thread work
	#    (F-363) and neither is helped by a GPU.
	if threads > 0 and threads < WEAK_CPU_THREADS:
		preset = maxi(PRESET_LOW, preset - 1)
		reasons.append("%d CPU thread(s)" % threads)
	if memory_mib > 0 and memory_mib < LOW_MEMORY_MIB:
		preset = maxi(PRESET_LOW, preset - 1)
		reasons.append("%.1f GB system memory" % (float(memory_mib) / 1024.0))

	if reasons.is_empty():
		reasons.append("discrete or Apple Silicon GPU '%s', %d threads"
			% [machine.get("adapter_name", "?"), threads])

	return {
		"preset": preset,
		# The safety net goes on for exactly the machines that might need it. On HIGH it would
		# only ever fire during a hitch, and a resolution that pulses on a machine which never
		# needed it to is a worse first impression than the hitch was.
		"dynamic_resolution": preset != PRESET_HIGH,
		"reason": ", ".join(reasons),
	}


## What the driver and OS say about this machine. Split out so `detect()` is pure and testable.
static func read_machine() -> Dictionary:
	var memory_mib: int = 0
	var memory: Dictionary = OS.get_memory_info()
	# `physical` is -1 on platforms that cannot report it; treat unknown as "do not penalise".
	var physical: int = int(memory.get("physical", -1))
	if physical > 0:
		memory_mib = physical / 1048576
	return {
		"adapter_name": RenderingServer.get_video_adapter_name(),
		"device_type": RenderingServer.get_video_adapter_type(),
		"cpu_threads": OS.get_processor_count(),
		"memory_mib": memory_mib,
	}


static func preset_name(preset: int) -> String:
	return ["low", "medium", "high"][clampi(preset, PRESET_LOW, PRESET_HIGH)]


## Apple Silicon reports `DEVICE_TYPE_INTEGRATED_GPU` and is nothing like the integrated parts
## that classification is meant to catch — an M-series base chip runs the shipped look above
## 100 fps. Matched on the vendor's own naming ("Apple M1 Pro", "Apple M5 Max").
static func _apple_silicon(adapter_lower: String) -> bool:
	return adapter_lower.begins_with("apple m") or adapter_lower.begins_with("apple a")


## The Apple Silicon parts that genuinely outrun the integrated class — "Apple M4 Pro", "Apple M2
## Max", "Apple M1 Ultra". A bare "Apple M1"/"Apple M3" is a base chip and does not.
##
## F-609. Matching on the suffix rather than on a chip list on purpose: a list would need editing
## for every generation Apple ships, and the failure mode of a stale list is that the newest base
## chip silently inherits HIGH — which is precisely the bug this replaces.
static func _apple_silicon_pro(adapter_lower: String) -> bool:
	if not _apple_silicon(adapter_lower):
		return false
	return _matches(adapter_lower, APPLE_PRO_MARKERS)


static func _matches(haystack: String, needles: PackedStringArray) -> bool:
	for needle: String in needles:
		if haystack.contains(needle):
			return true
	return false
