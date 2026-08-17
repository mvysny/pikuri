# LSP client — research notes

Split out of [`../lsp.md`](../lsp.md), which keeps the status and the
worklist. This file is the lab notebook: six independent throwaway
clients, a rubygems survey, and one shipped client read off its schema.
Nothing here is a decision — the decided design is in
[`design.md`](design.md).

**The labels are stable ids, cited from both other files.** Findings are
numbered per source — `finding 1`–`finding 9` for the first Ruby runs,
`J1`–`J9` for jdtls, `H1`–`H6` for the type-hierarchy run, `S1`–`S10` for
the document-sync/anchor run — in *discovery* order, not reading order.
Don't renumber them to tidy a sequence.

## How the protocol actually works

JSON-RPC 2.0 over the child's stdin/stdout, with LSP's own framing:

```
Content-Length: 87\r\n
\r\n
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{…}}
```

Header block, `\r\n\r\n`, then exactly N bytes of JSON. No newline
delimiting — read the header, then `read(n)`.

Three message shapes: **request** (has `id`, expects a response),
**response** (echoes the `id`), **notification** (no `id`). The channel
is bidirectional and asynchronous — the server sends *you* requests
(`window/workDoneProgress/create`, `workspace/configuration`) and can
block waiting for your reply. So the client is a demux loop keyed on
`id`, not a call-and-read-next-message.

Lifecycle: `initialize` (request) → `initialized` (notify) → work →
`shutdown` (request) → `exit` (notify).

The entire non-obvious core, which is also roughly the whole reason a
gem is cheap here:

```ruby
def write(msg)
  body = JSON.generate(msg)
  @stdin.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
  @stdin.flush
end

def read
  headers = {}
  while (line = @stdout.readline("\r\n").chomp("\r\n")) != ''
    k, v = line.split(': ', 2)
    headers[k.downcase] = v
  end
  JSON.parse(@stdout.read(Integer(headers.fetch('content-length'))))
end

def request(method, params = {})
  write(jsonrpc: '2.0', id: (@id += 1), method:, params:)
  loop do
    msg = read
    return msg if msg['id'] == @id && (msg.key?('result') || msg.key?('error'))

    write(jsonrpc: '2.0', id: msg['id'], result: nil) if msg['id'] && msg['method']
  end
end
```

## Findings from live runs against this repo

Two throwaway clients, one against `rubocop --lsp`, one against
`ruby-lsp` 0.26.10 driving the pikuri monorepo. (The scripts were
scratchpad-only; the findings are the durable part.) Later re-run
through Claude Code's own `LSP` tool against the same repo and the same
`ruby-lsp` 0.26.10 — a third, independent client. Where that run
confirmed or corrected a finding it is marked inline; what it revealed
about *that implementation* is under Prior art below.

**1. Capabilities are computed per workspace, not per binary.**
The killer finding. Same `ruby-lsp` binary, same version:

| capability | `rubocop --lsp` | `ruby-lsp` (in *this* repo) |
| --- | --- | --- |
| `documentFormattingProvider` | ✅ | — |
| `executeCommandProvider` | ✅ | — |
| `codeActionProvider` | ✅ | ✅ |
| `definitionProvider` / `referencesProvider` / `workspaceSymbolProvider` | — | ✅ |
| `hoverProvider` / `completionProvider` / `renameProvider` / `typeHierarchyProvider` / … | — | ✅ (23 total) |

`ruby-lsp` reports **no** formatting capability here purely because
pikuri's `Gemfile`/`Gemfile.lock` contain no rubocop, so it detected no
formatter (`window/logMessage`: "Auto detected formatter: none") and
didn't advertise it. In a rubocop-bundled project that row flips.
Consequence: **capability knowledge must come from the `initialize`
response for *this* workspace**, never from a matrix keyed on which
server binary was spawned.

But that check belongs at **dispatch time, not schema-construction time
— the `operation` enum stays hardcoded.** With several servers
registered (Ruby *and* Java, say) their capability sets differ, and
*which* server applies isn't known until a call names a file; routing is
by extension. A schema computed from capabilities would therefore have
to advertise the union anyway, and would need rebuilding whenever a
server restarts or a workspace gains a formatter — a moving tool
description is worse than a static one the model can learn. So: static
enum (the superset pikuri supports) → route on the file's extension →
consult *that* server's advertised capabilities → clean refusal string
if it lacks the operation. This is the one place `Mcp::Servers`'
synthesize-tools-from-what-the-server-reports shape does *not* transfer:
one MCP server owns its own tool names, whereas here many servers share
one tool and the file picks the server.

**2. Asking before the index is built returns `[]`, not an error.**
My first run fired `textDocument/definition` immediately after
`initialized` and got `{"id":2,"result":[]}` — a *successful* empty
answer, with the `$/progress` `begin` for indexing arriving afterward.
For an agent this is the worst failure mode available: the model
concludes the symbol has no definition and proceeds on a false premise.
The client must block on the indexing-progress `end` notification before
its first query, and should distinguish "not indexed yet" from "no
results" in what it hands the model. Non-uniform per method, too —
`references` *did* return results pre-index in that same run, so gate on
progress rather than trusting any one method.

