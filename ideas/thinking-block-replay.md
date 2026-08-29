# Replaying a thinking block after a model switch — is dropping the signature the right repair?

Status: **draft, grounded but undecided.** The investigation below is done
and the line numbers are checked (2026-08-29); the *choice* is not made.
Filed because the current behaviour has no decision behind it and, on the
provider it exists to protect, appears to be wrong.

Found while designing pikuri-web's per-conversation model picker
(`../pikuri-web/ideas/per-conversation-model.md`) — that shell needs
`run_loop(transport:)` to be safe on a *reopened* conversation, which is
exactly the path `load_history!`'s signature repair sits on. Nothing in
pikuri-web is blocked: `from_openai_server` against llama.cpp yields no
signature at all, so keep-vs-drop is a no-op there. This is about the
hosts that talk to Anthropic.


## Why this is a note and not an edit

There is no decision for this. The behaviour is **one paragraph inside
`D_history_load_repairs`** (`DECISIONS.md:897–900`), which is otherwise a
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

The reasoning in it is sound. The *mechanism* it picked may not be.


## Current state (grounded, 2026-08-29)

**The repair, in three places.**

- `Agent#load_history!` (`pikuri-core/lib/pikuri/agent.rb:503`) computes
  `current_model = @chat.model&.id`, then per message:

  ```ruby
  keep = m.thinking.nil? || m.model_id.nil? || m.model_id == current_model
  track_message(@chat.add_message(m.to_ruby_llm(keep_signature: keep)), ...)
  ```

- `History::Thinking = Data.define(:text, :signature)`
  (`history.rb:89`), with the rdoc at `:85` stating the rationale.

- `Message#to_ruby_llm(keep_signature:)` (`history.rb:205`) rebuilds the
  message, and at `:216` passes
  `signature: keep_signature ? thinking.signature : nil` — **text always
  survives**.

**What ruby_llm 1.16.0 does underneath** (the part that matters, and the
part the decision paragraph did not look at). In
`lib/ruby_llm/providers/anthropic/chat.rb`:

- `extract_thinking_signature` (`:103`):

  ```ruby
  thinking_block = blocks.find { |c| c['type'] == 'thinking' } ||
                   blocks.find { |c| c['type'] == 'redacted_thinking' }
  thinking_block&.dig('signature') || thinking_block&.dig('data')
  ```

  So a `redacted_thinking` block's **encrypted `data` payload is stored in
  `signature`**, and there is no `text` at all.

- `extract_thinking_content` (`:97`) joins `c['thinking'] || c['text']`
  and returns `nil` for an empty join.

- `build_thinking_block` (`:200`) branches on the way back out:

  ```ruby
  if thinking.text
    { type: 'thinking', thinking: thinking.text, signature: thinking.signature }.compact
  elsif thinking.signature
    { type: 'redacted_thinking', data: thinking.signature }
  end
  ```

  Note the `.compact`: a nil signature does not fail, it just **omits the
  key**.

- `RubyLLM::Thinking.build` (`lib/ruby_llm/thinking.rb:13`) returns `nil`
  when text and signature are both nil.

**What Anthropic requires.** From
[Thinking in tool and multi-turn workflows](https://platform.claude.com/docs/en/build-with-claude/thinking-tool-workflows),
"The rules this walkthrough applies":

> *Pass thinking blocks back complete and unmodified.*
>
> *Echo the assistant message exactly as received: rebuilding the message
> or **filtering out `redacted_thinking` blocks triggers a 400 error**.*

And, from the same page's step 2 note:

> *On models where display defaults to omitted, including claude-opus-4-8,
> the `thinking` field otherwise comes back as an empty string with only
> the `signature` populated.*


## The three failure modes

Composing the above, `keep_signature: false` does something different in
each case, and none of them is a supported wire shape.

| stored shape | what we emit | verdict |
|---|---|---|
| summarized thinking (`text` + `signature`) | `{type: 'thinking', thinking: text}`, **no signature** | a modified block; docs say "complete and unmodified" |
| `redacted_thinking` (`text` nil, blob in `signature`) | `Thinking.build(nil, nil)` → `nil` → **block deleted** | docs: filtering these out is itself a 400 |
| display-omitted model (`text` nil, real signature) | same as above — **block deleted** | and on *keep*, re-serialized as `{type: 'redacted_thinking', data: <a normal signature>}` |

The unifying observation:

> **Anthropic offers two options — send the block verbatim, or omit it.
> pikuri implements a third, which is neither.** At the wire level a
> signature is not independently droppable: it is either part of a block
> you send whole, or (for a redacted block) it *is* the block.

Two consequences worth stating separately, because they land differently:

- The **good** accident: an encrypted payload can never reach `text`, so
  pikuri cannot ship a decrypted-to-garbage string to another model and
  burn tokens on it. That failure mode is structurally impossible here.
  Worth keeping true under any fix.
- The **bad** accident: for opaque blocks the repair silently reaches
  "omit the block" — the right *shape*, arrived at by coincidence, only
  for the messages where `text` happens to be nil, and precisely where the
  docs say omitting is an error. Row 3 says this is not an exotic path but
  the default one for current models.

Row 3's keep-branch is a ruby_llm round-trip bug (a normal signature
re-serialized as a redacted block) sitting underneath ours. Worth an
upstream issue regardless of what pikuri decides; pikuri should not
design around it staying broken.


