#!/usr/bin/env python3
"""Regression guard for F-196: an asset rebuild racing `agent godot`'s own import pass poisoned the
shared `.godot/` cache (8 crafting-station GLBs unloadable for 40 minutes, self-healing never
triggered). The fix is `tools/blender/godot_import_lock.import_cache_guard` — every `build_*.py`
writer now holds `agent godot`'s own lock (`.agent/locks/godot.lock`) for its whole export window,
so no `agent godot` run can start a Godot process while a writer is mid-write.

This check proves the *mechanism*, not just that the code imports cleanly:

1. The guard actually holds an OS-level exclusive lock a concurrent process cannot also acquire.
2. It writes/clears the same holder record `.agent/bin/agent`'s own lock does, so a lane waiting on
   it sees who and why instead of "holder unknown".
3. The lock releases even when the guarded body raises — a failed rebuild must not wedge every other
   lane's `agent godot` checks forever.
4. **The real interop case**, not a re-implementation guess: while a process holds
   `import_cache_guard`, a genuine `agent godot --quit-after N` run started concurrently does not
   exit until the guard releases — proving both sides resolve to the exact same lock file, not two
   paths that happen to look alike.

Run:
    python3 tools/import_cache_guard_check.py            # cases 1-3, no Godot, ~2s
    python3 tools/import_cache_guard_check.py --godot     # adds case 4, needs a real Godot binary
"""

from __future__ import annotations

import argparse
import fcntl
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.append(str(ROOT / "tools" / "blender"))
from godot_import_lock import GODOT_HOLDER, GODOT_LOCK, import_cache_guard  # noqa: E402

AGENT_BIN = ROOT / ".agent" / "bin" / "agent"

# A subprocess-held guard is how every real case below observes contention: the lock is a real
# fcntl flock, and flock's exclusivity is per open-file-description, not per-thread — a second
# `open()` + `flock()` from *inside this same process* would not reproduce a cross-process race
# faithfully, so every case here spawns a genuinely separate interpreter to hold the guard.
_HOLD_SNIPPET = """
import sys, time
sys.path.append({blender_dir!r})
from godot_import_lock import import_cache_guard
with import_cache_guard("import_cache_guard_check.py (held)", force_import=False):
    print("HELD", flush=True)
    time.sleep({seconds})
print("RELEASED", flush=True)
"""


def _spawn_holder(seconds: float) -> subprocess.Popen:
    """Start a real second process that holds the guard for `seconds`, and block here until it
    reports the lock is actually acquired — otherwise every test below has a startup race of its
    own to worry about."""
    proc = subprocess.Popen(
        [sys.executable, "-c", _HOLD_SNIPPET.format(blender_dir=str(ROOT / "tools" / "blender"),
                                                      seconds=seconds)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
    line = proc.stdout.readline()
    assert line.strip() == "HELD", "holder subprocess never reported HELD: %r" % line
    return proc


def case_mutual_exclusion():
    proc = _spawn_holder(1.2)
    try:
        with open(GODOT_LOCK) as fh:
            try:
                fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(fh, fcntl.LOCK_UN)
                raise AssertionError(
                    "acquired the godot lock while a holder subprocess was inside the guard")
            except BlockingIOError:
                pass  # expected: someone else holds it
        proc.wait(timeout=5)
        assert proc.returncode == 0, "holder subprocess exited %d" % proc.returncode
        with open(GODOT_LOCK) as fh:
            fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)  # must succeed now
            fcntl.flock(fh, fcntl.LOCK_UN)
    finally:
        if proc.poll() is None:
            proc.kill()
    return "a second process cannot acquire the lock while the guard holds it, and can once released"


def case_holder_record():
    proc = _spawn_holder(1.2)
    try:
        assert GODOT_HOLDER.exists(), "no holder record written while the guard is held"
        text = GODOT_HOLDER.read_text()
        assert "import_cache_guard_check.py" in text, "holder record missing our label: %s" % text
        proc.wait(timeout=5)
        assert proc.returncode == 0
        assert not GODOT_HOLDER.exists(), "holder record survived past release"
    finally:
        if proc.poll() is None:
            proc.kill()
    return "holder record appears with our label while held, and is removed on release"


def case_releases_on_exception():
    class _Boom(Exception):
        pass

    try:
        with import_cache_guard("import_cache_guard_check.py (exception case)", force_import=False):
            raise _Boom("simulated rebuild failure")
    except _Boom:
        pass
    else:
        raise AssertionError("guard swallowed the exception instead of propagating it")
    assert not GODOT_HOLDER.exists(), "holder record survived a guarded body that raised"
    with open(GODOT_LOCK) as fh:
        fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)  # a wedged lock raises BlockingIOError here
        fcntl.flock(fh, fcntl.LOCK_UN)
    return "a guarded body that raises still releases the lock and clears the holder record"


def case_interops_with_agent_godot():
    """The one case that cannot be faked by re-deriving the lock path independently: hold the guard,
    launch the REAL `agent godot`, and prove it waits."""
    proc = _spawn_holder(6.0)
    try:
        started = time.time()
        godot = subprocess.Popen(
            [str(AGENT_BIN), "godot", "--quit-after", "5"], cwd=str(ROOT),
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        time.sleep(2.5)
        assert godot.poll() is None, (
            "`agent godot` finished while the guard was still held (%.1fs in) — "
            "it did not wait on the same lock" % (time.time() - started))
        proc.wait(timeout=8)
        assert proc.returncode == 0, "holder subprocess exited %d" % proc.returncode
        out, _ = godot.communicate(timeout=180)
        assert godot.returncode == 0, "agent godot exited %d:\n%s" % (godot.returncode, out)
        elapsed = time.time() - started
        assert elapsed >= 6.0, "agent godot finished (%.1fs) before the guard's 6s hold — no wait happened" % elapsed
    finally:
        if proc.poll() is None:
            proc.kill()
    return "a real `agent godot --quit-after 5` blocks until a held guard releases, then runs clean"


CASES = [
    ("mutual_exclusion", case_mutual_exclusion),
    ("holder_record", case_holder_record),
    ("releases_on_exception", case_releases_on_exception),
]
GODOT_CASES = [
    ("interops_with_agent_godot", case_interops_with_agent_godot),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--godot", action="store_true",
                     help="also run the real `agent godot` interop case (needs a Godot binary)")
    args = ap.parse_args()

    cases = list(CASES) + (list(GODOT_CASES) if args.godot else [])
    failed = 0
    for name, fn in cases:
        try:
            note = fn()
            print("  PASS  %s\n        %s" % (name, note))
        except AssertionError as e:
            failed += 1
            print("  FAIL  %s\n        %s" % (name, e))
        except Exception as e:  # a crash is a failure too, and a louder one
            failed += 1
            print("  ERROR %s\n        %r" % (name, e))
    if not args.godot:
        print("  (skipped interops_with_agent_godot — pass --godot to run it)")
    print("\n%d/%d passed" % (len(cases) - failed, len(cases)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
