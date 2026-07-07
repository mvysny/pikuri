# Bash session-grant confirmer: runtime-populated auto-approval

Status: **deferred brainstorm** — design space mapped, not scheduled.
The static read-only allowlist
({Pikuri::Code::Bash::ReadOnlyAutoConfirmer}) handles fatigue for the
commands it can *prove* read-only; this note is the runtime-populated
companion — "the human vouches for `pytest` this session" — and the
reasons it is harder than it looks. Moved out of
[`os-assistant.md`](os-assistant.md)'s deferred list so the design has
room to breathe.

## Related

- [`os-assistant.md`](os-assistant.md) §"Deferred / not yet built" —
  where this was born; the OS-helper is one of the two agents that would
  use it (the coding agent is the other, and the likelier winner — see
  below).
- [`more-confirmers.md`](more-confirmers.md) — the sibling
  human-in-the-loop confirmer shapes (the author seat, the reason
  channel, the ingest gate). This note is the **fatigue** axis; that
  file is the **authorship / steering** axis. Kept distinct on purpose —
  a confirmer that governs *how often we ask* is a different mechanism
  from one that governs *who authors the payload*.
- {Pikuri::Code::Bash::ReadOnlyAutoConfirmer} — the static allowlist
  this extends; the design below reuses its `Tokenizer` +
  `segment_read_only?` discipline wholesale.
- {Pikuri::Workspace::Confirmer} — records the **rejected**
  `:once/:always` scope knob; the "invariant" section below is why
  session grants are a different animal, not that knob resurrected.

## The problem

