extends SceneTree

## Proves `core/render/hardware_tier.gd` classifies machines the way F-452 says it does, and that
## `SettingsService` only ever consults it on a genuine first boot.
##
##   .agent/bin/agent godot --script tools/hardware_tier_check.gd
##
## Every case is a synthetic machine fed through `detect(probe)`, so this runs anywhere and does
## not report the classification of whatever hardware happens to be running the check — which is
## the exact mistake F-174 recorded about every other perf instrument in this repo.

const HardwareTier := preload("res://core/render/hardware_tier.gd")
const SettingsSave := preload("res://core/save/settings_save.gd")

var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_check_table()
	_check_first_boot_only()
	_check_real_machine_classifies()

	print("")
	# `agent verify` reads this line and fails the check outright when it is absent — an explicit,
	# greppable verdict is what stops a half-finished or crashed run passing by saying nothing
	# (F-293). This check reported in prose but never in that shape, so it was red however green
	# it ran (F-555).
	print("HARDWARE_TIER_CHECK failures=%d" % failures.size())
	if failures.is_empty():
		print("HARDWARE_TIER_OK")
		quit(0)
		return
	for failure: String in failures:
		print("  FAIL  %s" % failure)
	print("HARDWARE_TIER_FAIL %d" % failures.size())
	quit(1)


func _check_table() -> void:
	print("=== hardware tier classification ===")
	# name, probe, expected preset, expected dynamic resolution
	var cases: Array = [
		["M5 Pro (Apple Silicon)", {
			"adapter_name": "Apple M5 Pro", "cpu_threads": 12, "memory_mib": 24576,
			"device_type": RenderingDevice.DEVICE_TYPE_INTEGRATED_GPU,
		}, HardwareTier.PRESET_HIGH, false],
		["RTX 4070 desktop", {
			"adapter_name": "NVIDIA GeForce RTX 4070", "cpu_threads": 16, "memory_mib": 32768,
			"device_type": RenderingDevice.DEVICE_TYPE_DISCRETE_GPU,
		}, HardwareTier.PRESET_HIGH, false],
		["Steam Deck class integrated", {
			"adapter_name": "AMD Radeon Graphics (RADV VANGOGH)", "cpu_threads": 8,
			"memory_mib": 16384, "device_type": RenderingDevice.DEVICE_TYPE_INTEGRATED_GPU,
		}, HardwareTier.PRESET_MEDIUM, true],
		["2017 office laptop", {
			"adapter_name": "Intel(R) UHD Graphics 620", "cpu_threads": 4, "memory_mib": 8192,
			"device_type": RenderingDevice.DEVICE_TYPE_INTEGRATED_GPU,
		}, HardwareTier.PRESET_LOW, true],
		["software rasterizer", {
			"adapter_name": "llvmpipe (LLVM 15.0.7, 256 bits)", "cpu_threads": 8,
			"memory_mib": 16384, "device_type": RenderingDevice.DEVICE_TYPE_CPU,
		}, HardwareTier.PRESET_LOW, true],
		# The stacking rule: a discrete card does not save a machine that has nothing else.
		["discrete card, 2 threads, 4 GB", {
			"adapter_name": "NVIDIA GeForce GTX 1050", "cpu_threads": 2, "memory_mib": 4096,
			"device_type": RenderingDevice.DEVICE_TYPE_DISCRETE_GPU,
		}, HardwareTier.PRESET_LOW, true],
		# One penalty alone is one tier, not two.
		["discrete card, 6 GB memory", {
			"adapter_name": "NVIDIA GeForce GTX 1650", "cpu_threads": 8, "memory_mib": 6144,
			"device_type": RenderingDevice.DEVICE_TYPE_DISCRETE_GPU,
		}, HardwareTier.PRESET_MEDIUM, true],
		# Unknown/unreported hardware must not be punished into LOW by a -1 memory read.
		["driver reports nothing useful", {
			"adapter_name": "", "cpu_threads": 0, "memory_mib": 0,
			"device_type": RenderingDevice.DEVICE_TYPE_OTHER,
		}, HardwareTier.PRESET_HIGH, false],
	]
	for case: Array in cases:
		var label: String = case[0]
		var result: Dictionary = HardwareTier.detect(case[1] as Dictionary)
		var got: int = int(result["preset"])
		var got_dynamic: bool = bool(result["dynamic_resolution"])
		print("  %-32s -> %-6s %s" % [
			label, HardwareTier.preset_name(got), "+dynres" if got_dynamic else ""])
		if got != int(case[2]):
			failures.append("%s classified '%s', expected '%s'" % [
				label, HardwareTier.preset_name(got), HardwareTier.preset_name(int(case[2]))])
		if got_dynamic != bool(case[3]):
			failures.append("%s dynamic resolution %s, expected %s" % [
				label, got_dynamic, case[3]])


