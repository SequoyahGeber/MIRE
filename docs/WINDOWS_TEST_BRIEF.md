# MIRE Windows validation brief

Copy the prompt below into Codex on the physical Windows gaming PC. This first run is deliberately
read-only: it establishes the machine and closes the Windows side of the world-generation
determinism gate. Do not start multiplayer or export testing until this baseline is returned.

```text
You are validating MIRE, a co-op Godot game, on a physical Windows x86_64 gaming PC. Work in
PowerShell. Your job is to collect reproducible evidence, not change the project.

Repository: https://github.com/SequoyahGeber/MIRE.git
Required engine: stock Godot 4.7.1-stable Windows x86_64, official build a13da4feb

Rules:
1. Clone into a new directory. If a MIRE directory already exists, do not delete, reset, clean, pull,
   or overwrite it. Use a different new directory instead.
2. Read AGENTS.md after cloning and obey it. Run `.agent/bin/agent start` only if it works in your
   shell; this is a read-only validation, so do not claim a task, edit files, commit, or push.
3. Do not open or save the project in the Godot editor. Do not install addons, regenerate imports,
   edit project.godot, or run formatting.
4. Use only the stock Godot 4.7.1 executable from an official Godot download. Do not substitute a
   different engine version, a Steam build, Mono/.NET build, custom build, or GodotSteam editor.
5. Before running project checks, install the pinned GodotSteam addon using D-022's recipe (adapt its
   `curl`/`unzip`/copy steps to PowerShell without changing the URL or commit), then run
   `<godot-exe> --headless --editor --path . --quit` once to generate imports and the global class
   cache. The addon is intentionally absent from Git; skipping this produces 306 misleading startup
   errors on a raw clone.
6. If any prerequisite or version is wrong, stop and report it; do not improvise around it.
7. Preserve complete stdout and stderr. A mismatch is valuable evidence and must not be hidden.

Procedure:

A. Record environment evidence:
- Windows edition, version, and OS build (`Get-ComputerInfo` fields are sufficient).
- CPU name and architecture.
- GPU name and driver version.
- `git --version`.
- The absolute path to the Godot executable.
- Run `<godot-exe> --version`. It must identify 4.7.1 stable and official build a13da4feb.

B. Clone and pin the exact revision:
- `git clone https://github.com/SequoyahGeber/MIRE.git`
- Enter the new clone.
- `git status --short --branch`
- `git rev-parse HEAD`
- `git log -1 --format="%H%n%cI%n%s"`

C. Run both probes from the repository root, replacing `<godot-exe>` with the quoted absolute path:
- `& <godot-exe> --headless --path . --script tools/check_determinism.gd 2>&1 | Tee-Object windows-determinism-run1.txt`
- `& <godot-exe> --headless --path . --script tools/check_determinism_ops.gd 2>&1 | Tee-Object windows-determinism-ops-run1.txt`
- Repeat both commands as run2, writing `windows-determinism-run2.txt` and
  `windows-determinism-ops-run2.txt`.

D. Verify the checkout was not modified:
- `git status --short`
- Calculate SHA-256 hashes for the four output text files with `Get-FileHash`.

E. Return one report in your final response containing:
- All environment evidence from A.
- Commit evidence from B.
- Complete, unabridged output of all four runs.
- The final `git status --short` output.
- The four report-file SHA-256 values.
- A small comparison table showing whether run1 equals run2 for every reported hash.
- A second comparison against these established macOS/Linux values:
  `rng_sequence 0077d6b42cd6f78f`
  `noise_simplex 181e558b7b4841cf`
  `noise_perlin 6c7a944516e3e64f`
  The ops probe's first group (`arith`, `sqrt`, `vec2_length`, `falloff_safe`) is required to match
  the baselines recorded in `docs/ARCHITECTURE.md` section 6a. The second group is expected to vary.
- End with exactly one verdict: PASS, FAIL, or BLOCKED. PASS requires the pinned engine, two
  internally identical runs, matching required cross-platform hashes, zero probe errors, and no
  tracked checkout changes. FAIL means the test ran but a required check differed. BLOCKED means a
  prerequisite prevented a valid test.

Do not fix any failure. Report it exactly and wait for Sequoyah to send the evidence back to the
main MIRE task.
```

## What Sequoyah needs during the call

Confirm that the friend has enough disk space for the repository plus a stock Godot download, can
open PowerShell, can sign into Codex, and can access the public GitHub repository. No GitHub write
access, branch, token, Steam account, port forwarding, or game assets are needed for this first run.

If time remains, confirm availability for a later scheduled multiplayer session. That later brief
will require Sequoyah's Mac and the Windows PC online at the same time, Steam running under distinct
accounts, matching commits/builds, and voice contact. Do not attempt it from this determinism brief.
