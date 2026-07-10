# frozen_string_literal: true

require 'json'

# Regression coverage for the ruby_llm streaming error-parse patch.
# See {Pikuri::RubyLlmPatches} and ruby_llm #837. When the fix ships
# upstream and the patch file is deleted, delete this spec with it.
RSpec.describe Pikuri::RubyLlmPatches do
  # The private/module method the patch corrects. Called by ruby_llm as
  # +parse_streaming_error(parsed_data.to_json)+ from handle_parsed_error.
  let(:mod) { RubyLLM::Providers::OpenAI::Streaming }

  it 'is applied at load' do
    assert Pikuri::RubyLlmPatches.applied?
  end

  describe '#parse_streaming_error' do
    it 'returns the body as the message for a bare JSON string (the crash case)' do
      # Pre-patch this raised TypeError: String does not have #dig, because
      # String#['error'] substring-matches past the intended key guard.
      body = %q("The model foo is not available in your region (error).")
      status, message = mod.parse_streaming_error(body)
      assert_equal 500, status
      assert_equal 'The model foo is not available in your region (error).', message
    end

    it 'does not raise on a JSON string that lacks the substring "error"' do
      status, message = mod.parse_streaming_error(%q("plain message"))
      assert_equal 500, status
      assert_equal 'plain message', message
    end

    it 'still maps a well-formed rate-limit error hash to 429' do
      body = { error: { type: 'rate_limit_exceeded', message: 'slow down' } }.to_json
      status, message = mod.parse_streaming_error(body)
      assert_equal 429, status
      assert_equal 'slow down', message
    end

    it 'still maps a server_error hash to 500' do
      body = { error: { type: 'server_error', message: 'boom' } }.to_json
      status, message = mod.parse_streaming_error(body)
      assert_equal 500, status
      assert_equal 'boom', message
    end

    it 'maps an unrecognized error type to 400' do
      body = { error: { type: 'invalid_request_error', message: 'bad param' } }.to_json
      status, message = mod.parse_streaming_error(body)
      assert_equal 400, status
      assert_equal 'bad param', message
    end

    it 'is picked up through include as a private instance method' do
      # This is how ruby_llm actually calls it: the provider includes the
      # Streaming module, so the fix must reach the instance-method copy.
      klass = Class.new { include RubyLLM::Providers::OpenAI::Streaming }
      status, = klass.new.send(:parse_streaming_error, %q("some error body"))
      assert_equal 500, status
    end
  end
end