**3. Definition returns candidates, not an answer — and leaves the
workspace.** Cursor on `workspace.resolve_for_read(path)` at
`pikuri-workspace/lib/pikuri/workspace/read.rb:165`:

```
-> pikuri-workspace/lib/pikuri/workspace/filesystem.rb:218   # Filesystem#resolve_for_read
-> pikuri-workspace/lib/pikuri/workspace/filesystem.rb:415   # AllowAll#resolve_for_read
-> …/gems/pikuri-workspace-0.0.6/lib/pikuri/workspace/filesystem.rb:338
-> …/gems/pikuri-workspace-0.0.6/lib/pikuri/workspace/filesystem.rb:505
```

Ruby dispatch is dynamic, so both overrides come back — present as a
ranked list, never as "the definition". And note hits 3 and 4: ruby-lsp
indexes the *bundle*, and this monorepo's gems are also published gems,
so the agent gets pointed at a **stale released copy of the very file it
is editing**. Those paths were walked to by the server, never supplied
by the model, so they reach no `resolve_for_read` — `D-walked-path-denylist`
territory: results must go through `Filesystem#denied?`, plus almost
certainly a workspace-root confinement on top.

Re-checked with the third client, and worth recording because the
obvious reading of that run is wrong. There, `goToDefinition` on
`resolve_for_read` returned *only* the two in-repo hits — which looks
like root confinement. It isn't: `goToDefinition` on `Faraday` returned
45 locations, every one under `~/.local/share/…/gems/`. The stale
`pikuri-workspace-0.0.6` copies are absent from that run for an
unrelated reason (the top-level `Gemfile` wires siblings via
`gemspec path:`, so the bundle index points at the working tree), and
the released gem is installed either way. Conclusion: **no shipped
client confines results.** Both the `denied?` pass and the root
confinement are ours to write, with no prior art to inherit — which also
removes the last reason to hope a bridge would handle it.

**4. Two response shapes.** ruby-lsp answers with `LocationLink`
(`targetUri` / `targetRange` / `targetSelectionRange`), not plain
`Location` (`uri` / `range`); servers choose based on the `linkSupport`
capability the client declares. Parse both. (My first parser crashed on
exactly this.)

**5. `workspace/symbol` is fuzzy.** Query `resolve_for_read` returned
`resolve_for_write`, `resolve`, and `oversized_root_refusal` — matched on
scattered letters. Any name→position hop must filter for exact-name hits
before feeding positions onward.

**6. `references` is high-volume.** 40 hits for `resolve_for_read`: 4 lib
call sites, 2 declarations, **34 spec hits**. Raw output is a lousy
observation — needs a cap and lib/spec grouping. The cap has a precedent to
copy ({Pikuri::Workspace::Search::Grep::MAX_BYTES}, 50 KB, head-truncated
with a marker); the **grouping does not** — `Grep` hands rg's output
through and groups nothing, so that half is new work here.

The third client reproduced that split to the exact number, uncapped and
ungrouped. And it is not only `references`: `definition` and `hover` on
a **constant** are worse, for a Ruby-specific reason. Every file that
reopens `module Faraday` is a definition of it, so `goToDefinition` on
`Faraday` returned 45 locations and `hover` returned a wall of 45 doc
links *ahead of* the docstring. Capping and grouping must cover all
three operations, and the constant case wants the most aggressive cap —
a reopened namespace's "definitions" are nearly all noise, and the one
the model wants (`faraday.rb`) is not distinguishable by position in the
list.

**7. `positionEncoding` is negotiable.** Offer
`general.positionEncodings: ["utf-8","utf-16"]`; ruby-lsp picks `utf-8`,
which removes the UTF-16-code-unit offset conversion. Fall back to
converting if a server insists on utf-16 (the 3.17 default).

**8. Hover is rich on constants and empty on methods.** `hover` on
`Pikuri::FileType` returned the constant, a definition link, and the
*entire yardoc class comment* — both responsibilities, the two
`Pathname` conveniences, the "Deliberate non-goals" list. `hover` on the
`def resolve_for_read` line returned nothing at all. ruby-lsp resolves
documentation through its constant index; method-level hover is simply
not the same feature. Consequence: hover's value is split down the
middle, and in a codebase whose yardoc *is* the declared source of
truth, the constant half answers "what is this class for?" in one call
without reading a file — a different operation from `read`, not a third
spelling of it.

