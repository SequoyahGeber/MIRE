#!/usr/bin/env python3
"""Concurrency check for `.agent/bin/agent`'s state.json read-modify-write (F-266).

`cmd_claim` is `load()` -> check `in_flight`/`claims` for a conflict -> mutate -> `save()`. Nothing
serialised that window, so two lanes could both read a state where a task was free, both pass the
conflict check against that stale read, both print `✓ claimed`, and the later `save()` silently
erase the earlier one's claim. F-266 observed it live: two lanes wrote the same fix into
autoload/build_service.gd inside one claim window.

A race that rare in the wild has to be forced to be testable. This builds a throwaway repo with the
real harness in it, imports that copy as a module, and then `fork()`s N children that all block on
a pipe barrier before calling `cmd_claim` — so every child is already warm and the only thing left
between them is the load->save window itself. That makes the failure deterministic rather than a
one-in-a-thousand production surprise.

    python3 tools/agent_state_lock_check.py             # test the working-tree harness
    python3 tools/agent_state_lock_check.py --rev HEAD  # test the harness as of a git revision

The --rev form is how the F-266 fix was demonstrated: the pre-fix script fails cases 1-3 and 5,
the fixed script passes all six.
"""

import argparse
import contextlib
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HARNESS = os.path.join(ROOT, ".agent", "bin", "agent")

RACERS = 8          # enough that a last-writer-wins state.json loses most of them, visibly
BARRIER_WARMUP = 0.2  # seconds for every child to reach its barrier read before the gun fires


def brief(text, lines=4, chars=400):
    head = "\n".join(text.strip().splitlines()[:lines])[:chars]
    return head + (" …" if len(text.strip()) > len(head) else "")


def build_repo(harness_src, tasks=RACERS, pad=0):
    """A minimal repo with the real harness in it and `tasks` unclaimed tasks on the board.

    `pad` adds that many inert extra tasks, which is how case 4 widens the write: a 1 MB state.json
    takes real milliseconds to serialise, and a truncate-then-dump writer is readable mid-write for
    every one of them."""
    d = tempfile.mkdtemp(prefix="mire-statelock-")
    os.makedirs(os.path.join(d, ".agent", "bin"))
    os.makedirs(os.path.join(d, "world"))
    os.makedirs(os.path.join(d, "docs"))
    shutil.copy(harness_src, os.path.join(d, ".agent", "bin", "agent"))
    os.chmod(os.path.join(d, ".agent", "bin", "agent"), 0o755)

    def write(rel, text):
        with open(os.path.join(d, rel), "w") as f:
            f.write(text)

    st = {"version": 1, "tasks": {}, "in_flight": {}, "claims": {}}
    for i in range(tasks):
        st["tasks"]["9.%d" % i] = {"title": "task %d" % i, "tier": "T1", "est": "1",
                                   "milestone": "M9", "status": "todo"}
        write("world/f%d.gd" % i, "extends Node\n")
    for i in range(pad):
        st["tasks"]["8.%d" % i] = {"title": "inert padding task %d — " % i + "x" * 200,
                                   "tier": "T1", "est": "1", "milestone": "M9", "status": "todo"}
    write("world/shared.gd", "extends Node\n")
    write(".agent/state.json", json.dumps(st, indent=2, sort_keys=True) + "\n")
    write(".agent/BOARD.md", "# Board\n")
    write(".agent/JOURNAL.md", "# Journal\n")
    write("docs/FINDINGS.md", "# Findings\n\n## Open\n\n## Resolved\n")
    write("docs/ROADMAP.md", "# Roadmap\n")
    # `_journal()` shells out to `git rev-parse` for the head sha; without a repo it is noisy but
    # harmless. Init one anyway so `done`/`handoff` behave exactly as they do in the real tree.
    for cmd in (["git", "init", "-q", "-b", "main"],
                ["git", "config", "user.email", "statelock@test"],
                ["git", "config", "user.name", "statelock"],
                ["git", "add", "-A"], ["git", "commit", "-qm", "base"]):
        subprocess.run(cmd, cwd=d, capture_output=True, text=True)
    return d


def import_harness(repo):
    """Import the repo's own copy of the harness as a module, so its ROOT points at the fixture.

    Importing rather than shelling out is what makes the race tight: `fork()` after import means a
    child's whole remaining lifetime is the load->save window, with no interpreter startup jitter
    to smear the eight of them apart."""
    path = os.path.join(repo, ".agent", "bin", "agent")
    spec = importlib.util.spec_from_loader(
        "mire_agent_under_test", importlib.machinery.SourceFileLoader("mire_agent_under_test", path))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _exitcode(status):
    try:
        return os.waitstatus_to_exitcode(status)
    except AttributeError:      # pragma: no cover — Python < 3.9
        return os.WEXITSTATUS(status) if os.WIFEXITED(status) else -os.WTERMSIG(status)


