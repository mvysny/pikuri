# frozen_string_literal: true

module Pikuri
  module Thunderbird
    class Gloda
      # Mail search + read over the {Gloda} index service — the mail half of the
      # corpus (its people counterpart is {Gloda::Contacts}).
      #
      #   mail = Gloda::Mail.new(gloda: gloda)
      #   hit  = mail.search(query: 'invoice', limit: 10).first  # ranked, deduped
      #   mail.read(message_id: hit[:message_id])                # full decoded body
      #
      # It owns no resources: it queries {Gloda}'s live snapshot through
      # {Gloda#with_fresh_db} (so a rebuild under it is transparent), and there
      # is nothing to close — the {Gloda} it holds is closed by its own owner.
      #
      # == Gmail dedup
      #
      # Gmail exposes each label as an IMAP folder, so a message with N labels
      # yields N Gloda rows (+[Gmail]/All Mail+ alone duplicates nearly
      # everything). {#search} over-fetches and dedups by +headerMessageID+
      # (falling back to a +gloda:<id>+ handle when absent) *before* the top-N
      # cap, so duplicates can't eat result slots.
      class Mail
        # @return [Integer] over-fetch multiple before dedup+cap (so Gmail
        #   label duplicates don't shrink recall).
        OVERFETCH = 4

        # @return [Integer] absolute floor on the pre-dedup fetch.
        MIN_FETCH = 40

        # @param gloda [Gloda] the index service whose snapshot this queries.
        # @return [Mail]
        def initialize(gloda:)
          @gloda = gloda
        end

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
          fetch = [limit * OVERFETCH, MIN_FETCH].max
          rows = @gloda.with_fresh_db do |db|
            if query.to_s.strip.empty?
              filter_only(db, from:, to:, subject:, after:, before:, folder:, fetch:)
            else
              fts_search(db, query:, from:, to:, subject:, after:, before:, folder:, fetch:)
            end
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
          gloda_id = message_id.to_s[/\Agloda:(\d+)\z/, 1]
          where, bind = gloda_id ? ['m.id = ?', gloda_id.to_i] : ['m.headerMessageID = ?', message_id]
          row = @gloda.with_fresh_db do |db|
            db.execute(<<~SQL, [bind]).first
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
          end
          return nil unless row

          id, header_msgid, date_us, body, subj, attach, author, recipients, folder = row
          {
            message_id: header_msgid && !header_msgid.empty? ? header_msgid : "gloda:#{id}",
            date: to_time(date_us), from: author, to: recipients, subject: subj,
            folder: folder, attachment_names: attach.to_s, body: body.to_s
          }
        end

        private

        # @return [Array<Array>] raw result rows (see {#row_to_hit} for shape).
        def fts_search(db, query:, from:, to:, subject:, after:, before:, folder:, fetch:)
          clauses = ['fts MATCH ?', 'm.deleted = 0']
          binds = [match_expr(query)]
          append_filters(clauses, binds, from:, to:, subject:, after:, before:, folder:)
          db.execute(<<~SQL, binds + [fetch])
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
        def filter_only(db, from:, to:, subject:, after:, before:, folder:, fetch:)
          clauses = ['m.deleted = 0']
          binds = []
          append_filters(clauses, binds, from:, to:, subject:, after:, before:, folder:)
          db.execute(<<~SQL, binds + [fetch])
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
end
