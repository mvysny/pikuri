# LSP client — language intelligence for the coding agent

Status: **investigated, not built.** Protocol mechanics are settled and
verified against live servers — ruby-lsp, rubocop, a shipped client, and
now jdtls against a real Gradle multi-module repo; the direct-vs-MCP fork
is decided in principle; the registry entry's field list and the
progress-delivery mechanism are drafted (Configuration). The tool
surface is settled — three name-based operations, and no column ever
asked of the model — as are what an out-of-root result becomes and how
this gets tested. One implementation-level question is parked for the
next session; see "Open — revisit in an upcoming session".

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
observation — needs lib/spec grouping and a cap, like `Grep` already does.

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

## Findings from a live jdtls run

A fourth throwaway client, against `jdtls` 1.58 / JDK 25, on three
fixtures: a two-file plain-Java project, and a copy of the `vaadin-boot`
Gradle multi-module repo (copied to a scratch dir precisely because a
jdtls import writes `.project` / `.classpath` / `.settings/` into the
project directory) run both cold and warm. This settles the readiness
open question, and reverses one deferral.

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

## Direct vs MCP bridge — direct

Maintained bridges exist and are real: isaacphi/mcp-language-server,
Tritlo/lsp-mcp, bug-ops/mcpls, ProfessioneIT/lsp-mcp-server. Their pitch
is correct (a semantic answer costs ~50–200 tokens vs. dumping files),
and since `pikuri-mcp` exists, using one would be a *registry entry* —
config, not code. Genuine upside: zero implementation cost, every
language at once, someone else absorbs protocol drift.

Rejected anyway, for four reasons:

1. **The transport isn't the hard part.** Both paths terminate at the
   same `ruby-lsp` process over the same stdio JSON-RPC; MCP just adds a
   hop and a process. The actual difficulties — indexing readiness,
   capability gating, name→position, result capping, coordinate
   conversion — get solved somewhere either way, and via a bridge you
   inherit someone else's answers with no way to correct them.
2. **Two seams can't be delegated.** Findings 3 and 6 above: denylist
   filtering of walked paths, root confinement, and volume capping are
   post-processing we must write regardless — at which point most of the
   client exists anyway, and we're still paying for the extra process.
3. **It inverts the bounded-gem rule.** A direct client has a closeable
   threat model: read-only, no network, one long-lived child, reusing
   `Mcp::ClientWrapper`'s restart discipline. A third-party bridge is an
   opaque Go/TS/Rust binary with its own network posture and supply
   chain — widening the threat model to save ~200 lines of Ruby, in a
   project whose bar is "small enough to audit in an evening", and
   dragging a non-Ruby toolchain into a Ruby monorepo.
4. **Teaching mandate.** A small LSP client is a good book chapter about
   how editors actually work. "Install this Go binary" teaches nothing.

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

Worth stealing:

