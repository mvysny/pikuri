# Multi-modal input — images first

Goal: let the **user** hand the model an image ("what's wrong in this screenshot?"), not just
let a tool do it. Images only (audio and PDF rejected; why-not in `bin/chat_attachments.rb`).

Shipped 2026-11-04, now documented elsewhere: `Pikuri::Attachment`, `run_loop(attachments:)` +
`Event::UserTurn#attachments`, the same on `Interloper#inject_user_message`, `@path` in
`pikuri-chat` (`book/chat.md`), and the refusal of what a model can't see (`Agent#modalities`,
`D_refuse_unsupported_attachments`). What is left:

## Not done

- **Other bins.** Only `pikuri-chat` has `@path`; `pikuri-code`, `pikuri-assistant`, … can't
  attach. Lift `pikuri-core/bin/chat_attachments.rb` into `lib/` when a second bin wants it.
  Alternative syntax if `@path` ever clashes: a `/image <path>` line staging an attachment for
  the next turn.
- **Clipboard images** (`wl-paste --type image/png`) — a later nicety; terminals already paste a
  dragged file as its path, which `@path` handles.

## Open questions

- `Q_listener_render` — `Listener::Terminal` stays silent on `UserTurn` (it never echoes
  typed input), so it only matters to a host that renders its transcript from events —
  pikuri-tui: a dim `📎 shot.png (123 KB, image/png)` line, mirroring
  `Tool.describe_attachments`?
