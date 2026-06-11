# frozen_string_literal: true

require 'ruby_llm'
require 'faraday'
require 'json'
require 'cgi'

module Pikuri
  class Agent
    # Resolves the model's context-window cap by asking the server that
    # actually serves it. The only authoritative runtime source pikuri
    # has is llama.cpp's non-standard +/props+ endpoint, which reports
    # the server's *launched* +n_ctx+ (the real window — possibly
    # smaller than the model's theoretical max, e.g. +llama-server -c
    # 8192+ on a 128k model). Returns +nil+ — an honest "we don't
    # know" — for anything else.
    #
    # Used by {Agent#detect_and_emit_context_cap!} at construction and
    # after every model switch to feed {Listener::TokenLog} a cap it can
    # render alongside the running context size (so the +ctx=12.2k/32.0k+
    # line tells the operator how close the conversation is to the limit).
    # The caller prefers an explicit/inherited
    # {ChatTransport#context_window} over this probe; this runs only when
    # the transport carries none.
    #
    # == Why no ruby_llm registry source
    #
    # +RubyLLM::Model::Info#context_window+ is a static lookup in a
    # bundled +models.json+ snapshot: +nil+ for every +assume_exists+
    # local model id, +nil+ for anything newer than the snapshot, and —
    # worst — a *frozen* value for known models, so a window the provider
    # later bumped (256k → 1M) still reports the old number. A cap you
    # have to caveat defeats the cap's only job (a number trustworthy
    # enough to act on before +RubyLLM::ContextLengthExceededError+), so
    # pikuri deliberately does not consult it. The probe (server truth)
    # and an explicit {ChatTransport#context_window} (operator/parent
    # truth) are the only two sources; absent both, the cap is +nil+.
    #
    # == The openai-provider gate + auto-derived URL
    #
    # The probe only makes sense against an OpenAI-compatible local
    # server (llama.cpp), reached through ruby_llm's +:openai+ provider
    # with a custom base. So {.detect} runs only when
    # +transport.provider == :openai+ and derives the probe URL from the
    # *same* +RubyLLM.config.openai_api_base+ the chat itself uses —
    # +/props+ lives at the host root, NOT under +/v1+, so the +/v1+
    # suffix is stripped. Deriving from the live config (rather than a
    # URL passed in) means the probe can't target a different server than
    # the chat. A bare +:openai+ pointed at real +api.openai.com+ gets
    # one fast +/props+ 404 that degrades to +nil+ (the simple gate; not
    # worth narrowing — you're already sending that server the whole
    # conversation).
    #
    # == llama.cpp router mode
    #
    # A llama.cpp *router* (the multi-instance front that proxies to N
    # on-demand model servers) answers a bare +/props+ with
    # +{"role":"router", ..., "n_ctx":0}+ — there is no single loaded
    # model at the router itself, so its top-level +n_ctx+ is +0+. The
    # real per-model cap is one proxied hop away: +GET /props?model=<id>+
    # routes the probe to that model's instance, whose +/props+ carries
    # the launched +n_ctx+. So when the bare probe reports +role: router+
    # and a +model_id+ is known, this re-probes with the model id before
    # giving up. A plain single-model server is untouched: its bare
    # +/props+ already carries a positive +n_ctx+, so the router branch
    # never runs.
    #
    # == Failure handling
    #
    # The probe is best-effort. HTTP error, timeout, non-JSON body, or a
    # missing/invalid +n_ctx+ field all return +nil+ and log one +warn+
    # line via +Pikuri.logger_for('ContextWindowDetector')+. This is the
    # CLAUDE.md "secondary to the loop" carve-out — a wedged or
    # non-llama.cpp server should not abort agent construction over a
    # cosmetic readout.
    class ContextWindowDetector
      # Subsystem logger; set its level with
      # +PIKURI_LOG_CONTEXTWINDOWDETECTOR+ or the global +PIKURI_LOG+.
      #
      # @return [Logger]
      LOGGER = Pikuri.logger_for('ContextWindowDetector')

      # Connect timeout in seconds for the llama.cpp +/props+ probe.
      # Short on purpose: a server that isn't even listening should fail
      # fast rather than stall +Agent+ construction.
      #
      # @return [Integer]
      OPEN_TIMEOUT = 2
      # Read timeout in seconds for the llama.cpp +/props+ probe.
      # Generous on purpose, and the reason it differs from
      # {OPEN_TIMEOUT}: a llama.cpp router answers +/props?model=<id>+
      # only *after* spinning up that model's instance, and a cold model
      # load can take 10+ seconds — which the next chat turn must wait
      # for anyway. A read timeout shorter than the load would abandon
      # the probe (and lose the cap) precisely when switching to a
      # cold model. A server that accepts the connection but then hangs
      # would stall the actual chat identically, so tolerating the wait
      # here costs nothing extra.
      #
      # @return [Integer]
      READ_TIMEOUT = 30

      # Resolve the context-window cap for +transport+ by probing the
      # server that serves it.
      #
      # @param transport [Agent::ChatTransport] the model-resolution
      #   triple; +provider+ gates the probe and +model+ drives the
      #   router +?model=+ hop
      # @param openai_base [String, nil] the configured OpenAI-compatible
      #   base URL the probe URL is derived from; defaults to the live
      #   +RubyLLM.config.openai_api_base+. Passed explicitly only by
      #   tests, which don't want to mutate global config.
      # @return [Integer, nil] the launched +n_ctx+, or +nil+ for a
      #   non-+:openai+ transport, an unconfigured base, or any probe
      #   failure
      def self.detect(transport, openai_base: RubyLLM.config.openai_api_base)
        return nil unless transport.provider == :openai

        url = props_url(openai_base)
        return nil if url.nil?

        new(probe_url: url, model_id: transport.model).probe
      end

      # Derive the llama.cpp +/props+ URL from the OpenAI-compatible
      # base. +/props+ sits at the host root, so a trailing +/v1+ is
      # stripped before appending.
      #
      # @param openai_base [String, nil]
      # @return [String, nil] the +/props+ URL, or +nil+ when the base
      #   is blank
      def self.props_url(openai_base)
        base = openai_base.to_s.strip.chomp('/')
        return nil if base.empty?

        "#{base.delete_suffix('/v1')}/props"
      end

      # @param probe_url [String] full URL to llama.cpp +/props+
      # @param model_id [String, nil] the chat model id, used to follow a
      #   llama.cpp router via +/props?model=<id>+ when the bare probe
      #   reports +role: router+. +nil+ or empty disables that second hop.
      def initialize(probe_url:, model_id:)
        @probe_url = probe_url
        @model_id = model_id
      end

      # @return [Integer, nil] resolved cap, or +nil+ if the probe
      #   produced none
      def probe
        probe_llama_cpp
      end

      private

      def probe_llama_cpp
        data = fetch_props(@probe_url)
        return nil if data.nil?

        n_ctx = positive_n_ctx(data)
        return n_ctx if n_ctx

        # llama.cpp router: the bare /props carries no model, so its
        # n_ctx is 0. Follow the router to the model's own instance.
        return probe_router_model if data['role'] == 'router' && model_id_present?

        warn_and_nil(
          "no positive integer at default_generation_settings.n_ctx in #{@probe_url} response"
        )
      end

      def probe_router_model
        url = "#{@probe_url}?model=#{CGI.escape(@model_id)}"
        data = fetch_props(url)
        return nil if data.nil?

        n_ctx = positive_n_ctx(data)
        return n_ctx if n_ctx

        warn_and_nil(
          "no positive integer at default_generation_settings.n_ctx in router probe #{url}"
        )
      end

      # GETs +url+ and parses its JSON body.
      #
      # @param url [String] a llama.cpp +/props+ URL
      # @return [Hash, nil] the parsed body, or +nil+ (after one +warn+
      #   line) on non-200, timeout, transport error, or non-JSON body
      def fetch_props(url)
        response = Faraday.new(
          request: { open_timeout: OPEN_TIMEOUT, timeout: READ_TIMEOUT }
        ).get(url) do |req|
          req.headers['Accept'] = 'application/json'
        end

        return warn_and_nil("HTTP #{response.status} from #{url}") unless response.status == 200

        JSON.parse(response.body)
      rescue Faraday::Error, JSON::ParserError => e
        warn_and_nil("#{e.class.name.split('::').last}: #{e.message}")
      end

      # @param data [Hash] a parsed +/props+ body
      # @return [Integer, nil] the launched +n_ctx+ when present and
      #   positive, else +nil+
      def positive_n_ctx(data)
        n_ctx = data.dig('default_generation_settings', 'n_ctx')
        n_ctx if n_ctx.is_a?(Integer) && n_ctx.positive?
      end

      def model_id_present?
        !@model_id.nil? && !@model_id.empty?
      end

      def warn_and_nil(reason)
        LOGGER.warn("llama.cpp /props probe failed: #{reason}")
        nil
      end
    end
  end
end
