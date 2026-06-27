# Read-before-edit enforcement

Status: **mostly built.** The enforcement + composite landed and the
full suite is green; the only remaining piece is the optional
`Workspace::Extension` dedup (refactor step 3, see below) — deferred
until a second host (`pikuri-tui` / `pikuri-web`) makes the single
registration point pay off. The one *harness* item in the Claude-parity
backport set — Claude Code's harness fails an `edit` whose target wasn't
`Read` earlier in the conversation; pikuri's `edit` used to only *claim*
to, and now actually does.

One design change from the locked plan: the `ReadLedger` class was
**inlined** into the {Workspace} composite (an inline `Set` of
relative-path strings). It had exactly one caller and no logic of its
own beyond membership, so a separate class was the kind of speculative
abstraction the project avoids.

## The gap: the description promises an enforcement that doesn't exist

`Pikuri::Workspace::Edit`'s description tells the model
(`pikuri-workspace/lib/pikuri/workspace/edit.rb:76`):

> You must Read the file in this conversation before editing, or the
> call will fail.

But `Edit.edit` (`edit.rb:133`) does **no** read-tracking. The only
thing standing in for "the call will fail" is the implicit `old_string`
byte-match — you can't supply a correct `old_string` for a file you
haven't seen. The promised guarantee is currently a bluff. Backporting
real enforcement is what makes the existing sentence true.

## The design tension, reconciled

`edit.rb`'s "Why no confirmer" yardoc (lines 11–19) leans on the
*absence* of a read-check as a feature: the `old_string` match is "an
implicit read-check," which is why Edit needs no confirmer. That's an
argument about the *confirmer*, not about a ledger, so the two don't
conflict — but when this lands, that paragraph needs a reconciling
sentence: the `old_string` match still bounds blast radius; the ledger
is now a *second, explicit* check that also rejects edits to a file the
model only *thinks* it saw (a stale summary, an out-of-band claim).

## Design (locked)

Keep `Filesystem` pure; introduce a composite that pairs it with the
read-state, and a dedicated ledger type. The governing intuition
(ext4 vs inotify): **a filesystem doesn't track reads — a separate
watcher does.** Hanging read-state off `Filesystem` is the "easy to
forget it's there" trap, so the ledger is its own abstraction and the
composite is what owns both.

- **`Pikuri::Workspace::Filesystem`** — unchanged role: path
  resolution, fs abstraction, sandboxing. No read-state. (Its `@env`
  memo is a *derived, idempotent* property — not session state — so it
  stays immutable-by-value.)
- **`Pikuri::Workspace::ReadLedger`** — new. A named wrapper over a
  `Set` of **workspace-relative** path strings: `mark(rel)` /
  `seen?(rel)`. Dumb by design — no path logic, just membership.
  Relative (not absolute) keys keep it scoped and self-consistent to
  its one workspace and sidestep realpath/symlink noise.
- **`Pikuri::Workspace::Workspace`** — new composite class, nested
  under the existing module (the `com.pikuri.workspace.Workspace` Java
  shape — chosen over making `Pikuri::Workspace` itself a class so the
  existing `module Workspace` files need no `module`→`class` churn).
  Holds `filesystem` + `read_ledger`. Convenience `mark_read(resolved)`
  / `read?(resolved)` relativize the resolved path against
  `filesystem.project_root` and delegate to the ledger —
  relativization lives here, the only place holding both the root and
  the ledger, which is what lets `ReadLedger` stay dumb. (Paths under a
  readable dir *outside* `project_root` relativize to a `../..` form —
  deterministic and unique, so still a valid key.)
- **`Pikuri::Workspace::Confirmer`** — unchanged, stays in the
  namespace.
- **`Pikuri::Workspace::Extension`** — new. `new(filesystem:,
  confirmer:)` builds the composite internally (the ledger is hidden,
  the way `Tasks::Extension` hides its `List`) and registers all five
  file tools. This is the single registration point — for `pikuri-code`
  today and `pikuri-tui` / `pikuri-web` / any downstream gem on
  `pikuri-code` tomorrow. That bigger-picture dedup is what earns the
  Extension (one call site today, but the same set re-registered in
  every future host otherwise).

