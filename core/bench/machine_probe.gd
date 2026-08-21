extends RefCounted

## What state the machine was in while the benchmark measured it.
##
## ## Why a benchmark needs this at all
##
## A frame rate is only meaningful together with the conditions that produced it. A MacBook on
## battery, in Low Power Mode, with the CPU already speed-limited by heat, will measure maybe half
## what the same machine measures plugged in and cool — and the recommendation drawn from that run
## is then wrong for every minute the player spends plugged in, which is most of them. The
## benchmark's own rules already refuse to measure a world that is still streaming or a frame rate
## pinned to the refresh rate (docs/PERFORMANCE.md §1); measuring a machine that is throttled and
## reporting it as the machine is the same class of mistake, and it is the one a player is most
## likely to make by accident.
##
## So this is read TWICE — once before the first scene and once after the last — and the report
## carries both, plus what changed in between. A run that started unthrottled and ended at a 60%
## CPU speed limit did not measure one machine; it measured a machine getting hot, and the results
## screen says so rather than quietly recommending HIGH.
##
## ## What is actually readable, and what is not
##
## **Temperature is not available.** Reading the SMC on macOS needs root (`powermetrics --samplers
## smc` prompts for a password), and a game may not ask a player for their password to draw a chart.
## So this file reports no temperature at all rather than a made-up one. What it reports instead is
## the thing a temperature would have been used to infer: `pmset -g therm`'s `CPU_Speed_Limit`, which
## is macOS stating outright that it is throttling the CPU. That is strictly better than a number in
## degrees, because it is the effect rather than a proxy for it.
##
## **macOS is implemented; Windows and Linux are honestly blank.** Every source below is a macOS
## command, verified against this machine's real output rather than written from memory. Windows is
## the larger share of players and its equivalents exist (`powercfg`, WMI's `Win32_Battery` and
## `MSAcpi_ThermalZoneTemperature`), but nobody here can run them, and an unverified parser that
## silently returns garbage is worse than a field marked unsupported — the garbage would be quoted
## in bug reports as fact. Filed as its own finding; adding it is one function.
##
## AUTHORITY: none (docs/ARCHITECTURE.md §2.2, "VFX, audio, camera, UI" row). Reads local state,
## sends nothing anywhere.

## macOS `pmset -g`'s `powermode`, which is the machine's performance profile.
const POWER_MODE_NAMES: Dictionary = {
	0: "normal", 1: "low power", 2: "high power",
}

## Below this `CPU_Speed_Limit` percentage the machine is being actively held back and any number
## measured on it describes the throttling, not the hardware. 100 means unrestricted; macOS only
## reports the key at all once it has something to say.
const THROTTLE_LIMIT_PERCENT: int = 100

## A benchmark that drains this many battery percentage points is long enough that the machine's
## power budget may have shifted underneath it.
const BATTERY_DRIFT_POINTS: int = 5


## The whole snapshot: the fixed description of the machine plus its current, volatile state.
static func read() -> Dictionary:
	var machine: Dictionary = read_hardware()
	machine["power"] = read_power()
	return machine


## The parts that cannot change during a run. Safe to read once.
static func read_hardware() -> Dictionary:
	var memory: Dictionary = OS.get_memory_info()
	var physical: int = int(memory.get("physical", -1))
	var hardware: Dictionary = {
		"adapter_name": RenderingServer.get_video_adapter_name(),
		"adapter_type": RenderingServer.get_video_adapter_type(),
		"adapter_vendor": RenderingServer.get_video_adapter_vendor(),
		"driver": RenderingServer.get_video_adapter_api_version(),
		"os": "%s %s" % [OS.get_name(), OS.get_version()],
		"cpu": OS.get_processor_name(),
		"cpu_threads": OS.get_processor_count(),
		"memory_mib": (physical / 1048576) if physical > 0 else 0,
		"godot": String(Engine.get_version_info()["string"]),
		"refresh_hz": DisplayServer.screen_get_refresh_rate(),
		"screen_scale": DisplayServer.screen_get_scale(),
	}
	if OS.get_name() == "macOS":
		_read_macos_hardware(hardware)
	return hardware


## The parts that CAN change during a run, and the reason this file is read twice.
##
## `supported` is false on every platform whose sources are not implemented yet — a caller must
## check it rather than reading `ac_power: false` off a Windows machine and concluding it is on
## battery.
static func read_power() -> Dictionary:
	match OS.get_name():
		"macOS":
			return _read_macos_power()
		_:
			return {
				"supported": false,
				"reason": "power and thermal state are not read on %s yet" % OS.get_name(),
			}


