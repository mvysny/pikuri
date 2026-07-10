# frozen_string_literal: true

require 'ruby_llm'

module Pikuri
  # Local corrections to ruby_llm, applied at load time, that we carry
  # until the equivalent fix ships upstream.
  #
  # Each patch here is a liability: it pins us to the private shape of a
  # ruby_llm internal, so it must be small, self-contained, and tied to a
  # tracked upstream issue so we know when to delete it. Reopening a
  # third-party class is the tool of last resort — used here only because
  # the defect is on the live chat path (a streaming turn crashes) and the
  # release cadence is not ours to control.
  #
  # == The streaming error-parse crash (ruby_llm #837)
  #
  # {https://github.com/crmne/ruby_llm/issues/837}
  #
  # On a *streaming* turn, a non-200 response whose body parses to a JSON
  # value that is not a Hash (e.g. a bare JSON string — what some
  # OpenAI-compatible gateways return for "model not available in your
  # region") crashes ruby_llm 1.16.0 with +TypeError: String does not have
  # #dig method+ at +providers/openai/streaming.rb:43+, instead of
  # surfacing the endpoint's actual error message. The guard
  # +return unless error_data['error']+ is meant as a key-presence check,
  # but on a +String+ that is +String#[]+ *substring* matching, so a body
  # containing the substring +error+ slips past it into +.dig+, which
  # +String+ doesn't implement. The non-streaming path
  # (+RubyLLM::Provider#parse_error+) already handles the same body
  # gracefully by casing on Hash/Array/else — this patch brings the
  # streaming path in line by refusing to +.dig+ a non-Hash body and
  # returning the raw body as the message instead.
  #
  # We redefine the whole method (rather than +prepend+ + +super+) because
  # it is a small, self-contained +module_function+ with no state — a
  # faithful reproduction plus the missing guard is clearer than wrapping
  # a call to the buggy original. Re-running +module_function+ replaces
  # both the module method and the private instance-method copy that the
  # provider picks up via +include+ (the shape it is actually called
  # through). Delete this file once #837 is released and the gem pin moves
  # past it.
  module RubyLlmPatches
    module_function

    # @return [Boolean] +true+ once the patches below have been applied
    #   (they run unconditionally at file load; this is a marker for specs)
    def applied? = true
  end
end

module RubyLLM
  module Providers
    class OpenAI
      module Streaming
        # Parse a streaming error body into a +[status, message]+ pair,
        # tolerating a non-Hash parsed body. See
        # {Pikuri::RubyLlmPatches} for why this override exists and when
        # to remove it (ruby_llm #837).
        #
        # @param data [String] the JSON error body as received
        # @return [Array(Integer, String)] HTTP-ish status + human message
        def parse_streaming_error(data)
          error_data = JSON.parse(data)
          return [500, error_data.to_s] unless error_data.is_a?(Hash) && error_data['error']

          case error_data.dig('error', 'type')
          when 'server_error'
            [500, error_data['error']['message']]
          when 'rate_limit_exceeded', 'insufficient_quota'
            [429, error_data['error']['message']]
          else
            [400, error_data['error']['message']]
          end
        end
        module_function :parse_streaming_error
      end
    end
  end
end
