# Three ruby_llm bugs that make an Anthropic thinking round trip lossy

Upstream's, not pikuri's. Read from ruby_llm 1.16.0 source 2026-08-29,
`lib/ruby_llm/providers/anthropic/chat.rb`. File these; nothing in the
idea file's decision blocks on them.

The root cause is the type. `RubyLLM::Thinking` is one text plus one
signature:

```ruby
def self.build(text: nil, signature: nil)
  text = nil if text.is_a?(String) && text.empty?
  signature = nil if signature.is_a?(String) && signature.empty?
  return nil if text.nil? && signature.nil?
  new(text: text, signature: signature)
end
```

An Anthropic assistant turn is an ordered *sequence* of typed blocks, so
the type structurally cannot represent it. `History::Thinking` faithfully
mirrors the lossy shape — meaning **no pikuri-side repair can fix any of
this**; the loss happens before pikuri sees the message.

## 1. A display-omitted block is re-serialized as redacted

`build_thinking_block` (`:200`):

```ruby
if thinking.text
  { type: 'thinking', thinking: thinking.text, signature: thinking.signature }.compact
elsif thinking.signature
  { type: 'redacted_thinking', data: thinking.signature }
end
```

On current models `display` defaults to `"omitted"`, so a normal thinking
block arrives with an empty `thinking` field and a real signature.
`Thinking.build` nils the empty string, so `text` is nil, so the `elsif`
fires and a perfectly ordinary block goes back out as
`{type: 'redacted_thinking', data: <a normal signature>}`.

Confirmed by measurement — see `provider-survey.md`, the
thinking-enabled table.

## 2. Multiple thinking blocks collapse into one, losing n−1 signatures

`extract_thinking_content` (`:97`) *joins* every thinking block into one
string:

```ruby
thinking_blocks = blocks.select { |c| c['type'] == 'thinking' }
thoughts = thinking_blocks.map { |c| c['thinking'] || c['text'] }.join
```

while `extract_thinking_signature` (`:103`) keeps only the **first**
block's signature. Interleaved thinking is automatic on every adaptive
model, so multi-block turns are the normal case, not an edge one.

## 3. A `redacted_thinking` block alongside a `thinking` block is dropped

`extract_thinking_signature` (`:103`):

```ruby
thinking_block = blocks.find { |c| c['type'] == 'thinking' } ||
                 blocks.find { |c| c['type'] == 'redacted_thinking' }
thinking_block&.dig('signature') || thinking_block&.dig('data')
```

A `thinking` block wins the `||`, so a `redacted_thinking` block in the
same response is never read. This is exactly the failure Anthropic's
troubleshooting page names as the top cause of the modification 400:
"your code filters content blocks by type and drops `redacted_thinking`
blocks". Note also that `signature` here means two different things
depending on origin — an attestation, or a redacted block's `data` blob.

## Streaming is fine

`anthropic/streaming.rb` handles `signature_delta` correctly
(`extract_signature_delta`), so the loss is in the non-streaming parse
and the re-serialization, not in the stream.