## Everything about this machine's state that makes the numbers less trustworthy, in the words the
## player should see. Empty means nothing is wrong — which is what the screen wants to hear before
## it lets someone spend two minutes on a measurement.
static func warnings(power: Dictionary) -> PackedStringArray:
	var out: PackedStringArray = []
	if not bool(power.get("supported", false)):
		return out
	if not bool(power.get("ac_power", true)):
		out.append("Running on battery. Laptops cut GPU and CPU power on battery, so this will "
			+ "measure a slower machine than the one you play on when it is plugged in.")
	if int(power.get("power_mode", 0)) == 1:
		out.append("Low Power Mode is on. It caps performance deliberately — the benchmark would "
			+ "recommend settings for a machine that is being held back on purpose.")
	var limit: int = int(power.get("cpu_speed_limit", THROTTLE_LIMIT_PERCENT))
	if limit < THROTTLE_LIMIT_PERCENT:
		out.append("The CPU is already thermally limited to %d%% of its speed. Let the machine "
			% limit + "cool down first, or the result describes the heat rather than the hardware.")
	return out


## What moved between the snapshot taken before the first scene and the one taken after the last.
## The interesting case is a run that STARTED clean and ended throttled: every scene after the
## throttle began measured a different machine from the ones before it, and the suite's ordering
## means those are the night and combat scenes — the two the recommendation is most likely to turn
## on.
static func drift(before: Dictionary, after: Dictionary) -> Dictionary:
	if not bool(before.get("supported", false)) or not bool(after.get("supported", false)):
		return {"supported": false}
	var started: int = int(before.get("cpu_speed_limit", THROTTLE_LIMIT_PERCENT))
	var ended: int = int(after.get("cpu_speed_limit", THROTTLE_LIMIT_PERCENT))
	var notes: PackedStringArray = []
	if ended < started:
		notes.append("The CPU was throttled to %d%% of its speed during the benchmark (it started "
			% ended + "at %d%%). The later scenes — night and the wave — measured a machine that "
			% started + "was getting hot, so treat their numbers as a floor rather than a verdict.")
	elif ended < THROTTLE_LIMIT_PERCENT:
		notes.append("The CPU was thermally limited to %d%% throughout. These numbers are what "
			% ended + "this machine does when it is already warm.")
	if bool(before.get("ac_power", true)) != bool(after.get("ac_power", true)):
		notes.append("The power source changed while the benchmark was running, so the scenes "
			+ "were not all measured under the same power budget.")
	var drained: int = int(before.get("battery_percent", 0)) - int(after.get("battery_percent", 0))
	if drained >= BATTERY_DRIFT_POINTS:
		notes.append("The battery fell %d points during the run." % drained)
	return {
		"supported": true,
		"cpu_speed_limit_start": started,
		"cpu_speed_limit_end": ended,
		"throttled": ended < THROTTLE_LIMIT_PERCENT,
		"battery_drained": drained,
		"notes": notes,
	}


## One line for the pasteable report — the state a reader needs before they believe the table.
static func describe_power(power: Dictionary) -> String:
	if not bool(power.get("supported", false)):
		return String(power.get("reason", "power state unknown"))
	var parts: PackedStringArray = []
	parts.append("AC power" if bool(power.get("ac_power", true)) else "battery")
	if power.has("battery_percent") and int(power.get("battery_percent", -1)) >= 0:
		parts.append("%d%%%s" % [int(power["battery_percent"]),
			" charging" if bool(power.get("charging", false)) else ""])
	parts.append("%s mode" % String(POWER_MODE_NAMES.get(int(power.get("power_mode", 0)),
		"unknown")))
	var limit: int = int(power.get("cpu_speed_limit", THROTTLE_LIMIT_PERCENT))
	parts.append("CPU unthrottled" if limit >= THROTTLE_LIMIT_PERCENT
		else "CPU limited to %d%%" % limit)
	return " | ".join(parts)


# ── macOS ─────────────────────────────────────────────────────────────────────────────────────


