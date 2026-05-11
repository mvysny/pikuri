# frozen_string_literal: true

require 'rainbow'
require 'tty-markdown'

class Agent
  module Listener
    # Terminal renderer for the normalized event stream: dim grey
    # reasoning, Markdown-rendered assistant content, cyan tool-call
    # and tool-result lines. {Message::User} is intentionally silent —
    # the user typed it, so re-rendering it adds nothing on the CLI.
    # This is the default listener attached by {Agent#initialize}.
    class Terminal < MessageListener
      # @param message [Agent::Message] one of the {Agent::Message}
      #   variants; see {Agent::Message} for the full list
      # @return [void]
      def on_message(message)
        case message
        in Message::Thinking(content:)
          puts Rainbow(content).darkgray
        in Message::Assistant(content:)
          puts TTY::Markdown.parse(content)
        in Message::ToolCall(name:, arguments:)
          args = arguments.map { |k, v| "#{k}=#{v.inspect}" }.join(', ')
          puts Rainbow("→ #{name}(#{args})").cyan
        in Message::ToolResult(content:)
          puts Rainbow("= #{content}").cyan
        in Message::User
          # No-op: the user just typed this; echoing it back is noise.
        end
      end

      # @return [String] short label for {Agent#to_s}
      def to_s
        'Terminal'
      end
    end
  end
end
