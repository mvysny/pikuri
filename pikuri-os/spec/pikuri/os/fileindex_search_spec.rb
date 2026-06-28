# frozen_string_literal: true

LOCALSEARCH_AVAILABLE = begin
  Pikuri::Subprocess.spawn('localsearch', '--version', chdir: '/').wait.status.success?
rescue Errno::ENOENT
  false
end unless defined?(LOCALSEARCH_AVAILABLE)

RSpec.describe Pikuri::Os::FileindexSearch do
  # Stub the LocalSearch backend so these run without the binary.
  def stub_backend_search(&block)
    original = Pikuri::Os::LocalSearch.method(:search)
    Pikuri::Os::LocalSearch.define_singleton_method(:search, &block)
    original
  end

  def restore_backend_search(original)
    Pikuri::Os::LocalSearch.define_singleton_method(:search, original)
  end

  describe '.search' do
    it 'rejects an empty query without touching the backend' do
      assert_equal 'Error: empty query.', described_class.search(query: '   ')
    end

    it 'renders path + snippet per hit and a one-match-per-file disclaimer' do
      original = stub_backend_search do |query:, limit:|
        [{ path: '/home/u/a.pdf', snippet: 'alpha beta' },
         { path: '/home/u/b.txt', snippet: nil }]
      end
      begin
        out = described_class.search(query: 'beta', limit: 10)
        assert_includes out, "/home/u/a.pdf\n  alpha beta"
        assert_includes out, '/home/u/b.txt'
        assert_includes out, 'one match shown per file'
        assert_includes out, 'Found 2 files'
      ensure
        restore_backend_search(original)
      end
    end

    it 'reports no matches on an empty result' do
      original = stub_backend_search { |**| [] }
      begin
        assert_includes described_class.search(query: 'nonesuch'), "No files found matching 'nonesuch'"
      ensure
        restore_backend_search(original)
      end
    end

    it 'renders a backend CommandError as an Error observation' do
      original = stub_backend_search { |**| raise Pikuri::Os::LocalSearch::CommandError, 'bad query' }
      begin
        assert_equal 'Error: localsearch: bad query', described_class.search(query: 'x')
      ensure
        restore_backend_search(original)
      end
    end

    it 'clamps limit to MAX_LIMIT' do
      seen = nil
      original = stub_backend_search do |query:, limit:|
        seen = limit
        []
      end
      begin
        described_class.search(query: 'x', limit: 9999)
        assert_equal described_class::MAX_LIMIT, seen
      ensure
        restore_backend_search(original)
      end
    end
  end

  if LOCALSEARCH_AVAILABLE
    it 'constructs as a Pikuri::Tool named fileindex_search' do
      tool = described_class.new
      assert_kind_of Pikuri::Tool, tool
      assert_equal 'fileindex_search', tool.name
    end
  else
    it 'raises a clear error at construction when localsearch is missing' do
      err = assert_raises(RuntimeError) { described_class.new }
      assert_includes err.message, 'localsearch'
    end
  end
end
