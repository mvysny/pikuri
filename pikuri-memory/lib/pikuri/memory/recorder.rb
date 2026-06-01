# frozen_string_literal: true

module Pikuri
  module Memory
    # The off-the-interaction-path capture queue. A single background
    # worker thread drains enqueued user turns into {Mem0Client#add}, so a
    # turn never blocks on the ~3s extraction round-trip
    # (ideas/memory-mem0.md §"Patch verified live"). Reads are cheap and
    # synchronous; writes are deferred here — the read/write asymmetry
    # the design leans on.
    #
    # == Why a thread, not a fork or an external job
    #
    # mem0's +add+ is one HTTP call. A thread is the smallest thing that
    # takes it off the turn's critical path while keeping capture
    # *per-turn* (so a kill -9 / closed tab loses at most the in-flight
    # turn, not a whole session — the data-safety win that picked a
    # separate extraction model in ideas/memory-mem0.md §"Extraction
    # model decision"). No external queue, no persistence — durability is
    # "within seconds, in mem0," not "survives a crash mid-extraction."
    #
    # == Bounded flush on close
    #
    # {#close} signals the worker to stop and joins it with a timeout —
    # so "quit" never hangs for minutes while a backlog digests
    # (ideas/memory.md §"Capture mechanism & exit latency"). Anything
    # still queued past the timeout is dropped: the worker is a plain
    # Ruby thread, so process exit reaps it. One enqueue per turn means
    # the queue rarely holds more than a single item, so the common case
    # flushes in one +add+.
    #
    # == Failure is logged, not raised
    #
    # A {Mem0Client#add} that raises (mem0 down, timeout, 5xx) is caught,
    # logged at WARN, and the item dropped — a transient capture failure
    # must never crash the worker (which would silently end all future
    # capture) nor surface to the user mid-conversation.
    class Recorder
      LOGGER = Pikuri.logger_for('Memory::Recorder')

      # @return [Symbol] sentinel pushed by {#close} to stop the worker
      #   after it drains everything enqueued ahead of it.
      STOP = :__pikuri_memory_stop__

      # @return [Integer] default seconds {#close} waits for the worker
      #   to drain before giving up and letting process exit reap it.
      DEFAULT_FLUSH_TIMEOUT = 10

      # @param client [Mem0Client] the mem0 client +add+ is dispatched to.
      # @param user_id [String] the mem0 namespace captures land in.
      # @param infer [Boolean] forwarded to {Mem0Client#add}; +true+ stores
      #   extracted facts.
      # @param prompt [String, nil] optional per-request extraction
      #   prompt forwarded to {Mem0Client#add}.
      # @param flush_timeout [Integer] seconds {#close} blocks waiting
      #   for the backlog to drain.
      # @return [Recorder]
      def initialize(client:, user_id:, infer: true, prompt: nil,
                     flush_timeout: DEFAULT_FLUSH_TIMEOUT)
        @client = client
        @user_id = user_id
        @infer = infer
        @prompt = prompt
        @flush_timeout = flush_timeout
        @queue = Thread::Queue.new
        @thread = nil
        @closed = false
      end

      # Start the background worker. Idempotent — a second call is a
      # no-op, so {Extension#bind} can call it without guarding.
      #
      # @return [self]
      def start
        @thread ||= Thread.new { run_loop }
        self
      end

      # Enqueue one user turn for asynchronous extraction. Non-blocking
      # (a bounded push to an in-memory queue). Blank content and
      # post-close enqueues are silently ignored.
      #
      # @param content [String] the user's message to capture.
      # @return [void]
      def enqueue(content)
        return if @closed
        return if content.nil? || content.to_s.strip.empty?

        @queue << content
        nil
      end

      # Stop the worker and flush the backlog, bounded by
      # +flush_timeout+. Pushes {STOP} (so items already queued drain
      # first), then joins the worker for at most the timeout. Idempotent.
      # If the timeout elapses with work still pending, the remaining
      # items are abandoned to process-exit reaping — a deliberate
      # bound so quit never hangs.
      #
      # @return [void]
      def close
        return if @closed

        @closed = true
        @queue << STOP
        return unless @thread

        return if @thread.join(@flush_timeout)

        LOGGER.warn("flush did not finish within #{@flush_timeout}s; " \
                    "#{@queue.size} memory write(s) abandoned at exit")
        nil
      end

      private

      # Worker loop: block on the queue, dispatch each item to
      # {Mem0Client#add}, stop on {STOP}. Each +add+ is wrapped so a
      # transient failure drops one item rather than killing the worker.
      def run_loop
        loop do
          item = @queue.pop
          break if item == STOP

          begin
            @client.add(content: item, user_id: @user_id, infer: @infer, prompt: @prompt)
          rescue StandardError => e
            LOGGER.warn("extraction add failed, dropping turn: #{e.class}: #{e.message}")
          end
        end
      end
    end
  end
end
