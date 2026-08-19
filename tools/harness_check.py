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
import hashlib
import json
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
  "tasks": {"9.9": {"title": "a task that edited one ordinary file", "tier": "T1",
            "status": "todo", "milestone": "M9"}},
  "in_flight": {},
  "claims": %(claims)s,
  "recent": %(recent)s
}
"""


def brief(text, lines=3, chars=300):
    """Enough of a failing command's output to identify it, not enough to bury the next case."""
    head = "\n".join(text.strip().splitlines()[:lines])[:chars]
    return head + (" …" if len(text.strip()) > len(head) else "")


def run(cmd, cwd, agent="alpha", session=None, check=False, godot_bin=None, stdin=None):
    """`stdin` is a string for the commands that read a body that way (`finding`, `resolve`).
    Passing "" is meaningful and not the same as omitting it — it is how the empty-body refusal gets
    tested, since a pipe is never a tty either way.

    `session` stands in for a real chat's session-id env var (F-147): pass it instead of `agent` to
    drive `whoami()`'s auto-name/token machinery rather than a lane's fixed MIRE_AGENT identity."""
    env = dict(os.environ, NO_COLOR="1")
    env.pop("MIRE_AGENT", None)
    env.pop("MIRE_SESSION", None)
    if session is not None:
        env["MIRE_SESSION"] = session
    else:
        env["MIRE_AGENT"] = agent
    if godot_bin:
        # Stand in for the engine so the argv the wrapper builds is observable, and so a test never
        # launches a real Godot against a throwaway project.
        env["GODOT_BIN"] = godot_bin
    r = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True, input=stdin)
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


@case("ship warns when a claimed file drifted after done() (F-117)")
def _(harness):
    # A hash that matches nothing on disk, standing in for the snapshot _release() would have
    # taken at done()-time if the file had looked different then — i.e. a second lane edited
    # world/thing.gd (docs/FINDINGS.md and docs/SPECS.md in the real F-117 incident; an ordinary
    # claimed file here, since the drift check itself doesn't care which path it is) in the gap
    # between 9.9 finishing with the file and this ship() call.
    recent = ('{"world/thing.gd": {"task": "9.9", "agent": "alpha", '
              '"at": "2026-08-18T12:00:00+00:00", "hash": "%s"}}' % ("0" * 64))
    d = build_repo(harness, recent=recent)
    r = run([".agent/bin/agent", "ship", "9.9", "9.9: an ordinary change"], d, check=True)
    assert "F-117" in r.stdout, "no drift warning printed: %s" % brief(r.stdout)
    assert "world/thing.gd" in r.stdout.split("F-117", 1)[1], (
        "drift warning didn't name the file: %s" % brief(r.stdout))
    files = committed_files(d)
    assert "world/thing.gd" in files, "a warned-about file must still ship — warn, not block: %s" % files
    return r.stdout.strip()


@case("ship stays quiet when a claimed file's hash matches its done()-time snapshot")
def _(harness):
    # The real done()-time content, hashed the same way _file_hash() does — this is the ordinary
    # case (nobody else touched the file) and must not warn.
    content = "extends Node\n# the shipping task's own work\n"
    good_hash = hashlib.sha256(content.encode()).hexdigest()
    recent = ('{"world/thing.gd": {"task": "9.9", "agent": "alpha", '
              '"at": "2026-08-18T12:00:00+00:00", "hash": "%s"}}' % good_hash)
    d = build_repo(harness, recent=recent)
    r = run([".agent/bin/agent", "ship", "9.9", "9.9: an ordinary change"], d, check=True)
    assert "F-117" not in r.stdout, "false-positive drift warning: %s" % brief(r.stdout)
    return r.stdout.strip()


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