**9. What ruby-lsp does *not* advertise, exactly.** Finding 1 counted the
capabilities without naming them, and the absences turn out to decide the
operation enum. (The two counts differ only in units, re-checked against a
live `initialize` in this repo: **23 capability keys, of which 20 end in
`Provider`**; the other three are `experimental`, `positionEncoding` and
`textDocumentSync`.) Present: `definition`, `references`, `workspaceSymbol`,
`hover`, `documentSymbol`, `completion`, `rename`, `diagnostic`,
`typeHierarchy` (20 providers). **Absent: `typeDefinitionProvider`,
`implementationProvider`, `declarationProvider`,
`callHierarchyProvider`** — and calling one anyway returns
`Method not found: textDocument/typeDefinition`, i.e. the raw protocol
error a shipped client leaks (Prior art) rather than a clean refusal.
Same run re-confirmed finding 7's other half: ruby-lsp answered
`positionEncoding: "utf-8"`, accepting the offer jdtls ignored, so both
branches of that negotiation are now verified against real servers.

## Findings from a live jdtls run

A fourth throwaway client, against `jdtls` 1.58 / JDK 25, on three
fixtures: a two-file plain-Java project, and a copy of the `vaadin-boot`
Gradle multi-module repo (copied to a scratch dir precisely because a
jdtls import writes `.project` / `.classpath` / `.settings/` into the
project directory) run both cold and warm. This settles the readiness
open question, and reverses one deferral.

