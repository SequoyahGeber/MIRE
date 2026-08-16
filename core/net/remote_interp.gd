class_name RemoteInterpolator
extends Node

## Draws a replicated node smoothly by rendering it slightly in the past — task 1.6.
##
## Network authority (docs/ARCHITECTURE.md §2.2): NONE, deliberately, and that is the whole design.
## This is the table's last row — "VFX, audio, camera, UI · client-local · never networked". It only
## ever writes to a node this peer does NOT own, it is only ever attached on the receiving side, and
## nothing it computes is sent anywhere. Two peers may draw the same remote player a few centimetres
## apart and that is correct: the authoritative value is whatever its owner last sent, and this only
## decides how the gap between two of those is painted.
##
## WHY THIS EXISTS WHEN `physics/common/physics_interpolation` IS ALREADY ON (D-026, F-004).
## Engine physics interpolation smooths the 60 Hz physics grid up to the render rate. Replication
## arrives at 30 Hz, at arbitrary idle-frame times, with jitter and occasional loss — a 33 ms
## staircase, which a 16.7 ms smoothing window cannot flatten, and which the engine could not
## jitter-buffer even in principle because it has no idea when a packet arrived. Different problem,
## different fix, and both are needed. They also actively FIGHT each other: the engine would
## re-interpolate this node's per-frame output across physics ticks and add a tick of lag on top, so
## configure() turns engine interpolation OFF for the subtree it drives.
##
## HOW IT WORKS. Every arriving state goes into a small ring buffer stamped with its ARRIVAL time.
## Each frame we render the buffer as it stood `_delay` seconds ago, lerping between the two
## snapshots that bracket that instant. `_delay` is about two send intervals, so one lost packet
## still has a future snapshot to aim at, and it is derived from the observed arrival rate rather
## than configured — which is what makes this work unchanged for 15 Hz enemies (F-004) as well as
## 30 Hz players.
##
## THE COST, stated plainly: a remote player is drawn ~66 ms behind where its owner has it. That is
## the trade every game of this shape makes, and it is invisible next to the juddering it removes.
## Nothing gameplay-authoritative may read the interpolated transform — the host's speed check in
## player_net.gd reads the replicated value, which is untouched by this node, and must keep doing so.
##
## Attach it with the NetInterp autoload rather than by hand; see autoload/net_interp.gd.


# ── Tuning. Client-local presentation, so these deliberately do NOT live in NetConfig ─────────────
#
# Every constant in NetConfig has to be byte-identical in every process, because a peer that
# disagrees desyncs. None of these are that: they change only how this machine paints a frame, two
# peers may hold different values forever with no consequence, and a player on a bad connection
# should be free to buy smoothness with latency. That is a genuine difference in kind, not a
# shortcut — do not move them.

## How many send intervals of history we stay behind. Two is the standard choice: it keeps a future
## snapshot in hand across a single lost packet, which is the common case, without buying latency for
## the rare one.
const DELAY_INTERVALS: float = 2.0

## Floor and ceiling on the derived delay. The floor is one 30 Hz frame — below it a single late
## packet starves the buffer every time. The ceiling is where added latency stops being worth it: a
## quarter second behind is worse to play against than judder.
const MIN_DELAY_SEC: float = 0.030
const MAX_DELAY_SEC: float = 0.250

## Starting delay, used until two snapshots have arrived and the real interval is known.
const INITIAL_DELAY_SEC: float = 2.0 / 30.0

## Weight of each new arrival in the smoothed interval estimate. Converges in about a third of a
## second at 30 Hz, which is fast enough to follow a class change and slow enough that one late
## packet does not move the delay.
const INTERVAL_SMOOTHING: float = 0.1

## Arrivals closer together than this are treated as one. Two snapshots sharing a timestamp would put
## a near-zero denominator into the extrapolation velocity and fling the node across the level.
const MIN_ARRIVAL_GAP_SEC: float = 0.001

## How far past the newest snapshot we will guess before giving up and holding still. A remote player
## that keeps moving through a 150 ms gap looks right; one that keeps moving through a two-second
## dropout walks through a wall and then snaps back, which is worse than freezing.
const MAX_EXTRAPOLATION_SEC: float = 0.150

## A jump larger than this is a teleport, not movement, and is snapped to rather than interpolated
## through. Legitimate motion cannot reach it: sprint is 6 m/s (0.2 m per 30 Hz frame) and terminal
## velocity is 60 m/s (8 m across four consecutive lost packets). A respawn or a level swap easily
## clears it, and interpolating through one of those smears a player across the map for a second.
const TELEPORT_DISTANCE_M: float = 20.0

