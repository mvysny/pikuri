# Releasing 16 gems without pasting 16 OTP codes

Status: **direction chosen 2026-08-25, not built.** Filed after a
release run where every one of the sixteen `gem push` calls in
`rake release` stopped to ask for an OTP code. Both questions the
design hung on are now settled (codes are reusable; push order is not
enforced), so the shape below is decided — see *The chosen strategy*.
What remains is writing it.

## The problem

`GEMS` in the top-level `Rakefile` holds **sixteen** gem directories,
and the release task's fan-out ends in one `gem push` per directory.
With the rubygems.org account at MFA level `ui_and_api`, *every* push
is challenged, so a release is sixteen interactive OTP prompts spread
over several minutes. Three costs, in increasing order of annoyance:

1. **Tedium.** Sixteen pastes of a six-digit code.
2. **Expiry churn.** A code covers 3–5 pushes (see below), then the
   window rolls and you go back to the authenticator — several times
   per release, each time at a moment you can't predict.
3. **A bad failure mode.** A push that fails (expired code, fat
   finger, network) aborts the whole task partway through the
   fan-out — with the earlier gems already public and unyankable.
   `CONTRIBUTING.md` §Releasing's documented recovery is *"bump to
   the next patch version and release that"*, which burns a version
   number over a mistyped digit. This is the part that actually
   hurts, and (see *The orthogonal fix* below) it is fixable
   independently of the auth question.

## Settled: a code is **not** single-use

Author's direct experience across past releases: **one OTP code
covers 3–5 consecutive gem pushes** — as many as fit before its ~30 s
window rolls; then the next code covers the next 3–5. rubygems.org
does not burn a code on first use.

**Do not read 3–5 as a cost-per-push.** That figure was measured under
today's procedure, where each iteration is *prompt → human pastes →
build the next gem → upload*. It is dominated by paste latency and
build time; the upload itself is **sub-half-second**. 3–5 is therefore
a lower bound on how many pushes a window can hold, not a measure of
what a push costs — a distinction that turns out to decide the fan-out
width (see *Choosing the width*).

This is the pivot the whole file turns on, so it is worth stating what
it kills and what it unlocks:

- **Killed:** any design that pays for freshness. There is no need to
  wait out a window between pushes, so the "one fresh code per push,
  ~8 minutes of sleeping" worry is void. Sixteen pushes cost sixteen
  pushes' worth of network time — call it four windows, ~2 minutes.
- **Unlocked:** *one code can authorize the entire release* if the
  pushes fit in one window. That makes concurrency (below) not a
  micro-optimization but the difference between one prompt and four.

## Settled: push order is **not** enforced

rubygems.org does not validate that a gem's dependencies already
exist — it is explicitly built for the opposite. Three findings from
the rubygems.org source:

- **`Pusher` never looks at dependencies.** Its validation pipeline
  covers package format, gemspec validity, authorization, API-key
  scope, MFA, cert chains, platform/`full_name` consistency and
  sigstore attestations. Dependency availability is not among them.
- **`Dependency` has an `unresolved_name` column** for exactly this
  case: `self.unresolved_name = gem_dependency.name unless rubygem`.
  A dependency naming a gem the database has never seen is stored as
  a dangling name rather than refused.
- **The dangling name is healed later.** `Rubygem` carries
  `after_create :update_unresolved`, which walks
  `Dependency.where(unresolved_name: name)` and calls
  `dependency.update_resolved(self)`. Publishing a gem retroactively
  resolves every dependency that had been waiting for the name.

So the `Rakefile`'s topological `GEMS` order is a **precaution nothing
enforces**. It is not wrong to keep the list in that order — it
documents the real dependency graph and costs nothing — but it must
stop being a constraint on *scheduling*.

One caveat, so it is not mistaken for a regression: this settles
**push acceptance**, not **installability**. Right after any release,
index and CDN propagation means `bundle install` may briefly fail to
resolve the fresh versions. Pushing the metagem last never protected
against that either (indexing is asynchronous regardless), so
parallelism takes nothing away.

## The chosen strategy

Build locally, then fan out in parallel inside a **single fresh OTP
window**, and make every step idempotent so a blown window is retried
rather than repaired mid-flight.

