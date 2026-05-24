# frozen_string_literal: true

require 'pikuri-core'

# Entry file for the pikuri-workspace gem. After
# +require 'pikuri-workspace'+, +Pikuri::Workspace::Filesystem+,
# +Pikuri::Workspace::Confirmer+, and the five file tools (+Read+,
# +Write+, +Edit+, +Grep+, +Glob+) are all defined under the
# +Pikuri::Workspace+ namespace.
#
# The Zeitwerk loader is mounted plainly at this gem's +lib/+ root —
# Zeitwerk infers +Pikuri+ from pikuri-core and auto-vivifies
# +Pikuri::Workspace+ as a module from the +pikuri/workspace/+
# directory, so individual files like +lib/pikuri/workspace/read.rb+
# autoload as +Pikuri::Workspace::Read+.
module Pikuri
  module Workspace
    LOADER = Zeitwerk::Loader.new
    LOADER.tag = 'pikuri-workspace'
    LOADER.push_dir(__dir__)
    LOADER.ignore(File.expand_path('pikuri-workspace.rb', __dir__))
    LOADER.setup
    LOADER.eager_load

    # Reap +~/.cache/pikuri/workspace-*+ leftovers from sessions
    # killed before their +at_exit+ could fire. Best-effort; runs once
    # at gem load. See {Filesystem.sweep_stale_internal_temps!}.
    Filesystem.sweep_stale_internal_temps!
  end
end