## Snapshots retained. Half a second of history at 30 Hz — far more than the delay ever samples, so
## the buffer cannot underflow from behind, and small enough to stay in cache.
const BUFFER_CAPACITY: int = 16


# ── State ─────────────────────────────────────────────────────────────────────────────────────────

## The node whose position and yaw we drive. Never the local player's.
var _target: Node3D = null

## Optional second node carrying head pitch — CameraPivot on a player, null on anything else.
var _pitch_target: Node3D = null

var _sync: MultiplayerSynchronizer = null

# Ring buffer, oldest at _start, _count entries. Packed arrays sized once so a snapshot arriving
# thirty times a second per remote player never allocates.
var _times: PackedFloat64Array = PackedFloat64Array()
var _positions: PackedVector3Array = PackedVector3Array()
var _yaws: PackedFloat32Array = PackedFloat32Array()
var _pitches: PackedFloat32Array = PackedFloat32Array()
var _start: int = 0
var _count: int = 0

var _delay: float = INITIAL_DELAY_SEC
var _avg_interval: float = INITIAL_DELAY_SEC / DELAY_INTERVALS

## Counters, for the harness and for whoever wires this into the debug panel. Cheap to keep.
var _snapshots: int = 0
var _teleports: int = 0
var _starved_frames: int = 0
var _frames: int = 0


func _ready() -> void:
	# Run late in the frame, so that anything else writing this transform has already had its turn
	# and we are the last word on where the node is drawn.
	process_priority = 100
	set_process(_target != null)


func _exit_tree() -> void:
	# Hand the node back the way we found it. 1.7 may detach an interpolator when authority moves,
	# and leaving engine interpolation forced off on a node we no longer drive would be a silent
	# regression in exactly the case that is hardest to notice.
	if is_instance_valid(_target):
		_target.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_INHERIT


# ── Setup ─────────────────────────────────────────────────────────────────────────────────────────


## [param target] is the body to drive; [param pitch_target] optionally receives head pitch on its
## X rotation (CameraPivot for a player, null for anything without a head). If [param sync] is given,
## arrivals are picked up from it automatically — otherwise feed this with push_snapshot().
##
## Safe to call before or after the node enters the tree.
func configure(
	target: Node3D, pitch_target: Node3D = null, sync: MultiplayerSynchronizer = null
) -> void:
	_target = target
	_pitch_target = pitch_target
	_sync = sync

	_times.resize(BUFFER_CAPACITY)
	_positions.resize(BUFFER_CAPACITY)
	_yaws.resize(BUFFER_CAPACITY)
	_pitches.resize(BUFFER_CAPACITY)
	reset()

	if _target != null:
		# We write this transform every rendered frame, so the engine must not also interpolate it:
		# it would resample our already-smooth output onto the 60 Hz physics grid and add a tick of
		# lag doing it. See the class docs — this is the half of F-004 that is easy to get wrong.
		_target.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF

	if _sync != null and not _sync.synchronized.is_connected(_on_synchronized):
		# The synchronizer writes the incoming values onto the node and then emits this, so the
		# handler reads the raw arrival before _process overwrites it with the interpolated one.
		# Order within the frame does not matter: whichever runs first, what we sample here is
		# always the value that came off the wire.
		_sync.synchronized.connect(_on_synchronized)

	if is_inside_tree():
		set_process(_target != null)


## Drop all history and stop interpolating until fresh state arrives. Call after a teleport, a
## respawn or a level swap — anything where the path between the old state and the new one is not a
## path the node actually took.
func reset() -> void:
	_start = 0
	_count = 0
	_delay = INITIAL_DELAY_SEC
	_avg_interval = INITIAL_DELAY_SEC / DELAY_INTERVALS


# ── Input ─────────────────────────────────────────────────────────────────────────────────────────


