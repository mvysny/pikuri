# frozen_string_literal: true

RSpec.describe Pikuri::Agent::Control::Interloper do
  describe '#initialize' do
    it 'starts empty — pending? is false, size is 0, drain! returns []' do
      interloper = described_class.new
      refute interloper.pending?
      assert_equal 0, interloper.size
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

    it 'pushes a :user item onto the queue, observable via #pending?' do
      interloper = described_class.new
      interloper.inject_user_message('hi')

      assert interloper.pending?
      drained = interloper.drain!
      assert_equal [:user], drained.map(&:kind)
      assert_equal ['hi'], drained.map(&:content)
    end

    it 'preserves FIFO order across multiple injections' do
      interloper = described_class.new
      interloper.inject_user_message('one')
      interloper.inject_user_message('two')
      interloper.inject_user_message('three')

      assert_equal %w[one two three], interloper.drain!.map(&:content)
    end

    it 'returns nil' do
      assert_nil described_class.new.inject_user_message('x')
    end

    describe 'with attachments' do
      let(:png) { Pikuri::Attachment.new(mime: 'image/png', filename: 'shot.png', bytes: 'png') }

      it 'carries them on the item, beside the text' do
        interloper = described_class.new
        interloper.inject_user_message('and this?', attachments: [png])

        assert_equal [described_class::Item.new(kind: :user, content: 'and this?', attachments: [png])],
                     interloper.drain!
      end

      it 'accepts an attachment-only message, its text normalized to ""' do
        interloper = described_class.new
        interloper.inject_user_message(attachments: [png])
        interloper.inject_user_message("  \n", attachments: [png])

        assert_equal ['', ''], interloper.drain!.map(&:content)
      end

      it 'refuses a RubyLLM::Attachment, whose path or URL source ruby_llm would read' do
        raw = RubyLLM::Attachment.new(StringIO.new('png'), filename: 'shot.png')

        assert_raises(ArgumentError) { described_class.new.inject_user_message('hi', attachments: [raw]) }
      end
    end
  end

  describe '#inject_system_message' do
    it 'rejects blank content like #inject_user_message' do
      assert_raises(ArgumentError) { described_class.new.inject_system_message(nil) }
      assert_raises(ArgumentError) { described_class.new.inject_system_message('') }
      assert_raises(ArgumentError) { described_class.new.inject_system_message("  \n") }
    end

    it 'pushes a :system item, returning nil' do
      interloper = described_class.new
      assert_nil interloper.inject_system_message('<skill>…</skill>')

      assert_equal [described_class::Item.new(kind: :system, content: '<skill>…</skill>')], interloper.drain!
    end
  end

  describe 'mixed kinds' do
    it 'preserves injection order and per-item kind across both inject_* methods' do
      interloper = described_class.new
      interloper.inject_user_message('u1')
      interloper.inject_system_message('s1')
      interloper.inject_user_message('u2')

      drained = interloper.drain!
      assert_equal %i[user system user], drained.map(&:kind)
      assert_equal %w[u1 s1 u2], drained.map(&:content)
    end
  end

  describe '#size' do
    it 'tracks injections and resets to 0 after a drain' do
      interloper = described_class.new
      interloper.inject_user_message('one')
      interloper.inject_user_message('two')

      assert_equal 2, interloper.size

      interloper.drain!
      assert_equal 0, interloper.size
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

      assert_equal %w[one two], interloper.drain!.map(&:content)

      refute interloper.pending?
      assert_equal [], interloper.drain!
    end

    it 'items injected between drains are returned on the subsequent drain' do
      interloper = described_class.new
      interloper.inject_user_message('a')
      assert_equal ['a'], interloper.drain!.map(&:content)

      interloper.inject_user_message('b')
      assert_equal ['b'], interloper.drain!.map(&:content)
    end
  end

  describe 'cross-thread inject_user_message' do
    it 'a push from another thread is observed at the next drain!' do
      interloper = described_class.new

      Thread.new { interloper.inject_user_message('from another thread') }.join

      assert_equal ['from another thread'], interloper.drain!.map(&:content)
    end
  end

  describe '#on_change' do
    let(:png) { Pikuri::Attachment.new(mime: 'image/png', filename: 'shot.png', bytes: 'png') }

    it 'fires with the queued items, in delivery order, on each injection' do
      interloper = described_class.new
      snapshots = []
      interloper.on_change = ->(items) { snapshots << items }

      interloper.inject_user_message('one', attachments: [png])
      interloper.inject_system_message('<skill>…</skill>')

      user = described_class::Item.new(kind: :user, content: 'one', attachments: [png])
      system = described_class::Item.new(kind: :system, content: '<skill>…</skill>')
      assert_equal [[user], [user, system]], snapshots
    end

    it 'hands a frozen snapshot that a later injection does not change' do
      interloper = described_class.new
      snapshots = []
      interloper.on_change = ->(items) { snapshots << items }

      interloper.inject_user_message('one')
      first = snapshots.first
      interloper.inject_user_message('two')

      assert first.frozen?
      assert_equal ['one'], first.map(&:content)
    end

    it 'fires with [] when a non-empty queue is drained' do
      interloper = described_class.new
      interloper.inject_user_message('one')

      snapshots = []
      interloper.on_change = ->(items) { snapshots << items }
      interloper.drain!

      assert_equal [[]], snapshots
    end

    it 'does not fire when an empty queue is drained' do
      interloper = described_class.new
      fired = false
      interloper.on_change = ->(_items) { fired = true }

      interloper.drain!

      refute fired
    end

    it 'does nothing when unset (default nil)' do
      interloper = described_class.new
      interloper.inject_user_message('one')
      assert_equal ['one'], interloper.drain!.map(&:content)
    end

    it 'fires outside the queue lock — the callback may re-enter the interloper' do
      interloper = described_class.new
      seen = []
      interloper.on_change = lambda do |items|
        # Re-entering under the lock would deadlock; #size takes the mutex.
        seen << [items.size, interloper.size]
      end

      interloper.inject_user_message('one')

      assert_equal [[1, 1]], seen
    end
  end
end
