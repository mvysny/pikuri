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
    # * mail search + read + contact search — registered only when the Gloda
    #   index exists (the +available?+-probed gate, like +pikuri-os+'s
    #   file-index tools). Contact search is a pure read that resolves a name
    #   to addresses; it rides Gloda's presence, not the +compose:+ flag.
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
    # By default this is the v1 (search-only, no-egress) surface. The two v2
    # outbound tools are each *opt-in* because each adds an egress leg, so
    # leaving them off by default is what keeps a bundled inbound-only wiring's
    # trifecta broken by construction:
    #
    # * +compose: true+ wires +thunderbird_mail_compose+ (a hand-off to a
    #   compose window the human Sends from — see {MailCompose}).
    # * +create_calendar_event: true+ wires +thunderbird_calendar_create+ (a
    #   hand-off to Thunderbird's import wizard the human confirms — see
    #   {CalendarCreate}).
    #
    # Both are human-gated hand-offs — pikuri writes nothing to Thunderbird's
    # stores and sends/imports nothing itself (+DESIGN.md+,
    # +ideas/thunderbird.md+).
    class Extension
      include Pikuri::Agent::Extension

      LOGGER = Pikuri.logger_for('Thunderbird::Extension')

      # @param profile_dir [String, nil] explicit Thunderbird profile
      #   directory; +nil+ auto-discovers (snap then apt root).
      # @param cache_dir [String, nil] base dir for the snapshot copies;
      #   +nil+ mints a fresh per-process {Pikuri::Paths.new_temp} (reaped at
      #   exit), so two concurrent pikuri-thunderbird processes never share — and
      #   overwrite — one snapshot path. Mail and calendar snapshots live in
      #   +mail/+ and +calendar/+ subdirs of it.
      # @param compose [Boolean] wire the outbound +thunderbird_mail_compose+
      #   tool (default +false+). Opt-in because it adds an egress leg; the draft
      #   is still human-committed in Thunderbird's compose window.
      # @param create_calendar_event [Boolean] wire the outbound
      #   +thunderbird_calendar_create+ tool (default +false+). Opt-in for the
      #   same reason; the event is still human-committed in Thunderbird's
      #   import wizard.
      # @param thunderbird_bin [String] the Thunderbird executable for the
      #   outbound hand-offs (PATH name or absolute path); ignored unless
      #   +compose:+ or +create_calendar_event:+ is on. Mirrors +profile_dir:+'s
      #   override role.
      # @return [Extension]
      def initialize(profile_dir: nil, cache_dir: nil, compose: false, create_calendar_event: false,
                     thunderbird_bin: 'thunderbird')
        @profile_dir = profile_dir
        @cache_base = cache_dir || Paths.new_temp.to_s
        @compose = compose
        @create_calendar_event = create_calendar_event
        @thunderbird_bin = thunderbird_bin
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

        contacts = wire_mail(c, profile)
        wire_calendar(c, profile)
        # Neither outbound tool needs Gloda (only a Thunderbird binary); the
        # contacts resolver, when present, powers compose's recipient-novelty
        # warn and is nil otherwise.
        c.add_tool MailCompose.new(thunderbird_bin: @thunderbird_bin, backend: contacts) if @compose
        if @create_calendar_event
          c.add_tool CalendarCreate.new(profile: profile, thunderbird_bin: @thunderbird_bin)
        end
        nil
      end

      private

      # @return [Gloda::Contacts, nil] the contact resolver over the wired
      #   Gloda backend, or +nil+ when the index is absent (mail tools then
      #   omitted). Compose's novelty warn rides this same resolver.
      def wire_mail(c, profile)
        gloda = Gloda.new(gloda_path: profile.gloda_path, cache_dir: File.join(@cache_base, 'mail'))
        unless gloda.available?
          LOGGER.info("Gloda index absent (#{profile.gloda_path}); mail tools disabled.")
          return nil
        end

        mail = Gloda::Mail.new(gloda: gloda)
        contacts = Gloda::Contacts.new(gloda: gloda)
        c.add_tool MailSearch.new(backend: mail)
        c.add_tool MailRead.new(backend: mail)
        # A pure read, and useful on its own ("what's Jon's address?"), so it
        # rides Gloda's presence rather than the egress-gated compose flag.
        c.add_tool ContactSearch.new(backend: contacts)
        c.on_close { gloda.close }
        contacts
      end

      # @return [void]
      def wire_calendar(c, profile)
        calendar = Calendar.new(calendar_dbs: profile.calendar_dbs,
                                cache_dir: File.join(@cache_base, 'calendar'))
        c.add_tool CalendarSearch.new(backend: calendar)
        c.add_tool CalendarRead.new(backend: calendar)
        c.on_close { calendar.close }
      end
    end
  end
end
