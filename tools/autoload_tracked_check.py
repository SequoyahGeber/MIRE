#!/usr/bin/env python3
"""F-200: verifies project.godot's [autoload] block never registers a script git doesn't have.

F-190 shipped as a race between two acts that are not atomic: `agent autoload` appends the
`project.godot` registration line (claim-free, F-051) while the script itself is committed
separately by whatever claim covers it. Between those two commits — or if the script commit
never lands, gets reverted, or is dropped by a rebase — a revision can register an autoload whose
script is not tracked, and a clean checkout of it fails to boot with
`ERROR: Failed to instantiate an autoload, can't load from path: ...`. F-190 hit this for
`autoload/reward_service.gd`; F-144 hit the identical shape for `autoload/graphics_quality.gd`
preloading `res://world/environment/draw_policy.gd` — a script that loads clean can still pull in
an untracked dependency at `preload()` time. Both self-resolved by luck (a follow-up commit landed
the missing file before anyone hit the gap); nothing caught either at commit time.

This checks a REVISION, not the working tree — `os.path.exists` against dirty files on disk proves
nothing about what a clean checkout of that revision would have. For every `res://` path named in
`project.godot`'s `[autoload]` block:

1. It must resolve to a blob tracked at the revision (`git cat-file -e <rev>:<path>`, not a
   filesystem check).
2. If it is a `.gd` script, every string-literal `preload("res://...")` target inside it — read
   from the SAME revision, not off disk — is checked the same way, transitively.

Run:
    python3 tools/autoload_tracked_check.py            # HEAD
    python3 tools/autoload_tracked_check.py --rev abc123
    python3 tools/autoload_tracked_check.py --rev ""    # what's STAGED right now, HEAD for the rest —
                                                          # git's own `:path` index syntax, which is
                                                          # what `--rev` + `:` builds when rev is empty.
                                                          # This is the revision a pre-commit hook wants:
                                                          # there is no commit yet to name by sha.
    .agent/bin/agent baseline python3 tools/autoload_tracked_check.py   # a clean checkout of HEAD
    python3 tools/autoload_tracked_check.py --self-test  # proves it catches F-190's and F-144's
                                                          # exact shapes, in a throwaway repo

No Godot needed — this is pure git, so it's cheap enough to run on every commit that touches
project.godot or an autoload script. F-205 is mechanism #2: `.agent/bin/agent:cmd_check` (the
pre-commit hook) imports this module and calls `sweep("")` — the INDEX view above — whenever the
changed set includes project.godot or a .gd file, and refuses the commit if anything comes back
missing. Reuses this file's regexes/BFS rather than re-deriving them; see
`_case_catches_staged_precommit_f205_shape` below for the fixture that proves the INDEX view catches
a target that was never even `git add`ed, not just one missing from a named commit.
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# `Name="*res://path.gd"` or `Name="res://path.gd"` — the `*` marks it as added to its own group,
# irrelevant here. Values can also be `.tscn` (a scene autoload); either way it's a res:// path.
AUTOLOAD_LINE = re.compile(r'^\s*[A-Za-z_][A-Za-z0-9_]*\s*=\s*"\*?(res://[^"]+)"\s*$')
# Static string-literal preloads only (D-plan: matches what the finding names). A `load()`/`preload()`
# call built from a variable can't be swept this way and isn't what F-190/F-144 broke.
PRELOAD_CALL = re.compile(r'\bpreload\(\s*(["\'])(res://[^"\']+)\1\s*\)')


def git(args, check=True):
    r = subprocess.run(["git"] + args, cwd=ROOT, capture_output=True, text=True)
    if check and r.returncode != 0:
        raise RuntimeError("git %s failed: %s" % (" ".join(args), r.stderr.strip()))
    return r


def tracked_at(rev, respath):
    """True if res://path resolves to a blob tracked at rev — not merely present on disk."""
    relpath = respath[len("res://"):]
    return git(["cat-file", "-e", "%s:%s" % (rev, relpath)], check=False).returncode == 0


