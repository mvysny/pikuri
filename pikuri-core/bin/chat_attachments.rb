# frozen_string_literal: true

require 'rainbow'

# `@path` attachments for pikuri-chat's prompt line, kept out of the script so it
# reads as agent setup plus the loop. A token attaches that image to the turn:
#
#   message, attachments = ChatAttachments.split("@~/shot.png what's wrong here?")
#   # => ["what's wrong here?", [#<data Pikuri::Attachment mime="image/png", filename="shot.png", ...>]]
#
# A path with spaces is quoted, `@'/tmp/my shot.png'` (what a terminal pastes for a
# dragged file), or backslash-escaped. A `@word` that names no file and doesn't look
# like a path (no `/`, no image extension) stays text, so `@alice` is still a mention.
#
# Images only, on purpose: few local models take audio (nor do big hosted ones like
# Claude Opus), so audio is a transcriber's job such as whisper's, and a PDF is text for
# the `read` tool, wherever a host registers a PDF extractor (`pikuri-os` does).
module ChatAttachments
  # Raised for an `@path` that can't be attached; the line is then not sent.
  class Error < StandardError; end

  TOKEN = /(?<=\A|\s)@(?:'([^']*)'|"([^"]*)"|((?:\\.|\S)+))[ \t]?/
  IMAGE_EXTENSION = /\.(png|jpe?g|gif|webp)\z/i
  # Same cap as the `read` tool's (Pikuri::Workspace::Read::MAX_IMAGE_BYTES).
  MAX_IMAGE_BYTES = 5 * 1024 * 1024

  # @param line [String] what the user typed
  # @return [Array(String, Array<Pikuri::Attachment>)] the line without its `@path`
  #   tokens, and the images they named
  # @raise [Error]
  def self.split(line)
    attachments = []
    text = line.gsub(TOKEN) do
      token = Regexp.last_match(0)
      raw = Regexp.last_match(1) || Regexp.last_match(2) || Regexp.last_match(3).gsub(/\\(.)/, '\1')
      path = File.expand_path(raw)
      if File.file?(path)
        attachments << image(path)
        ''
      elsif raw.include?('/') || raw.match?(IMAGE_EXTENSION)
        raise Error, "no such file: #{raw}"
      else
        token
      end
    end
    [text.strip, attachments]
  rescue ArgumentError => e # File.expand_path on `~nosuchuser`
    raise Error, e.message
  end

  # Print a dim `📎 shot.png (image/png, 48.3 kB)` line per attachment — the
  # Terminal listener never echoes typed input, so this is the only confirmation.
  #
  # @param attachments [Array<Pikuri::Attachment>]
  # @return [void]
  def self.announce(attachments)
    attachments.each do |a|
      puts Rainbow("📎 #{a.filename} (#{a.mime}, #{Pikuri::Tool.format_bytes(a.bytes.bytesize)})").color(85, 85, 85)
    end
  end

  # Reads the file once, so the model sees the bytes that were checked.
  #
  # @param path [String] an existing file
  # @return [Pikuri::Attachment]
  # @raise [Error]
  def self.image(path)
    bytes = File.binread(path, MAX_IMAGE_BYTES + 1)
    raise Error, "#{path} is over #{Pikuri::Tool.format_bytes(MAX_IMAGE_BYTES)}" if bytes.bytesize > MAX_IMAGE_BYTES

    mime = Pikuri::FileType.detect_mime(bytes)
    raise Error, "#{path} is not a PNG, JPEG, GIF or WebP image" unless mime&.start_with?('image/')

    Pikuri::Attachment.new(mime: mime, filename: File.basename(path), bytes: bytes)
  rescue SystemCallError => e
    raise Error, e.message
  end
  private_class_method :image
end
