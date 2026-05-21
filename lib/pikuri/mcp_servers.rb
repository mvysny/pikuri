# frozen_string_literal: true

require 'mcp'
require 'set'

module Pikuri
  # Runtime side of MCP support: spawns the configured servers, holds
  # the live clients, and is the seam where the +mcp+ gem dependency
  # lives. Constructed from an {McpRegistry} (config), eager-starts
  # every entry at +#initialize+, registers an +at_exit+ hook to close
  # cleanly on process exit.
  #
  # == Transports
  #
  # Each {McpRegistry} entry maps to one of the +mcp+ gem's transports:
  #
  # * {McpRegistry::StdioEntry} → +MCP::Client::Stdio+ (local subprocess).
  # * {McpRegistry::HttpEntry}  → +MCP::Client::HTTP+ (remote endpoint).
  #
  # +#start_one+ pattern-matches on the entry type and constructs the
  # right transport; everything downstream (client, tools cache, audit
  # log, +#close+) is polymorphic — both transport classes expose
  # +#close+ with the same idempotent contract.
  #
  # == Lifecycle and the +Subprocess.spawn+ carve-out
  #
  # The +Subprocess.spawn+ chokepoint carve-out applies *only* to stdio
  # entries. The +mcp+ gem owns the subprocess lifecycle:
  # +MCP::Client::Stdio+ calls +Process.spawn+ internally; forcing it
  # through pikuri's {Pikuri::Subprocess.spawn} chokepoint would mean
  # either forking the gem or threading custom IO pipes through its
  # API — duplicating work the gem exists to do. So stdio MCP is the
  # documented exception to the chokepoint convention in CLAUDE.md
  # "Scope decisions": the gem spawns, we own +#close+, and
  # +at_exit { close }+ runs from inside {#initialize} to make sure
  # cleanup happens on every exit path. Graceful close on a stdio
  # transport closes stdin → server's read loop hits EOF → server
  # self-terminates, per the MCP spec.
  #
  # HTTP entries don't spawn anything — they're plain Faraday — so the
  # carve-out doesn't apply. +at_exit { close }+ still runs to send the
  # session-termination +DELETE+ per spec.
  #
  # == What lives where
  #
  # * {McpServers}: eager startup, audit logging, the client/transport
  #   hash, +#close+, the +<available_mcps>+ snippet renderer, and the
  #   shared +register_tools_with_agent+ that actually wires MCP tools
  #   into a given agent's underlying +RubyLLM::Chat+.
  # * {View}: thin facade for sub-agents — same public surface as
  #   {McpServers} but every method delegates to the root. Sub-agents
  #   share the parent's live clients; only the root owns +#close+.
  # * {McpConnect}: the +mcp_connect+ tool the LLM calls. Private inner
  #   {Pikuri::Tool} subclass instantiated per-agent by
  #   {Agent#initialize}. Tracks its own +Set+ of activated ids so
  #   re-activation comes back as an LLM-actionable +"Error: ..."+
  #   String. Each agent (parent + each sub-agent) gets its own
  #   instance with its own set, so activation is strictly per-agent.
  #
  # == Why MCP tools bypass +Pikuri::Tool+
  #
  # MCP tools arrive with JSON Schema in their +input_schema+;
  # +RubyLLM::Tool.params(schema)+ accepts that shape directly. We
  # therefore synthesize +RubyLLM::Tool+ subclasses inside this class
  # and feed them through {Agent#internal_add_tool} — no
  # +Pikuri::Tool::Parameters+ in the middle. The strict-validation
  # contract pikuri commits to for native tools is intentionally not
  # extended to MCP tools in v1; MCP-side validation catches bad input,
  # and the provenance prefix + audit log are the compensating
  # transparency.
  class McpServers
    LOGGER = Pikuri.logger_for('McpServers')
    private_constant :LOGGER

    # @param registry [McpRegistry] configured servers to start.
    # @return [McpServers]
    def initialize(registry)
      @registry    = registry
      @clients     = {} # id => MCP::Client (only for servers that started)
      @transports  = {} # id => MCP::Client::Stdio or MCP::Client::HTTP
      @tools_cache = {} # id => Array<MCP::Client::Tool>
      @descriptions = {} # id => short description shown in <available_mcps>
      @live_ids    = []
      @closed      = false

      start_all
      register_at_exit
    end

    # @return [Array<String>] ids of servers that successfully started.
    #   Excludes any whose subprocess spawn or handshake failed (those
    #   are logged as warnings and dropped). Identical to {McpRegistry#ids}
    #   when no startup failures occurred.
    attr_reader :live_ids

    # @return [Boolean] true when no servers are alive (either the
    #   registry was empty, or every configured server failed to start).
    def empty?
      @live_ids.empty?
    end

    # Build a sub-agent-facing facade. Sub-agents share the parent's
    # live clients (no re-spawn) but track their own activation state.
    #
    # @return [View]
    def view_for_sub_agent
      View.new(self)
    end

    # Build the +mcp_connect+ tool bound to the given agent. The agent
    # passes itself so the tool can call +agent.internal_add_tool+
    # without a circular constructor dance. Each call returns a fresh
    # {McpConnect} with an empty activation set.
    #
    # @param agent [Agent]
    # @return [McpConnect]
    def build_mcp_connect_tool(agent)
      McpConnect.new(view: self, agent: agent)
    end

    # System-prompt block advertising every live MCP server to the LLM.
    # Empty string when no servers are alive so the caller can
    # unconditionally concatenate, same shape as
    # {Tool::SkillCatalog#format_for_prompt}. The block is *not*
    # duplicated into the +mcp_connect+ tool description — the
    # available-ids list lives in one semantic home.
    #
    # @return [String]
    def system_prompt_snippet
      return '' if empty?

      lines = [
        '',
        '',
        'The following MCP (Model Context Protocol) servers expose tools you can pull into your toolset on demand.',
        "Call `mcp_connect` with a server's id to register its tools. Schemas only enter context after you connect.",
        '',
        '<available_mcps>'
      ]
      @live_ids.each do |id|
        lines << '  <mcp>'
        lines << "    <id>#{escape_xml(id)}</id>"
        lines << "    <description>#{escape_xml(@descriptions[id] || '(no description)')}</description>"
        lines << '  </mcp>'
      end
      lines << '</available_mcps>'
      lines.join("\n")
    end

    # Register every tool exposed by server +id+ into +agent+'s
    # underlying +RubyLLM::Chat+. Public so {View#register_tools_with_agent}
    # can delegate; intended caller is {McpConnect} via
    # {Agent#internal_add_tool}. Doesn't track activation — that's
    # {McpConnect}'s job (each agent's tool instance owns its own set).
    #
    # @param id [String] server id; must be in {#live_ids}.
    # @param agent [Agent]
    # @return [Integer] number of tools registered.
    # @raise [ArgumentError] if +id+ isn't live.
    def register_tools_with_agent(id, agent)
      raise ArgumentError, "MCP server #{id.inspect} is not live" unless @live_ids.include?(id)

      client = @clients.fetch(id)
      tools = @tools_cache.fetch(id)
      tools.each do |mcp_tool|
        rb_tool = synthesize_ruby_llm_tool(server_id: id, client: client, mcp_tool: mcp_tool)
        agent.internal_add_tool(rb_tool)
      end
      tools.size
    end

    # Close every live transport, terminating the spawned MCP server
    # subprocesses. Idempotent. Registered via +at_exit+ from
    # {#initialize} so process exit always cleans up, but callers may
    # invoke it explicitly (e.g. tests that swap in a fresh
    # {McpServers}).
    #
    # @return [void]
    def close
      return if @closed

      @transports.each do |id, transport|
        transport.close
      rescue StandardError => e
        LOGGER.warn("Error closing MCP server #{id.inspect}: #{e.class}: #{e.message}")
      end
      @closed = true
    end

    private

    def start_all
      @registry.entries.each { |entry| start_one(entry) }
    end

    def start_one(entry)
      transport = build_transport(entry)
      client = MCP::Client.new(transport: transport)
      client.connect

      tools = client.tools
      @clients[entry.id]      = client
      @transports[entry.id]   = transport
      @tools_cache[entry.id]  = tools
      @descriptions[entry.id] = extract_server_description(client)
      @live_ids << entry.id

      log_audit(entry, client, tools)
    rescue StandardError => e
      LOGGER.warn(
        "Failed to start MCP server #{entry.id.inspect} " \
        "(#{describe_entry(entry)}): #{e.class}: #{e.message}"
      )
      # Try to clean up a partially-opened transport so we don't leak
      # state on partial-startup failure (stdio: spawn succeeded but
      # handshake didn't; http: session opened but initialize 4xx'd).
      begin
        transport&.close
      rescue StandardError
        nil
      end
    end

    def build_transport(entry)
      case entry
      when McpRegistry::StdioEntry
        MCP::Client::Stdio.new(
          command: entry.command.first,
          args: entry.command.drop(1)
        )
      when McpRegistry::HttpEntry
        MCP::Client::HTTP.new(url: entry.url, headers: entry.headers)
      else
        raise ArgumentError, "Unknown MCP entry type: #{entry.class}"
      end
    end

    # Short human-readable identifier for an entry's transport, used in
    # the warning log when startup fails.
    def describe_entry(entry)
      case entry
      when McpRegistry::StdioEntry then "command: #{entry.command.join(' ')}"
      when McpRegistry::HttpEntry  then "url: #{entry.url}"
      else                              entry.class.to_s
      end
    end

    # Pull a short description out of the server's +initialize+
    # handshake. +client.server_info+ is the raw initialize response
    # hash from the +mcp+ gem; +instructions+ is the conventional
    # field for a "what this server does" blurb, with operational
    # identifiers (+serverInfo.name+, +serverInfo.title+) as fallback.
    def extract_server_description(client)
      info = client.server_info || {}
      server_info = info['serverInfo'] || {}
      info['instructions'] ||
        server_info['title'] ||
        server_info['name'] ||
        '(no description)'
    end

    def log_audit(entry, client, tools)
      info = client.server_info || {}
      server_info = info['serverInfo'] || {}
      lines = []
      lines << "MCP server #{entry.id.inspect} started (#{describe_entry(entry)})"
      lines << "  Protocol version: #{info['protocolVersion'] || '(unset)'}"
      lines << "  Server name:     #{server_info['name'] || '(unset)'}"
      lines << "  Server version:  #{server_info['version'] || '(unset)'}"
      lines << "  Instructions:    #{info['instructions'] || '(none)'}"
      lines << "  Tools (#{tools.size}):"
      tools.each do |t|
        lines << "    - #{t.name}"
        lines << "        description: #{t.description}"
        lines << "        input_schema: #{(t.input_schema || {}).inspect}"
        out = t.respond_to?(:output_schema) ? t.output_schema : nil
        lines << "        output_schema: #{out ? out.inspect : '(none)'}"
      end
      LOGGER.info(lines.join("\n"))
    end

    # Build an anonymous +RubyLLM::Tool+ subclass for one MCP-exposed
    # tool. Name is namespaced as +"<server_id>__<tool_name>"+ to avoid
    # collisions across servers (and with pikuri's native tools).
    # Description is prefixed with +[From MCP server "<id>"]+ as the
    # cheap provenance / injection-defense marker. Input-parameter
    # descriptions from +mcp_tool.input_schema+ flow through verbatim:
    # +RubyLLM::Tool.params(schema_hash)+ stores the JSON Schema and
    # +instance.params_schema+ deep-dups + stringifies it on the way
    # to the provider, so each property's +"description"+ field
    # reaches the LLM.
    #
    # Note: +mcp_tool.output_schema+ has no destination — RubyLLM has
    # no return-schema slot in its +Tool+ surface (no equivalent of
    # +params+ for outputs), and providers don't accept one in the
    # tool-call schema either. We surface output schemas in the INFO
    # audit log (+#log_audit+) so a privacy-conscious user can still
    # see what an MCP server claims to return, and otherwise the
    # data simply lives in the call response.
    def synthesize_ruby_llm_tool(server_id:, client:, mcp_tool:)
      namespaced_name = "#{server_id}__#{mcp_tool.name}"
      prefixed_desc = %([From MCP server "#{server_id}"]\n\n#{mcp_tool.description})
      schema = normalize_schema(mcp_tool.input_schema)

      # Capture the client + tool for the execute closure. The closure
      # converts the MCP::Tool::Response into the +"Error: ..."+ /
      # plain-text shape pikuri's tool-call observation contract uses.
      Class.new(RubyLLM::Tool) do
        description(prefixed_desc)
        params(schema)

        define_singleton_method(:name) { namespaced_name }

        define_method(:execute) do |**args|
          # +MCP::Client#call_tool+ returns the raw JSON-RPC response
          # Hash: +{"jsonrpc", "id", "result" => {"content" => [...],
          # "isError" => bool}}+ on success, or +{... "error" => {...}}+
          # on JSON-RPC-level failure.
          begin
            response = client.call_tool(tool: mcp_tool, arguments: args)
          rescue StandardError => e
            next "Error: MCP server #{server_id.inspect} call failed: #{e.class}: #{e.message}"
          end

          if response['error']
            err = response['error']
            next "Error: MCP server #{server_id.inspect} returned JSON-RPC error " \
                 "#{err['code']}: #{err['message']}"
          end

          content_arr = Array(response.dig('result', 'content'))
          text = content_arr.map { |c| c.is_a?(Hash) ? c['text'] : nil }
                            .compact.join("\n")
          is_error = response.dig('result', 'isError') == true

          is_error ? "Error: #{text.empty? ? '(no detail)' : text}" : text
        end
      end
    end

    # Normalize an MCP tool's +input_schema+ into a shape
    # +RubyLLM::Tool.params+ accepts. Returns a minimal empty-object
    # schema when the MCP tool didn't supply one.
    def normalize_schema(schema)
      return { type: 'object', properties: {}, required: [] } if schema.nil?

      h = schema.is_a?(Hash) ? schema : schema.to_h
      # Strip the +$schema+ URI declaration the MCP gem adds; RubyLLM
      # doesn't need it and some providers reject extra top-level keys.
      h = h.reject { |k, _| k.to_s == '$schema' }
      # Symbol-keyed for consistency with +Pikuri::Tool::Parameters#to_h+.
      h.transform_keys(&:to_sym)
    end

    def escape_xml(str)
      str.to_s.gsub('&', '&amp;')
         .gsub('<', '&lt;')
         .gsub('>', '&gt;')
         .gsub('"', '&quot;')
         .gsub("'", '&apos;')
    end

    def register_at_exit
      me = self
      at_exit { me.close }
    end

    # Sub-agent-facing facade. Shares the parent's clients, never owns
    # lifecycle. Constructed via {McpServers#view_for_sub_agent}.
    #
    # Recursive sub-agents (a sub-agent spawning its own sub-agent)
    # share the same {View} instance — {#view_for_sub_agent} returns
    # +self+ rather than wrapping again, since clients are already
    # delegated to root.
    class View
      # @param root [McpServers]
      def initialize(root)
        @root = root
      end

      # @return [Array<String>]
      def live_ids
        @root.live_ids
      end

      # @return [Boolean]
      def empty?
        @root.empty?
      end

      # @return [View] self (nested sub-agents share the same view).
      def view_for_sub_agent
        self
      end

      # @return [String]
      def system_prompt_snippet
        @root.system_prompt_snippet
      end

      # @param agent [Agent]
      # @return [McpConnect]
      def build_mcp_connect_tool(agent)
        McpConnect.new(view: self, agent: agent)
      end

      # @param id [String]
      # @param agent [Agent]
      # @return [Integer] number of tools registered.
      # @raise [ArgumentError] if +id+ isn't live.
      def register_tools_with_agent(id, agent)
        @root.register_tools_with_agent(id, agent)
      end
    end

    # The +mcp_connect+ tool exposed to the LLM. Private inner class —
    # instantiated only by {McpServers#build_mcp_connect_tool} (called
    # from {Agent#initialize}), never by application code.
    #
    # Tracks its own activation +Set+ so re-connecting an already-active
    # server returns a recoverable +"Error: ..."+ String (the LLM has
    # the tools in its toolset and should just call them). Each agent
    # owns its own {McpConnect} instance and therefore its own
    # activation set — activation does not propagate between parent and
    # sub-agent. See IDEAS.md §"v1 implementation shape".
    class McpConnect < Pikuri::Tool
      DESCRIPTION = <<~DESC
        Connect to an MCP (Model Context Protocol) server, adding its tools to your toolset for the rest of this conversation.

        Usage:
        - The list of available server ids and their descriptions is in your system prompt under `<available_mcps>`.
        - Call with a single `id` that matches one of those entries. The server's tools become callable immediately after.
        - On `Error: server '...' is already connected`, do NOT retry — the tools are already in your toolset; call them directly.
        - On `Error: unknown MCP server id ...`, pick an id that actually appears in `<available_mcps>`.
      DESC

      # @param view [McpServers, View] runtime view this tool resolves
      #   ids against.
      # @param agent [Agent] agent into whose chat the activated tools
      #   are registered.
      def initialize(view:, agent:)
        activated = Set.new

        super(
          name: 'mcp_connect',
          description: DESCRIPTION,
          parameters: Parameters.build { |p|
            p.required_string :id,
                              'Id of the MCP server to connect to. ' \
                              'Must match one of the ids listed under ' \
                              '`<available_mcps>` in the system prompt, e.g. "maven-tools".'
          },
          execute: lambda { |id:|
            unless view.live_ids.include?(id)
              available = view.live_ids.empty? ? 'none' : view.live_ids.join(', ')
              next "Error: unknown MCP server id #{id.inspect}. Available: #{available}."
            end

            if activated.include?(id)
              next "Error: server '#{id}' is already connected; its tools are in your toolset, call them directly."
            end

            count = view.register_tools_with_agent(id, agent)
            activated << id
            "Connected to MCP server '#{id}'. Added #{count} tool#{'s' if count != 1} to your toolset."
          }
        )
      end
    end
  end
end
