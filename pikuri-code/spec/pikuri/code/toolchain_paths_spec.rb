# frozen_string_literal: true

RSpec.describe Pikuri::Code::ToolchainPaths do
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

    it 'does not contain any of the ephemeral_overlay paths (no overlap)' do
      # The two lists are disjoint by design — overlay paths get
      # writable overlay treatment in the sandbox; readable paths are
      # true read-only. Overlap would mean ambiguous semantics in
      # Bubblewrap's iteration.
      Dir.mktmpdir do |fake_home|
        original = ENV.fetch('HOME', nil)
        ENV['HOME'] = fake_home
        # Populate every candidate dir so the presence filter passes
        # for both lists.
        %w[
          .local/share/mise .config/mise .asdf .rbenv .pyenv .nvm .rustup
          .cargo/registry .m2/repository .gradle .ivy2 go/pkg/mod
          .cache/pip .cache/uv .npm .local/share/pnpm/store .nuget/packages
        ].each { |p| FileUtils.mkdir_p(File.join(fake_home, p)) }

        readable_set = described_class.readable.to_set
        overlap = described_class.ephemeral_overlay.select { |p| readable_set.include?(p) }
        assert_empty overlap, "expected disjoint lists; overlapping paths: #{overlap.inspect}"
      ensure
        ENV['HOME'] = original
      end
    end
  end

  describe '.ephemeral_overlay' do
    it 'returns only directories that exist' do
      paths = described_class.ephemeral_overlay
      paths.each { |p| assert File.directory?(p), "expected #{p} to be a directory" }
    end

    it 'is frozen' do
      assert described_class.ephemeral_overlay.frozen?
    end

    it 'omits non-existent candidates (presence filter)' do
      Dir.mktmpdir do |fake_home|
        original = ENV.fetch('HOME', nil)
        ENV['HOME'] = fake_home
        # No toolchain dirs created → list must be empty.
        assert_empty described_class.ephemeral_overlay
      ensure
        ENV['HOME'] = original
      end
    end

    it 'includes ~/.gradle when present on the host' do
      Dir.mktmpdir do |fake_home|
        original = ENV.fetch('HOME', nil)
        ENV['HOME'] = fake_home
        FileUtils.mkdir_p(File.join(fake_home, '.gradle'))

        assert_includes described_class.ephemeral_overlay, File.join(fake_home, '.gradle')
      ensure
        ENV['HOME'] = original
      end
    end

    it 'includes ~/.m2/repository (not the whole ~/.m2, which would expose settings.xml credentials)' do
      Dir.mktmpdir do |fake_home|
        original = ENV.fetch('HOME', nil)
        ENV['HOME'] = fake_home
        FileUtils.mkdir_p(File.join(fake_home, '.m2/repository'))

        paths = described_class.ephemeral_overlay
        assert_includes paths, File.join(fake_home, '.m2/repository')
        refute_includes paths, File.join(fake_home, '.m2')
      ensure
        ENV['HOME'] = original
      end
    end
  end
end
