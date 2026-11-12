# frozen_string_literal: true

require 'pikuri-core'

# Entry file for the pikuri-web gem: mounts a per-gem Zeitwerk loader at this
# +lib/+ and eager-loads it, so the +ALL_CAPS+ tool constants ({Pikuri::Web::FETCH}
# and friends), which Zeitwerk's filename↔CamelCase rule won't auto-load, are
# defined at boot; then registers {Pikuri::Web::HTML} with the extractor registry.
module Pikuri
  # The tools that reach the internet: search, scrape, fetch, and a reader for a
  # search's stored page text.
  #
  #   c.add_tool Pikuri::Web::Search.from_h(examples_config['search'])
  #   c.add_tool Pikuri::Web::SCRAPE
  #   c.add_tool Pikuri::Web::FETCH
  #
  # Every tool here brings untrusted text in, and all but {READ_CACHED} send
  # bytes out — {SCRAPE} and {FETCH} to any host the model names. That is why
  # they live outside pikuri-core: an agent that needs none of them never loads
  # them, and wiring one is a visible choice on the trifecta map.
  #
  # For a search-only agent, pair a +page_text+ {Search.build} with
  # {READ_CACHED} rather than {SCRAPE}; see {Search.build}.
  module Web
    LOADER = Zeitwerk::Loader.new
    LOADER.tag = 'pikuri-web'
    LOADER.push_dir(File.expand_path('.', __dir__))
    LOADER.ignore(__FILE__)
    LOADER.inflector.inflect('duckduckgo' => 'DuckDuckGo', 'html' => 'HTML')
    LOADER.setup
    LOADER.eager_load

    HTML.register
  end
end
