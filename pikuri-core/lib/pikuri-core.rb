# frozen_string_literal: true

require 'logger'
require 'zeitwerk'

# +Pikuri::VERSION+ lives in its own tiny file so the gemspec can read
# the version constant via +require_relative+ at build time without
# loading Zeitwerk and every runtime dep. Requiring it here makes the
# constant available to ordinary +require 'pikuri-core'+ callers too —
# without this line, Zeitwerk's ignore-rule below would leave
# +Pikuri::VERSION+ undefined for anyone using the installed gem.
require_relative 'pikuri/version'

# Boot file: configures the Zeitwerk autoloader for every file under
# +pikuri-core/lib/pikuri/+ and eager-loads them all. After
# +require 'pikuri-core'+, every constant pikuri-core ships
# (+Pikuri::Agent+, +Pikuri::Tool+, +Pikuri::Tool::Calculator+, ...)
# is defined and resolvable. Sibling gems (+pikuri-skills+,
# +pikuri-mcp+, ...) set up their own Zeitwerk loaders rooted at
# their own +lib/+ and contribute to the same +Pikuri::+ namespace.
#
# Beyond loading, the +Pikuri+ module owns the logging surface — see
# {.logger_for}, {.log_io=}, and the +PIKURI_LOG+ /
# +PIKURI_LOG_<NAME>+ env vars. Each subsystem holds its own
# memoized +Logger+, all writing through a shared IO that
# {.log_io=} can swap in one shot (handy in tests, daemons, or
# anywhere stderr isn't the right sink).
#
# == Why eager-load
#
# Tool implementations (+Pikuri::Tool::CALCULATOR+,
# +Pikuri::Tool::WEB_SEARCH+, +Pikuri::Tool::WEB_SCRAPE+,
# +Pikuri::Tool::FETCH+) are +ALL_CAPS+ value constants rather than
# classes/modules, and Zeitwerk only auto-loads constants that match
# its filename-↔-CamelCase convention. Eager-loading at boot guarantees
# the files defining those values run, so the bin script can drop them
# straight into the +Agent.new+ block via +c.add_tool+ without per-file
# +require+ ceremony. The cost is a few milliseconds of startup —
# negligible compared to a single LLM round-trip.
module Pikuri
  # Search path for bundled system prompts. Mutable list: each pikuri
  # gem appends its own +prompts/+ directory when it boots, so a
  # +Pikuri.prompt(name)+ call from a host that requires +pikuri-code+
  # (for example) finds +coding-system-prompt.txt+ in
  # +pikuri-code/prompts/+. The core gem registers its own
  # +pikuri-core/prompts/+ below; sibling gems do the equivalent in
  # their own entry files.
  #
  # Exposed publicly so a downstream library user can read pikuri's
  # prompts as a starting point for their own system prompt (or
  # use them verbatim). Prefer {.prompt} for the common case of
  # loading one by name.
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

    # Swap the shared sink (e.g. a +StringIO+ in tests, a file in a
    # daemon). Re-points every logger already handed out by
    # {.logger_for} so callers don't have to re-fetch them.
    #
    # Why we don't use +Logger#reopen+: that method closes the previous
    # sink before installing the new one, which makes "swap to a
    # capture +StringIO+, then swap back to the original" impossible —
    # the original handle would be dead the second time around. Instead
    # we swap each logger's +@logdev+ to a fresh +Logger::LogDevice+
    # over the new +io+, leaving the previous device untouched so the
    # caller can hand the same +IO+ back in later. This uses a documented
    # but internal Logger ivar; if a future Ruby renames it the
    # +Engines+ logging specs will fail loudly.
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

    # Memoized {Logger} tagged with +name+ in its +progname+, so each
    # subsystem's lines stand out in the shared sink. Level resolves
    # in this order: +PIKURI_LOG_<NAME>+ (e.g. +PIKURI_LOG_ENGINES=debug+),
    # then +PIKURI_LOG+, then +INFO+.
    #
    # Repeated calls with the same +name+ return the same instance so
    # there is one logger per subsystem and {.log_io=} can rewire them
    # all in one shot.
    #
    # @param name [String] subsystem tag (rendered as +progname+)
    # @return [Logger]
    def logger_for(name)
      @log_loggers[name] ||= begin
        lg = Logger.new(@log_io, progname: name)
        override = ENV["PIKURI_LOG_#{name.upcase}"].to_s.downcase
        lg.level = LOG_LEVELS.fetch(override, @log_default)
        lg
      end
    end

    # Read a bundled prompt by basename. Searches every directory in
    # {PROMPT_DIRS} in order, returning the first match. +.txt+ is
    # auto-appended if absent. Symbols are accepted as a convenience
    # (+:pikuri-chat+ / +'pikuri-chat'+ / +'pikuri-chat.txt'+ all
    # resolve to the same file).
    #
    # Intended for downstream library users who want to bootstrap their
    # own +Pikuri::Agent+ wiring from pikuri's defaults — read the
    # prompt, customize the bits they care about, hand the result to
    # +Agent.new(system_prompt: ...)+.
    #
    # @example
    #   chat_prompt = Pikuri.prompt(:'pikuri-chat')
    #   agent = Pikuri::Agent.new(system_prompt: chat_prompt, ...)
    #
    # @param name [String, Symbol] basename of the prompt file
    # @return [String] file contents
    # @raise [ArgumentError] if no matching file exists in any
    #   directory in {PROMPT_DIRS}
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

  # Zeitwerk loader managing every constant under
  # +pikuri-core/lib/pikuri/+. Exposed as a constant (rather than scoped
  # to the boot block) so a downstream host that wants to add ignore
  # rules can reach it without monkey-patching. Sibling gems
  # (+pikuri-skills+, +pikuri-mcp+, ...) set up their own loaders
  # rooted at their own +lib/+ dirs — see each gem's entry file.
  #
  # @return [Zeitwerk::Loader]
  Loader = Zeitwerk::Loader.new
  Loader.tag = 'pikuri-core'
  Loader.push_dir(File.expand_path('.', __dir__))
  Loader.ignore(__FILE__)
  # +pikuri/version.rb+ defines +Pikuri::VERSION+ (an ALL_CAPS value
  # constant), not +Pikuri::Version+ as Zeitwerk would expect from the
  # filename — so tell the loader to skip it. The file is +require_relative+'d
  # at the top of this file (and also by the gemspec at build time), so
  # the constant is defined before Zeitwerk runs.
  Loader.ignore(File.expand_path('pikuri/version.rb', __dir__))
  Loader.inflector.inflect(
    'html'       => 'HTML',
    'pdf'        => 'PDF',
    'duckduckgo' => 'DuckDuckGo'
  )
  Loader.setup
  Loader.eager_load
end
