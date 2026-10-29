# frozen_string_literal: true

module Pikuri
  class Agent
    # Separates +<think>…</think>+ reasoning that a server left inline in the
    # reply text from the answer, as +[content, thinking]+ pairs. Whole text:
    #
    #   ThinkTagSplitter.split("<think>\nhmm\n</think>\n\nHi!")  # => ["Hi!", "hmm"]
    #
    # Streamed text, one {#feed} per chunk; a tag cut across chunks is held
    # back until the next one completes it:
    #
    #   splitter = ThinkTagSplitter.new
    #   splitter.feed('<thi')               # => ["", ""]
    #   splitter.feed("nk>hmm</think>\nHi") # => ["Hi", "hmm"]
    #   splitter.flush                      # => ["", ""] — what the last chunk held back
    #
    # Servers that put reasoning in a separate field (llama.cpp's default
    # +reasoning_content+) never send a tag, so their text passes through
    # unchanged. Why pikuri splits rather than ruby_llm: +design/decisions.md+
    # +D_inline_think_tags+.
    #
    # An unclosed +<think>+ (the model ran out of tokens mid-thought) counts as
    # thinking to the end. Whitespace right after a tag is dropped: templates
    # write +</think>\n\n+, and a delta preview would otherwise open on blank lines.
    class ThinkTagSplitter
      # @return [String]
      OPEN = '<think>'
      # @return [String]
      CLOSE = '</think>'

      # Split a whole message.
      #
      # @param text [String]
      # @return [Array(String, String)] the answer and the reasoning, each
      #   stripped; either may be empty.
      def self.split(text)
        splitter = new
        content, thinking = splitter.feed(text)
        rest_content, rest_thinking = splitter.flush
        [(content + rest_content).strip, (thinking + rest_thinking).strip]
      end

      def initialize
        @inside = false
        @held = +''
        @after_tag = false
      end

      # Split the next streamed chunk.
      #
      # @param text [String] the chunk's content.
      # @return [Array(String, String)] the answer and reasoning text this chunk
      #   completes; either may be empty.
      def feed(text)
        rest = @held + text
        @held = +''
        content = +''
        thinking = +''
        until rest.empty?
          tag = @inside ? CLOSE : OPEN
          out = @inside ? thinking : content
          index = rest.index(tag)
          if index.nil?
            kept = partial_tag_length(rest, tag)
            emit(out, rest[0, rest.length - kept])
            @held = rest[(rest.length - kept)..]
            break
          end

          emit(out, rest[0, index])
          rest = rest[(index + tag.length)..]
          @inside = !@inside
          @after_tag = true
        end
        [content, thinking]
      end

      # Release what {#feed} held back as a possible partial tag. Call once the
      # stream ends.
      #
      # @return [Array(String, String)] the held-back text, on the side it was
      #   in.
      def flush
        held = @held
        @held = +''
        @inside ? ['', held] : [held, '']
      end

      private

      # Append +piece+ to +out+, dropping whitespace that directly follows a tag.
      #
      # @param out [String]
      # @param piece [String]
      # @return [void]
      def emit(out, piece)
        piece = piece.lstrip if @after_tag
        return if piece.empty?

        @after_tag = false
        out << piece
      end

      # @param text [String]
      # @param tag [String]
      # @return [Integer] the length of the longest end of +text+ that could
      #   still grow into +tag+.
      def partial_tag_length(text, tag)
        (tag.length - 1).downto(1).find { |n| text.end_with?(tag[0, n]) } || 0
      end
    end
  end
end
