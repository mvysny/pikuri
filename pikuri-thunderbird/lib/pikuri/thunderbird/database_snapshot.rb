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
    #     if snap.refresh || db.nil?  # false: unchanged, or Thunderbird busy → keep the older copy
    #       db&.close                 # the older copy; the next refresh overwrites it
    #       db = SQLite3::Database.new(snap.path)
    #     end
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
    # discarded and retried after a backoff.
    #
    # When the tries run out, the older settled copy keeps serving, so a
    # query during a big sync answers one poll stale. Only with no older copy
    # does {#refresh} raise {TornError}, whose message is the model-facing
    # "Thunderbird is busy" text. Gloda holds its +-journal+ about 11 ms per
    # new message (4 s for 400), so no budget outlasts every poll, and a
    # crash leaves a hot +-journal+ until Thunderbird next starts.
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
    # catches. The target slot's +-wal+/+-shm+ are deleted before each copy:
    # a stale WAL would be replayed over the new main.
    #
    # Copies alternate between two slots, +a/+ and +b/+, so a failed attempt
    # never overwrites the copy a caller still reads. That is also why the
    # caller must close its connection after each successful {#refresh}: the
    # next one copies into the slot that connection holds.
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

      # Raised when no settled copy can be taken and there is no older one to
      # serve. Its message is written for the model; a tool answers it as
      # +Tool::Result.error(e.message)+.
      class TornError < StandardError; end

      # @return [String] what {TornError} says.
      BUSY = 'Thunderbird is busy writing to its database; please wait for Thunderbird to settle down ' \
             'and try again, or restart Thunderbird if this is taking too much time.'

      # @return [String] absolute path of the current snapshot copy. It moves
      #   to the other slot on each successful {#refresh}.
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
        @path = slot_path('a')
        @generation = nil
        FileUtils.mkdir_p(@dir, mode: 0o700)
        %w[a b].each { FileUtils.mkdir_p(File.join(@dir, _1), mode: 0o700) }
        # Fire-and-forget reap of the whole private dir (block form).
        Pikuri::Finalizers.register { FileUtils.rm_rf(@dir) }
      end

      # @return [Boolean] whether the copy exists and the source hasn't
      #   changed since it was taken.
      def current?
        !@generation.nil? && File.file?(@path) && self.class.generation(@source) == @generation
      end

      # (Re)take the snapshot unless {#current?}. On +true+, {#path} names the
      # new copy: close the connection to the older one and open it.
      #
      # @param attempts [Integer] bracket tries before giving up.
      # @param backoff [Float] seconds between tries; Thunderbird's sync is slow,
      #   so there is no point hammering the file.
      # @return [Boolean] +true+ if a fresh copy was taken this call; +false+
      #   when the copy is current, or when Thunderbird kept writing through
      #   every try and the older copy keeps serving.
      # @raise [TornError] if no settled copy could be taken and none exists yet.
      def refresh(attempts: 4, backoff: 0.25)
        return false if current?

        detail = copy_bracketed(attempts, backoff)
        return true unless detail

        LOGGER.warn("no settled snapshot of #{@source} after #{attempts} tries (#{detail})" \
                    "#{', serving the older copy' if @generation}")
        raise TornError, BUSY unless @generation

        false
      end

      private

      # @return [String, nil] why the last try failed, or +nil+ once a
      #   settled copy is in place.
      def copy_bracketed(attempts, backoff)
        target = slot_path(@generation && @path == slot_path('a') ? 'b' : 'a')
        detail = nil
        attempts.times do |i|
          sleep(backoff) if i.positive?
          before = self.class.generation(@source)
          before_journal = journal?
          copy_error = copy_files(target)
          after = self.class.generation(@source)
          after_journal = journal?

          if copy_error.nil? && !before.nil? && before == after && !before_journal && !after_journal
            @path = target
            @generation = after
            return nil
          end

          detail = copy_error || "generation #{before.inspect}->#{after.inspect}, " \
                                 "journal #{before_journal}/#{after_journal}"
        end
        detail
      end

      # @param slot [String] +"a"+ or +"b"+.
      # @return [String]
      def slot_path(slot) = File.join(@dir, slot, File.basename(@source))

      # @return [Boolean] whether a +<source>-journal+ (write in flight) exists.
      def journal? = File.exist?("#{@source}-journal")

      # Copy the main file, then its +-wal+ if one exists.
      #
      # @param target [String] the slot's copy path.
      # @return [String, nil] +cp+'s complaint, or +nil+ on success.
      def copy_files(target)
        FileUtils.rm_f(["#{target}-wal", "#{target}-shm"])
        error = cp(@source, target)
        wal = "#{@source}-wal"
        error ||= cp(wal, "#{target}-wal") if File.exist?(wal)
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
