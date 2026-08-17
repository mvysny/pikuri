# frozen_string_literal: true

module Pikuri
  module Lsp
    # Pure configuration: which language servers exist, how to launch each, and
    # which files each one claims. No I/O and no live state — a host writes this
    # once and {ClientWrapper} spawns from it.
    #
    #   registry = Registry.new(entries: [
    #     Registry::StdioEntry.new(id: 'ruby', command: %w[ruby-lsp],
    #                              files: %w[*.rb *.rake *.gemspec Rakefile Gemfile]),
    #     Registry::StdioEntry.new(id: 'java', command: ['jdtls', '-data', data_dir],
    #                              files: %w[*.java],
    #                              env: { 'JAVA_HOME' => ENV.fetch('JAVA_HOME') },
    #                              init_options: { extendedClientCapabilities: {
    #                                classFileContentsSupport: true } })
    #   ])
    #   registry.entry_for('lib/pikuri/agent.rb').id   # => "ruby"
    #   registry.entry_for('Gemfile').id               # => "ruby"
    #   registry.entry_for('README.md')                # => nil
    #
    # A Ruby server is two facts, +command+ and +files+; the Java one exercises
    # every remaining field.
    class Registry
      # Extension → LSP language identifier, for entries that don't spell out a
      # +language_id:+. Only the +didOpen+ notification uses it, and a server
      # given the wrong one indexes nothing, so an unmapped extension is a
      # config error rather than a guess.
      LANGUAGE_IDS = {
        '.rb' => 'ruby', '.rake' => 'ruby', '.gemspec' => 'ruby',
        '.java' => 'java', '.kt' => 'kotlin', '.kts' => 'kotlin',
        '.scala' => 'scala', '.groovy' => 'groovy', '.clj' => 'clojure',
        '.py' => 'python', '.js' => 'javascript', '.jsx' => 'javascriptreact',
        '.ts' => 'typescript', '.tsx' => 'typescriptreact',
        '.go' => 'go', '.rs' => 'rust', '.c' => 'c', '.h' => 'c',
        '.cpp' => 'cpp', '.cc' => 'cpp', '.hpp' => 'cpp', '.cs' => 'csharp',
        '.php' => 'php', '.swift' => 'swift', '.dart' => 'dart',
        '.ex' => 'elixir', '.exs' => 'elixir', '.erl' => 'erlang',
        '.hs' => 'haskell', '.lua' => 'lua', '.pl' => 'perl', '.r' => 'r',
        '.jl' => 'julia', '.sh' => 'shellscript', '.sql' => 'sql',
        '.html' => 'html', '.css' => 'css', '.scss' => 'scss',
        '.json' => 'json', '.yaml' => 'yaml', '.yml' => 'yaml',
        '.xml' => 'xml', '.md' => 'markdown', '.tex' => 'latex'
      }.freeze

      # One language server: the argv to launch it and the files it answers for.
      #
      # +files+ holds *basename* globs, not extensions, because +Rakefile+ has
      # none — and it is the dispatch key, so getting it wrong sends Ruby
      # questions to a Java server rather than merely failing.
      #
      # @!attribute [r] id
      #   @return [String] this server's name in log lines, restart messages and
      #     {ServerProgress#server_id}, e.g. +"ruby"+. Never model-facing: the
      #     model names no server, it names a file.
      # @!attribute [r] command
      #   @return [Array<String>] argv, e.g. +["jdtls", "-data", "/…/cache"]+.
      #     Spawned with cwd = the workspace root, always.
      # @!attribute [r] files
      #   @return [Array<String>] basename globs, e.g.
      #     +["*.rb", "*.rake", "Rakefile"]+. First entry whose glob matches
      #     wins; overlaps are not detected.
      # @!attribute [r] language_id
      #   @return [String] the +languageId+ every +didOpen+ carries, e.g.
      #     +"ruby"+. Derived at construction from the first extension-bearing
      #     glob when not given — per *entry*, not per file, which is wrong for
      #     the +eslint+-shaped server that claims eight extensions and right for
      #     everything pikuri has met.
      # @!attribute [r] env
      #   @return [Hash{String => String}] extra environment for the child,
      #     merged over the inherited environment, e.g.
      #     +{"JAVA_HOME" => "/usr/lib/jvm/java-21"}+. Frozen, defaults to +{}+.
      #     The legitimate per-child credential channel of the "environment is
      #     not a secret store" seam.
      # @!attribute [r] init_options
      #   @return [Hash, nil] +initializationOptions+, passed verbatim at
      #     handshake time and never parsed by pikuri — the home for outbound
      #     per-server glue, e.g. jdtls's +classFileContentsSupport+, without
      #     which every library symbol answers with silence.
      StdioEntry = Data.define(:id, :command, :files, :language_id, :env, :init_options) do
        # @raise [ArgumentError] on an empty +id+ / +command+ / +files+, or when
        #   +language_id:+ is omitted and no glob in +files+ carries an
        #   extension {LANGUAGE_IDS} knows.
        def initialize(id:, command:, files:, language_id: nil, env: {}, init_options: nil)
          raise ArgumentError, "id must be a non-empty String, got #{id.inspect}" if id.to_s.empty?
          raise ArgumentError, "command must be a non-empty argv Array, got #{command.inspect}" if command.to_a.empty?
          raise ArgumentError, "files must be a non-empty glob Array, got #{files.inspect}" if files.to_a.empty?

          super(id: id, command: command.freeze, files: files.freeze,
                language_id: language_id || Registry.derive_language_id(files, id),
                env: env.freeze, init_options: init_options)
        end

        # Whether this server answers for +path+ — matched on the basename, so a
        # directory component never decides which server sees a file.
        #
        # @param path [String, Pathname] absolute or relative; only the basename
        #   is read.
        # @return [Boolean]
        def claims?(path)
          basename = File.basename(path.to_s)
          files.any? { |glob| File.fnmatch?(glob, basename, File::FNM_DOTMATCH) }
        end
      end

      # LSP language id for a +files:+ list.
      #
      # @param files [Array<String>] basename globs.
      # @param id [String] the entry's id, for the error message.
      # @return [String]
      # @raise [ArgumentError] when no glob carries a known extension.
      def self.derive_language_id(files, id)
        files.each do |glob|
          extension = glob[/\.[A-Za-z0-9]+\z/]&.downcase
          language = extension && LANGUAGE_IDS[extension]
          return language if language
        end
        raise ArgumentError,
              "cannot derive language_id for #{id.inspect} from files: #{files.inspect} — " \
              'pass language_id: explicitly'
      end

      # @return [Array<StdioEntry>] the entries, in declaration order.
      attr_reader :entries

      # @param entries [Array<StdioEntry>] zero or more servers. Order is the
      #   dispatch order.
      # @raise [ArgumentError] if two entries share an id — one would shadow the
      #   other's log lines and progress bars.
      def initialize(entries: [])
        duplicate = entries.map(&:id).tally.find { |_, count| count > 1 }
        raise ArgumentError, "duplicate server id #{duplicate.first.inspect}" if duplicate

        @entries = entries.freeze
      end

      # The server that answers for +path+, or +nil+ when none claims it.
      #
      # @param path [String, Pathname]
      # @return [StdioEntry, nil]
      def entry_for(path)
        @entries.find { |entry| entry.claims?(path) }
      end

      # @return [Boolean] whether no server is configured, in which case a host
      #   wires no +lsp+ tool at all.
      def empty?
        @entries.empty?
      end

      # The no-servers default, so a host that configures nothing passes nothing.
      EMPTY = new
    end
  end
end
