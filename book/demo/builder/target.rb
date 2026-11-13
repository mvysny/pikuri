# frozen_string_literal: true

require 'fileutils'

module Pikuri
  module Demo
    # Where the demo profile goes, and the guard that keeps the build away
    # from anyone's real mail.
    #
    # Every demo profile carries a marker file, {MARKER}. The build refuses to
    # run while either Thunderbird root holds a profile *without* it, and in
    # +--dir+ mode refuses a non-empty target without it. It never deletes an
    # unmarked profile and never offers to: it prints the paths and stops.
    #
    # Two modes:
    #
    # * *registered* (the VM default): the profile lives in the installed
    #   Thunderbird's root and +profiles.ini+ names it +Default=1+, so pikuri's
    #   own auto-discovery finds it.
    # * *dir* (a reader, beside a real profile): the profile lives where the
    #   reader says, +profiles.ini+ is never touched, and Thunderbird and pikuri
    #   are both pointed at it explicitly.
    class Target
      # The marker every demo profile carries.
      MARKER = '.pikuri-demo'

      # Thunderbird's two install roots, as pikuri's +Profile+ probes them.
      ROOTS = {
        snap: File.expand_path('~/snap/thunderbird/common/.thunderbird'),
        apt: File.expand_path('~/.thunderbird')
      }.freeze

      # The profile's directory name in registered mode.
      PROFILE_NAME = 'pikuri-demo'

      # Raised when the guard finds something that isn't a demo.
      class Refused < StandardError; end

      # @return [String] absolute profile directory.
      attr_reader :dir

      # @param dir [String, nil] +--dir+ target; +nil+ for registered mode.
      # @return [Target]
      def self.for(dir:)
        dir ? new(dir: File.expand_path(dir), registered: false) : new(dir: registered_dir, registered: true)
      end

      # @return [String] the profile dir inside the installed Thunderbird's
      #   root: the snap one when Thunderbird is the snap (+/snap/bin/…+, a
      #   symlink to +/usr/bin/snap+, so the unresolved path tells).
      def self.registered_dir
        root = thunderbird_path.start_with?('/snap/') ? ROOTS[:snap] : ROOTS[:apt]
        File.join(root, PROFILE_NAME)
      end

      # @return [String] the +thunderbird+ found on +PATH+.
      # @raise [Refused] when there is none.
      def self.thunderbird_path
        ENV.fetch('PATH', '').split(':').map { |d| File.join(d, 'thunderbird') }
           .find { |p| File.executable?(p) } or raise Refused, 'no thunderbird on PATH'
      end

      # @param dir [String]
      # @param registered [Boolean]
      def initialize(dir:, registered:)
        @dir = dir
        @registered = registered
      end

      # @return [Boolean] whether +profiles.ini+ registers the profile.
      def registered? = @registered

      # Checks both roots and the target; raises before anything is written.
      #
      # @return [void]
      # @raise [Refused] naming every unmarked profile found.
      def guard!
        unmarked = ROOTS.values.flat_map { |root| profiles_in(root) }.reject { |p| marked?(p) }
        unless unmarked.empty?
          raise Refused, "Found a Thunderbird profile that isn't a pikuri demo:\n  " \
                         "#{unmarked.join("\n  ")}\n" \
                         'The demo build never touches one. Use --dir to build beside it.'
        end
        return if !File.exist?(@dir) || marked?(@dir) || Dir.empty?(@dir)

        raise Refused, "#{@dir} exists, isn't empty and isn't a pikuri demo (no #{MARKER}). " \
                       'Pick another --dir.'
      end

      # Wipes a previous demo at the target and creates it afresh, marked; in
      # registered mode also writes +profiles.ini+. Call after {#guard!}.
      #
      # @return [void]
      def prepare!
        FileUtils.rm_rf(@dir) if marked?(@dir)
        FileUtils.mkdir_p(@dir, mode: 0o700)
        File.write(File.join(@dir, MARKER), "A pikuri demo profile. Holds no real mail.\n")
        write_profiles_ini if @registered
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
        File.write(File.join(File.dirname(@dir), 'profiles.ini'), <<~INI)
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
