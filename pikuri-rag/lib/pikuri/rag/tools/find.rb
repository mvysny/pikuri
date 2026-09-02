# frozen_string_literal: true

module Pikuri
  module Rag
    module Tools
      # The LLM-facing +rag_find+ tool — every document matching a term, as a
      # listing rather than a ranking:
      #
      #   3 documents contain all of: "acme" "pricing". Counts are how many of the document's chunks matched, not occurrences.
      #
      #   acme-2026-08-14.md — 3 chunks, 5.2 KB
      #   acme-2026-07-02.md — 1 chunk, 1.8 KB
      #   acme-2026-03-11.md — 1 chunk, 2.4 KB
      #
      # This is the tool for the question +rag_search+ structurally cannot
      # answer. Top-k is a sample and cosine has no calibrated zero, so no
      # cutoff can be *documented* as complete — where a boolean keyword match
      # can. "Every note mentioning Acme" gets an answer that is either the
      # whole set or an empty one, and a timeline assembled from it is not
      # quietly missing a note.
      #
      # Terms are **AND**ed *per document* and stemmed, so +"acme pricing"+
      # lists a note holding both words even when they land in different
      # chunks — see {Pikuri::Rag::Backend::Fts5#find}, which is where that
      # costs one query per term. The AND is the opposite of {Search}'s OR and
      # for the opposite reason: a set of "documents about Acme's pricing"
      # that includes every note saying "pricing" is not the set that was
      # asked for.
      #
      # Rows sort by match count descending, then +source+ ascending — so a
      # +name-date.md+ corpus (the convention +book/rag.md+ recommends) yields
      # a date-ordered tail within each count, and the agent can read the
      # timeline off the citations without opening a file.
      #
      # == Why a byte size and no line count
      #
      # The size answers one question — *is this short enough to read in
      # full?* — and bytes answer it for one +stat+ per row. A line count
      # would cost a whole-file read of every match, and worse, it would be
      # *wrong* for every format the {Pikuri::Extractor} registry converts: a
      # PDF's newlines are container bytes, not the text the model reads, so
      # the number would disagree with the one +rag_read+ pages by.
      #
      # Sharing: +P_shared_locked+ — {Pikuri::Rag::Backend::Fts5} locks, and
      # the corpus root is immutable.
      class Find < Pikuri::Tool
        # @return [String] static description shown to the LLM,
        #   opencode-shape (summary + +Usage:+ bullets).
        DESCRIPTION = <<~DESC
          List EVERY indexed document containing the given terms. No cutoff, no top-k — the complete set.

          Usage:
          - Use when the question is a set rather than a ranking: "every note about Acme", "which documents mention invoice 4471", "all my notes on the migration".
          - Pass one entity or a couple of terms, not a sentence: every term must appear somewhere in a document for it to be listed.
          - Terms are stemmed, so "meetings" also matches "meeting". Matching is by word, not substring.
          - Returns each document's `source` path, how many of its chunks matched, and its size in bytes — then read the ones you need in full with rag_read.
          - Reading every listed document in full only pays off when they are short. Over long documents, use rag_search to locate the relevant passages instead.
        DESC

        # @param backend [#find] a {Pikuri::Rag::Backend::Hybrid}.
        # @param root [Pathname] the corpus root —
        #   {Pikuri::VectorDb::Indexer#root}. Each listed +source+ is stat'd
        #   relative to it.
        # @param legs [Pikuri::Tool::TrifectaLegs] the corpus's declaration,
        #   as {Search} takes it and for the same reason.
        # @return [Find]
        def initialize(backend:, root:, legs:)
          super(
            name: 'rag_find',
            description: DESCRIPTION,
            parameters: Pikuri::Tool::Parameters.build { |p|
              p.required_string :terms,
                                'One entity or a few words that must all appear in a ' \
                                'document, e.g. "Acme" or "invoice 4471". Not a ' \
                                'question — every term has to match.'
            },
            execute: lambda { |terms:|
              Find.execute(backend: backend, root: root, terms: terms)
            },
            # As {Search}: a listing of corpus paths and sizes, nothing outbound.
            trifecta_legs: legs
          )
        end

        # Run the listing and format the observation. Public so specs can
        # exercise it without constructing a Tool wrapper.
        #
        # @param backend [#find]
        # @param root [Pathname]
        # @param terms [String] as supplied by the LLM.
        # @return [String] the listing, a no-matches line, or +"Error: ..."+.
        def self.execute(backend:, root:, terms:)
          phrases = Pikuri::Rag::Query.terms(terms)
          if phrases.empty?
            return "Error: no searchable terms in #{terms.to_s.strip.inspect} — " \
                   'pass a word, a name or an id.'
          end

          listed = phrases.join(' ')
          rows = backend.find(terms: phrases).sort_by { |source, count| [-count, source] }
          return "No indexed document contains all of: #{listed}." if rows.empty?

          subject = rows.length == 1 ? '1 document contains' : "#{rows.length} documents contain"
          header = "#{subject} all of: #{listed}. " \
                   "Counts are how many of the document's chunks matched, not occurrences.\n\n"
          header + rows.map { |source, count| row(root, source, count) }.join("\n")
        end

        # One listing row: citation, match count, and the file's current size.
        #
        # A document indexed but since deleted says so rather than being
        # dropped — the index is stale and the model should hear it, the same
        # answer +rag_read+ gives for the same file.
        #
        # @param root [Pathname]
        # @param source [String]
        # @param count [Integer] matching chunks.
        # @return [String]
        def self.row(root, source, count)
          chunks = "#{count} chunk#{'s' unless count == 1}"
          path = root.join(source).expand_path
          base = root.expand_path.to_s
          unless path.to_s == base || path.to_s.start_with?(base + File::SEPARATOR)
            # Unreachable through the shipped Indexer, whose sources are all
            # relative_path_from(root); kept because this tool opens the path.
            return "#{source} — #{chunks} (resolves outside the corpus root)"
          end

          "#{source} — #{chunks}, #{bytes(File.size(path))}"
        rescue SystemCallError => e
          "#{source} — #{chunks} (cannot stat: #{e.class.name.split('::').last})"
        end
        private_class_method :row

        # @param size [Integer] bytes.
        # @return [String] e.g. +"812 B"+, +"5.2 KB"+, +"1.4 MB"+.
        def self.bytes(size)
          return "#{size} B" if size < 1024
          return format('%.1f KB', size / 1024.0) if size < 1024 * 1024

          format('%.1f MB', size / (1024.0 * 1024))
        end
        private_class_method :bytes
      end
    end
  end
end
