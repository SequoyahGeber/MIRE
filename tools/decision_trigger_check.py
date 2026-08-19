#!/usr/bin/env python3
"""Surfaces docs/DECISIONS.md reversal triggers with mechanical evidence they've fired (F-218).

Every `### D-0NN` entry ends with a **Would change my mind:** clause — the specific evidence that
should make someone revisit the call. Nothing ever re-reads those clauses, so a fired trigger sits
unnoticed until an agent happens to trip over the consequence. F-218 names two from one session:
D-011's ("file claims become a bottleneck often enough") is a frequency judgement with no concrete
referent — genuinely not mechanically checkable, and this tool correctly stays silent on it. D-041's
("the moment a real per-run seed authority exists") names a concrete symbol, `GameState`, and that
one this tool does catch: `GameState` was registered as an autoload the day after D-041 was written,
which is exactly the mechanical signal below.

So: this catches trigger clauses that name a backtick-quoted file or symbol which exists in the
tracked tree today but did not on the day the decision was written. Most clauses are prose
judgements like D-011's and stay outside what this can see — narrowing what needs a human read is
the goal, not replacing it.

    python3 tools/decision_trigger_check.py            # scan docs/DECISIONS.md as it stands
    python3 tools/decision_trigger_check.py --self-test # prove the detection on synthetic history

A decision already annotated `*Superseded by ...*`, `*Amended by ...*`, or `*Reviewed ...*` right
under its heading is skipped — that annotation IS the review the trigger was asking for, so
re-flagging it forever after would just be noise nobody reads. `*Reviewed <date> — <why it still
holds>.*` is this tool's one new convention, alongside the retro-edit markers docs/DECISIONS.md's
preamble already permits: a one-line way to silence a trigger that fired but is still the right
call, without rewriting the reasoning body.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DECISIONS = os.path.join(ROOT, "docs", "DECISIONS.md")

HEADING_RE = re.compile(r"^### (D-\d+) · (\d{4}-\d{2}-\d{2})", re.M)
REVIEWED_RE = re.compile(r"^\*(Superseded by|Amended by|Reversed by|Overturned by|Reviewed)\b")
TRIGGER_RE = re.compile(r"^\*\*Would change my mind:\*\*\s*(.+)", re.M | re.S)
TOKEN_RE = re.compile(r"`([A-Za-z_][A-Za-z0-9_./]*)")

# Source the way this repo defines it — tracked GDScript/config, never docs, never the .godot cache.
SOURCE_GLOBS = ["*.gd", "*.py", "*.tscn", "*.tres", "*.cfg", "*.import"]


def run(cmd, cwd):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)


def parse_decisions(text):
    """Yields (id, date, line_no, trigger_text, reviewed) for every ### D-0NN entry."""
    headings = list(HEADING_RE.finditer(text))
    for i, m in enumerate(headings):
        did, date = m.group(1), m.group(2)
        # HEADING_RE only matches up through the date — the rest of the title line follows. Body
        # must start at the next newline, not m.end(), or the title's tail gets read as body text
        # and REVIEWED_RE never sees the line right under the heading where it actually lives.
        nl = text.find("\n", m.end())
        start = nl + 1 if nl != -1 else len(text)
        end = headings[i + 1].start() if i + 1 < len(headings) else len(text)
        body = text[start:end]
        line_no = text.count("\n", 0, m.start()) + 1
        reviewed = bool(REVIEWED_RE.match(body.lstrip("\n").splitlines()[0])) if body.strip() else False
        tm = TRIGGER_RE.search(body)
        trigger = tm.group(1).split("\n\n")[0].strip() if tm else ""
        yield did, date, line_no, trigger, reviewed


def extract_tokens(trigger_text):
    seen = []
    for tok in TOKEN_RE.findall(trigger_text):
        tok = tok.split("(")[0].rstrip(".,;:")
        if len(tok) >= 3 and tok not in seen:
            seen.append(tok)
    return seen


# A leading-underscore lowercase token is almost always a Godot virtual method override
# (`_process`, `_ready`, `_physics_process`, ...) present in dozens of unrelated scripts since day
# one of every one of them — grepping for it finds "evidence" in whichever file was touched most
# recently, which is noise, not a signal that anything the decision cared about changed.
GENERIC_SYMBOL_RE = re.compile(r"^_[a-z][a-z0-9_]*$")


def find_file(repo, tok):
    """Exact tracked path, or a unique tracked file matching the basename — tries every token,
    since a decision may name a bare filename with no directory or extension (`agent`,
    `project.godot`)."""
    out = run(["git", "ls-files", "--", tok], repo).stdout.strip()
    if out:
        return out.splitlines()[0]
    base = os.path.basename(tok)
    out = run(["git", "ls-files", "--", "*/" + base, base], repo).stdout.strip()
    hits = [l for l in out.splitlines() if l]
    return hits[0] if len(hits) == 1 else None


