# pikuri (metagem)

The convenience bundle for the
[pikuri](https://codeberg.org/mvysny/pikuri) AI-assistant toolkit:
`gem install pikuri` brings in every pikuri-* gem in one shot, and
`require 'pikuri'` boots them all.

This gem ships no Ruby code of its own — its `lib/pikuri.rb` is
seven `require` lines, one per sibling.

## Install

```ruby
# Gemfile
gem 'pikuri'
```

Transitively installs:
- [`pikuri-core`](../pikuri-core/README.md) — the foundation
- [`pikuri-skills`](../pikuri-skills/README.md) — Agent Skills support
- [`pikuri-workspace`](../pikuri-workspace/README.md) — filesystem tools
- [`pikuri-code`](../pikuri-code/README.md) — Bash + `bin/pikuri-code`
- [`pikuri-lsp`](../pikuri-lsp/README.md) — read-only code navigation via a language server
- [`pikuri-mcp`](../pikuri-mcp/README.md) — MCP support
- [`pikuri-subagents`](../pikuri-subagents/README.md) — `agent` tool + bundled personas + `bin/pikuri-minions`
- [`pikuri-assistant`](../pikuri-assistant/README.md) — `bin/pikuri-assistant`

All version-locked together — bumping the metagem requires the
matching sibling versions.

## When NOT to use this gem

Privacy-conscious users who care about a minimal dependency tree
should install just the lean core + the extensions they actually
need:

```ruby
gem 'pikuri-core'
gem 'pikuri-mcp'     # if they want MCP
gem 'pikuri-skills'  # if they want skills
# ... etc.
```

`pikuri-core` is the minimal install. Adding `pikuri-mcp` adds
exactly one new runtime gem (`mcp`); `pikuri-workspace` /
`pikuri-skills` / `pikuri-code` / `pikuri-subagents` /
`pikuri-assistant` add nothing beyond pikuri's own gems. The dep
tree stays auditable.

## Further reading

- **Narrative walkthrough:** the [pikuri
  guide](../book/) — a short sequential book covering the
  whole family, chapter by chapter.
- **API reference:** browse the YARD docs at
  <https://rubydoc.info/gems/pikuri> (once published), or run
  `bundle exec yard` in any sibling gem's directory for a local
  copy of that gem's docs.
