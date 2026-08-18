#!/usr/bin/env python3
"""Focused check for F-119: `agent godot`'s own `--import` pre-pass must not emit undeclared
`ERROR:` lines.

F-093 made every `agent godot <...>` call run a real `--headless --import` pass before the caller's
own run (docs/DELEGATION.md, 2026-08-18 entry). On this machine that pre-pass itself printed, every
time, during `loading_editor_layout`:

    ERROR: Couldn't open external text editor, falling back to the internal editor. Review your
    `text_editor/external/` editor settings.
       at: edit (editor/script/script_editor_plugin.cpp:2229)

twice. Root cause: the shared per-user editor settings
(`~/Library/Application Support/Godot/editor_settings-4.7.tres` on macOS) had
`text_editor/external/use_external_editor = true` with an empty `exec_path` — every reopened script
in the saved layout tries the external editor, fails, and falls back. SPECS.md's standing rule 4
(F-021) says any undeclared `ERROR:` line is a failure, but nobody was grepping the pre-pass section:
an agent greps its own check's output, printed after the pre-pass already ran. This check greps the
whole thing.

Fix applied (not in this repo — the setting lives outside it, per-user):
`text_editor/external/use_external_editor` flipped to `false` in that `.tres`. No exec_path was ever
configured, so the external-editor path was dead weight, not a feature in use.

No fake-godot double here (unlike tools/harness_check.py's F-093 cases) — the bug lives in a real,
per-user global editor settings file that a double can't reproduce, so this runs the real engine
through the real wrapper:

    python3 tools/godot_prepass_check.py

Runs `.agent/bin/agent godot --import` for real (it takes the shared Godot lock itself, F-044, and
`--import` already in argv means `cmd_godot` does not double it into two passes — see F-093) and
fails if ANY `ERROR:` line appears anywhere in its output. Prints GODOT_PREPASS_CHECK ok / FAIL and
exits 0/1.

This is a machine-config regression guard, not a portable one: it asserts THIS machine's `agent
godot` boots clean, not that every clone's editor settings are correct. That is the right scope —
the pre-pass itself is local to whichever machine runs it.
"""

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
AGENT = ROOT / ".agent" / "bin" / "agent"


def main() -> int:
    proc = subprocess.run(
        [str(AGENT), "godot", "--import"],
        cwd=ROOT, capture_output=True, text=True, timeout=600,
    )
    out = proc.stdout + proc.stderr
    error_lines = [line for line in out.splitlines() if "ERROR:" in line]

    if error_lines:
        print("GODOT_PREPASS_CHECK FAIL (%d undeclared ERROR: line(s))" % len(error_lines))
        for line in error_lines:
            print("  " + line)
        return 1

    if proc.returncode != 0:
        print("GODOT_PREPASS_CHECK FAIL (agent godot --import exited %d, no ERROR: line seen)"
              % proc.returncode)
        print(out[-2000:])
        return 1

    print("GODOT_PREPASS_CHECK ok (0 ERROR: lines from `agent godot --import`)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