@case("check blocks a colliding SESSION TOKEN even when the auto-assigned NAME matches (F-147)")
def _(harness):
    # F-145 fixed the generator so a FRESH chat never lands on a taken name again, but did nothing
    # for identities that already collided before that fix landed — F-147's residual risk. The
    # schema itself was the deeper gap: a claim keyed by `agent` name alone can't tell two
    # DIFFERENT chats apart once they share one, which is exactly what happened live (two sessions
    # both auto-named "nettle12"). Reproduce that directly rather than relying on crc32 luck: one
    # claim recorded under token-A's name AND token, a second session (token-B) whose
    # sessions.json entry already resolves to the SAME name, touching the same file token-A holds.
    claims = ('{".agent/bin/agent": {"agent": "nettle12", "token": "MIRE_SESSION:token-A", '
              '"task": "9.8", "at": "2026-08-18T12:00:00+00:00"}}')
    d = build_repo(harness, claims=claims)
    with open(os.path.join(d, ".agent", "sessions.json"), "w") as f:
        json.dump({"MIRE_SESSION:token-B": {"name": "nettle12", "at": "2026-08-18T12:00:00+00:00"}}, f)
    run(["git", "add", "--", ".agent/bin/agent"], d, check=True)
    r = run([".agent/bin/agent", "check"], d, session="token-B")
    assert r.returncode != 0, (
        "check let a same-NAME, different-TOKEN session commit over another session's claim:\n%s%s"
        % (r.stdout, r.stderr))
    assert "nettle12" in (r.stdout + r.stderr), "check did not name the holder: %s" % r.stdout
    return r.stdout.strip()


@case("check still allows the SAME session token to commit its own harness claim (F-147, no false-positive)")
def _(harness):
    claims = ('{".agent/bin/agent": {"agent": "nettle12", "token": "MIRE_SESSION:token-A", '
              '"task": "9.8", "at": "2026-08-18T12:00:00+00:00"}}')
    d = build_repo(harness, claims=claims)
    with open(os.path.join(d, ".agent", "sessions.json"), "w") as f:
        json.dump({"MIRE_SESSION:token-A": {"name": "nettle12", "at": "2026-08-18T12:00:00+00:00"}}, f)
    run(["git", "add", "--", ".agent/bin/agent"], d, check=True)
    r = run([".agent/bin/agent", "check"], d, session="token-A")
    assert r.returncode == 0, (
        "check blocked a session from committing its own claim:\n%s%s" % (r.stdout, r.stderr))
    return r.stdout.strip()


@case("reap --stale frees a chat claim whose session is long silent (F-186)")
def _(harness):
    # `reap` was written for lanes, which have a pid in lanes.json to check. A chat has no pid, and
    # its sessions.json entry recorded only when it registered — so a chat that died held its files
    # forever and every task needing them was blocked behind it. The `seen` heartbeat is what makes
    # a chat judgeable at all; here token-A last beat well over the threshold.
    claims = ('{"world/thing.gd": {"agent": "nettle12", "token": "MIRE_SESSION:token-A", '
              '"task": "9.8", "at": "2026-08-18T12:00:00+00:00"}}')
    d = build_repo(harness, claims=claims)
    with open(os.path.join(d, ".agent", "sessions.json"), "w") as f:
        json.dump({"MIRE_SESSION:token-A": {"name": "nettle12",
                                            "at": "2026-08-18T12:00:00+00:00",
                                            "seen": "2026-08-18T12:00:00+00:00"}}, f)
    r = run([".agent/bin/agent", "reap", "--stale", "1"], d, session="token-B")
    assert r.returncode == 0, "reap failed: %s" % brief(r.stdout + r.stderr)
    with open(os.path.join(d, ".agent", "state.json")) as f:
        assert "world/thing.gd" not in json.load(f)["claims"], (
            "reap --stale left a long-silent chat's claim in place:\n%s" % r.stdout)
    return r.stdout.strip()


@case("reap --stale refuses a chat claim it cannot attribute, because the name is shared (F-186)")
def _(harness):
    # The dangerous case. A pre-F-147 claim carries no token, only a name — and names collide
    # (F-145). If two sessions wear one name, the freshest of them is not necessarily the holder, so
    # trusting it would free a LIVE chat's files while its uncommitted edits sit in the tree.
    # Ambiguity must lose: report it, never act on it.
    claims = ('{"world/thing.gd": {"agent": "nettle12", '
              '"task": "9.8", "at": "2026-08-18T12:00:00+00:00"}}')
    d = build_repo(harness, claims=claims)
    with open(os.path.join(d, ".agent", "sessions.json"), "w") as f:
        json.dump({"MIRE_SESSION:token-A": {"name": "nettle12", "at": "2026-08-18T12:00:00+00:00"},
                   "MIRE_SESSION:token-B": {"name": "nettle12", "at": "2026-08-18T12:00:00+00:00",
                                            "seen": "2026-08-18T12:00:00+00:00"}}, f)
    r = run([".agent/bin/agent", "reap", "--stale", "1"], d, session="token-C")
    with open(os.path.join(d, ".agent", "state.json")) as f:
        assert "world/thing.gd" in json.load(f)["claims"], (
            "reap --stale freed a claim it could not attribute to a session:\n%s" % r.stdout)
    return r.stdout.strip()


