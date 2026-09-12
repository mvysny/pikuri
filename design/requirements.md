# Requirements

What must hold — of pikuri's behaviour, not of the environment it runs in. One entry per
requirement. A requirement *states*; it never argues: the fork behind it, if there is one, is a
`D_` entry it cites.

- Cite by slug — `R_<slug>`. `grep '^## R_' design/requirements.md` is the index.
- Slug only what is referenced from elsewhere. Most of what must hold about one class is stated
  completely in that class's yardoc and needs no entry here; an `R_` earns its slug when a seam
  spans gems, or when a tripwire and an `AGENTS.md` line both need something to point at.
- Shape: `## R_<slug> — <the requirement, one sentence>`, then **Status** (Active, or
  Retired <date> — see `D_<slug>`), **Why** (one paragraph), **Enforced by** (a spec, a tripwire
  cited as `T_<slug>` — this line is that slug's home — or "review only"), **See** (the yardoc
  and the `D_` entries behind it).
- A retired requirement stays as a tombstone. A requirement that wants a *Rejected:* section is a
  decision — move it to `decisions.md`.
- **The first entry is the ruler**: later entries are trimmed to its length, never the other way
  round.

---

## R_no_system_role — Nothing pikuri appends mid-conversation is ever `role: :system`

**Status:** Active.
**Why.** A `:system` message added after a chat has started fails two ways, neither visible to
anything pikuri can observe — the message is in the payload, the listener stream renders it, the
history holds it. Qwen3.6's chat template silently drops every one past the leading header, so the
text never reaches the model; a provider carrying `:system` in a separate field (Anthropic,
Bedrock) merges it into the standing prompt instead, so a block meant for one turn is presented as
though it had always been there and stays in force. Every block pikuri injects after the opening
prompt — a skill body, a reference file, an interloper's note — therefore rides a `:user` turn
wrapped in `<system-reminder>`.
**Enforced by.** `T_no_system_role` — no `add_message(role: :system` anywhere in `lib/`, and
`add_message(role:` at all confined to `pikuri-core/lib/pikuri/agent.rb`.
**See.** {Pikuri::Agent#append_reference_block}, `D_reference_text_as_user_turn`.

## R_walked_path_denylist — A path a tool walked to is filtered against the denylist before it is reported

**Status:** Active.
**Why.** `resolve_for_read` / `resolve_for_write` gate a path the *model* supplied. A directory
listing, a glob, a grep hit or an LSP location is a path pikuri found by itself, and nothing gated
it — so without this pass a denied `.env` or `.git/` leaks its name, and for grep a line of its
content, into the transcript. The `denied?` filter is the fail-closed guarantee; `rg`'s own
pruning is an optimization layered on top, never the thing relied on.
**Enforced by.** `T_walked_path_denylist` (the roster of files allowed to perform the filter),
`T_lsp_denied_sites` (only `Sources` and `Renderer` perform it inside pikuri-lsp).
**See.** {Pikuri::Workspace::Filesystem#denied?}, `D_walked_path_denylist`.

## R_subprocess_chokepoint — Every subprocess a gem's `lib/` spawns goes through `Pikuri::Subprocess.spawn`

**Status:** Active.
**Why.** The chokepoint puts every child in a fresh process group and tracks the pgid, so
`Subprocess.cleanup!` can SIGTERM whole groups at exit — including work a command backgrounded
with `&`, which `wait` alone never sees. A bare `Process.spawn` or `Open3` in a gem is untracked,
and what it leaves running outlives the turn that started it. (Timeouts are deliberately *not*
here: callers wrap their argv in coreutils' `timeout`.) Two long-lived stdio children are the
documented exceptions, each owning its own teardown: the MCP client and the LSP client.
**Enforced by.** `T_subprocess_chokepoint` — spawn primitives in `lib/` confined to
`subprocess.rb` and `pikuri-lsp/lib/pikuri/lsp/client_wrapper.rb`.
**See.** {Pikuri::Subprocess}, `pikuri-lsp/AGENTS.md`, `pikuri-mcp/AGENTS.md`.
