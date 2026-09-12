# frozen_string_literal: true

require 'spec_helper'

describe Pikuri::VectorDb::Embedder do
  # Stub +RubyLLM.embed+ via +define_singleton_method+ — the
  # pattern pikuri-core/spec/pikuri/agent_spec.rb established
  # for ruby_llm singletons (rspec-mocks isn't in the closure;
  # AGENTS.md "Tests" convention).
  let(:fake_vectors) { [[0.1, 0.2, 0.3], [0.4, 0.5, 0.6]] }
  let(:captured_calls) { [] }

  before do
    @original_embed = RubyLLM.method(:embed)
    captured = captured_calls
    fake_vectors_ref = fake_vectors
    fake_embedding_class = Struct.new(:vectors)
    RubyLLM.define_singleton_method(:embed) do |texts, **kw|
      captured << { texts: texts, kw: kw }
      fake_embedding_class.new(fake_vectors_ref)
    end
  end

  after do
    original = @original_embed
    RubyLLM.define_singleton_method(:embed) do |*args, **kw|
      original.call(*args, **kw)
    end
  end

  describe '#initialize' do
    it 'defaults model to nil (defer to RubyLLM.config.default_embedding_model)' do
      embedder = Pikuri::VectorDb::Embedder.new
      assert_nil embedder.model
    end

    it 'accepts a model name' do
      embedder = Pikuri::VectorDb::Embedder.new(model: 'nomic-embed-text-v1.5')
      assert_equal 'nomic-embed-text-v1.5', embedder.model
    end

    it 'defaults provider to nil and assume_model_exists to false' do
      embedder = Pikuri::VectorDb::Embedder.new
      assert_nil embedder.provider
      refute embedder.assume_model_exists
    end

    it 'accepts provider: and assume_model_exists: for local llama-server use' do
      embedder = Pikuri::VectorDb::Embedder.new(
        model: 'nomic-ai/nomic-embed-text-v1.5-GGUF:Q8_0',
        provider: :openai,
        assume_model_exists: true
      )
      assert_equal :openai, embedder.provider
      assert embedder.assume_model_exists
    end

    it 'rejects assume_model_exists: true without an explicit provider (RubyLLM requirement)' do
      err = assert_raises(ArgumentError) do
        Pikuri::VectorDb::Embedder.new(model: 'foo', assume_model_exists: true)
      end
      assert_match(/provider: must be specified/, err.message)
    end
  end

  describe '#embed' do
    it 'passes texts through to RubyLLM.embed and returns vectors' do
      embedder = Pikuri::VectorDb::Embedder.new
      result = embedder.embed(%w[alpha beta])

      assert_equal fake_vectors, result
      assert_equal 1, captured_calls.length
      assert_equal %w[alpha beta], captured_calls.first[:texts]
    end

    it 'forwards a configured model: kwarg to RubyLLM.embed' do
      embedder = Pikuri::VectorDb::Embedder.new(model: 'bge-small-en-v1.5')
      embedder.embed(['hi'])

      assert_equal 'bge-small-en-v1.5', captured_calls.first[:kw][:model]
    end

    it 'omits the model: kwarg when model is nil' do
      embedder = Pikuri::VectorDb::Embedder.new
      embedder.embed(['hi'])

      refute captured_calls.first[:kw].key?(:model)
    end

    it 'forwards provider: and assume_model_exists: kwargs to RubyLLM.embed' do
      embedder = Pikuri::VectorDb::Embedder.new(
        model: 'router/model',
        provider: :openai,
        assume_model_exists: true
      )
      embedder.embed(['hi'])

      kw = captured_calls.first[:kw]
      assert_equal :openai, kw[:provider]
      assert_equal true, kw[:assume_model_exists]
    end

    it 'omits provider: and assume_model_exists: when at defaults' do
      embedder = Pikuri::VectorDb::Embedder.new(model: 'some-model')
      embedder.embed(['hi'])

      kw = captured_calls.first[:kw]
      refute kw.key?(:provider)
      refute kw.key?(:assume_model_exists)
    end

    it 'short-circuits empty input without an HTTP call' do
      embedder = Pikuri::VectorDb::Embedder.new
      assert_equal [], embedder.embed([])
      assert_empty captured_calls
    end

    it 'rejects non-Array input' do
      embedder = Pikuri::VectorDb::Embedder.new
      err = assert_raises(ArgumentError) { embedder.embed('one string') }
      assert_match(/expected Array<String>/, err.message)
    end

    it 'rejects an Array containing non-String elements' do
      embedder = Pikuri::VectorDb::Embedder.new
      err = assert_raises(ArgumentError) { embedder.embed(['ok', 42, 'also ok']) }
      assert_match(/all elements must be String/, err.message)
    end

    it 'propagates errors raised by RubyLLM.embed verbatim (loud failure)' do
      RubyLLM.define_singleton_method(:embed) do |*_args, **_kw|
        raise 'provider 503: service unavailable'
      end

      embedder = Pikuri::VectorDb::Embedder.new
      err = assert_raises(RuntimeError) { embedder.embed(['hi']) }
      assert_match(/provider 503/, err.message)
    end
  end
end
