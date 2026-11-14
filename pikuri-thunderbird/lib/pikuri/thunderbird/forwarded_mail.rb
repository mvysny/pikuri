# frozen_string_literal: true

require 'mail'
require 'stringio'

module Pikuri
  module Thunderbird
    # A forwarded email (a +message/rfc822+ attachment) as text, laid out
    # like +thunderbird_mail_read+ shows a message, its attachments numbered
    # under the forward's own handle (+"2"+ here), so +"2.1"+ reads the CV:
    #
    #   ForwardedMail.render(part.decoded, handle: '2')
    #   # => Subject: Application: junior developer
    #   #    From: "Lea Mäkinen" <lea@example.com>
    #   #    To: Tomas Horák <tomas@novak.example>
    #   #    Date: 2026-11-09 22:14
    #   #    Attachments:
    #   #      2.1. Lea_Mäkinen_CV.docx (application/vnd.openxmlformats-…, 5.1 kB)
    #   #
    #   #    Hello Tomas, …
    #
    #   ForwardedMail.attachments(part.decoded)[0].part.decoded  # the CV's bytes
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
    # (+design/architecture.md+ § "Mail: the Gloda index"), and
    # +dev/testbed/compare-forwards+ re-checks them.
    module ForwardedMail
      # One attachment of a forwarded email.
      #
      # * +part+ — +Mail::Part+, its bytes via +part.decoded+.
      # * +name+ — +String+, sender-authored; a nameless part is Gloda's
      #   +"Part 1.5"+, after its part path.
      # * +content_type+ — +String+, lowercased, from the part's own header.
      Attachment = Data.define(:part, :name, :content_type)

      # @param bytes [String] the +message/rfc822+ part's decoded body.
      # @param handle [String] the forward's own attachment handle, e.g.
      #   +"2"+ or +"2.1"+; prefixes the numbers in the listing.
      # @return [String] headers, attachment list and text body.
      def self.render(bytes, handle:)
        mail = ::Mail.new(bytes.b)
        leaves = leaves(mail)
        attachments = leaves.filter_map { |part, path, kind| attachment(part, path) if kind == :attachment }

        headers = [['Subject', mail.subject], ['From', field(mail, :from)], ['To', field(mail, :to)],
                   ['Cc', field(mail, :cc)], ['Date', mail.date && DateHelpers.short_datetime(mail.date.to_time)]]
        lines = headers.filter_map { |name, value| "#{name}: #{clean(value)}" if value && !value.to_s.empty? }
        lines << (attachments.empty? ? 'Attachments: (none)' : "Attachments:\n#{listing(attachments, handle)}")
        "#{lines.join("\n")}\n\n#{body(leaves.filter_map { |part, _, kind| part if kind == :body })}"
      end

      # @param bytes [String] the +message/rfc822+ part's decoded body.
      # @return [Array<Attachment>] in listing order, so +"2.1"+ is the first.
      def self.attachments(bytes)
        leaves(::Mail.new(bytes.b)).filter_map { |part, path, kind| attachment(part, path) if kind == :attachment }
      end

      # The numbered listing under +handle+, also quoted back for a wrong
      # number:
      #
      #   listing(attachments(bytes), '2')
      #   # =>   2.1. Lea_Mäkinen_CV.docx (application/vnd.openxmlformats-…, 5.1 kB)
      #   #      2.2. Fwd.eml (forwarded email)
      #
      # @param attachments [Array<Attachment>]
      # @param handle [String] the forward's own handle.
      # @return [String] one indented line per attachment.
      def self.listing(attachments, handle)
        attachments.each_with_index.map { |a, i| "  #{handle}.#{i + 1}. #{describe(a)}" }.join("\n")
      end

      # @param mail [Mail::Message]
      # @return [Array<Array(Mail::Part, String, Symbol)>] every leaf, its
      #   part path and its {.kind}.
      def self.leaves(mail)
        out = []
        walk(mail, '1', related: false, alternative: false) { |part, path, kind| out << [part, path, kind] }
        out
      end
      private_class_method :leaves

      # @param part [Mail::Part]
      # @param path [String]
      # @return [Attachment]
      def self.attachment(part, path)
        Attachment.new(part:, name: part.filename || "Part #{path}",
                       content_type: (part.mime_type || 'text/plain').downcase)
      end
      private_class_method :attachment

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

      # @param att [Attachment]
      # @return [String] +"cv.pdf (application/pdf, 5.1 kB)"+.
      def self.describe(att)
        name = clean(att.name)
        return "#{name} (forwarded email)" if att.content_type == 'message/rfc822'

        "#{name} (#{att.content_type}, #{Pikuri::Tool.format_bytes(att.part.body.decoded.bytesize)})"
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
