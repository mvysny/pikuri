# frozen_string_literal: true

module Pikuri
  module Workspace
    module Search
      # Shared helpers for the two search tools ({Grep} and {Glob}), which
      # otherwise duplicate their oversized-root guard verbatim.
      module Utils
        # Guard against a search/list rooted at +/+, the user's whole home dir,
        # or any parent of home (+/home+, which holds *every* user's home) —
        # each walks an enormous tree and, under an +AllowAll+ workspace, floods
        # rg with unreadable-path diagnostics the model pays context for. The
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
        #   .config/
        #   work/
        #   todo.txt
        #
        # The listing is deliberately non-recursive: descending would re-do the
        # very traversal this guard exists to prevent. It falls back to a plain
        # "narrow `path`" line if the directory is empty or unreadable.
        #
        # @param resolved [Pathname] the absolute search root
        # @param verb [String] the tool's action word for the message, e.g.
        #   +"search"+ (Grep) or +"list"+ (Glob)
        # @return [String, nil] the +"Error: ..."+ refusal, or +nil+ to proceed
        def self.oversized_root_refusal(resolved, verb:)
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

          listing = child_listing(normalized)
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

        # One-level listing of +dir+'s immediate entries (dotfiles included, as
        # +ls -a+), directories first with a trailing +/+, then files, each
        # group sorted. Non-recursive by design (see {.oversized_root_refusal}).
        #
        # @param dir [String] absolute directory path
        # @return [String] newline-joined entries, or +""+ if empty/unreadable
        def self.child_listing(dir)
          entries = Dir.children(dir)
          dirs, files = entries.partition { |e| File.directory?(File.join(dir, e)) }
          (dirs.sort.map { |d| "#{d}/" } + files.sort).join("\n")
        rescue SystemCallError
          'OS error listing immediate children'
        end
      end
    end
  end
end