def race(mod, jobs, command="claim"):
    """Run `jobs` — a list of (agent_name, argv) — concurrently, all released by one barrier.

    Dispatches through `COMMANDS`, not the bare `cmd_*` function, so the racers run exactly what
    the CLI runs — transaction wrapper included. Calling `cmd_claim` directly would test a path no
    invocation takes and would silently pass a harness whose locking was never wired up.

    Returns [(agent, exit_code, output)] in job order."""
    fn = mod.COMMANDS[command]
    gun_r, gun_w = os.pipe()
    kids = []
    for name, argv in jobs:
        out_r, out_w = os.pipe()
        pid = os.fork()
        if pid == 0:
            os.close(out_r)
            os.close(gun_w)
            code = 0
            buf = io.StringIO()
            try:
                os.read(gun_r, 1)       # the barrier: every racer starts here, warm
                os.close(gun_r)
                for key in list(mod.SESSION_ENV_KEYS):
                    os.environ.pop(key.split(":")[0], None)
                os.environ["MIRE_AGENT"] = name
                os.environ["NO_COLOR"] = "1"
                with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
                    try:
                        fn(list(argv))
                    except SystemExit as e:
                        code = e.code if isinstance(e.code, int) else 1
            except BaseException as e:  # a crashed racer is a failed case, not a hung one
                buf.write("CHILD-CRASH %r\n" % e)
                code = 99
            try:
                os.write(out_w, buf.getvalue().encode())
            except OSError:
                pass
            os.close(out_w)
            os._exit(code)
        os.close(out_w)
        kids.append((name, pid, out_r))
    os.close(gun_r)
    time.sleep(BARRIER_WARMUP)
    os.write(gun_w, b"x" * len(jobs))
    os.close(gun_w)

    results = []
    for name, pid, out_r in kids:
        chunks = []
        while True:
            chunk = os.read(out_r, 65536)
            if not chunk:
                break
            chunks.append(chunk)
        os.close(out_r)
        results.append((name, _exitcode(os.waitpid(pid, 0)[1]), b"".join(chunks).decode()))
    return results


def read_state(repo):
    with open(os.path.join(repo, ".agent", "state.json")) as f:
        return json.load(f)


def run_cli(repo, args, agent="alpha"):
    env = dict(os.environ, NO_COLOR="1", MIRE_AGENT=agent)
    env.pop("MIRE_SESSION", None)
    return subprocess.run([os.path.join(repo, ".agent", "bin", "agent")] + args,
                          cwd=repo, env=env, capture_output=True, text=True, timeout=120)


CASES = []


def case(name):
    def deco(fn):
        CASES.append((name, fn))
        return fn
    return deco


@case("eight lanes racing ONE task: exactly one claim wins")
def _(harness):
    repo = build_repo(harness)
    mod = import_harness(repo)
    jobs = [("lane%d" % i, ["9.0", "world/f%d.gd" % i]) for i in range(RACERS)]
    results = race(mod, jobs)
    winners = [n for n, code, _ in results if code == 0]
    assert len(winners) == 1, (
        "%d of %d racers were told '✓ claimed' on the same task — F-266's window is open:\n%s"
        % (len(winners), RACERS, brief("\n".join("%s -> %s" % (n, brief(o, 1, 90))
                                                 for n, c, o in results if c == 0), 8, 700)))
    st = read_state(repo)
    held = st["in_flight"].get("9.0", {}).get("agent")
    assert held == winners[0], (
        "the winner printed was %r but state.json records %r — a claim was overwritten"
        % (winners[0], held))
    losers = [o for n, c, o in results if c != 0]
    assert all("already claimed by" in o for o in losers), (
        "a loser died for some reason other than the conflict check:\n%s"
        % brief("\n".join(losers), 6, 500))
    return "1 winner, %d told 'already claimed by %s'" % (len(losers), winners[0])


@case("eight lanes racing ONE file across eight tasks: exactly one claim wins")
def _(harness):
    repo = build_repo(harness)
    mod = import_harness(repo)
    jobs = [("lane%d" % i, ["9.%d" % i, "world/shared.gd"]) for i in range(RACERS)]
    results = race(mod, jobs)
    winners = [n for n, code, _ in results if code == 0]
    assert len(winners) == 1, (
        "%d racers each believe they hold world/shared.gd — two agents in one file is exactly "
        "what claims exist to prevent" % len(winners))
    st = read_state(repo)
    holder = st["claims"].get("world/shared.gd", {}).get("agent")
    assert holder == winners[0], (
        "the winner printed was %r but the file claim records %r" % (winners[0], holder))
    return "1 winner, %d refused the file" % (RACERS - 1)


