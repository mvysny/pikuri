# frozen_string_literal: true

require 'fileutils'
require 'open3'

module Pikuri
  module Demo
    # Where the demo goes, and the guard that keeps the build away from
    # anyone's real mail and files.
    #
    # The testbed is for pikuri's developers, on a machine that holds no
    # Thunderbird data of its own (the dev VM). The demo profile is
    # Thunderbird's only profile, registered +Default=1+ in +profiles.ini+, so
    # pikuri's auto-discovery and the hand-offs' plain +thunderbird <arg>+ both
    # land in it; the documents go to +~/Documents+, the secretary's default.
    #
    # Every demo directory carries a marker file, {MARKER}. The build refuses
    # while either Thunderbird root holds a profile without it, while
    # +~/Documents+ is non-empty and unmarked, or while Thunderbird runs. It
    # never deletes an unmarked directory and never offers to.
    class Target
      # The marker every demo directory carries.
      MARKER = '.pikuri-demo'

      # Thunderbird's two install roots, as pikuri's +Profile+ probes them.
      ROOTS = {
        snap: File.expand_path('~/snap/thunderbird/common/.thunderbird'),
        apt: File.expand_path('~/.thunderbird')
      }.freeze

      # The profile's directory name.
      PROFILE_NAME = 'pikuri-demo'

      # Raised when the guard finds something that isn't a demo, or a
      # running Thunderbird.
      class Refused < StandardError; end

      # @return [String] absolute profile directory.
      attr_reader :profile_dir

      # @return [String] absolute demo documents directory.
      attr_reader :documents_dir

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
        @documents_dir = File.expand_path('~/Documents')
      end

      # Raises before anything is written.
      #
      # @return [void]
      # @raise [Refused] naming every unmarked profile or directory found,
      #   or the running Thunderbird's pids.
      def guard!
        pids = self.class.running_pids
        raise Refused, "Thunderbird is running (pid #{pids.join(', ')}); quit it first." unless pids.empty?

        unmarked = ROOTS.values.flat_map { |root| profiles_in(root) }.reject { |p| marked?(p) }
        unless unmarked.empty?
          raise Refused, "Found a Thunderbird profile that isn't a pikuri demo:\n  " \
                         "#{unmarked.join("\n  ")}\n" \
                         'The testbed is for a machine with no Thunderbird data of its own.'
        end
        return if !File.exist?(@documents_dir) || marked?(@documents_dir) || Dir.empty?(@documents_dir)

        raise Refused, "#{@documents_dir} is not a pikuri demo (no #{MARKER}) and not empty. " \
                       'The demo build never overwrites it; move it aside.'
      end

      # Wipes a previous demo, creates both directories afresh, marked, and
      # registers the profile. Call after {#guard!}.
      #
      # @return [void]
      def prepare!
        [@profile_dir, @documents_dir].each do |dir|
          FileUtils.rm_rf(dir) if marked?(dir)
          FileUtils.mkdir_p(dir, mode: 0o700)
          File.write(File.join(dir, MARKER), "A pikuri demo. Holds no real mail or files.\n")
        end
        write_profiles_ini
      end

      private

      # @param path [String]
      # @return [Boolean]
      def marked?(path) = File.file?(File.join(path, MARKER))

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
