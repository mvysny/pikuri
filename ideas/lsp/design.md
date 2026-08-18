# LSP client — the settled design

Split out of [`../lsp.md`](../lsp.md), which keeps the status and the
worklist. Everything here is decided; the evidence it rests on lives in
[`research.md`](research.md) and is cited by stable label (`finding 1`,
`J4`, …).

None of it has met an implementation yet, which is why it is still in
`ideas/` rather than in `pikuri-lsp/DESIGN.md`, five `DECISIONS.md`
entries and a book chapter — see the graduation map in
[`../lsp.md`](../lsp.md).

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
2. **Two seams can't be delegated.** Findings 3 and 6 in
   [`research.md`](research.md): denylist filtering of walked paths, root
   confinement, and volume capping are post-processing we must write
   regardless — at which point most of the client exists anyway, and we're
   still paying for the extra process.
3. **It inverts the bounded-gem rule.** A direct client has a closeable
   threat model: read-only, no network, one long-lived child, reusing
   `Mcp::ClientWrapper`'s restart discipline. A third-party bridge is an
   opaque Go/TS/Rust binary with its own network posture and supply
   chain — widening the threat model to save ~200 lines of Ruby, in a
   project whose bar is "small enough to audit in an evening", and
   dragging a non-Ruby toolchain into a Ruby monorepo.
4. **Teaching mandate.** A small LSP client is a good book chapter about
   how editors actually work. "Install this Go binary" teaches nothing.

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
Ruby that is the entire entry. Three more fields earn their place, and two
that look obligatory must *not* exist. (The field table with both worked
values is in [`../lsp.md`](../lsp.md) §"The v1 build"; the *why* for each is
here.)

```ruby
StdioEntry = Data.define(:id, :command, :files, :language_id, :env, :init_options)
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
- **`language_id`** — the string `didOpen` carries, and the only field whose
  default is *computed*: `nil` means "look me up", and the lookup consults a
  built-in table (`.rb` → `ruby`, `.py` → `python`, `.cs` → `csharp`, … —
  the ids that are not simply the extension) **once per entry, against its
  first extension-bearing glob**, not per file. Per-entry because `files:` holds
  basename globs and a `Rakefile` has no extension to look up; every file an
  entry claims is then opened under that one id, which is coherent given that
  an entry *is* one server for one language.

  The values come from the LSP spec's *language identifiers* table — in
  practice VS Code's list, which the spec adopted and left open-ended, since
  the field is a plain string on the wire. **It is optional rather than
  required, and that is S11's doing.** jdtls ignores the field outright, and
  ruby-lsp falls through to `:ruby` for anything it does not recognize — so a
  garbage value is harmless while the two values it *does* recognize (`erb`,
  `rbs`) select a different parser and make every query return `nil` and zero
  symbols, silently. A string that only hurts when the user guesses
  *plausibly* is the worst thing to demand of them; a table cannot make that
  mistake, and it keeps the Ruby example at three lines.
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
  designated home for per-server non-spec glue that must travel *outbound
  at handshake time*, and it keeps that class of glue out of the client.

There is deliberately **no `content_request` field.** Reading a
server-private URI is per-server glue too, but it is the *inbound* half —
which request answers a `jdt:` URI — and pushing it into config would cost
the user two arcane coupled strings (a method name and a params shape)
that are wrong in silence when mistyped, in a YAML file, to configure
something they cannot verify. pikuri hardcodes that table instead: one row
today, `jdt:` → `java/classFileContents`, tried only after the standard
3.18 request is found absent. The asymmetry with `init_options` is the
point — a capability *declaration* is data the user can copy from their
server's README, whereas a *protocol method* is code. See "What a result
outside the root becomes".
**No `startup_timeout:`, and no timeout at all.** The obvious fifth field
— ruby-lsp indexes this repo in seconds, a cold jdtls import is minutes —
is a trap twice over. No value is defensible (30s is wrong for Java, 300s
is wrong for Ruby), and what it buys is a `"still indexing, try grep"`
observation — which is not information but a *decision point*: retry, wait,
or give up, and "wait" is the correct answer while being the one thing no
tool call can express. Relaying an empty index state is the one case where
waiting beats relaying, because there is nothing in `[]` to reason about
(see [`../lsp.md`](../lsp.md) §Strategy, point 4). So the first call blocks
until the server is ready, however long that is. The LLM can wait
endlessly; the human decides otherwise via Ctrl+C.

Three things replace the clock, none of them a clock:

- **Die on child death.** What a timeout actually guards is not a slow
  index but a server that never becomes ready — jdtls failing a
  dependency import, ruby-lsp's custom-bundle `bundle install` erroring,
  a second session finding the `-data` directory locked. Child exit is a
  *definite* answer, and it catches the common case earlier than any
  timeout would. It surfaces as the tool's own
  `"Error: ruby-lsp exited during startup: <stderr tail>"` — "errors are
  loud", in the tool-returns-a-string half of that rule, since the model
  can react to it.

  **And it ends there: no fallback, no suggestion.** The error does not
  say "try grep". That would be the `"still indexing, try grep"`
  observation this section just refused, arriving by a different door — a
  failure message that *steers*, when the model is the one holding the task
  and the tool is not. Either the `lsp` tool works —
  blocking as long as it takes — or it errors, and choosing what to do
  next is the model's normal business, not something the failure message
  steers.
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
  hits under `gems/`) always come back with the line of code — "what does
  this library method do" is one of the top reasons to want LSP at all —
  and with a **path only where the workspace would read that file**.
  *Refined 2026-08-18, during the build:* the original rule was
  snippet-only, on the grounds that a path the model cannot open is a
  dead-end citation. True under root confinement, and false under
  `AllowAll` — the `--yolo` and OS-agent wirings open a gem checkout
  happily, so suppressing the path there deletes a capability the wiring
  granted. `Sources` asks `resolve_for_read` per path and renders the
  actionable form: the path where it would open, the basename where it
  would not. **`Filesystem#denied?` still
  applies** — an LSP hit under a denied root must not leak just because
  the server walked to it, which is `D-walked-path-denylist` doing
  precisely its job.

  Measured, so the strength of that last sentence is not overstated
  (worklist item 8, now closed): under the *scoped* `Filesystem` that
  `bin/pikuri-code` wires, `denied?` is a constant `false` and
  `denied_roots` is empty — so **root confinement carries the out-of-root
  boundary alone**, and the `denied?` pass filters nothing there. It earns
  its place under `AllowAll` (the container wiring), where it answers `true`
  for `~/.ssh` and `/etc/shadow`, `false` for gem and `~/.m2` paths, and
  symlink-resolves first. Keep the pass — it is cheap, exact, never raises
  and fails closed — but the thing it guards is a credential path an LSP
  result could name, not a dependency checkout.
