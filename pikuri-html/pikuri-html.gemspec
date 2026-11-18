# frozen_string_literal: true

require_relative '../pikuri-core/lib/pikuri/version'

Gem::Specification.new do |spec|
  spec.name        = 'pikuri-html'
  spec.version     = Pikuri::VERSION
  spec.authors     = ['Martin Vysny']
  spec.email       = ['martin@vysny.me']

  spec.summary     = 'HTML → Markdown extraction for pikuri, with no network.'
  spec.description = <<~DESC
    pikuri-html plugs HTML → Markdown rendering into pikuri-core's
    +Pikuri::Extractor+ registry: +Pikuri::Extractors::HTML+ keeps a
    page's or a mail's content (readability plus a <main> fallback,
    and any schema.org JSON-LD) and drops its CSS, layout and chrome.
    Text the markup hides is kept, labelled as hidden.

    A gem of its own so an offline agent (the Thunderbird mail agent
    reading an HTML attachment) renders HTML without loading
    pikuri-web, the gem that reaches the internet. Requiring it
    registers the extractor.
  DESC

  spec.homepage = 'https://github.com/mvysny/pikuri'
  spec.license  = 'MIT'

  spec.required_ruby_version = '>= 3.3'

  spec.metadata = {
    'source_code_uri'       => "#{spec.homepage}/tree/master",
    'changelog_uri'         => "#{spec.homepage}/blob/master/CHANGELOG.md",
    'bug_tracker_uri'       => "#{spec.homepage}/issues",
    'rubygems_mfa_required' => 'true'
  }

  spec.files = Dir[
    'lib/**/*.rb',
    'LICENSE',
    'README.md'
  ]
  spec.require_paths = ['lib']

  # Extractor registry lives in pikuri-core; lockstep-versioned so an upgrade
  # to either always pulls the matching peer.
  spec.add_dependency 'pikuri-core', "= #{Pikuri::VERSION}"

  # Parses the document, finds hidden elements and JSON-LD blocks.
  spec.add_dependency 'nokogiri', '~> 1.19'

  # HTML → Markdown conversion, so the LLM reads Markdown rather than raw HTML.
  spec.add_dependency 'reverse_markdown', '~> 3.0'

  # Readability-style main-content extraction (require 'readability'), which
  # strips a page's chrome before converting it.
  spec.add_dependency 'ruby-readability', '~> 0.7'
end
