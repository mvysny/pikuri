# Boot-time orientation (Option D)

The last unshipped piece of the directory-listing work. Origin: Grok 4.6's
review of `pikuri-tui-code` (`feedback.txt`, item 1) — *"`glob *` gave me ten
root files and no tree. Orientation is the first thing I do in a repo."*

Already shipped, and graduated out of this note: `Workspace::Listing`, `read`'s
recovering refusal, and the `file_list` tool (plus the tool-naming convention →
`CLAUDE.md` Conventions, and the "five file tools" → "file tools" sweep). The
choice and every rejected road live in `DECISIONS.md` `D-directory-listing`;
don't re-argue them here.

## The idea — settled 2026-08-15

Inject a **depth-1** `Listing` into the system prompt once at startup, so
orientation costs zero tool calls.

Not depth 2, and no auto-degrade ladder: **depth 1 is the whole answer.** It
fixes the reported bug exactly — `rg --files` structurally cannot emit
directories, so `glob` hides them all; depth 1 reveals them — and the
measurements below say the extra levels are not worth their bytes.

## The evidence

Measured 2026-08-15 with the *shipped* `Listing` renderer over 45 projects in
`~/work/my` (vok excluded), plus this repo and a real `$HOME`.

| | median | max | fits 1 KB |
|---|---|---|---|
| depth 1 | 312 B (~90 tok) | 906 B (pikuri) | **45/45** |
| depth 2 | 772 B | 24,720 B (mvysny.github.io) | 35/45 |

Per-root, for the two extremes:

| root | depth 1 | depth 2 | depth 3 |
|---|---|---|---|
| this repo | 906 B | 3,900 B | 5,612 B |
| a real `$HOME` | 1,438 B | 8,065 B | 51,263 B (hits `Listing::MAX_BYTES`) |

Three findings, in order of weight:

1. **The counts column does depth-2's job exactly where depth 2 is
   unaffordable.** `mvysny.github.io` at depth 1 is 371 B and says
   `_posts/  [0 dirs, 256 files]` / `_site/  [255 dirs, 8 files]` — Jekyll blog,
   256 posts, generated output. Depth 2 there is **24.7 KB** and adds nothing
   but 256 post filenames. Same shape in `aedict/aedict-testing`: 13 dictionary
   corpora, 363 B at depth 1, ~80 near-identical filenames at depth 2.
2. **Where depth 2 *is* cheap it is uninformative, for the same reason it is
   cheap** — the layout is conventional. A 2× growth factor buys `src/`,
   `build/`, `.github/workflows/`. This monorepo is the extreme case: 4.3×
   growth to learn that fifteen gems each have `bin/ lib/ prompts/ spec/`.
3. **pikuri is the outlier, not the typical case** — largest depth-1 output of
   the 45 and the steepest depth-2 growth. Designing against it alone
   overestimates the cost of a snapshot and the value of a second level.

The one apparent counter-example, `~/work/my/aedict` (4 rows, 124 B — a
container of four sub-projects), does not survive contact with how the binaries
are launched: `project_root: Dir.pwd`, so a coding agent starts in
`aedict/aedict`, not the container. Each of the four renders as an ordinary
project at depth 1 (275–531 B, 13–23 rows).

## Settled design

D is a **`Workspace::Extension` system-prompt snippet, living in
`pikuri-workspace`**, unconditional, allowed to go stale.

- **Depth 1, always.** No constructor flag, no degrade ladder, no depth stated
  to the model. `file_list`'s own default stays depth 1 too, so the snapshot and
  the tool agree.
- **A 2 KB cap, as a fail-safe.** Twice the headroom over the largest root
  measured (`$HOME`, 1,438 B), and still catches a 5,000-entry `Downloads/`.
  Near-dead code by design.
- **Accept drift, and say so in the snippet.** Label the tree a boot snapshot
  and add one line: a file or folder you can't find here may simply be newer
  than the snapshot — call `file_list` for the current state. Cheaper than any
  refresh mechanism, and drift is *already* bounded without one —
  `Agent#assemble_system_prompt` (`agent.rb:490`) re-pulls every extension's
  snippets on `clear_conversation`, so the snapshot re-takes itself on `/clear`.
