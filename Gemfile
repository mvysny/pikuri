source 'https://rubygems.org'

# Monorepo layout: each gem (pikuri-core, plus extensions and the
# +pikuri+ metagem as they're extracted) lives in its own subdirectory
# with its own gemspec. Bundler is pointed at each via +gemspec path:+
# below so a checkout-mode +bundle install+ resolves local sibling
# versions rather than reaching out to rubygems. After release, end
# users install via +gem install pikuri-core+ (or +gem install pikuri+
# for the metagem) and the gemspec's +add_dependency+ entries take
# over.
gemspec path: 'pikuri-core'
gemspec path: 'pikuri-skills'
gemspec path: 'pikuri-tasks'
gemspec path: 'pikuri-mcp'
gemspec path: 'pikuri-workspace'
gemspec path: 'pikuri-code'
gemspec path: 'pikuri-subagents'
gemspec path: 'pikuri-assistant'
gemspec path: 'pikuri'

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

  # REPL for bin/console. Was a default gem in Ruby <= 3.x and dropped
  # from defaults in 4.0, so it must be declared explicitly.
  gem 'irb', '~> 1.14'

  # Drives the top-level Rakefile (lockstep release task + fan-out
  # test task across the monorepo's gems). Was a default gem; declared
  # explicitly so Bundler installs it for development.
  gem 'rake', '~> 13.0'
end
