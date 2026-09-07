# frozen_string_literal: true

require 'rainbow'
require 'io/console'

module Pikuri
  class Agent
    module Listener
      # Terminal renderer for the normalized event stream: dim grey reasoning,
      # assistant Markdown printed raw, tool-call/result lines in Kuri's coat
      # ({TOOL_COLOR}), yellow fallback notice, red cancelled, magenta
      # model-switch. A tool call renders as the two strings the tool composed,
      # never an argument dump or a slice of the observation:
      #
      #   → Write(lib/shared/config.rb)
      #   = Added 2 lines, removed 3 lines
      #
      # {Event::UserTurn} / {Event::Tokens} / {Event::ContextCap} are silent
      # (echo, or {TokenLog}'s business); {Event::SystemInjected} renders dim
      # grey with a +⊕+ marker. Any unrecognized event — notably a gem
      # *domain* event — renders generically via its +to_s+ (dim grey, +·+
      # marker), so a new variant shows in the demo without a change here. An
      # {Event::Transient} one instead rewrites a single line in place, and the
      # text of every domain event is defanged through {Pikuri::Sanitizer} —
      # a +to_s+ may carry a filename, a skill name or a server's own words.
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
        # Char cap on a tool's display strings ({Event::ToolResult}'s summary, a
        # display name). Generous — these are one short line by construction,
        # and the cap is a backstop against an +"Error: ..."+ observation
        # passing a long message through.
        MAX_SUMMARY_CHARS = 200

        # Floor on the room a tool-call argument gets, for the narrow terminal
        # where the budget arithmetic would otherwise leave it nothing.
        MIN_ARGUMENT_CHARS = 20

        # Color of the +→ call+ / += result+ lines: Kuri's Talus coat
        # (+assets/kuri.svg+) with the chroma lifted, because the coat verbatim
        # (+#a89c8e+, 13% saturation) lands on the dim reasoning grey's
        # lightness and reads as a second shade of it. An absolute RGB rather
        # than a named ANSI color, so a remapped terminal palette can't repaint
        # pikuri's own color — the same hex the tui and web shells paint.
        # @return [String]
        TOOL_COLOR = '#c1a586'

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
          @transient = false
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
          in Event::ToolCall(display_name:, argument:)
            println(indent(Rainbow("→ #{tool_call_line(display_name, argument)}").color(TOOL_COLOR)))
          in Event::ToolResult(summary:)
            println(indent(Rainbow("= #{defang(summary, MAX_SUMMARY_CHARS)}").color(TOOL_COLOR)))
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
            domain_event(event)
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
          clear_transient
          puts text
          @at_line_start = true
        end

        # A gem domain event, defanged and dimmed — an {Event::Transient} one
        # rewriting a single line rather than appending to the log.
        #
        # @param event [Object] any event variant this listener does not style.
        # @return [void]
        def domain_event(event)
          text = Sanitizer.sanitize(event.to_s.gsub(/\s+/, ' ').strip).text
          return dim_line(text) unless event.is_a?(Event::Transient)

          transient(text, done: event.done)
        end

        # @param text [String] sanitized and flattened.
        # @return [void]
        def dim_line(text)
          println(indent(Rainbow("· #{text}").color(85, 85, 85)))
        end

        # Rewrite the in-place line, or retire it.
        #
        # Off a terminal it degrades to the final state only, as an ordinary line:
        # a stream of +\r+ into a file is one unreadable mega-line, and a cold
        # index emits hundreds of updates.
        #
        # @param text [String] sanitized and flattened.
        # @param done [Boolean] the sequence is over, so the line goes away.
        # @return [void]
        def transient(text, done:)
          unless $stdout.tty?
            dim_line(text) if done
            return
          end

          clear_transient
          return if done

          print(Rainbow(cut(indent("· #{text}"))).color(85, 85, 85))
          $stdout.flush
          @transient = true
          @at_line_start = false
        end

        # Erase the in-place line so ordinary output does not land mid-bar.
        #
        # @return [void]
        def clear_transient
          return unless @transient

          print("\r\e[K")
          @transient = false
          @at_line_start = true
        end

        # Fit +text+ in one row, because a line that wraps leaves its tail behind
        # the carriage return that was supposed to erase it.
        #
        # @param text [String]
        # @return [String]
        def cut(text)
          width = terminal_width
          text.length < width ? text : "#{text[0, width - 2]}…"
        end

        # Emit a newline as a stream terminator and reset line-state — the
        # {Event::Thinking}/{Event::Assistant} bookend in streaming mode, where
        # the content already rendered via deltas.
        #
        # @return [void]
        def terminate_stream
          clear_transient
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

          clear_transient

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

        # The +Name(argument)+ half of a tool-call line, the argument capped to
        # whatever the row has left — a +command+ can be a 4 kB script and a
        # +path+ a very long one, and only a renderer knows its width.
        #
        #   tool_call_line('Write', 'lib/shared/config.rb')  # => "Write(lib/shared/config.rb)"
        #   tool_call_line('EnterPlanMode', '')              # => "EnterPlanMode"
        #
        # @param display_name [String] see {Pikuri::Tool#display_name}
        # @param argument [String] see {Pikuri::Tool#describe_call}
        # @return [String]
        def tool_call_line(display_name, argument)
          name = defang(display_name, MAX_SUMMARY_CHARS)
          return name if argument.to_s.empty?

          # "→ ", the parens, and the padding are all on this row too.
          budget = terminal_width - @padding - name.length - 5
          "#{name}(#{defang(argument, [budget, MIN_ARGUMENT_CHARS].max)})"
        end

        # Flatten whitespace, defang, and cap to +limit+ — every display string
        # off the event stream goes through this.
        #
        # Whitespace flattening is safe here (a passive status line, not an
        # approval artifact); {Pikuri::Sanitizer} is what stops a path carrying
        # +ESC[+ or a CR from recoloring or overwriting the transcript, now that
        # these strings no longer pass through +inspect+. Its warnings are
        # dropped — they belong at a confirmation prompt.
        #
        # @param text [String, nil]
        # @param limit [Integer] max characters, +…+ marking a cut
        # @return [String]
        def defang(text, limit)
          flattened = Sanitizer.sanitize(text.to_s.gsub(/\s+/, ' ').strip).text
          return flattened if flattened.length <= limit

          "#{flattened[0, limit - 1]}…"
        end

        # @return [Integer] terminal columns; 80 when stdout has no window size
        #   (a pipe, a file, a captured StringIO).
        def terminal_width
          $stdout.winsize[1]
        rescue StandardError
          80
        end
      end
    end
  end
end
