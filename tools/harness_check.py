#!/usr/bin/env python3
"""End-to-end check for the coordination harness's staging rules (F-081).

`.agent/bin/agent` is the one file every lane, every hook and every check shells out to, and it had
no automated test at all. This one builds a throwaway git repo, drops the real script into it, and
drives real `agent ship` / `agent check` runs against staged scenarios — so a regression shows up
here instead of in a lane's commit history.

    python3 tools/harness_check.py            # test the working-tree harness
    python3 tools/harness_check.py --rev HEAD # test the harness as of a git revision

The --rev form is how the F-081 fix was demonstrated: the pre-fix script fails case 1 and 2, the
fixed script passes all five.
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HARNESS = os.path.join(ROOT, ".agent", "bin", "agent")

# A task that touched one ordinary source file, closed out, and is about to ship. `recent` is what
# `_release()` leaves behind when a task closes, and it is where `ship` reads the task's file list.
STATE = """{
  "version": 1,
  "tasks": {"9.9": {"title": "a task that edited one ordinary file", "tier": "T1", "status": "todo"}},
  "in_flight": {},
  "claims": %(claims)s,
  "recent": %(recent)s
}
"""


def brief(text, lines=3, chars=300):
    """Enough of a failing command's output to identify it, not enough to bury the next case."""
    head = "\n".join(text.strip().splitlines()[:lines])[:chars]
    return head + (" …" if len(text.strip()) > len(head) else "")


def run(cmd, cwd, agent="alpha", check=False, godot_bin=None):
    env = dict(os.environ, MIRE_AGENT=agent, NO_COLOR="1")
    if godot_bin:
        # Stand in for the engine so the argv the wrapper builds is observable, and so a test never
        # launches a real Godot against a throwaway project.
        env["GODOT_BIN"] = godot_bin
    env.pop("MIRE_SESSION", None)
    r = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True)
    if check and r.returncode != 0:
        # AssertionError, not SystemExit: a failed setup command is a failed case, and SystemExit
        # would skip past the per-case handler in main() and abort the whole suite.
        raise AssertionError("command failed: %s\n        %s"
                             % (" ".join(cmd), brief(r.stdout + r.stderr)))
    return r


