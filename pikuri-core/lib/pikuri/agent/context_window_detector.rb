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
    #
    # Every call is a live request: nothing here is memoized, and the caller
    # decides when it has nothing left to learn (+design/decisions.md+
    # +D_probe_when_unknown+).
    #
    # This probe and an explicit {ChatTransport#context_window} are the *only*
    # cap sources: +RubyLLM::Model#context_window+ is deliberately never
    # consulted (why: +design/decisions.md+ +D_context_window_sources+).
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
    # The *credential* is derived the same way, and for a sharper reason:
    # +llama-server --api-key SECRET+ leaves only +/health+ and the +/models+
    # endpoints public, so an unauthenticated +/props+ is a 401 — and a 401
    # here costs both facts at once, silently (no cap to budget against, no
    # slot count to size {ServerPermits} with). The probe therefore sends the
    # chat's own key as +Authorization: Bearer+; a keyless server ignores a
    # header it was never configured to check.
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
    # Best-effort: an HTTP error, a timeout or a non-JSON body returns
    # {Props::NONE} with one +warn+ line, and a missing/invalid +n_ctx+ warns
    # but keeps a +total_slots+ the same document carried. The AGENTS.md
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
      # @param openai_key [String, nil] fallback credential for a transport
      #   that overrides no key of its own, i.e. one riding the global config;
      #   same default-and-override shape as +openai_base+, and it must stay
      #   that way — a key resolved from a different place than the base
      #   authenticates against the wrong server after a cross-server switch
      # @return [Props] what the server reported; {Props::NONE} for a
      #   non-+:openai+ transport, an unconfigured base, or any probe failure
      def self.detect(transport, openai_base: RubyLLM.config.openai_api_base,
                      openai_key: RubyLLM.config.openai_api_key)
        return Props::NONE unless transport.provider == :openai

        url = props_url(openai_base)
        return Props::NONE if url.nil?

        new(probe_url: url, model_id: transport.model,
            api_key: transport.api_key || openai_key).probe
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
      # @param api_key [String, nil] sent as +Authorization: Bearer+ on every
      #   hop; +nil+ or empty sends no header.
      def initialize(probe_url:, model_id:, api_key: nil)
        @probe_url = probe_url
        @model_id = model_id
        @api_key = api_key
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

        warn_and_keep(
          props,
          "no positive integer at default_generation_settings.n_ctx in #{@probe_url} response"
        )
      end

      def probe_router_model
        url = "#{@probe_url}?model=#{CGI.escape(@model_id)}"
        data = fetch_props(url)
        return Props::NONE if data.nil?

        props = props_from(data)
        return props if props.n_ctx

        warn_and_keep(
          props, "no positive integer at default_generation_settings.n_ctx in router probe #{url}"
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
          req.headers['Authorization'] = "Bearer #{@api_key}" if key?
        end

        return warn_and_nil(http_failure(response.status, url)) unless response.status == 200

        JSON.parse(response.body)
      rescue Faraday::Error, JSON::ParserError => e
        warn_and_nil("#{e.class.name.split('::').last}: #{e.message}")
      end

      # @return [Boolean] whether there is a credential to send.
      def key?
        !@api_key.nil? && !@api_key.empty?
      end

      # The +warn+ line's text for a non-200 status. A bare "HTTP 401" is
      # nobody's diagnosis of a misconfigured key, and this warning is the only
      # signal an operator gets — the probe degrades rather than raising.
      #
      # @param status [Integer] the response status.
      # @param url [String] the probed URL.
      # @return [String] never carrying the key itself, only whether one went.
      def http_failure(status, url)
        line = "HTTP #{status} from #{url}"
        return line unless [401, 403].include?(status)

        sent = key? ? 'the key sent was rejected' : 'none was sent'
        "#{line}: the server requires an API key (#{sent})"
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
      # @return [nil]
      def warn_and_nil(reason)
        LOGGER.warn("llama.cpp /props probe failed: #{reason}")
        nil
      end

      # Warn about the missing +n_ctx+ but keep whatever the document *did*
      # carry — a +total_slots+ beside a missing cap is still the slot count.
      #
      # @param props [Props] what {#props_from} parsed; equal to {Props::NONE}
      #   when the document carried neither field
      # @param reason [String] the +warn+ line's text
      # @return [Props] +props+, unchanged
      def warn_and_keep(props, reason)
        warn_and_nil(reason)
        props
      end
    end
  end
end
