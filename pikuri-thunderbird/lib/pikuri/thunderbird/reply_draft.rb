# frozen_string_literal: true

require 'mail'

module Pikuri
  module Thunderbird
    # Builds the draft +.eml+ that {MailReply} stages for Thunderbird: one
    # plain-text part, marked +X-Unsent: 1+ so Thunderbird opens it in a
    # compose window instead of as a message to read. Its body is the reply
    # text over a quote of the original:
    #
    #   body = "Thursday works.\n\n" +
    #          ReplyDraft.quote(text: "Yes, same link.\n…", author: 'Mira Koskinen', date: time)
    #   # => "Thursday works.\n\nOn 2026-11-22 14:10, Mira Koskinen wrote:\n> Yes, same link.\n> …"
    #   ReplyDraft.build(from: identity, to: ['mira@lumo-studio.example'], cc: [],
    #                    subject: 'Re: Planning call next week?',
    #                    thread: %w[plan-1@lumo-studio.example plan-2@novak.example plan-3@lumo-studio.example],
    #                    body: body)
    #   # => "From: Alex Novak <alex@novak.example>\r\nTo: …\r\nIn-Reply-To: <plan-3@lumo-studio.example>\r\n
    #   #     References: <plan-1@…>\r\n <plan-2@…>\r\n <plan-3@…>\r\nSubject: …\r\nX-Unsent: 1\r\n…"
    #
    # The file is the injection surface, as the URI is for {MailtoUri}: a
    # subject or Message-ID the original's sender wrote, carrying a line
    # break, would open a header of its own (+Bcc:+). So the header set is
    # fixed by construction — From, To, Cc, Subject, In-Reply-To, References,
    # X-Unsent and the MIME ones, nothing else, never an attachment — the
    # subject loses its control characters, a Message-ID that isn't one
    # +id@host+ of visible ASCII is dropped, and the +mail+ gem encodes and
    # folds what is left.
    #
    # == Implementation details
    #
    # Only the headers come from the +mail+ gem: a whole +Mail::Message+ adds
    # its own +Message-ID+ and +Date+ when encoded, and a draft carries
    # neither. The body is base64, so a quoted line past 998 bytes, which an
    # HTML mail stripped to text often has, still travels.
    module ReplyDraft
      # @return [Regexp] a Message-ID without its angle brackets: visible
      #   ASCII but +<+ and +>+, with an +@+.
      MESSAGE_ID = /\A[!-;=?-~]+@[!-;=?-~]+\z/

      # @return [Integer] most Message-IDs kept in +References+: the first and
      #   the latest, as RFC 5322 § 3.6.4 allows, so a hostile chain of
      #   thousands can't grow the draft without bound.
      MAX_REFERENCES = 20

      # @param from [Accounts::Identity, nil] the sending identity; +nil+ omits
      #   +From+, and Thunderbird opens the draft from its default one.
      # @param to [Array<String>] vetted recipient addresses; may be empty.
      # @param cc [Array<String>] vetted Cc addresses.
      # @param subject [String, nil] the subject, or +nil+ to omit it.
      # @param thread [Array<String>] Message-IDs, oldest first, the original's
      #   own last: +In-Reply-To+ is the last valid one, +References+ all.
      # @param body [String] the plain-text body.
      # @return [String] the +.eml+ bytes, CRLF throughout.
      def self.build(from:, to:, cc:, subject:, thread:, body:)
        message = ::Mail.new
        message.from = address(from) if from
        message.to = to unless to.empty?
        message.cc = cc unless cc.empty?
        message.subject = subject.gsub(/[[:cntrl:]]/, ' ') if subject
        ids = thread.grep(MESSAGE_ID).uniq
        ids = [ids.first, *ids.last(MAX_REFERENCES - 1)] if ids.size > MAX_REFERENCES
        unless ids.empty?
          message.in_reply_to = "<#{ids.last}>"
          message.references = ids.map { "<#{_1}>" }
        end
        message['X-Unsent'] = '1'
        "#{message.header.encoded}MIME-Version: 1.0\r\nContent-Type: text/plain; charset=UTF-8\r\n" \
          "Content-Transfer-Encoding: base64\r\n\r\n#{[body.gsub(/\r?\n/, "\r\n")].pack('m').gsub("\n", "\r\n")}"
      end

      # The original's text as a reply quotes it: an attribution line, then
      # every line +> +-prefixed. A text Gloda cut at its per-part cap ends
      # +> […]+, so the quote doesn't stop mid-sentence unannounced.
      #
      # @param text [String] the original's decoded body, as Gloda keeps it.
      # @param author [String] whom the attribution names; sender-authored.
      # @param date [Time, nil] when the original was sent.
      # @return [String] the attribution and the quote, no trailing newline.
      def self.quote(text:, author:, date:)
        wrote = "#{date ? "On #{DateHelpers.short_datetime(date)}, " : ''}#{author.gsub(/[[:cntrl:]]/, ' ')} wrote:"
        lines = text.strip.split(/\r?\n/).map { _1.rstrip.empty? ? '>' : "> #{_1.rstrip}" }
        lines << '> […]' if text.bytesize >= MailRead::GLODA_PART_CAP
        [wrote, *lines].join("\n")
      end

      # @param identity [Accounts::Identity]
      # @return [String] +"Name <email>"+, or the bare address when unnamed.
      def self.address(identity)
        address = ::Mail::Address.new
        address.address = identity.email
        address.display_name = identity.name unless identity.name.empty?
        address.to_s
      end
      private_class_method :address
    end
  end
end
