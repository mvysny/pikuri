# frozen_string_literal: true

require 'date'

module Pikuri
  module Demo
    # @param date [Date]
    # @param hhmm [String] e.g. "08:15".
    # @return [Time] that local time on +date+.
    def self.local_time(date, hhmm)
      hour, minute = hhmm.split(':').map { |s| Integer(s, 10) }
      Time.local(date.year, date.month, date.day, hour, minute)
    end

    # Everything the demo profile is built from, for one build day: the
    # mailbox (the scenes of +mail.yml+ plus {Noise}) and the calendar, over
    # the demo home's facts, and the demo home's documents the mail's
    # attachments are taken from.
    class Content
      # @return [Documents]
      attr_reader :documents

      # @param today [Date]
      # @param tzid [String] the IANA zone of the calendar's times.
      # @param converter [Converter]
      def initialize(today:, tzid:, converter:)
        facts = Facts.new(today: today)
        @calendar = Calendar.new(facts: facts, tzid: tzid)
        @documents = Documents.new(facts: facts, converter: converter)
        @scenes = Scenes.new(facts: facts, calendar: @calendar, documents: @documents, converter: converter)
        @noise = Noise.new(facts: facts)
      end

      # @return [Hash{String => Array<Mail::Message>}] mbox name to messages.
      def folders
        @folders ||= @scenes.folders.merge(@noise.folders) { |_, scenes, noise| scenes + noise }
      end

      # @return [Integer] one per copy: a message in two folders counts twice,
      #   as Gloda gives it two rows.
      def message_count = folders.values.sum(&:size)

      # @return [Integer]
      def event_count = @calendar.event_count

      # @return [String] the calendar Thunderbird syncs.
      def ics = @calendar.ics
    end
  end
end
