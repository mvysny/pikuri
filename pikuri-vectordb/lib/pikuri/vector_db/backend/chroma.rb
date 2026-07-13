# frozen_string_literal: true

require 'faraday'
require 'json'

module Pikuri
  module VectorDb
    module Backend
      # Thin Faraday HTTP client against a self-hosted Chroma server (v2 API),
      # targeting Chroma 0.5.x+. The persistent backend, behind the same
      # duck-typed {Backend} protocol as {InMemory} (same method names, return
      # shapes, and +ArgumentError+ contract on empty input / non-positive
      # +top_k+; the vector-dim contract diverges — see below). Hand-rolled
      # rather than a +chroma-db+ gem dep so the wire protocol stays auditable
      # in one readable file; the cost is tracking the v2 API by hand.
      #
      # Two ways to get one: **bring your own** — +Chroma.new(host:, port:,
      # collection:)+ against an existing deployment (this class is purely the
      # HTTP client); or **let pikuri manage it** —
      # {Server::Chroma.ensure_running}'s +#client(collection:)+ returns a
      # +Chroma+ pointed at a supervised container. Docker lifecycle and HTTP
      # wire protocol share nothing, so each is its own class.
      #
      # v2 endpoints used: +collections+ (get-or-create), +.../upsert+,
      # +.../query+, +.../count+, +DELETE .../{id}+, +.../delete+ (where-filtered),
      # +.../get+ (where-filtered projection).
      #
      # == BYO embeddings (Chroma's embedder is never invoked)
      #
      # Chroma collections can carry a server-side embedding function; we always
      # send pre-computed +embeddings+ and never use it. pikuri's {Embedder} is
      # the single source of truth — a parallel Chroma-side embedder would split
      # it invisibly (local embedder in pikuri + +OpenAIEmbeddingFunction+ in
      # Chroma ⇒ every indexed document silently lands at OpenAI).
      #
      # == Contracts
      #
      # * *Vector-dim* diverges from {InMemory}: enforced server-side (first
      #   upsert sets the dim; a mismatch is HTTP 4xx → +RuntimeError+, not the
      #   +ArgumentError+ InMemory raises). Same loud-failure shape; not worth
      #   parsing Chroma's error envelope to coerce the class.
      # * *Lazy collection resolution*: +new+ doesn't touch the server; the first
      #   +#upsert+/+#query+/+#count+ resolves (creating if missing) the
      #   collection by name and caches the id. +#delete_all+ clears it; the next
      #   +#upsert+ re-creates.
      # * *Cosine*: collection created +hnsw.space: 'cosine'+; Chroma returns
      #   *distance* +[0,2]+, +#query+ converts via +1 - distance+ so the
      #   {Backend::Result} score matches InMemory's similarity scale.
      # * *Metadata keys*: JSON round-trips Symbol keys to Strings, so +#upsert+
      #   stringifies and +#query+ re-symbolizes — a queried {Chunk} looks
      #   identical to one stored in InMemory. +source+ rides as a reserved
      #   metadata key (Chroma has no native +source+).
      class Chroma
        # Rows per +/get+ page in {#sources_with_hashes} — caps the parse
        # working set of the boot manifest on a large corpus (one row per file,
        # so a 50k-file corpus is ~50 localhost round trips, not one multi-MB
        # response). Small corpora finish in one page.
        MANIFEST_PAGE_SIZE = 1_000

        # @param host [String]
        # @param port [Integer]
        # @param collection [String] Chroma collection name — a Chroma-specific
        #   identifier, so it lives here, not on +VectorDb::Extension+ (a no-op
        #   for {InMemory}).
        # @param tenant [String] Chroma v2 tenant; defaults to Chroma's default.
        # @param database [String] Chroma v2 database; defaults to Chroma's default.
        # @param connection [Faraday::Connection, nil] DI point for tests.
        # @return [Chroma]
        # @raise [ArgumentError] on empty +host+ or empty +collection+.
        def initialize(host:, port:, collection:,
                       tenant: 'default_tenant',
                       database: 'default_database',
                       connection: nil)
          raise ArgumentError, 'host must be non-empty' if host.nil? || host.to_s.empty?
          raise ArgumentError, 'collection must be non-empty' if collection.nil? || collection.to_s.empty?

          @host = host
          @port = port
          @collection_name = collection
          @tenant = tenant
          @database = database
          @collection_id = nil
          @connection = connection || Faraday.new(url: "http://#{host}:#{port}") do |f|
            f.request :json
            f.response :json
            f.adapter Faraday.default_adapter
          end
        end

        # Insert-or-replace by +chunk.id+ (parallel equal-length arrays).
        # Vector-dim mismatch surfaces as +RuntimeError+ server-side (InMemory
        # raises +ArgumentError+ — see the class header).
        #
        # @param chunks [Array<Chunk>]
        # @param vectors [Array<Array<Float>>]
        # @return [void]
        # @raise [ArgumentError] on empty input or length mismatch.
        # @raise [RuntimeError] on HTTP failure.
        def upsert(chunks:, vectors:)
          raise ArgumentError, 'upsert called with empty chunks/vectors' if chunks.empty?
          if chunks.size != vectors.size
            raise ArgumentError, "size mismatch: #{chunks.size} chunks vs #{vectors.size} vectors"
          end

          ensure_collection!

          metadatas = chunks.map do |c|
            # Serialize +source+ as a reserved key in Chroma's
            # +metadata+; merge in the user's metadata Hash with
            # keys stringified for JSON round-trip stability.
            base = { 'source' => c.source }
            c.metadata.each { |k, v| base[k.to_s] = v }
            base
          end

          body = {
            ids: chunks.map(&:id),
            embeddings: vectors,
            documents: chunks.map(&:text),
            metadatas: metadatas
          }

          post_json("#{collection_path}/upsert", body)
          nil
        end

        # k-NN query by cosine similarity. Returns at most
        # +top_k+ {Backend::Result}s descending by score.
        # +score+ is +1 - cosine_distance+ so the value matches
        # {InMemory}'s cosine-similarity scale.
        #
        # @param vector [Array<Float>]
        # @param top_k [Integer]
        # @return [Array<Backend::Result>]
        # @raise [ArgumentError] on non-positive +top_k+.
        # @raise [RuntimeError] on HTTP failure.
        def query(vector:, top_k:)
          raise ArgumentError, "top_k must be positive (got #{top_k})" if top_k <= 0

          # If we've never upserted, the collection doesn't
          # exist yet — semantic answer is "no hits."
          return [] if @collection_id.nil? && !collection_exists?

          response_body = post_json("#{collection_path}/query", {
                                      query_embeddings: [vector],
                                      n_results: top_k,
                                      include: %w[documents metadatas distances]
                                    })

          ids = (response_body['ids']       || [[]]).first || []
          docs = (response_body['documents'] || [[]]).first || []
          metas = (response_body['metadatas'] || [[]]).first || []
          dists = (response_body['distances'] || [[]]).first || []

          ids.each_with_index.map do |id, i|
            meta = metas[i] || {}
            # Pull +source+ back out of the metadata blob;
            # symbolize the remaining keys for round-trip
            # consistency with InMemory.
            source = meta['source'] || ''
            chunk_meta = {}
            meta.each do |k, v|
              next if k == 'source'

              chunk_meta[k.to_sym] = v
            end

            chunk = Chunk.new(id: id, source: source, text: docs[i] || '', metadata: chunk_meta)
            Result.new(chunk: chunk, score: 1.0 - dists[i].to_f)
          end
        end

        # Drop the collection (the nuke-and-reload reindex path the {Indexer}
        # drives); the next +#upsert+ re-creates. No-op if none was created; a
        # 404 on the DELETE is treated as "already gone" — idempotent.
        #
        # @return [void]
        def delete_all
          return nil if @collection_id.nil? && !collection_exists?

          response = @connection.delete(collection_path)
          unless [200, 204, 404].include?(response.status)
            raise "Backend::Chroma: DELETE #{collection_path} returned " \
                  "HTTP #{response.status}: #{response.body.inspect}"
          end
          @collection_id = nil
          nil
        end

        # @return [Integer] current chunk count. Zero before the
        #   first +#upsert+.
        def count
          return 0 if @collection_id.nil? && !collection_exists?

          response = @connection.get("#{collection_path}/count")
          unless response.status == 200
            raise "Backend::Chroma: GET #{collection_path}/count returned " \
                  "HTTP #{response.status}: #{response.body.inspect}"
          end

          body = response.body
          # Chroma v2 returns the count as a bare integer.
          return body if body.is_a?(Integer)
          return body['count'] if body.is_a?(Hash) && body['count'].is_a?(Integer)

          raise "Backend::Chroma: count response was not an Integer (got #{body.inspect})"
        end

        # Remove every chunk whose +source+ matches, via a
        # metadata-filtered +POST .../delete+ (+source+ is the
        # reserved metadata key {#upsert} writes). The scoped
        # counterpart to {#delete_all}. No-op when the collection
        # doesn't exist yet.
        #
        # @param source [String] the {Chunk#source} to purge.
        # @return [void]
        # @raise [RuntimeError] on HTTP failure.
        def delete_by_source(source)
          return nil if @collection_id.nil? && !collection_exists?

          post_json("#{collection_path}/delete", { where: { 'source' => source } })
          nil
        end

        # Replace all chunks for one +source+: delete the old set, then upsert
        # the new (the incremental-reindex unit, {Indexer#reindex_file!}).
        #
        # *Not transactional* (the InMemory divergence): two HTTP calls, so a
        # +#query+ between them can see the source with zero chunks — a window
        # {InMemory#replace_source} closes with its monitor but Chroma can't. The
        # {Indexer} mitigates the common failure by embedding *before* calling
        # here, so an embedder outage never reaches this and the old chunks stay.
        # Delete-then-upsert, not the reverse — the reverse would delete the
        # just-written chunks.
        #
        # @param source [String] the {Chunk#source} being replaced.
        # @param chunks [Array<Chunk>] the new chunk set.
        # @param vectors [Array<Array<Float>>] parallel to +chunks+.
        # @return [void]
        # @raise [ArgumentError] on empty input or length mismatch.
        # @raise [RuntimeError] on HTTP failure.
        def replace_source(source:, chunks:, vectors:)
          delete_by_source(source)
          upsert(chunks: chunks, vectors: vectors)
          nil
        end

        # The boot-sweep reference: +source+ → stored content hash, one metadata
        # row per *file* (not per chunk) via +where: { offset: 0 }+ (every file
        # has one chunk at offset 0), +include: ['metadatas']+ (drops the heavy
        # embeddings/documents), and {MANIFEST_PAGE_SIZE} +limit+/+offset+
        # paging so a large corpus never materializes one multi-MB response.
        # (Two +offset+s collide in wording: the +where+ one is a *chunk*
        # metadata field, the top-level one is the *pagination* cursor.)
        #
        # Pagination assumes the manifest isn't mutating mid-read; the {Watcher}
        # drives this from its single worker thread, so no reindex runs
        # concurrently.
        #
        # @return [Hash{String => String, nil}] +source+ → content hash. Empty
        #   when the collection doesn't exist yet.
        # @raise [RuntimeError] on HTTP failure.
        def sources_with_hashes
          return {} if @collection_id.nil? && !collection_exists?

          result = {}
          cursor = 0
          loop do
            body = post_json("#{collection_path}/get", {
                               where: { 'offset' => 0 },
                               include: ['metadatas'],
                               limit: MANIFEST_PAGE_SIZE,
                               offset: cursor
                             })
            metas = body.is_a?(Hash) ? (body['metadatas'] || []) : []
            metas.each do |meta|
              next unless meta.is_a?(Hash) && meta['source']

              result[meta['source']] = meta['hash']
            end
            break if metas.size < MANIFEST_PAGE_SIZE

            cursor += metas.size
          end
          result
        end

        # Is +source+ in the corpus? Scoped existence check for
        # {VectorDb::Tools::Read}'s membership gate: a +where+-filtered
        # +/get+ capped at one row, +include: []+ so the response
        # carries only ids — O(1) transport regardless of corpus
        # size, never the full {#sources_with_hashes} manifest. See
        # the Backend protocol yardoc.
        #
        # @param source [String] the {Chunk#source} to test.
        # @return [Boolean] true if at least one chunk has this source.
        # @raise [RuntimeError] on HTTP failure.
        def source_indexed?(source)
          return false if @collection_id.nil? && !collection_exists?

          body = post_json("#{collection_path}/get", {
                             where: { 'source' => source },
                             include: [],
                             limit: 1
                           })
          ids = body.is_a?(Hash) ? (body['ids'] || []) : []
          !ids.empty?
        end

        private

        def collections_path
          "/api/v2/tenants/#{@tenant}/databases/#{@database}/collections"
        end

        def collection_path
          raise 'Backend::Chroma: collection_id not yet resolved' unless @collection_id

          "#{collections_path}/#{@collection_id}"
        end

        # Idempotent get-or-create against Chroma. Sets
        # +@collection_id+ on success. Returns the id String.
        def ensure_collection!
          return @collection_id if @collection_id

          body = post_json(collections_path, {
                             name: @collection_name,
                             configuration: { hnsw: { space: 'cosine' } },
                             get_or_create: true
                           })

          id = body.is_a?(Hash) ? body['id'] : nil
          raise "Backend::Chroma: collection-create response missing 'id' (got #{body.inspect})" unless id

          @collection_id = id
        end

        # Probe whether the collection exists without creating
        # it — used by +#query+ / +#count+ / +#delete_all+ to
        # short-circuit when the user queries before any upsert
        # has happened. Side-effect: caches +@collection_id+
        # when found.
        def collection_exists?
          response = @connection.get(collections_path)
          unless response.status == 200
            raise "Backend::Chroma: GET #{collections_path} returned " \
                  "HTTP #{response.status}: #{response.body.inspect}"
          end

          list = response.body
          return false unless list.is_a?(Array)

          match = list.find { |c| c.is_a?(Hash) && c['name'] == @collection_name }
          return false unless match

          @collection_id = match['id']
          true
        rescue Faraday::Error => e
          raise "Backend::Chroma: #{e.class.name.split('::').last} " \
                "calling #{collections_path}: #{e.message}"
        end

        # Tiny JSON-POST helper shared by upsert / query /
        # ensure_collection. Centralises the error-shape and
        # Faraday::Error wrapping.
        def post_json(path, body)
          response = @connection.post(path) do |req|
            req.headers['Content-Type'] = 'application/json'
            req.body = body
          end

          unless [200, 201].include?(response.status)
            raise "Backend::Chroma: POST #{path} returned " \
                  "HTTP #{response.status}: #{response.body.inspect}"
          end

          response.body
        rescue Faraday::Error => e
          raise "Backend::Chroma: #{e.class.name.split('::').last} " \
                "calling #{path}: #{e.message}"
        end
      end
    end
  end
end
