#!/usr/bin/env python3
"""Generate the derived half of docs/NEXT.md, and check the committed file still matches it (F-306).

    python3 tools/next_gen.py            # check: exit 1 if the committed block is stale
    python3 tools/next_gen.py --write    # regenerate the block in place
    python3 tools/next_gen.py --self-test

NEXT.md is the plan a human reads first, and it restated numbers that live authoritatively elsewhere:
task counts from `.agent/state.json`, open-finding counts and the "pick up today" list from
`docs/FINDINGS.md`. In a repo where several lanes land work every hour, a hand-maintained restatement
of fast-moving state is stale within hours — measured twice in one night, by two different reviewers
correcting the same document (F-306). A stale "pick up today" list is worse than stale prose: the
director and any fresh agent read it as current routing.

So the numbers are generated and the judgement is not. Everything between the two markers below is
rewritten from source; everything outside them — what the project is trying to do next, and why — is
hand-written and never touched, because that part does not drift.
"""
import argparse
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NEXT = os.path.join(ROOT, "docs", "NEXT.md")
STATE = os.path.join(ROOT, ".agent", "state.json")
FINDINGS = os.path.join(ROOT, "docs", "FINDINGS.md")

BEGIN = "<!-- BEGIN GENERATED — python3 tools/next_gen.py --write. Do not hand-edit. -->"
END = "<!-- END GENERATED -->"

## Findings that are open but are not code a lane can sit down and write — they need hardware, a
## second machine, or a human's eyes. Listed so the generated candidate count means "work available
## here", which is the number a router actually wants. Kept as data rather than inferred: nothing in
## the finding text reliably says "this needs a second PC".
EXTERNALLY_GATED = {
    "F-023": "needs the physical Windows PC and a real Steam lobby",
    "F-025": "needs a first-join latency measured on real hardware",
    "F-174": "no dev machine here stands in for mid-range",
}


def milestone_counts(state):
    """(done, total) per milestone and overall, counting ROADMAP tasks only.

    Findings live in the same dict and are deliberately excluded: they are not milestone progress,
    and folding them in is what made the hand-written percentages disagree with `agent board`.
    """
    per = {}
    for tid, task in state.get("tasks", {}).items():
        if tid.startswith("F-"):
            continue
        ms = task.get("milestone", "?")
        done, total = per.get(ms, (0, 0))
        per[ms] = (done + (1 if task.get("status") == "done" else 0), total + 1)
    return per


def open_findings(findings_text):
    """Ids under '## Open', in file order — newest first, which is how `agent finding` inserts.

    The candidate list below re-sorts ascending, because oldest-first is the order a finding backlog
    should actually be worked: an entry that has survived three hundred numbers is either the hardest
    or the most avoided, and file order buries it. The section boundary is the whole of the definition —
    `state.json` and this file disagree, and FINDINGS is the authority (F-269/F-270)."""
    head, _, _ = findings_text.partition("\n## Resolved\n")
    return re.findall(r"^### (F-\d+)\s*·", head, re.M)


def in_flight_findings(state):
    return {tid for tid in state.get("in_flight", {}) if tid.startswith("F-")}


def stale_done(state, open_ids):
    """Findings marked done in state but still under '## Open' — the drift F-269 is about."""
    tasks = state.get("tasks", {})
    return [f for f in open_ids if tasks.get(f, {}).get("status") == "done"]


