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
	# Migrated off DebugConsole.register()'s deprecation shim in task 3.16 — the catalog sweep's own
	# `commands --json` coverage check is what makes a leftover shim registration visible, so leaving
	# these two behind would have been the first thing it reported.
	var command_service: Node = get_node_or_null(^"/root/CommandService")
	if command_service == null:
		return
	command_service.call("register_spec", &"fps_cap", {
		# LOCAL: a frame cap is this machine's own rendering, not simulated state — nothing about it
		# belongs to the host, and a client capping its own frames must not need op.
		"scope": &"local",
		"args": [{"name": "cap", "type": &"int", "optional": true, "default": -1, "min": 0, "max": 1000}],
		"handler": _cmd_fps_cap,
		"help": "fps_cap [n] — show or set the frame cap; 0 uncaps (dev runs only)",
	})
	command_service.call("register_spec", &"vsync", {
		"scope": &"local",
		"args": [{"name": "state", "type": &"string", "optional": true, "default": ""}],
		"handler": _cmd_vsync,
		"help": "vsync [on|off] — off lets the fps counter exceed the panel's refresh rate (F-090)",
	})


## Vsync stays ON by default — retail-correct, tear-free, and F-090 measured its cost at zero
## while the frame is slower than the panel. The knob exists because once the frame IS faster
## than the panel, vsync is what pins the fps counter to the refresh rate, and every future
## "why is it exactly 120" investigation should be one console command, not a project edit.
## CommandSpec handler shape since task 3.16: (ctx, args) -> CommandResult, with the arguments
## already parsed and validated. The hand-rolled "usage:" string the shim version needed is gone —
## a typed spec produces it (COMMANDS.md §2.2).
func _cmd_vsync(_ctx: Dictionary, args: Dictionary) -> Dictionary:
	var state: String = String(args.get("state", "")).strip_edges().to_lower()
	if not state.is_empty():
		if state != "on" and state != "off":
			return {"ok": false, "message": "usage: vsync [on|off]", "data": {}}
		DisplayServer.window_set_vsync_mode(
			DisplayServer.VSYNC_ENABLED if state == "on" else DisplayServer.VSYNC_DISABLED)
	var enabled: bool = DisplayServer.window_get_vsync_mode() != DisplayServer.VSYNC_DISABLED
	var message: String = "vsync is on — frame rate tops out at the panel's %.0f Hz" \
		% DisplayServer.screen_get_refresh_rate() if enabled \
		else "vsync is off — frame rate is uncapped (fps_cap still applies if set)"
	return {"ok": true, "message": message, "data": {"vsync": enabled}}


## `cap` defaults to -1 rather than 0, because 0 is a MEANINGFUL value here (uncap) and the spec
## needs a sentinel for "no argument given, just tell me the current cap".
func _cmd_fps_cap(_ctx: Dictionary, args: Dictionary) -> Dictionary:
	var cap: int = int(args.get("cap", -1))
	if cap < 0:
		return {"ok": true, "message": "frame rate is %s (try `fps_cap %d` to halve GPU/CPU load)"
			% [_describe(), SUGGESTED_COOL_FPS], "data": {"cap": Engine.max_fps}}
	set_cap(cap)
	return {"ok": true, "message": "frame rate is now %s" % _describe(),
		"data": {"cap": Engine.max_fps}}


func _describe() -> String:
	return "uncapped (vsync decides)" if Engine.max_fps == UNCAPPED else "capped to %d fps" % Engine.max_fps
