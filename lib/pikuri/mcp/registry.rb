# frozen_string_literal: true

module Pikuri
  module Mcp
  # Pure configuration for MCP servers — id → transport descriptor
  # pairs and nothing more. No I/O, no live state. {Servers}
  # consumes a registry at construction time to start the actual
  # clients.
  #
  # Split from {Servers} so the dependency on the +mcp+ gem and on
  # subprocess / network lifecycle is confined to the runtime side.
  # Tests that only need to exercise registry value semantics never
  # have to load the gem or open a transport.
  #
  # == Entry types
  #
  # Two sibling value classes, picked per server. The registry holds
  # a mixed array; {Servers#start_one} dispatches on the type.
  #
  # * {StdioEntry} — local subprocess, +command:+ argv. The +mcp+ gem
  #   spawns it; see CLAUDE.md "Subprocess seam" carve-out.
  # * {HttpEntry} — remote MCP endpoint, +url:+ + optional +headers:+.
  #   Plain Faraday under the hood — no subprocess, no carve-out
  #   needed.
  #
  # == EMPTY
  #
  # The +EMPTY+ singleton is the default for {Agent#initialize}'s
  # +mcp_registry:+ kwarg. When the registry is empty {Agent}
  # short-circuits — no {Servers} is built, no +mcp_connect+ tool is
  # registered, no +<available_mcps>+ block is appended to the system
  # prompt. The +pikuri-chat+ binary relies on this short-circuit so it
  # can omit the kwarg entirely.
  #
  # Same shape as {Tool::SkillCatalog::EMPTY}.
  class Registry
    # One local-subprocess MCP server's configuration: a unique id
    # (used by the LLM to call +mcp_connect+) and the argv array used
    # to spawn the server process.
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
    StdioEntry = Data.define(:id, :command)

    # One remote-HTTP MCP server's configuration: a unique id, the
    # endpoint URL, and optional headers (typically auth) sent on every
    # request.
    #
    # No OAuth in v1 — if the endpoint needs a bearer token, pass it
    # via +headers:+ ({+"Authorization" => "Bearer ..."+}). Wiring the
    # gem's +oauth:+ provider would start a browser flow and persist
    # tokens; deferred until someone needs it. See CLAUDE.md
    # "Subprocess seam" — HTTP entries don't fall under the carve-out
    # because nothing is spawned.
    #
    # @!attribute [r] id
    #   @return [String] short identifier the LLM uses to refer to this
    #     server, e.g. +"hubspot"+.
    # @!attribute [r] url
    #   @return [String] full MCP endpoint URL, e.g.
    #     +"https://mcp.example.com/v1"+.
    # @!attribute [r] headers
    #   @return [Hash{String => String}] headers sent on every request.
    #     Frozen. Defaults to an empty hash.
    HttpEntry = Data.define(:id, :url, :headers) do
      def initialize(id:, url:, headers: {})
        super(id: id, url: url, headers: headers.freeze)
      end
    end

    # @param entries [Array<StdioEntry, HttpEntry>] zero or more server
    #   definitions. Order is preserved; duplicate ids raise.
    # @return [Registry]
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

    # @return [Array<StdioEntry, HttpEntry>] all configured entries, in
    #   declaration order.
    attr_reader :entries

    # @return [Boolean] true when no servers are configured. {Agent}
    #   keys its MCP auto-wiring off this — empty registry ⇒ no surface
    #   change, same pattern as {Tool::SkillCatalog#empty?}.
    def empty?
      @entries.empty?
    end

    # @param id [String]
    # @return [StdioEntry, HttpEntry, nil] the entry with this id, or
    #   +nil+.
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
end
