# frozen_string_literal: true

module Pikuri
  module Thunderbird
    # Detached launch of the user's Thunderbird — the shared mechanism behind
    # both outbound tools. Given an argument Thunderbird understands on its
    # command line (a +mailto:+ URI for {MailCompose}, an +.ics+ path for
    # {CalendarCreate}), it opens it in the running instance:
    #
    #   Launcher.new.launch('mailto:a@x.com?body=hi')   # compose window
    #   Launcher.new.launch('/…/pikuri-outbox/x.ics')   # import wizard
    #
    # It never sends or imports anything itself — the argument only *opens* a
    # window/wizard the human reviews and commits, which is the no-send seam.
    #
    # == Why detached (+setsid --fork+)
    #
    # The launch is +setsid --fork thunderbird <arg>+, putting Thunderbird in its
    # own session. Load-bearing two ways, both silent under test: (1) closing the
    # agent must never SIGTERM the user's running Thunderbird — the
    # {Pikuri::Subprocess} exit-sweep would, but the detached grandchild is out of
    # our process group; (2) when Thunderbird isn't already running, a foreground
    # launch would block the calling tool on the GUI. Don't drop the detach.
    class Launcher
      # Recoverable launch failure (binary missing, spawn error); the calling
      # tool turns it into an +"Error: …"+ observation.
      class Error < StandardError; end

      # @param thunderbird_bin [String] test seam — the executable, a PATH name
      #   (default +"thunderbird"+) or an absolute path.
      # @param spawn [#call, nil] test seam — a callable given the argument that
      #   returns a {Pikuri::Subprocess} result (responds to +#status+ /
      #   +#output+). +nil+ uses the real detached spawn.
      # @return [Launcher]
      def initialize(thunderbird_bin: 'thunderbird', spawn: nil)
        @thunderbird_bin = thunderbird_bin
        @spawn = spawn || method(:detached_spawn)
      end

      # Launch Thunderbird on +arg+.
      #
      # @param arg [String] a +mailto:+ URI or a filesystem path.
      # @return [void]
      # @raise [Error] if the binary is missing or the spawn fails.
      def launch(arg)
        unless resolvable?(@thunderbird_bin)
          raise Error, "Thunderbird executable #{@thunderbird_bin.inspect} not found on PATH — " \
                       'is Thunderbird installed?'
        end

        result = @spawn.call(arg)
        return if result.status.success?

        raise Error, "couldn't hand off to Thunderbird (#{result.output.strip.slice(0, 200)})."
      end

      private

      # De-bundlerized ({Pikuri::BundlerEnv}): a Thunderbird not yet running
      # starts here as the user's own instance, outlives pikuri, and passes its
      # environment to everything it launches.
      #
      # @param arg [String] the argument to open.
      # @return [Object] the {Pikuri::Subprocess} wait result.
      def detached_spawn(arg)
        Pikuri::Subprocess.spawn('setsid', '--fork', @thunderbird_bin, arg,
                                 chdir: Dir.home, env: Pikuri::BundlerEnv.clean_delta).wait
      end

      # @param bin [String] a PATH name or absolute path.
      # @return [Boolean] whether it resolves to an executable.
      def resolvable?(bin)
        return File.executable?(bin) if bin.include?(File::SEPARATOR)

        ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).any? do |dir|
          File.executable?(File.join(dir, bin))
        end
      end
    end
  end
end
