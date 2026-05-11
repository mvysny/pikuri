# frozen_string_literal: true

require 'faraday'
require 'faraday/adapter/test'
require 'stringio'

require 'agent'

# Drive +ContextWindowDetector#detect+ against an in-memory Faraday test
# adapter for the /props probe. Same +Faraday.new+ stub pattern as
# +spec/tool/scraper/simple_spec.rb+. The log sink is swapped to a
# +StringIO+ so probe-failure warnings can be asserted on without leaking
# to +$stderr+.
RSpec.describe Agent::ContextWindowDetector do
  let(:buf) { StringIO.new }

  before do
    @original_io = Pikuri.log_io
    Pikuri.log_io = buf
  end

  after { Pikuri.log_io = @original_io }

  let(:stubs) { Faraday::Adapter::Test::Stubs.new }

  around do |example|
    original_new = Faraday.method(:new)
    test_stubs = stubs
    Faraday.define_singleton_method(:new) do |*_, **_|
      Faraday::Connection.new { |b| b.adapter :test, test_stubs }
    end
    begin
      example.run
    ensure
      Faraday.define_singleton_method(:new, original_new)
    end
  end

  describe 'precedence' do
    it 'returns the override when set, ignoring ruby_llm_reported and the probe' do
      detector = described_class.new(
        override: 64_000,
        ruby_llm_reported: 32_000,
        llama_probe_url: 'http://example.com/props'
      )
      # No stub registered: if the probe were attempted, the test adapter
      # would raise on the un-stubbed request.
      assert_equal 64_000, detector.detect
    end

    it 'returns ruby_llm_reported when override is nil' do
      detector = described_class.new(
        override: nil,
        ruby_llm_reported: 200_000,
        llama_probe_url: 'http://example.com/props'
      )
      assert_equal 200_000, detector.detect
    end

    it 'probes llama.cpp /props when override and ruby_llm_reported are both nil' do
      stubs.get('http://example.com/props') do
        [200, { 'content-type' => 'application/json' },
         JSON.generate('default_generation_settings' => { 'n_ctx' => 32_768 })]
      end
      detector = described_class.new(
        override: nil, ruby_llm_reported: nil, llama_probe_url: 'http://example.com/props'
      )
      assert_equal 32_768, detector.detect
    end

    it 'returns nil when all three sources are unset' do
      detector = described_class.new(override: nil, ruby_llm_reported: nil, llama_probe_url: nil)
      assert_nil detector.detect
    end

    it 'skips the probe when llama_probe_url is the empty string' do
      detector = described_class.new(override: nil, ruby_llm_reported: nil, llama_probe_url: '')
      assert_nil detector.detect
      assert_equal '', buf.string
    end
  end

  describe 'probe failure modes' do
    let(:url) { 'http://example.com/props' }
    let(:detector) do
      described_class.new(override: nil, ruby_llm_reported: nil, llama_probe_url: url)
    end

    it 'returns nil and warns on a non-200 response' do
      stubs.get(url) { [404, {}, ''] }
      assert_nil detector.detect
      assert_includes buf.string, 'HTTP 404 from'
    end

    it 'returns nil and warns on Faraday::ConnectionFailed' do
      stubs.get(url) { raise Faraday::ConnectionFailed, 'getaddrinfo: Name does not resolve' }
      assert_nil detector.detect
      assert_includes buf.string, 'ConnectionFailed'
    end

    it 'returns nil and warns on Faraday::TimeoutError' do
      stubs.get(url) { raise Faraday::TimeoutError, 'execution expired' }
      assert_nil detector.detect
      assert_includes buf.string, 'TimeoutError'
    end

    it 'returns nil and warns on a malformed JSON body' do
      stubs.get(url) { [200, { 'content-type' => 'application/json' }, 'not-json'] }
      assert_nil detector.detect
      assert_includes buf.string, 'ParserError'
    end

    it 'returns nil and warns when default_generation_settings.n_ctx is missing' do
      stubs.get(url) { [200, {}, JSON.generate('other' => 1)] }
      assert_nil detector.detect
      assert_includes buf.string, 'default_generation_settings.n_ctx'
    end

    it 'returns nil and warns when n_ctx is not a positive integer' do
      stubs.get(url) do
        [200, {}, JSON.generate('default_generation_settings' => { 'n_ctx' => 0 })]
      end
      assert_nil detector.detect
      assert_includes buf.string, 'default_generation_settings.n_ctx'
    end

    it 'returns nil and warns when n_ctx is a string rather than an integer' do
      stubs.get(url) do
        [200, {}, JSON.generate('default_generation_settings' => { 'n_ctx' => '4096' })]
      end
      assert_nil detector.detect
      assert_includes buf.string, 'default_generation_settings.n_ctx'
    end
  end
end
