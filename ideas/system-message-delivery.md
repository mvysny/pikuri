# Two things still owed after the `:system`-delivery fix

The finding, the decision and the invariant have all graduated — the fix
shipped 2026-08-17 and was confirmed the same day through `bin/pikuri-code`
against `unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M`, which now reports the two
skills a `paths:` promotion had just put in play.

Read those in their homes rather than here: `DECISIONS.md`
`D-reference-text-as-user-turn` (the template excerpt, the three-model canary
table, the rejected probe/merge/subset options, the consequences),
`COMPARISON.md` §"grok-build's injection channel" (the prior art), the
**Reference-text delivery seam** in `CLAUDE.md` (the invariant), and
{Pikuri::Agent#append_reference_block} (the mechanism).

This file survives only for the two pieces with no home yet. The taps at the
bottom are kept because both pieces are built out of them.


## 1. `bin/pikuri-wire-check` — the online half of the test

The offline half shipped: the wire-format specs in
`pikuri-core/spec/pikuri/testing_spec.rb` assert role names *and* message
order in the recorded request body, including that the only `system` message
is at index 0. That pins the layer pikuri owns.

It cannot pin the layer below. Point the binary at the configured server and
have it print (a) what pikuri would POST for a representative turn — system
prompt, mid-conversation injection, tool call/result pair — and (b) which of
those markers survive `/apply-template`. One command answering *"is anything I
send being eaten?"*

Worth building because it generalizes past the bug that motivated it: the same
probe catches a template that drops tool messages, reorders them, or mangles
multi-part content. Two constraints for whoever writes it:

- `/apply-template` is **llama.cpp-only**, so the binary reports "couldn't
  ask" rather than pretending a clean bill of health on other backends.
- Do **not** build on `/props` → `chat_template_caps.supports_system_role`.
  Qwen3.6 reports `true` there — accurate for a *leading* system message,
  useless for the mid-conversation question. Note the trap wherever the check
  lands, or someone will reach for it.


## 2. A book chapter — "the messages array is not the prompt"

A teaching nugget of the first order for the stated audience (a skilled Ruby
dev new to LLMs), and the one graduation target still open. The shape: you
believe you sent something, every layer you can see agrees, and the model
never read it — here are the two commands that show you the difference.

The author's framing of why this class of bug is the worst, worth keeping
verbatim for the chapter: *"messages not getting through to the LLM is not
easy to test and the effects aren't immediately visible: the LLM just behaves
slightly differently than expected. So, not easy to reproduce and hard to find
— the worst kinds of bugs."*

Needs one new `book/<slug>.md`, one line in `book/README.md`, and the two
neighbouring "What's next" links fixed.


## The two taps, kept because both pieces are built from them

**pikuri → server.** ruby_llm talks HTTP through Faraday and pikuri already
lets a transport swap the adapter (that is how `Pikuri::Testing` fakes a
server), so recording is a subclass that peeks and delegates:

```ruby
class Tap < Faraday::Adapter::NetHttp
  def call(env)
    CAPTURED << JSON.parse(env.body.to_s)   # the exact JSON about to be POSTed
    super
  end
end

transport = Pikuri::Agent::ChatTransport.from_openai_server(
  server: CONFIG.fetch('llm_server'), model: CONFIG.fetch('llm_model')
).with(faraday_adapter: Tap)
```

Against the *scripted* transport the same trick needs no server — subclass
`Pikuri::Testing.build_adapter(script.responses)` instead of `NetHttp`. That
is what the `testing_spec.rb` wire specs do.

**server → model.** The canary, which is the whole check in five lines:

```python
prompt = POST('/apply-template', {'model': model, 'messages': [
    {'role': 'system', 'content': 'HEADER'},
    {'role': 'user',   'content': 'Q'},
    {'role': 'system', 'content': 'PIKURI_CANARY'}]})['prompt']
survives = 'PIKURI_CANARY' in prompt
```

No generation, no GPU work, no model state: `/apply-template` renders a
`messages` array and hands back the prompt string, which is the ground truth
for "what did the model actually read".

Delete this file once both pieces land.