- **Custom schemes — standard first, with one hardcoded fallback.** A
  `jdt://contents/slf4j-api-2.0.18.jar/org.slf4j/LoggerFactory.java?=…`
  is a *handle, not a locator*: an index into jdtls's own view of the
  classpath, closer to a file descriptor than a path, and meaningless to
  anything else. Only the issuing server can read it, and **the protocol
  offers no way to discover how to ask** (verified: jdtls advertises 25
  capabilities, none content-related, and the substring "content" appears
  nowhere in its handshake). Editors solve this with per-server plugins —
  vscode-java and nvim-jdtls both hardcode `java/classFileContents`.

  The preferred path stays **LSP 3.18's `workspace/textDocumentContent`**
  — client→server, `{uri}` → `{text}`, with the server advertising a
  `schemes: string[]` list, which is real discovery rather than
  out-of-band lore. Detection is a capability check at dispatch, the same
  shape finding 1 already established for operations. When a server
  advertises it, it wins outright and nothing below runs.

  **But nothing implements it yet, and a standard-only stance made the Java
  arm untestable.** That is the reversal: an earlier pass accepted
  "unreadable until 3.18" as a narrow cost, on the grounds that `hover`
  still answers "what is this library class" ([`research.md`](research.md),
  prior art). It is narrow in *capability* and total in *development* —
  Java's whole reason to want LSP is that most of what you navigate to lives
  in a jar, so a Java arm that cannot follow a single library definition
  cannot be exercised on a real project, and an operation set nobody can run
  against jdtls is designed blind. **Designing a surface you cannot test is
  the worse failure.** So:

  **A scheme→request table, hardcoded in the client, with exactly one
  entry today: `jdt:` → `java/classFileContents`.** Mechanics, all four
  of them small:

  - **The scheme is the discriminator, because there is nothing else to
    detect.** jdtls advertises no content capability, so a capability
    check is impossible by construction — but only the server that
    *issued* a `jdt:` URI can read it, and that server is jdtls by the
    same construction. Keying on the scheme of the URI we were just
    handed is therefore exact, not a guess.
  - **Try-then-degrade, never raise.** A `Method not found` (finding 9's
    error shape) drops straight back to the report-unreadable string
    below, so a wrongly-matched scheme costs one round trip and nothing
    else.
  - **Both reply shapes.** 3.18 returns `{text:}`; `java/classFileContents`
    returns a **bare String** (J7). One parse hook accepts either — J7
    already flagged this, and it is why the two paths can share a
    call site.
  - **Slice, memoize, cap.** J7 measured 22,639 bytes for one class in
    10 ms — cheap to fetch, ruinous to inline. Slice to the target range
    like any other snippet, memoize per URI within a call (the 45-hit
    `Faraday` shape repeats URIs), and cap how many content fetches one
    call makes.

  **The cost, named rather than waved off.** This *is* the jdtls-shaped
  hole a previous pass refused, and the refusal's reasoning was not
  wrong — it was aimed at the wrong shape. What it actually rejected was a
  **`content_request` config field**: two arcane coupled strings the user
  must get right, in a file format pikuri exists as a counter-move to.
  That rejection stands (see Configuration). A table in the client is a
  different animal: the user writes nothing, the entry is one line plus a
  parse hook, it is named after a server rather than parameterized over
  all of them, and it carries a **written deletion condition — delete the
  `jdt:` row the day jdtls advertises `textDocumentContent`**, at which
  point the standard path already above it takes over with no other edit.
  The generic-client principle survives where it matters: the *protocol
  layer* stays server-agnostic, and the exception is one table the book
  chapter can print in full.

  **No egress is added.** Every entry in that table is a JSON-RPC request
  to a child pikuri already spawned over a pipe it already owns — the same
  leg as every other operation. The table may never gain a row that
  reaches the network; that is what keeps the `http(s):` refusal below
  load-bearing rather than decorative, and it is the sentence the
  trifecta answer will lean on.

  ruby-lsp is unaffected either way — Ruby gems are unpacked source on
  disk, so it emits `file:` URIs exclusively (all 45 `Faraday` hits were
  gem paths). The table exists for the typed half of the target, which is
  exactly where the note already argued the payoff is close to certain.

  **A scheme with no row is still reported, never silent.** `zipfile:`,
  `deno:`, `sourcekit-lsp:` and anything else get the inline reason — "2
  more in libraries; this server's `zipfile:` URIs need LSP 3.18 content
  support, which it does not advertise" — never a bare count. Adding a row
  later is the same one-line change as removing the `jdt:` one, and the
  bar for adding one is a server someone actually wired and can test.

  **Still no `lsp_read` tool.** The tempting shape — a tool taking a URI
  and returning its text — would reintroduce exactly the chaining hop
  collapsed everywhere else in this note, spending a round trip on something
  the tool can do exactly, and would hand the model a 300-character `jdt:`
  URI to hold and decide about (J9: they encode the whole classpath entry).
  The `lsp` tool inlines content itself, on the same path for both the
  standard request and the fallback. And when explicit
  loading is eventually wanted it lands as **another `operation` enum
  entry, not a second tool** — free to defer because the enum is static
  and hardcoded (finding 1). The question to answer *then*: automatic
  inlining and an explicit read are not rivals but serve different needs —
  a bounded snippet per result keeps `definition` usable (J7's 22 KB × 45
  `Faraday` hits is the failure mode), while an explicit operation is how
  the model asks for the *whole* document when the snippet is not enough.

  **The Java entry's `classFileContentsSupport` is now load-bearing
  twice.** Without it jdtls returns *zero locations* for a library symbol
  (J4) and the model concludes it has no definition; with it, jdtls
  returns a `jdt:` URI — which the table now turns into readable source
  rather than a polite refusal. In-project navigation works either way
  (J2's `WebServer` resolved fine), so what the flag buys is the entire
  library half.

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

### One root, and where the entry is written

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
  command: ['jdtls', '-data', Pikuri::Paths.cache.join('jdtls', project_slug).to_s],
  env: { 'JAVA_HOME' => ENV.fetch('JAVA_HOME') },
  init_options: {
    extendedClientCapabilities: { classFileContentsSupport: true }
  }
)
```

Why `-data` is passed explicitly, read out of the launcher
(`jdtls.py`, read today — this is source-reading, not a live run like the
findings in [`research.md`](research.md)): its default is
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
The Ruby literals here are the shape the fields map onto; the chapter
shows the YAML beside them, because that is what the reader types.

Since the user writes the whole jdtls command themselves, the chapter
owes them a default *and* what each part of it means. All four are
evidenced by the runs in [`research.md`](research.md), which is what
makes them explainable rather than cargo-cult:

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
- **`classFileContentsSupport`** — the flag that turns Java library
  navigation on. Without it every library symbol answers with *silence*
  (J4); with it jdtls returns a `jdt:` URI, which pikuri reads through the
  scheme table's one row. So the chapter can *demonstrate* it rather than
  assert it: delete the flag and `LoggerFactory` has no definition, restore
  it and the same call returns its source. A toggle the reader can flip in
  ten seconds teaches the whole silent-empty lesson better than any
  paragraph — and it is the chapter's natural place to show the scheme
  table, since this is the one configuration where a custom-scheme URI
  actually appears.

The chapter gets a second payoff for free: with both entries registered,
finding 1's multi-server dispatch is exercised for real — `.java` and
`.rb` routing to different servers with different capability sets — and
the `.md` refusal is a live behaviour, not a hypothetical.

## Document synchronization: an agent is not an editor

**Before every position-based call, re-send `textDocument/didOpen` with the
file's current disk text.** No open-URI set, no version counter, no digest
comparison, no `didClose`. That is the whole policy, and it is deliberately
the thing the spec forbids ("a document must not be opened twice").

The reason it is sound rather than lucky: **pikuri has no unsaved
buffers.** An editor owns text the disk does not have, which is why LSP's
sync model exists at all; `write` and `edit` land on disk immediately, so
the disk is always the truth and the server's copy is only ever a cache of
it. Re-opening is how you say "here is the truth again", and the text it
needs is the text the tool already read for `locate`.

Everything else was measured and does not work (S1–S7 in
[`research.md`](research.md)):

- **A full-text `didChange` is not portable.** Both servers declare
  `textDocumentSync.change: 2`; jdtls accepts the rangeless whole-document
  variant, and ruby-lsp raises inside `push_edits` (it reads
  `edit[:range][:start]` unconditionally). A notification has no reply
  channel, so the only report is a `window/logMessage` line — the failure
  is invisible to a client that does not read the server's log, and the
  document silently keeps its old text (S1).
- **Syncing the document does not sync the index.** The *ranged*
  whole-document change is honoured by both, and on ruby-lsp it leaves the
  index behind: `documentSymbol` reports the new name while `definition`
  on it answers `[]`, because resolution goes through the index and
  `RubyDocument#should_index?` only reindexes when the edit's *start
  position* looks like a declaration — and a whole-file replace starts at
  0:0, on the leading comment (S2). A sync scheme that produces finding 2's
  silent empty is worse than none.
