# frozen_string_literal: true

module Pikuri
  module Thunderbird
    # The +thunderbird_calendar_read+ tool — the read half of the calendar
    # search→read pair. Given an +event_id+ from
    # +thunderbird_calendar_search+, returns the full event: when, where,
    # status, attendees (with RSVP), and description. Inbound-only.
    #
    # Sharing: +P_shared_locked+ — no state of its own, and the {Calendar}
    # backend it queries locks; see that class's +== Sharing+.
    class CalendarRead < Pikuri::Tool
      # @return [Integer] max attendees listed individually; beyond it the list
      #   truncates to a per-status tally so a 169-guest all-hands can't flood
      #   the observation.
      ATTENDEE_CAP = 40

      # @return [Hash{String=>String}] PARTSTAT → human RSVP word.
      STATUS_LABELS = {
        'ACCEPTED' => 'accepted', 'DECLINED' => 'declined',
        'TENTATIVE' => 'tentative', 'NEEDS-ACTION' => 'no reply'
      }.freeze

      # @return [String] opencode-shape description.
      DESCRIPTION = <<~DESC
        Read one Thunderbird calendar event in full (title, when, where, status, attendees with their RSVP, and description).

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
          },
          trifecta_legs: Pikuri::Thunderbird::INBOUND_LEGS
        )
      end

      # @return [String] formatted event or +"Error: …"+.
      def self.run_read(backend:, event_id:)
        ev = backend.read(event_id:)
        return "Error: no event found with id #{event_id.inspect}." unless ev

        desc = ev[:description].to_s.strip
        [
          "Title: #{ev[:title]}",
          "When: #{DateHelpers.when_label(ev)}",
          "Where: #{ev[:location].to_s.strip.empty? ? '(none)' : ev[:location].strip}",
          "Status: #{ev[:status] || '(none)'}",
          *attendee_lines(ev[:attendees]),
          '',
          desc.empty? ? '(no description)' : desc
        ].join("\n")
      end

      # The +Organizer:+ + +Attendees:+ block, or +[]+ when the event has no
      # guests. Individual guests list up to {ATTENDEE_CAP}; past it the tail
      # collapses to a per-status tally.
      #
      #   Organizer: Alice Organizer <alice@example.com>
      #   Attendees (3):
      #     - Bob Guest <bob@example.com> — no reply
      #     - Alice Organizer <alice@example.com> — accepted
      #     - carol@example.com — tentative (optional)
      #
      # @param people [Array<IcalLine::Attendee>, nil] +Calendar#read+'s +:attendees+.
      # @return [Array<String>]
      def self.attendee_lines(people)
        people = Array(people)
        return [] if people.empty?

        lines = []
        org = people.find(&:organizer?)
        lines << "Organizer: #{who(org)}" if org
        guests = people.reject(&:organizer?)
        return lines if guests.empty?

        lines << "Attendees (#{guests.size}):"
        guests.first(ATTENDEE_CAP).each { |g| lines << "  - #{guest_line(g)}" }
        lines << "  … and #{guests.size - ATTENDEE_CAP} more (#{tally(guests)})" if guests.size > ATTENDEE_CAP
        lines
      end
      private_class_method :attendee_lines

      # @param person [IcalLine::Attendee]
      # @return [String] +"Name <email>"+, or bare email when there's no
      #   distinct display name.
      def self.who(person)
        name = person.name.to_s.strip
        email = person.email.to_s.strip
        name.empty? || name == email ? email : "#{name} <#{email}>"
      end
      private_class_method :who

      # @param guest [IcalLine::Attendee]
      # @return [String] one attendee: who + RSVP + optional/resource markers.
      def self.guest_line(guest)
        line = +"#{who(guest)} — #{status_label(guest)}"
        line << ' (optional)' if guest.optional?
        line << ' [resource]' if guest.resource?
        line
      end
      private_class_method :guest_line

      # @param guest [IcalLine::Attendee]
      # @return [String] human RSVP word (unknown PARTSTAT downcased; a missing
      #   one is Google's implicit "no reply").
      def self.status_label(guest)
        STATUS_LABELS[guest.status] || guest.status&.downcase || 'no reply'
      end
      private_class_method :status_label

      # @return [String] +"12 accepted, 3 declined, 40 no reply"+ over all guests.
      def self.tally(guests)
        guests.group_by { |g| status_label(g) }.map { |label, gs| "#{gs.size} #{label}" }.join(', ')
      end
      private_class_method :tally
    end
  end
end
