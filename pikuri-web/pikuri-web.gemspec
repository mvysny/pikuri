# frozen_string_literal: true

require_relative '../pikuri-core/lib/pikuri/version'

Gem::Specification.new do |spec|
  spec.name        = 'pikuri-web'
  spec.version     = Pikuri::VERSION
  spec.authors     = ['Martin Vysny']
  spec.email       = ['martin@vysny.me']

  spec.summary     = 'Web search, scrape and fetch tools for pikuri.'
  spec.description = <<~DESC
    pikuri-web gives a pikuri-core agent the tools that reach the internet:
    +web_search+ (DuckDuckGo, plus Brave and Exa when the host supplies a
    key), +web_scrape+ (a page as readable Markdown), +fetch+ (a URL's body
    verbatim) and +web_read_cached+ (a search result's page text, with no
    request of its own). Each brings untrusted text into the conversation
    and most send bytes out, so they live outside pikuri-core: an agent
    that doesn't wire them never loads them.
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
    'LICENSE',
    'README.md'
  ]
  spec.require_paths = ['lib']

  # Tool framework, Extractor registry and Paths live in pikuri-core;
  # lockstep-versioned so an upgrade to either always pulls the matching peer.
  spec.add_dependency 'pikuri-core', "= #{Pikuri::VERSION}"

  # HTTP client for the scraper and the Brave / Exa APIs.
  spec.add_dependency 'faraday',     '~> 2.9'

  # HTML parser for DuckDuckGo's result page, Brave's snippets and
  # Pikuri::Web::HTML.
  spec.add_dependency 'nokogiri',    '~> 1.19'

  # HTML → Markdown conversion in Pikuri::Web::HTML, so the LLM reads
  # Markdown rather than raw HTML.
  spec.add_dependency 'reverse_markdown', '~> 3.0'

  # Readability-style main-content extraction (require 'readability'), which
  # Pikuri::Web::HTML uses to strip a page's chrome before converting it.
  spec.add_dependency 'ruby-readability', '~> 0.7'
end
