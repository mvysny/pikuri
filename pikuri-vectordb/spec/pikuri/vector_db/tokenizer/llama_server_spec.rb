# frozen_string_literal: true

require 'spec_helper'
require 'faraday'
require 'json'

describe Pikuri::VectorDb::Tokenizer::LlamaServer do
  # Build a Faraday connection wired to a Test::Stubs adapter,
  # mirroring the production middleware (+request :json+ /
  # +response :json+) so the LlamaServer sees the same parsed
  # body shape it would in real use.
  def build_connection(&block)
    stubs = Faraday::Adapter::Test::Stubs.new(&block)
    Faraday.new do |f|
      f.request :json
      f.response :json
      f.adapter :test, stubs
    end
  end

  describe '#initialize' do
    it 'rejects empty endpoints' do
      assert_raises(ArgumentError) do
        Pikuri::VectorDb::Tokenizer::LlamaServer.new(endpoint: '')
      end
    end

    it 'rejects nil endpoints' do
      assert_raises(ArgumentError) do
        Pikuri::VectorDb::Tokenizer::LlamaServer.new(endpoint: nil)
      end
    end

    it 'accepts a connection via dependency injection' do
      connection = build_connection { |_| }
      tokenizer = Pikuri::VectorDb::Tokenizer::LlamaServer.new(
        endpoint: 'http://example.invalid', connection: connection
      )
      refute_nil tokenizer
    end
  end

  describe '#count' do
    it 'returns 0 for the empty string without making an HTTP call' do
      # No stubs → any HTTP call would raise; reaching the
      # return value proves we short-circuited.
      connection = build_connection { |_| }
      tokenizer = Pikuri::VectorDb::Tokenizer::LlamaServer.new(
        endpoint: 'http://stub', connection: connection
      )
      assert_equal 0, tokenizer.count('')
    end

    it 'POSTs to /tokenize and returns tokens.length' do
      received_body = nil
      connection = build_connection do |stub|
        stub.post('/tokenize') do |env|
          received_body = JSON.parse(env.body)
          [200, { 'Content-Type' => 'application/json' }, { 'tokens' => [1, 2, 3, 4, 5] }.to_json]
        end
      end
      tokenizer = Pikuri::VectorDb::Tokenizer::LlamaServer.new(
        endpoint: 'http://stub', connection: connection
      )

      assert_equal 5, tokenizer.count('hello world')
      assert_equal({ 'content' => 'hello world' }, received_body)
    end

    it 'raises on HTTP non-2xx' do
      connection = build_connection do |stub|
        stub.post('/tokenize') { |_| [500, {}, '{"error":"oops"}'] }
      end
      tokenizer = Pikuri::VectorDb::Tokenizer::LlamaServer.new(
        endpoint: 'http://stub', connection: connection
      )

      err = assert_raises(RuntimeError) { tokenizer.count('hi') }
      assert_match(/HTTP 500/, err.message)
    end

    it "raises when the response is missing the 'tokens' key" do
      connection = build_connection do |stub|
        stub.post('/tokenize') { |_| [200, {}, '{"oops":[1,2]}'] }
      end
      tokenizer = Pikuri::VectorDb::Tokenizer::LlamaServer.new(
        endpoint: 'http://stub', connection: connection
      )

      err = assert_raises(RuntimeError) { tokenizer.count('hi') }
      assert_match(/missing 'tokens' array/, err.message)
    end

    it 'raises when the response body is not a JSON object' do
      connection = build_connection do |stub|
        stub.post('/tokenize') { |_| [200, {}, '[1,2,3]'] }
      end
      tokenizer = Pikuri::VectorDb::Tokenizer::LlamaServer.new(
        endpoint: 'http://stub', connection: connection
      )

      err = assert_raises(RuntimeError) { tokenizer.count('hi') }
      assert_match(/missing 'tokens' array/, err.message)
    end

    it 'wraps Faraday::Error into a loud RuntimeError' do
      connection = build_connection do |stub|
        stub.post('/tokenize') { |_| raise Faraday::ConnectionFailed, 'connection refused' }
      end
      tokenizer = Pikuri::VectorDb::Tokenizer::LlamaServer.new(
        endpoint: 'http://localhost:9999', connection: connection
      )

      err = assert_raises(RuntimeError) { tokenizer.count('hi') }
      assert_match(/ConnectionFailed/, err.message)
      assert_match(%r{localhost:9999/tokenize}, err.message)
    end
  end
end
