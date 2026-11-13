# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'open3'

module Pikuri
  module Demo
    # Builds a demo Thunderbird profile: we write only what Thunderbird reads
    # as *input* (+user.js+, mbox files, an +.ics+), and a real headless
    # Thunderbird builds its own stores from it (+prefs.js+, the +.msf+
    # summaries, Gloda, +calendar-data/cache.sqlite+). We never write
    # Thunderbird's own schemas, so pikuri is tested against what Thunderbird
    # really writes, not against our reading of it.
    #
    # The indexed profile is cached as a tarball, so an agent gets a fresh
    # copy in a second. The key is Thunderbird's version plus a digest of
    # every input: the dates move with +--today+, and Thunderbird writes
    # absolute paths into +prefs.js+, so a profile built for another day or
    # another directory is a different profile. One tarball is kept.
    class Builder
      # The POP3 account's mail directory, under the profile.
      MAIL_DIR = File.join('Mail', 'pop.novak.example')

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
          run('tar', '-xf', tarball, '-C', @target.dir)
          return nil
        end

        inputs.each do |path, bytes|
          file = File.join(@target.dir, path)
          FileUtils.mkdir_p(File.dirname(file))
          File.binwrite(file, bytes)
        end
        seconds = Indexer.new(profile_dir: @target.dir, messages: @content.message_count,
                              events: @content.event_count, log: @log).run!
        store(tarball)
        seconds
      end

      # @return [Hash{String => String}] profile-relative path to bytes.
      def inputs
        # The calendar sits in the profile itself: a snap Thunderbird can read
        # it there, and a reader's --dir profile carries it along.
        ics = File.join(@target.dir, 'demo.ics')
        mail = @content.folders.to_h { |name, messages| [File.join(MAIL_DIR, name), Mbox.render(messages)] }
        mail.merge('demo.ics' => @content.ics, 'user.js' => UserJs.render(ics_path: ics))
      end

      private

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
        run('tar', '-cf', partial, '--exclude=./lock', '-C', @target.dir, '.')
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
