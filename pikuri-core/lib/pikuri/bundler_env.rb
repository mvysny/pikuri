# frozen_string_literal: true

module Pikuri
  # The environment a child process should see when pikuri itself booted under
  # Bundler. Merge it under whatever the child's own configuration asks for:
  #
  #   Open3.popen3(BundlerEnv.clean_delta.merge(entry.env), *entry.command)
  #
  # Bundler implements +bundler/setup+ by rewriting the process environment —
  # it injects +BUNDLE_GEMFILE+ and +RUBYOPT+, repoints +GEM_HOME+ /
  # +GEM_PATH+, prepends the bundle's bin dir to +PATH+, and stashes each
  # original under +BUNDLER_ORIG_<NAME>+. A child inherits all of it, and for a
  # child that is itself Ruby that reads as the child being broken: a
  # +bundle exec+ the agent runs in another project resolves against *pikuri's*
  # Gemfile, and +ruby-lsp+ refuses to start at all ("can't find executable
  # ruby-lsp for gem ruby-lsp") unless pikuri's Gemfile happens to list it. Such
  # a child serves the *target project*, so it must see the environment the user
  # had before pikuri started.
  #
  # == Implementation details
  #
  # A delta rather than a scrub, for two reasons. A spawn's +env:+ is additive,
  # so removal has to be spelled as an explicit +nil+; and Bundler *changed*
  # variables it did not invent, so the fix restores each +BUNDLER_ORIG_*+
  # backup — a host-level +GEM_HOME+ from an apt-installed Ruby passes through,
  # where a blanket +GEM_*+ wipe would have eaten it.
  #
  # This does not break the "environment is not a secret store" seam, which
  # says pikuri never filters +ENV+ before spawning: nothing the user set is
  # removed, only pikuri's own boot undone.
  module BundlerEnv
    # The delta that, merged onto the current (bundler-polluted) +ENV+,
    # reconstructs +Bundler.unbundled_env+.
    #
    # Empty when pikuri runs without Bundler (gem-installed, or a host that
    # never required +bundler/setup+), so the child inherits +ENV+ unchanged
    # and no caller needs a branch of its own.
    #
    # @return [Hash{String=>(String,nil)}] an +env:+ for
    #   {Pikuri::Subprocess.spawn}, +Open3.popen3+ or +Process.spawn+; a +nil+
    #   value unsets that variable in the child.
    def self.clean_delta
      return {} unless defined?(Bundler) && Bundler.respond_to?(:unbundled_env)

      env_delta(current: ENV.to_h, clean: Bundler.unbundled_env)
    end

    # The additive delta that turns +current+ into +clean+ when passed as a
    # spawn's +env:+.
    #
    #   env_delta(current: { 'BUNDLE_GEMFILE' => '/pikuri/Gemfile', 'PATH' => '/bin' },
    #             clean:   { 'PATH' => '/bin' })
    #   # => { 'BUNDLE_GEMFILE' => nil }
    #
    # Keys equal in both are omitted, so a child's inherited environment is
    # otherwise untouched.
    #
    # @param current [Hash{String=>String}]
    # @param clean [Hash{String=>String}]
    # @return [Hash{String=>(String,nil)}] +nil+ where +clean+ lacks the key.
    def self.env_delta(current:, clean:)
      delta = {}
      clean.each { |k, v| delta[k] = v unless current[k] == v }
      current.each_key { |k| delta[k] = nil unless clean.key?(k) }
      delta
    end
  end
end
