# pikuri never enables thinking, so it never echoes thinking blocks back — on models where thinking is on by default

Status: **live defect, not an open design question.** Grounded and
measured 2026-08-29 against ruby_llm 1.16.0; the wire shape is confirmed
offline, the *consequence* is inferred from Anthropic's docs and wants one
afternoon against a real endpoint to close.

Split out of `ideas/thinking-block-replay.md`, which found this while
investigating something smaller. That note is about a resume-time repair
that currently does nothing; **this is a bug on every Anthropic tool-use
turn, resumed or not.** Different scope, different urgency, so it gets its
own file.


## The shape of it

Three facts that are individually fine and jointly a bug.

1. **pikuri never sets the `thinking` request parameter.**
   `with_thinking` appears nowhere in the repo, and `Agent` exposes no
   `attr_reader :chat`, so the Chat is sealed behind the loop seam and no
   host can set it either. This is an invariant, not a default.

2. **On current models, omitting `thinking` does not mean thinking is
   off.** From Anthropic's *Troubleshooting thinking*, §*Configurations
   each model rejects*:

   | Model | Default |
   |---|---|
   | Claude Fable 5 / Mythos 5 | Always on (`"disabled"` returns 400) |
   | Claude Opus 5 | **On** |
   | Claude Sonnet 5 | **On** |
   | Claude Opus 4.8 / 4.7 / 4.6 | Off |

   So on Opus 5 / Sonnet 5 / Fable 5, pikuri gets adaptive thinking
   whether it asked or not, and the response carries `thinking` blocks.
   pikuri stores them — `History::Thinking` exists precisely because they
   arrive.

3. **ruby_llm then never sends them back.** Both Anthropic serialization
   paths gate on the request's thinking config, which is `nil`:

   - `format_basic_message_with_thinking`: `if msg.role == :assistant && thinking_enabled`
   - `format_tool_call_with_thinking` → `prepend_thinking_block`:
     `return content_blocks unless thinking_enabled`

   Measured (pure function, no API key), thinking disabled — every stored
   shape collapses to the same thing:

   ```
   summarized (text+sig)      -> [{:type=>"text", :text=>"ok"}]
   display-omitted (nil+sig)  -> [{:type=>"text", :text=>"ok"}]
   redacted (nil+blob)        -> [{:type=>"text", :text=>"ok"}]
   ```

   And on a tool-call turn the `tool_use` block ships with no `thinking`
   block ahead of it.


## Why that is a bug and not a preference

Anthropic's Thinking page, §*Preserving thinking blocks*, states the rule
three ways, and the strict one is exactly pikuri's situation:

> * ***Required:** within a tool-use turn, pass thinking blocks back.*
> * ***Recommended:** across turns, pass everything back.*
> * ***Allowed:** outside tool use, omit prior turns' thinking.*

and, from the same section:

> *When Claude invokes a tool, it pauses construction of its response to
> await external information. When you return the tool result, Claude
> continues building that same response, so its earlier reasoning must
> still be present.*

**pikuri is a tool-use agent.** Every `run_loop` turn against Opus 5 or
Sonnet 5 is a tool-use turn where the model thought, and pikuri returns the
tool result without the reasoning that produced the call.

The reason this has never been noticed is that it does not raise. From
§*Thinking with tool use*:

> ***Mid-turn conflicts degrade gracefully.** If you toggle thinking
> mid-turn […] the API doesn't error. Instead, it silently disables
> thinking for that request. To preserve model quality, the API may strip
> thinking blocks that would create an invalid turn structure, or disable
> thinking when the conversation history is incompatible with thinking
> being enabled. To confirm whether thinking was active, check for the
> presence of `thinking` blocks in the response.*

So the failure mode is **silent**: no 400, no warning, no listener event.
Just a model that thinks on the first request of a turn and then, once a
tool result comes back without its reasoning, plausibly stops thinking for
the rest of the turn.


## What it plausibly costs

Ordered by confidence. The first is documented; the rest are the reason to
go measure rather than to go patching.

- **Cache invalidation, documented.** §*Thinking and prompt caching*:
  "*Thinking blocks are cached with tool results.* […] the previous
  conversation history, including its thinking blocks, can be cached".
  pikuri forfeits that leg on every multi-step turn.
- **Reasoning discontinuity across the tool boundary**, which is the
  stated purpose of the rule. Cost unmeasured.
- **Adaptive thinking possibly disabled for the remainder of a turn** by
  the graceful-degradation path — i.e. pikuri may be paying Opus 5 prices
  for the thinking on request 1 of a turn and getting a non-thinking model
  for requests 2..*n*.