def build_repo(harness_src, claims="{}", recent=None):
    """A minimal repo with the harness in it, one committed source file, and dirty files staged
    exactly the way the F-081 scenario had them."""
    if recent is None:
        recent = ('{"world/thing.gd": {"task": "9.9", "agent": "alpha", '
                  '"at": "2026-08-18T12:00:00+00:00"}}')
    d = tempfile.mkdtemp(prefix="mire-harness-")
    os.makedirs(os.path.join(d, ".agent", "bin"))
    os.makedirs(os.path.join(d, "world"))
    shutil.copy(harness_src, os.path.join(d, ".agent", "bin", "agent"))
    os.chmod(os.path.join(d, ".agent", "bin", "agent"), 0o755)

    def write(rel, text):
        with open(os.path.join(d, rel), "w") as f:
            f.write(text)

    write(".agent/BOARD.md", "# Board\n")
    write(".agent/JOURNAL.md", "# Journal\n")
    # Committed clean, before the task closed out — so the dirty state.json below is a real change,
    # the one `agent done` leaves behind.
    write(".agent/state.json", STATE % {"claims": "{}", "recent": "{}"})
    write(".agent/bin/lane", "#!/usr/bin/env python3\n# lane, committed clean\n")
    # The two shapes `baseline` has to graft, in miniature: a gitignored sidecar beside a tracked
    # asset, and a directory that is ignored EXCEPT for one tracked file inside it — which is what
    # `.godot` really is, and what once made a skip-if-exists graft silently graft nothing.
    write(".gitignore", "*.import\n.godot/*\n!.godot/extension_list.cfg\n")
    os.makedirs(os.path.join(d, "assets"))
    os.makedirs(os.path.join(d, ".godot"))
    write("assets/thing.glb", "not really a glb\n")
    write("assets/thing.glb.import", "[remap]\npath=\"res://.godot/imported/thing\"\n")
    write(".godot/extension_list.cfg", "committed by git\n")
    write(".godot/class_cache.cfg", "gitignored, grafted\n")
    # Stands in for the engine. It marks its line so an assertion cannot accidentally read the
    # wrapper's own progress line instead — those two are block-buffered into an arbitrary order.
    write("fake-godot", '#!/bin/sh\necho "ARGV: $@"\n')
    os.chmod(os.path.join(d, "fake-godot"), 0o755)
    # A .uid sidecar already on disk keeps ship from shelling out to Godot for it (F-017).
    write("world/thing.gd", "extends Node\n")
    write("world/thing.gd.uid", "uid://abc123\n")

    run(["git", "init", "-q", "-b", "main"], d, check=True)
    run(["git", "config", "user.email", "harness@test"], d, check=True)
    run(["git", "config", "user.name", "harness"], d, check=True)
    run(["git", "add", "-A"], d, check=True)
    run(["git", "commit", "-qm", "base"], d, check=True)

    # Now dirty the tree the way it was on 2026-08-18: this task edited its own file, and a DIFFERENT
    # agent is midway through editing the harness source.
    write("world/thing.gd", "extends Node\n# the shipping task's own work\n")
    write(".agent/BOARD.md", "# Board\n\nregenerated by the harness\n")
    write(".agent/state.json", STATE % {"claims": claims, "recent": recent})
    write(".godot/extension_list.cfg", "dirty in the working tree\n")
    write(".agent/bin/agent", open(os.path.join(d, ".agent/bin/agent")).read() +
          "\n# another director's half-finished edit\n")
    write(".agent/bin/lane", "#!/usr/bin/env python3\n# another director's half-finished edit\n")
    return d


def committed_files(d):
    r = run(["git", "show", "--name-only", "--format=", "HEAD"], d, check=True)
    return set(f for f in r.stdout.split() if f)


def _argv_lines(stdout):
    """Every argv the wrapper handed the engine, in call order, as reported by fake-godot."""
    lines = [line.split()[1:] for line in stdout.splitlines() if line.startswith("ARGV:")]
    if not lines:
        raise AssertionError("the engine was never invoked:\n%s" % brief(stdout))
    return lines


def _argv_line(stdout):
    """The argv for the caller's own command — the LAST engine call, since F-093's import
    pre-pass (see cmd_godot) invokes the engine once more before it."""
    return _argv_lines(stdout)[-1]


CASES = []


def case(name):
    def deco(fn):
        CASES.append((name, fn))
        return fn
    return deco


@case("an unrelated task's ship leaves another agent's harness edits alone")
def _(harness):
    d = build_repo(harness)
    r = run([".agent/bin/agent", "ship", "9.9", "9.9: an ordinary change"], d)
    files = committed_files(d)
    assert "world/thing.gd" in files, "the task's own file did not ship: %s" % files
    stowaways = sorted(f for f in files if f.startswith(".agent/bin/"))
    assert not stowaways, "ship carried harness source it had no claim on: %s" % stowaways
    return r.stdout


@case("the harness edits survive in the working tree, unstaged")
def _(harness):
    d = build_repo(harness)
    run([".agent/bin/agent", "ship", "9.9", "9.9: an ordinary change"], d)
    r = run(["git", "status", "--porcelain", "-uall"], d, check=True)
    dirty = set(l[3:].strip() for l in r.stdout.splitlines() if l.strip())
    for f in (".agent/bin/agent", ".agent/bin/lane"):
        assert f in dirty, "%s vanished from the working tree — it was committed or reset" % f
    return r.stdout


@case("generated coordination state still ships with whatever task commits next")
def _(harness):
    d = build_repo(harness)
    run([".agent/bin/agent", "ship", "9.9", "9.9: an ordinary change"], d)
    files = committed_files(d)
    for f in (".agent/BOARD.md", ".agent/state.json"):
        assert f in files, "coordination state stopped shipping: %s not in %s" % (f, sorted(files))
    return "shipped: %s" % sorted(files)


