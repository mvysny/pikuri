# frozen_string_literal: true

require_relative '../pikuri-core/lib/pikuri/version'

Gem::Specification.new do |spec|
  spec.name        = 'pikuri'
  spec.version     = Pikuri::VERSION
  spec.authors     = ['Martin Vysny']
  spec.email       = ['martin@vysny.me']

  spec.summary     = 'Convenience metagem: installs every pikuri-* gem.'
  spec.description = <<~DESC
    +pikuri+ is the convenience bundle for the pikuri AI-assistant
    toolkit. It ships no Ruby code of its own beyond a tiny entry
    file that +require+'s each sibling gem; +gem install pikuri+
    pulls in pikuri-core, pikuri-extractors, pikuri-pdf,
    pikuri-skills, pikuri-tasks, pikuri-memory, pikuri-workspace,
    pikuri-code, pikuri-mcp, pikuri-subagents, pikuri-vectordb, and
    pikuri-assistant in one shot, and +require 'pikuri'+ boots all
    of them.

    Privacy-conscious users who want a minimal dependency tree to
    audit should install +pikuri-core+ directly and opt into the
    extension gems they actually need — same +bundle add+ pattern
    Rails users have always had. See each pikuri-* gem's README
    for its individual surface.
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

  # All sibling gems, lockstep-versioned. Bumping +pikuri+ to
  # +X.Y.Z+ requires every sibling already at +X.Y.Z+ — the top-level
  # Rakefile's +rake release+ task handles the lockstep bump so this
  # constraint is satisfied automatically on every release.
  spec.add_dependency 'pikuri-assistant',  "= #{Pikuri::VERSION}"
  spec.add_dependency 'pikuri-code',       "= #{Pikuri::VERSION}"
  spec.add_dependency 'pikuri-core',       "= #{Pikuri::VERSION}"
  spec.add_dependency 'pikuri-extractors', "= #{Pikuri::VERSION}"
  spec.add_dependency 'pikuri-mcp',        "= #{Pikuri::VERSION}"
  spec.add_dependency 'pikuri-memory',     "= #{Pikuri::VERSION}"
  spec.add_dependency 'pikuri-pdf',        "= #{Pikuri::VERSION}"
  spec.add_dependency 'pikuri-skills',     "= #{Pikuri::VERSION}"
  spec.add_dependency 'pikuri-subagents',  "= #{Pikuri::VERSION}"
  spec.add_dependency 'pikuri-tasks',      "= #{Pikuri::VERSION}"
  spec.add_dependency 'pikuri-vectordb',   "= #{Pikuri::VERSION}"
  spec.add_dependency 'pikuri-workspace',  "= #{Pikuri::VERSION}"
end
