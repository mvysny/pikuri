# frozen_string_literal: true

require_relative '../pikuri-core/lib/pikuri/version'

Gem::Specification.new do |spec|
  spec.name        = 'pikuri-assistant'
  spec.version     = Pikuri::VERSION
  spec.authors     = ['Martin Vysny']
  spec.email       = ['martin@vysny.me']

  spec.summary     = 'MCP-aware assistant binary (pikuri-assistant) for pikuri.'
  spec.description = <<~DESC
    pikuri-assistant ships the demo +bin/pikuri-assistant+ binary on
    top of pikuri-core + pikuri-skills + pikuri-mcp: an interactive
    chat agent the user hand-edits to declare a +Pikuri::Mcp::Registry+
    of MCP servers. The +Pikuri.prompt+ search path picks up this
    gem's +prompts/pikuri-assistant.txt+ automatically on require —
    same multi-gem prompt-dir pattern as pikuri-code.
  DESC

  spec.homepage = 'https://codeberg.org/mvysny/pikuri'
  spec.license  = 'MIT'

  spec.required_ruby_version = '>= 3.3'

  spec.metadata = {
    'source_code_uri'       => "#{spec.homepage}/src/branch/master",
    'changelog_uri'         => "#{spec.homepage}/src/branch/master/CHANGELOG.md",
    'bug_tracker_uri'       => "#{spec.homepage}/issues",
    'rubygems_mfa_required' => 'true'
  }

  spec.files = Dir[
    'lib/**/*.rb',
    'prompts/*.txt',
    'LICENSE',
    'README.md'
  ]
  spec.require_paths = ['lib']

  # The assistant binary wires Agent (pikuri-core) + Skill::Extension
  # (pikuri-skills) + Mcp::Extension (pikuri-mcp) +
  # Tool::SubAgent::RESEARCHER (pikuri-subagents) together, plus the
  # sandboxed document extractor (pikuri-extractors — its PDF arm
  # supersedes pikuri-pdf here, so that gem is deliberately NOT a
  # dependency), VectorDb::Extension + the LIBRARIAN persona
  # (pikuri-vectordb), Memory::Extension (pikuri-memory) and the web
  # tools (pikuri-web). All
  # runtime deps, lockstep-pinned to the matching versions.
  #
  # NOTE: the vectordb and memory deps are forward-prep for the
  # assistant shape of book/assistant.md (egress + private-corpus
  # recall with the corpus quarantined in the LIBRARIAN sub-agent,
  # plus durable memories). The quarantined wiring wants a per-tool
  # pool choice on VectorDb::Extension, which registers all three
  # tools parent-visibly today — see design/ideas/vectordb-deferrals.md — so
  # the binary registers neither yet; the deps declare intent.
  spec.add_dependency 'pikuri-core',       "= #{Pikuri::VERSION}"
  spec.add_dependency 'pikuri-extractors', "= #{Pikuri::VERSION}"
  spec.add_dependency 'pikuri-mcp',        "= #{Pikuri::VERSION}"
  spec.add_dependency 'pikuri-memory',     "= #{Pikuri::VERSION}"
  spec.add_dependency 'pikuri-skills',     "= #{Pikuri::VERSION}"
  spec.add_dependency 'pikuri-subagents',  "= #{Pikuri::VERSION}"
  spec.add_dependency 'pikuri-vectordb',   "= #{Pikuri::VERSION}"
  spec.add_dependency 'pikuri-web',        "= #{Pikuri::VERSION}"
end
