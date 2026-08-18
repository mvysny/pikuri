# frozen_string_literal: true

# A child must not inherit the BUNDLE_*/RUBYOPT/GEM_* rewrite pikuri's own
# boot injected, or a Ruby child resolves its gems out of pikuri's bundle: a
# `bundle exec` the agent runs in another project dies, and `ruby-lsp` refuses
# to start at all. These are the pure diff that turns the polluted ENV back
# into Bundler.unbundled_env.
RSpec.describe Pikuri::BundlerEnv do
  describe '.env_delta' do
    it 'unsets a bundler-injected var the clean env lacks (nil ⇒ removed in child)' do
      delta = described_class.env_delta(
        current: { 'BUNDLE_GEMFILE' => '/pikuri/Gemfile', 'PATH' => '/bin' },
        clean: { 'PATH' => '/bin' }
      )

      assert delta.key?('BUNDLE_GEMFILE'), 'expected BUNDLE_GEMFILE in the delta'
      assert_nil delta['BUNDLE_GEMFILE'], 'expected BUNDLE_GEMFILE unset (nil) in the child'
    end

    it 'restores a host value the clean env changed (apt-ruby GEM_HOME, not a blanket GEM_* wipe)' do
      delta = described_class.env_delta(current: { 'GEM_HOME' => '/proj/.bundle/ruby' },
                                        clean: { 'GEM_HOME' => '/home/u/.gem' })

      assert_equal '/home/u/.gem', delta['GEM_HOME']
    end

    it 'omits keys both envs share (minimal delta)' do
      delta = described_class.env_delta(current: { 'PATH' => '/bin', 'HOME' => '/home/u' },
                                        clean: { 'PATH' => '/bin', 'HOME' => '/home/u' })

      assert_equal({}, delta)
    end
  end

  describe '.clean_delta' do
    it 'is empty when Bundler is absent (gem-installed / no bundler/setup)' do
      # Specs run under bundler, so Bundler is defined here. Swap it out
      # for a stand-in WITHOUT #unbundled_env to drive the no-bundler path.
      saved = Object.send(:remove_const, :Bundler)
      Object.const_set(:Bundler, Module.new)
      assert_equal({}, described_class.clean_delta)
    ensure
      Object.send(:remove_const, :Bundler)
      Object.const_set(:Bundler, saved)
    end

    it 'unsets BUNDLE_GEMFILE under the bundler these specs run in' do
      skip 'specs are not running under bundler' unless ENV['BUNDLE_GEMFILE']

      delta = described_class.clean_delta

      assert delta.key?('BUNDLE_GEMFILE'), 'expected the live bundler env to be corrected'
      assert_nil delta['BUNDLE_GEMFILE']
    end
  end
end
