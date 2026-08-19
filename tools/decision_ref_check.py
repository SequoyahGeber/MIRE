#!/usr/bin/env python3
"""Finds dangling `D-NNN` citations across docs/*.md (F-229).

F-229: `docs/SPECS.md` cited `D-095` twice for decisions that actually landed as `D-096` and
`D-097` — both typos predated task 4.7's own, correctly-numbered `D-095` and only surfaced when
4.7 claimed that slot for real, making both stale citations resolve to the wrong page instead of
no page at all. A citation that resolves to *something* is the dangerous case (nothing about it
looks broken until you read the target and it's about a different system entirely) — this tool
catches the mechanically detectable half of that shape: a `D-NNN` cited somewhere in the docs tree
that does not correspond to any `### D-NNN` heading in `docs/DECISIONS.md` at all, which is exactly
what F-229's own two references *would* have been flagged as if 4.7 had never claimed D-095.

It cannot catch a citation that resolves to a real, wrong decision (that needs a human to notice
the prose doesn't match, same as F-229 originally was) — narrowing what needs that read is the
goal, not replacing it, same posture as `decision_trigger_check.py`.

    python3 tools/decision_ref_check.py            # scan the live docs tree
    python3 tools/decision_ref_check.py --self-test # prove dangling detection on synthetic docs

Regression pin: also asserts the two exact citations F-229 fixed (`docs/SPECS.md` lines citing the
AI-framework and ChunkStreamer decisions) still point at `D-097`/`D-096`, not `D-095` — so this
specific collision cannot silently come back if a future edit reflows those lines.
"""

import argparse
import glob
import os
import re
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DECISIONS = os.path.join(ROOT, "docs", "DECISIONS.md")
DOCS_GLOB = os.path.join(ROOT, "docs", "*.md")

HEADING_RE = re.compile(r"^### (D-\d+)\s*·", re.M)
CITE_RE = re.compile(r"\bD-(\d{3})\b")

# The two exact strings F-229 fixed, pinned so a future reflow of these lines can't silently
# reintroduce the typo without this check noticing. Matched loosely (id + a few words of the
# surrounding sentence) so a harmless rewording nearby doesn't false-fail the pin.
PINNED = [
    ("docs/SPECS.md", "extracting a swappable brain class", "D-097"),
    ("docs/SPECS.md", "records why no new API", "D-096"),
]


def defined_decisions(decisions_text):
    return set(HEADING_RE.findall(decisions_text))


def find_dangling(defined, doc_paths_and_text):
    """Yields (path, line_no, ref) for every D-NNN cited in a doc that isn't a real heading in
    DECISIONS.md. DECISIONS.md's own body is scanned too (a decision can reference an earlier
    one), but its own headings obviously don't count as citations of themselves."""
    dangling = []
    for path, text in doc_paths_and_text:
        for m in CITE_RE.finditer(text):
            ref = "D-" + m.group(1)
            if ref in defined:
                continue
            line_no = text.count("\n", 0, m.start()) + 1
            dangling.append((path, line_no, ref))
    return dangling


def check_pins(doc_paths_and_text):
    text_by_path = dict(doc_paths_and_text)
    results = []
    for path, needle, want_id in PINNED:
        text = text_by_path.get(path, "")
        idx = text.find(needle)
        if idx == -1:
            results.append((path, needle, want_id, None, "needle not found (line reworded?)"))
            continue
        # Nearest D-NNN citation within 200 chars either side of the pinned phrase.
        window = text[max(0, idx - 200): idx + len(needle) + 200]
        cites = CITE_RE.findall(window)
        got = ("D-" + cites[0]) if cites else None
        ok = got == want_id
        results.append((path, needle, want_id, got, "ok" if ok else "MISMATCH"))
    return results


def load_docs(repo=ROOT):
    out = []
    for path in sorted(glob.glob(os.path.join(repo, "docs", "*.md"))):
        with open(path, encoding="utf-8") as f:
            out.append((os.path.relpath(path, repo), f.read()))
    return out


def report(repo=ROOT):
    docs = load_docs(repo)
    decisions_text = dict(docs).get("docs/DECISIONS.md", "")
    defined = defined_decisions(decisions_text)
    dangling = find_dangling(defined, docs)
    pins = check_pins(docs)

    print("DECISION_REF_CHECK defined=%d dangling=%d" % (len(defined), len(dangling)))
    for path, line_no, ref in dangling:
        print("  DANGLING %s:%d cites %s, which has no heading in docs/DECISIONS.md" %
              (path, line_no, ref))

    pin_failures = 0
    for path, needle, want_id, got, status in pins:
        print("  PIN %s [%s] want=%s got=%s -> %s" % (path, needle[:40], want_id, got, status))
        if status != "ok":
            pin_failures += 1

    failures = len(dangling) + pin_failures
    print("DECISION_REF_CHECK failures=%d" % failures)
    return failures


# --------------------------------------------------------------------------- self-test

def self_test():
    decisions_text = """# Decisions

### D-001 · 2026-01-01 · Fixture: real decision
Body.

### D-002 · 2026-01-01 · Fixture: another real decision
Body.
"""
    specs_text = """## Some task
References D-001 correctly.
References D-999, which does not exist.
"""
    docs = [("docs/DECISIONS.md", decisions_text), ("docs/SPECS.md", specs_text)]
    defined = defined_decisions(decisions_text)
    dangling = find_dangling(defined, docs)
    dangling_refs = {ref for _, _, ref in dangling}

    cases = [
        ("D-001 is not flagged (real heading exists)", "D-001" not in dangling_refs),
        ("D-999 is flagged (no heading)", "D-999" in dangling_refs),
        ("exactly one dangling reference found", len(dangling) == 1),
    ]
    failed = 0
    for label, ok in cases:
        print("  %s %s" % ("PASS" if ok else "FAIL", label))
        if not ok:
            failed += 1
    print("\n%d/%d passed" % (len(cases) - failed, len(cases)))
    return 1 if failed else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--self-test", action="store_true",
                     help="prove dangling-reference detection on synthetic docs — does not touch "
                          "this repo")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    failures = report()
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
