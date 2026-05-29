# frozen_string_literal: true

require 'pathname'
require 'monitor'

module Pikuri
  module VectorDb
    # The auto-watch daemon: keep a persistent index in sync with a
    # corpus on disk, without the user ever calling
    # +vectordb_reindex+. A thin layer over the +listen+ gem that
    # drives the {Indexer}'s per-file entry points
    # ({Indexer#reindex_file!} / {Indexer#remove_file!}) from
    # filesystem events plus a boot reconciliation sweep
    # ({Indexer#reconcile_plan}). Layer 2 of the design in
    # +ideas/vectordb-incremental-reindex.md+.
    #
    # == Host-owned, not agent-owned
    #
    # A web app has many {Agent}s but one corpus and one Watcher, so
    # the Watcher's lifetime is the host *process*, not any single
    # agent. The host constructs it once, around the same {Indexer}
    # (and therefore the same {Backend}) every agent's
    # {Extension} shares, and +#start+s / +#close+s it on process
    # lifecycle:
    #
    #   server = Pikuri::VectorDb::ChromaServer.ensure_running
    #   backend = server.client(collection: 'notes')
    #   ext = Pikuri::VectorDb::Extension.new(backend: backend, source: '~/notes')
    #   # ... build agents with `ext` ...
    #   watcher = Pikuri::VectorDb::Watcher.new(indexer: ext.indexer).start
    #
    # The {Extension} indexes nothing on its own, so the Watcher is
    # the population path here: its boot reconcile sweep
    # ({Indexer#reconcile_plan}) fills an empty backend and is uniform
    # across backends. A host that *also* indexes some other way (an
    # explicit +ext.indexer.index_if_empty!+ before +start+) is fine
    # too — the sweep then finds matching hashes and reindexes
    # nothing.
    #
    # == Single work queue, last-intent-per-path
    #
    # The boot sweep and the live event stream must not race. They
    # funnel into one +@pending+ map (path → +:reindex+/+:remove+)
    # drained by one worker thread, so:
    #
    # * Rapid edits to one file collapse to a single reindex (the
    #   map holds one intent per path); +listen+'s +latency+ window
    #   coalesces most of it before it even reaches us.
    # * Order doesn't corrupt content: {#process} resolves the file
    #   from disk *at process time*, and {Indexer#reindex_file!} of
    #   a vanished file is itself a removal — so a stale +:reindex+
    #   that runs after a delete self-corrects rather than writing
    #   old bytes.
    #
    # The boot sweep is enqueued by the worker thread *after* the
    # listener is already subscribed, so a change made mid-sweep
    # lands in the same queue rather than being lost.
    #
    # == Teardown drains the in-flight job
    #
    # The Watcher registers with {Pikuri::Finalizers} *last* (after
    # the host's {ChromaServer}), so LIFO closes it *first* — before
    # the container is +docker rm -f+'d. {#close} stops the listener
    # (no new events), then joins the worker, which finishes the job
    # it is mid-flight on and exits. That ordering is load-bearing: it
    # guarantees no {Backend#replace_source} is still writing when the
    # Chroma container goes down. Remaining queued (not-yet-started) jobs
    # are abandoned — the next boot's reconcile sweep catches them
    # (the downtime-gap guarantee).
    #
    # == What it deliberately does not do
    #
    # * **No model/parameter awareness.** The change signal is the
    #   file's byte hash ({Indexer#file_hash}), so swapping the
    #   embedder or chunker config does *not* trigger reindex — the
    #   recourse is a manual full +vectordb_reindex+. See
    #   {Extension} for the loud warning.
    # * **Symlinks are never indexed.** A live event whose path is
    #   reached through a symlink below the watch root is dropped —
    #   the leaf may be a symlinked file, or an ancestor a symlinked
    #   directory. This matches {Indexer#list_files}, which skips the
    #   same paths on the boot walk, so the watch and the walk index
    #   exactly the same set. The rule is strict on purpose, not
    #   OS-default: it is a privacy boundary (a link pointing out of
    #   the corpus never gets embedded) and it closes the otherwise
    #   off-tree divergence — a symlink target that changes outside
    #   the watched tree fires no event, so following it would leave
    #   stale chunks the walk would later remove.
    # * **No backpressure.** Re-embedding competes with the chat
    #   model on a shared llama-server; vectordb targets
    #   low-churn corpora (notes, docs), so a burst is tolerated
    #   rather than throttled.
    class Watcher
      LOGGER = Pikuri.logger_for('VectorDb::Watcher')

      # @param indexer [Indexer] the indexer to drive — supplies the
      #   watch {Indexer#root}, the source-vs-directory shape via
      #   {Indexer#source}, and the per-file + reconcile entry points.
      # @param latency [Float] +listen+ debounce window in seconds:
      #   how long filesystem events are batched before the callback
      #   fires. The corpus is expected to change rarely, so a coarse
      #   value (default 10s) coalesces editor save-storms without
      #   any cost.
      # @param listen_factory [#call, nil] dependency-injection seam
      #   for tests: +call(dir) { |modified, added, removed| ... }+
      #   returns an object responding to +#start+ / +#stop+. +nil+
      #   uses the real +Listen.to+ (required lazily — see the
      #   gemspec note).
      # @return [Watcher]
      def initialize(indexer:, latency: 10.0, listen_factory: nil)
        @indexer = indexer
        @latency = latency
        @listen_factory = listen_factory || lambda do |dir, &blk|
          require 'listen'
          Listen.to(dir, latency: @latency, &blk)
        end

        # Resolve the watch shape once, here, rather than re-stat'ing
        # per event. {Indexer#root} is the source for a directory tree
        # and the *parent* for a single file, so +source != watch_dir+
        # distinguishes the two without touching the filesystem — and
        # stays correct even if the single watched file is later
        # deleted (a +source.file?+ check would flip to directory mode
        # and start indexing its siblings).
        @source    = @indexer.source.expand_path
        @watch_dir = @indexer.root.expand_path
        @single_file = @source != @watch_dir

        @pending  = {} # path (String) → :reindex / :remove
        @monitor  = Monitor.new
        @cond     = @monitor.new_cond
        @closing  = false
        @started  = false
        @closed   = false
        @worker   = nil
        @listener = nil
        @finalizer_handle = nil
      end

      # Subscribe to filesystem events, spawn the worker thread (which
      # runs the boot reconcile sweep then drains events), and register
      # for teardown. Idempotent guard against a double start.
      #
      # @return [self]
      def start
        raise 'Watcher already started' if @started

        @started = true
        subscribe
        @worker = Thread.new { work_loop }
        # Register LAST so LIFO teardown closes the Watcher before the
        # ChromaServer the host registered earlier — see the class yardoc.
        @finalizer_handle = Pikuri::Finalizers.register(self)
        self
      end

      # Stop watching and tear down cleanly. Stops the listener so no
      # new events arrive, then joins the worker — which finishes its
      # in-flight job and exits, abandoning any still-queued work.
      # Idempotent and safe at process exit (the host may have called
      # it already, or only the +at_exit+ finalizer fires).
      #
      # @return [void]
      def close
        return if @closed

        @closed = true
        @listener&.stop
        @monitor.synchronize do
          @closing = true
          @cond.broadcast
        end
        @worker&.join
        Pikuri::Finalizers.unregister(@finalizer_handle) if @finalizer_handle
        nil
      end

      # The +listen+ callback body, also the test seam. Translates a
      # batch of changed paths into queued work: modified/added →
      # +:reindex+, removed → +:remove+. Non-indexable paths
      # (denylisted dirs, dot-files, anything outside the watch root)
      # are dropped, as are paths reached through a symlink (see the
      # class doc — strict, to agree with {Indexer#list_files}). The
      # symlink check guards only +:reindex+: it +lstat+s the path,
      # which a removed path no longer has, and a +:remove+ for a
      # never-indexed symlink source is a harmless no-op anyway.
      #
      # @param modified [Array<String>] absolute paths.
      # @param added [Array<String>] absolute paths.
      # @param removed [Array<String>] absolute paths.
      # @return [void]
      def process_event(modified, added, removed)
        (Array(modified) + Array(added)).each do |path|
          next unless indexable?(path)
          next if symlinked_below_root?(path)

          enqueue(:reindex, path)
        end
        Array(removed).each do |path|
          enqueue(:remove, path) if indexable?(path)
        end
        nil
      end

      # Process every currently-queued job synchronously and return.
      # The worker thread calls this implicitly via its blocking loop;
      # tests call it directly to drain without a thread. Does not wait
      # for new work and does not consult the closing flag.
      #
      # @return [void]
      def drain!
        loop do
          job = @monitor.synchronize do
            next nil if @pending.empty?

            key = @pending.keys.first
            [key, @pending.delete(key)]
          end
          break if job.nil?

          process(*job)
        end
        nil
      end

      private

      # Build and start the listener, wiring its callback to
      # {#process_event}. +listen+ hands absolute path strings; the
      # filtering happens in {#indexable?}, so we don't lean on
      # +listen+'s own ignore rules.
      def subscribe
        @listener = @listen_factory.call(@watch_dir.to_s) do |modified, added, removed|
          process_event(modified, added, removed)
        end
        @listener.start
      end

      # Worker-thread body: run the boot sweep first (now that the
      # listener is live), then block-drain the queue until closed.
      def work_loop
        enqueue_plan
        loop do
          job = next_job
          break if job.nil?

          process(*job)
        end
      end

      # Compute the boot reconcile plan and enqueue it. Failures
      # (backend unreachable, etc.) are logged, not raised — a failed
      # sweep must not take the worker down; live events still flow.
      def enqueue_plan
        plan = @indexer.reconcile_plan
        plan[:reindex].each { |path| enqueue(:reindex, path) }
        plan[:remove].each  { |path| enqueue(:remove, path) }
        LOGGER.info(
          "reconcile: #{plan[:reindex].size} file(s) to (re)index, " \
          "#{plan[:remove].size} to remove"
        )
      rescue StandardError => e
        LOGGER.warn("reconcile sweep failed: #{e.class}: #{e.message}")
      end

      # Record an intent for a path, collapsing any prior intent for
      # the same path (last-intent-wins), and wake the worker.
      def enqueue(intent, path)
        @monitor.synchronize do
          @pending[path.to_s] = intent
          @cond.signal
        end
      end

      # Block until a job is available or the Watcher is closing.
      # Returns +nil+ on close so the worker exits — abandoning any
      # still-queued jobs (the boot sweep recovers them next run).
      def next_job
        @monitor.synchronize do
          loop do
            return nil if @closing
            unless @pending.empty?
              key = @pending.keys.first
              return [key, @pending.delete(key)]
            end

            @cond.wait
          end
        end
      end

      # Run one queued job. Per-job failures (an embedder outage on a
      # reindex, a backend blip) are logged and swallowed so one bad
      # file can't kill the worker; the file is picked up again on its
      # next change or the next boot sweep.
      def process(path, intent)
        case intent
        when :reindex then @indexer.reindex_file!(path)
        when :remove  then @indexer.remove_file!(path)
        end
      rescue StandardError => e
        LOGGER.warn("watch #{intent} #{path} failed: #{e.class}: #{e.message}")
      end

      # Should a changed path be acted on? For a directory source:
      # the path is under {Indexer#root} and no path component is a
      # dot-entry or in {Indexer::DENYLIST}. For a single-file source:
      # the path is exactly that file (the listener watches the
      # parent dir, so siblings must be filtered out). Works on
      # removed paths too — it's pure path math, no +stat+.
      def indexable?(path)
        path = Pathname.new(path).expand_path
        return path == @source if @single_file

        rel = path.relative_path_from(@watch_dir)
        return false if rel.to_s.start_with?('..')

        rel.each_filename.none? do |part|
          part.start_with?('.') || Indexer::DENYLIST.include?(part)
        end
      rescue ArgumentError
        # relative_path_from raises when path is on a different prefix
        # than root — i.e. not under the watched tree.
        false
      end

      # Is +path+ reached through a symlink at or below the watch
      # root? Walks the components from the watch root (+@watch_dir+)
      # down to the leaf and +lstat+s each, so it catches both a
      # symlinked leaf file and a symlinked ancestor directory —
      # matching what {Indexer#list_files} skips. Components in the
      # watch root's own prefix are not checked: that is the path the
      # host pointed at, descended even when itself reached through a
      # link (same as the walk, which always descends its given
      # +root+).
      #
      # @param path [String] an absolute path under the watch root.
      # @return [Boolean]
      def symlinked_below_root?(path)
        path = Pathname.new(path).expand_path
        cur = @watch_dir # the file's parent in single-file mode, the tree root otherwise
        path.relative_path_from(cur).each_filename do |part|
          cur += part
          return true if cur.symlink?
        end
        false
      rescue ArgumentError
        false
      end
    end
  end
end
