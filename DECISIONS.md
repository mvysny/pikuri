# DECISIONS.md

A living record of the design decisions behind pikuri — especially the
*roads not taken*. It exists because the graduation pipeline (see
[`CLAUDE.md`](CLAUDE.md)) had no home for one fact class: a rejected
alternative. Both candidate homes refuse it on their own stated terms —
yardoc is browsed standalone on rubydoc.info by someone at the API, who
gains nothing from an argument against a design that never shipped; and
CLAUDE.md is loaded into *every* session's context under a 40 KB cap, so
rationale there is paid for on every turn. This file is the lazy side of
that split: never context-loaded, read only when someone asks "why this
way?".

It is the *why-we-chose* record. It is not the *how-it-works* reference
(yardoc), the *why-the-concept* narrative (the book), the *what-you-must-
not-break* list (CLAUDE.md), a gem's architecture + threat model (per-gem
`DESIGN.md`), what other projects do (`COMPARISON.md`), or the shipped
defenses (`SECURITY.md`). An entry links out rather than restating.

**Boundaries** — the three that keep this from becoming a second copy of a
neighbor:

- **vs. per-gem `DESIGN.md`.** DESIGN.md describes the system *as it is*,
  for someone extending that gem. This file records *forks*, and is
  repo-root so it can hold the cross-gem ones DESIGN.md structurally
  can't. Carve-out: when a rejected alternative is gem-local *and*
  inseparable from that gem's threat model, leave the reasoning in the
  gem's DESIGN.md and make the entry here a one-line pointer. Never two
  half-answers.
- **vs. `COMPARISON.md`.** That file says what *others* do; this one
  records our choice against that option.
- **vs. `SECURITY.md`.** A shipped defense stays there. Only the fork
  ("rejected X because it widens the surface") comes here.

**Format.** One entry per decision. The ID is a slug, not a number: `D-`
plus a 1–4-word kebab hint at the subject (`D-per-process-temp`), so a
citation carries meaning on its own. The `(date)` on the heading is
*decided* provenance, not a log position — git owns the edit history, so
don't narrate how an entry used to read. Keep each entry tight: context,
the decision, the alternatives rejected and why, and the consequences a
future contributor would trip over. A decision is worth logging the moment
it's *made*; implementation can lag (the `Status:` line says which).