(The `J<n>` labels are stable ids in discovery order, cited from all over
this note; the paragraphs below are grouped by topic instead, so they do
not run in numeric order. Don't renumber them to tidy the sequence.)

**J1. `$/progress` from jdtls is opt-in via *our* capability.** Declare
`window.workDoneProgress: true` and tokens flow; omit it and jdtls emits
**zero** `$/progress` messages, narrating startup only through
`language/status` — a custom notification outside the LSP spec. So the
readiness signal is not merely per-server, it is contingent on what the
client asked for.

**J2. There is a usable readiness edge, and it is a long-lived token.**
Cold import of the Gradle repo: an `Initialize Workspace` token opened at
2.08s and stayed open for the entire 74-second import, ending at 76.43s
together with `language/status` `ProjectStatus OK` and `Started "Ready"`;
`ServiceReady` followed 0.14s later, and the first correct answer 1.5s
after that. So the token's `end` is a good edge. But it is *bracketed* by
transient tokens — the plain project produced eight (`Building`,
`Check JDK Index`, `Synchronizing projects` ×2 concurrent, `Detect
installed JVMs`, `Validate documents`, …), several beginning and ending
inside the same millisecond, and there **all** tokens were closed 0.9s
before the server could answer. "No tokens open" is therefore a false
ready-edge; a short settle-debounce is what makes the rule usable, and a
debounce is not the timeout we removed — it never abandons the wait.

**J3. The gate is a ruby-lsp workaround, not a universal need — jdtls
defers instead of lying.** Every `textDocument/definition` sent during
that 74-second import got *no response at all*; the whole backlog flushed
at 77.87s with correct answers. Finding 2's catastrophic early-`[]` is a
ruby-lsp behaviour, not LSP's. Since a false-early gate is harmless
against a server that defers and essential against one that doesn't, one
generic quiescence-plus-debounce gate covers both — **and the feared
per-server readiness predicate is not needed.** The open question closes
without a config knob.

**J4. `initializationOptions` stops being deferrable.** Navigation to any
library symbol returned `0 location(s)` — silently, with no error, and
with **empty diagnostics on the file**, so the classpath was fine and it
compiled cleanly. It is not a readiness or resolution failure: jdtls
withholds library definitions unless the client declares
`initializationOptions.extendedClientCapabilities.classFileContentsSupport`,
another non-spec extension. Declaring it flips `LoggerFactory` from
nothing to a hit, in the same warm 7.7s. An agent without it concludes
"slf4j has no definition" — finding 2's false premise by a different
route. This is the tripwire the `init_options:` deferral named, tripped
before shipping.

**J5. A Java library definition is not a file.** That hit came back as
`jdt://contents/slf4j-api-2.0.18.jar/org.slf4j/LoggerFactory.java?=…` —
a virtual URI whose contents are fetched with jdtls's own
`java/classFileContents` request. `Filesystem#denied?` cannot be applied
to it and the model cannot `read` it. So the confinement open question
has one arm forced: for non-`file:` results the tool must return
*content*, or drop them and forfeit library navigation entirely.

**J7. `java/classFileContents` works, returns a bare String, and is
huge.** Called with the `jdt://` URI from J5 it answered in 10ms with
**22,639 bytes** — the complete attached source of `LoggerFactory.java`
from the sources jar. Two consequences: the reply is a plain String, not
the `{text:}` object a spec-shaped request would return, so a generic
hook must accept both; and a whole class is far too much for one
observation, so the content path slices to the target range.

**J9. `typeDefinition` and `implementation` work, and neither is
redundant.** A Maven fixture with `var names = new ArrayList<String>();`:
`typeDefinition(names)` → `java.util.ArrayList` in `java.base`, while
`definition(names)` → the local declaration in `Main.java`. **Different
answers to different questions**, and with `var` the type appears nowhere
in the source, so nothing else — hover aside — can recover it and grep
certainly cannot. `typeDefinition` on `Greeter g = new LoudGreeter()`
returns the *declared* type. `implementation` resolves an interface to
its implementor and works at method level too (`greet` → the override in
`LoudGreeter`). This is the evidence that a statically typed language
needs operations a dynamic one has no use for.

Also visible in that run: the `jdt://` URI for `ArrayList` is **~300
characters**, its query string encoding the whole classpath entry
(jrt-fs.jar path, javadoc location, `maven.pomderived`, …). Never show
one to the model; render it as `java.util.ArrayList (java.base)`.

**J8. `workspace/symbol` searches inside jars — the one thing grep can
never do.** A Maven fixture with commons-lang3 on the classpath:
`workspace/symbol("StringUtils")` returned 5 hits — commons-lang3's, the
JDK compiler's internal one, a jcef jar's — every one a `jdt://` URI
inside a binary jar. The decisive case is **`ArrayUtils`, which appears
nowhere in the source and is never imported**: 2 hits anyway. Grep over
the project finds nothing and grep over `~/.m2` finds unreadable binary.
The same argument holds for Ruby without the binary part, because
pikuri's `Grep` is workspace-scoped while the server's index covers the
whole bundle — there the hits are `file:` URIs and readable today. Prefix
queries work and are noisy (`StringUt` → 11 hits, including
`StringUTF16` and `StringBufferInputStream`), which is finding 5's
fuzziness confirmed on a second server.

**J6. Warm start is 10× cheaper, which settles the data-dir question.**
Same repo, same `-data`: 78s cold, 7.7s warm. `Paths.cache` (shared,
persistent) over `Paths.new_temp`, as leaned.

Two corrections to the Ruby findings above, both from this run:

- **Finding 7 understates it.** jdtls answered `positionEncoding: nil` —
  it ignored our `utf-8` offer and stayed on the 3.17 utf-16 default. The
  UTF-16 offset conversion is therefore mandatory code exercised by one
  of the two shipped examples, not a fallback for a hypothetical server.
- **`didOpen` is a precondition nowhere stated.** No query answers until
  the document has been opened with its full text. The `lsp` tool takes a
  path and the model never "opens" anything, so the tool opens it — and
  the file it opens must be the one on disk, which is a read the
  `Workspace` seam should route.

## There is no Ruby LSP client gem

Checked rubygems:

- **`lsp-client`** (0.0.1) — an *empty gem*. Its `data.tar.gz` is 35
  bytes; zero files, no homepage, no source URI. A name placeholder.
- **`language_server-protocol`** (283M downloads) — the protocol SDK:
  framing + typed structures/constants. Its `Io::Reader` is ~20 lines
  (`gets("\r\n\r\n")`, `read(n)`, `JSON.parse`) and is direction-agnostic,
  so it *works* client-side — but it supplies no lifecycle, no id
  correlation, no capability handling, no spawn, and its reader is a
  blocking whole-stream callback loop shaped for a server main loop.
- Everything else (`language_server`, `ruby_language_server`,
  `yoda-language-server`, `rubocop-language-server`, `solargraph`) is a
  **server**.

Structural reason: LSP clients live in editors, and editors are written
in TypeScript / Rust / Emacs Lisp / Vimscript. Nobody needed a Ruby
client until agents wanted language intelligence.

So we own the client outright — which is fine, it's the ~130 lines
sketched above plus policy, and it suits "readable end-to-end in an
evening". **Don't take the `language_server-protocol` dependency** for
40 lines of framing whose reader shape we'd fight.

## Prior art: what Claude Code's own LSP tool looks like

Read straight off its tool schema (it went direct too, with servers
registered as *plugins* — `jdtls-lsp`, `kotlin-lsp` — so: direct client,
pluggable server registry):

```
operation: enum[goToDefinition, findReferences, hover, documentSymbol,
                workspaceSymbol, goToImplementation, prepareCallHierarchy,
                incomingCalls, outgoingCalls]
filePath:  string   (required, all operations)
line:      integer  (required, 1-based, "as shown in editors")
character: integer  (required, 1-based, "as shown in editors")
query:     string   (workspaceSymbol only)
```

Run against this repo on the same `ruby-lsp` 0.26.10, it behaves as
follows — the parts worth knowing before copying it:

- **1-based in *and* out, confirmed.** Input `line: 218, character: 11`
  landed on `def resolve_for_read` at a 6-space indent; output reported
  `218:11`, and `415:13` for the 8-space-indented override. The
  translation is symmetric, which is the property that matters — a
  position it prints can be fed straight back in.
- **The degrade string is real.** `goToDefinition` on `CLAUDE.md` →
  `No LSP server available for file type: .md`. So it *does* route on
  extension — the mechanism the multi-server design needs.
- **But there is no capability check on the routed-to server.** Three of
  the nine enum operations are unbacked by ruby-lsp and leak the raw
  protocol error instead of degrading: `goToImplementation` →
  `Method not found: textDocument/implementation`; `prepareCallHierarchy`
  and `incomingCalls` → `Method not found:
  textDocument/prepareCallHierarchy`. Extension routing without the
  capability half. Pikuri should reuse the `.md` refusal's shape here —
  same static enum, one more gate.
- **No indexing gate.** The first `goToDefinition` after startup returned
  `No definition found. This may occur if the cursor is not on a symbol,
  or if the definition is in an external library not indexed…` — finding
  2's false-premise answer, verbatim — while a `hover` issued in the same
  batch correctly failed with `server is starting`. The readiness signal
  exists and one path ignores it. **The single most important thing not
  to copy.**
- **No confinement, no capping.** See findings 3 and 6.

Re-run later against a **Java** project (`vaadin-boot`) from a session
rooted elsewhere, which produced the sharpest lesson of the lot:

- **Its enum has no `typeDefinition`.** Confirmed verbatim from the
  schema — nine operations, and the one a statically typed language most
  needs is not among them, while `documentSymbol` is. Independent support
  for pikuri including it (J9) and dropping `documentSymbol`.
- **`line` and `character` are required for every operation**, including
  `workspaceSymbol`, which needs neither.
- **`goToDefinition` on a library class fails while `hover` on the very
  same position succeeds.** Re-run correctly rooted (headless, from the
  project dir): `goToDefinition` on `LoggerFactory` returned no location,
  yet `hover` there returned the FQN, the full javadoc prose, and a
  provenance line — `Source: slf4j-api-2.0.18.jar`. J4 reproduced in a
  shipped client on a real project: absent `classFileContentsSupport`,
  jdtls withholds library *locations* but not library *text*. **Hover is
  the working fallback** — "what is this library class" is answerable for
  Java without 3.18 and without any content request at all. Pikuri does
  not stop there (it declares the flag and reads the resulting `jdt:` URI
  via the scheme table), but this stays the floor: even a
  half-configured Java entry answers the *what*, and only the
  show-me-the-source half depends on the rest.
- **`findReferences` groups by file.** 9 references across 6 files, a
  count header, one group per repo-relative path, bare `Line L:C` entries,
  no snippets. So it *does* group — by file, which is not finding 6's
  lib/spec split — includes the declaration among the references, and
  leaves lines unsorted within a group (241, 73, 334). No cap is
  demonstrated either way; 9 results would not reach one.
- **An out-of-project file answers "No definition found".** Both probes
  returned that string; the *actual* cause appeared only as an editor
  diagnostic — `VaadinBootBase.java is a non-project file, only syntax
  errors are reported` — because the server had been rooted at the
  session's own workspace, not the file's project. So the honest reason
  existed and went to a side channel, while the model-facing answer was
  the false premise of finding 2 in yet another disguise. **pikuri needs
  a distinct refusal for out-of-project**, never "no definition found" —
  and it is a third argument for tying `rootUri` to the `Workspace` root
  and refusing paths outside it up front, where the reason is still known.

Worth stealing:

- **One tool, an `operation` enum — not nine tools.** Nine `lsp_*`
  entries is a real prompt-budget cost. Tension with the naming
  convention in [`../../CLAUDE.md`](../../CLAUDE.md) (a `foo_*` prefix marks a
  family sharing one backing resource, which LSP genuinely is); the
  evidence still favours the single tool, and `Tool::Parameters`
  validates enums strictly so nothing is lost on safety. The enum also
  stays **static** — per finding 1, with several servers registered it
  can't track any one server's capabilities anyway.
- **1-based line *and* character.** LSP is 0-based on both; translate at
  the boundary, because the model reads files through `Read`, which
  prints 1-based line numbers. This is the highest-value line of code in
  the whole tool.
- **Clean degrade when no server is configured.** Asked for a `.rb`
  definition on a machine with only Java/Kotlin servers registered, it
  returned `No LSP server available for file type: .rb` — a
  model-readable string, exactly pikuri's "errors the LLM can react to"
  rule.

Worth arguing with:

- ~~`filePath` is required even for `workspaceSymbol`, which takes no
  position in LSP — it's the server-routing selector. Principled, still a
  wart; consider routing on workspace root instead.~~ **Withdrawn.**
  Finding 1's multi-server argument vindicates it: once several servers
  can be registered, *every* operation needs a routing selector, and a
  file path is the only one the model reliably has. Routing on workspace
  root fails precisely in the mixed-language repo that makes a registry
  worth having.

  **But pikuri reaches a different conclusion from the same argument**,
  and the difference is the parameter shape, not the reasoning. Claude
  Code's required parameter is a *position* (`line` + `character`), and a
  position is meaningless without the file it indexes into — so for that
  shape a required `filePath` is forced, and the wart is unavoidable.
  Pikuri's required parameter is a **name** (see "The tool surface" in
  [`design.md`](design.md)),
  which is meaningful on its own, so a missing `file` is answerable rather
  than fatal: fan out to every registered server and merge. `file` is
  therefore an *optional* disambiguator here — routing selector when
  given, fan-out when absent — and that is not a rejection of the
  argument above but its consequence under a different required
  parameter. What the parameter description owes the model is which of
  the two it is doing.
