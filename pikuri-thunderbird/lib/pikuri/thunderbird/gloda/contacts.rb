# frozen_string_literal: true

require 'sqlite3'

module Pikuri
  module Thunderbird
    class Gloda
      # The *people* half of the Gloda corpus (its mail counterpart is
      # {Gloda::Mail}): resolve a name to an address, and check recipient
      # novelty. Both read the user's own correspondence graph, so they belong
      # together and away from mail search/read.
      #
      #   contacts = Gloda::Contacts.new(gloda: gloda)
      #   contacts.resolve(query: 'jon', limit: 5)  # name → ranked addresses
      #   contacts.domains_sent_to(['acme.com', 'paypa1.com'])  # => ['acme.com']
      #
      # It owns no resources: it queries {Gloda}'s live snapshot through
      # {Gloda#with_fresh_db} (so a rebuild under it is transparent), and there
      # is nothing to close — the {Gloda} it holds is closed by its own owner.
      #
      # == Implementation details
      #
      # Both read the decoded +c3author+ / +c4recipients+ columns, where display
      # name and address sit together, never Gloda's own graph tables: +contacts+
      # is dead (frecency/popularity unpopulated, +name+ unreliable), and
      # +identities+ holds every author, so a domain that only ever wrote to
      # the user would count as known.
      class Contacts
        LOGGER = Pikuri.logger_for('Thunderbird::Gloda::Contacts')

        # @return [Integer] max matched messages scanned when tallying contact
        #   frequency in {#resolve} — bounds work on a very common name.
        SCAN = 2000

        # @return [Integer] extra weight a Sent-folder appearance adds over a
        #   received one. "I have *mailed* this person" is the strongest
        #   real-contact signal, and a spoofer is never in your Sent — so this
        #   is what sinks a spoofed one-off below the genuine contact.
        SENT_WEIGHT = 3

        # @return [Integer] Gloda's +indexingPriority+ for a Sent folder.
        SENT_PRIORITY = 60

        # Bracket-agnostic email token: angle brackets, when present, fall
        # outside the class, so +Jon <jon@x>+ and a bare +jon@x+ (name
        # trailing) extract to the same +jon@x+. Commas/semicolons/quotes bound
        # it too, so it never swallows the next recipient or a nickname quote.
        EMAIL_RE = /[^\s<>,;"']+@[^\s<>,;"']+/

        # @param gloda [Gloda] the mail store whose snapshot this queries.
        # @return [Contacts]
        def initialize(gloda:)
          @gloda = gloda
        end

        # Resolve a name (or partial address) to ranked email addresses drawn
        # from the user's *own correspondence graph* — the decoded author /
        # recipient columns. Feeds {MailCompose}: the model has a name, compose
        # needs an address.
        #
        #   contacts.resolve(query: 'martin', limit: 5)
        #   # => [{address: 'martin@vysny.me', name: 'Martin Vysny',
        #   #      count: 42, sent: 12, score: 78}, …]
        #
        # +query+ terms match (recall-first OR, token-wise) against the author
        # and recipient columns only, via {Gloda}'s shared FTS5 index; every
        # email token in a matching *entry* is extracted {EMAIL_RE
        # bracket-agnostically}, grouped by lower-cased address, and ranked by
        # appearance count with a {SENT_WEIGHT Sent-folder bonus}. Never
        # auto-picks — several people/addresses come back and disambiguation is
        # the caller's job (silently choosing one is the mis-send
        # {ComposeGuard} exists to prevent). Reverse lookup (address → who?) is
        # the same call with the address as +query+.
        #
        # @param query [String] a name or partial address, e.g. "Jon Snow".
        # @param limit [Integer] max candidates returned.
        # @return [Array<Hash>] +[{address:, name: (String, nil), count:,
        #   sent:, score:}, …]+, best first, deduped by lower-cased address;
        #   empty when the query has no alphanumeric terms or nothing matches.
        def resolve(query:, limit:)
          terms = query.to_s.scan(/[[:alnum:]]+/)
          return [] if terms.empty?

          rows = @gloda.with_fresh_db do |db|
            db.execute(<<~SQL, [match_expr(terms), SCAN])
              SELECT c.c3author, c.c4recipients, fl.indexingPriority
              FROM fts
              JOIN messages m ON m.id = fts.rowid
              JOIN messagesText_content c ON c.docid = fts.rowid
              LEFT JOIN folderLocations fl ON fl.id = m.folderID
              WHERE fts MATCH ? AND m.deleted = 0
              LIMIT ?
            SQL
          end
          tally(rows, terms).first(limit)
        end

        # Which of +domains+ the user has *sent* mail to: a recipient of a
        # message in a Sent folder. Powers {ComposeGuard}'s recipient-novelty
        # warn.
        #
        #   contacts.domains_sent_to(['acme.com', 'paypa1.com'])  # => ['acme.com']
        #
        # Received mail never counts, since an attacker earns that by writing
        # first: a reply to a phishing mail has to warn. Sent mail archived out
        # of the Sent folder doesn't count either, which only adds a warning.
        #
        # @param domains [Array<String>] lowercased bare domains.
        # @return [Array<String>, nil] the subset the user has sent mail to, or
        #   +nil+ when no Sent-folder mail is indexed at all (an account that
        #   keeps no Sent copies), where every recipient would look new.
        # @raise [SQLite3::SQLException] if the schema differs from the probed
        #   shape — the caller degrades (it is unverified across Thunderbird
        #   versions).
        def domains_sent_to(domains)
          return [] if domains.empty?

          @gloda.with_fresh_db do |db|
            next nil unless db.get_first_value(<<~SQL, [SENT_PRIORITY])
              SELECT 1 FROM messages m JOIN folderLocations fl ON fl.id = m.folderID
              WHERE fl.indexingPriority = ? AND m.deleted = 0 LIMIT 1
            SQL

            domains.select { |domain| sent_to?(db, domain) }
          end
        end

        private

        # @param db [SQLite3::Database]
        # @param domain [String] a lowercased bare domain.
        # @return [Boolean] whether a Sent-folder message has a recipient at
        #   exactly +domain+ (the SQL +instr+ only narrows; +@acme.com+ is also
        #   inside +@acme.com.evil.example+).
        def sent_to?(db, domain)
          cells = db.execute(<<~SQL, [SENT_PRIORITY, "@#{domain}"])
            SELECT c.c4recipients FROM messages m
            JOIN messagesText_content c ON c.docid = m.id
            JOIN folderLocations fl ON fl.id = m.folderID
            WHERE fl.indexingPriority = ? AND m.deleted = 0
              AND instr(lower(c.c4recipients), ?) > 0
          SQL
          cells.any? do |(cell)|
            cell.to_s.scan(EMAIL_RE).any? { |email| email.downcase.split('@', 2).last == domain }
          end
        end

        # FTS5 expression matching any query term, restricted to the author /
        # recipient columns (each term phrase-quoted so punctuation in the name
        # is inert). A partial address like +vysny+ matches the tokenized
        # +martin@vysny.me+ the same way a name does.
        #
        # @param terms [Array<String>]
        # @return [String]
        def match_expr(terms)
          ored = terms.map { |t| %("#{t.gsub('"', '""')}") }.join(' OR ')
          "{c3author c4recipients} : (#{ored})"
        end

        # Group every extracted address across the matched author/recipient
        # cells, tally appearances + Sent-folder appearances, and rank.
        #
        # @param rows [Array<Array>] +[author_cell, recipients_cell, priority]+.
        # @param terms [Array<String>] the query terms, to keep only the
        #   entries that actually match (see {#extract}).
        # @return [Array<Hash>] ranked contact hashes (see {#resolve}).
        def tally(rows, terms)
          needles = terms.map(&:downcase)
          agg = Hash.new { |h, k| h[k] = { address: k, names: Hash.new(0), count: 0, sent: 0 } }
          rows.each do |author, recipients, priority|
            sent = (priority == SENT_PRIORITY)
            [author, recipients].each do |cell|
              extract(Gloda.strip_undefined(cell), needles).each do |address, name|
                rec = agg[address]
                rec[:count] += 1
                rec[:sent] += 1 if sent
                rec[:names][name] += 1 unless name.empty?
              end
            end
          end
          agg.values.map { |rec| finalize(rec) }
             .sort_by { |c| [-c[:score], -c[:count], c[:address]] }
        end

        # Split a cell into comma/semicolon entries and pull the address + a
        # cleaned display name from each entry that matches *all* query terms.
        # The per-entry all-terms filter is why a co-recipient — or my own
        # address on a Sent message, or a mailbox that merely shares a domain
        # token with a full-address query — doesn't pollute the result: FTS
        # matched the *message* (recall, OR of terms), this keeps only the
        # *entry* that matches every term (precision), while still scanning
        # every email token in a kept entry (a cell can hold several matching
        # recipients). Tolerates the real-data noise: missing brackets, quoted
        # nicknames.
        #
        # @param cell [String, nil] with {Gloda.strip_undefined} applied.
        # @param needles [Array<String>] lower-cased query terms.
        # @return [Array<Array(String, String)>] +[address_downcased, name]+
        #   per email token found (name +""+ when none survives cleaning).
        def extract(cell, needles)
          cell.to_s.split(/[,;]/).flat_map do |piece|
            next [] unless needles.all? { |n| piece.downcase.include?(n) }

            emails = piece.scan(EMAIL_RE)
            next [] if emails.empty?

            emails.map { |e| [e.downcase, entry_name(piece, emails.first)] }
          end
        end

        # The display name for an entry: the text *before* the address (the
        # dominant +Name <addr>+ form; the trailing duplicate in a tri-part
        # cell like +Martin Vysny <m@x> Martin Vyšný+ is ignored), falling back
        # to the text *after* it for the bare +m@x Name+ form.
        #
        # @param piece [String] one comma/semicolon-split entry.
        # @param addr [String] the (first) email token in the entry.
        # @return [String] the cleaned name, or +""+ if none survives.
        def entry_name(piece, addr)
          idx = piece.index(addr)
          before = clean_name(piece[0...idx])
          before.empty? ? clean_name(piece[(idx + addr.length)..]) : before
        end

        # @param text [String, nil]
        # @return [String] +text+ with brackets/quotes removed and whitespace
        #   collapsed.
        def clean_name(text)
          text.to_s.gsub(/[<>"]/, ' ').gsub(/\s+/, ' ').strip
        end

        # Pick the most-seen non-empty display name and compute the final score.
        #
        # @param rec [Hash]
        # @return [Hash] +{address:, name: (String, nil), count:, sent:, score:}+.
        def finalize(rec)
          name = rec[:names].max_by { |n, count| [count, n.length] }&.first
          {
            address: rec[:address], name: name,
            count: rec[:count], sent: rec[:sent],
            score: rec[:count] + (SENT_WEIGHT * rec[:sent])
          }
        end
      end
    end
  end
end
