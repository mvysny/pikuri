# The thinking-signature repair: the rationale is false and the mechanism is unreachable

Status: **draft, grounded, and now pointed somewhere different.** The
investigation is done, the line numbers are checked, and the wire
behaviour is measured (2026-08-29, ruby_llm 1.16.0). The *choice* is not
made — but the question changed shape, so the earlier framing of this
note is superseded rather than refined.

The note used to ask *"is dropping the signature the right repair?"*.
Research says the honest question is:

> **The stated rationale is factually wrong, and the mechanism it justifies
> is unreachable on the provider it exists to protect.**

Found while designing pikuri-web's per-conversation model picker
(`../pikuri-web/ideas/per-conversation-model.md`) — that shell needs
`run_loop(transport:)` to be safe on a *reopened* conversation, which is
exactly the path `load_history!`'s signature repair sits on.

A separate, larger defect fell out of the same research and now lives in
its own note: `ideas/thinking-blocks-never-echoed.md`. **Read that one
first if you only read one** — it is a live bug on every Anthropic
tool-use turn, where this note is about a resume-time repair that
currently does nothing.


## Why this is a note and not an edit

There is no decision for this. The behaviour is **one paragraph inside
`D_history_load_repairs`** (`DECISIONS.md:895–899`), which is otherwise a
decision about *dangling tool calls*:

> **A thinking signature is dropped when the model changed**, keeping its
> text. Signatures are attestations the issuing model validates, so
> replaying one after a switch is a 400 — and pikuri makes that likely,
> not exotic, since `ModelSwitched` ships and the whole point of resume is
> that time passed.

The tool-call repair immediately above it earns a three-row validation
table and a full *Alternatives rejected* list. This paragraph has neither,
no slug of its own, no `ideas/` note, and no CHANGELOG entry. It rode in
as a corollary.

**The reasoning in it is not sound, and neither is the mechanism.** That
is the change from the previous draft, which conceded the reasoning and
questioned only the mechanism.


## Correction 1 — replaying after a switch is not a 400

This is the load-bearing finding. Anthropic's Thinking page,
§*Thinking block preservation by model* → *Switching models
mid-conversation*:

> *When you switch between any two models […] strip `thinking` and
> `redacted_thinking` blocks from prior assistant turns. Thinking blocks
> are tied to the model that produced them. **Other models silently ignore
> them rather than rejecting the request**, but ignored blocks still add
> input tokens.*

The 400 that *does* exist is for **modified** blocks, and it is scoped to
one message (§*A 400 error says thinking blocks cannot be modified*):

```text
`thinking` or `redacted_thinking` blocks in the latest assistant message
cannot be modified
```

So the polarity is the reverse of what pikuri assumes:

| | pikuri assumes | Anthropic documents |
|---|---|---|
| replay a stale signature whole | 400 | silently ignored, costs input tokens |
| ship a block with the signature stripped | the safe repair | a *modified* block — the documented 400 shape |

`keep_signature: false` is a block modification. The current repair takes
a benign-but-wasteful situation and moves it toward the one the docs name
as an error.

Two supporting rules worth keeping together, because they settle the old
draft's open sub-question about tool-call turns (§*Preserving thinking
blocks*):

> * ***Required:** within a tool-use turn, pass thinking blocks back.*
> * ***Recommended:** across turns, pass everything back.*
> * ***Allowed:** outside tool use, omit prior turns' thinking.*

and, from §*Thinking encryption*:

> *It is only strictly necessary to send back thinking blocks when using
> tools with thinking. Otherwise you can omit thinking blocks from
> previous turns.*

**Three places in the tree currently state the falsehood** and would all
be wrong under any option below: `DECISIONS.md:895–899`,
`pikuri-core/lib/pikuri/agent.rb:494–496`, and
`pikuri-core/lib/pikuri/agent/history.rb:85–88`.

Note that Anthropic's *prescribed* repair on a switch is still "strip the
whole block" — option 1 below. Right answer, different reason: cost and a
documented instruction, not 400-avoidance.


## Correction 2 — the endpoint argument does not survive its source

The previous draft called this "probably the most interesting fork in
this note" and proposed a `History` schema change to record `api_base`
per message. The evidence does not carry that weight.

Against it, §*Thinking encryption*:

> *`signature` values are compatible across platforms (the Claude API,
> Amazon Bedrock, and Google Cloud). Values generated on one platform work
> on another.*

