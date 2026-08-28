# pikuri-workspace

Filesystem tools + Workspace/Confirmer seams for the
[pikuri](https://codeberg.org/mvysny/pikuri) AI-assistant toolkit.

Self-contained "operate on a directory tree" toolkit:
- `Pikuri::Workspace::Filesystem` — scopes filesystem access to a
  project root + explicit readable / writable prefix lists, with an
  optional ephemeral temp playground. Rejects `..`-escapes and
  symlinks that resolve outside the configured roots.
- `Pikuri::Workspace::Confirmer` — abstract base for approving
  user-state mutations, plus `AUTO_APPROVE` (headless) and `Terminal`
  (stdin/stdout). `Terminal` is written for pikuri's own single-threaded
  demo scripts — a real app implements this seam itself and reads
  `Terminal` as the worked example.
- Five file tools: `Pikuri::Workspace::Read`,
  `Pikuri::Workspace::Write`, `Pikuri::Workspace::Edit`,
  `Pikuri::Workspace::Grep`, `Pikuri::Workspace::Glob`.

No shell execution — `Pikuri::Code::Bash` ships in
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

workspace = Pikuri::Workspace::Filesystem.new(project_root: Dir.pwd)
# Fine for a script like this one; write your own for a real app.
confirmer = Pikuri::Workspace::Confirmer::Terminal.new

agent = Pikuri::Agent.new(
  transport: ...,
  system_prompt: ...,
) do |c|
  c.add_tool Pikuri::Workspace::Read.new(workspace: workspace)
  c.add_tool Pikuri::Workspace::Grep.new(workspace: workspace)
  c.add_tool Pikuri::Workspace::Glob.new(workspace: workspace)
  c.add_tool Pikuri::Workspace::Edit.new(workspace: workspace)
  c.add_tool Pikuri::Workspace::Write.new(workspace: workspace, confirmer: confirmer)
  c.add_listener ...
end
```

`Workspace` is the "look-but-don't-leak" guard around filesystem
access. Read tools route through `#resolve_for_read(path)`; mutating
tools route through `#resolve_for_write(path)` + the Confirmer's
`#confirm?(request:)`. Pass `temp: true` to mint an ephemeral
writable playground via `Dir.mktmpdir` — its path is exposed as
`workspace.temp` and auto-removed at process exit.

## Further reading

- **Narrative walkthrough:** the "Workspace seam" and "Confirmer
  seam" sections of
  [the coding-agent chapter of the pikuri guide](../book/code.md) — what
  each kwarg of `Filesystem.new` controls, when to use the
  `AllowAll` variant, and how the seams fit alongside `Sandbox`.
- **API reference:** browse the YARD docs at
  <https://rubydoc.info/gems/pikuri-workspace> (once published),
  or run `bundle exec yard` in this directory for a local copy.
