source 'https://rubygems.org'

# HTTP client. Used by the web-fetch scraper, the Brave / DuckDuckGo
# search providers, and (transitively) by ruby_llm.
gem 'faraday', '~> 2.9'

# ANSI color for terminal output (reasoning dim, tool calls cyan, …) in
# the agent loop.
gem 'rainbow', '~> 3.1'

# Renders the assistant's Markdown replies to a terminal-friendly form
# in the agent loop.
gem 'tty-markdown', '~> 0.7'

# HTML parser. Used by the web-fetch scraper and by both search providers
# (Brave, DuckDuckGo) to extract results from HTML responses.
gem 'nokogiri', '~> 1.19'

# Readability-style main-content extraction (require 'readability'). Used
# by Tool::Scraper::Simple to strip chrome from fetched pages before
# converting to Markdown.
gem 'ruby-readability', '~> 0.7'

# HTML → Markdown conversion. Used by Tool::Scraper::Simple to hand the
# LLM Markdown rather than raw HTML.
gem 'reverse_markdown', '~> 3.0'

# PDF text extraction. Used by Tool::Scraper::PDF to render application/pdf
# responses as plain text for the agent loop.
gem 'pdf-reader', '~> 2.15'

# LLM transport + agent loop. Pikuri sits on top of ruby_llm; see
# CLAUDE.md "Risks worth tracking" for the bus-factor and Chat-API-churn
# rationale behind the tight pin.
gem 'ruby_llm', '~> 1.15'

# Convention-based autoloader for lib/. Set up in lib/pikuri.rb; lets
# every file declare exactly the constant matching its path without the
# require_relative ceremony that creeps in once a project grows.
gem 'zeitwerk', '~> 2.7'

# Arithmetic backend for Tool::CALCULATOR.
gem 'dentaku', '~> 3.5'
# Dentaku 3.5 transitively requires tsort, which was a default gem in
# Ruby <= 4.0 and will be removed from defaults in 4.1. Pinning it
# silences the load-time deprecation warning.
gem 'tsort', '~> 0.2'

group :test do
  # Test runner. We use the rspec-core describe/it harness but write
  # assertions in minitest style — see CLAUDE.md.
  gem 'rspec-core', '~> 3.13'

  # Provides the minitest-style assertion methods (assert_equal, refute,
  # …) used throughout spec/.
  gem 'minitest', '~> 6.0'

  # Time freezing. Used by the rate-limiter spec to test the 2s
  # DuckDuckGo throttle without sleeping in real time.
  gem 'timecop', '~> 0.9'
end

group :development do
  # Generates YARD docs from the inline tags required by CLAUDE.md.
  gem 'yard', '~> 0.9.43'
end
