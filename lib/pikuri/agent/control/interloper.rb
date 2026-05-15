# frozen_string_literal: true

module Pikuri
  class Agent
    module Control
      # Mid-loop user-input queue. A host (TUI, web client)
      # constructs an +Interloper+, hands it to {Agent#initialize}
      # via the +interloper:+ kwarg, and calls
      # {#inject_user_message} from any thread while the agent
      # is running. The +Agent+ drains the queue at the next
      # +after_tool_result+ boundary — the only point inside
      # ruby_llm's loop where the conversation state is
      # consistent — and emits each item into the chat history
      # plus the listener stream. The agent's next round-trip
      # then sees the injected user message and reacts to it on
      # its own.
      #
      # +Interloper+ is groundwork for downstream TUI/web hosts;
      # the bundled +bin/pikuri-*+ entry-point scripts do *not*
      # wire one up, since they keep stdin synchronous and have
      # no way for a user to type while a turn is in flight.
      # Downstream hosts that *do* run the agent on a worker
      # thread can wire one in with no other changes to pikuri.
      #
      # == Delivery boundary and side effects
      #
      # When the +Agent+'s +after_tool_result+ wiring fires, it
      # calls {#drain!} on the interloper (if any) and, for each
      # returned item:
      #
      # 1. Appends a +role: :user+ message to the chat history so
      #    the next +complete+ round-trip's request includes it.
      # 2. Emits +Event::UserTurn(content:, mid_loop: true)+
      #    through the listener stream so other listeners
      #    (Terminal renderer, in-memory recorder, future logging)
      #    see the injection as a normal +UserTurn+ event with the
      #    +mid_loop:+ flag set.
      #
      # Controls do not respond to events; the +Agent+ pokes
      # {Control::StepLimit#reset!} and {Control::Cancellable#reset!}
      # only at the start of each turn — never on a mid-loop
      # injection — so the "cancel-then-inject" hazard and the
      # "refresh-budget-by-injecting" hazard cannot arise.
      #
      # == Boundary caveats
      #
      # The delivery point is +after_tool_result+, *not* the LLM
      # HTTP call. Injections placed while the model is
      # mid-response take effect on the *next* round-trip — by
      # the time the queue drains, the model has already
      # committed to whichever tool calls were in that response.
      # The agent therefore typically observes an injection at
      # the tool-batch boundary *after* the one during which the
      # host called {#inject_user_message}. This is the same
      # "gentle" semantic that {Control::Cancellable} promises
      # and is the cleanest cross-provider point: no in-flight
      # subprocess, no half-applied write, no half-built response.
      #
      # == Thread safety
      #
      # {#inject_user_message}, {#peek}, {#pending?}, and
      # {#drain!} are safe to call from any thread; the internal
      # queue is a +Mutex+-guarded +Array+. The +Agent+'s drain
      # runs on the run thread (whatever thread invoked
      # +Chat#ask+). +Mutex+ was chosen over +Thread::Queue+
      # because +Thread::Queue+ exposes no snapshot read, and
      # {#peek} is part of the surface (the host wants to render
      # "feedback received, will deliver shortly" in its UI
      # before the agent actually consumes the injection).
      #
      # == Sub-agent semantics
      #
      # {#for_sub_agent} returns +nil+. Sub-agents are private to
      # the parent agent; the host has no handle to them, so a
      # child +Interloper+ would be unreachable. The sub-agent's
      # {Agent#initialize} simply receives +interloper: nil+ from
      # {Tool::SubAgent}, which is its default. The behavior
      # contrasts with {Control::Cancellable}, which shares its
      # instance by reference so the parent's signal propagates
      # to children — cancellation is a global "stop the whole
      # tree" event, whereas injection is a directed "talk to the
      # main agent" event.
      class Interloper
        def initialize
          @mutex = Mutex.new
          @items = []
        end

        # Push +content+ onto the delivery queue. Safe from any
        # thread; the queue is +Mutex+-guarded.
        #
        # @param content [String] non-blank user-supplied text
        # @raise [ArgumentError] if +content+ is +nil+, empty, or
        #   whitespace-only — same rule as {Agent#run_loop}'s
        #   +user_message:+ argument, since an empty injection
        #   would poison the chat history just as a blank turn
        #   would
        # @return [void]
        def inject_user_message(content)
          raise ArgumentError, "content must not be blank, got #{content.inspect}" \
            if content.nil? || content.to_s.strip.empty?

          @mutex.synchronize { @items << content }
          nil
        end

        # Non-destructive snapshot of the queue, in delivery
        # order. Intended for hosts that want to render an
        # "ongoing / pending" UI affordance ("3 messages waiting
        # to deliver") in parallel with the agent's progress
        # stream. Safe to call from any thread.
        #
        # @return [Array<String>] copy of the pending items;
        #   never shares state with the internal buffer
        def peek
          @mutex.synchronize { @items.dup }
        end

        # @return [Boolean] whether the queue currently holds at
        #   least one pending injection; observable from any
        #   thread
        def pending?
          @mutex.synchronize { !@items.empty? }
        end

        # Atomically take and remove all pending items. Called by
        # {Agent}'s +after_tool_result+ wiring; the +Agent+ then
        # appends each item to the chat history and emits an
        # {Event::UserTurn} with +mid_loop: true+ for each.
        #
        # Returns +[]+ when the queue is empty (the hot path —
        # every +after_tool_result+ calls this).
        #
        # @return [Array<String>] items in delivery order; empty
        #   when the queue is empty
        def drain!
          @mutex.synchronize do
            next [] if @items.empty?

            items = @items.dup
            @items.clear
            items
          end
        end

        # Sub-agent variant: +nil+, signalling to {Agent} (and
        # transitively to {Tool::SubAgent}) that no +Interloper+
        # should be wired on a spawned sub-agent. See the class
        # header for the "host has no handle to sub-agents"
        # rationale.
        #
        # @return [nil]
        def for_sub_agent(**)
          nil
        end

        # @return [String] short label for {Agent#to_s}; reflects
        #   the pending-count so a debug print or banner can tell
        #   an idle interloper apart from one with queued items
        def to_s
          size = @mutex.synchronize { @items.size }
          size.zero? ? 'Interloper' : "Interloper(#{size} pending)"
        end
      end
    end
  end
end
