# frozen_string_literal: true

module Pikuri
  module Fileindex
    # The GNOME desktop file index (+localsearch+, formerly tracker-miners),
    # queried in SPARQL through the +tinysparql+ CLI. The stateless backend
    # behind +fileindex_search+ / +fileindex_read+:
    #
    #   LocalSearch.search(query: Query.parse('lease rent'), limit: 10, folders: ['/home/u/Documents'])
    #   # => [{ path: '/home/u/Documents/Housing/lease-agreement.pdf',
    #   #       snippet: 'Residential >>Lease<< Agreement Landlord: …',
    #   #       text_size: 4211, text: nil },
    #   #     { path: '/home/u/Documents/Notes/flat.md',
    #   #       snippet: '# Flat The >>rent<< is EUR 1,150 …',
    #   #       text_size: 212, text: "# Flat\nThe rent is EUR 1,150, due on the 5th.\n…" }, …]
    #   LocalSearch.read_text('/home/u/Documents/Housing/lease-agreement.pdf')
    #   # => "Residential Lease Agreement\nLandlord: …"   (nil when not indexed)
    #
    # A file matches when it holds every word of any one of the query's
    # groups, by its name or its extracted text. Hits come one per file,
    # those matching more groups first, then by relevance, each with one
    # snippet of about {SNIPPET_WORDS} words around a match, matched words
    # marked +>>like this<<+, and a short file's whole text too (up to
    # {WHOLE_TEXT_CHARS}). PDFs and office docs come for free: the index
    # extracted their text, so {.read_text} needs no extractor here.
    #
    # Needs +localsearch+ (the indexing daemon, a GNOME default) and the
    # +tinysparql+ CLI, which Debian/Ubuntu's +localsearch+ package depends on.
    #
    # == Implementation details
    #
    # Why SPARQL and not +localsearch search+: that CLI sorts its hits by
    # path, not relevance, before applying the limit, and cannot filter by
    # folder — so a common word returned the first ten paths A–Z under +$HOME+.
    #
    # +tinysparql query+ prints a row as its cells joined by +", "+, which
    # snippets and paths also contain. So every cell leaves SPARQL as
    # +"v:" + ENCODE_FOR_URI(value)+: no comma, space or newline survives
    # encoding, and the +v:+ marker sets data rows apart from the CLI's
    # +Results:+ / +None+ lines, which are translated by locale.
    #
    # Index URLs use GLib's escaping ({.file_uri}); a folder filter or a read
    # built with any other escaping silently matches nothing.
    #
    # Each group and each folder is its own bound parameter (+~group0+,
    # +~folder0+, …); only those generated names are spliced into the query
    # text, never a word or a path. A parameter's type is tinysparql's
    # one-letter code (+s+, +i+): +string+ and +xsd:string+ are refused.
    #
    # Any-group matching is a +UNION+ of one +fts:match+ per group, because
    # +fts:match+ has no OR: it reads +OR+, +NOT+ and parentheses as words.
    module LocalSearch
      # @return [String] the SPARQL query CLI.
      BINARY = 'tinysparql'

      # @return [String] the D-Bus name the localsearch daemon serves its
      #   index under; querying it starts the daemon through D-Bus activation.
      DBUS_SERVICE = 'org.freedesktop.LocalSearch3'

      # Not raised to show more: once a file's whole text fits the window,
      # +fts:snippet+ may answer its title alone (measured: a 46-word
      # invoice matching "invoice" gave +Kettle & Co. — >>Invoice<< #4471+
      # at 55 words). {WHOLE_TEXT_CHARS} shows short files instead.
      #
      # @return [Integer] words of context in a snippet: enough to tell an
      #   invoice from a book that mentions one without reading either.
      SNIPPET_WORDS = 40

      # @return [Integer] longest stored text, in characters, that a hit
      #   carries whole: a few sentences, about the 500 characters a vector
      #   search's chunk shows. A snippet of a file this short leaves the
      #   rest, often the answer (an invoice's total), to a read call: on a
      #   212-file test home (2026-11, 90 lookups, every answer in a short
      #   file), showing it whole cut the reads after a search from 73 to 10,
      #   for 13% more text a search.
      WHOLE_TEXT_CHARS = 600

      # @return [Array(String, String)] what wraps each matched word in a
      #   snippet, so the model sees which words hit.
      MATCH_MARKERS = ['>>', '<<'].freeze

      # @return [Logger]
      LOGGER = Pikuri.logger_for('Fileindex::LocalSearch')

      # The ranked, folder-scoped search: +%<match>s+ is {RANKED_MATCH} once
      # per group, joined by +UNION+, and +%<under>s+ the folder filter,
      # {.under}'s. +MAX+ over a file's rows keeps the better rank and the
      # non-empty snippet. The +OPTIONAL+ measures the file's stored text
      # and keeps it if short, whichever branch matched; a file indexed by
      # name only leaves both unbound.
      #
      # @return [String]
      SEARCH_QUERY = <<~SPARQL
        SELECT (CONCAT("v:", ENCODE_FOR_URI(?url)) AS ?u)
               (CONCAT("v:", ENCODE_FOR_URI(MAX(?snippet))) AS ?s)
               (CONCAT("v:", STR(MAX(?length))) AS ?n)
               (CONCAT("v:", ENCODE_FOR_URI(MAX(?short))) AS ?t)
        WHERE {
          %<match>s
          ?f nie:url ?url .
          OPTIONAL {
            ?stored nie:isStoredAs ?f ;
              nie:plainTextContent ?text .
            BIND (STRLEN(?text) AS ?length)
            BIND (IF(?length <= #{WHOLE_TEXT_CHARS}, ?text, "") AS ?short)
          }
          FILTER (tracker:available(nie:dataSource(?f)))
          FILTER (%<under>s)
        }
        GROUP BY ?url
        ORDER BY DESC(COUNT(DISTINCT ?group)) DESC(MAX(?rank)) ?url
        LIMIT ~limit
      SPARQL

      # One group's branches in {SEARCH_QUERY}: the file matches by name
      # (first branch, no snippet) or by extracted text (second). +%<group>s+
      # is the group's parameter name, +%<index>d+ its number, which ranks a
      # file by how many groups it matched.
      #
      # @return [String]
      RANKED_MATCH = <<~SPARQL.chomp
        {
          ?f fts:match ~%<group>s .
          BIND (fts:rank(?f) AS ?rank)
          BIND ("" AS ?snippet)
          BIND (%<index>d AS ?group)
        } UNION {
          ?elem fts:match ~%<group>s ;
            nie:isStoredAs ?f .
          BIND (fts:rank(?elem) AS ?rank)
          BIND (fts:snippet(?elem, "#{MATCH_MARKERS[0]}", "#{MATCH_MARKERS[1]}", "…", #{SNIPPET_WORDS}) AS ?snippet)
          BIND (%<index>d AS ?group)
        }
      SPARQL

      # Every file {SEARCH_QUERY} matches, unranked and uncapped: the same
      # branches ({MATCH}) and filters, no rank or snippet to compute.
      #
      # @return [String]
      PATHS_QUERY = <<~SPARQL
        SELECT DISTINCT (CONCAT("v:", ENCODE_FOR_URI(?url)) AS ?u)
        WHERE {
          %<match>s
          ?f nie:url ?url .
          FILTER (tracker:available(nie:dataSource(?f)))
          FILTER (%<under>s)
        }
      SPARQL

      # One group's branches in {PATHS_QUERY}.
      #
      # @return [String]
      MATCH = '{ ?f fts:match ~%<group>s . } UNION { ?elem fts:match ~%<group>s ; nie:isStoredAs ?f . }'

      # @return [String] the stored text of the file at +~url+.
      READ_QUERY = <<~SPARQL
        SELECT (CONCAT("v:", ENCODE_FOR_URI(?text)) AS ?t)
        WHERE {
          ?f nie:url ~url .
          ?elem nie:isStoredAs ?f ;
            nie:plainTextContent ?text .
        }
        LIMIT 1
      SPARQL

      # Any one searchable file under +~folder0+: a folder alone gives a
      # search nothing to find, and a file on an unmounted drive is filtered
      # as {SEARCH_QUERY} filters it.
      #
      # @return [String]
      PROBE_QUERY = <<~SPARQL
        SELECT (CONCAT("v:", ENCODE_FOR_URI(?url)) AS ?u)
        WHERE {
          ?f nie:url ?url .
          ?elem nie:isStoredAs ?f .
          FILTER NOT EXISTS { ?elem a nfo:Folder }
          FILTER (tracker:available(nie:dataSource(?f)))
          FILTER (STRSTARTS(?url, ~folder0))
        }
        LIMIT 1
      SPARQL

      # @return [Regexp] a byte GLib leaves unescaped in a +file://+ URI
      #   (+g_filename_to_uri+'s set, measured against the index); anything
      #   else, non-ASCII included, is +%XX+ per byte.
      URI_SAFE = %r{[A-Za-z0-9\-._~!$&'()*+,=:@/]}

      # Raised when a tinysparql invocation exits non-zero — a recoverable
      # failure the calling tool renders as +"Error: ..."+.
      class CommandError < StandardError; end

      # @return [String] short human name for this backend, used by the
      #   fileindex tools when prefixing an +"Error: ..."+ observation.
      def self.label = 'localsearch'

      # Uniform accessor mirroring {Recoll.limitations}; a constant here
      # because this index's blind spots are the same on every host.
      #
      # @return [String]
      def self.limitations = LIMITATIONS

      # What this index will not surface, appended to the fileindex tools'
      # LLM description so the model knows when to search the files directly
      # instead. Measured; see +pikuri-fileindex/design/architecture.md+.
      #
      # @return [String]
      LIMITATIONS = <<~LIMITS.chomp
        Not covered by this index (fall back to a text/regex search over the files for these):
        - Source code and other developer files are not content-indexed — only their names are. Search their text directly.
        - Nothing inside a git checkout is indexed (any folder containing a .git). Search those files directly.
      LIMITS

      # Ranked full-text search under any of +folders+.
      #
      # @param query [Query] a file matches every word, stemmed, of any group
      # @param limit [Integer] max files returned
      # @param folders [Array<String>] absolute real paths of the folders to
      #   search under, subfolders included; at least one
      # @return [Array<Hash>] +[{ path: String, snippet: String|nil,
      #   text_size: Integer|nil, text: String|nil }, …]+, best first, one
      #   per file; +text_size+ is the stored text's length in characters
      #   (SPARQL has no byte length; the two differ only by the non-ASCII
      #   share), +nil+ for a file indexed by name only; +text+ is the
      #   whole stored text when +text_size+ is at most {WHOLE_TEXT_CHARS}
      # @raise [CommandError] if tinysparql exits non-zero
      def self.search(query:, limit:, folders:)
        raw = run(format(SEARCH_QUERY, match: union(RANKED_MATCH, query), under: under(folders.size)),
                  limit: limit, **group_args(query), **folder_args(folders))
        parse_rows(raw).map do |url, snippet, length, text|
          snippet = snippet&.gsub(/\s+/, ' ')&.strip
          { path: path_of(url), snippet: (snippet unless snippet.to_s.empty?), text_size: length&.to_i,
            text: (text unless text.to_s.strip.empty?) }
        end
      end

      # The path of every file {.search} would match, unranked and uncapped,
      # so a caller can tell how many matched beyond its +limit+.
      #
      # @param query [Query]
      # @param folders [Array<String>] as {.search}'s
      # @return [Array<String>] absolute paths
      # @raise [CommandError] if tinysparql exits non-zero
      def self.paths(query:, folders:)
        raw = run(format(PATHS_QUERY, match: union(MATCH, query), under: under(folders.size)),
                  **group_args(query), **folder_args(folders))
        parse_rows(raw).map { |(url)| path_of(url) }
      end

      # Full stored plain text of an indexed file. Works for PDFs/office docs
      # (extracted at index time).
      #
      # @param path [String] absolute path
      # @return [String, nil] +nil+ when the path isn't indexed, has no stored
      #   text, or the query fails — the caller turns that into an LLM-facing
      #   message
      def self.read_text(path)
        row = parse_rows(run(READ_QUERY, url: file_uri(File.expand_path(path)))).first
        text = row&.first
        text && !text.strip.empty? ? text : nil
      rescue CommandError
        nil
      end

      # Why this index can't answer a search under +folders+ right now, for
      # a human to act on; +nil+ when it can. An index that answers but holds
      # no file under any of them is not ready either: every search would
      # come back empty. Some empty folders are normal (an empty Desktop), so
      # they only log a warning naming each.
      #
      #   LocalSearch.unavailable_reason(folders: ['/home/u/notes'])
      #   # => "nothing under /home/u/notes is indexed. …"   (nil when ready)
      #
      # Starts the localsearch daemon if it is installed but not running, as
      # any query does (D-Bus activation).
      #
      # @param folders [Array<String>] absolute real paths
      # @return [String, nil]
      def self.unavailable_reason(folders:)
        empty = folders.reject { |folder| parse_rows(run(PROBE_QUERY, folder0: prefix(folder))).any? }
        if empty.size < folders.size
          empty.each { |folder| LOGGER.warn("nothing under #{folder} is indexed; searches there find nothing") }
          return nil
        end

        "nothing under #{folders.join(', ')} is indexed. Right after a first login GNOME may still be " \
          'indexing: `localsearch status` shows how far it got. Otherwise add the folders under ' \
          'GNOME Settings → Search. A folder inside a git checkout is never indexed.'
      rescue Errno::ENOENT
        "the '#{BINARY}' command is missing. Install the 'localsearch' and '#{BINARY}' " \
          "packages: GNOME's desktop file index and its query tool."
      rescue CommandError => e
        "the index doesn't answer (#{e.message}). Is the 'localsearch' package " \
          "installed? It is GNOME's desktop file indexer."
      end

      # The +file://+ URI the index stores for +path+, escaped the way GLib
      # escapes it.
      #
      #   LocalSearch.file_uri('/home/u/My Notes/ü#1.txt')
      #   # => "file:///home/u/My%20Notes/%C3%BC%231.txt"
      #
      # @param path [String] absolute path
      # @return [String]
      def self.file_uri(path)
        escaped = path.b.gsub(/./mn) { |c| c.match?(URI_SAFE) ? c : format('%%%02X', c.ord) }
        "file://#{escaped}"
      end

      # Parse +tinysparql query+ output into rows of decoded cells. Only rows
      # whose every cell carries the +v:+ marker count (see the class doc).
      #
      # @param raw [String] the CLI's stdout
      # @return [Array<Array<String, nil>>] one array of cells per row; an
      #   unbound cell (+(null)+) is +nil+
      def self.parse_rows(raw)
        raw.each_line(chomp: true).filter_map do |line|
          next unless line.start_with?('  ')

          cells = line.strip.split(', ')
          next unless cells.all? { |cell| cell == '(null)' || cell.start_with?('v:') }

          cells.map { |cell| cell == '(null)' ? nil : percent_decode(cell.delete_prefix('v:')) }
        end
      end

      # @param branches [String] {RANKED_MATCH} or {MATCH}
      # @param query [Query]
      # @return [String] +branches+ once per group, joined by +UNION+
      def self.union(branches, query)
        Array.new(query.groups.size) { |i| format(branches, group: "group#{i}", index: i) }.join(' UNION ')
      end
      private_class_method :union

      # @param query [Query]
      # @return [Hash{Symbol => String}] +group0:+, +group1:+, … bound to each
      #   group's words, which +fts:match+ ANDs
      def self.group_args(query)
        query.groups.each_with_index.to_h { |words, i| [:"group#{i}", words.join(' ')] }
      end
      private_class_method :group_args

      # @param count [Integer] how many folders the filter names
      # @return [String] a SPARQL condition true for a URL under any of
      #   +~folder0+ … +~folder<count-1>+
      def self.under(count)
        Array.new(count) { |i| "STRSTARTS(?url, ~folder#{i})" }.join(' || ')
      end
      private_class_method :under

      # @param folders [Array<String>]
      # @return [Hash{Symbol => String}] +folder0:+, +folder1:+, … bound to
      #   each folder's URL prefix
      def self.folder_args(folders)
        folders.each_with_index.to_h { |folder, i| [:"folder#{i}", prefix(folder)] }
      end
      private_class_method :folder_args

      # @param folder [String] absolute path
      # @return [String] the URL prefix of every file below +folder+; the
      #   trailing slash keeps +/a/b+ from matching +/a/bc+
      def self.prefix(folder)
        "#{file_uri(folder).chomp('/')}/"
      end
      private_class_method :prefix

      # @param query [String] SPARQL text
      # @param args [Hash{Symbol => String, Integer}] the query's +~name+
      #   parameters
      # @return [String] stdout
      # @raise [CommandError] on a non-zero exit
      # @raise [Errno::ENOENT] if tinysparql is missing
      def self.run(query, **args)
        argv = [BINARY, 'query', '-b', DBUS_SERVICE]
        args.each do |name, value|
          type = value.is_a?(Integer) ? 'i' : 's'
          argv.push('--arg', "#{name}:#{type}:#{value}")
        end
        argv.push('-q', query)
        result = Pikuri::Subprocess.spawn(*argv, chdir: '/').wait
        return result.output if result.status.success?

        message = result.output.strip
        raise CommandError, message.empty? ? "exited #{result.status.exitstatus}" : message
      end
      private_class_method :run

      # @param url [String] a +file://+ URI from the index
      # @return [String] the absolute path it names
      def self.path_of(url)
        percent_decode(url.delete_prefix('file://'))
      end
      private_class_method :path_of

      # @param encoded [String]
      # @return [String] +%XX+ decoded per byte, tagged UTF-8
      def self.percent_decode(encoded)
        encoded.b.gsub(/%([0-9A-Fa-f]{2})/n) { ::Regexp.last_match(1).hex.chr }.force_encoding('UTF-8')
      end
      private_class_method :percent_decode
    end
  end
end
