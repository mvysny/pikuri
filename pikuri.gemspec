# frozen_string_literal: true

require_relative 'lib/pikuri/version'

Gem::Specification.new do |spec|
  spec.name        = 'pikuri'
  spec.version     = Pikuri::VERSION
  spec.authors     = ['Martin Vysny']
  spec.email       = ['martin@vysny.me']

  spec.summary     = 'A small, privacy-first Ruby AI assistant you run on your own machine.'
  spec.description = <<~DESC
    Two CLI binaries on a shared core: pikuri-chat (general-purpose chat with
    calculator, web search, web scrape, fetch) and pikuri-code (in-repo coding
    agent with read/write/edit/grep/glob/bash). Wired by default to a local
    llama.cpp server so conversations never leave your machine unless you opt
    in. Built on top of ruby_llm, with pikuri owning the extension surface:
    strict tool-argument validation, listener-based rendering, a step-budget
    with synthesizer rescue, sub-agents, and bundled tools.
  DESC

  spec.homepage = 'https://codeberg.org/mvysny/pikuri'
  spec.license  = 'MIT'

  spec.required_ruby_version = '>= 3.3'

  spec.metadata = {
    'homepage_uri'          => spec.homepage,
    'bug_tracker_uri'       => "#{spec.homepage}/issues",
    'rubygems_mfa_required' => 'true'
  }

  spec.files = Dir[
    'lib/**/*.rb',
    'bin/pikuri-*',
    'prompts/*.txt',
    'LICENSE',
    'README.md',
    'GETTING_STARTED.md'
  ]
  spec.bindir        = 'bin'
  spec.executables   = ['pikuri-chat', 'pikuri-code']
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
