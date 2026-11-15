# frozen_string_literal: true

module Pikuri
  module Thunderbird
    # The +thunderbird_mail_read+ tool — the read half of the mail
    # search→read pair. Given a +message_id+ from +thunderbird_mail_search+,
    # returns the full decoded body (Gloda has already MIME-decoded and
    # HTML-stripped it, so no markup noise) plus headers and a numbered
    # attachment listing:
    #
    #   Attachments:
    #     1. invoice.pdf (application/pdf, 1.4 MB)
    #     2. notes.txt (text/plain)
    #
    # The number is what +thunderbird_mail_attachment_read+ takes. Inbound-only.
    #
    # Sharing: +P_shared_locked+ — no state of its own, and the {Gloda}
    # backend it queries locks; see that class's +== Sharing+.
    class MailRead < Pikuri::Tool
      # @return [Integer] hard cap on the body bytes returned. Gloda keeps at
      #   most {GLODA_PART_CAP} of each body part, but the parts of a message
      #   carrying forwards add up.
      MAX_BODY = 40 * 1024

      # @return [Integer] how much of one body part Gloda keeps: it indexes
      #   with +saneBodySize+, Thunderbird's +MAX_SANE_BODY_PART_SIZE+
      #   (+MimeMessageEmitter.sys.mjs+). A plain-text body this long was cut
      #   there; an HTML one is cut *before* its markup is stripped, so its
      #   shorter text slips under this test unflagged.
      GLODA_PART_CAP = 20 * 1024

      # @return [String] ends a body that reached {GLODA_PART_CAP}.
      CUT_NOTE = "[The message may continue past this point: Thunderbird's search index keeps only about " \
                 'the first 20 KB of its text. Ask the user to open it in Thunderbird for the rest.]'

      # @return [String] stands in for the body and the attachment list of a
      #   message Thunderbird keeps only the headers of (an IMAP account or
      #   folder not kept offline, or a message past its size or age limit);
      #   see {Gloda::Mail#read}'s +downloaded+. It names the settings as
      #   Thunderbird 159 labels them (+am-offline.dtd+), so the model can tell
      #   the user what to change.
      NOT_DOWNLOADED_NOTE = "[Thunderbird has downloaded only this message's headers, so its text and " \
                            "attachments can't be read here. Ask the user to turn on \"Keep messages in all " \
                            'folders for this account on this computer" in the account\'s "Synchronization & ' \
                            'Storage" settings (or select this folder under "Advanced…" there), and to lift any ' \
                            'size or age limit set there that excludes this message; once Thunderbird has ' \
                            'downloaded it, read it again.]'

      # @return [String] follows the listing when it holds a forwarded email.
      FORWARD_NOTE = "  (A forwarded email's text may also appear in the body below; read the attachment " \
                     'for its sender, date and attachments.)'

      # @return [String] opencode-shape description.
      DESCRIPTION = <<~DESC
        Read one local Thunderbird message in full (headers, decoded plain-text body, numbered attachment list).

        Usage:
        - Pass the id from a thunderbird_mail_search result.
        - Attachment contents are not included; read one by its number with thunderbird_mail_attachment_read.
      DESC

      # @param backend [Gloda::Mail] the mail backend.
      # @return [MailRead]
      def initialize(backend:)
        @backend = backend
        super(
          name: 'thunderbird_mail_read',
          description: DESCRIPTION,
          parameters: Parameters.build { |p|
            p.required_string :message_id,
                              'The id from a search result, e.g. "<CAF..@mail.example.com>".'
          },
          execute: lambda { |message_id:|
            MailRead.run_read(backend: @backend, message_id:)
          },
          trifecta_legs: Pikuri::Thunderbird::INBOUND_LEGS
        )
      end

      # @return [Pikuri::Tool::Result] the formatted message (+"Read 4.2 kB"+ —
      #   a size, because the subject is whatever the sender wrote), or
      #   {Pikuri::Tool::Result.error}.
      def self.run_read(backend:, message_id:)
        rec = backend.read(message_id:)
        return Pikuri::Tool::Result.error("no message found with id #{message_id.inspect}.") unless rec

        attachments = rec[:attachments]
        if !rec[:downloaded]
          listing = ' unknown'
        elsif attachments.empty?
          listing = ' (none)'
        else
          listing = "\n#{attachment_listing(attachments)}"
          # Gloda appends a forward's text to the outer body with no separator.
          listing += "\n#{FORWARD_NOTE}" if attachments.any? { _1.content_type == 'message/rfc822' }
        end
        message = <<~MSG.chomp
          Subject: #{rec[:subject]}
          From: #{rec[:from]}
          To: #{rec[:to]}
          Date: #{DateHelpers.short_datetime(rec[:date])}
          Folder: #{rec[:folder]}
          Attachments:#{listing}

          #{rec[:downloaded] ? body(rec[:body]) : NOT_DOWNLOADED_NOTE}
        MSG
        Pikuri::Tool::Result.new(content: message,
                                 summary: "Read #{Pikuri::Tool.format_bytes(message.bytesize)}")
      end

      # The numbered listing, also quoted back by +thunderbird_mail_attachment_read+
      # for a wrong index. Gloda's size is shown only when known (+-1+ for some
      # inline images), and never for a forwarded mail, where it is noise.
      #
      #   attachment_listing(rec[:attachments])
      #   # =>   1. invoice.pdf (application/pdf, 1.4 MB)
      #   #      2. Fwd.eml (forwarded email)
      #
      # @param attachments [Array<Gloda::Attachment>]
      # @return [String] one indented line per attachment, numbered from 1.
      def self.attachment_listing(attachments)
        attachments.each_with_index.map do |a, i|
          # The name is sender-authored; a newline in it would forge a line.
          details = if a.content_type == 'message/rfc822'
                      'forwarded email'
                    else
                      [a.content_type, (Pikuri::Tool.format_bytes(a.size) if a.size.positive?),
                       ('online link, not stored' if a.external)].compact.join(', ')
                    end
          "  #{i + 1}. #{a.name.gsub(/[[:cntrl:]]/, ' ')} (#{details})"
        end.join("\n")
      end

      # A byte cut can split a multi-byte character, and an invalid UTF-8
      # string fails the JSON encoding of the whole request, so the torn
      # tail is scrubbed away.
      #
      # @return [String] the body, truncated with a marker if over {MAX_BODY},
      #   and ending in {CUT_NOTE} if Gloda may have cut it.
      def self.body(text)
        text = text.to_s
        note = text.bytesize >= GLODA_PART_CAP ? "\n\n#{CUT_NOTE}" : ''
        return "#{text}#{note}" if text.bytesize <= MAX_BODY

        "#{text.byteslice(0, MAX_BODY).scrub('')}\n\n… [truncated; message longer than #{MAX_BODY / 1024} KB] …#{note}"
      end
      private_class_method :body
    end
  end
end
