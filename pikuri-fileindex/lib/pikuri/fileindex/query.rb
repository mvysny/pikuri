# frozen_string_literal: true

module Pikuri
  module Fileindex
    # What the model typed into +fileindex_search+, as groups of words. A
    # file matches when it holds every word of at least one group. A bare
    # word is a group of its own; double quotes make one group of their
    # words, in any order:
    #
    #   q = Query.parse('"notice period" tenant lessee')
    #   q.groups          # => [["notice", "period"], ["tenant"], ["lessee"]]
    #   q.all_of.groups   # => [["notice", "period", "tenant", "lessee"]]
    #
    # Any group matching is the point: a model lists alternatives (synonyms,
    # a second language) in one query, and an index that wants every word
    # found nothing for half its queries (measured 2026-11). Quotes are a
    # group, not a phrase: looser, so a model expecting a phrase still gets
    # every file a phrase would find.
    #
    # Dropped while parsing: a bare +OR+ or +AND+ (written out of web-search
    # habit, they would match nearly every file as words), a token with no
    # letter or digit, and parentheses, since only quotes group. A quote left
    # open runs to the end.
    #
    # Immutable.
    Query = Data.define(:groups) do
      # @param text [String] the model's query
      # @return [Query] with no groups when +text+ holds no word
      def self.parse(text)
        groups = text.to_s.split('"', -1).each_with_index.flat_map do |part, i|
          words = part.delete('()').split.reject { |word| word.match?(/\A(?:or|and)\z/i) || !word.match?(/[[:alnum:]]/) }
          i.odd? ? [words] : words.map { |word| [word] }
        end
        new(groups: groups.reject(&:empty?).uniq)
      end

      # @param groups [Array<Array<String>>] each group's words, none empty
      def initialize(groups:)
        super(groups: groups.map { |words| words.dup.freeze }.freeze)
      end

      # @return [Boolean] whether there is no word to search for
      def empty? = groups.empty?

      # @return [Query] one group holding every word: the files that match
      #   the whole query, not just some of it
      def all_of = Query.new(groups: [groups.flatten.uniq])
    end
  end
end