@case("plain reap never frees a chat's claim — it only reports it (F-186)")
def _(harness):
    # A chat can be legitimately idle for hours with real uncommitted work. Releasing the claim does
    # not remove those edits, it removes the protection around them, so the default must be advisory.
    claims = ('{"world/thing.gd": {"agent": "nettle12", "token": "MIRE_SESSION:token-A", '
              '"task": "9.8", "at": "2026-08-18T12:00:00+00:00"}}')
    d = build_repo(harness, claims=claims)
    with open(os.path.join(d, ".agent", "sessions.json"), "w") as f:
        json.dump({"MIRE_SESSION:token-A": {"name": "nettle12",
                                            "at": "2026-08-18T12:00:00+00:00",
                                            "seen": "2026-08-18T12:00:00+00:00"}}, f)
    r = run([".agent/bin/agent", "reap"], d, session="token-B")
    with open(os.path.join(d, ".agent", "state.json")) as f:
        assert "world/thing.gd" in json.load(f)["claims"], (
            "plain reap freed a chat's claim without being asked:\n%s" % r.stdout)
    assert "9.8" in r.stdout, "plain reap did not report the silent task: %s" % r.stdout
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


# Every launch shape that has actually been seen on this machine, plus the ones the two documented
# pgreps were written against. Each line is a real `ps -Ao pid,command` line, and the comment is why
# getting it wrong costs something. F-120.
GODOT_LAUNCH_SHAPES = [
    # Observed 2026-08-18, pid 89993: Godot.app double-clicked from Finder (hence the
    # AppTranslocation path), project opened from the Project Manager. argv is EMPTY, and MIRE was
    # open in the editor — .godot/editor/filesystem_cache10 was rewritten five minutes after this
    # process started. BOTH documented pgreps read this as "editor closed".
    ("89993 /private/var/folders/nx/bz287r9n1xg6sygxh5q4hlf40000gn/T/AppTranslocation/"
     "0994BA62-7DC4-49F8-AA8B-BA31536DC38C/d/Godot.app/Contents/MacOS/Godot", "editor"),
    # F-120's own case, from 3.10: `-e` is the short form of `--editor`, so the command line never
    # contains the substring the documented pgrep matched on.
    ("40311 /Applications/Godot.app/Contents/MacOS/Godot --path /Users/s/MIRE "
     "-e res://levels/hollowmere.tscn", "editor"),
    ("40311 /Applications/Godot.app/Contents/MacOS/Godot --editor --path /Users/s/MIRE", "editor"),
    # `agent godot --script` — the shape F-045 already excluded correctly.
    ("40311 /Applications/Godot.app/Contents/MacOS/Godot --headless --path /Users/s/MIRE "
     "--script tools/biome_check.gd", "run"),
    # `agent godot --windowed --script` — F-077 drops --headless on purpose, so the pre-F-120 check
    # read every render check as an open editor and made `agent order`/`agent autoload` refuse
    # while one ran.
    ("40311 /Applications/Godot.app/Contents/MacOS/Godot --path /Users/s/MIRE --resolution 64x64 "
     "--position 2400,1400 --script tools/hollowmere_night_render.gd", "run"),
    # `agent godot --windowed --quit-after 60` — a real boot check, no --script to match on either.
    ("40311 /Applications/Godot.app/Contents/MacOS/Godot --path /Users/s/MIRE --resolution 64x64 "
     "--position 2400,1400 --quit-after 60", "run"),
    ("40312 /usr/local/bin/godot --headless --path /Users/s/MIRE --import", "run"),
    # Not the engine at all. The middle two are this check's own probes — F-045's over-match.
    ("1234 -zsh", None),
    ("1235 grep -rn Godot.app/Contents/MacOS/Godot /Users/s/MIRE", None),
    ("1236 ps -Ao pid,command", None),
    ("1237 /Users/s/MIRE/.agent/bin/agent editor-running", None),
]


