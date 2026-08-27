# frozen_string_literal: true

require_relative '../pikuri-core/lib/pikuri/version'

Gem::Specification.new do |spec|
  spec.name        = 'pikuri-lsp'
  spec.version     = Pikuri::VERSION
  spec.authors     = ['Martin Vysny']
  spec.email       = ['martin@vysny.me']

  spec.summary     = 'Language Server Protocol client for pikuri — read-only code navigation.'
  spec.description = <<~DESC
    pikuri-lsp lets a pikuri agent ask a real language server the
    questions grep cannot answer: where is this defined, who calls it,
    what does it inherit from. It speaks LSP over a long-lived stdio
    child (+Pikuri::Lsp::Connection+ owns the JSON-RPC framing, the
    id demux and the reply to server-initiated requests) and models
    coordinates once, at the wire boundary, in
    +Pikuri::Lsp::Position+ / +Range+ / +Location+.

    Read-only by construction: no formatting, no code actions, no
    rename, no workspace edits. It reads what the server says and
    reports it.
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

  # Extension protocol, Tool base class, logging and the Finalizers
  # teardown registry; lockstep-versioned so an upgrade to either
  # always pulls the matching peer.
  spec.add_dependency 'pikuri-core', "= #{Pikuri::VERSION}"

  # Not optional: an LSP serves a *project*, and a project is a
  # +Workspace+ in pikuri. The tool needs +Filesystem#denied?+ for the
  # walked paths a server hands back (+D_walked_path_denylist+), the
  # root confinement that keeps the server's project and the
  # confinement boundary the same boundary, the seam-routed read behind
  # every document re-open, and +Filesystem#private?+ for its own
  # trifecta declaration.
  spec.add_dependency 'pikuri-workspace', "= #{Pikuri::VERSION}"
end
