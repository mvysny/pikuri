# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'pathname'

describe Pikuri::Rag::Tools::Find do
  let(:vectors) { Pikuri::VectorDb::Backend::InMemory.new }
  let(:hybrid) do
    Pikuri::Rag::Backend::Hybrid.new(vectors: vectors,
                                     keywords: Pikuri::Rag::Backend::Fts5.new)
  end

  # A real corpus on disk, because the tool stats each row at call time.
  around do |example|
    Dir.mktmpdir do |dir|
      @root = Pathname.new(dir)
      @root.join('acme-2026-08-14.md').write("Acme agreed to hold list pricing.\nRenewal in Q1.\n")
      @root.join('acme-2026-07-02.md').write("Acme pricing meetings started.\n")
      @root.join('initech-2026-08-01.md').write("Initech pricing deferred.\n")
      example.run
    end
  end

  after { hybrid.close }

  def chunk(id, source, text)
    Pikuri::VectorDb::Chunk.new(id: id, source: source, text: text,
                                metadata: { offset: 0, hash: 'h' })
  end

  def populate
    hybrid.upsert(
      chunks: [
        chunk('acme-2026-08-14.md:0', 'acme-2026-08-14.md', 'Acme agreed to hold list pricing.'),
        chunk('acme-2026-08-14.md:1', 'acme-2026-08-14.md', 'Renewal in Q1 for Acme pricing.'),
        chunk('acme-2026-07-02.md:0', 'acme-2026-07-02.md', 'Acme pricing meetings started.'),
        chunk('initech-2026-08-01.md:0', 'initech-2026-08-01.md', 'Initech pricing deferred.')
      ],
      vectors: Array.new(4) { [1.0, 0.0] }
    )
  end

  def execute(terms)
    result(terms).to_s
  end

  def result(terms)
    Pikuri::Rag::Tools::Find.execute(backend: hybrid, root: @root, terms: terms)
  end

  describe 'as a Pikuri::Tool' do
    let(:tool) do
      Pikuri::Rag::Tools::Find.new(backend: hybrid, root: @root,
                                   legs: Pikuri::Tool::TrifectaLegs::NONE)
    end

    it 'is named rag_find' do
      assert_equal 'rag_find', tool.name
    end

    it 'takes only terms' do
      assert_equal ['terms'], tool.parameters.to_openai[:properties].keys.map(&:to_s)
    end

    it 'promises completeness in those words' do
      assert_includes tool.description, 'No cutoff, no top-k'
    end
  end

  describe 'the display line' do
    it 'counts the documents, and carries no corpus text' do
      populate

      display = result('Acme pricing').summary

      assert_equal 'Found 2 documents', display
      refute_includes display, 'Acme'
    end

    it 'says zero rather than going silent' do
      populate
      assert_equal 'Found 0 documents', result('nothingmatchesthis').summary
    end
  end

  describe 'the listing' do
    it 'lists every matching document, count-desc then source-asc' do
      populate
      out = execute('Acme pricing')
      assert_equal %w[acme-2026-08-14.md acme-2026-07-02.md],
                   out.scan(/^(\S+\.md) —/).flatten
    end

    it 'reports the match count and the byte size per row' do
      populate
      out = execute('Acme pricing')
      assert_match(/^acme-2026-08-14\.md — 2 chunks, \d+ B$/, out)
      assert_match(/^acme-2026-07-02\.md — 1 chunk, \d+ B$/, out)
    end

    # A line count would mean reading every matching file whole, and would be
    # the *container's* line count for anything the Extractor converts — so it
    # would disagree with the offsets rag_read pages by.
    it 'reports no line count' do
      populate
      refute_includes execute('Acme pricing'), 'line'
    end

    it 'says what the counts are' do
      populate
      assert_includes execute('Acme'),
                      "Counts are how many of the document's chunks matched, not occurrences"
    end

    it 'ANDs the terms' do
      populate
      assert_includes execute('Acme initech'), 'No indexed document contains all of'
    end

    # The regression: FTS5's own implicit AND is row-scoped and a row is a
    # chunk, so a document whose two terms land in different chunks must
    # still be listed. Under the default 512-token chunker any note past a
    # couple of kilobytes is chunked, which made this the common case.
    it 'lists a document whose terms sit in different chunks' do
      hybrid.upsert(
        chunks: [
          chunk('split.md:0', 'split.md', 'Acme called about the legacy importer.'),
          chunk('split.md:1', 'split.md', 'Nothing here mentions the customer by name.'),
          chunk('split.md:2', 'split.md', 'They agreed to hold list pricing.')
        ],
        vectors: Array.new(3) { [1.0, 0.0] }
      )
      @root.join('split.md').write("a\n")
      out = execute('Acme pricing')
      assert_includes out, 'split.md — 2 chunks'
    end

    it 'stems, so a plural finds the singular' do
      populate
      assert_includes execute('meeting'), 'acme-2026-07-02.md'
    end

    it 'is a no-match line, not an error, when nothing matches' do
      populate
      assert_includes execute('kubernetes'), 'No indexed document contains all of'
    end

    it 'agrees in number for a single row' do
      populate
      assert_match(/\A1 document contains all of/, execute('initech'))
    end
  end

  describe 'error paths' do
    it 'refuses terms with nothing searchable, without touching SQLite' do
      populate
      assert_equal 'Error: no searchable terms in "???" — pass a word, a name or an id.',
                   execute('???')
    end

    it 'reports a row whose file has vanished rather than dropping it' do
      populate
      @root.join('acme-2026-07-02.md').delete
      out = execute('meeting')
      assert_includes out, 'acme-2026-07-02.md — 1 chunk (cannot stat: ENOENT)'
    end
  end
end