## The detection must be a FIRST-boot default and nothing more. A player who chose LOW on a
## monster machine, or HIGH on a weak one, keeps that choice through every later launch — the
## regression this guards against is a "helpful" re-detect that overwrites it.
func _check_first_boot_only() -> void:
	print("\n=== first boot only ===")
	var settings: Node = root.get_node_or_null(^"/root/SettingsService")
	if settings == null:
		failures.append("SettingsService autoload is not registered")
		return
	var probe_path: String = "user://_hardware_tier_check_settings.json"
	if FileAccess.file_exists(probe_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(probe_path))

	# A saved choice that the hardware would never pick on its own.
	var saved: Dictionary = SettingsSave._default_data()
	saved[&"graphics_preset"] = HardwareTier.PRESET_LOW
	saved[&"dynamic_resolution"] = false
	if not SettingsSave.save_data(saved, probe_path):
		failures.append("could not write the probe settings file")
		return

	settings.set("save_path", probe_path)
	settings.call("_load")
	var loaded: int = int(settings.call("graphics_preset"))
	print("  saved preset 'low' reloaded as '%s'" % HardwareTier.preset_name(loaded))
	if loaded != HardwareTier.PRESET_LOW:
		failures.append("a saved preset was overwritten by hardware detection — it must win")
	if bool(settings.call("dynamic_resolution")):
		failures.append("a saved dynamic-resolution choice of false was overwritten")

	# ...and with no file at all, detection decides.
	DirAccess.remove_absolute(ProjectSettings.globalize_path(probe_path))
	settings.call("_load")
	var detected: Dictionary = HardwareTier.detect()
	var fresh: int = int(settings.call("graphics_preset"))
	print("  no settings file -> '%s' (detected '%s')" % [
		HardwareTier.preset_name(fresh), HardwareTier.preset_name(int(detected["preset"]))])
	if fresh != int(detected["preset"]):
		failures.append("first boot loaded '%s' but detection says '%s'" % [
			HardwareTier.preset_name(fresh), HardwareTier.preset_name(int(detected["preset"]))])

	# Leave the real service pointing back at the real file, whatever happens next in this run.
	settings.set("save_path", SettingsSave.SAVE_PATH)


## `read_machine()` has to survive whatever the platform actually reports — a headless run has no
## video adapter, and that must classify rather than crash.
func _check_real_machine_classifies() -> void:
	print("\n=== this machine ===")
	var machine: Dictionary = HardwareTier.read_machine()
	var result: Dictionary = HardwareTier.detect()
	print("  %s | %d thread(s) | %d MiB -> %s (%s)" % [
		machine.get("adapter_name", "?"), int(machine.get("cpu_threads", 0)),
		int(machine.get("memory_mib", 0)),
		HardwareTier.preset_name(int(result["preset"])), result["reason"]])
	if int(result["preset"]) < HardwareTier.PRESET_LOW \
			or int(result["preset"]) > HardwareTier.PRESET_HIGH:
		failures.append("detect() returned a preset outside the table")