**No entry without a real fork.** If nothing was seriously considered and
rejected, it isn't a decision — it's how the thing works, and that's
yardoc. This is the guard against a diary. Nor is an entry warranted when
the fork is already argued somewhere durable — a rejected alternative with
real teaching value belongs to the **book** (worked example: the
MoE-vs-dense-model argument, the book's first-conversation chapter), and this file would only duplicate
it.

**Newest first.** Entries run reverse-chronologically by decided date, so a
scan hits recent decisions first.

**Never read wholesale.** `grep '^## D-' DECISIONS.md` is the index; there
is no ToC (same discipline as `ls ideas/`). Cite an entry by slug. Grep
tripwire: every `D-<slug>` referenced anywhere in the repo must exist as a
`^## D-` heading here.

**Entries are mutable — edit in place, don't append addendums.** Each entry
is the single coherent home for one *live* decision; keep it current as the
decision is refined or extended. Two things this does *not* license:

- **The roads-not-taken stay.** "We chose X, rejected Y because Z" is live
  content of the current decision, not stale history — never edit it away.
  It's the most valuable thing in the file.
- **A reversed *shipped* decision forks a tombstone, it is not
  overwritten.** When a design was tried, shipped, and then thrown away,
  leave the old entry as the scar, set its `Status:` to **Superseded by
  D-\<slug\>**, and write the replacement fresh. The line: *refined or
  extended* → edit in place; *reversed after shipping* → tombstone + new
  entry.

**Backfill is opportunistic.** Rejection rationale that already sits inline
in a yardoc or a `DESIGN.md` (the pre-2026-08-04 convention) stays put —
this file is the home going *forward*. Move an old one only when you're
already editing that doc and the inline rejection is crowding out the live
design.

---

## D-reference-text-as-user-turn — Mid-conversation reference text is a wrapped `:user` turn, never `:system` (2026-08-17)

**Status:** Accepted, shipped 2026-08-17, and confirmed the same day through
the shipped path — `bin/pikuri-code` against
`unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M`, where the model now reports the two
skills a `paths:` promotion had just put in play. The A/B below was a
hand-patched probe (`ext.announce` redefined on the singleton); this is the
library doing it.

**Context.** Everything pikuri appends to a live conversation on its own
initiative — pikuri-memory's per-turn prefetch, a host-loaded skill body
(`Skill::Extension#schedule_load_skill`), a `paths:` promotion
(`Skill::PathActivationListener`), plan mode's per-turn re-assertion, and
the retrieved-context injections vectordb RAG was heading toward — landed as
`add_message(role: :system)`. On 2026-08-17 that was measured against the
author's own llama.cpp router with `unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M`
and found to reach the model **not at all**. The chat template ships inside
the GGUF, the server runs `--jinja`, and its render loop is:

```jinja
{%- set num_sys = 0 %}
{%- if messages[0].role == 'system' or messages[0].role == 'developer' %}
    …merge messages[0] (and messages[1] if also system) into one header…
    {%- set num_sys = 2 %}   {# or 1 #}
{%- endif %}
{%- for message in messages %}
    {%- if loop.index0 >= num_sys and message.role != "system" and message.role != "developer" %}
```

Every system/developer message past the leading one or two is skipped. Not
rejected, not warned about — absent from the string the model reads.
`POST /apply-template` is the ground truth (it renders a `messages` array
and returns the prompt, no generation), and a canary of
`[system, user, system("PIKURI_CANARY")]` shows this is a *newer-template*
behaviour rather than a Qwen family trait:

| model | mid-conversation `system` survives |
|---|---|
| `bartowski/Qwen2.5-7B-Instruct-GGUF:Q5_K_M` | yes |
| `unsloth/Qwen3-4B-Instruct-2507-GGUF:Q5_K_M` | yes |
| `unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M` | **no** |

Live A/B on the real model, same conversation, only the injection role
changed: as `:system` the model named five loadable skills; as `:user` it
named all seven, including the two the promotion had just added. The
mechanism was correct end to end — only the delivery role was wrong.

Two properties make this the worst class of bug and are why the decision is
uniform rather than adaptive. **It is silent**: the message is in the HTTP
payload, the listener stream renders it, `Chat#messages` holds it — every
layer pikuri can observe says "delivered", and the model then reads as dumb
or stubborn. And **it flips when you change models**, with nothing in the
API reporting the change. `/props` even returns
`chat_template_caps.supports_system_role: true` for Qwen3.6 — true for a
*leading* system message, useless for this question. Do not build on it.

The second half of the context is that the hazard is not one template's
quirk. Anthropic's Messages API has no mid-conversation system role at all —
`system` is a top-level request param — so ruby_llm's provider hoists:
`messages.partition { |msg| msg.role == :system }`. On Anthropic a
promotion that fired at turn 5 was already being presented as though it had
been in the original prompt. grok-build's Anthropic converter does the same
thing, and grok-build never hits it because it has no mid-conversation
system message to hoist (`COMPARISON.md`, *grok-build's injection channel*).

**Decision.** One channel for all of it. `Agent#append_reference_block`
appends `role: :user` with the content wrapped in
`<system-reminder>…</system-reminder>`, and every producer routes through
it — the `Extension#on_user_message` dispatch and the interloper's
`:system` kind alike. `Control::Interloper` keeps both kinds: they now
differ in *dispatch and envelope*, not in wire role, which is exactly the
distinction worth keeping (a `:user` item is a turn and fires
`on_user_message`; a `:system` item is reference text and does not).
`Event::SystemInjected` keeps its name — it names the role the text
*plays* — and carries the block **unwrapped**, because the envelope is wire
plumbing and a listener showing it would render framing the host never
wrote. A closing tag inside the content is escaped, so an injected file,
web page or MCP description cannot close the envelope early and have what
follows read as conversation.

`<system-reminder>` is Claude Code's tag and grok-build's, taken
deliberately: an in-distribution envelope the model has seen in training
beats a pikuri-flavoured one it has to infer. A caller's own semantic tag
(`<memory-context>`) is kept and the envelope nests around it — nesting is
what grok-build does too, and it means one grep finds every injection.

**Alternatives rejected.**

- **Probe the template at boot and adapt** — canary `/apply-template`, use
  `:system` where it survives and `:user` where it doesn't. Rejected on
  three counts. A probe **cannot be authoritative**: `/apply-template` is
  llama.cpp-only, so there is always a default for "couldn't ask", and it
  has to be the option that cannot fail silently — at which point the
  probe only buys the *other* branch. **A branch taken rarely rots**: the
  `:system` path would run on Qwen2.5 and the `:user` path on Qwen3.6, and
  neither is exercised where the other lives. And the failure it guards is
  silent, where every other failure mode in pikuri is loud. The strongest
  version of this argument is that a real system message may carry more
  weight on models that honour one — true, untested, and not worth a
  silent-failure mode to chase.
- **Merge the block into the leading system prompt** (grok-build's memory
  path). Prefix mutation kills the KV cache on every injection, which is
  the exact cost `D-skill-path-activation` weighed and accepted *not*
  paying. grok-build can afford it for memory alone because it searches
  **once** per session and then refuses to re-score for precisely this
  reason; pikuri's prefetch is per-turn, so the same write would invalidate
  the cache every turn.
- **Hoist a subset** — keep `:user` for per-turn blocks, merge the
  once-per-conversation ones. There is no qualifying subset: a host-loaded
  skill and a path promotion are mid-conversation *by nature* (that is what
  makes them injections rather than prompt snippets), and memory and RAG
  are re-scored per turn. The one genuinely static case,
  `Workspace::Extension`'s boot snapshot, is already a
  `system_prompt_snippets` contribution and was never an injection.
- **A pikuri-flavoured envelope tag.** Out of distribution for no gain.
- **Collapse the two interloper kinds into one plus a `wrap:` flag.**
  Considered because both now land as `:user`. Declined: the kinds differ
  in dispatch semantics (a user turn fires `on_user_message` and emits
  `UserTurn`), and a boolean at the call site is a worse name for that than
  the kind is. grok-build reaches the same shape from the other direction —
  one role plus a nullable `SyntheticReason` tag, interrogated by
  `starts_prompt_turn()` / `is_real_user_turn`.

**Consequences.**

- **A host-loaded skill is no longer sticky on Anthropic.** It used to be
  hoisted into the system param and stay in force for the conversation;
  `schedule_load_skill` documented that as intentional. It is now a
  positional one-shot on every provider, identical to the `skill` tool's
  observation. Uniformity was judged worth more than the divergence, and
  what was actually happening (the whole block silently reordered to the
  front of the prompt) is not what the doc claimed.
- **`Agent::EmptyTurnError` survives, and got narrower.** Its trigger was a
  `:system`-only conversation rendering `messages: []` on a hoisting
  provider — which used to include the "bare-load a skill, then run a blank
  turn" case. A drained reference block is now a `:user` message, so that
  case completes normally; what remains is a genuinely empty conversation
  (fresh chat, blank turn). Kept rather than retired: that case is still
  reachable and still a 400.
- **Two consecutive `:user` messages are now routine** — the turn plus its
  reference block. Fine on OpenAI-family and on a chat template (two
  `<|im_start|>user` blocks); grok-build ships the same shape against the
  Anthropic Messages API without merging.
- **The offline pin is `pikuri-core/spec/pikuri/testing_spec.rb`**, whose
  wire-format specs assert role names *and message order* in the recorded
  request body — including that the only `system` message is at index 0.
  No assertion inside pikuri could have caught the original bug, because
  every layer pikuri owns reported success; the payload is the lowest layer
  it can see, so that is where the pin goes. The online half — a
  `bin/pikuri-wire-check` printing which markers survive
  `/apply-template` — is still owed, and generalizes past this bug to a
  template that drops tool messages or reorders them.
- **pikuri-memory was presumably inert against Qwen3.6** for as long as
  that model has been the default. Not measured retrospectively.

## D-slash-commands — Two registries, a user turn, and no scheduling function (2026-08-16)

**Status:** Accepted, shipped: `Pikuri::Command::Registry` / `Renderer` /
`Extension` in `pikuri-skills`, wired in `bin/pikuri-code` and
`bin/pikuri-assistant`. `ideas/slash-commands.md` is deleted with this entry.

**Context.** Moving the `wh` bundle from `~/.claude/skills/wh/SKILL.md` to
`~/.claude/commands/wh.md` made it invisible to pikuri twice over: the catalog
scans no `commands/` dir, and requires a *directory* holding `SKILL.md`. The
second motive is stronger and came from measuring a 12-skill catalog: two of
those skills were slash commands filed as skills, and their descriptions were
resident tokens spent telling the model to ignore them (`wh`'s read *"Only
invoked manually."*). A bundle the human invokes belongs on a surface that was
never advertised, where it costs nothing.

**Decision.** A separate `Command::Registry`, scanning `.pikuri/commands` /
`.claude/commands` under the same `Bundle::Base` search bases as the catalog.
Its expansion lands as the **user's** turn. There is no scheduling function:
the host holds both handles already (`registry.expand(name, arguments:)` then
`run_loop(user_message:)` or `Interloper#inject_user_message`). Typed
resolution, which only a host can do because nothing in the library sees all
three namespaces, is **host built-in > command > skill**.

**Alternatives rejected.**

- **One catalog holding both kinds.** Rejected because "never advertise a
  command to the model" would become a `reject { it.command? }` that a future
  refactor drops silently — costing tokens every turn and offering the model a
  half-working `skill(name: "wh")`. Two types, and the mistake is
  unrepresentable. The records and the scans genuinely differ too (one `.md`
  with `:`-joined path namespaces and an interpolatable body, vs. a directory
  of `SKILL.md` plus sidecars).
- **A `kind:` flag on `Skill::Extension#schedule_load_skill`.** Rejected: that
  path injects `:system`, and every consequence is wrong here.
  `on_user_message` would not fire (`pikuri-memory` hangs its per-turn
  prefetch there, so a memory layer would never see `/wh`); on Anthropic a
  `:system` block is hoisted and therefore *sticky*, turning a one-shot
  request into standing instructions; and a `:system`-only turn has to worry
  about `EmptyTurnError`, which an ordinary user turn does not.
- **A `Pikuri::Slash::Menu` façade merging both registries.** Rejected for
  now: the merge is five lines of presentation over two arrays that already
  carry `name` + `description`, and the halves *dispatch* differently, so a
  merged record needs a kind discriminator — at which point the library models
  the TUI's popup. The two registries ship with deliberately parallel shapes
  so a second host can write the merge in five lines; if two hosts write the
  same five, the façade earns its place then.
- **Raising on a name collision.** Rejected: `Catalog::Bundled` already
  answers the skill-vs-skill form by keeping the first entry and warning, and
  two collision policies in one codebase is worse than either.
- **Letting a skill win the typed name.** Rejected on asymmetric
  reachability: if `/wh` resolves to the skill, the *command* becomes
  unreachable by anything — nothing else can invoke it, by design — whereas
  the skill loses only its slash affordance and stays fully model-invocable.
  One side of the fork drops a capability, the other drops nothing.
- **A host built-in losing to a scanned file.** Rejected as a real hijack:
  commands are scanned from the project root, so a cloned repo shipping
  `.claude/commands/plan.md` would capture `/plan` — the read-only plan-mode
  toggle — and the failure is invisible, reading as a chatty model rather than
  a disabled gate.
- **Parsing `argument-hint:` into slots** so the library could reject `/wh`
  with no arguments. Rejected: it is display chrome for a menu, and a body
  handles a missing argument better than a validator can (`wh.md` already
  says "if no label was given, use 'swingai'").

**Consequences.**

- **`Registry` and `Renderer` are pure functions over disk**, testable and
  usable with zero agent integration — which is what let two synchronous
  `bin/` demos wire the feature before `pikuri-tui` exists.
- **`Registry#get` carries two contracts**: `nil` for a name that isn't there
  (an ordinary typo, fixable by retyping) and a raise for one that is there
  but refused (a fact about a file on disk). A host written against only the
  first dies on the second.
- **Commands still need an `Extension`** — a declaration-only one, because a
  surface that contributes no tool lands nowhere in the `Pikuri::Trifecta`
  tree, and an agent holding all three legs would report two. It grades the
  untrusted leg through `D-bundle-trust-grading`'s per-base channel.
- **`Trifecta::Contribution` gained a `label:`.** Extension legs used to be
  unioned into one row hardcoded as `(mcp)` — honest only while MCP was the
  only contributor. A second one made the banner blame an MCP server that
  wasn't wired, against `Report#attribution`'s whole purpose.

## D-command-inlining-legs — No bash pre-execution, and `@path` is not a refusal (2026-08-16)

**Status:** Accepted, shipped in `Command::Registry`. Graduates whether or not
the command surface survives: *"just add bash pre-execution, Claude Code has
it"* is the recurring temptation, and the answer is not reconstructible from
code that never grew the feature.

**Context.** Claude Code expands two more things in a command body. `` !`cmd` ``
runs a shell command *before the prompt is sent* and inlines its stdout, gated
only by the command file's own `allowed-tools:` frontmatter — i.e. gated by the
untrusted file itself. `@path` inlines a file's bytes.

**Decision.** Neither ships, and they get *different* handlings from the same
premise. A body containing `` !` `` is **refused**: `Registry#get` raises
`RefusedError`, the scan warns, and detection is deliberately over-eager
(fence-blind, and matching `allowed_tools` beside the documented
`allowed-tools`). `@path` is simply **not interpolated** — it passes through as
literal text, with no warning and no refusal. `allowed-tools:` is refused on a
command while still being ignored on a skill.

**Alternatives rejected.**

- **Implementing `` !`cmd` `` behind pikuri's confirmer + sandbox.** Rejected:
  it makes a `.md` that travels with a clone into arbitrary code execution
  triggered by typing a slash. Without it a command is *text*, and its worst
  case is prompt injection into a turn the human deliberately asked for —
  which is also what keeps the feature inside `pikuri-skills` instead of
  earning its own gem. Wanting it back is a feature request, which is exactly
  the signal to have before building the gated version.
- **Passing the `!` line through as literal text** so the human can see it.
  Rejected, and this reversed an earlier lean: a literal `` !`git status` ``
  sitting in the prompt reads to the *model* as an instruction, so the likely
  outcome is not "visibly misbehaves" but "the model runs it through the real
  `bash` tool a beat later" — the refused behaviour, arrived at
  unpredictably. An exception has no second reading.
- **Refusing `@path` too.** Rejected: unlike `!` it has a harmless second
  reading. A literal `@docs/style.md` left in the text reads as a path
  mention, and the worst case is the model calling `read` — through the gated
  tool, against the workspace, exactly as wanted. Detection would also have to
  be over-eager to be safe, and `@`-shapes false-positive on the email
  addresses in the very file that motivated the feature.
- **Ignoring `allowed-tools:` on commands, as skills do.** Rejected: pikuri
  fixes tools at `configure` time and cannot narrow them mid-conversation, so
  ignoring the key runs the command with the full toolset when its author
  asked for a fenced one. That is a *widening*, not a no-op.
- **Refusing `allowed-tools:` on skills too**, for symmetry. Rejected on
  compatibility asymmetry, and the two halves are only defensible together:
  the key is one of the six official Agent Skills fields, so refusing it on
  the shipped skill surface would break catalogs doing nothing wrong by
  carrying a field the standard defines (`COMPARISON.md`'s finding 3 is the
  general form — a key the host doesn't implement is advertised anyway). On
  the command surface the key is not spec, it is Claude Code's own, and its
  documented job is gating the pre-execution pikuri refuses.

**Consequences.**

- **Refusal is a scan-time fact stored on the record**, so `#refused?` and its
  reason are free to a menu; only `#get` raises. Skipping the entry at scan
  time instead would make it silently absent, which is the same
  discoverability failure one layer up.
- **`RefusedError` is host-facing**, never reaching a tool, so the
  `"Error: …"`-string convention for model-visible failures does not apply.

## D-command-substitution — Fence-aware, and the append reads the body the same way (2026-08-16)

**Status:** Accepted, shipped in `Command::Renderer`.

**Context.** Measured against Claude Code 2.1.233 (headless, throwaway project,
reproduced on two models): the expansion is wrapped in
`<command-message>` / `<command-name>` / `<command-args>`; arguments a body
never references are appended after two blank lines as `ARGUMENTS: <raw>`; and
`$n` indexes the argument list **0-based** while being documented and
universally written as 1-based, so `$1` yields the second word.

**Decision.** `$n` is **1-based**. An out-of-range `$n` stays **literal**, as
it does there. Substitution skips fenced blocks and inline code spans, for
*both* tokens — and the "body references neither" check that gates the append
runs over the same segmentation, as one pass. The append copies Claude Code's
exact spelling. No XML wrapper; a `(this command lives in …)` footer instead,
and only when the directory holds a sidecar.

**Alternatives rejected.**

- **Matching the 0-based bug.** Rejected: nobody authored *against* it — the
  shape it produces is a body that silently reads the wrong word, likelier
  papered over than noticed — and matching it means matching it forever.
- **Blanking an out-of-range `$n`.** Rejected on the same axis as everything
  else here: blanking makes a `$1` the author never meant as a placeholder
  silently vanish, while leaving it literal keeps the mistake visible in the
  transcript.
- **Substituting blindly, as the prior art does.** Rejected on the motivating
  file: `wh.md` carries `$ARGUMENTS` and `$1` inside backticks while writing
  *about* them, and a blind pass rewrites that sentence into one that asserts
  something false to the model. A command emitting a shell script has its
  `"$1"` hardcoded to one invocation the same way.
- **A `$$` escape for authors who mean the literal.** Rejected: it only works
  on files someone edits, and imported bundles nobody will edit are the whole
  reason to scan someone else's directory.
- **Fence-aware `$n` with blind `$ARGUMENTS`**, on the theory that
  `$ARGUMENTS` is distinctive enough that a mention means a placeholder.
  Rejected by counterexample in the same file: authors writing about commands
  backtick both tokens.
- **Reading the body blind for the append gate** while substituting
  fence-aware. Rejected as a data-loss bug: `wh.md`'s every `$ARGUMENTS` is
  backticked, so it counts as "referenced", gets no append — and gets no
  substitution either. The typed argument disappears with no error, on the
  most common invocation of the only command file we had.
- **Wrapping the expansion in `<command-*>` tags.** Rejected: the prior art's
  wrapper carries no *location*, so it does not solve the base-directory
  problem that was the only functional argument for having one. A wrapper we
  would have to extend anyway is a wrapper worth not having.

**Consequences.**

- **`` !` `` detection stays fence-blind while substitution is fence-aware**,
  and that is not an inconsistency: a false positive in detection is a loud
  exception on an editable file, a false positive in substitution is silent
  corruption. Whoever "fixes" one to match the other reintroduces the bug.
- **`wh.md` interpolates nothing and rides the append**, which is the correct
  reading of it and the reason the gate is shared.

## D-skill-path-activation — A `paths:` skill is not in play until its path fires (2026-08-16)

**Status:** Accepted, shipped 2026-08-17. One qualification the decision did
not anticipate: a promotion reaches the model only through mid-loop injection,
so an agent built without an `interloper:` has no channel to un-hide a skill
on. Rather than hide what nothing can bring back, the gate comes off wholesale
there — `Skill::Activation::Open` plus a warning naming the skills that stayed
advertised. `bin/pikuri-code` now wires an interloper for exactly this reason,
though the REPL enqueues nothing itself. The author's own
`~/.claude/skills` is already annotated, so the five gated skills there are
now live for pikuri too. Decisions 2 and 5 were
**reversed the same day they were written**, after probing Claude Code
rather than reasoning about it; the first version is the first rejected
alternative below, and it is there because the argument for it was good
and someone will make it again.

**Context.** The axis is *what the catalog advertises, and when the body
arrives*. `Skill::Extension` contributes an `<available_skills>`
system-prompt snippet carrying every skill's description; on the author's
ten-skill catalog that is ~4.8 KB resident on every turn, of which at most
one entry is relevant to any given session. Two things made the status quo
hard to defend. The author's global CLAUDE.md hand-wrote five skill nudges
*while that catalog was already resident* — nobody writes a redundant
nudge for a mechanism that works. And descriptions fail asymmetrically:
they work for capability-shaped skills, where the model feels a gap it
cannot fill, and fail for correction-shaped ones like `cop`, where the
model confidently does the wrong thing and never runs the relevance check
at all.

**Decision.** Adopt grok-build's `paths:` frontmatter key, with pikuri's
own placement:

1. The catalog **stays a system-prompt snippet** and carries every
   *ungated* skill in full.
2. A skill declaring a non-empty `paths:` is withheld **entirely** — no
   description, no name, no sibling section, and no hint that anything is
   withheld. The catalog does not advertise its own incompleteness.
3. When a tool **reads or edits** a file matching those globs, the skill's
   description is appended to the log as a system message.
4. A promotion carries a **description, never a body**.
5. A gated skill is **not loadable by name** before its path fires:
   `skill(name:)` refuses it exactly as it refuses a name that exists
   nowhere, with the same message. `SkillTool`'s `name` therefore stays a
   **free-form string, never an enum** of the active set — an enum would
   have to be rebuilt on every promotion, churning the tool schema
   mid-session on every provider.
6. `paths:` answers *"is this ecosystem in play?"*; `when-to-use:` answers
   *"is this the moment?"*. They compose on one skill and are not rivals.
7. The gate is the **default at every surface**, not the model's alone:
   {Pikuri::Skill::Extension#schedule_load_skill} refuses a pending skill
   exactly as the tool does, and so must any future picker or typed
   `/name`. One rule with no exceptions to remember — *a `paths:` skill
   is not in play until its path fires*. Two deliberate carve-outs, both
   because they are not invocation routes: `Catalog#get` stays unfiltered
   (the catalog is frozen, session-less, pure holding — the gate lives in
   its callers, never in the catalog itself), and `bin/pikuri-code`'s
   startup banner keeps reporting what is *installed*.

Prior art and the read of grok-build's implementation live in
`COMPARISON.md` (*Skills → Frontmatter*, and *→ How grok-build's
conditional activation actually works*).

**Alternatives rejected.**

- **Delete the catalog; rely on `skill(name:)` plus path activation.** The
  model cannot call a tool with an argument it has never seen. The name
  has to come from somewhere, and every substitute is worse: a CLAUDE.md
  nudge is the same words in a hand-maintained home that rots silently on
  a rename, where the catalog is regenerated from the filesystem at boot;
  path activation alone leaves a skill without `paths:` permanently
  unreachable, and `cop` is exactly that skill; a `skill_list` discovery
  call buys a round-trip.
- **Tier 0 — names-only for *every* skill, descriptions promoted on
  demand.** Measured at ~65 tokens for names against ~1.5 k for
  descriptions, so the ratio is tempting. Rejected because it withholds
  the descriptions that *work*: the file-shaped skills whose descriptions
  do fire are precisely the ones a glob can gate, while `cop` — which
  demonstrably never fires — has no predicate and would stay resident. It
  removes the working half and keeps the failing half, and makes every
  gated skill need two things to go right where it previously needed one.
  Gating per skill, chosen by the author, keeps the ratio without the
  inversion. No surveyed harness ships a names-only catalog; grok-build
  renders one only as budget overflow, and its source carries a comment
  rejecting a names-only footer as "wastes tokens and looks like skills
  with no description".
- **Move the catalog out of the system prompt, as grok-build does.** Its
  baseline goes into the first user message
  (`prompt/user_message.rs`), never the prompt — a genuinely better
  position on two counts: promotion mutates no prefix, and skill
  descriptions are `untrusted: :hard` text that would sit in a data
  position rather than the most-trusted slot in the request. Declined for
  now as a larger change than this decision needs; recorded because it is
  the strongest argument against our placement and the first thing to
  revisit. The consequence we accept is that the untrusted-description gap
  stays open for ungated skills.
- **Advertise gated skills name-only, in a sibling `<contextual_skills>`
  section, and keep them invocable.** This was the decision as first
  accepted, reversed the same day on evidence. Three things killed it.
  It is shipped by **nobody**: grok-build holds a gated skill out of its
  `AvailableSkills` registry entirely (`has_skill()` refuses it), and
  Claude Code was then observed doing the same, down to returning the
  identical "unknown skill" message it returns for a name that exists
  nowhere (`COMPARISON.md`, *Skills → Frontmatter*, finding 4). One
  harness is noise; two independent ones are a signal, and this is the
  same convergence argument that chose the top-level `paths:` spelling —
  applying it to the spelling and declining it for the semantics would
  have been incoherent. It rests on an **unmeasured assumption that is
  weakest exactly where pikuri runs**: that a bare name is a strong
  enough recall cue, which is far likelier on Claude than on the local
  llama.cpp default. And it costs more than the names — a preamble
  explaining the two-tier scheme and the load-by-name-anyway caveat
  outweighs the ~65 bytes of names it was protecting.
- **Keep the `SkillTool` `name` argument enum-constrained** over the
  active set. Rejected as incompatible with decision 5, and the two
  surveyed harnesses agree by construction: the one that hides skills is
  the one that takes a free-form name. This retires the enum item that
  `ideas/skill-catalog-in-context.md` carried as owed-regardless, and
  with it the lenient-name-validation reversal that blocked it —
  `validate_name`'s warn-and-continue posture stands, because a lenient
  name now reaches only a prompt block, never a tool schema.
- **Invent a `project-has:` predicate** for "this is a Gradle project"
  rather than "a Gradle file was touched". Not in the spec, not in
  grok-build, not anywhere; inventing a predicate no harness implements,
  to serve a saving in the hundreds of tokens, was the clearest thing to
  drop. Its motivating case is served by operator wiring instead.
- **Pre-inject the body on a path match.** A `paths:` in a downloaded
  bundle deciding to occupy 4 KB of a host's context is the skill *author*
  spending someone else's window — where the same act by a host loading a
  skill it named itself is legitimate, because it is spending its own.
  Same mechanism, different hand on it, opposite verdict. Note this is
  the one place the author/host asymmetry still bites after decision 7
  closed the operator exemption: a host may pre-inject a body it chose,
  but it may no longer name a *gated* skill to do it to.
- **`paths: []` as the spelling for "never advertise".** In the shipped
  implementation an empty list means **unconditional** — the exact
  opposite — and so does `["**"]`, because normalization drops a match-all
  to `nil`. It is also a YAML footgun with an inverted failure: a bare
  `paths:` with nothing under it parses to `nil`, so the author types the
  thing meaning "hide" and gets "advertise". A skill that should never be
  model-invoked wants `disable-model-invocation:`, which is a separate
  question and blocked on the host load path.
- **`metadata: {pikuri-paths: …}` over the top-level key.** Spec-clean,
  and the spec's sanctioned extension point — grok-build parses `metadata`
  too, so the shape is proven. Rejected because top-level `paths:` is what
  two independent harnesses already honour, and agreement is the whole
  value of not inventing a dialect. For a *newly invented* predicate there
  would be no agreement to buy and `metadata:` would win by default.

**Consequences.**

- **Anthropic and Bedrock pay a prompt-cache invalidation per activation,
  accepted.** ruby_llm's `providers/anthropic/chat.rb` partitions *every*
  `:system` message out of the array and folds it into `payload[:system]`,
  so an injected promotion rewrites the prefix. The OpenAI-compatible path
  — including the local llama.cpp default — keeps it positional
  (`providers/openai/chat.rb` `format_role`), so it costs nothing there.
  pikuri targets the OpenAI path first; this is a known trade, not an
  oversight.
- **The gated set is ecosystem filters, not moment triggers.** When a
  predicate cannot be exact, prefer over-firing to under-firing: an
  over-fire spends a few hundred bytes on an entry the model ignores, an
  under-fire withholds the skill at the moment it was needed. A coarse
  glob is also not *adding* a false positive relative to leaving a skill
  ungated — ungated shows it in every project — so it strictly shrinks the
  surface.
- **Measured on the author's ten-skill catalog:** five skills carry
  `paths:`, holding 2 828 of 4 798 description bytes (59 %); in a Ruby
  session roughly 1 465 bytes (31 %) stay withheld, since the Ruby-gated
  ones fire almost at once. Both numbers matter — the first is what the
  mechanism *can* gate, the second what it saves in one session. An
  earlier estimate of the same quantity, made by the party proposing the
  mechanism, was 3× off in the optimistic direction and was corrected only
  by writing the frontmatter it was estimating. Anyone re-opening this
  should author before estimating.
- **Cheap-to-gate and expensive-to-carry are nearly disjoint.** `gradle`
  (117 B) and `maven` (175 B) are the skills a project-type predicate fits
  best and the ones with nothing to save; `cop` (1058 B) is the largest
  description and the least gateable. Gating is a relevance measure that
  happens to save bytes, not a compression scheme.
- **Ships as one change:** frontmatter parsing (with the empty/match-all
  normalization), a glob matcher, a post-tool-call listener holding
  session-scoped activation state — *not* in `Catalog::Bundled`, which
  deep-freezes itself — and a catalog render that simply skips gated
  entries. Activation must ignore
  paths a tool *walked* to (`grep` hits, listing rows) and count only
  model-supplied read/edit targets, mirroring both grok-build and pikuri's
  own **Denylist seam** distinction; a repo-wide grep would otherwise
  activate half the catalog at once. A skill is announced **at most once
  per conversation**, however many matching files are touched — the
  promotion is already in the log, and re-injecting it pays the cost
  again for nothing. That flag clears on `Event::Reset`, which is also
  what makes `clear_conversation` re-hide correctly: the reset drops the
  announcement from the log, so the next touch must re-announce. Both the
  walked-path exclusion and the once-per-conversation rule were then
  observed in Claude Code before pikuri wrote a line of it — see
  `COMPARISON.md` finding 4. **Every place that enumerates the catalog
  is part of the change, not just the render** — including `SkillTool`'s
  own not-found error, which lists `catalog.list` and would otherwise
  turn one refused guess into a full catalog dump, hiding a name in the
  prompt and reciting it in the error.
- **`paths:` still is not access control, and now looks like it.** It
  withholds and refuses, but it restricts nothing, because **the gated
  party controls the trigger**: a model that wants a hidden skill need
  only read a matching file. The honest formulation is *unreachable by
  ignorance, not by permission* — and ignorance is not a security
  boundary. The feature's shape now invites the wrong reading where
  before only its name did, so the non-claim is owed in
  {Pikuri::Skill::Catalog}'s yardoc, not merely available here. Anything
  wanting a real restriction is `disable-model-invocation:`, a separate
  question.
- **The operator is gated too, and that was decided twice.** The entry
  first carved out an operator exemption on the reasoning that
  withholding is defensible only because the model cannot judge relevance
  for a skill it was never shown, while an operator typing the name has
  already made that judgment. Both surveyed harnesses refuse the carve-
  out. Claude Code: `/writing-rdoc` in a fresh session returns `Unknown
  command`. grok-build: `slash_skills()` is built from `startup_skills`,
  which `take_unconditional` has already stripped of held skills, and
  `skill_resolvable` searches only that set — so the name does not
  resolve when typed, not merely fail to autocomplete. Its one accessor
  reaching held skills, `ConditionalSkills::held`, serves a single
  model-facing did-you-mean for a failed `SKILL.md` read.
  **What settled it was not the vote but what an exemption would be worth
  in practice.** `Catalog` is public and unfiltered, so a host building
  the obvious skill picker enumerates `catalog.list` — as
  `bin/pikuri-code`'s banner already does — and re-exposes every gated
  skill on precisely the surface both harnesses gate. An exemption that
  every naive host opts out of is a nominal convergence. Gating by
  default is the only version that survives contact with a third-party
  host.
- **`paths:` auto-*advertises*; it never auto-loads.** Worth stating
  because the opposite reading makes decision 7 look redundant rather
  than restrictive. A promotion carries description (+ `when-to-use`),
  capped — grok-build's listing renderer says so outright: *"Discovery
  only — the full skill body is loaded on invocation, so the listing
  stays terse"* — and Claude Code was observed doing the same. So
  invocation stays the only route to a body, and gating it closes the
  sole path rather than a redundant one. A `force:` escape hatch on
  `schedule_load_skill` is the obvious future request; deferred until
  something concrete needs it, since the case that would have wanted it
  (`gradle`) is a skill deliberately left ungated. pikuri ships **no cap**
  on a promotion: descriptions are already capped at 1 024 chars by the
  standard, and the mechanism exists precisely to spend a few hundred bytes
  at the moment they matter. grok-build's arithmetic is there if a fat
  catalog ever wants one — 400 bytes per entry shared between description
  and `when-to-use`, split proportionally with a 20-byte floor each, then a
  names-only fallback row.
- **A gated skill is unreachable to sub-agents, and now by construction.**
  They do not
  inherit extensions, so no listener ever promotes for them, and under
  decision 5 the name will not load either. Accepted rather than fixed:
  no bundled persona wires `skill` at all, and a persona that wants one
  should name it in `tool_names:` and carry the knowledge in its own
  system prompt. Held only by accident at first — the child inherits the
  parent's `skill` tool *instance*, so it would have resolved against the
  parent's promotions — which is why the tool now rebuilds itself for a
  child over `Skill::Activation::Sealed`, and the listener opts out of
  sub-agent propagation. This retires the per-agent-vs-catalog-wide scope
  question the build note carried.
- **Reopen when** one of these trips: (1) the untrusted-description
  position becomes a real finding rather than a theoretical one, which
  argues for the placement move above; (2) activation counts per session
  turn out high enough on Anthropic that the cache trade stops being
  noise; (3) a third harness settles on a different spelling.

---

## D-keep-ruby-llm — Decline the piece, keep the gem (2026-08-16)

**Status:** Accepted; nothing to implement. Reviewed against the reopen
criteria below on 2026-08-16 and reaffirmed.

**Context.** pikuri has only ever spoken the OpenAI-compatible
`/v1/chat/completions` shape — a local llama.cpp server by default, the
occasional cloud endpoint — and multi-provider config is out of scope
(CLAUDE.md). ruby_llm's selling point is provider breadth we use none of,
weighed against a stated value of being small enough to audit in an evening.
A streaming error-parse crash in ruby_llm's OpenAI path (a non-200 whose
body wasn't a Hash) made the question concrete enough to need an answer
rather than a shrug.

**Decision.** Keep ruby_llm as the chat transport. Where its direction
fights ours, **decline the piece, keep the gem** — the pattern already set by
`D-context-window-sources`, which refuses ruby_llm's model registry for a
`/props` probe without touching the dependency. A defect on our path gets an
upstream issue plus a small monkeypatch, guarded so it fails at boot rather
than silently stops applying, and deleted the moment the fix ships
({Pikuri::RubyLlmPatches}).

**Alternatives rejected.**

- **Hand-roll an OpenAI client.** Source-mapping ruby_llm's implementation
  against the symbols we touch puts the *client* at ~550 LOC — believable.
  But the *swap* is 2–3× that: ~100 `RubyLLM` references in `lib/` are
  matched by ~106 more in `spec/`, and four consumers fall outside the
  client entirely — `VectorDb::Embedder`'s `RubyLLM.embed` (the documented
  lone Connection-seam exception), `Mcp::Servers` synthesizing raw
  `RubyLLM::Tool` subclasses, `Workspace::Read`'s shipped image
  observations (real multimodal `Content`, not the stub a first pass
  assumed), and pikuri-tui downstream. We would also own the exact surface
  that produced the motivating bug — SSE framing, partial-chunk buffering,
  the `[DONE]` sentinel, error-body shapes — forever, instead of once.
- **Adopt `ruby-openai`** (single-provider client; own only the loop, tool
  dispatch and value types above it). The strongest of the three, and the
  right target *if* a criterion below ever trips: Faraday-native like us, so
  one HTTP stack in the process and `Pikuri::Testing`'s seam survives; the
  dependency delta is −3 gems (`marcel`, `ruby_llm-schema` — already
  replaced by `Tool::Parameters` — and `faraday-retry`). Rejected only
  because it buys that against the same swap cost above, for a stack that is
  otherwise stable.
- **Adopt the official `openai` gem.** Its short dependency line lies in the
  opposite direction: it hand-rolls `net/http` inside a large
  Stainless-generated SDK. That adds a second HTTP path to a
  Faraday-everywhere process, is not code anyone reads end-to-end, and
  **deletes `Pikuri::Testing`** outright (see `D-fake-transport`), forcing a
  new fake harness across every gem's specs. Vendor backing pays for a
  moving API surface; ours is frozen.
- **Wrapping the leaked `RubyLLM` value types** to make a future swap cheap.
  They are public API three ways — `Workspace::Read` *returns* a
  `RubyLLM::Content`, `Pikuri::Tool` *subclasses* `RubyLLM::Tool`, and MCP
  tools *are* `RubyLLM::Tool`s — so a swap is a major-version break either
  way. An anti-corruption layer bought for a swap we've decided against is
  the just-in-case abstraction CLAUDE.md rejects; the **Value-type
  passthrough** seam sanctions the leak deliberately.

**Consequences.**

- The dependency stays, monkeypatches are the escape hatch, and each is a
  liability with a delete condition rather than a fixture.
- **Reopen when** one of these trips, and not before: (1) a *second* bug of
  this kind in ruby_llm's OpenAI path that upstream is slow to fix and is
  awkward to patch — one bug is noise, a pattern is signal; (2) upstream
  drift that actively fights the single-provider, audit-first posture and
  cannot be declined in place; (3) a request/response knob we genuinely
  need and cannot reach through `RubyLLM::Context`.
- Criterion 1 has been tested once and did not trip: the motivating crash
  was one 20-line method, found in two shapes, fixed upstream in a month.
  Criterion 2 currently trends the other way — ruby_llm's
  `providers/<vendor>/` → `protocols/<wire-format>/` refactor is upstream
  converging on the single-wire-format view we already hold.
- If a criterion does trip, spike before committing: a `ruby-openai` client
  plus tool-call delta-merge and one round-trip against llama.cpp, driven by
  `Pikuri::Testing`'s existing scripted-SSE specs, to replace the ~550-LOC
  estimate with a measurement.

---

## D-single-hunk-edit — `occurrence` pays the uniqueness tax; no batch tool, no patch tool (2026-08-15)

**Status:** Accepted and shipped. `Workspace::Edit` gains `occurrence:`;
no second edit tool ships. `ideas/feedback.txt` item 2 is cut with this
entry.

**Context.** Grok 4.6, reviewing a coding-agent wiring: *"`edit` is
search-replace only. Painful for a rename-across-a-file or a method move. A
unified-diff / apply-patch tool as a sibling of `edit` would cover the
'this function is now a different shape' case without the unique-string
dance."* Three pain cases are named, and they are not the same problem:
(a) rename — `replace_all` exists, so the real gap is that it has no word
boundary; (b) method move — two edits, so the body crosses the wire twice;
(c) reshape — one edit, old body plus new body.

The prescription doesn't fit any of them. A diff is not cheaper: a move
under a diff is a removal hunk carrying the body as `-` lines plus an
addition hunk carrying it again as `+` lines — the same 2×, plus headers
and context; a reshape under a diff is context + old + new, where
search-replace is `old + new`. **The tax Grok actually hit was
*uniqueness*, not exactness.** A diff hunk is disambiguated by line number,
`old_string` by *being unique*, so a repetitive file forces a much larger
anchor than three lines of context would — `edit.rb`'s own four
near-identical `p.required_string` blocks are the worked example.

**Decision.** Add `occurrence: N` to `edit` — replace the Nth match by
position, mutually exclusive with `replace_all`. It lifts uniqueness
without touching strictness: `old_string` still matches byte-for-byte, so a
stale index fails the call rather than editing the wrong text. Ship no
second edit tool.

**Alternatives rejected.**

- **A batched-edits tool (one call, a JSON array of hunks, atomic).** The
  arm "sibling of `edit`" is really reaching for, and the only one that
  improves (b). Killed by a clean sweep of the field: **four harnesses, four
  different edit philosophies, zero batch tools.** Claude Code shipped
  `MultiEdit` and *removed* it (2.1.233 retains only permission-help and
  enum residue beside dead names like `FileEditTool`, with no `edits`
  parameter anywhere); opencode ships `edit` / `write` / `apply_patch` and
  no batch; grok-build maintains *four* interchangeable `ToolKind::Edit`
  implementations (`search_replace`, opencode's `edit`, `hashline_edit`,
  `apply_patch`) and benchmarks them — and batching is not among the four.
  That is not an oversight in a project that clearly cares about the
  question. Secondary costs that made it unattractive independently: the
  naming convention has no slot for it (a universal verb goes bare, a
  prefix marks a family sharing a backing resource — `multi_edit` is
  neither), and partial-batch failure needs its own reporting vocabulary or
  the model retries blind.
- **`apply_patch` / a V4A envelope.** Grok's literal ask, and the arm with
  real prior art — it is Codex's entire edit surface. Rejected because the
  format is **model-specific training, not generic diff fluency**: OpenAI
  describes V4A as a grammar their models were specifically trained to
  produce, and designed the line arithmetic *out* rather than reuse unified
  diff. The decisive evidence is how the one cross-model harness gates it —
  opencode's registry enables `apply_patch` only for `gpt-` models that are
  neither `gpt-4` nor `oss`, and *removes* `edit`/`write` when it does, so
  Claude, Grok, Qwen and local models never see it. **`gpt-oss` is excluded
  too**: OpenAI's own open-weights models don't get the format OpenAI
  trained — a harness author's empirical judgment, and the most relevant
  data point there is for a local-first project. grok-build agrees
  implicitly, filing its port under a namespace literally called `codex`
  rather than making it Grok's default.
- **A unified diff.** `@@ -145,7 +145,9 @@` is line *arithmetic*, which
  small models are bad at in the way they are bad at arithmetic generally.
  Note this is the *only* arm the "fuzz cascade" objection in {Pikuri::Workspace::Edit}
  applies to — a context-anchored envelope fails on an unmatched anchor,
  exactly like `old_string`, and is no fuzzier.
- **Line-range replace (`start_line` / `end_line`, no `old_string`).** The
  only arm that genuinely drops payload, and `Read` already emits `cat -n`
  numbering so the anchors are free. Rejected on two counts: staleness —
  `Edit` deliberately keeps a path marked read after a write, so numbers
  drift silently — and it forfeits the implicit read-check, letting a
  hallucinated range silently destroy real code where a wrong `old_string`
  merely fails.

**Consequences.**

- **The uniqueness escape lives in the error string.** `edit`'s multi-match
  refusal leads with `Set occurrence=N` before the paste-more-context
  advice; that observation is where the model actually learns the parameter
  exists, so it must not be reworded back into a bare "add more context".
- **The rename gap (a) is untouched and still open.** A word-boundary
  `replace_all` was never part of this fork. `sed` via `bash` is *not* the
  fallback: it escapes both the read-before-edit gate and the `ReadOnly`
  gate (plan mode covers Write/Edit, not bash), so routing renames through
  the shell routes them around the posture.
- **One thing the field cannot tell us, recorded so nobody re-derives it as
  new.** All four harnesses target models with reliable *parallel* tool
  calls, which is what makes N single-hunk edits cost one turn. If pikuri's
  local default emits one tool call per turn, N edits become N sequential
  round-trips — and on local hardware prompt processing, not generation, is
  the expensive part. Nobody in the field is local-first, so 0-for-4 does
  not test this. It did not change the decision (an unused tool costs schema
  tokens on every turn, and the measurement has never been taken), but it is
  the one hypothesis that could reopen it.
- **Revisit only with a measurement**, in this order: does the default local
  model emit parallel tool calls; would it reach for a batch tool unprompted
  if given one. If payload size rather than call count ever becomes the
  problem, the prior art to read first is grok-build's `hashline` family
  (`anchor.rs`, `scheme.rs`, `benchmark.rs`) — line-range replace with the
  staleness hole closed by per-line hashes. It closes that hole by
  *fingerprint*, not equality, so it trades in a small silent wrong-edit
  window that `old_string` doesn't have; `COMPARISON.md` works the numbers.

---

## D-keep-calculator — The unconfirmed arithmetic path, kept even where bash exists (2026-08-15)

**Status:** Accepted; no code change. `calculator` stays wired in all ten
`bin/pikuri-*` demos. `ideas/feedback.txt` item 6 is cut with this entry.

**Context.** Grok 4.6, reviewing a coding-agent wiring: *"`calculator` is a
smell. If the model can't add, a tool won't save it; if it can, bash/python
already exist. I'd drop it."* Neither Claude Code nor opencode ships a
calculator, so the instinct has company. Both halves of the argument turn out
to be properties of the harness Grok was speaking from rather than of the tool.

**Decision.** Keep it, everywhere — including the three wirings that do have a
shell.

**Alternatives rejected.**

- **Drop it from `pikuri-core` outright.** Ten bins wire `CALCULATOR`; only
  three (`pikuri-code`, `pikuri-os`, `pikuri-computer`) wire a `bash`. In the
  other seven — `pikuri-chat`, `pikuri-thunderbird`, `pikuri-memory`,
  `pikuri-corpus`, `pikuri-minions`, `pikuri-openlibrary`, `pikuri-assistant` —
  "bash/python already exist" is simply false, and there is no fallback at all:
  a mail agent totalling invoice amounts, `LIBRARIAN` computing a percentage
  over corpus hits. This is `D-directory-listing`'s asymmetry again, and the
  same one-liner settles it: **Claude Code and opencode are single binaries
  that always have bash; pikuri is a set of gems that frequently isn't wired
  with one.** Composability is the product, so pikuri can't assume the shell.
- **Drop it only from the three bash-carrying wirings** — the narrower move,
  and the one that looks right until you read the confirmer. Three arms, in
  order of weight.
  (1) *An interpreter can never be allowlisted.* `python3`, `bc`, `awk` and
  `expr` are absent from `Bash::PassiveCommandDetector::PASSIVE_BINARIES` and
  must stay absent — pre-approving an interpreter is pre-approving arbitrary
  code execution, which is the one thing the detector exists to stop. So the
  modal prompt on `python3 -c '17.5 * 3'` is permanent by construction, not a
  gap someone patches later.
  (2) *The unconfirmed shell arithmetic is integer-only.* `echo` **is** passive,
  so `echo $((7 * 3))` costs no prompt — but `$((7/2))` is `3`. Anything with a
  decimal point isn't expressible without reaching for (1).
  (3) *Confirmation prompts are a budget, spent from the human's attention.*
  Routing every average-of-three-numbers through a `python3 -c` prompt trains
  reflex-approval on the single most dangerous binary in the set, for the most
  harmless possible reason. Keeping arithmetic off the prompt stream is what
  leaves `python3 -c` rare enough to be worth reading. Nothing is traded for
  it: `CALCULATOR.trifecta_legs` is `TrifectaLegs::NONE`, so the unconfirmed
  path grants no capability to abuse.
- **Accept "if it can add, drop the tool."** The premise is model-specific and
  pikuri's default contradicts it: the book's first conversation runs
  `unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M` — a 4-bit-quantized MoE with ~3B active
  parameters — not a frontier model. And the failure mode was never "can't
  add"; it's digit-level unreliability on long multiplication and floats, which
  is exactly what a deterministic evaluator fixes. Privacy-first-by-default
  makes this tool *more* load-bearing here than in a cloud-only coding agent,
  not less.

**Consequences.**

- **The recurring cost is one tool schema per wiring, and nothing else.** The
  implementation is ~100 hand-rolled lines with no gem closure (dropping
  dentaku took concurrent-ruby, bigdecimal and tsort with it) and no trifecta
  leg. Grok's separate complaint about the heavy static prefix is real, but
  it's a per-wiring budget question — answered by unwiring tools a *given*
  binary doesn't need, not by deleting one from core.
- **It stays the teaching spine of the first chapter.** `book/chat.md` uses it
  as the first tool call a reader ever sees, `Pikuri::Testing`'s yardoc
  examples are built on it, and `bundled_legs_spec.rb` uses it as the canonical
  zero-leg tool that keeps the trifecta advisory quiet. Dropping it would
  re-spine all three around a tool that has legs — a worse first example, to
  satisfy a critique aimed at a different wiring.
- **Revisit only if** a wiring ever gains an unconfirmed float-capable
  evaluator. By arm (1) that can't be an interpreter, so in practice it would
  have to be this tool under another name.

---

## D-walked-path-denylist — Two layers, and the cheap one is never the guarantee (2026-08-15)

**Status:** Accepted, shipped. `Filesystem#denied?` plus `rg --glob` pruning
across `Listing` / `Search::Glob` / `Search::Grep`.

**Context.** `AllowAll`'s credential denylist (`~/.ssh`, `~/.aws`, …,
`/etc/shadow`) was enforced in exactly one place: `resolve_for_read` /
`resolve_for_write`. Those only ever see a path the **model supplied**. A path
a tool **walked** to on its own reaches no `resolve_` call — so, measured
against a synthetic home:

| call | before |
|---|---|
| `read .ssh/id_rsa` | refused |
| `glob '**/*'` | listed `.ssh/id_rsa` |
| `grep 'PRIVATE KEY'` | **returned the key's contents** |

Adding `file_list` would have made a third leak (it enumerated the key
filenames at depth 2), which is how the gap surfaced. `pikuri-code --yolo`'s
own comment claimed "every path resolves except those under the credential
denylist" — false for two of its own tools.

**Decision.** Two layers, with an explicit ordering of trust:

1. **`Filesystem#denied?` on every walked result** — the guarantee. Base
   `Filesystem` returns `false` (a scoped workspace contains by its
   readable/writable ceiling instead); `AllowAll` symlink-resolves the
   candidate and tests containment against the same denylist
   `resolve_unrestricted` uses.
2. **`rg --glob '!<rel>'` pruning** via `Filesystem#denied_roots` — an
   optimization, so rg never walks a subtree whose results would be discarded.

**Layer 2 is never load-bearing**, and that is the point of writing it down: it
goes silently partial whenever a denied root sits outside the search root, and
an rg flag change could weaken it with no test going red. A spec runs `glob`
and `grep` with the pruning stubbed out to pin that layer 1 alone still holds.

**Alternatives rejected.**

- **Pruning alone (layer 2 only).** The tempting "just exclude it from rg"
  fix. Rejected on the failure mode, not the coverage: an optimization that
  quietly stops working leaves no trace, whereas a filter on the data path
  fails closed. The rejected-lines spec exists to keep this honest.
- **A cheap lexical prefix test instead of symlink resolution.** Sound for the
  rg tools specifically — neither passes `-L`, so rg never follows a symlink
  and its paths are always real. Rejected anyway: `Listing` *does* follow
  symlinks (`File.directory?`), so a `decoy → ~/.ssh` inside the workspace
  would be descended into. Two strengths of the same predicate is a subtle
  thing to get wrong for a saving nobody has measured — realpath is
  microseconds, and layer 2 keeps the volume small. The rg-symlink fact is
  recorded as grounds to weaken it later *under profiling*, not now.
- **Silently omitting denied entries from `file_list`.** Rejected: that tool
  answers *"what is here"*, where an omission is a lie the model burns turns
  re-probing. `~/.ssh` existing is not the secret; its filenames and bytes
  are — so the row shows `[denied]`, matching what `read` already says out
  loud. `glob`/`grep` answer *"what matches"*, where a non-match is not a lie,
  so they omit silently. The asymmetry is the question each tool answers, not
  inconsistency.
- **Scoping the denylist to reads and documenting listing/searching as out of
  scope.** Not defensible while `grep` returned key material.

**Consequences.**

- **`Listing.render` takes `filesystem:` as a required keyword.** No default.
  An optional "nothing is denied" default is precisely how a new caller leaks
  by forgetting, and this is the seam a future path-walking tool will copy.
- **The `denylist: []` hosts are untouched.** `pikuri-os`, `pikuri-computer`
  and `pikuri-tui-computer` pass an empty denylist deliberately (their `bash`
  sees the whole disk under `FullFsNoNet`, so half a floor is theater), so
  `denied?` short-circuits to `false` and they pay nothing. This fix does not
  quietly re-close a door someone opened on purpose — a spec pins that too.
- **The grep filter may over-match.** It drops any output line starting with a
  denied relative prefix rather than parsing where the path ends (a filename
  containing `:` makes that ambiguous), so a `.netrc.bak` line goes too.
  Over-filtering is the safe direction for a credential guard.
- **Documented in `SECURITY.md` rather than quietly fixed.** pikuri is alpha
  and rarely deployed; naming the hole and the exposure window costs less than
  the doc-debt of a defense that was advertised before it worked.

---

## D-bundle-trust-grading — Trust is per search base, and the workspace is not asked (2026-08-16)

**Status:** Accepted, fully shipped: `Bundle::Base`,
`Catalog#untrusted_level`, `SkillTool` consuming it, and the third boot
question in `bin/pikuri-code`. The record lives in the shared `Pikuri::Bundle`
namespace rather than under `Catalog` because slash commands
(`D-slash-commands`) grade the same way from the same bases: duplicating it
would have a host build two parallel arrays out of one pair of booleans, and
handing `Command::Registry` a `Skill::Catalog::Base` would read as a command
being a kind of skill. `ideas/bundle-trust-grading.md` is deleted with
this entry; its one open thread moved to `ideas/security-open-questions.md`.

**Context.** {Pikuri::Skill::SkillTool} declared `untrusted: :hard`
unconditionally, with a comment naming the gap: "the tool cannot tell a
hand-written skill from a downloaded `.agents/` bundle." Meanwhile
{Pikuri::Workspace::Filesystem#trusted?} lets `read` answer exactly that
question for the file tools — and `.pikuri/skills/` lives *under the project
root*, so one workspace could report `:none` for `read` and `:hard` for
`skill` on the same file. The argument that collapses it is that a `SKILL.md`
body is prose: Markdown rendered into the model's context verbatim, no added
privilege, indistinguishable from a README the model `read`. An executable
sidecar is the *other* axis — it runs only through bash, where the sandbox and
confirmer gate it.

Nothing here is a defense. `untrusted` is read by {Pikuri::Trifecta::Report}
and nothing else, and the detector never blocks; this only changes what a boot
banner prints, in the *quieter* direction. The reason to do it anyway is the
one `Pikuri::Trifecta`'s own header names: a false alarm is what gets an
advisory muted, and an agent printing three legs when it holds two teaches its
operator the map is wrong.

**Decision.** Trust is declared **per search base** —
`Bundle::Base = Data.define(:dir, :trusted)`, unioned at scan time into one
`#untrusted_level` — and the host answers it with a value, never by handing the
catalog a `Filesystem`.

Two properties carry the design. **The union is over skills actually
*stored***, counted at the point a skill wins its name: one unvouched skill
takes the whole catalog to `:hard` (the tool declares its legs once), but a
base that is empty, absent, or whose skills all lost a collision costs
nothing. That is what lets a host wire `Dir.home` untrusted unconditionally —
it cannot know what a marketplace plugin left in `~/.claude/skills` — and still
report `:none` for the user who has none.

**And a base's trust is a claim about *that root*, not about "the repo".** This
is what stops the obvious simplification below from being right, and
`bin/pikuri-code` is the proof: `Code::ToolchainPaths.readable` puts
`~/.m2/repository` and `~/.cargo/registry` in the workspace's reachable set
permanently, so `Filesystem(trusted: true)` can never be honest there no matter
what the user answers. Its new prompt therefore feeds the catalog and nothing
else. `read` really can reach somebody else's bytes and its `:hard` is correct;
the catalog reached `.pikuri/skills` under this root and nothing else, and its
`:none` is correct too. Same question, two reachable sets, two honest answers.

**Alternatives rejected.**

- **Keep the unconditional `:hard`.** Rejected: it over-warns exactly the
  operator who did the work to deserve a quiet banner, and an ignored smoke
  alarm is the failure mode {Pikuri::Trifecta}'s own header names.
- **Spend one repo-trust boolean on both the workspace and the catalog.** The
  tempting simplification, since both are "is this repo mine?". Rejected: the
  two objects reach different bytes, so a single boolean forces a lie in
  whichever direction it is set — `true` claims `pikuri-code`'s `read` is safe
  over `~/.cargo`, `false` reports the user's own hand-written skills as
  attacker-authored. The fact is shared; the value each object needs is not.
- **Derive it — have the catalog inspect a `Filesystem`.** Rejected twice
  over. `pikuri-skills` depends on `pikuri-core` only, so it would invert the
  dependency to answer a question the host can answer in one kwarg; and
  `bin/pikuri-code` builds the catalog *before* the filesystem, because the
  filesystem needs `skill_catalog.roots` in `readable:`, so `filesystem.trusted?`
  is not even in scope at the call site.
- **One catalog-wide flag instead of per-base.** Rejected: the project root and
  the home skill dirs earn their trust by different arguments — one is a claim
  the user makes about bytes they may not have read, the other a property of
  the wiring (nothing but the user can write there) — and they are answered at
  different times, the first by a prompt and the second by two flags. One
  boolean cannot carry both. The union then covers the case neither can: a base
  that stores nothing costs nothing, which only the catalog is in a position to
  know.
- **Defaulting `~/.claude/skills` to trusted in the *library*.** Rejected while
  accepting the argument for it: `pikuri-skills` is wired by hosts that are not
  a personal dev tool, and it cannot verify that a host keeps skill roots out
  of `writable:` the way `pikuri-code` does. Silence keeps buying the
  pessimistic value; a host that can rule out writes says so in one kwarg.
- **Per subdir rather than per base** — grading `.pikuri/skills` apart from
  `.agents/skills` under one root. Rejected as unrepresentable: `trusted?` is
  all-or-nothing over a root, so splitting them recreates the same-bytes
  asymmetry this entry exists to remove. The worry that `.agents/skills` is
  where a foreign bundle lands is real, and it is an argument about the *home*
  base.
- **A `--trusted` flag rather than a boot question.** Rejected by the author.
  The counter-case is real — forgetting a flag fails *loud*, so its absence is
  safe — but a `bin/` script is illustrative, and a flag nobody types is an
  axis nobody meets.

**Consequences.**

- **A bare path in `search_bases:` still works and means `trusted: false`**, so
  every existing call site stays correct and the unsafe value is the one you
  get by saying nothing. The abstract `Catalog` defaults to `:hard` for the same
  reason; `Catalog::Empty` returns `:none`, which is not a special case but the
  union over zero skills.
- **`bin/pikuri-code` now asks three trust questions**, and they are genuinely
  three: sensitive bytes (`private_repo`), user-authored bytes (the new one),
  and whether a hostile `.gitattributes` may *execute code* (`trusted_repo`).
  Reusing the last for the second would claim `vendor/` is your own work on the
  strength of you controlling `.git/config`.
- **It vouches for `Dir.home` without asking, on a property rather than a
  guess.** Skill roots ride in the workspace's `readable:` and never its
  `writable:`, so `write`/`edit` refuse them and sandboxed bash gets them as
  *ephemeral overlays* whose writes vanish at exit; unsandboxed bash still
  confirms every command. The agent therefore has no way to put a skill in
  `~/.claude/skills`, which is the whole content of the claim — and if it did,
  the self-poisoning loop it would open is the failure pikuri exists to
  prevent, not a banner nuance. The flag is `sandbox_enabled ||
  confirm_enabled`, because `--yolo` (and `--no-sandbox --no-confirm`) is
  exactly the mode where both guards are off and that write becomes real. Note
  this vouches for the *skill dirs*, not for `$HOME`: `~/Downloads` and a mail
  store are why the home directory as a whole is not trusted.
- **What moves in that binary is the map, not the verdict.** `read` and `bash`
  keep the untrusted leg, so it stays `[TRIFECTA: HARD]`; what changes is that
  `skill` leaves the `untrusted(…)` attribution and its own line reads `[]`. A
  host that moves the *verdict* is one whose readable set is the project root
  alone. `pikuri-code/spec/pikuri/code/dry_run_spec.rb` therefore wires no
  `SkillTool` — no answer can move a row there — and says so.
- **Commands adopt this channel rather than inventing one** — a command file
  is prose on the same terms a skill body is, so `Command::Registry` takes the
  same bases and unions the same flag, and `bin/pikuri-code` reuses the same
  two answers (its home vouch covers `~/.claude/commands` for the same reason
  it covers `~/.claude/skills`: the roots ride in `readable:`, never
  `writable:`). One rule does not carry over: a *refused* command never taints,
  because its bytes cannot reach the context at all.
- **Left open:** folding home skill roots into a workspace's `readable:` while
  declaring that workspace trusted is the vouched-for-island problem arriving
  through the back door — `Filesystem` raises on `AllowAll` + `trusted:` for
  the same reason. `pikuri-code` cannot reach it (its workspace is untrusted
  regardless), so it binds the first host whose readable set is the project
  root. See `ideas/security-open-questions.md`.

---

## D-directory-listing — Directories are not glob's job, and `read` self-heals (2026-08-15)

**Status:** Accepted, fully shipped: `Workspace::Listing`, `read`'s recovering
refusal, the `file_list` tool, and the depth-1 boot snapshot on
`Workspace::Extension`. `ideas/directory-listing.md` is deleted with this
entry, and `ideas/feedback.txt` item 1 is cut.

**Context.** Grok 4.6, reviewing a coding-agent wiring, opened where every
model opens — orienting in the repo — and reported: *"`glob *` gave me ten
root files and no tree."* It was right. `glob` is built on `rg --files`, and
**`rg --files` emits files only**: at this repo's root `glob '*'` returned 15
files and hid all 18 directories, including every one of the fifteen
`pikuri-*` gems. A model orienting here concludes pikuri is a docs repo.
There is no glob pattern that reveals a directory exists; the only workaround
is `glob '**/*'`, which dumps every file, mtime-scrambled and head-truncated.

Worse, `read` on a directory *sent the model there*: `"is a directory; use
the glob tool to list files."` Grok followed that instruction and correctly
concluded the primitive was wrong.

**Decision.** One renderer, {Pikuri::Workspace::Listing}, built on
`Dir.children`. `read` on a directory refuses *and hands back the depth-1
listing* — and says nothing about it in its description.

**Alternatives rejected.**

- **Teach `glob` about directories.** Three reasons, in order of weight.
  (1) *mtime sort on directories is actively misleading* — measured at this
  repo's root, 12 of the top 13 entries by mtime are directories, `.git` at
  #2, because a directory's mtime bumps when a child is added or removed, not
  edited. Directories would colonise the top of every result, and
  mtime-descending is glob's stated unique capability. (2) *A matched
  directory is a dead end* — the model gets `lib/` in a list and cannot
  `read` it; its only follow-up is another `glob`. (3) `rg --files` can't
  emit directories at all. A `depth:` parameter is separately a non-starter:
  depth is already expressible in the pattern (`*`, `*/*`, `**/*`), and
  `pattern: "**/*", depth: 1` has no defensible answer.
- **Just tell the model to run `bash ls`** — what Claude Code does, and
  verified frictionless here (`ls` is in `PASSIVE_BINARIES`, so it
  pre-approves with no prompt in both `pikuri-code` and `pikuri-os`).
  Rejected decisively because **`FILE_MINER` has no bash, by design**: the
  recon sub-agent whose entire job is orienting in an unfamiliar tree would
  be the one agent that can never list a directory, and granting it bash to
  fix that deletes the documented no-shell-for-`curl` property. Two
  supporting reasons: `pikuri-workspace` depends on `pikuri-core` only, so a
  host wiring the file tools without the coding gem would have no way to see
  a directory — the lower gem's completeness hanging on a gem above it; and
  `Bash` takes the bare `Filesystem`, not the `Workspace` composite, so
  `bash ls` bypasses `resolve_for_read` and routes orientation through
  `ReadOnly`'s one admitted hole. **The asymmetry in one line: Claude Code is
  one binary that always has bash; `pikuri-workspace` is a gem that
  frequently isn't wired with one.** Composability is pikuri's product, so
  pikuri can't assume the shell.
- **`read` lists directories as a *documented* capability**, opencode-style
  (*"Read a file **or directory** from the local filesystem"*). Rejected:
  `read` would then have two behaviours keyed on path type — structurally the
  same objection used against overloading `glob`. It's a weaker objection
  here ("read" is a generic verb, "glob" names a mechanism), which is exactly
  why the *undocumented recovery path* survives while the documented one
  doesn't. Teaching two ways to list hands the model a
  two-tools-no-criterion coin flip; teaching one and rescuing the other costs
  zero schema and zero prompt bytes.
- **Derive directories from `rg --files` output by path prefix.** Tempting —
  gitignore correctness and child counts fall out of one call — but there a
  directory exists only if some *file* under it survived rg, so symlinked
  directories, directories holding only gitignored files, and empty
  directories all vanish. `Dir.children` is correct on all three and needs no
  subprocess. (This was held open as *tolerable for a boot snapshot* until the
  snapshot chose depth 1 — see below — at which point gitignore stopped
  mattering and the second walker died with it.)

**The boot snapshot is depth 1** (2026-08-15, the second half of this
decision). `Workspace::Extension` contributes a `<workspace_snapshot>`
system-prompt snippet — one `Listing` of the root, one level deep,
unconditional, capped at 2 KB, allowed to go stale. ~325 tokens at this repo's
root; ~90 at the median project.

Measured with the shipped renderer over 45 projects in `~/work/my`, plus a real
`$HOME`. Depth 1 fits 1 KB on **45/45** (median 312 B, max 906 B — this repo).
Depth 2's median is 772 B but its max is 24.7 KB, and the shape of that spread
is the whole argument: **depth 2 is expensive exactly where it is informative,
and uninformative exactly where it is cheap.** `Listing`'s `[N dirs, M files]`
column already does its job on wide-flat directories — a Jekyll blog's
`_posts/  [0 dirs, 256 files]` is 30 bytes against 24 KB for the expansion, and
says more — while the repos where depth 2 costs only 2× are the ones with
conventional layouts, so it buys `src/` and `build/`.

Rejected, all of them consequences of wanting a second level:

- **Depth 2 with an auto-degrade ladder** (2 → 1 → omit, against a byte
  budget). The ladder is ~one line of code, so the objection isn't cost: it is
  that the snippet's shape then varies silently by repo, and the model cannot
  tell which depth it got. Depth 1 is one shape, always.
- **A dirs-only or files-at-top-level-only walker**, to make depth 2 affordable
  (~540 B here vs 1,900 B). A second rendering mode in `Listing` to buy a level
  that measurement says isn't worth having.
- **Keeping the `rg --files` prefix derivation for the snapshot**, on the
  grounds that a boot budget can't afford to render `node_modules/`. True at
  depth 2, where it eats the whole allowance; at depth 1 it is *one row*, and
  an informative one. Dropping it is what leaves the gem with one walker.
- **A `root == Dir.home` special case.** It was a proxy for a budget test, and
  wrong in both directions — a tidy `$HOME` renders in 1,438 B and is genuinely
  useful to an OS-helper agent; `~/work/my/pikuri` is a repo. `$HOME` at depth
  1 clears the cap, so nothing needs the special case. (Narrower still than it
  looked: `Filesystem::Restricted` *refuses* a `/home/*` project root outright,
  so only the `AllowAll` hosts can be rooted there at all.)
- **A constructor flag, default off, on in `pikuri-code`.** At ~90 tokens
  median it is cheap enough to be unconditional, and a flag is a thing a host
  forgets to set. The premise: if a harness wires the workspace, it wants to
  work with those files.
- **Head-truncating an over-budget snapshot.** A truncated listing is an
  alphabetical prefix — it teaches the model that `spec/` does not exist. Over
  the cap the snippet degrades to a single line naming the root; an empty root
  likewise says so, because a blank block reads as a failed walk. A root that
  can't be *opened* is the one case left unhandled: it raises out of
  `Agent.new`, costs zero lines, and is a wiring bug every file tool is about
  to hit anyway.
- **`Control::Interloper` instead of a prompt snippet**, guessed to be the
  cheaper answer to staleness. It is the more expensive one: a snippet is a
  stable prefix, while a re-injected `kind: :system` item appends a message
  every time, growing history and busting the prompt cache. Drift is bounded
  without any mechanism — `Agent#assemble_system_prompt` re-pulls snippets on
  `clear_conversation`, so the snapshot re-takes itself on `/clear`.

**Consequences.**

- **The snippet may name `file_list`**, against `CLAUDE.md`'s "no tool names in
  a main/binary system prompt". That rule's target is prompt-vs-wiring drift,
  and a snippet contributed by the extension that *registers* the tool
  structurally can't drift — the `Tasks::Extension` /
  `SubAgentTool.available_agents_snippet` precedent.
- **`FILE_MINER` never sees the snapshot.** `SubAgentTool` selects tool
  *instances* by name and wires no extensions, so no snippet reaches a
  sub-agent. Mitigated ahead of it: both recon personas already open with a
  `file_list`.
- **Nothing evaluates `.gitignore` any more.** Without rg, the listing shows
  everything except `.git/` (matching Glob's hard exclusion) — so this is the
  one file-tool surface that diverges from Grep/Glob on gitignore. Accepted:
  `ls` doesn't respect gitignore either, and "`build/` exists" is orientation
  signal rather than noise. Revisit only if the noise proves real.
- **`Search::Utils.child_listing` is gone**, and with it its prose
  `'OS error listing immediate children'` fallback. The oversized-root
  refusal now renders through `Listing`, so it gained the size / child-count
  columns and a byte cap it never had. Per-row failures print the errno class
  (`[Errno::EACCES]`, `[Errno::ELOOP]`) rather than a prose word or Glob's
  `0.0` fallback — same code, strictly more information, and each errno
  implies a different follow-up.
- **`read` must never mark the read ledger for a directory.** Free today (the
  refusal returns before `mark_read`), but exactly the kind of thing a
  refactor breaks silently, so it's pinned by a spec.
- **The tool is `file_list`, and the file tools are not renamed.** Enumerating
  the shipped tool names surfaced pikuri's unwritten convention, already
  consistent: a prefix marks a *family sharing one backing resource*
  (`task_*`, `thunderbird_*`, `vectordb_*`, `fileindex_*`, `web_*`, `git_*`),
  while a *universal singleton verb goes bare* (`read`, `write`, `edit`,
  `grep`, `glob`, `bash`, `fetch`, `skill`, `recall`, `agent`, `calculator`).
  Rejected: a `file_read` / `file_write` sweep over the siblings — it spends
  the most in-distribution tool names in existence for nothing semantic, is a
  breaking change to every host's persona `tool_names:`, and makes pikuri the
  one row that doesn't line up in `COMPARISON.md`'s parity table. So why
  prefix *this* one? Not collision — grammar. `read`/`write`/`edit` are
  transitive verbs with an implied object convention supplies ("a file");
  `list` has none, and "list *what*?" is live in a wiring that also carries
  tasks, MCP servers and skills. Also rejected: `ls`, whose precise
  behavioural prior (flags, columns, `-la`) makes every divergence from real
  `ls` a trap; and `file_tree`, because **the name must track the default
  depth** — "tree" promises hierarchy and depth 1 delivers a flat listing.
  The convention itself now lives in `CLAUDE.md`'s Conventions.
- **`depth` caps rather than refuses.** Over `Listing::MAX_DEPTH` clamps down
  (the answer is still the one asked for, just shallower); below 1 is an
  error, mirroring `read`'s `offset` / `limit` guards.
- **Both recon personas take it, with no new trifecta leg.** `FILE_MINER` and
  `GIT_REPO_RESEARCHER` orient in trees they have never seen, which is the
  whole case for the tool; listing grants no *action*, so the no-tool-to-act-on-
  an-injection property is untouched. The `file_list` first move is in their
  persona prompts — the sanctioned carve-out that may name its own tools.
- **"Five file tools" is gone from the docs.** Adding a sixth made the count
  wrong in 15 places at once; it collapses to "file tools", which can't go
  stale the next time one lands.
- **One walker, one formatter.** `Listing`'s `Dir.children` walk serves both
  `file_list` and the boot snapshot. The work started from a "one listing
  formatter, not two" rule and, having briefly owed a second *walker* to the
  snapshot's gitignore needs, ends up owing neither.

---

## D-no-static-poisoned-flag — No declared `poisoned:` on a node (2026-08-12)

**Status:** Accepted (won't build); no code change. Closes the last open
question in `ideas/trifecta-detector.md`, which is deleted with this entry —
the detector's homes are {Pikuri::Trifecta} and `book/trifecta-detector.md`.

**Context.** Propagation grades every parent as drivable: whatever it is
told, it will faithfully relay or launder. Right for `pikuri-computer`, whose
root reads attacker-authored mail on day one; pessimistic for a topology
built to keep the root pristine, where untrusted content reaches it only as
sub-agent summaries (the federation sketched in `ideas/assistant.md`). A
per-node `poisoned: true|false` was floated so the two analyses could differ.

**Decision.** No such field. It is redundant, and the direction it exists to
enable is the harmful one.

**It is already computed.** A node's untrusted *strength* is the
poisoned-capable answer: hard `:untrusted` means the node reads attacker
content directly, `:weakened` means it arrives through a summarizing
delegation boundary — which is exactly what
{Pikuri::Tool::TrifectaLegs#relabel_inbound} encodes as content crosses that
boundary. A declared flag would restate a derived value, and the two would
drift the first time a
wiring changed without the declaration being revisited.

**And `poisoned: false` would silence a true alarm.** Egress propagates up at
full strength *because* a parent is assumed drivable — the laundering
channel: a poisoned parent needs no egress tool of its own, it puts the
secret into a sub-agent's task string and asks the egress-holder to send it.
A human asserting a parent stays clean turns that assumption off by hand, and
that is precisely the assertion that outlives the refactor which falsifies
it. A detector whose alarms can be declared away is a detector nobody trusts.

**Alternatives rejected.**

- **A raise-only flag (`poisoned: true` permitted, `false` not).** Safe by
  construction, and therefore pointless: hard `:untrusted` already raises,
  and the one thing left to express — a node poisoned through a channel the
  detector cannot see — is the unknowable input the detector already declines
  to grade.
- **Keeping the question open pending a scenario hunt.** The open note asked
  for a topology the lattice cannot express. The only candidate it ever named,
  the pristine-parent federation, maps cleanly onto `:weakened`; no second
  candidate was produced in the time the question sat open. Leaving it parked
  would keep inviting a rediscovery of the same redundancy.

**Consequences.**

- **The soft/loud untrusted split *is* the poisoned-vs-pristine answer**, so
  the way to make a parent read pristine is structural — put a summarizing
  boundary in front of it — never declarative. Same shape as the trusted
  island rule: change the wiring, not the label.
- **The runtime question is a different one, and stays open elsewhere.**
  Whether an agent has *now* read untrusted content is observed rather than
  declared, needs no declaration to be trustworthy, and is worth showing in
  the UI. It rides `ideas/private-context-taint.md`'s per-context flag as the
  display half of that mechanism. The narrower "poisoned *right now*" alarm
  on LLM-*authored* bytes remains `ideas/injection-tripwire.md`'s.

---

## D-write-custody-axis — No synced-folder egress axis on writes (2026-08-12)

**Status:** Accepted (won't build); no code change. The gap it leaves is
stated at {Pikuri::Workspace::Write}'s `trifecta_legs:` declaration site and
named in `book/trifecta-detector.md` §"The edges, stated plainly" — neither
is a to-do any more.

**Context.** `Write` and `Edit` ship {Pikuri::Tool::TrifectaLegs::NONE}: a
local write is not an external sink, and the observation reports an outcome
rather than the file's bytes. But a workspace root that *replicates* — a
`~/Dropbox`, a Nextcloud folder, a team Drive — plausibly turns a write into
egress, and nothing declares it. The gap sat parked as the "custody
question" through `D-egress-axis-shape`, which cited it as a reason not to
name the destination axis `egress_target_server`. Two findings close it.

**Decision.** No custody axis, no synced-folder declaration. Writes keep
`NONE`, and the under-warn is documented rather than fixed.

First, **the design space collapsed**. The intuition that a synced write
looked like `:tool_vouched` — the destination is a party the attacker
doesn't control — *but somehow safer* was real, and mislocated:
`egress_destination` grades whether the attacker can read the bytes back,
while the property separating these cases is custody — **does the recipient
differ from the data's owner?** A personal cloud sync doesn't change
custody: same account, different hardware, and an attacker gains nothing
without separately compromising that account. So it is not a weaker egress
leg, it is **no leg at all**. A shared folder or public link changes custody
exactly as a mail recipient does — humans read it, the bytes persist — so it
is plain `:attacker_reachable`. Both ends land on values that already exist
and the middle is empty, so no new lattice level was ever at stake.

And **the sync this project's users actually run is the off-axis one.** A
privacy-conscious user replicates with self-hosted Syncthing or Nextcloud —
between machines *they* own, one owner end to end, no third party in the
path at all. The shape that would need a leg is a corporate or public share,
i.e. precisely what that audience deliberately doesn't run. So the axis
would be built for a population inverse to the actual one.

Second, **what was left is a knob that mostly echoes its own input.** The
property is invisible to the framework, exactly as
{Pikuri::Workspace::Filesystem#private?} is, so it could only be
user-declared — and the reachable-set rule bites: a vouch counts only for a
tool's *entire* reachable set, so "a shared folder somewhere under this root"
means the leg is present. Since `~/Dropbox` routinely holds private and shared
subtrees at once, the honest tag for the realistic layout is leg-present
regardless of what the user knows about any one subfolder.

And it isn't a dead end, which is what makes won't-build cheap: a host that
knows its workspace replicates to someone other than its owner can add the
leg **today**, with a five-line
{Pikuri::Agent::Extension#trifecta_contribution} returning a
{Pikuri::Trifecta::Contribution} carrying egress legs. Contribution legs are
additive, so that can only ever harden a verdict.

**Alternatives rejected.**

- **A four-value declaration** (local / private cloud / shared cloud / git),
  the shape first floated. Collapses to a binary the moment custody is the
  test, and then to nothing once each end lands on an existing value.
- **A new rung between `:tool_vouched` and `:attacker_reachable`** for the
  "one step safer" feeling. Rejected: the feeling was custody, not
  readability, and grading it on the readability axis would put a
  *not-a-leg* case above the bottom rung — the same error
  `D-egress-axis-shape` rejected for `egress_human_author`.
- **Putting git on the axis.** A write into a working tree egresses nothing;
  a `push` does, and a push is `bash`, already tagged from the sandbox. What
  makes the Dropbox case interesting is that replication is **ambient** — no
  further agent action. A sink needing a deliberate second capability is
  already covered by that capability.
- **Auto-detecting the sink** — probing for a `.dropbox` marker,
  `~/.config/syncthing`, or reading the mount table / `st_dev`. Rejected as
  unsound in the direction that decides the verdict: no marker distinguishes
  a private subfolder from a team share, which is the only distinction that
  matters here. A heuristic that mislabels is worse than a documented
  silence in a detector whose whole credibility rests on a tag meaning what
  it says.
- **Shipping the knob anyway, since it's cheap.** Rejected on the
  axis-with-no-consumer rule `D-trifecta-map-orphans` applied to
  `Report#unreachable_tools`: no wiring in this repo points a workspace at a
  synced folder, so it would change no verdict today, and the day one does,
  the contribution hook already covers it without a core axis.

**Consequences.**

- **A synced-workspace wiring reads clean, permanently and on purpose.**
  This is one of the named under-warns, alongside a single tool that is all
  three legs internally and private data staged through a file. Smoke alarm,
  not firewall.
- **Custody survives as teaching, not machinery.** It is why a search query
  and a Dropbox write get opposite answers despite both being "bytes to a
  third party", and it is the argument that keeps the empty middle rung from
  being relitigated.
- **The reversal trigger is a shipped wiring, not a report that one is
  possible** — and even then it starts host-side as a
  `trifecta_contribution`, becoming a core axis only if several hosts write
  the same five lines.

---

## D-trifecta-map-orphans — A tool nothing can call gets no line on the map (2026-08-12)

**Status:** Accepted; no code change — the silence is what
{Pikuri::Trifecta.build} already produces, now pinned by
`pikuri-core/spec/pikuri/trifecta_build_spec.rb`.

**Context.** {Pikuri::Code::Extension} registers `git_clone` on the
sub-agent-only pool unconditionally, solely for the `GIT_REPO_RESEARCHER`
persona. {Pikuri::Os::Extension} composes that extension but wires no such
persona, so in both OS binaries the tool is registered and named by nobody:
the root node takes `agent.tools` only, each sub-agent node takes its
persona's `tool_names`, and `git_clone` lands in neither. It appears nowhere
on the map. The question that raised: the map doubles as a wiring audit, and
here it had surfaced a shipped-but-unreachable capability — should it *say*
so, with a trailing `(registered, unreachable: git_clone)` line? Such a line
would be a bare fact, so it fits the map's no-prose rule.

**Decision.** No line, and no data field either. The map lists capabilities
some agent in the tree holds; an orphan is the *absence* of one.

Two things settle it. First, **the direction that is a bug already fails
louder.** The slip the line was meant to catch — a typo'd `tool_names` entry
silently orphaning a tool you meant to grant — cannot happen:
{Pikuri::SubAgent::Extension#configure} raises `ArgumentError` at boot when a
persona names an unregistered tool. What survives is the reverse — registered,
named by nobody — which can only ever *subtract* a capability, i.e. a
functionality gap, and this is not a functionality linter. Second, **an orphan
can never change a verdict, so it can never explain one.** Every other line on
the map earns its place by making a verdict attributable. A line no verdict
can depend on, printing on every `pikuri-os` and `pikuri-computer` boot for a
deliberate registration, is exactly the noise that gets a warn-only detector
muted.

**Alternatives rejected.**

- **The trailing `(registered, unreachable: …)` line.** The proposal above.
  Rejected on both counts: the audit value it reaches for is already delivered,
  more loudly, by the boot-time raise, and it spends permanent screen space on
  two shipped binaries to report a non-capability.
- **Exposing it as data (`Report#unreachable_tools`) for a host to render on
  demand.** Rejected as a field with no consumer. The day a host wants it, it
  is `agent.sub_agent_tools` minus the names in the walked tree — three lines
  at the call site, needing nothing from core.
- **Removing the orphan instead: make `Code::Extension`'s `git_clone`
  registration opt-in.** Rejected: a config knob added to silence a question
  the map answers by staying quiet, and it buys nothing — `pikuri-code` names
  the tool, and the OS binaries pay one unused constructor whose Bubblewrap
  sandbox is minted lazily and never is.

**Consequences.**

- **The map is a capability map, not a wiring linter.** Reading a tool's
  absence from it as a detector miss is the mistake to guard against, so
  `book/trifecta-detector.md` §"The edges, stated plainly" names this silence
  alongside the two unbuilt axes.
- **The orphan direction has no automated guard at all**, and that is
  accepted. It can only remove a capability, and a persona that actually needs
  the tool fails at boot rather than at the first delegation.

---

## D-egress-axis-shape — Two orthogonal egress axes, no invented persona (2026-08-12)

**Status:** Accepted; implemented 2026-08-12 in
{Pikuri::Tool::TrifectaLegs}. Folds in two earlier forks that never had a
home: the `egress_human_author` drop (2026-08-09) and the rejected
proxy-visible middle rung.

**Context.** The detector's egress leg started as one graded axis
(`none < human_approver < autonomous`) reading *payload visibility* — did a
human see the bytes, or only a proxy for them? A second property kept
recurring in the notes without a place to live: `web_search` reaches an
engine this repo picked, while `fetch` reaches a host the model chose, and
an attacker can read back the second but not the first. The two were
repeatedly mistaken for rungs of one scale.

**Decision.** The egress leg is **two orthogonal axes**, both carrying
`:no_egress` at the bottom and kept coherent by the constructor:
`egress_payload_review` (`:human_reviewed` / `:unreviewed`) and
`egress_destination` (`:tool_vouched` / `:attacker_reachable`). The verdict
grid becomes eight exhaustive clauses; exactly one cell moved, and no
shipped wiring's verdict changed.

**Alternatives rejected.**

- **A third rung on the visibility axis (`egress_human_author`).** Dropped
  2026-08-09, not deferred: a seat whose outbound bytes originate in the
  human's own intent holds no egress leg to grade, so it declares
  `:no_egress`. A rung definitionally equal to the bottom rung is not a
  rung, and clean-by-construction is leg-*absence*. The teaching gain is
  sharper too: **the only thing better than a reviewed gate is not holding
  the leg.**
- **A middle rung for a gate showing a *proxy* for the payload** (bash
  behind a confirmer). Rejected: it would make `Code::Bash` soft and with it
  every loud verdict in the repo. The admissible test is structural —
  payload or proxy — and grading the human's attention instead relaunches
  trust-the-approver at a finer grain.
- **Naming the visibility axis for the seat** (`egress_confirmer`,
  `egress_gatekeeper`), i.e. "who can stop it". Rejected on the same
  example, one level up: `Code::Bash` *has* a confirmer and still grades
  top-rung, so a seat-named field invites a confirmer-holding tool to
  declare the softer rung and silently deletes the alarm. Naming the
  payload makes `:unreviewed` cover both "no human" and "a human who saw
  only a proxy" without a gloss.
- **Grading the destination by who chose it** (`:tool_pinned` vs
  `:llm_chosen`). The natural framing, killed by one counter-example: a
  tool hard-coding a POST to `github.com` picks its own destination and
  still hands the bytes over, because a gist is world-readable. Pinning is
  necessary, not sufficient — so the axis asks whether a hijacked model can
  *reach the attacker*, and `:attacker_reachable` covers a model-chosen host
  and a republishing fixed sink with one rung.
- **`:safe_vetted_set` for the softer rung.** Rejected: this detector never
  claims safety. Bytes genuinely leave a vouched destination; they merely
  cannot be read back.
- **`egress_target_server`.** Rejected: a mail recipient is not a server,
  and the then-open custody question had synced folders as candidate sinks
  (settled since, as `D-write-custody-axis`).
- **Folding both axes into one lattice.** Rejected: neither dominates the
  other. A reviewed send to an attacker's inbox and an unreviewed query to a
  vouched engine are different animals, and a single scale would have to
  order them.
- **Nesting the pair in an `EgressLeg` value that is `nil` when absent.**
  Genuinely deletes the both-or-neither invariant, but costs a nested
  `Data`, `nil`-handling at ~10 read sites and churn at every declaration
  site. The invariant is three lines in a constructor; that was the cheaper
  trade.
- **Shipping a `SEARCHER` persona alongside the axis.** The plan of record
  bundled them ("all three together or none") on the grounds that the tag
  alone is decoration. Rejected: that conflates two reachabilities. The
  *verdict* cell needs a search-only wiring, but the **map** shows the
  distinction the day `web_search` declares it, which is where the teaching
  value lives. Inventing a persona so a verdict could fire would have traded
  away page-reading in a demo to satisfy the detector — and the detector must
  not be what forces a capability decision.

**Consequences.**

- **The detector now has two declared axes and one determined.**
  `:tool_vouched` is a claim the framework inherits from the tool's author,
  exactly as `private:` is inherited from the user; only `untrusted` is
  determined. The vocabulary says which is which, and the book says the tag
  is worth precisely the care that went into declaring it.
- **A vouched destination survives only as the sole egress leg.** No special
  case: `max` at a node hardens it the moment one attacker-reachable tool
  joins. The advisory for that cell says so, so a soft verdict does not read
  as settled.
- **A soft cell no shipped wiring reaches.** Every persona holding
  `web_search` also holds `fetch`. It is tested from hand-built nodes and
  waits for the first host that wants a search-only agent; the unplaced-level
  tripwire in `Report#verdict` was re-pointed at a hypothetical fourth level
  so it survives its own graduation.
- **The delegation cap applies to one axis.** A gate bounds what leaves and
  who saw it, never who can read it back, so `#cap_payload_review` leaves the
  destination alone — the name says the scope.

---

## D-blob-spotter-alphabets — Single-alphabet encodings count, at their own longer thresholds (2026-08-08)

**Status:** Accepted; implemented 2026-08-08 in
{Pikuri::Thunderbird::ComposeGuard}. Supersedes an inline "hex and base32
stay out" note that lived in `#body_blob_note`'s yardoc, moved here under
the pre-2026-08-04 relocation rule above.

**Context.** The blob spotter soft-warns when a compose body carries an
encoded dump — the lazy way to walk a secret past a skimming human. Its
original gate was three-class (upper *and* lower *and* a digit) over the
base64 alphabet, which by construction can match neither single-case hex
nor base32. Stress-testing the egress axis surfaced the hole: those two are
not evasion, they are the *natural* dress for a key — it is already hex on
disk — and they drew **no flag at all**. 64 lowercase hex chars is an
entire 256-bit ed25519 seed, silent.

**Decision.** Two chunk shapes with independent thresholds, whichever trips
first: the existing three-class shape at 16/32, and a single-alphabet shape
({Pikuri::Thunderbird::ComposeGuard::HEX_ALPHABET} /
`BASE32_ALPHABET`) at 32/48. 48 is not a round number — it is the only gap
available, above a full git SHA-1 (40) and below a 32-byte key in base32
(52) or hex (64).

**Alternatives rejected.**

- **Keep hex and base32 out** (the original call). Its reasoning was right
  about the *mechanism* — a two-class alphabet cannot clear a three-class
  gate — but weighed only false positives and never counted the zero-flag
  hole on the other side. A guard that catches the encoding an attacker
  picks *when trying to look normal*, and misses the one they pick by
  default, has its priorities inverted.
- **Widen the three-class gate to two classes.** This is what the original
  note actually rejected, and rightly: it applies the *base64* thresholds
  (16/32) to hex, so every UUID and every short SHA in an engineering mail
  warns. Alarm fatigue, and the note is body-wide, so one dev thread would
  train the user to ignore it. Separate longer thresholds get the coverage
  without touching that gate.
- **Raise the single-class join to 64** to dodge the SHA-256 false
  positive. Buys FP relief by surrendering half the coverage: a 32-byte key
  in base32 is 52 chars, so the threshold *must* sit below 52 to see it.
- **Fail closed on a blob** instead of warning. Same answer as everywhere
  else in this guard: it is trivially walked under by splitting the payload
  into sub-threshold pieces, so a hard reject would block honest mail while
  stopping no motivated attacker.

**Consequences.** A lone SHA-256 checksum (64 hex chars) now warns, and
this is irreducible — a 256-bit hash and a 256-bit key are the same string,
so no threshold separates them. Accepted: checksums are rare in mail, keys
are the thing being looked for. The guard's character is unchanged — a
paste / dumb-attack guard, not an exfil control; widening the alphabets
raises the attacker's cost by one token of prompt.

## D-headless-os-agent — No app launching, and the sandbox masks the session's IPC surface (2026-08-06)

**Status:** Accepted. The mask ships in
{Pikuri::Code::Bash::Sandbox::FullFsNoNet::SESSION_IPC_MASKS}; app launching
was never built and now won't be.

**Context.** `pikuri-os` advises on GUI config (it prints the `gsettings`
command rather than applying it), and "let it launch apps / `xdg-open` a
file" sat on the deferred list as a post-v1 nicety. Measuring what
`FullFsNoNet` actually permits killed the nicety and exposed a hole in the
egress cut, on this host, GNOME/Wayland:

- A sandboxed `curl` gets nothing (`000`, loopback-only netns). The same
  `curl` handed to `systemd-run --user` returns **HTTP 200** — `systemd
  --user` spawns it in the *host* netns, parented outside the sandbox.
- `xdg-open file.png` on a `DBusActivatable=true` handler (loupe) is spawned
  by the session bus: host netns, full network, cgroup `dbus.service`, and it
  survives `--die-with-parent` because it was never a child.
- A plain `Exec=` handler (librewolf) forks *inside* the sandbox and is
  contained — **unless an instance is already running**, in which case the
  remote-instance handoff delivers the URL to the outside process. Measured
  both ways: cold browser → "Unable to connect"; warm browser → the GET
  landed in the listener's log. Containment that depends on whether the user
  happens to have their browser open is not a security property.

So the trifecta's egress leg reopened through the session, and the enabling
authority is one unauthenticated socket: the session bus is the user's own
bus, with the user's full authority and no polkit in front of it.

**Decision.** The OS agent is **headless**. Two halves, one decision:

1. **No launcher.** No `open`/`launch` tool, and no GUI-application arm to
   the config advice. The human is at the keyboard; opening a file or
   starting an app is a double-click, so the capability buys ~nothing while
   costing an egress channel.
2. **The sandbox subtracts the session's live IPC surface** — a tmpfs over
   `$XDG_RUNTIME_DIR` (session bus, Wayland socket, keyring / ssh-agent /
   at-spi, a rootless container daemon) and over `/tmp/.X11-unix`, plus a
   `/dev/null` mask over a `DBUS_SESSION_BUS_ADDRESS` pointing elsewhere.
   Abstract-namespace sockets need no mask: `--unshare-net` already scopes
   them (measured — reachable from the host, `ECONNREFUSED` inside).

Being headless is what *permits* half 2: with launching declined, nothing
legitimate wants those sockets.

**Alternatives rejected.**

- **Ship the launcher anyway, confirmer-gated.** Rejected on value, not just
  risk: it's an egress-capable tool in a deliberately offline agent, bought
  for a double-click. It would also have to pick a broken semantics —
  direct-exec keeps the egress cut but ships crippled apps (a browser with no
  network), `xdg-open` works properly *by* escaping the cut.
- **Deny `xdg-open` (a bash denylist).** The tempting one-liner, and the
  losing side of the enumeration game that `PASSIVE_BINARIES` is deliberately
  the winning side of: `gio open`, `gdbus call`, `dbus-send`, `systemd-run
  --user`, `setsid librewolf URL`, five lines of Python on the bus socket are
  all the same channel. Worse, a partial denylist manufactures false comfort
  — "no deny hit ⇒ contained" is exactly the wrong lesson. Remove the
  authority, not the names.
- **Accept and document it** (the status quo, with the confirmer as the only
  guard). Rejected because the innocuous *look* of the trigger is the whole
  problem: a human who has read "bash here is network-severed" approves
  `xdg-open ~/report.png` on that understanding, and it is not true. Every
  such binary is non-passive today, so the human *does* see the command —
  which is necessary but too thin a thread to hang the gem's premise on.
- **Mask the rootful container sockets too** (`/run/docker.sock` &c., reusing
  `Bubblewrap::DENIED_CONTAINER_SOCKETS`; mechanically easy — `--ro-bind
  /dev/null <socket>` masks one cleanly). Rejected on the **error-signal**
  argument that already decided the real `/dev` and
  `D-permission-wall-handoff`: a user outside the `docker` group — the common
  case, and the reason rootless docker exists — gets an honest `EACCES` from
  the untouched socket, which tells the model *and* the human exactly what is
  true. Masking it trades that for a confusing `ENOENT`, and then both waste
  turns wondering where the daemon went. It would also cost `docker ps` as a
  diagnostic. For a user who *is* in the `docker` group the socket is a live
  root-equivalent escape — but that user holds root-equivalent power outside
  the agent anyway, and the guard there stays the confirmer (`docker` is
  non-passive, so it reaches the human).

**Consequences.**

- Lost, and worth stating plainly: `systemctl --user` (session-bus state
  queries), a *rootless* `docker`/`podman` socket, `ssh-add -l`, and audio
  tooling. Still fine, measured: `systemctl`/`hostnamectl`/`loginctl` on the
  system bus, `journalctl` (including `--user`, it reads files), `gsettings
  get` / `dconf read` (dconf reads the file; only *writes* need the bus),
  `ps`/`lsblk`/`smartctl` and every file read. The masked runtime dir is
  user-owned and writable, so a program wanting its own socket there still
  works.
- Residual paths out, all human-gated and none silent: the **system** bus
  stays bound (`systemctl status` needs it) — a transient unit there is
  polkit-gated and pops an *authentication dialog on the user's desktop*
  (observed; it is loud, and consistent with `D-no-agent-sudo`); **deferred
  execution** via a confirmed write (`~/.bashrc`, `~/.config/autostart/*`,
  `crontab`), which the write confirmer shows as a diff; and **rootful**
  container sockets, left visible on purpose so the denial is honest — see
  the rejected alternative above.
- The mask must stay *after* `--dev-bind / /` in the argv or the root bind
  covers it — invisible in review and silent under every other test, so
  there's an ordering assertion in the spec.
- `Bubblewrap` needs no change: it binds an allowlist that never included
  `/run/user`, so the coding agent never had the channel.

## D-no-agent-sudo — Privileged actions are a human hand-off, never agent-held root (2026-08-06)

**Status:** Accepted. Already the shipped behaviour on both legs (the
`EACCES` read hand-off of `D-permission-wall-handoff`, and
{Pikuri::Workspace::WriteGate}'s "sudo it yourself" short-circuit for an
unwritable write). The 2026-08-06 addition is one prompt clause splitting
*read* hand-offs (paste the output back) from *state-change* hand-offs
(say when it's done, the agent verifies itself).

**Context.** `pikuri-os` operates the real host but runs unprivileged, so
anything needing root — installing a package, editing `/etc`, restarting a
service — is out of reach. The recurring question is whether the agent
should ever *acquire* root, most concretely for package installation. Three
barriers stack up today, and it's worth keeping them straight:

- Inside either bwrap sandbox, `sudo` cannot work at all: `bwrap` sets
  `PR_SET_NO_NEW_PRIVS`, which neuters the setuid bit (`sudo: The "no new
  privileges" flag is set`). No sudoers or password arrangement gets around
  it.
- Under `FullFsNoNet` the network is severed too, so an install's download
  leg fails independently of privilege.
- Under `Bubblewrap` the target is also wrong: toolchain dirs are ephemeral
  overlays, so an install would vanish at session exit.

So installation is reachable only under `Sandbox::NONE` (`--no-sandbox` /
`--yolo`) — which for `pikuri-os` re-opens the network and reassembles the
trifecta the gem exists to break. The fork therefore isn't "sandbox or
not"; it's what the *host* does when root is genuinely required.

**Decision.** The agent never holds root. It advises: hand the human the
exact `sudo …` command with an explanation, and let them run it in their
own terminal. A downstream host (`pikuri-tui`, a web UI) must not add a
privilege-acquisition path either. This costs no new mechanism — the
hand-off is the shipped `EACCES` path, and the human's "done" is an
ordinary next user turn.

**Alternatives rejected.**

- **Agent-held sudo via `sudo -S` on stdin, or `SUDO_ASKPASS` / `sudo -A`.**
  Mechanically possible under `Sandbox::NONE`. Rejected because it
  **collapses the confirmation posture the file tools are built on**:
  {Pikuri::Workspace::WriteGate} short-circuits an unwritable write instead
  of prompting, and that is precisely why there is no sensitive-path
  denylist to maintain — "the files worth confirming are simply the ones
  you can actually write." Grant root and *every* file becomes writable,
  the argument evaporates, and the denylist we deliberately avoided has to
  be built. `D-permission-wall-handoff` rests on the same precondition:
  root turns its wall into a suggestion.
- **polkit / `run0` / `pkexec`** — the strongest form, since the auth prompt
  renders in the desktop's trusted UI and pikuri never touches the
  password. Rejected anyway: it solves password *handling* and leaves the
  posture problem untouched, still granting root to an LLM-authored command.
- **A per-install password prompt** ("just ask each time"). Rejected: with
  `--new-session`, sudo's timestamp cache is per-tty, so the password is
  re-fed on every call — making it a **standing root capability** for the
  session rather than one authorized act, which is
  `ideas/bash-confirmer.md` §"The danger" at maximum privilege. A web UI is
  strictly worse: password over a transport, held server-side, no local
  trusted tty.

**Consequences.**

- **The two hand-off legs are asymmetric, and the prompt now says so.** A
  privileged *read* needs its output pasted back; a privileged *change*
  does not — verification is available to the agent locally, needing
  neither root nor network (`dpkg -l`, `apt-cache policy`, and friends are
  already in the passive allowlist, so it self-verifies without even a
  confirmation prompt). Observed on a live 2026-08-06 "install openjdk-21"
  run: the model handed back the correct `sudo apt-get install …` from the
  grounding block's `Packaging:` fact, then asked for apt's progress bars
  to be pasted back. That misfire is what the clause fixes.
- **Probing with a doomed command first is fine.** The same run spent two
  steps discovering the dpkg lock was unwritable before escalating. Left
  as-is deliberately: it's the honest-`EACCES` path working, and the
  opposite of `D-permission-wall-handoff`'s open caveat (escalating *too*
  fast, before gathering the partial picture).
- **Package availability works offline.** apt's package lists are local, so
  `apt-cache policy` names the exact candidate version with the network
  severed. The agent can confirm a package exists and what it would install
  before handing off — the network barrier never fires on that leg.
- **This closes the "package installation" item** that sat in
  `ideas/pikuri-os.md`'s deferred list as "post-v1". It is not deferred
  work; it is declined by posture, and the hand-off already ships.

---

## D-context-window-sources — The `/props` probe, never ruby_llm's model registry (2026-08-04)

**Status:** Accepted; the behaviour has always shipped this way
({Pikuri::Agent::ContextWindowDetector}). Logged 2026-08-04 when the
argument moved out of that class's yardoc.

**Context.** A context-window cap is only worth emitting if a host can *act*
on it — warn, compact, or switch models before
`RubyLLM::ContextLengthExceededError`. So the number has to be trustworthy
without a caveat attached.

**Decision.** Two sources only: llama.cpp's non-standard `/props` probe (the
server's *launched* `n_ctx`, i.e. the real window) and an explicit
{Pikuri::Agent::ChatTransport#context_window}. Anything else resolves to
`nil` — an honest "we don't know."

**Alternatives rejected.**

- **`RubyLLM::Model::Info#context_window`** (the obvious source, and free) —
  it's a static `models.json` lookup, so it returns `nil` for every
  `assume_exists` local id, `nil` for anything past the snapshot, and —
  worst — a **frozen** value for models it *does* know: a window bumped
  256k → 1M still reports the old number. A cap you must caveat defeats its
  only job, and a confidently-wrong number is worse than `nil`. Not
  consulted at all, rather than consulted as a last resort, because a
  fallback that lies is indistinguishable from one that works until it
  silently truncates.

**Consequences.** Non-llama.cpp servers get no cap unless the host passes
`context_window:` on the transport — deliberate, and why the detector's
failure path is a debug log rather than a raise.

---

## D-permission-wall-handoff — An honest `EACCES` beats prompt guidance (2026-07-18)

**Status:** Accepted; the read-vs-mutate sub-bullets were removed in
`f917226`. Validated live 2026-07-18 ("Is my SSD healthy?").

**Context.** `pikuri-os` runs unprivileged inside a bwrap user namespace
where `sudo` doesn't work, so anything genuinely needing root must be handed
to the human. The question was how much of that escalation *strategy* the
system prompt has to spell out.

**Decision.** One line in `prompts/os-assistant.txt` states the hand-off (a
`Permission denied` means the real answer needs root → give the exact
`sudo …` command, explain it, ask for the output pasted back). No
elaboration beyond that. On the live test the model ran the probe, read
"Permission denied", recognized root was required, and handed back exact
`sudo nvme smart-log` / `sudo smartctl -a` with an explanation and a
paste-back ask — unprompted, and reaching for the NVMe-specific tool first.

**Alternatives rejected.**

- **Read-vs-mutate escalation sub-bullets in the prompt** — they existed and
  were trimmed as dead weight once the behaviour proved emergent.
  **Don't re-add them thinking they're load-bearing.** Prompt text is not
  free: every line competes for attention with the ones that *are* doing
  work, and this one was buying behaviour the model already had.

**Consequences.**

- **The precondition is the load-bearing half, and it's in the sandbox, not
  the prompt.** This only works because `FullFsNoNet` binds the *real*
  `/dev`. The earlier synthetic `--dev /dev` hid block-device nodes, so
  `smartctl` failed `ENOENT` ("No such device") while `lsblk` / `/sys`
  showed a healthy disk — an incoherent machine, and the model retry-looped
  instead of escalating. A prompt cannot fix an environment that lies. See
  {Pikuri::Code::Bash::Sandbox::FullFsNoNet} + `pikuri-code/DESIGN.md`.
- **Open caveat.** The model escalated *straight* to `sudo` without first
  gathering the partial non-root picture. Fine when root is genuinely
  required (SMART data is), but on a case with real partial value (a
  root-only log where `/sys` gives half the story) the leaner prompt may
  leave that on the table. Watch for it before calling a "gather partial
  first" nudge permanently unnecessary.

---

## D-fake-transport — Fake the HTTP backend, not the agent (2026-07-18)

**Status:** Accepted; shipped for single-agent 2026-07-17
({Pikuri::Testing}), export boundary settled 2026-07-18. Graduated from
`ideas/fake-llm.md`.

**Context.** Unit-testing agent behaviour needs no server and no network,
but mocking the *agent* tests nothing — the value is in the real `run_loop`,
real listeners, real tools/extensions, real `Event` stream, real ruby_llm
loop.

**Decision.** A fake is a plain {Pikuri::Agent::ChatTransport} carrying an
anonymous `Faraday::Adapter` (a generic `faraday_adapter:` field, no
subclass), installed on the agent's *per-chat* `RubyLLM::Context` so the
global `RubyLLM.config` is untouched. Only `fake_transport` is exported.
Mechanics + limitations: {Pikuri::Testing}.

**Alternatives rejected.**

- **A fake backend that reimplements the ruby_llm loop** — it would drift
  against every ruby_llm upgrade, and the whole point is that the *real*
  loop parses the tool calls and invokes the real registered tools.
- **The two-phase `new` / `configure` split** — splitting `Agent.new` (pure)
  from a public `Agent#configure` (block + network) to make offline
  construction testable. Tried, then **reverted: it bought nothing.**
  pikuri-tui's stubs fake `run_loop` (turn *execution*), not construction,
  and pikuri-core already tests real agents by faking the backend — which
  needs no construction change and works with the existing ctor block. The
  lever was always the backend seam. **Don't re-open the two-phase split as
  a testing enabler.**
- **Exporting the white-box `fake_chat`** — the callback-capture stub that
  `agent_spec` (and the mcp / skills / subagents specs) hand-roll, which
  fires individual chat callbacks by hand and inspects chat internals. It
  tests pikuri's own `Agent` ↔ `RubyLLM::Chat` adapter seam — an *internal*
  contract. No downstream consumer ever pokes that wiring (they test their
  own tools/listeners/extensions, which is `fake_transport`'s job), so
  exporting it would ship a helper no external caller can use and leak the
  internal adapter contract into the public API.

**Consequences.**

- The white-box fake stays test-internal, per gem, and its ~5×
  duplication is an **accepted** internal DRY smell: the copies genuinely
  diverge, cross-gem spec-support sharing is awkward, and the real-loop
  coverage those callback tests approximate is carried end-to-end by
  `pikuri-core/spec/pikuri/testing_spec.rb`.
- Most of `agent_spec` can't move to `fake_transport` without losing
  coverage — you can't fire a lone `after_tool_result`, or read
  `model_switches`, off a real chat.
- Faking at the Faraday-adapter level constrains any future LLM-client
  swap: a Faraday-native replacement keeps this seam, one that hand-rolls
  `net/http` deletes it and forces a new fake harness across every gem's
  specs. See `D-keep-ruby-llm`.

---

## D-per-process-temp — Two named `Paths` methods, not `cache(session:)` (2026-07-14)

**Status:** Accepted; implemented 2026-07-14 (`Paths.new_temp` +
`Paths.sweep_stale_temps!`). Graduated from `ideas/session-scoped-store.md`,
now retired.

**Context.** Two concurrent `pikuri-thunderbird` processes shared a *fixed*
snapshot path (`~/.cache/pikuri/thunderbird/{mail,calendar}/`), so they
clobbered each other's SQLite copies — and one process's clean-exit `rm_rf`
(a `Snapshot` finalizer) deleted the copy the other was mid-query on. The
root cause was **discoverability**, not the path: `Paths` was invisible, so
the implementer re-derived `XDG_CACHE_HOME` inline and landed on a shared,
persistent directory without ever meeting the per-process concept. Any fix
had to make the shared-vs-private choice unmissable at the call site.

**Decision.** Split the concept into two *named* methods with distinct
semantics — `Paths.cache` (shared across all pikuri processes, persistent)
and `Paths.new_temp` (private to this process, ephemeral, finalizer-reaped,
stale-swept at core load). Per-symbol mechanics and their full why —
in-home rather than `/tmp`, factory rather than memoized accessor, the
reap/sweep contract — live in {Pikuri::Paths.new_temp} /
{Pikuri::Paths.sweep_stale_temps!}. The invariant ("cache & temp paths go
through `Paths`") plus its `ENV['XDG_CACHE_HOME']` grep tripwire live in
CLAUDE.md *Conventions*.

**Alternatives rejected.**

- **`Paths.cache(session: :shared | :current)`** — a required kwarg
  *forcing* the decision at the signature. Genuinely attractive: great
  discoverability, and pikuri-shaped like `StepLimit.new(on_exhausted:)`.
  **Killed** because the enum is secretly a 2×2 matrix — *shared-vs-private*
  × *persistent-vs-nuked* — crammed onto one axis: `:shared` implies
  persistent, `:current` implies nuked, and **there is no cell for a
  persistent per-process session**. The moment that cell is wanted, the enum
  breaks. Two named methods don't share an axis, so the same future need
  becomes a *third named method* instead of a broken enum value. It also
  invented an on-disk `sessions/<id>/…` tree the two-method design never
  needed.
- **Keeping the mint on `Workspace::Filesystem`** (`mint_internal_temp` /
  `sweep_stale_internal_temps!`) — rejected: the concept isn't
  workspace-shaped, and the stale sweep ran at *workspace* gem load, so a
  binary that wires no workspace never swept. Both were deleted;
  `Filesystem#internal_temp` now memoizes `Paths.new_temp`, and the sweep
  moved to *core* load with a generic `temp-*` prefix, so every binary
  sweeps.

**Consequences.**

- **A persistent per-process session is deliberately not built.** If the
  need appears (scratch that survives a process's own restart yet stays
  private), it is a *third* named `Paths` method — the two-method split
  leaves room without reopening the rejected enum.
- **Stale-sweep liveness is a known latent hazard** (pre-existing —
  inherited from the workspace design, not created here). The sweep is
  mtime-cutoff based (`Paths::TEMP_STALE_SECONDS`, 7 days), so a process
  outliving the cutoff whose temp-dir mtime never gets bumped could have a
  *live* dir reaped by a newly-starting process's core-load sweep. A pidfile
  + `Process.kill(0, pid)` liveness probe would fix it but is PID-recycle-
  fragile. Deferred — revisit if it actually bites.
- `new_temp` registers one block-form reap per mint at its ownership
  boundary, under the single `at_exit` of the *Finalizers / teardown seam* —
  no second `at_exit`.
- Thunderbird's `Extension` now takes `cache_dir` with `nil` meaning "mint a
  fresh per-process dir," which is what closed the original collision.

**Related.** [`ideas/thunderbird.md`](ideas/thunderbird.md) — where the
collision surfaced; its Q11 (concurrency) covered the *live-DB* race, not
this *snapshot-destination* race between two pikuri processes.