1. **Build all sixteen first, push nothing.** A gemspec error in gem
   14 must be found before gem 1 is public. Building is offline and
   cheap; make it a phase with its own failure exit.
2. **Pre-flight the whole set against rubygems.org**, before the
   first push:
   - *Version already published?* Report it and skip that gem. On a
     resumed run this is the expected case and is what makes retry
     safe.
   - *Name exists but we are not an owner?* This is the squatting
     signal worth alarming on — and it is a **different check from
     the one above**. An already-published version under a name you
     own is benign (a resumed run); a name in `GEMS` owned by someone
     else is not, and `gem push` would only surface it as a 403 deep
     in the fan-out. Checking ownership up front turns that into a
     pre-flight refusal.
3. **Take the code with enough window left to spend it.** TOTP
   windows are aligned to the Unix epoch, so the task can compute
   `30 - (Time.now.to_i % 30)` — how much of the current code's life
   remains. Ask for a code, measure on arrival, and if too little is
   left for the budget, sleep to the boundary and ask once more.
   **The task enforces the timing — never the human**, who cannot be
   asked to eyeball an authenticator against a stopwatch. The code
   arrives on **stdin** — the ordering this depends on is the whole
   subject of *Supplying the code* below.
4. **Push everything inside that window, budget ≤20 s.** One code
   covers the whole release, and ordering is free to ignore per the
   finding above. With builds already done, sixteen uploads cost
   under 8 s even serially, so a modest 4-wide fan-out leaves the
   budget mostly headroom — see *Choosing the width*.
5. **No mid-flight re-prompt. No self-healing.** If the window is
   blown, some pushes fail; the task reports exactly which gems landed
   and exits non-zero. **The recovery is re-running it** — which step
   2 already made safe and cheap. This is the whole payoff of the
   idempotency work: the retry story *replaces* the re-prompt story,
   and with it goes the parent-owned OTP state machine, the
   output-scraping needed to tell an MFA rejection from a real
   failure, and the risk of children fighting over a TTY.
6. **Idempotent tail.** A re-run must sail through a bump that is
   already applied, a commit that already exists and a tag that
   already exists, rather than raising. With that,
   `CONTRIBUTING.md`'s "bump to the next patch version and release
   that" recovery advice gets deleted, not followed.

### Supplying the code: stdin, and only stdin

Handing the code in **upfront** as `GEM_HOST_OTP_CODE=… rake release`
looks like the tidy non-interactive option and quietly breaks step 3.
The task cannot wait for a fresh window, because the code it was
already given expires at that boundary; and it cannot ask for a
replacement, because the whole point of the env var was that nobody is
watching. It can only spend what it holds, however little life is left
— which is precisely the flaky, silent short-window failure step 3
exists to prevent.

The escape is to notice that **the ordering is the bug, not the
waiting**. Prompt for the code *after* the wait rather than before,
and the cycle does not form.

**The interactive path (default).** Do every slow thing first — build
all sixteen, run the pre-flight — then ask for the code. The human's
attention is needed exactly once, at the end, for one paste, and the
task can freely re-ask because stdin is right there.

Two refinements worth building in:

- **Don't sleep pre-emptively.** Ask immediately once the pre-flight
  is done; measure the remaining window when the paste *arrives*. With
  an ~8 s budget in a 30 s window, roughly three runs in four already
  have enough room and pay no wait at all. Only the unlucky quarter
  sleeps — and never more than ~8 s.
- **Say what is happening during the sleep.** "Only 4 s of this code's
  window left — waiting 4 s for the next one" is the difference
  between a deliberate pause and a hung release.

**The env-var path is dropped**, not kept as an opt-in. Beyond the
cycle above, it loses on ordering even when it works: a code supplied
upfront starts dying immediately, so the task must either build *while
the clock runs* — spending window on work that had no need to be inside
it — or refuse and make you re-run. The stdin path inverts exactly
that. The machine does its slow work first and only then asks, which
means **the human prepares for the window while the build is already
finished**: grab the code, paste it, and every one of the next thirty
seconds is available for uploads. There is no arrangement of the
env-var path that recovers this, because the code always arrives before
the work instead of after it.

