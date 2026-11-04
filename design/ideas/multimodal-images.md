# Multi-modal input — images first

Goal: let the **user** hand the model an image ("what's wrong in this screenshot?"), not just
let a tool do it. Images first; audio / PDF-as-pixels / video later, if ever.

Shipped 2026-11-04, now documented elsewhere: `Pikuri::Attachment`, `run_loop(attachments:)` +
`Event::UserTurn#attachments`, `@path` in `pikuri-chat` (`book/chat.md`), and the refusal of what
a model can't see (`Agent#modalities`, `D_refuse_unsupported_attachments`). What is left:

## Not done

- **Other bins.** Only `pikuri-chat` has `@path`; `pikuri-code`, `pikuri-assistant`, … can't
  attach. Lift `pikuri-core/bin/chat_attachments.rb` into `lib/` when a second bin wants it.
  Alternative syntax if `@path` ever clashes: a `/image <path>` line staging an attachment for
  the next turn.
- **Clipboard images** (`wl-paste --type image/png`) — a later nicety; terminals already paste a
  dragged file as its path, which `@path` handles.

## Open questions

- `Q_trifecta` — a user-attached image is user input, not a tool observation, so no tool leg
  applies. But a screenshot of a web page or e-mail carries *someone else's* text. Treat it
  like typed/pasted text (the user vouches for it) — most likely — or does it deserve a note
  in `SECURITY.md`?
- `Q_mid_loop` — `Control::Interloper#inject_user_message(content)` is text only; should it
  carry attachments too (pikuri-tui: drop an image while the agent works)? Probably not until a
  host asks.
- `Q_subagents` — the `agent` tool's task is a String; a sub-agent never sees the parent's
  image. Fine (the parent can tell it a path and the child can `read` it), as long as the
  child persona has `read`.
- `Q_memory` — `Extension#on_user_message` gets text only, and an attachment-only turn skips it
  (decided, in its yardoc). Should pikuri-memory at least record "[user attached image.png]" so
  a recalled fact isn't missing its referent?
- `Q_listener_render` — `Listener::Terminal` stays silent on `UserTurn` (it never echoes
  typed input), so it only matters to a host that renders its transcript from events —
  pikuri-tui: a dim `📎 shot.png (123 KB, image/png)` line, mirroring
  `Tool.describe_attachments`?
- `Q_beyond_images` — ruby_llm's Chat Completions path also does audio (`input_audio`) and
  PDFs (`file` parts); llama.cpp does audio with an audio mmproj. The core already says no
  "image" (the modality check goes by MIME family), so this is bins only: which file types
  `@path` accepts.
