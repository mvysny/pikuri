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
  Attachment = Data.define(:mime, :filename, :bytes) do
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

    # ruby_llm's attachment over these bytes, for the wire.
    #
    # ruby_llm takes no MIME type; it re-detects one from the bytes and
    # {#filename}, so {#mime} does not cross.
    #
    # @return [RubyLLM::Attachment]
    def to_ruby_llm
      RubyLLM::Attachment.new(StringIO.new(bytes), filename: filename)
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