def _load_harness(harness_src):
    """Import the harness as a module so its pure helpers can be called directly.

    Safe because everything at module scope in `.agent/bin/agent` is a constant or a def — the
    entry point is behind `if __name__ == "__main__"`.
    """
    import importlib.util
    from importlib.machinery import SourceFileLoader
    spec = importlib.util.spec_from_loader("mire_agent_harness",
                                           SourceFileLoader("mire_agent_harness", harness_src))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@case("the editor check classifies every real Godot launch shape correctly (F-120)")
def _(harness):
    mod = _load_harness(harness)
    wrong = []
    for line, expected in GODOT_LAUNCH_SHAPES:
        got = mod._godot_process_kind(line)
        if got != expected:
            wrong.append("expected %r, got %r for: %s" % (expected, got, line[:110]))
    assert not wrong, "the editor check misreads a real launch shape:\n        " + \
        "\n        ".join(wrong)

    # And the composition on top of it: a machine running only checks is not an open editor, while
    # one bare launch among them is.
    runs = [line for line, kind in GODOT_LAUNCH_SHAPES if kind != "editor"]
    editors = [line for line, kind in GODOT_LAUNCH_SHAPES if kind == "editor"]
    assert not any(k == "editor" for _p, k, _l in mod._godot_processes(runs)), (
        "headless and windowed check runs read as an open editor — that is the false positive that "
        "makes the pre-commit hook block safe commits, and --no-verify is the way round it")
    assert any(k == "editor" for _p, k, _l in mod._godot_processes(runs + editors[:1])), (
        "a real editor hid behind concurrent check runs")

    # A check that cannot see must not answer "all clear".
    mod._ps_lines = lambda: None
    assert mod._godot_running(), (
        "with `ps` unavailable the editor check failed OPEN — it must assume the editor is up, "
        "because the cost of guessing wrong that way is a false alarm and the other way is a "
        "corrupted .tscn (D-031)")
    return "%d launch shapes classified" % len(GODOT_LAUNCH_SHAPES)


@case("`agent editor-running` reports a verdict and an exit code that agree (F-120)")
def _(harness):
    d = build_repo(harness)
    r = run([".agent/bin/agent", "editor-running"], d)
    open_verdict = "the Godot editor is OPEN" in r.stdout
    closed_verdict = "the Godot editor is closed" in r.stdout
    assert open_verdict != closed_verdict, (
        "expected exactly one verdict, got:\n        %s" % brief(r.stdout + r.stderr))
    # Predicate convention, and the reason it is worth asserting: a lane that reads the exit code
    # instead of the text must get the same answer the text gives.
    expected_code = 0 if open_verdict else 1
    assert r.returncode == expected_code, (
        "verdict says %s but exit code is %d (expected %d)"
        % ("open" if open_verdict else "closed", r.returncode, expected_code))
    return "verdict: %s" % ("open" if open_verdict else "closed")


# F-131. Two findings under '## Open', both marked done in state — but for different reasons, and
# only one of them is a fact anybody recorded. F-901 has a `done_at`, so an agent really did run
# `agent done` on it; F-902 has none, so its `done` came from `_sync_findings()`'s own inference
# after the doc transiently lost its heading. The whole fix turns on telling those apart.
FINDINGS_DOC = """# Findings

## How to file one

### F-000 · the template example, which sits above '## Open' and must never be parsed

## Open

### F-901 · an agent ran `agent done` on this one — status is a recorded fact

Body.

### F-902 · nobody ever closed this: no done_at, so the status came from the sync's inference

Body.

## Resolved

### F-900 · something genuinely fixed — **fixed**

Body.
"""

FINDINGS_STATE = """{
  "version": 1,
  "tasks": {
    "9.9": {"title": "an ordinary task", "tier": "T1", "est": "1",
            "status": "todo", "milestone": "M1"},
    "F-901": {"title": "closed by an agent", "tier": "F", "est": "\u2014",
              "milestone": "Findings", "status": "done",
              "done_at": "2026-08-18T14:09:11+00:00", "done_by": "lp"},
    "F-902": {"title": "closed by the sync rule", "tier": "F", "est": "\u2014",
              "milestone": "Findings", "status": "done"}
  },
  "in_flight": {},
  "claims": {},
  "recent": {}
}
"""


