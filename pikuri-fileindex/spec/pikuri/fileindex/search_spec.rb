# frozen_string_literal: true

RSpec.describe Pikuri::Fileindex::Search do
  around { |example| RootTree.with { |tmp| @tmp = tmp; example.run } }

  def docs = "#{@tmp}/docs"
  def roots = Pikuri::Fileindex::Roots.new(dirs: [docs])

  def search(backend, **kwargs)
    described_class.search(query: 'x', backend: backend, roots: roots, **kwargs)
  end

  def folders_searched(backend) = backend.calls.map { |_, args| args[:folders] }

  describe '.search' do
    it 'rejects an empty query without touching the backend' do
      backend = FakeBackend.build
      assert_equal 'Error: empty query.', search(backend, query: '   ').to_s
      assert_empty backend.calls
    end

    it 'renders path, text size and snippet per hit, and says when that is every match' do
      backend = FakeBackend.build(hits: [{ path: "#{docs}/a.pdf", snippet: 'alpha beta', text_size: 176_531 },
                                         { path: "#{docs}/b.rb", snippet: nil, text_size: nil }])
      result = search(backend, limit: 10)
      assert_includes result.to_s, "#{docs}/a.pdf  (172.4 kB of text)\n  alpha beta\n"
      assert_includes result.to_s, "#{docs}/b.rb  (no indexed text)\n\nFound 2 files, all shown. One match shown per file,"
      assert_equal 'Found 2 files', result.summary
      assert_equal [:search], backend.calls.map(&:first), 'a short answer holds every match: no count needed'
    end

    it "renders a short file's whole text, on one line, in place of its snippet" do
      backend = FakeBackend.build(hits: [{ path: "#{docs}/n.md", snippet: '>>rent<< is', text_size: 32,
                                           text: "# Flat\nThe rent is EUR 1,150.\n" }])
      assert_includes search(backend).to_s, "#{docs}/n.md  (32 B of text, shown whole)\n  # Flat The rent is EUR 1,150.\n"
    end

    it 'says how many matched in all when more match than the limit' do
      hits = (1..5).map { |i| { path: "#{docs}/#{i}.txt" } }
      result = search(FakeBackend.build(hits: hits), limit: 2)
      assert_includes result.to_s, "#{docs}/2.txt  (no indexed text)\n\nShowing 2 of 5 matching files, best first. " \
                                   'To see the others, narrow the query or `folder`, or raise `limit` (max 25).'
      refute_includes result.to_s, '3.txt'
      assert_equal 'Found 2 of 5 files', result.summary
    end

    it 'offers no higher limit at the maximum' do
      hits = (1..30).map { |i| { path: "#{docs}/#{i}.txt" } }
      out = search(FakeBackend.build(hits: hits), limit: 25).to_s
      assert_includes out, 'Showing 25 of 30 matching files'
      assert_includes out, 'narrow the query or `folder`.'
      refute_includes out, 'raise `limit`'
    end

    it 'counts only the files it would show: none outside the roots, none hidden' do
      hits = [{ path: "#{docs}/a.txt" }]
      paths = ["#{docs}/a.txt", "#{docs}/b.txt", "#{docs}/.hidden/c.txt", "#{@tmp}/work/d.txt"]
      result = search(FakeBackend.build(hits: hits, paths: paths), limit: 1)
      assert_equal 'Found 1 of 2 files', result.summary
    end

    it 'never shows fewer files than it counts' do
      result = search(FakeBackend.build(hits: [{ path: "#{docs}/a.txt" }], paths: []), limit: 1)
      assert_equal 'Found 1 file', result.summary
    end

    it 'counts the matches past the limit even when every hit it got was dropped' do
      hits = [{ path: "#{docs}/.hidden/a.txt" }]
      result = search(FakeBackend.build(hits: hits, paths: ["#{docs}/.hidden/a.txt", "#{docs}/b.txt"]), limit: 1)
      assert_includes result.to_s, 'Showing 0 of 1 matching files'
      refute_includes result.to_s, 'No files found'
    end

    it 'drops a hit outside the roots, or hidden below one' do
      backend = FakeBackend.build(hits: [{ path: "#{docs}/a.txt" }, { path: "#{@tmp}/work/b.txt" },
                                         { path: "#{docs}/.hidden/c.txt" }, { path: "#{docs}-old/d.txt" }])
      out = search(backend).to_s
      assert_includes out, "#{docs}/a.txt"
      refute_includes out, 'b.txt'
      refute_includes out, 'c.txt'
      refute_includes out, 'd.txt'
      assert_includes out, 'Found 1 file'
    end

    it 'reports no matches on an empty result' do
      assert_includes search(FakeBackend.build, query: 'nonesuch').to_s, "No files found matching 'nonesuch'"
    end

    it 'searches any of the words, then all of them, and shows the files with all of them first' do
      backend = FakeBackend.build(hits: [{ path: "#{docs}/one.txt" }, { path: "#{docs}/both.txt" }],
                                  all_hits: [{ path: "#{docs}/both.txt" }])
      out = search(backend, query: 'rent lease').to_s
      assert_equal [[['rent'], ['lease']], [%w[rent lease]]], backend.calls.map { |_, args| args[:query].groups }
      assert out.index('both.txt') < out.index('one.txt'), out
      assert_includes out, 'Found 2 files, all shown. 1 contains all of your words, shown first.'
    end

    it 'says when no file holds every word' do
      backend = FakeBackend.build(hits: [{ path: "#{docs}/one.txt" }], all_hits: [])
      assert_includes search(backend, query: 'rent lease').to_s,
                      'Found 1 file, all shown. None contains all of your words; these contain some of them.'
    end

    it 'counts the files with every word past the limit' do
      hits = (1..5).map { |i| { path: "#{docs}/#{i}.txt" } }
      out = search(FakeBackend.build(hits: hits, all_hits: hits.first(3)), query: 'rent lease', limit: 2).to_s
      assert_includes out, 'Showing 2 of 5 matching files, best first. 3 contain all of your words, shown first. ' \
                           'To see the others'
    end

    it 'asks a query of one quoted group once' do
      backend = FakeBackend.build(hits: [{ path: "#{docs}/a.txt" }])
      out = search(backend, query: '"notice period"').to_s
      assert_equal [[%w[notice period]]], backend.calls.map { |_, args| args[:query].groups }
      refute_includes out, 'all of your words'
    end

    it 'names any of the words when none matched' do
      assert_includes search(FakeBackend.build, query: 'rent lease').to_s, "No files found matching any of 'rent lease'"
    end

    it 'rejects a query with no word in it' do
      backend = FakeBackend.build
      assert_equal 'Error: empty query.', search(backend, query: 'OR ( ) ""').to_s
      assert_empty backend.calls
    end

    it 'renders a backend CommandError as an Error observation, prefixed with its label' do
      assert_equal 'Error: fake: bad query', search(FakeBackend.build(error: 'bad query')).to_s
    end

    it 'caps an oversized backend CommandError at MAX_BYTES' do
      result = search(FakeBackend.build(error: 'x' * (described_class::MAX_BYTES * 3))).to_s
      assert result.start_with?('Error: fake:'), "got #{result[0, 40].inspect}"
      assert_includes result, 'bytes omitted'
      assert result.bytesize <= described_class::MAX_BYTES + 200, "error not capped: #{result.bytesize} bytes"
    end

    it 'searches every root without a folder, and only the folder with one' do
      backend = FakeBackend.build
      search(backend)
      search(backend, folder: '  ')
      out = search(backend, folder: "#{docs}/tax/").to_s
      search(backend, folder: "#{docs}/tax/..")
      assert_equal [[docs], [docs], ["#{docs}/tax"], [docs]], folders_searched(backend)
      assert_includes out, "No files found matching 'x' under #{docs}/tax"
    end

    it 'refuses a folder outside the roots, however the path gets there' do
      backend = FakeBackend.build
      ["#{@tmp}/work", "#{docs}/../work", "#{docs}/link", "#{docs}/.hidden", "#{docs}-old", '/etc'].each do |folder|
        out = search(backend, folder: folder).to_s
        assert out.start_with?("Error: #{File.expand_path(folder)} is not inside the folders you can search (#{docs})"),
               "#{folder}: #{out}"
      end
      assert_empty backend.calls
    end

    it 'rejects a relative or missing folder without touching the backend' do
      backend = FakeBackend.build
      assert_equal "Error: folder must be an absolute path, got 'Documents'.",
                   search(backend, folder: 'Documents').to_s
      assert_equal "Error: no such folder: #{docs}/nope", search(backend, folder: "#{docs}/nope").to_s
      assert_empty backend.calls
    end

    it 'answers a file passed as folder with a pointer to fileindex_read' do
      out = search(FakeBackend.build, folder: "#{docs}/note.txt").to_s
      assert out.start_with?("Error: #{docs}/note.txt is a file, not a folder."), out
      assert_includes out, 'fileindex_read'
    end

    it 'clamps limit to MAX_LIMIT' do
      backend = FakeBackend.build
      search(backend, limit: 9999)
      assert_equal described_class::MAX_LIMIT, backend.calls.first.last[:limit]
    end
  end

  it 'names the roots and the backend limitations in the tool description' do
    tool = described_class.new(backend: FakeBackend.build, roots: roots)
    assert_includes tool.description, "Searches only under these folders (subfolders included):\n- #{docs}\n"
    assert_includes tool.description, 'FAKE BLIND SPOTS'
  end

  it 'constructs as a Pikuri::Tool named fileindex_search' do
    tool = described_class.new(backend: FakeBackend.build, roots: roots)
    assert_kind_of Pikuri::Tool, tool
    assert_equal 'fileindex_search', tool.name
  end
end
