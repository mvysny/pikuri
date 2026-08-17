# LSP client — language intelligence for the coding agent

Status: **investigated, not built.** The design is settled and the
evidence is in; what is left is implementation plus the worklist below.

This note is split three ways, because the argued-and-closed part had
grown to ~1600 lines and buried the handful of things still to do:

| file | holds |
| --- | --- |
| **this file** | status, the worklist, the graduation map |
| [`lsp/research.md`](lsp/research.md) | four live client runs, a rubygems survey, a shipped client read off its schema — the stable `finding N` / `J<n>` labels everything else cites |
| [`lsp/design.md`](lsp/design.md) | everything decided: direct-vs-MCP, the registry entry, no-timeout, progress + mailbox, the scheme table, the ten-operation surface, protocol modeling, testing, the trifecta legs |

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

## Worklist

Nine items, and they divide by kind: six want a decision, three want a
live run. **Every one is shaped like the silent-empty trap the design
spends its length refusing** — an advertised provider that returns
nothing, an ignored notification, an anchor on the wrong token, a name
that scores below a similarity threshold. None of them fails loudly,
which is why they are listed rather than left to be discovered.

The type-hierarchy run (`research.md`, H1–H6) closed two of the five
live-run items and **opened two decisions in their place**, now items 5
and 6 — which is the note's own thesis landing on the note: both were
advertised-and-empty, and neither would have been noticed by a capability
gate. It also closed one outright, with no fork behind it: **the
keyword-vs-symbol anchor.** `prepareTypeHierarchy` at the keyword column
returned zero items in 6 cases out of 6 and at the symbol's own column
returned exactly one in all 6, and `workspace/symbol`'s own range for
`class Tool` starts at column 2 — the keyword. So the design's
`locate(text, symbol)` helper is confirmed mandatory rather than a
nicety, and only the jdtls half of that check is left (folded into item 7).

### Needs deciding — before the tool layer is written

1. **Document synchronization across calls.** `didOpen` with the file's
   full text is a precondition nowhere stated in the spec (the jdtls
   corrections), and the tool does the opening because the model never
   opens anything. Unsettled: what the *second* call does — LSP forbids
   `didOpen` on an already-open document, so it is either `didClose` +
   re-open or a version-bumped full-text `didChange` — and what happens
   after the agent's own `write` / `edit` leaves the server's in-memory
   copy stale. A stale open document answers confidently against text
   that is no longer there, which is finding 2's false premise by a fifth
   route. Leaning: a per-server set of open URIs, `didOpen` on first
   touch, full-text `didChange` with an incremented version whenever the
   file's digest moved since the last sync, no `didClose` (the set dies
   with the child). Verification is item 7.
2. **What anchors a hop that resolves outside the root.** With `symbol`
   alone, `workspace/symbol` can place the anchor in a gem file *outside*
   the workspace root, or behind a `jdt:` URI (J5). Every position-based
   operation then needs a document the tool is currently not allowed to
   open: out-of-root paths are refused up front, and a `jdt:` document is
   not on disk at all. Result *rendering* has an answer already
   (snippet-only, the scheme table); the *anchor* does not. Three arms,
   and they need not all get the same one: refuse with a distinct
   message, permit a read-only `didOpen` of an out-of-root `file:` path,
   or `didOpen` the virtual URI with the text the scheme table already
   fetches (nvim-jdtls does the last). This is the one place where the
   confinement boundary and the capability J8 sells pull against each
   other directly.
3. **Fan-out blocks on every server.** A bare-`symbol` call fans out, so
   it waits for *all* registered servers to be ready — a Ruby-only
   question pays jdtls's cold import (78s, J6) the first time. That
   follows from the no-timeout rule and is probably acceptable, but it
   should be an accepted consequence in writing rather than a surprise.
   The cheap mitigation — fan out only to servers already ready, when any
   are — trades completeness for latency and is its own small decision.
4. **What the tool is constructed with.** The Sketch names only the
   emitter handoff. It also needs the client set and a
   `Workspace::Filesystem`: for `denied?`, the root confinement, the
   seam-routed read behind `didOpen`, and `private?` on the trifecta
   declaration. One line in the Sketch closes this.

### Needs deciding — opened by the type-hierarchy run

5. **`subtypes` does not work on ruby-lsp, so the Ruby "who overrides
   this" hole is still open — decide what ships.** ~~Does a type
   hierarchy actually return anything on ruby-lsp?~~ **Run: H1–H5.**
   `typeHierarchy/subtypes` is an unimplemented stub returning `nil`
   behind a truthfully-advertised `typeHierarchyProvider` (H1), and module
   ancestry is not walked in either direction (H4). `supertypes` works,
   but only upward and only for classes. That **removes the reason the two
   hierarchies were promoted into v1**: `design.md` argues `subtypes` is
   what closes the hole `implementation`'s `.rb` refusal leaves open, and
   it does not close it — Ruby still has no "who overrides this"
   operation, and grepping `< Base` is still the only answer.
   Consequences to settle, in order:
   - **A capability gate cannot express this.** One provider key covers
     both directions, so `.rb` would advertise `subtypes` and answer
     empty — the note's own headline failure mode shipped as a feature.
     Either the enum drops `subtypes` for now, or the dispatch table gains
     a per-server *known-stub* list, which is a new concept the design
     does not have.
   - **`supertypes` earns its place on its own** (H2's `Read` → 14 rows,
     one real), but it needs grouping by name with the declaration
     preferred over namespace reopenings, not just a cap — a cap would cut
     the one useful row, which sorted last in the live reply.
   - **A `nil` result is not `[]`.** The parse layer must accept both.
