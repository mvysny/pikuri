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
    # works against a {Snapshot} copy and builds its own FTS5 index into that
    # copy (Gloda's own +messagesText+ is an fts3 vtable behind the custom
    # +mozporter+ tokenizer, which the sqlite3 gem can't open).
    #
    # This service is *specific to Gloda's schema* — the FTS5 index it builds is
    # over Gloda's decoded columns (+c0body+ … +c4recipients+), so it is not a
    # generic SQLite handle and does not serve the calendar DBs ({Calendar} has
    # its own {Snapshot} + backend).
    #
    # == Freshness & consistency (one signal)
    #
    # Each {#with_fresh_db} first compares the live Gloda change counter against
    # the generation the current copy+index were built from; if it moved, a
    # fresh {Snapshot} is taken and the FTS5 index rebuilt (~1 s). Between
    # changes it's a 4-byte read and a no-op. The counter bumps on any Gloda
    # write — including read/star/tag flips during triage — so a rebuild can
    # fire mid-conversation (desirable: the views then see new mail). See
    # {Snapshot}.
    #
    # Immutable (holds no external state beyond its own snapshot/connection);
    # {#close} is required for orderly teardown. Not thread-safe.
    class Gloda
      LOGGER = Pikuri.logger_for('Thunderbird::Gloda')

      # @param gloda_path [String] path to +global-messages-db.sqlite+.
      # @param cache_dir [String] private 0700 dir for the snapshot copy.
      # @return [Gloda]
      def initialize(gloda_path:, cache_dir:)
        @source = gloda_path
        @snapshot = Snapshot.new(source: gloda_path, dir: cache_dir)
        @db = nil
        @indexed_generation = nil
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
      # @yield [SQLite3::Database] the fresh snapshot connection.
      # @return [Object] the block's value.
      def with_fresh_db
        ensure_fresh
        yield @db
      end

      # Close the snapshot connection (the snapshot dir itself is
      # finalizer-reaped). Idempotent.
      #
      # @return [void]
      def close
        @db&.close
        @db = nil
      end

      private

      # (Re)take the snapshot + rebuild the FTS5 index iff the live Gloda
      # generation differs from what the current index was built from.
      #
      # @return [void]
      def ensure_fresh
        live = Snapshot.change_counter(@source)
        return if @db && @indexed_generation && live == @indexed_generation

        close # release the fd before cp overwrites the copy in place
        @snapshot.refresh
        open_and_index
        @indexed_generation = @snapshot.generation
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
