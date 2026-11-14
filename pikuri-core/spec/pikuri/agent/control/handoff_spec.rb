# frozen_string_literal: true

RSpec.describe Pikuri::Agent::Control::Handoff do
  let(:cancellable) { Pikuri::Agent::Control::Cancellable.new }
  let(:handoff) { described_class.new(cancellable) }

  def elapsed_since(started) = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

  describe '#await' do
    it 'answers a value completed before the wait' do
      handoff.complete(:approved)
      assert_equal :approved, handoff.await
    end

    it 'answers nil when completed with nil' do
      handoff.complete(nil)
      assert_nil handoff.await
    end

    it 'blocks until another thread completes it' do
      completer = Thread.new { Kernel.sleep(0.05); handoff.complete(:approved) }
      assert_equal :approved, handoff.await
      completer.join
    end

    it 'raises at once when the token is already cancelled' do
      cancellable.cancel!
      assert_raises(Pikuri::Agent::Control::Cancellable::Cancelled) { handoff.await }
    end

    it 'cuts the wait short when cancelled from another thread' do
      canceller = Thread.new { Kernel.sleep(0.1); cancellable.cancel! }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_raises(Pikuri::Agent::Control::Cancellable::Cancelled) { handoff.await }
      canceller.join
      assert elapsed_since(started) < 2.0, "expected the cancel to cut the wait, took #{elapsed_since(started)}s"
    end

    it 'prefers the cancel when an answer is already there too' do
      handoff.complete(:approved)
      cancellable.cancel!
      assert_raises(Pikuri::Agent::Control::Cancellable::Cancelled) { handoff.await }
    end
  end

  describe '#complete' do
    it 'raises on a second answer' do
      handoff.complete(:approved)
      error = assert_raises(RuntimeError) { handoff.complete(:rejected) }
      assert_includes error.message, ':approved'
    end
  end
end