def _findings_repo(harness):
    """A repo whose FINDINGS.md and state.json disagree in both of F-131's two ways."""
    d = build_repo(harness)
    os.makedirs(os.path.join(d, "docs"), exist_ok=True)
    with open(os.path.join(d, "docs", "FINDINGS.md"), "w") as f:
        f.write(FINDINGS_DOC)
    with open(os.path.join(d, ".agent", "state.json"), "w") as f:
        f.write(FINDINGS_STATE)
    return d


def _status(d, fid):
    with open(os.path.join(d, ".agent", "state.json")) as f:
        return json.load(f)["tasks"][fid].get("status")


@case("a finding the sync rule closed by inference reopens when the doc says it is open (F-131)")
def _(harness):
    d = _findings_repo(harness)
    run([".agent/bin/agent", "board"], d, check=True)   # any sync point will do
    assert _status(d, "F-902") == "todo", (
        "a finding marked done with no done_at — closed by nobody, only inferred — stayed done "
        "while sitting under '## Open'. That is how F-112 spent days in the board's Done row after "
        "an unrelated commit clobbered its heading for five minutes; `brief` offered it and `board` "
        "hid it, so no director could ever dispatch it. Status is now: %s" % _status(d, "F-902"))
    assert _status(d, "F-901") == "done", (
        "a finding an agent really closed (it has a done_at) was silently reopened. Only the "
        "inference is safe to undo automatically — undoing a recorded close-out needs a human, "
        "which is what `agent reopen` is for")


@case("`agent reopen` corrects a recorded close-out, and refuses when there is nothing to correct (F-131)")
def _(harness):
    d = _findings_repo(harness)
    r = run([".agent/bin/agent", "reopen", "F-901", "the done meant 'my session ended', not 'fixed'"],
            d, check=True)
    assert _status(d, "F-901") == "todo", "reopen did not clear the status: %s" % brief(r.stdout)
    with open(os.path.join(d, ".agent", "state.json")) as f:
        t = json.load(f)["tasks"]["F-901"]
    assert "done_at" not in t and "done_by" not in t, (
        "reopen left the close-out stamps behind, so the next sync's evidence test still reads it "
        "as closed-by-an-agent: %s" % t)
    journal = open(os.path.join(d, ".agent", "JOURNAL.md")).read()
    assert "REOPEN" in journal and "my session ended" in journal, (
        "reopen left no journal entry — the whole reason it exists rather than hand-editing "
        "state.json is that the correction is attributable")
    # Reopening something that is not done is a mistake, not a no-op: it would clear a status the
    # caller has misread.
    r = run([".agent/bin/agent", "reopen", "9.9", "already open"], d)
    assert r.returncode != 0 and "already" in (r.stdout + r.stderr), (
        "reopen accepted a task that was not done: %s" % brief(r.stdout + r.stderr))
    return "F-901 reopened and journalled; reopen on a todo task refused"


@case("`agent resolve` moves the LAST open finding without eating the '## Resolved' heading (F-134)")
def _(harness):
    d = _findings_repo(harness)
    doc = os.path.join(d, "docs", "FINDINGS.md")

    # F-902 is the last entry under '## Open' in FINDINGS_DOC — the one case the hand-rolled
    # "slice to the next '### F-' heading" gets wrong, because the next one is inside '## Resolved'.
    r = run([".agent/bin/agent", "resolve", "F-902"], d,
            stdin="Fixed by doing the thing. Verified with the check.")
    assert r.returncode == 0, "resolve failed: %s" % brief(r.stdout + r.stderr)
    text = open(doc).read()

    # Count HEADINGS, not substrings: the fixture's template entry quotes "'## Open'" in its prose,
    # and so does the real docs/FINDINGS.md. A substring count reads that as a second heading.
    headings = [ln for ln in text.splitlines() if ln.startswith("## ")]
    assert headings.count("## Resolved") == 1, (
        "the '## Resolved' heading was eaten — this is the exact corruption 9505cfd shipped, which "
        "made all 121 resolved findings parse as open. Headings now: %s" % headings)
    assert headings.count("## Open") == 1, "the '## Open' heading was damaged: %s" % headings

    open_part, _, resolved_part = text.partition("## Resolved")
    assert "### F-902" in resolved_part and "### F-902" not in open_part, (
        "F-902 did not end up under '## Resolved'")
    assert "### F-901" in open_part, "F-901 was dragged across with it"
    assert "### F-900" in resolved_part, "the finding already under '## Resolved' was lost"
    assert "**fixed**" in resolved_part.split("### F-902")[1].split("\n")[0], (
        "the moved title line was not marked **fixed**")
    assert "Verified with the check." in resolved_part, "the resolution note did not make it in"
    assert "---\n\n---" not in text and "---\n---" not in text, (
        "the move left a doubled '---' separator behind — the entry carries its own, and the text "
        "before it already ends with the previous entry's:\n%s" % brief(open_part[-200:], lines=8))
    return "moved without damaging either section heading"


