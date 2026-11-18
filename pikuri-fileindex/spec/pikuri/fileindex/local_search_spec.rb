# frozen_string_literal: true

# Parsing and argv, with Subprocess.spawn stubbed (CI has no localsearch).
# The real index is exercised by local_search_index_spec.rb.
RSpec.describe Pikuri::Fileindex::LocalSearch do
  # Stubs spawn to answer +output+ (or, when it is a Proc, what it answers
  # for the argv) and records each argv in +calls+.
  def stub_spawn(success:, output:, calls: [])
    original = Pikuri::Subprocess.method(:spawn)
    result_struct = Struct.new(:status, :output) do
      def wait; self; end
    end
    status_struct = Struct.new(:success?, :exitstatus)
    Pikuri::Subprocess.define_singleton_method(:spawn) do |*args, **_kwargs|
      calls << args
      result_struct.new(status_struct.new(success, success ? 0 : 1), output.is_a?(Proc) ? output.call(args) : output)
    end
    original
  end

  def restore_spawn(original)
    Pikuri::Subprocess.define_singleton_method(:spawn, original)
  end

  def with_spawn(**kwargs)
    original = stub_spawn(**kwargs)
    yield
  ensure
    restore_spawn(original)
  end

  # The +--arg name:type:value+ pairs of one recorded argv.
  def args_of(argv)
    argv.each_cons(2).select { |flag, _| flag == '--arg' }.to_h { |_, arg| arg.split(':', 2) }
  end

  def q(text) = Pikuri::Fileindex::Query.parse(text)

  describe '.file_uri' do
    it 'escapes the way GLib does: reserved sub-delims stay, the rest is %XX per byte' do
      assert_equal "file:///a/b%20c/%C3%BC%23%3B%3F%25,&=+$!'()*~@:/x.txt",
                   described_class.file_uri("/a/b c/ü#;?%,&=+$!'()*~@:/x.txt")
    end
  end

  describe '.parse_rows' do
    it 'decodes the marked cells of each row, commas and newlines included' do
      raw = "Results:\n  v:file%3A%2F%2F%2Fa%2Fb%2520c.txt, v:one%2C%20two%0Athree\n\n"
      assert_equal [['file:///a/b%20c.txt', "one, two\nthree"]], described_class.parse_rows(raw)
    end

    it 'turns an unbound cell into nil' do
      assert_equal [['x', nil]], described_class.parse_rows("Results:\n  v:x, (null)\n")
    end

    it 'skips the unmarked header and empty-result lines, whatever their language' do
      assert_empty described_class.parse_rows("Výsledky:\n  Žádné\n")
    end
  end

  describe '.search' do
    it 'maps rows to paths, one-line snippets, text sizes and a short text whole' do
      out = "Results:\n  v:file%3A%2F%2F%2Fa%2Fb%2520c.txt, v:alpha%0A%20beta, v:812, v:\n" \
            "  v:file%3A%2F%2F%2Fs.md, v:%3E%3Eshort%3C%3C, v:13, v:short%0A%20note%0A\n" \
            "  v:file%3A%2F%2F%2Fd.rb, v:, (null), (null)\n"
      with_spawn(success: true, output: out) do
        assert_equal [{ path: '/a/b c.txt', snippet: 'alpha beta', text_size: 812, text: nil },
                      { path: '/s.md', snippet: '>>short<<', text_size: 13, text: "short\n note\n" },
                      { path: '/d.rb', snippet: nil, text_size: nil, text: nil }],
                     described_class.search(query: q('beta'), limit: 5, folders: ['/'])
      end
    end

    it 'binds each folder as an escaped URI prefix, with a trailing slash, and the query and limit' do
      calls = []
      with_spawn(success: true, output: "Results:\n  None\n", calls: calls) do
        described_class.search(query: q('tax'), limit: 7, folders: ['/home/u/My Docs', '/home/u/Downloads/'])
      end
      args = args_of(calls.first)
      assert_equal 's:file:///home/u/My%20Docs/', args['folder0']
      assert_equal 's:file:///home/u/Downloads/', args['folder1']
      assert_equal 's:tax', args['group0']
      assert_equal 'i:7', args['limit']
      assert_equal %w[tinysparql query -b org.freedesktop.LocalSearch3], calls.first.first(4)
      query = calls.first[calls.first.index('-q') + 1]
      assert_includes query, 'FILTER (STRSTARTS(?url, ~folder0) || STRSTARTS(?url, ~folder1))'
      refute_includes query, 'home/u', 'a path is bound, never spliced'
    end

    it 'binds each group, matched in a branch of its own, and ranks by groups matched' do
      [:search, :paths].each do |method|
        calls = []
        with_spawn(success: true, output: "Results:\n  None\n", calls: calls) do
          args = { query: q('notice "due date"'), folders: ['/a'] }
          method == :search ? described_class.search(**args, limit: 5) : described_class.paths(**args)
        end
        assert_equal ['s:notice', 's:due date'], args_of(calls.first).values_at('group0', 'group1')
        query = calls.first[calls.first.index('-q') + 1]
        assert_equal 2, query.scan('fts:match ~group0').size, "#{method}: name and text branch"
        assert_equal 2, query.scan('fts:match ~group1').size, method
        refute_match(/notice|due date/, query, 'a word is bound, never spliced')
      end
    end

    it 'filters the root folder as every local file' do
      calls = []
      with_spawn(success: true, output: '', calls: calls) { described_class.search(query: q('x'), limit: 1, folders: ['/']) }
      assert_equal 's:file:///', args_of(calls.first)['folder0']
    end

    it 'raises CommandError with the CLI message on a non-zero exit' do
      with_spawn(success: false, output: 'Could not run query') do
        err = assert_raises(Pikuri::Fileindex::LocalSearch::CommandError) { described_class.search(query: q('x'), limit: 5, folders: ['/']) }
        assert_equal 'Could not run query', err.message
      end
    end
  end

  describe '.read_text' do
    it 'returns the decoded stored text, asking by escaped URI' do
      calls = []
      with_spawn(success: true, output: "Results:\n  v:doc%0Abody\n", calls: calls) do
        assert_equal "doc\nbody", described_class.read_text('/a/b c.pdf')
      end
      assert_equal 's:file:///a/b%20c.pdf', args_of(calls.first)['url']
    end

    it 'returns nil when the index holds no text' do
      with_spawn(success: true, output: "Results:\n  None\n") { assert_nil described_class.read_text('/x') }
    end

    it 'returns nil on a non-zero exit' do
      with_spawn(success: false, output: 'boom') { assert_nil described_class.read_text('/x') }
    end
  end

  describe '.unavailable_reason' do
    def hit = "Results:\n  v:file%3A%2F%2F%2Fhome%2Fu%2Fa.txt\n"
    def none = "Results:\n  None\n"

    # Answers a file for the probe of every folder in +held+, none otherwise.
    def holding(*held)
      ->(argv) { held.any? { |folder| args_of(argv)['folder0'] == "s:file://#{folder}/" } ? hit : none }
    end

    def capture_warnings
      io = StringIO.new
      original = Pikuri.log_io
      Pikuri.log_io = io
      yield
      io.string
    ensure
      Pikuri.log_io = original
    end

    it 'is nil when every folder holds a file' do
      with_spawn(success: true, output: hit) { assert_nil described_class.unavailable_reason(folders: ['/a']) }
    end

    it 'is nil when one folder holds a file, warning about each empty one' do
      log = capture_warnings do
        with_spawn(success: true, output: holding('/docs')) do
          assert_nil described_class.unavailable_reason(folders: ['/desk', '/docs', '/down'])
        end
      end
      assert_includes log, 'nothing under /desk is indexed'
      assert_includes log, 'nothing under /down is indexed'
      refute_includes log, '/docs'
    end

    it 'names every folder when none holds a file' do
      with_spawn(success: true, output: none) do
        reason = described_class.unavailable_reason(folders: ['/a', '/b'])
        assert reason.start_with?('nothing under /a, /b is indexed.'), reason
        assert_includes reason, 'GNOME Settings → Search'
      end
    end

    it 'names the indexer package and what tinysparql said when the index does not answer' do
      said = 'Could not establish a connection to Tracker: The name org.freedesktop.LocalSearch3 ' \
             'was not provided by any .service files'
      with_spawn(success: false, output: said) do
        reason = described_class.unavailable_reason(folders: ['/a'])
        assert_includes reason, said
        assert_includes reason, "'localsearch' package"
      end
    end

    it 'names both packages when tinysparql is missing' do
      original = Pikuri::Subprocess.method(:spawn)
      Pikuri::Subprocess.define_singleton_method(:spawn) { |*_a, **_k| raise Errno::ENOENT, 'tinysparql' }
      begin
        reason = described_class.unavailable_reason(folders: ['/a'])
        assert_includes reason, "'tinysparql' command is missing"
        assert_includes reason, "'localsearch'"
      ensure
        restore_spawn(original)
      end
    end
  end
end
