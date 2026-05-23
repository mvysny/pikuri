# frozen_string_literal: true

require 'pikuri-core'
require 'pikuri-workspace'

# Entry file for the pikuri-code gem. After +require 'pikuri-code'+,
# +Pikuri::Tool::Bash+ and +Pikuri::Code::ToolchainPaths+ are defined,
# and the gem's +prompts/+ directory is appended to
# +Pikuri::PROMPT_DIRS+ so +Pikuri.prompt(:'coding-system-prompt')+
# resolves to the right file regardless of which gem actually shipped it.
#
# == Two non-overlapping Zeitwerk loaders
#
# Pikuri-code's +lib/+ tree splits into two namespaces:
#
# * +lib/pikuri/tool/+ → +Pikuri::Tool::*+ (notably +Tool::Bash+). This
#   subtree extends the +Pikuri::Tool+ *class* (owned by pikuri-core), so
#   its loader uses +push_dir(..., namespace: Pikuri::Tool)+ to tell
#   Zeitwerk "Tool already exists as a class, don't try to redefine it as
#   a module via implicit-namespace inference."
# * +lib/pikuri/code/+ → +Pikuri::Code::*+ (configuration helpers for
#   coding binaries, not +Pikuri::Tool+ subclasses). This subtree extends
#   the +Pikuri::Code+ module declared here in the entry file.
#
# Each loader manages a single +push_dir+ rooted at its own sibling
# subdir, so their trees never overlap (Zeitwerk rejects two loaders
# claiming the same path). The +Pikuri::Code+ module is declared *before*
# its loader's +push_dir+ call so the namespace constant already exists
# by the time Zeitwerk needs it.
Pikuri::PROMPT_DIRS << File.expand_path('../prompts', __dir__)

module Pikuri
  # Configuration helpers for binaries built on pikuri-code. Distinct
  # from +Pikuri::Tool+ — these aren't tools, they're values the binary
  # stitches into +Pikuri::Workspace::Filesystem+, the system prompt, etc.
  module Code; end

  class Tool
    LOADER_PIKURI_CODE_TOOL = Zeitwerk::Loader.new
    LOADER_PIKURI_CODE_TOOL.tag = 'pikuri-code-tool'
    LOADER_PIKURI_CODE_TOOL.push_dir(File.expand_path('pikuri/tool', __dir__), namespace: Pikuri::Tool)
    LOADER_PIKURI_CODE_TOOL.ignore(File.expand_path('pikuri-code.rb', __dir__))
    LOADER_PIKURI_CODE_TOOL.setup
    LOADER_PIKURI_CODE_TOOL.eager_load
  end

  module Code
    LOADER_PIKURI_CODE = Zeitwerk::Loader.new
    LOADER_PIKURI_CODE.tag = 'pikuri-code'
    LOADER_PIKURI_CODE.push_dir(File.expand_path('pikuri/code', __dir__), namespace: Pikuri::Code)
    LOADER_PIKURI_CODE.setup
    LOADER_PIKURI_CODE.eager_load
  end
end
