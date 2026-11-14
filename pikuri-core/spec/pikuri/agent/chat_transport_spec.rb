# frozen_string_literal: true

RSpec.describe Pikuri::Agent::ChatTransport do
  describe '.from_openai_server' do
    it 'builds an :openai transport that names its server' do
      t = described_class.from_openai_server(server: 'http://localhost:8080', model: 'm')
      assert_equal :openai, t.provider
      assert_equal 'm', t.model
      assert t.assume_model_exists
      refute_nil t.api_base
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

    it 'defaults params to empty' do
      t = described_class.from_openai_server(server: 'http://localhost:8080', model: 'm')
      assert_empty t.params
    end

    it 'carries a params table through, symbolized (the TOML-table spelling)' do
      t = described_class.from_openai_server(
        server: 'http://localhost:8080', model: 'm',
        params: { 'chat_template_kwargs' => { 'enable_thinking' => false } }
      )
      assert_equal({ chat_template_kwargs: { enable_thinking: false } }, t.params)
    end
  end

  describe '#chat_kwargs' do
    it 'exposes only the model-resolution kwargs, never the connection, cap or params' do
      t = described_class.new(model: 'm', provider: :openai, assume_model_exists: true,
                              api_base: 'http://x/v1', api_key: 'k', context_window: 32_768,
                              params: { min_p: 0.05 })
      assert_equal({ model: 'm', provider: :openai, assume_model_exists: true }, t.chat_kwargs)
    end
  end

  describe 'params' do
    it 'defaults to an empty hash on the bare constructor' do
      assert_empty described_class.new(model: 'm').params
    end

    it 'symbolizes nested keys, so the merge reaches into a provider subtree' do
      t = described_class.new(model: 'm', params: { 'a' => { 'b' => [{ 'c' => 1 }] } })
      assert_equal({ a: { b: [{ c: 1 }] } }, t.params)
    end

    it 'leaves values alone — only keys are touched' do
      t = described_class.new(model: 'm', params: { 'grammar' => 'root ::= "yes"' })
      assert_equal({ grammar: 'root ::= "yes"' }, t.params)
    end

    it 'freezes the table and its subtrees, so the transport stays a value' do
      t = described_class.new(model: 'm', params: { 'a' => { 'b' => [1] } })
      assert t.params.frozen?
      assert t.params[:a].frozen?
      assert t.params[:a][:b].frozen?
    end

    it 'leaves a scalar value as it came, frozen or not (only nodes are rebuilt)' do
      value = String.new('root ::= "yes"')
      t = described_class.new(model: 'm', params: { 'grammar' => value })
      refute t.params[:grammar].frozen?
      assert_same value, t.params[:grammar]
    end

    it 'raises on one key named in both spellings, rather than picking one' do
      err = assert_raises(ArgumentError) do
        described_class.new(model: 'm', params: { 'temperature' => 0.1, temperature: 0.9 })
      end
      assert_includes err.message, 'temperature'
    end

    it 'raises on a collision nested in a subtree too' do
      assert_raises(ArgumentError) do
        described_class.new(model: 'm', params: { outer: { 'x' => 1, x: 2 } })
      end
    end

    it 'does not alias the caller-s hash' do
      given = { 'min_p' => 0.05 }
      t = described_class.new(model: 'm', params: given)
      given['min_p'] = 0.9
      assert_equal({ min_p: 0.05 }, t.params)
    end

    it 'survives Data#with, so a forwarded transport keeps them' do
      t = described_class.new(model: 'm', params: { 'min_p' => 0.05 })
      assert_equal({ min_p: 0.05 }, t.with(context_window: 8_192).params)
    end

    it 'participates in structural equality (a params-only difference is a different transport)' do
      a = described_class.new(model: 'm', params: { 'min_p' => 0.05 })
      b = described_class.new(model: 'm', params: { 'min_p' => 0.9 })
      c = described_class.new(model: 'm', params: { min_p: 0.05 })
      refute_equal a, b
      # The symbolizing is what makes the string- and symbol-keyed spellings
      # one transport rather than two.
      assert_equal a, c
    end

    it 'raises on a non-Hash rather than silently sending nothing' do
      assert_raises(ArgumentError) { described_class.new(model: 'm', params: 'min_p=0.05') }
      assert_raises(ArgumentError) { described_class.new(model: 'm', params: nil) }
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

    it 'shows the params, so a log line says which connection was configured' do
      # Hash#inspect punctuation moved in Ruby 3.4; match the content, not it.
      s = described_class.new(model: 'm', params: { 'min_p' => 0.05 }).inspect
      assert_includes s, 'params='
      assert_includes s, 'min_p'
      assert_includes s, '0.05'
    end
  end
end
