# frozen_string_literal: true

require 'logger'
require 'zeitwerk'

# +Pikuri::VERSION+ lives in its own tiny file so the gemspec can +require_relative+
# it at build time without loading Zeitwerk and every runtime dep. Requiring it
# here also defines the constant for ordinary +require 'pikuri-core'+ callers —
# without this line the Zeitwerk ignore-rule below would leave it undefined.
require_relative 'pikuri/version'

# Boot file: configures the Zeitwerk autoloader for +pikuri-core/lib/pikuri/+
# and eager-loads it, so after +require 'pikuri-core'+ every constant
# pikuri-core ships is defined. Sibling gems set up their own loaders into the
# same +Pikuri::+ namespace.
#
# The +Pikuri+ module also owns the logging surface ({.logger_for}, {.log_io=},
# the +PIKURI_LOG+ / +PIKURI_LOG_<NAME>+ env vars): each subsystem holds a
# memoized +Logger+ writing through a shared IO that {.log_io=} swaps in one shot.
#
# == Why eager-load
#
# The stateless bundled tools (+Tool::CALCULATOR+, +Tool::WEB_SCRAPE+,
# +Tool::FETCH+) are +ALL_CAPS+ value constants, and Zeitwerk only auto-loads
# constants matching its filename↔CamelCase convention. Eager-loading runs the
# files defining those values so a bin script can +c.add_tool+ them without
# per-file +require+. (web_search is host-configured via
# {Tool::WebSearch.build}, so it's not a value constant.) Cost: a few ms.
module Pikuri
  # Search path for bundled system prompts. Mutable: each pikuri gem appends its
  # own +prompts/+ at boot, so +Pikuri.prompt(name)+ from a host requiring
  # +pikuri-code+ finds +coding-system-prompt.txt+ there. Public so a downstream
  # user can read pikuri's prompts as a starting point; prefer {.prompt}.
  #
  # @return [Array<String>]
  PROMPT_DIRS = [File.expand_path('../prompts', __dir__)]

  # Mapping from +PIKURI_LOG+ env-var values (lowercased) to
  # {Logger} level constants. Anything else falls back to +INFO+.
  #
  # @return [Hash{String=>Integer}]
  LOG_LEVELS = {
    'debug' => Logger::DEBUG,
    'info'  => Logger::INFO,
    'warn'  => Logger::WARN,
    'error' => Logger::ERROR,
    'fatal' => Logger::FATAL
  }.freeze

  @log_io      = $stderr
  @log_loggers = {} # name → Logger; lets {.log_io=} rewire all of them
  @log_default = LOG_LEVELS.fetch(ENV['PIKURI_LOG'].to_s.downcase, Logger::INFO)

  class << self
    # @return [IO] shared sink every {.logger_for} writes through
    attr_reader :log_io

    # Swap the shared sink (a +StringIO+ in tests, a file in a daemon),
    # re-pointing every logger already handed out by {.logger_for}.
    #
    # Not +Logger#reopen+: it closes the previous sink before installing the new
    # one, which makes "swap to a capture StringIO, then swap back" impossible —
    # the original handle would be dead. Instead we swap each logger's +@logdev+
    # to a fresh +Logger::LogDevice+ over +io+, leaving the previous device
    # open. Uses an internal Logger ivar; if a future Ruby renames it the
    # +Engines+ logging specs fail loudly.
    #
    # @param io [IO] new sink for every Pikuri logger
    # @return [IO]
    def log_io=(io)
      @log_io = io
      @log_loggers.each_value do |lg|
        lg.instance_variable_set(:@logdev, Logger::LogDevice.new(io))
      end
      io
    end

    # Memoized {Logger} tagged with +name+ as its +progname+. Level resolves
    # +PIKURI_LOG_<NAME>+ → +PIKURI_LOG+ → +INFO+. Repeated calls with the same
    # +name+ return the same instance, so {.log_io=} can rewire them all.
    #
    # @param name [String] subsystem tag (the +progname+)
    # @return [Logger]
    def logger_for(name)
      @log_loggers[name] ||= begin
        lg = Logger.new(@log_io, progname: name)
        override = ENV["PIKURI_LOG_#{name.upcase}"].to_s.downcase
        lg.level = LOG_LEVELS.fetch(override, @log_default)
        lg
      end
    end

    # Read a bundled prompt by basename, searching {PROMPT_DIRS} in order
    # (+.txt+ auto-appended; Symbols accepted). For downstream users
    # bootstrapping their own +Agent+ wiring from pikuri's defaults.
    #
    # @example
    #   agent = Pikuri::Agent.new(system_prompt: Pikuri.prompt(:'pikuri-chat'), ...)
    #
    # @param name [String, Symbol] basename of the prompt file
    # @return [String] file contents
    # @raise [ArgumentError] if no matching file exists in any {PROMPT_DIRS}
    def prompt(name)
      basename = name.to_s
      basename += '.txt' unless basename.end_with?('.txt')
      PROMPT_DIRS.each do |dir|
        path = File.join(dir, basename)
        return File.read(path) if File.exist?(path)
      end
      available = PROMPT_DIRS.flat_map { |dir| Dir.exist?(dir) ? Dir.children(dir) : [] }.sort.uniq
      raise ArgumentError, "Unknown pikuri prompt #{name.inspect}; available: #{available.join(', ')}"
    end
  end

  # Zeitwerk loader for every constant under +pikuri-core/lib/pikuri/+. A
  # constant (not block-scoped) so a downstream host can add ignore rules
  # without monkey-patching. Sibling gems set up their own loaders.
  #
  # @return [Zeitwerk::Loader]
  Loader = Zeitwerk::Loader.new
  Loader.tag = 'pikuri-core'
  Loader.push_dir(File.expand_path('.', __dir__))
  Loader.ignore(__FILE__)
  # +pikuri/version.rb+ defines the ALL_CAPS +Pikuri::VERSION+, not
  # +Pikuri::Version+ as Zeitwerk expects — so skip it (it's +require_relative+'d
  # above and by the gemspec, so the constant is already defined).
  Loader.ignore(File.expand_path('pikuri/version.rb', __dir__))
  # +pikuri/testing.rb+ is opt-in test scaffolding (+require 'pikuri/testing'+
  # from a spec), kept off the production load path — so don't autoload or
  # eager-load it. See {Pikuri::Testing}.
  Loader.ignore(File.expand_path('pikuri/testing.rb', __dir__))
  Loader.inflector.inflect(
    'html'       => 'HTML',
    'duckduckgo' => 'DuckDuckGo'
  )
  Loader.setup
  Loader.eager_load

  # Reap +~/.cache/pikuri/temp-*+ scratch left by processes killed before their
  # {Pikuri::Finalizers} reap could fire. Best-effort, once per process at the
  # earliest load point (every gem requires pikuri-core). See {Paths.new_temp}.
  Paths.sweep_stale_temps!
end
