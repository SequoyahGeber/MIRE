# MENU — the front end, end to end

> Written 2026-08-20 (reed31c598) on Sequoyah's directive: *"plan out the game menu, every aspect,
> UI/UX and design"* — with the explicit steer **"don't limit yourself to the current code or plan,
> it can all be redone, I want a good menu."** So this document designs the menu MIRE should ship
> with, from the game's identity outward. Shipped UI is treated as raw material: §10 gives a
> disposition (keep / rework / replace) for every existing file, and §11 turns the whole design into
> ordered, claimable tasks with acceptance checks. Sibling docs: `GAMELOOP.md` (the run this menu
> wraps), `WORLDGEN.md` (the island the backdrop shows), `DESIGN.md` (identity this must sell).
>
> **Reading rule (same as GAMELOOP.md):** every element below either names the shipped system that
> carries it or carries a task id from §11. Nothing is aspiration without an address.

---

## 1 · What the menu is for

Three jobs, in priority order, taken straight from the design pillars:

1. **D5 — zero-friction co-op is the product.** From a cold boot, a player must be in a lobby with
   friends in **two clicks**, and a friend accepting a Steam invite must land in that lobby in
   **one**. Every screen between "I want to play with you" and "we are playing" is friction that
   kills the actual product. The menu's information architecture is built around this path; solo
   play is the same path with nobody else on the dock.
2. **Sell the identity in five seconds.** "The island is the health bar" — the menu backdrop *is* a
   doomed island, live, fog rolling, the Mire visibly chewing the shoreline. A stranger watching a
   friend's screen at the title should already understand the game: an island, a bog eating it,
   warm light worth defending. (Atmosphere target per art direction: Valheim-warm, not haze.)
3. **Make the number matter.** The brag is *"we made it to Cycle 9"* (DESIGN §1). The menu is where
   that number lives between runs: the last-expedition card on the title screen, the run-summary
   ceremony, the salvage bench. The menu turns a run into a story you can point at.

**Tone:** silly-but-atmospheric. The *world* is moody; the *words* are dumb and warm. Copy rules in
§8. Never lore (DESIGN §6).

---

## 2 · The map — every screen, one diagram

```
 boot
  │  <2s studio card, any key skips (MENU-3)
  ▼
 TITLE ──────────────────────────────┐ backdrop: live doomed island (§4)
  │ PLAY                             │ UNLOCKS → Salvage Bench (§7.2)
  │                                  │ SETTINGS → Settings (§7.1)
  ▼                                  │ CREDITS → overlay card (§7.3)
 EXPEDITION (the lobby, §5)          │ QUIT → confirm → desktop
  │ SET SAIL (host) / auto (client)  │
  ▼                                  │
 THE RUN (GAMELOOP.md)               │
  │ Esc/Start                        │
  ├── PAUSE (§6.1, overlay, sim never stops)
  │     ├ RESUME · INVITE · SETTINGS
  │     └ ABANDON RUN → confirm → summary
  │ run ends: extracted / wiped / consumed (GAMELOOP §1)
  ▼
 RUN SUMMARY (§6.2, the ceremony)
  ├ ONE MORE RUN (host) → EXPEDITION (party intact)
  └ BACK TO TITLE
```

Navigation invariants, everywhere, no exceptions:

- **One stack.** Screens live on a single navigation stack owned by one `MenuStack` autoload
  (MENU-2). Push/pop only; no screen ever opens beside another. This absorbs and replaces the
  shipped `blocks_gameplay_input` + "refuse to stack" convention (D-032) with an actual structure.
- **Esc / gamepad B always means "back one level."** In-run, at stack bottom, Esc opens PAUSE. In
  the front end, at stack bottom (TITLE), Esc does nothing. No raw-keycode panel toggles in shipped
  builds — F1/M become dev-only shortcuts behind the debug flag (§10).
- **Focus is never lost.** Every push remembers the focused control; every pop restores it. Every
  screen names its default-focus control in its spec below.

---

## 3 · Design language

The visual system every screen shares. Built once as MENU-1, consumed everywhere.

### 3.1 Palette

The shipped eight-file copy-pasted constants are the right *family* (bog greens, lantern amber) —
promoted to named tokens in one place (`ui/theme/mire_theme.gd`), extended with the two colours the
design actually needs (Mire purple for corruption/danger, moss green for success/owned):

