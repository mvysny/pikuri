# frozen_string_literal: true

require 'date'
require 'set'
require 'ice_cube'
require 'tzinfo'

module Pikuri
  module Thunderbird
    # The start instants of one recurring series inside a search window.
    # Thunderbird stores a series as one master row dated at its *first*
    # occurrence plus its raw +cal_recurrence+ lines, so a date search must
    # expand them:
    #
    #   rec = Recurrence.new(start: Time.utc(2026, 11, 9, 7), tz: 'Europe/Helsinki',
    #                        lines: ['RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR'], overridden: Set.new)
    #   rec.starts(after: Time.utc(2026, 11, 16), before: Time.utc(2026, 11, 20, 22))
    #   # => [2026-11-16 07:00 UTC, 2026-11-18 07:00 UTC, 2026-11-20 07:00 UTC]  — 09:00 Helsinki each
    #
    # DTSTART is always the first occurrence, even when the rule doesn't
    # match it (libical's reading of RFC 5545, so Thunderbird's). +EXDATE+
    # drops a date, +RDATE+ adds one, and a start in +overridden+ — an edited
    # occurrence Thunderbird stores as its own row — is left to that row.
    #
    # == Implementation details
    #
    # Expansion runs on the event's *wall clock*: its local time rewritten as
    # if it were UTC, where there is no DST, so ice_cube keeps a 09:00 meeting
    # at 09:00 and matches +BYDAY+ on the local weekday. Each date then goes
    # back through the event's zone to an instant. ice_cube's own iCal reader
    # drops +TZID+, so only the RRULE value goes through it; +UNTIL+, +EXDATE+
    # and +RDATE+ are parsed here.
    #
    # A stranger's invitation can write a rule into the calendar, and ice_cube
    # has no loop guard: a +COUNT+ rule walks from DTSTART whatever the window,
    # and an +HOURLY+ or finer one yields a date per step. So only +DAILY+ and
    # coarser rules expand, +COUNT+ stops at {MAX_COUNT}, and the window spans
    # at most {MAX_SPAN}; past those, {Unexpandable}.
    #
    # Immutable.
    class Recurrence
      # Raised for a series this class won't expand: a rule part, zone or date
      # it can't read, or one past the guards. The message names the culprit.
      class Unexpandable < StandardError; end

      # @return [Array<String>] the +FREQ+ values that expand.
      FREQUENCIES = %w[DAILY WEEKLY MONTHLY YEARLY].freeze

      # @return [Integer] the largest +COUNT+ that expands; a 0.2 s walk at
      #   100,000, so well below.
      MAX_COUNT = 1000

      # @return [Integer] seconds: the longest window expanded, two years.
      MAX_SPAN = 731 * 86_400

      # @return [Integer] seconds of slack each side of the wall-clock window,
      #   covering any zone's offset; the exact bounds are applied after.
      SLACK = 86_400

      # @param start [Time] the master row's start instant (DTSTART).
      # @param tz [String] its +event_start_tz+: an Olson name, +floating+,
      #   +UTC+ or +GMT+0300+.
      # @param lines [Array<String>] its +cal_recurrence.icalString+ rows.
      # @param overridden [Set<Integer>] epoch seconds of the occurrences
      #   stored as their own rows (their +recurrence_id+).
      # @raise [Unexpandable]
      def initialize(start:, tz:, lines:, overridden:)
        @tz = tz.to_s
        @zone = zone(@tz)
        @start = wall_of(start, @zone)
        @overridden = overridden
        @rules = []
        @exdates = Set.new
        @exdays = Set.new
        @rdates = []
        lines.each { |raw| read_line(raw) }
      end

      # @param after [Time, nil] inclusive lower bound.
      # @param before [Time, nil] inclusive upper bound; at least one of the two.
      # @return [Array<Time>] UTC start instants, ascending.
      def starts(after:, before:)
        from, to = window(after, before)
        schedule = IceCube::Schedule.new(@start)
        @rules.each { |rule| schedule.add_recurrence_rule(rule) }
        walls = schedule.occurrences_between(wall_of(from, @zone) - SLACK, wall_of(to, @zone) + SLACK)
                        .map { |occurrence| Time.at(occurrence.to_i).utc }
        walls = (walls + [@start] + @rdates).uniq.reject { |w| @exdates.include?(w) || @exdays.include?(w.to_date) }
        walls.map { |w| instant_of(w, @zone) }
             .select { |t| t.between?(from, to) && !@overridden.include?(t.to_i) }
             .sort
      end

      private

      # @return [Array(Time, Time)]
      def window(after, before)
        raise ArgumentError, 'a window needs after or before' unless after || before

        from = after || (before - MAX_SPAN)
        [from, [before, from + MAX_SPAN].compact.min]
      end

      # @param raw [String] one +cal_recurrence+ content line.
      # @return [void]
      def read_line(raw)
        line = IcalLine.parse(raw.to_s.strip)
        case line.name
        when 'RRULE' then @rules << rule(line.value)
        when 'EXDATE'
          dates(line).each { |kind, wall| kind == :date ? @exdays << wall.to_date : @exdates << wall }
        when 'RDATE' then @rdates.concat(dates(line).map(&:last))
        else raise Unexpandable, "unsupported #{line.name} line"
        end
      end

      # @param value [String] an RRULE value, e.g. +"FREQ=WEEKLY;UNTIL=20270101T000000Z"+.
      # @return [IceCube::Rule]
      def rule(value)
        parts = value.split(';').to_h { |part| part.split('=', 2).then { |k, v| [k.to_s.upcase, v.to_s] } }
        raise Unexpandable, "FREQ=#{parts['FREQ']}" unless FREQUENCIES.include?(parts['FREQ'])
        raise Unexpandable, "COUNT=#{parts['COUNT']}" if parts['COUNT'].to_i > MAX_COUNT

        until_value = parts.delete('UNTIL')
        rule = IceCube::Rule.from_ical(parts.map { |k, v| "#{k}=#{v}" }.join(';'))
        return rule unless until_value

        kind, wall = date(until_value, {})
        rule.until(kind == :date ? wall + 86_399 : wall) # a DATE UNTIL includes its whole day
      rescue ArgumentError, NoMethodError => e
        raise Unexpandable, "RRULE #{value}: #{e.message}"
      end

      # @param line [IcalLine::Parsed] an +EXDATE+ or +RDATE+ line.
      # @return [Array<Array(Symbol, Time)>] +[:date | :time, wall]+ per value.
      def dates(line)
        line.value.split(',').map { |value| date(value.split('/').first.to_s, line.params) } # a PERIOD counts by its start
      end

      # @param value [String] +20261118+, +20261118T090000+ or +20261118T070000Z+.
      # @param params [Hash{String => String}] the line's params (+TZID+).
      # @return [Array(Symbol, Time)] +:date+ or +:time+, and the wall clock in
      #   the event's zone.
      def date(value, params)
        m = value.strip.match(/\A(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})(Z?))?\z/)
        raise Unexpandable, "unreadable date #{value.inspect}" unless m

        y, mo, d, h, mi, s, utc = m.captures
        return [:date, Time.utc(y.to_i, mo.to_i, d.to_i)] unless h

        wall = Time.utc(y.to_i, mo.to_i, d.to_i, h.to_i, mi.to_i, s.to_i)
        return [:time, wall_of(wall, @zone)] if utc == 'Z'

        tzid = params['TZID']
        return [:time, wall] if tzid.nil? || tzid == @tz

        [:time, wall_of(instant_of(wall, zone(tzid)), @zone)]
      end

      # @param name [String]
      # @return [TZInfo::Timezone, Integer, nil] an Olson zone, a fixed offset
      #   in seconds, or +nil+ for a UTC or floating time (stored as if UTC).
      def zone(name)
        case name
        when '', 'floating', 'UTC', 'Z' then nil
        when /\AGMT([+-])(\d{2})(\d{2})\z/ then (Regexp.last_match(1) == '-' ? -1 : 1) *
                                                ((Regexp.last_match(2).to_i * 3600) + (Regexp.last_match(3).to_i * 60))
        else TZInfo::Timezone.get(name)
        end
      rescue TZInfo::InvalidTimezoneIdentifier
        raise Unexpandable, "unknown time zone #{name}"
      end

      # @param instant [Time]
      # @param zone [TZInfo::Timezone, Integer, nil]
      # @return [Time] the local time in +zone+, labelled UTC.
      def wall_of(instant, zone)
        case zone
        when nil then instant.getutc
        when Integer then Time.at(instant.to_i + zone).utc
        else
          local = zone.to_local(instant)
          Time.utc(local.year, local.month, local.day, local.hour, local.min, local.sec)
        end
      end

      # A local time DST skipped (02:30 on a spring-forward night) moves an
      # hour on, as RFC 5545 says; one that happens twice takes the first.
      #
      # @param wall [Time] the local time in +zone+, labelled UTC.
      # @param zone [TZInfo::Timezone, Integer, nil]
      # @return [Time] the UTC instant.
      def instant_of(wall, zone)
        case zone
        when nil then wall
        when Integer then Time.at(wall.to_i - zone).utc
        else
          begin
            zone.local_to_utc(wall) { |periods| periods.first }.utc
          rescue TZInfo::PeriodNotFound
            zone.local_to_utc(wall + 3600) { |periods| periods.first }.utc
          end
        end
      end
    end
  end
end
