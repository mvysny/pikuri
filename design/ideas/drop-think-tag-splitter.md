# Drop `ThinkTagSplitter` once ruby_llm 2.2 ships

Status: **blocked on an upstream release.** [ruby_llm#1345](https://github.com/crmne/ruby_llm/issues/1345)
was closed 2026-11-03 by [#1405](https://github.com/crmne/ruby_llm/pull/1405) (merge `2885c59`),
on `main` only — the newest tag is still `v2.1.1`, `main`'s `version.rb` still says `2.1.1`. Its
`docs/_getting_started/whats-new-in-2-2.md` suggests it ships in 2.2. Check
`gem list -r ruby_llm --exact` before starting.

## What upstream shipped

`Protocols::ChatCompletions::ThinkTags`, behind `config.split_think_tags` — **off by default**,
settable per `RubyLLM.context`.

- Non-streaming: `parse_completion_body` splits the content when no `reasoning_content` /
  `reasoning` / thinking block came with it.
- Streaming: `build_chunk` splits each chunk *before* `Protocol::Streaming#stream_response` hands
  it to the caller's block; a tag cut across chunks is held back and released by the new
  `stream_remainder` hook as one last chunk. So `Agent#emit_chunk` would get clean deltas — the
  gap that made `D_inline_think_tags` keep a streaming half in pikuri is closed.
- Unclosed block → thinking; whitespace after `</think>` dropped; up to 64 bytes of leading
  whitespace tolerated; tags exact and case-sensitive.
- Annotation/citation indices shifted by the removed prefix.

Differences from ours, none of which matter for pikuri:

- Only a block that **opens** the content is split; ours splits a `<think>` anywhere, which eats
  a literal `<think>` the model writes mid-answer. Upstream is the better rule.
- Explicit `reasoning_content` wins and the content is left alone; ours merges both. A server
  sending `reasoning_content` never inlines tags.
- Only the Chat Completions protocol; pikuri already forces `c.openai_protocol = :chat_completions`
  in `Agent#build_context`, and every OpenAI-compatible provider there rides it.

## The removal

1. `pikuri-core.gemspec`: `ruby_llm` `~> 2.1` → `~> 2.2`; `bundle update ruby_llm`.
2. `Agent#build_context`: `c.split_think_tags = true`, with a one-line why beside the
   `openai_protocol` line (llama.cpp `--reasoning-format none`; a no-op for a server that sends
   `reasoning_content`). Per-chat context, so the connection seam holds.
3. Delete `Pikuri::Agent::ThinkTagSplitter` + `think_tag_splitter_spec.rb`,
   `Agent#split_inline_thinking!` and its `after_message` call, both `@think_splitter = …`
   resets (`after_message`, `streaming_block`), and the splitter in `emit_chunk` (back to plain
   `chunk.content`). Fix the `emit_chunk` / `streaming_block` yardoc that mentions it.
4. Delete `History#lift_inline_thinking` and its helpers (`inline_thinking?`, `lift_thinking`)
   and its call site — histories saved while the bug was live need no repair, nothing is in
   production. Specs that cover it go too.
5. Specs: one agent spec through `Pikuri::Testing.fake_transport` pinning that an inline
   `<think>` reply lands in `thinking`, streamed and not — it guards the config line against a
   ruby_llm rename.
6. Docs: delete `D_inline_think_tags` (or shrink it to "why `split_think_tags = true`"), drop
   the `<think>` paragraph from `D_history_load_repairs`, grep for `ThinkTagSplitter` /
   `D_inline_think_tags` / `lift_inline_thinking` across `design/`, `book/`, `SECURITY.md`.
   One-sentence CHANGELOG entry under `[Unreleased]`.

## Empty `reasoning_content` — not a problem with llama.cpp

#1351's review flagged that an empty `reasoning_content: ""` counts as present and suppresses
the split: upstream's `parse_think_tags` checks `thinking_text.nil?`, and `ThinkTags#feed` stops
on any non-nil explicit thinking. Measured 2026-11-03 against llama.cpp `b10438` serving
Ornith-1.5, raw HTTP, per-request `reasoning_format`:

- `none`: the message has no `reasoning_content` key at all, streamed (0 of 114 deltas carry
  one) or not; content opens with `<think>\n`. Upstream splits it.
- `auto` / `deepseek` / server default: `reasoning_content` is a real string, never `""`, and
  content arrives clean (`"391"`) — nothing to split either way.

A proxy that sends `""` alongside inline tags would still defeat the upstream split; none
pikuri targets is known to.
