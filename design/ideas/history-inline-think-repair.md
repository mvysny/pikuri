# Repair inline `<think>` tags in saved histories

Between the ruby_llm 2.1 upgrade (`333a391`, 2026-10-10) and
`D_inline_think_tags`, a server that leaves reasoning inline saved it as
assistant **content**. Those histories still carry `<think>…</think>` in
`content`, so loading one replays the reasoning as answer text on every turn,
and a model switch can't strip it.

## Open questions

- `Q_think_history`: should `History.load` lift the tags into `thinking`, the
  way `D_history_load_repairs` already repairs other damage on the way in?
  `Pikuri::Agent::ThinkTagSplitter.split` would do the work. Or is the window
  short enough that a fix going forward is enough, and old conversations just
  carry the tags?
- If repaired: only for histories written in that window (there is no format
  version to key on), or for any assistant content that contains a tag?
