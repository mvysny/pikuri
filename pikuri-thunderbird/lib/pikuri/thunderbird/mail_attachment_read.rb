# frozen_string_literal: true

require 'mail'
require 'stringio'

module Pikuri
  module Thunderbird
    # The +thunderbird_mail_attachment_read+ tool — the text of one attachment,
    # line-paged like +read+. The model picks it by the number
    # +thunderbird_mail_read+ listed it under:
    #
    #   thunderbird_mail_read(message_id: "<a@x>")
    #   #   Attachments:
    #   #     1. invoice.pdf (application/pdf, 1.4 MB)
    #   thunderbird_mail_attachment_read(message_id: "<a@x>", attachment: 1)
    #   #        1	--- Page 1 ---
    #   #        2	Invoice no. 4711 …
    #
    # Both tools number Gloda's +attachmentInfos+ list ({Gloda::Attachment}), so
    # the index means the same thing in each. The bytes come from the offline
    # mbox ({MessageStore}); the +mail+ gem walks to the attachment's MIME part
    # number and undoes its transfer encoding; the {Pikuri::Extractor} registry
    # turns it into text, so which formats read depends on what the host
    # registered (pikuri-pdf, pikuri-extractors; an HTML attachment renders
    # only when pikuri-web is loaded, and is raw markup otherwise).
    #
    # A forwarded mail (+message/rfc822+) reads as its headers, attachment
    # list and text ({ForwardedMail}); its own attachments can't be opened
    # yet. A PNG, JPEG, GIF or WebP comes back as the picture itself, for a
    # vision model to see (a text-only one gets a note instead; see
    # {Pikuri::Tool#to_ruby_llm_tool}). Refused up front: encrypted parts,
    # links to online files, and detached stubs. Inbound-only, with the
    # same legs as +thunderbird_mail_read+: an attachment is untrusted the same
    # way a body is.
    #
    # Sharing: +P_shared_locked+ — the {Gloda} backend locks; {MessageStore} is
    # stateless.
    class MailAttachmentRead < Pikuri::Tool
      # @return [Integer] default +limit+, the shared page default.
      DEFAULT_LIMIT = Pikuri::Extractor::PAGE_DEFAULT_LIMIT

      # @return [Array<String>] content types refused as encrypted: there is no
      #   text to show without key material, which pikuri never touches.
      ENCRYPTED_TYPES = %w[application/pkcs7-mime application/x-pkcs7-mime
                           application/pgp-encrypted multipart/encrypted].freeze

      # Raised inside {.run_read} when the attachment has no bytes to read; the
      # message becomes the +Error:+ observation.
      Unreadable = Class.new(StandardError)

      # @return [String] opencode-shape description.
      DESCRIPTION = <<~DESC
        Read the text of one attachment of a local Thunderbird message, with line numbers.

        Usage:
        - Pass the message id and the attachment's number, both as thunderbird_mail_read listed them.
        - PDFs and other documents come back as extracted text; PDFs carry `--- Page N ---` markers you can cite.
        - Use `offset` and `limit` to page; when the response ends in `Use offset=N to continue`, call again with that offset.
        - A forwarded email comes back as its headers, attachment list and text.
        - A PNG, JPEG, GIF or WebP image comes back as the picture itself, which needs a vision-capable model to see.
        - Encrypted attachments can't be read here.
      DESC

      # @param backend [Gloda::Mail] the attachment list and folder copies.
      # @param store [MessageStore] the raw message bytes.
      # @return [MailAttachmentRead]
      def initialize(backend:, store:)
        super(
          name: 'thunderbird_mail_attachment_read',
          description: DESCRIPTION,
          parameters: Parameters.build { |p|
            p.required_string :message_id,
                              'The message id from thunderbird_mail_search, e.g. "<CAF..@mail.example.com>".'
            p.required_integer :attachment,
                               'The attachment number as thunderbird_mail_read listed it (1-based), e.g. 1.'
            p.optional_integer :offset, 'Line number to start reading from (1-indexed). Defaults to 1, e.g. 200.'
            p.optional_integer :limit, "Maximum number of lines to read. Defaults to #{DEFAULT_LIMIT}, e.g. 500."
          },
          execute: lambda { |message_id:, attachment:, offset: 1, limit: DEFAULT_LIMIT|
            MailAttachmentRead.run_read(backend:, store:, message_id:, attachment:, offset:, limit:)
          },
          trifecta_legs: Pikuri::Thunderbird::INBOUND_LEGS
        )
      end

      # @param backend [Gloda::Mail]
      # @param store [MessageStore]
      # @param message_id [String] the search handle.
      # @param attachment [Integer] 1-based index into the message's attachments.
      # @param offset [Integer] 1-indexed start line.
      # @param limit [Integer] max lines.
      # @return [Pikuri::Tool::Result] the paged text (+"Read 120 PDF lines"+),
      #   or {Pikuri::Tool::Result.error}.
      def self.run_read(backend:, store:, message_id:, attachment:, offset:, limit:)
        return Pikuri::Tool::Result.error("offset must be >= 1, got #{offset}") if offset < 1
        return Pikuri::Tool::Result.error("limit must be >= 1, got #{limit}") if limit < 1

        rec = backend.read(message_id:)
        return Pikuri::Tool::Result.error("no message found with id #{message_id.inspect}.") unless rec

        list = rec[:attachments]
        return Pikuri::Tool::Result.error('this message has no attachments.') if list.empty?

        att = list[attachment - 1] if attachment.between?(1, list.size)
        unless att
          return Pikuri::Tool::Result.error("no attachment #{attachment}; this message has:\n" \
                                            "#{MailRead.attachment_listing(list)}")
        end
        refusal = refusal(att)
        return Pikuri::Tool::Result.error("attachment #{attachment} #{refusal}") if refusal

        bytes = attachment_bytes(store, rec, att)
        # By the bytes, not Gloda's type, which it guessed from a sender-chosen file name.
        mime = Pikuri::FileType.detect_mime(bytes)
        return image_result(attachment, att, bytes, mime) if mime&.start_with?('image/')

        type = att.content_type
        bytes, type = ForwardedMail.render(bytes), 'text/plain' if type == 'message/rfc822'
        page = extract(bytes, type, offset:, limit:)
        Pikuri::Tool::Result.page(page, name: 'attachment')
      rescue Unreadable, MessageStore::Error => e
        Pikuri::Tool::Result.error(e.message)
      rescue Pikuri::Extractor::Unsupported
        Pikuri::Tool::Result.error("no reader for #{att.content_type} attachments on this host.")
      rescue Pikuri::Extractor::Error => e
        Pikuri::Tool::Result.error(e.message)
      end

      # Gloda's type first, so pikuri-extractors can claim an office format by
      # it. On a refusal, sniff the way a local file is: the registry's
      # plain-text arm claims only +text/*+ under a content type, yet calendar
      # invites (+application/ics+), JSON and XML are text too.
      #
      # @param bytes [String] the decoded attachment.
      # @param content_type [String] Gloda's content type.
      # @param offset [Integer]
      # @param limit [Integer]
      # @return [Pikuri::Extractor::Page]
      # @raise [Pikuri::Extractor::Unsupported] when the sniff refuses it too.
      # @raise [Pikuri::Extractor::Error] when the claiming extractor fails.
      def self.extract(bytes, content_type, offset:, limit:)
        Pikuri::Extractor.extract_paged(StringIO.new(bytes), content_type:, offset:, limit:)
      rescue Pikuri::Extractor::Unsupported
        Pikuri::Extractor.extract_paged(StringIO.new(bytes), content_type: nil, offset:, limit:)
      end
      private_class_method :extract

      # @param att [Gloda::Attachment]
      # @return [String, nil] why it can't be read (completing "attachment N …"),
      #   or +nil+.
      def self.refusal(att)
        type = att.content_type
        if att.external then 'is a link to an online file, not stored in the message.'
        elsif ENCRYPTED_TYPES.include?(type) then "is encrypted, so there is no text to read."
        end
      end
      private_class_method :refusal

      # The picture as an attachment beside a note; +offset+ and +limit+ don't
      # apply. The note reads:
      #
      #   Read image: cottage.png (398 B, image/png)
      #
      # @param number [Integer] the attachment's number, for the refusal.
      # @param att [Gloda::Attachment]
      # @param bytes [String] the decoded image.
      # @param mime [String] sniffed from +bytes+, e.g. +"image/png"+.
      # @return [Pikuri::Tool::Result] the image, or an error over
      #   {Pikuri::Attachment::MAX_IMAGE_BYTES}.
      def self.image_result(number, att, bytes, mime)
        size = Pikuri::Tool.format_bytes(bytes.bytesize)
        cap = Pikuri::Attachment::MAX_IMAGE_BYTES
        if bytes.bytesize > cap
          return Pikuri::Tool::Result.error("attachment #{number} is an image of #{size}, over the " \
                                            "#{Pikuri::Tool.format_bytes(cap)} that can be shown.")
        end

        name = att.name.gsub(/[[:cntrl:]]/, ' ')
        Pikuri::Tool::Result.new(content: "Read image: #{name} (#{size}, #{mime})",
                                 attachments: [Pikuri::Attachment.new(mime:, filename: name, bytes:)],
                                 summary: "Read image, #{size}")
      end
      private_class_method :image_result

      # @param store [MessageStore]
      # @param rec [Hash] the {Gloda::Mail#read} record.
      # @param att [Gloda::Attachment]
      # @return [String] the decoded bytes (UTF-8 for a text part, binary
      #   otherwise).
      # @raise [Unreadable] when there are none to read.
      # @raise [MessageStore::Error] when the store can't be read.
      def self.attachment_bytes(store, rec, att)
        if rec[:message_id].start_with?('gloda:')
          raise Unreadable, "this message has no Message-ID header, so its stored copy can't be found; " \
                            'open it in Thunderbird.'
        end

        raw = store.raw_message(message_id: rec[:message_id], folder_uris: rec[:folder_uris]) or
          raise Unreadable, "this message isn't stored on this computer (Thunderbird keeps only some mail " \
                            'offline); open it in Thunderbird.'
        part = att.part.split('.').drop(1).reduce(::Mail.read_from_string(raw)) do |node, i|
          node.parts[i.to_i - 1] or
            raise Unreadable, "the stored copy of this message doesn't match Thunderbird's index; " \
                              'open it in Thunderbird.'
        end
        if part.mime_type == 'text/x-moz-deleted' || part.header['X-Mozilla-External-Attachment-URL']
          raise Unreadable, 'this attachment was detached or deleted in Thunderbird; only a placeholder is ' \
                            'left in the message.'
        end

        part.decoded
      end
      private_class_method :attachment_bytes
    end
  end
end
