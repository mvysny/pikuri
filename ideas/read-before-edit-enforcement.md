# Read-before-edit enforcement

Status: **agreed, not built.** The one *harness* item in the
Claude-parity backport set (the rest are pure prose). Sourced from the
`claude.txt` vs `pikuri.txt` study — Claude Code's harness literally
fails an `edit` whose target wasn't `Read` earlier in the conversation;
pikuri's `edit` only *claims* to.

## The gap: the description promises an enforcement that doesn't exist

`Pikuri::Workspace::Edit`'s description already tells the model
(`pikuri-workspace/lib/pikuri/workspace/edit.rb:76`):

> You must Read the file in this conversation before editing, or the
> call will fail.

But `Edit.edit` (`edit.rb:133`) does **no** read-tracking. The
preconditions it actually enforces are: non-empty `old_string`,
`old_string != new_string`, file exists, not a directory, not binary,
and `old_string` matches exactly. None of them check that the file was
ever `Read`. The promised "the call will fail" is currently a bluff —
the only thing standing in for it is the implicit `old_string`
byte-match (you can't supply a correct `old_string` for a file you
haven't seen).

So the description and the behavior disagree. Backporting real
enforcement is what makes the existing sentence true.

## The design tension to reconcile first

`edit.rb`'s own yardoc (lines 11–19, "Why no confirmer") leans on the
*absence* of enforcement as a feature:

> The `old_string` argument is itself an implicit read-check: the model
> can't write a correct `old_string` without having seen the file [...]
> That makes Edit safe to execute without prompting.

That argument is about the *confirmer*, not about a read-ledger, so the
two aren't in direct conflict — but a real read-before-edit check
changes the framing from "the match is our only read-check" to "the
match is a *second* read-check behind an explicit ledger." When this
lands, that yardoc paragraph needs a sentence reconciling the two
(implicit match still bounds blast radius; the ledger now also rejects
edits to files the model only *thinks* it saw, e.g. via a stale summary
or out-of-band claim).

## Direction (decided): implement the ledger, not soften the prose

Two ways to close the gap; we take the first:

- **(chosen) Make the claim true** — track which paths were `Read` this
  conversation and reject an `edit` to an untracked path with an
  `Error:` that points at the `read` tool. Matches Claude's harness,
  which guarantees the precondition so the prompt can stay terse.
- (rejected) Soften the description to admit there's no enforcement.
  Cheaper, but throws away the guarantee — and the whole Lesson-0 point
  is that a hard runtime guarantee lets the prose lighten, not that the
  prose should retreat to match a weak runtime.

## Implementation notes (to settle when we tackle it)

- **Where the ledger lives.** `Read` and `Edit` are separate tool
  instances that already share one `Workspace::Filesystem` by
  constructor. A read-ledger keyed on the *resolved* path is the
  natural home — either on the `Filesystem` seam or an agent-scoped set
  both tools close over. Keying on the resolved path (not the raw LLM
  string) avoids `./foo` vs `foo` misses.
- **What counts as "read".** Only the `read` tool, full-file or paged.
  A `grep`/`glob` hit returns fragments, not the file — it should *not*
  satisfy the ledger (same as Claude: "Read in this conversation").
- **Invalidation.** A successful `edit`/`write` changes the file, so the
  model's mental copy is now stale. Decide whether a write clears the
  ledger entry (forcing a re-read before the *next* edit) or refreshes
  it with the just-written bytes (the writer knows the new content).
  Claude refreshes after its own writes; lean that way to avoid a
  re-read tax on consecutive edits.
- **Extend to `Write`?** Claude's `Write` also fails on overwriting an
  unread existing file. Pikuri's `Write` already routes through the
  `Confirmer`, which is a *different* guard (human gate vs read-ledger).
  Worth deciding whether the ledger also gates `Write`-over-existing, or
  whether the confirmer is enough there. Probably: ledger-gate the
  overwrite too, since a hallucinated 500-line `content` over an unread
  file is exactly the blast radius the confirmer yardoc worries about.
- **Error shape.** Standard `"Error: ..."` observation the LLM can react
  to (read the file, then retry) — not a raised exception. Consistent
  with the rest of `Edit`'s refusals.

## Source

External study: `prompts-examples/system_prompts/claude-pikuri.md`
§4 ("Put tool-selection and editing rules *at the tools*") — the
"enforce the precondition first, then trim the prose" argument.
