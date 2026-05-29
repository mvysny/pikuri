# frozen_string_literal: true

require 'faraday'
require 'json'
require 'cgi'

module Pikuri
  class Agent
    # Resolves the model's context-window cap from three sources, in order:
    # an explicit override, the value ruby_llm reports for the model, or a
    # llama.cpp +/props+ probe. Returns +nil+ if none of those produce a
    # value.
    #
    # Used by {Agent#initialize} at construction time to feed
    # {Listener::TokenLog} a cap it can render alongside the running
    # context size (so the +ctx=12.2k/32.0k+ line tells the operator how
    # close the conversation is to the limit).
    #
    # == Precedence
    #
    # 1. +override+ — the +Agent.new(context_window:)+ kwarg. Wins over
    #    everything; an explicit value is the operator's statement of
    #    truth.
    # 2. +ruby_llm_reported+ — +RubyLLM::Model::Info#context_window+ from
    #    {Agent#chat}'s resolved model. Populated for models in ruby_llm's
    #    bundled registry (OpenAI, Anthropic, Gemini, …); +nil+ for custom
    #    local model ids that fall through to +Model::Info.default+.
    # 3. +llama_probe_url+ — HTTP GET against llama.cpp's non-standard
    #    +/props+ endpoint. The server exposes the launched +n_ctx+ at
    #    +default_generation_settings.n_ctx+ there. Probed only when the
    #    first two are +nil+. Provider-specific to llama.cpp; the caller
    #    (typically +bin/pikuri-chat+) derives the right URL from its configured
    #    base.
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
      # Short on purpose: this runs synchronously during +Agent.new+ and
      # a wedged server should not stall startup noticeably.
      #
      # @return [Integer]
      OPEN_TIMEOUT = 2
      # Read timeout in seconds for the llama.cpp +/props+ probe; matches
      # {OPEN_TIMEOUT} for the same reason.
      #
      # @return [Integer]
      READ_TIMEOUT = 2

      # @param override [Integer, nil] explicit cap from the caller; wins if
      #   non-+nil+
      # @param ruby_llm_reported [Integer, nil] value off
      #   +RubyLLM::Chat#model.context_window+
      # @param llama_probe_url [String, nil] full URL to llama.cpp +/props+;
      #   +nil+ or empty string skips the probe
      # @param model_id [String, nil] the chat model id, used only to
      #   follow a llama.cpp router via +/props?model=<id>+ when the bare
      #   probe reports +role: router+. +nil+ or empty disables that
      #   second hop.
      def initialize(override:, ruby_llm_reported:, llama_probe_url:, model_id: nil)
        @override = override
        @ruby_llm_reported = ruby_llm_reported
        @llama_probe_url = llama_probe_url
        @model_id = model_id
      end

      # @return [Integer, nil] resolved cap, or +nil+ if no source produced
      #   one
      def detect
        return @override if @override
        return @ruby_llm_reported if @ruby_llm_reported
        return nil if @llama_probe_url.nil? || @llama_probe_url.empty?

        probe_llama_cpp
      end

      private

      def probe_llama_cpp
        data = fetch_props(@llama_probe_url)
        return nil if data.nil?

        n_ctx = positive_n_ctx(data)
        return n_ctx if n_ctx

        # llama.cpp router: the bare /props carries no model, so its
        # n_ctx is 0. Follow the router to the model's own instance.
        return probe_router_model if data['role'] == 'router' && model_id_present?

        warn_and_nil(
          "no positive integer at default_generation_settings.n_ctx in #{@llama_probe_url} response"
        )
      end

      def probe_router_model
        url = "#{@llama_probe_url}?model=#{CGI.escape(@model_id)}"
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
