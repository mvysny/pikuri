# frozen_string_literal: true

class Agent
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
    # events. {Message::User} is not a +Chat+ event — {Agent#run_loop}
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
      #   Message::Assistant, Message::ToolCall, Message::ToolResult]
      # @return [void]
      def on_message(message); end

      private

      def dispatch_chat_message(msg)
        return unless msg.role == :assistant

        text = msg.thinking&.text
        on_message(Message::Thinking.new(content: text)) if text && !text.empty?

        content = msg.content
        on_message(Message::Assistant.new(content: content)) if content.is_a?(String) && !content.empty?
      end
    end
  end
end
