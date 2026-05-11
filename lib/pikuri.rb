# frozen_string_literal: true

require 'logger'
require 'zeitwerk'

# Boot file: configures the Zeitwerk autoloader for every file under
# +lib/+ and eager-loads them all. After +require 'pikuri'+, every
# constant pikuri ships (`Agent`, `Tool`, `Tool::Calculator`,
# `Tool::Scraper::HTML`, …) is defined and resolvable.
#
# Beyond loading, the +Pikuri+ module owns the logging surface — see
# {.logger_for}, {.log_io=}, and the +PIKURI_LOG+ /
# +PIKURI_LOG_<NAME>+ env vars. Each subsystem holds its own
# memoized +Logger+, all writing through a shared IO that
# {.log_io=} can swap in one shot (handy in tests, daemons, or
# anywhere stderr isn't the right sink). Otherwise the interesting
# code lives under top-level constants (`Tool`, `Agent`, `UrlCache`)
# that Zeitwerk discovers from filenames — pikuri is a CLI, not a
# library people import as a namespace.
#
# == Why eager-load
#
# Tool implementations (`Tool::CALCULATOR`, `Tool::WEB_SEARCH`,
# `Tool::WEB_SCRAPE`, `Tool::FETCH`) are +ALL_CAPS+ value constants
# rather than classes/modules, and Zeitwerk only auto-loads constants
# that match its filename-↔-CamelCase convention. Eager-loading at
# boot guarantees the files defining those values run, so the bin
# script can splat them straight into +Agent.new(tools: [...])+
# without per-file +require+ ceremony. The cost is a few milliseconds
# of startup — negligible compared to a single LLM round-trip.
module Pikuri
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
  end

  Loader = Zeitwerk::Loader.new
  Loader.tag = 'pikuri'
  Loader.push_dir(File.expand_path('.', __dir__))
  Loader.ignore(__FILE__)
  Loader.inflector.inflect(
    'html'       => 'HTML',
    'pdf'        => 'PDF',
    'duckduckgo' => 'DuckDuckGo'
  )
  Loader.setup
  Loader.eager_load
end
