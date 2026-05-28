# frozen_string_literal: true

require 'rspec/core'
require 'minitest'
require 'minitest/assertions'

require 'pikuri-todo'

# Silence Pikuri's default $stderr logging for the suite so production
# log lines don't bleed into rspec output.
Pikuri.log_io = File.open(File::NULL, 'w')

# Match pikuri-core's spec_helper minitest wiring: mix the
# assertion module in + provide the `assertions` accessor that
# `assert_equal` and friends require internally. CLAUDE.md's
# "Tests" convention — minitest-style assertions inside rspec
# example groups.
RSpec.configure do |config|
  config.include Minitest::Assertions
  config.include(Module.new do
    attr_writer :assertions

    def assertions
      @assertions ||= 0
    end
  end)
end
