# frozen_string_literal: true

require 'fileutils'
require 'securerandom'

module Pikuri
  module Thunderbird
    # Locates the active Thunderbird profile on disk and derives the paths
    # the mail/calendar backends read. Discovery *never guesses*: it either
    # resolves one profile unambiguously, raises {DiscoveryError} with a
    # fix, or (when Thunderbird isn't installed) returns +nil+ so the
    # extension can simply omit the tools.
    #
    #   profile = Pikuri::Thunderbird::Profile.discover  # => Profile or nil
    #   profile&.gloda_path      # …/global-messages-db.sqlite
    #   profile&.gloda?          # is the Gloda index present?
    #   profile&.calendar_dir    # …/calendar-data
    #
    # Two install roots are probed, in this order: **snap**
    # (+~/snap/thunderbird/common/.thunderbird+, confirmed) and **apt**
    # (+~/.thunderbird+, recalled). Flatpak is out of scope. A profile with
    # no mail account (Thunderbird started once, its account wizard closed)
    # doesn't count. If *both* roots hold a profile with an account (a stale
    # apt profile left behind by an apt→snap migration is the common case),
    # discovery raises rather than guess which is live — the one-time fix
    # (delete the obsolete root) beats a liveness heuristic that guesses
    # wrong exactly there. An explicit +profile_dir:+ override bypasses all
    # of this.
    #
    # == Implementation details
    #
    # Roots are compared by +File.realpath+: started while +~/.thunderbird+
    # existed and its own root didn't, the snap launcher links
    # +~/snap/thunderbird/common/.thunderbird -> ~/.thunderbird+, so both
    # roots are one directory and one profile, found as +:snap+.
    #
    # Within a root, the active profile is the +profiles.ini+ section with
    # +Default=1+ (or the sole profile when there's exactly one and none is
    # marked default); +Path+ is resolved relative to the ini's directory
    # when +IsRelative=1+. The confirmed real-world ini has no +[Install…]+
    # sections (Firefox's per-install default mechanism), so the plain
    # +Default=1+ scan suffices.
    #
    # A mail account is a +mail.server.serverN.type+ in +prefs.js+ other
    # than +none+, which is Local Folders: every profile gets those on first
    # start, so a +Mail/+ directory proves nothing. Nor does a missing Gloda
    # index — a real profile has none until its first indexing finishes.
    class Profile
      # @return [String] snap install root (confirmed on a live box).
      SNAP_ROOT = File.expand_path('~/snap/thunderbird/common/.thunderbird')

      # @return [String] apt/deb install root (recalled).
      APT_ROOT = File.expand_path('~/.thunderbird')

      # @return [Hash{Symbol => String}] probed roots in preference order.
      ROOTS = { snap: SNAP_ROOT, apt: APT_ROOT }.freeze

      # Raised when discovery is ambiguous or an override is unusable — the
      # message names the offending paths and the fix. Not recoverable by
      # the LLM; it's a wiring/config problem for the human.
      class DiscoveryError < StandardError; end

      # @return [String] absolute path of the resolved profile directory.
      attr_reader :dir

      # @return [Symbol] +:snap+, +:apt+, or +:override+ — which root this
      #   came from. Drives {#outbox_dir} (snap confinement differs).
      attr_reader :variant

      # Discover the active profile, or return +nil+ when Thunderbird is not
      # installed (no +profiles.ini+ under any probed root).
      #
      # When every found profile lacks a mail account, the first root's wins,
      # so a fresh install is still found.
      #
      # @param profile_dir [String, nil] explicit override; when given, it is
      #   used verbatim (expanded) and the root scan is skipped.
      # @param roots [Hash{Symbol => String}] install roots to probe, in
      #   preference order; the spec points it at temp dirs.
      # @return [Profile, nil] the resolved profile, or +nil+ if none found.
      # @raise [DiscoveryError] if +profile_dir+ isn't a directory, if two
      #   roots hold a profile with a mail account, or if a root has several
      #   profiles and none is marked +Default=1+.
      def self.discover(profile_dir: nil, roots: ROOTS)
        return from_override(profile_dir) if profile_dir

        present = roots.select { |_, root| File.file?(File.join(root, 'profiles.ini')) }
                       .uniq { |_, root| File.realpath(root) }
                       .map { |variant, root| new(dir: resolve_within(root), variant: variant) }
        return nil if present.empty?

        live = present.select(&:mail_account?)
        if live.size > 1
          paths = live.map(&:dir).join(' and ')
          raise DiscoveryError,
                "Found Thunderbird profiles with mail accounts under two roots (#{paths}). " \
                'This usually means a stale profile from an old install. Delete the ' \
                'obsolete root, or pass profile_dir: to pick one explicitly.'
        end

        live.first || present.first
      end

      # @param dir [String] resolved profile directory (absolute).
      # @param variant [Symbol] originating root (+:snap+/+:apt+/+:override+).
      # @return [Profile]
      def initialize(dir:, variant:)
        @dir = dir
        @variant = variant
      end

      # @return [String] path to the Gloda full-text index DB.
      def gloda_path = File.join(@dir, 'global-messages-db.sqlite')

      # @return [Boolean] whether the Gloda index exists (the mail backend's
      #   +available?+ gate).
      def gloda? = File.file?(gloda_path)

      # @return [Boolean] whether Thunderbird keeps the Gloda index current:
      #   +false+ once its *Enable Global Search and Indexer* setting is off,
      #   which stops the indexer and leaves the file in place, frozen; +true+
      #   when +prefs.js+ is missing or doesn't say (the default is on).
      def gloda_indexing?
        return true unless File.file?(prefs_path)

        File.foreach(prefs_path, encoding: 'UTF-8').none? do |line|
          line.match?(/\Auser_pref\("mailnews\.database\.global\.indexer\.enabled",\s*false\);/)
        end
      end

      # @return [String] Thunderbird's preferences, which map each mail
      #   account to its store directory (see {MessageStore}).
      def prefs_path = File.join(@dir, 'prefs.js')

      # @return [Boolean] whether +prefs.js+ names an account beyond Local
      #   Folders; +false+ when there is no +prefs.js+.
      def mail_account?
        return false unless File.file?(prefs_path)

        File.foreach(prefs_path, encoding: 'UTF-8').any? do |line|
          line.match?(/\Auser_pref\("mail\.server\.server\d+\.type",\s*"(?!none")/)
        end
      end

      # @return [String] the calendar stores directory.
      def calendar_dir = File.join(@dir, 'calendar-data')

      # @return [String] cached network-calendar store (CalDAV etc.).
      def calendar_cache_db = File.join(calendar_dir, 'cache.sqlite')

      # @return [String] local ("storage") calendar store.
      def calendar_local_db = File.join(calendar_dir, 'local.sqlite')

      # @return [Array<String>] existing calendar DBs (cache first — it holds
      #   the CalDAV events; local holds storage calendars). Empty when the
      #   calendar-data dir has neither.
      def calendar_dbs
        [calendar_cache_db, calendar_local_db].select { |p| File.file?(p) }
      end

      # A directory a *snap-confined* Thunderbird can read a hand-off file
      # from. Snap's +home+ interface blocks hidden +$HOME+ dirs (so the
      # +~/.cache+ snapshot dir is unreadable by the confined app — see
      # +design/architecture.md+ § "Platform confinement"); we stage instead in
      # the variant's own readable root: the snap-owned data area for +:snap+
      # (readable regardless of the dotfile rule), the unconfined profile dir
      # for +:apt+/+:override+. {#stage} writes there.
      #
      # @return [String] +…/snap/thunderbird/common/pikuri-outbox+ or
      #   +<profile>/pikuri-outbox+.
      def outbox_dir
        base = @variant == :snap ? File.dirname(SNAP_ROOT) : @dir
        File.join(base, 'pikuri-outbox')
      end

      # Writes a hand-off file into {#outbox_dir}, reaped at process exit:
      #
      #   @launcher.launch(profile.stage(ics, 'ics'))  # …/pikuri-outbox/handoff-3f9c….ics
      #
      # Reap-at-exit, not immediately: Thunderbird reads the file when its
      # wizard or compose window opens, seconds after the hand-off, and the
      # human then takes their time while the session lives. A one-shot that
      # exits at once can out-race a *cold* Thunderbird start — best-effort,
      # as with the detached launch.
      #
      # @param content [String] the file's bytes.
      # @param ext [String] its extension, which tells Thunderbird what it is.
      # @return [String] the staged file's absolute path.
      def stage(content, ext)
        FileUtils.mkdir_p(outbox_dir, mode: 0o700)
        path = File.join(outbox_dir, "handoff-#{SecureRandom.hex(8)}.#{ext}")
        File.binwrite(path, content)
        Pikuri::Finalizers.register { FileUtils.rm_f(path) }
        path
      end

      # @param profile_dir [String]
      # @return [Profile]
      # @raise [DiscoveryError] if it isn't a directory.
      def self.from_override(profile_dir)
        dir = File.expand_path(profile_dir)
        unless File.directory?(dir)
          raise DiscoveryError, "profile_dir #{dir.inspect} is not a directory."
        end

        new(dir: dir, variant: :override)
      end
      private_class_method :from_override

      # @param root [String] an install root known to hold a profiles.ini.
      # @return [String] the resolved (absolute) profile directory.
      # @raise [DiscoveryError] on an unresolvable / ambiguous ini.
      def self.resolve_within(root)
        ini_path = File.join(root, 'profiles.ini')
        section = default_section(parse_ini(File.read(ini_path)), ini_path)
        path = section['Path'] or
          raise DiscoveryError, "#{ini_path}: chosen profile has no Path= key."

        # IsRelative defaults to relative; only an explicit 0 means absolute.
        section['IsRelative'] == '0' ? File.expand_path(path) : File.join(root, path)
      end
      private_class_method :resolve_within

      # Pick the active profile section: the one with +Default=1+, or the
      # sole profile when exactly one exists and none is marked default.
      #
      # @param sections [Hash{String => Hash}] parsed ini.
      # @param ini_path [String] for error messages.
      # @return [Hash{String => String}] the chosen +[ProfileN]+ section.
      # @raise [DiscoveryError] on zero profiles, or several with no default.
      def self.default_section(sections, ini_path)
        profiles = sections.select { |name, _| name.start_with?('Profile') }.values
        raise DiscoveryError, "#{ini_path}: no [Profile…] sections." if profiles.empty?

        default = profiles.find { |s| s['Default'] == '1' }
        return default if default
        return profiles.first if profiles.size == 1

        names = profiles.map { |s| s['Name'] || s['Path'] }.join(', ')
        raise DiscoveryError,
              "#{ini_path}: several profiles (#{names}) and none is Default=1. " \
              'Pass profile_dir: to pick one.'
      end
      private_class_method :default_section

      # Minimal INI parse: +[Section]+ headers + +key=value+ lines. Blank
      # lines and +;+/+#+ comments ignored; values keep their case.
      #
      # @param text [String]
      # @return [Hash{String => Hash{String => String}}]
      def self.parse_ini(text)
        sections = {}
        current = nil
        text.each_line do |line|
          line = line.strip
          next if line.empty? || line.start_with?(';', '#')

          if (m = line.match(/\A\[(.+)\]\z/))
            current = (sections[m[1]] ||= {})
          elsif current && (m = line.match(/\A([^=]+)=(.*)\z/))
            current[m[1].strip] = m[2].strip
          end
        end
        sections
      end
      private_class_method :parse_ini
    end
  end
end
