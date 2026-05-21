# frozen_string_literal: true

RSpec.describe Pikuri::McpRegistry do
  Entry = Pikuri::McpRegistry::Entry

  describe Pikuri::McpRegistry::EMPTY do
    it 'is the canonical empty singleton' do
      assert_kind_of Pikuri::McpRegistry, described_class
      assert described_class.empty?
      assert_equal [], described_class.entries
      assert_equal [], described_class.ids
      assert_nil described_class.get('anything')
    end

    it 'is frozen' do
      assert described_class.frozen?
    end
  end

  describe Pikuri::McpRegistry::Entry do
    it 'is a Data value class with id and command' do
      e = Entry.new(id: 'maven', command: ['npx', 'mcp-maven'])
      assert_equal 'maven', e.id
      assert_equal ['npx', 'mcp-maven'], e.command
    end

    it 'compares by value' do
      e1 = Entry.new(id: 'a', command: ['x'])
      e2 = Entry.new(id: 'a', command: ['x'])
      e3 = Entry.new(id: 'b', command: ['x'])
      assert_equal e1, e2
      refute_equal e1, e3
    end
  end

  describe '#initialize' do
    it 'defaults to no entries' do
      r = Pikuri::McpRegistry.new
      assert r.empty?
      assert_equal [], r.ids
    end

    it 'preserves declaration order' do
      r = Pikuri::McpRegistry.new(entries: [
        Entry.new(id: 'b', command: ['x']),
        Entry.new(id: 'a', command: ['y']),
        Entry.new(id: 'c', command: ['z'])
      ])
      assert_equal %w[b a c], r.ids
    end

    it 'rejects duplicate ids loudly' do
      err = assert_raises(ArgumentError) do
        Pikuri::McpRegistry.new(entries: [
          Entry.new(id: 'x', command: ['a']),
          Entry.new(id: 'x', command: ['b'])
        ])
      end
      assert_match(/Duplicate MCP id "x"/, err.message)
    end

    it 'freezes itself and its entries array after construction' do
      r = Pikuri::McpRegistry.new(entries: [Entry.new(id: 'a', command: ['x'])])
      assert r.frozen?
      assert r.entries.frozen?
    end

    it 'does not mutate the caller-supplied entries array' do
      caller_entries = [Entry.new(id: 'a', command: ['x'])]
      Pikuri::McpRegistry.new(entries: caller_entries)
      caller_entries << Entry.new(id: 'b', command: ['y'])
      # caller_entries is still mutable; the registry's own copy is frozen
      assert_equal 2, caller_entries.size
    end
  end

  describe '#get' do
    let(:registry) do
      Pikuri::McpRegistry.new(entries: [
        Entry.new(id: 'gmail',   command: ['gmail-mcp']),
        Entry.new(id: 'calendar', command: ['cal-mcp'])
      ])
    end

    it 'returns the entry with a matching id' do
      assert_equal 'gmail', registry.get('gmail').id
      assert_equal ['gmail-mcp'], registry.get('gmail').command
    end

    it 'returns nil for an unknown id' do
      assert_nil registry.get('unknown')
    end
  end
end
