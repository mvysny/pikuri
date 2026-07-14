# frozen_string_literal: true

require 'fileutils'

module Pikuri
  module Thunderbird
    # One-call wiring for local Thunderbird mail + calendar. Adding this
    # extension to an +Agent.new+ block discovers the active Thunderbird
    # profile and registers the inbound-only tools:
    #
    #   Pikuri::Agent.new(...) do |c|
    #     c.add_extension Pikuri::Thunderbird::Extension.new
    #   end
    #
    # * mail search + read — registered only when the Gloda index exists
    #   (the +available?+-probed gate, like +pikuri-os+'s file-index tools).
    # * calendar search + read — registered *whenever a profile is found*,
    #   even with nothing cached: the empty state is self-explaining (the
    #   tool tells the user to enable Offline Support — Q6), which a bare
    #   "not registered" could not.
    #
    # When Thunderbird isn't installed ({Profile.discover} returns +nil+),
    # nothing is registered and the agent still constructs. An *ambiguous*
    # install (profiles under two roots) raises from {Profile.discover} —
    # loud, with the fix — rather than guessing.
    #
    # This is the v1 (search-only, no-egress) surface. Compose /
    # create-event are deliberately absent: they are egress and belong to a
    # future v2 as human-gated hand-offs to Thunderbird's own UI (see
    # +DESIGN.md+ / +ideas/thunderbird.md+).
    class Extension
      include Pikuri::Agent::Extension

      LOGGER = Pikuri.logger_for('Thunderbird::Extension')

      # @param profile_dir [String, nil] explicit Thunderbird profile
      #   directory; +nil+ auto-discovers (snap then apt root).
      # @param cache_dir [String, nil] base dir for the snapshot copies;
      #   defaults to +$XDG_CACHE_HOME/pikuri/thunderbird+ (or
      #   +~/.cache/pikuri/thunderbird+). Mail and calendar snapshots live in
      #   +mail/+ and +calendar/+ subdirs.
      # @return [Extension]
      def initialize(profile_dir: nil, cache_dir: nil)
        @profile_dir = profile_dir
        @cache_base = cache_dir || default_cache_base
      end

      # @param c [Pikuri::Agent::Configurator]
      # @return [void]
      # @raise [Profile::DiscoveryError] on an ambiguous install (fail loud).
      def configure(c)
        profile = Profile.discover(profile_dir: @profile_dir)
        unless profile
          LOGGER.info('no Thunderbird profile found; thunderbird_* tools disabled on this host.')
          return
        end

        wire_mail(c, profile)
        wire_calendar(c, profile)
        nil
      end

      private

      # @return [void]
      def wire_mail(c, profile)
        gloda = Gloda.new(gloda_path: profile.gloda_path, cache_dir: File.join(@cache_base, 'mail'))
        unless gloda.available?
          LOGGER.info("Gloda index absent (#{profile.gloda_path}); mail tools disabled.")
          return
        end

        c.add_tool MailSearch.new(backend: gloda)
        c.add_tool MailRead.new(backend: gloda)
        c.on_close { gloda.close }
      end

      # @return [void]
      def wire_calendar(c, profile)
        calendar = Calendar.new(calendar_dbs: profile.calendar_dbs,
                                cache_dir: File.join(@cache_base, 'calendar'))
        c.add_tool CalendarSearch.new(backend: calendar)
        c.add_tool CalendarRead.new(backend: calendar)
        c.on_close { calendar.close }
      end

      # @return [String]
      def default_cache_base
        base = ENV['XDG_CACHE_HOME']
        base = File.expand_path('~/.cache') if base.nil? || base.empty?
        File.join(base, 'pikuri', 'thunderbird')
      end
    end
  end
end