That leaves nothing for it to be good at. Its only remaining claim is
unattended operation, and it is a poor answer there too — a code pasted
into a shell needs the same human as a prompt does. Genuinely
unattended releases want option 3 (`rotp`, minting at the boundary) or
option 5 (trusted publishing, no OTP at all); the env var satisfies
neither while adding a second code path, its own refuse-with-wait-time
failure mode, and a config knob the project's own "no knobs not needed
for the next concrete step" rule would reject. **One supply path:
stdin.**

**Do not confuse the supply path with the plumbing.** The parent still
hands the code to each `gem push` child through `GEM_HOST_OTP_CODE` —
that is the documented way to pass it and stays. What is dropped is
`GEM_HOST_OTP_CODE` as a *user-facing input to the release task*. The
env var is internal wiring, not an interface, and the distinction is
worth keeping straight so the knob does not get re-added by someone
noticing the task sets a variable it refuses to read.

### Choosing the width

**The budget is not tight — it was never close.** Once the two slow
steps are lifted out of the window, what remains is the wire time of
sixteen small uploads at under half a second each: **under 8 seconds
even fully serial.** Step 1 is doing double duty here — moving the
builds ahead of the push phase is not only fail-fast, it is what keeps
the window clear.

So the width is chosen for **margin, not throughput**:

- **4-wide is ample** — roughly 2 s of wire time, leaving the 20 s
  budget almost entirely as headroom.
- Going 8- or 16-wide buys nothing. The earlier draft of this note
  argued for them from a 6–10 s per-push estimate derived by
  misreading 3–5-per-window as a cost-per-push; corrected above.
- The parallelism now exists to absorb a **straggler** — one slow
  upload, a TCP retry, a server hiccup — rather than to fit the
  window. Four-wide means a single 5 s outlier costs 5 s, not 5 s
  added to a critical path that was already near the limit.

**A useful consequence: serial still works.** With the whole push
phase under 8 s, one OTP code covers the release even with no
concurrency at all. That makes parallelism a *robustness* choice, not
a *load-bearing* one — so if fanning out complicates error reporting
or the per-gem landed/skipped/failed summary, dropping to serial is a
legitimate simplification that still delivers the single-prompt goal.
Worth knowing before writing the concurrency.

There is also free headroom worth knowing about but **not** designing
against: rubygems.org accepts a code from the preceding window as well
(standard TOTP drift tolerance), so the real validity is nearer 60 s
than 30 s. Treat that as margin that turns a marginal run into a
successful one, never as budget to spend.

**Where the margin actually gets spent: clock skew.** Step 3 computes
the window boundary from the *release machine's* clock, but the code
is read off the *authenticator's*. If the two disagree by δ, the task
waits for the wrong boundary and hands the pushes a code with `30 − δ`
seconds left rather than 30. This is the one assumption in the design
that fails silently — nothing reports a skewed clock, the release just
gets flakier.

It is tolerated rather than fixed, and comfortably: an ~8 s push phase
in a 30 s window absorbs **up to ~20 s of skew** before the budget is
threatened, and TOTP drift tolerance roughly doubles that. Any machine
running NTP is nowhere near it. Worth knowing as the reason the
generous margin is not over-engineering — it is what buys the right to
compute the boundary locally instead of asking the human to watch the
authenticator.

### What survives from the parallel-execution notes

Most of the earlier implementation caution evaporates with step 5. Two
things remain:

- **Close the children's stdin.** Not to arbitrate a re-prompt any
  more, but so a `gem push` that decides to self-heal cannot silently
  block the run waiting on a prompt nobody is watching. It should fail
  fast instead.
- **Pass the code by environment, never argv** — it should not appear
  in the process table.

Children may otherwise inherit stdout; the parent needs only exit
statuses and a per-gem landed/skipped/failed summary.

## What the tooling actually offers (grounded)

Read out of the installed rubygems, not from memory —
`lib/rubygems/gemcutter_utilities.rb` (rubygems 4.0.19):

- **`GEM_HOST_OTP_CODE` is honoured per-process** (`:62`,
  `otp = options[:otp] || ENV["GEM_HOST_OTP_CODE"]`), and `gem push`
  also takes `--otp CODE`. Combined with reusability, this is the
  whole fix: supply a code once, spend it many times.