- It exposes `workspaceSymbol` raw and lets the model chain it into
  `goToDefinition`. That works because the model is strong. **Pikuri's
  default is local llama.cpp**, and small local models chain multi-call
  sequences unreliably — a real reason for pikuri to collapse the
  name→position hop *inside* the tool where Claude Code doesn't.


## Findings from a type-hierarchy run against ruby-lsp

A fifth throwaway client, `ruby-lsp` 0.26.10 / Ruby 3.3.11, against this
repo — the run the two hierarchies' promotion was waiting on. Ready in
5.4s behind one
progress token, `positionEncoding: "utf-8"`, `typeHierarchyProvider: {}`
advertised, `callHierarchyProvider` and `implementationProvider` absent
(finding 9 reproduced). Targets were picked for known in-repo ancestry:
`Pikuri::Tool` (14 subclasses), `Agent::Listener::Base` (4),
`Workspace::Confirmer` (2), plus `Confirmer::Terminal` and
`Workspace::Read` upward and `Workspace::Extension`'s `include`.

Where a finding was confirmed in ruby-lsp's own source that is said so —
those are the ones that will not change by asking differently.

**H1. `typeHierarchy/subtypes` is an unimplemented stub, and the provider
is advertised anyway.** Every call returned nothing: `Pikuri::Tool` → 0,
`Listener::Base` → 0, `Workspace::Confirmer` → 0, from a `prepare` item
that `supertypes` then answered correctly, so the item was valid and the
anchor was right. The reason is in `server.rb:1203`:

