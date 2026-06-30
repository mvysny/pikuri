# frozen_string_literal: true

RSpec.describe Pikuri::Os::SystemInfo do
  describe '.render' do
    it 'renders facts as "- Label: value" in order, skipping nil/blank' do
      out = described_class.render(
        os: 'Ubuntu 26.04 LTS', kernel: '7.0.0 x86_64', init: 'systemd',
        desktop: nil, hostname: 'box', home: '/home/u', shell: '/usr/bin/fish',
        cpus: 8, memory: '23.5 GiB', date: '2026-06-28 10:00:00 +0000'
      )
      assert_includes out, '- OS: Ubuntu 26.04 LTS'
      assert_includes out, '- Kernel: 7.0.0 x86_64'
      assert_includes out, '- Init: systemd'
      assert_includes out, '- CPUs: 8'
      refute_includes out, 'Desktop', 'nil facts are skipped'
      # OS line precedes Kernel line (FACT_ORDER honored).
      assert out.index('- OS:') < out.index('- Kernel:')
    end
  end

  describe '#facts (on this host)' do
    let(:facts) { described_class.new.facts }

    it 'reports the core facts as a hash with the expected keys' do
      assert_equal Pikuri::Os::SystemInfo::FACT_ORDER.map(&:first).sort, facts.keys.sort
    end

    it 'reads real values from primitives' do
      assert_kind_of String, facts[:os]      # /etc/os-release present on Linux CI
      assert_equal Dir.home, facts[:home]
      assert_kind_of Integer, facts[:cpus]
      assert_match(/\A\d{4}-\d\d-\d\d /, facts[:date])
    end
  end

  describe '#prompt_section' do
    it 'always includes the heading and the primitive core' do
      out = described_class.new.prompt_section
      assert_includes out, '# This machine'
      assert_includes out, '- OS:'
      assert_includes out, '- CPUs:'
    end

    it 'appends the inxi block when inxi is present (stubbed)' do
      original = Pikuri::Subprocess.method(:spawn)
      result_struct = Struct.new(:status, :output) do
        def wait; self; end
      end
      status_struct = Struct.new(:success?, :exitstatus)
      Pikuri::Subprocess.define_singleton_method(:spawn) do |*_args, **_kwargs|
        result_struct.new(status_struct.new(true, 0), "System:\n  Host: box Kernel: 7.0.0\n")
      end
      begin
        out = described_class.new.prompt_section
        assert_includes out, 'inxi -b'
        assert_includes out, 'Host: box'
      ensure
        Pikuri::Subprocess.define_singleton_method(:spawn, original)
      end
    end

    it 'omits the inxi block when inxi is absent (stubbed ENOENT)' do
      original = Pikuri::Subprocess.method(:spawn)
      Pikuri::Subprocess.define_singleton_method(:spawn) do |*_args, **_kwargs|
        raise Errno::ENOENT, 'inxi'
      end
      begin
        out = described_class.new.prompt_section
        refute_includes out, 'inxi -b'
        assert_includes out, '# This machine' # core still present
      ensure
        Pikuri::Subprocess.define_singleton_method(:spawn, original)
      end
    end

    it 'is memoized — the inxi subprocess runs at most once across repeated calls' do
      original = Pikuri::Subprocess.method(:spawn)
      spawns = 0
      result_struct = Struct.new(:status, :output) { def wait = self }
      status_struct = Struct.new(:success?, :exitstatus)
      Pikuri::Subprocess.define_singleton_method(:spawn) do |*_args, **_kwargs|
        spawns += 1
        result_struct.new(status_struct.new(true, 0), "System:\n  Host: box\n")
      end
      begin
        info = described_class.new
        first = info.prompt_section
        second = info.prompt_section

        assert_equal 1, spawns # second call hit the memo, no re-spawn
        assert_same first, second # same frozen-snapshot String object
      ensure
        Pikuri::Subprocess.define_singleton_method(:spawn, original)
      end
    end
  end
end