@case("eight lanes claiming eight DIFFERENT tasks: no claim is silently lost")
def _(harness):
    repo = build_repo(harness)
    mod = import_harness(repo)
    jobs = [("lane%d" % i, ["9.%d" % i, "world/f%d.gd" % i]) for i in range(RACERS)]
    results = race(mod, jobs)
    failed = [(n, brief(o, 2, 200)) for n, c, o in results if c != 0]
    assert not failed, "a non-conflicting claim was refused: %s" % failed
    st = read_state(repo)
    missing = [tid for tid, _ in (argv for _, argv in jobs) if tid not in st["in_flight"]]
    lost_files = [f for _, (_, f) in jobs if f not in st["claims"]]
    assert not missing and not lost_files, (
        "%d of %d in-flight records and %d of %d file claims never reached disk — every one of "
        "those lanes was told it had the claim.\n  missing in_flight: %s\n  missing claims:    %s"
        % (len(missing), RACERS, len(lost_files), RACERS, missing, lost_files))
    return "%d/%d claims survived" % (RACERS, RACERS)


@case("a reader never sees a half-written state.json")
def _(harness):
    repo = build_repo(harness, pad=1500)
    mod = import_harness(repo)
    size = os.path.getsize(os.path.join(repo, ".agent", "state.json"))
    jobs = [("lane%d" % i, ["9.%d" % i, "world/f%d.gd" % i]) for i in range(RACERS)]
    torn = []

    pid = os.fork()
    if pid == 0:                                  # the reader, hammering load() while they write
        code = 0
        try:
            deadline = time.time() + 3.0
            bad = 0
            while time.time() < deadline:
                try:
                    read_state(repo)
                except ValueError:
                    bad += 1
            code = min(bad, 100)
        except BaseException:
            code = 99
        os._exit(code)
    race(mod, jobs)
    bad = _exitcode(os.waitpid(pid, 0)[1])
    torn.append(bad)
    assert bad == 0, (
        "%d truncated reads of a %d-byte state.json while eight lanes wrote it — a plain "
        "truncate-then-dump writer is readable mid-write (same class as F-304)" % (bad, size))
    return "0 torn reads of a %d-byte state.json" % size


@case("a save that would clobber a state changed since its load is refused")
def _(harness):
    repo = build_repo(harness)
    mod = import_harness(repo)
    os.environ["MIRE_AGENT"] = "alpha"
    st = mod.load()
    # Stand in for a writer that reached state.json without going through this process's
    # transaction — a hand-edit, a stale process, or a future command that forgets the lock.
    other = read_state(repo)
    other["tasks"]["9.7"]["status"] = "in_flight"
    other["rev"] = other.get("rev", 0) + 1
    with open(os.path.join(repo, ".agent", "state.json"), "w") as f:
        json.dump(other, f, indent=2, sort_keys=True)
    st["tasks"]["9.0"]["status"] = "in_flight"
    buf = io.StringIO()
    refused = False
    with contextlib.redirect_stdout(buf):
        try:
            mod.save(st)
        except SystemExit:
            refused = True
    assert refused, (
        "save() wrote a state loaded before someone else's write and lost it silently:\n  %s"
        % brief(buf.getvalue(), 3, 300))
    assert read_state(repo)["tasks"]["9.7"]["status"] == "in_flight", \
        "the foreign write was erased anyway"
    return brief(buf.getvalue(), 1, 120) or "(refused)"


@case("the ordinary sequential protocol still runs — claim, note, done, drop (no deadlock)")
def _(harness):
    repo = build_repo(harness)
    for args in (["claim", "9.0", "world/f0.gd"],
                 ["note", "9.0", "a thing I learned"],
                 ["done", "9.0", "finished it"],
                 ["claim", "9.1", "world/f1.gd"],
                 ["board"],
                 ["drop", "9.1"]):
        r = run_cli(repo, args)
        assert r.returncode == 0, ("agent %s failed:\n%s"
                                   % (" ".join(args), brief(r.stdout + r.stderr, 6, 600)))
    st = read_state(repo)
    assert st["tasks"]["9.0"]["status"] == "done", "done did not stick: %s" % st["tasks"]["9.0"]
    assert "9.1" not in st["in_flight"], "drop did not release: %s" % st["in_flight"]
    assert not st["claims"], "claims outlived their tasks: %s" % st["claims"]
    return "claim/note/done/claim/board/drop all exit 0"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rev", help="test the harness as of this git revision instead of the working tree")
    a = ap.parse_args()

    harness = HARNESS
    tmp = None
    if a.rev:
        tmp = tempfile.mkdtemp(prefix="mire-statelock-rev-")
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
            detail = fn(harness)
            print("  PASS  %s\n        %s" % (name, detail))
        except AssertionError as e:
            failed += 1
            print("  FAIL  %s\n        %s" % (name, e))
        except Exception as e:      # a crash is a failure too, and a louder one
            failed += 1
            print("  ERROR %s\n        %r" % (name, e))
    if tmp:
        shutil.rmtree(tmp, ignore_errors=True)
    print("\nAGENT_STATE_LOCK_CHECK failures=%d  %d/%d passed"
          % (failed, len(CASES) - failed, len(CASES)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