| Token | Value (start point) | Used for |
|---|---|---|
| `SHADE` | `0.018 0.035 0.028 @ 0.78` | full-screen dim behind overlays |
| `PANEL` | `0.055 0.086 0.070 @ 0.97` | panel fills |
| `FIELD` | `0.085 0.125 0.102 @ 0.98` | buttons, inputs, cards |
| `BORDER` | `0.345 0.475 0.390` | resting borders, separators |
| `TEXT` | `0.91 0.94 0.89` | primary text |
| `MUTED` | `0.60 0.69 0.62` | secondary text, captions, hints |
| `AMBER` | `0.894 0.704 0.286` | focus ring, primary CTA, the *one* highlight colour |
| `MIRE` | `0.42 0.26 0.52` (new) | corruption, danger, ABANDON/destructive accents |
| `MOSS` | `0.56 0.80 0.60` (existing `COLOUR_OWNED`) | success, owned, banked |
| `ERROR` | `0.96 0.47 0.39` | failures in status lines |

Rules: AMBER is scarce — focus ring, one primary CTA per screen, headline numbers. State is never
colour-only (§9). Text on PANEL/FIELD must hold ≥ 4.5:1 contrast (all tokens above already do).

### 3.2 Type scale

Shipped menus use 10–13px body text — too small for Steam Deck (1280×800 on a 7" panel). New scale,
at 1080p reference, all sizes scaled by the UI-scale setting (§7.1):

| Role | Size | Notes |
|---|---|---|
| Display | 64 | the Cycle number on the summary; the title logotype is an image, not type |
| Headline | 32 | screen titles |
| Title | 20 | section heads, card titles, primary buttons |
| Body | 16 | everything default |
| Caption | 13 | hints, metadata — **floor**; nothing smaller ships |

One font family, chunky and rounded (matches flat-shaded low-poly; pick a licensed/OFL font in
MENU-1 — candidates with the right weight range and a free licence, judged by eye: Sequoyah's call
on the shortlist, since typeface choice is genuine taste). Numerals must be tabular for the summary
count-ups.

### 3.3 Space, shape, components

- **8px grid** (multiples of 8 for margins/gaps; 4 allowed inside compact rows).
- Corner radius 6 on fields/buttons, 10 on panels/cards — soft, not bubbly.
- Minimum interactive target **44×44px** at 100% scale.
- Component kit (MENU-1 builds these as functions/classes in `ui/theme/`, replacing the per-file
  `_button()`/`_panel_style()` copies): primary button (AMBER border + fill tint), standard button,
  destructive button (MIRE accents), list row, card, tab bar, slider (+ the F-215 focus-ring
  wrapper), toggle, text field, dropdown, modal (confirm dialogs), toast (transient status),
  tooltip, keycap hint (the `[E]`-style glyph for input prompts).
- Focus ring: the shipped F-209 recipe is right — 2px AMBER outline stylebox — kept as the kit's
  single implementation.

### 3.4 Motion

- Standard transitions 150ms ease-out (panel fades/slides ≤ 16px travel). Scene-level fades 300ms.
  Summary count-ups ≤ 1.2s and skippable with any press.
- The **reduce-motion setting (shipped) kills all of it** — instant cuts, final values shown
  immediately. Honouring it is an acceptance criterion on every MENU task.
- Nothing in any menu is time-critical; nothing auto-advances (the 60s extraction group-confirm is
  gameplay, not menu).

### 3.5 Sound

Every interaction has a voice (hooks in MENU-9, assets under 7.1/7.2):

| Event | Sound direction |
|---|---|
| focus move | soft wet tick (bog bubble) |
| confirm | low wooden thunk |
| back/cancel | reversed tick |
| error | flat squelch — comedic, not alarming |
| purchase / bank | coin-pour + moss chime |
| SET SAIL | rope creak + gull |
| pause open | world audio ducks −12dB with 200ms low-pass ramp |

Menu music: its own track (7.2), starts on TITLE, ducks (not stops) into EXPEDITION, crossfades out
over the run start.

---

## 4 · The title screen

**The backdrop is the pitch.** A live 3D island — generated by our worldgen, small bound — seen
from a drifting boat-height camera offshore: warm low sun, drifting ground fog, and the Mire's
purple-black stain visibly creeping at one shoreline (a slow scripted corruption feed into the same
Mire visuals the run uses — 4.10's materials, reused). Gulls, bubbles, occasional distant silhouette
of something big walking the treeline. Seed = a daily constant (date-derived) so friends see the
same "today's island" — a tiny shared-world touch that costs one line.

The logotype **MIRE** sits half-sunk: the bottom of the letterforms swallowed by rendered bog,
slow bubbles around them. (Logo asset: A-task in `ASSET_TRACKER.md`; until it exists, typeset
placeholder.)

```
 ┌────────────────────────────────────────────────────────────┐
 │   (live island, fog, creeping Mire, warm dawn light)       │
 │                                                            │
 │      M I R E   ← logotype, half-sunk, bubbling             │
 │                                                            │
 │   ▸ PLAY                        ┌──────────────────────┐   │
 │     UNLOCKS                     │ LAST EXPEDITION      │   │
 │     SETTINGS                    │ Cycle 7 — the bog    │   │
 │     QUIT                        │ ate well. Banked 84. │   │
 │                                 └──────────────────────┘   │
 │  v0.x · Sequoyah's Steam name          credits · salvage ⌂ │
 └────────────────────────────────────────────────────────────┘
```

- **Menu list** lower-left, Title size, vertical, focus wraps. Default focus: PLAY. No icons —
  words in this font on this backdrop are the look.
- **Last-expedition card** lower-right (hidden on first ever boot): headline Cycle number, cause
  line in tone ("swallowed", "sailed home", "the bog ate well"), salvage banked. Data: the shipped
  local persistence (6.6's versioned save) — needs the last-run record added if absent (MENU-7).
- **Footer** Caption size: version string, Steam persona (SteamLobby), salvage balance, CREDITS as
  a text link.
- **QUIT** → modal: "Quit? The bog will keep." [STAY] [QUIT]. Default focus STAY.
- A Steam invite accepted while anywhere in the front end skips straight to EXPEDITION as a joining
  client (SteamLobby's `invite_accepted`, kept).
- Attract idle (nice-to-have, MENU-3 stretch): 90s of no input → camera drifts wider; any input
  returns. No demo reel, no timeout to anything.

**Boot flow:** the front end becomes the project main scene. `-- host` / `-- client` / check
harnesses bypass it straight into the world scene exactly as today (they run `--script` or pass
launch flags the frontend honours first-thing in `_ready()`), so every existing headless check and
two-process test keeps working unchanged. That bypass is a hard acceptance criterion of MENU-3.

---

## 5 · EXPEDITION — the lobby, the heart of the menu

One screen for solo and co-op; solo is just an empty dock. Replaces the shipped seed-panel +
lobby-panel split (whose "seed staged — HOST in MULTIPLAYER to use it" handshake is exactly the
friction D5 forbids). Fantasy: your party stands on a dock at dawn deciding where to sail.

```
 ┌────────────────────────────────────────────────────────────┐
 │  ◄ back                EXPEDITION                          │
 │                                                            │
 │  THE PARTY                        THE ISLAND               │
 │  ┌──────────────────────────┐    ┌─────────────────────┐   │
 │  │ ⛵ Sequoyah   HOST  ready │    │  (island silhouette │   │
 │  │ ⛵ wren             ready │    │   minimap render)   │   │
 │  │ ⛵ moss12       joining…  │    │                     │   │
 │  │ ˔ empty — INVITE          │    │ seed  [ 7741932  ]  │   │
 │  │ ˔ empty                   │    │ [REROLL] [PASTE]    │   │
 │  │ ˔ empty                   │    │ "or type a word"    │   │
 │  └──────────────────────────┘    └─────────────────────┘   │
 │  [INVITE FRIENDS]  [JOIN CODE: 90210 ⧉]                    │
 │                                                            │
 │                 ▸ SET SAIL                                 │
 │  "everyone aboard? the island won't wait"                  │
 └────────────────────────────────────────────────────────────┘
```

**The party (left).** Six slots (player cap per Q5). Each row: colour chip (the one allowed
customization — click/accept cycles a palette of 8; replicated via lobby member metadata), persona
name, HOST/YOU tags, state (ready / joining… / lost connection). Empty slots are the invite
affordance — focusing one and pressing accept opens the Steam invite overlay. Data: SteamLobby
members + NetSession state, both shipped.

**The island (right).** Seed field (text or number, the shipped hash trick kept verbatim), REROLL,
PASTE. Above it a **silhouette minimap** of the actual island the seed produces — worldgen's shape
mask rendered to a small texture (the audit PNGs under `assets/audit/terrain/` prove this render
path exists; MENU-4 productionizes it). The map redraws ~300ms debounced after seed edits. Client
view: seed and map are read-only, host's choice replicates via lobby metadata ("the host picks the
island; you're cargo").

**Join code row.** The Steam lobby ID as a copyable code with one COPY button (shipped flow, kept)
— it's the LAN-party-over-Discord path and it stays first-class. A JOIN field appears here when not
in a lobby (paste → join), replacing the separate join screen entirely.

**SET SAIL.** The screen's one AMBER primary. Host-only enabled (clients see "waiting for the
host — stretch your legs"); pressing it starts the session through the existing host paths
(SteamLobby host / NetSession open / seed draw — all shipped) with a 3-2-1 creak-of-ropes
transition into landfall. No ready-check gate below 2 players; with 2+, players toggle ready via
accept on their own row, and SET SAIL enables when all present are ready (host can force-sail after
a 10s "leaving without them" grace — flaky friends must not hold the dock hostage, D5).

**Drop-in.** If a friend's session is already mid-run, the invite path lands here with the party
list live and SET SAIL replaced by **JUMP IN** (the shipped mid-run join). The island card shows
the run's current Cycle: "Cycle 4 and sinking — hurry."

**Errors.** All Steam/connection failures land as plain-speech status under the party list, ERROR
colour, with the retry affordance the shipped NetSession retry signals already drive. "Steam isn't
running" gets its own line and a disabled-not-hidden INVITE.

Network authority: this whole screen is client-local UI over SteamLobby/NetTransport/NetSession
requests — the free last row of ARCHITECTURE §2.2's table, same as everything shipped. Ready flags
and colour chips ride Steam lobby member metadata (SteamLobby owns; add two keys, MENU-4). Nothing
new is trusted.

---

## 6 · In-run and after

### 6.1 Pause (Esc / Start)

An overlay, never a pause: the sim runs, co-op or solo — one rule, no divergent path (revisit
solo-pause only if playtests demand it, §12). World blurs slightly and audio ducks (§3.5); the
vitals HUD stays visible under it — you can be eaten while in this menu and you deserve it.

```
   PAUSED — the Mire isn't.
   ▸ RESUME
     INVITE FRIENDS
     SETTINGS
     ABANDON RUN
     QUIT TO TITLE
```

- RESUME (default focus) and Esc/B both close.
- INVITE = the same overlay call as the dock (drop-in mid-run is a pillar, so it's one press from
  pause, not buried).
- ABANDON RUN → destructive modal, consequences in numbers, live from SalvageService:
  *"Swim home? You'll bank 41 of the 118 Salvage you're carrying. The others sail on without
  you."* [KEEP FIGHTING] [SWIM HOME]. Default focus KEEP FIGHTING. Solo abandon routes through the
  normal wipe path (fraction banked) then the summary.
- QUIT TO TITLE = leave session (client) / end run for all with the same modal (host). QUIT TO
  DESKTOP only lives on the title screen — one place to fully exit, fewer misclicks.
- Replaces `player_controller.gd`'s "temporary mouse-release toggle" (its own comment already
  promises this: "Replaced by the pause menu in M7").

### 6.2 Run summary — the ceremony (task 6.8 grown up)

One shared screen for all three endings (extracted / wiped / consumed), replacing the two
duplicated terminal overlays inside `extraction_hud.gd` and `defeat_hud.gd` (their own headers
already ask for the factor-out). This is the scoreboard the "one more Cycle" bet needs (GAMELOOP
§1) and the screen most likely to be screenshotted — it gets the polish budget.

```
        C Y C L E   9          ← Display size, counts up, tabular numerals
     "sailed home heavy"       ← cause line, per-ending copy pool
   ──────────────────────────
   modifiers drawn:  [Long Night] [Bloom] [The Hunt] …   ← chips, in draw order
   Sequoyah   142 kills · 96 gathered · 3 revives · died twice
   wren        88 kills · 210 gathered · 5 revives · never died  ★ favourite
   ──────────────────────────
   SALVAGE  +118  ▓▓▓▓▓▓░░  → 84 banked (extraction) / 29 of 118 (wipe)
   "next on the bench: FUNGAL CHARM — 34 more"
   ▸ ONE MORE RUN            BACK TO TITLE
```

- Headline number counts up (skippable, reduce-motion honours instantly).
- Cause lines are a small authored pool per ending, silly and warm: extracted *"sailed home
  heavy"*; wiped *"the bog ate well tonight"*; consumed *"there was no more island"*.
- **Per-player rows need data that doesn't exist yet**: a host-authoritative `RunStatsService`
  (kills, gathered, revives, deaths per peer; tallied from existing EventBus events, replicated
  once at run end). That is MENU-7's service half and the one genuinely new system in this doc —
  its ARCHITECTURE §2.2 row: host-authoritative tally, replicate-on-run-end, clients render only.
- Salvage bar fills toward the next affordable unlock and *names it* — the bench teaser is what
  converts a loss into "one more run".
- ONE MORE RUN: host-only enabled (the shipped F-243 host-restart path, kept — including its
  disabled-with-reason client state), but now returns everyone to EXPEDITION with the party intact
  rather than instantly restarting — the dock is where re-rolling the island and re-readying lives.
  BACK TO TITLE leaves the session (with the host-ends-it modal for hosts).

---

## 7 · The support screens

### 7.1 Settings

Same `SettingsService` backend (shipped, keeps owning all state, InputMap, persistence); the front
grows tabs and the missing settings. Tab bar: **GAME · DISPLAY · AUDIO · CONTROLS · GAMEPAD ·
ACCESSIBILITY**. LB/RB / Q/E switch tabs; within a tab one focus column, label left, control right;
footer: [RESET TAB TO DEFAULTS].

| Tab | Settings (● = shipped, ○ = new) |
|---|---|
| GAME | ○ tutorial hints on/off · ○ damage numbers · ○ streamer mode (hide join codes) |
| DISPLAY | ○ window mode · ○ resolution · ○ vsync · ○ fps cap · ● graphics quality preset · ● FOV |
| AUDIO | ● master/music/sfx · ○ ui volume · ○ mute-on-unfocus |
| CONTROLS | ● mouse sensitivity · ● invert Y · ● full keybind table (capture flow shipped) |
| GAMEPAD | ● gamepad sensitivity · ● gamepad rebind (shipped) · ○ vibration on/off |
| ACCESSIBILITY | ● reduce motion · ○ UI scale 100–150% · ○ screen-shake intensity · ○ colourblind-safe accents check (§9) · ○ hold-to-press alternatives toggle |

New settings are each a small `SettingsService` addition; the display tab wires
`DisplayServer`/`GraphicsQuality` (shipped autoload). Settings opens as a push from TITLE or PAUSE
— same screen, same stack.

### 7.2 UNLOCKS — the Salvage Bench

The existing flat unlock list reframed as a workbench: category shelves (**POWERUPS · MODIFIERS ·
GEAR · POIS · COSMETICS** — the 6.9 unlock table's own categories), cards per item with silly
flavour text (authoring pass, content not code), costs, and states: affordable (AMBER border) /
owned (MOSS + "on the bench") / can't-afford (muted, cost shown in ERROR only after an attempted
buy). Balance always visible top-right. Purchase = confirm modal with the flavour line. "NEW" badge
on anything added to the pool since last visit (one persisted timestamp). Backend: shipped
`UnlockService`/`SalvageService` untouched.

### 7.3 Credits

A pushed card, Body type, scrolls with stick/wheel, Esc backs out. Names, asset/licence credits
(CC0 packs per `reference-art` policy), "made with Godot". One joke at the bottom. Zero engineering
beyond the kit.

---

## 8 · Copy — the voice

Rules, then examples. The menu speaks like a friend who has been on the island before: short, warm,
dumb, never lore, never corporate.

- Buttons: verbs, ≤ 3 words, no title-case shouting except single-word CTAs.
- Errors: what happened + what to do, one sentence each, joke optional but never instead of the fix.
- Numbers are sacred: every destructive confirm states the cost in real numbers, live.
- Never "session", "instance", "invalid input" — say "game", "run", "that's not a seed, but we
  hashed it anyway" (the hash trick genuinely accepts anything, so the joke is also true).

| Moment | Copy |
|---|---|
| host force-sails | "left the slow ones on the dock" |
| Steam missing | "Steam isn't running — start it, then we sail." |
| join failed after retries | "couldn't reach that lobby. Wrong code, or it sank." |
| abandon confirm | "Swim home? You'll bank 41 of 118 Salvage." |
| quit title confirm | "Quit? The bog will keep." |
| settings reset | "back to how the swamp intended" |

---

## 9 · Input & accessibility — the contract every screen signs

- Full mouse/keyboard **and** gamepad parity on every screen; Steam Deck is a first-class layout
  target (1280×800: verify every screen at that size in the render check, MENU-10).
- Focus: F-209's recipe (neighbour chains + visible AMBER ring) via the kit, plus stack focus
  memory (§2). Default focus named per screen above. No focus traps: modals capture, restore on
  close.
- Esc/B = back, everywhere (§2). Start = pause. Accept = `ui_accept` (gamepad bindings shipped
  project-wide since F-209/D-134).
- Text floor Caption/13px @ 1080p; UI scale to 150%; hit targets ≥ 44px.
- State never by colour alone: ready = check glyph + colour; owned = label + colour; affordable =
  border + enabled state.
- Reduce motion honoured by every animation (§3.4). Screen-shake and vibration have sliders
  (§7.1). No flashing above 3Hz anywhere in the front end.
- Screen-reader support: **cut for launch** (consistent with the cut list's scope discipline);
  noted as post-launch.

Network authority summary (ARCHITECTURE §2.2): every menu screen is the client-local UI row. The
only two touchpoints with authority: lobby member metadata (SteamLobby owns, two new keys) and
`RunStatsService` (new, host-authoritative, MENU-7). Neither adds a trusted client path; new RPCs
in MENU-7 bump `PROTOCOL_VERSION` per the standing rule.

---

## 10 · Disposition of everything that exists

| File | Disposition |
|---|---|
| `ui/menu/main_menu.gd` (F1 shell) | **Replace** with TITLE (§4). Seed logic moves to EXPEDITION; `set_pending_seed` staging survives underneath. F1 becomes a debug-flag dev shortcut, then dies. |
| `ui/lobby/lobby_menu.gd` (M panel) | **Replace** with EXPEDITION (§5). Every SteamLobby/NetSession request path and signal wiring inside it is reused as-is — the backend was always right; the shell around it goes. |
| `ui/menu/settings_menu.gd` | **Rework**: keep all controls + both rebind capture flows; re-house into tabs on the kit (§7.1). |
| `ui/menu/unlock_menu.gd` | **Rework** into the Salvage Bench (§7.2); rows → cards, backend untouched. |
| `ui/hud/extraction_hud.gd` / `defeat_hud.gd` summary halves | **Replace** with the shared summary (§6.2). Their prompt/bleed-out HUD halves are gameplay HUD, untouched. F-243's host-only restart and F-275's focus-trap fix carry over as requirements. |
| `ui/menu/focus_ring_slider.gd`, F-209 recipe, `blocks_gameplay_input` | **Absorb** into the kit + MenuStack (MENU-1/2). The group stays as the signal `player_controller.gd` reads; MenuStack manages membership. |
| Palette constants ×8 files | **Promote** to `ui/theme/mire_theme.gd` tokens (§3.1), delete the copies as each screen migrates. |
| `tools/main_menu_check.gd`, `lobby_menu_check.gd`, `menu_focus_check.gd` | **Rework** per replacing task — same drive-the-public-API pattern, pointed at the new screens. Checks are rewritten in the same task that replaces their screen, never later. |
| `project.godot` main scene (`levels/hollowmere.tscn`) | **Change** to the frontend scene (MENU-3) via the normal atomic mechanism; `-- host`/`-- client`/`--script` bypass is the same task's acceptance gate. |

Code-built UI (no `.tscn`) stays the law — it is why menus merge cleanly across agents (D-031
never bites). The frontend 3D backdrop is likewise assembled in script.

---

## 11 · Task breakdown — ordered, claimable, checked

Anchors: 7.4 (shell/theme/transitions), 7.5 (settings), 7.6 (gamepad/Deck), 6.8 (summary), 7.2
(music), 7.1 (SFX). Sizes in sessions. Each task rewrites the checks for what it replaces.

| Id | Task | Builds on | Size | Acceptance (headless via `agent godot`) |
|---|---|---|---|---|
| MENU-1 | Theme + component kit: `ui/theme/mire_theme.gd` tokens (§3.1–3.3), component builders, focus recipe absorbed | — | 2 | `tools/menu_kit_check.gd`: every component instantiates, focus ring present, contrast assertions on token pairs |
| MENU-2 | `MenuStack` autoload: push/pop, focus memory, Esc/B contract, `blocks_gameplay_input` membership, modal + toast plumbing | MENU-1 | 2 | `tools/menu_stack_check.gd`: push/pop/focus-restore, one-blocking invariant, modal capture |
| MENU-3 | Frontend boot scene: backdrop island + camera drift + Mire creep, title screen, quit modal, boot-bypass flags | MENU-1/2 | 3 | rework `main_menu_check.gd` → `tools/title_check.gd`; **every existing check and `-- host`/`-- client` two-process test still passes unchanged**; `--windowed` render PNG at 1280×800 + 1080p |
| MENU-4 | EXPEDITION: party dock, ready/colour via lobby metadata, seed + minimap render, join code, SET SAIL / JUMP IN, force-sail grace | MENU-3 | 4 | rework `lobby_menu_check.gd` → `tools/expedition_check.gd`; two-process host/client sail + drop-in join |
| MENU-5 | Pause menu + abandon flow; retire the controller's mouse-release toggle | MENU-2 | 2 | `tools/pause_menu_check.gd`: sim continues while open, abandon banks the fraction, client vs host quit paths |
| MENU-6 | Settings retab + new settings (display/game/accessibility additions to `SettingsService`) | MENU-1 | 3 | extend shipped settings check: tab focus chains, every new setting persists round-trip |
| MENU-7 | `RunStatsService` (host-tally, replicate at run end, `PROTOCOL_VERSION` bump) + shared run summary screen replacing both HUD summary halves + last-expedition record for TITLE | MENU-2 | 4 | `tools/run_summary_check.gd`: two-process — stats match host truth on both peers for all three endings; F-275 focus-trap regression |
| MENU-8 | Salvage Bench rework + flavour-text authoring pass + NEW badges | MENU-1 | 2 | rework unlock check: category shelves, buy flow, badge persistence |
| MENU-9 | Menu audio hooks (§3.5) + music states (asset tasks live in 7.1/7.2) | MENU-3 | 1 | hooks fire in check with stub streams; duck/ramp values asserted |
| MENU-10 | Deck/gamepad + accessibility audit: every screen at 1280×800 and 150% scale, full pad-only traversal, reduce-motion sweep | all | 2 | `tools/menu_a11y_check.gd`: scripted pad-only walk of every screen; render PNGs both sizes for eye review |

Sequencing: MENU-1 → 2 → 3 are strictly ordered; 4–9 parallelize after 3 (5/6/8 only need 1–2);
10 last. Total ≈ 25 sessions, which is 7.4+7.5+7.6+6.8's combined roadmap budget spent as one
coherent design instead of four polish passes.

**What only Sequoyah can judge** (hand-off points, per D-039 kept to genuine taste): the font
shortlist (§3.2), the logotype, the backdrop's light/fog by eye, cause-line and flavour copy pools
worth keeping, and whether SET SAIL *feels* like leaving a dock. Everything else here is agent
work.

---

## 12 · Open questions, with defaults that don't block

- **Solo pause?** Default: no — one rule, sim never stops (§6.1). Revisit only if solo playtests
  complain; the fix is host-side `Engine.time_scale`, isolated behind PAUSE, ~1 session.
- **Ready-check worth it at 2 players?** Default: no gate below 2 present + host force-sail grace.
  Watch the first co-op playtests for dock-idling.
- **Daily title-island seed** — cosmetic; if worldgen determinism across versions makes "same for
  everyone" untrue, silently fall back to random. Never a correctness surface.
- **Player count cap (Q5)** decides dock slots: built as 6, collapses to 4 by constant.
- **Does EXPEDITION-after-summary beat instant restart?** Default: yes (re-roll + re-ready has a
  home). If playtests show groups always instant-restart, ONE MORE RUN can skip the dock when the
  party is unchanged — small change, noted here so it isn't re-litigated.
