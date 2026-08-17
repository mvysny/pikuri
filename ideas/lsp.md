# LSP client — language intelligence for the coding agent

Status: **investigated, not built.** The design is settled and the
evidence is in; what is left is implementation plus the worklist below.

This note is split three ways, because the argued-and-closed part had
grown to ~1600 lines and buried the handful of things still to do:

| file | holds |
| --- | --- |
| **this file** | status, the strategy, the worklist, the graduation map |
| [`lsp/research.md`](lsp/research.md) | six live client runs, a rubygems survey, a shipped client read off its schema — the stable `finding N` / `J<n>` / `H<n>` / `S<n>` labels everything else cites |
| [`lsp/harness-analysis.md`](lsp/harness-analysis.md) | the three shipped harnesses' LSP tools read first-hand (Claude Code, opencode, grok-build) — the operation surface, and where they converge, differ, or are contradicted by a finding |
| [`lsp/design.md`](lsp/design.md) | everything decided: direct-vs-MCP, the registry entry, no-timeout, progress + mailbox, the scheme table, the operation surface, document sync, protocol modeling, testing, the trifecta legs |

Nothing in `lsp/design.md` has met an implementation, which is why it is
still here rather than in `pikuri-lsp/DESIGN.md`, four `DECISIONS.md`
entries and a book chapter. Graduation below.

Origin: [`feedback.txt`](feedback.txt) item 2 — "No language
intelligence. For Ruby I'd want go-to-definition and find-references. I
can grep, but `ConfirmerPopup` vs `ask` vs the pikuri `Confirmer`
interface is exactly the kind of thing an LSP hop settles in one call."
That is the concrete use case
[`coding-agent.md`](coding-agent.md)'s LSP bullet was waiting for —
**this note supersedes that bullet** (and the matching one in
[`claude-parity.md`](claude-parity.md)); delete both when this
graduates.

Related:

- [`../DECISIONS.md`](../DECISIONS.md) `D-walked-path-denylist` — every
  LSP result is a *walked* path, so that entry's rule applies verbatim.
  Probably the single most load-bearing constraint here.
- `Pikuri::Mcp::ClientWrapper` — the existing long-lived stdio JSON-RPC
  child, restart-on-death and all. The shape to copy.
- [`../COMPARISON.md`](../COMPARISON.md) §"Available tools" — the LSP
  column is `—` for pikuri, `✅` for opencode and grok-build. Update
  when this ships.

---

## Strategy: source the surface from harnesses, relay glitches honestly

**Decided 2026-08-17, and it reverses how this note was being built.** The
six runs in [`lsp/research.md`](lsp/research.md) found a genuine pattern,
and then the pattern turned on the method: *every* server is broken in its
own way, and the ways do not generalize. ruby-lsp advertises a type
hierarchy whose `subtypes` half is a `# TODO` (H1); jdtls's
`workspace/symbol` cannot see a method at all (S10);
ruby-lsp crashes on a full-text `didChange` that jdtls accepts (S1);
ruby-lsp's index desynchronizes from its own document because of a
typing-speed heuristic (S2). There are LSPs for Python, Kotlin, Rust, Go
and thirty other languages, each with its own list. **A catalogue of two
servers' glitches is not a design input**, and the arms it was steering
toward — a per-server known-stub list, per-server readiness predicates,
per-operation workarounds — are unbounded work that gets one server right
and says nothing about the third.

So:

1. **The operation surface comes from harnesses that shipped one**, not
   from what two servers happen to implement. Claude Code's nine
   (`research.md`, prior art), grok-build's set, opencode's — the authors
   did this homework, and their union is both a better v1 and a stable
   input. Deviate only where there is a *measured* reason (the
   `typeDefinition` addition, J9).
2. **Server glitches are relayed, not worked around.** The tool reports
   what the server said and what it asked for; the model decides what to do
   about it. This is not a shrug — a strong model handles "the index is
   stale, let me try another way" routinely, and the runs show pikuri
   cannot pre-empt the failure modes anyway.
3. **The one thing that must not be relayed is a *lie*.** Three distinct
   answers must stay distinct in what the model reads: *the server does not
   support this operation*, *the server answered nothing*, and *the server
   is not ready yet*. Collapsing them is the single most consequential
   defect in the shipped prior art (Claude Code's
   `No definition found. This may occur if…`, finding 2's false premise
   verbatim), and keeping them apart is one rendering rule, not a
   per-server anything.
