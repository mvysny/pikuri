# frozen_string_literal: true

require_relative '../pikuri-core/lib/pikuri/version'

Gem::Specification.new do |spec|
  spec.name        = 'pikuri-workspace'
  spec.version     = Pikuri::VERSION
  spec.authors     = ['Martin Vysny']
  spec.email       = ['martin@vysny.me']

  spec.summary     = 'Filesystem tools (Read/Write/Edit/Grep/Glob) + Workspace + Confirmer seams for pikuri.'
  spec.description = <<~DESC
    pikuri-workspace adds "operate on a directory tree" to pikuri-core
    agents: the +Pikuri::Workspace::Filesystem+ class that scopes
    filesystem access to an anchor + explicit readable / writable
    prefix lists (with optional ephemeral temp playground), the
    +Pikuri::Workspace::Confirmer+ seam (+AUTO_APPROVE+ + +TERMINAL+)
    for user-state mutations, and five tools wired to those seams:
    +Pikuri::Workspace::Read+, +Pikuri::Workspace::Write+,
    +Pikuri::Workspace::Edit+, +Pikuri::Workspace::Grep+, and
    +Pikuri::Workspace::Glob+. Self-contained — no shell execution;
    +Pikuri::Code::Bash+ ships in pikuri-code on top of these.
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

  # The +Pikuri::Tool+ class + Pikuri::Tool::Parameters live in
  # pikuri-core; lockstep-versioned so an upgrade to either always
  # pulls the matching peer.
  spec.add_dependency 'pikuri-core', "= #{Pikuri::VERSION}"
end
