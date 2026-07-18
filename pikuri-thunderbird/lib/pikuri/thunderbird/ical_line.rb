# frozen_string_literal: true

module Pikuri
  module Thunderbird
    # Splits one iCalendar *content line* (RFC 5545 §3.1) —
    # +NAME;PARAM=value;PARAM="quoted":value+ — into its name, parameters, and
    # value. The inbound counterpart to {IcsEvent}'s outbound line *building*;
    # pikuri needs it only for +cal_attendees+, the single field Thunderbird
    # leaves as opaque ICS ({Calendar#attendees} turns the parts into people).
    #
    #   line = IcalLine.parse('ATTENDEE;CN="Last, First";PARTSTAT=ACCEPTED:mailto:x@y.com')
    #   line.name           # => "ATTENDEE"
    #   line.params["CN"]   # => "Last, First"   (surrounding quotes stripped)
    #   line.value          # => "mailto:x@y.com"
    #
    # Quote-aware: a +;+ or +:+ inside a double-quoted param value doesn't
    # split. Param names are upcased (RFC 5545 §3.2 says they're
    # case-insensitive); +TEXT+-value backslash *unescaping* is deliberately
    # not done — the addresses and names +cal_attendees+ carries arrive quoted,
    # not +\,+/+\;+-escaped, so it would be dead code here.
    #
    # Immutable.
    module IcalLine
      # One parsed content line.
      #
      # @!attribute [r] name
      #   @return [String] the property name, upcased (e.g. +"ATTENDEE"+).
      # @!attribute [r] params
      #   @return [Hash{String => String}] param name (upcased) → unquoted value.
      # @!attribute [r] value
      #   @return [String] the text after the first unquoted +:+ (+""+ if none).
      Parsed = Data.define(:name, :params, :value)

      # Parse one content line into its {Parsed} parts. Never raises — a line
      # with no +:+ yields an empty value, a token with no +=+ is skipped.
      #
      # @param line [String] a raw iCal content line.
      # @return [Parsed]
      def self.parse(line)
        head, value = split_unquoted(line, ':', max: 2)
        name, *param_tokens = split_unquoted(head, ';')
        params = param_tokens.each_with_object({}) do |token, h|
          key, val = token.split('=', 2)
          h[key.to_s.upcase] = unquote(val) if val
        end
        Parsed.new(name: name.to_s.upcase, params: params, value: value.to_s)
      end

      # Split +str+ on the single char +delim+, ignoring delimiters inside a
      # double-quoted iCal param value; +max+ caps the part count (like
      # +String#split+'s limit) so a value's own +mailto:+ colon survives.
      #
      # @param str [String]
      # @param delim [String] one-character delimiter.
      # @param max [Integer, nil] max parts, or +nil+ for unlimited.
      # @return [Array<String>]
      def self.split_unquoted(str, delim, max: nil)
        parts = []
        buf = +''
        in_quote = false
        str.to_s.each_char do |c|
          if c == '"'
            in_quote = !in_quote
            buf << c
          elsif c == delim && !in_quote && (max.nil? || parts.size < max - 1)
            parts << buf
            buf = +''
          else
            buf << c
          end
        end
        parts << buf
        parts
      end
      private_class_method :split_unquoted

      # @param str [String, nil]
      # @return [String] +str+ with one layer of surrounding double quotes off.
      def self.unquote(str) = str.to_s.gsub(/\A"|"\z/, '')
      private_class_method :unquote
    end
  end
end
