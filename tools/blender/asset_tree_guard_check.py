#!/usr/bin/env python3
"""F-329's proof: an asset reproducibility check must leave the tree exactly as it found it.

    python3 tools/blender/asset_tree_guard_check.py

Drives the real `asset_tree_guard` against a scratch tree, with a fake builder standing in for
Blender. That substitution is the point, not a shortcut: the thing under test is the snapshot and
restore, and a real builder would cost two Blender launches per assertion while making the check
unable to run anywhere Blender is not installed.

The fake builder does exactly what a real one does to the tree -- rewrites its deterministic export,
re-renders a preview that differs every time, re-saves a `.blend` that differs every time, adds a new
file, and deletes one -- so every restoration path is exercised:

  1. a file the builder rewrote with DIFFERENT bytes is restored, byte for byte
  2. a file the builder rewrote with IDENTICAL bytes is not restored at all -- the guard must not
     rewrite bytes that already match, because a needless mtime bump re-imports the whole family
  3. a file the builder never touched keeps its original mtime for the same reason
  4. a file the builder created is removed
  5. a file the builder deleted is put back
  6. a write OUTSIDE the declared roots, made by the builder, is reported as a stray rather than
     silently repaired
  7. a write outside the declared roots made by SOMEONE ELSE, in the gap between builder runs, is
     not blamed on the builder -- several agents work this repo at once, and the first version of
     this guard failed a passing check because a concurrent lane rendered eight audit PNGs
  8. the tree is restored even when the guarded body raises

Nothing here touches `assets/`. The guard's `watch_root`/`source_dir` are parameters precisely so
this check cannot revert a concurrent lane's real work while testing that it reverts things.
"""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path

sys.path.append(str(Path(__file__).resolve().parent))
from asset_tree_guard import asset_tree_guard  # noqa: E402

failures: list[str] = []


def check(label: str, condition: bool) -> None:
    if condition:
        print(f"PASS: {label}")
    else:
        failures.append(label)
        print(f"FAIL: {label}")


def build_tree(root: Path) -> None:
    """A family directory and a source directory as a builder leaves them."""
    (root / "family" / "exports").mkdir(parents=True)
    (root / "family" / "preview").mkdir(parents=True)
    (root / "source").mkdir(parents=True)
    (root / "other").mkdir(parents=True)
    (root / "family" / "exports" / "bench.glb").write_bytes(b"deterministic-glb")
    (root / "family" / "exports" / "anvil.glb").write_bytes(b"stable-glb")
    (root / "family" / "exports" / "hammer.glb").write_bytes(b"reproducible-glb")
    (root / "family" / "catalog.json").write_text('{"kit": "family"}')
    (root / "family" / "preview" / "family_preview.png").write_bytes(b"render-one")
    (root / "family" / "doomed.txt").write_text("about to be deleted by the builder")
    (root / "source" / "family.blend").write_bytes(b"blend-one")
    (root / "other" / "untouched.txt").write_text("nobody should write here")


