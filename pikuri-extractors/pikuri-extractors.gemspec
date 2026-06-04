# frozen_string_literal: true

require_relative '../pikuri-core/lib/pikuri/version'

Gem::Specification.new do |spec|
  spec.name        = 'pikuri-extractors'
  spec.version     = Pikuri::VERSION
  spec.authors     = ['Martin Vysny']
  spec.email       = ['martin@vysny.me']

  spec.summary     = 'Sandboxed document extractors (DOCX/ODT/XLSX/PPTX/EPUB/RTF) for pikuri.'
  spec.description = <<~DESC
    pikuri-extractors plugs additional document formats into
    pikuri-core's +Pikuri::Extractor+ registry. The bundled
    +Pikuri::Extractors::DOCUMENTS+ extractor converts office
    documents (DOCX, ODT, XLSX, legacy XLS, PPTX, EPUB, RTF) to
    Markdown by piping the bytes through pandoc / markitdown —
    preferably inside a one-shot, networkless, locally-built docker
    container (the untrusted bytes never touch the host filesystem or
    network), falling back to a host-installed pandoc / markitdown
    CLI when docker is absent.

    Registration is explicit — +Pikuri::Extractors::DOCUMENTS.register+
    — so requiring the gem changes nothing by itself; the host script
    picks which extractors it wires in.
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
    # The DOCUMENTS extractor builds its converter image from these at
    # runtime — they must ship in the gem.
    'docker/Dockerfile',
    'docker/convert.sh',
    'LICENSE',
    'README.md'
  ]
  spec.require_paths = ['lib']

  # Extractor registry + Subprocess chokepoint live in pikuri-core;
  # lockstep-versioned so an upgrade to either always pulls the
  # matching peer.
  spec.add_dependency 'pikuri-core', "= #{Pikuri::VERSION}"
end
