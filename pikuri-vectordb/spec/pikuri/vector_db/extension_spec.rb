# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'pathname'

describe Pikuri::VectorDb::Extension do
  # Real Configurator — same shape pikuri-tasks's
  # extension_spec uses. Easier to spec wiring against the real
  # type than a stub.
  let(:configurator) do
    Pikuri::Agent::Configurator.new(
      transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
      system_prompt_base: 'base',
      id: '',
      streaming: false,
      step_limit: nil,
      cancellable: nil,
      interloper: nil
    )
  end

  let(:root) { Pathname.new(Dir.mktmpdir('pikuri-vectordb-ext-')).realpath }
  let(:backend) { Pikuri::VectorDb::Backend::InMemory.new }

  # Deterministic fake embedder, fixed 3-dim vector per text.
  let(:fake_embedder) do
    obj = Object.new
    def obj.embed(texts)
      texts.map { |_t| [1.0, 0.0, 0.0] }
    end
    obj
  end

  after { FileUtils.rm_rf(root) }

  def build_extension(**overrides)
    Pikuri::VectorDb::Extension.new(
      backend: backend,
      source: root.to_s,
      embedder: overrides.fetch(:embedder, fake_embedder),
      reranker: overrides.fetch(:reranker, nil),
      chunker: overrides.fetch(:chunker, nil),
      index_on_boot: overrides.fetch(:index_on_boot, :if_empty)
    )
  end

  it 'is an Agent::Extension by composition' do
    refute_nil build_extension
    assert_kind_of Pikuri::Agent::Extension, build_extension
  end

  describe '#initialize' do
    it 'constructs an Indexer exposed via #indexer' do
      ext = build_extension
      assert_kind_of Pikuri::VectorDb::Indexer, ext.indexer
    end

    it 'defaults the chunker to FixedWindow when not provided' do
      ext = build_extension(chunker: nil)
      # Indirect: the Indexer should produce chunks for a
      # short file (the default chunker handles a short text).
      File.write(root + 'hi.md', 'hello world')
      ext.configure(configurator)
      assert_operator backend.count, :>, 0
    end

    it 'defaults the embedder to Embedder when not provided' do
      # Construct without an explicit embedder; verify the
      # default is wired through. We don't run #configure here
      # because the real Embedder would actually try to call
      # RubyLLM.embed.
      ext = Pikuri::VectorDb::Extension.new(
        backend: backend, source: root.to_s
      )
      assert_kind_of Pikuri::VectorDb::Indexer, ext.indexer
    end

    it 'rejects an unknown index_on_boot value' do
      err = assert_raises(ArgumentError) do
        build_extension(index_on_boot: :nope)
      end
      assert_match(/index_on_boot must be one of/, err.message)
    end
  end

  describe '#configure' do
    it 'registers vectordb_search and vectordb_reindex tools' do
      build_extension(index_on_boot: :never).configure(configurator)

      tool_names = configurator.tools.map(&:name)
      assert_includes tool_names, 'vectordb_search'
      assert_includes tool_names, 'vectordb_reindex'
    end

    it 'does NOT append a system-prompt snippet' do
      # Two use modes (direct + LIBRARIAN-mediated) live behind
      # the same Extension; appending a one-or-the-other usage
      # block would conflict in the LIBRARIAN-mediated case.
      build_extension(index_on_boot: :never).configure(configurator)
      assert_empty configurator.system_prompt_additions
    end

    it 'does NOT auto-register the LIBRARIAN persona' do
      # LIBRARIAN is opt-in via SubAgent::Extension — same
      # precedent as Pikuri::Code::GIT_REPO_RESEARCHER.
      build_extension(index_on_boot: :never).configure(configurator)
      # The agent tool would only be present if a SubAgent
      # extension had been registered; VectorDb::Extension
      # alone doesn't pull that in.
      refute(configurator.tools.any? { |t| t.name == 'agent' })
    end

    it 'raises if vectordb_search has been pre-registered' do
      pre = Pikuri::VectorDb::Search.new(embedder: fake_embedder, backend: backend)
      configurator.add_tool(pre)

      err = assert_raises(RuntimeError) do
        build_extension(index_on_boot: :never).configure(configurator)
      end
      assert_match(/vectordb_search cannot be pre-registered/, err.message)
    end

    it 'raises if vectordb_reindex has been pre-registered' do
      pre = Pikuri::VectorDb::Reindex.new(indexer: build_extension.indexer)
      configurator.add_tool(pre)

      err = assert_raises(RuntimeError) do
        build_extension(index_on_boot: :never).configure(configurator)
      end
      assert_match(/vectordb_reindex cannot be pre-registered/, err.message)
    end
  end

  describe 'boot indexing' do
    before { File.write(root + 'note.md', 'first second third') }

    it ':if_empty (default) indexes when the backend is empty' do
      ext = build_extension
      ext.configure(configurator)

      assert_operator backend.count, :>, 0
    end

    it ':if_empty skips when the backend already has entries' do
      preexisting = Pikuri::VectorDb::Chunk.new(
        id: 'pre:0', source: 'pre', text: 't', metadata: {}
      )
      backend.upsert(chunks: [preexisting], vectors: [[1.0, 0.0, 0.0]])
      before_count = backend.count

      build_extension.configure(configurator)

      # No new chunks added (the index was already non-empty).
      assert_equal before_count, backend.count
    end

    it ':always nukes and re-indexes even when the backend is populated' do
      preexisting = Pikuri::VectorDb::Chunk.new(
        id: 'pre:0', source: 'pre', text: 't', metadata: {}
      )
      backend.upsert(chunks: [preexisting], vectors: [[1.0, 0.0, 0.0]])

      build_extension(index_on_boot: :always).configure(configurator)

      # The pre-existing chunk is gone (delete_all was called).
      query = backend.query(vector: [1.0, 0.0, 0.0], top_k: 10)
      ids = query.map { |r| r.chunk.id }
      refute_includes ids, 'pre:0'
      refute query.empty? # the source file's chunks did get indexed
    end

    it ':never skips indexing entirely' do
      build_extension(index_on_boot: :never).configure(configurator)
      assert_equal 0, backend.count
    end
  end
end
