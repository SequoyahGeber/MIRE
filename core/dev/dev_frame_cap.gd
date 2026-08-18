extends Node

## DevFrameCap — autoload. A runtime frame-rate knob for editor and debug runs. It caps NOTHING by
## default; it exists so the cap can be reached for without an editor restart, and so task 7.5's
## settings menu has one seam to hook into rather than scattering `Engine.max_fps` writes around.
##
## WHY IT DEFAULTS TO UNCAPPED (F-066). Play Scene cost roughly 2.2 CPU cores on an M5 Pro for a
## greybox level, and almost none of it was our rendering — at a 4800x2700 backing store, turning off
## the per-frame atmosphere re-apply, volumetric fog, every FogVolume, glow, the 4-split sun shadows
## AND the cloud deck together bought back 0.08 ms per frame. Roughly half the total was the editor
## compositing the *embedded* game window on top of its own UI at the game's frame rate. Turning off
## `run/window_placement/game_embed_mode` removed that half outright: the editor fell from ~105% CPU
## to its ~6.5% idle.
##
## This file briefly defaulted to 60 fps as well. That was over-correction — it halved the frame rate
## of a first-person game to save a load the un-embedding had already dealt with, and a game using
## about one core is not pathological. So the default is now Godot's own: no cap, vsync decides,
## which is exactly what a shipped build does. Dev matching retail is worth something on its own.
##
## The knob is still here because the trade is real and measured, on a 120 Hz panel:
##     uncapped (vsync 120)  120 fps  ~104% CPU
##     fps_cap 60             60 fps   ~60% CPU
## `fps_cap 60` in the debug console when the laptop gets hot; `fps_cap 0` to go back.
##
## AUTHORITY: none. Frame rate is presentation, local to one process, and decides nothing. Peers
## already run at different frame rates — the one system that cared, Steam's callback pump (F-025),
## is why simulation lives on the physics tick rather than the rendered frame.

## `Engine.max_fps = 0` means "no cap", which is both the engine default and what retail gets.
const UNCAPPED: int = 0
## What `fps_cap` with no argument offers as the cooler alternative, and what F-066 measured.
const SUGGESTED_COOL_FPS: int = 60


func _ready() -> void:
	if not OS.has_feature("editor"):
		return
	# Nothing to apply: the default IS the engine default. Announce the knob instead, so the trade is
	# discoverable from the Output panel rather than only from this file.
	if Engine.max_fps == UNCAPPED:
		MireLog.info(&"dev", "frame rate uncapped (vsync decides) — `fps_cap %d` if the machine "
			% SUGGESTED_COOL_FPS + "runs hot, see F-066")
	else:
		MireLog.info(&"dev", "frame cap %d fps, set explicitly before autoloads ran" % Engine.max_fps)
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
		return "frame rate is %s (try `fps_cap %d` to halve GPU/CPU load)" % [
			_describe(), SUGGESTED_COOL_FPS]
	if not args[0].is_valid_int():
		return "usage: fps_cap [n]  — n is a whole number of frames per second, 0 uncaps"
	set_cap(int(args[0]))
	return "frame rate is now %s" % _describe()


func _describe() -> String:
	return "uncapped (vsync decides)" if Engine.max_fps == UNCAPPED else "capped to %d fps" % Engine.max_fps
