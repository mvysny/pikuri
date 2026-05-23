# frozen_string_literal: true

RSpec.describe Pikuri::Tool::CodingPaths do
  describe '.readable' do
    it 'returns only directories that exist' do
      paths = described_class.readable
      paths.each { |p| assert File.directory?(p), "expected #{p} to be a directory" }
    end

    it 'is frozen' do
      assert described_class.readable.frozen?
    end

    it 'includes /usr on a typical Linux host' do
      skip 'no /usr on this system' unless File.directory?('/usr')
      assert_includes described_class.readable, '/usr'
    end

    it 'omits non-existent candidates (presence filter)' do
      Dir.mktmpdir do |fake_home|
        original = ENV.fetch('HOME', nil)
        ENV['HOME'] = fake_home
        paths = described_class.readable
        paths.each do |p|
          refute p.start_with?(fake_home), "expected #{p} to be filtered out for empty home"
        end
      ensure
        ENV['HOME'] = original
      end
    end
  end
end