Fatigue is a **security** concern, not UX (see
{Pikuri::Code::Bash::ReadOnlyAutoConfirmer}'s "why fatigue is a security
concern"): a user who has clicked "yes" forty times this session has
stopped reading, so the injected forty-first prompt gets rubber-stamped.
The allowlist's whole job is to make prompts **rare and meaningful**.

`ReadOnlyAutoConfirmer` handles fatigue for commands it can *prove*
read-only, and it keeps absorbing more cases (the `journalctl` example
the OS-helper note once used for "session grants" is now stale — it
shipped in the flag denylist). But one residue can **never** join a
static allowlist, by construction: **commands that execute arbitrary
project code** — `pytest`, `cargo build`, `npm test`, `make`, `./run.sh`,
`bundle exec rspec`. None can join `READ_ONLY_BINARIES` (whose curation
rule is "no mutating form in *any* argument"), yet a real coding /
diagnosis loop runs them dozens of times a session and each one prompts.

These are safe **by the human's judgment of this session**, not safe
**by proof**. That is the gap: the allowlist encodes universal proofs; it
has no way to encode "I, the human, vouch for `pytest` in *this* run."
The missing capability is turning a one-off approval into a
session-scoped standing rule.

## The danger

A session grant is a **standing capability that later untrusted content
can ride**. Once "always allow `pytest`" is in place, a *subsequent
injected* command that matches it auto-approves silently — the exact
rubber-stamp the mechanism fights, just deferred. Three things decide
whether that is survivable:

1. **Granularity is the whole ballgame.** "Always allow *this exact
   string*" is safe-ish but nearly useless (args vary). "Always allow the
   binary `git`" re-opens `git reset --hard`; "always allow `find`"
   re-opens `find . -delete`. A grant is only as safe as the matcher it
   compiles to, and a loosely-specified grant silently re-imports the
   mutating forms the allowlist was curated to *exclude*.
2. **Composition.** If a grant applies to anything but a
   metacharacter-free simple invocation, `granted-cmd && evil` rides it.
3. **TOCTOU on the executed bytes.** *Every* text-keyed grant — even an
   exact-string one — pins the command *text*, not the *code that text
   executes*. `./run.sh` is the same string tomorrow with different
   bytes; `pytest` re-reads `conftest.py`; `make` re-reads the Makefile.
   So a grant is a **capability grant** (trust the binary for the
   session), never a **safety proof**. This is why Option A below is not
   the "provably-safe floor" it first appears to be.

## The invariant, and the rejected-knob reconciliation

Two documented positions look like they collide:

- [`os-assistant.md`](os-assistant.md) contemplates session grants in
  "Claude Code's shape: **deterministic rules + user-granted session
  approvals, no LLM in the yes/no**."
- {Pikuri::Workspace::Confirmer} **rejected** the `:once/:always` scope
  knob — "the long-term answer to fatigue is making confirmations rare
  (sandboxing, `--yolo`), not smarter approval modes."

They reconcile once you see they name different things. What the yardoc
killed was a *scope knob baked into the confirmer's return* — making the
`Confirmer` protocol cleverer about saying yes. What this note wants is a
**deterministic rule layer in the `ReadOnlyAutoConfirmer` lineage**:
the human authors a rule, *code* matches it. That is the same category as
the static allowlist, just runtime-populated — not a smarter approval
mode.

So the governing invariant (inherited from `os-assistant.md`): **AI may
*translate* a command, but code and the human *decide* — never an AI
✓/⚠ verdict.** The grant must originate from a *human keystroke*; an LLM
proposing "add this to the allowlist" would be exactly the AI-approver
anti-pattern. Concretely, three constraints keep this on the right side
of the rejected knob:

1. **Human-authored** — a grant is recorded only on an explicit human
   keystroke, never inferred.
2. **No widening past the simple-invocation gate** — a grant is honored
   only for a metacharacter-free, bare-name simple segment (reuse
   `segment_read_only?`), so it can never be composed.
3. **Session-only, in-memory, never persisted** — a persisted grant
   outlives the human's attention and becomes a config-file attack
   surface; the OS-helper is "start fresh each session" anyway.

## Options

**A — Exact-command-string grants.** "Don't ask again for *this exact
normalized string*." Marketed as the provably-safe floor — but the TOCTOU
point above kills that claim: the string is pinned, the executed bytes
are not. Strip the false safety and A is just the *brittle* option
(`pytest tests/a` ≠ `pytest tests/b`, near-zero hit rate). Not worth
building on its own.

**B — Binary-scoped grants, gated by the existing `Tokenizer`
(recommended if ever built).** The human grants `pytest`; it joins a
**session grant-set** that the same `segment_read_only?` discipline
consults, so it is honored only for a metacharacter-free, bare-name
simple invocation — `pytest && rm -rf` still delegates. Reuses all the
machinery already there; the only new thing is a user-populated set
beside the static one. Honest difference from `READ_ONLY_BINARIES`: a
granted binary carries **no "no mutating form" guarantee** — it is a
capability grant (Claude Code's `Bash(pytest:*)` model), and the human
must understand they are handing that binary its full power for the
session. The metacharacter-free gate is what stops it composing; the
session scope bounds the window.

**C — Structured patterns (`git commit:*`).** B generalized to
subcommand + prefix. More expressive, more rope, and the pattern language
becomes its own attack surface (users will mis-specify). Defer until B
proves insufficient.

## Architectural fit — no protocol change

The clean shape avoids reopening the return type:

- A **shared, in-memory, session-scoped grant-set**.
- The **matcher** is a decorator in the `ReadOnlyAutoConfirmer` lineage
  (or a small addition to it) that reads the grant-set.
- The **chrome** (`Confirmer::Terminal`) offers a third answer on an
  otherwise-approved prompt — `[y] yes  [a] always (this session)
  [n] no` — and on `a` **mutates the shared grant-set directly**.

Because chrome and matcher hold a reference to the *same* object, the
"always" keystroke needs **no new `Approved` case and no `remember:`
flag** — the confirmer return type stays exactly as-is. The grant is a
side-effect on a shared session object, authored by a human keystroke,
not a value threaded through the confirmer protocol. That is the
mechanical reason this doesn't resurrect `:once/:always`.

## Recommendation, and why it's deferred

If built: **Option B**, under the five constraints above
(human-authored · simple-invocation-gated · session-only · in-memory ·
shared-object side-effect). It is a small add given the `Tokenizer` and
decorator already exist.

Deferred anyway, because:

- **The OS-helper barely needs it.** Its repetitive commands are mostly
  read-only queries the static allowlist already covers; the
  build/test/mutate residue that grants would help is small there.
- **The coding agent is the real customer** (`pytest`, `cargo build`,
  `git commit` loops), so this should be scoped when a real
  `pikuri-code` session shows the residue biting — not speculatively.
- **The residual is real and must ship documented** when it does: a
  grant is a standing capability a later injection can ride; session
  scope bounds the window, the simple-invocation gate bounds
  composition, and granularity + the TOCTOU-on-bytes truth are the
  human's explicit, informed choice.
