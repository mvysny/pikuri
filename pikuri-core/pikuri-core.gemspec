# frozen_string_literal: true

require_relative 'lib/pikuri/version'

Gem::Specification.new do |spec|
  spec.name        = 'pikuri-core'
  spec.version     = Pikuri::VERSION
  spec.authors     = ['Martin Vysny']
  spec.email       = ['martin@vysny.me']

  spec.summary     = 'The minimal core of the pikuri AI-assistant toolkit (Agent, Tool framework, bin/pikuri-chat).'
  spec.description = <<~DESC
    pikuri-core is the lean, audit-friendly foundation of the pikuri family:
    Pikuri::Agent (a thin wrapper around ruby_llm's chat loop) with its
    Configurator + Extension protocol, the strict Pikuri::Tool framework, a
    listener surface for rendering / budgets / sub-agents, and a calculator
    as the one bundled example tool. Extensions (web tools, skills, MCP,
    workspace, coding stack, named-agent personas) live in
    sibling gems so a privacy-conscious user can install just this core and
    audit a minimal dependency tree.
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

  # pikuri-core ships as a library only. The bin/ scripts (pikuri-chat,
  # pikuri-wire-check) are dev / demo entry points that run from a source
  # checkout and are deliberately outside this list — not gem executables.
  spec.files = Dir[
    'lib/**/*.rb',
    'prompts/*.txt',
    'CHANGELOG.md',
    'LICENSE',
    'README.md'
  ]
  spec.require_paths = ['lib']

  # Runtime deps — alphabetical. The Gemfile pulls these in via `gemspec`
  # so this list is the single source of truth.

  # HTTP client. Used by the agent's request throttle and context-window
  # probe, and (transitively) by ruby_llm.
  spec.add_dependency 'faraday',          '~> 2.9'

  # ANSI color for terminal output (reasoning dim, tool calls tan, …)
  # in the agent loop.
  spec.add_dependency 'rainbow',          '~> 3.1'

  # LLM transport + agent loop. Pikuri sits on top of ruby_llm and owns
  # only the extension surface (see AGENTS.md "Invariants (seams)" and
  # "Out of scope"). The tight pin reflects the bus-factor and Chat-API-churn risk
  # of leaning on a single upstream for the loop itself.
  spec.add_dependency 'ruby_llm',         '~> 2.1'

  # Convention-based autoloader for lib/. Set up in lib/pikuri.rb; lets
  # every file declare exactly the constant matching its path without the
  # require_relative ceremony that creeps in once a project grows.
  spec.add_dependency 'zeitwerk',         '~> 2.7'
end
