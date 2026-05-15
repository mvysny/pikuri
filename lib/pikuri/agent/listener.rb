# frozen_string_literal: true

module Pikuri
  class Agent
    # Namespace for the +Agent+'s pure event consumers — {Terminal},
    # {InMemoryEventList}, {TokenLog}, and any host- or test-defined
    # consumer. Each subclasses {Base} and overrides {Base#on_event}
    # to pattern-match on the {Event} variants it cares about;
    # everything else flows through unobserved.
    #
    # == What lives here, what doesn't
    #
    # The directory holds *pure consumers*: code whose only side
    # effect is to react to events the +Agent+ has already emitted.
    # No listener writes back into the stream — the +Agent+ is the
    # only emitter — and no listener reaches into ruby_llm's chat
    # callbacks. Both responsibilities live in {Agent}.
    #
    # Host-facing signal holders — step budget, cancellation flag,
    # mid-loop user input queue — are *controls*, not listeners.
    # They live under {Pikuri::Agent::Control} and reach {Agent}
    # through dedicated kwargs on {Agent#initialize}; they never
    # appear in the {ListenerList} and they never receive events.
    module Listener
      # Abstract base for event-stream consumers. Subclasses override
      # {#on_event} with a +case+ on the {Event} variant; the default
      # implementation is a no-op so a listener that cares about a
      # single variant doesn't have to enumerate the rest.
      #
      # Subclasses optionally define +for_sub_agent(**params)+ to
      # return a variant suitable for a spawned sub-agent — a fresh
      # zeroed instance, the same instance shared by reference, or
      # +nil+ to opt out of propagation. See
      # {ListenerList#for_sub_agent} for the dispatch and the
      # per-listener semantics.
      class Base
        # Single entry point for every event in the normalized stream.
        # Concrete subclasses override this and dispatch on the
        # variant (typically with a +case event in Event::X(...)+
        # pattern). The default implementation is a no-op so a
        # listener that only cares about a subset can match
        # selectively and let everything else fall through.
        #
        # @param event [Event::UserTurn, Event::Thinking,
        #   Event::Assistant, Event::ToolCall, Event::ToolResult,
        #   Event::Tokens, Event::ContextCap,
        #   Event::FallbackNotice, Event::Cancelled]
        # @return [void]
        def on_event(event); end
      end
    end
  end
end
