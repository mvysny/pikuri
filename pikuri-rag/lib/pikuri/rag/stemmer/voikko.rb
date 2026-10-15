# frozen_string_literal: true

module Pikuri
  module Rag
    module Stemmer
      # Finnish stemming by dictionary form, over an open handle of the
      # +voikko+ gem (libvoikko + +voikko-fi+ from the distro):
      #
      #   stemmer = Pikuri::Rag::Stemmer::Voikko.new(::Voikko.new(language: 'fi'))
      #   stemmer.stems('kadulla')                    # => ["katu"]
      #   stemmer.stems('tulosta')                    # => ["tulostaa", "tulonen", "tulo", "tulos"]
      #   stemmer.stems('backend')                    # => ["backend"]   unknown, answers itself
      #   stemmer.index_stems('yrityskirjautumisen')  # => ["yrityskirjautua", "yritys", "kirjautua"]
      #
      # The handle is injected, so +pikuri-rag+ neither requires nor depends
      # on +voikko+: the host does, and owns the handle's {#close}. Part of
      # the stemmer duck; see {Stemmer} for the contract.
      #
      # An English word is unknown to Voikko and answers itself, which leaves
      # it to the +porter+ tokenizer as before, so a mixed corpus keeps its
      # English stemming.
      #
      # Thread-safe: it holds no state, and the +voikko+ gem locks each call
      # on the handle.
      class Voikko
        # @param voikko [#analyze, #language] an open +::Voikko+ handle; anything
        #   whose +#analyze(word)+ answers objects with +#base_form+ and
        #   +#morphemes+ will do.
        # @param compounds [Boolean] whether {#index_stems} adds each compound
        #   part's dictionary forms, which lets "kone" find "tietokone" at the
        #   cost of longer bm25 document lengths.
        def initialize(voikko, compounds: true)
          @voikko = voikko
          @compounds = compounds
        end

        # @return [String] +"voikko-fi+compounds"+, or +"voikko-fi"+ with
        #   +compounds: false+; the language is the handle's tag as opened.
        def id = "voikko-#{@voikko.language}#{'+compounds' if @compounds}"

        # Every reading's dictionary form, lower-cased.
        #
        # @param word [String] one {Query.tokenize} token.
        # @return [Array<String>] never empty; +[word]+ when Voikko does not
        #   know it.
        def stems(word)
          forms = @voikko.analyze(word).filter_map(&:base_form)
          forms.empty? ? [word.downcase] : forms.map(&:downcase).uniq
        end

        # {#stems}, plus each compound part's own {#stems}.
        #
        #   index_stems('versionhallintajärjestelmää')
        #   # => ["versionhallintajärjestelmä", "versio", "hallinta", "järjestelmä"]
        #
        # A part that is no word alone answers itself as written: the
        # +pediassa+ of +wikipediassa+, the +esi+ of a prefixed word.
        #
        # @param word [String] one {Query.tokenize} token.
        # @return [Array<String>] never empty.
        def index_stems(word)
          return stems(word) unless @compounds

          forms = @voikko.analyze(word).flat_map do |analysis|
            parts = analysis.morphemes || []
            part_stems = parts.size < 2 ? [] : parts.flat_map { |part| stems(part.text) }
            [analysis.base_form&.downcase, *part_stems]
          end.compact.uniq
          forms.empty? ? [word.downcase] : forms
        end
      end
    end
  end
end
