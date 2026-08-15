# A real directory listing

Origin: Grok 4.6's review of `pikuri-tui-code` (`feedback.txt`, item 1) —
*"`glob *` gave me ten root files and no tree. I used `bash ls` to see `lib/`,
`spec/`, `bin/`, `ideas/`. Orientation is the first thing I do in a repo, and
glob-as-find is the wrong primitive for it."*

## Landed 2026-08-15

`Pikuri::Workspace::Listing` (the `Dir.children` renderer), and `read` on a
directory now refuses *with* the depth-1 listing instead of pointing at `glob`.
`Search::Utils.child_listing` is gone — the oversized-root refusal renders
through `Listing` — and `head_truncate` moved to `Search::Utils` now that three
callers share it.

Rationale graduated to {Pikuri::Workspace::Listing}'s yardoc and
`DECISIONS.md` `D-directory-listing` (which owns the four rejected roads:
overloading `glob`, `bash ls`, a *documented* `read`-lists-directories, and the
`rg --files` prefix derivation). Don't re-argue them here.

What remains below is the part that hasn't shipped.

## Still open: the `file_list` tool

New **`Pikuri::Workspace::FileList`** — top level alongside Read/Write/Edit,
*not* under `Workspace::Search::` where Grep/Glob live. Listing a folder is
essentially a read of it, not a search; it borrows `Search::Utils` but that's
reuse, not membership.

- Params: `path` (default workspace root), `depth` (**default 1**, cap 3 —
  both already `Listing::DEFAULT_DEPTH` / `MAX_DEPTH`). The default is
  load-bearing on the name — see *Naming*.
- Body is `Listing.render`; the tool owns only param validation, the
  `resolve_for_read` call, and the refusals.
- Reuse `Utils.oversized_root_refusal` and Glob's trifecta legs verbatim
  (filenames, no new leg — same reasoning as `glob.rb:108`).
- Refuse a regular `path` the way Glob does (`glob.rb:148` points at `read`).
- Takes the `Workspace::Workspace` composite like its siblings (it doesn't mark
  the read ledger, but consistency settles it).
- **Add to `FILE_MINER`** (`file_miner.rb:33` → `%w[read grep glob file_list]`),
  and update the `SECURITY.md:132` row. Safe: `file_list` adds *no* trifecta leg
  beyond what the persona already carries, and the injection defense is about
  having no tool to *act* on an injected instruction — listing grants no action.
  It's also the persona that needs orientation most.
- Say nothing about directory listing in `read`'s description. That's what
  dissolves the duality: the model is only ever *taught* one way to list, so it
  never faces a two-tools-no-criterion coin flip, and the `read` path stays a
  rescue for a call already made. (Shipped that way; the point is to keep it
  that way when the tool lands.)

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

## Still open: docs sweep — drop the count from "five file tools"

