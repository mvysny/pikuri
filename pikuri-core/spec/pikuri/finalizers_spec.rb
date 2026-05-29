# frozen_string_literal: true

require 'stringio'

RSpec.describe Pikuri::Finalizers do
  # Isolate the process-global registry per example: swap in a fresh
  # list around each spec and restore the real one after, so registering
  # and running here can't close resources other specs registered (and
  # vice versa). Mirrors the log_io / spawn swaps used elsewhere in the
  # suite.
  before do
    @saved = described_class.instance_variable_get(:@registered)
    described_class.instance_variable_set(:@registered, [])
  end

  after do
    described_class.instance_variable_set(:@registered, @saved)
  end

  describe '.register / .run!' do
    it 'closes registrants in LIFO order' do
      order = []
      described_class.register { order << :a }
      described_class.register { order << :b }
      described_class.register { order << :c }

      described_class.run!

      assert_equal %i[c b a], order
    end

    it 'calls #close on a registered object' do
      closed = false
      obj = Object.new
      obj.define_singleton_method(:close) { closed = true }
      described_class.register(obj)

      described_class.run!

      assert closed
    end

    it 'continues the sweep when a registrant raises, and logs it' do
      ran = []
      described_class.register { ran << :first_registered }
      described_class.register { raise 'boom' }
      described_class.register { ran << :last_registered }

      io = StringIO.new
      previous = Pikuri.log_io
      Pikuri.log_io = io
      begin
        described_class.run! # must not raise
      ensure
        Pikuri.log_io = previous
      end

      # LIFO: last registered runs first, the raiser is skipped, the
      # first registered still runs.
      assert_equal %i[last_registered first_registered], ran
      assert_match(/finalizer .*raised RuntimeError: boom/, io.string)
    end

    it 'drains the registry so a second run! closes nothing' do
      count = 0
      described_class.register { count += 1 }

      described_class.run!
      described_class.run!

      assert_equal 1, count
    end

    it 'raises ArgumentError without an object or a block' do
      assert_raises(ArgumentError) { described_class.register }
    end
  end

  describe '.unregister' do
    it 'drops a handle so it is not closed at run!' do
      closed = false
      handle = described_class.register { closed = true }

      described_class.unregister(handle)
      described_class.run!

      refute closed
    end

    it 'is a no-op for a handle that was never registered' do
      described_class.unregister(Object.new) # must not raise
    end
  end
end
