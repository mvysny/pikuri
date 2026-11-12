# pikuri-ext: split the functionality gems into a second project

Status: **direction agreed, cut being worked out.** Nothing moved yet.

## The problem

The gem count only grows. Every integration adds a gem, a module-map line,
a lockstep release target, a book chapter, and a share of AGENTS.md's
34 KB. `D_read_what_you_run` already promises you read only what you run,
so the reader's cost isn't the issue. The maintainer's cost is, and so is
the book, which now gets a chapter per integration.

## The proposal

Two projects:

- **pikuri** (vanilla): the universal concepts an agent is built from,
  each explained in book 1, with a demo that teaches it. It stays small
  on purpose.
- **pikuri-ext**: the gems that deliver functionality on top. It's a
  separate repo and is "book 2", a continuation the reader can pick up if
  they want to.

### The rule that places a gem

**Does the gem's future say "explain it better" or "more features"?**
The first stays in vanilla, the second goes to ext. `design/ideas/` already
answers this: `thunderbird*.md`, `coding-agent.md`, `claude-parity.md`,
`bash-confirmer.md` and `grok-build-cheap-borrows.md` all ask for features.

Two hard constraints come with the rule:

- **Dependencies point from ext to vanilla, never back.** No vanilla
  `lib/`, `bin/`, spec or book chapter may require an ext gem.
- **Book 1 runs only vanilla.** A chapter whose demo needs an ext gem
  belongs in book 2.

## The cut

| Vanilla (book 1) | pikuri-ext (book 2) |
|---|---|
| `pikuri-core` | `pikuri-code`: the *coding* agent (plan mode, `git_clone`, `GIT_REPO_RESEARCHER`, `ToolchainPaths`, the coding prompt, `bin/pikuri-code`) |
| `pikuri-subagents` | `pikuri-lsp` |
| `pikuri-web` | `pikuri-os`, plus the `pikuri-computer` demo |
| `pikuri-mcp` | `pikuri-thunderbird` |
| `pikuri-skills` | `pikuri-extractors` (Docker office conversion) |
| `pikuri-tasks` | |
| `pikuri-workspace` | |
| **`pikuri-bash`** (new, split out of `pikuri-code`) | |
| `pikuri-vectordb`, `pikuri-rag`, `pikuri-memory` | |
| `pikuri-pdf` | |

Vanilla goes from 16 gems to 12 (counting `pikuri-bash`); ext has 5.

The `pikuri` metagem is already gone (step 0, `D_no_metagem`), and ext gets
none either.

Notes on the individual placements:

- **tasks stays.** It's small (~630 lines), nothing depends on it, and
  every serious agent keeps a task list. Its chapter is a pure tool-design
  lesson (status in the verb's name, id-addressed changes, two of three
  choices reversed by watching transcripts), which is what book 1 is for.
- **memory stays, though mem0 is an integration.** Durable memory is a
  basic concept, and its chapter teaches why automatic capture is only safe
  on an agent with no egress.
- **pdf stays, extractors goes.** `pikuri-pdf` (139 lines, pure Ruby) is the
  cheap PDF option the vectordb and rag demos need. Docker-based office
  conversion is a feature. The `Extractor` registry itself stays in core.
- **os goes.** Now that the assistant is dropped, os is a lone leaf. It's
  an app built from domain tools (Recoll, the GNOME file index,
  `system_info`, `MACHINE.md`), not a concept. Its one lesson that *is* a
  concept, the network severed by the kernel, moves to the bash chapter
  (see below).

## `pikuri-bash`: why vanilla and not ext

What would move: `Code::Bash`, `Bash::Sandbox` (`NONE`, `Bubblewrap`,
`FullFsNoNet`), `Bash::PassiveCommandDetector`, `Bash::Tokenizer`, and the
git hardening. That's about 1,850 lines. It depends only on core and
`pikuri-workspace` (`Confirmer`, `Filesystem`).

Arguments for vanilla:

