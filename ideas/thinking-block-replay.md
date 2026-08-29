# Dropping thinking blocks when the model changes

Status: **decided, not implemented.** The research is done and the
load-bearing claims are measured against a live llama.cpp (2026-08-29,
ruby_llm 1.16.0). What remains is writing the code and the
`DECISIONS.md` entry.

Research and sourcing live in `ideas/thinking-block-replay/` — this file
is the argument and the decision, and should read straight through.

A second defect fell out of the same investigation and has its own note:
`ideas/thinking-blocks-never-echoed.md`. It is unrelated to this decision
and larger; read it separately.


## The problem

`Agent#load_history!` drops a thinking **signature** when a message's
`model_id` is not the agent's current model, keeping the thinking text
(`agent.rb:513`, `history.rb:216`). The behaviour has no decision behind
it — it is one paragraph inside `D_history_load_repairs`
(`DECISIONS.md:895–899`), which is otherwise about dangling tool calls,
with no slug, no CHANGELOG entry and no alternatives considered.

It arrived as a corollary, and both halves are wrong: the stated reason
does not hold, and the operation repairs a field no reachable backend
reads.


## What we found

**1. The stated rationale is false.** The paragraph says replaying a
signature after a model switch "is a 400". Anthropic documents the
opposite — a foreign thinking block is *silently ignored*, costing only
input tokens. The 400 that does exist is for **modified** blocks, scoped
to the latest assistant message, which is precisely the shape
`keep_signature: false` produces. The polarity is inverted: keeping is
benign, modifying is the error case.
→ `thinking-block-replay/anthropic-replay-rules.md`

**2. On Anthropic the repair is unreachable.** pikuri never calls
`Chat#with_thinking` — it appears nowhere in the repo — and `Agent`
exposes no `attr_reader :chat`, so no host can enable thinking either.
ruby_llm's Anthropic serializer gates every thinking block on that
config, so pikuri emits none at all. Measured: all four stored shapes
render identically to `[{type: "text"}]`. Keep and drop are
indistinguishable on that wire.
→ `thinking-block-replay/provider-survey.md`

**3. On the OpenAI-compatible path it is live, and repairs the wrong
field.** `format_thinking` there is **ungated** — every assistant message
carries `reasoning`, `reasoning_content` and `reasoning_signature`
regardless of any config. llama.cpp reads `reasoning_content` off input
assistant messages and hands it to the template as a `{type: "thinking"}`
block; it has no signature concept whatsoever. ruby_llm's `XAI < OpenAI`
overrides only `format_role` and `format_content`, so Grok gets the same
treatment, and xAI has no chat-completions signature either.
→ `thinking-block-replay/provider-survey.md`

**4. Measured on the real setup.** Against `http://mavi-fw:8080` running
`unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M`:

```
requested (transport.model / @chat.model.id) : "unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M"
reported  (message.model_id / data['model']) : "unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M"
equal?                                       : true
thinking.text      : "Here's a thinking process:\n\n1.  **Analyze User Input:**…"
thinking.signature : nil
```

Three things at once: the model ids **do** echo, so the identity test is
sound here; the reasoning text is populated and is raw first-person chain
of thought, not a summary; and the signature is **always nil**. On the
default local backend today's repair drops a field that never exists,
and forwards the reasoning it should have dropped.

**So the live harm is this:** resume a Grok conversation under Qwen — the
commented-out pair in `~/.pikuri-examples-config.yaml` — and Qwen is
handed Grok's verbose first-person reasoning in the slot where its own
scratchpad belongs, labelled as its own. The current repair does nothing
about it. Worse, on a *mid-session* switch no repair runs at all, and the
foreign reasoning is replayed on every subsequent turn.


## Why dropping is right, rather than merely cheaper

Anthropic's own reason for stripping on a switch is economic — the
receiving model ignores the blocks anyway, so you are paying for nothing.
It can say that because signatures let its server detect and discard
foreign blocks. **llama.cpp has no such mechanism**, so the same strip is
a correctness fix rather than an optimization, and pikuri's default
backend is the one where that is true.

Three reasons the content should go, strongest first:

1. **It is not even the model's reasoning as generated.** On Anthropic
   and Grok the text is a summary produced for human display; the raw
   reasoning lives in the signature (or nowhere). Feeding a human-facing
   paraphrase into the position where raw scratchpad belongs is the wrong
   *kind* of object, not just degraded context.
2. **The slot is self-attributive.** A thinking block is not neutral
   background — templates place it where the model treats the contents as
   its own working state. The model is told it already reasoned this way
   and continues from there, carrying register and rejected branches.
3. **The marginal information is the discarded branches.** Conclusions
   already survive in the visible content; what is unique to the
   reasoning is mostly paths the previous model rejected.

