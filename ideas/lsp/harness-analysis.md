# LSP client — what the shipped harnesses expose

The survey the note's worklist asked for, and the input its strategy
([`../lsp.md`](../lsp.md) §Strategy) says the operation surface must come
from: three harnesses that shipped a model-facing LSP tool, read
first-hand rather than recalled.

The survey itself spawned no server: this is a reading of three
implementations, and the point is that **their authors already paid for the
per-server learning pikuri refuses to keep cataloguing**. (It did trigger
one run — the `subtypes` question below was too close to call from absence
alone, so H7–H10 in [`research.md`](research.md) settled it.) Where a
harness's code contradicts a finding there, that is called out rather than
smoothed over, because those are the places a decision is actually being
made.

Provenance, so a later reader knows what was read:

| harness | what was read | when |
| --- | --- | --- |
| **Claude Code** | its live `LSP` tool schema, in-session (description + JSON Schema, verbatim) | 2026-08-17 |
| **opencode** | `packages/opencode/src/tool/lsp.{ts,txt}`, `src/lsp/{lsp,client,server}.ts` at `2cba7e227d68` | 2026-08-17 |
| **grok-build** | vendored source at `SOURCE_REV 7bd63df3`, `crates/codegen/xai-grok-tools/src/implementations/lsp/*` + `.../grok_build/lsp/mod.rs` (~7.9 kLOC of client) | 2026-08-17 |

## The three surfaces, side by side

| | Claude Code | opencode | grok-build |
| --- | --- | --- | --- |
| operations | **9** | **9** (identical set *and* names) | **6** |
| `goToDefinition` / `findReferences` / `hover` | ✅ | ✅ | ✅ |
| `documentSymbol` / `workspaceSymbol` | ✅ | ✅ | ✅ |
| `goToImplementation` | ✅ | ✅ | ✅ |
| `prepareCallHierarchy` / `incomingCalls` / `outgoingCalls` | ✅ | ✅ | — |
| `typeDefinition`, `declaration`, type hierarchy | — | — | — |
| (pikuri adds `goToTypeDefinition` + `supertypes` on measured evidence) | | | |
| rename / format / codeAction / completion | — | — | — |
| diagnostics as a *tool* | — | — | — (surfaced as reminders instead) |
| required params | `operation` + `filePath` + `line` + `character` | same | `operation` only; rest validated per operation |
| coordinates **in** | 1-based line + character | 1-based (schema enforces ≥ 1) | **0-based** |
| coordinates **out** | 1-based | **0-based** (raw LSP JSON) | 1-based (`+1` at format time) |
| empty result | `No definition found. This may occur if…` | `No results found for <op>` | `No results found.` / `No symbols found.` |
| output shape | grouped by file, count header, no snippets | `JSON.stringify(lspResult, null, 2)` | `Definition (N locations):` + `path:line:col` |
| result cap / grouping | count header only, no cap | none | none |
| per-operation capability gate | — (leaks `Method not found`) | — | — (surfaces as `LSP error: …`) |
| no-server-for-this-file | `No LSP server available for file type: .md` | `No LSP server available for this file type.` | `No LSP server configured for <path>` |
| indexing-readiness gate | partial — one path ignores it (finding 2) | — | — (ready == handshake done, not indexed) |
| document sync | not visible | read disk every call; `didOpen` if new else versioned `didChange` | same, plus `notify_file_changed` from the write path |
| change shape | not visible | **ranged** if server declared incremental, else rangeless | **ranged** if incremental, else rangeless |
| `didChangeWatchedFiles` | not visible | sent alongside every open/change | — |
| server registry | plugins (`jdtls-lsp`, `kotlin-lsp`) | **~20 bundled definitions** incl. `ruby-lsp` + `jdtls`, auto-installed | user-written `~/.grok/lsp.json` or `<cwd>/.grok/lsp.json` |
| timeouts | not visible | per-request, per-diagnostics-wait | `initialize` 15 s, request 30 s, shutdown 5 s; readiness itself unbounded |
| crash policy | not visible | marks a root `broken` | `restartOnCrash` + `maxRestarts` (default 3), monitor task |
| permission gate | none (read-only) | `ctx.ask({permission: "lsp"})` | `is_read_only: true`, `ToolScope::Read` |

