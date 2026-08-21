"""F-329: make a Blender reproducibility check leave the asset tree exactly as it found it.

**The bug this closes:** `asset_repro_check.py` and `crafting_stations_repro_check.py` each launch a
`build_*.py` builder twice *in the real repository* and then compare only the exported GLBs and the
catalog. A builder writes more than that. `build_crafting_stations.py`, for one, also renders two
preview PNGs into `assets/crafting_stations/preview/` and saves `assets/source/crafting_stations.blend`
-- neither of which the check snapshots, and neither of which it restores. Running the check during
the 2026-08-20 audit dirtied all three tracked paths even though the check itself passed; the audit
had to restore them by hand.

Both docstrings justify writing into the real tree with "the output is supposed to be deterministic,
so a passing run always leaves the tree in the state a human running the build script once would."
That is true of the GLBs -- which is exactly what the check proves -- and false of everything else.
A `.blend` is a container full of timestamps and pointer soup, and F-042 already established that two
Eevee renders are never byte-identical. So the *check* is what changes those files, every single run,
and with several lanes working at once it can overwrite another agent's in-progress tuning or leave
Godot's import cache stamped against content nobody chose.

**The fix, in two halves:**

*Restore what we expect to be touched.* Copy the declared roots -- the family's asset directory and
`assets/source/` -- before the first builder runs, then afterwards put back every file whose bytes
changed, re-create every file that was deleted, and remove every file that appeared. `copy2` keeps
the original mtime, so Godot's import cache stays consistent with the restored content rather than
seeing a fresh timestamp on identical bytes. The restore runs under `import_cache_guard`, the same
lock every writer takes (F-196), so no `agent godot` run can read the tree mid-restore, and one clean
import is forced on release.

*Fail loudly on what we did not expect.* Hash every file under `assets/` immediately before and
immediately after each builder launch. Anything that changed OUTSIDE the declared roots is a builder
writing somewhere its check does not know about -- which is how F-329 happened in the first place.
That is reported as a check failure rather than silently repaired, because the right fix is to widen
the declared roots deliberately.

The window is per-builder, not per-check, and that is load-bearing in a repo where several agents
work at once. A builder holds `import_cache_guard` for its whole write, so no `agent godot` run --
`tools/title_render.gd`, any render or audit check -- can write while the window is open. Measured
across the whole check instead, the first run of this guard blamed the crafting-stations builder for
eight `assets/audit/menu/*.png` that a concurrent lane rendered in the gap between the two Blender
launches. A check that goes red because someone else was working is a check people learn to ignore.

Kept dependency-free (no `bpy`) so a check can drive it with a bare `python3`, same as
`godot_import_lock`, which it composes with rather than reimplements.
"""

from __future__ import annotations

import contextlib
import hashlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Iterator

sys.path.append(str(Path(__file__).resolve().parent))
from godot_import_lock import AGENT_BIN, import_cache_guard  # noqa: E402

# tools/blender/asset_tree_guard.py -> tools/blender -> tools -> repo root.
REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_WATCH_ROOT = REPO_ROOT / "assets"
## Every builder saves its `.blend` here, so it is a declared root for every family.
SOURCE_DIR = REPO_ROOT / "assets" / "source"


