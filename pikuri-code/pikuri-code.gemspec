# frozen_string_literal: true

require_relative '../pikuri-core/lib/pikuri/version'

Gem::Specification.new do |spec|
  spec.name        = 'pikuri-code'
  spec.version     = Pikuri::VERSION
  spec.authors     = ['Martin Vysny']
  spec.email       = ['martin@vysny.me']

  spec.summary     = 'In-repo coding-agent shell tool (Bash) + pikuri-code binary.'
  spec.description = <<~DESC
    pikuri-code adds the shell-and-dev-loop layer on top of
    pikuri-workspace's filesystem tools: a +Pikuri::Tool::Bash+ that
    runs commands via the +Pikuri::Subprocess+ chokepoint with
    +Confirmer+ gating, plus the demo +bin/pikuri-code+ binary that
    wires file + shell + web tools into an interactive coding agent
    rooted at the current working directory. The +Pikuri.prompt+
    search path picks up this gem's +prompts/coding-system-prompt.txt+
    automatically on require.
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
    'prompts/*.txt',
    'LICENSE',
    'README.md'
  ]
  spec.require_paths = ['lib']

  # +Pikuri::Tool+ + +Pikuri::Subprocess+ live in pikuri-core; lockstep
  # version-pinned so an upgrade to either always pulls the matching peer.
  spec.add_dependency 'pikuri-core',      "= #{Pikuri::VERSION}"

  # +Pikuri::Workspace::Filesystem+ + +Pikuri::Workspace::Confirmer+ live
  # in pikuri-workspace; Bash takes both via constructor.
  spec.add_dependency 'pikuri-workspace', "= #{Pikuri::VERSION}"
end
