# frozen_string_literal: true

require 'pikuri-core'
require 'pikuri-workspace'
require 'pikuri-code'

# Entry file for the pikuri-os gem. Sets up a dedicated Zeitwerk loader
# rooted at this gem's +lib/+, contributing to the shared +Pikuri::+
# namespace alongside pikuri-core, pikuri-workspace, and pikuri-code.
#
# pikuri-os is the OS-integration layer and the home of the
# +bin/pikuri-os-assistant+ demo — a single, local, network-severed
# agent for understanding and operating the host OS. The design lives
# in +ideas/os-assistant.md+; the load-bearing posture is: egress is
# severed at the kernel (a net-isolated Bash sandbox), every mutation
# is confirmed, and durable memory is a single user-owned +MACHINE.md+
# rather than mem0 — so this gem depends on pikuri-code (Bash +
# sandbox) but NOT on pikuri-mcp/-memory/-vectordb.
#
# As the OS-specific surface lands it will define, under
# +Pikuri::Os+: the localsearch-backed content-search tool, the
# +MACHINE.md+ resident memory, and the boot-time machine grounding.
# The two cross-cutting pieces (the +FullFsNoNet+ Bash sandbox and the
# conservative read-only auto-confirmer) live in pikuri-code with the
# other OS-touching primitives, not here.
#
# The loader is per-gem (not shared with the sibling gems' loaders) so
# each gem owns its own +lib/+ tree; cooperation between gems is via
# the +Pikuri+ namespace alone.
module Pikuri
  module Os
    LOADER = Zeitwerk::Loader.new
    LOADER.tag = 'pikuri-os'
    LOADER.push_dir(__dir__)
    LOADER.ignore(File.expand_path('pikuri-os.rb', __dir__))
    LOADER.setup
    LOADER.eager_load
  end
end
