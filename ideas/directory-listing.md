# A real directory listing

Origin: Grok 4.6's review of `pikuri-tui-code` (`feedback.txt`, item 1) —
*"`glob *` gave me ten root files and no tree. I used `bash ls` to see `lib/`,
`spec/`, `bin/`, `ideas/`. Orientation is the first thing I do in a repo, and
glob-as-find is the wrong primitive for it."*

## The problem, reproduced

`glob` is built on `rg --files` (`search/glob.rb:188`), and **`rg --files`
emits files only** — directories never appear. `glob '*'` at this repo's root
returns 15 files and hides all 18 directories, including every one of the
fifteen `pikuri-*` gems. A model orienting here concludes pikuri is a docs repo.

There is no glob pattern that reveals a directory exists. The only workaround
is `glob '**/*'`, which lists all 497 files, mtime-scrambled, head-truncated at
50 KB.

## The broken cross-reference (fix regardless of what else we do)

The two tools point at each other, and one of them lies:

- `read.rb:164` — `"Error: <path> is a directory; use the glob tool to list files."`
- `glob.rb:148` — `"Error: <path> is a file, not a directory; use the read tool to view it."`

`read` sends the model to `glob` for a job `glob` structurally cannot do. Grok
followed that instruction, got ten root files, and correctly concluded the
primitive was wrong. That advice line is false today.

## Why not just teach `glob` about directories

Rejected — three reasons, in order of weight:

1. **mtime sort on directories is actively misleading.** Measured at this
   repo's root: 12 of the top 13 entries by mtime are directories, `.git` at
   #2. A directory's mtime bumps when a child is *added or removed* (a
   `git checkout`, a new spec file), not when a child is edited. Directories
   would colonise the top of every result — and mtime-descending is glob's
   stated unique capability (`glob.rb:13`). We'd damage the differentiator to
   bolt on a feature the tool does badly.
2. **A matched directory is a dead end.** The model gets `lib/` in a result
   list and cannot `read` it. Its only follow-up is another `glob`. Reveals
   that something exists without revealing what's in it.
3. **Not a flag flip.** `rg --files` can't emit directories at all.

And a `depth:` parameter on `glob` is a non-starter: depth is *already*
expressible in the pattern (`*` = 1, `*/*` = 2, `**/*` = any). A second,
contradictable way to say the same thing — `pattern: "**/*", depth: 1` has no
defensible answer.

## Why not just tell the LLM to run `bash ls`

The tempting option, and the one Claude Code takes. Verified that it really
would be frictionless: `ls` is in `PASSIVE_BINARIES`, so
`PassiveCommandDetector#passive?` pre-approves it with no prompt, and the
detector is wired in both `pikuri-code` (`bin/pikuri-code:252`) and `pikuri-os`
(`os/extension.rb:103`). One call, zero friction, and `ls -la` is about as
deeply in-distribution as a command gets.

**Rejected, decisively, because `FILE_MINER` has no bash — by design.**
`file_miner.rb:33` is `tool_names: %w[read grep glob]`, and the yardoc above it
(`:16-21`) says why: *"no shell for `curl`… even if a file the miner reads
carries a prompt-injection attempt."* Under a bash-only listing policy, the
recon sub-agent whose entire job is orienting in an unfamiliar tree is the one
agent that can never list a directory — and granting it bash to fix that would
delete the documented security property and its `SECURITY.md:132` row.

Two supporting reasons:

- **Dependency direction.** `pikuri-workspace.gemspec` depends on `pikuri-core`
  only; Bash lives in `pikuri-code`, which depends on workspace, not the
  reverse. A host wiring the file tools without the coding gem would get
  read/write/edit/grep/glob and no way to see a directory — the lower gem's
  completeness hanging on a gem above it.
- **Seam escape.** Bash takes the bare `Filesystem`, not the `Workspace`
  composite, so `bash ls` bypasses `resolve_for_read` entirely — and
  `read_only.rb:16` states outright that it doesn't gate Bash and won't pretend
  to. Orientation in plan mode would route through the read-only posture's one
  admitted hole.

**The asymmetry in one line: Claude Code is one binary that always has bash;
`pikuri-workspace` is a gem that frequently doesn't.** Claude Code can assume
the shell — composability is pikuri's product, so pikuri can't. `pikuri-code`
and `pikuri-os` lose nothing either way; the model can still reach for
`bash ls` there if it prefers.

## What other harnesses do

- **opencode** puts it in `read`, not glob — `COMPARISON.md:252` quotes its
  description verbatim: *"Read a file **or directory** from the local
  filesystem."*