4. **No fallback steering.** An error says what failed; it never proposes
   grep. Unchanged from `design.md`, and it is the same principle as (3):
   report, don't decide.

**And the readiness gate stays**, because it is the one case where waiting
is strictly better than relaying: a server that is still indexing will
answer `[]` (finding 2) and there is nothing for the model to reason about
in an empty list. Block until ready, emit progress, let the human be the
timeout.

**Model target: 25B+, not 4B.** A 4B model cannot code, so nothing here is
sized for one. This deletes the "small local models chain badly" argument
wherever `design.md` leans on it (the `lsp_read` refusal, the prepare-hop
collapse, the no-timeout decision, the name→position collapse) — each of
those needs an honest replacement reason or needs dropping. The strongest
surviving one is not about model capability at all: **a hop the tool can
perform exactly is not a hop worth spending a round trip on**, and a
coordinate the model was never shown is not a coordinate it should be
asked to invent (see the parameter item below).

## The v1 build

What ships, assembled in one place because it is currently spread over three
files. Every line has its rationale elsewhere; this is the checklist, not the
argument.

**The gem.** `pikuri-lsp`, depending on `pikuri-core` **and
`pikuri-workspace`** — the latter is not optional: the tool needs
`Filesystem#denied?`, the root confinement, the seam-routed read behind every
re-open, and `filesystem.private?` for its own trifecta declaration. An LSP
serves a *project*, and `Workspace` is what a project is in pikuri.

**Build order** (each step testable before the next exists):

1. **Protocol layer + `Location` / `Position` / `Range` / `ServerProgress`
   value types.** Framing, id demux on a reader thread, auto-reply to
   server→client requests, both `Location` and `LocationLink` shapes
   (finding 4), utf-16↔utf-8 offset conversion (finding 7, mandatory —
   jdtls ignored the utf-8 offer), 1-based↔0-based at the boundary only.
2. **`ClientWrapper.new(stdin:, stdout:)` + `.spawn(entry)`** — the
   constructor must not spawn, so the fake server can drive it over
   `IO.pipe`. Restart-on-death copied from `Mcp::ClientWrapper`, with the
   documented Subprocess-seam exception.
3. **The fake server + raw-byte fixtures** from the recorded runs, so a
   serializer bug cannot hide behind a symmetric parser.
4. **Registry + `Registry.from_h`**, entry as below.
5. **Readiness gate + the coalescing mailbox + `ServerProgress`.**
   Quiescence (all progress tokens closed) plus a settle debounce, blocking
   with no timeout, polling `Cancellable`, `window.workDoneProgress: true`
   declared or jdtls emits nothing to watch (J1–J3).
6. **The `lsp` tool**: ten operations, the `symbol`-anchored parameters,
   capability gate at dispatch, re-open-on-read sync, result rendering.
7. **`Lsp::Extension`**: `configure` builds the client set, registers the
   tool via `Configurator#add_tool` (**not** `add_raw_tool`, or the legs go
   invisible), arms `on_close`; `bind` hands the tool the emitter.
   Contributes **no** `trifecta_contribution`.
8. **Live smoke specs**, tagged to skip when the binary is absent.

**The entry.**

```ruby
StdioEntry = Data.define(:id, :command, :files, :language_id, :env, :init_options)
```

`language_id:` closes the hole the harness survey found — `didOpen` carries
a `languageId` and basename globs cannot supply one — but it is **optional,
with a built-in extension→id table behind it**, which is what S11 argues.
The value's origin is the LSP spec's *language identifiers* table (VS Code's
list, adopted by the spec and open-ended, since the field is a plain string
on the wire), so pikuri ships the well-known rows — the ones that are not
simply the extension: `.rb`→`ruby`, `.java`→`java`, `.py`→`python`,
`.rs`→`rust`, `.cs`→`csharp`, `.ts`→`typescript`, … — and the entry's
field overrides them for anything unlisted.

**The default is derived from the *entry*, not from the file being opened.**
`files:` holds basename globs, so a `Rakefile` has no extension to look up;
the table is consulted once per entry, against its first extension-bearing
glob (`*.rb` → `ruby`), and every file that entry claims is opened under that
id. Coherent because an entry *is* one server for one language, and it keeps
`Rakefile` / `Gemfile` / `Dockerfile` rows out of the table entirely.

