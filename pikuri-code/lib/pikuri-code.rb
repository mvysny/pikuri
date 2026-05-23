# frozen_string_literal: true

require 'pikuri-core'
require 'pikuri-workspace'

# Entry file for the pikuri-code gem. After +require 'pikuri-code'+,
# +Pikuri::Tool::Bash+ and +Pikuri::Tool::CodingPaths+ are defined, and
# the gem's +prompts/+ directory is appended to +Pikuri::PROMPT_DIRS+ so
# +Pikuri.prompt(:'coding-system-prompt')+ resolves to the right
# file regardless of which gem actually shipped it.
#
# Zeitwerk loader is mounted under +Pikuri::Tool+ rather than rooted
# at this gem's lib/ — same trick pikuri-workspace uses to avoid
# Zeitwerk redefining the +Pikuri::Tool+ class as an inferred
# module. See pikuri-workspace/lib/pikuri-workspace.rb for the
# rationale.
Pikuri::PROMPT_DIRS << File.expand_path('../prompts', __dir__)

module Pikuri
  class Tool
    LOADER_PIKURI_CODE = Zeitwerk::Loader.new
    LOADER_PIKURI_CODE.tag = 'pikuri-code'
    LOADER_PIKURI_CODE.push_dir(File.expand_path('pikuri/tool', __dir__), namespace: Pikuri::Tool)
    LOADER_PIKURI_CODE.ignore(File.expand_path('pikuri-code.rb', __dir__))
    LOADER_PIKURI_CODE.setup
    LOADER_PIKURI_CODE.eager_load
  end
end
