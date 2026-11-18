# frozen_string_literal: true

require_relative '../pikuri-core/lib/pikuri/version'

Gem::Specification.new do |spec|
  spec.name        = 'pikuri-fileindex'
  spec.version     = Pikuri::VERSION
  spec.authors     = ['Martin Vysny']
  spec.email       = ['martin@vysny.me']

  spec.summary     = "Search your files through the desktop's own file index, for pikuri."
  spec.description = <<~DESC
    pikuri-fileindex gives a pikuri agent two tools, fileindex_search
    and fileindex_read, over the file index the desktop already keeps:
    GNOME's localsearch, queried in SPARQL through tinysparql, or
    recoll. The index has already extracted the text of your PDFs and
    office documents, so the agent reads them with no parser of its own.

    Named for what it refuses to become: the owner of an index. It never
    builds, configures or refreshes one; the desktop keeps it fresh.
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

  # Tool framework, the Subprocess chokepoint and the Extractor paging live in
  # pikuri-core; lockstep-versioned so an upgrade to either always pulls the
  # matching peer.
  spec.add_dependency 'pikuri-core', "= #{Pikuri::VERSION}"
end
