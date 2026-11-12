# Book 1 rework: one track that ends on the secretary

Status: **shape agreed, not started.** The workshop split (2026-11-12) took the chapters about
running code you didn't write to book 2; book 1 now ends on [the secretary](secretary.md), and
several chapters still lean on what moved out.

## Approach

**The secretary first, the book after.** The chapters quote real output: the trifecta
chapter's worked examples are the secretary's boot verdicts, the security chapter's concrete
case is search-never-fetch, and the climax chapter wants real transcripts. Writing them before
the binary exists means writing them twice. Running it on real mail and a real `~/Documents`
also changes the design (gate fatigue, what the model does with snippets only).

**Then write backwards from the climax:**

1. the secretary chapter, since it decides what earlier chapters must set up;
2. `trifecta-detector.md`, rebuilt on the secretary;
3. `security.md`, rewritten;
4. the two new chapters, designing a tool and touching files;
5. a sweep of the rest.

**Not a rewrite of the whole book.** `chat`, `subagents`, `vectordb`, `rag` and `hosting` are
sound and need repointing, not rewriting. The real writing is three new chapters and two rebuilt
ones.

**A demo per chapter, not one example grown across the book.** Each demo isolates one concept
and one trifecta shape, and the climax needs `pikuri-briefing`'s one-legged agent as its
contrast. (`Q_running_example` if this is ever reopened.)

## The running order

The assistant/code split collapses into one track. Tentative order: setup, chat, **designing a
tool** (new), **touching files** (new), sub-agents, vectordb, rag, security, measuring the
trifecta, hosting, **the secretary** (new), then the coda ("go run Puri").

`Q_climax_position`: where the secretary chapter sits relative to hosting. It may read best
right after measuring the trifecta, since that's the chapter it pays off, with hosting moved
after it or into the coda's neighbourhood.

## New chapters

- **Designing a tool, on `calculator`** (replaces `tasks.md`, which went to book 2). Demo:
  `pikuri-chat`, which already wires it; `chat.md` already introduces it. The lessons are in its
  decision entries: the tool speaks a grammar the model already knows ("be a superset of Python,
  never a subset", `D_calculator_functions`), watching transcripts settles a design (the model
  wrote `math.cos` unprompted, reversing operators-only), why have the tool at all when "the
  model can't add" and "bash exists" are properties of someone else's harness
  (`D_keep_calculator`), descriptions and errors written for the model, and declaring trifecta
  legs on a tool that holds none. What went to book 2 with `tasks.md` is the stateful-tool half:
  id-addressed changes, status in the verb's name, per-agent state.
- **Touching files: the workspace and the confirmer.** `os-assistant.md` and `code.md` used to
  introduce `Workspace`, the file tools and `Confirmer`, and both left. Book 1 still leans on
  them: sub-agents confirm their task prompts, the secretary confirms every write and search, and
  the security chapter's "does the human see the bytes" test is about confirmers. It goes before
  sub-agents, since their task prompt and `FILE_MINER` use it. `Q_files_demo`: which demo? An
  agent rooted in a folder with read, write and edit, every write confirmed. Lean: a
  `--workspace DIR` flag on `pikuri-chat`, not a new binary.
- **The secretary.** Owned by [`secretary.md`](secretary.md). Carries the lessons that used to
  live elsewhere: durable memory as a user-owned confirmed file (and why automatic capture needs
  no egress), stored prompt injection as an integrity attack, and the large private pool the
  severity lesson needed.

## Chapters to rebuild

- **`trifecta-detector.md`** (17 mentions of `pikuri-code` / Bubblewrap / MCP / mem0 / skills).
  Its worked examples ran `pikuri-code`'s boot verdicts; rebuild them on the secretary, which fits
  the chapter better (three legs present, each graded weak), with `pikuri-briefing`'s one-legged
  agent as the contrast.
- **`security.md`** (29 mentions). It cites `code.md` and Bubblewrap throughout and MCP eighteen
  times, and its strongest case for "cuts built into the structure beat filters" was the kernel
  namespace. The replacement is search-never-fetch; MCP shrinks to "the instant trifecta", with a
  forward link to book 2.

## The sweep

- **The default model becomes Ornith-1.5**, `ornith-ai/Ornith-1.5-35B-A3B-GGUF:Q4_K_M`
  (agreed 2026-11-12, see [`secretary.md`](secretary.md)), replacing
  `unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M` in `chat.md`'s download step and its MoE explanation,
  every `bin/`'s fallback, `pikuri-core/README.md`, and wherever `hosting.md`, `vectordb.md`
  and `design/decisions.md` cite it — checking each cite is a default, not a measurement taken
  on Qwen, which stays as history.
- `chat.md`, `subagents.md`, `prerequisites.md`, `rag.md`, `vectordb.md` mention memories, mem0,
  skills, MCP or `pikuri-extractors`; repoint them at the secretary chapter or book 2.
- `chat.md` may gain one paragraph from book 2's `wire.md`: the messages array is not the prompt
  (template flattening), with a forward link.
- `prerequisites.md`: Docker now earns its keep only at the vectordb chapter (Qdrant); check the
  chapter still says so honestly.
- **The coda, `apps.md`:** Puri first, as "the secretary with all the bells and whistles", then
  pikuri-tui and pikuri-web.
- **`book/README.md`:** drop the "being reshaped" paragraph once this lands; the running order
  above becomes the ToC.
