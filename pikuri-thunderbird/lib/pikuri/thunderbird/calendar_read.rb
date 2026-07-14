# frozen_string_literal: true

module Pikuri
  module Thunderbird
    # The +thunderbird_calendar_read+ tool — the read half of the calendar
    # search→read pair. Given an +event_id+ from
    # +thunderbird_calendar_search+, returns the full event: when, where,
    # status, and description. Inbound-only.
    class CalendarRead < Pikuri::Tool
      # @return [String] opencode-shape description.
      DESCRIPTION = <<~DESC
        Read one Thunderbird calendar event in full (title, when, where, status, description).

        Usage:
        - Pass the id from a thunderbird_calendar_search result.
      DESC

      # @param backend [Calendar] the calendar backend.
      # @return [CalendarRead]
      def initialize(backend:)
        @backend = backend
        super(
          name: 'thunderbird_calendar_read',
          description: DESCRIPTION,
          parameters: Parameters.build { |p|
            p.required_string :event_id, 'The id from a search result, e.g. "abc123-uid".'
          },
          execute: lambda { |event_id:|
            CalendarRead.run_read(backend: @backend, event_id:)
          }
        )
      end

      # @return [String] formatted event or +"Error: …"+.
      def self.run_read(backend:, event_id:)
        ev = backend.read(event_id:)
        return "Error: no event found with id #{event_id.inspect}." unless ev

        desc = ev[:description].to_s.strip
        <<~EV.chomp
          Title: #{ev[:title]}
          When: #{Format.when_label(ev)}
          Where: #{ev[:location].to_s.strip.empty? ? '(none)' : ev[:location].strip}
          Status: #{ev[:status] || '(none)'}

          #{desc.empty? ? '(no description)' : desc}
        EV
      end
    end
  end
end
