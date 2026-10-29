# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

describe Pikuri::Rag::Extension do
  let(:inner) { Pikuri::VectorDb::Backend::InMemory.new }

  let(:embedder) do
    fake = Object.new
    fake.define_singleton_method(:embed) { |texts| texts.map { [1.0, 0.0] } }
    fake
  end

  # A Configurator stand-in: the extension only ever reads +tools+ and calls
  # +add_tool+, and building a real Agent would need a transport.
  let(:configurator) do
    c = Object.new
    c.instance_variable_set(:@tools, [])
    c.define_singleton_method(:tools) { @tools }
    c.define_singleton_method(:add_tool) { |tool| @tools << tool }
    c
  end

  def build(**overrides)
    Pikuri::Rag::Extension.new(
      **{ backend: inner, source: Dir.tmpdir, embedder: embedder }.merge(overrides)
    )
  end

  describe '#configure' do
    it 'registers the four rag_* tools and nothing else' do
      build.configure(configurator)
      assert_equal Pikuri::Rag::Extension::TOOL_NAMES, configurator.tools.map(&:name)
    end

    it 'builds rag_read and rag_reindex from the vectordb classes' do
      build.configure(configurator)
      read, reindex = configurator.tools.last(2)
      assert_instance_of Pikuri::VectorDb::Tools::Read, read
      assert_instance_of Pikuri::VectorDb::Tools::Reindex, reindex
      assert_includes read.description, 'rag_search'
    end

    it 'refuses a pre-registered rag_* tool' do
      configurator.add_tool Pikuri::Rag::Tools::Find.new(
        backend: inner, root: Pathname.new(Dir.tmpdir),
        legs: Pikuri::Tool::TrifectaLegs::NONE
      )
      error = assert_raises(RuntimeError) { build.configure(configurator) }
      assert_includes error.message, 'rag_find cannot be pre-registered'
    end

    it 'refuses a pre-registered vectordb_* tool — the two tool sets are exclusive' do
      configurator.add_tool Pikuri::VectorDb::Tools::Search.new(
        embedder: embedder, backend: inner, legs: Pikuri::Tool::TrifectaLegs::NONE
      )
      error = assert_raises(RuntimeError) { build.configure(configurator) }
      assert_includes error.message, 'vectordb_search cannot be pre-registered'
    end
  end

  describe 'the corpus declaration' do
    it 'defaults to the pessimistic reading' do
      ext = build
      refute ext.private?
      assert_equal :hard, tool_legs(ext, 'rag_search').untrusted
    end

    it 'derives the same legs for all three reading tools' do
      ext = build(private: true, trusted: true)
      assert ext.private?
      assert ext.trusted?
      %w[rag_search rag_find rag_read].each do |name|
        legs = tool_legs(ext, name)
        assert legs.private, "#{name} should carry the private leg"
        assert_equal :none, legs.untrusted
        assert_equal :no_egress, legs.egress_payload_review
      end
    end

    it 'leaves rag_reindex with no legs at all' do
      legs = tool_legs(build(private: true, trusted: false), 'rag_reindex')
      refute legs.private
      assert_equal :none, legs.untrusted
    end
  end

  describe 'the composed backend' do
    it 'hands the indexer the composite, not the bare vector backend' do
      ext = build
      assert_instance_of Pikuri::Rag::Backend::Hybrid, ext.backend
      # Indexing through the indexer must fill the keyword index too.
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'note.md'), 'Acme pricing was agreed.')
        ext = build(source: dir)
        ext.indexer.index_all!
        assert_equal [Pikuri::Rag::Backend::DocumentMatch.new(source: 'note.md', first_lines: [1])],
                     ext.backend.find(terms: ['"acme"'])
        ext.backend.close
      end
    end

    it 'defaults the keyword index to an in-process store' do
      assert_equal ':memory:', build.backend.keywords.store
    end

    it 'takes a file store when the host pairs one with a persistent backend' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'fts.sqlite3')
        ext = build(store: path)
        assert_equal path, ext.backend.keywords.store
        ext.backend.close
        assert File.exist?(path)
      end
    end
  end

  # Configures once per extension, so a caller may ask about several tools.
  def tool_legs(ext, name)
    @configured ||= {}
    @configured[ext] ||= begin
      ext.configure(configurator)
      configurator.tools
    end
    @configured[ext].find { |t| t.name == name }.trifecta_legs
  end
end
