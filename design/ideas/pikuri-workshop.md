# pikuri-workshop: split the functionality gems into a second project

Status: **direction and cut agreed. The eight gems moved to
[pikuri-workshop](https://github.com/mvysny/pikuri-workshop) on 2026-11-12**, ahead of
the order below (`pikuri-workshop:D_separate_repo`). What remains is book 1's side, now in
two ideas of its own: [`secretary.md`](secretary.md) (the climax demo) and
[`book-rework.md`](book-rework.md) (the chapters). This file keeps the split's rationale and
the non-book leftovers.

## The problem

The gem count only grows. Every integration adds a gem, a module-map line,
a lockstep release target, a book chapter, and a share of AGENTS.md's
34 KB. `D_read_what_you_run` already promises you read only what you run,
so the reader's cost isn't the issue. The maintainer's cost is, and so is
the book, which now gets a chapter per integration.

Worse, one repo pulls every gem two ways: stay simple enough to teach, and
grow complete enough to handle the corner cases and the features. Bash's
tokenizer and sandbox, language servers and MCP's container model are
inherently complex and can't do both. Split, each project keeps one promise:
book 1 stays readable in an evening, and book 2 is free to be as complex as
the real world makes it, explaining the hard parts rather than every line.

Book 1 still has three big gems: core (~8,900 lines), `pikuri-vectordb` and
`pikuri-thunderbird` (~3,800 each). They stay because they pass both tests
below, not because they're simple. If one starts growing features, the first
test sends it to book 2.

## The proposal

Two projects:

- **pikuri** (vanilla), book 1: the universal concepts an agent is built
  from, each explained in the book, with a demo that teaches it. Learning is
  the guiding principle: a gem is here to be understood, and it stays small
  on purpose. Its theme: **privacy and security, so you can run it on your
  host OS.** Safe because of what's *missing*: no shell, no stranger's code,
  writes confined to one folder, egress only to an engine the code picks.
  You can point it at your real mail on your real machine, because the
  dangerous combinations don't exist. "The trifecta is broken by
  construction", made into a book.
- **pikuri-workshop**, book 2: **power, which needs a cage.** Safe because of
  what *surrounds* it: bash, MCP servers, skills' scripts, the coding agent and
  language servers (which often evaluate the project's build files) all run
  code you didn't write, and nothing can be left out to make that safe. The
  cage is usually a VM (for an agent with a shell, a shared kernel is a thin
  wall), sometimes a container, and for the OS assistant, whose whole point is
  your host, a network the kernel has cut. It's a separate repo, a
  continuation the reader can pick up if they want to.

### The rule that places a gem

Two tests; failing either sends a gem to the workshop:

1. **Does the gem's future say "explain it better" or "more features"?**
   This is the learning principle, and it comes first: book 1 grows by
   teaching a concept better, never by gaining features. Features go to the workshop
   even when they're host-safe. This is what places mem0 and the Docker
   office extractors. `design/ideas/` already answers it: `coding-agent.md`,
   `claude-parity.md` and `bash-confirmer.md`
   all ask for features.
2. **Would you run it on your host, with your real data, as-is?** If it
   needs a cage, it's book 2, however well it teaches. This is what places
   bash, MCP, skills, LSP, the coding agent and os, and what keeps
   `pikuri-thunderbird` in book 1: the CLI Puri reads your mail on the host
   and that's fine.

`thunderbird*.md` also asks for features. Thunderbird stays because book 1's
climax needs it, but each of its feature ideas faces the "explain it better"
bar before it lands, and a feature that fails it is the moment to reconsider
the placement.

Two hard constraints come with the rule:

- **Dependencies point from the workshop to vanilla, never back.** No vanilla
  `lib/`, `bin/`, spec or book chapter may require a workshop gem.
- **Book 1 runs only vanilla.** A chapter whose demo needs a workshop gem
  belongs in book 2.

## The cut

| Vanilla (book 1) | pikuri-workshop (book 2) |
|---|---|
| `pikuri-core` | `pikuri-code`: the coding agent with `Bash`, the sandbox (`NONE`, `Bubblewrap`, `FullFsNoNet`), `PassiveCommandDetector`, the tokenizer, git hardening, plan mode, `git_clone`, `GIT_REPO_RESEARCHER`, `ToolchainPaths`, the coding prompt, `bin/pikuri-code` |
| `pikuri-subagents` | `pikuri-lsp` |
| `pikuri-web` | `pikuri-os`, plus the `pikuri-computer` demo |
| `pikuri-workspace` (gains the generic memory file) | `pikuri-extractors` (Docker office conversion) |
| `pikuri-vectordb`, `pikuri-rag` | `pikuri-skills` (skills and slash commands) |
| `pikuri-pdf` | `pikuri-memory` (mem0) |
| **`pikuri-thunderbird`** (the climax needs it) | `pikuri-mcp`, plus `bin/pikuri-openlibrary` |
| | `pikuri-tasks` |

Vanilla goes from 16 gems to 8; the workshop has 8. No `pikuri-bash` split: bash
stays inside `pikuri-code` and goes to the workshop with it.

The `pikuri` metagem is already gone (step 0, `D_no_metagem`), and the workshop gets
none either.

Notes on the individual placements:

- **bash goes, with the sandbox.** It's the tool that writes anywhere, so it
  drags in the passive-command detector and the confirms; the climax decided
  against it for the same reason. Book 1 loses the kernel-namespace cut and
  the "opposite cuts on one seam" lesson (`FullFsNoNet` vs Bubblewrap), and
  gains search-never-fetch as its structural cut, one you can see in a
  tool's shape instead of in kernel machinery. Book 2 opens with the
  sandbox, where the coding agent needs it.
- **workspace stays, and can't go.** `pikuri-subagents` depends on it (the
  `agent` tool's confirmed task prompt goes through its `Confirmer`, and it
  builds a `Workspace` per child), `pikuri-vectordb` depends on
  `pikuri-subagents`, and the climax needs `Confirmer` for searches,
  calendar creates and memory diffs. Dropping note writes from the climax
  would save nothing gem-wise.
- **thunderbird stays.** At 3,780 lines it's the biggest vanilla gem after
  core and vectordb. Its threat model (read-only inbound, outbound handed to
  a human) is the book's best concrete case of a human gate that counts.
- **skills go.** Siri has no skills, and the climax doesn't wire them. A
  skill earns its keep by shipping scripts, and running a script needs the
  shell, which is in the workshop. Without one, a skill is only instructions loaded on
  demand, and a note in `~/Documents` that the climax's rag finds covers
  most of that. What a note doesn't give is the catalog: the model knows
  what exists without searching. Path-activated skills (promoted when a
  matching file is touched) are coding material outright. The only binary
  that wires slash commands is `bin/pikuri-code`. Nothing in vanilla's
  `lib/` requires `pikuri-skills`; subagents, vectordb and mcp mention it
  only in comments.
- **MCP goes: it's an instant trifecta.** An MCP server is a stranger's
  code. Its tool output is untrusted, it usually holds a credential or
  private data, and its process can reach the network without the agent
  seeing it, so pikuri can't truthfully declare its tools' legs and has to
  assume the worst. The gem's distinctive defense, the verifier, is an LLM
  scanning tool descriptions for injection: a filter, which book 1's thesis
  says loses to adversarial text. The climax doesn't wire MCP. Book 1's
  `security.md` names MCP as the instant trifecta and links forward. Nothing
  in vanilla's `lib/` requires `pikuri-mcp`. Docker still earns its keep in
  book 1, at the vectordb chapter (Qdrant).
- **tasks goes; its tool-design lesson stays, rebuilt on the calculator.**
  Only `bin/pikuri-code` wires `pikuri-tasks`, and a task list earns its keep
  on long multi-step work, mostly coding; the secretary answering "what's on
  Thursday?" doesn't need one. That's the skills argument again, and the
  "stay small" principle settles it. Book 1 keeps a tool-design chapter built
  on `calculator` instead (see `book-rework.md`). What moves with `tasks.md`
  is the stateful-tool half: id-addressed changes, status in the verb's
  name, per-agent state.
- **memory goes; the concept stays.** mem0 is an integration: a sidecar, a
  Qdrant collection, a non-reasoning extraction model. Its future is
  features. Book 1 teaches durable memory through the climax's memory file,
  the shape the climax picks *over* mem0, and the "automatic capture needs
  no egress" lesson moves into the climax chapter. Nothing in vanilla's
  `lib/` requires `pikuri-memory`. Lost from book 1: the automatic prefetch
  tier, and `wire.md`'s lead example (Qwen dropping the mid-conversation
  `system` message that carried recalled memory). So `wire.md` moves too (see `book-rework.md`).
