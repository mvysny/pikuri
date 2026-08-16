# LSP client — language intelligence for the coding agent

Status: **investigated, not built.** Protocol mechanics are settled and
verified against live servers — ruby-lsp, rubocop, a shipped client, and
now jdtls against a real Gradle multi-module repo; the direct-vs-MCP fork
is decided in principle; the registry entry's field list and the
progress-delivery mechanism are drafted (Configuration). The
tool-surface sketch is the live part. Two lifecycle questions remain
open: what a result outside the workspace root becomes, and whether
`bin/pikuri-code` registers a Ruby server by default.

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

**But use a bridge as a measuring instrument.** Wire
`mcp-language-server` through `pikuri-mcp` for an afternoon and watch
*which operations the model actually reaches for and how it phrases
them* — the one question a design doc can't answer. Then throw it away
and write the direct client informed by that. Ship direct; spike via MCP.

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
  `Mcp::Registry::StdioEntry` — see Configuration below. The
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
  "how does an editor know things". Two worked configs, Ruby and Java —
  see Configuration.

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

**Config is Ruby, and that is half the point.** The Java entry below
computes its data directory through `Pikuri::Paths.cache`; a JSON config
file — the thing pikuri exists as a counter-move to — cannot. Worth one
paragraph in the chapter.

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
- **Does the model actually use it?** The honest risk: `grep` is right
  there and the model is good at it. This is what the MCP spike measures.
- **Multi-language, or Ruby-only first?** Registry design is
  language-agnostic for free; the question is whether to ship any server
  config beyond Ruby before there's a user. Whichever way it goes, the
  *dispatch* path must assume multi-server from day one (finding 1) —
  retrofitting extension routing plus per-server capability checks later
  would touch every operation.
- **Where does workspace-root confinement live** — in the wrapper, or as
  a `Workspace::Filesystem` call in the tool? The latter reuses the seam;
  the former keeps the tool thin.
- **…and confinement is a *capability* question, not only a filtering
  one.** Finding 3 treats out-of-root hits as noise to drop, but the
  `Faraday` run is the counter-example: 45 locations under `gems/`, and
  "what does this library method actually do" is one of the top reasons to
  want LSP at all. Confine hard and the model falls back to grep for
  exactly the case where grep is worst. Return the paths unconfined and
  the model gets citations it cannot then `read`. Third way: for
  out-of-root hits return the *snippet* rather than the path, so no read
  capability is granted. Note this lands differently per host — under
  `bin/pikuri-code` the gem sources are already reachable via `bash`, so
  nothing is widened; under a read-only workspace-confined host it is a
  new leg. **J5 forces one arm for Java**: a library definition comes back
  as a `jdt://` URI, not a path — nothing to deny-check, nothing to
  `read`, contents only via jdtls's own `java/classFileContents`. So
  either non-`file:` results return *content*, or Java library navigation
  is dropped outright. The snippet answer and the `jdt://` answer are the
  same mechanism, which is a good sign it is the right one.
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
- **Missing binary at boot.** If `bin/pikuri-code` ships a Ruby entry
  registered *by default* — which is the only way the feature gets used —
  then a machine without `ruby-lsp` must warn loudly and degrade, not
  raise. That tension (registered-by-default vs. errors-are-loud) is
  decided by whether the default entry ships, so decide that first.

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
section, since they are the same lesson wearing three hats; per-symbol rationale → yardoc on `Lsp::ClientWrapper` / the
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
