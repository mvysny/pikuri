# frozen_string_literal: true

require 'sqlite3'

module Pikuri
  module Thunderbird
    # Mail search + read over Thunderbird's Gloda index
    # (+global-messages-db.sqlite+), used as a *pre-decoded corpus*: Gloda
    # has already MIME-decoded, HTML-stripped, and split every message into
    # body / subject / attachment-names / author / recipients, and keeps it
    # fresh for free. pikuri never queries the locked live file — it works
    # against a {Snapshot} copy and builds its *own* ephemeral FTS5 index
    # into that copy (Gloda's own +messagesText+ is an fts3 vtable behind
    # the custom +mozporter+ tokenizer, which the sqlite3 gem can't open).
    #
    #   gloda = Gloda.new(gloda_path: profile.gloda_path, cache_dir: dir)
    #   gloda.available?                       # is the Gloda file present?
    #   gloda.search(query: 'invoice', limit: 10)  # ranked, deduped hits
    #   gloda.read(message_id: hit[:message_id])   # full decoded body
    #   gloda.close                            # closes the snapshot connection
    #
    # == Freshness & consistency (one signal)
    #
    # Each call to {#search}/{#read} first compares the live Gloda change
    # counter against the generation the current copy+index were built from;
    # if it moved, a fresh {Snapshot} is taken and the FTS5 index rebuilt
    # (~1 s). Between changes it's a 4-byte read and a no-op. The counter
    # bumps on any Gloda write — including read/star/tag flips during triage
    # — so a rebuild can fire mid-conversation (desirable: the agent then
    # sees new mail). See {Snapshot}.
    #
    # == Gmail dedup
    #
    # Gmail exposes each label as an IMAP folder, so a message with N labels
    # yields N Gloda rows (+[Gmail]/All Mail+ alone duplicates nearly
    # everything). {#search} over-fetches and dedups by +headerMessageID+
    # (falling back to a +gloda:<id>+ handle when absent) *before* the top-N
    # cap, so duplicates can't eat result slots.
    #
    # Immutable (holds no external state beyond its own snapshot/connection);
    # {#close} is required for orderly teardown. Not thread-safe.
    class Gloda
      LOGGER = Pikuri.logger_for('Thunderbird::Gloda')

      # @return [Integer] over-fetch multiple before dedup+cap (so Gmail
      #   label duplicates don't shrink recall).
      OVERFETCH = 4

      # @return [Integer] absolute floor on the pre-dedup fetch.
      MIN_FETCH = 40

      # @param gloda_path [String] path to +global-messages-db.sqlite+.
      # @param cache_dir [String] private 0700 dir for the snapshot copy.
      # @return [Gloda]
      def initialize(gloda_path:, cache_dir:)
        @source = gloda_path
        @snapshot = Snapshot.new(source: gloda_path, dir: cache_dir)
        @db = nil
        @indexed_generation = nil
      end

      # @return [Boolean] whether the Gloda index file exists (the mail
      #   tools' registration gate).
      def available? = File.file?(@source)

      # Ranked, deduped mail search. +query+ is matched as an OR of terms
      # over all decoded columns (recall-first); +bm25+ ranks, recency
      # breaks ties. Structured filters are exact predicates applied
      # alongside. An empty query degrades to a filter-only, date-ordered
      # listing.
      #
      # @param query [String] free text over body/subject/author/recipients/
      #   attachment-names.
      # @param limit [Integer] max hits after dedup.
      # @param from [String, nil] substring match on the author.
      # @param to [String, nil] substring match on the recipients.
      # @param subject [String, nil] substring match on the subject.
      # @param after [Time, nil] only messages on/after this instant.
      # @param before [Time, nil] only messages on/before this instant.
      # @param folder [String, nil] exact Gloda folder name.
      # @return [Array<Hash>] +[{message_id:, date: Time, from:, to:,
      #   subject:, folder:, snippet:}, …]+, best first, deduped.
      def search(query:, limit:, from: nil, to: nil, subject: nil,
                 after: nil, before: nil, folder: nil)
        ensure_fresh
        fetch = [limit * OVERFETCH, MIN_FETCH].max
        rows = if query.to_s.strip.empty?
                 filter_only(from:, to:, subject:, after:, before:, folder:, fetch:)
               else
                 fts_search(query:, from:, to:, subject:, after:, before:, folder:, fetch:)
               end
        dedup(rows).first(limit)
      end

      # Full decoded body + headers + attachment names for one message.
      #
      # @param message_id [String] the {#search} handle (an RFC +Message-ID+
      #   or a +gloda:<id>+ fallback).
      # @return [Hash, nil] +{message_id:, date:, from:, to:, subject:,
      #   folder:, attachment_names:, body:}+, or +nil+ if not found.
      def read(message_id:)
        ensure_fresh
        gloda_id = message_id.to_s[/\Agloda:(\d+)\z/, 1]
        where, bind = gloda_id ? ['m.id = ?', gloda_id.to_i] : ['m.headerMessageID = ?', message_id]
        row = @db.execute(<<~SQL, [bind]).first
          SELECT m.id, m.headerMessageID, m.date,
                 c.c0body, c.c1subject, c.c2attachmentNames, c.c3author, c.c4recipients,
                 fl.name AS folder
          FROM messages m
          JOIN messagesText_content c ON c.docid = m.id
          LEFT JOIN folderLocations fl ON fl.id = m.folderID
          WHERE #{where} AND m.deleted = 0
          ORDER BY m.date DESC
          LIMIT 1
        SQL
        return nil unless row

        id, header_msgid, date_us, body, subj, attach, author, recipients, folder = row
        {
          message_id: header_msgid && !header_msgid.empty? ? header_msgid : "gloda:#{id}",
          date: to_time(date_us), from: author, to: recipients, subject: subj,
          folder: folder, attachment_names: attach.to_s, body: body.to_s
        }
      end

      # Which of +domains+ the user has correspondence history with, per
      # Gloda's identity graph (+identities+ collects the email of every author
      # *and* recipient across all indexed messages, Sent included — so it
      # answers "have I ever exchanged mail with this domain?" in both
      # directions). Powers {ComposeGuard}'s recipient-novelty warn.
      #
      #   gloda.domains_seen(['acme.com', 'paypa1.com'])  # => ['acme.com']
      #
      # @param domains [Array<String>] lowercased bare domains.
      # @return [Array<String>] the subset present in the identity graph.
      # @raise [SQLite3::SQLException] if the +identities+ schema differs from
      #   the probed shape — the caller degrades (the schema is unverified
      #   across Thunderbird versions).
      def domains_seen(domains)
        return [] if domains.empty?

        ensure_fresh
        domains.select do |domain|
          @db.get_first_value(<<~SQL, [domain])
            SELECT 1 FROM identities
            WHERE kind = 'email'
              AND lower(substr(value, instr(value, '@') + 1)) = ?
            LIMIT 1
          SQL
        end
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

      # @return [Array<Array>] raw result rows (see {#row_to_hit} for shape).
      def fts_search(query:, from:, to:, subject:, after:, before:, folder:, fetch:)
        clauses = ['fts MATCH ?', 'm.deleted = 0']
        binds = [match_expr(query)]
        append_filters(clauses, binds, from:, to:, subject:, after:, before:, folder:)
        @db.execute(<<~SQL, binds + [fetch])
          SELECT m.headerMessageID, m.id, m.date, c.c1subject, c.c3author, c.c4recipients,
                 fl.name, snippet(fts, 0, '', '', ' … ', 12)
          FROM fts
          JOIN messages m ON m.id = fts.rowid
          JOIN messagesText_content c ON c.docid = fts.rowid
          LEFT JOIN folderLocations fl ON fl.id = m.folderID
          WHERE #{clauses.join(' AND ')}
          ORDER BY bm25(fts), m.date DESC
          LIMIT ?
        SQL
      end

      # @return [Array<Array>] raw result rows, date-ordered.
      def filter_only(from:, to:, subject:, after:, before:, folder:, fetch:)
        clauses = ['m.deleted = 0']
        binds = []
        append_filters(clauses, binds, from:, to:, subject:, after:, before:, folder:)
        @db.execute(<<~SQL, binds + [fetch])
          SELECT m.headerMessageID, m.id, m.date, c.c1subject, c.c3author, c.c4recipients,
                 fl.name, substr(c.c0body, 1, 180)
          FROM messages m
          JOIN messagesText_content c ON c.docid = m.id
          LEFT JOIN folderLocations fl ON fl.id = m.folderID
          WHERE #{clauses.join(' AND ')}
          ORDER BY m.date DESC
          LIMIT ?
        SQL
      end

      # Append the shared structured predicates (mutates +clauses+/+binds+).
      #
      # @return [void]
      def append_filters(clauses, binds, from:, to:, subject:, after:, before:, folder:)
        add_like(clauses, binds, 'c.c3author', from)
        add_like(clauses, binds, 'c.c4recipients', to)
        add_like(clauses, binds, 'c.c1subject', subject)
        if after
          clauses << 'm.date >= ?'
          binds << to_prtime(after)
        end
        if before
          clauses << 'm.date <= ?'
          binds << to_prtime(before)
        end
        if folder && !folder.empty?
          clauses << 'fl.name = ?'
          binds << folder
        end
      end

      # @return [void]
      def add_like(clauses, binds, column, needle)
        return if needle.nil? || needle.to_s.empty?

        clauses << "#{column} LIKE '%' || ? || '%'"
        binds << needle.to_s
      end

      # Build the FTS5 MATCH expression: OR of the query's terms, each
      # phrase-quoted (internal +"+ doubled) so FTS5 syntax in user input is
      # inert. OR maximizes recall; bm25 does the ranking.
      #
      # @param query [String]
      # @return [String]
      def match_expr(query)
        terms = query.to_s.scan(/[[:alnum:]]+/)
        return '""' if terms.empty?

        terms.map { |t| %("#{t.gsub('"', '""')}") }.join(' OR ')
      end

      # @param rows [Array<Array>] raw rows.
      # @return [Array<Hash>] hit hashes, deduped by handle, order preserved.
      def dedup(rows)
        seen = {}
        rows.each do |row|
          hit = row_to_hit(row)
          seen[hit[:message_id]] ||= hit
        end
        seen.values
      end

      # @param row [Array] +[headerMessageID, id, date_us, subject, author,
      #   recipients, folder, snippet]+
      # @return [Hash]
      def row_to_hit(row)
        header_msgid, id, date_us, subject, author, recipients, folder, snippet = row
        {
          message_id: header_msgid && !header_msgid.empty? ? header_msgid : "gloda:#{id}",
          date: to_time(date_us), from: author, to: recipients,
          subject: subject, folder: folder, snippet: snippet.to_s.strip
        }
      end

      # @param prtime_us [Integer, nil] PRTime microseconds since epoch.
      # @return [Time, nil]
      def to_time(prtime_us)
        return nil if prtime_us.nil? || prtime_us.zero?

        Time.at(prtime_us / 1_000_000)
      end

      # @param time [Time]
      # @return [Integer] PRTime microseconds.
      def to_prtime(time) = (time.to_i * 1_000_000)
    end
  end
end
