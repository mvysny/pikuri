# frozen_string_literal: true

require 'zeitwerk'

# Boot file: configures the Zeitwerk autoloader for every file under
# +lib/+ and eager-loads them all. After +require 'pikuri'+, every
# constant pikuri ships (`Agent`, `Tool`, `Tool::Calculator`,
# `Tool::Scraper::HTML`, …) is defined and resolvable.
#
# The +Pikuri+ module itself is a marker — pikuri is a CLI rather than
# a library people import as a namespace, so the interesting code lives
# under top-level constants (`Tool`, `Agent`, `UrlCache`) that Zeitwerk
# discovers from filenames.
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
