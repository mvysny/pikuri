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

# Silence Pikuri's default $stderr logger for the suite so production
# log lines don't bleed into rspec output. Specs that exercise logging
# (e.g. spec/tool/search/engines_spec.rb) swap in their own +Logger+
# pointed at a +StringIO+.
Pikuri.logger = Logger.new(File::NULL)

RSpec.configure do |config|
  config.include Minitest::Assertions
  config.include(Module.new do
    attr_writer :assertions

    def assertions
      @assertions ||= 0
    end
  end)
end
