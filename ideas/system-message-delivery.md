# Mid-conversation `:system` messages are eaten by some chat templates

Status: **finding verified beyond doubt, fix undecided.** Measured 2026-08-17
against the author's own llama.cpp router (`mavi-fw:8080`) with
`unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M`. Nothing has been changed in response
yet — two *adjacent* bugs were fixed the same day (see *Already fixed*), and
neither of them was this one.

**The finding in one line:** every `role: :system` message pikuri appends
*after* the system prompt is silently discarded by Qwen3.6's chat template.
Not rejected, not warned about — absent from the string the model reads.


## Why this is the worst kind of bug

The message is in the HTTP payload. The listener stream renders it. The chat
history holds it. Every layer pikuri can see says "delivered". The model then
behaves as if it never happened, which reads as the model being dumb or
stubborn rather than as a delivery failure. The reported symptom was exactly
that: *"the model insists it only sees five skills"* — and it was right.

This is also why it needs a permanent test (below): no assertion inside
pikuri, at any layer pikuri owns, can catch it.


## The evidence

### 1. It is the model's own Jinja template, executed faithfully

The template ships **inside the GGUF**, authored by the model publisher.
The server runs with `--jinja` (visible in `/v1/models` → `status.args`), so
llama.cpp executes that embedded template verbatim via minja rather than its
own built-in heuristics. Fetch it:

```
curl -s 'http://mavi-fw:8080/props?model=unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M' \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['chat_template'])"
```

8 KB of Jinja. The relevant part:

```jinja
{%- set num_sys = 0 %}
{%- if messages[0].role == 'system' or messages[0].role == 'developer' %}
    …merge messages[0] (and messages[1] if it is also system) into one header…
    {%- set num_sys = 2 %}   {# or 1 #}
{%- endif %}
…
{%- for message in messages %}
    {%- if loop.index0 >= num_sys and message.role != "system" and message.role != "developer" %}
```

That last line is the whole bug: the render loop **skips every
system/developer message** past the leading one or two it already merged into
the header.

### 2. Rendered proof — `/apply-template`

llama.cpp exposes the template step as an endpoint. No generation, no GPU
work, no model state: it renders a `messages` array and hands back the prompt
string. This is the ground truth for "what did the model actually read".

```
POST /apply-template
{"model":"unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M","messages":[
 {"role":"system","content":"SYSPROMPT_MARKER"},
 {"role":"user","content":"USER_MARKER"},
 {"role":"assistant","content":"","tool_calls":[{"id":"call_1","type":"function",
   "function":{"name":"read","arguments":"{\"path\":\"a.rb\"}"}}]},
 {"role":"tool","tool_call_id":"call_1","content":"TOOLRESULT_MARKER"},
 {"role":"system","content":"PROMOTION_MARKER"}]}
```

→

```
<|im_start|>system\nSYSPROMPT_MARKER<|im_end|>
<|im_start|>user\nUSER_MARKER<|im_end|>
<|im_start|>assistant\n<think>\n\n</think>\n\n<tool_call>…</tool_call><|im_end|>
<|im_start|>user\n<tool_response>\nTOOLRESULT_MARKER\n</tool_response><|im_end|>
<|im_start|>assistant\n<think>\n
```

`PROMOTION_MARKER` is gone. Same result for a system message *between* two
user turns, so it is not a trailing-position quirk. A `user` message in the
identical position renders fine.

### 3. Live A/B on the real model

A stripped pikuri-code (real server, Faraday adapter tapping every request
body). Turn 1 reads `pikuri-core/lib/pikuri/agent.rb` — which fires the
`**/*.rb` gate for `tuile` + `writing-rdoc`. Turn 2 asks the model to name the
skills it can load.

| promotion injected as | in the HTTP payload | model's answer |
|---|---|---|
| `:system` (today) | yes, every request from #2 on | `cop, gh-auth, gradle, maven, vaadin-boot-app` |
| `:user` wrapped in `<system-reminder>` | yes | `cop, gh-auth, gradle, maven, **tuile**, vaadin-boot-app, **writing-rdoc**` |

The mechanism is correct end to end. Only the delivery role was wrong.

