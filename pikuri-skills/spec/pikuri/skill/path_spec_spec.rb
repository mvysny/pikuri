# frozen_string_literal: true

RSpec.describe Pikuri::Skill::PathSpec do
  # Warnings go through Pikuri's logger, which the spec_helper points at
  # /dev/null; redirect to a StringIO so the fail-open warning can be asserted.
  def captured_log
    captured = StringIO.new
    original = Pikuri.log_io
    Pikuri.log_io = captured
    yield
    captured.string
  ensure
    Pikuri.log_io = original if original
  end

  def parse(value)
    described_class.parse(value, path: '/skills/x/SKILL.md')
  end

  describe 'the unconditional spellings' do
    it 'treats an absent key as unconditional' do
      assert_equal [], parse(nil)
    end

    it 'treats an empty list as unconditional, not as "matches nothing"' do
      assert_equal [], parse([])
    end

    it 'treats a match-all pattern as unconditional' do
      assert_equal [], parse(['**'])
      assert_equal [], parse('**')
    end

    it 'treats a list of nothing but match-all patterns as unconditional' do
      assert_equal [], parse(['**', '/**'])
    end
  end

  describe 'sequences' do
    it 'keeps the patterns in the authored order' do
      assert_equal ['**/*.rb', '**/*.gemspec'], parse(['**/*.rb', '**/*.gemspec'])
    end

    it 'strips a trailing /** so src and src/** compare equal' do
      assert_equal parse(['src']), parse(['src/**'])
      assert_equal ['src'], parse(['src/**'])
    end

    it 'strips the suffix once only' do
      assert_equal ['src/**'], parse(['src/**/**'])
    end

    it 'drops blank entries' do
      assert_equal ['docs'], parse(['', '  ', 'docs'])
    end
  end

  describe 'scalars' do
    it 'comma-splits a single string' do
      assert_equal %w[src docs], parse('src/**, docs')
    end

    it 'protects commas inside a brace group' do
      assert_equal ['{app,lib}/**/*.rb', 'spec'], parse('{app,lib}/**/*.rb, spec')
    end

    it 'comma-splits inside a sequence element too' do
      assert_equal %w[src docs spec], parse(['src, docs', 'spec'])
    end
  end

  describe 'a value that is neither' do
    it 'warns and leaves the skill unconditional rather than hiding it' do
      log = captured_log { assert_equal [], parse({ 'src' => true }) }
      assert_match(/'paths:' must be a string or a list of strings/, log)
      assert_match(/stays unconditional/, log)
    end

    it 'refuses a mixed list rather than reading half of it' do
      log = captured_log { assert_equal [], parse(['src', 42]) }
      assert_match(/must be a string or a list of strings/, log)
    end

    it 'says nothing when the key is simply absent' do
      log = captured_log { parse(nil) }
      assert_equal '', log
    end
  end
end