- **`didClose` is half a mechanism.** It resyncs ruby-lsp (the store entry
  is dropped, the next request re-reads disk) and does nothing for jdtls,
  which kept answering its pre-close copy (S6).
- **The spec's own out-of-band channel is ignored by both.**
  `workspace/didChangeWatchedFiles` changed nothing while the client owned
  the URI — ruby-lsp's source says why (`unless @store.key?(uri)`): a client
  that opened a document is *presumed* to be its authority (S7). Which is
  the assumption to avoid triggering, not to work around.
- **`didOpen` is not universally required, so this costs nothing where it
  is not needed.** ruby-lsp reads any unopened URI straight off disk
  (`Store#get` → `File.binread`); jdtls needs the open for `definition` but
  not for `documentSymbol` (S3). Re-opening every time is correct on both
  and asks neither which it is.

One cost, named: re-opening re-parses the file on every call, so a call on
a large file pays a parse it might have skipped. That is a local child
process doing what it does anyway on every keystroke in an editor, and the
alternative is a correctness bug that reports success.

### Observing the agent's own edits — settled, deferred past v1

grok-build syncs from the **write** path as well
(`notify_file_changed(path, content)`, queued while the server is still
starting), and pikuri should eventually too. The shape is decided so that
the deferral is a scheduling choice rather than an open question:

- **The event is emitted by the composite, not by the tools.**
  `Workspace::Workspace` already owns the read-before-edit ledger — it is
  the "what has this agent done to files" bookkeeper — and `Write` / `Edit`
  already hold that one instance and call `mark_read` on it, so
  `note_written(resolved)` sits beside the existing ledger calls.
  `Workspace::Extension#bind` bridges the callback to `ctx.emit_event`,
  exactly as {Pikuri::Tasks::Extension} arms `List#on_change` to emit
  `ListChanged`: emission stays on the agent thread and at one call site,
  per the capability seam. `WriteGate` is the wrong hook — it is a stateless
  module that runs *before* the write, and a refused write must not notify.
- **The payload is the path, not the bytes.** Every consumer that needs
  content reads it through the `Workspace` seam anyway, and an event stream
  other listeners also receive is no place to duplicate file contents.
- **It must never be load-bearing.** `bash` writes files, and so do
  `git checkout`, `sed` and any build the agent runs, so an
  edit-notification is *structurally* incomplete. Re-opening on read stays
  the correctness guarantee and this is enrichment on top — the same split
  `D-walked-path-denylist` draws between `denied?` (the guarantee, fails
  closed) and `denied_roots` glob-pruning (an optimization that may go
  partial).
- **The event fills a dirty set; the next `lsp` call drains it.** A 50-file
  refactor must not mean 50 full-text re-opens and 50 jdtls rebuilds.
  Coalescing per path bounds the work to once per LSP call and costs nothing
  in a turn that never touches LSP. That is also the **second caller** the
  coalescing mailbox was waiting for (see "Where it lives"), so the
  primitive gets reused rather than rebuilt.
- **What it buys over re-open-on-read is one measured thing**, and it is
  worth writing down because it is not obvious: a file the agent has just
  *created* is invisible to `workspace/symbol` until something opens it
  (S4 — ruby-lsp indexes only what it has loaded), and under re-open-on-read
  nothing opens it until the model asks a position question naming that exact
  file. So `symbol`-only lookup of a just-written class fails. The other two
  gains are softer: jdtls rebuilds ahead of the next call rather than during
  it, and this is the precondition for diagnostics-after-edit.

Deferred past v1 because it changes no interface in `pikuri-lsp` — the
client is self-sufficient by construction — so shipping it later costs one
listener arm and nothing else. The gem dependency it would need is present
regardless: `pikuri-lsp` depends on `pikuri-workspace` already, for
`denied?`, the root confinement, the seam-routed read behind the re-open,
and `filesystem.private?` in the trifecta declaration. An LSP serves a
*project*, and the notion of a project is what `Workspace` is.

## Questions raised, and how they settled

(All seven are closed; what is still open is the worklist in
[`../lsp.md`](../lsp.md). They are kept because each one's *resolution* is
the thing a reader will otherwise re-litigate — the
considered-then-deferred record an `ideas/` note owns.)

- ~~**Startup cost vs. session model.**~~ **Settled: spawn at boot,
  index in the background, block the first call.** Indexing dominated
  every run's wall time, and the three candidates were lazy-on-first-call,
  eager-at-boot, and background-at-boot-blocking-on-first-use. The third
  wins, and splits cleanly in two: **the spawn itself is synchronous at
  boot** — it is cheap, and it is what makes a missing binary raise
  immediately and loudly (see "Missing binary at boot") — while
  *readiness* is what proceeds in the background. The first `lsp` call
  then blocks until its server is fully ready, however long that takes,
  emitting `ServerProgress` while it waits so the block is legible rather
  than a hang. Background indexing overlaps with the user typing their
  first prompt and the model's first few turns, so the unbounded block is
  usually near-zero and only bites the session that asks for language
  intelligence immediately.
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
  **Settled — see "What a result outside the root becomes" above.** Every
  result is location + snippet, the scheme decides where the snippet comes
  from, and only `file:` is ever read by pikuri itself.
