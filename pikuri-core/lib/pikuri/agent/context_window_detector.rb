# frozen_string_literal: true

require 'ruby_llm'
require 'faraday'
require 'json'
require 'cgi'

module Pikuri
  class Agent
    # Asks the server that serves the model what it is capable of, and answers
    # a {Props} carrying the two facts pikuri can use:
    #
    #   props = ContextWindowDetector.detect(transport)
    #   props.n_ctx        # => 16384 — the window to budget against
    #   props.total_slots  # => 4 — how many requests it serves at once
    #
    # The only authoritative runtime source is llama.cpp's non-standard +/props+
    # endpoint, reporting the server's *launched* +n_ctx+ (the real window —
    # possibly smaller than the model's max, e.g. +llama-server -c 8192+ on a
    # 128k model) beside the slot count {ServerPermits} sizes itself from. Both
    # fields are +nil+ — an honest "we don't know" — for anything else.
    # {Agent#detect_and_emit_context_cap!} calls it only when the transport
    # carries no explicit {ChatTransport#context_window}.
    #
    # This probe and an explicit {ChatTransport#context_window} are the *only*
    # cap sources: +RubyLLM::Model::Info#context_window+ is deliberately never
    # consulted (why: +DECISIONS.md+ +D_context_window_sources+).
    #
    # == The openai-provider gate + auto-derived URL
    #
    # The probe only makes sense against an OpenAI-compatible local server
    # (llama.cpp) via ruby_llm's +:openai+ provider, so {.detect} runs only for
    # +transport.provider == :openai+ and derives the URL from the *same*
    # +RubyLLM.config.openai_api_base+ the chat uses (+/props+ is at the host
    # root, so the +/v1+ suffix is stripped) — so it can't target a different
    # server than the chat. A bare +:openai+ at real +api.openai.com+ gets one
    # fast +/props+ 404 that degrades to +nil+.
    #
    # == llama.cpp router mode
    #
    # A llama.cpp *router* (the multi-instance front) answers a bare +/props+
    # with +{"role":"router", ..., "n_ctx":0}+ — no single loaded model. The
    # real per-model cap is one hop away: +GET /props?model=<id>+ routes to that
    # model's instance. So when the bare probe reports +role: router+ and a
    # +model_id+ is known, this re-probes with the id. A plain single-model
    # server (bare +/props+ already positive) never hits this branch.
    #
    # == Failure handling
    #
    # Best-effort: HTTP error, timeout, non-JSON body, or a missing/invalid
    # +n_ctx+ all return {Props::NONE} with one +warn+ line. The CLAUDE.md
    # "secondary to the loop" carve-out — a wedged or non-llama.cpp server must
    # not abort agent construction over a cosmetic readout.
    class ContextWindowDetector
      # What one probe learned. Every field is optional, because the two
      # documents a llama.cpp answers carry different halves (a router's bare
      # +/props+ has neither) and a non-llama server has no +/props+ at all.
      #
      # @!attribute [r] n_ctx
      #   @return [Integer, nil] the server's launched context window.
      # @!attribute [r] total_slots
      #   @return [Integer, nil] how many requests it serves concurrently —
      #     {ServerPermits}'s default size for this server.
      class Props < Data.define(:n_ctx, :total_slots)
        # Nothing learned: not an +:openai+ transport, no base URL, or a failed
        # probe.
        #
        # @return [Props]
        NONE = new(n_ctx: nil, total_slots: nil)
      end

      # Subsystem logger; set its level with
      # +PIKURI_LOG_CONTEXTWINDOWDETECTOR+ or the global +PIKURI_LOG+.
      #
      # @return [Logger]
      LOGGER = Pikuri.logger_for('ContextWindowDetector')

      # Connect timeout (s) for the +/props+ probe. Short: a server that isn't
      # listening should fail fast rather than stall {Agent} construction.
      #
      # @return [Integer]
      OPEN_TIMEOUT = 2
      # Read timeout (s) for the +/props+ probe — generous, unlike
      # {OPEN_TIMEOUT}: a router answers +/props?model=<id>+ only after spinning
      # up that model's instance, and a cold load can take 10+s (which the next
      # chat turn must wait for anyway). A shorter timeout would lose the cap
      # exactly when switching to a cold model.
      #
      # @return [Integer]
      READ_TIMEOUT = 30

      # Probe the server +transport+ targets.
      #
      # @param transport [Agent::ChatTransport] +provider+ gates the probe,
      #   +model+ drives the router +?model=+ hop
      # @param openai_base [String, nil] base URL the probe URL derives from;
      #   defaults to the live +RubyLLM.config.openai_api_base+ (passed
      #   explicitly only by tests, to avoid mutating global config)
      # @return [Props] what the server reported; {Props::NONE} for a
      #   non-+:openai+ transport, an unconfigured base, or any probe failure
      def self.detect(transport, openai_base: RubyLLM.config.openai_api_base)
        return Props::NONE unless transport.provider == :openai

        url = props_url(openai_base)
        return Props::NONE if url.nil?

        new(probe_url: url, model_id: transport.model).probe
      end

      # Derive the +/props+ URL from the OpenAI-compatible base (+/props+ is at
      # the host root, so a trailing +/v1+ is stripped).
      #
      # @param openai_base [String, nil]
      # @return [String, nil] the +/props+ URL, or +nil+ when the base is blank
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

      # @return [Props] what the server reported; {Props::NONE} if the probe
      #   produced nothing
      def probe
        probe_llama_cpp
      end

      private

      def probe_llama_cpp
        data = fetch_props(@probe_url)
        return Props::NONE if data.nil?

        props = props_from(data)
        return props if props.n_ctx

        # llama.cpp router: the bare /props carries no model, so its
        # n_ctx is 0 (and it reports no slot count either). Follow the router
        # to the model's own instance, which reports both.
        return probe_router_model if data['role'] == 'router' && model_id_present?

        warn_and_none(
          "no positive integer at default_generation_settings.n_ctx in #{@probe_url} response"
        )
      end

      def probe_router_model
        url = "#{@probe_url}?model=#{CGI.escape(@model_id)}"
        data = fetch_props(url)
        return Props::NONE if data.nil?

        props = props_from(data)
        return props if props.n_ctx

        warn_and_none(
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
      # @return [Props] the launched +n_ctx+ (nested under
      #   +default_generation_settings+) and +total_slots+ (top level), each
      #   +nil+ unless present and positive
      def props_from(data)
        Props.new(n_ctx: positive_int(data.dig('default_generation_settings', 'n_ctx')),
                  total_slots: positive_int(data['total_slots']))
      end

      # @param value [Object] a value off a +/props+ body
      # @return [Integer, nil]
      def positive_int(value)
        value if value.is_a?(Integer) && value.positive?
      end

      def model_id_present?
        !@model_id.nil? && !@model_id.empty?
      end

      # @param reason [String]
      # @return [nil] so {#fetch_props} can +return+ it
      def warn_and_nil(reason)
        LOGGER.warn("llama.cpp /props probe failed: #{reason}")
        nil
      end

      # @param reason [String]
      # @return [Props] {Props::NONE}
      def warn_and_none(reason)
        warn_and_nil(reason)
        Props::NONE
      end
    end
  end
end
