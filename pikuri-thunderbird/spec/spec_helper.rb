# frozen_string_literal: true

require 'rspec/core'
require 'minitest'
require 'minitest/assertions'

require 'pikuri-thunderbird'

# Silence Pikuri's default $stderr logging for the suite.
Pikuri.log_io = File.open(File::NULL, 'w')

# CLAUDE.md "Tests" convention: rspec-core describe/it groups, minitest
# assertions. Mix the assertion module in + provide the `assertions`
# accessor the assert_* helpers need internally.
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
