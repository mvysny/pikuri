# pikuri-skills

[Agent Skills standard](https://agentskills.io/specification)
support for the [pikuri](https://codeberg.org/mvysny/pikuri)
AI-assistant toolkit.

Provides:
- `Pikuri::Skill::Catalog` — discovery + validation of skill folders
  under `.pikuri/skills`, `.claude/skills`, `.agents/skills` beneath
  each *search base* you supply (typically the project root and
  `Dir.home`).
- `Pikuri::Skill::SkillTool` — the loading tool the LLM uses to pull
  a skill's body into the conversation on demand.
- `Pikuri::Skill::Extension` — wires both into a `Pikuri::Agent` via
  the `c.add_extension(...)` block API.

## Install

```ruby
# Gemfile
gem 'pikuri-skills'
```

## Usage

```ruby
require 'pikuri-core'
require 'pikuri-skills'

# Pass the directories to search under. The catalog scans
# .pikuri/skills, .claude/skills and .agents/skills beneath each base;
# missing subdirs are skipped. Earlier bases beat later ones on a
# name collision.
catalog = Pikuri::Skill::Catalog::Bundled.new(
  search_bases: [project_root, Dir.home]
)

agent = Pikuri::Agent.new(transport: ..., system_prompt: ...) do |c|
  c.add_extension(Pikuri::Skill::Extension.new(catalog: catalog))
end
```

When the catalog is non-empty, the extension's `configure` appends
`<available_skills>` to the system prompt (listing every discovered
skill) and registers the `skill` tool. The LLM invokes `skill` with a
name; the tool returns the skill's body wrapped with its base
directory so the LLM can resolve sidecar files via `read`.

## Further reading

- **Narrative walkthrough:**
  [the skills chapter of the pikuri guide](../book/skills.md) —
  how skill folders are discovered, the `SKILL.md` format, and a
  worked drop-in example. (Currently a stub chapter; the API
  surface lives in the YARD docs below.)
- **API reference:** browse the YARD docs at
  <https://rubydoc.info/gems/pikuri-skills> (once published), or
  run `bundle exec yard` in this directory for a local copy.
