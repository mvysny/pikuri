# frozen_string_literal: true

require 'pikuri-core'

# Entry file for the pikuri-workspace gem. After
# +require 'pikuri-workspace'+, +Pikuri::Workspace::Filesystem+, the
# +Pikuri::Workspace::Workspace+ composite (Filesystem + read record),
# +Pikuri::Workspace::Confirmer+, and the file tools (+Read+, +Write+,
# +Edit+, +Grep+, +Glob+, +FileList+) are all defined under the
# +Pikuri::Workspace+ namespace.
#
# The Zeitwerk loader is mounted plainly at this gem's +lib/+ root —
# Zeitwerk infers +Pikuri+ from pikuri-core and auto-vivifies
# +Pikuri::Workspace+ as a module from the +pikuri/workspace/+
# directory, so individual files like +lib/pikuri/workspace/read.rb+
# autoload as +Pikuri::Workspace::Read+. Its +prompts/+ joins
# +Pikuri::PROMPT_DIRS+ for +bin/pikuri-files+'s prompt.
Pikuri::PROMPT_DIRS << File.expand_path('../prompts', __dir__)

module Pikuri
  module Workspace
    LOADER = Zeitwerk::Loader.new
    LOADER.tag = 'pikuri-workspace'
    LOADER.push_dir(__dir__)
    LOADER.ignore(File.expand_path('pikuri-workspace.rb', __dir__))
    LOADER.setup
    LOADER.eager_load
  end
end
