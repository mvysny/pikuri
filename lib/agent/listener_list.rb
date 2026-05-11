# frozen_string_literal: true

class Agent
  # Listener-list value object that an {Agent} owns. Implements the same
  # +attach(chat)+ / +on_message(msg)+ protocol as an individual
  # listener — every call is fanned out to the underlying list — so the
  # +Agent+ never sees a raw +Array+ and never has to express
  # "for each listener, do X" inline.
  #
  # == Why a class, not an Array
  #
  # Two operations want one home rather than scattered helpers:
  #
  # 1. {#with_max_steps} produces a derived list for a sub-context
  #    (sub-agent run, synthesizer rescue) with the +StepLimit+
  #    swapped to a fresh instance. {Listener::StepLimit} carries
  #    shared +@step+ state and registers a +before_tool_call+ hook
  #    on whatever chat it's attached to, so the *same* instance
  #    cannot govern two chats independently. {#with_max_steps} is
  #    the load-bearing reason this class exists.
  #
  # 2. {#attach} / {#on_message} replace +each { |l| l.attach(chat) }+
  #    and +each { |l| l.on_message(msg) }+ at the call sites, which
  #    makes the seam ("a listener list is a thing the agent owns")
  #    more visible.
  class ListenerList
    # @param listeners [Array] listeners that respond to the duck-typed
    #   +attach(chat)+ / +on_message(msg)+ protocol
    def initialize(listeners)
      @listeners = listeners.dup
    end

    # Wire every listener into +chat+'s callback API. Forwarded verbatim
    # to each listener's +#attach+ — see {Listener::MessageListener#attach}
    # and {Listener::StepLimit#attach} for what each one registers.
    #
    # @param chat [RubyLLM::Chat]
    # @return [void]
    def attach(chat)
      @listeners.each { |l| l.attach(chat) }
    end

    # Dispatch one message to every listener.
    #
    # @param message [Agent::Message]
    # @return [void]
    def on_message(message)
      @listeners.each { |l| l.on_message(message) }
    end

    # Return a new {ListenerList} with the same non-+StepLimit+
    # listeners, plus a +StepLimit+ governed by +max_steps+:
    #
    # - +max_steps+ is an +Integer+: ensure exactly one
    #   {Listener::StepLimit} with that cap. Any existing +StepLimit+
    #   is replaced with a fresh +Listener::StepLimit.new(max: max_steps)+;
    #   if none exists in the list, the fresh one is appended.
    # - +max_steps+ is +nil+: strip every +StepLimit+ from the new
    #   list. The derived list has no step cap.
    #
    # +max_steps+ is positional and required — every internal caller
    # ({Agent}'s synth rescue, {Tool::SubAgent} factory) makes a
    # deliberate decision about the sub-context's budget, and the
    # missing-default forces that decision to be stated.
    #
    # Non-+StepLimit+ listeners are passed by reference: a {Terminal}
    # or {InMemoryList} in the parent is the same instance the new
    # list holds, so output and structured capture flow continuously
    # across parent + sub-context. +StepLimit+ is the one variant
    # where sharing is unsafe (mutable counter, per-chat callback).
    #
    # @param max_steps [Integer, nil] required; see above
    # @return [ListenerList]
    def with_max_steps(max_steps)
      stripped = @listeners.reject { |l| l.is_a?(Listener::StepLimit) }
      stripped << Listener::StepLimit.new(max: max_steps) unless max_steps.nil?
      self.class.new(stripped)
    end

    # @example
    #   list.to_s # => "[Terminal, StepLimit(max=20)]"
    #
    # @return [String]
    def to_s
      "[#{@listeners.map(&:to_s).join(', ')}]"
    end
  end
end