DECLARATION_KEYWORDS = ("class_name", "func", "signal", "const", "var")


def find_declaration(repo, tok):
    """Where the symbol was actually introduced, as (path, [literal search strings]) or None.

    Two declaration shapes, because this codebase uses both: a `class_name`/`func`/`signal`/
    `const`/`var` line in a script, or a singleton registered by name in `project.godot`'s
    `[autoload]` section (`GameState`, `RewardService`, ... are never `class_name`'d — they're
    referenced globally by their autoload name). Either is real evidence the symbol exists;
    merely *mentioning* the name — `MultiMesh`/`SceneReplicationConfig` used as a parameter type
    in a dozen scripts since day one — is not, so a plain grep hit is deliberately not enough."""
    base = tok.split(".")[0]
    if GENERIC_SYMBOL_RE.match(base):
        return None
    autoload_needle = '%s="*res://' % base
    hit = run(["git", "grep", "-F", "-l", autoload_needle, "--", "project.godot"], repo).stdout.strip()
    if hit:
        return "project.godot", [autoload_needle]
    pattern = r"(class_name|func|signal|const|var)\s+" + re.escape(base) + r"\b"
    out = run(["git", "grep", "-P", "-l", "-e", pattern, "--"] + SOURCE_GLOBS, repo).stdout.strip()
    hits = [l for l in out.splitlines() if l and not l.startswith("docs/")]
    if not hits:
        return None
    return hits[0], ["%s %s" % (kw, base) for kw in DECLARATION_KEYWORDS]


def earliest_add_date(repo, path):
    out = run(["git", "log", "--diff-filter=A", "--format=%ad", "--date=short",
               "--follow", "--", path], repo).stdout.strip().splitlines()
    return out[-1] if out else None


def earliest_declaration_date(repo, path, needles):
    """Oldest commit whose diff added or removed any of `needles` in `path` — a proxy for 'when
    this was added', not merely 'when this file last changed'. One `-S` (literal pickaxe) call per
    needle rather than a combined `-G` regex: git's pickaxe regex engine does not reliably support
    `\\s`/`\\b`, so a single OR'd pattern silently matches nothing on some git builds."""
    dates = []
    for needle in needles:
        out = run(["git", "log", "-S", needle, "--format=%ad", "--date=short",
                   "--", path], repo).stdout.strip().splitlines()
        if out:
            dates.append(out[-1])  # oldest for this needle
    return min(dates) if dates else None


def scan(repo=ROOT, rev_note=""):
    text = open(os.path.join(repo, "docs", "DECISIONS.md")).read()
    decisions = list(parse_decisions(text))
    checkable, fired = 0, []
    for did, date, line_no, trigger, reviewed in decisions:
        if reviewed or not trigger:
            continue
        tokens = extract_tokens(trigger)
        if not tokens:
            continue
        checkable += 1
        for tok in tokens:
            path = find_file(repo, tok)
            if path:
                added = earliest_add_date(repo, path)
            else:
                found = find_declaration(repo, tok)
                if not found:
                    continue
                path, needles = found
                added = earliest_declaration_date(repo, path, needles)
            if added and added > date:
                fired.append((did, date, line_no, tok, path, added))
                break  # one confirmed hit is enough evidence to surface this decision
    return decisions, checkable, fired


def report(repo=ROOT):
    decisions, checkable, fired = scan(repo)
    print("DECISION_TRIGGER_CHECK decisions=%d checkable=%d fired=%d"
          % (len(decisions), checkable, len(fired)))
    for did, date, line_no, tok, path, added in fired:
        print("  FIRED %s (%s, docs/DECISIONS.md:%d) — trigger names `%s`, "
              "which now exists in %s (added %s, after the decision) — re-read the trigger clause"
              % (did, date, line_no, tok, path, added))
    if fired:
        print("\n%d decision(s) have a reversal trigger with mechanical evidence it fired." % len(fired))
        print("Read the clause in docs/DECISIONS.md. If it's still the right call, add a one-line")
        print("`*Reviewed <date> — <why>.*` under the heading; if not, write a new entry that")
        print("supersedes it. Either way, that annotation is what stops this decision from")
        print("re-flagging on every future run.")
    return fired


# --------------------------------------------------------------------------- self-test

