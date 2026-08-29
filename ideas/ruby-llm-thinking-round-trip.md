# File three ruby_llm thinking round-trip bugs upstream

Status: **open, and the only thing left is filing.** Found while deciding
`D_thinking_block_replay` (2026-08-29, ruby_llm 1.16.0); that decision
shipped and its note is graduated. These three are **upstream's**, none
of them blocks pikuri, and none is fixable from pikuri — so they get a
note of their own rather than a decision entry.

Nothing here is urgent: pikuri never enables thinking, so it sends no
thinking block to Anthropic at all, and bug 1 is the only one that could
bite the moment anyone calls `Chat#with_thinking`. See
`ideas/thinking-blocks-never-echoed.md` for why that day may come.

**Do not carry a workaround in pikuri without a decision entry saying
why** — the whole point of these being upstream's is that pikuri does not
design around them staying broken.


## The root cause

`RubyLLM::Thinking` is one text plus one signature:

```ruby
def self.build(text: nil, signature: nil)
  text = nil if text.is_a?(String) && text.empty?
  signature = nil if signature.is_a?(String) && signature.empty?
  return nil if text.nil? && signature.nil?
  new(text: text, signature: signature)
end
```

An Anthropic assistant turn is an ordered *sequence* of typed blocks, so
the type structurally cannot represent one. All three bugs below are that
one flaw surfacing differently. A faithful fix is a list of typed blocks,
which is a breaking change to a public value type — worth saying so in the
issue rather than proposing three separate patches.

All line numbers are `lib/ruby_llm/providers/anthropic/chat.rb` @ 1.16.0.


## 1. A display-omitted block is re-serialized as `redacted_thinking`

`build_thinking_block` (`:200`):

```ruby
if thinking.text
  { type: 'thinking', thinking: thinking.text, signature: thinking.signature }.compact
elsif thinking.signature
  { type: 'redacted_thinking', data: thinking.signature }
end
```

On every current model `display` defaults to `"omitted"`, so an ordinary
thinking block arrives with an empty `thinking` field and a real
signature. `Thinking.build` nils the empty string, so `text` is nil, the
`elsif` fires, and a perfectly normal block goes back out as
`{type: 'redacted_thinking', data: <a normal signature>}`.

This is the one that would actually 400 — Anthropic rejects modified
blocks in the latest assistant message. **Highest severity of the three.**

Measured, thinking enabled:

```
display-omitted (nil+sig)  -> [{:type=>"redacted_thinking", :data=>"SIG"}, …]
```


## 2. Multiple thinking blocks collapse into one, losing n−1 signatures

`extract_thinking_content` (`:97`) joins every thinking block into one
string:

```ruby
thinking_blocks = blocks.select { |c| c['type'] == 'thinking' }
thoughts = thinking_blocks.map { |c| c['thinking'] || c['text'] }.join
```

while `extract_thinking_signature` (`:103`) keeps only the **first**
block's signature. Interleaved thinking is automatic on every adaptive
model, so multi-block turns are the normal case rather than an edge one.


## 3. A `redacted_thinking` block beside a `thinking` block is dropped

`extract_thinking_signature` (`:103`):

```ruby
thinking_block = blocks.find { |c| c['type'] == 'thinking' } ||
                 blocks.find { |c| c['type'] == 'redacted_thinking' }
thinking_block&.dig('signature') || thinking_block&.dig('data')
```

A `thinking` block wins the `||`, so a `redacted_thinking` block in the
same response is never read. Anthropic's troubleshooting page names
exactly this as the top cause of the modification 400: "your code filters
content blocks by type and drops `redacted_thinking` blocks".

Note also that `signature` here means two different things depending on
origin — an attestation, or a redacted block's `data` blob. Worth calling
out in the issue, since it is what makes bug 1 possible.


## Not a bug

`anthropic/streaming.rb` handles `signature_delta` correctly
(`extract_signature_delta`), so the loss is in the non-streaming parse and
the re-serialization, not in the stream. Say so in the issue — it narrows
the search.


## Graduation

File one issue (or three linked ones) at
<https://github.com/crmne/ruby_llm>, then **delete this note**, leaving
only the issue URL wherever it earns a mention. If upstream declines and
pikuri ends up carrying a workaround, that is a `DECISIONS.md` entry, not
a revival of this file.
