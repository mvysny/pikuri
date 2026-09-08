# frozen_string_literal: true

module Pikuri
  class Agent
    # Everything that must travel together for a chat to resolve to the same
    # model *on the same server* on every construction: model id, provider
    # hint, registry-bypass flag, and — when the model lives off the
    # process-global +RubyLLM.config+ default — that server's base URL and API
    # key. One value object so a forwarding site (the synthesizer, a sub-agent
    # spawn, a mid-conversation switch) can't silently drop a field and route
    # the chat to the wrong server or raise +RubyLLM::ModelNotFoundError+.
    #
    # == Why +api_base+ / +api_key+ live here
    #
    # +RubyLLM::Chat#with_model+ swaps only model/provider against the chat's
    # *existing* connection, so switching to a model on a different server
    # needs the connection to travel with the model — else the new id is sent
    # to the old server's URL with the old key. {Agent} maps these two generic
    # fields onto the provider's config slots (+#{provider}_api_base+ /
    # +#{provider}_api_key+) via a per-chat +RubyLLM::Context+; both +nil+ for a
    # transport riding the global config.
    #
    # Pure data carrier — no +RubyLLM+ references here, so the seam stays in
    # {Agent}, +bin/pikuri-chat+, and {Tool}.
    #
    # @!attribute [r] model
    #   @return [String, nil] LLM id; +nil+ defers to
    #     +RubyLLM.config.default_model+ at {Agent} construction.
    # @!attribute [r] provider
    #   @return [Symbol, nil] forwarded to +RubyLLM.chat+. Required with
    #     +assume_model_exists+ for a local OpenAI-compatible server whose ids
    #     aren't in ruby_llm's registry, and whenever +api_base+/+api_key+ is
    #     set (it names the config slots).
    # @!attribute [r] assume_model_exists
    #   @return [Boolean] forwarded to +RubyLLM.chat+; +true+ skips the registry
    #     lookup and trusts the model id. Requires +provider+.
    # @!attribute [r] api_base
    #   @return [String, nil] this server's base URL (e.g.
    #     +http://localhost:8080/v1+); +nil+ rides the global config. Mapped to
    #     +#{provider}_api_base+ by {Agent}.
    # @!attribute [r] api_key
    #   @return [String, nil] API key for this server; +nil+ rides the global
    #     config. Mapped to +#{provider}_api_key+ by {Agent}. Redacted in
    #     {#inspect}.
    # @!attribute [r] context_window
    #   @return [Integer, nil] explicit context-window cap for this
    #     model-on-server, or +nil+ to defer to {ContextWindowDetector}. Travels
    #     with the model because the cap *is* per-model-per-server. Setting it
    #     skips the probe, and with it the {Agent::ServerPermits} auto-size, so
    #     a host that sets this and cares about throttling calls
    #     +ServerPermits.limit+ too.
    #     Never sent to ruby_llm — pure pikuri metadata read by
    #     {Agent#detect_and_emit_context_cap!}, and the cap-inheritance channel:
    #     a spawned agent gets +parent.transport.with(context_window:
    #     parent.context_window_cap)+ so the resolved cap rides along without a
    #     re-probe.
    # @!attribute [r] faraday_adapter
    #   @return [Class, Symbol, nil] a custom Faraday adapter to install on this
    #     agent's per-chat +RubyLLM::Context+ (via +config.faraday_adapter=+),
    #     or +nil+ for ruby_llm's default (+:net_http+). A generic HTTP seam —
    #     inject a VCR / logging / *scripted-fake* adapter without touching the
    #     global +RubyLLM.config+. Its worked use is
    #     {Pikuri::Testing.fake_transport}, which bakes an anonymous scripted
    #     adapter here so the real ruby_llm loop runs against canned HTTP.
    class ChatTransport < Data.define(:model, :provider, :assume_model_exists, :api_base, :api_key,
                                      :context_window, :faraday_adapter)
      # Build an +:openai+-provider transport for an OpenAI-compatible server
      # (local llama.cpp, cloud endpoint, ...), carrying its connection so the
      # agent rides a per-chat +RubyLLM::Context+ instead of the global config.
      # The +bin/pikuri-*+ host-boot factory in place of +RubyLLM.configure+ —
      # one isolated connection per agent.
      #
      # A trailing +/v1+ on +server+ is stripped and re-appended exactly once,
      # so +https://api.x.ai+, +.../v1+, and +.../v1/+ all normalize to the same
      # +.../v1+ base — without which a +/v1+-terminated value would double to
      # +/v1/v1+ and 404.
      #
      # @param server [String] server origin, with or without a trailing +/v1+
      # @param model [String] model id served there, trusted verbatim
      # @param api_key [String] API key; the +"not-needed"+ placeholder for a
      #   keyless local server
      # @param context_window [Integer, nil] explicit cap, or +nil+ to defer to
      #   {ContextWindowDetector}'s +/props+ probe (right for local llama.cpp;
      #   an override for a cloud server the probe can't reach)
      # @return [ChatTransport]
      def self.from_openai_server(server:, model:, api_key: 'not-needed', context_window: nil)
        base = server.to_s.strip.chomp('/').delete_suffix('/v1')
        new(
          model: model,
          provider: :openai,
          assume_model_exists: true,
          api_base: "#{base}/v1",
          api_key: api_key,
          context_window: context_window
        )
      end

      # @param model [String, nil]
      # @param provider [Symbol, nil]
      # @param assume_model_exists [Boolean]
      # @param api_base [String, nil]
      # @param api_key [String, nil]
      # @param context_window [Integer, nil]
      # @param faraday_adapter [Class, Symbol, nil]
      # @raise [ArgumentError] if +api_base+ or +api_key+ is set without
      #   a +provider+ (the provider names the config slots the
      #   connection overrides map onto)
      def initialize(model:, provider: nil, assume_model_exists: false,
                     api_base: nil, api_key: nil, context_window: nil, faraday_adapter: nil)
        if (api_base || api_key) && provider.nil?
          raise ArgumentError, "api_base/api_key require a provider, got #{provider.inspect}"
        end

        super
      end

      # Model-resolution kwargs to spread into +RubyLLM.chat+ /
      # +RubyLLM::Context#chat+. Excludes the connection fields (those configure
      # the +Context+, not the +chat+ call).
      #
      # @return [Hash{Symbol => String, Symbol, Boolean, nil}]
      def chat_kwargs
        { model: model, provider: provider, assume_model_exists: assume_model_exists }
      end

      # Whether this transport overrides the process-global connection
      # (and so needs a dedicated +RubyLLM::Context+).
      #
      # @return [Boolean]
      def connection_overrides?
        !api_base.nil? || !api_key.nil?
      end

      # Default +Data#inspect+ would print +api_key+ verbatim into any log line
      # or backtrace. Redact it.
      #
      # @return [String]
      def inspect
        "#<#{self.class} model=#{model.inspect} provider=#{provider.inspect} " \
          "assume_model_exists=#{assume_model_exists} api_base=#{api_base.inspect} " \
          "api_key=#{api_key.nil? ? 'nil' : '[REDACTED]'} context_window=#{context_window.inspect} " \
          "faraday_adapter=#{faraday_adapter.inspect}>"
      end
      alias to_s inspect
    end
  end
end
