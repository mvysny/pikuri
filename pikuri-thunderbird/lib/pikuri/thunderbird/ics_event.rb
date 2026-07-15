# frozen_string_literal: true

require 'securerandom'
require 'time'

module Pikuri
  module Thunderbird
    # Builds the iCalendar (+.ics+) text that {CalendarCreate} stages for
    # Thunderbird's import wizard. The text *is* the injection surface — the same
    # role {MailtoUri} plays for compose — because a raw newline in a text field
    # would let an attacker-authored description close +DESCRIPTION+ and inject
    # its own +ATTENDEE+ line or a second +VEVENT+. So every text value is
    # RFC-5545-escaped (+\+, +;+, +,+, newline) and control bytes are stripped
    # before it joins a property line:
    #
    #   IcsEvent.build(title: 'Q2 review', start: Time.parse('2026-07-20 14:00'))
    #   # BEGIN:VCALENDAR … BEGIN:VEVENT
    #   #   SUMMARY:Q2 review
    #   #   DTSTART:20260720T120000Z      ← host-local 14:00 emitted as UTC
    #   #   DTEND:20260720T130000Z        ← default +1h
    #   # END:VEVENT END:VCALENDAR
    #
    # == Time & all-day encoding
    #
    # Timed events emit +DTSTART+/+DTEND+ as UTC (+…Z+): the caller's {Time} is
    # taken at face value and converted with +#utc+, so a bare "2pm" the user
    # typed is 2pm in the *host* zone — the same "host zone == user zone"
    # heuristic {Calendar}/{Format} already read events back with. All-day events
    # emit +VALUE=DATE+ with an iCal *exclusive* +DTEND+ (a single-day event's
    # DTEND is the next day), so +finish+ is the user-intuitive *last* day.
    #
    # Immutable.
    module IcsEvent
      # @return [String] product id line value; identifies pikuri as the writer.
      PRODID = '-//pikuri//thunderbird//EN'

      # C0/C1 control bytes (except the ones {.escape} turns into +\n+) — invalid
      # in an ICS value and a structure-injection vector; stripped outright.
      CONTROL = /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/n

      # Build the +.ics+ document for one event.
      #
      # @param title [String] event summary (SUMMARY).
      # @param start [Time] start instant (timed) or day (all-day, date part used).
      # @param finish [Time, nil] end instant / last all-day date; +nil+ defaults
      #   to +start + 1h+ (timed) or the same single day (all-day).
      # @param all_day [Boolean] emit +VALUE=DATE+ instead of a UTC datetime.
      # @param location [String, nil] LOCATION, or +nil+ to omit.
      # @param description [String, nil] DESCRIPTION, or +nil+ to omit.
      # @param uid [String] event UID; defaults to a fresh random one.
      # @param dtstamp [Time] the DTSTAMP instant; defaults to now.
      # @return [String] a complete +VCALENDAR+ with one +VEVENT+, CRLF-joined.
      def self.build(title:, start:, finish: nil, all_day: false, location: nil, description: nil,
                     uid: "#{SecureRandom.uuid}@pikuri", dtstamp: Time.now)
        lines = [
          'BEGIN:VCALENDAR', 'VERSION:2.0', "PRODID:#{PRODID}", 'METHOD:PUBLISH',
          'BEGIN:VEVENT', "UID:#{escape(uid)}", "DTSTAMP:#{utc_stamp(dtstamp)}",
          *date_lines(start, finish, all_day),
          "SUMMARY:#{escape(title)}"
        ]
        lines << "LOCATION:#{escape(location)}" if present?(location)
        lines << "DESCRIPTION:#{escape(description)}" if present?(description)
        lines += %w[END:VEVENT END:VCALENDAR]
        # CRLF line endings + a trailing CRLF, per RFC 5545 §3.1.
        "#{lines.join("\r\n")}\r\n"
      end

      # @return [Array<String>] the DTSTART/DTEND property lines.
      def self.date_lines(start, finish, all_day)
        return timed_lines(start, finish) unless all_day

        last = finish || start
        ["DTSTART;VALUE=DATE:#{date_stamp(start)}",
         "DTEND;VALUE=DATE:#{date_stamp(last + 86_400)}"] # exclusive: last day + 1
      end
      private_class_method :date_lines

      # @return [Array<String>]
      def self.timed_lines(start, finish)
        ["DTSTART:#{utc_stamp(start)}", "DTEND:#{utc_stamp(finish || start + 3600)}"]
      end
      private_class_method :timed_lines

      # @param time [Time]
      # @return [String] +"YYYYMMDDTHHMMSSZ"+ (UTC).
      def self.utc_stamp(time) = time.getutc.strftime('%Y%m%dT%H%M%SZ')
      private_class_method :utc_stamp

      # @param time [Time]
      # @return [String] +"YYYYMMDD"+ (local date, for all-day VALUE=DATE).
      def self.date_stamp(time) = time.getlocal.strftime('%Y%m%d')
      private_class_method :date_stamp

      # RFC 5545 §3.3.11 TEXT escaping + control-byte strip (the injection
      # defense). Long lines are left unfolded — Thunderbird reads them fine.
      #
      # @param value [String]
      # @return [String]
      def self.escape(value)
        # Block form: the returned strings are used literally, sidestepping
        # gsub's backreference interpretation of a replacement String. Backslash
        # first, so the escapes introduced below aren't themselves re-escaped.
        value.to_s.gsub(CONTROL, '')
             .gsub('\\') { '\\\\' }
             .gsub(';') { '\\;' }
             .gsub(',') { '\\,' }
             .gsub(/\r\n|\r|\n/) { '\\n' }
      end
      private_class_method :escape

      # @return [Boolean]
      def self.present?(value) = !value.nil? && !value.to_s.strip.empty?
      private_class_method :present?
    end
  end
end