@case("harness source DOES ship for the task that claimed it")
def _(harness):
    recent = ('{"world/thing.gd": {"task": "9.9", "agent": "alpha", "at": "2026-08-18T12:00:00+00:00"},'
              ' ".agent/bin/agent": {"task": "9.9", "agent": "alpha", "at": "2026-08-18T12:00:00+00:00"},'
              ' ".agent/bin/lane": {"task": "9.9", "agent": "alpha", "at": "2026-08-18T12:00:00+00:00"}}')
    d = build_repo(harness, recent=recent)
    run([".agent/bin/agent", "ship", "9.9", "9.9: fix the harness"], d)
    files = committed_files(d)
    for f in (".agent/bin/agent", ".agent/bin/lane"):
        assert f in files, "a claimed harness file did not ship: %s not in %s" % (f, sorted(files))
    return "shipped: %s" % sorted(files)


@case("check blocks a commit of harness source another agent holds")
def _(harness):
    claims = ('{".agent/bin/agent": {"agent": "beta", "task": "9.8", '
              '"at": "2026-08-18T12:00:00+00:00"}}')
    d = build_repo(harness, claims=claims)
    run(["git", "add", "--", ".agent/bin/agent"], d, check=True)
    r = run([".agent/bin/agent", "check"], d, agent="alpha")
    assert r.returncode != 0, ("check passed a harness file claimed by another agent:\n%s%s"
                               % (r.stdout, r.stderr))
    assert "beta" in (r.stdout + r.stderr), "check did not name the holder: %s" % r.stdout
    return r.stdout.strip()


@case("baseline runs at the revision, not the dirty working tree")
def _(harness):
    d = build_repo(harness)
    r = run([".agent/bin/agent", "baseline", "cat", "world/thing.gd"], d)
    assert r.returncode == 0, "baseline failed: %s" % brief(r.stdout + r.stderr)
    assert "the shipping task's own work" not in r.stdout, (
        "baseline read the dirty working tree, not the commit:\n%s" % r.stdout)
    assert "extends Node" in r.stdout, "baseline read nothing: %r" % r.stdout
    return r.stdout.strip()


@case("baseline leaves every other lane's uncommitted work alone")
def _(harness):
    d = build_repo(harness)
    before = run(["git", "status", "--porcelain", "-uall"], d, check=True).stdout
    run([".agent/bin/agent", "baseline", "cat", "world/thing.gd"], d, check=True)
    after = run(["git", "status", "--porcelain", "-uall"], d, check=True).stdout
    assert before == after, ("the shared working tree changed under a baseline run — this is the "
                            "`git stash` hazard F-080 exists to remove:\n%s\n%s" % (before, after))
    # And it took its checkout with it rather than leaving a worktree registered behind.
    trees = run(["git", "worktree", "list"], d, check=True).stdout
    assert len([l for l in trees.splitlines() if l.strip()]) == 1, "worktree left behind:\n%s" % trees
    return after or "(clean)"


@case("godot runs headless by default")
def _(harness):
    d = build_repo(harness)
    r = run([".agent/bin/agent", "godot", "--script", "tools/x_check.gd"], d,
            godot_bin=os.path.join(d, "fake-godot"), check=True)
    argv = _argv_line(r.stdout)
    assert "--headless" in argv, "the injected --headless is gone: %s" % argv
    return " ".join(argv)


@case("godot --windowed drops --headless and parks the window offscreen")
def _(harness):
    d = build_repo(harness)
    r = run([".agent/bin/agent", "godot", "--windowed", "--script", "tools/x_check.gd"], d,
            godot_bin=os.path.join(d, "fake-godot"), check=True)
    argv = _argv_line(r.stdout)
    assert "--headless" not in argv, "--windowed did not drop --headless: %s" % argv
    assert "--windowed" not in argv, "--windowed leaked through to the engine: %s" % argv
    for flag in ("--resolution", "64x64", "--position", "2400,1400"):
        assert flag in argv, "%s missing — the window is not parked offscreen: %s" % (flag, argv)
    # The caller's own flags come last, so an explicit --resolution of theirs still wins.
    assert argv.index("--script") > argv.index("--resolution"), (
        "caller arguments must follow the injected ones: %s" % argv)
    return " ".join(argv)


