# frozen_string_literal: true

require_relative '../pikuri-core/lib/pikuri/version'

Gem::Specification.new do |spec|
  spec.name        = 'pikuri-subagents'
  spec.version     = Pikuri::VERSION
  spec.authors     = ['Martin Vysny']
  spec.email       = ['martin@vysny.me']

  spec.summary     = 'Bundled sub-agent personas + the pikuri-minions demo for pikuri.'
  spec.description = <<~DESC
    pikuri-subagents is the home for bundled +Pikuri::Tool::SubAgent::Persona+
    instances + the +bin/pikuri-minions+ demo that shows fan-out
    delegation. pikuri-core hosts the machinery (the +Tool::SubAgent+
    tool, the +Persona+ record, +Configurator#allow_agent+); this
    gem populates it with concrete personas. Today's surface is
    +Pikuri::Tool::SubAgent::RESEARCHER+ (network read only). Hosts
    that want sub-agents add this gem as a runtime dep and call
    +c.allow_agent(...)+ in their +Agent.new+ block — same opt-in
    shape as +pikuri-skills+ / +pikuri-mcp+ extensions.
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

  # +Pikuri::Tool::SubAgent::Persona+ and the +Tool::SubAgent+ class
  # live in pikuri-core; we only contribute populated +Persona+
  # instances on top. The bundled +RESEARCHER+ persona's
  # +tool_names+ list (+web_search+, +web_scrape+, +fetch+) all
  # resolve to constants in pikuri-core too.
  spec.add_dependency 'pikuri-core', "= #{Pikuri::VERSION}"
end
