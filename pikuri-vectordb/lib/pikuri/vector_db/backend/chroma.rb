# frozen_string_literal: true

require 'faraday'
require 'json'

module Pikuri
  module VectorDb
    module Backend
      # Thin Faraday HTTP client against a self-hosted Chroma
      # server (v2 API). The persistent backend, behind the same
      # duck-typed {Backend} protocol as {InMemory}: same method
      # names, same return shapes, same +ArgumentError+ contract
      # on empty input + non-positive +top_k+. Where the two
      # diverge is the vector-dim contract — see below.
      #
      # == Two ways to get one
      #
      # * **Bring your own.** +Backend::Chroma.new(host:, port:,
      #   collection:)+ against an existing chroma deployment
      #   (production cluster, docker-compose stack, a chroma
      #   already running on the host for an unrelated project).
      #   The host owns the process; this class is purely the
      #   HTTP client.
      # * **Let pikuri manage it.** {ChromaServer.ensure_running}
      #   spawns and supervises a chroma container under the
      #   +pikuri-internal-chroma+ name, against a pinned image,
      #   with a bind-mounted volume in the user's cache dir.
      #   Its +#client(collection:)+ returns a +Backend::Chroma+
      #   pre-pointed at the supervised container. The split is
      #   deliberate: docker lifecycle and HTTP wire protocol
      #   have nothing in common, so each lives in its own class.
      #
      # == Chroma v2 API
      #
      # Endpoints used:
      #
      # * +POST /api/v2/tenants/{tenant}/databases/{db}/collections+
      #   with +get_or_create: true+ — idempotent collection
      #   creation. Returns +{id, name, ...}+.
      # * +POST /api/v2/.../collections/{id}/upsert+ — insert or
      #   replace by id. Body carries parallel arrays of +ids+,
      #   +embeddings+, +documents+, +metadatas+.
      # * +POST /api/v2/.../collections/{id}/query+ — k-NN
      #   search. Body: +{query_embeddings, n_results, include}+.
      # * +GET /api/v2/.../collections/{id}/count+ — integer
      #   count.
      # * +DELETE /api/v2/.../collections/{id}+ — drop the
      #   collection (used by +#delete_all+).
      # * +POST /api/v2/.../collections/{id}/delete+ — metadata-
      #   filtered delete (+{where:}+); used by +#delete_by_source+.
      # * +POST /api/v2/.../collections/{id}/get+ — fetch rows by
      #   +{where:}+ filter with an +include:+ projection; used by
      #   +#sources_with_hashes+.
      #
      # == BYO embeddings (not Chroma's embedder)
      #
      # Chroma collections can carry an embedding function in
      # their metadata — Chroma's term for what pikuri calls an
      # {Embedder}. When configured, +add+ / +query+ accept raw
      # text via +documents+ / +query_texts+ and Chroma embeds
      # server-side. We deliberately don't use this: pikuri's
      # +Embedder+ is the one source of truth for embedder
      # choice, the provider-cliff visibility lives in pikuri's
      # config, and a parallel Chroma-side embedder config would
      # split the truth without pikuri noticing (e.g. local
      # embedder in pikuri + +OpenAIEmbeddingFunction+ in Chroma
      # — every indexed document silently lands at OpenAI). We
      # always send pre-computed +embeddings+; Chroma's
      # collection embedder is never invoked.
      #
      # == Vector-dim contract diverges from InMemory
      #
      # +InMemory+ enforces vector-dim consistency client-side
      # (locks on first upsert, raises +ArgumentError+ on
      # mismatch). +Chroma+ enforces server-side — first upsert
      # to a collection establishes the dim; mismatched
      # subsequent upserts produce HTTP 4xx which propagates
      # as +RuntimeError+. Different exception class, same
      # loud-failure shape. Documented divergence; not worth
      # parsing Chroma's error envelope to coerce to +ArgumentError+.
      #
      # == Lazy collection resolution
      #
      # +Backend::Chroma.new+ doesn't talk to the server. The
      # first +#upsert+ / +#query+ / +#count+ call resolves
      # (and creates if missing) the collection by name, caches
      # the id, and uses it thereafter. +#delete_all+ drops the
      # collection and clears the cached id; the next +#upsert+
      # re-creates from scratch.
      #
      # == Cosine distance (matches InMemory)
      #
      # Collection is created with +hnsw.space: 'cosine'+.
      # Chroma returns cosine *distance* (range +[0, 2]+ where
      # +0+ = identical, +1+ = orthogonal); +#query+ converts
      # to similarity via +1 - distance+ so the {Backend::Result}
      # score has the same meaning across backends.
      #
      # == Metadata key normalization
      #
      # Chroma serializes through JSON, so Symbol metadata keys
      # become Strings on round-trip. +#upsert+ converts the
      # incoming {Chunk}'s +metadata+ keys to Strings before
      # sending; +#query+ converts them back to Symbols on the
      # way out, so the {Chunk} a caller pulls from a query
      # looks identical to one stored in InMemory. +source+
      # rides as a special metadata key (Chroma has no native
      # +source+ concept).
      #
      # == Testing posture
      #
      # Specs use +Faraday::Adapter::Test+ stubs only — they
      # verify "we send what we think we're sending" against
      # the v2 API shape but don't catch real-Chroma protocol
      # drift. Real-Chroma smoke testing is wired into the demo
      # binary in a later phase. Targets Chroma 0.5.x+ (v2 API).
      class Chroma
        # Rows per +/get+ page in {#sources_with_hashes}. Caps the
        # JSON burst + parse working set of the boot manifest read on
        # a large corpus; small corpora finish in one page. Chunky but
        # not arbitrary — one round trip per this-many *files*, and the
        # manifest is one row per file (the +offset 0+ chunk), so a
        # 50k-file corpus is ~50 localhost round trips instead of one
        # multi-MB response. See +ideas/vectordb-incremental-reindex.md+.
        MANIFEST_PAGE_SIZE = 1_000

        # @param host [String]
        # @param port [Integer]
        # @param collection [String] collection name in Chroma.
        #   This is a Chroma-specific identifier, so it lives
        #   here rather than on +VectorDb::Extension+ (where
        #   it'd be a no-op for +Backend::InMemory+).
        # @param tenant [String] Chroma v2 tenant; defaults to
        #   Chroma's own default.
        # @param database [String] Chroma v2 database; defaults
        #   to Chroma's own default.
        # @param connection [Faraday::Connection, nil] optional
        #   dependency-injection point for tests.
        # @return [Chroma]
        # @raise [ArgumentError] on empty +host+ or empty
        #   +collection+.
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

        # Insert-or-replace by +chunk.id+. Parallel arrays of
        # equal length; raises on empty input or length mismatch
        # (same contract as {InMemory}). Chroma server enforces
        # vector-dim consistency; mismatched dims surface as
        # +RuntimeError+ from a 4xx response (the InMemory
        # backend raises +ArgumentError+ for the same case —
        # documented divergence).
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

        # Drop the collection. Next +#upsert+ re-creates from
        # scratch — that's the v1 nuke-and-reload reindex path
        # the {Indexer} drives. No-op if no collection was ever
        # created (consistent with {InMemory}'s clear-on-empty
        # behaviour). 404 on the DELETE is treated as "already
        # gone" — idempotent.
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

        # Replace all chunks for one +source+: delete the old set,
        # then upsert the new one. The incremental-reindex unit
        # (see {Indexer#reindex_file!}).
        #
        # == Not transactional (the InMemory divergence)
        #
        # These are two HTTP calls, so a +#query+ landing between
        # them can see the source with zero chunks — a window
        # {InMemory#replace_source} closes with its monitor but
        # Chroma cannot, short of server-side transactions it
        # doesn't expose. The window is small and the
        # {Indexer} mitigates the *common* failure: it embeds
        # before calling here, so an embedder outage never reaches
        # this method and the old chunks stay put. Delete-then-upsert
        # (not the reverse): upserting first then deleting by source
        # would delete the just-written chunks.
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

        # The boot-sweep reference: +source+ → stored content hash
        # for every indexed document. Reads one metadata row per
        # *file*, not per chunk, via three Chroma +/get+ knobs:
        #
        # * +where: { offset: 0 }+ — every file has exactly one
        #   chunk at offset 0, so this returns one row per source.
        # * +include: ['metadatas']+ — drops the heavy +embeddings+
        #   and +documents+ from the response; we pull only the
        #   metadata projection, never the vectors.
        # * +limit+ / +offset+ — page the read in
        #   {MANIFEST_PAGE_SIZE} chunks so a large corpus never
        #   materializes one multi-MB response. (Two unrelated
        #   +offset+s collide in the wording: the +where+ +offset+ is
        #   a *chunk* metadata field; the top-level +offset+ is the
        #   *pagination* cursor — different namespaces in the API.)
        #
        # Pagination assumes the manifest isn't mutating mid-read; the
        # {Watcher} drives this from its single worker thread, so no
        # reindex runs concurrently with the boot sweep that calls it.
        #
        # @return [Hash{String => String, nil}] +source+ → content
        #   hash. Empty when the collection doesn't exist yet.
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
        # {VectorDb::Read}'s membership gate: a +where+-filtered
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