@case("godot imports before running a script, so a check can't read a stale build (F-093)")
def _(harness):
    d = build_repo(harness)
    r = run([".agent/bin/agent", "godot", "--script", "tools/x_check.gd"], d,
            godot_bin=os.path.join(d, "fake-godot"), check=True)
    argvs = _argv_lines(r.stdout)
    assert len(argvs) == 2, "expected an import pre-pass plus the caller's own run: %s" % argvs
    assert "--import" in argvs[0] and "--script" not in argvs[0], (
        "the FIRST engine call must be the import-only pre-pass: %s" % argvs[0])
    assert "--script" in argvs[1] and "--import" not in argvs[1], (
        "the SECOND engine call must be the caller's own run, unmodified: %s" % argvs[1])
    return " | ".join(" ".join(a) for a in argvs)


@case("godot --import does not import twice")
def _(harness):
    d = build_repo(harness)
    r = run([".agent/bin/agent", "godot", "--import"], d,
            godot_bin=os.path.join(d, "fake-godot"), check=True)
    argvs = _argv_lines(r.stdout)
    assert len(argvs) == 1, (
        "an explicit --import call should not also get a pre-pass import: %s" % argvs)
    return " ".join(argvs[0])


@case("baseline grafts the gitignored files a checkout cannot run without")
def _(harness):
    d = build_repo(harness)
    probe = ("import os;"
             "print('sidecar', os.path.exists('assets/thing.glb.import'));"
             "print('ignored_in_dir', os.path.exists('.godot/class_cache.cfg'));"
             "print('tracked', open('.godot/extension_list.cfg').read().strip())")
    r = run([".agent/bin/agent", "baseline", "python3", "-c", probe], d, check=True)
    assert "sidecar True" in r.stdout, (
        "the gitignored *.import sidecar did not reach the checkout — every ext_resource pointing "
        "at an imported asset loads as null there:\n%s" % brief(r.stdout))
    assert "ignored_in_dir True" in r.stdout, (
        "a directory that git partly tracks was grafted as all-or-nothing, so its ignored contents "
        "were skipped:\n%s" % brief(r.stdout))
    assert "tracked committed by git" in r.stdout, (
        "the graft overwrote a file git had already placed — the checkout is no longer the "
        "revision it claims to be:\n%s" % brief(r.stdout))
    return r.stdout.strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rev", help="test the harness as of this git revision instead of the working tree")
    a = ap.parse_args()

    harness = HARNESS
    tmp = None
    if a.rev:
        tmp = tempfile.mkdtemp(prefix="mire-harness-rev-")
        harness = os.path.join(tmp, "agent")
        blob = subprocess.run(["git", "show", "%s:.agent/bin/agent" % a.rev], cwd=ROOT,
                              capture_output=True, text=True)
        if blob.returncode != 0:
            raise SystemExit(blob.stderr.strip())
        with open(harness, "w") as f:
            f.write(blob.stdout)
        os.chmod(harness, 0o755)
        print("testing harness at %s" % a.rev)

    failed = 0
    for name, fn in CASES:
        try:
            fn(harness)
            print("  PASS  %s" % name)
        except AssertionError as e:
            failed += 1
            print("  FAIL  %s\n        %s" % (name, e))
        except Exception as e:  # a crash is a failure too, and a louder one
            failed += 1
            print("  ERROR %s\n        %r" % (name, e))
    if tmp:
        shutil.rmtree(tmp, ignore_errors=True)
    print("\n%d/%d passed" % (len(CASES) - failed, len(CASES)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
