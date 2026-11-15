# frozen_string_literal: true

require 'json'

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

        # Full decoded body + headers + attachments for one message.
        #
        # +folder_uris+ is every folder holding a copy, this row's own first —
        # Gmail fans one message out over its labels, and any copy carries the
        # same attachment bytes.
        #
        # +downloaded+ is whether Gloda saw the message's body. It parses the
        # MIME only for a message in a local folder or one whose IMAP body is
        # offline; any other it indexes from headers alone, leaving body and
        # attachment names NULL — where a parsed message with no text or no
        # attachments has an empty string (+IndexMsg.sys.mjs+, Thunderbird
        # 159). So +attachments+ empty means "none" only when +downloaded+.
        # Of a message's copies, one Gloda saw the body of is read first.
        #
        # @param message_id [String] the {#search} handle (an RFC +Message-ID+
        #   or a +gloda:<id>+ fallback).
        # @return [Hash, nil] +{message_id:, date:, from:, to:, subject:,
        #   folder:, folder_uris: Array<String>, attachments: Array<Attachment>,
        #   body:, downloaded: Boolean}+, or +nil+ if not found.
        # @raise [NoMatchingPatternError] on an +attachmentInfos+ entry of a
        #   shape Gloda never wrote.
        def read(message_id:)
          gloda_id = message_id.to_s[/\Agloda:(\d+)\z/, 1]
          where, bind = gloda_id ? ['m.id = ?', gloda_id.to_i] : ['m.headerMessageID = ?', message_id]
          row, attr_id, uris = @gloda.with_fresh_db do |db|
            row = db.execute(<<~SQL, [bind]).first
              SELECT m.id, m.headerMessageID, m.date,
                     c.c0body, c.c1subject, c.c3author, c.c4recipients,
                     fl.name, fl.folderURI, m.jsonAttributes, c.c2attachmentNames IS NOT NULL
              FROM messages m
              JOIN messagesText_content c ON c.docid = m.id
              LEFT JOIN folderLocations fl ON fl.id = m.folderID
              WHERE #{where} AND m.deleted = 0
              ORDER BY c.c2attachmentNames IS NULL, m.date DESC
              LIMIT 1
            SQL
            next unless row

            # Attribute ids are assigned per profile at Gloda's creation, so
            # look this one up by name rather than hardcoding the 51 seen live.
            attr_id = db.get_first_value(
              "SELECT id FROM attributeDefinitions WHERE extensionName = 'built-in' AND name = 'attachmentInfos'"
            )
            header_msgid = row[1]
            uris = if header_msgid.to_s.empty?
                     []
                   else
                     db.execute(<<~SQL, [header_msgid]).flatten
                       SELECT fl.folderURI FROM messages m JOIN folderLocations fl ON fl.id = m.folderID
                       WHERE m.headerMessageID = ? AND m.deleted = 0
                     SQL
                   end
            [row, attr_id, uris]
          end
          return nil unless row

          id, header_msgid, date_us, body, subj, author, recipients, folder, folder_uri, json, downloaded = row
          {
            message_id: header_msgid && !header_msgid.empty? ? header_msgid : "gloda:#{id}",
            date: to_time(date_us), from: author, to: recipients, subject: subj,
            folder: folder, folder_uris: [folder_uri, *uris].compact.uniq,
            attachments: attachments(json, attr_id), body: body.to_s, downloaded: downloaded == 1
          }
        end

        private

        # @param json [String, nil] +messages.jsonAttributes+.
        # @param attr_id [Integer, nil] the +attachmentInfos+ attribute id.
        # @return [Array<Attachment>] in Gloda's order — the order the listing
        #   numbers them, so the reader resolves the same index.
        def attachments(json, attr_id)
          return [] if json.nil? || attr_id.nil?

          (JSON.parse(json)[attr_id.to_s] || []).map { |entry| Attachment.from_gloda(entry) }
        end

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
