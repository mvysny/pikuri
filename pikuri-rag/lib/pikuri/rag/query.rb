# frozen_string_literal: true

module Pikuri
  module Rag
    # Turns model-supplied text into safe FTS5 +MATCH+ input. Two shapes: a
    # list of terms to AND at the document level, and one OR expression to
    # rank by +bm25()+.
    #
    #   Query.terms('Acme pricing')        # => ['"acme"', '"pricing"']
    #   Query.any('what did we discuss?')  # => '"what" OR "did" OR "we" OR "discuss"'
    #   Query.terms('   ')                 # => []
    #
    # +MATCH+ is a mini-language — +AND+ / +OR+ / +NOT+, +*+ prefixes, +^+
    # anchors, +col:+ filters, phrase quotes, +()+ and +{}+ grouping — so a
    # stray quote or a leading +-+ in model text is an SQL *error*, not a
    # query that finds nothing. Every token comes out as a quoted phrase term,
    # which makes that syntax inert: +Query.any('acme OR initech')+ looks for
    # the literal word "or" alongside the two names. Not exposing the
    # operators is the point, so "Acme *or* Initech" is two searches.
    #
    # Nothing searchable comes back empty (or +nil+) rather than as an
    # expression that cannot match, so the caller answers the model instead of
    # asking SQLite a question with no terms in it.
    module Query
      # One quoted phrase term per word.
      #
      #   Query.terms('Acme pricing')   # => ['"acme"', '"pricing"']
      #
      # A list, not the juxtaposed +'"acme" "pricing"'+ FTS5 reads as an
      # implicit AND, because that AND is row-scoped and a row is a chunk —
      # so ANDing has to happen per document instead. {Fts5#find} does it, and
      # says what it costs.
      #
      # @param text [String] model-supplied terms, e.g. +"Acme pricing"+.
      # @return [Array<String>] one FTS5 phrase term per word; empty when
      #   +text+ holds no letters or digits.
      def self.terms(text)
        tokenize(text).map { |t| phrase(t) }
      end

      # The OR form: any token may match, and +bm25()+ does the ranking.
      #
      # OR is right for +rag_search+, whose input is a natural-language
      # question: a twelve-word sentence ANDed matches nothing, and bm25's
      # inverse-document-frequency term already discounts the "what did we
      # discuss" words that appear in every document.
      #
      # @param text [String] model-supplied query, e.g.
      #   +"what did we agree about pricing?"+.
      # @return [String, nil] an FTS5 +MATCH+ expression, or +nil+ when +text+
      #   holds no letters or digits.
      def self.any(text)
        tokens = tokenize(text)
        return nil if tokens.empty?

        tokens.map { |t| phrase(t) }.join(' OR ')
      end

      # Split +text+ into lower-cased runs of letters and digits.
      #
      #   Query.tokenize("Acme's Q3 pricing — v2.1")
      #   # => ["acme", "s", "q3", "pricing", "v2", "1"]
      #
      # Unicode-aware (+\p{L}+ / +\p{N}+), so accented and non-Latin words
      # survive; punctuation is a separator, never a term. Lower-casing is
      # belt-and-braces — +unicode61+ folds case on its own — but it keeps the
      # expression readable in a log line.
      #
      # NFC first, so a decomposed "ö" (+o+ and a combining diaeresis, as macOS
      # and some PDFs write it) is one letter and stays inside its word, and a
      # {Stemmer} sees the composed form: Voikko finds no reading of an NFD
      # word.
      #
      # @param text [String, nil]
      # @return [Array<String>] possibly empty.
      def self.tokenize(text)
        text.to_s.unicode_normalize(:nfc).scan(/[\p{L}\p{N}]+/).map(&:downcase)
      end

      # One token as an FTS5 phrase term, internal +"+ doubled.
      #
      # @param token [String]
      # @return [String] e.g. +'"acme"'+.
      def self.phrase(token)
        %("#{token.gsub('"', '""')}")
      end
      private_class_method :phrase
    end
  end
end
