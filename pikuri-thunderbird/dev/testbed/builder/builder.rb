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

      # The IMAP folders never marked for offline use, so Thunderbird syncs
      # their headers alone, as many keep Gmail's All Mail.
      HEADERS_ONLY = ['[Gmail]/All Mail'].freeze

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
        # The first account's store, empty: on a real install it exists long
        # before a second account on the same host is added, which is what
        # makes Thunderbird name that one's store 127.0.0-1.1. On a fresh
        # profile neither exists, and both accounts got the same directory.
        FileUtils.mkdir_p(File.join(@target.profile_dir, 'ImapMail', UserJs::IMAP_HOST))
        dovecot = Dovecot.start(messages: under(inputs, IMAP_PREFIX))
        imap = imap_folders.transform_values(&:size)
        headers_only = imap.keys.select { |key| HEADERS_ONLY.include?(key.split('/', 2).last) }
        seconds = Indexer.new(profile_dir: @target.profile_dir, messages: @content.message_count,
                              imap_folders: imap, headers_only: headers_only, dropped: @content.dropped,
                              events: @content.event_count, log: @log).run!
        store(tarball)
        seconds
      ensure
        dovecot&.stop
      end

      # @return [Hash{String => String}] every input, by path: +profile/…+ is
      #   written into the profile, +imap/<login>/<folder>/<n>+ is one message
      #   {Dovecot} serves.
      def inputs
        # The calendar sits in the profile itself, where a snap Thunderbird
        # can read it (the snap can't read hidden dirs in $HOME).
        ics = File.join(@target.profile_dir, 'demo.ics')
        local = @content.folders.values.flat_map { |folders| folders.slice(*LOCAL_FOLDERS).to_a }
                        .group_by(&:first).transform_values { |pairs| pairs.flat_map(&:last) }
        profile = local.to_h { |name, messages| [File.join(LOCAL_DIR, name), Mbox.render(messages)] }
                       .merge('demo.ics' => @content.ics, 'user.js' => UserJs.render(ics_path: ics))
        served = imap_folders.flat_map do |key, messages|
          # Numbered in date order, so the UIDs dovecot assigns are too.
          messages.sort_by { |m| m.date.to_time }.each_with_index.map do |message, i|
            [format('%<key>s/%<n>04d', key: key, n: i + 1), message.encoded]
          end
        end
        profile.transform_keys { PROFILE_PREFIX + _1 }.merge(served.to_h.transform_keys { IMAP_PREFIX + _1 })
      end

      private

      # @return [Hash{String => Array<Mail::Message>}] each IMAP folder, as
      #   +<login>/<server name>+, to its messages. The inbox is INBOX, as
      #   every server names it.
      def imap_folders
        @content.folders.flat_map do |login, folders|
          folders.except(*LOCAL_FOLDERS).map do |name, messages|
            ["#{login}/#{name == 'Inbox' ? 'INBOX' : name}", messages]
          end
        end.to_h
      end

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
