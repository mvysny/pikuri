# The pikuri guide

A short, sequential book on pikuri. Each chapter builds on the
vocabulary the previous one established, so reading order matters
— don't jump into the security chapter without the first two.

**This page is the running order.** Chapters are named, not
numbered: the files are `security.md`, `chat.md`, and so on, and
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

A setup chapter, then the base vocabulary in four chapters (a
conversation, a tool, files, delegation), then recall over your own
documents, then the security arc that says why none of it can leak
them, then the secretary, which holds all three legs of the trifecta
on purpose and shows what keeps that in bounds. Hosting steps outside
the single-agent shape, and the coda points at the apps built on
pikuri.

Each chapter has its own small demo binary rather than one example
grown chapter by chapter: a demo shows one idea and one trifecta
shape, so you can see what each chapter adds and what it costs.

Running code you didn't write — a shell and its sandbox, the OS
assistant, the coding agent, MCP, skills, language servers — is
[book 2, the workshop](https://github.com/mvysny/pikuri-workshop/blob/master/book/README.md).

## Chapters

### Setup

- **[Prerequisites](prerequisites.md).** One-time machine
  setup: Ruby + the checkout, and a container runtime — what a
  container is in sixty seconds, Podman as the short path, and why
  Docker only **rootless**: the usual `docker` group shortcut is
  passwordless root. Safe to skim past until the vector-DB chapter,
  which is where containers first earn their keep.

### Base vocabulary

- **[Your first conversation](chat.md).** Install
  `llama.cpp`, start the server, run `pikuri-chat`. Establishes
  the base vocabulary: `Pikuri::Agent`, `Pikuri::Tool`,
  listeners, the Thought → Tool-call → Observation loop. The
  bundled tools and the privacy posture of each search
  provider.
- **[Designing a tool: the calculator](designing-a-tool.md).**
  Writing a tool, on the smallest one in pikuri. The four fields a
  tool is made of and who reads each; why a calculator earns its
  place where "bash exists" is true of other harnesses but not this
  one; speaking a grammar the model already knows ("be a superset
  of Python, never a subset"); errors and descriptions written for
  the model; naming a tool by what makes it different; the status
  line the tool owns; and declaring trifecta legs on a tool that
  holds none. Every rule traced to the transcript that settled it.
- **[Touching files: the workspace and the confirmer](touching-files.md).**
  Tools that change things on your disk, and the two pieces that keep
  that in bounds: the *workspace*, one folder the file tools can't see
  out of, and the *confirmer*, which shows you every change as a diff
  before it lands. Read before edit, approve / reject / redirect, why a
  diff and not a question, and how much to confirm. Demo via
  `pikuri-files`.
- **[Sub-agents](subagents.md).** One new concept on top of
  the last chapter: delegation. The `Persona` record, the
  `SubAgent::Extension`, the configure/bind dance. Demo via
  `pikuri-minions` — fan out three research questions, get one
  synthesised answer back. This is also where pikuri's main
  privilege-separation story starts.

### Recall

- **[Agentic search and the vector DB](vectordb.md).** One
  new feature on top of sub-agents: semantic recall over a local
  corpus. The chunker / tokenizer / embedder / backend /
  reranker pipeline, in-memory vs Qdrant backends, and why the
  demo agent has no internet access — treat the corpus as
  private, give the reader an agent that can't leak it. Demo via
  `pikuri-corpus` against the pikuri guide itself. (The
  privilege-separated `LIBRARIAN` persona, for an agent that
  *does* have egress, gets a short section of its own.)
- **[Hybrid retrieval: the questions vectors can't answer](rag.md).**
  The two questions pure geometry cannot answer — *completeness*
  ("every note mentioning Acme": top-k is a sample and cosine has no
  calibrated zero) and *exactness* ("invoice #4471": rare tokens are
  what embedders rank worst) — and the field's settled fix, a keyword
  index beside the vectors. BM25, reciprocal rank fusion and why not
  a weighted sum, the backend decorator that reuses the whole
  indexing pipeline, and why "indexed" has to mean *both* stores hold
  it. Also the first chapter that points you at your own real private
  data: demo via `pikuri-briefing`, the **one-legged agent** — private
  data, no untrusted input, no egress — which briefs you on a customer
  from your own notes, and where the interesting choices are which gems
  *not* to wire.

### Security

- **[Security: picking a defense for your harness](security.md).**
  The synthesis chapter. Why there's no NX flag for tokens,
  the lethal trifecta, breaking it with sub-agents, and when a job
  needs all three legs, weakening the one that leaves (search,
  never fetch). The defense kit, a decision procedure for your own
  harness, the five worked attacks, and how
  pikuri's structural bet compares to Claude Code's
  operational one. No new binary — read it before pointing any
  write- or network-capable agent at something sensitive. This
  is where every "the security chapter explains why" reassurance
  pays off.
- **[Measuring the trifecta](trifecta-detector.md).** Closes the
  security arc: the map every binary has been
  printing at boot since the first chapter, finally explained.
  Capability presence versus data flow and why it only ever warns,
  who declares each leg, the two strength lattices behind
  loud/soft/silent, the structural test for whether a human gate
  counts (**does the human see the bytes, or a proxy for them?**),
  how legs propagate across a delegation, and how to tag a tool you
  write yourself. The worked example: one flag that adds a leg
  without moving the verdict — where everything that changed for the
  human sits outside what the detector grades.

### The secretary

- **[The secretary: all three legs, on purpose](secretary.md).** The
  book's last binary, `pikuri-secretary`: a command-line personal
  assistant over your documents, notes, mail, calendar and the web,
  and the first agent here to hold every trifecta leg. Read as a diff
  against briefing with mail: note writes confined to one folder and
  shown as a diff (integrity, and stored prompt injection), memory as
  a note you approve, mail and events handed to Thunderbird for you to
  send, and search that never fetches. Its map reads soft, and the
  chapter says why from the map alone, then what the map still can't
  see.

### Hosting

- **[Hosting many agents at once](hosting.md).** Every binary in
  the book runs one agent at a time; a real host doesn't. What
  changes when N agents share one process, with
  [pikuri-web](https://codeberg.org/mvysny/pikuri-web) as the
  concrete case: concurrent conversations plus the one-off jobs
  that caption and summarize them. The two agent shapes, why
  `Agent` is thread-unsafe on purpose and what the two doors in
  from another thread are, the queueing problem N agents create
  for one llama.cpp and the per-request permit that fixes it
  (with the measurements), why a connection rides the transport
  instead of `RubyLLM.configure`, the tool sharing postures
  finally with a scene behind them, and why a stored conversation
  and a rendered transcript are two artifacts that don't
  reconstruct each other. No demo — the honest version is a few
  hundred lines of plumbing; read pikuri-web instead.

### Coda

- **[Apps built on pikuri](apps.md).** The book's coda. What an
  everyday assistant should look like beyond the secretary's plain
  command line is being worked out by apps, not by this repo:
  [Puri](https://github.com/mvysny/puri), the secretary with all the
  bells and whistles, then
  [pikuri-tui](https://codeberg.org/mvysny/pikuri-tui)'s terminal
  shells and [pikuri-web](https://codeberg.org/mvysny/pikuri-web)'s
  browser chat. A piece that proves itself there moves back into a
  gem.

### Book 2

- **[The workshop](https://github.com/mvysny/pikuri-workshop/blob/master/book/README.md).**
  Power, which needs a cage: the shell and its sandbox, the OS
  assistant, memories, skills, MCP, language intelligence and the
  coding agent. A separate repo that builds on everything here.
