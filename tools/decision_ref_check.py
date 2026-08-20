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

F-283 added the other half of the same shape: a `D-NNN` that heads *two* decisions. That is F-229's
dangerous case by construction — every citation of the number resolves, silently, to whichever of
the two entries the reader scrolls to first — and the dangling scan above passes it twice over,
because a set of defined ids cannot tell one heading from two. Three were live at HEAD (`D-050`,
`D-144`, `D-150`, all allocated before `agent decision` took a lock, F-260); the renumbering pass is
in F-283 and the assertion below is what stops the next one. It is deliberately a hard failure and
not a warning: the allocator makes a new collision impossible, so a duplicate reappearing means
something wrote a heading by hand, which is exactly the thing to catch at the commit that does it.

It cannot catch a citation that resolves to a real, wrong decision (that needs a human to notice
the prose doesn't match, same as F-229 originally was) — narrowing what needs that read is the
goal, not replacing it, same posture as `decision_trigger_check.py`.

    python3 tools/decision_ref_check.py            # scan the live docs tree
    python3 tools/decision_ref_check.py --self-test # prove dangling + duplicate detection

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


def duplicate_decisions(decisions_text):
    """Yields (id, [line numbers]) for every D-NNN that heads more than one entry (F-283).

    Line numbers, not just the id: the whole point of the failure is to send the reader to the two
    pages that share a number, and 'D-150 appears twice' without them is a second search."""
    seen = {}
    for m in HEADING_RE.finditer(decisions_text):
        line_no = decisions_text.count("\n", 0, m.start()) + 1
        seen.setdefault(m.group(1), []).append(line_no)
    return [(ref, lines) for ref, lines in sorted(seen.items()) if len(lines) > 1]


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
    duplicates = duplicate_decisions(decisions_text)
    pins = check_pins(docs)

    print("DECISION_REF_CHECK defined=%d dangling=%d duplicate=%d" %
          (len(defined), len(dangling), len(duplicates)))
    for path, line_no, ref in dangling:
        print("  DANGLING %s:%d cites %s, which has no heading in docs/DECISIONS.md" %
              (path, line_no, ref))
    for ref, line_nos in duplicates:
        print("  DUPLICATE %s heads %d entries in docs/DECISIONS.md (lines %s) — every citation of "
              "it resolves to whichever a reader finds first. Renumber the later one with "
              "`agent decision`'s allocator and move its citations with it (F-283)." %
              (ref, len(line_nos), ", ".join(str(n) for n in line_nos)))

    pin_failures = 0
    for path, needle, want_id, got, status in pins:
        print("  PIN %s [%s] want=%s got=%s -> %s" % (path, needle[:40], want_id, got, status))
        if status != "ok":
            pin_failures += 1

    failures = len(dangling) + len(duplicates) + pin_failures
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

    # F-283's shape: the same number heading two unrelated entries. The clean fixture above is the
    # negative control — a detector that only ever fires is worth as little as one that never does,
    # so both directions are asserted against fixtures that differ in exactly this one respect.
    colliding_text = decisions_text + """
### D-002 · 2026-01-02 · Fixture: an unrelated decision that reused D-002
Body.
"""
    clean_dupes = duplicate_decisions(decisions_text)
    colliding_dupes = duplicate_decisions(colliding_text)

    cases = [
        ("D-001 is not flagged (real heading exists)", "D-001" not in dangling_refs),
        ("D-999 is flagged (no heading)", "D-999" in dangling_refs),
        ("exactly one dangling reference found", len(dangling) == 1),
        ("a file with no repeated heading reports no duplicates", clean_dupes == []),
        ("a repeated D-number is flagged", [r for r, _ in colliding_dupes] == ["D-002"]),
        ("the duplicate names both of its heading lines",
         colliding_dupes[0][1] == [6, 9] if colliding_dupes else False),
        ("the singleton D-001 is not swept up with it",
         "D-001" not in [r for r, _ in colliding_dupes]),
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
