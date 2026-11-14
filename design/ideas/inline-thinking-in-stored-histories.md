# Inline `<think>` in histories stored before `split_think_tags`

Found moving Puri onto pikuri `f4d0a6f`: `History#lift_inline_thinking` went in `e05635f` with
`ThinkTagSplitter`, and Puri's `Replay` called it. Nothing replaced it on the way *in*.

`D_inline_think_tags` splits a live reply, so a history written from now on is clean. A history
written before the split — by a server on `--reasoning-format none`, or any server that kept
reasoning in `content` — still holds `<think>…</think>` at the head of assistant `content`. Resumed
through `Agent.new(history:)`, that reasoning replays to the model as answer text on every turn,
which is the exact cost `D_inline_think_tags`' context names; and a host replaying it for display
(Puri's `Replay`, webui's `HistoryReplay`) shows the reasoning as the answer.

## Already decided, on a reason that is backwards

`D_inline_think_tags` does mention the lift — under *Alternatives rejected*: "Repairing histories
saved with the tags at load. Only pre-release builds wrote them." The reason is inverted:

- pikuri first split live replies in `ac0571e` (2026-10-29), which is **not** in v0.1.0
  (2026-08-30).
- v0.1.0 shipped `History#to_json`, writing `version: 1` — the version
  pikuri-workshop's `HistoryFile` (`VERSION = 1`) still reads, so such a file plausibly loads
  today.

So the *released* builds are the ones that wrote the tags; every pre-release build since
Oct 29 writes clean histories.

## Who actually holds one

- Puri began saving in `bac1ba6` (2026-11-12) on pikuri `c7b972c`, which already split live — no
  history Puri ever wrote holds tags; its `lift_inline_thinking` call was belt-and-braces.
- Measured 2026-11-14 on the dev box: 0 of the stored histories under `~/.local/state/puri` and
  `~/.cache/pikuri` contain `<think>`.
- The exposed population is: v0.1.0 from rubygems × llama.cpp on `--reasoning-format none` × a host
  that saved conversations. Nothing runs pikuri in production.

## Why restoring the lift is more than a few lines

- **ruby_llm exposes no splitter.** `RubyLLM::Protocols::ChatCompletions::ThinkTags` is
  `# :nodoc:`. Reaching for it couples core to an internal; re-adding pikuri's own static split
  gives two rules, live and stored, free to drift (ruby_llm's 64-byte leading-whitespace cap,
  explicit `reasoning_content` winning).
- **A load repair fixes only the model-facing half.** Puri's `Replay` and webui's `HistoryReplay`
  read a `History` with no `Agent` in sight, so display needs the public
  `History#lift_inline_thinking` back too, with its spec and yardoc.
- **It is a weak fit for `D_history_load_repairs`**, whose context is history a provider
  *refuses* — a hard 400. Inline `<think>` is never refused, only wasteful; "a resumed
  conversation reads like a live one" is broader than what that entry argues.

## Options

- `Q_restore_lift`: put the lift back as a load repair plus a public `History` method for display
  hosts — on ruby_llm's internal `ThinkTags`, or on a re-added pikuri splitter.
- `Q_document_the_gap`: keep the rejection, but correct its reason in `D_inline_think_tags`.
- `Q_host_migrates`: per `D_history_value_type` the stored file format and its version belong to
  the host (`HistoryFile`), so if old files ever need fixing, a `VERSION` bump with a migration
  there is the right home — not a permanent repair in core.

## Proposal

`Q_document_the_gap`, with `Q_host_migrates` named as the escape hatch. Rewrite the rejected
alternative in `D_inline_think_tags` to say: only v0.1.0, the last release before the split, wrote
such histories; nothing in production runs it; a host that must read one owns the file format and
its version (`D_history_value_type`) and migrates there. Then graduate this file, and drop any
leftover `lift_inline_thinking` mention in Puri's `Replay` if `5f3e195` left one.
