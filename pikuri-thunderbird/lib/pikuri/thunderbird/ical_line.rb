# frozen_string_literal: true

module Pikuri
  module Thunderbird
    # Parses the little iCalendar that Thunderbird leaves opaque — the raw
    # content lines of +cal_attendees+ and +cal_recurrence+ (everything else
    # is already in normalized columns). The
    # inbound counterpart to {IcsEvent}'s outbound line *building*. Two entry
    # points:
    #
    #   # domain: an attendee line → a typed {Attendee}
    #   who = IcalLine.attendee('ATTENDEE;CN="Last, First";PARTSTAT=ACCEPTED:mailto:x@y.com')
    #   who.name        # => "Last, First"
    #   who.email       # => "x@y.com"
    #   who.optional?   # => false
    #
    #   # generic: any content line → its name/params/value
    #   line = IcalLine.parse('ATTENDEE;PARTSTAT=ACCEPTED:mailto:x@y.com')
    #   line.params["PARTSTAT"]   # => "ACCEPTED"
    #
    # Both are quote-aware — a +;+/+:+ inside a double-quoted param value
    # doesn't split — and upcase param names (RFC 5545 §3.2: case-insensitive).
    # +TEXT+-value backslash *unescaping* is deliberately not done: the names
    # and addresses +cal_attendees+ carries arrive quoted, not +\,+/+\;+-escaped,
    # so it would be dead code.
    #
    # Immutable.
    module IcalLine
      # One attendee or organizer, parsed from an +ATTENDEE+/+ORGANIZER+ line.
      # +email+ falls back from the +EMAIL+ param to the +mailto:+ value,
      # +name+ from +CN+ to the email — so both are always present.
      #
      # @!attribute [r] name
      #   @return [String] display name (+CN+), or the email when there's no CN.
      # @!attribute [r] email
      #   @return [String] the address, sans +mailto:+.
      # @!attribute [r] status
      #   @return [String, nil] raw +PARTSTAT+ (+"ACCEPTED"+, +"NEEDS-ACTION"+…).
      # @!attribute [r] role
      #   @return [String, nil] raw +ROLE+ (+"REQ-PARTICIPANT"+, +"OPT-PARTICIPANT"+).
      # @!attribute [r] cutype
      #   @return [String, nil] raw +CUTYPE+ (+"INDIVIDUAL"+, +"RESOURCE"+…).
      # @!attribute [r] organizer
      #   @return [Boolean] whether the line was an +ORGANIZER+, not an +ATTENDEE+.
      Attendee = Data.define(:name, :email, :status, :role, :cutype, :organizer) do
        # @return [Boolean] the ORGANIZER (vs a plain attendee).
        def organizer? = organizer

        # @return [Boolean] an optional invitee (+ROLE=OPT-PARTICIPANT+).
        def optional? = role == 'OPT-PARTICIPANT'

        # @return [Boolean] a room/equipment, not a person (+CUTYPE=RESOURCE+).
        def resource? = cutype == 'RESOURCE'
      end

      # One generic parsed content line.
      #
      # @!attribute [r] name
      #   @return [String] the property name, upcased (e.g. +"ATTENDEE"+).
      # @!attribute [r] params
      #   @return [Hash{String => String}] param name (upcased) → unquoted value.
      # @!attribute [r] value
      #   @return [String] the text after the first unquoted +:+ (+""+ if none).
      Parsed = Data.define(:name, :params, :value)

      # Parse one +ATTENDEE+/+ORGANIZER+ content line into an {Attendee}.
      #
      # @param line [String] one raw +cal_attendees.icalString+.
      # @return [Attendee]
      def self.attendee(line)
        parsed = parse(line)
        email = (parsed.params['EMAIL'].to_s.empty? ? parsed.value.sub(/\Amailto:/i, '') : parsed.params['EMAIL']).strip
        name = parsed.params['CN'].to_s.strip
        Attendee.new(
          name: name.empty? ? email : name, email: email,
          status: parsed.params['PARTSTAT'], role: parsed.params['ROLE'],
          cutype: parsed.params['CUTYPE'], organizer: parsed.name == 'ORGANIZER'
        )
      end

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
