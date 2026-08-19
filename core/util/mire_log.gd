class_name MireLog
extends RefCounted

## Channelled logging. Static, so nothing has to hold a reference and it costs nothing to call from
## anywhere: MireLog.write(&"net", "peer %d joined" % id)
##
## Network authority: none — logging is CLIENT-LOCAL and is never replicated.
##
## The point of channels is that you can leave the logging in. Netcode debugging in particular means
## turning one firehose on for ten minutes and off again; deleting and re-adding print() statements
## is a quota expense we should never pay twice.

enum Level { DEBUG, INFO, WARN, ERROR }

## Channels are just StringNames — declare new ones here so they show up in the console and overlay.
const CHANNELS: Array[StringName] = [
	&"net", &"world", &"mire", &"combat", &"harvest", &"inventory", &"ai", &"perf", &"gen", &"ui", &"content",
	&"health", &"powerup", &"reward",
]

## Lines kept in memory for the console to display on open.
const HISTORY_LIMIT: int = 400

static var _enabled: Dictionary[StringName, bool] = {}
static var _history: Array[String] = []
static var _sinks: Array[Callable] = []
static var _initialised: bool = false


static func _init_channels() -> void:
	if _initialised:
		return
	_initialised = true
	# On in dev, off in exported release builds. Individual channels are toggled at runtime from
	# the console: `log net off`
	var default_on: bool = OS.is_debug_build()
	for channel: StringName in CHANNELS:
		_enabled[channel] = default_on


static func write(channel: StringName, message: String, level: Level = Level.INFO) -> void:
	_init_channels()

	# Warnings and errors always get through, whatever the channel is set to. If it matters enough
	# to be an error, it matters enough to be seen.
	if level < Level.WARN and not _enabled.get(channel, false):
		return

	var line: String = "[%s] %s: %s" % [_level_name(level), channel, message]

	_history.append(line)
	if _history.size() > HISTORY_LIMIT:
		_history.remove_at(0)

	match level:
		Level.ERROR:
			push_error(line)
		Level.WARN:
			push_warning(line)
		_:
			print(line)

	for sink: Callable in _sinks:
		if sink.is_valid():
			sink.call(line, level)


static func debug(channel: StringName, message: String) -> void:
	write(channel, message, Level.DEBUG)


static func info(channel: StringName, message: String) -> void:
	write(channel, message, Level.INFO)


static func warn(channel: StringName, message: String) -> void:
	write(channel, message, Level.WARN)


static func error(channel: StringName, message: String) -> void:
	write(channel, message, Level.ERROR)


static func set_enabled(channel: StringName, enabled: bool) -> bool:
	_init_channels()
	if not _enabled.has(channel):
		return false
	_enabled[channel] = enabled
	return true


static func is_enabled(channel: StringName) -> bool:
	_init_channels()
	return _enabled.get(channel, false)


static func channel_states() -> Dictionary[StringName, bool]:
	_init_channels()
	return _enabled.duplicate()


static func history() -> Array[String]:
	return _history.duplicate()


## Register a listener that receives every emitted line — how the console mirrors the log.
static func add_sink(sink: Callable) -> void:
	if not _sinks.has(sink):
		_sinks.append(sink)


static func remove_sink(sink: Callable) -> void:
	_sinks.erase(sink)


static func _level_name(level: Level) -> String:
	match level:
		Level.DEBUG:
			return "dbg"
		Level.WARN:
			return "WARN"
		Level.ERROR:
			return "ERR"
		_:
			return "info"
