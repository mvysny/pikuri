# frozen_string_literal: true

require 'time'

module Pikuri
  module Thunderbird
    # Shared presentation helpers turning backend records into the compact,
    # LLM-facing text the tools emit. Kept out of {Gloda}/{Calendar} so those
    # stay pure data accessors (raw {Time}s + tz strings), and out of the
    # tool classes so mail/calendar render dates identically.
    module Format
      # Human "when" for a calendar event. All-day events render as a date
      # (or date range, honoring the iCal exclusive DTEND); timed events
      # render in the *machine's* local zone with the event's own tzid
      # appended — a correct-in-the-common-case heuristic (TB host zone ==
      # user zone == dominant event zone), with the tzid shown so a
      # cross-zone event is legible.
      #
      # @param event [Hash] a {Calendar} record (+:start+, +:end+, +:all_day+,
      #   +:start_tz+).
      # @return [String]
      def self.when_label(event)
        return '(no date)' unless event[:start]

        event[:all_day] ? all_day_label(event) : timed_label(event)
      end

      # @param time [Time, nil]
      # @return [String] +"YYYY-MM-DD HH:MM"+ (local), or +"?"+.
      def self.short_datetime(time)
        time ? time.getlocal.strftime('%Y-%m-%d %H:%M') : '?'
      end

      # @return [String]
      def self.all_day_label(event)
        start_date = event[:start].strftime('%Y-%m-%d')
        return start_date unless event[:end]

        last = (event[:end] - 86_400).strftime('%Y-%m-%d') # DTEND is exclusive
        last == start_date ? start_date : "#{start_date} – #{last}"
      end
      private_class_method :all_day_label

      # @return [String]
      def self.timed_label(event)
        tz = event[:start_tz].to_s
        suffix = tz.empty? ? '' : " (#{tz})"
        "#{event[:start].getlocal.strftime('%Y-%m-%d %H:%M')}#{suffix}"
      end
      private_class_method :timed_label

      # Parse a user/LLM-supplied date or datetime string to a {Time}.
      #
      # @param str [String, nil]
      # @return [Time, nil] +nil+ when +str+ is blank.
      # @raise [ArgumentError] on an unparseable non-blank string.
      def self.parse_time(str)
        return nil if str.nil? || str.to_s.strip.empty?

        Time.parse(str.to_s)
      end
    end
  end
end
