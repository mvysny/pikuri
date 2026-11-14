# Leaner pikuri

Keep in pikuri only what its own bins and vended extensions use; for everything else decide:
**drop**, **keep with a written why**, or **move to pikuri-workshop**.

Method (2026-11-14): a reachability audit per gem. Roots = the 9 bin scripts (`bin/pikuri-secretary`,
`pikuri-chat`, `chat_attachments.rb`, `pikuri-wire-check`, `pikuri-briefing`, `pikuri-minions`,
`pikuri-thunderbird`, `pikuri-corpus`, `pikuri-files`) + every sibling gem's `lib/`. Usage in
pikuri-workshop, pikuri-tui and pikuri-webui recorded separately, never a root. Each feature tagged
ROOT / DOWNSTREAM-ONLY (leaf or seam) / UNUSED / INFRA.

Ground rule agreed: **seams stay** — they are where the workshop grows what pikuri would otherwise
carry — **but every seam needs a solid written justification.** A seam with no consumer anywhere is
just unused code.

Headline: almost nothing downstream-only is a movable leaf; it is hooks in the loop / Filesystem.
The real slimming is unused code (~900 lines) and capability we choose to drop (section D).

## A. Unused — referenced only by own spec, book or docs

- ~~`Q_page_text`~~ **Decided 2026-11-14: keep, and the secretary now uses it** (keyed Brave/Exa →
  `page_text` + `web_read_cached`, else `snippets_only`; `Engines` drops DuckDuckGo from a
  key-derived `page_text` cascade). Graduated into `D_page_text_by_handle` and
  `D_secretary_wiring`. The analysis below can go when this file graduates.
- ~~`Q_tokenizer_seam`~~ **Done 2026-11-14:** dropped `Tokenizer::LlamaServer` and
  `chars_per_token:` (now `CharHeuristic::CHARS_PER_TOKEN`). Kept `FixedWindow`'s `tokenizer:`: six
  specs (vectordb, rag, pdf) pass a one-token-per-word fake through it, and it's where a host plugs
  an exact tokenizer. Documented in `Tokenizer`'s yardoc.
- ~~`Q_librarian`~~ **Done 2026-11-14:** removed, with pikuri-vectordb's pikuri-subagents
  dependency. The book promised a demo it never gave, it couldn't be wired as a boundary
  (`VectorDb::Extension` puts `vectordb_search` on the parent), and the secretary contradicts the
  "corpus + web ⇒ quarantine" argument. Why-not note in `D_corpus_trust_declaration`; the
  per-tool-pool deferral went with it. Stale examples remain in pikuri-workshop's docs
  (`design/decisions.md:610,638`, `design/ideas/tool-list-in-context.md:79`,
  `pikuri-memory/design/architecture.md:461`).
