# Book 1 rework: one track that ends on the secretary

Status: **the secretary chapter is written** (`book/secretary.md`, 2026-11-13); the rest of the
book is audited (2026-11-13, below) and not yet reworked. The workshop split (2026-11-12) took
the chapters about running code you didn't write to book 2; book 1 now ends on
[the secretary](secretary.md), and several chapters still lean on what moved out.

**To pick up:** the next unchecked step of *The order of work*.

## Approach

**The secretary first, the book after.** The chapters quote real output, so the climax decides
what earlier chapters must set up, and writing them before the binary existed would have meant
writing them twice.

**Not a rewrite of the whole book.** `chat`, `subagents`, `vectordb`, `rag` and `hosting` are
sound and need repointing, not rewriting. The real writing is two new chapters and two rebuilt
ones.

**A demo per chapter, not one example grown across the book.** Each demo isolates one concept
and one trifecta shape. (`Q_running_example` if this is ever reopened.)

**Transcripts come from demo data** (agreed 2026-11-13), never a real mailbox or folder. A
scene runs on the testbed only: `dev/thunderbird-testbed/build`, then `session start
--display`, and the binary with `DISPLAY` set to the session's.

## The running order

One track: setup, chat, **designing a tool** (new), **touching files** (new), sub-agents,
vectordb, rag, security, measuring the trifecta, **the secretary**, hosting, then the coda
("go run Puri").

**The secretary follows measuring the trifecta directly** (agreed 2026-11-13): it is a diff
against the `briefing --with-mail` the reader just ran there. Hosting depends only on
sub-agents, so it moves after the climax; its concrete case, pikuri-web, leads into the coda.
The secretary stays the book's last binary.

## The order of work

Audited 2026-11-13 by counting each chapter's mentions of book-2 material (`pikuri-code`,
`pikuri-os`, Bubblewrap, MCP, mem0, skills, extractors, the OS-assistant and coding-agent
chapters). Some are legitimate links to book 2.

| Chapter | Mentions | Work |
|---|---|---|
| `security.md` | 39 | rewrite |
| `trifecta-detector.md` | 15 | finish the rebuild |
| `prerequisites.md` | 9 | lead with podman |
| `subagents.md` | 8 | repoint |
| `chat.md`, `vectordb.md`, `apps.md` | 6 each | repoint; Ornith; coda leads with Puri |
| `rag.md`, `hosting.md` | 1 each | sound |

1. ~~The secretary chapter.~~ Written 2026-11-13.
2. ~~**`trifecta-detector.md`, the rest of its rebuild.**~~ Done 2026-11-13: no book-2 wiring
   is its example any more. The map tour reads `pikuri-thunderbird` and `pikuri-minions`; the
   loud advisory is rendered from the real tools of `pikuri-chat` beside a private notes
   folder, and drops to soft when `fetch` and `web_scrape` go; the briefing flag stays its
   worked example. Book 2 is still named where it is the honest example (a shell tool behind
   a confirmer, a coding agent loud by design).
3. **`security.md`, rewritten.** It cites `code.md` and Bubblewrap throughout and MCP eighteen
   times, its strongest case for "cuts built into the structure beat filters" was the kernel
   namespace, and it says the book's one loud shape is a coding agent. The replacement case is
   search-never-fetch; MCP shrinks to "the instant trifecta", with a link to book 2.
4. **The two new chapters**, below.
5. **The sweep**, below.

## New chapters

- **Designing a tool, on `calculator`** (replaces `tasks.md`, which went to book 2). Demo:
  `pikuri-chat`, which already wires it; `chat.md` already introduces it. The lessons are in its
  decision entries: the tool speaks a grammar the model already knows ("be a superset of Python,
  never a subset", `D_calculator_functions`), watching transcripts settles a design (the model
  wrote `math.cos` unprompted, reversing operators-only), why have the tool at all when "the
  model can't add" and "bash exists" are properties of someone else's harness
  (`D_keep_calculator`), descriptions and errors written for the model, and declaring trifecta
  legs on a tool that holds none. The naming story (`rag_find` → `rag_search_keywords`, the
  per-word miss count) belongs here too. What went to book 2 with `tasks.md` is the
  stateful-tool half: id-addressed changes, status in the verb's name, per-agent state.
- **Touching files: the workspace and the confirmer.** `os-assistant.md` and `code.md` used to
  introduce `Workspace`, the file tools and `Confirmer`, and both left. Book 1 still leans on
  them: sub-agents confirm their task prompts, the secretary confirms every write and search, and
  the security chapter's "does the human see the bytes" test is about confirmers. It goes before
  sub-agents, since their task prompt and `FILE_MINER` use it. `Q_files_demo`: which demo? An
  agent rooted in a folder with read, write and edit, every write confirmed. Lean: a
  `--workspace DIR` flag on `pikuri-chat`, not a new binary.

## The sweep

- ~~**The default model becomes Ornith-1.5**~~ Done 2026-11-13 (bins, `pikuri-core/README.md`,
  `chat.md`, `vectordb.md`); `hosting.md`'s thinking passage and `design/decisions.md` keep Qwen3.6,
  where it is a measurement.
- `chat.md`, `subagents.md`, `prerequisites.md`, `rag.md`, `vectordb.md` mention memories, mem0,
  skills, MCP or `pikuri-extractors`; repoint them at the secretary chapter or book 2.
- `chat.md` may gain one paragraph from book 2's `wire.md`: the messages array is not the prompt
  (template flattening), with a forward link.
- `prerequisites.md`: Docker now earns its keep only at the vectordb chapter (Qdrant); check the
  chapter still says so honestly. And pikuri now prefers Podman when it's installed (rootless and
  daemonless out of the box), so the chapter leads with `apt install podman` and keeps rootless
  Docker as the alternative; the secretary needs one of them, since its index lives in Qdrant.
- **The coda, `apps.md`:** Puri first, as "the secretary with all the bells and whistles", then
  pikuri-tui and pikuri-web.
- **`book/README.md`:** drop the "being reshaped" paragraph once this lands; the running order
  above becomes the ToC.
