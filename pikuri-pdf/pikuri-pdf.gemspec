# frozen_string_literal: true

require_relative '../pikuri-core/lib/pikuri/version'

Gem::Specification.new do |spec|
  spec.name        = 'pikuri-pdf'
  spec.version     = Pikuri::VERSION
  spec.authors     = ['Martin Vysny']
  spec.email       = ['martin@vysny.me']

  spec.summary     = 'In-process, lazily-paged PDF text extraction for pikuri.'
  spec.description = <<~DESC
    pikuri-pdf plugs PDF → text extraction into pikuri-core's
    +Pikuri::Extractor+ registry. The bundled +Pikuri::Extractors::PDF+
    extractor wraps the pure-Ruby pdf-reader gem and extracts lazily:
    paged reads (the +read+ tool's windows) parse only the pages the
    window needs, so the first page of a 500-page PDF never pays for
    the other 499.

    Shipped separately from pikuri-core so the core's dependency tree
    stays minimal and auditable: pdf-reader and its transitive deps
    (Ascii85, afm, hashery, ruby-rc4, ttfunk) ride along only for hosts
    that opt into PDF support.

    Registration is explicit — +Pikuri::Extractors::PDF.register+ — so
    requiring the gem changes nothing by itself; the host script picks
    which extractors it wires in. One registration extends the +read+
    tool, +web_scrape+, and the pikuri-vectordb indexer simultaneously.
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

  # Extractor registry + FileType magic-byte sniffer live in
  # pikuri-core; lockstep-versioned so an upgrade to either always
  # pulls the matching peer.
  spec.add_dependency 'pikuri-core', "= #{Pikuri::VERSION}"

  # PDF text extraction. Pure Ruby — no native parser in the loop —
  # and lazy: a page's content stream parses only on Page#text access,
  # which is what makes the windowed reads cheap.
  spec.add_dependency 'pdf-reader', '~> 2.15'
end