- ~~**The readiness gate may not be generic.**~~ **Settled by J1–J3** —
  one generic gate (all progress tokens closed, plus a short settle
  debounce) serves both servers, because a false-early edge is harmless
  against a server that defers its replies and essential against one that
  answers `[]`. No per-server predicate, no knob. What must not be
  forgotten is the *capability* half: `window.workDoneProgress: true`
  has to be declared or jdtls emits no progress for the gate to watch.
- ~~**Concurrent sessions in one repo.**~~ **Settled: keep `cache`, and
  the loser errors.** Two `pikuri-code` processes on the same checkout
  hand both servers the same state directory (jdtls's `-data`, ruby-lsp's
  in-repo `.ruby-lsp/` custom bundle). `Paths.cache` is
  shared-and-persistent by design; `Paths.new_temp` would fix the
  collision and re-index from scratch every session, which for jdtls costs
  minutes — J6 measured it at 78s cold against 7.7s warm on the same repo.
  So: keep `cache`, and when the second session's server dies on the
  locked directory it is exactly the child death above — that session's
  `lsp` calls return `"Error: …"` with no fallback. **Not a degrade to
  grep**: the tool either works or errors, and nothing in pikuri quietly
  substitutes a weaker answer for the one that was asked for.
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
  {Pikuri::Mcp::Servers#start_one} rather than warning and degrading. It
  is the *spawn* that raises, which is why spawning stays synchronous at
  boot while readiness does not (see "Startup cost vs. session model") —
  an `ENOENT` is known in milliseconds and has no reason to wait for a
  tool call to be reported. That is "errors are loud" in its raising half,
  affordable here because there is no default wiring to break for people
  who never asked for LSP. (A server that spawns and *then* dies is the
  other half — the tool's `"Error: …"` string, see "Die on child death".)

## The tool surface: ten operations, and no column

> **Membership has been re-derived, and this section is now evidence rather
> than derivation.** Per [`../lsp.md`](../lsp.md) §Strategy the enum is
> sourced from harnesses that shipped an LSP tool, and
> [`harness-analysis.md`](harness-analysis.md) is that survey — read
> first-hand from Claude Code's live schema, opencode's `tool/lsp.ts` and
> grok-build's vendored client. **The list it lands on:**
>
> ```
> goToDefinition  findReferences  hover  documentSymbol  workspaceSymbol
> goToImplementation  incomingCalls  outgoingCalls  goToTypeDefinition
> supertypes
> ```
>
> Changes against what this section argues: `documentSymbol` is back in (all
> three ship it; S10 makes it the only name→position route for a Java
> method), **`subtypes` is out and `supertypes` stays** (H7–H10, below), and
> the names are the harnesses' `goTo*` spellings rather than pikuri's
> bare ones. `goToTypeDefinition` survives as a measured deviation (J9), and
> `prepareCallHierarchy` stays excluded — the one place pikuri narrows a
> 2-of-3 majority, because the prepare hop belongs inside the tool. The
> per-server arguments below explain the deviations; they are no longer how
> the list is chosen.
>
> **The `subtypes` / `supertypes` split, measured.** `goToImplementation` is
> the better answer to "list all subtypes" on jdtls — transitive in one call
> for an abstract type (3 descendants where `subtypes` returned 1) and
> working on concrete classes too (H7/H8) — so `subtypes` is not merely
> unshipped by every harness, it is dominated by an operation already in the
> enum, and on ruby-lsp it is a `# TODO` (H1). `supertypes` is the opposite
> case: it works on **both** servers (H2, H9), and its value is the *chain*
> (`FancyPanel → Panel → Widget → Object`, one call per level), which the
> tool walks internally rather than making the model chain. Note that the
> walk reaches jar URIs routinely (H9's `Object`), so the scheme table is on
> the hierarchy path and not only on `definition`'s.

Membership could not be settled on its own — it falls out of the
parameter shape, which is the more consequential half.

**pikuri never asks the model for a column** — and the reason is not model
capability (the target is 25B+; the arithmetic is not the problem). It is
that **nothing in the model's input contains a column**: `Read` prints
line→text, `grep` prints `file:line:text`, neither prints columns. So a
column can only be *invented* by counting characters in a line the model
saw as prose, exactly right, with tabs and multibyte — and being wrong is
not an error. S8 has `definition` answering 0 from a keyword column, and S9
has `references` seven columns off returning **80,609** results instead of
2. Meanwhile the tool can derive the column exactly from one line of text.
(Evidence from the throwaway clients: every one of them grew a
`locate(text, symbol)` helper on the first attempt, because supplying
columns by hand was intolerable even by hand.)

So the parameters are **`symbol` (required), `file` and `line`
(optional disambiguators)**. The tool resolves the column itself by
locating the symbol text, and resolves a bare name through
`workspace/symbol` + an exact-name filter (finding 5). That is the
"collapse the name→position hop inside the tool" commitment made
concrete.

> **The two halves are not equally deliverable, and v1 says so.**
> `symbol` + `file` + `line` → column is pure local text search: no index,
> no server, works everywhere. `symbol` *alone* → position depends on
> `workspace/symbol`, which fails in opposite directions on the two servers
> measured — H6 (a bare namespaced Ruby class scores below ruby-lsp's 0.7
> threshold) and S10 (jdtls indexes no methods at all, so `"shout"` returns
> 0 hits and `"greet"` returns the *class*). So the index route ships as a
> best-effort convenience that reports honestly when it resolves nothing,
> and `file` + `line` is the shape the tool description teaches. See
> [`../lsp.md`](../lsp.md) §"The forks behind the v1 calls".

Three consequences worth noting:

> **H6 holds the collapse and breaks its input.** ruby-lsp scores
> `workspace/symbol` with Jaro-Winkler over the `::`-stripped **fully
> qualified** name against a 0.7 threshold, so a bare `Tool` scores 0.000
> and a bare `Confirmer` scores 0.455 — never returned, while the ivar
> `@confirmer` scores 0.967 and is. In a codebase where every class is
> namespaced, `symbol: "Confirmer"` therefore resolves to nothing and the
> tool answers "not found": this note's own headline failure, reached
> through its own headline parameter. The hop still belongs inside the
> tool; what "a bare name" may be is settled in [`../lsp.md`](../lsp.md)
> §"The forks behind the v1 calls", and S10 adds the other half — jdtls
> indexes no methods, so a bare name cannot reach a Java method at all. Two
> things are settled regardless: the filter compares the **last `::`
> segment**, never `name` (ruby-lsp reports the
> FQN there deliberately), and this is a *below-threshold* drop, so no cap
> or ranking tweak reaches it.

- Routing still works: `file` is the server selector when given, and with
  a bare name the tool fans out to every registered server and merges —
  cheap, and correct, since a name may live in either language.
- The 1-based↔0-based conversion shrinks to `line` alone, and the utf-16
  conversion (mandatory per finding 7, since jdtls refused our utf-8
  offer) becomes an entirely *private* detail: the model never sees an
  encoded offset in either direction.
- A symbol that isn't literally on the named line is a clean error
  ("`foo` not found on line 42"), not a silent wrong answer.

### Does the wider enum drag `character` back in?

It does not, and the check is worth writing out, because the enum grew
after the no-column decision was taken and every operation in it is
position-based in LSP. Sort the ten by *what the anchor is*:

- **Anchor is a declaration the index knows** — `definition`,
  `references`, `hover`, `implementation`, `supertypes`,
  `incomingCalls`, `outgoingCalls` on a named entity, plus
  `workspaceSymbol`, which needs no anchor at all. `workspace/symbol` +
  the exact-name filter supplies file, line *and* column. The model
  supplies nothing positional, and `file` / `line` only narrow which
  declaration is meant.
- **Anchor is not a workspace symbol** — a local, a parameter, an
  expression. `typeDefinition` on `var names = new ArrayList<String>()`
  is the archetype (J9), and `definition` / `hover` on a local are the
  same shape. The index cannot help, so `file` + `line` are effectively
  required — but the *column* is still derived by locating the symbol
  text on that line, never asked for.

So `character` is never the only way to reach an anchor: with a line, the
column is derivable from the line's text; without one, the index supplies
both. What a column would uniquely buy is **the same identifier twice on
one line** (`names = names.trim()`, `foo(foo)`). The answer there is the
discipline already used for multi-server routing, not a new parameter:
**query every occurrence on the line and merge.** Identical results
collapse to one — the overwhelmingly common case, since repeated
identifiers usually denote the same entity — and genuinely different
results are returned labelled by column. At most a couple of extra round
trips against a local child process, and the model is asked nothing.

The wider enum does add a second ambiguity class, and it is worth naming
because **a column would not have solved it either**: `prepare*` and
`workspace/symbol` can return several exact-name items — Java overloads
(`greet(String)` / `greet(int)`), one name defined in several classes.
The model has no more idea which one it means than the tool does, so a
`character` it invented would be a guess wearing a coordinate. `file` +
`line` narrow it when the model does know; otherwise the tool runs each
item and labels every result by its container and signature, under the
usual cap. That is an argument *for* the name-based shape, not against
it — the disambiguator the wider enum wants is semantic, and a column is
not.

Conclusion: parameters stay `operation`, `symbol`, optional `file`,
optional `line`. `typeDefinition`'s parameter description must say that
`file` + `line` are effectively required for it, since it is the one
operation whose usual anchor is invisible to the index.

**The one mechanic this rests on, now verified on ruby-lsp.** The index
hop has two steps: `workspace/symbol` + exact-name filter finds the
declaration (findings 3 and 5, J8 — and H6 for what "a name" may be), and
then that hit must become a *position*. It is not simply
`location.range.start`: a symbol's range routinely begins at the
**keyword** — `class Foo` starts at `class`, `def resolve_for_read` at
`def` — and a `definition` / `references` / `prepare*` query anchored on
`class` can legitimately answer nothing, which is finding 2's empty
result yet again. Newer servers sharpen it: a `WorkspaceSymbol` reply may
carry a bare `{uri}` with no range at all.

So the column is derived at *both* ends by the same helper — read the
declaration's line, locate the symbol text in it, take that column —
which is why every throwaway client grew `locate(text, symbol)` on its
first attempt. That costs a line read at the declaration site (routed
through the `Workspace` seam like any other, and subject to worklist
item 2 in [`../lsp.md`](../lsp.md) when the declaration is out of root).
**Confirmed on ruby-lsp, 6 cases out of 6** (H5): `prepareTypeHierarchy`
at the keyword column returned zero items every time and at the symbol's
own column exactly one every time, and `workspace/symbol`'s range for
`class Tool` starts at column 2 — the keyword — so feeding a hit's range
back in *is* the failure rather than the shortcut. The helper is
load-bearing, not a convenience. **And on jdtls too, for different reasons
per operation** (S8): `definition` answers 0 from a keyword column there as
well, while `prepareTypeHierarchy` answers from any column on the line, and
`workspace/symbol` reports the *symbol* column where ruby-lsp reports the
keyword. Two servers, opposite details, same helper.

Membership then follows:

**The exclusion criterion, stated properly.** An earlier pass cut
operations because *ruby-lsp lacks them* — which contradicts this note's
own design. The enum is the superset **pikuri** supports, gated per
server at dispatch (finding 1); "one server lacks it" is precisely what
that gate is for, and produces a clean refusal rather than an absence.
The real criteria are: too little value, chaining the model handles
badly, or redundancy with a tool pikuri already ships.

That matters because **statically and dynamically typed languages want
different operations**, and pikuri targets both — ruby-lsp and jdtls are
the two representatives, and every operation below was exercised against
whichever of them supports it. An enum sized to the intersection would
serve neither well.

**In: `goToDefinition`, `findReferences`, `hover`, `documentSymbol`,
`workspaceSymbol`, `goToImplementation`, `goToTypeDefinition`,
`incomingCalls`, `outgoingCalls`, `supertypes`** — ten (the earlier list
here read `definition` / `references` / `implementation` / `typeDefinition`,
included `subtypes`, and excluded `documentSymbol`). Uniform shape, no
chaining. Each needs its capping
discipline — references grouped lib/spec (finding 6), hover and definition
capped hardest on constants, where a reopened Ruby namespace yields 45
near-identical hits, and `findReferences` capped hardest of all: S9 measured
a single call returning 80,609 locations.

`typeDefinition` and `implementation` are the static-language pair, and
J9 is why they are not redundant with `definition`:

- **`typeDefinition`** answers a different question than `definition`.
  On `var names = new ArrayList<String>()`, `definition` gives the local
  declaration and `typeDefinition` gives `java.util.ArrayList` — a type
  written nowhere in the source. Nothing else recovers it. It is the one
  operation for which `symbol` alone is insufficient (a local variable is
  not in the workspace index), so `file` + `line` are effectively
  required and its parameter description must say so.
- **`implementation`** resolves an interface to its implementors, at type
  and method level both. Ruby has no interfaces and ruby-lsp does not
  advertise it (finding 9) — so for `.rb` it is a clean refusal, which is
  the gate working, not a gap.

**~~The two hierarchies ship in v1, as four enum values.~~ Three of the
four survive: the call pair, and `supertypes`.** `subtypes` went first to H1
(a ruby-lsp stub), then to the harness survey (nobody ships it), and finally
to H7/H8 — `goToImplementation` answers the same question better on jdtls, so
it is dominated rather than merely absent. `supertypes` earns its place on
H2 + H9 (both servers, no substitute for the chain), and the call pair on
two of three harnesses shipping it, minus the model-facing `prepare` hop.
The original argument, kept because it is what a reader will otherwise
reconstruct: they were the strongest deferred candidates and the deferral
was doing real damage: with
`implementation` refusing on `.rb`, Ruby had *no* "who overrides this"
operation at all, and grepping `< Base` is exactly the unreliable thing an
LSP hop exists to settle. Both hierarchies are valuable in both languages,
which no other candidate on the fence can say.

> **Reopened by the live run.** H1 and H4 falsify the load-bearing half of
> the argument above: ruby-lsp's `typeHierarchy/subtypes` is an
> unimplemented stub behind a truthfully-advertised provider, and module
> ancestry is walked in neither direction. So Ruby's "who overrides this"
> hole is **not** closed, and the promotion argument above loses its
> load-bearing half; `supertypes` survives intact and on its own merits
> (H2, H3).
>
> **Resolved by dropping `subtypes`, not by modelling the stub.** The arm
> considered and rejected was a per-server *known-stub list* — pikuri
> tracking which advertised capabilities are lies — which is precisely the
> unbounded per-server catalogue [`../lsp.md`](../lsp.md) §Strategy refuses.
> What retired the operation instead was H7/H8: `goToImplementation` answers
> the same question better on the one server whose `subtypes` works, so
> nothing is lost by cutting it. One mechanical consequence survives for
> `supertypes`, whose reply shape is the same: the parse layer accepts `nil`
> as well as `[]`.

- **Four values, not two.** Direction *is* the question — "who calls this"
  and "what does this call" are separate asks, and one lumped operation
  returning both doubles the volume for a model that wanted half. A
  `direction:` parameter is worse: it would apply to four of ten
  operations, which is Claude Code's `query`-only-for-`workspaceSymbol`
  wart rebuilt. Flat enum values, strictly validated by
  `Tool::Parameters`.
- **The prepare hop is collapsed, exactly like `workspace/symbol` inside
  `definition`.** LSP makes both a two-step chain —
  `textDocument/prepareCallHierarchy` → item → `callHierarchy/incomingCalls`,
  and `textDocument/prepareTypeHierarchy` → item → `typeHierarchy/subtypes`.
  The model issues one call with a `symbol`; the tool runs prepare, filters
  its items for an exact name match (finding 5's discipline again, since
  prepare can return several), and fetches. This *was* the exclusion reason,
  and it is the one the note's own design already knows how to dissolve.
  Claude Code exposes `prepareCallHierarchy` as a model-facing operation —
  the chaining hop, handed to the model — which is precisely what pikuri's
  local-model default cannot afford.
- **The capability gate splits them per language, and that is the gate
  working.** Finding 9: jdtls advertises both providers; ruby-lsp
  advertises `typeHierarchyProvider` but **not** `callHierarchyProvider`.
  So `.rb` gets `supertypes` and a clean refusal on the call pair, while
  `.java` gets all three. ~~`subtypes` is what closes the Ruby hole
  `implementation`'s refusal leaves open.~~ **That half was wrong** — H1:
  one provider key covers both directions, ruby-lsp advertises it for the
  `supertypes` it really implements, and `subtypes` answers `nil` from a
  `# TODO`. The gate is *working* and still lets a known-empty operation
  through, which is the one failure mode a capability check was supposed to
  remove; with `subtypes` cut (H7/H8) the case no longer arises, and where it
  would, the answer is to relay the empty result rather than model the lie.
- ~~**Unverified, and it must be verified first.**~~ **Verified — H1–H5,
  and it went the other way.** `subtypes` returned 0 for `Pikuri::Tool`
  (14 in-repo subclasses), `Listener::Base` and `Confirmer` alike, from
  `prepare` items that `supertypes` then answered correctly, so the anchor
  was right and the operation is simply a stub (H1). Module ancestry
  returns 0 in both directions (H4), which was the specific thing worth
  having. What does work is `supertypes` on a class — usefully, but noisily:
  14 rows for `Read`, every one named `Pikuri::Tool`, one per file that
  reopens the namespace, with the real declaration ordered *last* (H2), and
  6 rows of `Object` out of rbs stubs and unrelated gems for a root class
  (H3). Two mechanical consequences for the client: group by name and
  prefer the declaration over reopenings rather than capping (a cap cuts
  the useful row), and accept `nil` as well as `[]` from a hierarchy reply.
- **Volume.** `incomingCalls` on a popular method is `references`-shaped —
  same cap and same lib/spec grouping. `outgoingCalls` is the weakest of
  the four, since the model can just `read` the body; it ships because
  once prepare is collapsed the marginal cost is one enum value and one
  dispatch arm, and it is the honest counterpart to `incomingCalls`. If it
  goes unused, drop it — the enum is static, so removal is as cheap as
  addition.

`workspaceSymbol` is exposed *as well as* being the internal
name→position mechanism, because J8 shows it does something no tool
pikuri has can ever do: it searches the server's index, which reaches
inside jars and outside the workspace root. That is not in tension with
collapsing the hop — the collapse means the model is never *forced* to
chain, not that discovery is hidden. Its fuzziness (finding 5, and 11
hits for a three-letter prefix in J8) makes it the operation most in need
of exact-match-first ordering and a hard cap.

**Out, with reasons that survive the reframe:**

- **`documentSymbol`** — the only file-keyed operation, so it breaks the
  uniform shape, and for one named file `grep '^\s*(def|class|module)'`
  genuinely does outline it. The reach-into-dependencies argument that
  might seem to save it belongs to `workspaceSymbol`: `documentSymbol`
  takes a single `textDocument: {uri}` and searches nothing.

  > **Contested by S10, and probably wrong.** jdtls's `workspace/symbol`
  > returns *types only* — a method defined in the fixture returns 0 hits by
  > name — so for Java the in-file outline is the only way to turn a method
  > name into a position, and the `grep` substitute does not survive
  > overloads or a `Foo.Bar` nested type. Claude Code ships it, and the
  > survey agreed — it is **in** the v1 enum; see
  > [`harness-analysis.md`](harness-analysis.md).
- **`declaration`** — marginal against `definition` in both languages
  (C-style header/impl splits are the case it exists for).

Adding a value later breaks nothing (the enum is static and hardcoded), so
this is a floor, not a ceiling. What remains outside it is now only
`documentSymbol`, `declaration`, and the write-side operations the gem
refuses on purpose (rename, formatting, code actions, diagnostics) —
plus `completion`, which never came up because an agent writes whole
files rather than completing at a cursor, and is recorded here so the
omission is a decision rather than an oversight.

## How the protocol is modeled, and the build order

`Data.define` values serialized through `JSON.generate`; **no string
concatenation anywhere near the wire**. The framing header is the one
place bytes are assembled by hand, and it is three fields.

But *not* a model of LSP. The full protocol is hundreds of interfaces —
hand-writing them is the `language_server-protocol` dependency rejected
in [`research.md`](research.md), rebuilt worse. Data classes earn their
place only where the wire shape is messy and the internal shape should be clean:

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
   a `java/classFileContents` reply (a bare String, J7 — the fixture that
   proves the both-shapes parse hook), the `$/progress` payloads, all
   recorded in the findings in [`research.md`](research.md).

## Testing

**A fake server driven over in-process pipes, not a subprocess.** The
client's transport is a pair of IOs; a spec hands it `IO.pipe` ends and
plays the server side from a thread in the same process. No spawn, no
binary to install, one backtrace instead of two.

The structural implication is the part worth writing down: **the wrapper
must not spawn in its constructor.** `ClientWrapper.new(stdin:, stdout:)`
with a separate `.spawn(entry)` factory. This **is** a seam cut for tests,
and saying so is cheaper than the precedent it is tempting to claim:
{Pikuri::Mcp::Servers} documents a two-phase lifecycle, but at the
*collection* level (`.new` + `#start_all`), while
{Pikuri::Mcp::ClientWrapper}`#initialize` spawns immediately. At the level
being copied, MCP does the opposite — so the shape transfers, the
precedent does not.

Three layers, because the middle one cannot be done in-process:

1. **Protocol logic → in-process pipes.** Framing, id demux, answering
   server→client requests, the readiness gate, progress coalescing,
   capability gating, denylist filtering, capping. This is also the only
   way to test the failure paths that matter most, since a real server
   will not produce them on demand: an early `[]` (finding 2), a progress
   token that never closes (J2), a reply that never arrives, hostile
   bytes in a `title`. Drive the fake from a thread — a spec that writes
   more than the pipe buffer with nobody reading will deadlock.

   The scheme table belongs here too, and it is three cases the fake can
   play that no real server will: a server advertising 3.18
   `textDocumentContent` (the standard path wins, the table is never
   consulted), a server advertising nothing that answers
   `java/classFileContents` with a bare String (the fallback fires), and
   one that answers `Method not found` (degrade to the inline
   report-unreadable string, no raise). A prepare-then-fetch hierarchy
   whose `prepare` returns several items is a fourth — that is where the
   exact-name filter earns its spec.
2. **Spawn and death → tiny real subprocesses, no LSP involved.** A
   nonexistent command for the missing-binary raise; `sh -c 'exit 1'` for
   child-death detection and the stderr tail; teardown through
   {Pikuri::Finalizers}. In-process pipes give EOF but no exit status, so
   this layer is what covers "died" as distinct from "closed".
3. **Live-server smoke specs**, each tagged to skip when its binary is
   absent. `ruby-lsp` against this repo proves the stack end to end
   without making CI depend on it — the `ruby:4.0` image has no
   `ruby-lsp`, and while CI already installs `ripgrep` for the Grep specs,
   layers 1 and 2 mean nothing here *needs* that precedent followed.

   **A second arm against `jdtls` is what the scheme table buys**, and it
   is the reason the table exists: with it, one `definition` on
   `LoggerFactory` in a scratch Maven fixture exercises the typed half all
   the way through — capability routing by extension, `initializationOptions`,
   a `jdt:` URI, the fallback fetch, the range slice. Skipped in CI like
   the Ruby arm (a cold import is minutes, J6), and the honest framing is
   that this arm is **primarily a manual check** — a spec that runs on one
   developer's machine is a smoke test, not coverage. Everything it would
   assert is already covered deterministically by layer 1's fake; what a
   live jdtls adds is the thing a fake can never give, which is proof that
   our idea of the protocol matches a real server's.

## Trifecta: the legs this gem declares

Settled — this was the last parked design fork, alongside the testing story
and the enum's membership. Two *verification* tasks survive it (not forks;
both listed at the end) and belong to the implementation session.

`Mcp::Extension` declares its legs; `pikuri-lsp` must too, and the answer
is not "nothing".

```ruby
Tool::TrifectaLegs.new(
  private: <rides the host's project-private answer>,
  untrusted: :hard,             # unconditional — see below
  egress_payload_review: :no_egress
)
```

**Egress: `:no_egress` — and *not* because we trust the server.** The
tempting argument is that a well-behaved LSP only fetches artifacts from a
vetted set of hosts (jdtls pulling a jar from Maven Central), and that this
is too weak a leg to tag. That argument must not be written down, because
it argues for the opposite of its conclusion: `D-egress-axis-shape` defines
`egress_destination` as `:tool_vouched` / `:attacker_reachable` and
explicitly rejected a `:safe_vetted_set` rung — "this detector never claims
safety; bytes genuinely leave a vouched destination, they merely cannot be
read back." A vetted destination is a *rung*, so that phrasing lands
`lsp` on the map as `:tool_vouched` + `:unreviewed` forever. It is also
not true: the hosts come from the *project's* `build.gradle` /
`settings.xml`, so they are project-controlled, not vetted.

The argument that survives is the one that entry used to drop
`egress_human_author`: a seat whose outbound bytes do not originate in the
model's choosing **holds no leg to grade**, and clean-by-construction is
leg-*absence*. Apply it here: the model supplies `operation`, `symbol`,
`file`, `line`, and none of it reaches a socket — it reaches an in-memory
index. A jdtls dependency fetch happens at project import, driven by build
files, and happens identically if the model never issues a single call.
Network activity is not a function of model input, so there is nothing to
grade.

**Why that does not collide with MCP, which is the objection to expect.**
`Mcp::Extension` declares `ASSUMED` — hard `:untrusted`, unreviewed,
attacker-reachable — *unconditionally*, because "the tool list arrives at
runtime from a server you didn't write". Both gems spawn a user-configured
foreign stdio binary with inherited env, so the parity question is fair and
the answer must be in the DESIGN.md: **an MCP server contributes
model-callable tools with model-supplied arguments; an LSP server
contributes none.** One pikuri-authored tool, fixed schema, and pikuri
chooses every JSON-RPC request that leaves. There is no foreign tool
surface, hence nothing undeclarable, hence `ASSUMED` does not transfer.

**Untrusted: `:hard`, unconditionally — and the reason is that `Read`'s
conditional cannot be copied.** The first draft of this note claimed
results "are derived from files the agent can already read". That is false
by *design*: the server's index reaches outside the workspace root — the
whole bundle, jars, the JDK — while `Grep` is workspace-scoped, which J8
sells as the feature. The `jdt:` fallback widens it once more, pulling text
out of a **jar**, the one place this gem reads bytes the user never checked
out.

The shape of the declaration follows from what {Pikuri::Workspace::Read}
already does:

```ruby
untrusted: workspace.filesystem.trusted? ? :none : :hard
```

So pikuri's model is not "source files are untrusted" — it is *"the host
asked the human whether this checkout is trusted, and `read` rides that
answer."* That works precisely because `read` is confined to the root: the
vouching and the reach are the same set. For `lsp` they are not. **A user
who answered "yes, I trust this repo" made a claim about the code they
checked out, not about four hundred transitive jars Maven resolved, nor a
`-sources.jar` nobody has ever diffed.** Riding `trusted?` would stretch a
human's answer past the question they were asked — the same failure
`D-egress-axis-shape` names when it rejects a seat-named egress axis
("invites a confirmer-holding tool to declare the softer rung and silently
deletes the alarm"). No question the host currently asks has an answer that
could honestly turn this leg off, so it is a constant.

And it is not a theoretical exposure: finding 8 has `hover` returning an
entire yardoc class comment verbatim (45 doc links for `Faraday`), and J7
has `java/classFileContents` returning 22 KB of attached source. **Quoting
third-party prose into the context in bulk is this gem's marquee feature,
not an edge case of it** — and a sources jar is the cheapest place in a
dependency tree to put text aimed at a model, since it is fetched
separately from the binary and scrutinized far less.

**The consequence to accept on purpose.** On an *untrusted* checkout
nothing changes — `read` is already `:hard` there. On a **trusted** one it
does: `read` declares `:none`, so a wiring with `fetch` or `web_search`
that sits below the verdict line today would light the untrusted leg the
day `lsp` is wired in. That is correct rather than unfortunate — the jars
were never vouched for, and a trusted repo with a poisoned dependency is
the realistic attack, not a contrived one — but it means adding LSP to a
trusted-repo coding session can flip the trifecta verdict, and the
`DECISIONS.md` entry must say so rather than let a user discover it as an
unexplained alarm. `D-egress-axis-shape` already blesses declaring a true
axis for the map's sake when no verdict moves; this is the stronger case,
where one does.

**The escape hatch, named and rejected:** confine results to the root and
keep `:none`. That deletes J8 — searching inside jars, the one thing grep
can never do — so the tag is *the price of the capability*, not a defect to
engineer away. Write that sentence down, because it is the first thing
someone will propose when the map goes loud.

**Private: no new mechanism.** `private:` is inherited from the user, not
claimed by the tool (`D-egress-axis-shape`), and `bin/pikuri-code` already
asks at startup whether the project is private and feeds the map. LSP reads
the same project, so it rides that answer rather than introducing an
`Lsp::Registry#private?` mirroring MCP's.

**Which settles the declaration site too.** MCP declares at the *extension*
because its tools synthesize as raw `RubyLLM::Tool`s with no leg surface
(the MCP-tool bypass seam). `lsp` has no bypass — it is a real
`Pikuri::Tool` — and the three axes now want three different sources: a
host answer, a constant, and `:no_egress`. That composes comfortably at a
`trifecta_legs:` declaration site on the tool, the way
{Pikuri::Workspace::Read} does it, and awkwardly at the extension. So: on
the tool, with the extension contributing nothing.

**Confirmed against the real classes** (worklist item 9, now closed), and
the mechanism matters because it is easy to get accidentally wrong.
`Lsp::Extension` must **not** override `trifecta_contribution` — the base
`Agent::Extension` already returns `nil`, so this is a non-action rather
than a suppression. What makes it safe is that the extension registers the
tool through `Configurator#add_tool` at *configure* time (the
`Tasks::Extension` shape), which puts it in `agent.tools`, where
`Trifecta.build` reads `trifecta_legs` directly. The leg-invisible path is
`ExtensionContext#add_raw_tool`, and it exists for MCP's and sub-agents'
synthesized `RubyLLM::Tool`s — using it here is what would force the legs
back onto the extension. Two measured details on why a duplicate
declaration is not merely redundant: contributions are unioned per label
and `legs | legs == legs`, so the *verdict* would not move — but the map
would grow a `(lsp)` row beside the `lsp` row carrying the same three legs,
and `Contribution#label` is what `Report#attribution` points the reader at,
so it would blame the extension's wiring for a declaration living on the
tool. And an MCP-shaped `ASSUMED` contribution would *widen* the answer
outright: `legs | ASSUMED` flips egress to
`:unreviewed` / `:attacker_reachable`, the opposite of what §Egress
concludes.

**Four sentences the DESIGN.md owes about the *absent* egress leg, none of
them a tag:**

1. pikuri-lsp never dereferences a remote URI — the `http(s):` refusal plus
   the no-network-row invariant on the scheme table, both greppable.
2. The registered server may go online on its own; that traffic is a
   function of the project's build files, not of anything the model said.
3. The one steering path, stated so nobody thinks we missed it: the model
   edits `build.gradle`, the server re-imports, and fetches a host that
   file names. It takes a confirmed `Write`, and `bash` running gradle
   produces the same fetch — so the leg belongs to `write`, not to `lsp`.
4. A malicious registered server means all bets are off, and that is the
   *same* boundary an `Mcp::Registry::StdioEntry` already has — user-chosen
   argv, inherited env, unsandboxed — so it reads as precedent rather than
   special pleading. Such a server needs no clever channel; it can POST
   `~/.ssh` directly.

**And one asymmetry to state before a reader finds it.** `Code::Bash`
defaults to `FullFsNoNet` (`--unshare-net`), and the code agent's prompt
tells the model the commands it runs cannot reach the internet — while the
LSP child is not sandboxed at all. So a repo gets network through jdtls
that it explicitly does not get through `bash`. It cannot simply inherit
the bash posture either: a netless jdtls cannot import a Gradle project
that must resolve dependencies, and ruby-lsp's custom-bundle mode shells
out to `bundle install`. The answer is "not sandboxed, deliberately, and
here is why" — but written down, because someone who knows about the
sandbox will otherwise find it themselves and read it as an oversight.

**Both verification tasks are done** — `Filesystem#denied?` outside the
root (see §"What a result outside the root becomes") and the declaration
site (just above). Neither changed a leg.

## Considered, deferred

- **Diagnostics.** `rubocop --lsp` gives them for ~4 capabilities' worth
  of client work, and grok-build/Claude Code surface fresh diagnostics as
  system-reminders appended to tool output. Attractive, but it needs the
  reminder mechanism pikuri doesn't have (see
  [`../../COMPARISON.md`](../../COMPARISON.md) §system reminders) and it pushes
  the gem from read-only navigation toward lint policy. Separate note if
  it ever gets legs.
- **`rename` / workspace edits.** Needs `Confirmer` + the read-before-edit
  gate; breaks the closeable threat model. Not in v1.
- **Depending on `language_server-protocol`.** See
  [`research.md`](research.md) — 40 lines of
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

