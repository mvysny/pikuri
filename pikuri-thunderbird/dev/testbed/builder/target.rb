# frozen_string_literal: true

require 'fileutils'
require 'open3'

module Pikuri
  module Demo
    # Where the demo profile goes, and the guard that keeps the build away
    # from anyone's real mail. The demo +~/Documents+ is {Home}'s.
    #
    # The testbed is for pikuri's developers, on a machine that holds no
    # Thunderbird data of its own (the dev VM). The demo profile is
    # Thunderbird's only profile, registered +Default=1+ in +profiles.ini+, so
    # pikuri's auto-discovery and the hand-offs' plain +thunderbird <arg>+ both
    # land in it.
    #
    # The profile carries {Home::MARKER}. The build refuses while either
    # Thunderbird root holds a profile without it, or while Thunderbird runs.
    # It never deletes an unmarked directory and never offers to.
    class Target
      # Thunderbird's two install roots, as pikuri's +Profile+ probes them.
      ROOTS = {
        snap: File.expand_path('~/snap/thunderbird/common/.thunderbird'),
        apt: File.expand_path('~/.thunderbird')
      }.freeze

      # The profile's directory name.
      PROFILE_NAME = 'pikuri-demo'

      # Raised when the guard finds a profile that isn't a demo, or a
      # running Thunderbird. The same class as {Home::Refused}, so one rescue
      # covers both guards.
      Refused = Home::Refused

      # @return [String] absolute profile directory.
      attr_reader :profile_dir

      # @return [Array<Integer>] pids of running Thunderbirds (the snap's
      #   and the tarball's +thunderbird-bin+, a distro's +thunderbird+).
      def self.running_pids
        # Two exact names, not one regex: pgrep matches the 15-character
        # process name and warns about any longer pattern.
        %w[thunderbird thunderbird-bin].flat_map do |name|
          out, _err, status = Open3.capture3('pgrep', '-x', name)
          status.success? ? out.split.map(&:to_i) : []
        end
      end

      # @return [String] the +thunderbird+ found on +PATH+.
      # @raise [Refused] when there is none.
      def self.thunderbird_path
        ENV.fetch('PATH', '').split(':').map { |d| File.join(d, 'thunderbird') }
           .find { |p| File.executable?(p) } or raise Refused, 'no thunderbird on PATH'
      end

      def initialize
        # The snap's root when Thunderbird is the snap (+/snap/bin/…+, a
        # symlink to +/usr/bin/snap+, so the unresolved path tells).
        root = self.class.thunderbird_path.start_with?('/snap/') ? ROOTS[:snap] : ROOTS[:apt]
        @profile_dir = File.join(root, PROFILE_NAME)
      end

      # Raises before anything is written.
      #
      # @return [void]
      # @raise [Refused] naming every unmarked profile found, or the running
      #   Thunderbird's pids.
      def guard!
        pids = self.class.running_pids
        raise Refused, "Thunderbird is running (pid #{pids.join(', ')}); quit it first." unless pids.empty?

        unmarked = ROOTS.values.flat_map { |root| profiles_in(root) }.reject { |p| Home.marked?(p) }
        return if unmarked.empty?

        raise Refused, "Found a Thunderbird profile that isn't a pikuri demo:\n  " \
                       "#{unmarked.join("\n  ")}\n" \
                       'The testbed is for a machine with no Thunderbird data of its own.'
      end

      # Wipes a previous demo, creates the profile directory afresh, marked,
      # and registers it. Call after {#guard!}.
      #
      # @return [void]
      def prepare!
        FileUtils.rm_rf(@profile_dir) if Home.marked?(@profile_dir)
        FileUtils.mkdir_p(@profile_dir, mode: 0o700)
        File.write(File.join(@profile_dir, Home::MARKER), "A pikuri demo. Holds no real mail.\n")
        write_profiles_ini
      end

      private

      # Every profile under +root+: the ones +profiles.ini+ lists, plus any
      # child dir that looks like one, so an unlisted profile is caught too.
      #
      # @param root [String]
      # @return [Array<String>]
      def profiles_in(root)
        return [] unless File.directory?(root)

        listed = listed_profiles(root)
        found = Dir.children(root).map { |c| File.join(root, c) }.select { |p| profile_like?(p) }
        (listed + found).uniq
      end

      # @param root [String]
      # @return [Array<String>] the +Path=+ entries of +root/profiles.ini+.
      def listed_profiles(root)
        ini = File.join(root, 'profiles.ini')
        return [] unless File.file?(ini)

        entries = File.read(ini).split(/^\[/).filter_map do |section|
          path = section[/^Path=(.*)$/, 1]&.strip or next
          absolute = section[/^IsRelative=(\d)/, 1] == '0'
          absolute ? File.expand_path(path) : File.join(root, path)
        end
        entries.select { |p| File.directory?(p) }
      end

      # @param path [String]
      # @return [Boolean]
      def profile_like?(path)
        File.directory?(path) &&
          %w[prefs.js global-messages-db.sqlite Mail ImapMail].any? { |f| File.exist?(File.join(path, f)) }
      end

      # @return [void]
      def write_profiles_ini
        File.write(File.join(File.dirname(@profile_dir), 'profiles.ini'), <<~INI)
          [Profile0]
          Name=#{PROFILE_NAME}
          IsRelative=1
          Path=#{PROFILE_NAME}
          Default=1

          [General]
          StartWithLastProfile=1
          Version=2
        INI
      end
    end
  end
end
