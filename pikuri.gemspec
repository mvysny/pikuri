# frozen_string_literal: true

require_relative 'lib/pikuri/version'

Gem::Specification.new do |spec|
  spec.name        = 'pikuri'
  spec.version     = Pikuri::VERSION
  spec.authors     = ['Martin Vysny']
  spec.email       = ['martin@vysny.me']

  spec.summary     = 'A small, privacy-first Ruby toolkit for building local AI assistants.'
  spec.description = <<~DESC
    A library for assembling AI assistants: Pikuri::Agent (a thin wrapper around
    ruby_llm's chat loop), Pikuri::Tool with strict argument validation, a
    listener surface for rendering / budgets / sub-agents, and a small set of
    bundled tools (calculator, web search, web scrape, fetch, plus six coding
    tools: read / write / edit / grep / glob / bash). Downstream projects
    (notably the planned pikuri-tui) wire these into actual binaries. The repo
    also ships `bin/pikuri-chat` and `bin/pikuri-code` as demo entry points,
    but they are NOT installed by `gem install pikuri` — they exist to show
    how to wire the library together and to support development.
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

  # pikuri ships as a library. The bin/pikuri-* scripts in the repo are
  # dev / demo conveniences — not advertised as gem executables, and not
  # included in the gem payload. Production binaries (e.g. the planned
  # pikuri-tui) will live in their own gems and consume pikuri-as-library.
  spec.files = Dir[
    'lib/**/*.rb',
    'prompts/*.txt',
    'CHANGELOG.md',
    'LICENSE',
    'README.md',
    'GETTING_STARTED.md'
  ]
  spec.require_paths = ['lib']

  # Runtime deps — alphabetical. The Gemfile pulls these in via `gemspec`
  # so this list is the single source of truth.

  # Arithmetic backend for Pikuri::Tool::CALCULATOR.
  spec.add_dependency 'dentaku',          '~> 3.5'

  # HTTP client. Used by the web-fetch scraper, the Brave / DuckDuckGo
  # search providers, and (transitively) by ruby_llm.
  spec.add_dependency 'faraday',          '~> 2.9'

  # Model Context Protocol client + server. Used by
  # Pikuri::McpServers to spawn and talk to external MCP servers, and
  # by spec/support/test_mcp_server.rb (the in-tree test server side).
  # The gem owns subprocess lifecycle, JSON-RPC framing, and the
  # tools/list / tools/call round-trips; pikuri's adapter converts
  # discovered MCP tools into RubyLLM::Tool subclasses.
  spec.add_dependency 'mcp',              '~> 0.17'

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

  # Renders the assistant's Markdown replies to a terminal-friendly form
  # in the agent loop.
  spec.add_dependency 'tty-markdown',     '~> 0.7'

  # Convention-based autoloader for lib/. Set up in lib/pikuri.rb; lets
  # every file declare exactly the constant matching its path without the
  # require_relative ceremony that creeps in once a project grows.
  spec.add_dependency 'zeitwerk',         '~> 2.7'
end
