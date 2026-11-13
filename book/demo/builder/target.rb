# frozen_string_literal: true

require 'fileutils'

module Pikuri
  module Demo
    # Where the demo profile and the demo documents go, and the guard that
    # keeps the build away from anyone's real mail and files.
    #
    # Every demo directory carries a marker file, {MARKER}. The build refuses
    # to run while either Thunderbird root holds a profile *without* it, or
    # while a directory it would write is non-empty and unmarked. It never
    # deletes an unmarked directory and never offers to: it prints the paths
    # and stops.
    #
    # Two modes:
    #
    # * *registered* (the VM default): the profile lives in the installed
    #   Thunderbird's root and +profiles.ini+ names it +Default=1+, so pikuri's
    #   own auto-discovery finds it; the documents go to +~/Documents+, the
    #   secretary's default.
    # * *dir* (a reader, beside a real profile): one folder holds the whole
    #   demo, +profile/+ and +Documents/+; +profiles.ini+ is never touched, and
    #   Thunderbird and the secretary are pointed at it explicitly.
    class Target
      # The marker every demo directory carries.
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
      attr_reader :profile_dir

      # @return [String] absolute demo documents directory.
      attr_reader :documents_dir

      # @param dir [String, nil] +--dir+ target; +nil+ for registered mode.
      # @return [Target]
      def self.for(dir:)
        if dir
          dir = File.expand_path(dir)
          new(top: dir, profile_dir: File.join(dir, 'profile'), documents_dir: File.join(dir, 'Documents'))
        else
          new(top: nil, profile_dir: registered_dir, documents_dir: File.expand_path('~/Documents'))
        end
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

      # @param top [String, nil] the +--dir+ folder; +nil+ when registered.
      # @param profile_dir [String]
      # @param documents_dir [String]
      def initialize(top:, profile_dir:, documents_dir:)
        @top = top
        @profile_dir = profile_dir
        @documents_dir = documents_dir
      end

      # @return [Boolean] whether +profiles.ini+ registers the profile.
      def registered? = @top.nil?

      # Checks both roots and every directory the build writes; raises
      # before anything is written.
      #
      # @return [void]
      # @raise [Refused] naming every unmarked profile or directory found.
      def guard!
        unmarked = ROOTS.values.flat_map { |root| profiles_in(root) }.reject { |p| marked?(p) }
        unless unmarked.empty?
          raise Refused, "Found a Thunderbird profile that isn't a pikuri demo:\n  " \
                         "#{unmarked.join("\n  ")}\n" \
                         'The demo build never touches one. Use --dir to build beside it.'
        end
        blocked = owned_dirs.reject { |d| !File.exist?(d) || marked?(d) || Dir.empty?(d) }
        return if blocked.empty?

        raise Refused, "Not a pikuri demo (no #{MARKER}), and not empty:\n  #{blocked.join("\n  ")}\n" \
                       'The demo build never overwrites one. Move it aside, or use --dir.'
      end

      # Wipes a previous demo and creates the directories afresh, marked; in
      # registered mode also writes +profiles.ini+. Call after {#guard!}.
      #
      # @return [void]
      def prepare!
        owned_dirs.each do |dir|
          FileUtils.rm_rf(dir) if marked?(dir)
          FileUtils.mkdir_p(dir, mode: 0o700)
          File.write(File.join(dir, MARKER), "A pikuri demo. Holds no real mail or files.\n")
        end
        write_profiles_ini if registered?
      end

      private

      # @return [Array<String>] the directories the build owns and wipes.
      def owned_dirs = registered? ? [@profile_dir, @documents_dir] : [@top]

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