- **The account MFA level is a three-way** (`:374`): `ui_only`,
  `ui_and_gem_signin`, `ui_and_api`. Only the third challenges the
  push API. A web-UI setting, not a code change.
- **`gem push` self-heals once, but only within its own process**
  (`:111-116`): on an MFA-unauthorized response it calls `fetch_otp`
  — an interactive prompt — and retries. `fetch_otp` writes to
  `options[:otp]`, which **takes precedence over the env var** and
  **dies with the child process**.
- **WebAuthn is a per-push browser round-trip** (`:261-285`): with a
  security key registered, `gem push` opens a localhost listener and
  sends you to a URL. That is *more* interactive than typing a code.
  Not a way out.
- There is no "MFA session" and no push-many command. Sixteen pushes
  are sixteen authenticated requests, full stop.

### The trap: `GEM_HOST_OTP_CODE=… rake release` does not work

The obvious move — export one code and run the task unchanged — makes
things *worse*, and the reason is the third bullet above. The Rakefile
spawns a **separate `gem push` process per gem**. Each starts from the
same stale env var; each independently discovers it is expired, prompts
you, retries, succeeds, and then **throws the fresh code away** when it
exits. The next gem starts from the stale env var again. So instead of
one prompt per *window* you get one prompt per *gem* from the first
expiry onward — roughly twelve prompts, worse than today's sixteen only
in that it feels like it should have helped.

The naive reading of this is "the code must be owned by the parent"
(option 1 below). The chosen strategy takes the other exit: **it never
lets the code go stale in the first place**, so no process needs to own
OTP state. The trap is recorded because it is the obvious first thing
to try, it looks like it should work, and it silently makes the problem
worse.

## Options considered

Kept as the rationale for the choice above — options 1 and 2 are what
*The chosen strategy* combines; 3–5 are the roads not taken and why.

### 1. The Rakefile owns the OTP (no new dependencies)

Prompt **once** up front, hold the code in the task, set
`GEM_HOST_OTP_CODE` on each child. When a push comes back
MFA-unauthorized, prompt for *one* fresh code, retry that gem, and
**carry the new code forward** to the rest of the fan-out.

- Sixteen prompts → **~4**, exactly matching the manual rhythm today
  but without you having to notice the moment it rolled.
- No new gems, no secret on disk, MFA level untouched. Maybe 20 lines
  in the `Rakefile`.
- Implementation note: needs the child's output captured to tell an
  MFA rejection from a real failure, so `system` becomes a capture,
  and the children must not be handed a TTY to prompt on themselves
  (otherwise the parent's retry logic races the child's).
- This is the obvious floor. Even if a later option supersedes it,
  nothing here is wasted.

### 2. Push concurrently — one code for the whole release

If sixteen pushes are in flight together, they all land inside one
window and **one code authorizes the entire release**. One prompt.

- **Unblocked**: push order is not enforced (see the finding above),
  so the fan-out is free to be parallel. The `Rakefile`'s topological
  `GEMS` order stays as documentation of the real dependency graph;
  it just stops governing scheduling.
- Once the fan-out fits inside one deliberately-fresh window, this
  option **absorbs** option 1 rather than composing with it: there is
  no second prompt to carry forward, so the parent never needs to own
  OTP state at all.

### 3. Generate the OTP locally (`rotp`)

Keep `ui_and_api`. Put the TOTP *seed* in `pass` (GPG-encrypted, one
passphrase prompt), mint a code in the release task, spend it until
rejected, mint another. **Zero prompts, fully unattended** — and with
reusability settled, zero wall-clock penalty. Strictly better than
option 1 on ergonomics, and better than option 4 on security.

- **Cost — factor collapse.** The seed and the API key end up on the
  same machine, so "two factors" is a fiction against a host
  compromise. It is *not* a fiction against credential theft alone:
  the seed sits behind GPG, the key sits in plaintext in
  `~/.gem/credentials`. That gap is the entire argument for this over
  option 4.
- Adds a dev-time `rotp` dependency and a `pass` (or keyring) lookup
  to the release path. Pass the code via env, never argv — it should
  not appear in the process table.