```ruby
def type_hierarchy_subtypes(message)
  # TODO: implement subtypes
  # The current index representation doesn't allow us to find the children of an entry.
  send_message(Result.new(id: message[:id], response: nil))
end
```

So this is finding 2's silent-empty in its purest form — not a readiness
problem, not an anchor problem, not fixable by indexing harder: an
advertised capability wired to a stub. Note the reply is **`nil`, not
`[]`**, which a parse layer has to accept. And a *capability gate cannot
catch this*, which is the part that matters for the design: the gate reads
`typeHierarchyProvider`, and ruby-lsp advertises it truthfully for
`supertypes`. One provider key covers both directions, so no declaration
distinguishes the half that works from the half that is a TODO.

**H2. `supertypes` works, and namespace reopening dominates the result.**
`supertypes(Pikuri::Workspace::Read)` → **14 results, every one named
`Pikuri::Tool`** — one per file that reopens `class Tool` / `module Tool`
as a namespace wrapper (`calculator.rb:4`, `fetch.rb:4`, `parameters.rb:8`,
`brave.rb:8`, …), with the real declaration `tool.rb:35` last in the list.
`supertypes(Confirmer::Terminal)` → 2, both `Pikuri::Workspace::Confirmer`
(`terminal.rb:9`, the reopening; `confirmer.rb:67`, the declaration). This
is finding 6's reopened-constant noise on a fourth operation, and the
`Read` case is the sharper one: 14 rows carrying one fact, with the row a
human wants ordered last. Grouping by name and preferring the file whose
path matches the constant is the obvious pass; capping alone would cut the
useful row.

**H3. `supertypes` leaves the workspace by default, into places nobody
checked out.** `supertypes(Pikuri::Tool)` → 6 results, all `Object`, from
`rbs-4.1.3/core/object.rbs`, `psych/core_ext.rb`, `hashery-2.1.2`,
`json-2.21.1` and `racc-1.8.1` (twice). Every one is out-of-root, every
one is useless to an agent, and they arrive on a query about a class in
the workspace. Independent support for the unconditional
`untrusted: :hard` leg — and note *which* files: an `.rbs` core stub and
four unrelated gems that merely reopen `Object`.

**H4. Module ancestry is not walked — the specific hope, and it is a
no.** `prepare` on `include Pikuri::Agent::Extension` resolves the module
cleanly (1 item, `Pikuri::Agent::Extension`), and then **both**
`supertypes` and `subtypes` return 0. So "who includes this module?" is
unanswerable, and so is `include` / `prepend` ordering — the one thing the
hierarchy was promoted for, as what grep genuinely cannot reconstruct. Between
this and H1, ruby-lsp's type hierarchy answers exactly one question:
*what is above this class?*

