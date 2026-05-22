# pikuri-code

In-repo coding-agent gem for the
[pikuri](https://codeberg.org/mvysny/pikuri) AI-assistant toolkit.

Adds the shell-and-dev-loop layer on top of
[`pikuri-workspace`](../pikuri-workspace/README.md)'s filesystem
tools:
- `Pikuri::Tool::Bash` — runs commands via the
  `Pikuri::Subprocess.spawn` chokepoint with `Confirmer` gating.
- `bin/pikuri-code` — the interactive coding-agent binary that
  wires file + shell + web tools into an agent rooted at the
  current working directory.

## Install

```ruby
# Gemfile
gem 'pikuri-code'
```

Pulls in `pikuri-core` + `pikuri-workspace` transitively.

## Usage

Run from the root of the repo you want it to work in:

```sh
cd ~/code/your-project
/path/to/pikuri/pikuri-code/bin/pikuri-code
```

You'll land in a REPL — type a request at the `>` prompt, hit enter,
and the agent reads files, runs commands, and edits code. Ctrl+C or
Ctrl+D exits. You can also pass an initial message on the command
line:

```sh
/path/to/pikuri/pikuri-code/bin/pikuri-code "find the failing spec and fix it"
```

If an `AGENTS.md` or `CLAUDE.md` exists at the workspace root, it's
prepended to the system prompt as project context.

## Security

This is a tech demo. **Do not run `pikuri-code` against a sensitive
checkout on a machine that holds secrets you care about.** The `bash`
tool runs commands as your user, with access to `~/.ssh`,
`~/.aws/credentials`, shell history, etc. The workspace lock only
applies to pikuri's file tools — it does *not* sandbox `bash`. See
the root [README.md](../README.md) and [IDEAS.md](../IDEAS.md) for
the full threat-model discussion and planned mitigations.