The cost is real — reasoning continuity is worth preserving, and
Anthropic recommends it. But their advice flips at the model boundary,
because that is where the attribution premise breaks. Same-model keeps,
cross-model drops, is one rule rather than a compromise between two.


## The decision — options 1 + 2 + 0

> When a message's recorded `model_id` does not match the agent's current
> model, its thinking block is dropped **from what goes to the provider** —
> text and signature both — while the message and the stored record keep
> it. The check runs at both moments the model identity can change:
> `load_history!` and `apply_transport!`.

- **Option 1 — the operation.** `keep_signature:` → `keep_thinking:`;
  false emits `thinking: nil`. The whole block is the only unit that
  means the same thing on every backend; the text/signature split is an
  Anthropic implementation detail.
- **Option 2 — the placement.** Load time provably cannot cover a
  mid-session switch, which is the more damaging case. This is **two call
  sites, not a hook**: `with_model` has exactly one call site
  (`agent.rb:732`, inside `apply_transport!`) with exactly one caller, so
  identity can only change at construction (no history), `load_history!`,
  or `apply_transport!`. The loop seam is untouched.
- **Option 0 — the premise.** Correct the three places asserting the 400:
  `DECISIONS.md:895–899`, `agent.rb:494–496`, `history.rb:85–88`. Not
  separately landable if 1 lands — the yardoc changes anyway — so this is
  one commit, not two. Land 0 alone **only** if 1 stalls; three files
  should not keep stating a falsehood while a design decision is pending.

Two details, both settled:

- **`model_id: nil` drops.** Today it keeps. Under the old rationale
  (avoid an invalid signature) unknown provenance was harmless; under the
  attribution rationale it is indistinguishable from foreign. Assume the
  worst rather than silently corrupt.
- **Retention rides `@message_meta`.** Scrubbing `@chat` alone would mean
  a load-under-a-different-model followed by a save writes the reasoning
  out of existence — measured, and a record that degrades each time you
  open it is not the faithful record the History seam promises.
  `Agent#track_message` already keeps an identity-keyed side map of
  per-message data that never reaches a provider (`id`, `kind`); stripped
  thinking is the same kind of thing. `export_history` prefers the map.
  Wire sees nothing, disk keeps everything, no per-request hook.


## Not doing

- **Option 3 — key on transport identity instead of `model_id`.**
  Closed, not deferred. Its evidence was one bug report about *rewriting
  proxies*, against a docs statement that signatures are portable across
  the Claude API, Bedrock and Vertex; and the probe shows ids echo on the
  backend that matters. A false mismatch can only occur same-model and
  fails safe (you lose the model's own reasoning, you never inject a
  foreign one). Not worth a schema change.
  → `thinking-block-replay/openclaw-issue-provenance.md`
- **Option 4 — fix ruby_llm first.** File the three round-trip bugs
  upstream; nothing here blocks on them.
  → `thinking-block-replay/ruby-llm-round-trip-bugs.md`
- **Option 5 — do nothing.** Would mean knowingly shipping a foreign
  model's reasoning as the current model's on the default local setup.
- **Option 6 — never replay thinking at all.** Simpler, and it would
  delete the identity test outright. Rejected because the entire case
  against replay is false attribution, and none of it applies when the
  model has not changed. Same-model continuity is behaviour that works
  today and that Anthropic explicitly recommends.


## Where the nuggets go at graduation

- The choice + the roads not taken → its own `DECISIONS.md` entry
  (`D_thinking_block_replay*`?), **not** another paragraph inside
  `D_history_load_repairs` — this outgrew being that decision's footnote.
  Cross-link both ways and cut the existing paragraph to a pointer. The
  rejected alternatives include the four corrections themselves: the 400
  premise, the endpoint-identity fork, the belief that the local path was
  a no-op, and the belief that this was an Anthropic problem. All four
  are plausible enough to be re-derived by the next reader.
- The per-symbol contract → yardoc on `Agent#load_history!`,
  `Agent#apply_transport!` and `History::Thinking`, all of which state
  the false premise today.
- **The provider survey is verified behaviour and must not die with this
  note.** "llama.cpp reads `reasoning_content` off an input assistant
  message and has no signature concept" is exactly what someone will
  otherwise re-derive from C++ source. Home: the yardoc on whatever
  carries the repair, with the *why* in the `DECISIONS.md` entry. The
  per-provider table belongs in the entry, not CLAUDE.md, which owns
  invariants rather than surveys.
- Nothing here changes the History file format, so no `**Breaking:**`
  CHANGELOG line — one `Fix` entry naming the symbol.
- The three ruby_llm bugs are upstream's; cite the issues once filed.