@case("`agent resolve` refuses rather than writing when the file or the id is wrong (F-134)")
def _(harness):
    d = _findings_repo(harness)
    doc = os.path.join(d, "docs", "FINDINGS.md")

    # Already resolved, unknown, and no note at all: each must refuse and change nothing.
    before = open(doc).read()
    for argv, why in [(["resolve", "F-900"], "a finding already under '## Resolved'"),
                      (["resolve", "F-899"], "an id that is not in the file"),
                      (["resolve", "9.9"], "a roadmap task id")]:
        r = run([".agent/bin/agent"] + argv, d, stdin="a note")
        assert r.returncode != 0, "resolve accepted %s: %s" % (why, brief(r.stdout + r.stderr))
    r = run([".agent/bin/agent", "resolve", "F-902"], d, stdin="")
    assert r.returncode != 0, "resolve accepted an empty resolution note"
    assert open(doc).read() == before, "a refused resolve still wrote to the file"

    # A file whose '## Resolved' heading is already missing is damaged; appending would hide that.
    with open(doc, "w") as f:
        f.write(before.replace("## Resolved", "## Not The Heading"))
    r = run([".agent/bin/agent", "resolve", "F-902"], d, stdin="a note")
    assert r.returncode != 0 and "damaged" in (r.stdout + r.stderr), (
        "resolve wrote into a file with no '## Resolved' heading instead of refusing: %s"
        % brief(r.stdout + r.stderr))
    return "4 bad ids/notes and a damaged file all refused, nothing written"


@case("a commit blocked ONLY by foreign claims names the shared-index mechanism and the pathspec fix (F-199)")
def _(harness):
    # alpha edited its own unclaimed doc; beta holds world/thing.gd, which is also dirty (their
    # mid-ship state). alpha's bare commit must be blocked — and the block must explain that the
    # obstacle is the shared index, and print the pathspec commit for alpha's OWN files.
    d = build_repo(harness,
                   claims='{"world/thing.gd": {"task": "8.8", "agent": "beta", '
                          '"at": "2026-08-18T12:00:00+00:00"}}',
                   recent="{}")
    os.makedirs(os.path.join(d, "docs"), exist_ok=True)
    with open(os.path.join(d, "docs", "NOTES.md"), "w") as f:
        f.write("alpha's own doc edit\n")
    # Stage both — the shared-index state at the moment of a bare commit — and drive the check
    # directly, as the pre-commit hook would (build_repo installs no real hook).
    r = run(["git", "add", "docs/NOTES.md", "world/thing.gd"], d, check=True)
    r = run([".agent/bin/agent", "check"], d)
    assert r.returncode != 0, "check passed a tree where beta's claimed file is dirty: %s" % brief(r.stdout)
    out = r.stdout + r.stderr
    assert "shared" in out and "git commit -m" in out and "docs/NOTES.md" in out, (
        "the block did not explain the shared-index mechanism or name alpha's own pathspec:\n%s"
        % brief(out, lines=12, chars=800))
    assert "world/thing.gd" not in out.split("git commit -m")[1].splitlines()[0], (
        "the suggested pathspec includes beta's claimed file")
    return "guidance printed with alpha's files only"