`"five file tools"` is load-bearing in 15 live places (re-grepped 2026-08-15):
`CLAUDE.md:27`, the Workspace seam at `CLAUDE.md:97`,
`pikuri-workspace/lib/pikuri-workspace.rb:8`, `extension.rb:5`,
`workspace.rb:25`, `DESIGN.md:44`, `trifecta_legs_spec.rb:5`, a spec *name*
(`extension_spec.rb:35`, `it 'registers all five file tools'`),
`pikuri-code/bin/pikuri-code:411`,
`pikuri-code/spec/pikuri/code/dry_run_spec.rb:35`, `pikuri-os/bin/pikuri-os:174`,
`pikuri-os/bin/pikuri-computer:167`, `pikuri-os/pikuri-os.gemspec:52`,
`book/os-assistant.md:409`, `book/trifecta-detector.md:48` ("wires five file
tools"), plus `CHANGELOG.md` (historical, leave alone). Re-grep before the
sweep rather than trusting this list.

Collapse to **"file tools"** — no counting, can't go stale. This is a pure
docs/naming cleanup with no dependency on the tool, so it can land as its own
commit and stop being a blocker.

## Still open: Option D — boot-time orientation, on top

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

**Do NOT reuse `Listing::MAX_BYTES` here.** A boot injection is paid on *every*
turn, forever; 50 KB would admit ~14k tokens of paths, which is Grok's item 7
made worse by the fix for item 1. On this repo the cap wouldn't even bite —
the full file list is 21.6 KB — so it would silently authorise a ~6.2k-token
per-turn tax. Cap D at a couple of KB and let *depth* do the trimming. 50 KB
stays the per-call ceiling, where a one-off cost is fine.

Unlike `Listing`, D may keep the `rg --files` prefix derivation: gitignore
correctness matters more for a snapshot, and the three blind spots
(symlinked / gitignored-only / empty directories vanish) are tolerable when
the tool can always answer the follow-up.

**Gotcha if D does go the rg route:** sort path-segment-wise, not lexically.
`-` (0x2D) sorts before `/` (0x2F), so `pikuri/lib` lands *after*
`pikuri-workspace/spec` and renders under the wrong parent. (`Listing` is
immune — it sorts per-directory.)

### Wiring — settled 2026-08-15

D is a **`Workspace::Extension` system-prompt snippet, living in
`pikuri-workspace`**, and it is allowed to go stale.

- **Accept drift, and say so in the snippet.** Label the tree a boot snapshot
  and add one line: a file or folder you can't find here may simply be newer
  than the snapshot — call `file_list` for the current state. Cheaper than any
  refresh mechanism, and drift is *already* bounded without one —
  `Agent#assemble_system_prompt` (`agent.rb:490`) re-pulls every extension's
  snippets on `clear_conversation`, so the snapshot re-takes itself on `/clear`.
- **Extension, not `Control::Interloper`.** `system_prompt_snippets` is exactly
  this hook and already carries dynamic content (`Skill::Extension`,
  `Mcp::Extension`). The Interloper is also the *more* expensive answer to
  staleness, not the cheaper one guessed above: a snippet is a stable prefix,
  while a re-injected `kind: :system` item appends a message every time —
  growing history and busting the prompt cache.
- **`pikuri-workspace`, riding the existing `Workspace::Extension`.** The
  listing needs the workspace to know its root, and is useless without the
  read/grep/glob/edit/write tools the same extension wires. Cost is a constant
  plus a line in `#system_prompt_snippets` — no new wiring point.
  - It's also the only home where the staleness line may *name* `file_list`. A
    `prompts/<bin>.txt` version couldn't — CLAUDE.md's "No tool names in a
    main/binary system prompt" tripwire would hit it. That rule's target is
    prompt-vs-wiring drift, and a snippet contributed by the extension that
    *registers* the tool structurally can't drift: the `Tasks::Extension` /
    `SubAgentTool.available_agents_snippet` precedent.

Three consequences, none of them blockers:

1. **It can't be unconditional — flag it, default off.** `pikuri-os` and
   `pikuri-computer` both wire
   `Filesystem::AllowAll.new(project_root: Dir.pwd, …)`
   (`pikuri-os/bin/pikuri-os:98`, `pikuri-os/bin/pikuri-computer:98`), so a
   launch from `$HOME` walks a home directory. Head-truncating that to the
   couple-of-KB cap buys two KB of noise, not orientation — so **over budget,
   drop a depth level, then omit entirely; never truncate mid-tree.** A
   constructor flag on `Workspace::Extension` (default off, on in
   `pikuri-code`) leaves the call with the host that knows its root is a repo.
   Per-binary asymmetry is already established: `bin/pikuri-code:287` appends
   `"Project root: …"` and the others don't.
2. **`FILE_MINER` never sees D.** `SubAgentTool` selects tool *instances* from
   the parent by name and wires no extensions (`sub_agent_tool.rb:34,149`), so
   no snippet reaches a sub-agent. That dents the depth-1 argument under
   *Naming*: "D solves orientation at boot, so the tool's remaining job is the
   targeted follow-up" holds for the main agent and fails for the one persona
   this note calls the neediest orienteer. Fix in
   `prompts/persona-file-miner.txt` — persona prompts are the sanctioned
   carve-out that may name their tools, so tell the miner to open with a
   `file_list` at depth 2. Depth 1 survives as the *default*; the miner just
   passes an argument.
3. **Two walkers in one gem, deliberately.** D keeps the `rg --files` prefix
   derivation while `Listing` uses `Dir.children`, and once D lands in
   pikuri-workspace the two sit side by side — against this note's own "one
   listing formatter, not two". It stands, because the budgets differ: a boot
   snapshot that renders `node_modules/` has spent its whole allowance on
   nothing, so gitignore correctness outranks the three blind spots there,
   while a tool answering *"what is actually in this directory?"* can't afford
   them. One formatter, two walkers — record the reason in
   `D-directory-listing` so a later reader doesn't read it as drift.

## Open questions

None. Both remaining pieces are ready to implement.

## Graduation

- the naming rule the inventory revealed — *prefix marks a family sharing one
  backing resource; a universal singleton verb goes bare* — is currently
  unwritten. It's an invariant new tools need, so it belongs in `CLAUDE.md`'s
  Conventions (one line, pointing at nothing).
- the tool itself + its rationale → yardoc on `Workspace::FileList`; the
  choice + rejected roads → the existing `D-directory-listing` entry
- `FILE_MINER`'s new toolset → `SECURITY.md:132` row + the trifecta map
- if D ships: a line in the relevant seam/convention in `CLAUDE.md`; the
  boot-snapshot flag + the omit-don't-truncate rule → yardoc on
  `Workspace::Extension`; the miner's opening `file_list` →
  `prompts/persona-file-miner.txt`; *two walkers, one formatter* →
  `D-directory-listing`
- `CHANGELOG.md` one-liner
