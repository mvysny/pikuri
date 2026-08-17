# frozen_string_literal: true

describe Pikuri::Lsp::Registry do
  entry = Pikuri::Lsp::Registry::StdioEntry
  ruby = entry.new(id: 'ruby', command: %w[ruby-lsp], files: %w[*.rb *.rake *.gemspec Rakefile Gemfile])
  java = entry.new(id: 'java', command: %w[jdtls -data /tmp/x], files: %w[*.java],
                   env: { 'JAVA_HOME' => '/usr/lib/jvm/java-21' },
                   init_options: { extendedClientCapabilities: { classFileContentsSupport: true } })

  describe Pikuri::Lsp::Registry::StdioEntry do
    it 'derives the language id from the first extension-bearing glob' do
      assert_equal 'ruby', ruby.language_id
      assert_equal 'java', java.language_id
    end

    it 'takes an explicit language id over the table' do
      assert_equal 'erb', entry.new(id: 'erb', command: %w[x], files: %w[*.rb], language_id: 'erb').language_id
    end

    it 'refuses to guess when no glob carries a known extension' do
      error = assert_raises(ArgumentError) { entry.new(id: 'make', command: %w[x], files: %w[Makefile]) }
      assert_includes error.message, 'language_id'
    end

    it 'matches globs against the basename, so a directory never picks the server' do
      assert ruby.claims?('/home/m/pikuri/lib/pikuri/agent.rb')
      assert ruby.claims?('Rakefile'), 'a glob, not an extension — Rakefile has none'
      assert ruby.claims?('/home/m/pikuri/Gemfile')
      refute ruby.claims?('/home/m/ruby-project/README.md'), 'a path saying "ruby" is not a Ruby file'
      refute ruby.claims?('Main.java')
      assert java.claims?('src/main/java/Main.java')
    end

    it 'carries the two per-server escape hatches verbatim' do
      assert_equal({ 'JAVA_HOME' => '/usr/lib/jvm/java-21' }, java.env)
      assert_equal({ extendedClientCapabilities: { classFileContentsSupport: true } }, java.init_options)
      assert_equal({}, ruby.env)
      assert_nil ruby.init_options
    end

    it 'refuses a configuration that cannot launch or dispatch' do
      assert_raises(ArgumentError) { entry.new(id: '', command: %w[ruby-lsp], files: %w[*.rb]) }
      assert_raises(ArgumentError) { entry.new(id: 'ruby', command: [], files: %w[*.rb]) }
      assert_raises(ArgumentError) { entry.new(id: 'ruby', command: %w[ruby-lsp], files: []) }
    end
  end

  describe '#entry_for' do
    registry = described_class.new(entries: [ruby, java])

    it 'picks the first server that claims the file' do
      assert_equal 'ruby', registry.entry_for('lib/pikuri/agent.rb').id
      assert_equal 'java', registry.entry_for('Main.java').id
    end

    it 'answers nil for a file no server claims' do
      assert_nil registry.entry_for('README.md')
    end

    it 'resolves an overlap by declaration order, silently' do
      greedy = entry.new(id: 'greedy', command: %w[x], files: %w[*.rb])
      assert_equal 'greedy', described_class.new(entries: [greedy, ruby]).entry_for('a.rb').id
      assert_equal 'ruby', described_class.new(entries: [ruby, greedy]).entry_for('a.rb').id
    end
  end

  it 'refuses duplicate ids, which would collide in logs and progress bars' do
    error = assert_raises(ArgumentError) { described_class.new(entries: [ruby, ruby]) }
    assert_includes error.message, 'ruby'
  end

  it 'has an empty singleton for a host that configures nothing' do
    assert described_class::EMPTY.empty?
    assert_nil described_class::EMPTY.entry_for('a.rb')
    refute described_class.new(entries: [ruby]).empty?
  end
end
