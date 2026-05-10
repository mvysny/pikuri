# frozen_string_literal: true

class Tool
  # Namespace for the HTTP→Markdown scraper stack: {Simple} owns the
  # Faraday GET + content-type dispatch, {HTML} and {PDF} are pure
  # extractors. Files under +lib/tool/scraper/+ each define their own
  # leaf constant; this file owns only the namespace and the shared
  # exception type.
  module Scraper
    # Raised by anything in the scraper stack when a URL cannot be
    # rendered into Markdown text — HTTP non-2xx, network failure,
    # redirect-loop, missing +Location+, unsupported content-type, or a
    # parse failure that reads as "try a different URL" to the LLM.
    # Catching this in {Tool::WEB_SCRAPE} / {Tool::FETCH} turns the
    # failure into an +"Error: ..."+ observation; anything else bubbles
    # up so genuine bugs stay visible.
    class FetchError < StandardError; end
  end
end
