# frozen_string_literal: true

require 'json'
require 'tempfile'

# Probed once at load: localsearch is a GNOME desktop component, absent
# in CI. The end-to-end / construction tests gate on it; the pure-logic
# tests (parsing, windowing, extraction) call class methods directly and
# run everywhere.
LOCALSEARCH_AVAILABLE = begin
  Pikuri::Subprocess.spawn('localsearch', '--version', chdir: '/').wait.status.success?
rescue Errno::ENOENT
  false
end

RSpec.describe Pikuri::Os::LocalSearch do
  describe '.parse_search_hits' do
    it 'pairs each path with its ANSI-highlighted matched word(s), percent-decoded and de-duped' do
      raw = "file:///home/u/Documents/report.pdf (urn:fileid:x:1)\n" \
            "  …physical or \e[0;1;39menvironmental\e[0m damage…\n" \
            "\n" \
            "file:///home/u/My%20Notes/todo.txt ((null))\n" \
            "  \e[0;1;39mEnvironmentalReverb\e[0m.java\n" \
            "\n" \
            "file:///home/u/Documents/report.pdf (urn:fileid:x:1)\n"
      hits = described_class.parse_search_hits(raw)
      assert_equal ['/home/u/Documents/report.pdf', '/home/u/My Notes/todo.txt'],
                   hits.map { |h| h[:path] }
      assert_equal ['environmental'], hits[0][:terms]
      assert_equal ['EnvironmentalReverb'], hits[1][:terms]
    end

    it 'returns [] when there are no file:// lines' do
      assert_empty described_class.parse_search_hits("no results\n")
    end

    it 'tolerates a hit whose snippet has no highlight (empty terms)' do
      hits = described_class.parse_search_hits("file:///a/b.txt (urn:x)\n  plain snippet, no color\n")
      assert_equal '/a/b.txt', hits[0][:path]
      assert_empty hits[0][:terms]
    end
  end

  describe '.extract_plain_text' do
    it 'walks the nested @graph to find nie:plainTextContent' do
      json = JSON.generate(
        '@context' => { 'nie' => 'http://...' },
        '@graph' => [{ '@id' => 'a', '@graph' => [{ '@id' => 'b', 'nie:plainTextContent' => 'hello world' }] }]
      )
      assert_equal 'hello world', described_class.extract_plain_text(json)
    end

    it 'returns nil when the key is absent' do
      assert_nil described_class.extract_plain_text('{"@graph":[{"a":1}]}')
    end

    it 'returns nil for non-JSON' do
      assert_nil described_class.extract_plain_text('not json at all')
    end

    it 'is lenient: recovers JSON after a stray diagnostic prefix' do
      raw = "WARN: something\n{\"nie:plainTextContent\":\"recovered\"}"
      assert_equal 'recovered', described_class.extract_plain_text(raw)
    end
  end

  describe '.window_around' do
    let(:fifty) { (1..50).map { |i| "w#{i}" }.join(' ') }

    it 'centres an interior window on the match, with ellipses both sides' do
      out = described_class.window_around(fifty, ['w25'], 10)
      assert_includes out, 'w25'
      assert_includes out, 'w20'
      assert_includes out, 'w30'
      refute_includes out, 'w19'
      refute_includes out, 'w31'
      assert out.start_with?('… '), "expected leading ellipsis: #{out.inspect}"
      assert out.end_with?(' …'),   "expected trailing ellipsis: #{out.inspect}"
    end

    it 'falls back to the document head when no term is found literally' do
      out = described_class.window_around(fifty, ['zzz'], 5)
      assert out.start_with?('w1 w2 w3'), out.inspect
      refute out.start_with?('… '), 'head window has no leading ellipsis'
      assert out.end_with?(' …'), 'head of a longer doc has a trailing ellipsis'
    end

    it 'matches by substring (a term contained in an indexed word — query fallback)' do
      out = described_class.window_around('the quick environmental fox', ['environment'], 10)
      assert_includes out, 'environmental'
    end

    it 'returns the whole text without ellipses when shorter than the window' do
      assert_equal 'a b c', described_class.window_around('a b c', ['b'], 100)
    end

    it 'returns empty string for empty text' do
      assert_equal '', described_class.window_around('   ', ['x'], 100)
    end
  end

  describe '.head_truncate' do
    it 'truncates oversized output at a newline boundary with a marker' do
      big = (["x" * 100] * 1000).join("\n") # ~100 KB, > MAX_BYTES
      content, marker = described_class.send(:head_truncate, big)
      assert content.bytesize <= described_class::MAX_BYTES
      assert content.bytesize.positive?, 'truncation should keep a non-empty head'
      assert_includes marker, 'bytes omitted'
      assert_includes marker, 'total was'
    end

    it 'leaves small output untouched (empty marker)' do
      content, marker = described_class.send(:head_truncate, "short\noutput")
      assert_equal "short\noutput", content
      assert_equal '', marker
    end
  end

  describe '.search_files' do
    it 'rejects an empty query before spawning anything' do
      assert_equal 'Error: empty query.', described_class.search_files(query: '   ')
    end

    it 'runs the full search → info → window pipeline (stubbed subprocess)' do
      file = Tempfile.create(['pikuri-ls', '.txt'])
      path = file.path
      original = Pikuri::Subprocess.method(:spawn)
      result_struct = Struct.new(:status, :output) do
        def wait; self; end
      end
      status_struct = Struct.new(:success?, :exitstatus)

      Pikuri::Subprocess.define_singleton_method(:spawn) do |*args, **_kwargs|
        out =
          if args.include?('search')
            # -d format: path + URN, then a snippet with the matched word
            # ANSI-highlighted.
            "file://#{path} (urn:x:1)\n  …alpha beta \e[0;1;39mneedle\e[0m gamma…\n"
          elsif args.include?('info')
            JSON.generate('@graph' => [{ '@graph' => [{ 'nie:plainTextContent' =>
              'alpha beta needle gamma delta' }] }])
          else
            ''
          end
        result_struct.new(status_struct.new(true, 0), out)
      end

      begin
        out = described_class.search_files(query: 'needle', limit: 5, window_words: 4)
        assert_includes out, path
        assert_includes out, 'needle'
        assert_includes out, 'Found 1 file'
      ensure
        Pikuri::Subprocess.define_singleton_method(:spawn, original)
        file.close
        File.unlink(path) if File.exist?(path)
      end
    end

    it 'reports no matches when search returns nothing (stubbed)' do
      original = Pikuri::Subprocess.method(:spawn)
      result_struct = Struct.new(:status, :output) do
        def wait; self; end
      end
      status_struct = Struct.new(:success?, :exitstatus)
      Pikuri::Subprocess.define_singleton_method(:spawn) do |*_args, **_kwargs|
        result_struct.new(status_struct.new(true, 0), "no results\n")
      end
      begin
        out = described_class.search_files(query: 'nonesuch')
        assert_includes out, "No files found matching 'nonesuch'"
      ensure
        Pikuri::Subprocess.define_singleton_method(:spawn, original)
      end
    end
  end

  if LOCALSEARCH_AVAILABLE
    it 'constructs as a Pikuri::Tool named search_files' do
      tool = described_class.new
      assert_kind_of Pikuri::Tool, tool
      assert_equal 'search_files', tool.name
    end

    it 'end-to-end smoke: a real search returns a String observation' do
      described_class.new # proves the binary is wired
      out = described_class.search_files(query: 'the', limit: 2, window_words: 40)
      assert_kind_of String, out
    end
  else
    it 'raises a clear error at construction when localsearch is missing' do
      err = assert_raises(RuntimeError) { described_class.new }
      assert_includes err.message, 'localsearch'
    end
  end
end
