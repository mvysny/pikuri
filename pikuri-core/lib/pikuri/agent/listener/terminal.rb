# frozen_string_literal: true

require 'rainbow'
require 'tty-markdown'

module Pikuri
  class Agent
    module Listener
      # Terminal renderer for the normalized event stream: dim grey
      # reasoning, Markdown-rendered assistant content, cyan tool-
      # call and tool-result lines, yellow fallback notice, red
      # cancelled notice. {Event::UserTurn} is intentionally silent
      # (the terminal user just typed the message, so re-rendering
      # it adds nothing); {Event::Tokens} and {Event::ContextCap}
      # are silent too (their consumer is {TokenLog}).
      #
      # Optionally prepends a fixed number of leading spaces to
      # every rendered line via the +padding:+ kwarg. Sub-agents
      # get a fresh padded instance through {#for_sub_agent}
      # (dispatched by {ListenerList#for_sub_agent}) so their
      # output is visually indented under the parent's stream.
      #
      # == Streaming mode
      #
      # When constructed with +streaming: true+ (typically because
      # the host's {Agent} was constructed with the matching flag):
      #
      # - {Event::ThinkingDelta} fragments print live in the same
      #   dim grey as the non-streaming {Event::Thinking}, with no
      #   trailing newline so the next fragment continues the line.
      # - {Event::AssistantDelta} fragments print live, *raw* — no
      #   Markdown render. tty-markdown can't render half-finished
      #   Markdown (broken code blocks, half-rendered tables), so
      #   the live stream gives up formatting in exchange for
      #   liveness.
      # - {Event::Thinking} and {Event::Assistant} bookends print
      #   a single blank line as a stream terminator, not their
      #   content (the content already landed via the deltas). The
      #   terminator gives the next event (tool call, next round,
      #   final REPL prompt) a clean line to start on.
      #
      # In non-streaming mode (+streaming: false+, the default),
      # the deltas are silently ignored and the bookend events
      # render the full text the way they always have.
      class Terminal < Base
        # Subsystem logger; set its level with +PIKURI_LOG_TERMINAL+
        # or the global +PIKURI_LOG+. Used for the narrow rescue
        # around third-party rendering (+tty-markdown+ choking on
        # assistant output) — see the CLAUDE.md "secondary to the
        # loop" carve-out.
        #
        # @return [Logger]
        LOGGER = Pikuri.logger_for('Terminal')

        # Cap, in characters, applied to tool-result content
        # rendered to the terminal. Anything longer is truncated
        # with a marker that reports the original byte size so the
        # reader can tell a 200-char return apart from a 50KB HTML
        # dump.
        MAX_TOOL_RESULT_CHARS = 200

        # Padding applied to a sub-agent's rendered stream.
        # Absolute, not additive — sub-agent recursion is blocked
        # (the sub-agent's tool set excludes +sub_agent+ itself),
        # so the depth never exceeds 1 in practice and a fixed
        # indent reads cleanly.
        SUB_AGENT_PADDING = 2

        # @param padding [Integer] non-negative number of leading
        #   spaces prepended to every rendered line. Defaults to 0;
        #   sub-agents get a fresh instance with
        #   {SUB_AGENT_PADDING} via {#for_sub_agent}.
        # @param streaming [Boolean] render the chunk-level delta
        #   stream live. See the class header's "Streaming mode"
        #   section for the behavior swap. Defaults to +false+.
        def initialize(padding: 0, streaming: false)
          super()
          @padding = padding
          @streaming = streaming
          @at_line_start = true
        end

        # @return [Integer] current padding width; exposed so
        #   callers can introspect it (and so tests can assert it).
        attr_reader :padding

        # @return [Boolean] +true+ when this Terminal is in
        #   streaming mode (deltas rendered live; bookends emit a
        #   terminator newline only).
        attr_reader :streaming

        # Sub-agent variant: a fresh +Terminal+ at
        # {SUB_AGENT_PADDING}, carrying the same +streaming+ flag
        # the parent had, so sub-agent output is visually indented
        # under the parent's stream and the stream mode stays
        # consistent across the agent tree. Called by
        # {ListenerList#for_sub_agent}; ignores any params it's
        # handed (Terminal has no caller-provided knobs).
        #
        # @return [Terminal]
        def for_sub_agent(**)
          self.class.new(padding: SUB_AGENT_PADDING, streaming: @streaming)
        end

        # @param event [Agent::Event] one of the {Agent::Event}
        #   variants; see {Agent::Event} for the full list
        # @return [void]
        def on_event(event)
          case event
          in Event::Thinking(content:)
            if @streaming
              terminate_stream
            else
              println(indent(Rainbow(content).color(85, 85, 85)))
            end
          in Event::Assistant(content:)
            if @streaming
              terminate_stream
            else
              println(indent(render_markdown(content)))
            end
          in Event::ThinkingDelta(content:)
            stream_fragment(Rainbow(content).color(85, 85, 85)) if @streaming
          in Event::AssistantDelta(content:)
            stream_fragment(content) if @streaming
          in Event::ToolCall(name:, arguments:)
            args = arguments.map { |k, v| "#{k}=#{v.inspect}" }.join(', ')
            println(indent(Rainbow("→ #{name}(#{args})").cyan))
          in Event::ToolResult(content:)
            println(indent(Rainbow("= #{truncate_tool_result(content)}").cyan))
          in Event::FallbackNotice(reason:)
            println(indent(Rainbow("! #{reason}").yellow))
          in Event::Cancelled
            println(indent(Rainbow('! cancelled').red))
          else
            # UserTurn / Tokens / ContextCap silent on the terminal.
            # In non-streaming mode the deltas fall through here
            # too (the final Thinking / Assistant bookend already
            # renders the full text).
          end
        end

        # @return [String] short label for {Agent#to_s}; appends
        #   each non-default knob (+padding+, +streaming+) so the
        #   default form stays +"Terminal"+
        def to_s
          suffix = []
          suffix << "padding=#{@padding}" unless @padding.zero?
          suffix << 'streaming' if @streaming
          suffix.empty? ? 'Terminal' : "Terminal(#{suffix.join(', ')})"
        end

        private

        # +puts+ wrapper that also resets the streaming line-state
        # to "at line start" — every full-line print necessarily
        # leaves the cursor at column 0, so the next fragment
        # printed in streaming mode knows to insert padding before
        # its first character. Used by every branch in
        # {#on_event} except the delta branches.
        #
        # @param text [String]
        # @return [void]
        def println(text)
          puts text
          @at_line_start = true
        end

        # Emit a single newline as a stream terminator and reset
        # the line-state. Called on {Event::Thinking} /
        # {Event::Assistant} bookends in streaming mode, where the
        # content has already been rendered via the delta stream
        # and what's left to do is give the next event a clean
        # line to start on.
        #
        # @return [void]
        def terminate_stream
          puts
          @at_line_start = true
        end

        # Print one streaming fragment to stdout *without* a
        # trailing newline (so the next fragment continues the
        # line) and flush so the bytes actually reach the
        # terminal. Threads padding through any mid-fragment
        # newlines: a fragment that contains "foo\nbar" with
        # padding 2 prints +"  foo\n  bar"+ when the cursor was
        # at line start.
        #
        # @param text [String] the fragment to emit; +nil+ / empty
        #   short-circuits
        # @return [void]
        def stream_fragment(text)
          return if text.nil? || text.empty?

          if @padding.zero?
            print(text)
            @at_line_start = text.end_with?("\n")
          else
            buf = String.new
            prefix = ' ' * @padding
            text.each_char do |ch|
              buf << prefix if @at_line_start
              buf << ch
              @at_line_start = (ch == "\n")
            end
            print(buf)
          end
          $stdout.flush
        end

        # Prepend +@padding+ spaces to every line of +text+. Splits
        # on +each_line+ rather than a +gsub+ trick so a trailing
        # newline in the input doesn't produce a stray padded blank
        # line at the end — +puts+ adds the final newline if
        # missing, same as before.
        #
        # @param text [String]
        # @return [String]
        def indent(text)
          return text if @padding.zero?

          prefix = ' ' * @padding
          text.to_s.each_line.map { |line| prefix + line }.join
        end

        # Render assistant Markdown for the terminal, degrading to
        # the raw string when the renderer raises. tty-markdown /
        # strings have known bugs around ANSI inside tables (e.g.
        # +Strings::Wrap.insert_ansi+ raising +IndexError+); we'd
        # rather show ugly Markdown than abort an in-flight
        # conversation.
        #
        # @param content [String] assistant Markdown
        # @return [String] rendered ANSI text, or +content+
        #   unchanged on render failure
        def render_markdown(content)
          TTY::Markdown.parse(content)
        rescue StandardError => e
          LOGGER.warn("TTY::Markdown render failed (#{e.class}: #{e.message}); falling back to raw text")
          content
        end

        # Flatten whitespace and cap to {MAX_TOOL_RESULT_CHARS}. The
        # cap keeps multi-screen dumps (rendered HTML, PDF text)
        # from drowning the terminal stream; the byte-count suffix
        # on a truncated result distinguishes "tool returned
        # exactly this" from "tool returned much more, you're
        # seeing a slice."
        #
        # @param content [String] tool observation
        # @return [String] single-line display form, possibly
        #   truncated
        def truncate_tool_result(content)
          original_bytes = content.to_s.bytesize
          flattened = content.to_s.gsub(/\s+/, ' ').strip
          return flattened if flattened.length <= MAX_TOOL_RESULT_CHARS

          "#{flattened[0, MAX_TOOL_RESULT_CHARS]}… (#{original_bytes} bytes total)"
        end
      end
    end
  end
end
