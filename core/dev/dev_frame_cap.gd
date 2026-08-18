extends Node

## DevFrameCap — autoload. Caps the frame rate of editor and debug runs, and only those.
##
## WHY THIS EXISTS (F-066). Pressing Play Scene on a 120 Hz laptop panel cost roughly 2.2 CPU cores
## and left the GPU at 91% device utilization — on an M5 Pro, for a greybox level. Almost none of
## that is our rendering: `tools/perf_probe.gd` renders this project's real level at a 4800x2700
## backing store, four times the shipped pixel count, and turning off the per-frame atmosphere
## re-apply, volumetric fog, every FogVolume, glow, the 4-split sun shadows AND the cloud deck
## together gives back 0.08 ms per frame. The cost is per-FRAME overhead, not per-pixel work, and
## nothing in the project capped how many frames we asked for.
##
## Capping frames is the one lever that cuts BOTH processes at once. The editor composites the
## embedded game window on top of its own UI at the game's frame rate, so halving the game's frames
## halves the editor's compositing too — which is why this is worth more than any renderer setting
## we could turn down.
##
## RETAIL IS DELIBERATELY UNTOUCHED. `OS.has_feature("editor")` is true for an editor run and for a
## debug export, false in a release export. A shipped build keeps Godot's default (vsync-limited,
## uncapped), because what frame rate a player's machine should target is a product decision and
## belongs in a video-settings menu, not silently in an autoload. That menu does not exist yet;
## F-066 records the gap.
##
## AUTHORITY: none. Frame rate is presentation, local to one process, and decides nothing. Peers may
## run at different frame rates and already do — the one system that cared, Steam's callback pump
## (F-025), is why simulation lives on the physics tick rather than the rendered frame.

## Frames per second for editor and debug runs. 60 is half the cost of a 120 Hz panel and is still
## well above the physics tick, so nothing about how the game behaves changes.
const DEFAULT_DEV_MAX_FPS: int = 60
## `Engine.max_fps = 0` means "no cap", which is what a release build gets.
const UNCAPPED: int = 0


func _ready() -> void:
	if not OS.has_feature("editor"):
		return
	# Defer to anything that already has an opinion. Godot applies both `--max-fps` and
	# `application/run/max_fps` before autoloads run, so a non-zero value here was asked for
	# deliberately — by someone testing high-frame-rate behaviour, or by a project setting added
	# later — and silently overriding it would make that flag look broken.
	if Engine.max_fps != UNCAPPED:
		MireLog.info(&"dev", "frame cap left at %d fps (set explicitly, not by DevFrameCap)"
			% Engine.max_fps)
		_register_commands()
		return
	Engine.max_fps = DEFAULT_DEV_MAX_FPS
	MireLog.info(&"dev", "frame cap %d fps (editor/debug run only — F-066)" % DEFAULT_DEV_MAX_FPS)
	_register_commands()


## Public so a check can drive it, and so the console command below has something to call.
func set_cap(fps: int) -> void:
	Engine.max_fps = maxi(fps, UNCAPPED)


func cap() -> int:
	return Engine.max_fps


func _register_commands() -> void:
	var console: Node = get_node_or_null(^"/root/DebugConsole")
	if console == null or not console.has_method("register"):
		return
	console.call("register", &"fps_cap", _cmd_fps_cap,
		"fps_cap [n] — show or set the frame cap; 0 uncaps (dev runs only)")


func _cmd_fps_cap(args: PackedStringArray) -> String:
	if args.is_empty():
		return "frame cap is %s" % ("uncapped" if Engine.max_fps == UNCAPPED else "%d fps" % Engine.max_fps)
	if not args[0].is_valid_int():
		return "usage: fps_cap [n]  — n is a whole number of frames per second, 0 uncaps"
	set_cap(int(args[0]))
	return "frame cap is now %s" % ("uncapped" if Engine.max_fps == UNCAPPED else "%d fps" % Engine.max_fps)
