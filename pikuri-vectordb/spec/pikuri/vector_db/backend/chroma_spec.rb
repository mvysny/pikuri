# frozen_string_literal: true

require 'spec_helper'
require 'faraday'
require 'json'

describe Pikuri::VectorDb::Backend::Chroma do
  JSON_HEADERS = { 'Content-Type' => 'application/json' }.freeze

  # Mirror the Faraday::Adapter::Test stub pattern from the
  # other LlamaServer specs. The block is the full Stubs DSL.
  def build_connection(&block)
    stubs = Faraday::Adapter::Test::Stubs.new(&block)
    Faraday.new do |f|
      f.request :json
      f.response :json
      f.adapter :test, stubs
    end
  end

  let(:collection_path) do
    '/api/v2/tenants/default_tenant/databases/default_database/collections'
  end

  let(:collection_id) { 'abc-collection-uuid' }

  def build_backend(conn:)
    Pikuri::VectorDb::Backend::Chroma.new(
      host: 'localhost', port: 8000,
      collection: 'test-coll', connection: conn
    )
  end

  describe '#initialize' do
    it 'rejects empty host' do
      assert_raises(ArgumentError) do
        Pikuri::VectorDb::Backend::Chroma.new(host: '', port: 8000, collection: 'c')
      end
    end

    it 'rejects empty collection' do
      assert_raises(ArgumentError) do
        Pikuri::VectorDb::Backend::Chroma.new(host: 'localhost', port: 8000, collection: '')
      end
    end

    it 'does not call the server on construction (lazy)' do
      # No stubs registered → any HTTP call would raise. Reaching
      # the end of the block proves no call happened.
      conn = build_connection { |_| }
      backend = build_backend(conn: conn)
      refute_nil backend
    end
  end

  describe '#upsert' do
    let(:c_a) { Pikuri::VectorDb::Chunk.new(id: 'a', source: 'docs/a.md', text: 'apple', metadata: { offset: 0 }) }
    let(:c_b) { Pikuri::VectorDb::Chunk.new(id: 'b', source: 'docs/b.md', text: 'banana', metadata: { offset: 64 }) }
    let(:v_a) { [1.0, 0.0, 0.0] }
    let(:v_b) { [0.0, 1.0, 0.0] }

    it 'creates the collection on first upsert and sends the expected body' do
      received_upsert_body = nil
      conn = build_connection do |stub|
        stub.post(collection_path) do |_env|
          [200, JSON_HEADERS, { id: collection_id, name: 'test-coll' }.to_json]
        end
        stub.post("#{collection_path}/#{collection_id}/upsert") do |env|
          received_upsert_body = JSON.parse(env.body)
          [200, JSON_HEADERS, '{}']
        end
      end

      build_backend(conn: conn).upsert(chunks: [c_a, c_b], vectors: [v_a, v_b])

      assert_equal %w[a b], received_upsert_body['ids']
      assert_equal [v_a, v_b], received_upsert_body['embeddings']
      assert_equal %w[apple banana], received_upsert_body['documents']
      # +source+ rides as a reserved key, alongside symbolized
      # metadata keys stringified for JSON.
      assert_equal({ 'source' => 'docs/a.md', 'offset' => 0 }, received_upsert_body['metadatas'][0])
      assert_equal({ 'source' => 'docs/b.md', 'offset' => 64 }, received_upsert_body['metadatas'][1])
    end

    it 'passes get_or_create + cosine in the collection-create body' do
      received_create_body = nil
      conn = build_connection do |stub|
        stub.post(collection_path) do |env|
          received_create_body = JSON.parse(env.body)
          [200, JSON_HEADERS, { id: collection_id, name: 'test-coll' }.to_json]
        end
        stub.post("#{collection_path}/#{collection_id}/upsert") do |_|
          [200, JSON_HEADERS, '{}']
        end
      end

      build_backend(conn: conn).upsert(chunks: [c_a], vectors: [v_a])

      assert_equal 'test-coll', received_create_body['name']
      assert_equal true, received_create_body['get_or_create']
      assert_equal 'cosine', received_create_body.dig('configuration', 'hnsw', 'space')
    end

    it 'caches the collection_id; subsequent upserts skip the create call' do
      create_calls = 0
      upsert_calls = 0
      conn = build_connection do |stub|
        stub.post(collection_path) do |_|
          create_calls += 1
          [200, JSON_HEADERS, { id: collection_id, name: 'test-coll' }.to_json]
        end
        stub.post("#{collection_path}/#{collection_id}/upsert") do |_|
          upsert_calls += 1
          [200, JSON_HEADERS, '{}']
        end
      end

      backend = build_backend(conn: conn)
      backend.upsert(chunks: [c_a], vectors: [v_a])
      backend.upsert(chunks: [c_b], vectors: [v_b])

      assert_equal 1, create_calls # create only on first
      assert_equal 2, upsert_calls
    end

    it 'raises on empty input (matches InMemory contract)' do
      conn = build_connection { |_| }
      backend = build_backend(conn: conn)
      assert_raises(ArgumentError) { backend.upsert(chunks: [], vectors: []) }
    end

    it 'raises on length mismatch (matches InMemory contract)' do
      conn = build_connection { |_| }
      backend = build_backend(conn: conn)
      assert_raises(ArgumentError) { backend.upsert(chunks: [c_a], vectors: [v_a, v_b]) }
    end

    it 'raises on HTTP non-2xx from upsert' do
      conn = build_connection do |stub|
        stub.post(collection_path) do |_|
          [200, JSON_HEADERS, { id: collection_id, name: 'test-coll' }.to_json]
        end
        stub.post("#{collection_path}/#{collection_id}/upsert") do |_|
          [500, JSON_HEADERS, '{"error":"oops"}']
        end
      end

      err = assert_raises(RuntimeError) { build_backend(conn: conn).upsert(chunks: [c_a], vectors: [v_a]) }
      assert_match(/HTTP 500/, err.message)
    end

    it 'wraps Faraday::Error from upsert as a loud RuntimeError' do
      conn = build_connection do |stub|
        stub.post(collection_path) { |_| raise Faraday::ConnectionFailed, 'no route' }
      end

      err = assert_raises(RuntimeError) { build_backend(conn: conn).upsert(chunks: [c_a], vectors: [v_a]) }
      assert_match(/ConnectionFailed/, err.message)
    end
  end

  describe '#query' do
    let(:vector) { [1.0, 0.0, 0.0] }

    # Build a connection wired to return one collection + a
    # canned query response. Captures the query body for
    # request-shape assertions.
    def query_connection(query_payload:, captured: nil)
      build_connection do |stub|
        stub.get(collection_path) do |_|
          [200, JSON_HEADERS, [{ id: collection_id, name: 'test-coll' }].to_json]
        end
        stub.post("#{collection_path}/#{collection_id}/query") do |env|
          captured << JSON.parse(env.body) if captured
          [200, JSON_HEADERS, query_payload.to_json]
        end
      end
    end

    it 'returns [] when the collection does not exist yet' do
      conn = build_connection do |stub|
        stub.get(collection_path) do |_|
          [200, JSON_HEADERS, '[]'] # empty list — no collections
        end
      end

      assert_equal [], build_backend(conn: conn).query(vector: vector, top_k: 5)
    end

    it 'parses the Chroma response into Result objects with sources/metadata restored' do
      payload = {
        ids: [%w[a b]],
        documents: [%w[apple banana]],
        metadatas: [[
          { 'source' => 'docs/a.md', 'offset' => 0 },
          { 'source' => 'docs/b.md', 'offset' => 64 }
        ]],
        distances: [[0.1, 0.5]] # cosine distance; similarity = 1 - dist
      }
      conn = query_connection(query_payload: payload)

      results = build_backend(conn: conn).query(vector: vector, top_k: 5)

      assert_equal 2, results.size
      assert_equal 'a', results[0].chunk.id
      assert_equal 'docs/a.md', results[0].chunk.source
      assert_equal 'apple', results[0].chunk.text
      # Symbol keys restored on round-trip.
      assert_equal({ offset: 0 }, results[0].chunk.metadata)
      assert_in_delta 0.9, results[0].score, 0.0001  # 1 - 0.1
      assert_in_delta 0.5, results[1].score, 0.0001  # 1 - 0.5
    end

    it 'sends the expected query body shape' do
      captured = []
      conn = query_connection(
        captured: captured,
        query_payload: { ids: [[]], documents: [[]], metadatas: [[]], distances: [[]] }
      )

      build_backend(conn: conn).query(vector: vector, top_k: 7)

      assert_equal [vector], captured.first['query_embeddings']
      assert_equal 7, captured.first['n_results']
      assert_includes captured.first['include'], 'distances'
    end

    it 'raises on non-positive top_k (matches InMemory)' do
      conn = build_connection { |_| }
      backend = build_backend(conn: conn)
      assert_raises(ArgumentError) { backend.query(vector: vector, top_k: 0) }
      assert_raises(ArgumentError) { backend.query(vector: vector, top_k: -1) }
    end

    it 'raises on HTTP non-2xx' do
      conn = build_connection do |stub|
        stub.get(collection_path) do |_|
          [200, JSON_HEADERS, [{ id: collection_id, name: 'test-coll' }].to_json]
        end
        stub.post("#{collection_path}/#{collection_id}/query") { |_| [500, JSON_HEADERS, '{}'] }
      end

      err = assert_raises(RuntimeError) { build_backend(conn: conn).query(vector: vector, top_k: 5) }
      assert_match(/HTTP 500/, err.message)
    end
  end

  describe '#count' do
    it 'returns 0 when the collection does not exist yet' do
      conn = build_connection do |stub|
        stub.get(collection_path) do |_|
          [200, JSON_HEADERS, '[]'] # empty list
        end
      end

      assert_equal 0, build_backend(conn: conn).count
    end

    it 'returns the integer count from the server' do
      conn = build_connection do |stub|
        stub.get(collection_path) do |_|
          [200, JSON_HEADERS, [{ id: collection_id, name: 'test-coll' }].to_json]
        end
        stub.get("#{collection_path}/#{collection_id}/count") do |_|
          [200, JSON_HEADERS, '42']
        end
      end

      assert_equal 42, build_backend(conn: conn).count
    end
  end

  describe '#delete_all' do
    it 'is a no-op when the collection was never created' do
      conn = build_connection do |stub|
        stub.get(collection_path) { |_| [200, JSON_HEADERS, '[]'] }
      end
      # Reaching the assertion without an HTTP DELETE-call stub
      # would have errored if DELETE was issued.
      build_backend(conn: conn).delete_all
    end

    it 'DELETEs the collection and clears the cached id' do
      delete_calls = 0
      conn = build_connection do |stub|
        stub.get(collection_path) do |_|
          [200, JSON_HEADERS, [{ id: collection_id, name: 'test-coll' }].to_json]
        end
        stub.delete("#{collection_path}/#{collection_id}") do |_|
          delete_calls += 1
          [204, {}, '']
        end
      end

      build_backend(conn: conn).delete_all

      assert_equal 1, delete_calls
    end

    it 'treats 404 as idempotent (already gone)' do
      conn = build_connection do |stub|
        stub.get(collection_path) do |_|
          [200, JSON_HEADERS, [{ id: collection_id, name: 'test-coll' }].to_json]
        end
        stub.delete("#{collection_path}/#{collection_id}") { |_| [404, {}, ''] }
      end

      build_backend(conn: conn).delete_all # no raise
    end

    it 'raises on unexpected HTTP error (5xx)' do
      conn = build_connection do |stub|
        stub.get(collection_path) do |_|
          [200, JSON_HEADERS, [{ id: collection_id, name: 'test-coll' }].to_json]
        end
        stub.delete("#{collection_path}/#{collection_id}") { |_| [500, {}, '{}'] }
      end

      err = assert_raises(RuntimeError) { build_backend(conn: conn).delete_all }
      assert_match(/HTTP 500/, err.message)
    end
  end

  # A connection with the collection already resolvable via GET,
  # plus whatever extra stubs the block registers.
  def with_existing_collection(&block)
    build_connection do |stub|
      stub.get(collection_path) do |_|
        [200, JSON_HEADERS, [{ id: collection_id, name: 'test-coll' }].to_json]
      end
      block.call(stub)
    end
  end

  describe '#delete_by_source' do
    it 'is a no-op when the collection was never created' do
      conn = build_connection do |stub|
        stub.get(collection_path) { |_| [200, JSON_HEADERS, '[]'] }
      end
      # No /delete stub: issuing one would error.
      build_backend(conn: conn).delete_by_source('docs/a.md')
    end

    it 'POSTs a where-filtered delete on the source' do
      captured = nil
      conn = with_existing_collection do |stub|
        stub.post("#{collection_path}/#{collection_id}/delete") do |env|
          captured = JSON.parse(env.body)
          [200, JSON_HEADERS, '{}']
        end
      end

      build_backend(conn: conn).delete_by_source('docs/a.md')

      assert_equal({ 'where' => { 'source' => 'docs/a.md' } }, captured)
    end
  end

  describe '#sources_with_hashes' do
    it 'returns {} when the collection does not exist yet' do
      conn = build_connection do |stub|
        stub.get(collection_path) { |_| [200, JSON_HEADERS, '[]'] }
      end

      assert_equal({}, build_backend(conn: conn).sources_with_hashes)
    end

    it 'requests one row per file (offset 0) with a metadata-only projection' do
      captured = nil
      conn = with_existing_collection do |stub|
        stub.post("#{collection_path}/#{collection_id}/get") do |env|
          captured = JSON.parse(env.body)
          [200, JSON_HEADERS, { metadatas: [] }.to_json]
        end
      end

      build_backend(conn: conn).sources_with_hashes

      assert_equal({ 'offset' => 0 }, captured['where'])
      assert_equal ['metadatas'], captured['include']
    end

    it 'maps each source to its stored content hash' do
      conn = with_existing_collection do |stub|
        stub.post("#{collection_path}/#{collection_id}/get") do |_|
          payload = { metadatas: [
            { 'source' => 'docs/a.md', 'offset' => 0, 'hash' => 'aaa' },
            { 'source' => 'docs/b.md', 'offset' => 0, 'hash' => 'bbb' }
          ] }
          [200, JSON_HEADERS, payload.to_json]
        end
      end

      result = build_backend(conn: conn).sources_with_hashes

      assert_equal({ 'docs/a.md' => 'aaa', 'docs/b.md' => 'bbb' }, result)
    end
  end

  describe '#replace_source' do
    let(:chunk) do
      Pikuri::VectorDb::Chunk.new(id: 'docs/a.md:0', source: 'docs/a.md', text: 'apple',
                                  metadata: { offset: 0, hash: 'aaa' })
    end

    it 'deletes the source then upserts the new chunks' do
      calls = []
      conn = with_existing_collection do |stub|
        stub.post("#{collection_path}/#{collection_id}/delete") do |env|
          calls << [:delete, JSON.parse(env.body)]
          [200, JSON_HEADERS, '{}']
        end
        stub.post("#{collection_path}/#{collection_id}/upsert") do |env|
          calls << [:upsert, JSON.parse(env.body)]
          [200, JSON_HEADERS, '{}']
        end
      end

      build_backend(conn: conn).replace_source(
        source: 'docs/a.md', chunks: [chunk], vectors: [[1.0, 0.0, 0.0]]
      )

      assert_equal %i[delete upsert], calls.map(&:first) # delete precedes upsert
      assert_equal({ 'source' => 'docs/a.md' }, calls[0][1]['where'])
      assert_equal ['docs/a.md:0'], calls[1][1]['ids']
    end
  end
end
