# frozen_string_literal: true

require 'rspec/core'
require 'minitest'
require 'minitest/assertions'

require 'pikuri-skills'

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
