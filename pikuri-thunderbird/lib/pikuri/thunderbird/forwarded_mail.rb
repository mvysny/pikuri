# frozen_string_literal: true

require 'mail'
require 'stringio'

module Pikuri
  module Thunderbird
    # A forwarded email (a +message/rfc822+ attachment) as text, laid out
    # like +thunderbird_mail_read+ shows a message:
    #
    #   ForwardedMail.render(part.decoded)
    #   # => Subject: Application: junior developer
    #   #    From: "Lea Mäkinen" <lea@example.com>
    #   #    To: Tomas Horák <tomas@novak.example>
    #   #    Date: 2026-11-09 22:14
    #   #    Attachments (open them in Thunderbird):
    #   #      - Lea_Mäkinen_CV.docx (application/vnd.openxmlformats-…, 5.1 kB)
    #   #
    #   #    Hello Tomas, …
    #
    # Gloda indexes only the outer message, so this walks the bytes with the
    # +mail+ gem, which decodes the RFC 2047 headers and charsets.
    #
    # == Implementation details
    #
    # The attachment list follows Gloda's rule for a top-level message, so the
    # two levels agree: whatever sits under +multipart/alternative+ or
    # +multipart/related+ is body (an HTML mail's +cid:+ images included), and
    # a +text/plain+ or +text/html+ leaf without a file name is body too
    # (measured on the testbed; +design/architecture.md+ § "Mail: the Gloda
    # index").
    module ForwardedMail
      # @param bytes [String] the +message/rfc822+ part's decoded body.
      # @return [String] headers, attachment list and text body.
      def self.render(bytes)
        mail = ::Mail.new(bytes.b)
        leaves = []
        walk(mail, in_body: false) { |part, in_body| leaves << [part, in_body] }
        attachments = leaves.filter_map { |part, in_body| part unless in_body || body_text?(part) }

        headers = [['Subject', mail.subject], ['From', field(mail, :from)], ['To', field(mail, :to)],
                   ['Cc', field(mail, :cc)], ['Date', mail.date && DateHelpers.short_datetime(mail.date.to_time)]]
        lines = headers.filter_map { |name, value| "#{name}: #{clean(value)}" if value && !value.to_s.empty? }
        lines << if attachments.empty?
                   'Attachments: (none)'
                 else
                   "Attachments (open them in Thunderbird):\n#{attachments.map { "  - #{describe(_1)}" }.join("\n")}"
                 end
        "#{lines.join("\n")}\n\n#{body(leaves.map(&:first).select { body_text?(_1) })}"
      end

      # Yields every leaf part with whether it sits inside an +alternative+ or
      # +related+ subtree.
      #
      # @param part [Mail::Message, Mail::Part]
      # @param in_body [Boolean]
      # @yieldparam leaf [Mail::Part]
      # @yieldparam in_body [Boolean]
      # @return [void]
      def self.walk(part, in_body:, &)
        return yield(part, in_body) unless part.multipart?

        nested = in_body || %w[alternative related].include?(part.sub_type)
        part.parts.each { walk(_1, in_body: nested, &) }
      end
      private_class_method :walk

      # @param part [Mail::Part]
      # @return [Boolean] a text leaf the mail shows as its body, not a file.
      def self.body_text?(part)
        %w[text/plain text/html].include?(part.mime_type) && !part.attachment?
      end
      private_class_method :body_text?

      # Every plain-text leaf, or the first HTML one when there is none. HTML
      # renders through the {Pikuri::Extractor} registry: Markdown when
      # pikuri-web is loaded, raw markup otherwise.
      #
      # @param parts [Array<Mail::Part>] the body-text leaves, in order.
      # @return [String]
      def self.body(parts)
        plain = parts.select { _1.mime_type == 'text/plain' }
        return plain.map { _1.decoded.strip }.join("\n\n") unless plain.empty?

        html = parts.first or return '(no text body)'
        Pikuri::Extractor.extract(StringIO.new(html.decoded), content_type: 'text/html').strip
      end
      private_class_method :body

      # @param part [Mail::Part]
      # @return [String] +"cv.pdf (application/pdf, 5.1 kB)"+.
      def self.describe(part)
        name = clean(part.filename || '(unnamed)')
        return "#{name} (forwarded email)" if part.mime_type == 'message/rfc822'

        "#{name} (#{part.mime_type}, #{Pikuri::Tool.format_bytes(part.body.decoded.bytesize)})"
      end
      private_class_method :describe

      # @param mail [Mail::Message]
      # @param name [Symbol]
      # @return [String, nil] the decoded header, or +nil+ when absent.
      def self.field(mail, name)
        mail[name]&.decoded
      end
      private_class_method :field

      # Sender-authored text on one line: a newline in a name would forge a
      # header line.
      #
      # @param text [String]
      # @return [String]
      def self.clean(text)
        text.to_s.gsub(/[[:cntrl:]]/, ' ')
      end
      private_class_method :clean
    end
  end
end