Note the second-order oddity: `Agent` *emits* `Event::ThinkingDelta` and
`Tokens#thinking`, and listeners render reasoning to the user. pikuri
surfaces thinking it then throws away.


## Confirming it

This is the note that actually earns an afternoon with a key, because
unlike `thinking-block-replay.md` the wire shape here is real and
reachable today.

Against `claude-opus-5` (thinking on by default), a two-step tool-use
conversation through a normal `Agent`:

1. Record the outbound bodies (the `faraday_adapter` seam on
   `ChatTransport` is already the sanctioned injection point — see
   `Pikuri::Testing.fake_transport` for the pattern). Confirm request 2
   carries no `thinking` block ahead of the `tool_use`.
2. Check whether request 2's *response* still contains `thinking` blocks.
   The docs say their presence is how you detect that thinking stayed
   active — that single observation decides how bad this is.
3. Compare `usage.cache_read_input_tokens` across the turn against a
   control run that echoes blocks back.

Step 2 is the whole experiment. If thinking survives, this is a cache and
tidiness problem; if it does not, pikuri is silently running a
non-thinking model for most of every turn on its most capable providers.


## The fix is not obvious, which is why this is a note

The naive fix — call `with_thinking` — is wrong on three counts, and each
one is a real fork:

- **`Thinking::Config` is effort/budget, and ruby_llm maps it per
  provider.** `with_thinking(effort:)` on a local llama.cpp becomes
  `reasoning_effort`, which is not a no-op. Enabling thinking is not a
  provider-neutral act, and pikuri's whole posture is
  local-first-cloud-opt-in.
- **It changes cost and latency on every wired host**, silently, on a
  default nobody opted into. §*Thinking and prompt caching*: the thinking
  configuration "is rendered into the prompt itself", so turning it on
  also invalidates every existing cache prefix.
- **It does not actually fix the round trip.** ruby_llm loses signatures,
  collapses multi-block turns into one, and drops `redacted_thinking`
  blocks — the three upstream defects catalogued in
  `ideas/thinking-block-replay.md` §*ruby_llm cannot round-trip an
  Anthropic turn at all*. Enabling thinking would start *sending* blocks,
  and some of them would be the malformed shapes that earn the real 400
  ("`thinking` or `redacted_thinking` blocks in the latest assistant
  message cannot be modified"). **Turning this on before upstream is fixed
  could convert a silent degradation into a hard failure.**

Sketch of the options, unargued:

1. **Do nothing, deliberately, and write it down.** Defensible if step 2
   above shows thinking survives. Costs a cache leg and some quality;
   buys immunity from the ruby_llm round-trip bugs. Needs a `DECISIONS.md`
   entry either way, because right now this is an accident.
2. **Fix ruby_llm first, then enable.** The ordering the section above
   argues for. Blocks on upstream.
3. **Enable per-transport, not globally.** A `thinking:` field on
   `ChatTransport` — it already carries what "must travel together […] on
   the same server", and thinking-vs-not is exactly that kind of
   per-model-per-server fact. Keeps llama.cpp untouched. Still blocked on
   the round-trip bugs for the Anthropic leg.
4. **Explicitly disable it** (`thinking: {type: "disabled"}`) so the
   behaviour is intentional rather than emergent. Cheapest honest option —
   but rejected outright on Fable 5 / Mythos 5 (400), accepted on Opus 5
   only at effort `high` or below, and the troubleshooting page warns that
   Opus 5 with thinking disabled leaks tool calls into visible text on
   tool-heavy workloads. Probably a trap; listed so nobody re-derives it.


## Where the nuggets go at graduation

- The choice + roads not taken → **`DECISIONS.md`**, its own entry
  (`D_thinking_mode*`?). There is a real fork here regardless of outcome,
  so this earns an entry even if the answer is "do nothing" — today the
  behaviour has no decision behind it at all.
- If a `thinking:` field lands on `ChatTransport` → its yardoc, which
  already owns the "must travel together on the same server" rationale.
- Whatever step 2 measures → the entry's evidence, and a
  `pikuri-core/DESIGN.md` line if it turns out to shape the loop.
- **Do not** let this end up as a paragraph inside
  `D_history_load_repairs`. That is the mistake
  `ideas/thinking-block-replay.md` exists to unwind.
- The three ruby_llm round-trip bugs are upstream's, and are catalogued in
  `ideas/thinking-block-replay.md` — file them from there, once, not twice.
