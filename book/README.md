# The pikuri guide

A short, sequential book on pikuri. Each chapter builds on the
vocabulary the previous one established, so reading order matters
— don't jump into the MCP chapter without the first two.

**This page is the running order.** Chapters are named, not
numbered: the files are `security.md`, `code.md`, and so on, and
the sequence lives here and nowhere else. So a chapter can be
added or moved without renaming files or rewriting every
cross-reference — chapters refer to each other by name ("the
security chapter"), which stays true whatever position they end
up in.

If you want the reference instead of the narrative, every public
class and module is documented with YARD headers in the sources.
Run `bundle exec yard` inside any gem directory for a browsable
local site, or — once gems are published — see
<https://rubydoc.info/gems/pikuri-core> and its siblings.

## How the guide is shaped

A setup chapter, then the base vocabulary in two chapters. The
**assistant track** (broader audience, privacy-conscious user)
covers recall, memory, and MCP, is capped by the security chapter,
and then pays off concretely in the OS assistant — the first
*complete, fully-implemented* assistant in the book, a full-disk
OS helper made safe by a severed network, then a second part that
carefully reattaches it through a quarantined researcher. The
**code track** (narrower audience, developer-flavoured) opens by
taking those very seams and making the *opposite* cut, then
revisits security and MCP at the sharper edges. Tasks and skills
close out as smaller chapters across both tracks, and the last
chapter is a coda — the universal assistant that combines every
gem, landing once they stabilise.

## Chapters

### Setup

- **[Prerequisites](prerequisites.md).** One-time machine
  setup: Ruby + the checkout, and Docker — what a container is
  in sixty seconds, and why **rootless**: the usual `docker`
  group shortcut is passwordless root. Safe to skim past until
  the vector-DB chapter, which is where Docker first earns its
  keep.

### Base vocabulary

- **[Your first conversation](chat.md).** Install
  `llama.cpp`, start the server, run `pikuri-chat`. Establishes
  the base vocabulary: `Pikuri::Agent`, `Pikuri::Tool`,
  listeners, the Thought → Tool-call → Observation loop. The
  four bundled tools and the privacy posture of each search
  provider.
- **[Sub-agents](subagents.md).** One new concept on top of
  the last chapter: delegation. The `Persona` record, the
  `SubAgent::Extension`, the configure/bind dance. Demo via
  `pikuri-minions` — fan out three research questions in
  parallel, get one synthesised answer back. This is also
  where pikuri's main privilege-separation story starts.

### Assistant track

- **[Agentic search and the vector DB](vectordb.md).** One
  new feature on top of sub-agents: semantic recall over a local
  corpus. The chunker / tokenizer / embedder / backend /
  reranker pipeline, in-memory vs Qdrant backends, and why the
  demo agent has no internet access — treat the corpus as
  private, give the reader an agent that can't leak it. Demo via
  `pikuri-corpus` against the pikuri guide itself. (The
  privilege-separated `LIBRARIAN` persona, for an agent that
  *does* have egress, is deferred to the universal-assistant
  chapter.)
- **[Memories](memories.md).** Durable facts the agent keeps
  across conversations, paired with the vector DB for
  recall. The three retrieval tiers (resident persona / automatic
  prefetch / `recall` tool), the mem0 + Qdrant sidecar, why the
  extraction model must be non-reasoning, and why automatic
  capture is only safe on a no-egress agent. Demo via
  `pikuri-memory`. This is where the privacy posture starts to
  *matter*.
- **[Your first MCP server](mcp.md).** The gentle MCP intro:
  one low-stakes server (a public book-catalogue reader, no
  credentials, nothing private wired in), your first taste of
  (rootless) Docker as the boundary, the registry/servers split,
  the verifier and synthesizer that are `pikuri-mcp`'s distinctive
  contributions. Demo via `pikuri-openlibrary`. The sharper MCP
  shapes — credentials, untrusted code, the full container threat
  model — wait for the MCP-revisited chapter.
- **[Security: picking a defense for your harness](security.md).**
  The synthesis chapter. Why there's no NX flag for tokens,
  the lethal trifecta, the defense kit, a decision procedure
  for your own harness, the five worked attacks, and how
  pikuri's structural bet compares to Claude Code's
  operational one. No new binary — read it before pointing any
  write- or network-capable agent at something sensitive. This
  is where every "the security chapter explains why" reassurance
  pays off.
- **[The OS assistant: your machine](os-assistant.md).**
  The first complete assistant in the book — and the gentle
  introduction of the file/shell/sandbox/confirmer seams through
  a concept every reader owns: operating their own machine. In two
  parts. **Part 1:** full read-write over the disk, but the network
  severed *by the kernel* (`FullFsNoNet`) — the trifecta's egress
  leg cut structurally, the security chapter made concrete. Confirmed
  mutations, a read-only auto-confirmer, spotlight-style content
  search over the GNOME index, and a `MACHINE.md` resident memory.
  **Part 2 — the third leg returns:** carefully reattaching the
  network (`--with-internet`) by quarantining all web tools in a
  privilege-separated `RESEARCHER` sub-agent with no filesystem,
  reached through a confirmed task prompt — so no single context
  holds all three trifecta legs. **Part 3 — a second app:** composes
  local Thunderbird mail + calendar onto that agent (`pikuri-computer`)
  to sharpen the trifecta itself — a leg's **presence** is binary
  (all three live = assembled) while **severity** grades on the
  size of the private pool beside it and on how strong each leg
  is — which is also why "the secret is too big to hide" is never
  a defense (a 256-bit key is one paragraph of acrostic). Demo via
  `pikuri-os` / `pikuri-computer`.

### Code track

- **[The in-repo coding agent](code.md).** The same three
  seams from the OS assistant — `Workspace`, `Confirmer`, `Sandbox` —
  now in a developer's hands and grown up: where that chapter
  severed the network and kept the disk, the coding agent keeps
  the network (builds need it) and confines the disk instead
  (`Bubblewrap` + a project-rooted workspace). Same adversary,
  opposite trifecta leg. Plus read-only recon via `FILE_MINER` /
  `GIT_REPO_RESEARCHER` and the git-config hardening the OS
  assistant deferred. The mechanics; the threat model moves to the
  next chapter as its closing pair.
- **[Security revisited: the coding-agent shape](security-revisited.md).**
  What `pikuri-code`'s defaults actually protect and where they
  stop, plus wrapping the whole pikuri process in Docker for
  when the in-process defenses aren't enough.
- **[Measuring the trifecta](trifecta-detector.md).** Closes the
  security arc across both tracks: the map every binary has been
  printing at boot since the first chapter, finally explained.
  Capability presence versus data flow and why it only ever warns,
  who declares each leg, the two strength lattices behind
  loud/soft/silent, the structural test for whether a human gate
  counts (**does the human see the bytes, or a proxy for them?**),
  how legs propagate across a delegation, and how to tag a tool you
  write yourself. Worked example: one binary, three verdicts, two
  declarations.
- **[MCPs revisited: containerised servers](mcp-revisited.md).**
  The harder MCP shapes: the official GitHub MCP in Docker as
  the worked example, plus npx- and pip-based community MCPs,
  Playwright with its open-web surface, and the full threat
  model for `pikuri-mcp`.

### Shorter chapters, across both tracks

- **[Task tracking](tasks.md).** A short chapter near the
  end. What `pikuri-tasks` is, why an agent benefits from
  externalized working memory, and the three design choices
  that shape its four tools — status-in-verb-name,
  id-addressed mutations, JSON-array mass-create (two of the
  three reversed by watching real transcripts).
- **[Agent Skills (stub)](skills.md).** What skills are in one
  paragraph, a minimal `lol` demo, the three ways a bundle gets
  invoked (model-decides, you-decide, and model-decides-once-the-
  project-proves-relevant), why a skill needs a trigger where an
  MCP server doesn't, and how to write a description that fires.
  Still a stub for the part that needs the reader's own itch.
- **[The messages array is not the prompt](wire.md).** The
  debugging chapter, and the one to remember when an agent seems
  to be ignoring you. A local model's chat template — arbitrary
  Jinja shipped inside the GGUF — is what flattens your messages
  into the single string the model reads, and it may silently drop
  some: Qwen3.6 discards every mid-conversation `system` message,
  which disabled pikuri's memory prefetch and skill promotions
  with no error at any layer. Why no assertion you can write will
  catch it, the two taps that show you what you *sent* versus what
  the model *read*, why a fallback path is an alibi, and why the
  fix is a uniform `<system-reminder>`-wrapped user turn rather
  than a per-model branch. Demo via `pikuri-wire-check`.

### Coda

- **[pikuri-assistant (stub)](assistant.md).** The book's
  coda: the universal privacy-conscious assistant — vector-DB
  recall, persistent memories, MCP, and the four bundled tools
  in one binary, the one agent that reaches for all three
  trifecta legs. Stub until the gems it integrates stabilise and
  the quarantined corpus wiring lands.

Further chapters — a deeper `pikuri-assistant` walkthrough and more
advanced coding-agent recipes — will land as those surfaces stabilise.
