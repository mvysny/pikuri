# frozen_string_literal: true

require 'pathname'
require 'tmpdir'
require 'fileutils'

module Pikuri
  # Standardized on-disk locations for pikuri's local state, centralizing XDG
  # resolution so every disk-caching component roots under one place instead of
  # re-deriving it. The load-bearing distinction is {.cache} (shared across all
  # pikuri processes, persistent) vs. {.new_temp} (private to this process,
  # ephemeral) — reach for the wrong one and two concurrent processes clobber
  # each other's scratch.
  module Paths
    # +temp-*+ umbrellas older than this are reaped by {.sweep_stale_temps!} at
    # core load — generous enough not to disturb a long-lived process in another
    # shell, tight enough that one killed last week doesn't leak forever.
    #
    # @return [Integer] seconds
    TEMP_STALE_SECONDS = 7 * 24 * 60 * 60

    # Pikuri's cache root: +$XDG_CACHE_HOME/pikuri+ or +~/.cache/pikuri+.
    #
    # Shared across ALL pikuri processes and PERSISTENT (survives exit) — the
    # home for state meant to be reused: the URL cache, mem0 / Qdrant / Chroma
    # server data. For scratch private to *this* process that should vanish when
    # it exits, use {.new_temp}; reaching for +cache+ + a fixed subdir is how two
    # concurrent processes end up overwriting each other's files.
    #
    # A method, not a constant: a constant would snapshot +XDG_CACHE_HOME+ at
    # +require+ time, breaking env-stubbing in tests and a runtime change. Not
    # created — callers +mkdir_p+ the subdir they need.
    #
    # @return [Pathname] the +<cache home>/pikuri+ directory
    def self.cache
      home = ENV['XDG_CACHE_HOME']
      home = File.expand_path('~/.cache') if home.nil? || home.empty?
      Pathname.new(home).join('pikuri')
    end

    # A fresh scratch dir private to this process, reaped at exit via
    # {Pikuri::Finalizers} (and stale-swept by {.sweep_stale_temps!} for strays a
    # crash leaves behind). Mint one per concurrent-safe scratch need and hold
    # the result:
    #
    #   dir  = Paths.new_temp                       # ~/.cache/pikuri/temp-XXXX/
    #   snap = Snapshot.new(source: db, dir: dir)   # can't collide with another process
    #
    # Minted IN HOME under {.cache} — never +/tmp+ — for two concrete reasons: a
    # +cp --reflink=auto+ copy shares extents only on the source's filesystem
    # (the copied DB lives under +$HOME+), and the bubblewrap sandbox binds its
    # scratch at +/tmp+ inside, so an umbrella already under +/tmp+ would bind on
    # top of itself.
    #
    # A factory — a *new* dir each call (hence +new_+, not a memoized accessor
    # like {.cache}); a caller memoizes if it wants one stable dir, but per
    # *consumer*, not per process. Memoizing one at process scope and handing it
    # to several agents puts two writers on one path — the collision this exists
    # to prevent, moved inside the process.
    #
    # @return [Pathname] absolute, symlink-resolved path of the freshly-made dir
    def self.new_temp
      FileUtils.mkdir_p(cache)
      path = Pathname.new(Dir.mktmpdir('temp-', cache)).realpath
      Pikuri::Finalizers.register { FileUtils.remove_entry(path.to_s) if path.exist? }
      path
    end

    # Reap +temp-*+ umbrellas under {.cache} older than {TEMP_STALE_SECONDS}.
    # Called once at core load (so every binary sweeps, regardless of which gems
    # it wires) — the net for a process killed before its {Pikuri::Finalizers}
    # reap could fire. Failures are swallowed (best-effort; the Finalizers
    # removal is the load-bearing path), and recent dirs are left for concurrent
    # processes.
    #
    # @return [void]
    def self.sweep_stale_temps!
      return unless File.directory?(cache)

      cutoff = Time.now - TEMP_STALE_SECONDS
      Dir.children(cache).each do |entry|
        next unless entry.start_with?('temp-')

        path = File.join(cache, entry)
        next unless File.directory?(path)
        next if File.mtime(path) > cutoff

        FileUtils.remove_entry(path)
      rescue StandardError
        # best-effort sweep; never block the host on dead state
      end
    end

    # Pikuri's config root: +$XDG_CONFIG_HOME/pikuri+ or +~/.config/pikuri+.
    # Home for user-owned, hand-edited config (the OS helper's +MACHINE.md+).
    #
    # A method for the same reason as {.cache}. Not created — config is
    # user-owned, so callers +mkdir_p+ only when writing.
    #
    # @return [Pathname] the +<config home>/pikuri+ directory
    def self.config
      home = ENV['XDG_CONFIG_HOME']
      home = File.expand_path('~/.config') if home.nil? || home.empty?
      Pathname.new(home).join('pikuri')
    end

    # Pikuri's state root: +$XDG_STATE_HOME/pikuri+ or +~/.local/state/pikuri+.
    # Created automatically. For state that persists across restarts but isn't
    # portable enough for XDG_DATA_HOME (logs, history, layout).
    #
    # @return [Pathname] the +<state home>/pikuri+ directory
    def self.state
      state = ENV['XDG_STATE_HOME']
      state = File.expand_path('~/.local/state') if state.nil? || state.empty?
      state = Pathname.new(state).join('pikuri')
      FileUtils.mkdir_p(state.to_path)
      state
    end
  end
end
