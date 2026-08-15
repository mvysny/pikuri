# frozen_string_literal: true

module Pikuri
  module Workspace
    # Renders a directory as rows a model can orient from — name-sorted,
    # directories first, sizes +ls -h+ style:
    #
    #   Listing.render(project_root, depth: 2)   # =>
    #   lib/
    #     pikuri/  [3 dirs, 1 file]
    #     version.rb  48B
    #   spec/  [empty]
    #   README.md  4.2K
    #   broken.md  [Errno::ENOENT]
    #
    # A directory shows +[3 dirs, 1 file]+ exactly where its contents *aren't*
    # on screen — the deepest rendered level — so +lib/+ above, expanded, never
    # restates children that are already rows. Counts are immediate children,
    # not recursive.
    #
    # A row that can't be measured prints its errno class rather than a prose
    # word or a fake zero: +ENOENT+ is a dangling symlink or an entry that
    # vanished mid-listing, +EACCES+ a directory you can't open, +ELOOP+ a
    # symlink cycle. Each implies a different follow-up, and a model reads
    # +EACCES+ unaided. Only the *root* failing raises.
    #
    # == Implementation details
    #
    # Walks with +Dir.children+, not the +rg --files+ prefix derivation
    # {Search::Glob} uses, so symlinked / gitignored-only / empty directories
    # can't silently vanish from the answer. The price is a caller-visible one:
    # nothing evaluates +.gitignore+ here, so everything shows except +.git/+ —
    # +ls+ behaviour, and the one place the file tools diverge on gitignore.
    # Full argument in +DECISIONS.md+ +D-directory-listing+.
    module Listing
      # @return [Integer] hard byte cap on rendered output. Same value as
      #   {Search::Glob::MAX_BYTES}; re-declared rather than cross-referenced
      #   because Zeitwerk's eager-load order between siblings isn't guaranteed.
      MAX_BYTES = 50 * 1024

      # @return [Integer] default +depth+ — immediate children only.
      DEFAULT_DEPTH = 1

      # @return [Integer] deepest +depth+ honoured; larger values clamp down.
      #   Past three levels a listing stops being orientation and becomes the
      #   whole-tree dump {MAX_BYTES} would eat anyway.
      MAX_DEPTH = 3

      # @return [String] per-level indent for nested rows.
      INDENT = '  '

      # @return [String] separator between an entry's name and its size /
      #   summary column.
      GAP = '  '

      # @return [String] the one entry never listed, matching
      #   {Search::Glob}'s +--glob '!.git/*'+.
      GIT_DIR = '.git'

      # @return [Array<String>] size suffixes, +ls -h+ style.
      SIZE_UNITS = %w[B K M G T].freeze

      # Render +dir+'s entries.
      #
      # @param dir [String, Pathname] absolute directory path
      # @param depth [Integer] levels to descend, clamped to +1..{MAX_DEPTH}+
      # @return [String] newline-joined rows, head-truncated at {MAX_BYTES};
      #   +""+ when +dir+ has no entries
      # @raise [SystemCallError] if +dir+ itself can't be opened
      def self.render(dir, depth: DEFAULT_DEPTH)
        rows = child_rows(dir.to_s, depth: depth.clamp(1, MAX_DEPTH), indent: '')
        return '' if rows.empty?

        content, marker = Search::Utils.head_truncate(
          rows.join("\n"), max_bytes: MAX_BYTES, hint: 'list a subdirectory instead'
        )
        content + marker
      end

      # Rows for +dir+'s immediate children, recursing while +depth+ allows.
      #
      # @return [Array<String>]
      # @raise [SystemCallError] if +dir+ can't be opened
      def self.child_rows(dir, depth:, indent:)
        dirs, files = partition_children(dir)
        dirs.flat_map { |name| dir_rows(File.join(dir, name), name: name, depth: depth, indent: indent) } +
          files.map { |name| file_row(File.join(dir, name), name: name, indent: indent) }
      end
      private_class_method :child_rows

      # One directory's row, plus its children's rows when +depth+ allows. An
      # expanded directory that turns out to have no children keeps +[empty]+:
      # a bare +foo/+ with nothing under it reads as truncation.
      #
      # @return [Array<String>]
      def self.dir_rows(absolute, name:, depth:, indent:)
        label = "#{indent}#{name}/"
        return ["#{label}#{GAP}#{summary(absolute)}"] if depth <= 1

        sub = child_rows(absolute, depth: depth - 1, indent: indent + INDENT)
        sub.empty? ? ["#{label}#{GAP}[empty]"] : [label] + sub
      rescue SystemCallError => e
        ["#{label}#{GAP}[#{e.class}]"]
      end
      private_class_method :dir_rows

      # @return [String] the +[N dirs, M files]+ / +[empty]+ column
      # @raise [SystemCallError] if the directory can't be opened
      def self.summary(absolute)
        dirs, files = partition_children(absolute)
        return '[empty]' if dirs.empty? && files.empty?

        "[#{pluralize(dirs.size, 'dir')}, #{pluralize(files.size, 'file')}]"
      end
      private_class_method :summary

      # @return [String] one file's row, e.g. +"version.rb  48B"+
      def self.file_row(absolute, name:, indent:)
        "#{indent}#{name}#{GAP}#{human_size(File.size(absolute))}"
      rescue SystemCallError => e
        "#{indent}#{name}#{GAP}[#{e.class}]"
      end
      private_class_method :file_row

      # Immediate children split into directories and files, each sorted,
      # dotfiles kept (as +ls -a+). A symlink is classified by its target, so a
      # dangling one lands in +files+ and degrades in the size column.
      #
      # Don't "simplify" this into one flat sort of full paths: +-+ (0x2D)
      # sorts before +/+ (0x2F), so +pikuri/lib+ would land after
      # +pikuri-workspace/spec+ and render under the wrong parent. Sorting
      # per-directory is what makes that unrepresentable.
      #
      # @return [Array(Array<String>, Array<String>)]
      # @raise [SystemCallError] if the directory can't be opened
      def self.partition_children(dir)
        entries = Dir.children(dir).reject { |e| e == GIT_DIR }
        dirs, files = entries.partition { |e| File.directory?(File.join(dir, e)) }
        [dirs.sort, files.sort]
      end
      private_class_method :partition_children

      # @param bytes [Integer]
      # @return [String] +ls -h+ style: a decimal below 10 (+4.2K+), whole
      #   units above (+50M+), raw bytes under 1 K (+812B+)
      def self.human_size(bytes)
        unit  = SIZE_UNITS.first
        value = bytes.to_f
        SIZE_UNITS.drop(1).each do |bigger|
          break if value < 1024

          value /= 1024
          unit = bigger
        end
        return "#{value.round}#{unit}" if unit == SIZE_UNITS.first || value >= 10

        format('%.1f%s', value, unit)
      end
      private_class_method :human_size

      # @return [String] +"1 dir"+ / +"4 dirs"+
      def self.pluralize(count, noun)
        "#{count} #{noun}#{'s' unless count == 1}"
      end
      private_class_method :pluralize
    end
  end
end
