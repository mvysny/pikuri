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
    #
    # Optionally prepends a fixed number of leading spaces to every
    # rendered line via the +padding:+ kwarg. Sub-agents get a fresh
    # padded instance through {Agent::ListenerList#with_padding} so
    # their output is visually indented under the parent's stream.
    class Terminal < MessageListener
      LOGGER = Pikuri.logger_for('Terminal')

      # Cap, in characters, applied to tool-result content rendered to
      # the terminal. Anything longer is truncated with a marker that
      # reports the original byte size so the reader can tell a 200-
      # char return apart from a 50KB HTML dump.
      MAX_TOOL_RESULT_CHARS = 200

      # @param padding [Integer] non-negative number of leading spaces
      #   prepended to every rendered line. Defaults to 0; sub-agents
      #   set this to 2 via {Agent::ListenerList#with_padding}.
      def initialize(padding: 0)
        super()
        @padding = padding
      end

      # @return [Integer] current padding width; exposed so
      #   {Agent::ListenerList#with_padding} can introspect it (and so
      #   tests can assert it).
      attr_reader :padding

      # @param message [Agent::Message] one of the {Agent::Message}
      #   variants; see {Agent::Message} for the full list
      # @return [void]
      def on_message(message)
        case message
        in Message::Thinking(content:)
          puts indent(Rainbow(content).darkgray)
        in Message::Assistant(content:)
          puts indent(render_markdown(content))
        in Message::ToolCall(name:, arguments:)
          args = arguments.map { |k, v| "#{k}=#{v.inspect}" }.join(', ')
          puts indent(Rainbow("→ #{name}(#{args})").cyan)
        in Message::ToolResult(content:)
          puts indent(Rainbow("= #{truncate_tool_result(content)}").cyan)
        in Message::FallbackNotice(reason:)
          puts indent(Rainbow("! #{reason}").yellow)
        in Message::User
          # No-op: the user just typed this; echoing it back is noise.
        end
      end

      # @return [String] short label for {Agent#to_s}; includes the
      #   padding suffix only when non-zero so the default form stays
      #   +"Terminal"+
      def to_s
        @padding.zero? ? 'Terminal' : "Terminal(padding=#{@padding})"
      end

      private

      # Prepend +@padding+ spaces to every line of +text+. Splits on
      # +each_line+ rather than a +gsub+ trick so a trailing newline
      # in the input doesn't produce a stray padded blank line at the
      # end — +puts+ adds the final newline if missing, same as
      # before.
      #
      # @param text [String]
      # @return [String]
      def indent(text)
        return text if @padding.zero?

        prefix = ' ' * @padding
        text.to_s.each_line.map { |line| prefix + line }.join
      end

      # Render assistant Markdown for the terminal, degrading to the
      # raw string when the renderer raises. tty-markdown / strings
      # have known bugs around ANSI inside tables (e.g.
      # +Strings::Wrap.insert_ansi+ raising +IndexError+); we'd rather
      # show ugly Markdown than abort an in-flight conversation.
      #
      # @param content [String] assistant Markdown
      # @return [String] rendered ANSI text, or +content+ unchanged on
      #   render failure
      def render_markdown(content)
        TTY::Markdown.parse(content)
      rescue StandardError => e
        LOGGER.warn("TTY::Markdown render failed (#{e.class}: #{e.message}); falling back to raw text")
        content
      end

      # Flatten whitespace and cap to {MAX_TOOL_RESULT_CHARS}. The cap
      # keeps multi-screen dumps (rendered HTML, PDF text) from
      # drowning the terminal stream; the byte-count suffix on a
      # truncated result distinguishes "tool returned exactly this"
      # from "tool returned much more, you're seeing a slice."
      #
      # @param content [String] tool observation
      # @return [String] single-line display form, possibly truncated
      def truncate_tool_result(content)
        original_bytes = content.to_s.bytesize
        flattened = content.to_s.gsub(/\s+/, ' ').strip
        return flattened if flattened.length <= MAX_TOOL_RESULT_CHARS

        "#{flattened[0, MAX_TOOL_RESULT_CHARS]}… (#{original_bytes} bytes total)"
      end
    end
  end
end