- **One tool, an `operation` enum — not nine tools.** Nine `lsp_*`
  entries is a real prompt-budget cost. Tension with the naming
  convention in [`../CLAUDE.md`](../CLAUDE.md) (a `foo_*` prefix marks a
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
  worth having. Keep it; explain why in the parameter description, since
  a required `filePath` on a workspace-wide query reads as a bug
  otherwise.
- It exposes `workspaceSymbol` raw and lets the model chain it into
  `goToDefinition`. That works because the model is strong. **Pikuri's
  default is local llama.cpp**, and small local models chain multi-call
  sequences unreliably — a real reason for pikuri to collapse the
  name→position hop *inside* the tool where Claude Code doesn't.

## Sketch

- `pikuri-lsp` gem. Name it after what it refuses to become: no
  formatting, no code actions, no diagnostics push, no rename/edit
  application — **read-only navigation**. The moment it applies a
  workspace edit it needs the `Confirmer` seam and stops being closeable.
- `Pikuri::Lsp::Registry::StdioEntry` mirroring
  `Mcp::Registry::StdioEntry`, plus a `Registry.from_h` bridge so hosts
  can map their own config file onto it — see Configuration below. The
  claimed-files field is load-bearing, not decorative: it is the dispatch
  key that picks the server, per finding 1.
- `Pikuri::Lsp::ClientWrapper` — long-lived child, id demux on a reader
  thread, auto-reply to server→client requests, restart-on-death copied
  from the MCP wrapper. Needs the same documented exception to the
  Subprocess seam (`Subprocess.spawn` is one-shot; this isn't).
- `Pikuri::Lsp::ServerProgress` domain event + an `Lsp::Extension`
  mirroring `Mcp::Extension`: configure builds the shared client set and
  arms `on_close`, bind hands the tool its emitter. See Configuration.
- One `lsp` tool, static `operation` enum, 1-based coordinates,
  capability-gated **at dispatch** (route by extension, then refuse
  cleanly if that server lacks the operation), results filtered through
  `Filesystem#denied?` + root-confined + capped/grouped.
- Book chapter when it lands (`book/language-intelligence.md`?) — the
  protocol is genuinely interesting and nothing else in pikuri teaches
  "how does an editor know things". It also has to carry the *setup*,
  since nothing ships wired and the user writes the server command
  themselves: two worked configs, Ruby and Java, with every part of the
  jdtls one explained — see Configuration.

## Configuration

Launch argv plus the files a server claims is indeed the spine, and for
Ruby that is the entire entry. Two more fields earn their place, and two
that look obligatory must *not* exist.

```ruby
StdioEntry = Data.define(:id, :command, :files, :env, :init_options)
```

- **`id`** — `"ruby"`, `"java"`. Unlike MCP's id this is *not* a
  model-facing handle (the model never names a server; the file picks
  it). It is for log lines, restart messages, and the degrade string.
  Duplicates raise, copied from `Mcp::Registry`.
- **`command`** — argv array, `Subprocess.spawn` convention, same
  Subprocess-seam carve-out as the MCP wrapper.
- **`files`** — the dispatch key. **Globs matched against the basename**,
  not bare extensions: `%w[*.rb *.rake *.gemspec Rakefile]`. An
  extension-keyed field is one character shorter and lies the first time
  someone opens a `Rakefile`. First match in declaration order wins; no
  overlap detection (computing glob overlap is real work to prevent a
  misconfiguration nobody has made yet).
- **`env`** — merged over the inherited environment, exactly
  `StdioEntry#env`'s role in MCP: the legitimate per-child channel of the
  "Environment is not a secret store" seam. Here it carries `JAVA_HOME`
  rather than a token.
- **`init_options`** — passed verbatim as `initializationOptions` in the
  `initialize` request; pikuri never parses the contents. Deferred as
  speculative until J4 tripped its own tripwire: without
  `extendedClientCapabilities.classFileContentsSupport` jdtls silently
  refuses every library definition, so this is the difference between
  Java navigation working and quietly returning nothing. It is the
  designated home for per-server non-spec glue, which keeps the client
  generic — pikuri has no jdtls special case, the Java *entry* does.
There is deliberately **no `content_request`** field — reading a
server-private URI is standard-only; see "What a result outside the root
becomes".
  Same principle as `init_options` and its natural partner: the
  capability declared there is what makes the server hand back `jdt://`
  URIs at all, so an entry that sets one without the other is
  half-configured. Nil means non-`file:` results are reported and
  dropped. See "What a result outside the root becomes".
**No `startup_timeout:`, and no timeout at all.** The obvious fifth field
— ruby-lsp indexes this repo in seconds, a cold jdtls import is minutes —
is a trap twice over. No value is defensible (30s is wrong for Java, 300s
is wrong for Ruby), and what it buys is a `"still indexing, try grep"`
observation, which is a *decision point* handed to a small local model:
retry, wait, or give up, and it cannot express "wait" as a tool call
anyway. This is finding 6's name→position argument again — pikuri
collapses hops the model would chain badly. So the first call blocks
until the server is ready, however long that is. The LLM can wait
endlessly; the human decides otherwise via Ctrl+C.

Three things replace the clock, none of them a clock:

- **Die on child death.** What a timeout actually guards is not a slow
  index but a server that never becomes ready — jdtls failing a
  dependency import, ruby-lsp's custom-bundle `bundle install` erroring.
  Child exit is a *definite* answer: `"ruby-lsp failed to start: <stderr
  tail>"`, an honest error rather than a guess, and it catches the common
  case earlier than any timeout would.
- **`Cancellable` must break the wait.** A blocking read never reaches a
  tool-call boundary, so `bin/pikuri-code`'s SIGINT trap would not fire —
  the wait has to poll the cancel flag. This is what makes "endless"
  acceptable: the human is the timeout, using a mechanism pikuri already
  has.
- **Surface progress as a domain event.** A silent three-minute stall is
  indistinguishable from a hang for the person watching. The `$/progress`
  payloads are already parsed for the readiness gate, so they only need a
  way out — see below. Not optional once the clock is gone.

### Progress as a domain event

`Pikuri::Lsp::ServerProgress`, emitted via `ctx.emit_event` like
`Tasks::ListChanged` and `Code::PlanModeChanged`; a TUI or web host draws
a bar, `bin/pikuri-code`'s terminal listener prints one crude line, and
every other listener no-ops for free. (Named without the `Lsp` prefix —
the namespace already carries it, per its siblings.)

```ruby
ServerProgress = Data.define(:server_id, :title, :message, :percentage, :done)
```

Maps 1:1 onto LSP's `WorkDoneProgress` `begin` / `report` / `end`, with
`done: true` as the `end` marker so one variant covers the lifecycle and
the host knows when to dismiss the bar. Two payload notes that decide
whether a consumer works: **`percentage` is optional in LSP** and plenty
of servers never send it, so a host needs an indeterminate-spinner
fallback — a bar is not always drawable. And **`server_id` is why the
entry keeps `id`**: at boot with Ruby and Java both registered, two
servers index concurrently and a host must key its bars by server. That
promotes `id` from a diagnostics-only field to a real payload key.

**The thread problem, which is the actual design work here.** Progress
notifications arrive on the client's *reader thread*, while
{ExtensionContext#emit_event} is documented as agent-thread-only — this
would be pikuri's first event emitted from anywhere else, and emitting it
raw would let a progress line interleave into the middle of the terminal
listener's streaming render. Resolution: the client parks progress, and
the **first-call wait loop drains it and emits on the agent thread** —
the loop is already there polling `Cancellable`, so this costs nothing
and the contract holds. Emission therefore has exactly one call site, and
`bind` hands the tool an emitter lambda (the `Tasks::Extension` shape;
the capability seam's sanctioned explicit handoff to a non-extension
consumer) rather than wiring the producer.

Two details that decide whether the deferred drain behaves:

- **Park latest-value-per-token, not a FIFO backlog.** ruby-lsp emits
  hundreds of `report` notifications during an index; a queue drained
  three minutes later would replay all of them, a burst of stale
  percentages racing to catch up before the first live one. Coalescing
  per token makes the drain emit *current* state, then track live.
- **Always emit a terminal `done: true` when the wait exits**, whatever
  is parked. Otherwise a host that drew a bar keeps it up forever when
  readiness arrives without a matching `end`.

### What a result outside the root becomes

**There is no standard "read this URI" request in the LSP that ships
today, and no way to discover a server's non-standard one.** Verified:
the Ruby SDK is `language_server-protocol` 3.17.0.6 and neither it nor
ruby-lsp mentions `textDocumentContent` anywhere. The spec assumes the
client is an editor that owns a filesystem. jdtls fills the gap with its
own `java/classFileContents`, and other servers invent their own schemes
the same way (`zipfile:`, `deno:`, `jar:`, `sourcekit-lsp:`) — each
documented in prose, none announced over the wire.

So: **every result is rendered as location + snippet, and the URI scheme
decides where the snippet comes from.** Three tiers, and the third is a
hard refusal.

- **`file:` — the only scheme pikuri reads itself.** In-root results go
  through the `Workspace` seam and also carry the path, because the model
  can usefully `read` more of it. Out-of-root results (the 45 `Faraday`
  hits under `gems/`) come back as snippet-only: a path the model cannot
  open is a dead-end citation, and "what does this library method do" is
  one of the top reasons to want LSP at all. **`Filesystem#denied?` still
  applies** — an LSP hit under a denied root must not leak just because
  the server walked to it, which is `D-walked-path-denylist` doing
  precisely its job.
- **Custom schemes — standard-only, which today means not at all.** A
  `jdt://contents/slf4j-api-2.0.18.jar/org.slf4j/LoggerFactory.java?=…`
  is a *handle, not a locator*: an index into jdtls's own view of the
  classpath, closer to a file descriptor than a path, and meaningless to
  anything else. Only the issuing server can read it, and **the protocol
  offers no way to discover how to ask** (verified: jdtls advertises 25
  capabilities, none content-related, and the substring "content" appears
  nowhere in its handshake). Editors solve this with per-server plugins —
  vscode-java and nvim-jdtls both hardcode `java/classFileContents`.

  pikuri will not. The one supported path is **LSP 3.18's
  `workspace/textDocumentContent`** — client→server, `{uri}` → `{text}`,
  with the server advertising a `schemes: string[]` list, which is real
  discovery rather than out-of-band lore. Detection is then a capability
  check at dispatch, the same shape finding 1 already established for
  operations; no new mechanism and no config field.

  The cost, accepted deliberately: **nothing implements it yet**, so
  today a custom-scheme result is unreadable. ruby-lsp is unaffected —
  Ruby gems are unpacked source on disk, so it emits `file:` URIs
  exclusively (all 45 `Faraday` hits were gem paths). **Java library
  navigation is therefore blocked until jdtls ships 3.18**, and that is
  an acceptable wait rather than a reason to carry a
  `content_request` escape hatch: one config field, two arcane coupled
  strings, and a jdtls-shaped hole in a generic client, all to buy a
  feature the standard is about to provide for free.

  **No `lsp_read` tool.** The tempting shape — expose a tool that takes a
  URI and returns its text — would be, in every configuration that ships
  today, a tool that always errors: ruby-lsp never emits a custom URI and
  jdtls's cannot be read. It would spend prompt budget to do nothing, and
  reintroduce exactly the chaining hop collapsed elsewhere in this note
  because small local models chain badly. Instead the existing `lsp` tool
  reports unreadable results inline with their reason — "2 more in
  libraries; this server's `jdt:` URIs need LSP 3.18 content support,
  which jdtls does not implement yet" — never a bare count, never
  silence. When a 3.18 server appears the *same* path fetches and inlines
  the text: no new tool, no chaining, and the model never holds a URI it
  must decide what to do with.

  And when explicit loading is eventually wanted, it lands as **another
  `operation` enum entry, not a second tool** — the same reasoning that
  made this one tool rather than nine, and free to defer because the enum
  is static and hardcoded anyway (finding 1), so adding a value later
  breaks nothing. The question to answer *then*, not now: automatic
  inlining and an explicit read are not rivals but serve different needs
  — a bounded snippet per result keeps `goToDefinition` usable (J7's
  22 KB × 45 `Faraday` hits is the failure mode), while an explicit
  operation is how the model asks for the *whole* document when the
  snippet is not enough.

  **Wire jdtls anyway and you still want the capability declared.**
  Nothing stops a user registering it, and there the entry's
  `init_options` still earns its keep: with `classFileContentsSupport`
  jdtls returns a `jdt://` URI and pikuri says plainly that it cannot
  read it; without it, jdtls returns *zero locations* (J4) and the model
  concludes the symbol has no definition. Loud beats silent, so the Java
  example keeps it — and in-project navigation works either way (J2's
  `WebServer` resolved fine), so only the library half is blocked.

- **`http(s):` and everything else — never dereferenced, only printed.**
  This is the load-bearing refusal. Fetching a URI the *server* chose
  hands pikuri-lsp an attacker-influenceable egress leg: the gem's entire
  claim is read-only local navigation with no network, and a dependency
  that can name a URL in its source map would break that claim, with the
  request itself as the exfiltration channel (the data rides in the URL).
  pikuri already has `fetch` and `web_scrape` for network reads a human
  asked for. Render the URL as text and let the model decide to reach for
  those; the LSP tool never dereferences.

Volume is part of this, not separate from it: J7's single class was
22 KB. A snippet is the definition's `range` plus a few lines of context,
never the whole document — the same capping discipline finding 6 demands
for `references`.

### The coalescing mailbox

Both of those belong in one small class rather than smeared across the
wait loop, and its single responsibility states cleanly: **it is the
thread boundary** — a producer thread pushes, a consumer thread drains
the newest value per key, and the block runs on the *consumer's* thread.

```ruby
mailbox.drain(tick: 0.1) do |update|   # nil on an idle tick
  cancellable.check!
  break if client.ready? || client.dead?
  emit.call(update) if update
end
```

- **`push(key, value)`** — coalesce per key, not to one global latest.
  jdtls can hold "Importing project" and "Building workspace" open at
  once, and with Ruby and Java both booting there are two servers besides;
  a single latest-value flickers between unrelated tasks. Taking the key
  as a parameter keeps the class ignorant of the value type, so no
  key-extractor strategy has to be injected.
- **Terminate with `break`.** The caller must check readiness *and*
  `Cancellable` regardless, so give it one place to do it: yield `nil` on
  an idle tick and let plain Ruby end the loop. No `stop_when:` predicate,
  no magic return value, and a `Cancelled` raised inside the block just
  propagates.
- **Not named `run_loop`** — {Pikuri::Agent#run_loop} is *the* chat loop,
  and a second one is a permanent readability tax at every call site.
- **A mailbox, not a queue**: no backlog exists by construction, so
  `Thread::Queue` is the wrong primitive (it preserves exactly what this
  discards). `Mutex` + `ConditionVariable`, ~30 lines.

**Where it lives.** Its own class either way, but *inside `pikuri-lsp`*
until a second caller exists — with one, "reusable" is a hypothesis, and
promoting later costs nothing. Candidates worth checking when the time
comes: vectordb corpus indexing and MCP boot probing. Both need testing
for whether they are genuinely cross-thread or merely sequential on the
agent thread; if sequential, there is no second caller and this correctly
stays gem-local.

Consequence accepted deliberately: progress nobody is waiting on
surfaces no events. That is the *correct* scope, not merely the cheap
one, in both directions — background indexing while the user types their
first prompt has no audience, and background indexing while the model is
mid-turn doing unrelated work has a worse-than-none audience, since a bar
for something nobody is blocked on competes with the model's output. A
host wanting a boot-time status bar anyway needs current-state polling on
the extension; v1 shouldn't build it until a real TUI asks, and if this
bites, redesign then.

`title` / `message` are server-supplied strings reaching a terminal;
defanging is the renderer's job via `Pikuri::Sanitizer`, per the
Confirmer seam's presentation rule, so nothing new is owed here.

**No `root:` / `cwd:`, deliberately.** The child is spawned with cwd =
the `Workspace` root, full stop. Both reference servers derive their
identity from cwd — ruby-lsp resolves the project bundle from it, and the
jdtls launcher hashes it to pick a data directory — so a configurable
root would silently let the LSP's idea of the project diverge from the
`Workspace` root, which is also the confinement and denylist boundary
(finding 3). One root, one boundary. If a Java-in-a-subdirectory monorepo
breaks that, we learn it from a real user; jdtls imports nested projects
from a parent root today.

**Where the user actually writes this.** The entry is a Ruby value
object — that is the library API, and a host embedding pikuri can compute
its fields (the Java `-data` path through `Pikuri::Paths.cache`, say).
But *this particular config is machine state*: which server binaries you
have installed, where `JAVA_HOME` points. That is the same category as
`llm_server` and the API keys, which is why those already live in
`~/.pikuri-examples-config.yaml` rather than in each `bin/` script.
Making a user hand-edit a version-controlled demo script to add their
local server paths dirties the repo and loses the edit on the next pull.

So: **`Lsp::Registry.from_h`** as the bridge, and each host picks its own
file. The demo bins read the existing YAML; `pikuri-tui` maps its own
(much larger) config file through the same method. `from_h` is
format-agnostic on purpose — a plain Hash in, a `Registry` out — so
nothing in `pikuri-lsp` knows what YAML is.

Two costs to accept with open eyes:

- **A YAML entry cannot compute**, so the jdtls `-data` path is written
  out literally by the user instead of derived from `Paths.cache`. The
  alternative — pikuri injecting a default `-data` when the entry omits
  one — is a jdtls special case inside a generic client, which J4's whole
  point was to avoid. Interpolation syntax in the YAML is worse still:
  that is reinventing Ruby badly, in the file format pikuri exists as a
  counter-move to.
- **The file changes kind.** It holds credentials today; it would then
  also hold an argv and an env that get *spawned*. Anyone able to write
  it could already exfiltrate the keys in it, so the trust boundary does
  not move — but "config that runs a command" deserves the sentence, and
  `YAML.safe_load_file` (already used) is what keeps it data.

### The two book examples

Ruby is three lines and teaches that the whole config is two facts:

```ruby
Pikuri::Lsp::Registry::StdioEntry.new(
  id: 'ruby', command: %w[ruby-lsp],
  files: %w[*.rb *.rake *.gemspec Rakefile Gemfile]
)
```

Java exercises the remaining two, each for a reason the reader can check
— and is where the chapter shows a first call blocking for minutes and
that being the correct behaviour:

```ruby
Pikuri::Lsp::Registry::StdioEntry.new(
  id: 'java', files: %w[*.java],
  command: ['jdtls', '-data', Pikuri::Paths.cache('jdtls', project_slug).to_s],
  env: { 'JAVA_HOME' => ENV.fetch('JAVA_HOME') },
  init_options: {
    extendedClientCapabilities: { classFileContentsSupport: true }
  }
)
```

Why `-data` is passed explicitly, read out of the launcher
(`jdtls.py`, read today — this is source-reading, not a live run like the
findings above): its default is
`~/.cache/jdtls/jdtls-<sha1>` where the sha1 is over
**`File.basename(Dir.pwd)`** — the basename alone, so `~/work/app` and
`~/clients/acme/app` share one workspace state directory. It also
hardcodes `~/.cache`, ignoring `XDG_CACHE_HOME`. Both are exactly what
pikuri's `Paths` convention exists to prevent, which makes this a
four-line demonstration of the convention rather than a paragraph
asserting it.

Both are *examples*, and neither ships wired — the chapter teaches the
config by having the reader add one to their own
`~/.pikuri-examples-config.yaml`, which is the only honest way to present
it, since the entry depends on which servers that reader has installed.
The Ruby literals above are the shape the fields map onto; the chapter
shows the YAML beside them, because that is what the reader types.

Since the user writes the whole jdtls command themselves, the chapter
owes them a default *and* what each part of it means. All four are
evidenced by the runs above, which is what makes them explainable rather
than cargo-cult:

- **`jdtls`** — the Python launcher shipped with eclipse.jdt.ls. It execs
  a JVM with the equinox launcher and a dozen `-D` flags; nobody should
  hand-assemble that, so the entry names the launcher and adds only what
  it can't guess.
- **`-data <per-project dir>`** — the Eclipse workspace state. Override it
  because the launcher's default is `sha1(File.basename(Dir.pwd))` under
  a hardcoded `~/.cache`: two checkouts *named* the same collide, however
  far apart they live. This is also the dir that makes a restart cheap
  (J6: 78s → 7.7s), so it wants a real cache location, not `/tmp`, and
  one per project.
- **`JAVA_HOME`** — the JDK that *runs the server*, which is not the JDK
  the project compiles against. The launcher hard-fails below Java 21
  (`jdtls requires at least Java 21`) while your project may target 8;
  a reader who conflates the two will "fix" the wrong one.
- **`classFileContentsSupport`** — and the honest caveat that comes with
  it. Without it every library symbol answers with *silence* (J4); with
  it you get a `jdt://` URI pikuri reports as unreadable until jdtls
  ships LSP 3.18. Declaring it therefore buys a loud failure instead of a
  false premise, which is the whole reason it stays in the example. The
  chapter should show that failure rather than assert it: a
  `LoggerFactory` with no definition is a better teacher than a
  capability flag nobody would question — and in-project navigation works
  throughout, so only the library half is missing.

The chapter gets a second payoff for free: with both entries registered,
finding 1's multi-server dispatch is exercised for real — `.java` and
`.rb` routing to different servers with different capability sets — and
the `.md` refusal is a live behaviour, not a hypothetical.

## Open questions

- **Startup cost vs. session model.** Indexing this repo dominated each
  run's wall time. `bin/pikuri-code` is synchronous and request-scoped —
  do we pay it lazily on first `lsp` call (a multi-second stall mid-loop),
  eagerly at boot (slow start for sessions that never use it), or in
  background at boot and block only on first use? Leaning the third, and
  the no-timeout decision strengthens it: background start overlaps
  indexing with the user typing their first prompt and the model's first
  few turns, so the unbounded block is usually near-zero and only bites
  the session that asks for language intelligence immediately.
- ~~**Does the model actually use it?**~~ **Not a blocker — build it
  anyway**, but the expected payoff is uneven and the book should say so.
  For a typed language it is close to certain: Java's answer to "where is
  this defined" is a compiler fact, and `grep` for an overloaded method
  name in a multi-module build is hopeless. For Ruby it is genuinely
  unclear — dynamic dispatch means the server returns *candidates*
  (finding 3), which is much closer to what `grep` already gives, and
  whether a given model reaches for it will vary by model. Since the
  registry is language-agnostic anyway, this changes no design decision;
  it is a claim to keep out of the chapter's marketing.
- ~~**Multi-language, or Ruby-only first?**~~ **Moot** — nothing ships
  wired either way. Dispatch still assumes multi-server from day one
  (finding 1); retrofitting routing plus per-server capability checks
  later would touch every operation.
- ~~**Where does confinement live, and is it a capability question?**~~
  **Settled — see "What a result outside the root becomes" below.** Every
  result is location + snippet, the scheme decides where the snippet comes
  from, and only `file:` is ever read by pikuri itself.
- ~~**The readiness gate may not be generic.**~~ **Settled by J1–J3** —
  one generic gate (all progress tokens closed, plus a short settle
  debounce) serves both servers, because a false-early edge is harmless
  against a server that defers its replies and essential against one that
  answers `[]`. No per-server predicate, no knob. What must not be
  forgotten is the *capability* half: `window.workDoneProgress: true`
  has to be declared or jdtls emits no progress for the gate to watch.
- **Concurrent sessions in one repo.** Two `pikuri-code` processes on the
  same checkout hand both servers the same state directory (jdtls's
  `-data`, ruby-lsp's in-repo `.ruby-lsp/` custom bundle). `Paths.cache`
  is shared-and-persistent by design; `Paths.new_temp` would fix the
  collision and re-index from scratch every session, which for jdtls costs
  minutes — J6 measured it at 78s cold against 7.7s warm on the same repo.
  So: keep `cache`, accept that the second session may fail to start its
  server and degrades to grep.
- ~~**Missing binary at boot.**~~ **Settled: nothing is registered by
  default, so it may be loud.** `bin/pikuri-code` is written in Ruby, but
  that is an implementation detail of the agent, not a claim about the
  code it edits — it runs against any project, so shipping a Ruby server
  wired in would be wrong for most sessions. The registry starts empty
  and the user adds entries by hand, in the demo bins' existing
  `~/.pikuri-examples-config.yaml` rather than in the script itself (see
  "Where the user actually writes this"). With no default
  entry, a registered-but-missing binary is a misconfiguration the user
  made deliberately, so it raises at boot like a failing
  {Pikuri::Mcp::Servers#start_one} rather than warning and degrading —
  "errors are loud", with no default to break for people who never asked
  for LSP.

## The tool surface: three operations, and no column

Membership could not be settled on its own — it falls out of the
parameter shape, which is the more consequential half.

**pikuri never asks the model for a column.** Claude Code requires
`line` *and* `character`; getting a column right means counting
characters inside a line, which a strong model does and a local 4B model
does not. Nothing hands the model that coordinate either: `Read` prints
line numbers, `grep` prints `file:line:text`, neither prints columns.
(Evidence from the throwaway clients: every one of them grew a
`locate(text, symbol)` helper on the first attempt, because supplying
columns by hand was intolerable even by hand.)

So the parameters are **`symbol` (required), `file` and `line`
(optional disambiguators)**. The tool resolves the column itself by
locating the symbol text, and resolves a bare name through
`workspace/symbol` + an exact-name filter (finding 5). That is the
"collapse the name→position hop inside the tool" commitment made
concrete. Three consequences worth noting:

- Routing still works: `file` is the server selector when given, and with
  a bare name the tool fans out to every registered server and merges —
  cheap, and correct, since a name may live in either language.
- The 1-based↔0-based conversion shrinks to `line` alone, and the utf-16
  conversion (mandatory per finding 7, since jdtls refused our utf-8
  offer) becomes an entirely *private* detail: the model never sees an
  encoded offset in either direction.
- A symbol that isn't literally on the named line is a clean error
  ("`foo` not found on line 42"), not a silent wrong answer.

Membership then follows:

**In: `definition`, `references`, `hover`.** Uniform shape, no chaining,
and precisely the origin use case. Each needs its capping discipline —
references grouped lib/spec (finding 6), hover and definition capped
hardest on constants, where a reopened namespace yields 45 near-identical
hits.

**Out, with reasons:**

- **`workspaceSymbol`** — becomes the internal mechanism, not a verb.
  Exposing it hands a small model a deliberately fuzzy list to chain
  from, and `definition(symbol: "Foo")` returning nothing is already the
  existence check.
- **`documentSymbol`** — the only file-keyed operation, so it breaks the
  uniform shape, and `grep '^\s*(def|class|module)'` already outlines a
  file using a tool that is always present.
- **`goToImplementation`, `prepareCallHierarchy`, `incomingCalls`,
  `outgoingCalls`** — unsupported by ruby-lsp (verified: Claude Code
  leaks raw `Method not found` for all three against it), and the
  hierarchy trio is a three-call chain on top.
- **`typeDefinition`, `declaration`, `typeHierarchy`** — advertised by
  both servers, but marginal over `definition` or chained like the above.

Adding a value later breaks nothing (the enum is static and hardcoded),
so this is a floor, not a ceiling.

## How the protocol is modeled, and the build order

`Data.define` values serialized through `JSON.generate`; **no string
concatenation anywhere near the wire**. The framing header is the one
place bytes are assembled by hand, and it is three fields.

But *not* a model of LSP. The full protocol is hundreds of interfaces —
hand-writing them is the `language_server-protocol` dependency rejected
above, rebuilt worse. Data classes earn their place only where the wire
shape is messy and the internal shape should be clean:

- **`Location`** — the prize. Servers answer with either `Location`
  (`uri`/`range`) or `LocationLink` (`targetUri`/`targetRange`/
  `targetSelectionRange`) depending on the `linkSupport` we declare
  (finding 4, and the bug that crashed the first throwaway parser). One
  Data class, one `.from_wire` accepting both shapes, and the rest of the
  gem never learns there were two.
- **`ServerProgress`** — `begin` / `report` / `end` collapsing into the
  one variant hosts consume.
- **`Position` / `Range`** — small, ubiquitous, and the home for the
  1-based↔0-based and utf-16 conversions, so those live in one place
  instead of at every call site.

Everything else stays plain: outbound message envelopes are Hashes handed
to `JSON.generate` (that is not string concatenation), and **the
`initialize` result's capabilities object stays a Hash** — we only ask
whether a key is present, and capability values are unions in practice
(`definitionProvider` came back as `true` from jdtls, an object
elsewhere), so typing 25 fields buys a schema nobody reads.

Build order:

1. **Gem skeleton + the protocol layer.** Framing, id demux, the Data
   classes above. Independent of both parked questions — enum membership
   is the tool layer, the trifecta contribution is the extension layer,
   and neither touches this.
2. **The fake server, sharing those types in reverse** — it parses what
   the client writes and serializes canned replies. Any asymmetry (a
   field we can write but not parse) surfaces immediately.

   The trap to avoid: if the fake builds replies with our own serializer,
   a serialization bug is invisible because both sides agree on the same
   wrong thing. So the parse layer also gets **fixtures of raw captured
   bytes** from real servers — the `LocationLink` reply, a `jdt://` URI,
   the `$/progress` payloads, all recorded in the findings above.

## Testing

**A fake server driven over in-process pipes, not a subprocess.** The
client's transport is a pair of IOs; a spec hands it `IO.pipe` ends and
plays the server side from a thread in the same process. No spawn, no
binary to install, one backtrace instead of two.

The structural implication is the part worth writing down: **the wrapper
must not spawn in its constructor.** `ClientWrapper.new(stdin:, stdout:)`
with a separate `.spawn(entry)` factory — the same two-phase
construct-then-start shape {Pikuri::Mcp::Servers} already documents, so
this is consistency rather than a seam cut for tests.

Three layers, because the middle one cannot be done in-process:

1. **Protocol logic → in-process pipes.** Framing, id demux, answering
   server→client requests, the readiness gate, progress coalescing,
   capability gating, denylist filtering, capping. This is also the only
   way to test the failure paths that matter most, since a real server
   will not produce them on demand: an early `[]` (finding 2), a progress
   token that never closes (J2), a reply that never arrives, hostile
   bytes in a `title`. Drive the fake from a thread — a spec that writes
   more than the pipe buffer with nobody reading will deadlock.
2. **Spawn and death → tiny real subprocesses, no LSP involved.** A
   nonexistent command for the missing-binary raise; `sh -c 'exit 1'` for
   child-death detection and the stderr tail; teardown through
   {Pikuri::Finalizers}. In-process pipes give EOF but no exit status, so
   this layer is what covers "died" as distinct from "closed".
3. **One live-server smoke spec** against `ruby-lsp`, tagged to skip when
   the binary is absent. Proves the stack works end to end without making
   CI depend on it — the `ruby:4.0` image has no `ruby-lsp`, and while CI
   already installs `ripgrep` for the Grep specs, layers 1 and 2 mean
   nothing here *needs* that precedent followed.

## Open — revisit in an upcoming session

One left. The other two — the testing story and the operation enum's
membership — are settled above; this is the place to start next time.

- **The gem's trifecta contribution.** `Mcp::Extension` declares its
  legs; `pikuri-lsp` must too, and the answer is not obviously "nothing".
  No egress (the `http(s)` refusal is what buys that) and no new private
  data *in principle* — results are derived from files the agent can
  already read — but snippet content for out-of-root results is text from
  outside the workspace entering the context, which is the untrusted-input
  leg however local it is. Write it down rather than defaulting to silence.

## Considered, deferred

- **Diagnostics.** `rubocop --lsp` gives them for ~4 capabilities' worth
  of client work, and grok-build/Claude Code surface fresh diagnostics as
  system-reminders appended to tool output. Attractive, but it needs the
  reminder mechanism pikuri doesn't have (see
  [`../COMPARISON.md`](../COMPARISON.md) §system reminders) and it pushes
  the gem from read-only navigation toward lint policy. Separate note if
  it ever gets legs.
- **`rename` / workspace edits.** Needs `Confirmer` + the read-before-edit
  gate; breaks the closeable threat model. Not in v1.
- **Depending on `language_server-protocol`.** See above — 40 lines of
  framing, wrong reader shape.
- ~~**An `init_options:` passthrough** on `StdioEntry`.~~ **Reversed by
  J4** — jdtls needs it for library navigation, so it is a field now. What
  stays deferred is the *other* half: a `settings:` slice to answer the
  server's `workspace/configuration` requests with something other than
  `null`. Both reference servers tolerate `null`s.
- **Hover as a `read` replacement.** Deferred as a third way to read code
  alongside `read` and `grep`. Finding 8 weakens that reasoning: on a
  *constant*, one hover returns the whole yardoc class comment, which in
  this codebase is the declared source of truth — a different operation
  from "read the file", not a third spelling of it. Still deferred, but
  the blocker has moved: it is now the volume problem (45 doc links for
  `Faraday`), which is a capping question, not a tool-surface one.

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
**direct-vs-MCP with the bridges named**, and **no-timeout with its three
replacements**, → two new `DECISIONS.md` entries (suggested slugs
`lsp-direct-not-mcp` and `lsp-no-startup-timeout`, with the usual
prefix); the COMPARISON.md LSP column → `✅`. Then delete this file,
plus the superseded LSP bullets in `coding-agent.md` and
`claude-parity.md`.
