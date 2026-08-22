#!/usr/bin/env python3
"""The standing regression guard for the two ways the findings queue rots (F-269).

`agent start` already detects both shapes and *prints a warning*. F-269 is the proof that a warning
is not enough: eight findings had drifted at once, four of them fixed and verified days earlier, and
every session since had seen the warning scroll past above the board it was trying to read. The same
argument `tools/findings_numbering_check.gd` makes for the numbering half — "this is the standing
regression guard so a reintroduced collision fails a check instead of only printing a warning nobody
reads" — applies here, and this is that guard for the drift half.

    python3 tools/findings_hygiene_check.py             # scan the live records
    python3 tools/findings_hygiene_check.py --self-test # prove both detectors on synthetic docs

SOURCE-TEXT check, like `decision_ref_check.py` — a doc/state consistency property, nothing a
running game can fail against, so it does not go through `agent godot`.

**It imports `.agent/bin/agent` rather than re-deriving the rules.** Two implementations of "is this
finding rotted" would drift apart, and then the check and the board would disagree about the queue —
the exact two-records-of-one-fact failure (F-071) this whole area is about. The detectors live in
the harness; this file decides that they are *failures* and proves they still fire.

Shape 1 — **drift** (`_findings_drift`, F-071). `agent done` ran, the section never moved. `board`
reads state and hides it; `brief` reads the doc and offers it as claimable work. A lane can be
routed at finished work, which is how F-269 itself was written.

Shape 2 — **self-resolved** (`_self_resolved_findings`). The resolution was written INTO the entry
— a `— **fixed**` heading suffix or a `**Resolved ...**` body line — and neither the section nor the
status ever moved. Both records agree it is open, so nothing disagrees and no drift is detectable;
only the prose knows.

Deliberately NOT checked: duplicate F-numbers. `tools/findings_numbering_check.gd` owns that shape
already, and duplicating it here would mean two checks failing on one defect.

A finding that is genuinely NOT fixed is not a violation of either shape — `agent reopen <id> "why"`
is the correct exit, and it clears shape 1 by correcting the status rather than by moving the
section. `agent done` gets used to mean "my session ended", which is not the same fact (F-131).
"""

import argparse
import importlib.util
import json
import os
import re
import shutil
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _load_harness(root):
    """Import `.agent/bin/agent` as a module. It has no `.py` suffix, so the loader is explicit."""
    path = os.path.join(root, ".agent", "bin", "agent")
    spec = importlib.util.spec_from_loader(
        "mire_agent_harness", importlib.machinery.SourceFileLoader("mire_agent_harness", path))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def structure(root):
    """Structural faults in docs/FINDINGS.md, as a list of human-readable strings.

    The two detectors below both ask "is this finding in the right SECTION?", which quietly assumes
    the sections exist and that the parser agrees with the file about where they are. Three times now
    that assumption has been the thing that broke (F-134), and each time it was a hand-edit rather
    than the tooling: a slice from a heading to the next `### F-` steps over the boundary when the
    finding being moved is the last one under `## Open`, and a splice at `text.index("## Resolved")`
    can land on a mention of that string inside a finding's own BODY — which is exactly how
    bram937a51 spliced two entries into the middle of F-464 on 2026-08-22, F-464 being the finding
    about parsers being fooled by `##` inside a body.

    `agent resolve` already refuses to write when the marker is missing, and that refusal is what
    caught it. This is the same assertion made where it costs nothing to run: no Godot, no lock. A
    rule that says "never hand-edit" failed precisely because it was a rule and not a guard.
    """
    faults = []
    with open(os.path.join(root, "docs", "FINDINGS.md"), encoding="utf-8") as f:
        text = f.read()
    for heading in ("## Open", "## Resolved"):
        n = len(re.findall(r"^%s\s*$" % re.escape(heading), text, re.M))
        if n != 1:
            faults.append("docs/FINDINGS.md has %d '%s' heading(s), expected exactly 1 — a hand-edit "
                          "has eaten or duplicated a section boundary (F-134)" % (n, heading))
    if faults:
        # Counting entries per section is meaningless once the boundary itself is wrong, and would
        # bury the one fault that matters under a wall of derived ones.
        return faults
    open_text = text.split("\n## Resolved\n", 1)[0].split("\n## Open\n", 1)[1]
    physical = len(re.findall(r"^### F-\d+", open_text, re.M))
    parsed = len(_load_harness(root)._open_findings())
    if parsed != physical:
        # F-464: a level-2 heading inside a finding's body closes the open section early for the
        # scanner, so every finding filed after it becomes invisible to every tool that reads the
        # doc — while still being visibly present to a human reading the file.
        faults.append("docs/FINDINGS.md has %d '### F-' heading(s) physically under '## Open' but "
                      "the scanner sees %d — a '## ' heading inside a finding body is hiding the "
                      "rest of the section (F-464)" % (physical, parsed))
    return faults


