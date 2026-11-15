# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'open3'

module Pikuri
  module Demo
    # Builds a demo Thunderbird profile: we write only what Thunderbird reads
    # as *input* (+user.js+, an +.ics+, mbox files — Local Folders' in the
    # profile, the IMAP account's in {Dovecot}), and a real headless
    # Thunderbird builds its own stores from it (+prefs.js+, the IMAP offline
    # store, the +.msf+ summaries, Gloda, +calendar-data/cache.sqlite+). We
    # never write Thunderbird's own schemas, so pikuri is tested against what
    # Thunderbird really writes, not against our reading of it.
    #
    # The indexed profile is cached as a tarball, so an agent gets a fresh
    # copy in a second. The key is Thunderbird's version plus a digest of
    # every input: the dates move with +--today+, so a profile built for
    # another day is a different profile. One tarball is kept.
    class Builder
      # Local Folders' mail directory, under the profile.
      LOCAL_DIR = File.join('Mail', 'Local Folders')

      # The content's folders that live in Local Folders; the rest are the
      # IMAP account's.
      LOCAL_FOLDERS = %w[Archive].freeze

      # {#inputs}' path prefixes: written into the profile, or served by {Dovecot}.
      PROFILE_PREFIX = 'profile/'
      IMAP_PREFIX = 'imap/'

      # @param target [Target]
      # @param content [Content]
      # @param cache_dir [String] where the tarball lives.
      # @param log [String] Thunderbird's output.
      def initialize(target:, content:, cache_dir:, log:)
        @target = target
        @content = content
        @cache_dir = cache_dir
        @log = log
      end

      # @param rebuild [Boolean] ignore a cached tarball.
      # @return [Float, nil] seconds the index took; +nil+ when restored
      #   from the cache.
      # @raise [Target::Refused] when the guard finds a non-demo profile.
      def build!(rebuild: false)
        @target.guard!
        inputs = self.inputs
        tarball = File.join(@cache_dir, "#{key(inputs)}.tar")
        @target.prepare!
        if !rebuild && File.file?(tarball)
          run('tar', '-xf', tarball, '-C', @target.profile_dir)
          return nil
        end

        under(inputs, PROFILE_PREFIX).each do |path, bytes|
          file = File.join(@target.profile_dir, path)
          FileUtils.mkdir_p(File.dirname(file))
          File.binwrite(file, bytes)
        end
        dovecot = Dovecot.start(messages: under(inputs, IMAP_PREFIX))
        seconds = Indexer.new(profile_dir: @target.profile_dir, messages: @content.message_count,
                              events: @content.event_count, log: @log).run!
        store(tarball)
        seconds
      ensure
        dovecot&.stop
      end

      # @return [Hash{String => String}] every input, by path: +profile/…+ is
      #   written into the profile, +imap/<folder>/<n>+ is one message
      #   {Dovecot} serves.
      def inputs
        # The calendar sits in the profile itself, where a snap Thunderbird
        # can read it (the snap can't read hidden dirs in $HOME).
        ics = File.join(@target.profile_dir, 'demo.ics')
        local, imap = @content.folders.partition { |name, _| LOCAL_FOLDERS.include?(name) }
        profile = local.to_h { |name, messages| [File.join(LOCAL_DIR, name), Mbox.render(messages)] }
                       .merge('demo.ics' => @content.ics, 'user.js' => UserJs.render(ics_path: ics))
        served = imap.flat_map do |name, messages|
          # The IMAP inbox is INBOX, as every server names it. Numbered in
          # date order, so the UIDs dovecot assigns are too.
          folder = name == 'Inbox' ? 'INBOX' : name
          messages.sort_by { |m| m.date.to_time }.each_with_index.map do |message, i|
            [format('%<folder>s/%<n>04d', folder: folder, n: i + 1), message.encoded]
          end
        end
        profile.transform_keys { PROFILE_PREFIX + _1 }.merge(served.to_h.transform_keys { IMAP_PREFIX + _1 })
      end

      private

      # @param inputs [Hash{String => String}] from {#inputs}.
      # @param prefix [String]
      # @return [Hash{String => String}] the inputs under +prefix+, without it.
      def under(inputs, prefix)
        inputs.filter_map { |path, bytes| [path.delete_prefix(prefix), bytes] if path.start_with?(prefix) }.to_h
      end

      # @param inputs [Hash{String => String}]
      # @return [String]
      def key(inputs)
        digest = Digest::SHA256.new
        digest << thunderbird_version
        inputs.sort.each { |path, bytes| digest << path << "\0" << bytes << "\0" }
        "#{thunderbird_version.tr(' ', '-')}-#{digest.hexdigest[0, 16]}"
      end

      # @return [String] e.g. "Mozilla-Thunderbird-159.0".
      def thunderbird_version
        @thunderbird_version ||= run('thunderbird', '--version').strip
      end

      # Tars the indexed profile (less its stale lock) and drops older ones.
      #
      # @param tarball [String]
      # @return [void]
      def store(tarball)
        FileUtils.mkdir_p(@cache_dir)
        partial = "#{tarball}.partial"
        run('tar', '-cf', partial, '--exclude=./lock', '-C', @target.profile_dir, '.')
        Dir[File.join(@cache_dir, '*.tar')].each { |old| File.delete(old) }
        File.rename(partial, tarball)
      end

      # @return [String] the command's stdout.
      # @raise [RuntimeError] when it fails.
      def run(*cmd)
        out, err, status = Open3.capture3(*cmd)
        raise "#{cmd.join(' ')} failed: #{err.strip}" unless status.success?

        out
      end
    end
  end
end
