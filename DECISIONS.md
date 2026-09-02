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

**Format.** One entry per decision. The ID is a slug, not a number: `D_`
plus a 1–4-word snake_case hint at the subject (`D_per_process_temp`), so a
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

**Never read wholesale.** `grep '^## D_' DECISIONS.md` is the index; there
is no ToC (same discipline as `ls ideas/`). Cite an entry by slug. Grep
tripwire: every `D_<slug>` referenced anywhere in the repo must exist as a
`^## D_` heading here.

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

## D_kuri_mascot — pikuri's mascot is a pika named Kuri, in a grey Talus coat (2026-08-29)

**Status:** Accepted, shipped 2026-08-29 as `assets/kuri.svg` +
`assets/kuri.png`, shown in `README.md`. The *icons* built from him are
downstream and belong to whichever host needs them; pikuri-web was the
first to build a set, and records its own icon decisions on its own side.
(Foreign decision slugs are deliberately not cited here — `T_decision_slugs`
holds every `D_` in this repo to a heading in this file, and a library
should not know a shell's decision ids anyway.)

**Context.** pikuri-web needed a PWA icon and discovered pikuri had no
mascot at all. Picking one is a decision for *this* repo, not for a
shell: it is the project's face, it will outlive any one front-end, and
every host that wants an icon renders it from the same drawing.

**Decision.** **Kuri, a pika** — *Ochotona*, a palm-sized lagomorph of
alpine rockslides. The animal is the project's own argument, told as an
animal rather than a paragraph: it does not migrate and does not
hibernate; it spends the summer clipping grass into a haypile under a
rock and the winter living on what it stored; it sits up on its boulder
and gives a sharp alarm call before anything gets close. That is the
local corpus, the offline posture and the confirmer, in one creature.
The name was already inside the project's own — *pi‑ku‑ri* — so the
mascot hands the name a folk etymology it can keep.

He is drawn flat and geometric, head-on, in the **Talus** coat: fur
`#a89c8e`, inner ear `#786d61`, muzzle `#ded5c8`, ink `#26241f` — the
grey-brown of the scree he hides in. `assets/kuri.svg` is the master and
is **transparent**, with a tight `viewBox` on the art's own bounding
square so a host can scale it into any frame without a transform.

**The anatomy rule, because the first draft got it wrong.** Ears that
are small, high and clear of the skull read as a **teddy bear** — which
is exactly what the first render produced, and it was not obvious until
it was drawn at 512px. A pika's ears are *large* and sit on the **sides**
of the head, at roughly 8 and 4 o'clock, overlapping it. Those, a muzzle
kept well under half the face, and whiskers are the three tells. Any
future pose keeps them or stops being a pika.

**Rejected: three other mascots and one anti-mascot.** All were drawn
before choosing, because a mascot argument settled in prose picks the
best *sentence* rather than the best drawing.

- **A spark in a sealed jar.** Draws the containment posture directly —
  the sandbox, the severed network, the read-before-edit gate. Dropped
  because "in a jar" reads as *trapped* rather than *safe*, the wrong
  note for a tool asking to be trusted, and because it is two objects at
  32px.
- **A ruby firefly** — a beetle whose shell is a cut ruby, carrying its
  own light. Says Ruby without shipping another faceted stone. Dropped
  because red is the *error* colour in pikuri's palette, and spending it
  on the mascot means red stops meaning "something went wrong".
- **A hooded keeper with a lamp**, the README's Dune epigraph as a
  character. The strongest silhouette of the set. Dropped on the owner's
  call: a faceless hooded figure reads cryptic and a step further,
  occult, which is a cold face for a project whose premise is teaching —
  **and the mascot is deliberately not a Dune reference.** The epigraph
  stays in the README; it does not get a body.
- **A pulse-line mark and no mascot at all** — flat, one jolt, flat, for
  ぴくり, "a small twitch". Flawless at 16px, one colour, nothing to keep
  on-model. Kept in reserve rather than rejected: a mark and a mascot are
  not exclusive, and this is what to reach for if a one-ink or
  eight-pixel rendering is ever needed.

**Rejected: seven other coats, and the warm ones were the hard call.**
Eight were drawn as one SVG with four values swapped, so the comparison
was the colour and nothing else. **Ember** (`#dd9046`) was the initial
recommendation and the runner-up: warm, cuddly, close enough to the send
gold that an icon would rhyme with the UI. It lost because warmth is
generic — Ember reads as *a friendly shape in a brand colour*, where
Talus reads as *this animal*. **Send gold** (`#e8b339`) is the literal
brand token and the brightest on a dark ground, and invites the
electric-rodent comparison. **Cinnamon** is the most realistic and the
least brand-y. **Tool teal** is the most logo-like and no pika was ever
that colour. Accent blue, slate-and-gold and bone were also drawn; bone
wins 16px and then vanishes on a white tab strip.

**Consequences.** Talus is a **mid grey, and that is the one thing it
costs**: there is no ground it reliably contrasts against, so any host
rendering him small has to supply one. That is a host's decision, not
this repo's — pikuri-web pays it by putting every icon it ships on an
opaque plate. At README and book sizes no plate is needed: mid grey holds
on both a white and a dark page, which is why `assets/kuri.png` is
transparent too.

**The coat also colors the demo chrome** (2026-09-02): the tool-call /
tool-result lines and the confirmer's diff hunk headers were terminal
cyan, which is nobody's color — the shells had already moved their own
tool token onto the coat, so the library's demo renderer follows.
`Listener::Terminal::TOOL_COLOR` is `#c1a586`, the coat's hue with the
chroma lifted, and **not the swatch verbatim**: at 13% saturation
`#a89c8e` lands on the dim reasoning grey's lightness and reads as a
second shade of it. It is an absolute RGB rather than a named ANSI
color, which is the same trade the shells make — a terminal that remaps
cyan cannot be asked to carry pikuri's own color — and the trade is
worth it only for *this* token; the notice/error/cancel accents stay
named and keep tracking the user's palette.

There is deliberately **no generator script and no second pose**. The
mascot changes about as often as a logo does, and a monorepo with no
build step should not grow one for it; a sleeping Kuri for an empty
state, or a one-colour Kuri, gets drawn from this head-on sit if and
when something actually needs it.

---

## D_model_owns_thinking — Send no thinking configuration; the model's own default stands (2026-08-29)

**Status:** Accepted 2026-08-29; describes shipped behaviour, no code change.
Companion to `D_thinking_block_replay`, which owns what happens to a thinking
block pikuri has already *stored*.

**Context.** pikuri sets no thinking / reasoning parameter on any request.
`with_thinking` appears nowhere in the repo, and `Agent` exposes no
`attr_reader :chat`, so the Chat is sealed behind the loop seam and a host
cannot set one either. Until now that was an *accident* — an invariant with no
decision behind it, discovered while working `D_thinking_block_replay`. This
entry is the decision it never had.

**What "no parameter" actually resolves to.** Omitting the parameter takes the
model's own default, and on models that support thinking that default is on:
OpenAI reasoning models always reason and an omitted `reasoning_effort` takes
the provider's default rather than its floor; Gemini 2.5 Pro cannot disable
thinking and 2.5 Flash defaults to it; Anthropic Opus 5 and Sonnet 5 are on by
default, Fable 5 and Mythos 5 always (`{type: "disabled"}` is a 400 there); and
on the local llama.cpp pikuri actually wires, the chat template decides —
Qwen3's `enable_thinking` defaults true, DeepSeek-R1 reasons unconditionally.
The one band where omitting means *off* is Anthropic's Opus 4.8 / 4.7 / 4.6 and
Sonnet 4.6, which need an explicit `{type: "adaptive"}`.

**Decision.** Send nothing. The model's default stands, whatever it is.

**The posture is the decision, not the outcome.** "Thinking ends up on" is a
property of today's lineup, not a guarantee — the 4.6–4.8 band is the
counter-example, and defaults move. What pikuri commits to is *not overriding
the server's own default*, the same posture as the connection seam (a per-chat
`RubyLLM::Context`, never a process-global `RubyLLM.configure`) and
`openai_use_system_role` (adapt to what the local server actually is). It stays
right when a model's default flips, and on a local-first stack the chat
template — not pikuri — is what knows whether the served model reasons.

