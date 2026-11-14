# frozen_string_literal: true

require 'stringio'

module Pikuri
  # A file shown to the model beside text — the image +read+ answers, a
  # screenshot the user attaches — held as its bytes:
  #
  #   png = File.binread(path)
  #   Pikuri::Attachment.new(mime: Pikuri::FileType.detect_mime(png), filename: 'shot.png', bytes: png)
  #
  # It is the only attachment type pikuri's API carries ({Tool::Result#attachments},
  # {Agent::History::Message#attachments}); {#to_ruby_llm} builds ruby_llm's own
  # at the wire. Bytes rather than a path is the point: ruby_llm reads a path
  # String at construction, fetches a URL one, and may read a path again at send
  # time, so a file edited in between reaches the model unchecked. An
  # +Attachment+ is what the model saw, and compares by content.
  class Attachment < Data.define(:mime, :filename, :bytes)
    # @return [Integer] the largest image a tool or host attaches: Anthropic's
    #   per-image limit, the same order on OpenAI and Gemini. Refuse a bigger
    #   one with an error the model can react to, rather than send a payload
    #   the provider rejects.
    MAX_IMAGE_BYTES = 5 * 1024 * 1024

    # Rebuild one from ruby_llm's type — the way back from a live chat.
    #
    # @param attachment [RubyLLM::Attachment] path- or IO-backed; a URL-backed
    #   one is fetched, which pikuri never builds.
    # @return [Attachment]
    def self.from_ruby_llm(attachment)
      new(mime: attachment.mime_type, filename: attachment.filename.to_s, bytes: attachment.content)
    end

    # @param mime [String] e.g. +"image/png"+
    # @param filename [String] the name the model is shown
    # @param bytes [String] the file's contents; re-tagged binary, since the
    #   same image arrives as UTF-8 from a source file and as ASCII-8BIT from
    #   base64, and two differently-tagged copies of one PNG are not +==+.
    def initialize(mime:, filename:, bytes:)
      super(mime: mime, filename: filename, bytes: bytes.b.freeze)
    end

    # ruby_llm's attachment over these bytes, for the wire. {#mime} crosses as
    # stated, so ruby_llm detects nothing: the provider is told the type pikuri
    # checked, never one guessed from a sender-chosen {#filename}.
    #
    # @return [RubyLLM::Attachment]
    def to_ruby_llm
      RubyLLM::Attachment.new(StringIO.new(bytes), filename: filename, mime_type: mime)
    end

    # The line that stands in for this attachment when the model can't take
    # it ({Agent#modalities}), so the model learns why it sees nothing:
    #
    #   png.withheld_note('model m takes no vision input')
    #   # => "[shot.png not shown: model m takes no vision input]"
    #
    # @param reason [String]
    # @return [String]
    def withheld_note(reason)
      "[#{filename} not shown: #{reason}]"
    end
  end
end
