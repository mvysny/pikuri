# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'pathname'

describe Pikuri::VectorDb::Read do
  # Real Backend::InMemory + real files on disk under a tmp root —
  # the membership gate derives from upserted chunks' sources, and
  # extraction reads the matching file, so a real backend + real
  # files exercise the whole path without stubs.
  let(:root) { Pathname.new(Dir.mktmpdir('pikuri-vectordb-read-')).realpath }
  let(:backend) { Pikuri::VectorDb::Backend::InMemory.new }

  after { FileUtils.rm_rf(root) }

  # Write +content+ to +source+ under root and register a chunk for
  # it so the membership gate sees it as indexed.
  def index_file(source, content)
    File.write(root + source, content)
    chunk = Pikuri::VectorDb::Chunk.new(
      id: "#{source}:0", source: source, text: content[0, 50],
      metadata: { offset: 0, hash: 'h' }
    )
    backend.upsert(chunks: [chunk], vectors: [[1.0, 0.0, 0.0]])
  end

  def read(source:, offset: 1, limit: Pikuri::VectorDb::Read::DEFAULT_LIMIT)
    Pikuri::VectorDb::Read.read(backend: backend, root: root, source: source, offset: offset, limit: limit)
  end

  describe 'as a Pikuri::Tool' do
    it 'is named vectordb_read' do
      tool = Pikuri::VectorDb::Read.new(backend: backend, root: root)
      assert_equal 'vectordb_read', tool.name
    end

    it 'advertises source as required and offset/limit as optional integers' do
      schema = Pikuri::VectorDb::Read.new(backend: backend, root: root).parameters.to_h
      assert_equal %w[source], schema[:required]
      assert_equal 'string', schema[:properties][:source][:type]
      assert_equal 'integer', schema[:properties][:offset][:type]
      assert_equal 'integer', schema[:properties][:limit][:type]
    end
  end

  describe 'membership gate' do
    it 'refuses a source that is not in the indexed corpus' do
      result = read(source: 'not-indexed.md')
      assert_match(/is not in the indexed corpus/, result)
    end

    it 'refuses even when the file exists on disk but was never indexed' do
      File.write(root + 'present.md', 'on disk but not indexed')
      result = read(source: 'present.md')
      assert_match(/is not in the indexed corpus/, result)
    end
  end

  describe 'containment (defense-in-depth)' do
    it 'refuses a traversal source even if the backend claims it is indexed' do
      # Fake backend whose manifest contains a traversal key, to drive
      # the containment branch past the membership gate.
      evil = Object.new
      def evil.sources_with_hashes = { '../escape.txt' => 'h' }

      result = Pikuri::VectorDb::Read.read(
        backend: evil, root: root, source: '../escape.txt', offset: 1, limit: 10
      )
      assert_match(/resolves outside the corpus root/, result)
    end
  end

  describe 'reading an indexed document' do
    it 'returns the full text with an end-of-document trailer' do
      index_file('doc.md', "alpha\nbeta\ngamma")
      result = read(source: 'doc.md')
      assert_includes result, 'alpha'
      assert_includes result, 'gamma'
      assert_match(/End of doc\.md — 3 lines\./, result)
    end

    it 'does NOT prefix lines with cat -n numbers' do
      index_file('doc.md', 'just one line')
      result = read(source: 'doc.md')
      refute_match(/^\s+1\t/, result)
    end

    it 'reports an empty document distinctly' do
      index_file('empty.md', '')
      assert_equal '(empty.md is empty)', read(source: 'empty.md')
    end

    it 'truncates an over-long line with a marker' do
      index_file('wide.md', 'x' * (Pikuri::FileType::PAGE_MAX_LINE_LENGTH + 500))
      result = read(source: 'wide.md')
      assert_includes result, 'line truncated'
    end
  end

  describe 'paging' do
    before { index_file('long.md', (1..5).map { |n| "line#{n}" }.join("\n")) }

    it 'windows by offset and limit with a continuation hint' do
      result = read(source: 'long.md', offset: 1, limit: 2)
      assert_includes result, 'line1'
      assert_includes result, 'line2'
      refute_includes result, 'line3'
      assert_match(/Showing lines 1-2 of 5\. Use offset=3 to continue\./, result)
    end

    it 'resumes from a later offset' do
      result = read(source: 'long.md', offset: 3, limit: 2)
      assert_includes result, 'line3'
      assert_includes result, 'line4'
      assert_match(/Use offset=5 to continue\./, result)
    end

    it 'errors when offset is past the end' do
      result = read(source: 'long.md', offset: 99, limit: 2)
      assert_match(/offset 99 is beyond end of document \(5 lines total\)/, result)
    end

    it 'rejects a non-positive offset' do
      assert_match(/offset must be >= 1/, read(source: 'long.md', offset: 0))
    end

    it 'rejects a non-positive limit' do
      assert_match(/limit must be >= 1/, read(source: 'long.md', limit: 0))
    end
  end

  describe 'extraction errors the LLM can react to' do
    it 'reports a stale index entry whose file is gone from disk' do
      index_file('gone.md', 'temporary')
      File.delete(root + 'gone.md')
      result = read(source: 'gone.md')
      assert_match(/no longer on disk/, result)
    end

    it 'refuses a binary indexed document as an Error string' do
      # A NUL byte makes FileType.binary? true; read_as_text raises
      # ArgumentError, which we surface as an Error observation.
      index_file('blob.bin', "ok\x00\x01\x02binary")
      result = read(source: 'blob.bin')
      assert_match(/cannot read "blob\.bin" as text/, result)
    end
  end
end
