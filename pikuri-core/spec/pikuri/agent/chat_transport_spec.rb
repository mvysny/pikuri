# frozen_string_literal: true

RSpec.describe Pikuri::Agent::ChatTransport do
  describe '.from_openai_server' do
    it 'builds an :openai transport that overrides the connection' do
      t = described_class.from_openai_server(server: 'http://localhost:8080', model: 'm')
      assert_equal :openai, t.provider
      assert_equal 'm', t.model
      assert t.assume_model_exists
      assert t.connection_overrides?
    end

    it 'appends /v1 to a bare server origin' do
      t = described_class.from_openai_server(server: 'http://localhost:8080', model: 'm')
      assert_equal 'http://localhost:8080/v1', t.api_base
    end

    it 'does not double a server that already ends in /v1' do
      t = described_class.from_openai_server(server: 'https://api.x.ai/v1', model: 'm')
      assert_equal 'https://api.x.ai/v1', t.api_base
    end

    it 'normalizes a trailing /v1/ (slash) the same way' do
      t = described_class.from_openai_server(server: 'https://api.x.ai/v1/', model: 'm')
      assert_equal 'https://api.x.ai/v1', t.api_base
    end

    it 'strips a lone trailing slash' do
      t = described_class.from_openai_server(server: 'http://localhost:8080/', model: 'm')
      assert_equal 'http://localhost:8080/v1', t.api_base
    end

    it 'leaves a path that merely resembles /v1 untouched (e.g. /v10)' do
      t = described_class.from_openai_server(server: 'https://host/v10', model: 'm')
      assert_equal 'https://host/v10/v1', t.api_base
    end

    it "defaults api_key to the keyless 'not-needed' placeholder" do
      t = described_class.from_openai_server(server: 'http://localhost:8080', model: 'm')
      assert_equal 'not-needed', t.api_key
    end

    it 'carries an explicit api_key through' do
      t = described_class.from_openai_server(server: 'https://api.x.ai/v1', model: 'm', api_key: 'sk-1')
      assert_equal 'sk-1', t.api_key
    end

    it 'defaults context_window to nil (defer to the probe)' do
      t = described_class.from_openai_server(server: 'http://localhost:8080', model: 'm')
      assert_nil t.context_window
    end

    it 'carries an explicit context_window through (the cloud-cap override)' do
      t = described_class.from_openai_server(server: 'https://api.x.ai/v1', model: 'grok',
                                             context_window: 2_000_000)
      assert_equal 2_000_000, t.context_window
    end
  end

  describe '#chat_kwargs' do
    it 'exposes only the model-resolution kwargs, never the connection or the cap' do
      t = described_class.new(model: 'm', provider: :openai, assume_model_exists: true,
                              api_base: 'http://x/v1', api_key: 'k', context_window: 32_768)
      assert_equal({ model: 'm', provider: :openai, assume_model_exists: true }, t.chat_kwargs)
    end
  end

  describe 'context_window' do
    it 'defaults to nil on the bare constructor' do
      assert_nil described_class.new(model: 'm').context_window
    end

    it 'participates in structural equality (a cap-only difference is a different transport)' do
      a = described_class.new(model: 'm', context_window: 8_192)
      b = described_class.new(model: 'm', context_window: 64_000)
      c = described_class.new(model: 'm', context_window: 8_192)
      refute_equal a, b
      assert_equal a, c
    end
  end

  describe '#connection_overrides?' do
    it 'is false for a transport that rides the global config' do
      refute described_class.new(model: 'm').connection_overrides?
    end

    it 'is true when api_base is set' do
      assert described_class.new(model: 'm', provider: :openai, api_base: 'http://x/v1').connection_overrides?
    end

    it 'is true when only api_key is set' do
      assert described_class.new(model: 'm', provider: :openai, api_key: 'k').connection_overrides?
    end
  end

  describe 'validation' do
    it 'requires a provider when api_base is set' do
      assert_raises(ArgumentError) { described_class.new(model: 'm', api_base: 'http://x/v1') }
    end

    it 'requires a provider when api_key is set' do
      assert_raises(ArgumentError) { described_class.new(model: 'm', api_key: 'k') }
    end
  end

  describe '#inspect' do
    it 'redacts the api_key but keeps the rest legible' do
      s = described_class.new(model: 'm', provider: :openai, api_base: 'http://x/v1', api_key: 'secret').inspect
      refute_includes s, 'secret'
      assert_includes s, '[REDACTED]'
      assert_includes s, 'http://x/v1'
      assert_includes s, 'model="m"'
    end

    it 'shows nil for an absent api_key' do
      s = described_class.new(model: 'm').inspect
      assert_includes s, 'api_key=nil'
      refute_includes s, 'REDACTED'
    end

    it 'shows the context_window' do
      assert_includes described_class.new(model: 'm', context_window: 2_000_000).inspect,
                      'context_window=2000000'
    end
  end
end