## Core counts by performance level, which `OS.get_processor_count()` cannot express. On Apple
## Silicon the split between performance and efficiency cores is most of what predicts how the
## main-thread work — the streamer, the nav bake, the Mire tick — will behave, and a machine with
## four P-cores is a different machine from one with ten even when both report the same total.
static func _read_macos_hardware(into: Dictionary) -> void:
	var memsize: String = _run("sysctl", ["-n", "hw.memsize"]).strip_edges()
	if memsize.is_valid_int() and int(into.get("memory_mib", 0)) <= 0:
		into["memory_mib"] = int(memsize) / 1048576
	var performance_cores: String = _run("sysctl", ["-n", "hw.perflevel0.logicalcpu"]).strip_edges()
	var efficiency_cores: String = _run("sysctl", ["-n", "hw.perflevel1.logicalcpu"]).strip_edges()
	if performance_cores.is_valid_int():
		into["cpu_performance_cores"] = int(performance_cores)
	if efficiency_cores.is_valid_int():
		into["cpu_efficiency_cores"] = int(efficiency_cores)
	# The charger's wattage: a laptop on an underpowered adapter throttles under sustained load
	# even while it reads as "AC power", which is exactly the case that would otherwise look clean.
	# GPU core count and Metal level, which no Godot API exposes. On Apple Silicon the core count
	# is the single best predictor of what this machine will do with the frame — "Apple M5 Pro"
	# alone spans a 1.6x range of GPU configurations — so a benchmark result that omits it cannot
	# be compared with another machine's, which is most of what a shared benchmark is for.
	# ~270 ms, so it is read once at the start and never near a sample.
	for line: String in _run("system_profiler", ["SPDisplaysDataType"]).split("\n"):
		var display_line: String = line.strip_edges()
		if display_line.begins_with("Total Number of Cores:") and not into.has("gpu_cores"):
			var cores: String = display_line.split(":")[1].strip_edges()
			if cores.is_valid_int():
				into["gpu_cores"] = int(cores)
		elif display_line.begins_with("Metal Support:"):
			into["metal_support"] = display_line.split(":")[1].strip_edges()
		elif display_line.begins_with("Chipset Model:") and not into.has("chipset"):
			into["chipset"] = display_line.split(":")[1].strip_edges()

	var power_report: String = _run("system_profiler", ["SPPowerDataType"])
	for line: String in power_report.split("\n"):
		var trimmed: String = line.strip_edges()
		if trimmed.begins_with("Wattage (W):"):
			var value: String = trimmed.split(":")[1].strip_edges()
			if value.is_valid_int():
				into["adapter_watts"] = int(value)
		elif trimmed.begins_with("Condition:"):
			into["battery_condition"] = trimmed.split(":")[1].strip_edges()


## Parses the three `pmset` queries, all of which run in under 10 ms and none of which needs a
## password. Verified against this machine's real output on 2026-08-21 rather than written from
## memory — the formats below are quoted from it.
static func _read_macos_power() -> Dictionary:
	var state: Dictionary = {"supported": true}

	# `Now drawing from 'AC Power'` / `'Battery Power'`, then
	# ` -InternalBattery-0 (id=...)	11%; charging; 6:33 remaining present: true`
	var battery: String = _run("pmset", ["-g", "batt"])
	if battery.is_empty():
		# `OS.execute` is unavailable in a sandboxed build. Say so rather than reporting defaults
		# that read as facts.
		return {"supported": false, "reason": "this build cannot read the system power state"}
	state["ac_power"] = battery.contains("'AC Power'")
	for line: String in battery.split("\n"):
		var percent_at: int = line.find("%;")
		if percent_at < 0:
			continue
		var digits: String = ""
		for index: int in range(percent_at - 1, -1, -1):
			if not line[index].is_valid_int():
				break
			digits = line[index] + digits
		if digits.is_valid_int():
			state["battery_percent"] = int(digits)
		state["charging"] = line.contains("; charging")
		state["battery_present"] = true
		break
	if not state.has("battery_present"):
		# A desktop. Not "0% battery" — a distinction the warnings depend on.
		state["battery_present"] = false

	# `CPU_Speed_Limit 	= 70`, absent entirely when nothing is being limited: macOS prints
	# `Note: No CPU power status has been recorded` instead, which is the healthy case.
	state["cpu_speed_limit"] = THROTTLE_LIMIT_PERCENT
	for line: String in _run("pmset", ["-g", "therm"]).split("\n"):
		var trimmed: String = line.strip_edges()
		if not trimmed.begins_with("CPU_Speed_Limit"):
			continue
		var value: String = trimmed.split("=")[-1].strip_edges()
		if value.is_valid_int():
			state["cpu_speed_limit"] = int(value)

	# ` powermode            2` — 0 normal, 1 Low Power Mode, 2 High Power Mode.
	state["power_mode"] = 0
	for line: String in _run("pmset", ["-g"]).split("\n"):
		var trimmed: String = line.strip_edges()
		if not (trimmed.begins_with("powermode") or trimmed.begins_with("lowpowermode")):
			continue
		var parts: PackedStringArray = trimmed.split(" ", false)
		if parts.size() >= 2 and parts[1].is_valid_int():
			# `lowpowermode 1` and `powermode 1` mean the same thing across OS versions.
			state["power_mode"] = int(parts[1])
	return state


## Runs a read-only system query and returns its stdout, or an empty string if it could not run.
## Never called while frames are being sampled — every one of these blocks the main thread for a
## few milliseconds, which would land in the 1% tail and be attributed to the game.
static func _run(command: String, arguments: PackedStringArray) -> String:
	var output: Array = []
	if OS.execute(command, arguments, output, false, false) != 0:
		return ""
	return "\n".join(PackedStringArray(output))
