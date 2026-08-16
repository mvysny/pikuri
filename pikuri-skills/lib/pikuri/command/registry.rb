# frozen_string_literal: true

module Pikuri
  # Slash commands: prompt templates a *human* invokes by typing +/name+.
  #
  # The counterpart of {Pikuri::Skill}, and deliberately not a variant of it.
  # A skill is advertised to the model and loaded by the model, so it costs
  # prompt tokens on every turn; a command is never advertised, costs nothing
  # resident, and lands as the user's own turn when the human asks for it.
  # {Registry} discovers them, {Renderer} expands one into the text a host
  # then sends.
  module Command
    # On-disk registry of slash commands, over the same *search bases* as the
    # skill catalog: under each base it scans +.pikuri/commands+ and
    # +.claude/commands+ for +.md+ files.
    #
    #   registry = Pikuri::Command::Registry.new(search_bases: [
    #     Pikuri::Bundle::Base.new(dir: project_root, trusted: repo_sources_are_mine),
    #     Pikuri::Bundle::Base.new(dir: Dir.home, trusted: home_bundles_are_mine)
    #   ])
    #   text = registry.expand('wh', arguments: 'swingai')   # nil if no such command
    #   agent.run_loop(user_message: text)                   # it *is* the human's turn
    #
    # == Names are paths
    #
    # A command's name is its file path under the scanned dir, +.md+ dropped
    # and separators +:+-joined: +commands/frontend/deploy.md+ is
    # +/frontend:deploy+. A frontmatter +name:+ is *ignored* (warned about) —
    # for a skill the name is a label the model reads, but for a command it is
    # the address the human types, and an address its location doesn't predict
    # is not an address.
    #
    # == Precedence
    #
    # Bases left to right, +.pikuri/commands+ before +.claude/commands+; the
    # first command seen for a name wins and later ones are dropped with a
    # warning. Pass the project root first for "project beats global".
    #
    # A host resolving a typed +/name+ owes one more rule, which lives in the
    # host because nothing here can see the other two namespaces: **host
    # built-in > command > skill**. Built-ins are matched first so a cloned
    # repo shipping +.claude/commands/plan.md+ cannot capture a +/plan+ that
    # flips a safety gate.
    #
    # == Validation, and the two refusals
    #
    # Nothing else is fatal. Frontmatter is optional (a bare +.md+ is all
    # body); +description+ falls back to the name; unknown keys are ignored.
    # A command that parses is a command the human can invoke — a menu entry
    # that silently vanished would be the worse failure, since the human is
    # looking straight at the list.
    #
    # Two things are refused, at {#get} rather than at scan time, so typing
    # +/foo+ explains itself instead of the entry being mysteriously absent:
    #
    # * +allowed-tools:+ — a *restriction* the author asked for. pikuri fixes
    #   tools at configure time and cannot narrow them mid-conversation, so
    #   honouring it is out of reach and ignoring it would silently run the
    #   command with the full toolset.
    # * a <code>!`cmd`</code> body directive — Claude Code runs these before
    #   sending the prompt, gated only by the untrusted file's own
    #   +allowed-tools:+. pikuri never will: it would make a +.md+ that
    #   travels with a clone into arbitrary code execution behind a slash,
    #   reaching no confirmer, no sandbox and no {Pikuri::Subprocess} seam.
    #
    # Detection is deliberately over-eager and does *not* skip fenced blocks:
    # a false positive is a loud exception on a file its author can edit, a
    # false negative is silent semantic drift. Substitution ({Renderer}) makes
    # the opposite call for the opposite reason — see there.
    #
    # == Trust
    #
    # {#untrusted_level} unions {Pikuri::Bundle::Base#trusted} over the
    # commands actually stored, exactly as the skill catalog does, and
    # {Extension} declares the result. A *refused* command never counts: its
    # bytes cannot reach the context.
    #
    # Immutable.
    class Registry
      LOGGER = Pikuri.logger_for('Commands')
      private_constant :LOGGER

      # Subdirectory names scanned under each search base, in precedence
      # order. There is deliberately no +.agents/commands+: no harness
      # surveyed in +COMPARISON.md+ defines one, and an invented convention is
      # worse than a missing one.
      COMMAND_SUBDIRS = ['.pikuri/commands', '.claude/commands'].freeze
      private_constant :COMMAND_SUBDIRS

      # A loaded command. Bodies are eager-loaded at scan time; command files
      # are small and expansion stays IO-free.
      #
      # +refusal+ is the reason string this command cannot be run (+nil+ when
      # it can), captured during the scan rather than re-derived by {#get}.
      # +sidecars+ says the command's directory holds something the registry
      # did *not* load as a command — a non-Markdown file, or a subdirectory
      # holding no commands — which is what earns the expansion its
      # "this command lives in …" footer.
      Command = Data.define(:name, :description, :argument_hint, :location, :body, :refusal, :sidecars) do
        # @return [Boolean] true when {#get} would raise instead of returning this
        def refused? = !refusal.nil?

        # @return [Boolean]
        def sidecars? = sidecars
      end

      # @param search_bases [Array<Pikuri::Bundle::Base, String, Pathname>]
      #   directories under which to look for command subdirs. Typical values:
      #   the project root and +Dir.home+. Processed left to right. A bare
      #   path means +Bundle::Base.new(dir: path)+ — untrusted, so the unsafe
      #   value is the one you get by saying nothing.
      # @return [Registry]
      def initialize(search_bases:)
        @roots = []
        @commands = {}
        @untrusted = false

        search_bases.each do |entry|
          base = entry.is_a?(Bundle::Base) ? entry : Bundle::Base.new(dir: entry)
          COMMAND_SUBDIRS.each do |sub|
            root = File.join(base.dir.to_s, sub)
            next unless File.directory?(root)

            @roots << root
            scan_root(root, trusted: base.trusted)
          end
        end

        @roots.freeze
        @commands.freeze
        @list = @commands.values.freeze
        freeze
      end

      # @return [Array<Command>] commands in discovery order (which equals
      #   precedence order), refused ones included so a menu can show them
      attr_reader :list

      # @return [Array<String>] absolute paths of the command directories this
      #   registry covered, in scan order. Hosts fold these into
      #   +Pikuri::Workspace::Filesystem+'s +readable:+ so the model can
      #   +read+ a file a command body points at.
      attr_reader :roots

      # Look a command up by the name the human typed.
      #
      # Two outcomes beyond success, and they are different on purpose:
      # *absent* is an ordinary thing a human causes by typo, while *refused*
      # is a fact about a file on disk that retyping cannot fix.
      #
      # @param name [String] e.g. +"wh"+ or +"frontend:deploy"+
      # @return [Command, nil] +nil+ when no command has that name
      # @raise [RefusedError] when the command exists but cannot be run
      def get(name)
        command = @commands[name]
        return nil if command.nil?
        raise RefusedError.new(command.location, command.refusal) if command.refused?

        command
      end

      # {#get} plus {Renderer.expand} — the one-call form, and the one that
      # documents what the result *is*: the human's own user turn, to be sent
      # with +run_loop(user_message:)+ or
      # +Control::Interloper#inject_user_message+, never as a +:system+ block.
      #
      # @param name [String]
      # @param arguments [String] everything typed after the command name
      # @return [String, nil] +nil+ when no command has that name
      # @raise [RefusedError] when the command exists but cannot be run
      def expand(name, arguments: '')
        command = get(name)
        return nil if command.nil?

        Renderer.expand(command, arguments: arguments)
      end

      # @return [Boolean]
      def empty? = @list.empty?

      # @return [Symbol] +:none+ when every runnable command came from a
      #   +trusted+ base, else +:hard+
      def untrusted_level = @untrusted ? :hard : :none

      private

      def scan_root(root, trusted:)
        Dir.glob('**/*.md', base: root).sort.each do |relative|
          path = File.join(root, relative)
          next unless File.file?(path)

          command = parse_command(path, name: relative.delete_suffix('.md').tr(File::SEPARATOR, ':'))
          next if command.nil?

          existing = @commands[command.name]
          if existing
            LOGGER.warn("command name '#{command.name}' at #{path} is shadowed by " \
                        "earlier entry at #{existing.location}")
          else
            @commands[command.name] = command
            @untrusted ||= !trusted && !command.refused?
          end
        end
      end

      def parse_command(path, name:)
        frontmatter, body = Bundle::Frontmatter.split(File.read(path), path: path)
        frontmatter ||= {}

        declared = frontmatter['name'].to_s.strip
        LOGGER.warn("#{path}: frontmatter name '#{declared}' ignored; a command is addressed " \
                    "by its path, so this one is '#{name}'") if !declared.empty? && declared != name

        description = frontmatter['description'].to_s.strip
        LOGGER.warn("#{path}: no 'description'; the menu will show the name") if description.empty?

        refusal = refusal_for(frontmatter, body)
        LOGGER.warn("#{path}: #{refusal}; /#{name} will refuse to run") if refusal

        Command.new(
          name: name,
          description: description.empty? ? name : description,
          argument_hint: frontmatter['argument-hint']&.to_s,
          location: path,
          body: body,
          refusal: refusal,
          sidecars: sidecars?(File.dirname(path))
        )
      rescue Errno::ENOENT, Errno::EACCES => e
        LOGGER.warn("#{path}: #{e.class}: #{e.message}; skipped")
        nil
      end

      # Both spellings of the key: the documented +allowed-tools+ and the
      # underscore form an author is as likely to write.
      def refusal_for(frontmatter, body)
        if frontmatter.key?('allowed-tools') || frontmatter.key?('allowed_tools')
          'declares allowed-tools:, which pikuri cannot honour (an agent\'s toolset ' \
          'is fixed at configure time, so ignoring the key would *widen* it)'
        elsif body.match?(/!`/)
          'contains a !`…` bash pre-execution directive, which pikuri never runs'
        end
      end

      # True when +dir+ holds anything the registry did not load as a command.
      # A subdirectory full of commands is a *namespace*, not a sidecar, so it
      # does not count; a directory of nothing but commands — the common case
      # — gets no footer and stays quiet.
      def sidecars?(dir)
        Dir.children(dir).any? do |entry|
          child = File.join(dir, entry)
          if File.directory?(child)
            Dir.glob('**/*.md', base: child).empty?
          else
            !entry.end_with?('.md')
          end
        end
      rescue Errno::ENOENT, Errno::EACCES
        false
      end
    end
  end
end
