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
      # @return [Integer] hard cap on the body bytes returned (a runaway
      #   50k-char body would swamp the context).
      MAX_BODY = 40 * 1024

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
        message = <<~MSG.chomp
          Subject: #{rec[:subject]}
          From: #{rec[:from]}
          To: #{rec[:to]}
          Date: #{DateHelpers.short_datetime(rec[:date])}
          Folder: #{rec[:folder]}
          Attachments:#{attachments.empty? ? ' (none)' : "\n#{attachment_listing(attachments)}"}

          #{body(rec[:body])}
        MSG
        Pikuri::Tool::Result.new(content: message,
                                 summary: "Read #{Pikuri::Tool.format_bytes(message.bytesize)}")
      end

      # The numbered listing, also quoted back by +thunderbird_mail_attachment_read+
      # for a wrong index. Gloda's size is shown only when known: it is +-1+ for
      # some inline images and +0+ for a forwarded mail.
      #
      #   attachment_listing(rec[:attachments])
      #   # =>   1. invoice.pdf (application/pdf, 1.4 MB)
      #
      # @param attachments [Array<Gloda::Attachment>]
      # @return [String] one indented line per attachment, numbered from 1.
      def self.attachment_listing(attachments)
        attachments.each_with_index.map do |a, i|
          # The name is sender-authored; a newline in it would forge a line.
          details = [a.content_type, (Pikuri::Tool.format_bytes(a.size) if a.size.positive?),
                     ('online link, not stored' if a.external)].compact.join(', ')
          "  #{i + 1}. #{a.name.gsub(/[[:cntrl:]]/, ' ')} (#{details})"
        end.join("\n")
      end

      # @return [String] the body, truncated with a marker if over {MAX_BODY}.
      def self.body(text)
        text = text.to_s
        return text if text.bytesize <= MAX_BODY

        "#{text.byteslice(0, MAX_BODY)}\n\n… [truncated; message longer than #{MAX_BODY / 1024} KB] …"
      end
      private_class_method :body
    end
  end
end