And the source that was cited *for* it —
[openclaw#92019](https://github.com/openclaw/openclaw/issues/92019)
(real, closed 2026-06-10) — is weaker than it read:

- "model-specific and endpoint-specific" is the **reporter's root-cause
  hypothesis in a bug body**, not a vendor statement.
- Its endpoint half is specifically about **rewriting proxies** — the body
  names Bifrost and LiteLLM. A proxy that rebuilds request bodies is a
  different failure from a first-party alternate endpoint, which is what
  the platform-compatibility sentence above covers.
- Its model-switch half asserts a hard 400, which Correction 1
  contradicts for current models.

[claude-code#10627](https://github.com/anthropics/claude-code/issues/10627)
is also real (closed 2025-10-30) but is a bare `Invalid signature in
thinking block` report that never mentions a model switch — it does not
support the "most-reported form of this bug" claim it was cited for.

So: keying on the transport rather than the model id is now the *most
expensive* option resting on the *weakest* evidence. Demoted, not deleted
— a rewriting proxy is a real deployment shape, and `ChatTransport`'s own
rdoc ("everything that must travel together … *on the same server*") still
reads as the more principled identity. It is just not urgent and not
evidenced.


## Correction 3 — the repair is dead on Anthropic and live on the path this note dismissed

The previous draft opened with *"Nothing in pikuri-web is blocked:
`from_openai_server` against llama.cpp yields no signature at all, so
keep-vs-drop is a no-op there. This is about the hosts that talk to
Anthropic."*

That is backwards.

**pikuri never enables thinking.** `with_thinking` appears nowhere in the
repo, and `Agent` exposes no `attr_reader :chat`, so the Chat is sealed
behind the loop seam and no *host* can enable it either. This is an
invariant, not a default. `@thinking` is therefore `nil` on every
`render_payload`, and ruby_llm's Anthropic provider gates both
serialization paths on it:

- `format_basic_message_with_thinking`: `if msg.role == :assistant && thinking_enabled`
- `format_tool_call_with_thinking` → `prepend_thinking_block`:
  `return content_blocks unless thinking_enabled`

Measured offline (no API key needed — `format_message` is pure), all four
stored shapes with thinking disabled:

```
summarized (text+sig)      -> [{:type=>"text", :text=>"ok"}]
display-omitted (nil+sig)  -> [{:type=>"text", :text=>"ok"}]
redacted (nil+blob)        -> [{:type=>"text", :text=>"ok"}]
dropped sig (text+nil)     -> [{:type=>"text", :text=>"ok"}]
```

**Keep and drop are indistinguishable on the Anthropic wire.** No thinking
block is emitted at all.

Meanwhile the OpenAI-compatible path's `format_thinking` is **ungated** —
`.compact.merge(format_thinking(msg))` on every assistant message,
regardless of any thinking config:

```
keep -> {:role=>"assistant", :content=>"ok", :reasoning=>"…",
         :reasoning_content=>"…", :reasoning_signature=>"SIG"}
drop -> {:role=>"assistant", :content=>"ok", :reasoning=>"…",
         :reasoning_content=>"…"}
```

So the repair has exactly one live consumer: **OpenAI-compatible servers
that return a signature.** llama.cpp does not, which is why the previous
draft read it as a no-op — but `from_openai_server` also points at
OpenRouter / LiteLLM / vLLM / DeepSeek-shaped backends that populate
`reasoning_signature`, and `ChatTransport` is provider-generic.

Any option below should be evaluated against *that* consumer, not against
Anthropic.


## What the repair would do, if it ran

Kept for reference: this is the old table, still correct, but it now
describes a **hypothetical** — the shape pikuri would put on the wire
*if* it ever called `with_thinking`. Measured, thinking enabled:

| stored shape | what we'd emit | verdict |
|---|---|---|
| summarized (`text` + `signature`) | `{type: 'thinking', thinking: text}`, **no signature** | a modified block — Correction 1's 400 shape |
| `redacted_thinking` (`text` nil, blob in `signature`) | `Thinking.build(nil, nil)` → `nil` → **block deleted** | docs: filtering these out is itself a 400 |
| display-omitted (`text` nil, real signature) | same — **block deleted** | and on *keep*, re-serialized as `{type: 'redacted_thinking', data: <a normal signature>}` |

The **good accident** still holds and is worth keeping true under any
fix: an encrypted payload can never reach `text`, so pikuri cannot ship a
decrypted-to-garbage string to another model and burn tokens on it. That
failure mode is structurally impossible here.


## ruby_llm cannot round-trip an Anthropic turn at all

Three upstream defects, not one. This is the reason a fourth option
exists below.

1. **Display-omitted re-serialized as redacted.** `text` nil + a real
   signature comes back out as `{type: 'redacted_thinking', data: <a
   normal signature>}`. Found in the previous draft; confirmed by
   measurement.
2. **Multiple thinking blocks collapse to one, losing *n*−1 signatures.**
   `extract_thinking_content` (`anthropic/chat.rb:97`) *joins* every
   `thinking` block into one string, while `extract_thinking_signature`
   (`:103`) keeps only the **first** block's signature. Interleaved
   thinking is automatic on every adaptive model, so multi-block turns are
   the normal case, not an edge one.
3. **A `redacted_thinking` block alongside a `thinking` block is dropped
   entirely.** `extract_thinking_signature` finds a `thinking` block first
   and only falls back to `redacted_thinking`. This is precisely the
   "filters content blocks by type and drops `redacted_thinking` blocks"
   that the troubleshooting page names as the top cause of the
   modification 400.

`RubyLLM::Thinking` is one text plus one signature; an Anthropic
assistant turn is an ordered *sequence* of blocks. The type is
structurally incapable of representing it, and `History::Thinking`
faithfully mirrors that lossy shape. **No option 1–3 below repairs this**,
because the loss happens before pikuri ever sees the message.

File upstream regardless of what pikuri decides; do not carry a
workaround without a decision entry saying why.


## The one thing that survives unchanged

**Load time cannot cover a mid-session switch.** The scrub runs only in
`load_history!`. `Agent#apply_transport!` (`agent.rb:726`) calls
`Chat#with_model`, which preserves history — so a switch *after* the load
replays untouched.

The internal-consistency argument still stands, and is now stronger:
`D_history_load_repairs` justifies itself with the survey finding that all
five harnesses *"repair when building the request and leave the stored
record untouched"* — and then puts signature repair at load time, the one
place that provably cannot cover a switch. For dangling tool calls
load-time is fine (a stored history is the only way to acquire one). For
signatures it is not, and Anthropic's own rule is phrased per-request too.


## Options

Re-ordered and re-justified. Not yet argued to a conclusion.

0. **Fix the premise. Unconditional, and independent of everything else.**
   Three places assert a 400 that does not happen (Correction 1). This is
   cheap, is owed regardless of which option lands, and should not wait on
   the rest of this note. Current lean: do this now, decide the rest
   later.
1. **Repair the whole block, not the signature.** Replace
   `keep_signature:` with `keep_thinking:`; false emits `thinking: nil`.
   Still the best mechanism, but **re-justified**: it is what Anthropic
   instructs on a switch, it removes a block-modification pattern, and it
   is simpler than what is there — *not* because it dodges a 400. The old
   open sub-question (is dropping legal for a prior assistant turn
   carrying `tool_calls`?) is answered by the three-way rule in Correction
   1 plus the 400's scoping to "the latest assistant message": a loaded
   history's turns are completed prior turns, so omitting is *Allowed*.
   Still interacts with `repair_interrupted_tool_calls`, which synthesizes
   exactly that shape.
2. **Move the repair to request-build time** (or additionally into
   `apply_transport!`), matching both the survey finding the decision
   already cites and Anthropic's own per-request phrasing. **Promoted** —
   load-time-only was justified by the 400-on-switch premise, and that
   premise is gone. Costs a hook where there isn't one; the loop seam says
   ruby_llm owns `Chat#complete`, so placement is a real design question.
3. **Key it on the transport rather than the model id.** **Demoted** — see
   Correction 2. Wants `api_base` per message, a `History` schema change,
   and a migration story, on evidence that is one bug report about
   rewriting proxies.
4. **Fix it upstream instead.** New. Given that ruby_llm loses signatures,
   collapses multi-block turns, and drops `redacted_thinking` before
   pikuri sees anything (§above), the honest repair may not live in
   `load_history!` at all. A faithful `RubyLLM::Thinking` — an ordered
   list of typed blocks — would make options 1–3 nearly moot.
5. **Do nothing, and say so.** Now the *most* defensible it has ever been,
   because Correction 3 shows the mechanism is unreachable on Anthropic
   and only reaches non-llama.cpp OpenAI-compatible backends. But it still
   cannot be chosen while Correction 1's falsehood stands in three files —
   option 0 is not optional.

Options 0–3 are independent and can land separately. 0 is free. 1 is the
smallest real change and fixes the most.

**The old "one afternoon with a key" plan is retired.** Three of the four
rows in the table above cannot be produced by pikuri at all today, so a
live repro would be measuring ruby_llm, not pikuri. If someone does spend
an afternoon, spend it on `ideas/thinking-blocks-never-echoed.md`, where
the wire shape is real.


## Where the nuggets go at graduation

- The choice + the roads not taken → **its own `DECISIONS.md` entry**
  (`D_thinking_block_replay*`?), *not* another paragraph inside
  `D_history_load_repairs` — the whole point of this note is that the
  behaviour outgrew being that decision's footnote. Cross-link the two,
  and edit the existing paragraph down to a pointer. **The rejected
  alternatives now include Corrections 1–3 themselves**: the 400 premise,
  the endpoint-identity fork, and the belief that this was an Anthropic
  problem. All three are exactly the kind of plausible-and-wrong a future
  reader would re-derive.
- The per-symbol contract ("what happens to a thinking block whose model
  no longer matches") → the yardoc on `Agent#load_history!` and
  `History::Thinking`, which both already carry a version of it and are
  both **wrong today**, before any option lands.
- Any `History` format change → the schema's own doc plus a
  `**Breaking:**` CHANGELOG line with the migration.
- If the repair moves to request-build time, that is a **loop-seam**
  fact → CLAUDE.md *Seams*.
- The three ruby_llm round-trip bugs are **upstream's** — file them there
  and cite the issues here.
