# frozen_string_literal: true

require_relative 'lib/pikuri/version'

Gem::Specification.new do |spec|
  spec.name        = 'pikuri-core'
  spec.version     = Pikuri::VERSION
  spec.authors     = ['Martin Vysny']
  spec.email       = ['martin@vysny.me']

  spec.summary     = 'The minimal core of the pikuri AI-assistant toolkit (Agent, Tool framework, web tools, bin/pikuri-chat).'
  spec.description = <<~DESC
    pikuri-core is the lean, audit-friendly foundation of the pikuri family:
    Pikuri::Agent (a thin wrapper around ruby_llm's chat loop) with its
    Configurator + Extension protocol, the strict Pikuri::Tool framework, a
    listener surface for rendering / budgets / sub-agents, and four bundled
    stateless tools (calculator, web search, web scrape, fetch). Extensions
    (skills, MCP, workspace, coding stack, named-agent personas) live in
    sibling gems so a privacy-conscious user can install just this core and
    audit a minimal dependency tree. For the convenience bundle that pulls
    in everything, see the +pikuri+ metagem.
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

  # pikuri-core ships as a library. The bin/pikuri-chat script in the
  # gem payload is a dev / demo convenience — not advertised as a gem
  # executable.
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

  # Arithmetic backend for Pikuri::Tool::CALCULATOR.
  spec.add_dependency 'dentaku',          '~> 3.5'

  # HTTP client. Used by the web-fetch scraper, the Brave / DuckDuckGo
  # search providers, and (transitively) by ruby_llm.
  spec.add_dependency 'faraday',          '~> 2.9'

  # HTML parser. Used by the web-fetch scraper and by both search
  # providers (Brave, DuckDuckGo) to extract results from HTML responses.
  spec.add_dependency 'nokogiri',         '~> 1.19'

  # PDF text extraction. Used by Pikuri::Tool::Scraper::PDF to render
  # application/pdf responses as plain text for the agent loop.
  spec.add_dependency 'pdf-reader',       '~> 2.15'

  # ANSI color for terminal output (reasoning dim, tool calls cyan, …)
  # in the agent loop.
  spec.add_dependency 'rainbow',          '~> 3.1'

  # HTML → Markdown conversion. Used by Pikuri::Tool::Scraper::Simple to
  # hand the LLM Markdown rather than raw HTML.
  spec.add_dependency 'reverse_markdown', '~> 3.0'

  # Readability-style main-content extraction (require 'readability').
  # Used by Pikuri::Tool::Scraper::Simple to strip chrome from fetched
  # pages before converting to Markdown.
  spec.add_dependency 'ruby-readability', '~> 0.7'

  # LLM transport + agent loop. Pikuri sits on top of ruby_llm and owns
  # only the extension surface (see CLAUDE.md "Scope decisions" and "The
  # seam"). The tight pin reflects the bus-factor and Chat-API-churn risk
  # of leaning on a single upstream for the loop itself.
  spec.add_dependency 'ruby_llm',         '~> 1.15'

  # tsort is transitively required by Dentaku. It was a default gem in
  # Ruby <= 4.0 and is removed from defaults in 4.1; declaring it here
  # silences the load-time deprecation warning on 4.1+.
  spec.add_dependency 'tsort',            '~> 0.2'

  # Convention-based autoloader for lib/. Set up in lib/pikuri.rb; lets
  # every file declare exactly the constant matching its path without the
  # require_relative ceremony that creeps in once a project grows.
  spec.add_dependency 'zeitwerk',         '~> 2.7'
end