**The field is not required**, because S11 measured that jdtls ignores it
entirely and ruby-lsp falls through to `:ruby` for anything it does not
recognize, while the two values it *does* recognize
wrongly (`erb`, `rbs`) return `nil` and zero symbols in silence. Asking a
user to type a string that only hurts when it is *plausible* is the worst
shape available; a table cannot make that mistake, and the Ruby book example
stays three lines. One field per entry rather than a glob→id map, since an
entry *is* a server; a multi-language server wires two entries at the same
command, which `id` already distinguishes. No `root:`, no
`startup_timeout:`, no `content_request:`, no `settings:` (deferred, and
both harnesses have one — say so honestly rather than implying nobody needs
it).

**The tool.** `operation` (enum of ten), `symbol` (required), `file` and
`line` (optional). Column derived by `locate(text, symbol)`, never asked
for. Rendering rules, all measured: cap and group (`findReferences` hardest
— S9's 80,609), group `supertypes` by name preferring the declaration over
namespace reopenings (H2), snippet-only outside the root, the scheme table
for `jdt:`, never dereference `http(s):`, and keep *unsupported* /
*answered-nothing* / *not-ready* three distinct strings.

**Proposed for the last open call** (worklist item 2): an anchor that
resolves outside the root is **refused with its own message** in v1. With
`file` + `line` the ordinary shape, the anchor is in-root by construction
almost always, and what is lost — following a hop *into* a dependency — is
still answered by `hover` and the scheme table.

**Explicitly not in v1**, each with its home: observing the agent's own
edits (a settled shape, deferred — `design.md` §"Observing the agent's own
edits"), diagnostics, `rename` / formatting / code actions, an `lsp_read`
operation, and the operations left out of the enum — `subtypes` (H7/H8),
`prepareCallHierarchy` (collapsed inside the tool), `declaration`,
`completion`.

## Worklist

Three items left, and none of them is a server-behaviour question. The
original nine are closed: items 1, 7, 8 and 9 by the document-sync run,
items 3, 5 and 6 folded into what follows, the operation surface by the
harness survey, and items 2 and 4 restated below.

### 1. The parameter shape: `symbol` replaces `character`

Deliverable, and the run settles which half is deliverable how:

- **`symbol` + `file` + `line` → the column, derived by the tool.** One
  line read, one string search, no index and no server involvement. This
  works on every server that will ever be wired, and it is the whole point:
  **nothing in the model's input contains a column.** `Read` prints
  line→text, `grep` prints `file:line:text`; producing a column means
  counting characters in a line the model saw as prose, exactly right, with
  tabs and multibyte. Being wrong is not an error — S8 has `definition`
  answering 0 at a keyword column, and S9 has `references` seven columns
  off returning **80,609** results instead of 2.
- **`symbol` alone → position via `workspace/symbol`** is the half that is
  *not* reliable, in opposite directions per server: H6 (a bare namespaced
  Ruby class scores below ruby-lsp's 0.7 Jaro-Winkler threshold and is never
  returned) and S10 (jdtls indexes no methods, so a Java method name is
  unreachable). Ship it as a best-effort convenience that reports honestly
  when it resolves nothing, and let `file` + `line` be the shape the tool
  description actually teaches.
- Two mechanical rules survive from the runs: the exact-name filter
  compares the **last `::` segment**, never `name` (H6, deliberate in
  ruby-lsp's source), and `locate(text, symbol)` is mandatory on both
  servers for different reasons (H5 strict, S8 strict-per-operation).
- An optional `character` override is strictly additive if the derived
  column ever disagrees with what the model meant. Not v1.

### 2. What anchors a hop that resolves outside the root

**A v1 answer is proposed in "The v1 build" above** (refuse with its own
message); this is the full fork, kept because the other two arms are what a
reader will ask about.
With `symbol` alone, `workspace/symbol` can place the anchor in a gem file
outside the workspace root, or behind a `jdt:` URI (J5). Every
position-based operation then needs a document the tool is not allowed to
open. Result *rendering* has an answer (snippet-only, the scheme table);
the *anchor* does not. Three arms, and they need not all get the same one:
refuse with a distinct message, permit a read-only `didOpen` of an
out-of-root `file:` path, or `didOpen` the virtual URI with the text the
scheme table already fetches (nvim-jdtls does the last).

Smaller than it was: with `file` + `line` the normal shape (item 1), the
anchor is in-root by construction almost always, so "refuse with a distinct
message" is a defensible v1 — the capability lost is following a hop *into*
a dependency, which `hover` and the scheme table still answer.

### 3. What the tool and the registry entry are missing

**Also answered in "The v1 build" above** (`language_id:` as one field per
entry); the reasoning is below.

**The tool.** The Sketch names only the emitter handoff. It also needs the
client set and a `Workspace::Filesystem` — for `denied?`, the root
confinement, the seam-routed read behind the sync notification, and
`private?` on the trifecta declaration (the closed item 9 makes that last
one load-bearing: the tool declares all three legs itself, so it must hold
the filesystem). One line in the Sketch closes this.

**The entry needs a `languageId`, and this is the one real hole the harness
survey found.** `didOpen` carries a `languageId` and pikuri's
`StdioEntry#files` is a list of *basename globs*, which cannot answer what
to put there. Both harnesses carry an extension→language-id map
(grok-build's `extensions:`, opencode's `LANGUAGE_EXTENSIONS` with a
`"plaintext"` fallback). Either `files:` becomes a glob→id map, or a single
`language_id:` rides alongside it — right for a one-language server, wrong
for the `eslint`-shaped server that claims eight extensions. Decide before
the client is written; see
[`lsp/harness-analysis.md`](lsp/harness-analysis.md) §"Two gaps".

Also folded in here: **fan-out.** A bare-`symbol` call fans out to every
registered server and therefore waits for all of them to be ready, so a
Ruby-only question pays jdtls's cold import (78s, J6) the first time. That
follows from the no-timeout rule and is acceptable — and with `file` the
normal shape it is now the rare path rather than the default. Write it down
as an accepted consequence; the mitigation (fan out only to servers already
ready) trades completeness for latency and can wait for a complaint.

## Closed by the harness survey

Full reading in [`lsp/harness-analysis.md`](lsp/harness-analysis.md); the
outcome, so nobody re-derives it:

- **The v1 enum is ten operations, harness names verbatim plus one** —
  `goToDefinition`, `findReferences`, `hover`, `documentSymbol`,
  `workspaceSymbol`, `goToImplementation`, `incomingCalls`, `outgoingCalls`,
  `goToTypeDefinition`, `supertypes`. Claude Code and opencode ship an
  identical nine (near-identical tool text too, so they count as roughly one
  data point); grok-build ships six, a strict subset; the last two are
  measured deviations.
- **`subtypes` is out — and the reason is now measured, not merely an
  absence.** H7/H8: on jdtls, `goToImplementation` answers "list all
  subtypes" **transitively in one call** (abstract `Widget` → all 3
  descendants) and works on *concrete* classes too (`Panel` → 2), while
  `typeHierarchy/subtypes` returns the direct children only (`Widget` → 1)
  and needs one round trip per level. On ruby-lsp it is the `# TODO` (H1).
  So there is **no server on which `subtypes` is the best available
  answer**, and the question that motivated it is already served by an
  operation in the enum. `findReferences` is *not* the substitute — H10 has
  exactly 1 of 4 hits being the `extends` site, unlabelled.
- **`supertypes` is in, as the tenth.** It is the one hierarchy operation
  that works on **both** servers (H2 on ruby-lsp, H9 on jdtls), and the one
  with no substitute: `goToDefinition` on the name after `extends` answers a
  single level, whereas the *chain* takes one call per level — which the tool
  walks internally, the same collapse `workspace/symbol` and `prepare*` get.
  Marginal cost is one enum value and one dispatch arm, because the
  prepare-then-fetch machinery is already required by the call pair. Two
  known consequences: H2's grouping pass is mandatory (14 rows of namespace
  reopenings for one Ruby class, declaration ordered last), and an ancestor
  walk reaches jar URIs routinely (H9's `Object`), so the scheme table is on
  this path too.
- **`documentSymbol` is in**, reversing `design.md`'s cut: all three ship it,
  and S10 makes it the only route from a Java method *name* to a position.
- **`goToTypeDefinition` is in**, the one deviation from all three, because
  J9 measured what nothing else recovers (`var names = new ArrayList<>()`).
- **`prepareCallHierarchy` stays out** — the one place pikuri narrows a
  2-of-3 majority, because exposing it hands the model an opaque
  `CallHierarchyItem` to echo back; the prepare hop runs inside the tool.
- **Two harness habits are confirmed and adopted**: `workspaceSymbol` fans
  out and takes no position (opencode documents `filePath` as a
  server-selector only), and a read-only tool takes no confirmer.
- **One convergence is rejected with evidence**: both visible harnesses
  sync documents with version-tracked ranged whole-document `didChange`
  events — and grok-build's `capabilities.rs` opens by describing S1's
  failure against *Roslyn*, which is the finding independently confirmed on
  a third server. The scheme still loses to S2 on ruby-lsp (document fresh,
  index stale), and opencode ships a `ruby-lsp` definition, so pikuri keeps
  its own re-open policy.
- **Also confirmed by contrast**: nobody caps results (S9's 80,609-location
  `references` would arrive as raw JSON in opencode), nobody gates per
  operation, and nobody waits for indexing — the three places pikuri
  deviates deliberately.

## Closed by the document-sync run

Recorded here rather than deleted, because each one's *resolution* is what
a reader would otherwise re-litigate. Findings `S1`–`S10` in
[`lsp/research.md`](lsp/research.md); the settled policy is in
[`lsp/design.md`](lsp/design.md) §"Document synchronization".

- ~~**Document synchronization across calls**~~ (was items 1 and 7).
  **Settled, and the leaning was wrong.** The leaned scheme — a per-server
  open-URI set, `didOpen` on first touch, full-text `didChange` with an
  incremented version when the digest moved — fails on the first server it
  meets: ruby-lsp declares incremental sync and *crashes* on a rangeless
  full-text change, reporting it only to `window/logMessage` (S1). The
  ranged variant is honoured, and then desynchronizes the *index* from the
  document it just updated (S2), so `definition` answers `[]` for a symbol
  the server can see. What works on both servers is the thing the spec
  forbids: **re-send `didOpen` with the current disk text before every
  call** (S5) — no versions, no digests, no `didClose` (which resyncs
  ruby-lsp and does nothing for jdtls, S6). The reason it is sound rather
  than merely lucky is that **pikuri has no unsaved buffers**: `write` and
  `edit` land on disk immediately, so the tool never owns state the disk
  lacks, and the spec's own out-of-band channel
  (`workspace/didChangeWatchedFiles`) is ignored precisely because a client
  that opened a document is *presumed* to be its authority (S7).
- ~~**Does jdtls anchor like ruby-lsp?**~~ **No, and not uniformly within
  itself** (S8): `prepareTypeHierarchy` answers from any column on the
  declaration line including the keywords, while `definition` answers 0 at
  a keyword column, and `workspace/symbol` reports the *symbol* column
  where ruby-lsp reports the *keyword* column. `locate(text, symbol)` is
  load-bearing on both servers; the per-server reasons are not worth
  modeling.
- ~~**Does `Filesystem#denied?` have an opinion outside the root?**~~ (was
  item 8). **Only under `AllowAll`, and that is fine.** Measured against
  the real classes: the scoped `Filesystem` — `bin/pikuri-code`'s wiring —
  has `denied_roots == []` and answers `denied?(path) == false` for
  *everything*, in-root and out, while `resolve_for_read` raises for every
  out-of-root path. `AllowAll` answers `true` for `~/.ssh`, `~/.ssh/id_*`
  and `/etc/shadow` and `false` for gem paths, `~/.m2/repository` and a
  nonexistent path, symlink-resolving first and never raising.

  So: **root confinement carries the out-of-root boundary alone**, and the
  `denied?` pass is load-bearing exactly where it was designed to be — the
  container wiring, where an LSP result *could* name a credential path and
  nothing else would stop it. `design.md`'s sentence "`Filesystem#denied?`
  still applies" is true but weaker than it reads; keep the pass (it is
  cheap, exact and fails closed) and stop implying it filters gem paths.
- ~~**Does `Lsp::Extension` contribute trifecta legs?**~~ (was item 9).
  **No — it must not override `trifecta_contribution` at all**, and the
  base class already returns `nil`, so this costs nothing. Three mechanics
  make it definite: an extension registers a real `Pikuri::Tool` through
  `Configurator#add_tool` at *configure* time (the `Tasks::Extension`
  shape), which lands it in `agent.tools`, so `Trifecta.build` reads its
  `trifecta_legs` directly — `add_raw_tool` is the leg-invisible path and
  is only for MCP's and sub-agents' synthesized `RubyLLM::Tool`s. A
  contribution's legs are *unioned* per label, and `legs | legs == legs`
  (verified), so a duplicate declaration would not move the verdict —
  the harm is the map: a `(lsp)` row would appear beside the `lsp` row
  carrying the same three legs, and `Contribution#label` is what
  `Report#attribution` points the reader at, so it would blame the
  extension for a declaration living on the tool. And an MCP-shaped
  `ASSUMED` contribution would actively *widen* the answer —
  `legs | ASSUMED` flips egress to `:unreviewed` / `:attacker_reachable`
  (verified) — which is the opposite of the measured truth.

## Graduation

When built: protocol mechanics + the "capabilities are per-workspace"
and "empty result ≠ no definition" lessons → book chapter (both are
better taught with the observation that a shipped client gets the second
one wrong, and the second is sharper for J3's contrast — one server
defers, the other answers `[]`, and only one of them can be trusted);
the silent-empty traps (pre-index query, an undeclared
`classFileContentsSupport`, a fuzzy `workspace/symbol` hit, an advertised
provider wired to a `# TODO`) → one book section, since they are the same
lesson wearing four hats; **the document-sync policy** → yardoc on the
client plus a book paragraph, because "an agent is not an editor: it has no
unsaved buffers, so it must not own documents" is the whole reason the
spec-forbidden re-open is the right answer; per-symbol
rationale → yardoc on `Lsp::ClientWrapper` / the tool, including why the
`operation` enum is static while gating happens at dispatch; the
walked-path-filtering and Subprocess-exception invariants → a `CLAUDE.md`
seam entry; the entry's field-by-field rationale → yardoc on
`Lsp::Registry::StdioEntry`, and the two worked configs → the book chapter
(the *no configurable root* rule is the one that also wants a sentence in
the seam entry, since it is what keeps the LSP's project and the
`Workspace` root the same boundary);
**direct-vs-MCP with the bridges named**, **no-timeout with its three
replacements** (plus the startup and failure policy that falls out of it:
spawn synchronously at boot so a missing binary raises, index in the
background, block the first call for as long as it takes, and on child
death return `"Error: …"` with **no fallback suggestion** — the tool works
or it errors, and never proposes grep), **the harness-sourced operation
surface with relay-don't-work-around as its rule** (rejected: a per-server
known-stub list; per-server readiness predicates; an enum sized to what two
servers implement), and **the scheme table** (standard-first, one hardcoded
`jdt:` row, rejected alternatives: standard-only — which made the Java arm
untestable — and a `content_request` config field; plus the deletion
condition), and **the declared trifecta legs** — one entry for all three
axes, since it is one declaration a reader questions once: `:no_egress`
despite a child that goes online (rejected: a `:tool_vouched` tag on the
vetted-destination argument; inheriting MCP's `ASSUMED` on the shared
foreign-stdio-binary shape) and unconditional `untrusted: :hard` (rejected:
riding `filesystem.trusted?` the way {Pikuri::Workspace::Read} does;
confining results to the root to earn `:none`), **with the trusted-checkout
verdict flip stated as a consequence** → five new `DECISIONS.md` entries
(suggested slugs `lsp-direct-not-mcp`, `lsp-no-startup-timeout`,
`lsp-operation-surface`, `lsp-scheme-fallback`, `lsp-trifecta-legs`, with
the usual prefix); the threat model itself, including the
unsandboxed-child asymmetry against `Code::Bash` → `pikuri-lsp/DESIGN.md`;
the COMPARISON.md LSP column → `✅`.
Then delete this file **and the whole `lsp/` folder with it**, plus the
superseded LSP bullets in `coding-agent.md` and `claude-parity.md`.

The scheme table also wants a line in the `CLAUDE.md` seam entry, since
"pikuri-lsp reads only `file:` paths and one enumerated server-private
scheme, never the network" is an invariant someone could break by adding
a row without noticing.