## Two more problems in the same repair

**The identity is weaker than pikuri's own.** The test is
`m.model_id == current_model` — a bare model-id string compare. But
signatures are endpoint-specific as well as model-specific: field reports
are consistent that a preserved signature is not guaranteed valid on
replay once the base URL is not `api.anthropic.com`
([openclaw#92019](https://github.com/openclaw/openclaw/issues/92019)).
pikuri knows this everywhere else — `ChatTransport`'s own rdoc is
"everything that must travel together … *on the same server*", and
pikuri-tui's `Shared::Model::Choice.key` keys on `[model, api_base]`
because two `[[llm]]` entries can name one model on two servers. The
signature test is the one place using the weaker notion, and it gives the
wrong answer for exactly that local-vs-remote case.

Snag: `History::Message` records `model_id` and no server, so tightening
this is a **history-format question**, not a one-liner. That is probably
the most interesting fork in this note.

**Load time cannot cover a mid-session switch.** The scrub runs only in
`load_history!`. `Agent#apply_transport!` (`agent.rb:726`) calls
`Chat#with_model`, which preserves history — so a switch *after* the load
replays the old model's signatures untouched. That is the most-reported
form of this bug in the wild
([openclaw#92019](https://github.com/openclaw/openclaw/issues/92019),
[claude-code#10627](https://github.com/anthropics/claude-code/issues/10627)).

There is an internal-consistency argument here.
`D_history_load_repairs` justifies itself with the survey finding that all
five harnesses *"repair when building the request and leave the stored
record untouched"* — and then puts signature repair at load time, which is
the one place that provably cannot cover a switch. For dangling tool calls
load-time is fine (a stored history is the only way to acquire one). For
signatures it is not.


## Options

Not yet argued, deliberately — this is the agenda for the session that
takes it.

1. **Repair the whole block, not the signature.** Replace
   `keep_signature:` with `keep_thinking:`; false emits `thinking: nil`.
   This is Anthropic's actual two-option menu, it is correct on every row
   of the table above, and it is *simpler* than what is there. Current
   lean. Open sub-question: is dropping legal for a **prior** assistant
   turn that carries `tool_calls`? The docs' "must accompany the
   `tool_use` block" rule is stated for the live round trip; a completed
   turn already answered by its results may be a different case, and the
   community workaround ("filter out `type: thinking` blocks from history")
   suggests it is. Needs confirming, not assuming — and it interacts with
   `repair_interrupted_tool_calls`, which synthesizes exactly that shape.
2. **Move the repair to request-build time** (or additionally into
   `apply_transport!`), matching the survey finding the decision already
   cites. Costs a hook where there currently isn't one; the loop seam says
   ruby_llm owns `Chat#complete`, so where this lives is a real design
   question rather than an obvious placement.
3. **Key it on the transport rather than the model id.** Wants
   `api_base` (or the whole transport identity) recorded per message —
   a `History` schema change, with a migration story for existing files.
4. **Do nothing, and say so.** Defensible *if* row 1 turns out to be
   accepted by the API in practice and rows 2–3 are judged rare. Requires
   evidence against a live endpoint, which nobody has gathered; it should
   not be chosen by default just because it is the status quo.

Options 1–3 are independent and can land separately. 1 is the smallest and
fixes the most.

Worth doing before deciding: a live reproduction against a real Anthropic
endpoint for each row of the table. Everything above is read from source
and docs, and one afternoon with a key would turn three inferences into
three facts.


## Where the nuggets go at graduation

- The choice + the roads not taken → **its own `DECISIONS.md` entry**
  (`D_thinking_block_replay`?), *not* another paragraph inside
  `D_history_load_repairs` — the whole point of this note is that the
  behaviour outgrew being that decision's footnote. Cross-link the two,
  and edit the existing paragraph down to a pointer.
- The per-symbol contract ("what happens to a thinking block whose model
  no longer matches") → the yardoc on `Agent#load_history!` and
  `History::Thinking`, which both already carry a version of it and would
  both be wrong after any of options 1–3.
- Any `History` format change → the schema's own doc plus a
  `**Breaking:**` CHANGELOG line with the migration.
- If the repair moves to request-build time, that is a **loop-seam**
  fact → CLAUDE.md *Seams*.
- The ruby_llm round-trip bug (row 3, keep branch) is **upstream's** —
  file it there and cite the issue here; do not carry a workaround in
  pikuri without a decision entry saying why.
