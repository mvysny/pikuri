# frozen_string_literal: true

module Pikuri
  module Workspace
    module Search
      # The two guards every path-listing tool needs and none should own: an
      # oversized-root refusal, and a byte cap on the rendered result.
      module Utils
        # Guard against a search/list rooted at +/+, the user's whole home dir,
        # or any parent of home (+/home+, which holds *every* user's home) —
        # each walks an enormous tree and, under a +readable:+ root that broad,
        # floods rg with unreadable-path diagnostics the model pays context for. The
        # refused set is home and everything at-or-above it: blocking +~+ while
        # waving through its strictly-broader parent +/home+ would be no guard
        # at all. Refused regardless of any glob: rg traverses the tree *before*
        # the glob narrows which files it searches. Lesser roots (a project dir,
        # +~/work+) return +nil+ and proceed.
        #
        # Rather than dead-end at "narrow it", the refusal hands back a
        # one-level listing of the root's own entries, so the model can pick a
        # subdirectory and retry *without* another tool call or a shell:
        #
        #   Error: refusing to search from /home/alice — the whole home
        #   directory is too broad. Pick one of its entries below as `path` and
        #   search there instead (directories end with `/`):
        #   .config/  [3 dirs, 2 files]
        #   .ssh/  [denied]
        #   work/  [12 dirs, 1 file]
        #   todo.txt  412B
        #
        # The listing is deliberately one level deep: rendering a tree would
        # re-do the very traversal this guard exists to prevent. (The child
        # summary does open each entry once, but that's bounded by the root's
        # own entry count — nothing like rg's walk.) It falls back to a plain
        # "narrow `path`" line if the directory is empty or unreadable.
        #
        # @param resolved [Pathname] the absolute search root
        # @param filesystem [Filesystem] threaded into the listing so a
        #   credential dir under the refused root renders +[denied]+
        # @param verb [String] the tool's action word for the message, e.g.
        #   +"search"+ (Grep) or +"list"+ (Glob)
        # @return [String, nil] the +"Error: ..."+ refusal, or +nil+ to proceed
        def self.oversized_root_refusal(resolved, filesystem:, verb:)
          normalized = normalize_root(resolved)
          home = normalize_root(Pathname.new(Dir.home))
          root_kind =
            if normalized == normalize_root(Pathname.new('/'))
              'the whole filesystem root'
            elsif normalized == home
              'the whole home directory'
            elsif home.start_with?(normalized + File::SEPARATOR)
              # e.g. /home — a parent of ~ is strictly broader than ~ itself.
              # (+/+ is a parent too, but its "//"-prefix test never matches,
              # so it stays owned by the first branch and its clearer message.)
              'a parent of your home directory'
            end
          return nil unless root_kind

          listing = root_listing(normalized, filesystem: filesystem)
          guidance =
            if listing.empty?
              'Narrow `path` to a specific subdirectory.'
            else
              "Pick one of its entries below as `path` and #{verb} there " \
                "instead (directories end with `/`):\n#{listing}"
            end
          "Error: refusing to #{verb} from #{resolved} — #{root_kind} is too " \
            "broad. #{guidance}"
        end

        # @param path [String, Pathname]
        # @return [String] symlink-resolved absolute path; falls back to a
        #   lexical cleanup when the path doesn't exist on disk.
        def self.normalize_root(path)
          Pathname.new(path).realpath.to_s
        rescue SystemCallError
          Pathname.new(path).expand_path.cleanpath.to_s
        end

        # Head-truncate +raw+ to +max_bytes+, cutting at the last newline so
        # the final row is never partial.
        #
        # @param raw [String]
        # @param max_bytes [Integer]
        # @param hint [String] what the caller should change to get less
        #   output, e.g. +"refine pattern or path"+
        # @return [Array(String, String)] the content and a marker (+""+ when
        #   nothing was cut)
        def self.head_truncate(raw, max_bytes:, hint:)
          total = raw.bytesize
          return [raw, ''] if total <= max_bytes

          head = raw.byteslice(0, max_bytes)
          last_nl = head.rindex("\n")
          head = head.byteslice(0, last_nl) if last_nl
          omitted = total - head.bytesize
          marker = "\n\n... [#{omitted} bytes omitted; total was #{total} bytes; " \
                   "#{hint}] ..."
          [head, marker]
        end

        # Search-root-relative paths of every denied root that falls *under*
        # +root+ — the only ones an rg walk rooted there could reach.
        #
        #   denied_prefixes(filesystem: fs, root: Pathname.new('/home/alice'))
        #   # => [".aws", ".gnupg", ".ssh"]
        #
        # @param filesystem [Filesystem] supplies {Filesystem#denied_roots}
        # @param root [Pathname] the rg search root
        # @return [Array<String>] sorted, +""+-free relative paths
        def self.denied_prefixes(filesystem:, root:)
          base = normalize_root(root)
          filesystem.denied_roots.filter_map { |denied|
            absolute = denied.exist? ? denied.realpath.to_s : denied.to_s
            next unless absolute.start_with?(base + File::SEPARATOR)

            absolute.delete_prefix(base + File::SEPARATOR)
          }.sort
        end

        # +rg --glob '!<rel>'+ for each denied root under +root+, pruning the
        # subtree before rg ever walks it. Verified: a negative glob on a
        # directory prunes its contents and survives +--no-ignore+, the same
        # property {Glob}'s +!.git/*+ relies on.
        #
        # This is the *optimization*, never the guarantee — it goes silently
        # partial whenever a denied root sits outside the search root, and an
        # rg flag change could weaken it without a test noticing. The
        # {Filesystem#denied?} filter on the results is what fails closed.
        #
        # @param filesystem [Filesystem]
        # @param root [Pathname] the rg search root
        # @return [Array<String>] argv fragments, empty when nothing is denied
        def self.denied_globs(filesystem:, root:)
          denied_prefixes(filesystem: filesystem, root: root)
            .flat_map { |rel| ['--glob', "!#{rel}"] }
        end

        # Drop every output line rg emitted for a denied path. rg puts the path
        # first on the line and never follows symlinks (no +-L+ in either
        # tool's argv), so a leading-prefix test is exact for the path segment
        # — no need to find where the path ends, which a filename containing
        # +:+ would make ambiguous. It may over-match (a +.netrc.bak+ line goes
        # too); over-filtering is the safe direction for a credential guard.
        #
        # @param raw [String] rg output, +./+ prefixes already stripped
        # @param prefixes [Array<String>] from {.denied_prefixes}
        # @return [String]
        def self.reject_denied_lines(raw, prefixes:)
          return raw if prefixes.empty?

          raw.lines.reject { |line|
            prefixes.any? { |rel| line.start_with?(rel) }
          }.join
        end

        # A refusal still has to come back when the root itself can't be
        # opened, so that degrades to the "narrow `path`" wording rather than
        # raising out of a message-building helper.
        #
        # @param dir [String] absolute directory path
        # @param filesystem [Filesystem]
        # @return [String] {Pikuri::Workspace::Listing.render} at depth 1, or +""+
        def self.root_listing(dir, filesystem:)
          Listing.render(dir, filesystem: filesystem)
        rescue SystemCallError
          ''
        end
        private_class_method :root_listing
      end
    end
  end
end
