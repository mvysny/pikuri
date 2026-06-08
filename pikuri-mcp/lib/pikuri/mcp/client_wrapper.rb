# frozen_string_literal: true

require 'mcp'

module Pikuri
  module Mcp
    # Wraps one +MCP::Client+ plus its transport with retry-and-restart
    # semantics for stdio-subprocess death. The wrapper owns the
    # client/transport lifecycle: on construction it builds a fresh
    # transport and runs the +initialize+ handshake; on a
    # subprocess-died failure during {#call_tool} it closes the dead
    # transport, spawns a fresh one, re-handshakes, and retries — up
    # to {MAX_CALL_ATTEMPTS} times total. After exhaustion the
    # underlying +RequestHandlerError+ propagates and the synthesized
    # tool's execute closure converts it to an +Error: ...+ observation
    # like any other failure.
    #
    # == Why only subprocess-death messages
    #
    # Once an stdio subprocess dies, +MCP::Client::Stdio+'s state is
    # irreversibly broken: +@wait_thread.alive?+ returns false forever
    # and every subsequent call raises from +ensure_running!+ without
    # ever talking to the server. Restarting is the only way back.
    # Other +RequestHandlerError+ failures (protocol mismatch on the
    # initialize handshake, JSON parse error, ValidationError on a
    # malformed response) leave the transport usable; a restart there
    # would just retry the same logical mistake and waste latency.
    #
    # == HTTP entries
    #
    # The wrapper accepts {Registry::HttpEntry} too, but no HTTP
    # failure raises with the subprocess-death messages we match on,
    # so the retry path naturally never triggers — the wrapper is a
    # pass-through for HTTP. If transient HTTP retry is ever wanted,
    # it should land here, not in {Servers}.
    #
    # == Lifecycle responsibility
    #
    # Spawning happens inside {#initialize} (via +spawn_fresh!+), and
    # if the +initialize+ handshake fails the wrapper closes its own
    # half-opened transport before re-raising. That means a caller
    # who saw +ClientWrapper.new(entry)+ raise does NOT need to also
    # close anything — the wrapper either returns a fully-initialized
    # object or no object at all.
    class ClientWrapper
      LOGGER = Pikuri.logger_for('Mcp::ClientWrapper')
      private_constant :LOGGER

      # Maximum number of +call_tool+ attempts including the initial
      # one, before propagating the underlying exception. 3 means: one
      # normal try plus up to two restart-then-retry attempts.
      MAX_CALL_ATTEMPTS = 3

      # Substrings of +MCP::Client::RequestHandlerError#message+ that
      # signal "the stdio subprocess is dead and the transport is
      # unrecoverable." All three come from
      # +mcp-X.Y.Z/lib/mcp/client/stdio.rb+:
      #
      # * +Server process has exited+ — +ensure_running!+ on a
      #   +wait_thread+ that is no longer alive.
      # * +Failed to write to server process+ — broken pipe on
      #   write (+EPIPE+ / +IOError+).
      # * +Server process closed stdout unexpectedly+ — +gets+
      #   returned +nil+ mid-read because the pipe was closed.
      SUBPROCESS_DEAD_PATTERNS = [
        'Server process has exited',
        'Failed to write to server process',
        'Server process closed stdout unexpectedly'
      ].freeze
      private_constant :SUBPROCESS_DEAD_PATTERNS

      # @return [Registry::StdioEntry, Registry::HttpEntry] the
      #   registry entry the wrapper builds (and rebuilds) transports
      #   from.
      attr_reader :entry

      # @return [MCP::Client] the *current* live client. Replaced on
      #   each restart, so callers must not cache this across
      #   {#call_tool} invocations. Exposed for one-shot boot-time
      #   reads of +server_info+ / +tools+ by {Servers}, {Verifier},
      #   {Synthesizer}, and {Cache}.
      attr_reader :client

      # @param entry [Registry::StdioEntry, Registry::HttpEntry] the
      #   configured server.
      # @raise [StandardError] anything raised by the underlying
      #   transport's spawn / +connect+ handshake. The half-opened
      #   transport is closed before the exception propagates.
      def initialize(entry)
        @entry = entry
        @closed = false
        spawn_fresh!
      end

      # Server's cached +InitializeResult+, as exposed by the
      # transport. Delegates to {#client}.
      #
      # @return [Hash, nil]
      def server_info
        @client.server_info
      end

      # Enumerate the server's tools via +MCP::Client#tools+. Each
      # call is a real round-trip — callers typically invoke this
      # once at boot and cache the result.
      #
      # @return [Array<MCP::Client::Tool>]
      def tools
        @client.tools
      end

      # Call an MCP tool on the underlying server. On any failure
      # whose message matches {SUBPROCESS_DEAD_PATTERNS}, closes the
      # dead transport, spawns a fresh one, re-runs the +initialize+
      # handshake, and retries the call — up to {MAX_CALL_ATTEMPTS}
      # times total. Other failures (server-returned JSON-RPC errors
      # don't reach this method — they come back inside the response
      # Hash; non-recoverable transport errors like protocol-version
      # mismatch or JSON parse errors) propagate on the first attempt
      # without restart.
      #
      # @param tool [MCP::Client::Tool] the tool object obtained from
      #   {#tools} at boot. Only +name+ is used at call time, so a
      #   reference captured before a restart keeps working as long
      #   as the new server still exposes that tool name.
      # @param arguments [Hash] passed verbatim to the underlying
      #   +call_tool+.
      # @return [Hash] the JSON-RPC response.
      # @raise [MCP::Client::RequestHandlerError] when retries are
      #   exhausted, or on the first non-recoverable failure.
      def call_tool(tool:, arguments:)
        attempt = 1
        begin
          @client.call_tool(tool: tool, arguments: arguments)
        rescue MCP::Client::RequestHandlerError => e
          raise unless subprocess_dead?(e)
          raise if attempt >= MAX_CALL_ATTEMPTS

          LOGGER.warn(
            "MCP server #{@entry.id.inspect} subprocess died " \
            "(#{e.message.inspect}); restarting and retrying " \
            "(attempt #{attempt + 1}/#{MAX_CALL_ATTEMPTS})."
          )
          restart!
          attempt += 1
          retry
        end
      end

      # Close the underlying transport. Idempotent — subsequent calls
      # are no-ops. After close, {#call_tool} will fail on the dead
      # client.
      #
      # @return [void]
      def close
        return if @closed

        begin
          @transport&.close
        rescue StandardError => e
          LOGGER.warn(
            "Error closing MCP transport for #{@entry.id.inspect}: " \
            "#{e.class}: #{e.message}"
          )
        end
        @closed = true
      end

      private

      def spawn_fresh!
        @transport = build_transport
        begin
          @client = MCP::Client.new(transport: @transport)
          @client.connect
        rescue StandardError
          # The +initialize+ handshake (or the subprocess spawn it
          # implicitly triggers for stdio) failed. Close whatever
          # half-opened state we have so we don't leak a stdio
          # subprocess that succeeded popen3 but failed handshake.
          # The new transport is not retained — the wrapper either
          # returns from initialize cleanly or raises with no live
          # state.
          begin
            @transport.close
          rescue StandardError
            nil
          end
          raise
        end
      end

      def restart!
        begin
          @transport.close
        rescue StandardError
          # The old transport's subprocess is presumed dead — close
          # may raise (e.g. on an already-closed pipe). We don't
          # care: we're about to discard the transport anyway, and
          # the recovery is the fresh spawn below.
          nil
        end
        spawn_fresh!
      end

      def build_transport
        case @entry
        when Registry::StdioEntry
          MCP::Client::Stdio.new(
            command: @entry.command.first,
            args: @entry.command.drop(1),
            env: @entry.env
          )
        when Registry::HttpEntry
          MCP::Client::HTTP.new(url: @entry.url, headers: @entry.headers)
        else
          raise ArgumentError, "Unknown MCP entry type: #{@entry.class}"
        end
      end

      def subprocess_dead?(error)
        msg = error.message.to_s
        SUBPROCESS_DEAD_PATTERNS.any? { |pat| msg.include?(pat) }
      end
    end
  end
end
