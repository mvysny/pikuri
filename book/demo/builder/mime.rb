# frozen_string_literal: true

require 'mail'

module Pikuri
  module Demo
    # MIME parts for the demo mail, built with the +mail+ gem so its encoders
    # write the RFC 2047 subjects and RFC 2231 attachment names, and made
    # byte-stable: the gem picks random multipart boundaries, which {.finish}
    # replaces with ones derived from the Message-ID.
    module Mime
      # @param text [String]
      # @param subtype [String] "plain" or "html".
      # @return [Mail::Part]
      def self.text(text, subtype = 'plain')
        part = Mail::Part.new
        part.content_type = "text/#{subtype}; charset=UTF-8"
        part.body = text
        part
      end

      # @param subtype [String] "mixed", "alternative" or "related".
      # @param parts [Array<Mail::Part>]
      # @return [Mail::Part]
      def self.multipart(subtype, parts)
        part = Mail::Part.new
        part.content_type = "multipart/#{subtype}"
        parts.each { |p| part.add_part(p) }
        part
      end

      # An attachment, the way the gem's +attachments[name]=+ writes one.
      #
      # @param name [String] may be non-ASCII (RFC 2231).
      # @param bytes [String]
      # @param type [String, nil] MIME type; guessed from the name when nil.
      # @return [Mail::Part]
      def self.attachment(name, bytes, type: nil)
        scratch = Mail.new
        scratch.attachments[name] = type ? { mime_type: type, content: bytes } : bytes
        scratch.attachments.first
      end

      # Rewrites an attachment's name as an RFC 2231 parameter
      # (+filename*=UTF-8''f%C3%B6.zip+). The gem's own form is an RFC 2047
      # encoded-word inside quotes; real mail carries both, and parsers trip
      # on each differently, so the demo has one of each.
      #
      # @param part [Mail::Part] from {.attachment}.
      # @param name [String]
      # @return [Mail::Part]
      def self.rfc2231(part, name)
        encoded = "UTF-8''#{name.bytes.map { |b| b.chr.match?(/[A-Za-z0-9._-]/) ? b.chr : format('%%%02X', b) }.join}"
        part['Content-Type'] = "#{part.mime_type}; name*=#{encoded}"
        part['Content-Disposition'] = "attachment; filename*=#{encoded}"
        part
      end

      # An image the HTML part shows by +cid:+.
      #
      # @return [Mail::Part]
      def self.inline_image(name, bytes, cid)
        part = attachment(name, bytes, type: 'image/png')
        part.content_disposition = %(inline; filename="#{name}")
        part.content_id = "<#{cid}>"
        part
      end

      # @param ics [String]
      # @param method [String] e.g. "REQUEST".
      # @return [Mail::Part]
      def self.calendar(ics, method:)
        part = Mail::Part.new
        part.content_type = "text/calendar; method=#{method}; charset=UTF-8"
        part.body = ics
        part
      end

      # A forwarded message, attached whole.
      #
      # @param message [Mail::Message]
      # @return [Mail::Part]
      def self.forwarded(message)
        part = Mail::Part.new
        part.content_type = 'message/rfc822'
        part.content_disposition = %(attachment; filename="#{message.subject}.eml")
        part.body = message.encoded
        part
      end

      # Makes +top+ the body of +message+ and fixes every boundary.
      #
      # @param message [Mail::Message]
      # @param top [Mail::Part]
      # @param seed [String] unique per message (its Message-ID).
      # @return [Mail::Message]
      def self.finish(message, top, seed)
        if top.multipart?
          message.content_type = top.content_type
          top.parts.each { |p| message.add_part(p) }
        else
          message.content_type = top.content_type
          message.body = top.body.decoded
        end
        counter = 0
        fix = lambda do |part|
          next unless part.multipart?

          boundary = "=_pikuri_#{seed}_#{counter += 1}"
          part.content_type = part.content_type.sub(/;\s*boundary="?[^";]*"?/, '') + %(; boundary="#{boundary}")
          part.body.boundary = boundary
          part.parts.each(&fix)
        end
        fix.call(message)
        message
      end
    end
  end
end