def run_case(
    label: str,
    mutate,
    expect_strays: list[str] | None = None,
    raise_in_body: bool = False,
    concurrent=None,
):
    """Snapshot a fresh scratch tree, let `mutate` play the builder, and report what survived.

    Everything the caller needs is read INSIDE the temporary directory's lifetime and returned as
    plain values -- a returned `Path` would point at a tree that no longer exists.
    """
    with tempfile.TemporaryDirectory(prefix="mire_guard_check_") as raw:
        root = Path(raw)
        build_tree(root)
        before = {p: p.read_bytes() for p in sorted(root.rglob("*")) if p.is_file()}
        preview = root / "family" / "preview" / "family_preview.png"
        untouched = root / "family" / "exports" / "anvil.glb"
        untouched_mtime_ns = untouched.stat().st_mtime_ns

        raised = False
        try:
            with asset_tree_guard(
                [root / "family"], label=label, watch_root=root, source_dir=root / "source"
            ) as guard:
                # Inside the bracket: this is the builder, and it owns what changes here.
                with guard.builder_run():
                    mutate(root)
                # Outside it: another lane, working while the builder is not holding the lock.
                if concurrent is not None:
                    concurrent(root)
                if raise_in_body:
                    raise RuntimeError("builder died mid-run")
        except RuntimeError:
            raised = True

        after = {p: p.read_bytes() for p in sorted(root.rglob("*")) if p.is_file()}
        declared_before = {p: b for p, b in before.items() if (root / "other") not in p.parents}
        declared_after = {p: b for p, b in after.items() if (root / "other") not in p.parents}

        check(f"{label}: declared roots restored exactly", declared_before == declared_after)
        if raise_in_body:
            check(f"{label}: the body's exception still reached the caller", raised)
        # A file the builder never touched must not be rewritten by the restore either -- an mtime
        # bump on identical bytes re-imports a whole family for nothing.
        check(
            f"{label}: a file the builder never touched kept its original mtime",
            untouched.stat().st_mtime_ns == untouched_mtime_ns,
        )
        check(
            f"{label}: a file rewritten with identical bytes was not restored",
            not any(name.endswith("hammer.glb") for name in guard.restored),
        )
        # Compared by suffix: the guard reports repo-relative paths for real assets and absolute
        # ones for a scratch tree, and this check deliberately runs on a scratch tree.
        expected = sorted(expect_strays or [])
        reported = sorted(guard.strays)
        check(
            f"{label}: strays reported exactly ({reported or 'none'})",
            len(reported) == len(expected)
            and all(got.endswith(want) for got, want in zip(reported, expected)),
        )
        check(
            f"{label}: no Godot re-import forced for a tree outside the repository",
            not guard.touched_repo,
        )
        return guard, preview.read_bytes()


def builder_normal(root: Path) -> None:
    """What a real builder does: a stable export, a non-deterministic preview and `.blend`, plus a
    file it adds and a file it removes."""
    (root / "family" / "exports" / "hammer.glb").write_bytes(b"reproducible-glb")  # identical bytes
    (root / "family" / "exports" / "bench.glb").write_bytes(b"deterministic-glb")
    (root / "family" / "preview" / "family_preview.png").write_bytes(b"render-two")
    (root / "source" / "family.blend").write_bytes(b"blend-two")
    (root / "family" / "exports" / "new_station.glb").write_bytes(b"brand-new")
    (root / "family" / "doomed.txt").unlink()


def builder_stray(root: Path) -> None:
    builder_normal(root)
    (root / "other" / "untouched.txt").write_text("a builder wrote outside its declared root")


def concurrent_lane(root: Path) -> None:
    """Another agent rendering into `assets/` between the two builder launches -- the real 2026-08-20
    case, where `tools/title_render.gd` rewrote eight audit PNGs while this check was mid-run."""
    (root / "other" / "untouched.txt").write_text("another lane rendered this, not the builder")


def main() -> None:
    print("== the tree a builder dirtied is put back ==")
    guard, preview_bytes = run_case("normal", builder_normal)
    check("normal: the guard reported restoring files", len(guard.restored) >= 2)
    check("normal: the guard reported removing the builder's new file", len(guard.removed) == 1)
    check(
        "normal: the restored preview holds the ORIGINAL render, not the builder's",
        preview_bytes == b"render-one",
    )

    print("\n== a write outside the declared roots is a failure, not a silent repair ==")
    stray_guard, _ = run_case(
        "stray", builder_stray, expect_strays=["other/untouched.txt"]
    )
    check("stray: the stray file is left as the builder wrote it", bool(stray_guard.strays))

    print("\n== a concurrent lane's write is not blamed on the builder ==")
    concurrent_guard, _ = run_case("concurrent", builder_normal, concurrent=concurrent_lane)
    check(
        "concurrent: the other lane's write is left exactly as it made it",
        not concurrent_guard.strays,
    )

    print("\n== a builder that dies halfway still gets cleaned up after ==")
    run_case("crash", builder_normal, raise_in_body=True)

    verdict = "PASS" if not failures else f"FAIL ({len(failures)})"
    print(f"\nASSET_TREE_GUARD_CHECK {verdict}")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
