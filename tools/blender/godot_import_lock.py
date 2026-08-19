"""Shared write-lock guard for the `build_*.py` asset writers (F-196).

**The bug this closes:** every `tools/blender/build_*.py` writer exports its GLBs directly to
`assets/**/exports/*.glb` with no coordination at all, while `agent godot`'s own runs (`cmd_godot` in
`.agent/bin/agent`) force an import pre-pass (F-093) under an exclusive lock
(`.agent/locks/godot.lock`) before every check. That lock only ever serialised *Godot* processes
against each other (F-044) — a Blender writer never took it, so nothing stopped a check's import pass
from reading a GLB mid-write. Observed 2026-08-19: 8 crafting-station GLBs rebuilt while the audit
battery cycled `agent godot` runs, and one import pass caught a torn read, stamped the cache against
it, and every later pass — including the writer's own trailing checks — kept reading "already
imported" and skipping. 16 ERROR lines per run for 40 minutes, self-healing never triggered, until a
human ran `agent godot --import` by hand. Full account: `docs/FINDINGS.md` F-196.

**The fix:** a writer that holds this exact lock for its whole export window makes that race
structurally impossible — no `agent godot` run can even start a Godot process while the writer is
still mid-write, so nothing can ever stamp the cache against partial content. On release, one more
explicit `agent godot --import` forces a clean, definitive import against the now-finished files —
the same manual step F-196 already verified clears the cache — so a check run immediately after a
rebuild sees correct assets rather than depending on some other lane's next check to notice and
re-import.

Kept dependency-free (no `bpy`) on purpose: every writer needs it, and so does
`tools/import_cache_guard_check.py`, which drives it with a bare `python3` interpreter — no Blender,
no Godot boot, both far too slow for a check meant to run every session.

Usage, from any `build_*.py`::

    sys.path.append(str(Path(__file__).resolve().parent))
    from godot_import_lock import import_cache_guard

    if __name__ == "__main__":
        with import_cache_guard(Path(__file__).name):
            main()

Wrap the whole `main()` call, not just the export step — anything narrower risks missing a future
call site (a second GLB, a texture) added later without updating the wrapped span.
"""

from __future__ import annotations

import contextlib
import datetime
import fcntl
import json
import os
import subprocess
from pathlib import Path
from typing import Iterator

# tools/blender/godot_import_lock.py -> tools/blender -> tools -> repo root.
REPO_ROOT = Path(__file__).resolve().parents[2]
LOCKS_DIR = REPO_ROOT / ".agent" / "locks"
GODOT_LOCK = LOCKS_DIR / "godot.lock"
GODOT_HOLDER = LOCKS_DIR / "godot.holder"
AGENT_BIN = REPO_ROOT / ".agent" / "bin" / "agent"


def _write_holder(label: str) -> None:
    """Best-effort — matches `.agent/bin/agent`'s own `file_lock` holder record so a lane waiting on
    `agent godot` sees "held by ... running <label>" instead of "holder unknown"."""
    try:
        with open(GODOT_HOLDER, "w") as h:
            json.dump({
                "pid": os.getpid(),
                "agent": "blender-writer",
                "label": label,
                "at": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat(),
            }, h)
    except OSError:
        pass


def _clear_holder() -> None:
    try:
        os.remove(GODOT_HOLDER)
    except OSError:
        pass


@contextlib.contextmanager
def import_cache_guard(label: str = "blender export", force_import: bool = True) -> Iterator[None]:
    """Hold `agent godot`'s own lock for the caller's whole write, then force one clean import.

    Blocking, no timeout: a live asset rebuild is worth waiting for, and the alternative (die and
    make a human retry) is worse than a Blender process that occasionally sits a few minutes behind a
    long check queue. `force_import=False` is for tests that only need to prove the mutual exclusion,
    not pay for a real Godot boot.
    """
    LOCKS_DIR.mkdir(parents=True, exist_ok=True)
    with open(GODOT_LOCK, "w") as fh:
        fcntl.flock(fh, fcntl.LOCK_EX)
        try:
            _write_holder(label)
            yield
        finally:
            _clear_holder()
            fcntl.flock(fh, fcntl.LOCK_UN)

    if force_import and AGENT_BIN.exists():
        subprocess.run([str(AGENT_BIN), "godot", "--import"], cwd=str(REPO_ROOT), check=False)
