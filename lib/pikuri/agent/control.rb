# frozen_string_literal: true

module Pikuri
  class Agent
    # Namespace for the +Agent+'s host-facing controls:
    # {StepLimit}, {Cancellable}, and {Interloper}. Each is a small
    # value-holder that the +Agent+ reads from (or pokes into the
    # event stream from) at well-defined points in ruby_llm's
    # chat-callback cycle. They are *not* listeners — they receive
    # no events and never appear in a {ListenerList}.
    #
    # == Why they're separated
    #
    # The previous shape modelled these as listeners that also
    # signalled back into the stream: +StepLimit+ counted tool
    # calls inside its own +attach+, +Cancellable+ raised from its
    # own callback, +Interloper+ poked +Message::User+ events
    # back through a +listener_list=+ setter. The roles weren't
    # distinct — every listener might write to the stream, every
    # listener might read from it — and the "what fires when" was
    # spread across nine files.
    #
    # The new shape names the two roles: listeners are pure
    # consumers of the event stream; controls are host-facing
    # signal holders that the +Agent+ reads from. The +Agent+ is
    # the only entity that emits events, the only entity that
    # ticks the step counter, the only entity that checks the
    # cancellation flag, and the only entity that drains the
    # interloper queue. "What fires when" is a single grep for
    # +@listeners.emit+ in +agent.rb+.
    #
    # == What each control does
    #
    # * {StepLimit} — caps the number of tool calls per
    #   {Agent#run_loop}. The +Agent+ calls {StepLimit#tick!} on
    #   every +before_tool_call+ (raising {StepLimit::Exceeded}
    #   when over budget) and {StepLimit#reset!} at the start of
    #   each turn. Sub-agents get their own counter.
    # * {Cancellable} — cooperative cancellation flag. The host
    #   calls {Cancellable#cancel!} from any thread; the +Agent+
    #   calls {Cancellable#check!} at +before_tool_call+ (raising
    #   {Cancellable::Cancelled} when the flag is set) and
    #   {Cancellable#reset!} at the start of each turn. The same
    #   instance is shared by reference across the parent, every
    #   sub-agent, and the synthesizer rescue.
    # * {Interloper} — mid-loop user-input queue. The host calls
    #   {Interloper#inject_user_message} from any thread; the
    #   +Agent+ drains the queue at +after_tool_result+,
    #   appending each item as a user-role message and emitting
    #   {Event::UserTurn} with +mid_loop: true+. Not propagated to
    #   sub-agents (the host has no handle to them).
    module Control
    end
  end
end