def _digest(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def _repo_rel(path: Path) -> str:
    """Repo-relative for readability, absolute when the path is outside the repo. The guard is
    driven against a scratch tree by its own check, and a report that crashed on a temp directory
    would make the module untestable without touching the real `assets/`."""
    try:
        return str(path.relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


def _manifest(root: Path) -> dict[str, str]:
    """`relpath -> sha256` for every regular file under `root`. Hash-only: a 179 MB tree is far too
    big to copy just to notice a stray write, and cheap to hash next to two Blender launches."""
    if not root.is_dir():
        return {}
    out: dict[str, str] = {}
    for path in sorted(root.rglob("*")):
        if path.is_file() and not path.is_symlink():
            out[str(path.relative_to(root))] = _digest(path)
    return out


class AssetTreeGuard:
    """The report a check reads after the tree has been put back.

    `restored`/`removed` are informational -- a builder rewriting its own `.blend` and previews is
    expected, and the whole point is that it no longer survives the run. `strays` is the assertion:
    a non-empty list means some builder wrote outside the roots its check declared.
    """

    def __init__(self, roots: list[Path], watch_root: Path) -> None:
        self.roots = roots
        self.watch_root = watch_root
        self.builder_runs: int = 0
        self.restored: list[str] = []
        self.removed: list[str] = []
        self.strays: list[str] = []
        ## True once a restore has touched a path inside the repository. Gates the forced re-import:
        ## Godot only has an import cache for content under `res://`, so a guard driven against a
        ## scratch tree must not pay for an editor import pass that has nothing to reimport.
        self.touched_repo: bool = False

    @contextlib.contextmanager
    def builder_run(self) -> Iterator[None]:
        """Bracket ONE builder launch, and attribute any out-of-root write inside it to that builder.

        Wrap the `subprocess.run` that launches Blender and nothing else. Widening this to cover the
        whole check re-admits every concurrent lane's writes as false strays; narrowing it further
        would miss the builder's own late writes (a `.blend` save is the last thing it does).
        """
        before = _manifest(self.watch_root)
        try:
            yield
        finally:
            self.builder_runs += 1
            after = _manifest(self.watch_root)
            for rel in sorted(set(before) | set(after)):
                if before.get(rel) == after.get(rel):
                    continue
                absolute = (self.watch_root / rel).resolve()
                if any(_is_within(absolute, root) for root in self.roots):
                    continue
                stray = _repo_rel(absolute)
                if stray not in self.strays:
                    self.strays.append(stray)

    def summary(self) -> str:
        parts = []
        if self.restored:
            parts.append(f"{len(self.restored)} restored")
        if self.removed:
            parts.append(f"{len(self.removed)} removed")
        return ", ".join(parts) if parts else "nothing to restore"


def _restore_root(live: Path, snapshot: Path, guard: AssetTreeGuard) -> None:
    """Put `live` back to `snapshot`, touching only what actually differs.

    Untouched files keep their original mtime and are never rewritten, so a restore does not
    invalidate Godot's import cache for the whole family just because one preview was re-rendered.
    """
    snapshot_files = {
        str(p.relative_to(snapshot)) for p in snapshot.rglob("*") if p.is_file() and not p.is_symlink()
    }
    live_files = (
        {str(p.relative_to(live)) for p in live.rglob("*") if p.is_file() and not p.is_symlink()}
        if live.is_dir()
        else set()
    )

    for rel in sorted(snapshot_files):
        src = snapshot / rel
        dst = live / rel
        if dst.is_file() and _digest(dst) == _digest(src):
            continue
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)  # copy2 keeps mtime: the import cache stays consistent
        guard.restored.append(_repo_rel(dst))
        guard.touched_repo = guard.touched_repo or _is_within(dst.resolve(), REPO_ROOT)

    for rel in sorted(live_files - snapshot_files):
        target = live / rel
        target.unlink()
        guard.removed.append(_repo_rel(target))
        guard.touched_repo = guard.touched_repo or _is_within(target.resolve(), REPO_ROOT)


@contextlib.contextmanager
def asset_tree_guard(
    roots: list[Path],
    label: str = "asset repro check",
    watch_root: Path = DEFAULT_WATCH_ROOT,
    source_dir: Path = SOURCE_DIR,
) -> Iterator[AssetTreeGuard]:
    """Snapshot `roots`, run the caller's builders, then put the tree back exactly as it was.

    `roots` are the directories the builders are known to write. `source_dir` is added automatically
    -- every builder saves its `.blend` into `assets/source/`, and forgetting it is precisely the
    omission F-329 filed. Restoration happens even if the body raises, because a check that dies
    halfway is the worst case for leaving another lane's tree dirty.

    `watch_root` and `source_dir` are parameters rather than constants so `asset_tree_guard_check.py`
    can exercise the real code against a scratch tree. A test that pointed the guard at the live
    `assets/source/` would itself be able to revert a concurrent lane's work -- the exact class of
    damage this module exists to prevent.
    """
    declared = list(dict.fromkeys([r.resolve() for r in roots] + [source_dir.resolve()]))
    guard = AssetTreeGuard(declared, watch_root)

    with tempfile.TemporaryDirectory(prefix="mire_asset_tree_guard_") as raw_tmp:
        tmp = Path(raw_tmp)
        snapshots: list[tuple[Path, Path]] = []
        for index, root in enumerate(declared):
            snapshot = tmp / f"root{index}"
            if root.is_dir():
                shutil.copytree(root, snapshot, symlinks=True)
            else:
                snapshot.mkdir(parents=True)
            snapshots.append((root, snapshot))

        try:
            yield guard
        finally:
            # Under the writers' own lock (F-196): no `agent godot` may read the tree while it is
            # half restored. `force_import=False` because the import is conditional -- see below.
            with import_cache_guard(f"{label} restore", force_import=False):
                for root, snapshot in snapshots:
                    _restore_root(root, snapshot, guard)

            # Only when the restore actually changed something. A clean reproducible family restores
            # nothing (the builder rewrote its files with identical bytes and we kept them), and
            # paying for a full Godot boot to re-import a tree nobody altered is the kind of cost
            # that gets a check quietly dropped from the battery.
            if guard.touched_repo and AGENT_BIN.exists():
                subprocess.run(
                    [str(AGENT_BIN), "godot", "--import"], cwd=str(REPO_ROOT), check=False
                )


def _is_within(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
    except ValueError:
        return False
    return True