- **Claude Code** ships no listing tool at all today; it shells out to `ls`.
  (It historically had an `LS` tool, since dropped.)

So the convergent position is "**not in glob**" — but it is *not* "everyone
ships a `file_list` tool". Worth knowing before claiming parity either way.

## Proposal: a `file_list` tool (+ `read` self-heals)

New **`Pikuri::Workspace::FileList`** — top level alongside Read/Write/Edit,
*not* under `Workspace::Search::` where Grep/Glob live. Listing a folder is
essentially a read of it, not a search; it borrows `Search::Utils` but that's
reuse, not membership.

- Params: `path` (default workspace root), `depth` (**default 1**, cap ~3).
  The default is load-bearing on the name — see *Naming* below.
- **Sorted by name**, directories first with a trailing `/`, then files.
  Hierarchy is the axis here — which is the whole argument against putting this
  in `glob`, so borrowing glob's mtime sort would undercut it.
- **Every row says how big it is, or why it can't**: files carry a size,
  directories carry a child summary — `[4 dirs, 25 files]`.
- **Summary rule: show it exactly where the contents aren't shown** — i.e. on
  directories at the deepest rendered level. At depth 1 that's every directory;
  at depth 2+ an expanded directory's children are already on screen, so a
  summary there restates them at ~8 tokens a row. One rule, no depth branch.
  - Counts are **immediate children, not recursive**. Recursive is arguably
    better orientation ("this gem has 200 files") but needs a full walk,
    re-introducing the traversal `Dir.children` was picked to avoid.
  - `[empty]` is its own case — `[0 dirs, 0 files]` reads as a lie next to a
    directory we simply couldn't open.
  - **On failure, print the errno class, not a prose word.** Rescue
    `SystemCallError` (as `Utils.child_listing` already does) and render
    `e.class`: `[Errno::EACCES]`, `[Errno::ENOENT]` (vanished mid-listing),
    `[Errno::ELOOP]` (symlink cycle), `[Errno::ENOTDIR]`. Same code as a fixed
    `[unreadable]`, strictly more information, and each errno implies a
    different follow-up where one prose word collapses them. Errno constants
    are deeply in-distribution — the model reads `EACCES` as "permission
    denied" unaided. This is "errors are loud — raise with the offending data"
    applied to a per-row degradation instead of a raise.
  - **Same treatment for file rows.** A dangling symlink fails `File.size` with
    `ENOENT`; `[Errno::ENOENT]` in the size column beats printing `0B`. Glob
    hits this case today and papers over it with a `0.0` mtime fallback
    (`glob.rb:236`) — don't inherit that.
  - Folding this in retires `Utils.child_listing`'s prose fallback
    (`'OS error listing immediate children'`), which the delegation removes
    anyway.
- **Sizes human-readable** (`4.2K`, `50M`), not `52428800`. Models parse the
  scaled form as easily as humans, and it's what `ls -h` has trained them on.
  Note the existing `Glob::MAX_BYTES_LABEL` renders `"50 KB"` with a space —
  keep that phrasing in the *truncation marker* and use `ls -h` style only for
  per-row sizes; don't unify them.
- **Output capped at `Glob::MAX_BYTES`** (50 KB), same head-truncation
  treatment.
- Takes the `Workspace::Workspace` composite like its siblings (it doesn't mark
  the read ledger, but consistency settles it).
- Reuse `Utils.oversized_root_refusal` and Glob's trifecta legs verbatim
  (filenames, no new leg — same reasoning as `glob.rb:108`).
- Make `Utils.child_listing` delegate to the new renderer so there's one
  listing formatter, not two.
- Replace `read.rb:164`'s false advice with the self-healing refusal below.
- **Add to `FILE_MINER`** (`file_miner.rb:33` → `%w[read grep glob file_list]`), and
  update the `SECURITY.md:132` row. Safe: `file_list` adds *no* trifecta leg beyond
  what the persona already carries, and the injection defense is about having
  no tool to *act* on an injected instruction — listing grants no action. It's
  also the persona that needs orientation most.

### Implementation: `Dir.children`, not the `rg --files` prefix trick

Settled 2026-08-15. Deriving directories by grouping `rg --files` output by
path prefix looked clever — gitignore correctness and child counts fall out of
one call — but it has three blind spots, because a directory only exists if a
*file* under it survived rg:

