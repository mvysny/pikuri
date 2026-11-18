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

    it 'renders path, text size and snippet per hit and a one-match-per-file disclaimer' do
      backend = FakeBackend.build(hits: [{ path: "#{docs}/a.pdf", snippet: 'alpha beta', text_size: 176_531 },
                                         { path: "#{docs}/b.rb", snippet: nil, text_size: nil }])
      out = search(backend, limit: 10).to_s
      assert_includes out, "#{docs}/a.pdf  (172.4 kB of text)\n  alpha beta\n"
      assert_includes out, "#{docs}/b.rb  (no indexed text)\n"
      assert_includes out, 'one match shown per file'
      assert_includes out, 'Found 2 files'
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
        assert out.start_with?('Error: '), "#{folder}: #{out}"
        assert_includes out, "is not inside the folders you can search (#{docs})"
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
