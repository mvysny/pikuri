# frozen_string_literal: true

require 'spec_helper'
require 'faraday'
require 'json'

describe Pikuri::VectorDb::Reranker::LlamaServer do
  # Mirror the Faraday::Adapter::Test stub pattern from
  # tokenizer/llama_server_spec.rb so request shape + response
  # parsing are exercised end-to-end with the same middleware
  # production uses.
  def build_connection(&block)
    stubs = Faraday::Adapter::Test::Stubs.new(&block)
    Faraday.new do |f|
      f.request :json
      f.response :json
      f.adapter :test, stubs
    end
  end

  # Standard JSON Content-Type header for stubbed responses —
  # Faraday's :response :json middleware only parses bodies
  # whose Content-Type is application/json.
  JSON_HEADERS = { 'Content-Type' => 'application/json' }.freeze

  describe '#initialize' do
    it 'rejects empty endpoints' do
      assert_raises(ArgumentError) do
        Pikuri::VectorDb::Reranker::LlamaServer.new(endpoint: '')
      end
    end

    it 'rejects nil endpoints' do
      assert_raises(ArgumentError) do
        Pikuri::VectorDb::Reranker::LlamaServer.new(endpoint: nil)
      end
    end

    it 'accepts a connection via dependency injection' do
      conn = build_connection { |_| }
      r = Pikuri::VectorDb::Reranker::LlamaServer.new(endpoint: 'http://x', connection: conn)
      refute_nil r
    end
  end

  describe '#rerank' do
    it 'returns [] for an empty documents array without an HTTP call' do
      conn = build_connection { |_| } # no stubs registered; any HTTP call would raise
      r = Pikuri::VectorDb::Reranker::LlamaServer.new(endpoint: 'http://stub', connection: conn)
      assert_equal [], r.rerank(query: 'anything', documents: [])
    end

    it 'POSTs query + documents and returns Hits sorted descending by score' do
      received_body = nil
      conn = build_connection do |stub|
        stub.post('/v1/rerank') do |env|
          received_body = JSON.parse(env.body)
          [200, { 'Content-Type' => 'application/json' }, {
            results: [
              { index: 1, relevance_score: 0.18 },
              { index: 2, relevance_score: 0.92 },
              { index: 0, relevance_score: 0.41 }
            ]
          }.to_json]
        end
      end
      r = Pikuri::VectorDb::Reranker::LlamaServer.new(endpoint: 'http://stub', connection: conn)

      hits = r.rerank(query: 'capital of France?', documents: %w[Berlin Madrid Paris])

      # Caller relies on the descending-by-score contract.
      assert_equal [2, 0, 1], hits.map(&:index)
      assert_in_delta 0.92, hits[0].score, 0.0001
      assert_in_delta 0.41, hits[1].score, 0.0001
      assert_in_delta 0.18, hits[2].score, 0.0001

      assert_equal 'capital of France?', received_body['query']
      assert_equal %w[Berlin Madrid Paris], received_body['documents']
    end

    it 'forwards a configured model: kwarg in the request body' do
      received_body = nil
      conn = build_connection do |stub|
        stub.post('/v1/rerank') do |env|
          received_body = JSON.parse(env.body)
          [200, JSON_HEADERS, { results: [] }.to_json]
        end
      end
      r = Pikuri::VectorDb::Reranker::LlamaServer.new(
        endpoint: 'http://stub', model: 'bge-reranker-v2-m3', connection: conn
      )

      r.rerank(query: 'q', documents: ['d'])

      assert_equal 'bge-reranker-v2-m3', received_body['model']
    end

    it 'sends a configured api_key: as a Bearer Authorization header' do
      received_headers = nil
      conn = build_connection do |stub|
        stub.post('/v1/rerank') do |env|
          received_headers = env.request_headers
          [200, JSON_HEADERS, { results: [] }.to_json]
        end
      end
      r = Pikuri::VectorDb::Reranker::LlamaServer.new(
        endpoint: 'http://stub', api_key: 'sekret', connection: conn
      )

      r.rerank(query: 'q', documents: ['d'])

      assert_equal 'Bearer sekret', received_headers['Authorization']
    end

    it 'sends no Authorization header when api_key is nil' do
      received_headers = nil
      conn = build_connection do |stub|
        stub.post('/v1/rerank') do |env|
          received_headers = env.request_headers
          [200, JSON_HEADERS, { results: [] }.to_json]
        end
      end
      r = Pikuri::VectorDb::Reranker::LlamaServer.new(endpoint: 'http://stub', connection: conn)

      r.rerank(query: 'q', documents: ['d'])

      refute received_headers.key?('Authorization')
    end

    it 'omits the model field when model is nil' do
      received_body = nil
      conn = build_connection do |stub|
        stub.post('/v1/rerank') do |env|
          received_body = JSON.parse(env.body)
          [200, JSON_HEADERS, { results: [] }.to_json]
        end
      end
      r = Pikuri::VectorDb::Reranker::LlamaServer.new(endpoint: 'http://stub', connection: conn)

      r.rerank(query: 'q', documents: ['d'])

      refute received_body.key?('model')
    end

    it 'raises on HTTP non-2xx' do
      conn = build_connection do |stub|
        stub.post('/v1/rerank') { |_| [500, {}, '{"error":"oops"}'] }
      end
      r = Pikuri::VectorDb::Reranker::LlamaServer.new(endpoint: 'http://stub', connection: conn)

      err = assert_raises(RuntimeError) { r.rerank(query: 'q', documents: ['d']) }
      assert_match(/HTTP 500/, err.message)
    end

    it "raises when the response is missing the 'results' key" do
      conn = build_connection do |stub|
        stub.post('/v1/rerank') { |_| [200, JSON_HEADERS, '{"oops":[]}'] }
      end
      r = Pikuri::VectorDb::Reranker::LlamaServer.new(endpoint: 'http://stub', connection: conn)

      err = assert_raises(RuntimeError) { r.rerank(query: 'q', documents: ['d']) }
      assert_match(/missing 'results' array/, err.message)
    end

    it 'raises when an entry is malformed (no index or no relevance_score)' do
      conn = build_connection do |stub|
        stub.post('/v1/rerank') do |_|
          [200, JSON_HEADERS, { results: [{ index: 0 }] }.to_json] # missing relevance_score
        end
      end
      r = Pikuri::VectorDb::Reranker::LlamaServer.new(endpoint: 'http://stub', connection: conn)

      err = assert_raises(RuntimeError) { r.rerank(query: 'q', documents: ['d']) }
      assert_match(/malformed result entry/, err.message)
    end

    it 'wraps Faraday::Error into a loud RuntimeError with the endpoint' do
      conn = build_connection do |stub|
        stub.post('/v1/rerank') { |_| raise Faraday::ConnectionFailed, 'connection refused' }
      end
      r = Pikuri::VectorDb::Reranker::LlamaServer.new(
        endpoint: 'http://localhost:9999', connection: conn
      )

      err = assert_raises(RuntimeError) { r.rerank(query: 'q', documents: ['d']) }
      assert_match(/ConnectionFailed/, err.message)
      assert_match(%r{localhost:9999/v1/rerank}, err.message)
    end
  end
end