def scan(root):
    """(drift, self_resolved) for the records under `root`, using the harness's own detectors."""
    harness = _load_harness(root)
    harness.ROOT = root
    harness.FINDINGS = os.path.join(root, "docs", "FINDINGS.md")
    harness.STATE = os.path.join(root, ".agent", "state.json")
    with open(harness.STATE) as f:
        st = json.load(f)
    st.setdefault("tasks", {})
    return harness._findings_drift(st), harness._self_resolved_findings()


def report(root, label="live records"):
    print("FINDINGS_HYGIENE_CHECK — %s" % label)
    faults = structure(root)
    for fault in faults:
        print("  FAIL: %s" % fault)
    if faults:
        # A broken section boundary makes every per-finding verdict below it a guess, so stop here
        # rather than printing verdicts derived from a file we have just proved we cannot read.
        print("  (skipping the per-finding detectors — they read the sections this fault breaks)")
        return len(faults)
    drift, settled = scan(root)
    for fid in settled:
        print("  FAIL: %s sits under '## Open' but its own text says it is resolved — move the "
              "section with `agent resolve %s`, or delete the claim from its body" % (fid, fid))
    for fid in drift:
        print("  FAIL: %s is done in state.json but still under '## Open' — `agent resolve %s` if "
              "it IS fixed, `agent reopen %s \"why\"` if it is not" % (fid, fid, fid))
    if not drift and not settled:
        print("  PASS: no finding under '## Open' is recorded or written as already resolved")
    return len(drift) + len(settled)


_SYNTH_FINDINGS = """# FINDINGS

## Open

### F-001 · A genuinely open finding

**Area:** tooling · **Severity:** low · **Found:** 2026-08-20 by synth

Nothing about this one is resolved.

---

### F-002 · A finding whose own heading says it is done — **fixed**

**Area:** tooling · **Severity:** low · **Found:** 2026-08-20 by synth

Shape 2: the heading carries the resolution and the section never moved.

---

### F-003 · A finding closed with `agent done` that nobody moved

**Area:** tooling · **Severity:** low · **Found:** 2026-08-20 by synth

Shape 1: state.json says done, the doc still says open.

---

## Resolved

### F-004 · Correctly resolved — **fixed**

**Resolved 2026-08-20 by synth.** Moved, as it should have been.
"""