1. **Bash is the tool models are trained on.** They reach for it even when
   `write` is wired (heredoc into a file). An agent without it fights its
   training, and a book without it doesn't teach the agents people
   actually run.
2. **"The sandbox is brutally hard to get right" argues for teaching it,
   not hiding it.** The security chapter's claim (cuts built into the
   structure beat filters) has its strongest concrete case here: a kernel
   namespace, not a command filter. `PassiveCommandDetector` is the
   counterexample in the same gem. It only decides what may skip the
   confirmer, never what is safe, and the reason it can't be a defense is
   itself a lesson. The hard part is exactly where a reader shouldn't be
   left alone.
3. **Book 1 needs a workhorse binary, and that binary needs bash.**
   `pikuri-code` is currently that workhorse across chapters that stay in
   book 1: `skills.md` uses it as the skill host, `tasks.md` names it as
   the default wiring, `mcp-revisited.md` wires the GitHub MCP into
   `bin/pikuri-code`, and `trifecta-detector.md` does its worked example on
   `pikuri-code`'s boot verdicts (13 mentions). If bash went to ext, all
   four chapters would lose their host.
4. **The gem passes "name a gem after what it refuses to become".**
   pikuri-bash refuses to become a coding agent: a shell and its cage, with
   a threat model you can close.

The case for ext, taken seriously: 1,850 lines of sandbox and tokenizer is
more than an evening's read, and a reader can't verify Bubblewrap's
correctness alone. The answer is that the promise is per-deployment: a
vanilla wiring without bash never reads it. If that answer stops holding,
bash moves to ext and book 1 teaches with file tools only.

### The workhorse binary

The coding agent minus what's coding-specific is the classic harness: an
agent rooted in a directory with the file tools, bash in Bubblewrap,
sub-agents, MCP, skills, tasks and web. That becomes vanilla's
general-purpose demo and replaces `pikuri-code` in the four chapters above.
The ext `pikuri-code` becomes that harness plus plan mode, `git_clone`,
`GIT_REPO_RESEARCHER`, `ToolchainPaths`, the coding prompt and LSP. It's
built *from* vanilla, which is the lesson book 2 opens with.

- `Q_workhorse_name`: what is it called, and where does it live? Options:
  `pikuri-bash/bin/<name>`, or a root `bin/` demo (AGENTS.md: root
  `bin/pikuri-*` are dev/demo entry points). Candidates: `pikuri-agent`,
  `pikuri-shell`, `pikuri-harness`.
- `Q_private_question`: `bin/pikuri-code` asks at startup whether the
  directory is private, and `trifecta-detector.md` builds on that question.
  Does it move to the workhorse unchanged? It isn't coding-specific.

## Open questions

