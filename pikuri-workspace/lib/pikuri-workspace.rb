# frozen_string_literal: true

require 'pikuri-core'

# Entry file for the pikuri-workspace gem. After
# +require 'pikuri-workspace'+, +Pikuri::Tool::Workspace+,
# +Pikuri::Tool::Confirmer+, and the five file tools (+Read+,
# +Write+, +Edit+, +Grep+, +Glob+) are all defined.
#
# The Zeitwerk loader is mounted under +Pikuri::Tool+ (rather than
# rooted at this gem's +lib/+) because +Pikuri::Tool+ is a class
# owned by pikuri-core; without the explicit +namespace:+ argument,
# Zeitwerk would try to redefine +Pikuri::Tool+ as a module from the
# implicit-namespace inference, which would conflict. Mounting at
# the existing class side-steps the conflict and lets our nested
# files (+lib/pikuri/tool/workspace.rb+ → +Pikuri::Tool::Workspace+,
# etc.) autoload naturally.
module Pikuri
  class Tool
    LOADER = Zeitwerk::Loader.new
    LOADER.tag = 'pikuri-workspace'
    LOADER.push_dir(File.expand_path('pikuri/tool', __dir__), namespace: Pikuri::Tool)
    LOADER.ignore(File.expand_path('pikuri-workspace.rb', __dir__))
    LOADER.setup
    LOADER.eager_load
  end
end