- ~~`Q_core_dead_code`~~ **Done 2026-11-14:** removed `Agent#to_s`, `Agent#model`,
  `Cancellable#to_s`, `Result.error(detail:)`. Kept, correcting the audit:
  - `Parameters`' number/boolean types and `#names` — a complete, simple type family a tool can
    reasonably want (owner's call; speculative but not a knob).
  - `Result#error?`, `Cancellable#cancelled?`, `Agent#system_prompt` — the observation points specs
    in four repos assert through.
  - Listener / `ListenerList#to_s` — pikuri-tui's specs read listener names through them, and
    downstream listeners follow the convention.
  - `InMemoryEventList` — moving it into `Testing` saves no lines and edits specs in five workshop
    gems; tidiness only.
- ~~`Q_dead_knobs`~~ **Done 2026-11-14:** cut `thunderbird_bin:` on Extension / MailCompose /
  CalendarCreate (stays on `Launcher` as its test seam), `Calendar#available?` (doc claimed a role
  it didn't play), `Watcher` `latency:`, Voikko `compounds:` (id string kept, so no rebuild),
  `ProjectRoot` `markers:`. Kept as test seams specs pass: thunderbird `cache_dir:`, the servers'
  `data_dir:`/`port:`/`healthcheck_timeout:`/`#endpoint`, both Extensions' `chunker:`,
  `Workspace::Extension#workspace`, `SubAgent::Extension#personas` (specs in two repos), the
  snapshot/ICS/Engines injection kwargs, `UrlCache::NULL`. Kept as a declaration: Filesystem
  `trusted:` (specs in three repos). Kept `Profile#gloda?` (public probe on a class pikuri-tui
  calls). Deferred: Chroma `tenant:`/`database:` → `Q_chroma`; Filesystem `env:` → the sandbox
  seam row in C. Original list: thunderbird `thunderbird_bin:` (4 ctors), `cache_dir:`;
  `Server::{Qdrant,Chroma}` `data_dir:` / `port:` / `healthcheck_timeout:` + `#endpoint`;
  `Backend::Chroma` `tenant:` / `database:`; `Watcher` `latency:`; both Extensions' `chunker:`;
  Voikko `compounds:`; Filesystem `trusted:` (never `true`), `env:`; `ProjectRoot` `markers:`;
  spec-only readers `Workspace::Extension#workspace`, `SubAgent::Extension#personas`,
  `Profile#gloda?`, `Calendar#available?`; `DatabaseSnapshot#refresh(attempts:, backoff:)` and
  `IcsEvent.build(uid:, dtstamp:)` are test seams. web: Engines `disk_cache:`/`memory_cache:`
  injection + `UrlCache::NULL` (~45, test seams).
- ~~`Q_chat_dead_rescue`~~ **Done 2026-11-14:** dropped from `pikuri-chat`.
- ~~`Q_handoff`~~ **Decided 2026-11-14: keep** — a seam awaiting its consumer, justified by
  `D_confirmer_sees_the_cancel`.

## B. Downstream-only leaves — could move as-is

| Item | Lines | Consumers | Catch |
|---|---|---|---|
| ~~`Workspace::ProjectRoot`~~ | 77 | pikuri-code, tui-code | **moved 2026-11-14** to `Pikuri::Code::ProjectRoot` (workshop 77cad77, pushed); pikuri-tui-code still calls the old constant, handed off with its catch-up to pikuri `4baa2076` / `35f02e10` |
| ~~`BundlerEnv`~~ | 68 | lsp, mcp, code | **kept 2026-11-14** — why in `D_de_bundlerized_children`; `Thunderbird::Launcher` now spawns over it too, giving it a pikuri root |
| `FILE_MINER` persona | 56 | pikuri-code, tui-code | book subagents/security chapters lean on it |
| `Parameters#required_string_array`, `EMPTY` | ~46 | tasks, code | generic, tiny — lean keep |
| `TokenLog` status-line API | ~40 | tui, webui | could go to pikuri-conversations |
| `Confirmer::AutoApprove`, `#confirm?` | ~32 | code, os, tui | |
| `Paths.config` / `Paths.state` | ~26 | os, tui, webui | the `Paths` convention lives here — lean keep |

`Q_move_leaves` — which of these move.

## C. Seams — keep; each needs a written why

| Seam | Lines | Consumers | Written why |
|---|---|---|---|
| History export/restore | ~440 | conversations, webui | ✓ `D_history_*` (4) |
| `around_request:` + `RequestInstrumenter` | ~125 | conversations, mcp | ✓ `D_llm_request_throttle` |
| `ChatTransport#params` | ~70 | tui, webui | ✓ `D_opaque_request_params` |
| `modalities` + attachment refusal | ~110 | conversations, tui, webui | ✓ `D_refuse_unsupported_attachments` |
| reference block | ~50 | skills, memory (pikuri: wire-check only) | ✓ `D_reference_text_as_user_turn` |
| denylist walk in grep/glob/listing | ~80 | code/tui-code `--yolo`, lsp | ✓ `D_walked_path_denylist`; `AllowAll` (~150) itself could move |
| `Control::Handoff` | 75 | none yet | ✓ `D_confirmer_sees_the_cancel` |
| mid-conversation model switch | ~110 | conversations | ◐ `D_thinking_block_replay` = how, not why in core |
| Subprocess `env:` / `terminate` / `io` | ~20 | workshop | ◐ `D_de_bundlerized_children` |
| streaming | ~140 | conversations, tui, webui | ✗ AGENTS.md invariant only; no pikuri bin can turn it on |
| domain events (`emit_event`, `Transient`, Terminal) | ~85 | lsp, tasks, code, skills | ✗ |
| Interloper `:user` kind, `on_change`/`pending?`/`size` | ~65 | conversations | ◐ yardoc + invariant |
| bare turn / `EmptyTurnError` | ~55 | skills, tui | ✗ |
| `on_user_message` hook | ~41 | memory, code | ✗ |
| `ReadOnly` gate + slots in Write/Edit/Extension | ~150 | code plan mode, os, tui | ✗ |
| Filesystem temp/tmp-alias, env/git identity | ~118 | code bash sandbox | ✗ |
| temp workspace for sub-agents (`with_workspace` ×4, mint, `needs_temp_workspace`) | ~105 | GIT_REPO_RESEARCHER | ✗ |
| delegation confirmer gate (subagents) | ~35 | os, computer, tui | ✗ |
| `Configurator#history`, `Contribution` legs, `display_name` override | ~30 | mcp, command, lsp | ✗ |

✗ = no dedicated `D_` found (passing mentions not all read). `Q_seam_justifications` — write `D_`s
for all, or first ask which a pikuri bin should exercise (streaming, `ReadOnly`).

## D. ROOT, but one flag or one bin — capability calls

- `Q_chroma` — Chroma backend + server, ~540 lib + 620 spec; only `pikuri-corpus --chroma`. Its
  design case is "costs nothing but its (already written) line count". Leaves `Server::Container`
  with Qdrant alone.
- `Q_pikuri_corpus` — `pikuri-corpus` + `VectorDb::Extension` + `vectordb_search` wrapper, ~300;
  secretary and briefing go through rag. Dropping makes vectordb the pure primitive the module map
  says it is.
- `Q_voikko` — `Stemmer::Voikko`, 74; only `pikuri-briefing --finnish`.
- Brave + Exa (~410, config-file only) — keep. Thunderbird real-data hardening (~400: blob spotter,
  Google calendar quirks, forwarded mail, image attachments, multi-account store) — keep.

## E. Side findings

- `Q_researcher_pdf` — bug: `persona-researcher.txt:7` says `fetch` for a PDF; `fetch` refuses PDFs
  and neither `pikuri-chat` nor `pikuri-minions` registers pikuri-pdf.
- `Q_write_defaults` — promptless `Edit` and silent new-file `Write` are the defaults, yet only
  pikuri-code / tui-code use them; every pikuri root opts into confirm-all. Flip?
- `Q_global_ruby_llm_config` — three vectordb-using bins call `RubyLLM.configure` for the embedder;
  an unwritten exception to the Connection seam?
- `Q_stale_thunderbird_docs` — `MailCompose` yardoc ("never wired", flag `compose:` → is
  `allow_compose_mail:`); entry file's "v2"; `pikuri-computer:187` "five" tools (six).
- Dependency edges: vectordb → subagents goes with `Q_librarian`. subagents → workspace only via
  seams that stay. web → workspace stays (secretary's query confirmer).

## `Q_page_text` analysis

**What it buys.** Three ways to give a web-searching agent page content:

| Wiring | Egress leg | Reads pages? |
|---|---|---|
| `web_search` + `web_scrape` | `:attacker_reachable` — model types URLs; even a handle-only scraper leaks via row selection (`D_no_result_scraper`) | yes |
| `web_search(snippets_only:)` | `:tool_vouched` | no — snippets rarely answer; model loops (observed) |
| `web_search(page_text:)` + `web_read_cached` | `:tool_vouched` — reader makes no request | yes |

The third is the only shape in which an agent holding private data reads the web without its
egress turning attacker-reachable. That is the third promise ("trifecta broken by construction")
made concrete, and book/trifecta-detector.md and SECURITY.md already teach it. So it is not a
workshop "more features" item; by `D_gem_placement`'s test its future is "explain it better".

**Why it has no root.** It needs Brave or Exa (paid keys); DuckDuckGo returns no text. Every bin's
default is DuckDuckGo, and `D_page_text_by_handle` deliberately shipped no persona "for the map's
sake".

**The natural root is the secretary.** It is exactly the node the feature exists for — private
mail, notes and Documents, untrusted mail and snippets, and one vouched egress leg — and today it
falls back to `snippets_only`. Proposal: when the config's `search:` block keys Brave or Exa, the
secretary builds `web_search(page_text: true, engines: <the keyed ones>)` + `READ_CACHED`; with
DuckDuckGo alone it stays `snippets_only`. The trifecta verdict doesn't move: `web_read_cached` adds
`untrusted: :hard` (already present via mail and snippets) and no egress. The query confirmer still
gates every query.

Wrinkle: with `page_text: true` and `engines: nil`, DuckDuckGo stays in the cascade and its rows get
no handle, so on a random DuckDuckGo win the model can't read anything. The secretary should pass
`engines:` restricted to the text engines — or `Engines` should drop DuckDuckGo from a `page_text`
cascade by itself, which removes the trap for every host.

**Slimming within it.** Brave's LLM Context mode is ~115 of the ~490; Exa's text is ~12. Dropping
Brave's text mode would leave page text only on the engine that trains on queries (Exa), while
Brave only logs — the wrong way round for **Privacy first** on a private-data node. Keep both.

**Moving it to the workshop** would need pikuri-web to grow an injection seam through `Engines`,
`Brave` and `Exa` — adding a seam to remove a feature, net complexity up — and pikuri would lose its
best runnable example of the third promise.

**Lean:** keep; give it a root in `pikuri-secretary` (keyed engines → page text, else
snippets-only); consider making `Engines` exclude DuckDuckGo under `page_text`.