**H5. The keyword anchor returns zero items — 6 cases out of 6.**
`prepareTypeHierarchy` at the first non-space column of the declaration
line returned `0 item(s)` for all six targets; at the column of the symbol
text itself it returned exactly `1 item(s)` for all six. Measured offsets:
`class Tool` keyword 2 / symbol 8, `class Base` 6 / 12, `class Confirmer`
4 / 10, `class Terminal < Confirmer` 6 / 12, `class Read < Pikuri::Tool`
4 / 10, `include Pikuri::Agent::Extension` 6 / 29 (the last segment of the
path, which resolved fine). And `workspace/symbol`'s own
`location.range.start.character` for `class Tool` is **2** — the keyword —
so feeding a symbol hit's range straight back in is the failure, not a
shortcut. So the `locate(text, symbol)` helper is load-bearing, and its
absence fails silently. (S8 has the jdtls half, which disagrees in both
details and needs the same helper.)

**H6. `workspace/symbol` matches on the *fully qualified* name, so a bare
namespaced class name is unreachable.** The headline number: query
`"Confirmer"` → 25 hits, **0 of them a class or module**, 0 exact-name;
`"Base"` → 20 hits, 0 classes; `"Terminal"` → 10 hits, 0 classes; `"Tool"`
→ 81 hits, 14 classes, none of them `Tool` itself (they are
`Pikuri::Tool::Search::Exa`, `Pikuri::Tool::Parameters`, …). Query the FQN
`"Pikuri::Workspace::Confirmer"` and it works: 471 hits, 2 exact.

