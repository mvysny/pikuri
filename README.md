# pikuri

[![status](https://ci.codeberg.org/api/badges/17229/status.svg)](https://ci.codeberg.org/repos/17229)

<img src="assets/kuri.svg" alt="Kuri, pikuri's mascot — a pika" align="right" width="150">

> *"Once men turned their thinking over to machines in the hope that
> this would set them free. But that only permitted other men with
> machines to enslave them."*
> — Frank Herbert, *Dune* (1965)

A small Ruby AI assistant you run on your own machine, shipped as
a family of gems in a monorepo; you install the ones you wire.
Defaults wire a local
[llama.cpp](https://github.com/ggml-org/llama.cpp) server, so a
conversation never leaves your computer unless the model itself
decides to call a network tool. The smallest demo binary is
`pikuri-chat` from [`pikuri-core`](pikuri-core/README.md); the rest
of the family adds filesystem tools, sub-agents, web search,
local-corpus vector search and your Thunderbird mail à la carte.
The power tools (a shell, a coding agent, MCP, skills) live in
[pikuri-workshop](https://github.com/mvysny/pikuri-workshop).

That's **Kuri** on the right — a pika, which is a real animal: a
palm-sized relative of the rabbit that lives in alpine rockslides,
spends the summer stacking cut grass into a pile under a rock, spends
the winter eating it, and never leaves its own mountain. He gathers
what he needs, keeps it where he can see it, and shouts at anything
that comes close. It seemed about right.

## Install

```sh
git clone https://codeberg.org/mvysny/pikuri.git
cd pikuri

# Ruby 3.x + Bundler (Ubuntu/Debian — adapt for your distro)
sudo apt install ruby ruby-bundler
bundle install
```

From the vector-DB chapter onward, the guide also runs local
infrastructure (the vector store) in Podman or Docker. Podman runs
**rootless** out of the box and pikuri prefers it when installed;
Docker must be set up rootless, not via the `docker` group, which is
passwordless root. The
one-time setup lives in
[book/prerequisites.md](book/prerequisites.md).

Pikuri itself is now installed in dev mode. To actually have a
conversation you also need a model running. The shortest route —
install `llama.cpp` and start `llama-server` with the default model,
Ornith-1.5, — is the first thing the guide walks through:

→ **[book/chat.md](book/chat.md)** — your first
conversation, from a fresh checkout to a working assistant.

## Where to go next

You only read the code you run: `pikuri-core` plus the gems you
wire is small enough to read end-to-end in an evening. Two ways
in:

- **Read the guide** at [`book/`](book/). It's a short
  book — the [first-conversation chapter](book/chat.md) starts a
  chat agent, the [sub-agents chapter](book/subagents.md)
  introduces delegation (`pikuri-minions`), and the
  [security chapter](book/security.md) says why none of it can
  leak your data. Reading order
  matters: each chapter assumes the previous one's vocabulary,
  and [`book/README.md`](book/README.md) is the running order.
- **Or jump straight to whichever gem you want to use.** Each
  per-gem README is a reference card with a wired-up snippet:
  - [`pikuri-core`](pikuri-core/README.md) — `Pikuri::Agent`, the
    `Tool` framework, the `pikuri-chat` demo.
  - [`pikuri-pdf`](pikuri-pdf/README.md) — PDF → text extraction,
    in-process and lazily paged (pure-Ruby pdf-reader); the
    docker-free alternative to pikuri-workshop's pikuri-extractors.
  - [`pikuri-html`](pikuri-html/README.md) — HTML → Markdown
    extraction, for web pages and HTML mail attachments alike.
  - [`pikuri-web`](pikuri-web/README.md) — the tools that reach the
    internet: `web_search` (DuckDuckGo, Brave, Exa), `web_scrape`,
    `fetch` and `web_read_cached`.
  - [`pikuri-workspace`](pikuri-workspace/README.md) — filesystem
    tools + `Workspace` / `Confirmer` seams.
  - [`pikuri-subagents`](pikuri-subagents/README.md) — the `agent`
    tool + `Persona` record + the `pikuri-minions` fan-out demo.
  - [`pikuri-vectordb`](pikuri-vectordb/README.md) — topical
    retrieval over a local corpus, the vector-search primitive:
    `vectordb_search` / `vectordb_read` / `vectordb_reindex` and the
    `pikuri-corpus` demo (a no-egress recall agent).
  - [`pikuri-rag`](pikuri-rag/README.md) — hybrid retrieval on that
    primitive: a keyword index beside the vectors, so `rag_search`
    also finds an invoice number and `rag_search_keywords` lists *every*
    matching document. Demo: `pikuri-briefing`, which briefs you on
    a customer from your own notes.
  - [`pikuri-fileindex`](pikuri-fileindex/README.md) — search your
    files through the index the desktop already keeps (GNOME's
    localsearch, or recoll): `fileindex_search` / `fileindex_read`,
    PDFs and office documents included, with no index of our own.
  - [`pikuri-thunderbird`](pikuri-thunderbird/README.md) — the
    local Thunderbird profile as read-only mail/calendar
    tools plus two human-gated hand-offs. No network, no
    autonomous send.
  - The power tools, which run code you didn't write and so need a
    cage (`pikuri-code`, `pikuri-os`, `pikuri-lsp`, `pikuri-mcp`,
    `pikuri-skills`, `pikuri-tasks`, `pikuri-memory`,
    `pikuri-extractors`), live in
    [pikuri-workshop](https://github.com/mvysny/pikuri-workshop).

There is deliberately no `gem install pikuri` that brings in everything:
every gem you add is a tool the model can call, so add only the ones
the job needs.

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
actually works. See [`design/decisions.md`](design/decisions.md) for the
design rationale and the roads not taken;
[`design/research.md`](design/research.md) places pikuri next to
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
pointing pikuri at anything sensitive.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for how to run the test
suite and how releases work.
