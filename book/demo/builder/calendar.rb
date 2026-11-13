# frozen_string_literal: true

require 'date'

module Pikuri
  module Demo
    # The demo calendar as iCalendar text: +demo.ics+, which Thunderbird syncs
    # into +calendar-data/cache.sqlite+, and the invitations the mail carries.
    #
    # Timed events carry the build machine's +TZID+; without one Thunderbird
    # stores them as +floating+.
    class Calendar
      # @param facts [Facts]
      # @param tzid [String] an IANA zone, e.g. "Europe/Helsinki".
      def initialize(facts:, tzid:)
        @facts = facts
        @tzid = tzid
      end

      # @return [Integer] VEVENTs in {#ics} (a recurring event is one).
      def event_count = @facts.events.size

      # @return [String] the calendar Thunderbird syncs.
      def ics
        wrap(@facts.events.map { |e| vevent(e) })
      end

      # An invitation, as a +text/calendar; method=REQUEST+ part carries it.
      #
      # @param key [String] an +invites+ key.
      # @return [String]
      def invite(key)
        e = @facts.invites[key]
        wrap([vevent(e, organizer: e.organizer, attendee: true)], method: 'REQUEST')
      end

      # The same event as a plain +.ics+ file to import.
      #
      # @param key [String]
      # @return [String]
      def ics_file(key) = wrap([vevent(@facts.invites[key])], method: 'PUBLISH')

      private

      # @return [String]
      def wrap(events, method: nil)
        lines = ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//pikuri//demo//EN',
                 *("METHOD:#{method}" if method), *events.flatten, 'END:VCALENDAR']
        "#{lines.join("\r\n")}\r\n"
      end

      # @param e [Facts::Node] an event from facts.yml.
      # @return [Array<String>]
      def vevent(e, organizer: nil, attendee: false)
        day = first_day(e)
        lines = ['BEGIN:VEVENT', "UID:#{e.to_h['uid'] || e.summary.downcase.tr(' ', '-')}@novak.example",
                 "DTSTAMP:#{@facts.today.strftime('%Y%m%d')}T000000Z"]
        if e.to_h['all_day']
          lines << "DTSTART;VALUE=DATE:#{day.strftime('%Y%m%d')}" << "DTEND;VALUE=DATE:#{(day + 1).strftime('%Y%m%d')}"
        else
          lines << "DTSTART;TZID=#{@tzid}:#{stamp(day, e.from)}" << "DTEND;TZID=#{@tzid}:#{stamp(day, e.to)}"
        end
        lines << "RRULE:#{e.rrule}" if e.to_h['rrule']
        lines << "SUMMARY:#{e.summary}"
        lines << "LOCATION:#{e.location}" if e.to_h['location']
        if organizer
          lines << "ORGANIZER;CN=#{@facts.people[organizer].name}:mailto:#{@facts.email(organizer)}"
          lines << "ATTENDEE;CN=#{@facts.owner.name};RSVP=TRUE;PARTSTAT=NEEDS-ACTION:mailto:#{@facts.owner.email}" if attendee
        end
        lines << 'END:VEVENT'
      end

      # @return [Date] the event's (first) day.
      def first_day(e)
        h = e.to_h
        return @facts.date(@facts.next_weekday(h['weekday'])) if h['weekday']
        return @facts.date(h['day']) if h['day']

        # A monthly series: start it on the last such day of the month on or before today.
        today = @facts.today
        start = Date.new(today.year, today.month, h.fetch('monthday'))
        start > today ? start.prev_month : start
      end

      # @return [String] e.g. "20261119T100000".
      def stamp(day, hhmm) = "#{day.strftime('%Y%m%d')}T#{hhmm.delete(':')}00"
    end
  end
end
