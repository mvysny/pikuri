# frozen_string_literal: true

module Pikuri
  module Fileindex
    # The folders a host lets the file-index tools reach, and what the owner
    # declares about them. The model's +folder+ can only narrow inside them:
    #
    #   roots = Roots.new(dirs: %w[~/Desktop ~/Documents], private: true)
    #   roots.dirs                                   # => ["/home/u/Desktop", "/home/u/Documents"]
    #   roots.resolve('~/Documents/tax/../2024.pdf') # => "/home/u/Documents/2024.pdf"
    #   roots.resolve('/home/u/work/plan.md')        # => nil: outside every root
    #   roots.resolve('~/Documents/.secret/x.txt')   # => nil: hidden below a root
    #   roots.resolve('~/Documents/link-to-work/a')  # => nil: the symlink leads outside
    #   roots.legs.untrusted                         # => :hard, until the owner vouches
    #
    # A real boundary, not a hint: the stock localsearch index covers all of
    # +$HOME+, so these roots are the only thing keeping +~/work+ or a
    # Downloads file out of an agent that was given +~/notes+.
    #
    # Roots are real paths, because the index stores a file under its real
    # path: each root is resolved through its symlinks at construction, and
    # {#resolve} judges a path by where it leads.
    #
    # One declaration covers every root, not one per folder: each tool
    # declares its legs once, so per-root grades would only union back to the
    # least-trusted root's. Mixed folders take the declaration that fits all.
    #
    # Immutable.
    Roots = Data.define(:dirs, :private, :trusted) do
      # @param dirs [Array<String>] folders, absolute or +~+-relative; each
      #   must exist
      # @param private [Boolean] the folders may hold data worth
      #   exfiltrating; the owner declares it, nothing inspects the files
      # @param trusted [Boolean] every file under the folders is the user's
      #   own: nothing a stranger wrote lands there (so not Downloads, and
      #   not a folder an agent that reads mail writes into)
      # @raise [ArgumentError] when +dirs+ is empty, or an entry is relative,
      #   missing or not a folder
      def initialize(dirs:, private: false, trusted: false)
        raise ArgumentError, 'roots: give at least one folder' if dirs.empty?

        super(dirs: dirs.map { |dir| real_dir(dir.to_s) }.uniq.freeze, private: private, trusted: trusted)
      end

      # The real path of +path+ when it lies inside a root, or is one, with
      # no hidden (dot-named) folder or file below that root; else +nil+.
      # Symlinks resolve through the longest part of +path+ that exists, so a
      # file not on disk (deleted since indexing, or never there) is judged
      # by its folder. Hidden is judged only below the root, so a root under
      # +~/.cache+ still covers its files.
      #
      # @param path [String] absolute or +~+-relative
      # @return [String, nil]
      def resolve(path)
        real = real_path(File.expand_path(path))
        real if dirs.any? do |dir|
          rest = below(real, dir)
          rest && rest.split('/').none? { |part| part.start_with?('.') }
        end
      rescue ArgumentError # "~nosuchuser"
        nil
      end

      # @return [Pikuri::Tool::TrifectaLegs] the legs every tool returning
      #   these folders' contents declares; never egress, retrieval stays on
      #   the machine.
      def legs
        Pikuri::Tool::TrifectaLegs.new(private: private, untrusted: trusted ? :none : :hard,
                                       egress_payload_review: :no_egress)
      end

      private

      # @param dir [String]
      # @return [String] the folder's real path
      # @raise [ArgumentError]
      def real_dir(dir)
        raise ArgumentError, "root must be an absolute path, got '#{dir}'" unless dir.start_with?('/', '~')

        real = File.realpath(File.expand_path(dir))
        raise ArgumentError, "root #{dir} is not a folder" unless File.directory?(real)

        real
      rescue Errno::ENOENT
        raise ArgumentError, "root #{dir} does not exist"
      end

      # @param path [String] absolute, normalized
      # @return [String] +path+ with every symlink in its existing part resolved
      def real_path(path)
        return File.realpath(path) if File.exist?(path)

        parent = File.dirname(path)
        parent == path ? path : File.join(real_path(parent), File.basename(path))
      end

      # @param path [String] absolute, normalized
      # @param dir [String] a root
      # @return [String, nil] +path+ relative to +dir+ (+""+ for +dir+
      #   itself), or +nil+ when +path+ is outside it
      def below(path, dir)
        return '' if path == dir

        prefix = dir.end_with?('/') ? dir : "#{dir}/"
        path.delete_prefix(prefix) if path.start_with?(prefix)
      end
    end
  end
end
