# frozen_string_literal: true

RSpec.describe Pikuri::Tasks::List do
  let(:list) { described_class.new }

  describe '#add' do
    it 'appends a pending item and returns it' do
      item = list.add('first task')
      assert_equal 'first task', item.content
      assert_equal 'pending', item.status
      assert_equal 1, list.size
    end

    it 'preserves insertion order' do
      list.add('a')
      list.add('b')
      list.add('c')
      assert_equal %w[a b c], list.items.map(&:content)
    end

    it 'raises DuplicateItem on identical content' do
      list.add('dup')
      err = assert_raises(Pikuri::Tasks::DuplicateItem) { list.add('dup') }
      assert_equal 'dup', err.message
    end
  end

  describe '#set_status' do
    it 'updates status to a valid value' do
      list.add('task')
      updated = list.set_status(content: 'task', status: 'in_progress')
      assert_equal 'in_progress', updated.status
      assert_equal 'in_progress', list.items.first.status
    end

    it 'is idempotent: setting the same status again is a no-op result' do
      list.add('task')
      list.set_status(content: 'task', status: 'completed')
      again = list.set_status(content: 'task', status: 'completed')
      assert_equal 'completed', again.status
    end

    it 'raises ItemNotFound for unknown content' do
      list.add('exists')
      err = assert_raises(Pikuri::Tasks::ItemNotFound) do
        list.set_status(content: 'missing', status: 'completed')
      end
      assert_equal 'missing', err.message
    end

    it 'raises ArgumentError for an invalid status' do
      list.add('task')
      err = assert_raises(ArgumentError) do
        list.set_status(content: 'task', status: 'cancelled')
      end
      assert_match(/invalid status/, err.message)
    end
  end

  describe '#delete' do
    it 'removes the matching item and returns it' do
      list.add('a')
      list.add('b')
      removed = list.delete('a')
      assert_equal 'a', removed.content
      assert_equal %w[b], list.items.map(&:content)
    end

    it 'raises ItemNotFound for unknown content' do
      assert_raises(Pikuri::Tasks::ItemNotFound) { list.delete('nope') }
    end
  end

  describe '#items' do
    it 'returns a frozen snapshot that does not mutate the underlying list' do
      list.add('a')
      snapshot = list.items
      assert snapshot.frozen?
      assert_raises(FrozenError) { snapshot << :anything }
      # Underlying list is unaffected
      assert_equal 1, list.size
    end
  end

  describe '#render' do
    it 'returns the empty marker when the list has no items' do
      assert_equal '<tasks>(empty)</tasks>', list.render
    end

    it 'renders each item on its own line with status in brackets' do
      list.add('first')
      list.add('second')
      list.set_status(content: 'second', status: 'in_progress')
      out = list.render
      assert out.start_with?("<tasks>\n"), out
      assert out.end_with?("\n</tasks>"), out
      assert_match(/^- \[pending\] first$/, out)
      assert_match(/^- \[in_progress\] second$/, out)
    end
  end

  describe '#size and #empty?' do
    it 'tracks size and empty? as items are added and removed' do
      assert list.empty?
      assert_equal 0, list.size
      list.add('a')
      refute list.empty?
      assert_equal 1, list.size
      list.delete('a')
      assert list.empty?
    end
  end

  describe 'STATUSES' do
    it 'is the canonical three-value set in workflow order' do
      assert_equal %w[pending in_progress completed], Pikuri::Tasks::STATUSES
      assert Pikuri::Tasks::STATUSES.frozen?
    end
  end
end
