# frozen_string_literal: true

module Pikuri
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
    # 1. {#for_sub_agent} produces a derived list for a sub-agent run by
    #    forwarding to each listener's own +for_sub_agent(**params)+
    #    hook (default identity for listeners that don't define one).
    #    The dispatch lives on the listener — +Terminal+ swaps in a
    #    padded fresh instance, +TokenLog+ resets its snapshot,
    #    +StepLimit+ picks +max_steps+ out of the params hash — so this
    #    class doesn't grow a method per new listener type. The
    #    synthesizer rescue uses the same hook with +max_steps: 1+,
    #    since a step-exhausted synth is just another fresh-context run.
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
      # Listeners that need to emit events *back* into the listener
      # stream (notably {Listener::Interloper}, which surfaces injected
      # messages as +Message::User+ events for the other listeners)
      # opt in by defining +listener_list=+; the receiver pokes itself
      # via that setter before calling +attach+. Listeners that don't
      # respond to the setter are skipped — the protocol is duck-typed,
      # not part of any base class, so it costs nothing when unused.
      #
      # @param chat [RubyLLM::Chat]
      # @return [void]
      def attach(chat)
        @listeners.each do |l|
          l.listener_list = self if l.respond_to?(:listener_list=)
          l.attach(chat)
        end
      end

      # Dispatch one message to every listener.
      #
      # @param message [Agent::Message]
      # @return [void]
      def on_message(message)
        @listeners.each { |l| l.on_message(message) }
      end

      # Return a new {ListenerList} in which every listener has been
      # asked for its sub-agent variant. Each listener that defines
      # +for_sub_agent(**params)+ receives the forwarded +params+ and
      # returns either +self+, a replacement instance, or +nil+ to
      # opt out of propagation entirely — the resulting list compacts
      # +nil+ entries away. Listeners that don't define the method are
      # kept by reference (output, structured capture, and anything else
      # stateful flow continuously into the parent's instances).
      #
      # The dispatch lives on the listener so adding a new listener type
      # with sub-agent-specific behavior doesn't change this class — see
      # {Listener::Terminal#for_sub_agent} (fresh padded instance),
      # {Listener::TokenLog#for_sub_agent} (fresh, zeroed snapshot),
      # {Listener::StepLimit#for_sub_agent} (fresh cap from +max_steps:+),
      # {Listener::Cancellable#for_sub_agent} (same instance, shared by
      # reference so a parent cancel kills sub-agents too), and
      # {Listener::Interloper#for_sub_agent} (+nil+, since sub-agents
      # are private to the parent and the host never holds a handle to
      # them — the host's injection channel must terminate at the main
      # agent).
      #
      # +params+ is a flat hash forwarded as kwargs to every listener's
      # hook; each listener picks the keys it cares about and ignores
      # the rest (the +**+ catch-all in their signatures). Calling with
      # no params is always valid — every listener's +for_sub_agent+
      # treats its consumed keys as optional (e.g. +StepLimit+ falls
      # back to its own cap when +max_steps:+ is absent).
      #
      # @param params [Hash{Symbol => Object}] kwargs forwarded to each
      #   listener's +for_sub_agent+. Currently +max_steps:+ and +name:+
      #   are the keys consumed by bundled listeners.
      # @return [ListenerList]
      def for_sub_agent(**params)
        swapped = @listeners.map do |l|
          l.respond_to?(:for_sub_agent) ? l.for_sub_agent(**params) : l
        end.compact
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
end
