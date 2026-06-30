# frozen_string_literal: true

module Pikuri
  class Agent
    module Listener
      # Logs the conversation's context-window consumption per
      # assistant turn via +Pikuri.logger_for('Tokens')+. Consumes
      # {Event::Tokens} (one log line per emission) and
      # {Event::ContextCap} (the cap, picked off and cached —
      # refreshed if a later {Event::ContextCap} arrives after a
      # model switch) and {Event::Reset} (the host cleared the
      # conversation — zero the running snapshot, see {#reset_snapshot});
      # every other event variant is a no-op. A
      # switch does not reset the running size or message count: the
      # next {Event::Tokens} self-corrects the headline to the new
      # model's count.
      #
      # Existence rationale: catch context-window growth before the
      # provider raises +RubyLLM::ContextLengthExceededError+.
      # +ctx+ is the headline number — tokens consumed by the
      # conversation *through* this turn: this turn's prompt plus
      # its reply, both of which the model will re-process on the
      # next turn. The +Δ+ field shows the climb between turns;
      # +↑+ / +↓+ are the per-turn input / output sizes that drove
      # it (matching Claude Code's convention: +↑+ is what's sent
      # to the model, +↓+ is what comes back).
      #
      # == State and scope
      #
      # The latest snapshot lives on the instance, so one
      # +TokenLog+ is per-conversation. Sub-agents (with their own
      # +RubyLLM::Chat+) get a fresh instance via {#for_sub_agent}
      # (dispatched by {ListenerList#for_sub_agent}) so their
      # counts log against their own chat. The synthesizer rescue
      # gets a derived list via the same hook because its synth
      # chat is also fresh.
      #
      # == Log line shape
      #
      # Without a cap (no {Event::ContextCap} carrying a value):
      #
      #   msg #1: ctx=6.8k  Δ+6.8k  ↑6.8k  ↓0.0k
      #   msg #2: ctx=8.4k  Δ+1.6k  ↑1.0k  ↓0.6k
      #
      # With a cap of e.g. 32k (an {Event::ContextCap} with
      # +cap: 32_768+ was emitted at {Agent#initialize}):
      #
      #   msg #1: ctx=6.8k/32.0k  Δ+6.8k  ↑6.8k  ↓0.0k
      #
      # When the owning {Agent} has a non-empty {Agent#id} (i.e. a
      # sub-agent), the line is prefixed with +[id] +:
      #
      #   [researcher 0] msg #1: ctx=4.2k  Δ+4.2k  ↑4.2k  ↓0.0k
      #
      # +ctx+ is the snapshot
      # (+input + cached + cache_creation + output+; see
      # {Event::Tokens}), optionally suffixed with +/<cap>+ when
      # {#context_window_cap} is set so the operator can see how
      # close the conversation is to the limit. Including +output+
      # makes this turn's reply visible immediately — leaving it
      # out would hide a long reply in the +ctx=+ headline until
      # the next turn pulled it in as cached prompt. +Δ+ is
      # signed: +Δ+X+ for growth, +Δ-X+ for shrinkage (legitimate
      # if ruby_llm ever prunes between turns). On the first
      # message the baseline is implicitly zero, so +Δ+ equals
      # +ctx+. Sizes are scaled by 1024 and shown with one
      # decimal + a +k+ suffix.
      class TokenLog < Base
        # Subsystem logger; the per-turn context-window line is
        # emitted at +INFO+ level. Set its level with
        # +PIKURI_LOG_TOKENS+ or the global +PIKURI_LOG+.
        #
        # @return [Logger]
        LOGGER = Pikuri.logger_for('Tokens')

        # Tokens consumed by the conversation through the most
        # recent turn — this turn's prompt plus its reply, which
        # together make up the bulk of what the next turn will
        # re-process. Equals +input + cached + cache_creation +
        # output+ from the latest {Event::Tokens}. Zero until the
        # first {Event::Tokens} arrives.
        #
        # @return [Integer]
        attr_reader :context_window_size

        # Model's context-window cap, or +nil+ if no source could
        # supply one (see {Agent::ContextWindowDetector}). When
        # set, the +ctx=+ field renders as +ctx=<used>/<cap>+
        # instead of just +ctx=<used>+. {Agent#initialize} emits a
        # one-shot {Event::ContextCap} at construction; this
        # listener picks the value off it and caches it here. An
        # instance constructed bare (e.g. in tests, or by
        # {#for_sub_agent}) defaults to +nil+.
        #
        # @return [Integer, nil]
        attr_accessor :context_window_cap

        # @return [String] owning agent's id ({Agent#id}). Empty by
        #   default (main agent); set by {#for_sub_agent} from the
        #   sub-agent's generated id so the log lines can be
        #   prefixed with +[<id>] +. Read-only — for a sub-agent's
        #   listener you get a fresh instance via {#for_sub_agent}.
        attr_reader :id

        # The most recent status line, *without* the +[<id>] +
        # prefix — the prefix is {LOGGER}'s concern (the log
        # stream interleaves agents, so its lines must carry the
        # id inline); consumers of this reader get the id
        # separately ({#id} here, the first callable parameter on
        # {#on_status_line}) and decide the presentation
        # themselves. Empty until the first {Event::Tokens} has
        # been processed. Hosts that
        # want to surface the current context-window snapshot in
        # their own UI (e.g. a TUI status footer) read this
        # instead of re-implementing the formatting. Hosts that
        # want to be *pushed* each new line instead of polling
        # set {#on_status_line}.
        #
        # Thread safety: a single instance-variable read of a
        # +String+ — safe to read from any thread; readers may
        # briefly see the previous turn's line during an in-flight
        # {#on_event} call, which is acceptable for a status
        # display.
        #
        # @return [String]
        attr_reader :status_line

        # Optional status-line observer, +nil+ by default. When
        # set to a callable, it is invoked with the owning
        # agent's {#id} and the freshly formatted {#status_line}
        # after every {Event::Tokens} — the push counterpart to
        # polling {#status_line}, for hosts that stream the line
        # onward (a Sinatra SSE endpoint pushing it to the
        # browser, a websocket, a TUI redraw trigger). Fires on
        # whatever thread runs the owning agent's loop, so the
        # callable must hand off to its sink thread-safely; and
        # like any listener it sits on the loop's path — an
        # exception it raises propagates into the conversation,
        # so handle dead connections inside the callable.
        #
        # Instances derived via {#for_sub_agent} copy the
        # observer set at derivation time, so one callable
        # receives parent and sub-agent lines alike; the +id+
        # parameter (+""+ for the main agent, the generated id
        # for a sub-agent) is what lets the UI route each line to
        # the right status row — the line itself is unprefixed
        # (see {#status_line}). An observer assigned *after*
        # a sub-agent spawned doesn't reach that sub-agent's
        # instance.
        #
        # @return [Proc, nil] called with +(id, status_line)+ —
        #   the owning agent's id +String+ and the unprefixed
        #   {#status_line} +String+
        attr_accessor :on_status_line

        # @param id [String] owning agent's id, prepended to each
        #   log line as +[<id>] + when non-empty. Defaults to +""+
        #   for the main agent.
        def initialize(id: '')
          super()
          @id = id
          @msg = 0
          @context_window_size = 0
          @context_window_cap = nil
          @status_line = ''
          @on_status_line = nil
        end

        # Sub-agent variant: a fresh +TokenLog+ with a zeroed
        # snapshot so the sub-agent's context-window readings
        # track its own +RubyLLM::Chat+ rather than continuing the
        # parent's. Picks the sub-agent's +id:+ out of the
        # forwarded params so its log lines carry the +[<id>] +
        # prefix; defaults to +""+ when absent. The cap is left
        # +nil+ here; the sub-agent's {Agent#initialize} emits a
        # fresh {Event::ContextCap} immediately after construction
        # and this listener picks it up off the stream. The
        # {#on_status_line} observer carries over by reference, so
        # a host streaming the parent's lines sees the sub-agent's
        # too — distinguished by the +id+ the callable receives.
        #
        # @param id [String] sub-agent's id
        # @return [TokenLog]
        def for_sub_agent(id: '', **)
          derived = self.class.new(id: id)
          derived.on_status_line = @on_status_line
          derived
        end

        # @param event [Agent::Event]
        # @return [void]
        def on_event(event)
          case event
          in Event::Tokens => tokens
            log_tokens(tokens)
          in Event::ContextCap(cap:)
            @context_window_cap = cap
          in Event::Reset
            reset_snapshot
          else
            # Every other variant: no-op.
          end
        end

        # @return [String] short label for {Agent#to_s}, including
        #   the current context-window size (with cap suffix when
        #   set)
        def to_s
          "TokenLog(ctx=#{format_ctx})"
        end

        private

        # Zero the running snapshot on an {Event::Reset} (the host
        # cleared the conversation): the next conversation starts from
        # message #1 again, so the message counter, the running
        # context-window size, and the status line all reset to their
        # construction-time values. The cap is *not* cleared — it is a
        # property of the (unchanged) model, not the conversation. The
        # cleared status line is pushed to {#on_status_line} so a TUI
        # footer blanks immediately rather than showing the prior
        # conversation's +ctx=+ until the first new turn arrives.
        #
        # @return [void]
        def reset_snapshot
          @msg = 0
          @context_window_size = 0
          @status_line = ''
          @on_status_line&.call(@id, @status_line)
          nil
        end

        # Update the snapshot, write one +INFO+ line to the
        # subsystem logger, and push the line to the status-line
        # observer (when one was given at construction).
        #
        # @param tokens [Event::Tokens]
        # @return [void]
        def log_tokens(tokens)
          @msg += 1
          input_now          = tokens.input.to_i
          cached_now         = tokens.cached.to_i
          cache_creation_now = tokens.cache_creation.to_i

          prev_ctx = @context_window_size
          @context_window_size = input_now + cached_now + cache_creation_now + tokens.output.to_i
          delta = @context_window_size - prev_ctx

          @status_line = format_line(input_now, tokens.output.to_i, delta)
          prefix = @id.empty? ? '' : "[#{@id}] "
          LOGGER.info("#{prefix}#{@status_line}")
          @on_status_line&.call(@id, @status_line)
        end

        def format_line(input, output, delta)
          sign = delta.negative? ? '-' : '+'
          "msg ##{@msg}: ctx=#{format_ctx}  Δ#{sign}#{format_k(delta.abs)}  ↑#{format_k(input)}  ↓#{format_k(output)}"
        end

        # +<used>+ when no cap is set, +<used>/<cap>+ when one is.
        # Shared between {#format_line} and {#to_s} so the headline
        # reads the same in the log stream and in {Agent#to_s}
        # banners.
        def format_ctx
          base = format_k(@context_window_size)
          return base if @context_window_cap.nil?

          "#{base}/#{format_k(@context_window_cap)}"
        end

        # Format a token count as a 1024-scaled +k+-suffixed
        # string. +nil+ → +0.0k+; +0+ → +0.0k+; 12_453 → +12.2k+.
        # Uniform format keeps lines easy to scan at the cost of
        # looking odd for very small per-turn outputs (+↓0.0k+ on
        # tool-call acks).
        #
        # @param n [Integer, nil]
        # @return [String]
        def format_k(n)
          format('%.1fk', n.to_i / 1024.0)
        end
      end
    end
  end
end
