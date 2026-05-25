# frozen_string_literal: true

require_relative '../pikuri-core/lib/pikuri/version'

Gem::Specification.new do |spec|
  spec.name        = 'pikuri-subagents'
  spec.version     = Pikuri::VERSION
  spec.authors     = ['Martin Vysny']
  spec.email       = ['martin@vysny.me']

  spec.summary     = 'Sub-agent / persona machinery + bundled personas + the pikuri-minions demo for pikuri.'
  spec.description = <<~DESC
    pikuri-subagents owns the sub-agent (delegation) feature top
    to bottom: the +Pikuri::SubAgent::SubAgentTool+ class (exposed
    to the LLM as the +agent+ tool), the +Persona+ record, the
    +Extension+ that wires it onto an agent, and the bundled
    +Pikuri::SubAgent::RESEARCHER+ persona (network-read only).
    Hosts that want sub-agents add this gem as a runtime dep and
    call +c.add_extension Pikuri::SubAgent::Extension.new(personas: [...])+
    inside their +Agent.new+ block — same opt-in shape as
    +pikuri-skills+ / +pikuri-mcp+. Also ships +bin/pikuri-minions+
    as a fan-out delegation demo.
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

  # pikuri-core ships the +Agent+ runtime + +Pikuri::Tool+ base class
  # that +SubAgentTool+ subclasses; the bundled +RESEARCHER+ persona's
  # +tool_names+ list (+web_search+, +web_scrape+, +fetch+) also
  # resolves to constants in pikuri-core.
  spec.add_dependency 'pikuri-core', "= #{Pikuri::VERSION}"
end
