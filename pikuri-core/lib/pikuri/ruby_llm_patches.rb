# frozen_string_literal: true

require 'ruby_llm'

module Pikuri
  # Local corrections to ruby_llm, applied at load time, carried until the fix
  # ships upstream. Each patch pins us to a ruby_llm internal's private shape, so
  # it's a liability: small, self-contained, tied to a tracked upstream issue so
  # we know when to delete it. Reopening a third-party class is last resort —
  # here only because the defect is on the live chat path and the release cadence
  # isn't ours. Patching rather than dropping the dependency is the standing
  # policy — `DECISIONS.md` +D_keep_ruby_llm+.
  #
  # == The streaming error-parse crash (ruby_llm #837)
  #
  # {https://github.com/crmne/ruby_llm/issues/837}
  #
  # On a *streaming* turn, a non-200 response whose body parses to a non-Hash
  # JSON value crashes ruby_llm 1.16.0 with +TypeError: String does not have
  # #dig+ at +providers/openai/streaming.rb:43+, instead of surfacing the
  # endpoint's error. Two bodies trigger it, both because the method assumes a
  # nested object to +.dig+:
  #
  # 1. A bare JSON string. The guard +return unless error_data['error']+ is
  #    meant as key-presence, but on a +String+ that's substring matching, so a
  #    body containing "error" slips through into +.dig+.
  # 2. A +{"error": "<message>"}+ body where +error+ is a string value
  #    (xAI/Grok), not an object: the guard passes, then
  #    +error_data.dig('error', 'type')+ calls +String#dig+ — same +TypeError+.
  #
  # The non-streaming path already handles both (cases on Hash/Array/else,
  # short-circuits a string +error+). This mirrors that: never +.dig+ a non-Hash,
  # hand a non-typed error up as the message with a +nil+ status so ruby_llm's
  # +build_stream_error_response+ falls back to the real HTTP status.
  #
  # Redefined whole (not +prepend+ + +super+) because it's a small self-contained
  # +module_function+ with no state — faithful reproduction plus the guard is
  # clearer than wrapping the buggy original. Re-running +module_function+
  # replaces both the module method and the private copy the provider gets via
  # +include+.
  #
  # == When to delete this file
  #
  # ruby_llm main already carries an equivalent fix, in a module renamed to
  # +RubyLLM::Protocols::ChatCompletions::Streaming+ — so the next release past
  # 1.16.0 obsoletes the patch *and* moves its target. The load-time guard below
  # turns that into a boot failure naming this file; delete it and its spec then.
  module RubyLlmPatches
    module_function

    # @return [Boolean] +true+ once the patches below have been applied; a
    #   literal, kept honest by the load-time guard that raises if the target
    #   module has moved out from under it
    def applied? = true
  end
end

# Reopening a module that has moved silently defines a fresh empty one: the
# patch would stop applying, the bug would return, and nothing — not even
# {Pikuri::RubyLlmPatches.applied?} — would notice. Fail at boot instead.
unless defined?(RubyLLM::Providers::OpenAI::Streaming) &&
       RubyLLM::Providers::OpenAI::Streaming.respond_to?(:parse_streaming_error)
  raise "RubyLLM::Providers::OpenAI::Streaming.parse_streaming_error is gone from ruby_llm " \
        "#{RubyLLM::VERSION} — the streaming error-parse patch no longer applies. It is fixed " \
        'upstream: delete pikuri-core/lib/pikuri/ruby_llm_patches.rb and its spec (ruby_llm #837).'
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
        # @return [Array(Integer, nil), String] a +[status, message]+
        #   pair; +status+ is +nil+ when the body carries no error type,
        #   deferring classification to the response's HTTP status
        def parse_streaming_error(data)
          error_data = JSON.parse(data)
          # Non-Hash body (a bare JSON string/number/array): no structured
          # error to read — surface it as the message, defer status.
          return [nil, error_data.to_s] unless error_data.is_a?(Hash)

          error = error_data['error']
          return [nil, error_data.to_s] unless error
          # A string error value (xAI/Grok's {"error": "..."}) has no type
          # field — hand it up as-is, defer status to the HTTP response.
          return [nil, error] if error.is_a?(String)

          case error['type']
          when 'server_error'
            [500, error['message']]
          when 'rate_limit_exceeded', 'insufficient_quota'
            [429, error['message']]
          else
            [400, error['message']]
          end
        end
        module_function :parse_streaming_error
      end
    end
  end
end