- **Extension, not `Control::Interloper`.** `system_prompt_snippets` is exactly
  this hook and already carries dynamic content (`Skill::Extension`,
  `Mcp::Extension`). The Interloper is also the *more* expensive answer to
  staleness, not the cheaper one guessed originally: a snippet is a stable
  prefix, while a re-injected `kind: :system` item appends a message every time
  — growing history and busting the prompt cache.
- **`pikuri-workspace`, riding the existing `Workspace::Extension`.** The
  listing needs the workspace to know its root, and is useless without the
  file tools the same extension wires. Cost is a constant plus a line in
  `#system_prompt_snippets` — no new wiring point.
  - It's also the only home where the staleness line may *name* `file_list`. A
    `prompts/<bin>.txt` version couldn't — CLAUDE.md's "No tool names in a
    main/binary system prompt" tripwire would hit it. That rule's target is
    prompt-vs-wiring drift, and a snippet contributed by the extension that
    *registers* the tool structurally can't drift: the `Tasks::Extension` /
    `SubAgentTool.available_agents_snippet` precedent.

### The degenerate paths

Two replace the snapshot with **one line**, never silence and never a
head-truncated tree — a truncated listing is an alphabetical prefix that
teaches the model `spec/` does not exist.

1. **Over the 2 KB cap** — name the root and point at `file_list`.
2. **Empty root** — say the root is empty. `Listing.render` returns `""` there
   (real case: `~/work/my/pikuri-worktrees`), and a bare empty snippet reads as
   a failed walk.

The third, **root unreadable**, is deliberately *not* handled: `Listing.render`
raises `SystemCallError` when the root itself can't be opened, and that
propagates out of `Agent.new`. Costs zero lines, and it's the loud-errors call
— a workspace rooted at a directory you can't open is a wiring bug, and every
file tool is about to fail the same way. Narrower than it looks, too:
`Filesystem::Restricted#initialize` already `realpath`s the root, so a *missing*
root explodes before this code runs; only `EACCES` on an existing directory
reaches here.

### What the depth-1 choice dissolves

Recorded so a later reader doesn't reopen them:

- **No dirs-only walker, no `rg --files` derivation.** Gitignore correctness was
  the whole case for a second walker, and it only matters at depth 2, where
  `node_modules/` eats the allowance. At depth 1 it is *one row* — and an
  informative one. So: one walker, one formatter, and no path-segment-sort
  gotcha (`-` 0x2D sorts before `/` 0x2F) to guard against.
- **No `root == Dir.home` proxy.** It was standing in for a budget test, and it
  is wrong in both directions: a tidy home renders in 1.4 KB and is genuinely
  useful to an OS-helper agent; `~/work/my/pikuri` is a repo. `$HOME` at depth 1
  is comfortably under the cap, so nothing needs a special case.
- **No constructor flag / per-host asymmetry.** ~90 tok at the median is cheap
  enough to be unconditional, which is also the user's argument for D at all:
  **if a harness wires the workspace, it is safe to assume it wants to work with
  those files.**
- **No "which depth did I get?" ambiguity.** The snippet is one shape, always.

### Still true, and unaffected

**`FILE_MINER` never sees D.** `SubAgentTool` selects tool *instances* from the
parent by name and wires no extensions (`sub_agent_tool.rb:34,149`), so no
snippet reaches a sub-agent. Already mitigated ahead of D:
`prompts/persona-file-miner.txt` and `persona-git-repo-researcher.txt` tell both
recon personas to open with a `file_list` at `depth: 2`. Re-check that wording
still reads right once D ships for the main agent.

## Open questions

None. Ready to implement.

## Graduation

- depth 1 + the 2 KB cap + one-line-not-truncation → yardoc on
  `Workspace::Extension`
- a line in the relevant seam/convention in `CLAUDE.md`
- the depth-1 choice + its rejected roads (depth 2 with an auto-degrade ladder,
  the dirs-only walker, the `rg --files`/gitignore walker, the `$HOME` proxy,
  the constructor flag) → fold into the existing `D-directory-listing` entry,
  whose status line already promises this snippet. Not a new entry: same
  decision, second half.
- `CHANGELOG.md` one-liner

Once D ships, this note is fully graduated — delete it.