def _self_test():
    """Prove both detectors fire, and that a clean file passes. An assertion that has never failed
    is not evidence — F-259's own close-out note, and the reason this mode exists."""
    harness = _load_harness(ROOT)
    failures = 0
    tmp = tempfile.mkdtemp(prefix="findings_hygiene_")
    try:
        os.makedirs(os.path.join(tmp, "docs"))
        os.makedirs(os.path.join(tmp, ".agent", "bin"))
        shutil.copy(os.path.join(ROOT, ".agent", "bin", "agent"),
                    os.path.join(tmp, ".agent", "bin", "agent"))
        findings = os.path.join(tmp, "docs", "FINDINGS.md")
        state = os.path.join(tmp, ".agent", "state.json")
        m = harness.FINDINGS_MILESTONE

        def write(text, tasks):
            with open(findings, "w") as f:
                f.write(text)
            with open(state, "w") as f:
                json.dump({"tasks": tasks}, f)

        def expect(name, want_drift, want_settled):
            nonlocal failures
            drift, settled = scan(tmp)
            if drift != want_drift or settled != want_settled:
                failures += 1
                print("  FAIL: %s — drift=%s settled=%s, wanted drift=%s settled=%s"
                      % (name, drift, settled, want_drift, want_settled))
            else:
                print("  PASS: %s" % name)

        done = {"F-003": {"milestone": m, "status": "done", "done_at": "2026-08-20T00:00:00+00:00"}}
        write(_SYNTH_FINDINGS, done)
        expect("both shapes detected, and neither fires on the open or the resolved entry",
               ["F-003"], ["F-002"])

        # Shape 1's exit that is NOT a move: reopening corrects the status, so the drift clears
        # while the section stays exactly where it is (F-131).
        write(_SYNTH_FINDINGS, {"F-003": {"milestone": m, "status": "todo"}})
        expect("reopening F-003 clears the drift without moving its section", [], ["F-002"])

        # Shape 2 is prose, not bookkeeping: marking it done converts it into shape 1 rather than
        # silencing it, which is what stops `agent done` from being a way to hide the warning.
        write(_SYNTH_FINDINGS, {"F-002": {"milestone": m, "status": "done",
                                          "done_at": "2026-08-20T00:00:00+00:00"}})
        expect("F-002 marked done becomes drift too, not silence", ["F-002"], ["F-002"])

        clean = _SYNTH_FINDINGS.replace(" — **fixed**\n\n**Area:** tooling · **Severity:** low · "
                                        "**Found:** 2026-08-20 by synth\n\nShape 2",
                                        "\n\n**Area:** tooling · **Severity:** low · "
                                        "**Found:** 2026-08-20 by synth\n\nShape 2")
        write(clean, {})
        expect("a clean file passes both detectors", [], [])

        def expect_structure(name, want_count, must_mention):
            nonlocal failures
            faults = structure(tmp)
            if len(faults) != want_count or not all(
                    any(needle in f for f in faults) for needle in must_mention):
                failures += 1
                print("  FAIL: %s — got %r" % (name, faults))
            else:
                print("  PASS: %s" % name)

        # An assertion that has never failed is not evidence, so each structural fault is reproduced
        # from the way it actually happened rather than asserted in the abstract.
        write(_SYNTH_FINDINGS, {})
        expect_structure("a well-formed file has no structural fault", 0, [])

        # F-134, three times over: a slice from a heading to the next '### F-' steps past the
        # boundary when the finding being moved is the LAST one under '## Open', and takes the
        # '## Resolved' heading with it.
        write(_SYNTH_FINDINGS.replace("\n## Resolved\n", "\n"), {})
        expect_structure("a swallowed '## Resolved' heading is caught", 1, ["'## Resolved' heading"])

        # The repair that goes wrong the other way: splicing at text.index("## Resolved") can land on
        # a mention of that string inside a finding's own body, duplicating the boundary.
        write(_SYNTH_FINDINGS.replace("\n## Resolved\n", "\n## Resolved\n\n## Resolved\n"), {})
        expect_structure("a duplicated boundary is caught too", 1, ["2 '## Resolved' heading"])

        # F-464: a level-2 heading inside a body closes the open section early for the scanner, so
        # every finding filed after it is invisible to every tool while still visible to a human.
        write(_SYNTH_FINDINGS.replace("Nothing about this one is resolved.",
                                      "Nothing about this one is resolved.\n\n## Notes\n\nmore"), {})
        expect_structure("a '## ' heading inside a body hides the rest of the section", 1,
                         ["hiding the rest of the section"])

        # And the boundary fault wins: with no '## Resolved' at all, the count assertion below it is
        # derived from a file we have just proved we cannot read, so it must not also be reported.
        write(_SYNTH_FINDINGS.replace("\n## Resolved\n", "\n").replace(
            "Nothing about this one is resolved.",
            "Nothing about this one is resolved.\n\n## Notes\n\nmore"), {})
        expect_structure("a broken boundary suppresses the derived count fault", 1,
                         ["'## Resolved' heading"])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("SELF_TEST failures=%d" % failures)
    return failures


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--self-test", action="store_true",
                    help="prove both detectors on synthetic docs instead of scanning the repo")
    args = ap.parse_args()
    if args.self_test:
        return 1 if _self_test() else 0
    n = report(ROOT)
    print("FINDINGS_HYGIENE_CHECK failures=%d" % n)
    return 1 if n else 0


if __name__ == "__main__":
    sys.exit(main())