- `Q_fullfsnonet_home`: once os is in ext, nothing in vanilla wires
  `Sandbox::FullFsNoNet`. Either the bash chapter teaches it (kernel-cut
  network vs Bubblewrap's confined disk, the two opposite cuts on one seam)
  and the workhorse gets a flag for it, or it moves to ext with os. A flag
  added only to keep a class in vanilla is the "knob not needed for the next
  concrete step" that `D_read_what_you_run` forbids. Lean: teach it, because
  the opposite-cut lesson is one of book 1's best security moments.
- `Q_plan_mode`: plan mode goes to ext with the coding agent. Confirm the
  workhorse doesn't want it.
- `Q_severity_lesson`: Part 3 of `os-assistant.md` (`pikuri-computer`) and
  the `pikuri-computer` example in `trifecta-detector.md` teach trifecta
  *severity*: a leg is present or not, but its severity depends on how big
  the private pool is and how strong each leg is. That's a vanilla concept
  with an ext demo. Options: rebuild the example on a vanilla wiring, or let
  `trifecta-detector.md` state severity with a forward link to book 2.
- `Q_repo_wiring`: during development, ext's root `Gemfile` points at a
  sibling checkout (`gemspec path: '../pikuri/pikuri-core'`)? Its CI
  checks out pikuri at a pinned sha? Without backward compatibility, every
  vanilla rename breaks ext until ext catches up, and one commit becomes
  two. That's the price.
- `Q_ext_release`: does ext release lockstep with vanilla (one version
  number, `~>` pins), or independently? `D_release_one_otp` gets simpler
  either way: 12 pushes instead of 16 (11 vanilla gems that exist today
  plus `pikuri-bash`, and no metagem).
- `Q_tripwires`: the five seam checks (`tasks/tripwires.rake`) guard
  invariants that ext code also has to honour (subprocess, loop seam…).
  Does ext copy the rake file, or does vanilla ship it so ext can load it?
  The closed-set-of-five rule (`D_tripwire_bar`) still applies.
- `Q_book2_shape`: book 2's running order. Probably the coding agent
  (built from the workhorse), then security revisited for coding agents,
  then language intelligence, then the OS assistant, then local mail and
  calendar (severity). Book 1's coda (`apps.md`) points at book 2 alongside
  the apps.

## What moves where (the mechanical list)

**Docs that travel to ext:**

- per-gem `AGENTS.md` and `design/architecture.md` for `pikuri-code`,
  `pikuri-lsp`, `pikuri-os`, `pikuri-thunderbird` and `pikuri-extractors`;
- `D_` entries from `design/decisions.md`, at least: the `D_lsp_*` family
  (7), `D_thunderbird_*` (2), `D_headless_os_agent`, and the LSP half of
  `D_gloda_locks_mcp_does_not` (needs a split);
- ideas: `thunderbird*.md` (3), `coding-agent.md`, `claude-parity.md`,
  `bash-confirmer.md` (or does it stay with `pikuri-bash`?),
  `grok-build-cheap-borrows.md`;
- book chapters: `code.md`, `lsp.md`, `os-assistant.md`, and most of
  `security-revisited.md`.

**Docs that stay but need edits:**

- `D_keep_calculator` and `D_command_inlining_legs` mention bash. They stay,
  since bash stays.
- `R_permissions` and the grok-build sandbox deep-dive in
  `design/research.md` stay. They're prior art for `pikuri-bash`.
- Book chapters to repoint at the workhorse: `security.md` (cites
  `code.md` ×6 and Bubblewrap ×6), `trifecta-detector.md`,
  `mcp-revisited.md`, `skills.md`, `tasks.md`, `chat.md`, `subagents.md`,
  `mcp.md`, `prerequisites.md`; `vectordb.md` drops or forward-links
  `pikuri-extractors`.
- `book/README.md`: the assistant track loses its OS-assistant payoff and
  the code track loses its first two chapters. Book 1 probably flattens
  into: setup, base vocabulary, retrieval (vectordb, rag, memories), MCP,
  security, **the shell and its cage** (new; harvests `code.md`,
  `os-assistant.md` Part 1 and the sandbox half of `security-revisited.md`),
  measuring the trifecta, MCPs revisited, then the shorter chapters,
  hosting, and the coda.
- AGENTS.md: the module map, the "Name a gem after what it refuses to
  become" line (add: "a gem whose future is more features goes to
  pikuri-ext"), and Promises → *Readable in an evening*.
- `SECURITY.md`: drop the sections about ext gems, or link to them.
- `CHANGELOG.md`: one line per move.

## Order of work (sketch)

0. ~~Drop the metagem.~~ Done.
1. Split `pikuri-bash` out of `pikuri-code` inside this repo. It's a pure
   refactor and stays green under `rake check`.
2. Build the workhorse binary, then repoint the four book chapters and
   `trifecta-detector.md` at it.
3. Write the bash chapter.
4. Create the pikuri-ext repo and move the five gems with `git mv` history
   (`git filter-repo` per path, or just a plain copy, since git is for
   syncing code, not curating history). Move their docs, `D_` entries and
   ideas with them.
5. Rewrite `book/README.md`, AGENTS.md, SECURITY.md and the coda's pointer.
