# frozen_string_literal: true

require_relative '../pikuri-core/lib/pikuri/version'

Gem::Specification.new do |spec|
  spec.name        = 'pikuri-todo'
  spec.version     = Pikuri::VERSION
  spec.authors     = ['Martin Vysny']
  spec.email       = ['martin@vysny.me']

  spec.summary     = 'Per-session in-memory todo list + tools for pikuri.'
  spec.description = <<~DESC
    pikuri-todo gives a pikuri-core agent an in-memory todo list it can
    use to plan and track multi-step work. A +Pikuri::Todo::List+ holds
    the per-Agent state; four tools (+todo_create+, +todo_in_progress+,
    +todo_completed+, +todo_delete+) mutate it via content-as-identifier
    (no item IDs to hallucinate). +Pikuri::Todo::Extension+ wires the
    list and tools onto an +Pikuri::Agent+ via +c.add_extension(...)+
    inside the +Agent.new+ block.

    The list lives in process memory only — nothing is written to disk.
    Sub-agents do not inherit the parent's list (consistent with the
    "sub-agents do not inherit extensions" rule).
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

  # Extension protocol + Tool base class live in pikuri-core;
  # lockstep-versioned so an upgrade to either always pulls the
  # matching peer.
  spec.add_dependency 'pikuri-core', "= #{Pikuri::VERSION}"
end
