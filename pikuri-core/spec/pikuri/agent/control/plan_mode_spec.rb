# frozen_string_literal: true

RSpec.describe Pikuri::Agent::Control::PlanMode do
  describe '#initialize' do
    it 'defaults to inactive' do
      refute described_class.new.active?
    end

    it 'honors active: true for a startup-flag posture' do
      assert described_class.new(active: true).active?
    end
  end

  describe '#enter! / #exit!' do
    it 'enter! activates the flag' do
      flag = described_class.new
      flag.enter!
      assert flag.active?
    end

    it 'exit! deactivates the flag' do
      flag = described_class.new(active: true)
      flag.exit!
      refute flag.active?
    end

    it 'enter! is idempotent' do
      flag = described_class.new
      flag.enter!
      flag.enter!
      assert flag.active?
    end

    it 'exit! is idempotent' do
      flag = described_class.new
      flag.exit!
      refute flag.active?
    end
  end

  describe '#on_change' do
    it 'fires with the new state on a real transition' do
      flag = described_class.new
      seen = []
      flag.on_change { |active| seen << active }

      flag.enter!
      flag.exit!

      assert_equal [true, false], seen
    end

    it 'does not fire on a no-op flip' do
      flag = described_class.new
      seen = []
      flag.on_change { |active| seen << active }

      flag.exit! # already inactive
      flag.enter!
      flag.enter! # already active

      assert_equal [true], seen
    end

    it 'fans out to every registered callback' do
      flag = described_class.new
      a = []
      b = []
      flag.on_change { |s| a << s }
      flag.on_change { |s| b << s }

      flag.enter!

      assert_equal [true], a
      assert_equal [true], b
    end

    it 'requires a block' do
      assert_raises(ArgumentError) { described_class.new.on_change }
    end
  end

  describe 'cross-thread transitions' do
    it 'an #enter! from another thread is observed via #active?' do
      flag = described_class.new

      Thread.new { flag.enter! }.join

      assert flag.active?
    end
  end

  describe '#to_s' do
    it 'renders the off state' do
      assert_equal 'PlanMode(off)', described_class.new.to_s
    end

    it 'renders the on state' do
      assert_equal 'PlanMode(on)', described_class.new(active: true).to_s
    end
  end
end
