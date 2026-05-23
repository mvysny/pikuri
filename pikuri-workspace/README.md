# pikuri-workspace

Filesystem tools + Workspace/Confirmer seams for the
[pikuri](https://codeberg.org/mvysny/pikuri) AI-assistant toolkit.

Self-contained "operate on a directory tree" toolkit:
- `Pikuri::Tool::Workspace` — scopes filesystem access to an anchor +
  explicit readable / writable prefix lists, with an optional
  ephemeral temp playground. Rejects `..`-escapes and symlinks that
  resolve outside the configured roots.
- `Pikuri::Tool::Confirmer` — abstract base + `AUTO_APPROVE` /
  `TERMINAL` for user-state mutations.
- Five file tools: `Pikuri::Tool::Read`, `Pikuri::Tool::Write`,
  `Pikuri::Tool::Edit`, `Pikuri::Tool::Grep`, `Pikuri::Tool::Glob`.

No shell execution — `Pikuri::Tool::Bash` ships in
[`pikuri-code`](../pikuri-code/README.md) on top of these.

## Install

```ruby
# Gemfile
gem 'pikuri-workspace'
```

## Usage

```ruby
require 'pikuri-core'
require 'pikuri-workspace'

workspace = Pikuri::Tool::Workspace.new(anchor: Dir.pwd)
confirmer = Pikuri::Tool::Confirmer::TERMINAL

agent = Pikuri::Agent.new(
  transport: ...,
  system_prompt: ...,
) do |c|
  c.add_tool Pikuri::Tool::Read.new(workspace: workspace)
  c.add_tool Pikuri::Tool::Grep.new(workspace: workspace)
  c.add_tool Pikuri::Tool::Glob.new(workspace: workspace)
  c.add_tool Pikuri::Tool::Edit.new(workspace: workspace)
  c.add_tool Pikuri::Tool::Write.new(workspace: workspace, confirmer: confirmer)
  c.add_listener ...
end
```

`Workspace` is the "look-but-don't-leak" guard around filesystem
access. Read tools route through `#resolve_for_read(path)`; mutating
tools route through `#resolve_for_write(path)` + the Confirmer's
`#confirm?(prompt:)`. Pass `temp: true` to mint an ephemeral
writable playground via `Dir.mktmpdir` — its path is exposed as
`workspace.temp` and auto-removed at process exit.