## Record a state that just arrived. Stamped with the local arrival time, because that — not any
## timestamp on the wire — is what the render clock is measured against.
##
## Public so that a source other than a MultiplayerSynchronizer can drive this: an RPC state stream,
## or a test harness. Yaw and pitch are radians.
func push_snapshot(position: Vector3, yaw: float, pitch: float) -> void:
	var now: float = _now()

	if _count > 0:
		var newest: int = _index(_count - 1)
		var gap: float = now - _times[newest]

		# Two arrivals in the same instant are one arrival. Replace rather than append, so the
		# extrapolation velocity is never divided by ~0.
		if gap < MIN_ARRIVAL_GAP_SEC:
			_positions[newest] = position
			_yaws[newest] = yaw
			_pitches[newest] = pitch
			return

		# A teleport is not motion and must not be drawn as motion.
		if position.distance_squared_to(_positions[newest]) > TELEPORT_DISTANCE_M * TELEPORT_DISTANCE_M:
			_teleports += 1
			reset()
		else:
			_avg_interval = lerpf(_avg_interval, gap, INTERVAL_SMOOTHING)
			_delay = clampf(_avg_interval * DELAY_INTERVALS, MIN_DELAY_SEC, MAX_DELAY_SEC)

	var slot: int
	if _count == BUFFER_CAPACITY:
		slot = _start
		_start = (_start + 1) % BUFFER_CAPACITY
	else:
		slot = _index(_count)
		_count += 1

	_times[slot] = now
	_positions[slot] = position
	_yaws[slot] = yaw
	_pitches[slot] = pitch
	_snapshots += 1


func _on_synchronized() -> void:
	if _target == null:
		return
	push_snapshot(
		_target.position,
		_target.rotation.y,
		_pitch_target.rotation.x if _pitch_target != null else 0.0,
	)


# ── Output ────────────────────────────────────────────────────────────────────────────────────────


func _process(_delta: float) -> void:
	if _target == null or _count == 0:
		return

	_frames += 1

	var render_at: float = _now() - _delay
	var newest: int = _index(_count - 1)

	# Behind the oldest thing we have: we only just started, or the stream stalled long enough that
	# the buffer aged out. Show the oldest known state rather than guessing backwards.
	if render_at <= _times[_index(0)] or _count == 1:
		_apply(_positions[_index(0)], _yaws[_index(0)], _pitches[_index(0)])
		return

	# Past the newest: the next packet is late. Carry on along the last known velocity for a moment —
	# this is what makes a single dropped packet invisible — then hold, because a guess that runs for
	# a second is worse than a pause.
	if render_at >= _times[newest]:
		_starved_frames += 1
		var previous: int = _index(_count - 2)
		var span: float = _times[newest] - _times[previous]
		var ahead: float = minf(render_at - _times[newest], MAX_EXTRAPOLATION_SEC)
		if span <= 0.0:
			_apply(_positions[newest], _yaws[newest], _pitches[newest])
			return
		var factor: float = ahead / span
		_apply(
			_positions[newest] + (_positions[newest] - _positions[previous]) * factor,
			_wrap_angle(_yaws[newest] + angle_difference(_yaws[previous], _yaws[newest]) * factor),
			_pitches[newest] + angle_difference(_pitches[previous], _pitches[newest]) * factor,
		)
		return

	# The normal case: find the pair bracketing the render instant and lerp across it. Newest-first,
	# because that is where the answer almost always is, over at most BUFFER_CAPACITY entries.
	for i: int in range(_count - 1, 0, -1):
		var later: int = _index(i)
		var earlier: int = _index(i - 1)
		if _times[earlier] > render_at:
			continue
		var span: float = _times[later] - _times[earlier]
		var weight: float = 0.0 if span <= 0.0 else (render_at - _times[earlier]) / span
		_apply(
			_positions[earlier].lerp(_positions[later], weight),
			lerp_angle(_yaws[earlier], _yaws[later], weight),
			lerp_angle(_pitches[earlier], _pitches[later], weight),
		)
		return


func _apply(position: Vector3, yaw: float, pitch: float) -> void:
	_target.position = position
	_target.rotation.y = yaw
	if _pitch_target != null:
		_pitch_target.rotation.x = pitch


# ── Read-only, for the debug panel and the harness ────────────────────────────────────────────────


## How far behind live this node is currently drawn, in seconds.
func lag_seconds() -> float:
	return _delay


## Snapshots held right now. 0 means nothing has arrived and the node has never been moved by us.
func buffered() -> int:
	return _count


func debug_stats() -> Dictionary:
	return {
		"delay_ms": _delay * 1000.0,
		"interval_ms": _avg_interval * 1000.0,
		"buffered": _count,
		"snapshots": _snapshots,
		"teleports": _teleports,
		"frames": _frames,
		"starved_frames": _starved_frames,
	}


# ── Internals ─────────────────────────────────────────────────────────────────────────────────────


## Ring index of the [param offset]-th oldest entry.
func _index(offset: int) -> int:
	return (_start + offset) % BUFFER_CAPACITY


## Monotonic seconds. Deliberately not a frame-accumulated clock: arrival times have to be measured
## against something that keeps running while frames are long, which is exactly when it matters.
func _now() -> float:
	return float(Time.get_ticks_usec()) / 1_000_000.0


func _wrap_angle(radians: float) -> float:
	return wrapf(radians, -PI, PI)
