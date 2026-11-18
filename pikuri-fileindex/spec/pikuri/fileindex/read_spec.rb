# frozen_string_literal: true

RSpec.describe Pikuri::Fileindex::Read do
  around { |example| RootTree.with { |tmp| @tmp = tmp; example.run } }

  def docs = "#{@tmp}/docs"
  def roots = Pikuri::Fileindex::Roots.new(dirs: [docs])

  def read(text: nil, path: "#{docs}/x.txt", **kwargs)
    described_class.read(path: path, backend: FakeBackend.build(text: text), roots: roots, **kwargs)
  end

  describe '.read' do
    it 'rejects offset < 1 and limit < 1' do
      assert_includes read(offset: 0, limit: 10).to_s, 'offset must be >= 1'
      assert_includes read(offset: 1, limit: 0).to_s, 'limit must be >= 1'
    end

    it 'returns a not-in-index error when the backend has no text' do
      out = read(path: "#{docs}/missing.pdf").to_s
      assert_includes out, 'is not in the index'
      assert_includes out, 'use the read tool'
    end

    it 'asks the backend for the real, absolute path' do
      backend = FakeBackend.build(text: 'body')
      described_class.read(path: "#{docs}/tax/../note.txt", backend: backend, roots: roots)
      assert_equal [[:read_text, "#{docs}/note.txt"]], backend.calls
    end

    it 'refuses a path outside the roots, however the path gets there, without asking the backend' do
      backend = FakeBackend.build(text: 'secret')
      ["#{@tmp}/work/a.txt", "#{docs}/../work/a.txt", "#{docs}/link/a.txt", "#{docs}/.hidden/a.txt",
       "#{docs}/.env", "#{docs}-old/a.txt", '/etc/passwd'].each do |path|
        out = described_class.read(path: path, backend: backend, roots: roots).to_s
        assert out.start_with?('Error: '), "#{path}: #{out}"
        assert_includes out, "is not inside the folders you can read (#{docs})"
      end
      assert_empty backend.calls
    end

    it 'refuses a relative path' do
      assert_equal "Error: path must be absolute, got 'note.txt'.", read(path: 'note.txt').to_s
    end

    it 'renders cat-n with a paging trailer for a windowed read' do
      out = read(text: (1..30).map { |i| "line #{i}" }.join("\n"), offset: 1, limit: 10).to_s
      assert_includes out, "     1\tline 1"
      assert_includes out, "    10\tline 10"
      refute_includes out, 'line 11'
      assert_includes out, 'Use offset=11 to continue'
    end

    it 'pages from an offset and reports end of file' do
      out = read(text: (1..5).map { |i| "line #{i}" }.join("\n"), offset: 3, limit: 100).to_s
      assert_includes out, "     3\tline 3"
      assert_includes out, "     5\tline 5"
      refute_includes out, 'line 2'
      assert_includes out, 'End of file - total 5 lines'
    end

    it 'reports the byte cap on indexed text larger than one window' do
      out = read(text: "#{'x' * 1000}\n" * 200).to_s
      assert_includes out, 'Output capped at 50 KB.'
      assert_match(/Use offset=\d+ to continue\./, out)
    end

    # localsearch hands a .docx over as one line, its paragraphs joined by spaces.
    it 'breaks a line longer than the per-line cap at a space, so all of it is read' do
      out = read(text: (1..800).map { |i| "word#{i}" }.join(' ')).to_s
      assert_includes out, 'word800'
      assert_includes out, "     2\tword"
      refute_includes out, 'line truncated'
    end

    it 'cuts a long line with no space at the cap' do
      out = read(text: 'x' * 4500).to_s
      assert_includes out, "     3\t#{'x' * 500}\n"
      refute_includes out, 'line truncated'
    end
  end

  describe '.read with a pattern' do
    def grep(pattern, **kwargs)
      read(text: "Kettle & Co.\nInvoice #4471\nItem: kettle\nTotal: EUR 506.50\nPaid by invoice, not card\n",
           pattern: pattern, **kwargs)
    end

    it 'returns only the matching lines, numbered as a read numbers them, ignoring case' do
      result = grep('invoice')
      assert_includes result.to_s, "     2\tInvoice #4471\n     5\tPaid by invoice, not card\n"
      refute_includes result.to_s, 'kettle'
      assert_includes result.to_s, 'Found 2 matching lines (the indexed text has 5 lines).'
      assert_equal 'Found 2 lines', result.summary
    end

    it 'searches from offset on' do
      out = grep('invoice', offset: 3).to_s
      refute_includes out, '#4471'
      assert_includes out, "     5\tPaid by invoice"
      assert_includes out, 'Found 1 matching line from line 3 on'
    end

    it 'stops at limit matches and names the offset to continue from' do
      out = grep('k|invoice', limit: 2).to_s
      assert_includes out, "     1\tKettle"
      assert_includes out, "     2\tInvoice"
      refute_includes out, 'Item'
      assert_includes out, 'same `pattern` and offset=3 for the rest'
    end

    it 'says so when nothing matches' do
      result = grep('refund')
      assert_equal 'No lines match /refund/ (the indexed text has 5 lines).', result.to_s
      assert_equal 'Found 0 lines', result.summary
    end

    it 'rejects a malformed pattern without reading the file' do
      backend = FakeBackend.build(text: 'body')
      out = described_class.read(path: "#{docs}/x.txt", pattern: '(', backend: backend, roots: roots).to_s
      assert_includes out, 'Error: bad pattern:'
      assert_empty backend.calls
    end

    it 'finds a match past the per-line cap of one long line' do
      out = read(text: (1..800).map { |i| "word#{i}" }.join(' '), pattern: 'word799').to_s
      assert_includes out, 'word799'
      refute_includes out, 'line truncated'
    end

    it 'treats an empty pattern as a plain read' do
      assert_includes grep('').to_s, "     3\tItem: kettle"
    end
  end

  it 'constructs as a Pikuri::Tool named fileindex_read' do
    tool = described_class.new(backend: FakeBackend.build, roots: roots)
    assert_kind_of Pikuri::Tool, tool
    assert_equal 'fileindex_read', tool.name
  end
end
