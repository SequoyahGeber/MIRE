class_name ThreadedLoadRegistry
extends RefCounted

## One lifecycle per path, process-wide. The fix for F-591: two overlapping `load()` lifecycles over
## the same resource path corrupt the heap, and this makes that impossible **by construction** rather
## than by anybody remembering not to do it.
##
## ## The bug this exists to make unrepresentable
##
## `ResourceLoader.load_threaded_request(path)` starts a load on a worker thread and hands ownership
## of that path's load task to the caller until they call `load_threaded_get(path)`. A plain
## `load(path)` for the SAME path while that task is in flight is a second, independent lifecycle
## over one internal task. Sequoyah's crash report is what that costs:
##
##     Triggered by Thread 2 :: WorkerThread 0
##     EXC_BREAKPOINT (SIGABRT)
##     BUG IN CLIENT OF LIBMALLOC: memory corruption of free block
##
## with the main thread inside `_realloc` at the same moment — two threads in the allocator over one
## block. It aborts wherever the damaged block is next touched, which is why the same defect has been
## seen as `signal 11` in `_load_mesh_parts`, as `signal 5` in ZSTD decompression frames, and as this
## SIGABRT, and why it was filed as a flaky check (F-495) rather than as a threading defect.
##
## ## The invariant
##
## **A path is either in flight through this registry, or it is not being loaded at all.** Every
## caller goes through here, so:
##
##   · `request()` refuses a second threaded request for a path already in flight, and says so.
##   · `blocking_load()` on an in-flight path **retires the existing request** with
##     `load_threaded_get()` (which blocks until that task finishes and releases it properly) instead
##     of starting a competing `load()`.
##
## `tools/threaded_load_check.gd` asserts both, and asserts them going red when the guard is removed.
##
## ## Why static rather than an autoload
##
## The two owners are an autoload (`MaterialWarmer`) and a world node (`ResourceScatterField`), and
## the registry has to be reachable from both without either depending on the other's presence — a
## world node cannot assume the warmer exists, and the warmer must not reach into the world. Static
## state on a `class_name` is process-wide, which is exactly the scope of the resource loader itself.
## It also means a caller cannot fail to find it, which a `get_node_or_null` seam could.

## path -> true, for every path with a live threaded request nobody has retrieved yet.
static var _in_flight: Dictionary[String, bool] = {}
## Diagnostics, for the check and for anyone chasing this again. Counts refusals rather than hiding
## them: a nonzero `collisions` is the registry doing its job, not an error.
static var _collisions: int = 0
static var _blocking_takeovers: int = 0


## Starts a threaded load, unless this path already has one in flight.
##
## Returns true when the CALLER now owns a live request and must eventually `retrieve()` it. Returns
## false when the path was already in flight (someone else owns it — wait and retry) or when the
## engine refused the request. A false return is never an error the caller should log loudly: two
## owners wanting the same asset in the same frame is ordinary, and the whole point of this registry
## is that the second one quietly waits instead of starting a race.
static func request(path: String) -> bool:
	if path.is_empty():
		return false
	if _in_flight.has(path):
		_collisions += 1
		return false
	if ResourceLoader.load_threaded_request(path) != OK:
		return false
	_in_flight[path] = true
	return true


static func is_in_flight(path: String) -> bool:
	return _in_flight.has(path)


## `ResourceLoader.load_threaded_get_status()`, unchanged. Kept on the registry so a caller never has
## a reason to reach past it to the loader.
static func status(path: String) -> int:
	return ResourceLoader.load_threaded_get_status(path)


## Completes a request this caller started, releasing the path. Blocks if the load has not finished,
## same as `ResourceLoader.load_threaded_get()` — callers who do not want to block check `status()`
## for `THREAD_LOAD_IN_PROGRESS` first, which is what both warm pumps do.
static func retrieve(path: String) -> Resource:
	if not _in_flight.has(path):
		# Not ours to retrieve. Falling through to a plain load would be the exact double-lifecycle
		# this class exists to prevent, so the honest answer is the cache lookup a plain load would
		# have hit anyway once the real owner finished.
		return ResourceLoader.load(path) if ResourceLoader.has_cached(path) else null
	_in_flight.erase(path)
	return ResourceLoader.load_threaded_get(path)


## The safe replacement for a bare `load(path)` anywhere a threaded request might also be live.
##
## When the path is in flight, this **takes over the existing request** rather than starting a second
## one: `load_threaded_get()` blocks until the worker finishes and retires the task cleanly, which is
## precisely the operation a competing `load()` was corrupting. The caller gets the same resource it
## would have got, and the in-flight owner's later `retrieve()` finds the path already released and
## falls through to the resource cache — which is warm by then, because we just filled it.
static func blocking_load(path: String) -> Resource:
	if _in_flight.has(path):
		_blocking_takeovers += 1
		_in_flight.erase(path)
		return ResourceLoader.load_threaded_get(path)
	return ResourceLoader.load(path)


static func in_flight_count() -> int:
	return _in_flight.size()


static func collision_count() -> int:
	return _collisions


static func blocking_takeover_count() -> int:
	return _blocking_takeovers


## Test seam. Never called in play — a run that ended with paths in flight has bigger problems than
## this dictionary — but a check that drives the pumps needs to start from a known state.
static func reset_for_test() -> void:
	_in_flight.clear()
	_collisions = 0
	_blocking_takeovers = 0