def self_test():
    """Builds a throwaway repo with five decisions of known shape and proves each is judged
    correctly: a `class_name` symbol added after the decision (must FIRE), one that predates the
    decision (must NOT fire), a prose-only trigger with no backtick token (not mechanically
    checkable — must NOT fire), a fired trigger already annotated `*Reviewed ...*` (must NOT
    re-fire), and a `project.godot` autoload registration added after the decision (must FIRE —
    this is the D-041/`GameState` shape, the worked example the finding itself cites)."""
    tmp = tempfile.mkdtemp(prefix="decision_trigger_check_")
    try:
        def git(*args, env=None):
            e = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t",
                     GIT_COMMITTER_EMAIL="t@t")
            if env:
                e.update(env)
            r = subprocess.run(["git"] + list(args), cwd=tmp, capture_output=True, text=True, env=e)
            if r.returncode != 0:
                raise RuntimeError("git %s failed: %s" % (args, r.stderr))
            return r

        git("init", "-q")
        os.makedirs(os.path.join(tmp, "docs"))
        os.makedirs(os.path.join(tmp, "systems"))

        def commit(date, msg):
            git("commit", "-q", "-m", msg,
                env={"GIT_AUTHOR_DATE": date + "T12:00:00", "GIT_COMMITTER_DATE": date + "T12:00:00"})

        # Day 1: the decision doc, with five entries, and an old symbol D-002 already depends on.
        decisions_text = """# Decisions

### D-001 · 2026-01-01 · Fixture: seed authority is provisional
Placeholder body.
**Would change my mind:** the moment a `RunSeed` authority exists, switch to deriving from it.

### D-002 · 2026-01-01 · Fixture: pre-existing symbol, not new evidence
Placeholder body referencing `OldThing` which already exists.
**Would change my mind:** `OldThing` disappearing from the codebase.

### D-003 · 2026-01-01 · Fixture: prose-only trigger
Placeholder body.
**Would change my mind:** the team deciding this was a bad idea after playtesting.

### D-004 · 2026-01-01 · Fixture: fired but already reviewed
*Reviewed 2026-01-02 — still the right call, RunSeedAgain existing doesn't change the reasoning.*
Placeholder body.
**Would change my mind:** the moment a `RunSeedAgain` authority exists.

### D-005 · 2026-01-01 · Fixture: autoload singleton, not a class_name
Placeholder body referencing the future `RewardAuthority` autoload.
**Would change my mind:** the moment `RewardAuthority` is registered as an autoload.
"""
        with open(os.path.join(tmp, "docs", "DECISIONS.md"), "w") as f:
            f.write(decisions_text)
        with open(os.path.join(tmp, "systems", "old_thing.gd"), "w") as f:
            f.write("class_name OldThing\n")
        with open(os.path.join(tmp, "project.godot"), "w") as f:
            f.write("[application]\n\n[autoload]\n\n")
        git("add", "-A")
        commit("2026-01-01", "day 1: decisions + pre-existing OldThing")

        # Day 2: RunSeed lands (class_name) and RewardAuthority lands (autoload) — D-001 and D-005
        # should now fire; D-002/D-003/D-004 must not (predates, prose-only, and reviewed).
        with open(os.path.join(tmp, "systems", "run_seed.gd"), "w") as f:
            f.write("class_name RunSeed\n")
        with open(os.path.join(tmp, "systems", "run_seed_again.gd"), "w") as f:
            f.write("class_name RunSeedAgain\n")
        with open(os.path.join(tmp, "project.godot"), "a") as f:
            f.write('RewardAuthority="*res://systems/reward_authority.gd"\n')
        git("add", "-A")
        commit("2026-01-02", "day 2: RunSeed, RunSeedAgain and RewardAuthority land")

        decisions, checkable, fired = scan(tmp)
        fired_ids = {d for d, *_ in fired}

        cases = [
            ("D-001 fires (RunSeed added after the decision)", "D-001" in fired_ids),
            ("D-002 does not fire (OldThing predates the decision)", "D-002" not in fired_ids),
            ("D-003 does not fire (prose-only, no backtick token)", "D-003" not in fired_ids),
            ("D-004 does not fire (annotated *Reviewed ...*)", "D-004" not in fired_ids),
            ("D-005 fires (RewardAuthority autoload registered after the decision)",
             "D-005" in fired_ids),
            ("all five decisions were parsed", len(decisions) == 5),
            ("D-001/002/005 were checkable (D-003 has no token, D-004 is reviewed)", checkable == 3),
        ]
        failed = 0
        for label, ok in cases:
            print("  %s %s" % ("PASS" if ok else "FAIL", label))
            if not ok:
                failed += 1
        print("\n%d/%d passed" % (len(cases) - failed, len(cases)))
        return 1 if failed else 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--self-test", action="store_true",
                     help="prove the fire/no-fire distinction on synthetic history — does not "
                          "touch this repo")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    fired = report()
    return 0  # informational — never blocks a commit; see docstring


if __name__ == "__main__":
    sys.exit(main())
