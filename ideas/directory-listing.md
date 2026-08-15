# Boot-time orientation (Option D)

The last unshipped piece of the directory-listing work. Origin: Grok 4.6's
review of `pikuri-tui-code` (`feedback.txt`, item 1) — *"`glob *` gave me ten
root files and no tree. Orientation is the first thing I do in a repo."*

Already shipped, and graduated out of this note: `Workspace::Listing`, `read`'s
recovering refusal, and the `file_list` tool (plus the tool-naming convention →
`CLAUDE.md` Conventions, and the "five file tools" → "file tools" sweep). The
choice and every rejected road live in `DECISIONS.md` `D-directory-listing`;
don't re-argue them here.

## The idea

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
stays `file_list`'s per-call ceiling, where a one-off cost is fine.

Unlike `Listing`, D may keep the `rg --files` prefix derivation: gitignore
correctness matters more for a snapshot, and the three blind spots
(symlinked / gitignored-only / empty directories vanish) are tolerable when
`file_list` can always answer the follow-up.

**Gotcha if D does go the rg route:** sort path-segment-wise, not lexically.
`-` (0x2D) sorts before `/` (0x2F), so `pikuri/lib` lands *after*
`pikuri-workspace/spec` and renders under the wrong parent. (`Listing` is
immune — it sorts per-directory.)

## Wiring — settled 2026-08-15

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
  file tools the same extension wires. Cost is a constant plus a line in
  `#system_prompt_snippets` — no new wiring point.
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
   no snippet reaches a sub-agent. Already mitigated ahead of D:
   `prompts/persona-file-miner.txt` and `persona-git-repo-researcher.txt` tell
   both recon personas to open with a `file_list` at `depth: 2`. Re-check that
   wording still reads right once D ships for the main agent.
3. **Two walkers in one gem, deliberately.** D keeps the `rg --files` prefix
   derivation while `Listing` uses `Dir.children`, and once D lands in
   pikuri-workspace the two sit side by side — against the "one listing
   formatter, not two" rule this work started from. It stands, because the
   budgets differ: a boot snapshot that renders `node_modules/` has spent its
   whole allowance on nothing, so gitignore correctness outranks the three
   blind spots there, while a tool answering *"what is actually in this
   directory?"* can't afford them. One formatter, two walkers — record the
   reason in `D-directory-listing` so a later reader doesn't read it as drift.

## Open questions

None. Ready to implement.

## Graduation

- the boot-snapshot flag + the omit-don't-truncate rule → yardoc on
  `Workspace::Extension`
- a line in the relevant seam/convention in `CLAUDE.md`
- *two walkers, one formatter* → the existing `D-directory-listing` entry
- `CHANGELOG.md` one-liner

Once D ships, this note is fully graduated — delete it.
