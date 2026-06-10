# frozen_string_literal: true

RSpec.describe Pikuri::Agent::ChatTransport do
  describe '#chat_kwargs' do
    it 'exposes only the model-resolution kwargs, never the connection' do
      t = described_class.new(model: 'm', provider: :openai, assume_model_exists: true,
                              api_base: 'http://x/v1', api_key: 'k')
      assert_equal({ model: 'm', provider: :openai, assume_model_exists: true }, t.chat_kwargs)
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
  end
end
