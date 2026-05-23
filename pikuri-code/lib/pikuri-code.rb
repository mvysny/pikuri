# frozen_string_literal: true

require 'pikuri-core'
require 'pikuri-workspace'

# Entry file for the pikuri-code gem. After +require 'pikuri-code'+,
# +Pikuri::Code::Bash+ and +Pikuri::Code::ToolchainPaths+ are defined,
# and the gem's +prompts/+ directory is appended to
# +Pikuri::PROMPT_DIRS+ so +Pikuri.prompt(:'coding-system-prompt')+
# resolves to the right file regardless of which gem actually shipped it.
#
# The Zeitwerk loader is mounted plainly at this gem's +lib/+ root —
# Zeitwerk infers +Pikuri+ from pikuri-core and auto-vivifies
# +Pikuri::Code+ as a module from the +pikuri/code/+ directory, so
# individual files like +lib/pikuri/code/bash.rb+ autoload as
# +Pikuri::Code::Bash+ (a +Pikuri::Tool+ subclass) and
# +lib/pikuri/code/bash/sandbox.rb+ as +Pikuri::Code::Bash::Sandbox+.
Pikuri::PROMPT_DIRS << File.expand_path('../prompts', __dir__)

module Pikuri
  module Code
    LOADER = Zeitwerk::Loader.new
    LOADER.tag = 'pikuri-code'
    LOADER.push_dir(__dir__)
    LOADER.ignore(File.expand_path('pikuri-code.rb', __dir__))
    LOADER.setup
    LOADER.eager_load
  end
end
