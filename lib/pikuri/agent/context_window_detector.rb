# frozen_string_literal: true

require 'faraday'
require 'json'

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
      def initialize(override:, ruby_llm_reported:, llama_probe_url:)
        @override = override
        @ruby_llm_reported = ruby_llm_reported
        @llama_probe_url = llama_probe_url
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
        response = Faraday.new(
          request: { open_timeout: OPEN_TIMEOUT, timeout: READ_TIMEOUT }
        ).get(@llama_probe_url) do |req|
          req.headers['Accept'] = 'application/json'
        end

        return warn_and_nil("HTTP #{response.status} from #{@llama_probe_url}") unless response.status == 200

        data = JSON.parse(response.body)
        n_ctx = data.dig('default_generation_settings', 'n_ctx')
        return n_ctx if n_ctx.is_a?(Integer) && n_ctx.positive?

        warn_and_nil(
          "no positive integer at default_generation_settings.n_ctx in #{@llama_probe_url} response"
        )
      rescue Faraday::Error, JSON::ParserError => e
        warn_and_nil("#{e.class.name.split('::').last}: #{e.message}")
      end

      def warn_and_nil(reason)
        LOGGER.warn("llama.cpp /props probe failed: #{reason}")
        nil
      end
    end
  end
end
