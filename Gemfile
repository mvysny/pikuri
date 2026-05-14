source 'https://rubygems.org'

# Runtime deps are declared in pikuri.gemspec (one source of truth for
# anyone who installs pikuri as a gem). The `gemspec` directive below
# pulls them into Bundler's dependency graph so `bundle install` from
# a source checkout resolves the same set.
gemspec

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
end
