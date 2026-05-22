# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'rspec/core'
require 'minitest'
require 'minitest/assertions'

require 'pikuri-core'

# Disable on-disk caching by default in the test suite. The specs that
# genuinely exercise caching behavior opt back in by stubbing +.cache+
# with a real {Pikuri::UrlCache} pointed at a tmpdir.
[Pikuri::Tool::WebScrape, Pikuri::Tool::Fetch, Pikuri::Tool::Search::Engines].each do |mod|
  mod.singleton_class.define_method(:cache) { Pikuri::UrlCache::NULL }
end

# Silence Pikuri's default $stderr logging for the suite so production
# log lines don't bleed into rspec output. Specs that exercise logging
# (e.g. spec/tool/search/engines_spec.rb) swap +Pikuri.log_io+ to a
# +StringIO+ and restore it.
Pikuri.log_io = File.open(File::NULL, 'w')

RSpec.configure do |config|
  config.include Minitest::Assertions
  config.include(Module.new do
    attr_writer :assertions

    def assertions
      @assertions ||= 0
    end
  end)
end
