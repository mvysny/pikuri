# frozen_string_literal: true

module Pikuri
  module Thunderbird
    # The +thunderbird_mail_read+ tool — the read half of the mail
    # search→read pair. Given a +message_id+ from +thunderbird_mail_search+,
    # returns the full decoded body (Gloda has already MIME-decoded and
    # HTML-stripped it, so no markup noise) plus headers and attachment
    # names. Inbound-only.
    class MailRead < Pikuri::Tool
      # @return [Integer] hard cap on the body bytes returned (a runaway
      #   50k-char body would swamp the context).
      MAX_BODY = 40 * 1024

      # @return [String] opencode-shape description.
      DESCRIPTION = <<~DESC
        Read one local Thunderbird message in full (headers, decoded plain-text body, attachment names).

        Usage:
        - Pass the id from a thunderbird_mail_search result.
        - Returns the full text; attachment contents are not opened, only their names are listed.
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

      # @return [String] formatted message or +"Error: …"+.
      def self.run_read(backend:, message_id:)
        rec = backend.read(message_id:)
        return "Error: no message found with id #{message_id.inspect}." unless rec

        attachments = rec[:attachment_names].to_s.strip
        <<~MSG.chomp
          Subject: #{rec[:subject]}
          From: #{rec[:from]}
          To: #{rec[:to]}
          Date: #{DateHelpers.short_datetime(rec[:date])}
          Folder: #{rec[:folder]}
          Attachments: #{attachments.empty? ? '(none)' : attachments}

          #{body(rec[:body])}
        MSG
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
