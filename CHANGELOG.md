# Changelog

All notable changes to pikuri are recorded here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project
uses semver as documented in `lib/pikuri/version.rb`.

## [Unreleased]

## [0.0.1] - 2026-05-14 — first packaged release

The initial gem release. Pikuri is shipped as a **library** — there are
no executables installed by `gem install pikuri`. The `bin/pikuri-chat`
and `bin/pikuri-code` scripts in the source tree are dev/demo entry
points; production binaries built on pikuri (notably the planned
`pikuri-tui`) will live in their own downstream gems.

### Added
- `pikuri.gemspec` with runtime deps pulled from the previous `Gemfile`
  (one source of truth; `Gemfile` now uses `gemspec`).
- `Pikuri::VERSION` constant (`lib/pikuri/version.rb`); Zeitwerk is
  told to ignore the file since the constant is `VERSION`, not
  `Version`.
- `LICENSE` (MIT) and gemspec license metadata.
- `Pikuri::PROMPTS_DIR` and `Pikuri.prompt(name)` — downstream library
  users can read pikuri's bundled system prompts as a starting point
  for their own wiring.
- `Tool::Bash` emits a loud warning at construction: the tool runs
  commands unsandboxed under pikuri's UID and can read `~/.ssh`, AWS
  credentials, etc. A future release will gate this behind a sandbox.
- `Pikuri::Tool::SkillCatalog` + `Pikuri::Tool::Skill` — pikuri's
  implementation of the [Agent Skills standard](https://agentskills.io/specification).
  `SkillCatalog` discovers and validates `SKILL.md` files under the
  standard `.pikuri/skills`, `.claude/skills`, `.agents/skills`
  directories (precedence in that order); `Tool::Skill` is auto-
  registered by `Agent#initialize` whenever the wired-in catalog is
  non-empty, and the catalog's prompt block is appended to the system
  prompt so the LLM sees the available inventory without an extra
  round-trip.
- `mise.toml` pinning Ruby 3.3, matching the gemspec floor.
- `CHANGELOG.md` (this file).

### Changed
- **Namespace move.** Top-level `Agent`, `Tool`, and `UrlCache` are now
  `Pikuri::Agent`, `Pikuri::Tool`, `Pikuri::UrlCache`. All bundled
  tools, listeners, and helpers live under `Pikuri::*`. Standard gem
  layout: `lib/pikuri.rb` + `lib/pikuri/**/*.rb`; `spec/` mirrors it.
- `Pikuri::Agent::Listener::InMemoryList` renamed to `InMemoryMessageList`
  to clarify what it records (message events).
- `UrlCache::ROOT_DIR` follows the XDG Base Directory spec:
  `$XDG_CACHE_HOME/pikuri/url_cache` if set, else
  `~/.cache/pikuri/url_cache`. Previously `/tmp/pikuri/cache`.
- `bin/pikuri-chat` and `bin/pikuri-code` read prompts via
  `Pikuri.prompt(name)` instead of hand-rolled `__dir__` arithmetic.

### Project scope
- Pikuri targets **Linux**; macOS may work; Windows is unsupported.
  Rationale: the eventual Bash-tool sandbox (Docker / bubblewrap) and
  the existing reliance on POSIX shell + GNU coreutils + XDG layout
  make a Windows port more cost than benefit.
- Hard ceiling on source size: a privacy-conscious user should be able
  to read pikuri end-to-end in an evening and decide whether to trust
  it outside a sandbox. New features compete against that budget.
