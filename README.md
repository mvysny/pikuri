# pikuri

[![status](https://ci.codeberg.org/api/badges/17229/status.svg)](https://ci.codeberg.org/repos/17229)

> *"Once men turned their thinking over to machines in the hope that
> this would set them free. But that only permitted other men with
> machines to enslave them."*
> — Frank Herbert, *Dune* (1965)

A small Ruby AI assistant you run on your own machine, shipped as
a family of thirteen gems in a monorepo (twelve functional gems plus
a convenience metagem). Defaults wire a local
[llama.cpp](https://github.com/ggml-org/llama.cpp) server, so a
conversation never leaves your computer unless the model itself
decides to call a network tool. The smallest demo binary is
`pikuri-chat` from [`pikuri-core`](pikuri-core/README.md); the rest
of the family adds skills, task tracking, MCP, filesystem tools, a
full in-repo coding agent, and local-corpus vector search à la
carte.

**Use the machine. Own it, and understand it — so no one with a
machine owns you.**

## Install

```sh
git clone https://codeberg.org/mvysny/pikuri.git
cd pikuri

# Ruby 3.x + Bundler (Ubuntu/Debian — adapt for your distro)
sudo apt install ruby ruby-bundler
bundle install
```

Chapters 3+ of the guide also run local infrastructure (vector
store, memory store, MCP servers) in Docker — set up **rootless**,
not via the `docker` group, which is passwordless root. The
one-time setup lives in
[docs/guide/00-prerequisites.md](docs/guide/00-prerequisites.md).

Pikuri itself is now installed in dev mode. To actually have a
conversation you also need a model running. The shortest route —
install `llama.cpp` and start `llama-server` with the default Qwen
model — is the first thing the guide walks through:

→ **[docs/guide/01-chat.md](docs/guide/01-chat.md)** — your first
conversation, from a fresh checkout to a working assistant.

## Where to go next

Pikuri is small enough to read end-to-end in an evening. Two ways
in:

- **Read the guide** at [`docs/guide/`](docs/guide/). It's a short
  book — chapter 01 starts a chat agent, chapter 02 introduces
  sub-agents (`pikuri-minions`), chapter 03 walks the in-repo
  coding agent (`pikuri-code`) and its security posture. Reading
  order matters: each chapter assumes the previous one's
  vocabulary.
- **Or jump straight to whichever gem you want to use.** Each
  per-gem README is a reference card with a wired-up snippet:
  - [`pikuri-core`](pikuri-core/README.md) — `Pikuri::Agent`, the
    `Tool` framework, four bundled tools, the `pikuri-chat` demo.
  - [`pikuri-extractors`](pikuri-extractors/README.md) — documents
    (DOCX / ODT / XLSX / PPTX / EPUB / RTF / PDF) → Markdown,
    converted inside a one-shot networkless docker container.
  - [`pikuri-pdf`](pikuri-pdf/README.md) — PDF → text extraction,
    in-process and lazily paged (pure-Ruby pdf-reader); the
    docker-free alternative to pikuri-extractors' PDF arm.
  - [`pikuri-skills`](pikuri-skills/README.md) —
    [Agent Skills](https://agentskills.io/specification)
    discovery.
  - [`pikuri-tasks`](pikuri-tasks/README.md) — in-memory task list
    + the four `task_*` tools (create / in-progress / completed /
    delete).
  - [`pikuri-workspace`](pikuri-workspace/README.md) — filesystem
    tools + `Workspace` / `Confirmer` seams.
  - [`pikuri-code`](pikuri-code/README.md) — `Bash` + the in-repo
    coding-agent binary. **Read the security notes before pointing
    it at anything sensitive.**
  - [`pikuri-mcp`](pikuri-mcp/README.md) — [Model Context
    Protocol](https://modelcontextprotocol.io) support.
  - [`pikuri-subagents`](pikuri-subagents/README.md) — the `agent`
    tool + `Persona` record + the `pikuri-minions` fan-out demo.
  - [`pikuri-vectordb`](pikuri-vectordb/README.md) — local-corpus
    vector search + agentic RAG: `vectordb_search` /
    `vectordb_read` / `vectordb_reindex`, the `LIBRARIAN` persona,
    and the `pikuri-corpus` demo (a no-egress recall agent).
  - [`pikuri-memory`](pikuri-memory/README.md) — name-reservation
    placeholder for an upcoming durable "memories" extension; no
    library code yet.
  - [`pikuri-assistant`](pikuri-assistant/README.md) — MCP-aware
    demo binary.
  - [`pikuri`](pikuri/README.md) — convenience metagem:
    `gem install pikuri` pulls in all twelve.

For browsable API docs, run `bundle exec yard` inside any gem
directory (output is gitignored) — or, once gems are published,
see <https://rubydoc.info/gems/pikuri-core> and its siblings.

## Why this exists

The existing self-hosted agent stacks have grown big and hit a
steep learning curve — a privacy-conscious user arriving fresh
hits a wall of JSON configuration before the first conversation.
Pikuri is the counter-move: privacy-first defaults (no cloud
account, no API key, no telemetry), sane defaults so the first
conversation needs no config file, and a deliberately small
codebase that doubles as a tour of how a small agent runtime
actually works. See [`CLAUDE.md`](CLAUDE.md) for the design
rationale; [`COMPARISON.md`](COMPARISON.md) places pikuri next to
opencode and pi.

## Curious how the agentic loop actually works?

Pikuri sits on top of [ruby_llm](https://rubyllm.com), which owns
the Thought → Tool-call → Observation loop. If you want to *learn*
how that loop works internally — minimal code, no extension
surface, nothing to wade through — read
[agentic-loop-demo](https://codeberg.org/mvysny/agentic-loop-demo).
Same author, written precisely so the source is the lesson.
Pikuri is the production-shaped sibling: same loop, plus tools,
listeners, sub-agents, and ergonomics.

## Security

The threat model in one page — code-trust baseline (what runs
where, and in which sandbox), then three worked prompt-injection
attacks broken by capability boundaries, plus explicit non-goals
— lives in [`SECURITY.md`](SECURITY.md). Read it once before
pointing `pikuri-code` (or any future write-capable variant) at
anything sensitive.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for how to run the test
suite and how releases work.