Claude Code's and opencode's tool descriptions are near-verbatim the same
text, down to the `Supported operations:` bullet list and the closing
`Note: LSP servers must be configured for the file type.` One of them was
copied from the other, so **treat those two as roughly one data point on
membership** and grok-build as the independent one.

## What this settles for pikuri's enum

Union is Claude Code's nine; intersection is grok-build's six. Two facts
decide the middle:

- **No harness ships a type hierarchy.** `supertypes` / `subtypes` appear
  in none of the three, which retires the argument that promoted them (H1
  and H4 had already taken its Ruby half). But "no harness ships it" is an
  absence of precedent, not evidence of uselessness, and a *measured* reason
  can still put an operation back — so the two halves were probed against
  jdtls before cutting, and they came apart (H7–H10, and the section below).
  **`subtypes` out, `supertypes` in as a tenth value.**
- **No harness ships `typeDefinition`** either — and this one stays anyway,
  because J9 is a *measured* deviation of exactly the kind the strategy
  allows: on `var names = new ArrayList<String>()`, `definition` gives the
  local declaration and `typeDefinition` gives `java.util.ArrayList`, a type
  written nowhere in the source. Nothing else recovers it. Claude Code's
  omission was already flagged in `research.md` as the sharpest lesson of
  its Java run.

Recommended v1 surface — **ten operations, harness names kept verbatim**
where they exist, so they match what a model has seen everywhere else:

```
goToDefinition  findReferences  hover  documentSymbol  workspaceSymbol
goToImplementation  incomingCalls  outgoingCalls  goToTypeDefinition
supertypes
```

Four notes on that list:

- **`documentSymbol` is back in**, reversing `design.md`'s cut. All three
  harnesses ship it, and S10 is the independent reason: jdtls's
  `workspace/symbol` returns *types only*, so an in-file outline is the only
  way to turn a Java method name into a position. The
  `grep '^\s*(def|class|module)'` substitute that justified cutting it does
  not survive overloads or a nested type.
- **`prepareCallHierarchy` stays out, and that is the one place pikuri
  deliberately narrows a 2-of-3 majority.** Both harnesses that ship the
  call family expose the prepare hop *to the model*, which means handing it
  an opaque `CallHierarchyItem` to hold and echo back. pikuri runs prepare
  inside the tool (the same collapse `workspace/symbol` gets) and exposes
  only the two directions. Same capability, one round trip, nothing opaque
  in the transcript.
- **Names, not pikuri-isms.** `design.md` called these `definition` /
  `implementation` / `typeDefinition`; the harnesses agree on
  `goToDefinition` / `goToImplementation`, so use those and make the
  deviation `goToTypeDefinition` by analogy. The naming convention in
  [`../../CLAUDE.md`](../../CLAUDE.md) is untouched — this is an `operation`
  enum value, not a tool name. `supertypes` keeps the LSP method's own name
  because no harness has one to copy.
