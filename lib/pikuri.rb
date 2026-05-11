# frozen_string_literal: true

require 'logger'
require 'zeitwerk'

# Boot file: configures the Zeitwerk autoloader for every file under
# +lib/+ and eager-loads them all. After +require 'pikuri'+, every
# constant pikuri ships (`Agent`, `Tool`, `Tool::Calculator`,
# `Tool::Scraper::HTML`, …) is defined and resolvable.
#
# Beyond loading, the +Pikuri+ module owns one piece of process-wide
# state: the {.logger} that the rest of the codebase writes
# diagnostics to. Otherwise the interesting code lives under
# top-level constants (`Tool`, `Agent`, `UrlCache`) that Zeitwerk
# discovers from filenames — pikuri is a CLI, not a library people
# import as a namespace.
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
  # Process-wide logger, written to +$stderr+. Defaults to +INFO+; set
  # the +PIKURI_LOG+ environment variable to one of +debug+, +info+,
  # +warn+, +error+, +fatal+ (case-insensitive) to override. Callers
  # may reassign +Pikuri.logger=+ to reroute output (e.g. to a file or
  # a +StringIO+ in tests).
  #
  # @return [Logger]
  LOG_LEVELS = {
    'debug' => Logger::DEBUG,
    'info'  => Logger::INFO,
    'warn'  => Logger::WARN,
    'error' => Logger::ERROR,
    'fatal' => Logger::FATAL
  }.freeze

  @logger = Logger.new($stderr)
  @logger.level = LOG_LEVELS.fetch(ENV['PIKURI_LOG'].to_s.downcase, Logger::INFO)

  class << self
    # @return [Logger] process-wide logger; see the {Pikuri} module docs
    attr_accessor :logger
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
