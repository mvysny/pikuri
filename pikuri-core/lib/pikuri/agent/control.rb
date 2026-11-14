# frozen_string_literal: true

module Pikuri
  class Agent
    # Namespace for the +Agent+'s host-facing controls: {Cancellable} and
    # {Interloper}. Each is a small value-holder the +Agent+ reads from (or
    # pokes into the event stream from) at fixed points in ruby_llm's callback
    # cycle. They are *not* listeners — they receive no events and never appear
    # in a {ListenerList}.
    #
    # The split: listeners are pure consumers of the event stream; controls are
    # host-facing signal holders the +Agent+ reads. The +Agent+ is the only
    # entity that emits events, checks the cancel flag, and drains the
    # interloper queue — "what fires when" is one grep for +@listeners.on_event+ in
    # +agent.rb+.
    #
    # * {Cancellable} — cooperative cancel flag, shared by reference across the
    #   parent and its sub-agents.
    # * {Interloper} — mid-loop user-input queue; not propagated to sub-agents.
    module Control
    end
  end
end