@case("two lanes' unclaimed docs edits sit staged together and `check` passes silently — docs/ is exempt (F-149 setup)")
def _(harness):
    # F-149's actual starting condition, distinct from F-199's: docs/ is claim-exempt (F-006), so
    # NEITHER lane's staged file is "claimed by someone else" — `check` has nothing to block or even
    # warn about. This is why the F-199 block (which fires only when every blocked file is a foreign
    # claim) never sees this shape at all: there is no blocked file. The only thing standing between
    # this state and a misattributed commit is which git command runs next — see the two cases below.
    d = build_repo(harness)
    os.makedirs(os.path.join(d, "docs"), exist_ok=True)
    with open(os.path.join(d, "docs", "FINDINGS.md"), "w") as f:
        f.write("lane A's staged docs edit\n")
    with open(os.path.join(d, "docs", "SPECS.md"), "w") as f:
        f.write("lane B's staged docs edit\n")
    run(["git", "add", "docs/FINDINGS.md", "docs/SPECS.md"], d, check=True)
    r = run([".agent/bin/agent", "check"], d)
    assert r.returncode == 0, (
        "check blocked two unclaimed docs/ edits — if this ever fires, F-149's premise (docs/ is "
        "silently exempt) is stale and this whole finding needs re-reading before closing it:\n%s"
        % brief(r.stdout + r.stderr))
    return r.stdout.strip() or "(no output — silent pass, as F-006 intends)"


@case("a bare `git commit` sweeps a different lane's staged-but-uncommitted docs file — the F-149 incident, reproduced")
def _(harness):
    d = build_repo(harness)
    os.makedirs(os.path.join(d, "docs"), exist_ok=True)
    with open(os.path.join(d, "docs", "FINDINGS.md"), "w") as f:
        f.write("lane A's staged docs edit — not yet committed\n")
    with open(os.path.join(d, "docs", "SPECS.md"), "w") as f:
        f.write("lane B's staged docs edit\n")
    run(["git", "add", "docs/FINDINGS.md", "docs/SPECS.md"], d, check=True)
    # Lane B commits with no pathspec — exactly nettle12's e5f96b1 in the real incident.
    run(["git", "commit", "-m", "F-144: lane B's own change"], d, check=True)
    files = committed_files(d)
    assert "docs/FINDINGS.md" in files, (
        "setup broke: lane B's bare commit should have swept lane A's staged file, but didn't — "
        "this case is supposed to demonstrate the hazard, not the fix")
    return "reproduced: bare commit carried %s under lane B's message" % sorted(files)


@case("a pathspec commit leaves a different lane's staged docs file untouched and still staged (F-149 fix)")
def _(harness):
    # The AGENTS.md-mandated form (`git commit -m "..." -- docs/X.md`) applied by the lane that is
    # NOT lane A: it must commit only its own named file, and lane A's staged-but-uncommitted file
    # must survive in the index, ready for lane A to commit separately under its own message —
    # `agent ship`'s own commit already works this way (F-014); this proves the hand-commit form
    # AGENTS.md tells a docs/ closer to type by hand behaves identically.
    d = build_repo(harness)
    os.makedirs(os.path.join(d, "docs"), exist_ok=True)
    with open(os.path.join(d, "docs", "FINDINGS.md"), "w") as f:
        f.write("lane A's staged docs edit — not yet committed\n")
    with open(os.path.join(d, "docs", "SPECS.md"), "w") as f:
        f.write("lane B's staged docs edit\n")
    run(["git", "add", "docs/FINDINGS.md", "docs/SPECS.md"], d, check=True)
    run(["git", "commit", "-m", "F-144: lane B's own change", "--", "docs/SPECS.md"], d, check=True)
    files = committed_files(d)
    assert files == {"docs/SPECS.md"}, (
        "pathspec commit carried more than the named file: %s" % sorted(files))
    staged = run(["git", "diff", "--cached", "--name-only"], d, check=True).stdout.split()
    assert "docs/FINDINGS.md" in staged, (
        "lane A's staged file was unstaged or lost by lane B's commit, not merely left alone: %s"
        % staged)
    committed_a = run(["git", "show", "HEAD:docs/FINDINGS.md"], d)
    assert committed_a.returncode != 0, (
        "lane A's docs edit ended up committed under lane B's message anyway")
    return "lane B committed only docs/SPECS.md; lane A's docs/FINDINGS.md stayed staged, uncommitted"


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