- **pdf stays, extractors goes.** `pikuri-pdf` (139 lines, pure Ruby) is the
  cheap PDF option the vectordb, rag and climax demos need. Docker-based
  office conversion is a feature. The `Extractor` registry itself stays in
  core.
- **os goes.** It's an app built from domain tools (Recoll, the GNOME file
  index, `system_info`, `MACHINE.md`), not a concept, and it needs
  `pikuri-code`'s sandbox. Its generic memory file moves to vanilla first
  (see above).

Gems to watch in book 1, by the first test: `pikuri-web` (search engines
tend to pile up) and `pikuri-workspace` (`ProjectRoot` and the
`.gitignore`-aware listing lean towards coding; if they grow, they move into
`pikuri-code`).

## Left over from the move

- **Promises.** Book 1's theme is *Privacy first* plus the trifecta promise, with
  *Readable in an evening* as the learning principle's promise; the owner rewords them.
- **`D_keep_calculator`** argues against `bash` beside the calculator; check it still reads
  right with no `bash` in pikuri.
- **`more-confirmers.md`** stays, since confirmers are pikuri's seam and the secretary's
  search confirmer grows out of it, but its examples are the OS assistant's; rebase them on
  the secretary.
- **Yardoc that names workshop symbols** (about 30, across core, workspace, subagents and
  vectordb: `{Pikuri::Code::Bash}`, `{Pikuri::Tasks::Extension}`, `{Pikuri::Mcp::Servers}`…)
  now dangles on rubydoc.info; each wants a rewrite that names the seam, not the consumer.

## Order of work (sketch)

0. ~~Drop the metagem.~~ Done.
1. Book 1's side: [`secretary.md`](secretary.md) first, then [`book-rework.md`](book-rework.md).
2. ~~Create the pikuri-workshop repo and move the eight gems, with their docs,
   `D_` entries, ideas and chapters.~~ Done, out of order.
3. ~~Rewrite `book/README.md`, AGENTS.md, SECURITY.md~~ (a first pass landed with the
   move).
