# frozen_string_literal: true

require 'pikuri-core'

# Entry file for the pikuri-fileindex gem: search and read your files through
# the index the desktop already keeps (GNOME's localsearch, or recoll), never
# an index of our own. Two tools, +fileindex_search+ ({Pikuri::Fileindex::Search})
# and +fileindex_read+ ({Pikuri::Fileindex::Read}), bounded by the folders the
# host names ({Pikuri::Fileindex::Roots}), over whichever backend
# {Pikuri::Fileindex.pick} finds ready; {Pikuri::Fileindex::Extension} wires
# both.
#
# The load-bearing posture: the desktop's extractor, not pikuri, parsed every
# office file and PDF the tools return, and the model's words reach the index
# as bound query parameters, never spliced into the query text. Threat model
# and the backend survey: +pikuri-fileindex/design/architecture.md+.
module Pikuri
  module Fileindex
    LOADER = Zeitwerk::Loader.new
    LOADER.tag = 'pikuri-fileindex'
    LOADER.push_dir(__dir__)
    LOADER.ignore(File.expand_path('pikuri-fileindex.rb', __dir__))
    LOADER.setup
    LOADER.eager_load

    # @return [Array<Module>] backends in preference order: localsearch needs
    #   no setup on GNOME; recoll only works once the user built an index.
    BACKENDS = [LocalSearch, Recoll].freeze

    # Raised by {.pick} when no backend is ready; the message names each
    # one's reason and is meant for the user.
    class Unavailable < StandardError; end

    # The first backend ready to answer over +roots+, probing each once, in
    # order, so a host never probes one itself. Probing spawns a subprocess
    # per root, so a host picks once and hands the result to every agent:
    #
    #   roots = Pikuri::Fileindex::Roots.new(dirs: %w[~/notes], private: true, trusted: true)
    #   backend = Pikuri::Fileindex.pick(roots)      # => Pikuri::Fileindex::LocalSearch
    #   Pikuri::Agent.new(transport:, system_prompt:) do |c|
    #     c.add_extension Pikuri::Fileindex::Extension.new(roots:, backend:)
    #   end
    #
    # On a host with neither index ready, the {Unavailable} it raises reads:
    #
    #   no file index is ready:
    #   - localsearch: the 'tinysparql' command is missing. Install …
    #   - recoll: no index in /home/u/.recoll yet. Build one with `recollindex`.
    #
    # A backend is a module answering +unavailable_reason(folders:)+,
    # +search(query:, limit:, folders:)+ and +paths(query:, folders:)+ (a file
    # matching any group of the {Query}), +read_text+, +limitations+ and
    # +label+, with a +CommandError+: {LocalSearch} and {Recoll}.
    #
    # @param roots [Roots] the folders the agent will search
    # @param backends [Array<Module>] candidates in preference order
    # @return [Module] the first one whose +unavailable_reason+ is +nil+
    # @raise [Unavailable] when none is ready
    def self.pick(roots, backends: BACKENDS)
      reasons = []
      backends.each do |backend|
        reason = backend.unavailable_reason(folders: roots.dirs)
        return backend unless reason

        reasons << "- #{backend.label}: #{reason}"
      end
      raise Unavailable, "no file index is ready:\n#{reasons.join("\n")}"
    end
  end
end
