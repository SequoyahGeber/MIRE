# Shipping MIRE on Steam

Everything here is process, not code. It's almost entirely **Tier 0** work — perfect for quota-dry days.

---

## 1. The hard scheduling constraints

These are Valve's, not negotiable, and they run in **calendar time regardless of how fast you work**.
Missing them is the most common way indies slip a launch date they announced.

| Step | Duration | Notes |
|---|---|---|
| Steamworks account + tax/banking verification | 2–7 business days | Do this early; identity/tax paperwork can stall |
| **Steam Direct fee: $100 per app** | — | Recouped after $1,000 adjusted gross revenue. Non-refundable otherwise. |
| **Mandatory wait after paying the fee** | **30 days** | You cannot release inside this window, no exceptions |
| Store page review | 3–5 business days | Repeats if you're asked to change things |
| **"Coming Soon" page must be public** | **≥ 2 weeks** before release | Builds wishlists; also a hard gate |
| Build review | 3–5 business days | Technical/compliance check — does it run, is the page accurate. **Not a quality judgement.** |

**Practical read: budget ~6–8 weeks of calendar between "I'm ready" and "it's live."** Start the
paperwork the moment you're confident the game will actually ship (end of M7), not when it's finished.

---

## 2. Don't pay yet — use App ID 480

**App ID 480 (Spacewar)** is Valve's public test app. Anyone with a Steam account can use it for
lobbies, P2P networking, and the overlay, with **no Steamworks account and no $100**.

Develop and playtest with friends on 480 for the entire project. Swap to your real App ID in M8 — a
one-line change if you routed it through `NetTransport` (`ARCHITECTURE.md` §2.3).

> Caveat: 480 is shared by every dev testing worldwide, so its public lobby list is full of strangers'
> junk. Always join by friend-invite or direct lobby ID; never build against a public lobby browser.

---

## 3. Pre-launch checklist

### S1 · Name and identity — do this before anything else
- [ ] Search Steam for the working title; confirm no collision
- [ ] Basic trademark search (USPTO TESS for US)
- [ ] Check domain and social handles if you care
- [ ] **Lock the name.** Changing it after the store page exists costs you wishlists and URL history.

### S2 · Account setup
- [ ] Steamworks partner account
- [ ] Tax interview + banking (allow a week)
- [ ] Pay $100 Steam Direct fee → **30-day clock starts**
- [ ] Real App ID issued

### S3 · Store page assets
- [ ] Capsule art at every required size (main, small, header, library, page background)
- [ ] 5+ screenshots — actual gameplay, not staged menus
- [ ] Trailer: 60–90s, gameplay in the first 5 seconds, no logo intro
- [ ] Short description (one sentence that says what you *do*)
- [ ] Long description with feature bullets and GIFs
- [ ] Tags: Co-op, Roguelike, Survival, Crafting, Multiplayer, First-Person
- [ ] System requirements (measure them, don't guess)
- [ ] Content rating questionnaire

> Capsule art is the single highest-leverage marketing asset you will make. It's the only thing most
> people ever see. If you commission one thing for this project, commission this.

### S4 · Technical integration
- [ ] Real App ID swapped in, all Steam features re-verified
- [x] Achievements/stats/rich presence — code shipped task 8.3: ten achievements (Cycle-depth ones
      included, per this line's own suggestion), seven stats, live "Cycle N" presence text. Pushing
      to the real Steam API is silently inert until the dashboard rows exist — see
      `tools/steam/ACHIEVEMENTS.md` for the exact copy-paste-ready runbook, blocked on S2's App ID
      the same way depots were (task 8.11, D-132's split applied again).
- [ ] Steam Cloud for meta-progression save (small, easy, prevents heartbreak)
- [ ] Depots + build pipeline; scripted `steamcmd` upload. Pipeline built (task 8.4); the
      dashboard runbook + ID-wiring script are ready in `tools/steam/DEPOT_SETUP.md` — blocked on
      S2's real App ID (task 8.11, D-132)
- [ ] **Password-protected beta branch** for friends
- [ ] Test: install from Steam on a clean machine that isn't yours

### S5 · Launch
- [ ] Coming Soon page live → **2-week clock starts**
- [ ] Closed beta with friends on the password branch
- [ ] Fix the crashes they find (there will be crashes)
- [ ] Submit build for review
- [ ] Set release date, price
- [ ] Launch

---

## 4. Free or paid?

Muck is free, which is a large part of why it spread — friends could all grab it instantly.

| | Free | Paid ($5–10) |
|---|---|---|
| Friends can all join instantly | ✅ | ❌ friction, and you'll end up gifting copies |
| Reaches more people | ✅ | ❌ |
| Recoups the $100 | ❌ | ✅ (needs $1,000 gross to recoup the Direct fee) |
| Review-bombing / support burden | higher | lower |
| Can you change your mind later? | free → paid is **not** allowed | paid → free is allowed |

**Recommendation: launch free.** Your stated goal is playing this with your friends. Free removes every
barrier to that, matches Muck's DNA, and a co-op game lives or dies on how easily a group can all get
in. Note the one-way door: you can go paid → free later, but **not free → paid**. If there's any chance
you'd want to charge, launch at a low price and discount aggressively instead.

---

## 5. Steam Playtest — probably not what you want

Steam Playtest is a separate free app attached to your main app, with gated access and friend invites
(inviters must have been friends 30+ days). It's built for gathering feedback at scale without reviews
or wishlist impact.

**For a handful of friends it's overkill** — it still requires the main app, the $100, and the 30-day
wait. A **password-protected beta branch** on your real app is simpler and does the same job. Revisit
Playtest only if you later want a wider public test.

---

## 6. Steam Deck

Aim for **Deck Compatible**, not **Deck Verified**. Verification is a submission-and-review process with
requirements (readable text at 1280×800, full controller support, no external launcher prompts). Nice
to have, real work, and irrelevant to your actual goal. Just make sure it runs and the text is legible.
