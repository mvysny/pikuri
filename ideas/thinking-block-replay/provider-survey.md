# What each backend does with a replayed thinking block

Sourcing for facts 2–4 in the idea file. Read from source and measured
2026-08-29 against ruby_llm 1.16.0 and a live llama.cpp.

**Anthropic is the only provider pikuri can reach that has a signature
concept on the wire pikuri uses.**

| provider | `reasoning_signature` / `signature` on input | reasoning **text** on input |
|---|---|---|
| Anthropic via ruby_llm | never sent — thinking is disabled | never sent either |
| llama.cpp | no such concept; unknown key, dropped | **read and handed to the template**, template-dependent |
| xAI / Grok (chat completions) | no signature on this surface | probably ignored — *unverified* |

## Anthropic: pikuri emits no thinking block at all

`with_thinking` appears nowhere in the repo; `Agent` exposes no
`attr_reader :chat`, so the Chat is sealed behind the loop seam and no
host can enable it either. This is an invariant, not a default. So
`@thinking` is `nil` on every `render_payload`, and ruby_llm gates both
Anthropic serialization paths on it:

- `format_basic_message_with_thinking`: `if msg.role == :assistant && thinking_enabled`
- `format_tool_call_with_thinking` → `prepend_thinking_block`:
  `return content_blocks unless thinking_enabled`

Measured offline (`format_message` is pure — no API key needed), all four
stored shapes with thinking disabled:

```
summarized (text+sig)      -> [{:type=>"text", :text=>"ok"}]
display-omitted (nil+sig)  -> [{:type=>"text", :text=>"ok"}]
redacted (nil+blob)        -> [{:type=>"text", :text=>"ok"}]
dropped sig (text+nil)     -> [{:type=>"text", :text=>"ok"}]
```

For reference, what it *would* emit if anyone called `with_thinking` —
this is the shape the old draft's three-row failure table described, and
it is entirely hypothetical today:

```
summarized (text+sig)      -> [{:type=>"thinking", :thinking=>"…", :signature=>"SIG"}, …]
display-omitted (nil+sig)  -> [{:type=>"redacted_thinking", :data=>"SIG"}, …]     # bug
redacted (nil+blob)        -> [{:type=>"redacted_thinking", :data=>"BLOB"}, …]
dropped sig (text+nil)     -> [{:type=>"thinking", :thinking=>"…"}, …]            # modified block
```

## OpenAI-compatible: ungated, always sent

`OpenAI::Chat#format_messages` does `.compact.merge(format_thinking(msg))`
on every assistant message, and `format_thinking` consults no thinking
config at all:

```
keep -> {:role=>"assistant", :content=>"ok", :reasoning=>"…",
         :reasoning_content=>"…", :reasoning_signature=>"SIG"}
drop -> {:role=>"assistant", :content=>"ok", :reasoning=>"…",
         :reasoning_content=>"…"}
```

Note the text survives both branches — `history.rb:216` passes `text:`
unconditionally.

## llama.cpp: reads the text, has no signature

From `common/chat.cpp`, in the OpenAI-compat **input** parser
(`common_chat_msgs_parse_oaicompat`, ~line 452):

```cpp
if (message.contains("reasoning_content")) {
    msg.reasoning_content = message.at("reasoning_content");
}
```

`grep -c signature common/chat.cpp` → **0**. Nothing to verify against,
so `reasoning_signature` is an unrecognized key: the parser reads named
fields and never rejects unknowns.

The generic Jinja path (~1044–1067) converts it into a content block and
erases the raw key:

```cpp
// If message contains `reasoning_content`, add it as a block of type `thinking`
content.push_back({{ "type", "thinking" }, { "thinking", … }});
…
adjusted.erase("reasoning_content");
```

Whether the template then renders that block is **template-version
dependent**, and further gated by `--reasoning-preserve` /
`supports_preserve_reasoning`, which controls full-history vs
last-assistant-message preservation. Caveat for anyone re-checking: the
`"<think>\n" + msg.reasoning_content` injection in the Qwen3 path
(~1207) is under `inputs.has_continuation()` — that is the
prefill/continuation path, **not** normal history. Don't cite it as proof.

That uncertainty is the argument rather than a hole in it: pikuri emits a
claim whose effect it cannot predict across templates, builds and flags.

## xAI / Grok

ruby_llm has a dedicated provider, but `XAI < OpenAI` and `XAI::Chat`
overrides only `format_role` and `format_content` — not `format_messages`
or `format_thinking`, and not `completion_url`. So Grok receives the same
ungated triple at `/v1/chat/completions`.

xAI's replay mechanism is Responses-API only and encrypted
(`include: ["reasoning.encrypted_content"]`), so there is no
chat-completions signature. On grok-4.6 what comes back is *summarized*
reasoning. **Unverified:** what xAI does with an unexpected
`reasoning_content` on an input message.

## Measured: live llama.cpp

`http://mavi-fw:8080`, `unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M`, one real
turn through a real `Agent`, reading `export_history`
(`model_id_echo_probe.rb`):

```
requested (transport.model / @chat.model.id) : "unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M"
reported  (message.model_id / data['model']) : "unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M"
equal?                                       : true
thinking.text      : "Here's a thinking process:\n\n1.  **Analyze User Input:**…"
thinking.signature : nil
```

Three findings: ids echo verbatim, so the `model_id` comparison is sound
here and no schema field is needed; the reasoning text is populated and
is **raw first-person chain of thought**, not a summary; and the
signature is nil, so today's repair drops a field that never exists.

### The two-namespace hazard (real, but does not bite here)

`current_model = @chat.model&.id` is what pikuri **requested**, resolved
through `Models.resolve`. `m.model_id` is what the server **reported**
(`data['model']`). Two namespaces. Where they disagree, `keep` is false
for every message on every load with no switch anywhere — which would
silently turn option 1 into option 6.

The probe shows they agree on llama.cpp. Keep the hazard as a note: it
can only misfire same-model, and it fails safe (lose the model's own
reasoning; never inject a foreign one). Re-run the probe before trusting
a new backend.

### Measured: the export round trip

`roundtrip.rb`, confirming why retention must ride `@message_meta`:

```
SAME MODEL       on disk: text | in @chat: text | re-exported: text
AFTER A SWITCH   on disk: text | TODAY   : text | re-exported: text
                              | OPTION 1: nil  | re-exported: nil   <-- data loss
```
