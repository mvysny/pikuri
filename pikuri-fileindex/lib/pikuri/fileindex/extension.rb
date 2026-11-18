# frozen_string_literal: true

module Pikuri
  module Fileindex
    # Wires +fileindex_search+ and +fileindex_read+ over one backend and one
    # set of roots, so the two tools can never disagree about which folders
    # the agent reaches:
    #
    #   roots = Pikuri::Fileindex::Roots.new(dirs: %w[~/Documents ~/Downloads], private: true)
    #   backend = Pikuri::Fileindex.pick(roots)   # once per process; raises Unavailable
    #   Pikuri::Agent.new(transport:, system_prompt:) do |c|
    #     c.add_extension Pikuri::Fileindex::Extension.new(roots:, backend:)
    #   end
    #
    # The backend comes in rather than being picked here: picking probes the
    # index once per root, and an extension is built anew for every agent.
    class Extension
      include Pikuri::Agent::Extension

      # @param roots [Roots] the folders both tools reach
      # @param backend [Module] a ready backend, from {Fileindex.pick}
      def initialize(roots:, backend:)
        @roots = roots
        @backend = backend
      end

      # @param c [Pikuri::Agent::Configurator]
      # @return [void]
      def configure(c)
        c.add_tool Search.new(backend: @backend, roots: @roots)
        c.add_tool Read.new(backend: @backend, roots: @roots)
        nil
      end
    end
  end
end
