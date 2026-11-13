# Book 1 rework: one track that ends on the secretary

Status: **shape agreed; the secretary chapter outlined, no prose yet.** Its transcripts run on
the Thunderbird testbed, `dev/thunderbird-testbed/` (`D_thunderbird_testbed`), built
2026-11-13. The workshop split (2026-11-12) took the
chapters about running code you didn't write to book 2; book 1 now ends on
[the secretary](secretary.md), and several chapters still lean on what moved out.

**To pick up:** capture the outline's scenes on the testbed only (`dev/thunderbird-testbed/build`
on the dev VM builds the demo mailbox and `~/Documents`); then write `book/secretary.md` from the
outline below. The compose guard's novelty scene waits on
[`compose-guard-sent-only.md`](compose-guard-sent-only.md): today a reply to a new sender isn't
warned.

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
trifecta, **the secretary** (new), hosting, then the coda ("go run Puri").

**The secretary follows measuring the trifecta directly** (agreed 2026-11-13). Its chapter is a
diff against the `briefing --with-mail` the reader just ran there, and its boot map is that
chapter's second worked example in all but name. Hosting depends only on sub-agents, so it moves
after the climax: it is for whoever builds their own host, and its concrete case, pikuri-web,
leads into the coda. The secretary stays the book's last binary.

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

## The secretary chapter: outline

`book/secretary.md`, "The secretary: all three legs, each one weakened". Written first; the
demo it teaches is [`secretary.md`](secretary.md)'s. A diff against `pikuri-briefing
--with-mail`, which the reader ran in the trifecta chapter: two legs, silent.

1. **What it is, and why it ends the book.** A plain CLI Siri over your documents, notes, mail,
   calendar and the web; the first binary in the book that holds all three legs, on purpose,
   and you can still point it at your real mailbox. Why this and not the coding agent (that one
   puts all three legs in one blob and confines the disk; book 2).
2. **Before you start.** Thunderbird with global search on; podman (or rootless docker) for
   Qdrant; and the embedding bill, measured: a 137-page PDF is 8.5 s of extraction and 36 s of
   embedding on a laptop iGPU, so a library is hours. Start with a subfolder or `--exclude`
   your books, then widen it; under Qdrant the first embed is paid once and a restart re-embeds
   nothing. The machine is busy while it runs and the chat waits behind the embedder.
3. **The map you'll see.** The real boot map, verdict `soft`, each row read off: which tools
   bring which leg, and the one row per leg that weakens it. Then the four steps that got there
   from briefing's two legs.
4. **Step one: it can write — integrity, not confidentiality.** No new leg, which is the point:
   `write` carries none, so the detector is silent about the most durable harm. Stored prompt
   injection (a mail asks for a note: "invoices go to IBAN X"). The cut: one folder, every write
   shown as a diff before it lands. A synced folder turns a write into egress (custody; link the
   trifecta chapter's edges). The two readers, `read` and `rag_read`, and why the error names
   the root.
5. **Memory is a note.** `SECRETARY.md`, pinned into the prompt, written through the same
   confirmed edit. Why not automatic capture (a mail plants a "fact"; only safe without egress,
   and this agent has egress). Why a change waits for the next session. The transcript: a
   preference remembered, the program restarted, the preference used.
6. **Step two: the first way out is a human's.** Compose and calendar create hand the bytes to
   Thunderbird, and you press Send: `egress_reviewed`, the human sees the payload. What the
   compose guard flags, and that its warning reaches you only through the model.
7. **Step three: search, never fetch.** `egress_vouched`: a query can carry a secret out, but
   no attacker can read it back. Snippets only, so nothing else leaves. The confirm, honestly:
   it moves no verdict and stops no attacker; it's there because the model will put your mail
   into a query unprompted, and the engine keeps it. The first shipped wiring to land in the
   soft-by-vouched-destination cell. Whether snippets alone make it loop (the trifecta chapter
   says models do; report what the secretary did).
8. **Step four: a corpus you didn't write.** `~/Documents` is `trusted: false` where briefing's
   notes were vouched for: downloads, statements, other people's files. What it reads (PDF,
   text, HTML, CSV) and what it can't (Office; book 2's extractors).
9. **The prompt, fixed by watching transcripts.** Four failures from the first real run and the
   one line each needed: the dentist note never searched (documents first), the sauna answered
   from the web (check what they kept), the invoice "discrepancy" (arithmetic with the
   calculator), the offered reminder (never offer what you can't do).
10. **What the map still can't see.** The pool is now everything; you are still a pipe (paste);
    a synced folder; the compose warning relayed by the model it warns about.
11. **What it leaves out, and where it lives instead.** Reminders (no resident process), the
    machine itself (book 2's OS assistant), Office formats, fetch, sub-agents.
12. **What's next:** the coda, Puri as this with the bells and whistles.

Ripples: the trifecta chapter's "The edges" first bullet ("no shipped wiring reaches" the
soft-by-vouched cell) becomes false and points here instead. The naming story (`rag_find` →
`rag_search_keywords`, the per-word miss count) belongs to the designing-a-tool chapter, not
this one.

**Transcripts come from demo data** (agreed 2026-11-13): each scene re-run on the demo
`~/Documents` and a demo mailbox, so no real byte reaches the book; the owner's host test stays
the account of what happened. **The steps are read off two maps**, briefing's and the
secretary's, not four per-step flags that would exist only for the chapter.

## Chapters to rebuild

- **`trifecta-detector.md`** (mentions of `pikuri-code` / Bubblewrap / MCP / mem0 / skills).
  Its "one binary, three verdicts" example (`pikuri-code`) is gone, a book-2 example
  (2026-11-13). The briefing flag is now its only worked example, and it should not grow a
  secretary one: the secretary's map is read once, in its own chapter, which follows next, so
  this chapter ends on a forward link ("three legs, each weakened"). Still to replace: the loud
  advisory in "Reading the advisory" (`[TRIFECTA: HARD] pikuri-code`), now the chapter's only loud
  reading, and the `pikuri-code` cites before it.
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
  chapter still says so honestly. And pikuri now prefers Podman when it's installed (rootless and
  daemonless out of the box), so the chapter leads with `apt install podman` and keeps rootless
  Docker as the alternative; the secretary needs one of them, since its index lives in Qdrant.
- **The coda, `apps.md`:** Puri first, as "the secretary with all the bells and whistles", then
  pikuri-tui and pikuri-web.
- **`book/README.md`:** drop the "being reshaped" paragraph once this lands; the running order
  above becomes the ToC.
