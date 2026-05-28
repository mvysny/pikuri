# frozen_string_literal: true

require_relative '../pikuri-core/lib/pikuri/version'

Gem::Specification.new do |spec|
  spec.name        = 'pikuri-memory'
  spec.version     = Pikuri::VERSION
  spec.authors     = ['Martin Vysny']
  spec.email       = ['martin@vysny.me']

  spec.summary     = 'Name reservation for an upcoming pikuri memory extension.'
  spec.description = <<~DESC
    pikuri-memory is a placeholder gem reserving the
    +pikuri-memory+ name on RubyGems for an upcoming "memories"
    extension to pikuri — durable long-lived facts about the user
    and the project that persist across conversations, modeled
    after the memory concept in
    https://github.com/nousresearch/hermes-agent. The gem ships
    no Ruby code yet; this release only claims the name so the
    eventual extension can publish under it.
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
end