def read_at(rev, respath):
    relpath = respath[len("res://"):]
    r = git(["show", "%s:%s" % (rev, relpath)], check=False)
    return r.stdout if r.returncode == 0 else None


def autoload_targets(rev):
    text = git(["show", "%s:project.godot" % rev]).stdout
    in_section = False
    targets = []
    for line in text.splitlines():
        stripped = line.strip()
        if stripped == "[autoload]":
            in_section = True
            continue
        if in_section and stripped.startswith("["):
            break
        if not in_section:
            continue
        m = AUTOLOAD_LINE.match(line)
        if m:
            targets.append(m.group(1))
    return targets


def sweep(rev):
    """Returns (missing, checked) — missing is a list of (path, autoload_root) for every res://
    path (an autoload target or something it transitively preloads) not tracked at `rev`;
    autoload_root is the top-level autoload script that pulled it in, for a readable report."""
    missing = []
    visited = set()
    queue = [(t, t) for t in autoload_targets(rev)]
    while queue:
        path, root = queue.pop(0)
        if path in visited:
            continue
        visited.add(path)
        if not tracked_at(rev, path):
            missing.append((path, root))
            continue
        if path.endswith(".gd"):
            src = read_at(rev, path)
            if src is None:
                continue  # tracked_at just confirmed it exists; a show race would be a git bug
            for m in PRELOAD_CALL.finditer(src):
                target = m.group(2)
                if target not in visited:
                    queue.append((target, root))
    return missing, visited


def _self_test_repo(tmpdir):
    """A throwaway git repo carrying a copy of THIS script, so invoking it there exercises the
    real code path (ROOT resolves from __file__, same trick harness_check.py uses)."""
    d = Path(tmpdir)
    (d / "tools").mkdir()
    (d / "autoload").mkdir()
    (d / "world" / "environment").mkdir(parents=True)
    shutil.copy(__file__, d / "tools" / "autoload_tracked_check.py")

    def write(rel, text):
        (d / rel).write_text(text)

    def git_(args, check=True):
        r = subprocess.run(["git"] + args, cwd=d, capture_output=True, text=True)
        if check and r.returncode != 0:
            raise AssertionError("git %s failed: %s" % (" ".join(args), r.stderr))
        return r

    git_(["init", "-q", "-b", "main"])
    git_(["config", "user.email", "check@test"])
    git_(["config", "user.name", "check"])
    return d, write, git_


def _run_self(d, rev="HEAD"):
    return subprocess.run([sys.executable, "tools/autoload_tracked_check.py", "--rev", rev],
                          cwd=d, capture_output=True, text=True)


def _case_clean_passes():
    with tempfile.TemporaryDirectory(prefix="mire-autoload-check-") as tmp:
        d, write, git_ = _self_test_repo(tmp)
        write("project.godot", '[autoload]\n\nThing="*res://autoload/thing.gd"\n')
        write("autoload/thing.gd",
              'extends Node\nconst Other := preload("res://world/environment/other.gd")\n')
        write("world/environment/other.gd", "extends RefCounted\n")
        git_(["add", "-A"])
        git_(["commit", "-qm", "base"])
        r = _run_self(d)
        assert r.returncode == 0, "clean repo failed the check:\n%s" % (r.stdout + r.stderr)
        assert "failures=0" in r.stdout, r.stdout
        return "clean autoload + transitive preload, both tracked: passes"


def _case_catches_f190_shape():
    """The autoload's own target was never committed — F-190's exact shape."""
    with tempfile.TemporaryDirectory(prefix="mire-autoload-check-") as tmp:
        d, write, git_ = _self_test_repo(tmp)
        write("project.godot", '[autoload]\n\nRewardService="*res://autoload/reward_service.gd"\n')
        git_(["add", "-A"])
        git_(["commit", "-qm", "registers an autoload whose script was never committed"])
        r = _run_self(d)
        assert r.returncode != 0, "did not fail on an untracked autoload target:\n%s" % r.stdout
        assert "res://autoload/reward_service.gd" in r.stdout, r.stdout
        return "untracked autoload target: caught, exit %d" % r.returncode