- **`supertypes` is the second measured deviation, and `subtypes` is the
  one operation an absence of precedent did *not* decide.** Probed against
  jdtls rather than cut on the survey alone: `goToImplementation` answers
  "list all subtypes" better than the hierarchy does — transitively in one
  call for an abstract type (3 descendants against `subtypes`' 1) and on
  concrete classes too (H7/H8) — so `subtypes` is dominated by an operation
  already in the list, on the only server where it works at all. `supertypes`
  goes the other way: it works on **both** servers (H2, H9) and the *chain*
  has no substitute, since `goToDefinition` on the name after `extends`
  answers a single level. The tool walks the chain internally, which is the
  collapse-the-hop move no harness makes.

## Where all three converge, and pikuri should follow

1. **One tool with an `operation` enum**, not nine tools. Unanimous.
2. **Route on the file's extension, and say so cleanly when nothing
   claims it.** All three ship almost the same sentence. pikuri's degrade
   string is already this shape.
3. **`workspaceSymbol` fans out / is not position-based.** grok-build
   dispatches it to every socket and merges; opencode documents that
   `filePath` is *only* a server selector and is never sent in the request.
   That is pikuri's design already, arrived at independently.
4. **Read-only, no confirmer.** grok-build declares `is_read_only`,
   Claude Code asks nothing. (opencode routes it through a permission with
   `always: ["*"]`, which is the same posture with a hook attached.)
5. **No result caps anywhere** — which is where pikuri deviates on
   purpose, see below.
6. **Server lifecycle is worth surfacing.** grok-build emits
   `LspServerStarting` / `Ready` / `Retrying` / `Crashed` / `Failed`
   notifications; opencode logs and marks roots broken. pikuri's
   `Lsp::ServerProgress` domain event covers the same ground, and
   grok-build's five names are a good check that one variant with
   `done:` is enough — it is, for a *progress* bar, but a `Retrying` /
   `Crashed` edge has no home in it. Worth deciding when the event is
   written.
7. **Restart-on-crash with a lifetime budget.** grok-build caps at 3
   restarts for the whole session, which is exactly what
   `Mcp::ClientWrapper`'s discipline should be checked against.

## Where they converge and pikuri should *not* follow

**The document-sync scheme.** Both harnesses whose code is visible do the
same thing: read the file from disk on every call, `didOpen` it if the
server has not seen it, otherwise send a version-bumped `didChange` whose
content change is a **whole-document replacement expressed as a range from
0:0 to where the previous revision ended** for servers that declared
incremental sync, and the rangeless form for servers that declared full
sync. grok-build's `capabilities.rs` even opens with the scar:

> Grok used to log the initialize result and throw it away, which is how it
> ended up sending Roslyn a change event the protocol says must carry a
> range.

That is **S1 confirmed on a third server** (Roslyn, where the failure is
worse than ruby-lsp's — it "tears its request queue down"), and it is the
best possible evidence that the finding generalizes. So the *lesson* is
shared. The *scheme* still must not be copied, for a reason both harnesses
had no way to hit:

- S2 measured that ruby-lsp honours exactly this ranged whole-document
  change for the **document** and then leaves its **index** behind, because
  reindexing is gated on `position_may_impact_declarations?(edit.range.start)`
  and the start of a whole-file replacement is 0:0 — a comment in any
  ordinary Ruby file. `definition` then answers `[]` for a symbol the
  server can see, which is finding 2's false premise.
- S7 measured that the `didChangeWatchedFiles` opencode helpfully sends
  alongside is **ignored for a URI the client has opened** — ruby-lsp's
  source says so outright (`unless @store.key?(uri)`), so the belt-and-braces
  notification does not rescue it.
- opencode ships a **`ruby-lsp` server definition** (`.rb .rake .gemspec
  .ru`) and a `jdtls` one, so this path is live there today. Stated as an
  inference from their code plus our measurement, not as something run
  against opencode: what would confirm it is renaming a method with
  opencode's own `edit` tool and then asking its `lsp` tool for the new
  name's definition.

pikuri's policy stays the measured one — **re-send `didOpen` with the
current disk text before every call** (S5, works on both servers, refreshes
document *and* index, no version bookkeeping) — with `didClose` + `didOpen`
as the spec-legal fallback if some future server rejects a duplicate open.
The harness scheme is what you build when the client might hold unsaved
buffers; pikuri never does.

**And the indexing-readiness gate.** grok-build's "ready" means the
`initialize` round-trip completed, not that the server has indexed
anything, and Claude Code has a gate that one path ignores. Against a
server that defers its replies (jdtls, J3) that is fine; against ruby-lsp
it is finding 2 exactly. Keep pikuri's quiescence-plus-debounce gate — it
is the one place where waiting beats relaying.

## Where they disagree with each other

These are the questions with no consensus to copy, so pikuri decides them
on its own evidence:

- **Coordinate base.** Claude Code is 1-based in and out; grok-build is
  0-based in and 1-based out; opencode is 1-based in and 0-based out (it
  prints raw LSP JSON). Two of the three are internally inconsistent, so a
  model that feeds a printed position back in gets it wrong on two of them.
  pikuri asks for no column at all and prints 1-based lines — the only
  self-consistent option on the table, and the one that matches what `Read`
  and `grep` print.
- **Whether parameters are required.** Claude Code and opencode require
  `line` + `character` even for `workspaceSymbol`, which needs neither;
  grok-build makes everything optional and validates per operation with a
  flat `Required: file_path, line, character.` string. pikuri follows
  grok-build's shape (`operation` required, the rest per-operation) because
  `symbol` is its anchor and `file` is a disambiguator.
- **Output shape.** Raw JSON (opencode), compact `path:line:col` lines
  (grok-build), grouped-by-file with a count (Claude Code). Nobody caps and
  nobody snippets. pikuri caps and groups deliberately — S9 has a single
  `references` call returning **80,609** locations, which as raw LSP JSON
  is a context-window incident, and finding 6 / H2 have the Ruby
  reopened-namespace shapes.
- **Who supplies the registry.** opencode bundles ~20 server definitions
  and installs binaries; grok-build requires a hand-written JSON file;
  Claude Code takes plugins. pikuri's "nothing is registered by default, so
  a registered-but-missing binary may raise loudly" matches grok-build and
  is incompatible with opencode's posture — worth knowing, because the raise
  is only defensible while nothing ships wired.

## Two gaps in pikuri's own registry entry, found by comparison

- **`languageId` is missing, and `didOpen` requires it.** grok-build's
  entry carries `extensions: {".rb" => "ruby"}` — an extension→language-id
  map — and opencode has a `LANGUAGE_EXTENSIONS` table with a `"plaintext"`
  fallback. pikuri's `StdioEntry#files` is a list of *basename globs*, which
  cannot answer "what `languageId` do I put in the `didOpen` for this
  file?". Either the field becomes a glob→language-id map, or a single
  `language_id:` rides alongside `files:` (right for a one-language server,
  wrong for the `eslint`-style server that claims eight extensions). Cheap
  to decide, and it is a hole a first implementation would hit in minutes.
- **`settings:` is real, not speculative.** Both harnesses carry it
  (`workspace/configuration` answers). `design.md` defers it on the grounds
  that both reference servers tolerate `null`; that stands, but the
  deferral should now cite two harnesses shipping the field rather than
  imply nobody needs it.

Also worth recording, since it is a design fork pikuri has not considered:
grok-build syncs from the **write** path (`notify_file_changed(path,
content)`, queued while the server is still starting), not only from the
read path. For pikuri that would mean `Workspace::Write` / `Edit` emitting
an event the `Lsp::Extension` consumes — a cross-gem dependency the
re-open-on-read policy avoids entirely. Note it as the alternative and its
price.

## Deferred, with the harnesses' evidence attached

- **Diagnostics.** All three surface diagnostics *without* a diagnostics
  tool: grok-build has a `reminders/lsp_diagnostics.rs` and a
  `read_diagnostics(paths)` backend call; opencode has push/pull merging,
  per-version staleness tracking and `waitForDiagnostics` with a
  document/full mode. That is a lot of machinery, and it confirms
  `design.md`'s reading: diagnostics are attractive but they need the
  system-reminder mechanism pikuri does not have, and grok-build's
  `is_stale` flag shows what honest diagnostics cost once you own document
  versions.
- **Transport beyond stdio.** grok-build's entry has a `transport` field.
  pikuri's stdio-only stance is unchallenged by the other two.
- **`workspace_open` / solution files.** grok-build has a C#-specific
  `solution/open` + `project/open` escape hatch in config. That is the
  `content_request`-shaped config field pikuri already rejected, in a
  different costume — a per-server protocol method pushed into user config.
  Good confirmation of that rejection, and of the alternative pikuri chose
  (a hardcoded table with a named server and a deletion condition).
