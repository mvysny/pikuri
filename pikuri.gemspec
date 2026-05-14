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
    'homepage_uri'          => spec.homepage,
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

  # Runtime deps — keep in sync with Gemfile (which now uses `gemspec`).
  spec.add_dependency 'dentaku',          '~> 3.5'
  spec.add_dependency 'faraday',          '~> 2.9'
  spec.add_dependency 'nokogiri',         '~> 1.19'
  spec.add_dependency 'pdf-reader',       '~> 2.15'
  spec.add_dependency 'rainbow',          '~> 3.1'
  spec.add_dependency 'reverse_markdown', '~> 3.0'
  spec.add_dependency 'ruby-readability', '~> 0.7'
  spec.add_dependency 'ruby_llm',         '~> 1.15'
  spec.add_dependency 'tsort',            '~> 0.2'
  spec.add_dependency 'tty-markdown',     '~> 0.7'
  spec.add_dependency 'zeitwerk',         '~> 2.7'
end