def _case_catches_f144_shape():
    """The autoload script itself is tracked and loads fine; what it preloads is not —
    F-144's exact shape (graphics_quality.gd tracked, draw_policy.gd not)."""
    with tempfile.TemporaryDirectory(prefix="mire-autoload-check-") as tmp:
        d, write, git_ = _self_test_repo(tmp)
        write("project.godot", '[autoload]\n\nGraphicsQuality="*res://autoload/thing.gd"\n')
        write("autoload/thing.gd",
              'extends Node\nconst Policy := preload("res://world/environment/other.gd")\n')
        git_(["add", "tools", "project.godot", "autoload/thing.gd"])
        git_(["commit", "-qm", "tracked autoload preloading an untracked dependency"])
        r = _run_self(d)
        assert r.returncode != 0, "did not fail on an untracked transitive preload:\n%s" % r.stdout
        assert "res://world/environment/other.gd" in r.stdout, r.stdout
        assert "reachable via autoload res://autoload/thing.gd" in r.stdout, r.stdout
        return "tracked autoload, untracked transitive preload: caught, exit %d" % r.returncode


def _case_catches_staged_precommit_f205_shape():
    """F-205's shape: nothing has been committed yet, so there is no revision to name by sha —
    the check has to work against what's staged. `git add` the autoload registration but
    deliberately never `git add` its target, then check `--rev ""` (the INDEX view) instead of
    `--rev HEAD`. This is exactly what `.agent/bin/agent:cmd_check` calls pre-commit."""
    with tempfile.TemporaryDirectory(prefix="mire-autoload-check-") as tmp:
        d, write, git_ = _self_test_repo(tmp)
        write("project.godot", '[autoload]\n\nThing="*res://autoload/thing.gd"\n')
        git_(["add", "tools", "project.godot"])  # thing.gd deliberately never `git add`ed
        r = _run_self(d, rev="")
        assert r.returncode != 0, (
            "did not fail on a staged-but-uncommitted missing target:\n%s" % r.stdout)
        assert "res://autoload/thing.gd" in r.stdout, r.stdout
        return "staged autoload, target never git-added: caught pre-commit, exit %d" % r.returncode


SELF_TEST_CASES = [
    ("clean_passes", _case_clean_passes),
    ("catches_f190_shape", _case_catches_f190_shape),
    ("catches_f144_shape", _case_catches_f144_shape),
    ("catches_staged_precommit_f205_shape", _case_catches_staged_precommit_f205_shape),
]


def self_test():
    failed = 0
    for name, fn in SELF_TEST_CASES:
        try:
            note = fn()
            print("  PASS  %s\n        %s" % (name, note))
        except AssertionError as e:
            failed += 1
            print("  FAIL  %s\n        %s" % (name, e))
        except Exception as e:  # a crash is a failure too, and a louder one
            failed += 1
            print("  ERROR %s\n        %r" % (name, e))
    print("\n%d/%d passed" % (len(SELF_TEST_CASES) - failed, len(SELF_TEST_CASES)))
    return 1 if failed else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rev", default="HEAD", help="revision to check (default: HEAD)")
    ap.add_argument("--self-test", action="store_true",
                     help="prove the check catches F-190's and F-144's exact shapes, in a "
                          "throwaway repo — does not touch this repo or need a real project.godot")
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    roots = autoload_targets(args.rev)
    if not roots:
        print("AUTOLOAD_TRACKED_CHECK rev=%s: no [autoload] entries found — is project.godot "
              "readable at that revision?" % args.rev)
        return 1

    missing, visited = sweep(args.rev)
    print("AUTOLOAD_TRACKED_CHECK rev=%s autoloads=%d paths_checked=%d"
          % (args.rev, len(roots), len(visited)))
    if missing:
        for path, root in missing:
            same = path == root
            print("  MISSING %s%s — not tracked at %s"
                  % (path, "" if same else " (reachable via autoload %s)" % root, args.rev))
        print("failures=%d" % len(missing))
        return 1
    print("failures=0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
