# frozen_string_literal: true

require 'date'
require 'mail'

module Pikuri
  module Demo
    # The demo mailbox and calendar, dated relative to +today+ so "what's on
    # Thursday?" and "due in five days" stay true whenever it is built.
    #
    # For now a small seed that proves the pipeline: one of each thing the
    # stores must hold (a thread chained by +In-Reply-To+, the owner's reply in
    # Sent, an RFC 2231 attachment name, an HTML-only newsletter; a timed, an
    # all-day and a recurring event). The scene messages replace it.
    class Content
      # The owner, as the account in {UserJs} names them.
      OWNER = 'Alex Novak <alex@novak.example>'

      # @param today [Date]
      # @param tzid [String] the IANA zone the calendar's times are in.
      def initialize(today:, tzid:)
        @today = today
        @tzid = tzid
      end

      # @return [Hash{String => Array<Mail::Message>}] mbox name to messages.
      def folders
        @folders ||= { 'Inbox' => inbox, 'Sent' => sent }
      end

      # @return [Integer]
      def message_count = folders.values.sum(&:size)

      # @return [Integer] VEVENTs in {#ics}.
      def event_count = events.size

      # @return [String] the calendar as an iCalendar file.
      def ics
        lines = ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//pikuri//demo//EN', *events.flatten, 'END:VCALENDAR']
        "#{lines.join("\r\n")}\r\n"
      end

      private

      # @return [Array<Mail::Message>]
      def inbox
        [
          mail(from: 'Billing <billing@acme-accounting.example>', days_ago: 2, hour: 8,
               id: 'inv-117@acme-accounting.example',
               subject: 'Pripomienka: faktúra 2026-117',
               body: "Hello Alex,\n\ninvoice 2026-117 (EUR 1 240.00) is due on " \
                     "#{(@today + 5).strftime('%-d %B')}.\n\nRegards,\nAcme Accounting\n") do |m|
            m.add_file(filename: 'faktúra_č.117.csv', content: "item,amount\nconsulting,1240.00\n")
          end,
          mail(from: 'Mira Koskinen <mira@lumo-studio.example>', days_ago: 4, hour: 9,
               id: 'plan-1@lumo-studio.example', subject: 'Planning call next week?',
               body: "Hi Alex,\n\ncould we do the planning call next Thursday at 10?\n\nMira\n"),
          mail(from: 'Mira Koskinen <mira@lumo-studio.example>', days_ago: 3, hour: 14,
               id: 'plan-3@lumo-studio.example', subject: 'Re: Planning call next week?',
               reply_to: %w[plan-1@lumo-studio.example plan-2@novak.example],
               body: "Great, sending an invite.\n\n> Thursday at 10 works.\n"),
          html_mail(from: 'Lumo Weekly <news@lumo-studio.example>', days_ago: 1, hour: 6,
                    id: 'weekly-46@lumo-studio.example', subject: 'Lumo Weekly: colour and light',
                    html: '<h1>Lumo Weekly</h1><p>This week: <b>colour and light</b>.</p>')
        ]
      end

      # @return [Array<Mail::Message>]
      def sent
        [
          mail(from: OWNER, to: 'Mira Koskinen <mira@lumo-studio.example>', days_ago: 4, hour: 11,
               id: 'plan-2@novak.example', subject: 'Re: Planning call next week?',
               reply_to: %w[plan-1@lumo-studio.example],
               body: "Thursday at 10 works.\n\nAlex\n\n> could we do the planning call next Thursday at 10?\n")
        ]
      end

      # @return [Array<Array<String>>] each event's VEVENT lines.
      def events
        thursday = @today + ((4 - @today.wday) % 7)
        [
          event('planning@novak.example', 'Planning call with Mira', thursday, 10, 11),
          event('standup@novak.example', 'Team standup', @today - 7, 9, 9.25, rrule: 'FREQ=WEEKLY;BYDAY=MO,WE,FR'),
          ['BEGIN:VEVENT', 'UID:invoice-due@novak.example', stamp,
           "DTSTART;VALUE=DATE:#{(@today + 5).strftime('%Y%m%d')}",
           "DTEND;VALUE=DATE:#{(@today + 6).strftime('%Y%m%d')}",
           'SUMMARY:Invoice 2026-117 due', 'END:VEVENT']
        ]
      end

      # @return [Array<String>]
      def event(uid, summary, day, from_hour, to_hour, rrule: nil)
        ['BEGIN:VEVENT', "UID:#{uid}", stamp,
         "DTSTART;TZID=#{@tzid}:#{ical_time(day, from_hour)}",
         "DTEND;TZID=#{@tzid}:#{ical_time(day, to_hour)}",
         *("RRULE:#{rrule}" if rrule), "SUMMARY:#{summary}", 'END:VEVENT']
      end

      # @return [String]
      def stamp = "DTSTAMP:#{@today.strftime('%Y%m%d')}T000000Z"

      # @param hour [Numeric] fractional hours allowed (9.25 = 09:15).
      # @return [String]
      def ical_time(day, hour)
        format('%<d>sT%<h>02d%<m>02d00', d: day.strftime('%Y%m%d'), h: hour.floor, m: ((hour % 1) * 60).round)
      end

      # @return [Mail::Message] a plain-text mail.
      def mail(from:, days_ago:, hour:, id:, subject:, body:, to: OWNER, reply_to: [], &block)
        date = local_time(days_ago, hour)
        message = Mail.new do
          from from
          to to
          date date
          message_id "<#{id}>"
          subject subject
          unless reply_to.empty?
            in_reply_to "<#{reply_to.last}>"
            references reply_to.map { |r| "<#{r}>" }.join(' ')
          end
        end
        message.charset = 'UTF-8'
        if block
          message.text_part = Mail::Part.new { body body }
          message.text_part.charset = 'UTF-8'
          block.call(message)
          # Mail picks a random boundary; a fixed one keeps the inputs, and so
          # the cache key, the same from build to build.
          boundary = "=_pikuri_#{id}"
          message.content_type = message.content_type.sub(/boundary="?[^";]+"?/, %(boundary="#{boundary}"))
          message.body.boundary = boundary
        else
          message.body = body
        end
        message
      end

      # @return [Mail::Message] an HTML-only mail, the way newsletters come.
      def html_mail(from:, days_ago:, hour:, id:, subject:, html:)
        message = mail(from: from, days_ago: days_ago, hour: hour, id: id, subject: subject, body: html)
        message.content_type = 'text/html; charset=UTF-8'
        message
      end

      # @return [Time]
      def local_time(days_ago, hour)
        day = @today - days_ago
        Time.local(day.year, day.month, day.day, hour)
      end
    end
  end
end
