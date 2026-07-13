# frozen_string_literal: true

module Pikuri
  class Agent
    module Control
      # Mid-loop user-input queue. A host (TUI, web client) constructs an
      # +Interloper+, passes it to {Agent#initialize} via +interloper:+, and
      # calls {#inject_user_message} from any thread while the agent runs. The
      # +Agent+ drains it at the next +after_tool_result+ boundary — the only
      # point in ruby_llm's loop where conversation state is consistent —
      # appending each item as a +role: :user+ message and emitting
      # +Event::UserTurn(mid_loop: true)+; the next round-trip reacts to it.
      #
      # Groundwork for downstream TUI/web hosts: the bundled +bin/pikuri-*+ do
      # not wire one (stdin is synchronous). A host running the agent on a
      # worker thread wires one in with no other changes.
      #
      # == Delivery boundary
      #
      # Delivery is at +after_tool_result+, *not* the LLM HTTP call: an
      # injection made mid-response takes effect on the *next* round-trip, once
      # the model has committed to the current response's tool calls. Same
      # "gentle" semantic {Control::Cancellable} promises — the cleanest
      # cross-provider point (no in-flight subprocess, no half-built response).
      # Controls are reset only at turn start, never on a mid-loop injection,
      # so "cancel-then-inject" and "refresh-budget-by-injecting" can't arise.
      #
      # == Change notification
      #
      # A host rendering the pending count reactively (a "3 waiting" badge)
      # sets {#on_change} instead of polling {#size}. It fires whenever the
      # count changes — once per {#inject_user_message}, once per {#drain!}
      # that empties a non-empty queue (an empty-queue drain, the hot path,
      # stays silent) — with the new count, outside the lock. A host-side hook,
      # not an {Agent} listener event: the count changes on the injecting
      # thread, off the agent-thread-confined stream. Mirrors
      # {Pikuri::Tasks::List#on_change} but pushes the count (the interloper
      # exposes no race-free snapshot to re-read).
      #
      # == Sub-agent semantics
      #
      # Sub-agents are private to the parent; the host has no handle to them,
      # so the +agent+ tool omits the kwarg, leaving a child's +interloper+
      # +nil+. Contrast {Control::Cancellable}, shared by reference so the
      # parent's stop propagates to the whole tree — cancellation is global,
      # injection is directed at the main agent.
      #
      # Thread-safe: {#inject_user_message}, {#peek}, {#pending?}, {#size}, and
      # {#drain!} are a +Mutex+-guarded +Array+ (chosen over +Thread::Queue+,
      # which exposes no snapshot for {#peek}). {#on_change} fires outside the
      # lock so a re-entrant or blocking callback can't deadlock.
      class Interloper
        def initialize
          @mutex = Mutex.new
          @items = []
          @on_change = nil
        end

        # Optional host callback invoked with the new pending count whenever it
        # changes (after {#inject_user_message}, and after a {#drain!} that
        # empties a non-empty queue). +nil+ (default) disables it. Runs
        # *outside* the queue lock, on the mutating thread, so a callback
        # feeding another thread should hand off only immutable data.
        #
        # @return [Proc, nil]
        attr_accessor :on_change

        # Push +content+ onto the delivery queue (any thread; +Mutex+-guarded).
        # Fires {#on_change} with the new count, outside the lock.
        #
        # @param content [String] non-blank user-supplied text
        # @raise [ArgumentError] if +content+ is +nil+/blank — a blank
        #   injection would poison the chat history like a blank turn
        # @return [void]
        def inject_user_message(content)
          raise ArgumentError, "content must not be blank, got #{content.inspect}" \
            if content.nil? || content.to_s.strip.empty?

          count = @mutex.synchronize { @items << content; @items.size }
          @on_change&.call(count)
          nil
        end

        # Non-destructive snapshot of the queue in delivery order, for a host
        # rendering a "pending" affordance. Safe from any thread.
        #
        # @return [Array<String>] copy of the pending items; never shares state
        #   with the internal buffer
        def peek
          @mutex.synchronize { @items.dup }
        end

        # @return [Boolean] whether the queue holds a pending injection;
        #   observable from any thread
        def pending?
          @mutex.synchronize { !@items.empty? }
        end

        # @return [Integer] number of pending injections; a snapshot from any
        #   thread (may have drained by the time the caller reads it)
        def size
          @mutex.synchronize { @items.size }
        end

        # Atomically take and remove all pending items. Called by {Agent}'s
        # +after_tool_result+ wiring. Returns +[]+ when empty (the hot path) —
        # an empty drain does *not* fire {#on_change}; a drain that empties a
        # non-empty queue fires it with +0+, outside the lock.
        #
        # @return [Array<String>] items in delivery order; empty when the queue
        #   is empty
        def drain!
          items = @mutex.synchronize do
            next [] if @items.empty?

            taken = @items.dup
            @items.clear
            taken
          end
          @on_change&.call(0) unless items.empty?
          items
        end

        # @return [String] short label for {Agent#to_s}, reflecting the
        #   pending count.
        def to_s
          pending = size
          pending.zero? ? 'Interloper' : "Interloper(#{pending} pending)"
        end
      end
    end
  end
end
