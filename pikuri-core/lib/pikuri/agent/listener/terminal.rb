# frozen_string_literal: true

require 'rainbow'

module Pikuri
  class Agent
    module Listener
      # Terminal renderer for the normalized event stream: dim grey reasoning,
      # assistant Markdown printed raw, cyan tool-call/result lines, yellow
      # fallback notice, red cancelled, magenta model-switch.
      # {Event::UserTurn} / {Event::Tokens} / {Event::ContextCap} are silent
      # (echo, or {TokenLog}'s business); {Event::SystemInjected} renders dim
      # grey with a +⊕+ marker. Any unrecognized event — notably a gem
      # *domain* event — renders generically via its +to_s+ (dim grey, +·+
      # marker), so a new variant shows in the demo without a change here.
      #
      # Assistant Markdown prints raw, no Markdown-to-ANSI: rendering can't
      # apply to the streaming path anyway (half-built fences/tables), and the
      # one gem for it (tty-markdown) was unmaintained, crashed on
      # ANSI-in-tables, and pulled seven transitive deps — proper rendering
      # belongs to a richer host (the planned pikuri-tui).
      #
      # +padding:+ prepends a fixed number of leading spaces to every line;
      # sub-agents get a fresh padded instance via {#for_sub_agent}.
      #
      # == Streaming mode
      #
      # With +streaming: true+ (matching the {Agent}'s flag):
      # {Event::ThinkingDelta} / {Event::AssistantDelta} print live (dim grey /
      # uncolored, no trailing newline), and the {Event::Thinking} /
      # {Event::Assistant} bookends print a single blank line as a terminator,
      # not their content (already landed via deltas). With +streaming: false+
      # (default) the deltas are ignored and the bookends render full text.
      class Terminal < Base
        # Char cap on tool-result content rendered to the terminal; longer is
        # truncated with a marker reporting the original byte size (so a
        # 200-char return is distinguishable from a 50KB dump).
        MAX_TOOL_RESULT_CHARS = 200

        # Padding for a sub-agent's stream. Absolute, not additive — sub-agent
        # recursion is blocked (the sub-agent's toolset excludes +sub_agent+),
        # so depth never exceeds 1 and a fixed indent reads cleanly.
        SUB_AGENT_PADDING = 2

        # @param padding [Integer] non-negative leading spaces per line
        #   (default 0; sub-agents get {SUB_AGENT_PADDING} via {#for_sub_agent}).
        # @param streaming [Boolean] render the chunk-level delta stream live
        #   (default +false+; see "Streaming mode").
        def initialize(padding: 0, streaming: false)
          super()
          @padding = padding
          @streaming = streaming
          @at_line_start = true
        end

        # @return [Integer] current padding width.
        attr_reader :padding

        # @return [Boolean] +true+ in streaming mode.
        attr_reader :streaming

        # Sub-agent variant: a fresh +Terminal+ at {SUB_AGENT_PADDING} carrying
        # the parent's +streaming+ flag, so sub-agent output indents under the
        # parent's stream. Ignores any params (Terminal has no caller knobs).
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
              println(indent(content))
            end
          in Event::ThinkingDelta(content:)
            stream_fragment(Rainbow(content).color(85, 85, 85)) if @streaming
          in Event::AssistantDelta(content:)
            stream_fragment(content) if @streaming
          in Event::SystemInjected(content:)
            println(indent(Rainbow("⊕ #{content}").color(85, 85, 85)))
          in Event::ToolCall(name:, arguments:)
            args = arguments.map { |k, v| "#{k}=#{v.inspect}" }.join(', ')
            println(indent(Rainbow("→ #{name}(#{args})").cyan))
          in Event::ToolResult(content:)
            println(indent(Rainbow("= #{truncate_tool_result(content)}").cyan))
          in Event::ModelSwitched(from:, to:)
            println(indent(Rainbow("⇄ model: #{from.model} → #{to.model}").magenta))
          in Event::FallbackNotice(reason:)
            println(indent(Rainbow("! #{reason}").yellow))
          in Event::Cancelled
            println(indent(Rainbow('! cancelled').red))
          in Event::Reset
            println(indent(Rainbow('— context cleared —').color(85, 85, 85)))
          in Event::UserTurn | Event::Tokens | Event::ContextCap
            # Silent: UserTurn echoes just-typed input; Tokens/ContextCap are
            # TokenLog's. (Non-streaming deltas no-op in their branches above.)
          else
            # Any other event — notably a gem *domain* event — renders via its
            # own to_s; core needs no knowledge of the type. A richer host
            # pattern-matches the variants it styles.
            println(indent(Rainbow("· #{event}").color(85, 85, 85)))
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

        # +puts+ wrapper that resets the streaming line-state to "at line
        # start" (a full-line print leaves the cursor at column 0, so the next
        # streamed fragment knows to insert padding first).
        #
        # @param text [String]
        # @return [void]
        def println(text)
          puts text
          @at_line_start = true
        end

        # Emit a newline as a stream terminator and reset line-state — the
        # {Event::Thinking}/{Event::Assistant} bookend in streaming mode, where
        # the content already rendered via deltas.
        #
        # @return [void]
        def terminate_stream
          puts
          @at_line_start = true
        end

        # Print one streaming fragment without a trailing newline (so the next
        # continues the line) and flush. Threads padding through mid-fragment
        # newlines: "foo\nbar" at padding 2 from line start prints
        # +"  foo\n  bar"+.
        #
        # @param text [String] the fragment; +nil+/empty short-circuits
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

        # Prepend +@padding+ spaces to every line of +text+. Uses +each_line+,
        # not a +gsub+, so a trailing newline doesn't produce a stray padded
        # blank line.
        #
        # @param text [String]
        # @return [String]
        def indent(text)
          return text if @padding.zero?

          prefix = ' ' * @padding
          text.to_s.each_line.map { |line| prefix + line }.join
        end

        # Flatten whitespace and cap to {MAX_TOOL_RESULT_CHARS}; a truncated
        # result's byte-count suffix distinguishes "returned exactly this" from
        # "returned much more, you're seeing a slice."
        #
        # Whitespace is flattened first (fine — this passive echo is a status
        # line, not an approval artifact), then run through {Pikuri::Sanitizer}
        # so a tool observation can't smuggle an ESC/control byte into this
        # line. Its warnings are dropped (they belong at a confirmation prompt).
        #
        # @param content [String] tool observation
        # @return [String] single-line display form, possibly truncated
        def truncate_tool_result(content)
          original_bytes = content.to_s.bytesize
          flattened = Sanitizer.sanitize(content.to_s.gsub(/\s+/, ' ').strip).text
          return flattened if flattened.length <= MAX_TOOL_RESULT_CHARS

          "#{flattened[0, MAX_TOOL_RESULT_CHARS]}… (#{original_bytes} bytes total)"
        end
      end
    end
  end
end
