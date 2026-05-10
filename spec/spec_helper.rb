# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'rspec/core'
require 'minitest'
require 'minitest/assertions'

require 'pikuri'

# Disable on-disk caching by default in the test suite. The specs that
# genuinely exercise caching behavior opt back in by stubbing +.cache+
# with a real {UrlCache} pointed at a tmpdir.
[Tool::WebScrape, Tool::Fetch, Tool::Search::Engines].each do |mod|
  mod.singleton_class.define_method(:cache) { UrlCache::NULL }
end

RSpec.configure do |config|
  config.include Minitest::Assertions
  config.include(Module.new do
    attr_writer :assertions

    def assertions
      @assertions ||= 0
    end
  end)
end