Both halves are deliberate in the source. `workspace_symbol.rb` sets
`name: entry.name` — the FQN — with a comment saying why ("to allow people
to search for fully qualified names… If we only included the short name
`Bar`, then searching for `Foo::Bar` would not return any results"), so an
exact-name filter must compare the **last `::` segment**, never `name`.
And `index.rb:199` scores with `DidYouMean::JaroWinkler` over the
`::`-stripped, downcased FQN against `ENTRY_SIMILARITY_THRESHOLD = 0.7`,
which is prefix-weighted — so a short query against a long namespaced name
falls off a cliff:

| query | indexed name | Jaro-Winkler | vs 0.7 |
| --- | --- | --- | --- |
| `Tool` | `pikuritool` | **0.000** | dropped |
| `Confirmer` | `pikuriworkspaceconfirmer` | **0.455** | dropped |
| `Terminal` | `pikuriworkspaceconfirmerterminal` | 0.460 | dropped |
| `Base` | `pikuriagentlistenerbase` | 0.529 | dropped |
| `Confirmer` | `@confirmer` | 0.967 | kept |
| `Pikuri::Workspace::Confirmer` | `pikuriworkspaceconfirmer` | 1.000 | kept |

So this is not ranking noise that a bigger cap would fix — the entry is
below threshold and never returned, while a same-named *instance variable*
scores 0.967 and is. In a codebase where every class is namespaced, that
means a bare `symbol` never resolves a class, and the tool's answer is a
clean "not found": finding 2's false premise reached through the design's
own headline parameter. Finding 5 recorded `workspace/symbol` as fuzzy in
the too-many direction; this is the too-few direction, and it is the
consequential one.

## Findings from a document-sync and anchor run, both servers

The run the document-sync question asked for, and the first one driving
**both** servers from the same client: `ruby-lsp` 0.26.10 / Ruby 3.3.11
against a throwaway two-file Ruby project, and `jdtls` 1.58 / JDK 25
against a throwaway two-file plain-Java project (`Greeter.java` +
`Main.java`, warm `-data`, ready in 3.1s). Both fixtures were built so a
stale answer is distinguishable *twice over* — every edit renames a method
**and** shifts it by three lines, so memory-vs-disk shows up in the name
and in the position independently.

Where a finding was confirmed in a server's own source that is said so;
those are the ones that will not change by asking differently.

**S1. A rangeless full-text `didChange` is honoured by jdtls and is a
crash on ruby-lsp — same notification, same declared sync kind.** Both
servers advertise `textDocumentSync.change: 2` (incremental). Sending the
whole-document variant (`contentChanges: [{text: …}]`, no `range`) leaves
jdtls's copy correctly updated, and on ruby-lsp raises inside
`document.rb:98` — `push_edits` reads `edit[:range][:start]`
unconditionally, so a rangeless edit is a `NoMethodError`. The document
keeps its **old** text, and because a notification has no reply channel the
only report is a `window/logMessage` line the client is free to ignore
(`"Error processing textDocument/didChange: …"`). What the *model* would
see is the next query: a position valid in the new text answers
`-32602 InvalidLocationError` with a raw Ruby backtrace as the message.

**S2. Sync the document and you can still desynchronize the index —
ruby-lsp updates one and not the other.** A whole-document *ranged*
change (range = 0:0 → end of file, text = the new file) is honoured by both
servers for the document itself: `documentSymbol` reported the renamed
method immediately. But on ruby-lsp `definition` on that same renamed
method then returned `[]`, because method resolution goes through the index
and the index had not moved: `workspace/symbol` still reported the *old*
name at the *old* line. The reason is a heuristic in the server's own
source — `RubyDocument#should_index?` reindexes only when
`position_may_impact_declarations?(last_edit.range.start)`, and the start of
a whole-file replace is 0:0, which in an ordinary Ruby file is the
`# frozen_string_literal` comment, not a declaration node. So the
optimization that makes editor typing cheap makes whole-file replacement
invisible, and the failure is finding 2's silent empty produced *by our own
sync scheme*.

**S3. `didOpen` is not universally a precondition — it is jdtls-specific,
and per-operation even there.** ruby-lsp answered `definition` and
`documentSymbol` correctly for a document that was never opened, because
`Store#get` reads the file from disk (`File.binread`, version 0) for any URI
it does not hold. (The *index* is a separate matter — see S4.) On jdtls the
same `definition` returned `[]` while `documentSymbol` on that same unopened
file worked. J4's correction ("`didOpen` is a precondition nowhere stated")
therefore holds for jdtls's semantic operations and not for ruby-lsp at
all — one more capability that cannot be read off the handshake.

**S4. On ruby-lsp the index refreshes as a *side effect of a
documentSymbol-family request*, not from any notification.** A `.rb` file
created after boot is invisible to `workspace/symbol` (0 hits) however long
you wait; issue one `documentSymbol` against it and it becomes 1 exact hit.
`server.rb:495` is why — the combined-request handler reindexes the
document while serving `documentSymbol` / `foldingRange` / `codeLens` /
`inlayHint`. Two consequences: an operation nobody would call for its
result can be the only way to freshen the index, and any measurement of
index freshness has to control for which request came first.

**S5. Re-sending `didOpen` with the current disk text before every call
works on both servers, and is the only mechanism that does.** It is
spec-forbidden — LSP says a document must not be opened twice — and neither
server minds: both replaced their copy wholesale, both then resolved the
renamed symbol at its shifted position, and on ruby-lsp the index flipped
too (new name 1 exact, old name 0). No version bookkeeping, no digest
tracking, no `didClose`, and the text it needs is the text the tool already
read for `locate`.

**S6. `didClose` resyncs ruby-lsp and does nothing for jdtls.** On
ruby-lsp `didClose` deletes the store entry, so the next request re-reads
disk — the fresh name and the shifted position both came back. jdtls kept
answering its pre-close in-memory copy: `documentSymbol` still reported the
old method name with the disk holding the new one, and `definition` at the
new declaration's position returned `[]`. So the close-and-forget scheme is
not portable, which is what promotes S5 from "one option" to "the policy".

**S7. The spec's own out-of-band channel is ignored by both.**
`workspace/didChangeWatchedFiles` with a `CHANGED` event for the edited
file changed nothing on either server while the client owned the URI.
ruby-lsp's source states the rule outright —
`index.handle_change(uri, content) unless @store.key?(uri)` — i.e. a
client that has opened a document is *expected* to be the authority for it,
which is exactly the assumption an agent that writes straight to disk
breaks.

**S8. jdtls anchors forgivingly where ruby-lsp is strict — for some
operations.** Probing every token of `public class Greeter {` and
`    public String greet(String name) {`: `prepareTypeHierarchy` returned
1 item at **every** column including the `public` and `class` keywords
(ruby-lsp returned 0 at the keyword in 6 cases out of 6, H5), while
`definition` returned 0 at both keyword columns and 1 at the symbol's own
column. And `workspace/symbol`'s reported column is the **symbol** column
on jdtls (13, where `Greeter` starts) against ruby-lsp's **keyword** column
(2). So the two servers disagree about both halves of H5, in opposite
directions, per operation — and `locate(text, symbol)` is load-bearing on
both, for different reasons.

**S9. Anchoring on the wrong token is not merely empty — it can be
80,609 results.** `references` at the return-type `String` of
`public String greet(String name)` returned **80,609** locations; at the
parameter type, the same 80,609; at `greet`, 2. Finding 6's volume problem
has no ceiling, and a cap is not an optimization.

**S10. jdtls's `workspace/symbol` returns types only, so a Java *method*
is unreachable by name.** Query `"shout"` (a method defined in the
fixture) → **0 hits**. Query `"greet"` → 1 hit, which is the *class*
`Greeter` matched on a substring. `"Greeter.greet"` and `"greet(String)"`
→ 0 each. Types work fine (`"StringUtils"` → 2, both inside jars, J8
reproduced). This is H6's Ruby problem inverted: there a bare name missed
because the index stores fully-qualified names, here a method name misses
because the index stores no methods at all. The name→position collapse
therefore cannot reach a Java method, which is the strongest argument yet
for `documentSymbol` — the in-file outline is how you find `shout` without
being handed a column.
