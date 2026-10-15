# frozen_string_literal: true

require 'monitor'
require 'sqlite3'

module Pikuri
  module Rag
    module Backend
      # The keyword half of hybrid retrieval: {Pikuri::VectorDb::Chunk}s in an
      # SQLite FTS5 table, searched by word rather than by meaning.
      #
      #   keywords = Pikuri::Rag::Backend::Fts5.new           # RAM-only
      #   keywords.upsert(chunks: chunks)                     # no vectors — see below
      #
      #   keywords.keyword_query(match: '"acme" OR "pricing"', top_k: 50)
      #   # => [#<Result chunk=…>, …]      bm25, best first
      #   keywords.find(terms: ['"acme"', '"pricing"'])
      #   # => [["acme-2026-07-02.md", 1], ["acme-2026-08-14.md", 3]]
      #
      # Usable on its own — a corpus with no embedder at all can be indexed
      # into this and searched by keyword — but the tool set is built on
      # {Hybrid}, which pairs it with a vector store and fuses the two.
      #
      # == A backend, minus the vectors
      #
      # It answers the {Pikuri::VectorDb::Backend} protocol's write half and
      # both of its bookkeeping reads ({#count}, {#sources_with_hashes},
      # {#source_indexed?}), so {Hybrid} can fan a write out to it and to a
      # vector store with the same call. Two deliberate differences:
      #
      # * *The write calls take no +vectors:+.* Nothing here embeds, and an
      #   ignored parameter would only invite someone to pass one and expect it
      #   to matter.
      # * *There is no +#query(vector:)+.* Cosine over an FTS table is not a
      #   degraded search, it is a different question — which is exactly why
      #   this needs a vector store beside it rather than instead of it.
      #
      # == Stemming
      #
      # Words are stemmed in Ruby by a {Pikuri::Rag::Stemmer}, before FTS5
      # sees them: each chunk is indexed under its words' +#index_stems+, and
      # a {Pikuri::Rag::Query} built with the same stemmer searches their
      # +#stems+. {#stemmer} is that one stemmer, so the tools ask the backend
      # for it rather than being handed a second, possibly different one.
      #
      # An index records the stemmer's +#id+ and {SCHEMA_VERSION}. Opened with
      # any other, or built before either was recorded, it drops its table and
      # starts empty, which is the cue {Hybrid} needs to refill both stores
      # (its "Indexed means both stores hold it"): an index built by one
      # stemmer and queried by another would quietly find nothing.
      #
      # == Thread-safety
      #
      # Thread-safe. A +sqlite3+ connection is not safe for concurrent use, and
      # a {Pikuri::VectorDb::Watcher} thread writes while agent threads read, so
      # every statement runs under one reentrant +Monitor+ — the posture
      # {Pikuri::VectorDb::Backend::InMemory} takes, for the same reason.
      class Fts5
        LOGGER = Pikuri.logger_for('Rag::Backend::Fts5')

        # @return [String] +store:+ value for an index that lives only as long
        #   as the process.
        MEMORY_STORE = ':memory:'

        # @return [Integer] the table layout's version, recorded beside the
        #   stemmer id; bump it whenever {SCHEMA} changes, so an old index
        #   rebuilds instead of failing.
        SCHEMA_VERSION = 2

        # The table. +stems+, the chunk's words run through the stemmer, is the
        # only indexed column; the other four ride along as +UNINDEXED+
        # payload, so a hit rebuilds its {Pikuri::VectorDb::Chunk} without a
        # second lookup and a word in a filename never scores as a word in the
        # document.
        #
        # +porter+ still stems English after the Ruby stemmer, before
        # +unicode61+ folds case and strips diacritics, so "meetings" matches
        # "meeting" whichever stemmer is wired: a Finnish stemmer passes an
        # English word through unchanged.
        #
        # @return [String] the +CREATE VIRTUAL TABLE+ statement.
        SCHEMA = <<~SQL
          CREATE VIRTUAL TABLE chunks USING fts5(
            id UNINDEXED, source UNINDEXED, hash UNINDEXED, text UNINDEXED, stems,
            tokenize='porter unicode61'
          )
        SQL

        # @param store [String, Pathname] SQLite path, or {MEMORY_STORE} (the
        #   default). {Pikuri::Rag::Extension} says which to pair with which
        #   vector backend.
        # @param stemmer [#stems, #index_stems, #id] see {Pikuri::Rag::Stemmer}.
        # @return [Fts5]
        def initialize(store: MEMORY_STORE, stemmer: Pikuri::Rag::Stemmer::Identity)
          @store = store.to_s
          @stemmer = stemmer
          @lock = Monitor.new
          @db = SQLite3::Database.new(@store)
          open_table
        end

        # @return [String] the path this instance opened, or {MEMORY_STORE}.
        attr_reader :store

        # @return [#stems, #index_stems, #id] the stemmer this index is built
        #   with, which every query against it must use too.
        attr_reader :stemmer

        # Insert-or-replace by +chunk.id+.
        #
        # @param chunks [Array<Pikuri::VectorDb::Chunk>]
        # @return [void]
        def upsert(chunks:)
          @lock.synchronize do
            @db.transaction do
              chunks.each { |c| @db.execute('DELETE FROM chunks WHERE id = ?', [c.id]) }
              insert(chunks)
            end
          end
          nil
        end

        # Replace every chunk of one document, as one transaction — so a
        # concurrent read sees the old set or the new one, never the gap.
        #
        # @param source [String] the {Pikuri::VectorDb::Chunk#source} replaced.
        # @param chunks [Array<Pikuri::VectorDb::Chunk>] the new set.
        # @return [void]
        def replace_source(source:, chunks:)
          @lock.synchronize do
            @db.transaction do
              @db.execute('DELETE FROM chunks WHERE source = ?', [source])
              insert(chunks)
            end
          end
          nil
        end

        # Drop one document's chunks; no-op when absent.
        #
        # @param source [String]
        # @return [void]
        def delete_by_source(source)
          @lock.synchronize { @db.execute('DELETE FROM chunks WHERE source = ?', [source]) }
          nil
        end

        # @return [void] empties the table.
        def delete_all
          @lock.synchronize { @db.execute('DELETE FROM chunks') }
          nil
        end

        # @return [Integer] stored chunk count.
        def count
          @lock.synchronize { @db.get_first_value('SELECT count(*) FROM chunks').to_i }
        end

        # @return [Hash{String => String, nil}] +source+ → the content hash on
        #   its chunks, the change signal
        #   {Pikuri::VectorDb::Indexer#reconcile_plan} diffs against disk.
        def sources_with_hashes
          rows = @lock.synchronize do
            @db.execute('SELECT source, hash FROM chunks GROUP BY source')
          end
          rows.to_h
        end

        # @param source [String]
        # @return [Boolean] whether any chunk carries this +source+.
        def source_indexed?(source)
          @lock.synchronize do
            !@db.get_first_value('SELECT 1 FROM chunks WHERE source = ? LIMIT 1', [source]).nil?
          end
        end

        # Top-k hits ranked by +bm25()+ — term frequency and rarity, normalized
        # by document length.
        #
        # @param match [String] an FTS5 +MATCH+ expression from
        #   {Pikuri::Rag::Query}, never raw model text.
        # @param top_k [Integer] must be positive.
        # @return [Array<Pikuri::VectorDb::Backend::Result>] best first. +score+
        #   is the *negated* +bm25()+ value, so higher is better, as in every
        #   other backend read. It is on bm25's scale — an unbounded corpus
        #   statistic — and so is not comparable with a cosine score.
        # @raise [ArgumentError] on +top_k+ <= 0.
        # @raise [SQLite3::SQLException] if +match+ is not a valid expression,
        #   which is a caller bug: {Pikuri::Rag::Query} cannot emit one.
        def keyword_query(match:, top_k:)
          raise ArgumentError, "top_k must be positive (got #{top_k})" if top_k <= 0

          rows = @lock.synchronize do
            @db.execute(<<~SQL, [match, top_k])
              SELECT id, source, hash, text, bm25(chunks) FROM chunks
              WHERE chunks MATCH ? ORDER BY bm25(chunks) LIMIT ?
            SQL
          end
          rows.map do |id, source, hash, text, bm25|
            Pikuri::VectorDb::Backend::Result.new(chunk: to_chunk(id, source, hash, text), score: -bm25)
          end
        end

        # Every document holding *all* of +terms+ somewhere in it, with how
        # many of its chunks matched. No cutoff and no +top_k+ — the promise is
        # a set, and a limit would be the sample this exists to avoid.
        #
        #   fts5.find(terms: ['"acme"', '"pricing"'])
        #   # => [["acme-2026-07-02.md", 1], ["acme-2026-08-14.md", 3]]   # any order
        #
        # One query per term, intersected, *not* the single juxtaposed
        # +MATCH '"acme" "pricing"'+ that FTS5's implicit AND invites: that AND
        # is row-scoped and a row is a chunk, so the one-query form drops a
        # note whose two words sit in different chunks — under the default
        # 512-token chunker, any note past a couple of kilobytes.
        #
        # @param terms [Array<String>] one FTS5 expression per word, from
        #   {Pikuri::Rag::Query.terms}: a phrase, or an OR group of the word's
        #   stems.
        # @return [Array<Array(String, Integer)>] +[source, matched_chunks]+,
        #   unordered. The count is the document's chunks matching *at least
        #   one* term, each counted once, because the chunks matching every
        #   term are routinely none — that being the point above.
        # @raise [ArgumentError] on empty +terms+, which is the caller's cue to
        #   answer the model rather than run a query matching everything.
        # @raise [SQLite3::SQLException] on an invalid term, as
        #   {#keyword_query}.
        def find(terms:)
          raise ArgumentError, 'find called with no terms' if terms.empty?

          per_term = terms.map { |term| chunk_ids_by_source(term) }
          per_term.map(&:keys).reduce(:&).map do |source|
            [source, per_term.filter_map { |by_source| by_source[source] }.reduce(:|).size]
          end
        end

        # Close the connection; every other method raises afterwards.
        # Idempotent.
        #
        # Skipping it loses nothing: writes are eager and process exit closes
        # the fd.
        #
        # @return [void]
        def close
          @lock.synchronize do
            @db&.close
            @db = nil
          end
          nil
        end

        private

        # Create the table, or keep the one on disk when it was built with this
        # {SCHEMA_VERSION} and stemmer; otherwise drop it. +IMMEDIATE+ so a
        # second process opening the same file waits rather than racing the
        # drop.
        #
        # @return [void]
        def open_table
          @lock.synchronize do
            @db.transaction(:immediate) do
              built_with = table?('meta') ? @db.get_first_row('SELECT schema_version, stemmer FROM meta') : nil
              next if built_with == [SCHEMA_VERSION, @stemmer.id]

              if table?('chunks')
                was = built_with ? "schema #{built_with[0]}, stemmer #{built_with[1]}" : 'an unversioned schema'
                LOGGER.warn("Rebuilding the keyword index at #{@store}: built with #{was}, opened " \
                            "with schema #{SCHEMA_VERSION}, stemmer #{@stemmer.id}. It is empty " \
                            'until the next index run refills it.')
              end
              @db.execute('DROP TABLE IF EXISTS chunks')
              @db.execute('DROP TABLE IF EXISTS meta')
              @db.execute(SCHEMA)
              @db.execute('CREATE TABLE meta (schema_version INTEGER NOT NULL, stemmer TEXT NOT NULL)')
              @db.execute('INSERT INTO meta VALUES (?, ?)', [SCHEMA_VERSION, @stemmer.id])
            end
          end
        end

        # @param name [String]
        # @return [Boolean] whether the database holds a table of that name.
        def table?(name)
          !@db.get_first_value("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
                               [name]).nil?
        end

        # @param text [String] a chunk's text.
        # @return [String] its words' +#index_stems+, space-separated, one run
        #   per occurrence so bm25 still counts term frequency.
        def stems_of(text)
          Pikuri::Rag::Query.tokenize(text).flat_map { |word| @stemmer.index_stems(word) }.join(' ')
        end

        # @param term [String] one word's expression from {Pikuri::Rag::Query.terms}.
        # @return [Hash{String => Array<String>}] +source+ → matching chunk ids.
        def chunk_ids_by_source(term)
          rows = @lock.synchronize do
            @db.execute('SELECT source, id FROM chunks WHERE chunks MATCH ?', [term])
          end
          rows.each_with_object({}) { |(source, id), h| (h[source] ||= []) << id }
        end

        # @param chunks [Array<Pikuri::VectorDb::Chunk>]
        # @return [void]
        def insert(chunks)
          chunks.each do |c|
            @db.execute('INSERT INTO chunks (id, source, hash, text, stems) VALUES (?, ?, ?, ?, ?)',
                        [c.id, c.source, c.metadata[:hash], c.text, stems_of(c.text)])
          end
        end

        # +metadata+ carries only +hash+, not the +offset+ the indexer also
        # sets: nothing downstream of a keyword hit reads +offset+, so the
        # column would be dead weight in every row.
        #
        # @return [Pikuri::VectorDb::Chunk]
        def to_chunk(id, source, hash, text)
          Pikuri::VectorDb::Chunk.new(id: id, source: source, text: text, metadata: { hash: hash })
        end
      end
    end
  end
end