### 4. Drop the account to `ui_and_gem_signin`

Keep MFA on the web UI; stop challenging the API. Zero prompts, zero
code changes, flipped back in the UI whenever you like.

- **Demoted by the reusability finding.** It buys exactly what option
  3 buys — zero prompts, unattended — while weakening authentication,
  and option 3's cost is now a one-time `pass` setup rather than
  minutes of waiting per release. Hard to argue for on the merits.
- If chosen anyway, the caveat is load-bearing: a **scoped** key (push
  only, no yank, no owner-add), scoped to `pikuri-*`, with an
  **expiry date** set at creation, deleted after the release. That is
  the difference between a deliberate trade and negligence.

### 5. Trusted Publishing (OIDC), via a GitHub mirror

The end state that dominates everything above: rubygems.org exchanges
a short-lived CI-issued OIDC token for a push token, so there is **no
long-lived API key and no OTP at all**. Nothing on your laptop to
steal.

- **Cost:** rubygems.org's trusted publishing supports GitHub Actions
  and GitLab CI — not Woodpecker. pikuri lives on Codeberg with
  Woodpecker (`.woodpecker.yml`), so this means a GitHub mirror whose
  only job is to run the release workflow on a tag.
- That is a **values call, not a technical one**: it puts a GitHub
  dependency in the release path of a deliberately Codeberg-hosted
  project. Worth asking whether Woodpecker + rubygems OIDC is on
  anyone's roadmap before building the mirror.
- Also the largest change: sixteen trusted-publisher registrations
  (one per gem, each naming repo + workflow), a release workflow, and
  a rethink of "release from a clean local tree" as the ritual.

## Where the other options stand

- **Option 2 is the chosen strategy**, and it swallowed option 1.
  Starting inside a fresh window means one prompt covers everything,
  so the parent-owned code and its carry-forward retry — option 1's
  entire content — are not needed. Sixteen prompts to one, no secret
  on disk, MFA level untouched, and *less* machinery than option 1
  alone would have required.
- **Option 3 (`rotp`) is not needed.** It was the way to reach zero
  prompts; one prompt per release is close enough that a TOTP seed on
  the release machine is not worth buying it. Revisit only if the
  release ever needs to run unattended.
- **Option 4 (MFA downgrade) is dead.** It weakens authentication to
  buy what option 3 buys, and option 3 already lost on a much smaller
  cost.
- **Option 5 (trusted publishing) stays the real end state**, gated on
  whether a GitHub mirror is acceptable for a Codeberg project. The
  chosen strategy does not conflict with it: an idempotent,
  build-then-fan-out release task is the same task a CI workflow would
  run, minus the OTP handling.

## Also noticed while reading (unrelated, worth fixing)

`CONTRIBUTING.md` §Releasing has **drifted**: it says "Pikuri's seven
gems release in lockstep" and enumerates a seven-gem release order
(`pikuri-core` → `pikuri-skills` → `pikuri-mcp` → `pikuri-workspace` →
`pikuri-code` → `pikuri-assistant` → `pikuri`). The `Rakefile`'s `GEMS`
is the source of truth and now holds sixteen. Either re-sync the prose
or — better, since it will drift again — have it point at `GEMS`
instead of restating the list.

## Open questions

Both load-bearing questions are settled; what is left is small.

- **Confirm the sub-half-second upload with one timing.** The budget
  has enormous margin if it holds, and the whole design leans on it.
  It is an observation, not a measurement — time one push on the next
  release. If it is wildly off, revisit the width; nothing else in the
  design moves.
- **Does the ownership pre-flight need an authenticated call?** The
  squatting check wants "does this name exist and do we own it",
  which may need the owners API rather than a public version lookup —
  and therefore the API key, before the OTP prompt.
- Is Woodpecker on rubygems.org's trusted-publishing roadmap? If it
  lands, option 5 loses its only real cost.

## Graduation

Not a `DECISIONS.md` entry yet — no fork has been taken. When one is:
the choice plus the rejected options belong in `DECISIONS.md`
(`D-release-otp-...`), the resulting procedure in `CONTRIBUTING.md`
§Releasing, and any release-task invariant in the `Rakefile`'s own
comments. Then delete this file.
