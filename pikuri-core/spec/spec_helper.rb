# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'rspec/core'
require 'minitest'
require 'minitest/assertions'

require 'pikuri-core'

# Disable caching by default in the test suite. The specs that genuinely
# exercise caching opt back in by stubbing an accessor with a real
# {Pikuri::UrlCache::OnDisk} on a tmpdir, or a fresh {Pikuri::UrlCache::InMemory}.
[Pikuri::Tool::WebScrape, Pikuri::Tool::Fetch].each do |mod|
  mod.singleton_class.define_method(:cache) { Pikuri::UrlCache::NULL }
end
# The class-level defaults +Engines.new(disk_cache:, memory_cache:)+ falls back
# to, so every engine built in the suite (including via
# +Tool::WebSearch.build+) defaults to NULL.
%i[disk_cache memory_cache].each do |accessor|
  Pikuri::Tool::Search::Engines.singleton_class.define_method(accessor) { |**| Pikuri::UrlCache::NULL }
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

    # Minitest::Assertions#skip shadows rspec's own and raises an
    # exception rspec reports as a *failure* — so an environment guard
    # (`skip 'git not on PATH'`) reddens the build on precisely the
    # hosts it means to excuse. Delegate back to rspec's pending
    # machinery; the trailing backtrace arg is minitest's signature.
    def skip(message = nil, _backtrace = nil)
      RSpec::Core::Pending.instance_method(:skip).bind_call(self, message)
    end
  end)
end
