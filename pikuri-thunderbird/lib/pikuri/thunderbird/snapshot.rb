# frozen_string_literal: true

require 'fileutils'

module Pikuri
  module Thunderbird
    # A consistent, lock-free, on-disk copy of a live Thunderbird SQLite DB
    # (Gloda or a calendar store), so pikuri never queries the file
    # Thunderbird holds open. Thunderbird keeps its DBs locked
    # (+locking_mode=EXCLUSIVE+), so the only live-file touch is a *bracketed*
    # +cp --reflink=auto+; every actual query runs against the copy we own.
    #
    #   snap = Snapshot.new(source: profile.gloda_path, dir: cache_dir)
    #   snap.refresh          # (re)copies iff the source generation moved
    #   run_query_against(snap.path)
    #   snap.generation       # the source change-counter this copy is as-of
    #
    # == Why bracketed
    #
    # A reflink clone is atomic w.r.t. concurrent writes, but *file
    # atomicity ≠ DB consistency*: a clone taken mid-transaction faithfully
    # photographs a torn DB. So each copy is bracketed — read the change
    # counter (header bytes 24–27) and check +-journal+ absence *before and
    # after* the copy; a copy counts as settled only when the counter didn't
    # move and no rollback journal was present at either edge. Otherwise the
    # copy is discarded and retried after a short backoff.
    #
    # The validated change counter doubles as the *generation* stamp: a
    # caller checks freshness by comparing {.change_counter} of the live
    # source against {#generation}, and {#refresh} re-copies only when they
    # differ. One signal drives both consistency and freshness.
    #
    # == Implementation details
    #
    # The copy lands in a caller-owned 0700 dir on the *same filesystem* as
    # the source (so reflink's copy-on-write extent share is available;
    # +--reflink=auto+ degrades to a full copy elsewhere). It is
    # {Pikuri::Finalizers}-reaped, so a normal exit removes it; a crash can
    # strand it (re-derivable data). Only the main DB file is copied — for a
    # WAL store that yields an as-of-last-checkpoint view (Thunderbird
    # checkpoints aggressively), which callers open with +?immutable=1+.
    class Snapshot
      LOGGER = Pikuri.logger_for('Thunderbird::Snapshot')

      # Raised when a settled copy can't be taken within the attempt budget
      # (Thunderbird mid-sync, counter won't sit still). Recoverable — the
      # calling tool degrades to a stale snapshot or an +"Error: …"+.
      class TornError < StandardError; end

      # @return [String] absolute path of the snapshot copy.
      attr_reader :path

      # @return [Integer, nil] the source change-counter this copy reflects;
      #   +nil+ before the first successful {#refresh}.
      attr_reader :generation

      # SQLite's file change counter: 4 big-endian bytes at header offset 24,
      # bumped only when the DB is unlocked after a modification (so a read
      # never moves it — a file-format guarantee). +nil+ if the file is too
      # short to have a header yet.
      #
      # @param db_path [String]
      # @return [Integer, nil]
      def self.change_counter(db_path)
        header = File.binread(db_path, 4, 24)
        header && header.bytesize == 4 ? header.unpack1('N') : nil
      rescue Errno::ENOENT, EOFError
        nil
      end

      # @param source [String] path to the live Thunderbird DB.
      # @param dir [String] private dir to hold the copy (created 0700 if
      #   absent); must sit on the same filesystem as +source+ for reflink.
      # @return [Snapshot]
      def initialize(source:, dir:)
        @source = source
        @dir = dir
        @path = File.join(dir, File.basename(source))
        @generation = nil
        FileUtils.mkdir_p(@dir, mode: 0o700)
        # Fire-and-forget reap of the whole private dir (block form).
        Pikuri::Finalizers.register { FileUtils.rm_rf(@dir) }
      end

      # (Re)take the snapshot iff the live source generation differs from the
      # copy we hold — a no-op (returning +false+) when already current.
      #
      # @param attempts [Integer] bracket retries before giving up.
      # @param backoff [Float] seconds between retries.
      # @return [Boolean] +true+ if a fresh copy was taken this call.
      # @raise [TornError] if no settled copy could be taken.
      def refresh(attempts: 6, backoff: 0.08)
        live = self.class.change_counter(@source)
        return false if @generation && live == @generation && File.file?(@path)

        copy_bracketed(attempts, backoff)
        true
      end

      private

      # @return [void]
      # @raise [TornError]
      def copy_bracketed(attempts, backoff)
        detail = nil
        attempts.times do
          before_counter = self.class.change_counter(@source)
          before_journal = journal?(@source)
          copy_file!
          after_counter = self.class.change_counter(@source)
          after_journal = journal?(@source)

          if settled?(before_counter, after_counter, before_journal, after_journal)
            @generation = after_counter
            return
          end

          detail = "counter #{before_counter}->#{after_counter}, " \
                   "journal #{before_journal}/#{after_journal}"
          sleep(backoff)
        end
        raise TornError, "no settled snapshot of #{@source} after #{attempts} tries (#{detail})"
      end

      # Settled iff the counter is present and unchanged across the copy and
      # no rollback journal existed at either edge.
      #
      # @return [Boolean]
      def settled?(before_counter, after_counter, before_journal, after_journal)
        !before_counter.nil? && before_counter == after_counter &&
          !before_journal && !after_journal
      end

      # @return [Boolean] whether a +<source>-journal+ (write in flight) exists.
      def journal?(db_path) = File.exist?("#{db_path}-journal")

      # reflink-when-possible copy through the Subprocess chokepoint.
      #
      # @return [void]
      # @raise [TornError] if +cp+ fails.
      def copy_file!
        result = Pikuri::Subprocess.spawn(
          'cp', '--reflink=auto', '-f', @source, @path, chdir: '/'
        ).wait
        return if result.status.success?

        raise TornError, "cp failed copying #{@source}: #{result.output.strip}"
      end
    end
  end
end
