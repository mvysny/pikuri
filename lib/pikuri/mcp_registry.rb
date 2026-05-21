# frozen_string_literal: true

module Pikuri
  # Pure configuration for MCP servers — id → command argv pairs and
  # nothing more. No I/O, no live state. {McpServers} consumes a
  # registry at construction time to spawn the actual clients.
  #
  # Split from {McpServers} so the dependency on the +mcp+ gem and on
  # subprocess lifecycle is confined to the runtime side. Tests that
  # only need to exercise registry value semantics never have to load
  # the gem or spawn anything.
  #
  # == EMPTY
  #
  # The +EMPTY+ singleton is the default for {Agent#initialize}'s
  # +mcp_registry:+ kwarg. When the registry is empty {Agent}
  # short-circuits — no {McpServers} is built, no +mcp_connect+ tool is
  # registered, no +<available_mcps>+ block is appended to the system
  # prompt. The +pikuri-chat+ binary relies on this short-circuit so it
  # can omit the kwarg entirely.
  #
  # Same shape as {Tool::SkillCatalog::EMPTY}.
  class McpRegistry
    # One MCP server's configuration: a unique id (used by the LLM to
    # call +mcp_connect+) and the argv array used to spawn the server
    # process.
    #
    # +command+ is an argv array (not a shell string) to align with
    # {Pikuri::Subprocess.spawn} conventions even though the +mcp+ gem
    # owns the actual spawn — see CLAUDE.md "Subprocess seam" carve-out.
    # First element is the executable; remaining elements are arguments.
    #
    # @!attribute [r] id
    #   @return [String] short identifier the LLM uses to refer to this
    #     server, e.g. +"gmail"+ or +"maven-tools"+.
    # @!attribute [r] command
    #   @return [Array<String>] argv to spawn the server,
    #     e.g. +["npx", "mcp-maven-deps"]+.
    Entry = Data.define(:id, :command)

    # @param entries [Array<Entry>] zero or more server definitions.
    #   Order is preserved; duplicate ids raise.
    # @return [McpRegistry]
    # @raise [ArgumentError] if two entries share an id.
    def initialize(entries: [])
      seen = {}
      entries.each do |e|
        raise ArgumentError, "Duplicate MCP id #{e.id.inspect}" if seen.key?(e.id)

        seen[e.id] = true
      end
      @entries = entries.dup.freeze
      freeze
    end

    # @return [Array<Entry>] all configured entries, in declaration order.
    attr_reader :entries

    # @return [Boolean] true when no servers are configured. {Agent}
    #   keys its MCP auto-wiring off this — empty registry ⇒ no surface
    #   change, same pattern as {Tool::SkillCatalog#empty?}.
    def empty?
      @entries.empty?
    end

    # @param id [String]
    # @return [Entry, nil] the entry with this id, or +nil+.
    def get(id)
      @entries.find { |e| e.id == id }
    end

    # @return [Array<String>] all configured ids, in declaration order.
    def ids
      @entries.map(&:id)
    end

    # Frozen empty registry. Used as the default for
    # {Agent#initialize}'s +mcp_registry:+ kwarg.
    EMPTY = new.freeze
  end
end
