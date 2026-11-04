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
    # No +RubyLLM+ references here, so the seam stays in {Agent},
    # +bin/pikuri-chat+, and {Tool}.
    #
    # == Extra request parameters
    #
    # +params+ is an opaque passthrough for a request key pikuri names no field
    # for. It is deep-merged into the chat-completion payload as written:
    #
    #   transport.with(params: { chat_template_kwargs: { enable_thinking: false } })
    #   # on the wire: {"model":…,"messages":[…],
    #   #               "chat_template_kwargs":{"enable_thinking":false}}
    #
    # It rides the transport rather than a call because the spelling is
    # per-model-per-server, exactly like +context_window+; pikuri translates
    # none of it — a parameter is sent as written or not at all. Why there is no
    # typed +thinking:+ flag instead: +design/decisions.md+
    # +D_opaque_request_params+.
    #
    # Two edges worth knowing. Keys are deep-symbolized on the way in (naming
    # one key in both spellings raises), without which a table read from TOML
    # would land a second +"temperature"+ beside the payload's +:temperature+
    # instead of overriding it. And the merge is unguarded: a table naming
    # +messages+, +tools+ or +stream+ breaks the loop rather than configuring
    # it, and one naming +model+ sends a model this transport does not think it
    # is using.
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
    #     with the model because the cap *is* per-model-per-server. It overrides
    #     the probed +n_ctx+ and nothing else — the {Agent::ServerPermits}
    #     auto-size still happens (+design/decisions.md+ +D_probe_when_unknown+).
    #     Never sent to ruby_llm — pure pikuri metadata read by
    #     {Agent#detect_and_emit_context_cap!}, and the cap-inheritance channel:
    #     a spawned agent gets +parent.transport.with(context_window:
    #     parent.context_window_cap)+, so the resolved cap rides along and the
    #     child probes nothing.
    # @!attribute [r] modalities
    #   @return [Hash{Symbol => Boolean}, nil] which input kinds this
    #     model-on-server accepts, in llama.cpp's +/props+ vocabulary
    #     (+{vision: false, audio: false}+), or +nil+ to defer to
    #     {ContextWindowDetector}'s first-turn probe; {#with_detected_modalities}
    #     fills it in up front. Only a +false+ entry refuses anything
    #     ({Agent#modalities}); a missing key is unknown, so +{}+ states "known
    #     to report nothing" and stops the probe without refusing. Pure pikuri
    #     metadata like +context_window+, and inherited the same way: a spawned
    #     agent gets the parent's resolved {Agent#modalities}.
    # @!attribute [r] faraday_adapter
    #   @return [Class, Symbol, nil] a custom Faraday adapter to install on this
    #     agent's per-chat +RubyLLM::Context+ (via +config.faraday_adapter=+),
    #     or +nil+ for ruby_llm's default (+:net_http+). A generic HTTP seam —
    #     inject a VCR / logging / *scripted-fake* adapter without touching the
    #     global +RubyLLM.config+. Its worked use is
    #     {Pikuri::Testing.fake_transport}, which bakes an anonymous scripted
    #     adapter here so the real ruby_llm loop runs against canned HTTP.
    # @!attribute [r] params
    #   @return [Hash{Symbol => Object}] extra chat-completion payload keys,
    #     merged in verbatim; +{}+ for none. Keys symbolized, and every hash /
    #     array node frozen (a value object is *not* deep-frozen: a +String+
    #     value the caller still holds stays mutable).
    #     See +== Extra request parameters+.
    class ChatTransport < Data.define(:model, :provider, :assume_model_exists, :api_base, :api_key,
                                      :context_window, :modalities, :faraday_adapter, :params)
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
      # @param params [Hash{String, Symbol => Object}] extra payload keys for
      #   this connection, e.g.
      #   +{'chat_template_kwargs' => {'enable_thinking' => false}}+
      # @return [ChatTransport]
      def self.from_openai_server(server:, model:, api_key: 'not-needed', context_window: nil,
                                  params: {})
        base = server.to_s.strip.chomp('/').delete_suffix('/v1')
        new(
          model: model,
          provider: :openai,
          assume_model_exists: true,
          api_base: "#{base}/v1",
          api_key: api_key,
          context_window: context_window,
          params: params
        )
      end

      # @param model [String, nil]
      # @param provider [Symbol, nil]
      # @param assume_model_exists [Boolean]
      # @param api_base [String, nil]
      # @param api_key [String, nil]
      # @param context_window [Integer, nil]
      # @param modalities [Hash{Symbol => Boolean}, nil]
      # @param faraday_adapter [Class, Symbol, nil]
      # @param params [Hash{String, Symbol => Object}]
      # @raise [ArgumentError] if +api_base+ or +api_key+ is set without
      #   a +provider+ (the provider names the config slots the
      #   connection overrides map onto), or if +params+ is not a Hash, or
      #   names one key in both the +String+ and +Symbol+ spelling
      def initialize(model:, provider: nil, assume_model_exists: false, api_base: nil,
                     api_key: nil, context_window: nil, modalities: nil, faraday_adapter: nil,
                     params: {})
        if (api_base || api_key) && provider.nil?
          raise ArgumentError, "api_base/api_key require a provider, got #{provider.inspect}"
        end
        raise ArgumentError, "params must be a Hash, got #{params.class}" unless params.is_a?(Hash)

        super(model: model, provider: provider, assume_model_exists: assume_model_exists,
              api_base: api_base, api_key: api_key, context_window: context_window,
              modalities: modalities&.transform_keys(&:to_sym)&.freeze,
              faraday_adapter: faraday_adapter, params: deep_symbolize(params))
      end

      # A copy whose +modalities+ the server reported, looked up without
      # loading the model, so {Agent#modalities} is known before the first
      # turn:
      #
      #   transport = ChatTransport.from_openai_server(server: url, model: 'Qwen3.8-Dense')
      #                            .with_detected_modalities
      #   Agent.new(transport: transport, system_prompt: prompt).modalities
      #   # => {vision: true, audio: false}
      #
      # Blocks on up to two HTTP requests
      # ({ContextWindowDetector.detect_modalities}), so a UI host calls it off
      # the UI thread — at startup, and when the user picks a model. Detect
      # every transport you hand {Agent}: one differing only in +modalities+
      # still counts as a model switch.
      #
      # @return [ChatTransport] +self+ when +modalities+ is already stated or
      #   the server reported nothing
      def with_detected_modalities
        return self if modalities

        detected = ContextWindowDetector.detect_modalities(self)
        detected ? with(modalities: detected) : self
      end

      # Model-resolution kwargs to spread into +RubyLLM.chat+ /
      # +RubyLLM::Context#chat+. Excludes the connection fields (those configure
      # the +Context+, not the +chat+ call) and +params+ (a
      # +with_provider_options+ call on the built chat).
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
      # +params+ is configuration rather than a credential channel, so it prints
      # verbatim — anything sensitive a host puts there lands in every log line
      # and backtrace that inspects a transport.
      #
      # @return [String]
      def inspect
        "#<#{self.class} model=#{model.inspect} provider=#{provider.inspect} " \
          "assume_model_exists=#{assume_model_exists} api_base=#{api_base.inspect} " \
          "api_key=#{api_key.nil? ? 'nil' : '[REDACTED]'} context_window=#{context_window.inspect} " \
          "modalities=#{modalities.inspect} faraday_adapter=#{faraday_adapter.inspect} params=#{params.inspect}>"
      end
      alias to_s inspect

      private

      # Recursively symbolize +value+'s hash keys, freezing what it builds.
      # Scalars pass through as they are — only the containers are rebuilt.
      #
      # @param value [Hash, Array, Object] any +params+ subtree.
      # @return [Hash, Array, Object] the same shape, symbol-keyed, with every
      #   hash / array node frozen.
      # @raise [ArgumentError] if a hash names one key in both spellings —
      #   the merge can send only one of them, and picking silently is the
      #   failure mode this whole channel exists to avoid.
      def deep_symbolize(value)
        case value
        when Hash
          symbolized = value.to_h { |k, v| [symbolize_key(k), deep_symbolize(v)] }
          reject_collisions(value) if symbolized.size < value.size
          symbolized.freeze
        when Array
          value.map { |item| deep_symbolize(item) }.freeze
        else
          value
        end
      end

      # @param key [Object] a +params+ hash key.
      # @return [Object] +key+ as a +Symbol+, or unchanged if it has no
      #   symbol form (an +Integer+ key in a provider's own table).
      def symbolize_key(key)
        key.respond_to?(:to_sym) ? key.to_sym : key
      end

      # @param table [Hash] the pre-symbolize hash whose keys collided.
      # @return [void]
      # @raise [ArgumentError] always, naming the colliding spellings.
      def reject_collisions(table)
        collided = table.keys.group_by { |k| symbolize_key(k) }.select { |_, ks| ks.size > 1 }
        raise ArgumentError, "params names a key twice: #{collided.values.flatten.inspect}"
      end
    end
  end
end
