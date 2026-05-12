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

    # Return a new {ListenerList} with each {Listener::TokenLog}
    # replaced by a fresh instance (zeroed context-window snapshot).
    # Non-+TokenLog+ listeners are passed by reference — same
    # convention as {#with_max_steps}, so terminal output and other
    # rendering still flow continuously into the parent's instances.
    #
    # Used by {Tool::SubAgent.build} (chained after {#with_max_steps})
    # so a sub-agent's context-window snapshot tracks its own
    # +RubyLLM::Chat+ rather than the parent's. Deliberately NOT used
    # by {Agent}'s synth rescue: the synthesizer's tokens are part of
    # the same conversation and should continue the parent's
    # +TokenLog+ readings.
    #
    # No-op (besides the +dup+) if the receiver contains no +TokenLog+.
    #
    # @return [ListenerList]
    def with_zero_tokens
      swapped = @listeners.map do |l|
        l.is_a?(Listener::TokenLog) ? Listener::TokenLog.new : l
      end
      self.class.new(swapped)
    end

    # Return a new {ListenerList} with each {Listener::Terminal} swapped
    # for a fresh instance carrying +padding+ leading spaces on every
    # rendered line. Used by {Tool::SubAgent.build} so sub-agent output
    # is visually indented under the parent's stream; the parent's
    # +Terminal+ is left at padding 0.
    #
    # Absolute, not additive: chaining +with_padding(2)+ twice yields a
    # list whose +Terminal+s render at 2 spaces, not 4 — same precedent
    # as {#with_max_steps} ("set this knob") rather than composing.
    # Sub-agent recursion is already blocked (the sub-agent's tool set
    # excludes +sub_agent+ itself), so the depth never exceeds 1 in
    # practice.
    #
    # Non-+Terminal+ listeners are passed by reference — same convention
    # as {#with_zero_tokens}. No-op (besides the +dup+) if the receiver
    # contains no +Terminal+.
    #
    # @param padding [Integer] non-negative number of leading spaces
    # @return [ListenerList]
    def with_padding(padding)
      swapped = @listeners.map do |l|
        l.is_a?(Listener::Terminal) ? Listener::Terminal.new(padding: padding) : l
      end
      self.class.new(swapped)
    end

    # Set the context-window cap on every {Listener::TokenLog} in the
    # list. Called by {Agent#initialize} once
    # {Agent::ContextWindowDetector} has resolved a value, so the
    # +ctx=<used>/<cap>+ form lights up across all token loggers without
    # the caller having to know which listeners they registered.
    #
    # Non-+TokenLog+ listeners are left alone — they have no cap to
    # carry.
    #
    # @param cap [Integer, nil] cap to apply; +nil+ is allowed (and
    #   keeps the existing +ctx=<used>+ form)
    # @return [void]
    def context_window_cap=(cap)
      @listeners.each do |l|
        l.context_window_cap = cap if l.is_a?(Listener::TokenLog)
      end
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
