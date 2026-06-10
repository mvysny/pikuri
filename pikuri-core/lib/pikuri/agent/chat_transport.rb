# frozen_string_literal: true

module Pikuri
  class Agent
    # Everything that has to travel together for a chat to resolve to
    # the same model *on the same server* on every construction: the
    # model id, the provider hint, the registry-bypass flag, and — when
    # the model lives on a server other than the process-global
    # +RubyLLM.config+ default — that server's base URL and API key.
    #
    # Bundling them is structural protection against a recurring bug
    # class — every forwarding site (the synthesizer rescue in
    # {Agent#run_loop}, the +agent+ tool from +pikuri-subagents+
    # spawning a sub-agent, a mid-conversation model switch) used to
    # pass the resolution fields individually, and dropping one routed
    # the chat to a different server or raised
    # +RubyLLM::ModelNotFoundError+ on the unknown model id. With a
    # single value object the call site can't silently miss a field.
    #
    # == Why +api_base+ / +api_key+ live here
    #
    # +RubyLLM::Chat#with_model+ swaps only the model/provider against
    # the chat's *existing* connection config, so switching to a model
    # on a different server (a small local llama.cpp vs a big cloud
    # model) needs the connection to travel with the model — otherwise
    # the new model id is sent to the old server's URL with the old
    # key. {Agent} maps these two generic fields onto the provider's
    # ruby_llm config slots (+#{provider}_api_base+ /
    # +#{provider}_api_key+) via a per-chat +RubyLLM::Context+; both are
    # +nil+ for a transport that rides the process-global config.
    #
    # Pure data carrier: no +RubyLLM+ references here, so the seam stays
    # in {Agent}, +bin/pikuri-chat+, and {Tool}.
    #
    # @!attribute [r] model
    #   @return [String, nil] LLM identifier; +nil+ defers to
    #     +RubyLLM.config.default_model+ at {Agent} construction time
    # @!attribute [r] provider
    #   @return [Symbol, nil] forwarded to +RubyLLM.chat+. Required
    #     together with +assume_model_exists+ when pointing at a local
    #     OpenAI-compatible server (llama.cpp, gpustack, ...) whose model
    #     ids are not in ruby_llm's bundled registry; required whenever
    #     +api_base+ / +api_key+ is set (it names the config slots).
    # @!attribute [r] assume_model_exists
    #   @return [Boolean] forwarded to +RubyLLM.chat+; +true+ skips
    #     ruby_llm's registry lookup and trusts the supplied model id.
    #     Requires +provider+.
    # @!attribute [r] api_base
    #   @return [String, nil] connection base URL for this model's
    #     server (e.g. +http://localhost:8080/v1+). +nil+ rides the
    #     process-global +RubyLLM.config+ base. Mapped to the provider's
    #     +#{provider}_api_base+ slot by {Agent}.
    # @!attribute [r] api_key
    #   @return [String, nil] API key for this model's server. +nil+
    #     rides the process-global config key. Mapped to the provider's
    #     +#{provider}_api_key+ slot by {Agent}. Redacted in {#inspect}
    #     so it never leaks into a log line or backtrace.
    class ChatTransport < Data.define(:model, :provider, :assume_model_exists, :api_base, :api_key)
      # Build an +:openai+-provider transport for an OpenAI-compatible
      # server (a local llama.cpp, a cloud endpoint, ...), carrying that
      # server's connection so the agent rides a per-chat
      # +RubyLLM::Context+ instead of the process-global +RubyLLM.config+.
      # This is the host-boot factory the +bin/pikuri-*+ demos use in
      # place of +RubyLLM.configure+ — one isolated connection per agent,
      # so several agents pointed at different servers (and different
      # keys) don't stomp a shared global.
      #
      # +server+ is the bare server origin; a trailing +/v1+ (the
      # OpenAI-compatible suffix ruby_llm appends to reach
      # +/v1/chat/completions+) is stripped and re-appended exactly once,
      # so +https://api.x.ai+, +https://api.x.ai/v1+, and
      # +https://api.x.ai/v1/+ all normalize to the same +.../v1+ base.
      # Without this, a +server+ value that already ended in +/v1+ would
      # double to +/v1/v1+ and every request would 404.
      #
      # @param server [String] server origin, with or without a trailing
      #   +/v1+, e.g. +"http://localhost:8080"+ or +"https://api.x.ai/v1"+
      # @param model [String] model id served there, trusted verbatim
      #   (+assume_model_exists+ is +true+, so it need not appear in
      #   ruby_llm's bundled registry)
      # @param api_key [String] API key for the server; the conventional
      #   +"not-needed"+ placeholder for a keyless local server
      # @return [ChatTransport] a transport whose +api_base+ is the
      #   normalized +.../v1+ URL and whose +api_key+ is +api_key+
      def self.from_openai_server(server:, model:, api_key: 'not-needed')
        base = server.to_s.strip.chomp('/').delete_suffix('/v1')
        new(
          model: model,
          provider: :openai,
          assume_model_exists: true,
          api_base: "#{base}/v1",
          api_key: api_key
        )
      end

      # @param model [String, nil]
      # @param provider [Symbol, nil]
      # @param assume_model_exists [Boolean]
      # @param api_base [String, nil]
      # @param api_key [String, nil]
      # @raise [ArgumentError] if +api_base+ or +api_key+ is set without
      #   a +provider+ (the provider names the config slots the
      #   connection overrides map onto)
      def initialize(model:, provider: nil, assume_model_exists: false,
                     api_base: nil, api_key: nil)
        if (api_base || api_key) && provider.nil?
          raise ArgumentError, "api_base/api_key require a provider, got #{provider.inspect}"
        end

        super
      end

      # The model-resolution kwargs to spread into +RubyLLM.chat+ /
      # +RubyLLM::Context#chat+. Excludes the connection fields — those
      # configure the +Context+ the chat is built from, not the +chat+
      # call itself.
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

      # Default +Data#inspect+ would print +api_key+ verbatim, leaking
      # the secret into any log line, +to_s+ interpolation, or backtrace
      # that touches the transport. Redact it.
      #
      # @return [String]
      def inspect
        "#<#{self.class} model=#{model.inspect} provider=#{provider.inspect} " \
          "assume_model_exists=#{assume_model_exists} api_base=#{api_base.inspect} " \
          "api_key=#{api_key.nil? ? 'nil' : '[REDACTED]'}>"
      end
      alias to_s inspect
    end
  end
end