### 4. It is this *model*, not llama.cpp and not Qwen as a family

Canary (`POST /apply-template` with `[system, user, system("PIKURI_CANARY")]`,
then grep the rendered prompt):

| model | mid-conversation `system` survives |
|---|---|
| `bartowski/Qwen2.5-7B-Instruct-GGUF:Q5_K_M` | **yes** |
| `unsloth/Qwen3-4B-Instruct-2507-GGUF:Q5_K_M` | **yes** |
| `unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M` | **no** |

So the behaviour arrived with the newer Qwen3.6 template. Which makes it
*more* dangerous than a blanket rule would be: it flips when you change
models, silently, and nothing in the API reports the change.

**Trap for a detector:** `/props` also returns `chat_template_caps`, and
Qwen3.6 reports `"supports_system_role": true`. True in the narrow sense (a
*leading* system message works), useless for this question. Do not build on
it.


## Blast radius — this is not a skills bug

Everything pikuri appends mid-conversation as `role: :system` is affected on
such a template:

- `Skill::Extension#schedule_load_skill` — a host-loaded skill body.
- `Agent#dispatch_ext_on_user_message` — the `<memory-context>` block, i.e.
  **pikuri-memory's entire per-turn prefetch**, on every turn.
- Any retrieved-context injection a host builds on `inject_system_message`
  (vectordb RAG was heading here).
- `Skill::PathActivationListener`'s promotion — where it was found.

Worth measuring before deciding: pikuri-memory has presumably been silently
inert against Qwen3.6 for as long as that model has been the default.


## Already fixed (do not re-find these)

Both were real, both were necessary, neither was sufficient. Committed
2026-08-17 as `fix(core): the promotion reached the model, mislabelled and in
the wrong place`:

1. **`:system` went over the wire as `developer`.** ruby_llm's OpenAI provider
   maps `:system` → `developer` unless `openai_use_system_role` is set;
   pikuri never set it, so the *whole system prompt* was mislabelled.
   `Agent#build_context` now asks for `system`. (Qwen3.6's template happens to
   accept both in the header slot — but a template checking only `system`
   would have dropped the prompt itself.)
2. **The injection split a tool-call pair.** ruby_llm fires
   `after_tool_result` *before* it appends the `role: :tool` message, so the
   drain landed the injection between the assistant's `tool_calls` and its
   result — invalid on OpenAI and Anthropic, mangled by a local template. The
   drain now rides `after_message` and waits for the whole tool batch.


## The decision to brainstorm

### Option A — always `:user`, wrapped

`inject_system_message` keeps its documented *semantics* (reference text, no
`on_user_message` dispatch, no `UserTurn`, still `Event::SystemInjected`) and
changes only what it lands as: `role: :user`, content wrapped in
`<system-reminder>…</system-reminder>`. Every caller fixed at once, no API
change. This is the shape Claude Code uses, presumably for this same reason.

Arguments for, in the order they seemed to weigh:

1. **A branch we rarely take is a branch that rots.** A conditional means the
   `:system` path runs on Qwen2.5 and the `:user` path on Qwen3.6, and neither
   is exercised where the other lives.
2. **A wrong guess here is silent.** Every other failure mode in pikuri is
   loud. This one is "the model seems a bit dim today".
3. **A probe cannot be authoritative anyway** — `/apply-template` is
   llama.cpp-only, so there is always a default to pick for "couldn't ask",
   and it has to be the one that cannot fail silently.

Costs to weigh: Anthropic's `:system` hoisting makes a host-loaded skill
*sticky*, which `schedule_load_skill` documents as intentional; uniform
`:user` gives that up. And a `<system-reminder>` inside a user turn may carry
less weight than a real system message on models that honour one — untested.

### Option B — probe and adapt

Canary `/apply-template` at boot; use `:system` where it survives, `:user`
where it doesn't; assume `:system` for non-llama.cpp providers (OpenAI and
Anthropic both honour it). Keeps the strongest signal available on each
backend, at the cost of two paths and a boot-time round trip.

### Option C — merge into the system prompt instead

