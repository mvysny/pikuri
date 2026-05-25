# frozen_string_literal: true

RSpec.describe Pikuri::Agent::Control::Interloper do
  describe '#initialize' do
    it 'starts empty — peek is empty, pending? is false, drain! returns []' do
      interloper = described_class.new
      assert_equal [], interloper.peek
      refute interloper.pending?
      assert_equal [], interloper.drain!
    end
  end

  describe '#inject_user_message' do
    it 'rejects nil content' do
      assert_raises(ArgumentError) { described_class.new.inject_user_message(nil) }
    end

    it 'rejects empty content' do
      assert_raises(ArgumentError) { described_class.new.inject_user_message('') }
    end

    it 'rejects whitespace-only content' do
      assert_raises(ArgumentError) { described_class.new.inject_user_message("   \t\n") }
    end

    it 'pushes onto the queue, observable via #peek and #pending?' do
      interloper = described_class.new
      interloper.inject_user_message('hi')

      assert_equal ['hi'], interloper.peek
      assert interloper.pending?
    end

    it 'preserves FIFO order across multiple injections' do
      interloper = described_class.new
      interloper.inject_user_message('one')
      interloper.inject_user_message('two')
      interloper.inject_user_message('three')

      assert_equal %w[one two three], interloper.peek
    end

    it 'returns nil' do
      assert_nil described_class.new.inject_user_message('x')
    end
  end

  describe '#peek' do
    it 'returns a copy — mutating the result does not mutate the queue' do
      interloper = described_class.new
      interloper.inject_user_message('a')

      snapshot = interloper.peek
      snapshot << 'b'

      assert_equal ['a'], interloper.peek
    end
  end

  describe '#drain!' do
    it 'returns [] when empty (no allocation churn on the hot path)' do
      interloper = described_class.new
      assert_equal [], interloper.drain!
      assert_equal [], interloper.drain!
    end

    it 'returns every item in delivery order, then leaves the queue empty' do
      interloper = described_class.new
      interloper.inject_user_message('one')
      interloper.inject_user_message('two')

      assert_equal %w[one two], interloper.drain!

      refute interloper.pending?
      assert_equal [], interloper.peek
      assert_equal [], interloper.drain!
    end

    it 'items injected between drains are returned on the subsequent drain' do
      interloper = described_class.new
      interloper.inject_user_message('a')
      assert_equal ['a'], interloper.drain!

      interloper.inject_user_message('b')
      assert_equal ['b'], interloper.drain!
    end
  end

  describe 'cross-thread inject_user_message' do
    it 'a push from another thread is observed at the next drain!' do
      interloper = described_class.new

      Thread.new { interloper.inject_user_message('from another thread') }.join

      assert_equal ['from another thread'], interloper.drain!
    end
  end

  describe '#to_s' do
    it 'renders the bare class name when idle' do
      assert_equal 'Interloper', described_class.new.to_s
    end

    it 'renders the pending count when items are queued' do
      interloper = described_class.new
      interloper.inject_user_message('one')
      interloper.inject_user_message('two')
      assert_equal 'Interloper(2 pending)', interloper.to_s
    end
  end
end
