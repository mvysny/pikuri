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
    #   thunderbird_mail_attachment_read(message_id: "<a@x>", attachment: "1")
    #   #        1	--- Page 1 ---
    #   #        2	Invoice no. 4711 …
    #
    # A forwarded mail (+message/rfc822+) reads as its headers, numbered
    # attachment list and text ({ForwardedMail}), and the handle takes a path
    # into it: +"2.1"+ is forward 2's first attachment, +"2.1.1"+ one level
    # further when that is a forward too.
    #
    # Both tools number Gloda's +attachmentInfos+ list ({Gloda::Attachment}), so
    # the first number means the same thing in each; past it, {ForwardedMail}
    # numbers the list it shows. The bytes come from the offline
    # mbox ({MessageStore}); the +mail+ gem walks to the attachment's MIME part
    # number and undoes its transfer encoding; the {Pikuri::Extractor} registry
    # turns it into text, so which formats read depends on what the host
    # registered (pikuri-pdf, pikuri-workshop's office extractors; an HTML attachment renders
    # as Markdown only when the host requires pikuri-html, and is raw markup otherwise).
    #
    # A PNG, JPEG, GIF or WebP comes back as the picture itself, for a
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
        - A forwarded email comes back as its headers, numbered attachment list and text; read one of its attachments by the number listed there, e.g. "2.1".
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
            p.required_string :attachment,
                              'The attachment number as listed, a string: "2" from thunderbird_mail_read, ' \
                              'or "2.1" from a forwarded email\'s own list.'
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
      # @param attachment [String] the handle: +"3"+, or +"3.1"+ inside
      #   forward 3. A trailing dot, as the listing prints it, is forgiven.
      # @param offset [Integer] 1-indexed start line.
      # @param limit [Integer] max lines.
      # @return [Pikuri::Tool::Result] the paged text (+"Read 120 PDF lines"+),
      #   or {Pikuri::Tool::Result.error}.
      def self.run_read(backend:, store:, message_id:, attachment:, offset:, limit:)
        return Pikuri::Tool::Result.error("offset must be >= 1, got #{offset}") if offset < 1
        return Pikuri::Tool::Result.error("limit must be >= 1, got #{limit}") if limit < 1

        handle = attachment.strip.delete_suffix('.')
        unless handle.match?(/\A[1-9]\d*(?:\.[1-9]\d*)*\z/)
          return Pikuri::Tool::Result.error("attachment must be a number as listed, e.g. \"2\" or \"2.1\"; " \
                                            "got #{attachment.inspect}.")
        end
        first, *inner = handle.split('.').map(&:to_i)

        rec = backend.read(message_id:)
        return Pikuri::Tool::Result.error("no message found with id #{message_id.inspect}.") unless rec

        return Pikuri::Tool::Result.error(MailRead::NOT_DOWNLOADED_NOTE) unless rec[:downloaded]

        list = rec[:attachments]
        return Pikuri::Tool::Result.error('this message has no attachments.') if list.empty?

        att = list[first - 1] if first.between?(1, list.size)
        unless att
          return Pikuri::Tool::Result.error("no attachment #{first}; this message has:\n" \
                                            "#{MailRead.attachment_listing(list)}")
        end
        refusal = att.external ? 'is a link to an online file, not stored in the message.' : refusal(att.content_type)
        return Pikuri::Tool::Result.error("attachment #{first} #{refusal}") if refusal

        # Gloda's type first: it beats the part's own header.
        found = descend(first.to_s, att.name, att.content_type, attachment_bytes(store, rec, att), inner)
        # By the bytes, not the type, which was guessed from a sender-chosen file name.
        mime = Pikuri::FileType.detect_mime(found.bytes)
        return image_result(found, mime) if mime&.start_with?('image/')

        bytes, type = found.bytes, found.content_type
        bytes, type = ForwardedMail.render(bytes, handle: found.handle), 'text/plain' if type == 'message/rfc822'
        page = extract(bytes, type, offset:, limit:)
        Pikuri::Tool::Result.page(page, name: 'attachment')
      rescue Unreadable, MessageStore::Error => e
        Pikuri::Tool::Result.error(e.message)
      rescue Pikuri::Extractor::Unsupported
        Pikuri::Tool::Result.error("no reader for #{found.content_type} attachments on this host.")
      rescue Pikuri::Extractor::Error => e
        Pikuri::Tool::Result.error(e.message)
      rescue DatabaseSnapshot::TornError => e
        Pikuri::Tool::Result.error(e.message)
      end

      # The attachment a handle names, once found.
      Found = Data.define(:handle, :name, :content_type, :bytes)

      # Walks a handle's numbers after the first into nested forwards, each
      # numbered as {ForwardedMail.listing} shows it.
      #
      # @param handle [String] the handle so far, e.g. +"3"+.
      # @param name [String]
      # @param content_type [String]
      # @param bytes [String] the decoded attachment +handle+ names.
      # @param rest [Array<Integer>] the numbers still to walk.
      # @return [Found]
      # @raise [Unreadable] on a number past a list, a number into something
      #   that is not a forward, or an unreadable part on the way.
      def self.descend(handle, name, content_type, bytes, rest)
        return Found.new(handle:, name:, content_type:, bytes:) if rest.empty?

        number, *rest = rest
        unless content_type == 'message/rfc822'
          raise Unreadable, "attachment #{handle} is not a forwarded email, so it has no attachment #{handle}.#{number}."
        end

        list = ForwardedMail.attachments(bytes)
        raise Unreadable, "attachment #{handle} is a forwarded email with no attachments." if list.empty?

        att = list[number - 1] if number.between?(1, list.size)
        unless att
          raise Unreadable, "no attachment #{handle}.#{number}; attachment #{handle} has:\n" \
                            "#{ForwardedMail.listing(list, handle)}"
        end
        inner = "#{handle}.#{number}"
        refusal = refusal(att.content_type)
        raise Unreadable, "attachment #{inner} #{refusal}" if refusal

        descend(inner, att.name, att.content_type, readable!(att.part).decoded, rest)
      end
      private_class_method :descend

      # Gloda's type first, so an office extractor can claim its format by
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

      # @param content_type [String]
      # @return [String, nil] why it can't be read (completing "attachment N …"),
      #   or +nil+.
      def self.refusal(content_type)
        'is encrypted, so there is no text to read.' if ENCRYPTED_TYPES.include?(content_type)
      end
      private_class_method :refusal

      # The picture as an attachment beside a note; +offset+ and +limit+ don't
      # apply. The note reads:
      #
      #   Read image: cottage.png (398 B, image/png)
      #
      # @param found [Found] the decoded image.
      # @param mime [String] sniffed from its bytes, e.g. +"image/png"+.
      # @return [Pikuri::Tool::Result] the image, or an error over
      #   {Pikuri::Attachment::MAX_IMAGE_BYTES}.
      def self.image_result(found, mime)
        bytes = found.bytes
        size = Pikuri::Tool.format_bytes(bytes.bytesize)
        cap = Pikuri::Attachment::MAX_IMAGE_BYTES
        if bytes.bytesize > cap
          return Pikuri::Tool::Result.error("attachment #{found.handle} is an image of #{size}, over the " \
                                            "#{Pikuri::Tool.format_bytes(cap)} that can be shown.")
        end

        name = found.name.gsub(/[[:cntrl:]]/, ' ')
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
        readable!(part).decoded
      end
      private_class_method :attachment_bytes

      # @param part [Mail::Part]
      # @return [Mail::Part] +part+, unless Thunderbird left only a placeholder.
      # @raise [Unreadable] for a detached or deleted attachment.
      def self.readable!(part)
        if part.mime_type == 'text/x-moz-deleted' || part.header['X-Mozilla-External-Attachment-URL']
          raise Unreadable, 'this attachment was detached or deleted in Thunderbird; only a placeholder is ' \
                            'left in the message.'
        end

        part
      end
      private_class_method :readable!
    end
  end
end
