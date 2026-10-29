# Inline `<think>` tags after the ruby_llm 2.1 upgrade

Status: **regression suspected, scope not measured.** Found from
pikuri-web, whose titler broke on it (fixed there in `16458b5`).

## What changed

ruby_llm 1.16 moved inline reasoning out of the reply on its own:

- **Non-streaming:** `Providers::OpenAI::Chat.extract_think_tag_content`
  (`providers/openai/chat.rb:225`). It scanned `<think>…</think>` into
  `thinking`, `gsub`bed the blocks out of `content`, and `.strip`ped the rest.
- **Streaming:** `StreamAccumulator` kept `@inside_think_tag` /
  `@pending_think_tag` state, so a tag split across chunks was still routed to
  thinking.

ruby_llm 2.x has neither. A grep for `<think`, `think_tag` or
`inside_think` under the `lib/` of 2.0.0, 2.1.0 and 2.1.1 (latest as of
2026-10-29) finds nothing. 2.0.0 dropped it, and its release notes don't say
so. An upgrade does not fix it. Reasoning now
reaches pikuri only through a separate field (`reasoning_content`,
`reasoning`, `thinking`) or content blocks. Text inline in `content` passes
through verbatim, leading and trailing whitespace included.

pikuri took the upgrade in `333a391` (2026-10-10). Its smoke test used
llama.cpp, which by default sends reasoning in `reasoning_content`, so that
path never exercised inline tags. pikuri-core has no `<think>` handling of its
own.

## Who sees it

A server that leaves reasoning inline in `content`:

- llama.cpp with `--reasoning-format none`;
- a chat template that does not split it out;
- a thinking-off parameter the template only half honours (the leak
  pikuri-web's titler was built to survive);
- some OpenAI-compatible proxies.

For those, since the upgrade:

- `Event::Assistant` / `AssistantDelta` carry the raw `<think>…</think>`, so
  every shell renders reasoning as answer text: pikuri-tui's transcript,
  pikuri-web's assistant blocks.
- No `Event::Thinking` / `ThinkingDelta` fires, so the collapsible reasoning
  display never sees it.
- `last_assistant_content` includes it, so any host parsing a reply (titles,
  sub-agent results handed to a parent) gets the reasoning as part of it.
- History stores it as content, so it is replayed to the model as content on
  every later turn. That costs context, and `strip_foreign_thinking!` cannot
  find it to remove it after a model switch.

## Open questions

- `Q_think_scope`: which servers people actually point pikuri at still emit
  inline tags? Try llama.cpp with `--reasoning-format none` against a Qwen3,
  plus whatever cloud or proxy setups the shells document. If none of them do
  in practice, this may be a note rather than code.
- `Q_think_where`: restore it in pikuri (a `ruby_llm_patches.rb` entry, or a
  splitter in the agent's message and streaming handling), or upstream in
  ruby_llm? Removing it may have been deliberate in 2.x. Neither the 2.0.0
  release notes nor a GitHub issue search for "think tag" / `<think>` gives
  a reason; asking upstream is the next step.
- `Q_think_stream`: a streamed splitter has to hold back a partial `<thi` at a
  chunk boundary, the way 1.16's `@pending_think_tag` did. That interacts with
  `Listener::RateLimited` coalescing and with delta-preview shells, so test it
  through pikuri-web's re-render-and-replace too, not just the final event.
- `Q_think_history`: should `History.load` also lift inline tags out of
  histories saved since 2026-10-10, or is a fix going forward enough?

## How to see it

`pikuri-core/spec/pikuri/agent/inline_think_spec.rb` asserts the split over the
wire through `Pikuri::Testing.fake_transport`. It covers a non-streamed reply
(`Thinking`, `Assistant`, `last_assistant_content`) and a streamed one with the
tags split across chunks (`ThinkingDelta`, `AssistantDelta`). Both examples are
`pending`, so CI stays green, and RSpec fails them as soon as they pass. A fix,
whether in pikuri or an upstream release, then forces removing the `pending`
lines.