def render(state, findings_text):
    per = milestone_counts(state)
    done = sum(d for d, _ in per.values())
    total = sum(t for _, t in per.values())
    opened = open_findings(findings_text)
    flying = in_flight_findings(state)
    stale = stale_done(state, opened)
    gated = [f for f in opened if f in EXTERNALLY_GATED]
    available = sorted((f for f in opened
                        if f not in flying and f not in stale and f not in EXTERNALLY_GATED),
                       key=lambda f: int(f.split("-")[1]))

    lines = [BEGIN, ""]
    lines.append("**Tasks: %d/%d done.** %s" % (
        done, total,
        " · ".join("%s %d/%d" % (ms, per[ms][0], per[ms][1]) for ms in sorted(per))))
    lines.append("")
    lines.append("**Findings: %d under `## Open`.** %d in flight · %d externally gated · "
                 "**%d available to pick up now**%s"
                 % (len(opened), len(flying & set(opened)), len(gated), len(available),
                    " · %d marked done but still under `## Open`" % len(stale) if stale else ""))
    lines.append("")

    if gated:
        lines.append("Externally gated — do not route these to a lane:")
        lines.append("")
        for f in gated:
            lines.append("- **%s** — %s" % (f, EXTERNALLY_GATED[f]))
        lines.append("")

    if stale:
        lines.append("Marked done but still under `## Open` — read the entry before claiming; "
                     "`agent board` hides these while `agent brief` still offers them:")
        lines.append("")
        lines.append("- " + " · ".join(stale))
        lines.append("")

    lines.append("Available now, oldest first: " + (", ".join(available) if available else "none"))
    lines.append("")
    lines.append(END)
    return "\n".join(lines)


def apply(text, block):
    """Replace the marked block, or append one if the file has never had it."""
    if BEGIN in text and END in text:
        start = text.index(BEGIN)
        end = text.index(END) + len(END)
        return text[:start] + block + text[end:]
    return text.rstrip("\n") + "\n\n---\n\n" + block + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true", help="regenerate the block in docs/NEXT.md")
    ap.add_argument("--self-test", action="store_true", help="run on fixtures, touching no file")
    args = ap.parse_args()
    if args.self_test:
        return self_test()

    with open(STATE) as f:
        state = json.load(f)
    with open(FINDINGS) as f:
        findings_text = f.read()
    with open(NEXT) as f:
        text = f.read()

    block = render(state, findings_text)
    updated = apply(text, block)

    if args.write:
        if updated != text:
            with open(NEXT, "w") as f:
                f.write(updated)
            print("NEXT_GEN rewrote the generated block in docs/NEXT.md")
        else:
            print("NEXT_GEN docs/NEXT.md already current")
        return 0

    if updated != text:
        print("NEXT_GEN failures=1")
        print("  docs/NEXT.md's generated block is stale. It restates task and finding counts that")
        print("  move hourly, and a stale 'available now' list is a routing hazard — the director")
        print("  reads it as current work (F-306). Regenerate it:")
        print("      python3 tools/next_gen.py --write")
        return 1
    print("NEXT_GEN failures=0")
    return 0


def self_test():
    state = {
        "tasks": {
            "1.1": {"milestone": "M1", "status": "done"},
            "1.2": {"milestone": "M1", "status": "todo"},
            "2.1": {"milestone": "M2", "status": "done"},
            "F-001": {"status": "todo"},
            "F-002": {"status": "done"},
            "F-023": {"status": "todo"},
        },
        "in_flight": {"F-003": {}, "1.2": {}},
    }
    findings = ("## Open\n\n### F-001 · a\n\n---\n\n### F-002 · b\n\n---\n\n"
                "### F-003 · c\n\n---\n\n### F-023 · d\n\n---\n\n"
                "## Resolved\n\n### F-900 · old\n")
    block = render(state, findings)
    cases = [
        ("findings are excluded from milestone counts", "**Tasks: 2/3 done.**" in block),
        ("per-milestone line is rendered", "M1 1/2 · M2 1/1" in block),
        ("open findings counted from the section, not state", "**Findings: 4 under" in block),
        ("an in-flight finding is not offered", "F-003" not in block.split("Available now")[1]),
        ("a done-but-open finding is called out", "F-002" in block and "Marked done" in block),
        ("an externally gated finding is separated out", "F-023" in block and "1 externally gated" in block),
        ("what is left is the available list", block.rstrip().endswith("F-001\n\n" + END)
         or "Available now, oldest first: F-001" in block),
        ("a file with no markers gains one", BEGIN in apply("# Doc\n\nbody\n", block)),
        ("a second apply is idempotent",
         apply(apply("# Doc\n\nbody\n", block), block) == apply("# Doc\n\nbody\n", block)),
    ]
    failed = 0
    for label, ok in cases:
        print("  %s %s" % ("PASS" if ok else "FAIL", label))
        if not ok:
            failed += 1
    print("\n%d/%d passed" % (len(cases) - failed, len(cases)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