6. **A bare `symbol` cannot resolve a namespaced Ruby class — the tool's
   required parameter needs rethinking.** Opened by H6, and it is the
   sharpest thing the run turned up. ruby-lsp's `workspace/symbol` matches
   Jaro-Winkler over the `::`-stripped **fully qualified** name against a
   0.7 threshold, so `Tool` scores 0.000 against `pikuritool` and
   `Confirmer` scores 0.455 against `pikuriworkspaceconfirmer` — both
   below threshold, both never returned, while the instance variable
   `@confirmer` scores 0.967 and is. Query the FQN and it works
   (1.000). Both halves are deliberate in ruby-lsp's source, so neither
   will change. So the design's "collapse the name→position hop inside the
   tool" commitment holds, but its *input* cannot be a bare name for Ruby.
   Arms: require an FQN (and say so in the parameter description, which
   costs the model nothing since it reads `module`/`class` lines anyway);
   or have the tool try the bare name, then retry as a suffix match over
   the unfiltered index; or accept either and let `file` disambiguate. The
   exact-name filter also has to compare the **last `::` segment**, never
   `name`.

### Needs a live run

7. **Is `didChange` honoured by both servers, and does jdtls anchor like
   ruby-lsp?** The sync scheme in item 1 is worthless if a server ignores
   it — and an ignored `didChange` fails silently, which is the whole
   problem. The keyword-vs-symbol anchor is settled for ruby-lsp (H5) and
   still wants one jdtls check, since it is the same helper.
8. **Does `Filesystem#denied?` have an opinion outside the root?** It is
   built for paths *under* the workspace root, and every interesting LSP
   result is outside it. Either it answers usefully for
   `~/.local/share/…/gems/` or root confinement is carrying that boundary
   alone — and the `D-walked-path-denylist` rule needs to know which.
9. **Confirm `Lsp::Extension` contributes no trifecta legs**, now that
   the tool declares all three, or the same legs land on the map twice.

## Graduation

When built: protocol mechanics + the "capabilities are per-workspace"
and "empty result ≠ no definition" lessons → book chapter (both are
better taught with the observation that a shipped client gets the second
one wrong, and the second is sharper for J3's contrast — one server
defers, the other answers `[]`, and only one of them can be trusted);
the three silent-empty traps (pre-index query, an undeclared
`classFileContentsSupport`, a fuzzy `workspace/symbol` hit) → one book
section, since they are the same lesson wearing three hats; per-symbol
rationale → yardoc on `Lsp::ClientWrapper` / the
tool, including why the `operation` enum is static while gating happens
at dispatch; the walked-path-filtering and Subprocess-exception
invariants → a `CLAUDE.md` seam entry; the entry's field-by-field
rationale → yardoc on `Lsp::Registry::StdioEntry`, and the two worked
configs → the book chapter (the *no configurable root* rule is the one
that also wants a sentence in the seam entry, since it is what keeps the
LSP's project and the `Workspace` root the same boundary);
**direct-vs-MCP with the bridges named**, **no-timeout with its three
replacements** (plus the startup and failure policy that falls out of it:
spawn synchronously at boot so a missing binary raises, index in the
background, block the first call for as long as it takes, and on child
death return `"Error: …"` with **no fallback suggestion** — the tool works
or it errors, and never proposes grep), and **the scheme table** (standard-first, one hardcoded
`jdt:` row, rejected alternatives: standard-only — which made the Java arm
untestable — and a `content_request` config field; plus the deletion
condition), and **the declared trifecta legs** — one entry for all three
axes, since it is one declaration a reader questions once: `:no_egress`
despite a child that goes online (rejected: a `:tool_vouched` tag on the
vetted-destination argument; inheriting MCP's `ASSUMED` on the shared
foreign-stdio-binary shape) and unconditional `untrusted: :hard` (rejected:
riding `filesystem.trusted?` the way {Pikuri::Workspace::Read} does;
confining results to the root to earn `:none`), **with the trusted-checkout
verdict flip stated as a consequence** → four new `DECISIONS.md` entries
(suggested slugs `lsp-direct-not-mcp`, `lsp-no-startup-timeout`,
`lsp-scheme-fallback`, `lsp-trifecta-legs`, with the usual prefix); the
threat model itself, including the unsandboxed-child asymmetry against
`Code::Bash` → `pikuri-lsp/DESIGN.md`; the COMPARISON.md LSP column → `✅`.
Then delete this file **and the whole `lsp/` folder with it**, plus the
superseded LSP bullets in `coding-agent.md` and `claude-parity.md`.

The scheme table also wants a line in the `CLAUDE.md` seam entry, since
"pikuri-lsp reads only `file:` paths and one enumerated server-private
scheme, never the network" is an invariant someone could break by adding
a row without noticing.
