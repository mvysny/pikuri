# frozen_string_literal: true

module Pikuri
  class Agent
    # Namespace for listeners that consume the +Agent+'s normalized event
    # stream. Concrete listeners — {Terminal}, {InMemoryMessageList},
    # {StepLimit}, {TokenLog} — extend {MessageListener} and override its
    # hooks; {Agent::ListenerList} owns the fan-out across the set.
    module Listener
      # Abstract base for listeners that consume the +Agent+'s normalized
      # event stream as {Message} value objects. Concrete subclasses
      # override the single {#on_message} hook and pattern-match on the
      # variant.
      #
      # +#attach(chat)+ wires the three +RubyLLM::Chat+ callbacks once,
      # builds the appropriate {Message} variant from each payload, and
      # forwards it into {#on_message}. Empty +thinking+ and +assistant+
      # content is filtered here so subclasses never receive vacuous
      # events.
      #
      # Provider-reported token usage is a separate channel: every
      # assistant +after_message+ event (including pure tool-call turns
      # with empty content) emits an {Agent::Tokens} through {#on_tokens}
      # so listeners that track context-window growth see every round
      # trip. {Message::User} is not a +Chat+ event — {Agent#run_loop}
      # constructs it directly and calls {#on_message}.
      class MessageListener
        # Wire the receiver into +chat+'s callback API. After this
        # returns, +chat+'s loop will build {Message} variants from each
        # event and forward them into {#on_message} on this instance.
        #
        # @param chat [RubyLLM::Chat]
        # @return [void]
        def attach(chat)
          chat.after_message     { |msg| dispatch_chat_message(msg) }
          chat.before_tool_call  { |tc|  on_message(Message::ToolCall.new(name: tc.name, arguments: tc.arguments)) }
          chat.after_tool_result { |r|   on_message(Message::ToolResult.new(content: r)) }
        end

        # Single entry point for every event in the normalized stream.
        # Concrete subclasses override this and dispatch on the variant
        # (typically with a +case msg in Message::X(...)+ pattern). The
        # default implementation is a no-op so listeners that only care
        # about a subset can pattern-match and let everything else fall
        # through.
        #
        # @param message [Message::User, Message::Thinking,
        #   Message::Assistant, Message::ToolCall, Message::ToolResult,
        #   Message::FallbackNotice]
        # @return [void]
        def on_message(message); end

        # Hook for provider-reported token usage. Fires once per
        # assistant turn (including pure tool-call turns with empty
        # content) from {#dispatch_chat_message}. Default is a no-op so
        # listeners that don't care — {Terminal}, {InMemoryMessageList} —
        # ignore it; {TokenLog} overrides this to log and accumulate.
        #
        # @param tokens [Agent::Tokens]
        # @return [void]
        def on_tokens(tokens); end

        private

        # Normalizes a +RubyLLM::Chat+ +after_message+ payload into the
        # appropriate {Message} variants for {#on_message}, plus an
        # {Agent::Tokens} for {#on_tokens}.
        #
        # +msg+ is a +RubyLLM::Message+. Beyond +role+, +content+,
        # +thinking+, and +tokens+ used here, it also carries
        # +msg.tool_calls+ on assistant turns that requested one and
        # +msg.raw+ for the unparsed provider payload.
        #
        # @param msg [RubyLLM::Message]
        # @return [void]
        def dispatch_chat_message(msg)
          return unless msg.role == :assistant

          text = msg.thinking&.text
          on_message(Message::Thinking.new(content: text)) if text && !text.empty?

          content = msg.content
          on_message(Message::Assistant.new(content: content)) if content.is_a?(String) && !content.empty?

          on_tokens(Agent::Tokens.new(
                      input: msg.input_tokens,
                      output: msg.output_tokens,
                      cached: msg.cached_tokens,
                      cache_creation: msg.cache_creation_tokens,
                      thinking: msg.thinking_tokens,
                      model_id: msg.model_id
                    ))
        end
      end
    end
  end
end
