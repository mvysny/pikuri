# frozen_string_literal: true

module Pikuri
  class Agent
    module Listener
      # Mid-loop user-input channel. A host (TUI, web client) constructs
      # an +Interloper+, registers it in the {Agent}'s {ListenerList},
      # and calls {#inject_user_message} from any thread while the agent
      # is running. The injection is queued and delivered into the
      # chat's history at the next +after_tool_result+ boundary — the
      # only point inside ruby_llm's loop where the conversation state
      # is consistent. The agent's next round-trip then sees the
      # injected user message and reacts to it on its own.
      #
      # +Interloper+ is groundwork for downstream TUI/web hosts; the
      # bundled +bin/pikuri-*+ entry-point scripts do *not* wire one
      # up, since they keep stdin synchronous and have no way for a
      # user to type while a turn is in flight. Downstream hosts that
      # *do* run the agent on a worker thread can wire one in with no
      # other changes to pikuri.
      #
      # == Delivery boundary and side effects
      #
      # When +after_tool_result+ fires, {#attach}'s callback drains the
      # entire queue and, for each item:
      #
      # 1. Calls +chat.add_message(role: :user, content: text)+ so the
      #    next +complete+ round-trip's request includes the message.
      # 2. Emits +Agent::Message::User.new(content: text, mid_loop_run: true)+
      #    through the surrounding {ListenerList} so other listeners
      #    (Terminal renderer, in-memory recorder, future logging) see
      #    the injection as a normal +User+ event with the +mid_loop_run:+
      #    flag set. {Listener::StepLimit} and {Listener::Cancellable}
      #    pattern-match on +mid_loop_run: false+ to avoid resetting their
      #    state on mid-loop injections — see their +on_message+ hooks.
      #
      # The reverse handle to the listener list is supplied via the
      # +listener_list=+ setter that {ListenerList#attach} pokes in
      # before calling {#attach}. The +respond_to?(:listener_list=)+
      # check there keeps the protocol duck-typed; no other bundled
      # listener defines the setter.
      #
      # == Boundary caveats
      #
      # The delivery point is +after_tool_result+, *not* the LLM HTTP
      # call. Injections placed while the model is mid-response take
      # effect on the *next* round-trip — by the time the queue
      # drains, the model has already committed to whichever tool calls
      # were in that response. The agent therefore typically observes an
      # injection at the tool-batch boundary *after* the one during
      # which the host called {#inject_user_message}. This is the same
      # "gentle" semantic that {Listener::Cancellable} promises and is
      # the cleanest cross-provider point: no in-flight subprocess, no
      # half-applied write, no half-built response.
      #
      # == Thread safety
      #
      # {#inject_user_message}, {#peek}, and {#pending?} are safe to
      # call from any thread; the internal queue is a +Mutex+-guarded
      # +Array+. The +after_tool_result+ callback drains the queue on
      # the run thread (whatever thread invoked +Chat#ask+). +Mutex+
      # was chosen over +Thread::Queue+ because +Thread::Queue+ exposes
      # no snapshot read, and {#peek} is part of the surface (the host
      # wants to render "feedback received, will deliver shortly" in
      # its UI before the agent actually consumes the injection).
      #
      # == Sub-agent semantics
      #
      # {#for_sub_agent} returns +nil+. Sub-agents are private to the
      # parent agent; the host has no handle to them, so a child
      # +Interloper+ would be unreachable. {ListenerList#for_sub_agent}
      # compacts the +nil+ out of the derived list, so the sub-agent's
      # +after_tool_result+ pipeline simply doesn't include this
      # listener. The behavior contrasts with {Listener::Cancellable},
      # which shares its instance by reference so the parent's signal
      # propagates to children — cancellation is a global "stop the
      # whole tree" event, whereas injection is a directed "talk to the
      # main agent" event.
      class Interloper
        def initialize
          @mutex = Mutex.new
          @items = []
          @listener_list = nil
        end

        # Reverse handle into the surrounding {ListenerList}, poked in
        # by {ListenerList#attach} before {#attach} runs so the
        # +after_tool_result+ callback can broadcast a +User+ event
        # back into the listener stream when an injection lands. See
        # {ListenerList#attach} for the +respond_to?+ convention.
        attr_writer :listener_list

        # Push +content+ onto the delivery queue. Safe from any thread;
        # the queue is +Mutex+-guarded.
        #
        # @param content [String] non-blank user-supplied text
        # @raise [ArgumentError] if +content+ is +nil+, empty, or
        #   whitespace-only — same rule as {Agent#run_loop}'s
        #   +user_message:+ argument, since an empty injection would
        #   poison the chat history just as a blank turn would
        # @return [void]
        def inject_user_message(content)
          raise ArgumentError, "content must not be blank, got #{content.inspect}" \
            if content.nil? || content.to_s.strip.empty?

          @mutex.synchronize { @items << content }
          nil
        end

        # Non-destructive snapshot of the queue, in delivery order.
        # Intended for hosts that want to render an "ongoing /
        # pending" UI affordance ("3 messages waiting to deliver") in
        # parallel with the agent's progress stream. Safe to call from
        # any thread.
        #
        # @return [Array<String>] copy of the pending items; never
        #   shares state with the internal buffer
        def peek
          @mutex.synchronize { @items.dup }
        end

        # @return [Boolean] whether the queue currently holds at least
        #   one pending injection; observable from any thread
        def pending?
          @mutex.synchronize { !@items.empty? }
        end

        # Wire the receiver into +chat+'s +after_tool_result+ callback.
        # The callback drains the queue and, for each pending item,
        # appends a user-role message to the chat's history and emits a
        # +Message::User(mid_loop_run: true)+ event into the listener
        # stream. See the class header for the full delivery contract.
        #
        # @param chat [RubyLLM::Chat]
        # @return [void]
        def attach(chat)
          chat.after_tool_result do |_result|
            drain_into(chat)
          end
        end

        # Listener protocol hook. No state is tied to message events —
        # the queue is drained only by the +after_tool_result+ callback
        # — so this is a no-op for every variant.
        #
        # @param message [Agent::Message]
        # @return [void]
        def on_message(message); end

        # Sub-agent variant: +nil+, meaning {ListenerList#for_sub_agent}
        # drops the receiver from the derived list. See the class header
        # for the "host has no handle to sub-agents" rationale.
        #
        # @return [nil]
        def for_sub_agent(**)
          nil
        end

        # @return [String] short label for {Agent#to_s}; reflects the
        #   pending-count so a debug print or banner can tell an idle
        #   interloper apart from one with queued items
        def to_s
          size = @mutex.synchronize { @items.size }
          size.zero? ? 'Interloper' : "Interloper(#{size} pending)"
        end

        private

        # Atomically drain the queue and deliver each item: append a
        # user-role message to +chat+ and notify the surrounding
        # listener stream with a +Message::User(mid_loop_run: true)+.
        # Empty-queue case is the hot path — every +after_tool_result+
        # fires this — so the early-return guard keeps it cheap.
        #
        # The drain happens under the mutex, but the +add_message+ /
        # +on_message+ side effects run *outside* it so a slow listener
        # cannot block a fresh +inject_user_message+ from the host.
        #
        # @param chat [RubyLLM::Chat]
        # @return [void]
        def drain_into(chat)
          pending = @mutex.synchronize do
            next [] if @items.empty?

            items = @items.dup
            @items.clear
            items
          end
          return if pending.empty?

          pending.each do |content|
            chat.add_message(role: :user, content: content)
            @listener_list&.on_message(
              Agent::Message::User.new(content: content, mid_loop_run: true)
            )
          end
        end
      end
    end
  end
end