- symlinked directories vanish (`rg --files` doesn't follow symlinks without `-L`)
- directories holding only gitignored files vanish (no `build/`, no `node_modules/`)
- empty directories vanish

Tolerable for a boot snapshot (option D); wrong for a tool answering *"what is
actually in this directory?"*. `Dir.children` is correct on all three, needs no
subprocess, and is simpler.

**Consequence: `include_gitignored` goes away.** Without rg, nothing evaluates
`.gitignore`, so `file_list` shows everything except `.git/` (matching Glob's
existing hard exclusion). This makes `file_list` the one file tool that diverges
from Grep/Glob on gitignore — accepted, because `ls` doesn't respect gitignore
either and "`build/` exists" is orientation signal rather than noise. Revisit
only if the noise proves real.

**Gotcha found while prototyping:** sort path-segment-wise, not lexically.
`-` (0x2D) sorts before `/` (0x2F), so `pikuri/lib` lands *after*
`pikuri-workspace/spec` and renders under the wrong parent.

### `read` on a directory — settled: error recovery, not a documented feature

Agreed 2026-08-15. `read` on a directory returns the depth-1 listing
(delegating to `file_list`'s renderer) behind an `Error:` prefix — exactly the
`Utils.oversized_root_refusal` move, which already refuses *and* hands back the
useful thing rather than dead-ending. Critically: **say nothing about it in
`read`'s description.**

That's what dissolves the duality with `file_list`: the model is only ever *taught*
one way to list, so it never faces a two-tools-no-criterion coin flip. The
`read` path exists solely to rescue a call that was already made.

- One *documented* way to list (`file_list`), so no coin-flip for the model.
- The accidental `read lib/` self-heals with no extra round-trip.
- Zero schema / description cost — which matters, because Grok's item 7 is that
  the standing prompt is already heavy.

The road not taken (carry into the `D-` entry): letting `read` list
directories as a *documented* capability, opencode-style. Rejected because
`read` would then have two behaviours keyed on path type — structurally the
same objection we used against overloading `glob`. It's weaker here ("read" is
a generic verb, "glob" names a mechanism), which is why the undocumented
recovery path survives while the documented one doesn't.

Constraint to preserve: `read` must not touch the read-before-edit ledger for a
directory. Free today — the `:164` branch returns before `mark_read` — but the
kind of thing a refactor silently breaks, so it wants a spec.

### Naming: `file_list` — settled 2026-08-15

**The tool is `file_list`. There is no `file_` sweep over the other file tools.**

Enumerating every shipped tool name surfaced pikuri's unwritten convention, and
it's already consistent: a prefix marks a **family sharing one backing
resource** — `task_*` (4), `thunderbird_*` (7), `vectordb_*` (3),
`fileindex_*` (2), `web_*` (2), `git_*` (2) — while a **universal singleton
verb goes bare**: `read`, `write`, `edit`, `grep`, `glob`, `bash`, `fetch`,
`skill`, `recall`, `agent`, `calculator`, `mcp_connect`. File verbs are the
second kind.

Rejected — renaming the file tools to `file_read` / `file_write` / …:

- It contradicts the anti-drift argument used against overloading `glob`.
  `read`/`write`/`edit`/`grep`/`glob` are the most in-distribution tool names
  in existence; `file_read` spends that prior for nothing semantic.
- Breaking change to every host's persona `tool_names:` — a `**Breaking:**`
  CHANGELOG entry bought with a cosmetic gain.
- `COMPARISON.md:136-142` is a parity table lining pikuri's tool names up
  column-for-column with other harnesses; the sweep makes pikuri the one row
  that doesn't align.
- There is no collision to solve — nothing in the inventory competes with
  `read` or `write`.

So why prefix *this* one, against its bare siblings? Because the problem isn't
collision, it's grammar. `read`/`write`/`edit` are transitive verbs with an
implied default object that convention supplies ("a file"). `list` has no
default object — "list *what*?" is live in a wiring that also carries tasks,
MCP servers and skills. (Checked: no `task_list` ships — the task tools are
create/delete/in_progress/completed — so bare `list` collides with nothing
today. The weakness is linguistic, not a clash.) The prefix is paid once, here,
to supply the missing object.

Also rejected:

- `ls` — the one candidate carrying a precise behavioural prior (flags,
  columns, `-la`), so every divergence from real `ls` invites the model to
  wonder which one it's holding. Its familiarity is the trap, not the benefit.
- `file_tree` — **the name must track the default depth.** "tree" promises
  hierarchy; a depth-1 default delivers a flat listing. There were only ever
  two coherent pairs: `file_tree` + depth 2 (one call buys orientation), or
  `file_list` + depth 1 (answers "what's in *this* directory"). **Option D
  picks between them:** since D solves orientation at boot, the tool's
  remaining job is the targeted follow-up — so depth 1, so `file_list`. Had D
  slipped, the tool would have had to carry orientation itself and the other
  pair would be right. Never mix them.

### Docs sweep: drop the count from "five file tools"

`"five file tools"` is load-bearing in nine places — `CLAUDE.md:27`, the
Workspace seam at `CLAUDE.md:97`, `lib/pikuri-workspace.rb:8`,
`extension.rb:5`, `workspace.rb:25`, `DESIGN.md:44`,
`trifecta_legs_spec.rb:5`, `CHANGELOG.md` (historical, leave alone), and a spec
*name* (`it 'registers all five file tools'`).

Collapse to **"file tools"** — no counting, can't go stale. This is a pure
docs/naming cleanup with no dependency on the tool, so it can land as its own
commit *first* and stop being a blocker.

## Option D: boot-time orientation, on top

Inject a depth-2 tree into the system prompt once at startup, so orientation
costs zero tool calls. Measured on this repo (497 files, 184 dirs,
gitignore-respecting, `~chars/3.5`):

| variant | chars | ~tokens |
|---|---|---|
| dirs depth ≤2, indented tree + child counts + root files | 1139 | **~325** |
| dirs depth ≤3, same shape | 1555 | ~444 |
| flat dir list, all depths | 6186 | ~1767 |
| every file (Claude Code-ish) | 21629 | ~6180 |

Indenting matters a lot here: the monorepo repeats `pikuri-X/lib/pikuri/X/`
fifteen times, and a tree collapses the shared prefix (flat depth-≤2 list is
1215 chars vs 1139 for the tree, but the gap widens fast with depth).

The depth-2 tree is genuinely legible — you learn instantly that this is a
15-gem monorepo with a uniform `bin/ lib/ prompts/ spec/` shape:

```
bin/  (4)
book/  (16)
ideas/  (17)
pikuri-code/  (4)
  bin/  (1)
  lib/  (1)
  prompts/  (2)
  spec/  (1)
pikuri-core/  (3)
  bin/  (1)
  ...
CHANGELOG.md
CLAUDE.md
...
```

**~325 tokens is cheap** for killing the single most common opening tool call.

**Do NOT reuse Glob's 50 KB cap here.** A boot injection is paid on *every*
turn, forever; 50 KB would admit ~14k tokens of paths, which is Grok's item 7
made worse by the fix for item 1. On this repo the cap wouldn't even bite —
the full file list is 21.6 KB — so it would silently authorise a ~6.2k-token
per-turn tax. Cap D at a couple of KB and let *depth* do the trimming. 50 KB
stays `file_list`'s per-call ceiling, where a one-off cost is fine.

Unlike `file_list`, D may keep the `rg --files` prefix derivation: gitignore
correctness matters more for a snapshot, and the three blind spots are
tolerable when the tool can always answer the follow-up.

Open questions:

- Does it go stale mid-session (agent creates files)? Re-inject, or accept drift?
- Where does it wire — system prompt at boot (`bin/`-level), an Extension, or
  `Control::Interloper` with `kind: :system`? The Interloper is already exactly
  *"reference text landing as `add_message(:system)`"*, and it's also the
  cheapest answer to staleness: re-inject mid-session instead of choosing
  between a stale snapshot and none.
- Does it belong in `pikuri-workspace` (owns the workspace) or the binaries
  (own the prompt)?

## Open questions

None left. This is ready to implement.

(Settled last: `[4 dirs, 25 files]` over `[4 folders, …]` and over a terser
`(4d, 25f)` — the terse form is inferable from context, but we're already
spending a row per entry, so the few extra tokens buy unambiguity.)

## Graduation

- decision + the rejected roads (`glob`-overload, `bash ls`, documented
  `read`-lists-dirs, the `file_*` rename sweep) → `DECISIONS.md`
- the naming rule the inventory revealed — *prefix marks a family sharing one
  backing resource; a universal singleton verb goes bare* — is currently
  unwritten. It's an invariant new tools need, so it belongs in `CLAUDE.md`'s
  Conventions (one line, pointing at nothing).
- the tool itself + its rationale → yardoc on `Workspace::FileList`
- `FILE_MINER`'s new toolset → `SECURITY.md:132` row + the trifecta map
- if D ships: a line in the relevant seam/convention in `CLAUDE.md`
- `CHANGELOG.md` one-liner