Tools flip from `workspace:`-is-a-`Filesystem` to
`workspace:`-is-the-composite. The param was *already* named
`workspace:` while receiving a `Filesystem` — the composite makes the
name truthful. `with_workspace(workspace)` likewise stops being a lie:
it takes a `Filesystem` today despite the name; it'll take a `Workspace`.

## Behavior (decisions locked)

- **What counts as "read":** only the `read` tool (full or paged). A
  `grep`/`glob` hit returns fragments, not the file — it does **not**
  satisfy the ledger (matches Claude's "Read in this conversation").
- **Marking:** mark on a successful `read`; *also* mark after a
  successful `edit` and a successful `write` — the writer knows the
  resulting bytes, so consecutive edits to the same file don't pay a
  re-read tax (the "refresh / keep the entry" choice, over
  "clear and force re-read").
- **Checks:** `edit` requires `read?` true, else an `Error:` pointing
  at the read tool. `write` over an **existing** file also requires
  `read?` true — this closes the exact blast radius the confirmer
  yardoc worries about (a hallucinated 500-line `content` clobbering
  unread bytes). Creating a **new** file is unaffected (nothing to
  read).
- **Error shape:** `"Error: ..."` observation, never a raise —
  consistent with Edit's other refusals; the model reads, then retries.

## Sub-agent behavior + caveats

- **inherit mode** reuses the parent's tool instances by reference
  (`sub_agent_tool.rb:160`) → child shares the parent composite and its
  ledger. **temp mode** rebuilds `Read` via
  `with_workspace(fresh composite)` (`sub_agent_tool.rb:182`) → fresh
  ledger, so a temp clone starts empty. Both correct.
- **Caveat (documented, not solved):** an *inherit-mode* sub-agent
  holding **both** read and edit/write would share the parent ledger
  and could edit a file it never read in its *own* context. No current
  persona has that combo (`RESEARCHER` / `FILE_MINER` /
  `GIT_REPO_RESEARCHER` are read-only). Fixing it means a fresh ledger
  per inherit child, which fights inherit mode's reuse-by-reference —
  revisit if a coder sub-agent ever ships.
- **Caveat:** `with_workspace` exists only on `Read`/`Grep`/`Glob`, not
  `Edit`/`Write` — temp personas are read-only, so the writers never
  needed it. If a temp persona ever edits/writes, `Edit`/`Write` need
  `with_workspace` too (carrying the composite). Left out now as YAGNI.

## Refactor scope (reviewable steps)

1. ✅ Add the `Workspace::Workspace` composite (read record inlined as a
   `Set`, no separate `ReadLedger` class), with specs.
2. ✅ Flip the five tools to take the composite; wire `mark_read` into
   `Read`/`Edit`/`Write` and the `read?` checks into `Edit`/`Write`;
   fix the `with_workspace` signatures.
3. ⏳ **Remaining.** Add `Workspace::Extension`; switch `bin/pikuri-code`
   from five `add_tool` calls to one `add_extension`. Deferred until a
   second host wires the file tools (the dedup payoff). Until then the
   bin builds the composite inline (`bin/pikuri-code`: `filesystem` for
   Bash/sandbox, `workspace` composite for the file tools).
4. ✅ Update the `sub_agent_tool.rb` temp-workspace site to wrap its
   freshly-minted `Filesystem` in a `Workspace` composite.
5. ✅ Update specs (pikuri-workspace, plus `git_repo_researcher_spec`,
   the subagents temp-workspace spec, and pikuri-pdf's read spec).
6. ✅ Reconcile the "Why no confirmer" paragraph in `edit.rb`'s yardoc
   (and Write's "Why ask-on-overwrite").

## Source

External study: `prompts-examples/system_prompts/claude-pikuri.md`
§4 ("Put tool-selection and editing rules *at the tools*") — "enforce
the precondition first, then trim the prose."
