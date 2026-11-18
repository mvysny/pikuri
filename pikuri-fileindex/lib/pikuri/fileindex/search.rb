# frozen_string_literal: true

module Pikuri
  module Fileindex
    # The +fileindex_search+ tool — a fast, cheap keyword lookup over a
    # desktop file index, returning matching paths each with the *single*
    # snippet the index provides (or a short file's whole text, when the
    # backend has it) and the size of its indexed text, so the
    # model can tell a file it may read whole from one it should search
    # with +fileindex_read+'s +pattern+. A {Pikuri::Tool} in the
    # shape of pikuri-workspace's +grep+, shelling out through the backend.
    #
    # The +backend:+ is the stateless module {Fileindex.pick} returns —
    # {LocalSearch} or {Recoll}. Backend-specific text (the blind-spot note,
    # the error label) is read from the backend, so a new index arm ships
    # its own without touching the tool.
    #
    # A file matches when it holds any of the query's words, or all the
    # words of any quoted group (see {Query} for why); files holding every
    # word come first, then those holding more of them.
    #
    # The +roots:+ bound it: the model's +folder+ must lie inside them, the
    # backend searches only under them, and a hit outside them (or hidden
    # below one) is dropped before the model sees it. That last filter is
    # the guarantee; recoll's query language is spliced, so its own folder
    # clause narrows but can't be trusted to bound.
    #
    # It's a locator, not a window: the index reports at most one match per
    # file, so the tool previews one match each and tells the LLM to read
    # the file for full content / other matches. It sees inside PDFs and
    # office docs (indexed at extract time), and being an index lookup is
    # cheap to run repeatedly.
    #
    # It says whether the hits are every match ("Found 8 files, all shown"
    # or "Showing 10 of 37 matching files"), and for several words how many
    # files hold all of them, counted after the roots filter, so the model
    # can report that nothing else mentions a thing. No paging past
    # {MAX_LIMIT}: the footer sends the model to narrow the query or +folder+
    # instead.
    #
    # Sharing: +P_stateless+ — the backend is a stateless module and each call
    # shells out to its own query, so one instance serves any number of agents.
    class Search < Pikuri::Tool
      # @return [Integer] default / max matching files returned.
      DEFAULT_LIMIT = 10
      MAX_LIMIT     = 25

      # @return [Integer] hard byte cap on combined output (the cap
      #   pikuri-workspace's +grep+ uses).
      MAX_BYTES = 50 * 1024

      # @return [String] human-readable form of {MAX_BYTES}.
      MAX_BYTES_LABEL = "#{MAX_BYTES / 1024} KB"

      # @return [String] how much text one +fileindex_read+ call returns,
      #   the yardstick a hit's text size is read against.
      READ_PAGE_LABEL = Pikuri::Tool.format_bytes(Pikuri::Extractor::PAGE_MAX_BYTES)

      # @return [String] opencode-shape description (summary + Usage),
      #   backend-neutral. The *runtime* tool description is this constant
      #   plus the roots and the backend's +#limitations+, appended at
      #   construction (see {#initialize}) — and it is that appended text, not
      #   this constant, that states *which folders are searched* and what the
      #   index misses there (recoll lists its +topdirs+; localsearch names
      #   source code and git checkouts). So keep coverage claims out of here.
      DESCRIPTION = <<~DESC
        Find files whose contents contain your words, using the desktop search index.

        Usage:
        - Use it when the user asks about something their own files may hold (a bill, a contract, a note, a saved web page): search before answering from general knowledge.
        - Searches inside PDFs, Word/ODT/spreadsheet documents and plain text.
        - A file matches when it contains any of your words (or their stems). Files with all of them come first, then those with more of them. So list the words the file may use, synonyms and other languages included: `rent lease vuokra`.
        - Put words in double quotes to require all of them in the same file, in any order: `"notice period" tenant` finds files with both notice and period, or with tenant.
        - Pass `folder` to search only under one folder (subfolders included) — the way to find a common word inside one project instead of across every folder you can search.
        - The index returns at most ONE match per file and may be slightly stale — this is a locator, not the full story. A short file may come whole instead ("shown whole"). To read a file's full, current text, read it (see fileindex_read).
        - Says how many files match in all: "Found 8 files, all shown" means no other file matches. When more match than are shown, narrow the query or `folder`.
        - Each file shows the size of its indexed text. fileindex_read returns up to #{READ_PAGE_LABEL} per call, so a smaller file reads whole in one call; in a bigger one, find the lines you need with fileindex_read's `pattern` first.
        - Cheap: it queries a prebuilt index rather than walking the filesystem, so it barely touches the disk of the machine the user is on — fine to run many times to narrow down.
        - Output is truncated to #{MAX_BYTES_LABEL}; narrow the query if it ends in a truncation marker.
      DESC

      # @param backend [Module] a ready file-index backend, from
      #   {Fileindex.pick}; this tool uses its +search+, +paths+, +limitations+,
      #   +label+ and +CommandError+.
      # @param roots [Roots] the folders searched; their declaration grades
      #   the tool's legs
      # @return [Search]
      def initialize(backend:, roots:)
        @backend = backend
        super(
          name: 'fileindex_search',
          description: "#{DESCRIPTION}\n#{Search.roots_note(roots)}\n#{backend.limitations}",
          parameters: Parameters.build { |p|
            p.required_string :query,
                              'Words to find in file contents; a file with any of them matches, ' \
                              'e.g. "tax return taxes 2024".'
            p.optional_integer :limit,
                               "Max number of matching files to return " \
                               "(default #{DEFAULT_LIMIT}, max #{MAX_LIMIT}), e.g. 10."
            p.optional_string :folder,
                              'Absolute path of a folder to search under, subfolders ' \
                              'included, inside the folders you can search; omit to search all of them, ' \
                              'e.g. "~/Documents/taxes".'
          },
          execute: lambda { |query:, limit: DEFAULT_LIMIT, folder: nil|
            Search.search(query: query, limit: limit, folder: folder, backend: backend, roots: roots)
          },
          trifecta_legs: roots.legs
        )
      end

      # @param roots [Roots]
      # @return [String] the description lines naming the searched folders
      def self.roots_note(roots)
        "Searches only under these folders (subfolders included):\n#{roots.dirs.map { |dir| "- #{dir}" }.join("\n")}"
      end

      # @param query [String]
      # @param limit [Integer]
      # @param folder [String, nil] folder to search under, absolute or
      #   +~+-relative, inside +roots+; +nil+ or blank searches all of them
      # @param backend [Module] the file-index backend to query
      # @param roots [Roots] the folders this search may reach
      # @return [Pikuri::Tool::Result] the hits and how many matched in all
      #   (summary +"Found 8 files"+, or +"Found 10 of 37 files"+), or
      #   {Pikuri::Tool::Result.error} for a bad +folder+ or a backend failure
      def self.search(query:, backend:, roots:, limit: DEFAULT_LIMIT, folder: nil)
        q = query.to_s.strip
        parsed = Query.parse(q)
        return Pikuri::Tool::Result.error('empty query.') if parsed.empty?

        folder = folder.to_s.strip
        folder = nil if folder.empty?
        if folder
          unless folder.start_with?('/', '~')
            return Pikuri::Tool::Result.error("folder must be an absolute path, got '#{folder}'.")
          end

          begin
            folder = File.expand_path(folder)
          rescue ArgumentError => e # "~nosuchuser"
            return Pikuri::Tool::Result.error("bad folder '#{folder}': #{e.message}")
          end
          # Resolved before any existence check, so nothing outside the roots
          # can be probed for whether it exists.
          real = roots.resolve(folder) or return outside_error(folder, roots)
          folder = real
          # A file as folder reads as "every match in this file", which the
          # index can't answer: it keeps one snippet per file.
          if File.file?(folder)
            return Pikuri::Tool::Result.error("#{folder} is a file, not a folder. The index shows only one " \
                                              'match per file; to see every match in this file, read its ' \
                                              'full text with fileindex_read.')
          end
          return Pikuri::Tool::Result.error("no such folder: #{folder}") unless File.directory?(folder)
        end

        limit = clamp(limit, 1, MAX_LIMIT)
        folders = folder ? [folder] : roots.dirs
        found = backend.search(query: parsed, limit: limit, folders: folders)
        hits = found.select { |hit| roots.resolve(hit[:path]) }
        total = count(backend, roots, query: parsed, folders: folders, hits: hits, full: found.size >= limit)
        if total.zero?
          return Pikuri::Tool::Result.new(content: no_match_message(q, folder, any: parsed.groups.size > 1),
                                          summary: 'Found 0 files')
        end

        all = nil
        if parsed.groups.size > 1
          # Asked apart, so "all of your words, shown first" holds whatever
          # order the backend ranks the any-word hits in.
          all_found = backend.search(query: parsed.all_of, limit: limit, folders: folders)
          all_hits = all_found.select { |hit| roots.resolve(hit[:path]) }
          all = count(backend, roots, query: parsed.all_of, folders: folders, hits: all_hits,
                                      full: all_found.size >= limit)
          hits = (all_hits + hits).uniq { |hit| hit[:path] }.first(limit)
          total = [total, hits.size].max
        end

        content, marker = head_truncate(hits.map { |hit| render_hit(hit) }.join("\n"))
        Pikuri::Tool::Result.new(
          content: [content.chomp, footer(hits.size, total, limit, all) + marker].reject(&:empty?).join("\n\n"),
          summary: "Found #{hits.size == total ? '' : "#{hits.size} of "}#{Pikuri::Tool.pluralize(total, 'file')}"
        )
      rescue backend::CommandError => e
        # Cap the error too — a raw subprocess error returned verbatim is
        # the shape that overflows the model's context; share the success
        # path's ceiling.
        content, marker = head_truncate(e.message)
        Pikuri::Tool::Result.error("#{backend.label}: #{content}#{marker}")
      end

      # @param hit [Hash] +{ path:, snippet:, text_size:, text: }+ from the
      #   backend; +text+, a short file's whole text, is optional
      # @return [String] +"<path>  (<size> of text)"+, then +"\n  <snippet>"+
      #   when there is one; for a hit with +text+, +"<path>  (<size> of
      #   text, shown whole)"+ and the text on one line
      def self.render_hit(hit)
        size = hit[:text_size] ? "#{Pikuri::Tool.format_bytes(hit[:text_size])} of text" : 'no indexed text'
        return "#{hit[:path]}  (#{size}, shown whole)\n  #{hit[:text].gsub(/\s+/, ' ').strip}" if hit[:text]

        head = "#{hit[:path]}  (#{size})"
        hit[:snippet] && !hit[:snippet].empty? ? "#{head}\n  #{hit[:snippet]}" : head
      end
      private_class_method :render_hit

      # How many files match in all, counted as +hits+ were filtered, so the
      # model can trust "all shown". A search that came back short of its
      # limit already holds every match; only a full one costs a listing.
      #
      # @param full [Boolean] the backend answered as many hits as asked for
      # @return [Integer]
      def self.count(backend, roots, query:, folders:, hits:, full:)
        return hits.size unless full

        # max: a file indexed between the two queries can't shrink the count
        # below what is on screen.
        [backend.paths(query: query, folders: folders).count { |path| roots.resolve(path) }, hits.size].max
      end
      private_class_method :count

      # @param shown [Integer]
      # @param total [Integer]
      # @param limit [Integer]
      # @param all [Integer, nil] how many files hold every word; +nil+ for a
      #   one-group query, where that is every match
      # @return [String] +"Found 8 files, all shown. 3 contain all of your
      #   words, shown first. …"+ or +"Showing 10 of 37 matching files, best
      #   first. To see the others, …"+
      def self.footer(shown, total, limit, all)
        per_file = 'One match shown per file, or the whole text of a short one; the index may be ' \
                   'slightly stale. Read a file to see its full text and any other matches.'
        every = case all
                when nil then ''
                when 0 then ' None contains all of your words; these contain some of them.'
                else " #{all == 1 ? '1 contains' : "#{all} contain"} all of your words, shown first."
                end
        return "Found #{Pikuri::Tool.pluralize(total, 'file')}, all shown.#{every} #{per_file}" if shown == total

        raise_limit = limit < MAX_LIMIT ? ", or raise `limit` (max #{MAX_LIMIT})" : ''
        "Showing #{shown} of #{total} matching files, best first.#{every} " \
          "To see the others, narrow the query or `folder`#{raise_limit}. #{per_file}"
      end
      private_class_method :footer

      # @return [Pikuri::Tool::Result]
      def self.outside_error(folder, roots)
        Pikuri::Tool::Result.error("#{folder} is not inside the folders you can search " \
                                   "(#{roots.dirs.join(', ')}), or is hidden.")
      end
      private_class_method :outside_error

      # @param any [Boolean] the query has several words, any of which would
      #   have matched
      # @return [String]
      def self.no_match_message(query, folder, any:)
        where = folder ? " under #{folder}" : ''
        "No files found matching #{any ? 'any of ' : ''}'#{query}'#{where}. (The index may also be slightly " \
          'stale, or still building.)'
      end
      private_class_method :no_match_message

      # Head-truncate to {MAX_BYTES} at the last newline boundary.
      #
      # @return [Array(String, String)] +[content, marker]+ (marker empty
      #   when no truncation)
      def self.head_truncate(raw)
        total = raw.bytesize
        return [raw, ''] if total <= MAX_BYTES

        head = raw.byteslice(0, MAX_BYTES)
        last_nl = head.rindex("\n")
        head = head.byteslice(0, last_nl) if last_nl
        omitted = total - head.bytesize
        [head, "\n\n... [#{omitted} bytes omitted; total was #{total} bytes; narrow the query] ..."]
      end
      private_class_method :head_truncate

      # @return [Integer] +value+ clamped to +[lo, hi]+ (lo on bad input)
      def self.clamp(value, lo, hi)
        Integer(value).clamp(lo, hi)
      rescue ArgumentError, TypeError
        lo
      end
      private_class_method :clamp
    end
  end
end