Rewrite the leading system message to append the block. Rejected before it was
written: prefix mutation kills the KV cache on every injection, which is the
exact cost `D-skill-path-activation` weighed and accepted *not* paying.

### Sub-questions either way

- **The wrapper tag.** `<system-reminder>` (Claude Code's) vs something
  pikuri-flavoured. Note the memory extension already wraps its own payload in
  `<memory-context>`, so a core wrapper double-wraps — is that fine, or should
  the wrapper be the caller's job?
- **Does `Agent::EmptyTurnError` survive?** Its whole trigger is a
  `:system`-only conversation rendering `messages: []` on Anthropic. If
  injections become `:user`, that case mostly evaporates. Keep the error for
  genuinely system-only histories, or retire it?
- **What about the `:user` kind that already exists?** `inject_user_message`
  fires `on_user_message` + `UserTurn`. Option A means two interloper kinds
  that both land as `role: :user` and differ only in dispatch. Is that two
  kinds, or one kind plus a flag, or a third `:reference` kind?
- **Streaming/prefill interaction** — untested. Qwen3.6's template opens an
  `<|im_start|>assistant\n<think>\n` prefill; does an injected user turn
  before that change anything? Probably not, but nobody looked.


## The permanent test this needs

The author's framing, worth keeping verbatim: *"messages not getting through
to the LLM is not easy to test and the effects aren't immediately visible: the
LLM just behaves slightly differently than expected. So, not easy to reproduce
and hard to find — the worst kinds of bugs."*

Two halves, because the two layers fail differently:

- **Offline, always-on:** the wire-format specs added in
  `pikuri-core/spec/pikuri/testing_spec.rb` — a `Faraday::Adapter` subclass
  over the scripted transport records every request body, and the specs assert
  role names and message *order* in the payload. That is the layer pikuri
  owns, and it is now pinned.
- **Online, on demand:** a `bin/pikuri-wire-check` dev binary — point it at
  the configured server and it prints (a) what pikuri would POST for a
  representative turn (system prompt, mid-conversation injection, tool
  call/result pair) and (b) which of those markers survive `/apply-template`.
  One command answering "is anything I send being eaten?" It generalizes past
  this bug: the same probe catches a template that drops tool messages,
  reorders them, or mangles multi-part content.

### Reproducing all of the above from scratch

Everything here came from two taps, both cheap enough to redo in a minute.

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

**server → model.** The canary, which is the whole detector in five lines:

```python
prompt = POST('/apply-template', {'model': model, 'messages': [
    {'role': 'system', 'content': 'HEADER'},
    {'role': 'user',   'content': 'Q'},
    {'role': 'system', 'content': 'PIKURI_CANARY'}]})['prompt']
survives = 'PIKURI_CANARY' in prompt
```

The live A/B was a stripped pikuri-code: real transport + `Tap`, one `read`
tool, `Skill::Extension` over the real `~/.claude/skills`, an interloper, then
two `run_loop` calls — "read pikuri-core/lib/pikuri/agent.rb" followed by
"which skills can you load right now?". Swapping the injection role was done
by redefining `ext.announce` on the singleton, so no library code was touched
to get the second row of the table.


## Graduation

- The **choice** (uniform vs probe) plus the rejected merge-into-prompt option
  → `DECISIONS.md`, a new entry. It must carry the template excerpt and the
  three-model table, because "why don't we just use system messages?" is
  exactly what someone re-opens in a year when their model handles them fine.
- The **delivery invariant** (never a bare mid-conversation `:system`) → a
  CLAUDE.md seam line, most likely folded into the **Interloper injection
  seam**, which currently documents `add_message(:system)` as the mechanism.
- **How to tap both layers** → the book. This is a teaching nugget of the
  first order for the stated audience (a skilled Ruby dev new to LLMs): the
  messages array is not the prompt, and here is the one command that shows you
  the difference.
- The **`/props` `chat_template_caps` trap** → wherever the detector lands, as
  a why-not note.
- `COMPARISON.md` if it turns out other harnesses already reached the same
  conclusion — Claude Code's `<system-reminder>` shape is evidence they did,
  but nobody has checked *why* they did.
- Delete this file once the fix ships.
