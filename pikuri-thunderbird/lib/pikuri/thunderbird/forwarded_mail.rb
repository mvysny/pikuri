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
    # The attachment list is what Gloda lists for the same mail at top level,
    # so the two levels agree. Thunderbird's C++ MIME code decides that, so
    # the rule in {.kind} is measured, not ported: the testbed holds Apple
    # Mail, Outlook and odd-leaf shapes each top-level and forwarded
    # (+design/architecture.md+ § "Mail: the Gloda index").
    module ForwardedMail
      # @param bytes [String] the +message/rfc822+ part's decoded body.
      # @return [String] headers, attachment list and text body.
      def self.render(bytes)
        mail = ::Mail.new(bytes.b)
        leaves = []
        walk(mail, '1', related: false, alternative: false) { |part, path, kind| leaves << [part, path, kind] }
        attachments = leaves.select { |_, _, kind| kind == :attachment }

        headers = [['Subject', mail.subject], ['From', field(mail, :from)], ['To', field(mail, :to)],
                   ['Cc', field(mail, :cc)], ['Date', mail.date && DateHelpers.short_datetime(mail.date.to_time)]]
        lines = headers.filter_map { |name, value| "#{name}: #{clean(value)}" if value && !value.to_s.empty? }
        lines << if attachments.empty?
                   'Attachments: (none)'
                 else
                   "Attachments (open them in Thunderbird):\n#{attachments.map { |p, path, _| "  - #{describe(p, path)}" }.join("\n")}"
                 end
        "#{lines.join("\n")}\n\n#{body(leaves.filter_map { |part, _, kind| part if kind == :body })}"
      end

      # Yields every leaf part with its Gloda-style part path (+"1.2.2"+:
      # the root is +1+) and its {.kind}.
      #
      # @param part [Mail::Message, Mail::Part]
      # @param path [String]
      # @param related [Boolean] inside a +multipart/related+ subtree.
      # @param alternative [Boolean] a direct child of +multipart/alternative+.
      # @yieldparam leaf [Mail::Part]
      # @yieldparam path [String]
      # @yieldparam kind [Symbol]
      # @return [void]
      def self.walk(part, path, related:, alternative:, &)
        return yield(part, path, kind(part, related:, alternative:)) unless part.multipart?

        part.parts.each_with_index do |child, i|
          walk(child, "#{path}.#{i + 1}", related: related || part.sub_type == 'related',
                                          alternative: part.sub_type == 'alternative', &)
        end
      end
      private_class_method :walk

      # Classifies a leaf the way Gloda's +attachmentInfos+ does:
      #
      #   related > [html, image by cid:]        # :body, :hidden
      #   mixed > [plain, pdf, csv by name only] # :body, :attachment, :attachment
      #   alternative > [plain, unnamed ics]     # :body, :hidden (an invitation)
      #   alternative > [plain, mixed > [html, named pdf, html]] # Apple Mail: the pdf is :attachment
      #
      # A file name, or +Content-Disposition: attachment+ alone, makes an
      # attachment anywhere but under +related+. An unnamed leaf that is not
      # text is one too (Gloda's "Part 1.5"), unless it is an +alternative+'s
      # rendition.
      #
      # @param part [Mail::Part]
      # @param related [Boolean]
      # @param alternative [Boolean]
      # @return [Symbol] +:attachment+, +:body+ (text shown as the body) or
      #   +:hidden+.
      def self.kind(part, related:, alternative:)
        text = %w[text/plain text/html].include?(part.mime_type)
        return text ? :body : :hidden if related
        return :attachment if part.filename || part.content_disposition.to_s.downcase.start_with?('attachment')
        return :body if text

        alternative ? :hidden : :attachment
      end
      private_class_method :kind

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
      # @param path [String] names a nameless part, as Gloda does.
      # @return [String] +"cv.pdf (application/pdf, 5.1 kB)"+.
      def self.describe(part, path)
        name = clean(part.filename || "Part #{path}")
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
