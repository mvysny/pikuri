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
    #   snap = DatabaseSnapshot.new(source: profile.gloda_path, dir: cache_dir)
    #   unless db && snap.current?
    #     db&.close           # before refresh overwrites the copy under it
    #     snap.refresh        # (re)copies iff the source generation moved
    #     db = SQLite3::Database.new(snap.path)
    #   end
    #
    # Open the copy normally, never +?immutable=1+: for a WAL store the copy
    # is the main file *plus* its +-wal+, and only a normal open applies the
    # WAL. Opening read-only is fine; SQLite builds the +-shm+ in our dir.
    #
    # == Why bracketed
    #
    # A reflink clone is atomic w.r.t. concurrent writes, but *file
    # atomicity ≠ DB consistency*: a clone taken mid-transaction faithfully
    # photographs a torn DB. So each copy is bracketed — read the source
    # {.generation} and check +-journal+ absence *before and after* the copy;
    # a copy counts as settled only when the generation didn't move and no
    # rollback journal was present at either edge. Otherwise the copy is
    # discarded and retried after a short backoff.
    #
    # The generation doubles as the freshness stamp: {#current?} compares the
    # live one against the copy's, and {#refresh} re-copies only when they
    # differ. One signal drives both consistency and freshness.
    #
    # == Implementation details
    #
    # The generation is the header change counter *plus* the WAL's salt and
    # size. In WAL mode SQLite bumps the counter only on a checkpoint, and
    # Thunderbird can leave a few new rows in the +-wal+ until it quits, so
    # the counter alone would call a stale copy current.
    #
    # The WAL is copied *after* the main file. A checkpoint between the two
    # leaves frames already in main, and re-applying them is idempotent; a
    # torn WAL tail fails its frame checksum, so SQLite stops at the last
    # whole commit. The one unsafe case — a WAL restart between the copies,
    # new frames over the old main — changes the salt, which the bracket
    # catches. Our dir's +-wal+/+-shm+ are deleted before each copy: a stale
    # WAL would be replayed over the new main.
    #
    # On-disk rather than an +:memory:+ load: the page cache keeps idle RAM ≈ 0
    # for a multi-hundred-MB Gloda, which a memory copy would pin for the life
    # of the process. Nor is there an +:memory:+ knob for a host that must
    # leave nothing on disk: the source already sits in the same profile on
    # the same filesystem, so the copy exposes nothing the profile doesn't.
    #
    # The copy lands in a caller-owned 0700 dir on the *same filesystem* as
    # the source (so reflink's copy-on-write extent share is available;
    # +--reflink=auto+ degrades to a full copy elsewhere). It is
    # {Pikuri::Finalizers}-reaped, so a normal exit removes it; a crash can
    # strand it (re-derivable data).
    class DatabaseSnapshot
      LOGGER = Pikuri.logger_for('Thunderbird::DatabaseSnapshot')

      # Raised when a settled copy can't be taken within the attempt budget
      # (Thunderbird mid-sync, generation won't sit still). Recoverable — the
      # calling tool degrades to a stale snapshot or an +"Error: …"+.
      class TornError < StandardError; end

      # @return [String] absolute path of the snapshot copy.
      attr_reader :path

      # The source's change stamp: any commit moves it, a read never does.
      #
      #   DatabaseSnapshot.generation('cache.sqlite')
      #   # => [412, "\xC2$\x93\x16ig\x84\xA0", 2_400_312]   # WAL store
      #   # => [87, nil, nil]                               # no -wal
      #
      # @param db_path [String]
      # @return [Array(Integer, String, Integer), nil] the header change
      #   counter (bytes 24–27), the +-wal+ salt (its header bytes 16–23) and
      #   the +-wal+ size; each WAL part is +nil+ without a +-wal+. +nil+
      #   overall when the file has no header yet.
      def self.generation(db_path)
        counter = read_bytes(db_path, 24, 4)&.unpack1('N')
        return nil unless counter

        wal = "#{db_path}-wal"
        [counter, read_bytes(wal, 16, 8), File.size?(wal)].freeze
      end

      # @return [String, nil] exactly +length+ bytes, or +nil+ if the file is
      #   missing or too short.
      def self.read_bytes(path, offset, length)
        bytes = File.binread(path, length, offset)
        bytes if bytes&.bytesize == length
      rescue Errno::ENOENT, EOFError
        nil
      end
      private_class_method :read_bytes

      # @param source [String] path to the live Thunderbird DB.
      # @param dir [String] private dir to hold the copy (created 0700 if
      #   absent); must sit on the same filesystem as +source+ for reflink.
      # @return [DatabaseSnapshot]
      def initialize(source:, dir:)
        @source = source
        @dir = dir
        @path = File.join(dir, File.basename(source))
        @generation = nil
        FileUtils.mkdir_p(@dir, mode: 0o700)
        # Fire-and-forget reap of the whole private dir (block form).
        Pikuri::Finalizers.register { FileUtils.rm_rf(@dir) }
      end

      # @return [Boolean] whether the copy exists and the source hasn't
      #   changed since it was taken.
      def current?
        !@generation.nil? && File.file?(@path) && self.class.generation(@source) == @generation
      end

      # (Re)take the snapshot unless {#current?} — a no-op returning +false+
      # then. Close any connection to {#path} first: the copy is overwritten
      # in place.
      #
      # @param attempts [Integer] bracket retries before giving up.
      # @param backoff [Float] seconds between retries.
      # @return [Boolean] +true+ if a fresh copy was taken this call.
      # @raise [TornError] if no settled copy could be taken.
      def refresh(attempts: 6, backoff: 0.08)
        return false if current?

        copy_bracketed(attempts, backoff)
        true
      end

      private

      # @return [void]
      # @raise [TornError]
      def copy_bracketed(attempts, backoff)
        detail = nil
        attempts.times do
          before = self.class.generation(@source)
          before_journal = journal?
          copy_error = copy_files
          after = self.class.generation(@source)
          after_journal = journal?

          if copy_error.nil? && !before.nil? && before == after && !before_journal && !after_journal
            @generation = after
            return
          end

          detail = copy_error || "generation #{before.inspect}->#{after.inspect}, " \
                                 "journal #{before_journal}/#{after_journal}"
          sleep(backoff)
        end
        raise TornError, "no settled snapshot of #{@source} after #{attempts} tries (#{detail})"
      end

      # @return [Boolean] whether a +<source>-journal+ (write in flight) exists.
      def journal? = File.exist?("#{@source}-journal")

      # Copy the main file, then its +-wal+ if one exists.
      #
      # @return [String, nil] +cp+'s complaint, or +nil+ on success.
      def copy_files
        FileUtils.rm_f(["#{@path}-wal", "#{@path}-shm"])
        error = cp(@source, @path)
        wal = "#{@source}-wal"
        error ||= cp(wal, "#{@path}-wal") if File.exist?(wal)
        error
      end

      # reflink-when-possible copy through the Subprocess chokepoint.
      #
      # @return [String, nil] +cp+'s complaint, or +nil+ on success.
      def cp(from, to)
        result = Pikuri::Subprocess.spawn('cp', '--reflink=auto', '-f', from, to, chdir: '/').wait
        result.status.success? ? nil : "cp failed copying #{from}: #{result.output.strip}"
      end
    end
  end
end
