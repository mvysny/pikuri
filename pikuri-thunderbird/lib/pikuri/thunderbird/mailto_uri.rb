# frozen_string_literal: true

module Pikuri
  module Thunderbird
    # Builds the percent-encoded +mailto:+ URI that {MailCompose} hands to
    # Thunderbird. The URI *is* the injection surface — a naive concat lets an
    # attacker-authored body smuggle its own +&bcc=exfil@evil.com+ — so every
    # field value is percent-encoded before it joins the URI:
    #
    #   MailtoUri.build(to: ['a@x.com'], subject: 'Re: hi',
    #                   body: "Line 1\nLine 2 & more")
    #   # => "mailto:a@x.com?subject=Re:%20hi&body=Line%201%0ALine%202%20%26%20more"
    #
    # Multiple recipients ride comma-separated (the commas stay literal — they
    # delimit addresses; each address is encoded individually). The caller
    # ({ComposeGuard}) has already split and validated the addresses, so a comma
    # here only ever separates two vetted recipients.
    #
    # Immutable.
    module MailtoUri
      # Bytes kept literal; everything else — the structural +& ? = # %+, spaces,
      # newlines, and every non-ASCII byte — is percent-encoded. +@+ stays literal
      # so an address reads as +a@x.com+ (the confirmed-working shape), not
      # +a%40x.com+. Matched byte-wise (+/n+) so a multibyte body encodes cleanly.
      UNRESERVED = %r{[^A-Za-z0-9\-._~@]}n

      # @param to [Array<String>] validated recipient addresses (may be empty —
      #   the human then types the recipient in the opened window).
      # @param cc [Array<String>] validated Cc addresses.
      # @param bcc [Array<String>] validated Bcc addresses.
      # @param subject [String, nil] subject line, or +nil+ to omit.
      # @param body [String, nil] plain-text body, or +nil+ to omit.
      # @return [String] the +mailto:+ URI.
      def self.build(to:, cc: [], bcc: [], subject: nil, body: nil)
        params = []
        params << "cc=#{encode_list(cc)}" unless cc.empty?
        params << "bcc=#{encode_list(bcc)}" unless bcc.empty?
        params << "subject=#{encode(subject)}" if subject && !subject.empty?
        params << "body=#{encode(body)}" if body && !body.empty?

        uri = "mailto:#{encode_list(to)}"
        params.empty? ? uri : "#{uri}?#{params.join('&')}"
      end

      # @param addrs [Array<String>]
      # @return [String] each address percent-encoded, joined by literal commas.
      def self.encode_list(addrs) = addrs.map { |a| encode(a) }.join(',')

      # Percent-encode one value byte-wise (uppercase hex).
      #
      # @param value [String]
      # @return [String]
      def self.encode(value)
        value.to_s.b.gsub(UNRESERVED) { |byte| format('%%%02X', byte.ord) }
      end
    end
  end
end
