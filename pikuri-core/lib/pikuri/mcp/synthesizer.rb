# frozen_string_literal: true

module Pikuri
  module Mcp
    # One-shot LLM synthesis of a short "what does this MCP server
    # do" description for the +<available_mcps>+ block, paired with
    # the on-disk cache that persists the result. Owns the prompt,
    # its version, the cleanup (whitespace collapse), and the
    # fail-soft contract — {Servers} just calls {#call} and treats a
    # +nil+ return as "fall back."
    #
    # == Cancellation
    #
    # +Cancellable::Cancelled+ raised from inside the +@thinker+
    # propagates up through {#call} (it's specifically *not*
    # caught by the +StandardError+ rescue) so a user's Ctrl+C
    # during a boot-time synthesis pass aborts startup cleanly
    # rather than being silently logged as a "synthesis failure."
    #
    # == Fail-soft on errors
    #
    # Any other +StandardError+ — a flaky LLM, garbage JSON, a
    # cache write failure — is logged at WARN and {#call} returns
    # +nil+. {Servers#resolve_description} treats +nil+ as the
    # signal to fall back to +serverInfo.name+, so a single
    # transient blip doesn't take a server out of the +<available_mcps>+
    # listing.
    class Synthesizer
      LOGGER = Pikuri.logger_for('Mcp::Synthesizer')
      private_constant :LOGGER

      # Bump when {#build_prompt} changes meaningfully. {Cache} folds
      # this into its key fingerprint via the +prompt_version:+
      # initializer kwarg, so a bump invalidates every cached entry
      # from the previous prompt without anyone having to +rm+ the
      # cache directory.
      PROMPT_VERSION = 1

      # @param thinker [Proc] one-arg callable invoked as
      #   +thinker.call(prompt)+ — typically a closure over
      #   {Pikuri::Agent.think} that captures the agent's transport
      #   and cancellable.
      # @param cache [Cache, Cache::NULL] storage layer. Defaults to
      #   {Cache::NULL} so tests can construct a synthesizer without
      #   a real cache.
      def initialize(thinker:, cache: Cache::NULL)
        @thinker = thinker
        @cache = cache
      end

      # Produce the description for one server. Returns the cleaned
      # description String, or +nil+ when the thinker raised
      # +StandardError+, returned blank, or otherwise failed to
      # produce anything usable. {Servers#resolve_description}
      # treats +nil+ as "fall back to +serverInfo.name+."
      #
      # @param entry [Registry::StdioEntry, Registry::HttpEntry]
      # @param client [MCP::Client]
      # @param tools [Array<MCP::Client::Tool>]
      # @return [String, nil]
      # @raise [Pikuri::Agent::Control::Cancellable::Cancelled] when
      #   the underlying thinker raises Cancelled — propagated so
      #   boot-time Ctrl+C aborts startup.
      def call(entry:, client:, tools:)
        raw = @cache.fetch(entry: entry, client: client, tools: tools) do
          # Only fires on cache miss — synthesis is the slow path (LLM
          # round-trip, easily 30+ s on a local model); a heads-up is
          # warranted so the user doesn't wonder if pikuri is hung.
          # Cache hits skip this and the thinker.call entirely.
          LOGGER.info("Synthesizing description for MCP server #{entry.id.inspect}, please wait...")
          @thinker.call(build_prompt(entry, tools))
        end
        cleaned = raw.to_s.strip.gsub(/\s+/, ' ')
        return nil if cleaned.empty?

        cleaned
      rescue Agent::Control::Cancellable::Cancelled
        raise
      rescue StandardError => e
        LOGGER.warn(
          "MCP description synthesis failed for #{entry.id.inspect} " \
          "(#{e.class}: #{e.message}); falling back to serverInfo.name."
        )
        nil
      end

      private

      def build_prompt(entry, tools)
        lines = []
        lines << 'You are summarizing an MCP (Model Context Protocol) server for an AI agent that decides which servers to connect to.'
        lines << ''
        lines << 'Given the server id and the names + descriptions of the tools it exposes, write ONE short sentence (under 30 words) describing what the server does and when an agent would call its tools. Do not list the tools. Do not echo the server id. No preamble, no quotes, no markdown — just the sentence.'
        lines << ''
        lines << "Server id: #{entry.id}"
        lines << 'Tools:'
        tools.each do |t|
          lines << "- #{t.name}: #{t.description}"
        end
        lines.join("\n")
      end
    end
  end
end
