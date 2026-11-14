# Inline `<think>` in histories stored before `split_think_tags`

Found moving Puri onto pikuri `f4d0a6f`: `History#lift_inline_thinking` went in `e05635f` with
`ThinkTagSplitter`, and Puri's `Replay` called it. Nothing replaced it on the way *in*.

`D_inline_think_tags` splits a live reply, so a history written from now on is clean. A history
written before the split — by a server on `--reasoning-format none`, or any server that kept
reasoning in `content` — still holds `<think>…</think>` at the head of assistant `content`. Resumed
through `Agent.new(history:)`, that reasoning replays to the model as answer text on every turn,
which is the exact cost `D_inline_think_tags`' context names; and a host replaying it for display
(Puri's `Replay`, webui's `HistoryReplay`) shows the reasoning as the answer.

`D_history_load_repairs` already repairs a loaded history on the way in (dangling tool calls);
the lift was the second such repair and its entry no longer mentions it.

- `Q_restore_lift`: put the lift back as a load repair, now on ruby_llm's splitter if it exposes
  one (one rule for live and stored), or
- `Q_document_the_gap`: decide old histories are rare enough, and say so in
  `D_inline_think_tags`' *Known gap*, so a host knows to expect it.

Leaning to the first: it is a few lines, and "a resumed conversation reads like a live one" is
the property `D_history_load_repairs` exists for.
