# frozen_string_literal: true

RSpec.describe Pikuri::Agent::Control::Interloper do
  describe '#initialize' do
    it 'starts empty — peek is empty, pending? is false, size is 0, drain! returns []' do
      interloper = described_class.new
      assert_equal [], interloper.peek
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

    it 'pushes a :user item onto the queue, observable via #peek and #pending?' do
      interloper = described_class.new
      interloper.inject_user_message('hi')

      assert_equal [:user], interloper.peek.map(&:kind)
      assert_equal ['hi'], interloper.peek.map(&:content)
      assert interloper.pending?
    end

    it 'preserves FIFO order across multiple injections' do
      interloper = described_class.new
      interloper.inject_user_message('one')
      interloper.inject_user_message('two')
      interloper.inject_user_message('three')

      assert_equal %w[one two three], interloper.peek.map(&:content)
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
                     interloper.peek
      end

      it 'accepts an attachment-only message, its text normalized to ""' do
        interloper = described_class.new
        interloper.inject_user_message(attachments: [png])
        interloper.inject_user_message("  \n", attachments: [png])

        assert_equal ['', ''], interloper.peek.map(&:content)
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

      assert_equal [:system], interloper.peek.map(&:kind)
      assert_equal ['<skill>…</skill>'], interloper.peek.map(&:content)
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

  describe '#peek' do
    it 'returns a copy — mutating the result does not mutate the queue' do
      interloper = described_class.new
      interloper.inject_user_message('a')

      snapshot = interloper.peek
      snapshot << 'b'

      assert_equal ['a'], interloper.peek.map(&:content)
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
      assert_equal [], interloper.peek
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
    it 'fires with the new pending count on each injection' do
      interloper = described_class.new
      counts = []
      interloper.on_change = ->(n) { counts << n }

      interloper.inject_user_message('one')
      interloper.inject_user_message('two')

      assert_equal [1, 2], counts
    end

    it 'fires with 0 when a non-empty queue is drained' do
      interloper = described_class.new
      interloper.inject_user_message('one')

      counts = []
      interloper.on_change = ->(n) { counts << n }
      interloper.drain!

      assert_equal [0], counts
    end

    it 'does not fire when an empty queue is drained' do
      interloper = described_class.new
      fired = false
      interloper.on_change = ->(_n) { fired = true }

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
      interloper.on_change = lambda do |n|
        # Re-entering under the lock would deadlock; #size takes the mutex.
        seen << [n, interloper.size]
      end

      interloper.inject_user_message('one')

      assert_equal [[1, 1]], seen
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
