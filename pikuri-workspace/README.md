# pikuri-workspace

Filesystem tools + Workspace/Confirmer seams for the
[pikuri](https://codeberg.org/mvysny/pikuri) AI-assistant toolkit.

Self-contained "operate on a directory tree" toolkit:
- `Pikuri::Tool::Workspace` — abstract base + bundled
  `Workspace::Cwd` that scopes filesystem access to a chosen root,
  rejecting `..`-escapes and symlinks that resolve outside the root.
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

workspace = Pikuri::Tool::Workspace::Cwd.new(root: Dir.pwd)
confirmer = Pikuri::Tool::Confirmer::TERMINAL

agent = Pikuri::Agent.new(
  transport: ...,
  system_prompt: ...,
  tools: [
    Pikuri::Tool::Read.new(workspace: workspace),
    Pikuri::Tool::Grep.new(workspace: workspace),
    Pikuri::Tool::Glob.new(workspace: workspace),
    Pikuri::Tool::Edit.new(workspace: workspace),
    Pikuri::Tool::Write.new(workspace: workspace, confirmer: confirmer)
  ],
  listeners: ...
)
```

`Workspace::Cwd` is the "look-but-don't-leak" guard around filesystem
access. Read tools route through `#resolve_for_read(path)`; mutating
tools route through `#resolve_for_write(path)` + the Confirmer's
`#confirm?(prompt:)`.
