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
3. **Not a flag flip.** `rg --files` can't emit directories at all, so this
   means abandoning rg for `Dir.glob` (loses gitignore) or deriving dirs from
   path prefixes. Real surgery.

And a `depth:` parameter on `glob` is a non-starter: depth is *already*
expressible in the pattern (`*` = 1, `*/*` = 2, `**/*` = any). A second,
contradictable way to say the same thing — `pattern: "**/*", depth: 1` has no
defensible answer.

## What other harnesses do

- **opencode** puts it in `read`, not glob — `COMPARISON.md:252` quotes its
  description verbatim: *"Read a file **or directory** from the local
  filesystem."*
- **Claude Code** ships no listing tool at all today; it shells out to `ls`.
  (It historically had an `LS` tool, since dropped.)

So the convergent position is "**not in glob**" — but it is *not* "everyone
ships a `list` tool". Worth knowing before claiming parity either way.

## Proposal: a `list` tool (+ `read` self-heals)

New `Pikuri::Workspace::Search::List`, sibling of Grep/Glob:

- `path` (default workspace root), `depth` (default 1, cap ~3),
  `include_gitignored` mirroring glob's.
- Directories first with a trailing `/` and a child count, then files with
  size. `Utils.child_listing` already renders exactly this shape — it's just
  unreachable except from the oversized-root refusal.
- Reuse `Utils.oversized_root_refusal` and Glob's trifecta legs verbatim
  (filenames, no new leg — same reasoning as `glob.rb:108`).
- Make `Utils.child_listing` delegate to the new renderer so there's one
  listing formatter, not two.
- Replace `read.rb:164`'s false advice with the self-healing refusal below.

**Implementation trick:** don't reimplement gitignore. Run the existing
`rg --files`, group paths by prefix at depth N. Directories, per-directory
counts and gitignore correctness fall out of one call. Cost: an empty or
fully-ignored directory vanishes — arguably correct for orientation.

**Gotcha found while prototyping:** sort path-segment-wise, not lexically.
`-` (0x2D) sorts before `/` (0x2F), so `pikuri/lib` lands *after*
`pikuri-workspace/spec` and renders under the wrong parent.

### `read` on a directory — settled: error recovery, not a documented feature

Agreed 2026-08-15. `read` on a directory returns the depth-1 listing
(delegating to `list`'s renderer) behind an `Error:` prefix — exactly the
`Utils.oversized_root_refusal` move, which already refuses *and* hands back the
useful thing rather than dead-ending. Critically: **say nothing about it in
`read`'s description.**

That's what dissolves the duality with `list`: the model is only ever *taught*
one way to list, so it never faces a two-tools-no-criterion coin flip. The
`read` path exists solely to rescue a call that was already made.

- One *documented* way to list (`list`), so no coin-flip for the model.
- The accidental `read lib/` self-heals with no extra round-trip.
- Zero schema / description cost — which matters, because Grok's item 7 is that
  the standing prompt is already heavy.
- Keeps `read`'s semantics honest: it must not touch the read-before-edit
  ledger for a directory (the `:164` branch returns before `mark_read`, so this
  is free today — don't break it).

The road not taken (carry into the `D-` entry): letting `read` list
directories as a *documented* capability, opencode-style. Rejected because
`read` would then have two behaviours keyed on path type — structurally the
same objection we used against overloading `glob`. It's weaker here ("read" is
a generic verb, "glob" names a mechanism), which is why the undocumented
recovery path survives while the documented one doesn't.

Constraint to preserve: `read` must not touch the read-before-edit ledger for a
directory. Free today — the `:164` branch returns before `mark_read` — but the
kind of thing a refactor silently breaks, so it wants a spec.

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
Open questions: does it go stale mid-session (agent creates files)? Re-inject
or accept drift? Is it an Extension, or `bin/`-level wiring? Does it belong in
`pikuri-workspace` (owns the workspace) or the binaries (own the prompt)?

## Open questions

- Output format of `list`: sizes in bytes or `4.2K`? mtime column, or is that
  glob's job and we keep them disjoint?
- Does `list` sort by name (orientation) or mtime (consistency with glob)?
  Name, probably — hierarchy is the axis here, which is the whole argument
  against putting this in glob.
- Sixth workspace tool = per-turn schema tokens, against Grok's item 7. Does D
  alone get us most of the way, making `list` optional? (Leaning no — D is a
  snapshot, `list` answers "what's in *this* dir I just found".)
- Does `list` earn a spot in `FILE_MINER`'s toolset?

## Graduation

- decision + the rejected `glob`-overload and `read`-only roads → `DECISIONS.md`
- the tool itself + its rationale → yardoc on `Search::List`
- if D ships: a line in the relevant seam/convention in `CLAUDE.md`
- `CHANGELOG.md` one-liner
