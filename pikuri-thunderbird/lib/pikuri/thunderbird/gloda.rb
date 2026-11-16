# frozen_string_literal: true

require 'sqlite3'

module Pikuri
  module Thunderbird
    # Provides queryable access to Thunderbird's Gloda index
    # (+global-messages-db.sqlite+) — a *pre-decoded corpus*: Gloda has already
    # MIME-decoded, HTML-stripped, and split every message into body / subject /
    # attachment-names / author / recipients, and keeps it fresh for free. This
    # is the *service*: it snapshots the locked live file, builds an ephemeral
    # FTS5 index into the copy, tracks freshness, and hands out a current
    # connection — but runs no queries itself. Two views do the querying:
    #
    #   gloda = Gloda.new(gloda_path: profile.gloda_path, cache_dir: dir)
    #   gloda.available?                       # is the Gloda file present?
    #   Gloda::Mail.new(gloda: gloda)          # mail search + read
    #   Gloda::Contacts.new(gloda: gloda)      # name → address + novelty
    #   gloda.close                            # closes the snapshot connection
    #
    # A view queries through {#with_fresh_db}; it never caches the connection
    # (a rebuild reopens it). pikuri never touches the locked live file — it
    # works against a {DatabaseSnapshot} copy and builds its own FTS5 index into that
    # copy (Gloda's own +messagesText+ is an fts3 vtable behind the custom
    # +mozporter+ tokenizer, which the sqlite3 gem can't open).
    #
    # This service is *specific to Gloda's schema* — the FTS5 index it builds is
    # over Gloda's decoded columns (+c0body+ … +c4recipients+), so it is not a
    # generic SQLite handle and does not serve the calendar DBs ({Calendar} has
    # its own {DatabaseSnapshot} + backend).
    #
    # == Freshness & consistency (one signal)
    #
    # Each {#with_fresh_db} first asks whether the {DatabaseSnapshot} the
    # copy+index were built from is still current; if not, a fresh one is
    # taken and the FTS5 index rebuilt (~1 s). Between changes it's a header
    # read and a no-op. The generation moves on any Gloda
    # write — including read/star/tag flips during triage — so a rebuild can
    # fire mid-conversation (desirable: the views then see new mail). See
    # {DatabaseSnapshot}.
    #
    # Holds no external state beyond its own snapshot + connection, but {#close}
    # is required for orderly teardown.
    #
    # == Sharing
    #
    # +P_shared_locked+, and sharing beats one-per-agent: the snapshot copy and
    # the ~1 s FTS5 rebuild are then paid once for the machine, not once each.
    # Three contracts come with that:
    #
    # * The lock is held **across the caller's block**. Releasing it at the
    #   +yield+ would hand out exactly the connection a rebuild then closes, so
    #   a rebuild parks a second agent for ~1 s — the cost it would have paid
    #   alone anyway; every other query is local SQLite.
    # * A view may therefore never nest {#with_fresh_db} inside another (the
    #   guard is a +Mutex+, not a +Monitor+).
    # * {#close} needs no refcount: it drops the fd, and the next
    #   {#with_fresh_db} reopens the same copy. A co-owner pays a rebuild,
    #   never a failure.
    #
    # The +cache_dir+ is what must stay unshared — two instances over one
    # snapshot path +cp -f+ under each other's open fd.
    class Gloda
      LOGGER = Pikuri.logger_for('Thunderbird::Gloda')

      # A literal +undefined+ right after an address, closing +>+ or bare.
      UNDEFINED_AFTER_ADDRESS = /(>|@[^\s<>,;"']+) undefined\b/

      # Removes the literal +undefined+ Gloda writes after every address in
      # +c3author+ / +c4recipients+ but the owner's own as author:
      #
      #   Gloda.strip_undefined('Mira <mira@lumo.example> undefined, bob@x.example undefined')
      #   # => "Mira <mira@lumo.example>, bob@x.example"
      #
      # The model would echo or interpret it, and it costs tokens per address.
      # Only the word right after an address goes, so a person named
      # "Undefined" survives. A +LIKE+ filter on the raw column needs no
      # stripping: the suffix never stops a substring from matching.
      #
      # @param cell [String, nil] a +c3author+ or +c4recipients+ value.
      # @return [String, nil] +cell+ without the suffix; +nil+ stays +nil+.
      def self.strip_undefined(cell) = cell&.gsub(UNDEFINED_AFTER_ADDRESS, '\1')

      # @param gloda_path [String] path to +global-messages-db.sqlite+.
      # @param cache_dir [String] private 0700 dir for the snapshot copy. Must
      #   be this instance's alone — see the +== Sharing+ section.
      # @return [Gloda]
      def initialize(gloda_path:, cache_dir:)
        @source = gloda_path
        @snapshot = DatabaseSnapshot.new(source: gloda_path, dir: cache_dir)
        @db = nil
        @lock = Mutex.new
      end

      # @return [Boolean] whether the Gloda index file exists (the mail /
      #   contact tools' registration gate).
      def available? = File.file?(@source)

      # Yield the snapshot connection, guaranteed current — a stale index is
      # rebuilt first. The sole seam the {Gloda::Mail} / {Gloda::Contacts} views
      # query through; they never cache the returned connection, because a
      # rebuild reopens it.
      #
      #   gloda.with_fresh_db { |db| db.execute('SELECT count(*) FROM messages') }
      #
      # The lock spans the block, so the yielded connection cannot be swapped
      # mid-query and the block must not re-enter (see +== Sharing+).
      #
      # @yield [SQLite3::Database] the fresh snapshot connection.
      # @return [Object] the block's value.
      def with_fresh_db
        @lock.synchronize do
          ensure_fresh
          yield @db
        end
      end

      # Close the snapshot connection (the snapshot dir itself is
      # finalizer-reaped). Idempotent, and safe while another agent shares this
      # instance — the next {#with_fresh_db} reopens.
      #
      # @return [void]
      def close
        @lock.synchronize { close! }
      end

      private

      # {#close} without the lock — the form the already-holding callers use;
      # +Mutex+ is not reentrant.
      #
      # @return [void]
      def close!
        @db&.close
        @db = nil
      end

      # (Re)take the snapshot + rebuild the FTS5 index iff the live Gloda
      # generation differs from what the current index was built from. While
      # Thunderbird is busy writing, the older copy and its index keep serving.
      # Callers hold the lock.
      #
      # @return [void]
      # @raise [DatabaseSnapshot::TornError] Thunderbird is busy and no copy
      #   exists yet.
      def ensure_fresh
        return if @db && @snapshot.current?
        return unless @snapshot.refresh || @db.nil?

        close!
        open_and_index
      end

      # Open the fresh snapshot copy read-write and build an external-content
      # FTS5 index over Gloda's decoded columns (stores only the index, no
      # second text copy; hits map back by rowid = +messages.id+).
      #
      # @return [void]
      def open_and_index
        @db = SQLite3::Database.new(@snapshot.path)
        @db.execute(<<~SQL)
          CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(
            c0body, c1subject, c2attachmentNames, c3author, c4recipients,
            content='messagesText_content', content_rowid='docid'
          )
        SQL
        @db.execute("INSERT INTO fts(fts) VALUES('rebuild')")
      end
    end
  end
end