**Request-side config and block replay are independent everywhere but one
place.** Sending no thinking config must not mean "never echo a stored thinking
block back", and on three of ruby_llm's four protocols it doesn't: `converse`
(`chat.rb:187`), `gemini` (`:157`) and `chat_completions` (`:393`) all key the
replay off the stored message. Only the `anthropic` protocol gates it on the
outgoing request's config (`:344`, `:378`), so there — and only there — pikuri's
default silently also means "never replay", including on a tool-use turn where
Anthropic documents echoing back as *required*. That is upstream's bug, filed as
[ruby_llm#897](https://github.com/crmne/ruby_llm/issues/897); it does not argue
against this decision, because Converse serves the same Claude models and
already replays without consulting the request.

**Unreachable today.** Every shipped wiring is `ChatTransport.from_openai_server`
(provider `:openai`), so nothing pikuri ships routes through the gated protocol.
The defect is latent, for a host that constructs `ChatTransport.new(provider:
:anthropic, ...)` itself.

**Alternatives rejected.**

- **Turn thinking on globally**, one `with_thinking` at `Agent` construction.
  Wrong layer: `Thinking::Config` is effort/budget and ruby_llm maps it
  per-provider, so on the wired `:openai` leg it becomes `reasoning_effort` —
  meaningful to a harmony/GPT-OSS template, inert to a Qwen3 one that gates
  thinking through `enable_thinking` instead. It would also change cost and
  latency on every host on a default nobody opted into, and on Anthropic it
  invalidates every existing cache prefix, since the thinking configuration is
  rendered into the prompt itself. It buys no correctness on the leg pikuri
  actually rides, whose replay is already ungated.
- **A `thinking:` field on `ChatTransport`.** The right layer — thinking-vs-not
  is exactly the per-model-per-server fact that value object exists to keep
  together, and it would leave llama.cpp untouched. Declined for now only
  because it has no caller: a knob with no host asking for it. Reopen when one
  does, or when #897 lands and an Anthropic wiring ships.
- **Explicitly disable it** so the behaviour is intentional rather than
  emergent. Not expressible: `Thinking::Config#enabled?` is `!effort.nil? ||
  !budget.nil?`, and the Anthropic path returns no payload at all for effort
  `'none'` — ruby_llm has no way to emit `thinking: {type: "disabled"}`. A trap
  even if it did: rejected outright on Fable 5 / Mythos 5, and on Opus 5 with
  thinking off the model leaks tool calls into visible text on tool-heavy
  workloads.
- **Pick a default per model id**, from a table pikuri owns. That table is a
  registry of other vendors' defaults, wrong the day a model ships and silently
  wrong thereafter — the JSON-config wall pikuri is the counter-move to. It is
  also the same class of thing `D_context_window_sources` already declined in
  favour of a live probe.

**Consequences.**

- No opt-in is safe on the Anthropic leg until
  [#895](https://github.com/crmne/ruby_llm/issues/895),
  [#896](https://github.com/crmne/ruby_llm/issues/896) and
  [#897](https://github.com/crmne/ruby_llm/issues/897) land: #897 alone would
  start *sending* the malformed shapes the other two describe, turning a silent
  degradation into a hard 400.
- pikuri surfaces reasoning it cannot always replay — `Event::ThinkingDelta`
  and `Tokens#thinking` render it live. On the wired `:openai` leg nothing is
  lost; on a hypothetical Anthropic one it would be, until #897.

---

## D_thinking_block_replay — Drop the whole thinking block on a model switch, and only from the wire (2026-08-29)

**Status:** Accepted; implemented 2026-08-29. See
{Pikuri::Agent#load_history!}, {Pikuri::Agent#apply_transport!},
{Pikuri::Agent::History::Message#to_ruby_llm}. Supersedes the thinking-signature
paragraph in `D_history_load_repairs`, which rode in as a corollary and was
wrong on both halves.

**Context.** A resumed or mid-session-switched conversation can carry an
assistant turn whose reasoning was produced by a *different* model. The
previous behaviour dropped that turn's thinking **signature** and kept its
text, on the stated grounds that "replaying one after a switch is a 400".

Two things are wrong with that. Anthropic documents the opposite — a foreign
thinking block is *silently ignored*, costing only input tokens — while the
400 that does exist is for **modified** blocks in the latest assistant
message, which is precisely the shape a stripped signature produces. And the
repair is unreachable on Anthropic anyway: pikuri never calls
`Chat#with_thinking` (`D_model_owns_thinking`) and seals the Chat behind the
loop seam, so ruby_llm's Anthropic serializer emits no thinking block at all.

Where the repair *is* live — the OpenAI-compatible path, whose
`format_thinking` is ungated, and which Grok also travels since ruby_llm's
`XAI < OpenAI` overrides only `format_role` and `format_content` — it repairs
the wrong field. llama.cpp reads
`reasoning_content` off an input assistant message and hands it to the chat
template; it has **no signature concept whatsoever**. Measured against
`unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M`: the signature is always nil, and the
text is populated with raw first-person chain of thought. So on the default
local backend the old repair dropped a field that never exists and forwarded
the reasoning it should have dropped.

**Decision.** When a message's recorded `model_id` does not match the agent's
current model, drop its thinking block **entirely** — text and signature both
— from what goes to the provider, while the message and the stored record keep
it. `Message#to_ruby_llm` takes `keep_thinking:` in place of `keep_signature:`.

**The whole block is the only portable unit.** The text/signature split is an
Anthropic implementation detail, and an inverted one: there the signature *is*
the reasoning (encrypted) and the text is a lossy summary that is empty by
default, while on llama.cpp the text is the substance and no signature exists.
"This turn's reasoning" is the only thing that means the same on every backend.

**The scrub runs at both points model identity can change** — `load_history!`
and `apply_transport!`. Load time provably cannot cover a mid-session switch,
which is the more damaging case: `Chat#with_model` preserves history, so today
the foreign reasoning is replayed on that turn and every turn after it. This
costs no request-build hook and does not touch the loop seam: `with_model` has
exactly one call site inside `apply_transport!`, with exactly one caller, so
identity changes only at construction (no history yet), load, or switch.

**Dropping is a correctness fix here, not the cost optimization it is for
Anthropic.** Anthropic's stated reason for stripping on a switch is that the
receiving model ignores the blocks anyway — it can say that because signatures
let its server detect and discard them. Nothing on the local path does, so the
foreign reasoning lands in the prompt. It also lands in a *self-attributive*
slot: templates place a thinking block where the model treats the contents as
its own working state, so the model is told it already reasoned that way and
continues from there, carrying register and rejected branches with it.

**Unknown provenance drops.** `model_id: nil` previously kept the block. Under
the old rationale (avoid an invalid signature) that was harmless; under the
attribution rationale unknown is indistinguishable from foreign, so assume the
worst rather than silently corrupt.

**Retention rides `@message_meta`, so the record stays faithful.** Scrubbing
`@chat` alone would mean a load-under-a-different-model followed by a save
writes the reasoning out of existence — a record that degrades every time it is
opened, which is the opposite of what this decision's parent promises.
`track_message` already keeps an identity-keyed side map of per-message data no
provider sees (`id`, `kind`); stripped thinking is the same kind of thing, and
`export_history` prefers the map. Wire sees nothing, disk keeps everything.

**Alternatives rejected.**

- **Keep dropping only the signature.** The status quo. Repairs a field that
  is nil on the local path and never sent on the Anthropic one, while
  forwarding the reasoning text that backends actually read. It also produces
  a *modified* block, which is the one shape Anthropic documents as a 400.
- **Never replay thinking at all**, deleting the identity test outright.
  Simpler, and tempting once you know the Anthropic path sends nothing. But
  the entire case against replay is false attribution, and none of it applies
  when the model has not changed — same-model continuity works today and
  Anthropic explicitly recommends it.
- **Key the test on the transport rather than `model_id`**, recording
  `api_base` per message. Its evidence was one bug report about *rewriting
  proxies* — [openclaw#92019](https://github.com/openclaw/openclaw/issues/92019),
  whose "endpoint-specific" claim is the reporter's own diagnosis and names
  Bifrost and LiteLLM — against a docs statement that signatures are
  portable across the Claude API, Bedrock and Vertex. A live probe shows model
  ids echo verbatim on llama.cpp, and under this decision a weak identity test
  can only misfire same-model, in the safe direction — losing the model's own
  reasoning, never injecting a foreign one. Not worth a `History` schema
  change. Reopen if a rewriting proxy enters the picture.
- **Scrub at request-build time** instead of at the two identity-change
  points. The only variant that would keep `@chat` itself whole, but it needs a
  hook into `Chat#complete` that the loop seam says is ruby_llm's. The side-map
  retention above gets the same guarantee for free.
- **Fixing ruby_llm first.** Its `Thinking` type is one text plus one
  signature, so it cannot represent an Anthropic turn's ordered block sequence:
  a display-omitted block re-serializes as `redacted_thinking`, multi-block
  turns collapse and lose all but the first signature, and a `redacted_thinking`
  block alongside a `thinking` one is dropped. All three are real and all three
  are upstream's — filed as
  [ruby_llm#895](https://github.com/crmne/ruby_llm/issues/895) and
  [#896](https://github.com/crmne/ruby_llm/issues/896), joined by
  [#897](https://github.com/crmne/ruby_llm/issues/897) for the gate that is the
  proximate reason the serializer emits nothing — and none of them blocks this,
  because pikuri sends no thinking to Anthropic at all.
- **Emitting a warning or event when thinking is dropped.** Duplicates a
  recovery nobody can act on, for the same reason the tool-set-drift warning
  above was declined.

---

## D_unwound_batch_repair — Answer the dangling calls on the way out, don't prevent the damage (2026-08-28)

**Status:** Accepted; implemented 2026-08-28 as an `ensure` on
{Pikuri::Agent#run_loop} calling a private `repair_dangling_tool_calls!`, four
public `*_RESULT` constants on `Agent`, and
`pikuri-core/spec/pikuri/agent/unwind_repair_spec.rb`. Graduated from
`ideas/unwind-mid-tool-batch.md` (deleted).

**Context.** ruby_llm's `complete_once` appends the assistant `tool_calls`
message *before* running any tool, so anything unwinding out of a batch leaves
calls that no `:tool` message answers. OpenAI and Anthropic reject that with a
400; a local llama.cpp feeds it to the chat template and the model improvises
— the same loud-on-cloud / silent-on-local split as
`D_reference_text_as_user_turn`.

Four sources, and the first is the one that shapes the decision: **any**
exception out of a tool, which "errors are loud" deliberately lets propagate —
a bug in tool code, a corrupt file, a library blowing up. Then
`Cancellable::Cancelled` (from `before_tool_call`, from `Cancellable#sleep`
inside a tool, or out of a sub-agent sharing the token),
`StepLimit::Exceeded` from `tick!`, and `Interrupt` in a host that doesn't
trap SIGINT.

It was already shipping. `bin/pikuri-chat`'s `run_turn` rescues `Cancelled` and
returns to the `> ` prompt with the agent intact, so Ctrl+C during a batch
poisons the next message; and the seven `bin/` scripts running
`on_exhausted: :synthesize` answer from the salvage path and return *normally*,
leaving the same wreckage behind. An earlier draft of the idea note asserted
the opposite ("they exit, or they `clear_conversation`") — worth recording,
because the same reflex will say it again.

**Decision.** An `ensure` on `run_loop` appends a `:tool` observation for every
call the last assistant turn left unanswered, then the exception propagates
untouched. The first unanswered call is told what went wrong; the ones behind
it are told they never ran.

`ensure` rather than a clause on each `rescue` is the load-bearing part. It
catches sources nobody enumerated (`Interrupt` is not a `StandardError`), it is
a no-op on the success path, and it runs *after* the `:synthesize` rescue body
— so {Pikuri::Agent::Synthesizer.build_prompt} still reads the unrepaired
history that its documented drop-calls-with-no-result pass expects, and the
salvage answer does not change. The one wrinkle: Ruby restores `$!` once a
rescue clause completes normally, so that branch hands its exception across in
a local.

Splitting culprit from skipped is worth the extra constant because telling a
call that never started "you failed" invites a retry of something that was
never attempted. It rests on `tool_calls` being insertion-ordered and ruby_llm
iterating it with `each_value` — true only while `tool_concurrency` stays off,
which `D_tool_sharing_postures` already asks for on separate grounds.

**Alternatives rejected.**

- **Prevent the damage: raise only where the conversation is well-formed.**
  Have `before_tool_call` observe the flag instead of raising, have the
  per-agent wrapper from `to_ruby_llm_tool` turn a `Cancelled` into an
  observation and short-circuit the batch's remaining calls, and raise from
  `after_message` when `tool_batch_complete?`. Nothing is ever synthesized:
  every call gets a real result, and the invariant collapses to one sentence.
  It was the leading candidate until the scope question was asked properly. It
  only covers cancellation — a `NoMethodError` in tool code still dangles the
  batch, so the repair path has to exist anyway and this becomes a second
  mechanism sitting on top of it. And it makes cancel *less* responsive: cancel
  latency becomes "when the current tool returns", which forecloses the
  direction we want, where a long-running tool blocked in IO polls the flag and
  aborts itself. (`RubyLLM::Tool::Halt` is the same idea wearing ruby_llm's own
  API, and loses for the same two reasons.)
- **Repair at turn start instead**, symmetric with the load path. Strictly
  later: the damaged chat is observable to the host in between (an
  `export_history`, a listener, a UI redraw), and the cause — which is what
  makes the message worth reading — is no longer in hand by then.
- **Reuse {Pikuri::Agent::History#repair_interrupted_tool_calls}.** It solves
  this shape and is already specced. But it walks `History::Message`, whose
  `role` is a `String` where ruby_llm's is a `Symbol`, and it carries
  interleaving logic for an arbitrary stored file that a live chat cannot need
  — the damage there is always the tail. A duck-typed shared helper with a
  String/Symbol trap in it is worse than two tail scans. Its generic
  `INTERRUPTED_RESULT` also stays put: the load path genuinely cannot tell a
  killed process from a cancel, and here the cause is known.
- **Drop the damaged tail** — delete the opener and its partial results, ending
  at the last clean boundary. Cheap, invents nothing. It erases that the model
  ever decided to call the tool, and "you tried this and it failed" is the most
  useful thing to carry into the next turn.
- **Refuse loudly** — a named error on the next `run_loop` telling the host to
  reset. Hands the host a conversation it cannot use and no way to fix it in
  place.
- **Nothing, and document that a damaged agent must be reset.** Puts the burden
  on every host, and fails at the provider rather than at the mistake — which
  on a local model means it does not fail at all, it just goes strange.
- **Sanitizing the exception message** before it lands in the conversation. It
  can carry attacker-controlled bytes (a filename off a scraped page, an HTTP
  body). Not a new leg: {Pikuri::Tool#run}'s own `"Error: …"` and tools' HTTP
  error strings already put exactly those there, and a model cannot react to a
  failure it is not told about. Class and message, never a backtrace.

**Consequences.** `Agent` gained four public constants, on the same reasoning
that makes `History::INTERRUPTED_RESULT` public: a renderer has to be able to
tell a synthesized observation from a real one. Each is also emitted as an
`Event::ToolResult`, so the listener stream stays consistent with
`@chat.messages` and a host can display what was appended — at the cost of
rendering identically to a result a tool really returned, which the wording of
the constants is what distinguishes. `Testing::Script` gained `tool_batch`, the
multi-call verb any batch-boundary spec needs. Dangling calls with *no*
in-flight exception raise: that is pikuri having lost a batch on a turn that
succeeded, and an `ensure` with no exception to clobber is a safe place to be
loud.

## D_gloda_locks_mcp_does_not — A lock where it is one method, one-agent-only where it is a pool (2026-08-28)

**Status:** Accepted; implemented 2026-08-28. {Pikuri::Thunderbird::Gloda}
and {Pikuri::Thunderbird::Calendar} are `P_shared_locked`; MCP and LSP stay
`P_one_agent`. The postures and their contracts live in each class's
`== Sharing`.

**Context.** `D_tool_sharing_postures` left a per-tool list of "should this
one be improved?" Two items looked identical — an unguarded collaborator
that a second agent would corrupt — and got opposite answers on the same
day, which is exactly the kind of split that reads as inconsistency later.

Nothing in `lib/` runs two agents concurrently, so *demand* cannot be the
discriminator: it is equally absent for both.

**Decision.** The discriminator is the **size of the fix**, not the size of
the win.

Gloda's entire hazard is one method. `#with_fresh_db` closes the
connection, re-copies the snapshot and rebuilds the FTS5 index, so a
concurrent reader holds a handle the rebuild is closing. A `Mutex` around
that method and `#close` is the whole fix, and `#close` turns out to be
*already* benign under sharing — it drops the fd and the next call reopens
the same copy, so a co-owner pays a rebuild rather than a failure. That is
why no refcount is needed, and why the change is five lines rather than a
lifecycle.

MCP and LSP need a **pool**: refcounted child processes, and a `#close`
that must not kill another caller's in-flight JSON-RPC request. There is
no five-line version. So they stay one-agent-only: both are coding tooling,
coding is TUI work, and a TUI is one agent; being wrong is slow (jdtls
twice), never incorrect.

The win is worth naming because it is not merely safety: sharing one Gloda
pays the multi-hundred-MB snapshot copy and the ~1 s index rebuild once for
the machine instead of once per agent — and the rebuild is not rare, since
Gloda's change counter bumps on read/star/tag flips during ordinary triage.

**Alternatives rejected.**

- **Close item 4 as `P_one_agent` too, for symmetry with MCP/LSP.** The
  honest competitor, and the one the house rules lean toward — five lines
  nothing exercises is speculative work for a host nobody has asked for.
  It loses because the asymmetry above is real: declining a *pool* and
  declining a *mutex* are not the same refusal, and pretending they are
  would have made the eventual multi-agent host pay a redesign for what a
  keyword and a lock buy now. The regression guard is the spec: it fails
  with the lock removed (verified), so the lock is not decoration.
- **A process-wide `Gloda.for(path:)` registry, refcounted.** The shape
  that "share the rebuild" first suggests. Rejected on two counts: it
  reintroduces the hidden cross-agent global that `D_per_process_temp`
  removed, and the refcount it exists to provide is unnecessary once
  `#close` is benign. Sharing is expressed by *handing the same object to
  both agents*, which needs no registry.
- **An `Extension.new(gloda:)` injection seam, now.** Deferred, not
  refused. The seam has to hand `on_close` ownership back to the host, and
  that is a lifecycle decision worth making with a real host in front of
  it. Until then a host that wants sharing builds the backend and registers
  the tools on their existing `backend:` keyword itself — no new API. Left
  as a stated non-feature in {Pikuri::Thunderbird::Extension}'s yardoc so
  the next reader doesn't re-derive the question.
- **Giving `Calendar` a `with_fresh_dbs` seam to match Gloda's.** Pure
  symmetry; it would restructure three working methods to make two classes
  rhyme. The guard sits on each public query instead, and the class doc
  says so.

**Consequences.** The five Thunderbird read tools inherit
`P_shared_locked` from their backend. `thunderbird_mail_compose` stays
`P_one_agent` on its *own* account — the human at the compose window is the
serialization point — which is the `D_tool_sharing_postures` rule that the
two axes stay independent, now with a worked example.

---

## D_tool_cancellation — An interruptible sleep on the token, opted into per tool (2026-08-28)

**Status:** Accepted; implemented 2026-08-28 as
{Pikuri::Agent::Control::Cancellable#sleep} + `Cancellable::NEVER`, a
`cancellable:` argument through `Tool#run` / `#to_ruby_llm_tool`, and
`web_search` as the first consumer (the {Pikuri::Tool::Search::RateLimiter}
pacing wait).

**Context.** Cancellation only fired at `before_tool_call`, so a tool that had
already started could not be interrupted at all. The sharpest case is the
search rate limiter: it holds its mutex across the HTTP call, so under
concurrent agents a queued one waits out everyone ahead of it with a user
cancel sitting unread. Graduated from `ideas/concurrent-tool-use.md` item 2,
whose first proposal — reserve a time slot instead of holding the lock — was
dropped as a complicated way to get at a simpler problem.

**Decision.** `Cancellable` grows an interruptible `#sleep(seconds)` that
raises `Cancelled` if the flag trips while waiting, and code that paces or
polls waits through it instead of `Kernel#sleep`. Tools opt in with
`wants_context: true` plus a `context:` keyword on their `execute` Proc;
`Tool#run` then passes a `Tool::ExecuteContext` — a `Data` type carrying
`cancellable` today and whatever a later call needs to know about *this
invocation*.

Per *call*, not per construction, and that is the load-bearing half:
`#to_ruby_llm_tool` mints a fresh wrapper per agent, so even a tool shared
between ten agents (`web_search` is `P_shared_locked`) honours whichever one is
actually waiting. Constructor injection — which is what `pikuri-lsp` already
does — cannot express that, because a shared tool would hold one agent's token.

The token is always a real object, defaulting to `Cancellable::NEVER` (a frozen
never-tripping instance) rather than `nil`, so there is one wait path instead of
a `cancellable ? … : …` branch at every site, and an `execute` never nil-checks
what it was handed. `NEVER` is frozen so a stray `cancel!` on it raises rather
than silently cancelling every agent that defaulted to it.

**Alternatives rejected.**

- **A `ConditionVariable` instead of polling.** The textbook answer: exact
  wake-up, no latency, no wasted timer ticks. It loses on one hard constraint —
  `cancel!` is documented as callable from a **SIGINT trap**, and taking a
  `Mutex` in trap context raises `ThreadError`. A CV wake-up wants the
  signalling side to lock and broadcast. Polling puts the cost on the waiting
  side and keeps `cancel!` a bare flag write, preserving the class's existing
  "a plain boolean suffices under MRI" argument. The price is ≤`SLICE_SECONDS`
  (100 ms) of cancel latency, which no human perceives.
- **Handing every tool's `execute` a `cancellable:`.** Uniform, no per-tool
  decision to get wrong. Rejected on scope: a token only reaches *waits*, and
  `lib/` has four real sleeps. Everything else that blocks is blocked in **IO** —
  Faraday reads, `Subprocess#wait`, sqlite — which no token can interrupt
  (`bash` needs a SIGTERM to the child, not a flag). Handing all 35 tools one
  would advertise an interruptibility most of them cannot honor, and ~25 have
  nothing to cancel at all.
- **A thread-local `Thread.current[:pikuri_cancellable]` set around the tool
  call.** The idiomatic-looking Ruby answer, and it directly contradicts the
  contract in `D_tool_sharing_postures`: `Agent` is thread-unsafe but *not*
  thread-confined, so nothing may key off `Thread.current`. It also dies the
  moment a tool spawns a thread of its own, and it is action-at-a-distance in a
  codebase that injects every collaborator explicitly.
- **Inferring the opt-in from the Proc's signature** (`execute.parameters.any?
  { |kind, name| name == :cancellable }`). Written that way first: zero churn,
  and impossible to desync from the lambda. It reads as magic at the one place
  a reader goes to understand the tool contract, and the reflection is doing
  work a boolean states plainly. The desync it protects against turns out to be
  a non-issue, because `context:` is a *required* keyword: flag without keyword
  and keyword without flag are both `ArgumentError` on the first call.
- **Putting the arguments inside the context too** (`context.args[:query]`, one
  object carrying everything). The tidier shape, and rejected on a measurement:
  `Parameters#validate` returns only the keys the model sent and applies **no**
  defaults, so 18 of the 36 bundled `execute` lambdas declare theirs in the
  signature (`max_results: 10`, `limit: DEFAULT_LIMIT`). Folding arguments in
  strands every one of them, and rewriting 36 lambdas to `ctx.args[:foo]` costs
  the kwarg ergonomics that make a tool definition readable. Reopen if
  `Parameters` ever grows a real `default:`, which would remove the blocker and
  is worth having for its own sake.
- **Passing the context to *every* `execute`, no opt-in.** The simplest possible
  contract, at the price of 25 tools declaring a parameter they ignore and a
  breaking change for every downstream tool.
- **A new `InterruptedError` for tools to raise.** `Cancelled` already is the
  vocabulary: `run_loop` rescues it, emits `Event::Cancelled` and re-raises, and
  ruby_llm rescues nothing on the tool path (`RubyLLM::Tool#call` and
  `Chat#execute_tool` both let it through), so a raise from inside a tool
  reaches the loop unaided. A second exception would need the same handling
  everywhere and distinguishes nothing a caller acts on.
- **A keyword rather than a positional for `Tool#run`'s second parameter.**
  Written that way first, and it broke ~16 specs across two gems. Give that
  method *any* keyword and Ruby 3
  re-reads the bare hash in `tool.run('text' => 'hi')` as keywords, so `args`
  arrives empty at every existing call site — including downstream ones nothing
  here would catch. A positional optional second parameter keeps every caller
  working verbatim. `#to_ruby_llm_tool` keeps a keyword, because it previously
  took no arguments at all and has no bare-hash call sites to break.
- **Making the mutex *acquisition* interruptible too**, by polling
  `Mutex#try_lock` with explicit `lock`/`unlock`. `cancellable:` covers the
  pacing wait, which is what the lock *holder* is doing; a caller still parked
  waiting to acquire cannot observe its own cancel. Deferred — it needs three
  concurrent agents to matter, and every agent that cancels already releases
  early and drains the queue faster.

**Consequences.** The cascade treats `Cancelled` as fatal rather than as a
provider failure: it is not caught by the `Unavailable` rescue, so no other
provider is tried and nothing is cached. That is intended — cancel means stop,
not "try Brave instead". A cancel landing mid-tool-batch leaves the chat holding
an assistant `tool_calls` message with no `:tool` reply; that hazard is
**pre-existing** (`check!` already fires before each call in a batch), but
making cancellation reachable from more places makes it likelier. Settled by
`D_unwound_batch_repair`, which found the real scope — any exception out of a
tool does the same thing.

## D_tool_sharing_postures — A yardoc posture per tool, not a machine-readable field (2026-08-28)

**Status:** Accepted; implemented 2026-08-28 as a `Sharing:` line (or
`== Sharing` section) on every tool, with the vocabulary defined once in
{Pikuri::Tool} and the threading contract in {Pikuri::Agent}. The
CLAUDE.md *Conventions* bullet carries the invariant and its grep tripwire.

**Context.** A host wanting ten agents in one Ruby VM has to know, per
tool, whether one instance may serve all ten. Nothing answered it.
`Tool::CALCULATOR` obviously can (it is a shared constant, so there is no
other way); `Tool::WebSearch` looked like the interesting case and turned
out not to be, because its throttle state is neither per agent nor per
instance (see `D_rate_limiter_scope`); and the genuinely dangerous cases
were not tools at all. The house style had the *habit* without the
convention — four files saying four different things ("Agent-thread-confined",
"Thread-safe (the one backend that locks)", "Thread-safe.", "frozen,
session-less and shared") and thirty-odd saying nothing.

Nothing in `lib/` runs two agents concurrently today, so every failure here
is a host's, discovered in production. That is exactly the argument for
writing the answer down per tool rather than finding it per bug: these
failures are silent — a wrong observation, a lost keystroke — never a raise.

**Decision.** Two halves.

**`Agent` is thread-unsafe, and that is the whole guarantee.** The caller
prevents concurrent access by whatever means it likes — a thread per agent,
a mutex around every call, an actor mailbox. Deliberately *not*
"agent-thread-confined": a confinement guarantee is stronger, and it would
invite keying state off `Thread.current`, which nothing here supports since
an agent may legitimately be driven from a different thread on each turn.
{Control::Cancellable} and {Control::Interloper} stay the two sanctioned
cross-thread doors, which is why they carry locks and the agent does not.

**Every tool declares one of four postures**, in its yardoc, naming the
collaborator that owns the state: `P_stateless`, `P_shared_locked`,
`P_shared_benign` (an unprotected race the doc argues is harmless), and
`P_one_agent`. Because agents serialize their own calls, "may a second
agent have this?" and "is this reachable from two threads?" are one
question — which is what makes a single per-tool answer sufficient.

Two things the vocabulary is shaped to prevent. **`P_one_agent` is a fine
answer, not a defect** — most of what a tool knows is one conversation's
business, and MCP, LSP and the terminal confirmer are accepted as
one-agent-only today. And **the two axes stay independent**:
`Skill::Activation` locks *and* is per-agent, so thread-safety is never a
licence to share.

**Alternatives rejected.**

- **A machine-readable `Tool#sharing` field, alongside `trifecta_legs`.**
  The tempting one, and it will be proposed again: same shape, computed at
  construction, same "wiring time is when you know". It fails the test the
  legs pass — the legs have a *consumer*, {Pikuri::Trifecta}, which renders
  a report a human acts on. A `sharing:` field has none. A host cannot
  enforce it (it holds the tool, so it has already decided) and the
  framework cannot check it, because a tool does not know its agent. It
  would be a comment with a type signature and a second place to drift.
  Reopen if a consumer appears — a `Configurator` that refuses a
  `P_one_agent` tool already wired elsewhere would need the tool to know its
  agent first.
- **A `== Sharing` section on every tool, uniformly.** The original ask. It
  loses to the `writing-rdoc` rule that a header fronting a one-line
  contract *is* the noise: for most tools the honest answer is one line
  deferring to a collaborator, and thirty near-identical section headers
  would train readers to skip the five that carry real findings. So the
  posture is universal and the *heading* is earned — `== Sharing` where the
  story runs long (`Bash`, `WebSearch`, `Confirmer::Terminal`, `LspTool`,
  `Mcp::Servers`, `Tasks::List`), a one-line tail elsewhere. Coverage is
  greppable either way.
- **Making the shared constants per-agent factories** (`Tool.calculator`
  instead of `Tool::CALCULATOR`). Moots the question for exactly three
  tools, costs the readability the constants buy, and says nothing about the
  tools a host constructs — which is where all the state actually lives.
- **Locking everything so any tool may be shared.** Mutexes on
  `Tasks::List`, the workspace read record, the MCP wrapper hash. It would
  make sharing *safe* without making it *correct*: a shared task list still
  lets agent A complete agent B's plan. The first failure is semantic, and a
  lock cannot fix a semantic failure.
- **Leaving it to a spec.** `rake test` is single-threaded, and a race that
  reproduces one run in fifty is worse than no test. What is testable is
  *structure* (a limiter constant is class-level; one workspace's read record
  does not answer for another's), and that is not what a host needs told.

**Consequences.** Nothing enforces the postures, so the doc is the whole
contract — a `P_one_agent` tool wired twice fails silently, exactly as
before, only now the reader was warned. The sweep also surfaced four things
a threaded host would hit, none of them in a `Tool`, and sorting them
taught the more useful lesson: `Paths.new_temp` (per *process*, so a host
memoizing "the" temp dir hands ten agents one scratch space) and `Agent`
itself are real, while `Confirmer::Terminal` (two agents interleave prompts
and either can consume the other's keystroke) and `Listener::Terminal`
(scrambled stdout) are **demo chrome, not defects** — both exist for
pikuri's own single-threaded `bin/` scripts, and a real host implements
those seams itself. Proposing a `Confirmer::Serialized` decorator for the
first was library work whose value rested entirely on a demo's shortcut,
which CLAUDE.md's `bin/` doctrine exists to prevent; the fix was to say so
in the class doc. Deleting `Confirmer::Terminal` outright, or inlining it
into `bin/pikuri-code`, was rejected on the same doctrine read the other
way: 237 lines inside the demo makes the demo *less* readable, which is what
the doctrine is actually for, and it is the only place the warning-gated
retype — security logic a real host must reimplement — is demonstrated. So a
posture on a demo-only class states a *limit of that class*, never a backlog
item.

## D_rate_limiter_scope — A limiter is scoped to the resource it protects, never to the agent (2026-08-28)

**Status:** Accepted; already the implementation
({Pikuri::Tool::Search::DuckDuckGo::LIMITER} and its siblings are
class-level constants) — logged 2026-08-28 because the fork is invisible in
the code and a per-agent limiter is the plausible "fix" someone reaches for.

**Context.** "Is the DDG rate limiter per agent or per tool instance?" is
the natural question and both answers are wrong. What the limiter protects
is one egress IP (DuckDuckGo bans IPs that hammer the HTML endpoint) and one
API key's quota (free-tier Brave meters 1 req/s per key). Neither is a
property of an agent, and neither is a property of an `Engines` instance —
a host that builds one cascade per agent has not changed how many requests
leave the machine.

**Decision.** Scope a limiter to the resource, which here means a
class-level constant per provider: every agent in the VM queues behind the
same limiter, whether hosts share one `web_search` tool or build ten.
`Pikuri::Agent::Listener::RateLimited` is the same rule pointing the other
way — it paces one renderer's repaints, a per-listener resource, so
`for_sub_agent` mints a fresh one per child.

**Alternatives rejected.**

- **A limiter per agent** (or per `Engines`). Ten agents would fire ten
  simultaneous requests from one IP and earn precisely the ban the class
  exists to avoid. It is not a tuning choice; it defeats the mechanism.
- **A limiter per process, in a registry keyed by provider.** What the
  class-level constant already is, with indirection and a lookup.
- **Widening the scope to the machine** (a lock file, so two pikuri
  processes pace each other). Correct in principle — the IP is shared across
  processes too — and deferred: it buys a rarer collision at the cost of
  file-locking on the search path, and nothing has reported a ban from
  running two pikuris.

**Consequences.** Two, both documented on {Search::RateLimiter} and both
surprising the first time. The mutex is held **across the HTTP call**, so it
is a global queue, not just a pacer: ten agents searching at once serialize,
and a thread parked in `Mutex#synchronize` has no timeout, no queue position
and is unreachable by `Control::Cancellable` — a user cancel is observed
only after the call returns. And the circuit breaker is global, so one agent
tripping a soft-block cools the provider down for all ten (right, since the
block is IP-wide, but it reads as nine agents punished for the tenth's
search). The stall does **not** deserve the obvious
`try_lock`-and-fall-through-the-cascade fix (settled 2026-08-28): the
no-config default is DuckDuckGo alone, so there is nothing to fall through
*to*, and the fix would turn "wait 2 s" into "search failed". What shipped
instead is an interruptible pacing wait (`D_tool_cancellation`), which lets a
queued agent abandon the wait on a cancel without inventing a failure.
Bounding the wait so a backed-up provider is *skipped* stays deferred — it is
only coherent with two or more providers wired.

## D_search_engine_selection — The engine list is a validated set, and DuckDuckGo lost its exemption (2026-08-27)

**Status:** Accepted; implemented 2026-08-27 as
{Pikuri::Tool::Search::Engines.resolve} / `.config_from_h` +
`Tool::WebSearch.from_h`, wired from the `search:` block of
`~/.pikuri-examples-config.yaml`.

**Context.** `Engines#initialize` seeded the cascade with
`[DuckDuckGo.new]` and only ever *appended* keyed providers, so DuckDuckGo
was unconditional — and it is the provider most worth turning off. It is
the one that gets bot-blocked and rate-limited, and the one whose privacy
story is weakest for anyone who went and paid Brave (DDG relays web results
over Bing, so the query still reaches Microsoft). A host with a Brave key
could add Brave; it could not stop half its searches going to DDG anyway,
because the cascade shuffles.

**Decision.** An explicit `engines:` selection, validated at both host
entry points, plus a `search:` config block grouping it with the keys it
depends on:

```yaml
search:
  brave_key: BSA...
  exa_key: xyz
  engines: [brave]
```

Four rules carry it. **`engines:` is a set, not a preference order** — it
normalizes to `ENGINE_NAMES` order and the per-call shuffle stands.
**Absent `engines:` means "whatever the keys say"** — DuckDuckGo plus every
provider whose key is present, which is exactly the old behavior, so a
keyless host still gets DuckDuckGo and no config file is required to chat.
**An engine named without its key is refused**, as is an empty list, a
repeat, and an unknown name; a key supplied without naming its engine is
*fine* (parking a key you are not using today is not a mistake). And **the
allowlist is closed at three** — the `web_search` leg is
`egress_destination: :tool_vouched` on the strength of pikuri owning the
destination set, and a config file picking from a hardcoded list of three
keeps that claim true where a `url:` field would have voided it.

**Alternatives rejected.**

- **An ordered preference list** (try Brave, fall back to DDG). It reads
  like the obvious meaning of `[brave, duckduckgo]`, which is exactly why
  the set had to be documented loudly — but it is a different feature. The
  shuffle exists to spread quota across providers that each meter you, and
  priority order would concentrate every query on the head of the list
  until it exhausts. A host that wants Brave only can say so in one word.
- **A `disable_duckduckgo:` boolean.** Solves today's ask and nothing else;
  a fourth provider makes it two booleans, then three. A list of names
  states the whole selection in one place and its error messages can
  enumerate what is valid.
- **Requiring `engines:` explicitly.** Loud, but it puts a mandatory config
  file in front of a first chat, against the project's "start slowly"
  positioning — and the derived default is not a guess, it is what the keys
  already said.
- **Coercing bad input instead of raising** (drop unknown names, silently
  ignore an engine with no key). The failure mode is worse search results
  weeks later, with nothing in the log saying why. Same argument as
  {Pikuri::Lsp::Registry.from_h}: a config file cannot be type-checked by
  the person writing it, so it is validated on the way in.
- **Reading keys from `ENV`.** Standing rule, unchanged: CLAUDE.md
  "Environment is not a secret store".
- **Leaving the keys top-level and adding only `search_engines:`.** No
  migration to pay for, but it splits three settings that are only
  meaningful together, and the pairing is what makes an
  engine-without-a-key refusal legible at the point of writing.

**Consequences.** Moving `brave_search_api_key` / `exa_api_key` under
`search:` breaks existing config files, and an unrecognized top-level key
is *silently ignored* by every bin — the failure would read as "Brave
quietly stopped working". So each bin that wires search carries a
three-line guard aborting on a stale top-level key; it is a migration
tripwire, deletable once no config file in the wild has one. Order in
`engines:` will keep looking like priority to anyone who has not read the
docs, which is a cost the set accepts.

## D_history_value_type — A conversation leaves as a typed value, not a bag of hashes (2026-08-27)

**Status:** Accepted; implemented 2026-08-27 as {Pikuri::Agent::History} +
`Agent#export_history` / `#load_history!`. Closes issue #1. Graduated from
`ideas/history-round-trip.md`, now retired. Prior art for every decision in
this family: `COMPARISON.md` §"Conversation persistence and resume".

**Context.** Two downstream shells need conversation continuity —
pikuri-web switches between stored conversations, pikuri-tui wants
`/resume` — and the only route on offer was
`agent.instance_variable_get(:@chat).messages`. The issue proposed
`export_history # => [Hash, ...]`.

An exported conversation is *written to disk*. That makes it a **file
format**, not a return value, and a bag of hashes shaped like whatever
`RubyLLM::Message#to_h` emitted that week is a format nobody wrote down,
versioned, or validated.

**Decision.** A `Data` value — `History(version:, messages:)` with typed
leaves — that owns both directions of its own serialization. The class *is*
the schema; `parse` / `from_h` / `load` are the only doors in and each
raises rather than returning something half-built. There is deliberately no
"accepts a String or a Hash or a History" convenience: one way in means one
place validation could be skipped, i.e. none.

**Scope: the model-facing half, and only that.** Both shells render the
`Agent::Event` stream, not the message list, and that rendering is lossy on
purpose (tool results truncated to 200 chars, `SystemInjected` collapsed to
a one-liner, `Tokens` rendered as nothing). So the rendered transcript
cannot be rebuilt from the history, nor the history from the transcript —
pikuri-web reached the same conclusion independently and calls it "the real
fork". The event log is the *shell's* artifact, because the truncation
policy is the shell's. Likewise title, timestamps and conversation ordering:
the shell's envelope wraps ours.

**Versioning is additive-only, and `version:` is expected to stay `1`.**
Unknown *keys* are ignored so a file from a newer pikuri still loads;
malformed *known* keys raise; a version above `CURRENT_VERSION` is refused
outright rather than best-effort loaded. The survey is the evidence: no
system examined carries a per-record schema version it migrates on —
opencode's 30 SQL migrations never once rewrite the stored JSON's shape, and
grok-build reserves `deny_unknown_fields` for tool arguments and wire
protocols while never applying it to a session type. The earlier plan of
"one migration function per version bump, kept forever" was over-engineering
nobody in the field has needed.

**Alternatives rejected.**

- **The issue's `[Hash, ...]`.** A top-level array can never grow a sibling
  key. An envelope can — which matters because extension state is a live
  question (below). That alone settled envelope-vs-array.
- **Building on `RubyLLM::Message#to_h`.** It is not a serializer: it passes
  `tool_calls` through as a live `Hash{String => RubyLLM::ToolCall}` and
  `content` as a live `Content` whenever attachments exist, so `to_json` on
  it yields object `to_s` garbage. It also is not the inverse of
  `Message.new` — thinking flattens to two sibling keys going out and is
  taken as an object coming in. Once you are hand-writing the load half
  anyway, own both directions.
- **Patching `to_h` in `ruby_llm_patches.rb`.** That file is for defects on
  the live chat path, each pinned to an upstream issue. `to_h` is not broken
  for its purpose (Rails persistence) — it is just not our format. Building
  a disk format on a monkey-patched third-party method inverts the whole
  argument: the point is to stop depending on ruby_llm's internal shape.
- **`Marshal` or any binary form.** Unreadable, unhand-editable, and
  version-fragile across Ruby releases — for artifacts that outlive the
  process.
- **Persisting the `Chat` itself.** Drags connection, config, registered
  tools and callbacks along; ruby_llm already excludes those from
  `instance_variables` precisely because they do not belong in a dump.
- **An `Extension#export_state` / `#load_state` protocol in v1.** Probably
  eventually right, but a much larger surface with no evidence yet about
  which gap bites. PI ships a session model that persists the conversation
  and its cost and *nothing* else — no todos, no permission grants, no
  file-read state.

**Consequences.** A resumed conversation restores the *conversation*, not
the *session*: workspace read-marks, promoted skills and the task list do
not come back (all fail closed or cosmetically — and re-reading a file that
sat on disk is arguably correct). The rule for when that changes: **state
whose lifecycle matches the conversation may ride in it; state with a
different lifecycle must not.** grok-build's folder-trust store is the
clinching case — a trust decision has to outlive any one session, so it
lives in a global TOML, not a session file.

## D_history_container — One JSON object, and JSONL is a sniff away (2026-08-27)

**Status:** Accepted; implemented 2026-08-27. See {Pikuri::Agent::History}.

**Context.** A chat client writes often and reads rarely, so appending
rather than rewriting looks like the obvious shape — three of the five
harnesses surveyed use an append-only JSONL log. The question was whether to
write JSONL from the start so a later version could simply append.

Measured first, on a whole-file rewrite (`JSON.generate` + temp file +
atomic rename, mean of ten):

| conversation | file | per turn |
|---|---|---|
| 200 messages @ 1.8 KB | 0.39 MB | 1.9 ms |
| 2000 messages @ 1.8 KB | 3.86 MB | 15.7 ms |

Against a turn that spends seconds on the model, that is 0.05–0.5%. The
write-often instinct is right about the access pattern and wrong about the
constant — and 2000 messages is already past where context management forces
a compaction.

**Decision.** One JSON object per conversation, rewritten wholesale. What
earns it is not the measurement but the **1:1 property**: `to_json` and
`parse` are literal inverses, the golden fixture *is* the format, and there
is no writer/reader layer that can be wrong on its own. Header-plus-records
makes the file an *encoding* of the value instead of the value.

Deferring is safe because adopting JSONL later is **not a version bump and
not a migration** — it is a sniff: *if the whole file parses as a single JSON
object it is the v1 container, otherwise read it as JSONL.* Three lines,
nothing on disk rewritten, every file ever written still readable. That is
what makes this reversible rather than a bet.

Whole-file rewrite is also *safer* than append: with temp-file-and-rename the
file on disk is always a complete valid history, so there is no torn state to
detect. Append trades that guarantee for O(1) writes.

**Alternatives rejected.**

- **Storing the history as one long line, "so it is trivially JSONL too".**
  It is valid JSONL, but its record type is *an entire history*. The first
  append leaves line 1 an envelope holding every message and lines 2..N bare
  messages — permanently bimodal, two record types for every reader forever,
  and the one-line-one-record property never holds. It also costs
  diffability immediately: a single-line blob is one wholly-changed line in
  `git diff`.
- **Numbered `1.json` / `2.json` segments rolled at a size threshold.** Each
  segment is a JSON *array*, so appending means either rewriting it
  (defeating the purpose) or omitting the closing `]` and repairing on read
  — which is JSONL reinvented, plus a rotation threshold, a naming scheme,
  an ordering rule and a which-segment-is-current question that JSONL does
  not have.

**Consequences.** If append ever becomes real it is JSONL, and the reader
must tolerate a torn last line (crash mid-append: drop it, keep the rest) —
PI's pattern, and the reason it needs one. Note also that the append-only log
the instinct reaches for already exists one layer up: grok-build treats its
event log as ground truth with the model-facing transcript as a rebuildable
cache, and pikuri-web plans exactly that split. `History` is the derived
snapshot, and a derived snapshot wants wholesale rewrite.

## D_history_attachments — Two encodings, one folder, and files that rot (2026-08-27)

**Status:** Accepted; implemented 2026-08-27. See
{Pikuri::Agent::History#save}, {Pikuri::Agent::History::Attachment}.

**Context.** `Workspace::Read` hands the model images as a
`RubyLLM::Content` whose attachment source is a **workspace path**. An
exported conversation therefore has to decide what an attachment *is* on
disk.

**Decision.** Two encodings of one in-memory value: `#to_json` inlines
attachments as base64 for a single self-contained artifact; `#save(dir)`
writes `history.json` plus content-addressed files under `attachments/`.
Both load back to the same value — pinned by
`History.load(dir) == History.parse(json)`, which is what stops them
drifting into two formats.

**Attachments live in the history's own folder or the history does not
load.** No sanitizing a bad path into a good one, no escape hatch for a big
file. A reference is a bare basename, and the check compares the
**resolved** path — a file sitting in `attachments/` may itself be a symlink
to `~/.ssh/id_ed25519`, which every textual check passes. `parse` refuses a
file-backed history outright (a String has no folder to resolve against) and
names `load` instead of guessing.

**`save` never deletes, and never enumerates the folder.** An attachment the
history no longer references — after a compaction, say — simply rots there.
pikuri writes into that folder but does not own everything in it, and
removing a file a human put there is a worse failure than an orphan. Its
only read is a `stat` per *referenced* attachment (skip if already present,
the name being content-addressed), so a folder holding a thousand stale
files costs nothing per save.

**Alternatives rejected.**

- **A path reference to the original file.** Smallest on disk, and the
  failure is invisible: the bytes are re-read at load, so a resumed
  conversation can show the model a *different* image than the transcript
  says it saw, or `ENOENT`. opencode does this for `@file` text mentions
  while inlining everything else — which reads as drift rather than design.
- **Degrading to the metadata note**, dropping the attachment. Cheap, honest,
  and breaks the round-trip property: a resumed vision conversation is
  missing the picture it is discussing.
- **Lazy attachment handles** in a `History` loaded from a folder. Saves
  memory, reintroduces exactly the path-reference failure (the folder can
  change or vanish underneath), and breaks `==` and therefore the
  convergence property above.
- **Sweeping unreferenced attachments**, or reporting them so a host can.
  The report was dropped because nothing consumes it, and it was the only
  reason `save` would scan the directory at all.

**Consequences.** Orphans accumulate silently and nothing will mention them
— bounded by what one conversation produced, content-addressed so they can
never collide. If it ever matters the answer is `rm`, not a feature. And
attachment bytes are re-tagged binary on construction: the same PNG arrives
as `UTF-8` from a source file and `ASCII-8BIT` from base64, and two
differently-tagged copies are not `==` — which would quietly break the one
property the design rests on.

## D_history_local_ids — Every message gets an id pikuri mints and no provider sees (2026-08-27)

**Status:** Accepted; implemented 2026-08-27. See
{Pikuri::Agent::History.mint_id}, `Agent#track_message`.

**Context.** Does a stored message need an id, and does anything upstream
supply one? Verified against ruby_llm 1.16 rather than assumed: **no
provider puts a message id on the wire.** OpenAI's formatter emits
`{role, content, tool_calls, tool_call_id}`; Anthropic's emits
`{role, content: [blocks]}` where the only ids are `tool_use.id`. The `id` on
a *response* identifies the HTTP response, not a message you send back. And
`RubyLLM::Message` has no `id` attribute at all, so there is nothing to
preserve — only something to mint.

**Decision.** Mint one anyway, plus a `kind` (`user` vs `reference`, marking
what `append_reference_block` injected). Both are local-only and never
reach a provider. The reason is not the wire but the **render/replay fork**
(`D_history_value_type`): the shell keeps an event log beside the message
list, and without ids nothing can say *this rendered block is that message*
— array indices stop answering the moment anything is appended.

Ids are minted **at message creation, not at export**, so two exports of one
conversation agree and a host's stored reference stays valid. They are
monotonic and lexicographically sortable (opencode's rationale: ordering
falls out of the id, and imported records keep their own without a rewrite).

**v1 is a flat list, not a tree**, even though Claude Code and PI both store
one (`parentUuid` / `parentId`) and branch points are common in Claude Code's
transcripts in practice. No pikuri consumer has asked for in-conversation
rewind — pikuri-web switches *between* conversations. The migration out stays
cheap precisely *because* of the ids: a flat history's implied tree is a
linked list, so `parent_id` backfills from position, and a v2 that grows
branches need not invent identity for records that never had it.

**Alternatives rejected.**

- **No ids.** Cheapest, and leaves the shell unable to correlate its two
  artifacts.
- **Deterministic content-hash ids** (role + content + calls + index). No
  side table, nothing to desync, stable across exports of an unchanged
  conversation — but every stored reference silently changes the day the
  hash inputs change, i.e. on a pikuri upgrade. References here cross
  artifacts and persist on disk, so that is the worse failure.
- **An index-aligned side table**, the first design. It could drift out of
  step with `@chat.messages` silently if a message ever entered by an
  unwatched path, and wanted a length assertion as a tripwire. Keying the map
  by **object identity** removes the failure mode instead of mitigating it: a
  message pikuri never saw is simply absent, and export mints it a fresh id
  rather than pairing it with another message's.

**Consequences.** Re-check on a ruby_llm upgrade: OpenAI's *Responses* API
does carry per-item ids that must be replayed (grok-build stores one for
exactly this), and ruby_llm 1.16 has no Responses provider. If it grows one,
ids stop being purely local and this decision needs revisiting.

## D_history_load_repairs — The file is a record; the repair happens on the way in (2026-08-27)

**Status:** Accepted; implemented 2026-08-27. See
{Pikuri::Agent#load_history!},
{Pikuri::Agent::History#repair_interrupted_tool_calls}.

**Context.** A stored conversation can describe something a provider will
refuse. An assistant turn carrying `tool_calls` plus the results answering it
is one indivisible unit on the wire; a process killed mid-batch leaves the
calls unanswered, and replaying that is a hard 400 on OpenAI and Anthropic
alike.

**Decision.** Export faithfully — including a dangling batch — and repair at
`load_history!`, synthesizing an `INTERRUPTED_RESULT` observation for every
call that never got one. This is the one thing all five surveyed harnesses
agree on: every one of them repairs when building the request and leaves the
stored record untouched. Telling the model *"you asked, it did not finish"*
also beats dropping the assistant turn, which would erase that it ever
decided to call the tool.

**Validation is asymmetric, and an early draft had it self-contradictory** —
requiring `from_h` to refuse a history where any call went unanswered *and*
having load repair exactly that case. Both cannot hold: the validator would
make the crash case the one thing unloadable. What ships:

| | | |
|---|---|---|
| result with no call | refuse | unrepairable — the call cannot be invented |
| one call answered twice | refuse | a live race would dedup; in a *file* it is corruption |
| call with no result | legal, repaired at load | what a killed process leaves behind |

**A thinking block is dropped when the model changed** — the whole block, and
at both points identity can change, not just at load. That rode in here as a
corollary with a rationale that did not survive checking; it now has its own
entry, `D_thinking_block_replay`.

**A tool the agent no longer wires draws no warning.** A recorded call is
never re-executed; it is a record of the harness that made it. The only live
risk is the model retrying a tool it can see in its own context, and ruby_llm
already answers that with an observation naming the tools that *are*
available, so the model self-corrects. A load-time warning would duplicate a
recovery that fires only when needed and says more.

**Alternatives rejected.**

- **Refusing to export a dangling batch**, or dropping the unanswered
  assistant turn. Dropping erases the model's stated intent; refusing makes
  the crash case unexportable.
- **Boot-time reconciliation** of interrupted calls. opencode explicitly does
  none: the read-time rule is provably sufficient because the provider
  constraint is enforced on *every* request regardless of what is on disk.
- **PI's replay-safety classification** (`replay: "never" | "safe"`,
  committed before the effect runs, so a read-only call re-executes on
  restart). Genuinely nicer, but it needs intent journalled at call time —
  a live-agent durability feature, not something a history format can
  retrofit. Revisit if pikuri ever wants crash-resume rather than clean-exit
  resume.
- **Warning on tool-set drift**, which pikuri-web records its tool list for.
  That stays a *shell* concern, where a picker may still want to show "saved
  by a different harness".

## D_release_one_otp — One OTP code for sixteen pushes; stdin only, and re-run to recover (2026-08-25)

**Status:** Accepted; implemented 2026-08-25 in the top-level `Rakefile`
(`rake release`). Graduated from `ideas/release-otp-fatigue.md`, now retired.

**Context.** A release pushes sixteen gems, and at rubygems.org MFA level
`ui_and_api` every `gem push` is challenged — so a release meant sixteen
interactive OTP prompts. Worse than the tedium was the failure mode: a push
that failed partway through the fan-out (an expired code, a typo, a network
blip) aborted the task with the earlier gems already public and unyankable,
and the documented recovery was to burn a version number and release the next
patch.

Two questions decided the design, and both were settled rather than assumed:

- **A TOTP code is not single-use.** The maintainer's past releases spent one
  code on 3–5 consecutive pushes. So nothing needs to pay for freshness, and
  one code can authorize an entire release that fits inside one window.
- **Push order is not enforced.** rubygems.org's `Pusher` never inspects
  dependencies; `Dependency` carries an `unresolved_name` column for a
  dependency naming a gem it has never seen, and `Rubygem`'s
  `after_create :update_unresolved` resolves those once the name appears. The
  `GEMS` list keeps its topological order as documentation of the real
  dependency graph, but it no longer constrains scheduling.

**Decision.** Do everything slow and everything fallible *before* asking for
the code, then spend one deliberately fresh window on uploads alone: build all
sixteen gems, pre-flight them against rubygems.org, sleep to the next TOTP
boundary with narration, take one code on stdin, and push two-wide with the
code passed to each child through `GEM_HOST_OTP_CODE` and its stdin closed.

The load-bearing half is that **every step is idempotent**, which is what lets
the push phase carry no OTP state at all. There is no mid-flight re-prompt and
no carry-forward retry because *the recovery for anything is re-running the
task*: an already-published version is skipped and reported, and an applied
bump / existing commit / existing tag are passed over. That also turns the
pre-flight into a squatting check — "this exact version is already published"
(benign, a resumed run) and "this name is owned by someone else" (not benign)
are deliberately two questions, and the second refuses the release up front
rather than surfacing as a 403 deep in the fan-out.

**Alternatives rejected.**

- **Generating the code locally with `rotp`** — mint from a TOTP seed in
  `pass`, zero prompts, fully unattended. Genuinely attractive once
  reusability made it free of waiting. **Killed on cost/benefit:** it wants a
  gem dependency, a secret-store integration, and the TOTP seed living on the
  release machine beside the API key — a real collapse of the two factors —
  to buy the difference between *one* prompt and none. Kept as a contingency
  with a defined trigger: the push phase not fitting inside a single window,
  at which point no single-code scheme survives. Measured margin at v0.1.0 is
  **1.7×**, not the 4× estimated here before a release had ever been timed:
  sixteen gems pushed two-wide took 14.8s against a usable 25.6s (the 30s
  window less 4.4s of paste), leaving 10.9s. The trigger is therefore nearer
  than it looked, but the cheap lever — widening `PUSH_CONCURRENCY` — comes
  first, since the same uploads run 29.3s serial and would already overrun.
  Even then it is not the next rung — a parent-owned code with a
  carry-forward retry costs a couple of extra prompts and no dependency.
- **Dropping the account to MFA level `ui_and_gem_signin`** — zero prompts,
  zero code. **Killed** because it buys exactly what `rotp` buys while
  weakening authentication, and `rotp` already lost on a much smaller cost. If
  it is ever revisited, the caveat is load-bearing: a push-only key scoped to
  `pikuri-*` with an expiry set at creation, deleted after the release.
- **Supplying the code through the environment** (`GEM_HOST_OTP_CODE=… rake
  release`) — the obvious non-interactive shape, and **the trap worth
  recording** because it looks like it should work and silently makes things
  worse. Each `gem push` runs as a separate child; when the exported code goes
  stale each child independently discovers it, prompts, retries, succeeds, and
  throws the fresh code away on exit — so from the first expiry you get one
  prompt per *gem*. Beyond that it loses on ordering even when it works: a
  code handed over upfront starts dying immediately, forcing the task to build
  while the clock runs or to refuse. Asking on stdin *after* the slow phases
  inverts exactly that. Its only remaining claim was unattended operation,
  which it serves badly — a code pasted into a shell needs the same human a
  prompt does. Not to be confused with the plumbing: each child still receives
  the code *through* `GEM_HOST_OTP_CODE`. That is how it reaches the child,
  not an interface for supplying it.
- **Trusted Publishing (OIDC)** — the real end state: rubygems.org exchanges a
  short-lived CI token for a push token, so there is no long-lived API key and
  no OTP at all. **Deferred, not rejected.** rubygems.org supports GitHub
  Actions and GitLab CI, not Woodpecker, so today it means a GitHub mirror
  whose only job is the release workflow — a values call for a deliberately
  Codeberg-hosted project, not a technical one. Nothing here conflicts with
  it: an idempotent build-then-fan-out task is the same task a workflow would
  run, minus the OTP handling.
- **Sleeping only when the current window is short** — measure, and skip the
  wait in the ~3 runs out of 4 that already have room. **Killed** as
  optimising the wrong thing: a release is rare enough that a mean 15 s costs
  nothing, and the wait is not idle — it is exactly when the human fetches
  their authenticator. The conditional version also needs a threshold covering
  paste latency as well as push time, and can strand the human mid-paste with
  "that code is too stale, try again".

**Consequences.**

- The boundary is computed from the release machine's clock while the code is
  read off the authenticator's; a disagreement of *d* seconds hands the pushes
  a window of `30 − d`. This is the one assumption that **fails silently** —
  nothing reports a skewed clock. It is tolerated rather than fixed, and the
  generous margin is what buys it: a push phase of a few seconds inside a 30 s
  window absorbs well over 20 s of skew, and rubygems.org's TOTP drift
  tolerance roughly doubles that. Recorded at `wait_for_fresh_otp_window`.
- The fan-out width (two) is not load-bearing. With the builds hoisted out,
  each upload is well under a second, so the concurrency absorbs a straggler
  rather than fitting a budget; serial would also work. The sub-second figure
  is an observation, not a timing — worth confirming on the first real release.
- The bump commit now carries `Gemfile.lock`, which pins every path gem's
  version and so is rewritten by bundler the moment the constant changes.
  Committing only `version.rb` left the lock dirty after every release and the
  tag pointing at a tree whose lock disagreed with its own gemspecs.
- `rake release` accepts `DRY_RUN=1`, which runs the pre-flight, the bump, the
  builds, the window wait and the prompt for real and reverts the bump on the
  way out. A release is irreversible — a pushed gem can be yanked, but its
  version number is spent forever — so the rehearsal is what makes changing
  this task safe.

## D_lsp_direct_not_mcp — Write the LSP client; don't bridge one through MCP (2026-08-18)

**Status:** Accepted, shipped as `pikuri-lsp`.

**Context.** `pikuri-mcp` already exists, and maintained LSP↔MCP bridges do
too: isaacphi/mcp-language-server, Tritlo/lsp-mcp, bug-ops/mcpls,
ProfessioneIT/lsp-mcp-server. Wiring one would have been a *registry entry*
— config, not code — buying every language at once and letting someone else
absorb protocol drift. Their pitch is correct, too: a semantic answer costs
~50–200 tokens against dumping a file at the model.

**Decision.** A direct stdio JSON-RPC client, in its own gem, reusing
`Mcp::ClientWrapper`'s restart discipline rather than its transport.

**Why — four reasons, and the first is the one that generalizes.**

- **The transport is not the hard part.** Both paths terminate at the same
  `ruby-lsp` process over the same stdio JSON-RPC; the bridge adds a hop and
  a process. The actual difficulties — indexing readiness, capability
  gating, name→position, result capping, coordinate conversion — get solved
  somewhere either way, and through a bridge you inherit someone else's
  answers to all five with no way to correct them.
- **Two seams cannot be delegated at all.** `F_definition_candidates` and
  `F_reference_volume`: denylist filtering of walked paths, root
  confinement, and volume capping are post-processing pikuri must write
  regardless. At which point most of a client exists anyway, and the extra
  process is still being paid for.
- **It inverts the bounded-gem rule.** A direct client has a closeable
  threat model — read-only, no network, one long-lived child
  (`pikuri-lsp/DESIGN.md`). A third-party bridge is an opaque Go/TS/Rust
  binary with its own network posture and supply chain: widening the threat
  model to save ~200 lines of Ruby, in a project whose bar is "small enough
  to audit in an evening", and dragging a non-Ruby toolchain into a Ruby
  monorepo.
- **Teaching mandate.** A small LSP client is a good book chapter about how
  editors actually work. "Install this Go binary" teaches nothing.

**Rejected: depending on `language_server-protocol`.** The one plausible
Ruby dependency, and it is a *protocol SDK*, not a client: framing plus typed
structures, no lifecycle, no id correlation, no spawn, and an `Io::Reader`
shaped as a blocking whole-stream callback loop for a server's main loop. It
would have supplied forty lines of framing whose reader shape pikuri then
fights. Nothing else on rubygems is a client at all — `lsp-client` is a
35-byte empty placeholder, and every other promising name is a *server*,
because LSP clients live in editors and editors are not written in Ruby.

**Consequence.** Protocol drift is pikuri's problem now. That is what
`bin/pikuri-lsp-check` is for — a human-run diagnostic that re-measures the
findings in `pikuri-lsp/DESIGN.md` §Measurements against a live server and
reports *ok* / *DRIFT* / *no answer*, rather than a spec that goes green by
skipping.

---

## D_lsp_operation_surface — Ten operations from shipped harnesses; relay server glitches, never work around them (2026-08-18)

**Status:** Accepted, shipped. The enum is static and hardcoded in
{Pikuri::Lsp::Operation}; adding or removing a value is one line, so this is
a floor rather than a ceiling.

**Context.** Six live runs against ruby-lsp and jdtls found a real pattern,
and then the pattern turned on the method that produced it: *every server is
broken in its own way, and the ways do not generalize.* ruby-lsp advertises
a type hierarchy whose `subtypes` half is a `# TODO` (`H_subtypes_stub`);
jdtls's `workspace/symbol` cannot see a method at all
(`S_jdtls_types_only`); ruby-lsp crashes on a full-text `didChange` that
jdtls accepts (`S_rangeless_didchange_crash`); ruby-lsp's index
desynchronizes from its own document because of a typing-speed heuristic
(`S_index_desync`). There are language servers for thirty other languages,
each with its own list.

**Decision.** Two rules, and they are the same rule twice.

1. **The operation surface comes from harnesses that shipped one**, not from
   what two servers happen to implement. Claude Code and opencode ship an
   identical nine (near-identical tool text too, so they count as roughly
   one data point); grok-build ships six, a strict subset. pikuri ships that
   union plus two *measured* additions and one collapse:
   `goToTypeDefinition` (`J_type_definition_recovers_var`: with
   `var names = new ArrayList<>()` the type appears nowhere in the source,
   so nothing else recovers it), `supertypes` (`H_supertypes_no_substitute`
   — the one hierarchy operation that works on both servers, and the *chain*
   is what has no substitute), and `prepareCallHierarchy` run inside the
   tool rather than exposed.
2. **Server glitches are relayed, not worked around.** The tool reports what
   the server said and what it was asked; the model decides what to do about
   it. Three answers must stay distinct in what the model reads: *the server
   does not support this operation*, *the server answered nothing*, and *the
   server could not be asked*. Collapsing them is the most consequential
   defect in the shipped prior art — Claude Code's
   `No definition found. This may occur if…` is `F_empty_before_index`'s
   false premise verbatim.

**Rejected: an enum sized to what the two reference servers implement.**
That is a catalogue of two servers' glitches, and it says nothing about the
third. It also gets the answer wrong in both directions: `documentSymbol`
would have been cut (all three harnesses ship it, and `S_jdtls_types_only`
makes it the only route from a Java method *name* to a position), while
`subtypes` would have been kept.

**Rejected: a per-server known-stub list.** The obvious fix for
`H_subtypes_stub` — record that ruby-lsp advertises `typeHierarchyProvider`
but implements only half of it. It is unbounded work that gets one server
right, and a capability gate provably cannot catch the case anyway: one
provider key covers both directions, and ruby-lsp advertises it *truthfully*
for the half that works. With `subtypes` cut the case no longer arises, and
where it would, the answer is to relay the empty result.

**Rejected: per-server readiness predicates.** Closed by
`J_jdtls_defers_replies`: jdtls defers its replies during an import instead
of answering `[]`, so a false-early gate is harmless there and essential
against ruby-lsp. One generic quiescence-plus-debounce gate covers both, and
the feared config knob is not needed.

**Rejected: `subtypes` as an eleventh operation.** It went first to
`H_subtypes_stub`, then to the harness survey (nobody ships it), and finally
to `H_implementation_is_transitive` / `H_subtypes_direct_only`: on jdtls,
`goToImplementation` answers "list all subtypes" transitively in one call
and works on concrete classes, while `typeHierarchy/subtypes` returns the
direct children only. So there is **no server on which `subtypes` is the
best available answer**, and `findReferences` is not the substitute either
(`H_references_not_substitute`: exactly 1 of 4 hits was the `extends` site,
unlabelled).

**Rejected: exposing `prepareCallHierarchy`.** The one place pikuri narrows
a 2-of-3 majority. Exposing it hands the model an opaque
`CallHierarchyItem` to echo back; the prepare hop runs inside the tool, the
same collapse `workspace/symbol` gets.

**Also out, recorded so nobody re-proposes them:** `declaration` (marginal
against `definition` outside C-style header/impl splits), `completion` (an
agent writes whole files rather than completing at a cursor), and the whole
write half — `rename`, formatting, code actions — which needs the
`Confirmer` seam and ends the closeable threat model. Diagnostics are
deferred rather than rejected: all three harnesses surface them *without* a
diagnostics tool, as reminders appended to tool output.

---

## D_lsp_no_startup_timeout — No clock anywhere; block on the index and let the human be the timeout (2026-08-18)

**Status:** Accepted, shipped. One half of the original decision — *spawn
at boot* — was reversed before shipping; see Consequences.

**Context.** ruby-lsp indexes this repo in seconds; a cold jdtls import of a
Gradle multi-module project took 78 seconds (`J_warm_start`), during which
every request went unanswered until the backlog flushed
(`J_jdtls_defers_replies`). The obvious fifth registry field is
`startup_timeout:`.

**Decision.** No `startup_timeout:`, and no timeout at all. The first call
blocks until its server is ready, however long that takes.

**Why.** No value is defensible — 30s is wrong for Java, 300s is wrong for
Ruby — and what a timeout buys is a `"still indexing, try grep"`
observation, which is not information but a *decision point*: retry, wait,
or give up. "Wait" is the correct answer and the one thing no tool call can
express. Relaying an empty index state is the single case where waiting
beats relaying, because there is nothing in `[]` to reason about — and
`F_empty_before_index` is what an un-gated client hands the model instead: a
*successful* empty answer, from which it concludes the symbol has no
definition.

**Three things replace the clock, none of them a clock.**

- **Die on child death.** What a timeout actually guards is not a slow index
  but a server that never becomes ready: jdtls failing a dependency import,
  ruby-lsp's custom-bundle `bundle install` erroring, a second session
  finding the `-data` directory locked. Child exit is a *definite* answer
  and catches the common case earlier than any clock would.
- **`Cancellable` breaks the wait.** A blocking read never reaches a
  tool-call boundary, so a host's SIGINT trap would not fire; the wait polls
  the cancel flag. This is what makes "endless" acceptable — the human is
  the timeout, through a mechanism pikuri already has.
- **Progress is a domain event.** A silent three-minute stall is
  indistinguishable from a hang for the person watching. Not optional once
  the clock is gone.

**Rejected: a failure message that steers.** The death report says what
failed and stops: it never says "try grep". That would be the
`"still indexing, try grep"` observation arriving by a different door — a
failure message deciding the task's next step, when the model is the one
holding the task.

**Consequences.** *Spawn synchronously at boot* was the original companion
to this — cheap, and it made a missing binary raise immediately and loudly.
It was reversed on 2026-08-18 in favour of starting a server on **first
use**: a registry is machine state (which binaries you have installed), so
an unconditional boot spawn starts a JVM and a 78-second import in projects
containing no Java at all. Missing-binary loudness moves with it — first use
reports `"Error: cannot spawn ruby-lsp: …"` and the model relays it to the
human, which is one policy instead of two. What the reversal does *not*
touch is what this entry is about: indexing proceeds in the background and
the first call blocks, unbounded.

---

## D_lsp_scheme_fallback — Standard first, one hardcoded `jdt:` row, and never dereference a URI the server chose (2026-08-18)

**Status:** Accepted, shipped as `Lsp::Sources::SCHEME_REQUESTS`, which
holds exactly one row.

**Context.** A result is not always a file. jdtls answers a library
definition with
`jdt://contents/slf4j-api-2.0.18.jar/org.slf4j/LoggerFactory.java?=…`
(`J_library_is_not_a_file`) — a *handle, not a locator*, an index into that
server's own view of the classpath, closer to a file descriptor than a path
and meaningless to anything else. **There is no standard "read this URI"
request in the LSP that ships today, and no way to discover a server's
non-standard one**: `language_server-protocol` 3.17.0.6 does not mention
`textDocumentContent`, and jdtls, `zipfile:`, `deno:` and `sourcekit-lsp:`
each invented their own, documented in prose and announced nowhere on the
wire.

**Decision.** Every result renders as location + snippet, and the URI scheme
decides where the snippet comes from. Three tiers: `file:` is read through
the `Workspace` seam (with `Filesystem#denied?` applied, since a result is a
*walked* path — `D_walked_path_denylist`); a custom scheme is asked of the
**server that issued it**, standard 3.18 `textDocumentContent` first and one
hardcoded row second; `http(s):` and everything else is printed as text,
never dereferenced. A scheme with no row gets an inline reason, never a bare
count.

**Why the `http(s):` refusal is load-bearing rather than decorative.**
Fetching a URI the *server* chose would hand the gem an
attacker-influenceable egress leg, with the request itself as the
exfiltration channel — the data rides in the path. A dependency that names a
URL in its source map would break the gem's entire claim. pikuri already has
`fetch` and `web_scrape` for network reads a human asked for. The table may
therefore never gain a row that reaches the network; every row is a JSON-RPC
request to a child pikuri already spawned over a pipe it already owns, which
is what `D_lsp_trifecta_legs` leans on.

**Rejected: standard-only, no fallback row.** The principled position — the
protocol layer stays server-agnostic — and it makes the Java arm untestable
in practice: without the row, `J_init_options_required` and
`J_class_file_contents` compose into "library navigation returns a polite
refusal", which is the capability the typed half of the target was for.

**Rejected: a `content_request:` config field.** The same fallback,
parameterized: two arcane coupled strings the user must get right, in a file
format pikuri exists as a counter-move to. A protocol method is code, not
config — grok-build's C#-specific `solution/open` escape hatch is the same
mistake in a different costume. The table is a different animal: the user
writes nothing, it is named after a server rather than parameterized over
all of them, and it carries a **written deletion condition — delete the
`jdt:` row the day jdtls advertises `textDocumentContent`**, at which point
the standard path above it takes over with no other edit.

**Rejected: an `lsp_read` operation or tool.** The tempting shape — hand
back a URI, let the model ask for its text — reintroduces exactly the
chaining hop collapsed everywhere else, spends a round trip on something the
tool can do exactly, and hands the model a ~300-character `jdt:` URI to hold
and reason about. The tool inlines content itself, on the same path for both
the standard request and the fallback. If explicit loading is ever wanted it
lands as another `operation` enum value, not a second tool — and the
question to answer *then* is that inlining and explicit reads are not rivals:
a bounded snippet per result keeps `definition` usable
(`J_class_file_contents`'s 22 KB × the 45 hits `F_reference_volume`
measured), while an explicit operation is how the model asks for a whole
document.

---

## D_lsp_hover_file_uris — Rewrite the `file:` URIs inside hover prose; link only what `read` would open (2026-08-19)

**Status:** Accepted, shipped as `Lsp::Renderer#rewrite_file_uris`.

**Context.** `hover` is the only one of the ten operations whose answer is
*prose* rather than rows. The other nine come back as `Location` /
`SymbolInformation` / `CallHierarchyItem` structures, and every one of them
renders through `Sources#label_for` and `Sources#denied?`. Hover's `contents`
is one opaque markdown string — the server has already flattened its own
structure into it, so there is no link list to walk. ruby-lsp fills that
string with VS Code file links:

```
**Definitions**: [version.rb](file:///home/m/proj/lib/version.rb#L9,3-9,20)
```

Three things are wrong with passing that through. It is a **walked path that
reaches no `denied?` pass** (`D_walked_path_denylist`), so a definition
inside a credential root prints its absolute path. It is a **dead-end
citation** — the `read` tool takes neither a URI nor a `#Lline,col` fragment
— while nine other operations spent their design on printing a path the
model can act on. And it is **expensive**: hover's whole value is quoting a
class comment, `MAX_HOVER_BYTES` is 3 KB, and each link burns ~90 bytes of
absolute path ahead of the documentation.

**Decision.** Every `file:` URI in the blob is rewritten, before the
truncation so the cap is spent on prose. Denied → a bracketed refusal, the
link dropped whole. Readable → the `label_for` citation with the fragment's
line, `path:line`, keeping its markdown link. Neither → the label alone
(`outside the workspace: entry.rb`), no link. A URI that arrived bare stays
bare. The rule in both directions: **never invent a link that was not there,
never keep one whose target `read` would refuse.**

**Rejected: pass it through as it came.** The renderer's own stated posture
(`D_lsp_operation_surface`) — pikuri cannot pre-empt thirty servers' failure
modes, so it relays glitches rather than smoothing them. That rule is about
a server's *behaviour*, though, and this is pikuri's own denylist obligation
arriving through a shape the row path does not cover. The rule still holds
for every byte that is not a `file:` URI.

**Rejected: parse ruby-lsp's `**Definitions**` line.** It knows the most
about the markdown and generalizes the least: the heading is ruby-lsp's own
invention, gopls emits no links at all, rust-analyzer emits different ones.
A scan keyed on the *scheme* treats all thirty servers alike and no-ops on a
server that emits nothing.

**Rejected: a bare or backticked citation, dropping the link.** Cheaper
still, and consistent with how a row cites. The link earns its ~15 bytes by
saying *this is a file that exists* — and once the refused and denied cases
degrade to plain text, link-presence carries the same signal `label_for`
already encodes, rather than a second one to learn.

**Rejected: keeping the `#L9,3-9,20` fragment.** It is VS Code's convention
for an editor that will place a cursor, and it carries **columns** — which
the whole tool refuses (`symbol`, never a column) and which produced a real
bug: two results differing only in column rendered as one row and counted
twice (`R_same_line_references`). A model finds the symbol on the line.

**Rejected: extending the scan to `jdt:`.** `Sources` can already label one
(`java.lang.String (rt.jar)`), so the objection is not semantic — it is that
a `jdt:` URI carries an entire classpath entry in its query, runs to ~300
characters and has **no reliable end inside a sentence**, where a `file:`
URI stops at whitespace or `)`. `http(s):` stays untouched for a different
reason: a URL in a docstring is prose, not a result, and it is never
dereferenced either way (`D_lsp_scheme_fallback`).

---

## D_lsp_document_sync — Re-open the document around every call; never send an edit stream (2026-08-18, revised 2026-08-19)

**Status:** Accepted, shipped. The policy and its mechanics are
{Pikuri::Lsp::ClientWrapper#open_document} and
{Pikuri::Lsp::ClientWrapper#close_document}; the measurements behind it are the
`S_` family in `pikuri-lsp/DESIGN.md` §Measurements; the teaching version is
`book/lsp.md`. Revised 2026-08-19 to send the `didClose` the original decision
declined — see *Balancing the open* below.

**Context.** LSP's document model assumes the client is a text editor: you
`didOpen` a document, stream `didChange` edits as a human types, and the server
holds a buffer the disk may not have seen for hours. An agent inverts that at
the root — `write` and `edit` land on disk immediately, so the tool never owns
text the disk lacks. Yet the servers still presume that *a client which opened a
URI is that document's authority* (`S_watched_files_ignored`, stated outright in
ruby-lsp's source), which is exactly the assumption an agent writing straight to
disk breaks.

**Decision.** Re-send `textDocument/didOpen` with the file's current disk text
before every position-based call, and `textDocument/didClose` once that call's
last reply is in (`S_reopen_works`). No open-URI set, no version counter, no
digest. Re-opening a document already open is spec-forbidden — *a document must
not be opened twice* — and neither reference server minds; balancing the pair
per call is what keeps that the only deviation.

**Why the alternatives all lost, one measurement each.** The first is not
spec-legal and the rest are.

- **Rejected: a rangeless whole-document `didChange` — and it was never ours to
  send.** The obvious "here is the new text" move leaves jdtls correctly updated
  and *crashes* inside ruby-lsp, which reads `edit[:range][:start]`
  unconditionally (`S_rangeless_didchange_crash`). The document keeps its old
  text, a notification has no reply channel, and the only report is a
  `window/logMessage` line — what the model sees is the next query failing with
  a raw backtrace. Both visible harnesses sync this way, and grok-build's own
  `capabilities.rs` opens by describing the same failure against *Roslyn*: the
  finding independently confirmed on a third server. But the reason it loses is
  the contract, not the crash. Both servers advertise **incremental** sync, and
  `TextDocumentSyncKind` is the *server's* declaration of which arm of the union
  it accepts — a client must support both so it can comply with either, never
  pick. Shopify closed that report three times (ruby-lsp #575, #1273, #3148; in
  #1273 the reporter wrote the ycmd client and came round to it), so a server
  that started tolerating the shape would still not make it usable. That is also
  why it is the one finding `bin/pikuri-lsp-check` does **not** probe: the
  response to a message the server never agreed to accept is undefined, so no
  outcome could inform this decision.
- **Rejected: the ranged whole-document `didChange`.** Honoured by both servers
  for the document, and then it desynchronizes ruby-lsp's *index* from the
  document it just updated (`S_index_desync`): `documentSymbol` reports the
  renamed method while `definition` on it returns `[]`. `RubyDocument#should_index?`
  reindexes only when the edit's start position looks like a declaration, and a
  whole-file replace starts at 0:0 — the `frozen_string_literal` comment. The
  optimization that makes editor typing cheap makes whole-file replacement
  invisible.
- **Rejected: `didClose` and forget.** Drops ruby-lsp's store entry so the next
  request re-reads disk, and does nothing at all on jdtls, which keeps answering
  its pre-close copy (`S_didclose_ruby_only`). Not portable, which is what
  promotes re-opening from an option to the policy.
- **Rejected: `workspace/didChangeWatchedFiles`.** The spec's own out-of-band
  "the disk changed" channel changed nothing on either server while the client
  held the URI (`S_watched_files_ignored`).
- **Rejected: version or digest bookkeeping on top of the re-open.** There is
  nothing to reconcile when the text always comes from disk, and the bytes are
  already in hand: they are the text the tool read to derive the column.

**Balancing the open.** The first version of this decision sent no `didClose`,
on the grounds that neither reference server needed one: ruby-lsp drops its
store entry and jdtls ignores the close outright (`S_didclose_ruby_only`), so
the close bought nothing measurable. That reasoning was the wrong shape. The
spec caps a document's open count at one and asks for the pair, and a client
that only ever opens is not relying on a measurement — it is relying on two
servers' *tolerance*, which no amount of testing on more servers can turn into
a guarantee. A pyls or gopls that trusted the count could leak a document per
call, answer from a stale buffer, or block; measuring three more servers would
only postpone the question. So the close is sent because it is owed.

**Rejected: closing per request rather than per call.** `supertypes` and the
call-hierarchy operations issue a `prepare` hop and then a request per level
against one document, so a close after each request would hand the later ones a
document the server had already dropped. The pair brackets the whole
`Navigator#navigate`, in an `ensure`, so a refusal or a death still balances.

**Rejected: firing the close alongside the request.** "Immediately" has to mean
*after the reply*, not concurrently with it. ruby-lsp happens to be safe either
way — one worker thread, one incoming queue, strict order — but that is one
server's implementation detail, and a server answering requests in parallel
could process the close first and answer about a document it had just dropped.
Since `request` already blocks for its reply, waiting costs nothing.

**Rejected: restarting a dead child to deliver the close.** Every other
notification here retries through `with_restart`; this one must not. A dead
child holds no open documents and a respawned one never received the matching
`didOpen`, so a retry would deliver a close that only the new process finds
confusing. `close_document` checks liveness, swallows `Connection::Closed`, and
never raises — it runs from an `ensure`, where raising would replace a served
answer with a teardown failure.

**Consequence.** The re-open half rests on server behaviour rather than on the
specification, so it is pinned by a probe rather than by a reading:
`bin/pikuri-lsp-check`'s `S_reopen_works` row re-measures it against the
server actually installed, opening and closing as the library does. The close
half needs no probe — it is a contract, not a measurement, and the specs pin
the ordering against the fake server.

**Consequence — observing the agent's own edits is deferred, not open.**
grok-build also syncs from the *write* path (`notify_file_changed(path,
content)`), and pikuri should eventually too; the shape is settled so the
deferral is a scheduling choice:

- The event is emitted by `Workspace::Workspace`, beside the read-before-edit
  ledger it already owns, and bridged to `ctx.emit_event` in
  `Workspace::Extension#bind` — the `Tasks::Extension` shape. `WriteGate` is the
  wrong hook: it is stateless, it runs *before* the write, and a refused write
  must not notify.
- The payload is the path, never the bytes; every consumer reads content through
  the `Workspace` seam anyway.
- It must never be load-bearing. `bash`, `git checkout` and any build the agent
  runs also write files, so an edit notification is *structurally* incomplete —
  re-opening on read stays the correctness guarantee, the same split
  `D_walked_path_denylist` draws between `denied?` and `denied_roots` pruning.
- The event fills a dirty set the next `lsp` call drains, coalesced per path, so
  a 50-file refactor is not 50 re-opens; that is also the second caller
  `Lsp::Mailbox` was waiting for.
- What it buys over re-open-on-read is one measured thing: a file the agent has
  just *created* is invisible to `workspace/symbol` until something opens it
  (`S_index_follows_didopen`), and under re-open-on-read nothing opens it until
  the model asks a position question naming that exact file — so symbol-only
  lookup of a just-written class fails. The other gains are softer: jdtls
  rebuilds ahead of the next call rather than during it, and this is the
  precondition for surfacing diagnostics after an edit, which all three
  harnesses do *without* a diagnostics tool (also deferred, per
  `D_lsp_operation_surface`). It changes no `pikuri-lsp` interface, so shipping
  it later costs one listener arm.

---

## D_lsp_trifecta_legs — `:no_egress` despite a child that goes online, and `untrusted: :hard` unconditionally (2026-08-18)

**Status:** Accepted, shipped on the tool. The posture as it stands is
`pikuri-lsp/DESIGN.md` §"Threat model"; this entry is the forks.

**Context.** `Mcp::Extension` declares `ASSUMED` unconditionally, and both
gems spawn a user-configured foreign stdio binary with inherited env and no
sandbox — so "why doesn't `lsp` declare what `mcp` declares?" is a fair
question with a non-obvious answer. One declaration, three axes, questioned
once.

**Decision.** `private:` rides the host's answer, `untrusted: :hard`
unconditionally, `egress_payload_review: :no_egress` — declared on the
*tool*, with `Lsp::Extension` contributing nothing.

**Rejected: tagging egress on the vetted-destination argument.** The
tempting version is that a well-behaved server only fetches from a vetted
set of hosts (jdtls pulling a jar from Maven Central), which is too weak to
tag. That argument must not be written down, because it argues for the
opposite of its conclusion: `D_egress_axis_shape` rejected a
`:safe_vetted_set` rung outright, so "vetted destination" is a *rung* and
the phrasing lands `lsp` on the map as `:tool_vouched` + `:unreviewed`
forever. It is also untrue — the hosts come from the project's
`build.gradle` / `settings.xml`, so they are project-controlled. The
argument that survives is the one that entry used to drop
`egress_human_author`: a seat whose outbound bytes do not originate in the
model's choosing holds no leg to grade.

**Rejected: inheriting MCP's `ASSUMED` on the shared foreign-binary shape.**
The distinction that breaks the parity is that **an MCP server contributes
model-callable tools with model-supplied arguments; an LSP server
contributes none.** One pikuri-authored tool, fixed schema, and pikuri
chooses every JSON-RPC request that leaves — no foreign tool surface, hence
nothing undeclarable. Declaring `ASSUMED` anyway would actively *widen* the
answer: `legs | ASSUMED` flips egress to `:unreviewed` /
`:attacker_reachable` (verified), the opposite of the measured truth.

**Rejected: riding `filesystem.trusted?` the way {Pikuri::Workspace::Read}
does.** `read` declares `untrusted: filesystem.trusted? ? :none : :hard`,
and that works because the vouching and the reach are the same set: the host
asked a human whether this checkout is trusted, and `read` is confined to
the checkout. `lsp` is not — the index reaches the whole bundle, jars and
the JDK (`J_index_reaches_jars`), and `H_ancestry_leaves_root` has a query
about a workspace class answering out of four unrelated gems. A user who
said "yes, I trust this repo" made a claim about the code they checked out,
not about four hundred transitive jars, nor a `-sources.jar` nobody has ever
diffed. Riding `trusted?` would stretch a human's answer past the question
they were asked.

**Rejected: confining results to the root to earn `:none`.** The first thing
someone will propose when the map goes loud. It deletes
`J_index_reaches_jars` — searching inside jars, the one thing grep can never
do — so the tag is *the price of the capability*, not a defect to engineer
away.

**Consequence, stated because a user will otherwise meet it as an
unexplained alarm.** On an untrusted checkout nothing changes; `read` is
already `:hard` there. On a **trusted** one, adding `lsp` to a wiring that
holds `fetch` or `web_search` lights the untrusted leg and can flip the
trifecta verdict, because `read` declares `:none` there and `lsp` does not.
That is correct rather than unfortunate — the jars were never vouched for,
and a trusted repo with a poisoned dependency is the realistic attack — and
`D_egress_axis_shape` already blesses declaring a true axis for the map's
sake when no verdict moves. This is the stronger case, where one does.

---

## D_de_bundlerized_children — Every long-lived child is de-bundlerized; no unset sentinel in config (2026-08-18)

**Status:** Accepted, shipped. `Pikuri::BundlerEnv` in pikuri-core; applied by
`Code::Bash`, `Mcp::ClientWrapper` and `Lsp::ClientWrapper`.

**Context.** pikuri boots under `bundler/setup`, and Bundler implements that by
rewriting the process environment — injecting `BUNDLE_GEMFILE` / `RUBYOPT`,
repointing `GEM_HOME` / `GEM_PATH`, prepending the bundle's bin dir to `PATH`,
and stashing each original under `BUNDLER_ORIG_*`. Children inherit all of it.
`Code::Bash` hit this first (a `bundle exec` the agent runs in *another*
project resolves against pikuri's Gemfile and dies) and fixed it privately.
`pikuri-lsp` then hit the same wall from a different angle: `ruby-lsp` refuses
to start at all — "can't find executable ruby-lsp for gem ruby-lsp" — unless
pikuri's own Gemfile happens to list it. A Ruby-written stdio MCP server has
the identical exposure and nobody had noticed.

**Decision.** The correction is pikuri's job, not the user's: every long-lived
child is spawned over `BundlerEnv.clean_delta`, with the entry's own `env:`
merged *over* it. `StdioEntry#env` stays `Hash{String=>String}` and learns no
unset sentinel.

**Why.** The child serves the *target project*, not pikuri, so it must see the
environment the user had before pikuri started. And this is a *restoration*,
not a filter: it undoes pikuri's own boot and nothing the user set, which is
why it doesn't breach the "environment is not a secret store" seam.

**Rejected: let `env:` express an unset, and document it as the user's job.**
The `bin/pikuri-lsp-check` workaround (`Bundler.with_unbundled_env`) is
available to a `bin/` script and not to a library host, so the first draft of
this fork asked config to carry it. Three problems. It is *incomplete* —
Bundler **changed** variables it did not invent, so deleting `BUNDLE_GEMFILE`
and `RUBYOPT` leaves the rewritten `PATH` and `GEM_HOME` in place; the delta
restores them from `BUNDLER_ORIG_*`, which a hand-written list cannot. It puts
pikuri-internal knowledge (that pikuri boots under Bundler at all) into the
user's config file, as boilerplate every Ruby-server wiring must copy. And it
would have fixed the LSP arm while leaving the identical MCP arm broken.

**Rejected: `FOO => ""` as the unset spelling.** Considered because a config
file "cannot express nil". It can — YAML has `FOO:` and `FOO: null`, JSON has
`null` — and the sentinel would collide with a real, different POSIX value:
set-but-empty is not unset, and `RUBYOPT=""` is itself a legitimate setting
(very nearly the fix for the case that raised this). Ruby's own spawn family
already spells removal as `nil`, and `BundlerEnv` relies on it, so a second
spelling would need a translation layer where none exists today.

---

## D_no_skills_in_sub_agents — A persona's brief is complete on arrival; no catalog, no `skill` tool (2026-08-17)

**Status:** Accepted; no code change. The plumbing that already enforces it
stays exactly as it is (see the third rejected alternative).

**Context.** Two halves of "does a sub-agent get skills?" were settled by
different accidents, and neither was settled on purpose.

The `<available_skills>` block is contributed by `Skill::Extension`, and
sub-agents don't inherit extensions — a blanket rule whose headline
rationale is privilege separation (`book/subagents.md`). So the block's
absence is a *consequence* of a rule argued for other reasons.

The `skill` **tool** is the open half. Tools reach a child by name:
`SubAgentTool` filters `parent.tools` by `persona.tool_names`, so a persona
naming `skill` would get it, and `SkillTool#for_sub_agent` already rebuilds
it over `Skill::Activation::Sealed` for exactly that case. Nothing has ever
asked — all four bundled personas (`RESEARCHER`, `FILE_MINER`,
`GIT_REPO_RESEARCHER`, `LIBRARIAN`) name narrow toolsets and no `skill`. The
mechanism is *prepared*, never *active*, and the question of whether it
should be has been answered by omission. This entry answers it deliberately.

**Decision.** A sub-agent receives no skills: no catalog in its system
prompt, and no `skill` tool. A persona that needs domain instructions carries
them in its own `system_prompt:`, which is the sanctioned route and the only
one.

**Why.** Privilege separation is *not* the argument here, and saying so
matters — a skill body is text, not a capability, so handing one to a child
breaches no boundary the no-inheritance rule protects. The case stands on
three other legs.

- **A persona is a closed brief, not a general agent.** The child gets
  `persona.system_prompt` *verbatim* — not appended to the parent's, which is
  invisible to it. {Pikuri::SubAgent::Persona}'s whole premise is that it is
  the single source of truth for what the child is. An agent that can pull in
  instructions its brief never mentioned is an agent whose brief is no longer
  complete, which trades a property that makes personas auditable for a
  convenience nobody has asked for. pikuri ships **no general-purpose
  persona**; every one is narrow enough that its full instruction set fits in
  the prompt its author wrote.
- **A skill body assumes a toolset the persona may not hold.** Skills are
  written against a general harness and say so: `SkillTool::DESCRIPTION`
  tells the model the loaded skill "may reference helper scripts and files in
  its base directory — use the `read` tool." That is dead advice for
  `RESEARCHER` (three network-read tools, no workspace) and worse than dead
  for `LIBRARIAN` (two corpus tools) — it spends context and invites a call
  that can only fail. Skills also bind to *ecosystems* rather than tasks:
  `writing-rdoc` fires on `**/*.rb`, which tells an agent whose job is
  retrieval from a vector corpus nothing it can act on.
- **Determinism.** A child reachable by the parent's promotions has a surface
  that depends on which files the parent happened to read — two identical
  `agent(name: 'file_miner', task: …)` calls in one session would see
  different skills because of unrelated earlier work. `Activation::Sealed`
  exists to prevent this; this entry is why it is welded shut rather than
  merely defaulted.

**Alternatives rejected.**

- **Let a persona opt in by naming `skill` in `tool_names:`.** Costs nothing
  to allow — the plumbing works today and the sealed view already narrows it
  correctly (ungated skills only). Rejected as the *posture*, not as an
  impossibility: it remains one word away the moment a persona has a real use
  for it. What it lacks is a case. "The author might add a skill later" is
  not one — that skill's content belongs in `system_prompt:`, where it is
  chosen rather than matched.
- **Thread extensions into the child so it gets the catalog block too.** Not
  on the table: that reverses the blanket no-inheritance rule, whose
  rationale is a security boundary (`tool_names:` is the child's entire
  surface, so a prompt-injected `RESEARCHER` has no `bash` to call) that has
  nothing to do with skills and should not be relitigated through them.
- **Delete the sub-agent plumbing as dead code** — `SkillTool#for_sub_agent`,
  `Activation::Sealed`, `PathActivationListener#for_sub_agent → nil`. It is
  unexercised by every bundled wiring, so it reads as dead. It is not dead —
  it is the *enforcement* of this decision for the opt-in path deliberately
  left open. Delete it and the next persona to name `skill` silently inherits
  the parent's promotions, which is precisely the accident
  `D_skill_path_activation` had to fix once already (it "held only by
  accident at first"). Unexercised guards against a future wiring are worth
  their lines.

**Consequences.**

- **The `paths:` gate is unreachable downward by construction**, which
  `D_skill_path_activation` records as accepted-rather-than-fixed. This entry
  is why it was accepted.
- **{Pikuri::SubAgent::Persona}'s yardoc is the place a persona author will
  look** and is currently silent in both directions; it should carry the
  one-line form of this decision, so it reads as one story with
  `SkillTool`'s header (which already carries the tool-side half).
- **Reopen when** a persona has a concrete need — a general-purpose sub-agent
  (there is none today), or one whose instructions genuinely vary per project
  in a way `system_prompt:` cannot cover. The cheapest move then is the first
  rejected alternative, not new machinery.

---

## D_reference_text_as_user_turn — Mid-conversation reference text is a wrapped `:user` turn, never `:system` (2026-08-17)

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
`system` is a top-level request param — so ruby_llm's provider splits every
`:system` message out of the array
(`messages.partition { |msg| msg.role == :system }`) and appends each one as
its own text block to that param (`build_system_content`).

Two failures fall out of that, not one, and the second is the worse of the
pair. The block is **mispositioned**: a promotion that fired at turn 5 is
presented as though it had been in the original prompt. And it is
**sticky** — the `system` param is standing instructions, in force for every
subsequent turn, so a one-shot becomes a permanent rule. That is bad for a
host-loaded skill; for a *per-turn* producer it compounds, because the
messages accumulate in `Chat#messages` and every one of them partitions into
the param on every request. pikuri-memory's prefetch is the worst case: by
turn 20 the request carries twenty standing blocks of stale recalled facts,
each still presented as a rule the model must follow. Nothing about
positional delivery does that, which is why the same block landing as
`:user` needs no Anthropic branch at all — the split moves `:system` and
nothing else.

grok-build's Anthropic converter does the same thing, and grok-build never
hits it because it has no mid-conversation system message to split out
(`COMPARISON.md`, *grok-build's injection channel*).

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
  the exact cost `D_skill_path_activation` weighed and accepted *not*
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

- **A host-loaded skill is no longer sticky on Anthropic.** It used to land
  in the `system` param and stay in force for the conversation;
  `schedule_load_skill` documented that as intentional. It is now a
  positional one-shot on every provider, identical to the `skill` tool's
  observation. Uniformity was judged worth more than the divergence — and
  that stickiness was a side effect of the split described above, not
  something anyone implemented, arriving bundled with a silent reposition
  the doc never claimed.
- **`Agent::EmptyTurnError` survives, and got narrower.** Its trigger was a
  `:system`-only conversation rendering `messages: []` on a provider that
  carries `:system` in a separate field — which used to include the
  "bare-load a skill, then run a blank turn" case. A drained reference
  block is now a `:user` message, so that
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
- **pikuri-memory's per-turn prefetch was inert against Qwen3.6**, and is
  now verified fixed — A/B against the live model with mem0's search
  stubbed to canned records, everything downstream real. Replaying the old
  `:system` delivery, the model answered *"I don't have any information
  about your car"* about a fact sitting in the payload; through the shipped
  path it named it. How long it had been inert was not measured
  retrospectively.
- **The `recall` tool was masking the broken prefetch**, which is most of
  why this survived so long. The first run of that A/B had the model answer
  *correctly* under the old delivery — it never saw the block, so it called
  `recall` and got the same facts that way. The symptom was therefore not
  "memory is broken" but "an extra tool round-trip and slightly worse
  answers on turns where the model didn't bother." Isolating prefetch took
  a stub that answers only the prefetch query. Worth remembering for the
  next silent-delivery bug: a fallback path is an *alibi*, and any test of
  an automatic tier has to disable the manual one.
- **A working prefetch removes a round-trip.** In the verified run the
  shipped path answered from the injected block with no tool call at all,
  where the `:system` delivery spent a `recall` call to get nowhere.

## D_slash_commands — Two registries, a user turn, and no scheduling function (2026-08-16)

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
  untrusted leg through `D_bundle_trust_grading`'s per-base channel.
- **`Trifecta::Contribution` gained a `label:`.** Extension legs used to be
  unioned into one row hardcoded as `(mcp)` — honest only while MCP was the
  only contributor. A second one made the banner blame an MCP server that
  wasn't wired, against `Report#attribution`'s whole purpose.
- **The chain's third leg landed 2026-08-17**, in `bin/pikuri-code` — the one
  bundled script wiring commands *and* skills, so it is the only place the
  full `host built-in > command > skill` order is observable. Three shapes
  chosen there, each over a live alternative. It is **argument-less**: a
  command is a template with `$ARGUMENTS` to interpolate, a skill body is
  fixed text, so an argument would have nothing to do — and `/name extra`
  silently ignoring the tail is worse than not offering it. It **enqueues
  without running a turn**, so the body arrives with the human's next
  message; the alternative — `run_loop(user_message: nil)`, the bare load
  `schedule_load_skill` documents — spends a completion on an
  acknowledgement, which is precisely the tax `feedback.txt`'s *"skill load
  costs a turn"* reported, and that this feature answers. And a *refused* name
  gets a **human-only** second line naming the skill as installed-but-gated,
  read from the unfiltered `Catalog`: decision 7 of
  `D_skill_path_activation` makes the gate answer the model as if the name
  existed nowhere, which is right for the model and useless to someone who
  just read that name in the startup banner. Nothing in that branch reaches
  the conversation, so the gate leaks nothing to the model.

## D_command_inlining_legs — No bash pre-execution, and `@path` is not a refusal (2026-08-16)

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

## D_command_substitution — Fence-aware, and the append reads the body the same way (2026-08-16)

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

## D_skill_path_activation — A `paths:` skill is not in play until its path fires (2026-08-16)

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

*Resident on every turn* survives the obvious objection — but only half of
it does, and knowing which half is what keeps this entry from being argued
in raw token counts. Caching means those bytes are **not** re-prefilled
each turn: the catalog sits in the stable system prefix, so llama.cpp's
slot prefix-reuse and Anthropic's prompt cache both skip it after turn one,
and cloud cache reads bill at ~0.1×. The compute framing of the complaint
is therefore simply wrong. Two costs no cache refunds, though, and they are
the ones this decision is about. **Window capacity:** cached tokens still
occupy KV slots, so 3.8 k tokens of a 64 k window is 3.8 k the conversation
cannot have — on a local GPU, VRAM held for the whole session.
**Attention:** every decoded token attends over the entire prefix, so
twenty-eight descriptions the current task will never use are twenty-eight
distractors competing on every single token generated. Both scale with
catalog **size**, which is why per-entry editing — worth doing, and
`when-to-use:` plus the `<location>` trim did it — cannot reach them, and
only *withholding entries* can. That is the reason this entry gates rather
than diets. For calibration at a real catalog size (Claude Code's own
`/context`, 2026-08-16, 28 skills): 3.8 k tokens of catalog, `dataviz` ~380
and `cop` ~310 per entry, against the Agent Skills spec's stated budget of
50–100 tokens per entry — 3–6× over, on descriptions that had started
carrying TRIGGER/SKIP blocks because they were doing the skill's job.

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
  (`prompt/user_message.rs`), never the prompt — pitched as a better
  position on two counts: promotion mutates no prefix, and skill
  descriptions are `untrusted: :hard` text that would sit in a data
  position rather than the most-trusted slot in the request. First
  declined as larger than this decision needed and logged as the first
  thing to revisit; **revisited 2026-08-17 and now declined outright**,
  because reading the two counts against pikuri's own code shrank the
  offer to one and a half. The prefix count is already banked:
  `assemble_system_prompt` runs exactly twice — at construction and on
  `clear_conversation` — and a promotion already rides the interloper, so
  nothing mutates a prefix mid-session here either. What remains is the
  trust position, in a sharper form than the original phrasing: the gate
  is a token-cost mechanism, and it is accidentally deciding trust
  placement for third-party bytes, since a *gated* skill's description
  arrives as `role: :user` while an *ungated* skill's identical bytes
  arrive in the system prompt. That is incoherent, but it is a tidiness
  argument, not a finding — `D_bundle_trust_grading` reports this exposure
  and deliberately does not defend against it, and moving the block would
  not defend against it either; it would only relocate it. The move is
  therefore priced as a real refactor buying no new defense. Two things a
  reopen would still have going for it, recorded so nobody re-derives
  them: seeding the baseline on the interloper makes one channel and one
  renderer carry both baseline and promotion, and requiring an interloper
  for a non-empty catalog would delete the two-branch fail-open in
  `Extension#arm_gate` (`Activation::Open` plus its warning) outright,
  since that branch exists only because the two live on different
  channels. Against it, and untested: the resident block is in the
  strongest position for instruction-following, which matters most on the
  local models pikuri targets. The one probe we have is the handful of
  local-model runs below, which settles nothing in either direction.
- **Move the baseline into `SkillTool`'s description instead.** Carried as
  an open fork for a day, on the reasoning
  that a persona replaces the system prompt but inherits the tool
  verbatim, so the tool is the only home correct for both agent kinds.
  Rejected: `D_no_skills_in_sub_agents` has since made "correct for both
  agent kinds" a property pikuri does not want, so the argument inverts
  into a hazard — a description built at `configure` time from the
  parent's catalog would hand the inventory to any persona naming `skill`,
  where `SkillTool#for_sub_agent`'s sealed `Activation` cannot reach it.
  It also cannot host promotions (a description is built once), and it
  wants the enum that decision 5 already rejected.
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
  the one that takes a free-form name. This retires the enum item carried
  as owed-regardless since this axis opened, and
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
- **A promotion must carry the catalog's load instruction, not just the
  names.** Shipped announcing availability only — "these skills just became
  relevant … and are now loadable" — while the resident block carried the
  imperative ("load it *before* answering from your own knowledge — the
  skill's instructions take precedence over your training. If none matches,
  just proceed normally"). Measured 2026-08-17 against a local
  `Qwen3.6-35B-A3B` on a repo task: the block was delivered, attended to, and
  the model named the promoted skill in its own reasoning and *resolved to
  load it* — then read a neighbouring source file instead and imitated its
  style, never calling the tool. Told afterwards to load it, it rewrote its
  own output substantially, so the skill's marginal value was real and had
  simply lost to a cheaper substitute. The lesson generalizes past this
  mechanism: **imitation transmits presence and never absence**, so every
  rule of the form "delete this" is invisible to a model reading exemplars,
  which is exactly the correction-shaped content a skill exists to carry.
  `format_promotion` now closes with the catalog's instruction, widened to
  outrank *inferred house style* alongside training. The `if none matches`
  escape rides with it deliberately: activation over-fires by design, and the
  same run promoted a skill irrelevant to the task, so declining must stay
  cheap. Filtering remains the description's job — a preamble cannot rescue a
  skill whose description omits its own skip condition, which is the
  authoring half of this and belongs in the book.
  **Weigh the evidence here as an anecdote, not a measurement** (noted
  2026-08-17): this is a handful of runs against one model on one task, and
  a local model's tool-calling is variable enough that separating a real
  effect from sampling noise would take on the order of a hundred. The
  change stands on a reason that needs no statistics — the promotion and
  the resident block advertise the same thing and should say the same
  thing — and the same caution applies to anything else in this repo
  reasoning from a single local-model transcript.
- **This is where the skills-surface work stops** (2026-08-17). Two
  re-readings closed the remaining items as a group rather than one at a
  time. First, the origin was thinner than the five notes it grew: the
  complaint is `ideas/feedback.txt`'s *"the standing prompt is heavy"* —
  not *"skill load costs a turn"*, which is what the notes grew from and is
  cut with this entry — and it lists the skills catalog in an enumeration
  and then names
  what is actually not worth its bytes — the tool-schema restatement and
  the duplicated "don't mention the guidelines" material — while saying
  the project file earns its keep. The catalog was never the item's
  target. Second, the prior art does not support trimming it either:
  grok-build is built for the same model that filed the complaint, and it
  renders a full resident inventory of *every* skill budgeted at up to
  **50 % of the context window**, names-only only as overflow. Its one
  divergence from pikuri is position, not volume — xAI's own harness
  spends more resident context on skills than pikuri does. So `paths:`
  gating plus two cheap trims is the whole of what this axis earned, and
  these stay unbuilt by decision, not by backlog: listing a skill's
  sidecar files in the load result, and deduping a repeated load. The two
  that did ship alongside the gate are the ones that cost nothing to
  reason about — `<location>` left the catalog and promotion renders
  (`format_skill` keeps it, which is the copy sidecars actually resolve
  against), and a typed `/name` now loads a skill in `bin/pikuri-code`.
  Note what the trim does *not* touch: `Filesystem#readable:` over
  `catalog.roots` is load-bearing for reading a skill's **sidecar files**,
  not merely a direct-`read` fallback for `SKILL.md` — dropping the
  catalog path narrows that fallback without touching the roots.
- **Reopen when** one of these trips: (1) the untrusted-description
  position becomes a real finding rather than a theoretical one, which
  argues for the placement move above; (2) activation counts per session
  turn out high enough on Anthropic that the cache trade stops being
  noise; (3) a third harness settles on a different spelling.

---

## D_keep_ruby_llm — Decline the piece, keep the gem (2026-08-16)

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
`D_context_window_sources`, which refuses ruby_llm's model registry for a
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
  **deletes `Pikuri::Testing`** outright (see `D_fake_transport`), forcing a
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

## D_single_hunk_edit — `occurrence` pays the uniqueness tax; no batch tool, no patch tool (2026-08-15)

**Status:** Accepted and shipped. `Workspace::Edit` gains `occurrence:`;
no second edit tool ships. `ideas/feedback.txt`'s *"edit is search-replace
only"* is cut with this
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

## D_keep_calculator — The unconfirmed arithmetic path, kept even where bash exists (2026-08-15)

**Status:** Accepted; no code change. `calculator` stays wired in all ten
`bin/pikuri-*` demos. `ideas/feedback.txt`'s *"`calculator` is a smell"* is
cut with this entry.

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
  over corpus hits. This is `D_directory_listing`'s asymmetry again, and the
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

## D_walked_path_denylist — Two layers, and the cheap one is never the guarantee (2026-08-15)

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

## D_bundle_trust_grading — Trust is per search base, and the workspace is not asked (2026-08-16)

**Status:** Accepted, fully shipped: `Bundle::Base`,
`Catalog#untrusted_level`, `SkillTool` consuming it, and the third boot
question in `bin/pikuri-code`. The record lives in the shared `Pikuri::Bundle`
namespace rather than under `Catalog` because slash commands
(`D_slash_commands`) grade the same way from the same bases: duplicating it
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

## D_directory_listing — Directories are not glob's job, and `read` self-heals (2026-08-15)

**Status:** Accepted, fully shipped: `Workspace::Listing`, `read`'s recovering
refusal, the `file_list` tool, and the depth-1 boot snapshot on
`Workspace::Extension`. `ideas/directory-listing.md` is deleted with this
entry, and `ideas/feedback.txt`'s *"a real directory listing"* is cut.

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

## D_no_static_poisoned_flag — No declared `poisoned:` on a node (2026-08-12)

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

## D_write_custody_axis — No synced-folder egress axis on writes (2026-08-12)

**Status:** Accepted (won't build); no code change. The gap it leaves is
stated at {Pikuri::Workspace::Write}'s `trifecta_legs:` declaration site and
named in `book/trifecta-detector.md` §"The edges, stated plainly" — neither
is a to-do any more.

**Context.** `Write` and `Edit` ship {Pikuri::Tool::TrifectaLegs::NONE}: a
local write is not an external sink, and the observation reports an outcome
rather than the file's bytes. But a workspace root that *replicates* — a
`~/Dropbox`, a Nextcloud folder, a team Drive — plausibly turns a write into
egress, and nothing declares it. The gap sat parked as the "custody
question" through `D_egress_axis_shape`, which cited it as a reason not to
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
  `D_egress_axis_shape` rejected for `egress_human_author`.
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
  axis-with-no-consumer rule `D_trifecta_map_orphans` applied to
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

## D_trifecta_map_orphans — A tool nothing can call gets no line on the map (2026-08-12)

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

## D_egress_axis_shape — Two orthogonal egress axes, no invented persona (2026-08-12)

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
  (settled since, as `D_write_custody_axis`).
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

## D_blob_spotter_alphabets — Single-alphabet encodings count, at their own longer thresholds (2026-08-08)

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

## D_headless_os_agent — No app launching, and the sandbox masks the session's IPC surface (2026-08-06)

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
  `D_permission_wall_handoff`: a user outside the `docker` group — the common
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
  (observed; it is loud, and consistent with `D_no_agent_sudo`); **deferred
  execution** via a confirmed write (`~/.bashrc`, `~/.config/autostart/*`,
  `crontab`), which the write confirmer shows as a diff; and **rootful**
  container sockets, left visible on purpose so the denial is honest — see
  the rejected alternative above.
- The mask must stay *after* `--dev-bind / /` in the argv or the root bind
  covers it — invisible in review and silent under every other test, so
  there's an ordering assertion in the spec.
- `Bubblewrap` needs no change: it binds an allowlist that never included
  `/run/user`, so the coding agent never had the channel.

## D_no_agent_sudo — Privileged actions are a human hand-off, never agent-held root (2026-08-06)

**Status:** Accepted. Already the shipped behaviour on both legs (the
`EACCES` read hand-off of `D_permission_wall_handoff`, and
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
  be built. `D_permission_wall_handoff` rests on the same precondition:
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
  opposite of `D_permission_wall_handoff`'s open caveat (escalating *too*
  fast, before gathering the partial picture).
- **Package availability works offline.** apt's package lists are local, so
  `apt-cache policy` names the exact candidate version with the network
  severed. The agent can confirm a package exists and what it would install
  before handing off — the network barrier never fires on that leg.
- **This closes the "package installation" item** that sat in
  `ideas/pikuri-os.md`'s deferred list as "post-v1". It is not deferred
  work; it is declined by posture, and the hand-off already ships.

---

## D_context_window_sources — The `/props` probe, never ruby_llm's model registry (2026-08-04)

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

## D_permission_wall_handoff — An honest `EACCES` beats prompt guidance (2026-07-18)

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

## D_fake_transport — Fake the HTTP backend, not the agent (2026-07-18)

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
  specs. See `D_keep_ruby_llm`.

---

## D_per_process_temp — Two named `Paths` methods, not `cache(session:)` (2026-07-14)

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
